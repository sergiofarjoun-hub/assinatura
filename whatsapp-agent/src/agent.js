// Chamada ao Claude (Messages API) com histórico multi-turno.
'use strict';

const Anthropic = require('@anthropic-ai/sdk');
const config = require('./config');
const { CLIENT_PROMPT, ADMIN_PROMPT } = require('./prompts');

const client = new Anthropic(); // lê ANTHROPIC_API_KEY do ambiente

const FALLBACK_CLIENT =
  'Peço desculpas, não foi possível processar sua mensagem neste momento. ' +
  'O Concierge da Hamsa entrará em contato em breve. Agradeço a compreensão.';
const FALLBACK_ADMIN = '⚠️ Não consegui gerar resposta (veja os logs do agente).';

/**
 * Gera a resposta do agente para um chat.
 * @param {Array<{role: 'user'|'assistant', content: string}>} history histórico (termina em user)
 * @param {boolean} admin true = modo assistente pessoal, false = modo cliente
 * @param {{kind:'image'|'pdf', mediaType:string, dataB64:string}|null} [media] anexo da última mensagem
 * @returns {Promise<string>} texto da resposta
 */
async function generateReply(history, admin, media, systemNote) {
  const systemPrompt = admin ? ADMIN_PROMPT : CLIENT_PROMPT;
  const systemBlocks = [
    { type: 'text', text: systemPrompt, cache_control: { type: 'ephemeral' } },
  ];
  // Nota volátil do sistema (ex.: cadastro localizado) vai num bloco separado,
  // DEPOIS do bloco cacheado, para não invalidar o cache do prompt principal.
  if (systemNote) systemBlocks.push({ type: 'text', text: systemNote });

  // Se a última mensagem trouxe imagem/PDF, transforma o conteúdo do último
  // turno num array de blocos (mídia + texto) para o Claude analisar o arquivo.
  let messages = history;
  if (media && history.length) {
    const last = history[history.length - 1];
    const mediaBlock =
      media.kind === 'pdf'
        ? {
            type: 'document',
            source: { type: 'base64', media_type: 'application/pdf', data: media.dataB64 },
          }
        : {
            type: 'image',
            source: { type: 'base64', media_type: media.mediaType, data: media.dataB64 },
          };
    messages = history.slice(0, -1).concat({
      role: 'user',
      content: [mediaBlock, { type: 'text', text: last.content }],
    });
  }

  try {
    const response = await client.messages.create({
      model: config.model,
      max_tokens: config.maxTokens,
      thinking: { type: 'adaptive' },
      output_config: { effort: config.effort },
      system: systemBlocks,
      messages,
    });

    if (response.stop_reason === 'refusal') {
      console.warn('Claude recusou a solicitação (stop_reason=refusal)');
      return admin ? FALLBACK_ADMIN : FALLBACK_CLIENT;
    }

    const text = response.content
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
      .trim();

    if (response.stop_reason === 'max_tokens') {
      console.warn('Resposta truncada em max_tokens; considere aumentar MAX_TOKENS');
    }

    return text || (admin ? FALLBACK_ADMIN : FALLBACK_CLIENT);
  } catch (err) {
    if (err instanceof Anthropic.RateLimitError) {
      console.error('Rate limit da API Anthropic:', err.message);
    } else if (err instanceof Anthropic.AuthenticationError) {
      console.error('ANTHROPIC_API_KEY inválida:', err.message);
    } else if (err instanceof Anthropic.APIError) {
      console.error(`Erro da API Anthropic (${err.status}):`, err.message);
    } else {
      console.error('Erro inesperado ao chamar o Claude:', err);
    }
    return admin ? FALLBACK_ADMIN : FALLBACK_CLIENT;
  }
}

// Extrai nome do cliente e número da apólice da conversa, se mencionados.
// Chamada leve e barata; retorna { nome, apolice } com strings vazias quando
// não encontrado. Nunca lança — em erro devolve {}.
async function extractIdentity(history) {
  const convo = history
    .map((m) => `${m.role === 'user' ? 'Cliente' : 'Atendente'}: ${m.content}`)
    .join('\n')
    .slice(-4000);
  try {
    const response = await client.messages.create({
      model: config.model,
      max_tokens: 200,
      output_config: {
        format: {
          type: 'json_schema',
          schema: {
            type: 'object',
            properties: {
              nome: { type: 'string', description: 'Nome do cliente, ou "" se não informado' },
              apolice: {
                type: 'string',
                description: 'Número da apólice, ou "" se não informado',
              },
              operadora: {
                type: 'string',
                description:
                  'Operadora/seguradora citada (ex.: VUMI, Ever, Redbridge, AFGS, Trawick), ou "" se não informado',
              },
              assunto: {
                type: 'string',
                description:
                  'Tipo de solicitação em curso: "reembolso" (reembolso/claim), "gop" ' +
                  '(internação/garantia de pagamento), "exames" (autorização de exames), ' +
                  'ou "" se ainda não estiver claro',
              },
            },
            required: ['nome', 'apolice', 'operadora', 'assunto'],
            additionalProperties: false,
          },
        },
      },
      messages: [
        {
          role: 'user',
          content:
            'Extraia da conversa de atendimento: NOME do cliente, NÚMERO DA APÓLICE, ' +
            'OPERADORA e o ASSUNTO/tipo de solicitação (reembolso, gop ou exames). ' +
            'Se algum não estiver presente, devolva "" (string vazia). Não invente.\n\n' +
            convo,
        },
      ],
    });
    const text = response.content.find((b) => b.type === 'text')?.text || '{}';
    const data = JSON.parse(text);
    return {
      nome: (data.nome || '').trim(),
      apolice: (data.apolice || '').trim(),
      operadora: (data.operadora || '').trim(),
      assunto: (data.assunto || '').trim().toLowerCase(),
    };
  } catch (err) {
    console.error('Falha ao extrair identidade do cliente:', err.message);
    return {};
  }
}

