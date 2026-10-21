// Shared structured generation for tags and podcast scripts. The caller owns admission and settlement.
import { holdForParams } from './inference.ts';
import { openRouterChat } from './openrouter-chat.ts';
import { routedClaudeModel } from './openrouter-claude-pricing.ts';
import { routedDeepSeekModel } from './openrouter-deepseek-pricing.ts';
import type { ScriptProvider } from './podcast-script.ts';

export function openRouterScriptProvider(options: { apiKey: string; fetch?: typeof fetch }): ScriptProvider {
  const generate = openRouterChat(options);
  return {
    // No direct-provider token-count endpoint and no paid call disguised as a quote.
    async countTokens() { return null; },
    async generate(params, signal, attribution) {
      const model = routedDeepSeekModel(routedClaudeModel(params.model));
      // DeepSeek and Haiku can disable reasoning. Vertex requires it for Sonnet/Opus: use low effort
      // inside the same reserved output cap, never an unaccounted extra token allowance.
      const requiredThinking = /anthropic\/claude-(?:sonnet|opus)-/.test(model);
      const request = { ...params, model, thinking: requiredThinking ? { type: 'adaptive' as const } : { type: 'disabled' as const },
        ...(requiredThinking ? { output_config: { ...params.output_config, effort: 'low' as const } } : {}) };
      let text = '';
      const result = await generate(request, { signal, attribution, inputEstimateTokens: holdForParams(request).inputTokens,
        onText: delta => { text += delta; } });
      const attempt = result.exact ? result.attempts[0] : null;
      const state = attempt && !attempt.estimated ? 'succeeded' : result.exact ? 'rejected' : 'unknown';
      return { state, requestID: result.requestID ?? result.messageID, model: params.model,
        stopReason: result.stopReason, text: state === 'succeeded' ? text : null,
        usage: attempt?.usage ?? null, billedMicrousd: attempt?.billedMicrousd,
        failure: result.status === 'failed' ? result.httpStatus ? `http_${result.httpStatus}` : result.failure : null };
    },
  };
}
