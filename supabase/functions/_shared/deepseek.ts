// DeepSeek as a podcast script provider (owner request 2026-10-14; docs/architecture/PAPER_PODCASTS.md "DeepSeek
// script provider"). The worker's script calls are Anthropic-shaped (`ScriptParams`); this adapter sends them to
// DeepSeek's OpenAI-compatible chat completions API with JSON mode and the draft's schema in the system prompt,
// and reports usage in the same shape as the Anthropic adapter so pricing, ceilings and settlement are unchanged.
// Prices are the PEAK list prices (DeepSeek bills less off-peak); the rate card in anthropic.ts carries them.
import type { ScriptCallResult, ScriptParams, ScriptProvider, ScriptUsage } from './podcast-script.ts';

export const DEEPSEEK_BASE_URL = 'https://api.deepseek.com';
export const DEEPSEEK_MODELS = ['deepseek-v4-pro', 'deepseek-flash'] as const;
/** The prompt's size estimate when there is no count endpoint: DeepSeek has none, so a conservative 2.5 bytes per token. */
export const DEEPSEEK_BYTES_PER_TOKEN = 2.5;

type Block = { type: string; text?: string };
/** Anthropic-shaped params to chat-completion messages: system text (and the output schema) first, then each turn's text. */
export function deepseekMessages(params: ScriptParams): { role: 'system' | 'user' | 'assistant'; content: string }[] {
  const system: string[] = [];
  if (typeof params.system === 'string') system.push(params.system);
  else if (Array.isArray(params.system)) system.push(...(params.system as Block[]).filter(b => b.type === 'text').map(b => b.text ?? ''));
  const format = (params as { output_config?: { format?: { type?: string; schema?: unknown } } }).output_config?.format;
  if (format?.type === 'json_schema' && format.schema) {
    system.push(`Respond with exactly one JSON object and nothing else, as compact JSON on one line (no indentation, no line breaks between keys: the output allowance counts every character). It must match this JSON schema:\n${JSON.stringify(format.schema)}`);
  } else system.push('Respond with exactly one compact JSON object on one line and nothing else.');
  // DeepSeek writes notation into speech more than Claude does (four turns of the owner's first episode were cut for it).
  system.push('Spoken text is plain prose for a voice: no Markdown, no asterisks, no backticks, no LaTeX, no dollar signs, no symbols; say numbers, variables and formulas in words.');
  const messages: { role: 'system' | 'user' | 'assistant'; content: string }[] = [{ role: 'system', content: system.join('\n\n') }];
  for (const message of params.messages) {
    const content = typeof message.content === 'string' ? message.content
      : (message.content as Block[]).filter(b => b.type === 'text').map(b => b.text ?? '').join('\n\n');
    messages.push({ role: message.role, content });
  }
  return messages;
}

interface Completion {
  id?: string; model?: string;
  choices?: { message?: { content?: string | null }; finish_reason?: string | null }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number; prompt_cache_hit_tokens?: number; prompt_cache_miss_tokens?: number };
}
const count = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0 ? v as number : null;

/** Usage in the adapter's shape: cache hits priced as cache reads, misses as input; DeepSeek has no cache-write price. */
export function deepseekUsage(usage: Completion['usage']): ScriptUsage | null {
  const prompt = count(usage?.prompt_tokens), output = count(usage?.completion_tokens);
  if (prompt === null || output === null) return null;
  const hit = count(usage?.prompt_cache_hit_tokens) ?? 0;
  const miss = count(usage?.prompt_cache_miss_tokens) ?? Math.max(0, prompt - hit);
  return { input: miss, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: Math.min(hit, prompt), output };
}

export function deepseekScriptProvider(options: { apiKey: string; baseURL?: string; fetch?: typeof fetch }): ScriptProvider {
  const base = (options.baseURL ?? DEEPSEEK_BASE_URL).replace(/\/$/, ''), doFetch = options.fetch ?? fetch;
  return {
    // No count endpoint: a conservative estimate from the request's bytes, never a paid call.
    async countTokens(params) {
      const bytes = new TextEncoder().encode(JSON.stringify(deepseekMessages(params))).byteLength;
      return Math.ceil(bytes / DEEPSEEK_BYTES_PER_TOKEN);
    },
    async generate(params, signal): Promise<ScriptCallResult> {
      // Thinking is on by default (effort high) and its tokens come out of max_tokens before any content: a 60-token
      // probe on 2026-10-14 returned nothing but reasoning. The Anthropic path thinks only between tool calls (none
      // here), so parity is no thinking: the output allowance is the script's.
      const body = { model: params.model, messages: deepseekMessages(params), max_tokens: params.max_tokens, stream: false,
        response_format: { type: 'json_object' }, thinking: { type: 'disabled' }, temperature: 0.3 };
      let response: Response;
      try {
        response = await doFetch(`${base}/chat/completions`, { method: 'POST', signal,
          headers: { 'content-type': 'application/json', authorization: `Bearer ${options.apiKey}` }, body: JSON.stringify(body) });
      } catch {
        return { state: 'unknown', requestID: null, model: null, stopReason: null, text: null, usage: null, failure: signal.aborted ? 'deadline' : 'transport_unknown' };
      }
      const requestID = response.headers.get('x-request-id') ?? response.headers.get('x-ds-trace-id');
      if (!response.ok) {
        // Explicit pre-processing rejections are not billed; a server error after the request may have been processed.
        const rejected = [400, 401, 402, 403, 404, 413, 422, 429].includes(response.status);
        return { state: rejected ? 'rejected' : 'unknown', requestID, model: null, stopReason: null, text: null, usage: null, failure: `http_${response.status}` };
      }
      let completion: Completion;
      try { completion = await response.json() as Completion; } catch {
        return { state: 'unknown', requestID, model: null, stopReason: null, text: null, usage: null, failure: 'response_unreadable' };
      }
      const usage = deepseekUsage(completion.usage), choice = completion.choices?.[0];
      const id = requestID ?? completion.id ?? null;
      if (!usage || !choice) return { state: 'unknown', requestID: id, model: completion.model ?? null, stopReason: null, text: null, usage: null, failure: 'usage_missing' };
      const stopReason = choice.finish_reason === 'stop' ? 'end_turn' : choice.finish_reason === 'length' ? 'max_tokens' : choice.finish_reason ?? null;
      return { state: 'succeeded', requestID: id, model: completion.model ?? params.model, stopReason, text: choice.message?.content ?? '', usage, failure: null };
    },
  };
}