// Modelo inicial da ficha, usado quando o cliente ainda não tem uma.
const FICHA_TEMPLATE = `# Ficha do cliente

## Dados
- Titular:
- Apólice:
- Operadora:
- Família / dependentes:
- Contato (WhatsApp):

## Resumo da relação
(visão geral do cliente, preferências, observações relevantes)

## Histórico de interações
(registro de TODA interação com o cliente — uma linha por contato)
| Data | Canal | Assunto | Resumo do que aconteceu |
|------|-------|---------|-------------------------|

## Claims / Reembolsos
| Data | Paciente | Procedimento / Prestador | Valor cobrado | Aplicado à franquia | Pago | Status |
|------|----------|--------------------------|---------------|---------------------|------|--------|

## Posição da franquia
- Por pessoa:
- Familiar (agregada):
(Só registre valor aplicado à franquia com base em EOB ou valor CONFIRMADO pela
seguradora. Sem confirmação, deixe em branco ou marque "estimativa".)

## Documentos recebidos
| Data | Documento | Referente a |
|------|-----------|-------------|

## Pendências / próximos passos
-
`;

// Mantém a ficha de memória de longo prazo do cliente. Recebe a ficha atual, a
// conversa recente e (se houver) o documento anexo, e devolve a ficha
// ATUALIZADA em Markdown. Nunca lança — em erro devolve null (ficha inalterada).
async function updateFicha(currentFicha, history, media) {
  const convo = history
    .map((m) => `${m.role === 'user' ? 'Cliente' : 'Atendente'}: ${m.content}`)
    .join('\n')
    .slice(-6000);

  const instruction =
    'Você é o responsável por manter a FICHA de memória de um cliente da corretora ' +
    'Hamsa (seguro-saúde internacional). A ficha fica salva na pasta do cliente e é ' +
    'relida a cada atendimento: é a memória de longo prazo dele e o controle de claims.\n\n' +
    'Receba a FICHA ATUAL e a CONVERSA RECENTE (e um documento anexo, se houver) e ' +
    'devolva a FICHA ATUALIZADA em Markdown. Regras:\n' +
    '- PRESERVE tudo o que já existe na ficha; apenas acrescente/atualize o que for novo. ' +
    'Nunca apague histórico anterior.\n' +
    '- Registre em "Histórico de interações" TODA e qualquer interação com o cliente: ' +
    'uma linha por contato, com data, canal (WhatsApp), assunto e um resumo objetivo do ' +
    'que aconteceu (o que o cliente pediu, o que foi respondido, documentos enviados).\n' +
    '- Registre cada claim/reembolso como uma linha na tabela "Claims / Reembolsos" ' +
    '(data, paciente, procedimento/prestador, valor cobrado, valor aplicado à franquia, ' +
    'valor pago, status). Status: "pendente", "processado" ou "negado". Atualize o status ' +
    'quando a conversa ou um documento indicar mudança.\n' +
    '- FRANQUIA: só some/registre "aplicado à franquia" com base em valor CONFIRMADO ' +
    '(controle de Claims/Renovações da Hamsa, EOB da seguradora ou documento oficial). ' +
    'Sem confirmação, deixe em branco ou marque "estimativa". NUNCA invente números.\n' +
    '- Some a franquia por pessoa e o total familiar em "Posição da franquia".\n' +
    '- Se houver documento anexo (EOB, nota fiscal, recibo, pedido médico, relatório), ' +
    'extraia dele os dados relevantes e registre em "Documentos recebidos" e, se for o ' +
    'caso, na tabela de claims.\n' +
    '- Seja conciso e factual. Sem conselhos, apenas o registro.\n' +
    '- Responda SOMENTE com o Markdown da ficha, nada fora dela.\n\n' +
    'Se a ficha atual estiver vazia, comece a partir deste modelo:\n\n' +
    FICHA_TEMPLATE;

  const content = [];
  if (media) {
    content.push(
      media.kind === 'pdf'
        ? {
            type: 'document',
            source: { type: 'base64', media_type: 'application/pdf', data: media.dataB64 },
          }
        : {
            type: 'image',
            source: { type: 'base64', media_type: media.mediaType, data: media.dataB64 },
          }
    );
  }
  content.push({
    type: 'text',
    text:
      '=== FICHA ATUAL ===\n' +
      (currentFicha || '(vazia — crie a partir do modelo)') +
      '\n\n=== CONVERSA RECENTE ===\n' +
      convo +
      '\n\n=== FIM ===\nDevolva a ficha atualizada, completa, em Markdown.',
  });

  try {
    const response = await client.messages.create({
      model: config.model,
      max_tokens: 3000,
      system: instruction,
      messages: [{ role: 'user', content }],
    });
    const text = response.content
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
      .trim();
    return text || null;
  } catch (err) {
    console.error('Falha ao atualizar ficha do cliente:', err.message);
    return null;
  }
}

module.exports = { generateReply, extractIdentity, updateFicha };
