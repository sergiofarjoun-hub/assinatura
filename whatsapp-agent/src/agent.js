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
async function generateReply(history, admin, media) {
  const systemPrompt = admin ? ADMIN_PROMPT : CLIENT_PROMPT;

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
      system: [
        {
          type: 'text',
          text: systemPrompt,
          cache_control: { type: 'ephemeral' },
        },
      ],
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
            },
            required: ['nome', 'apolice'],
            additionalProperties: false,
          },
        },
      },
      messages: [
        {
          role: 'user',
          content:
            'Extraia o NOME do cliente e o NÚMERO DA APÓLICE mencionados nesta ' +
            'conversa de atendimento. Se algum não estiver presente, devolva "" ' +
            '(string vazia). Não invente.\n\n' +
            convo,
        },
      ],
    });
    const text = response.content.find((b) => b.type === 'text')?.text || '{}';
    const data = JSON.parse(text);
    return { nome: (data.nome || '').trim(), apolice: (data.apolice || '').trim() };
  } catch (err) {
    console.error('Falha ao extrair identidade do cliente:', err.message);
    return {};
  }
}

module.exports = { generateReply, extractIdentity };
