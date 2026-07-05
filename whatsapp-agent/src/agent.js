// Chamada ao Claude (Messages API) com histórico multi-turno.
'use strict';

const Anthropic = require('@anthropic-ai/sdk');
const config = require('./config');
const { CLIENT_PROMPT, ADMIN_PROMPT } = require('./prompts');

const client = new Anthropic(); // lê ANTHROPIC_API_KEY do ambiente

const FALLBACK_CLIENT =
  'Peço desculpas, não foi possível processar sua mensagem neste momento. ' +
  'O Sérgio entrará em contato pessoalmente em breve. Agradeço a compreensão.';
const FALLBACK_ADMIN = '⚠️ Não consegui gerar resposta (veja os logs do agente).';

/**
 * Gera a resposta do agente para um chat.
 * @param {Array<{role: 'user'|'assistant', content: string}>} history histórico (termina em user)
 * @param {boolean} admin true = modo assistente pessoal, false = modo cliente
 * @returns {Promise<string>} texto da resposta
 */
async function generateReply(history, admin) {
  const systemPrompt = admin ? ADMIN_PROMPT : CLIENT_PROMPT;
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
      messages: history,
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

module.exports = { generateReply };
