import { isRouterDeepSeek, routerDeepSeekRates, ROUTER_DEEPSEEK_ENDPOINT } from "./openrouter-deepseek-pricing.ts";
import { openRouterPost, OpenRouterNotDispatched } from "./openrouter-transport.ts";
import { isRouterClaude, routerClaudeRates, ROUTER_CLAUDE_ENDPOINT, ROUTER_CLAUDE_PRICE_EXPIRES } from './openrouter-claude-pricing.ts';
// Gemini Flash on the same pinned OpenRouter -> Google route as the comparison. No SDK retries or alternate routes.
// Chat orchestration still owns tools, consent, admission and settlement. Content/signatures live only in memory.
import type Anthropic from '@anthropic-ai/sdk';
import { emptyUsage, holdForParams, type ProviderAttempt, type ProviderOutcome, type StreamOptions } from './anthropic.ts';
import { GEMINI_MODEL, GEMINI_OPENROUTER_MODEL, GEMINI_ENDPOINT, GEMINI_PRICE_EXPIRES, GEMINI_RATES } from './gemini-pricing.ts';

type Params = Anthropic.Beta.Messages.MessageCreateParamsNonStreaming;
type ObjectValue = Record<string, unknown>;
const object = (v: unknown): ObjectValue => v && typeof v === 'object' && !Array.isArray(v) ? v as ObjectValue : {};
const array = (v: unknown): unknown[] => Array.isArray(v) ? v : [];
const count = (v: unknown): number | null => Number.isSafeInteger(v) && (v as number) >= 0 ? v as number : null;
const string = (v: unknown): string => typeof v === 'string' ? v : '';
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;

/** Error bodies can echo prompts. Inspect a bounded body in memory, returning only our own closed category. */
async function rejectionReason(response: Response): Promise<NonNullable<ProviderOutcome['rejectionReason']>> {
  const reader = response.body?.getReader();
  let text = '', size = 0;
  const decoder = new TextDecoder();
  try {
    if (reader) for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) return 'unknown';
      text += decoder.decode(value, { stream: true });
    }
    const error = object(object(JSON.parse(text)).error);
    const message = string(error.message);
    if (/zero.?data.?retention|\bzdr\b/i.test(message)) return 'privacy_zdr';
    if (/data policy|privacy|zero.?data.?retention|logging|training/i.test(message)) return 'privacy_policy';
    if (/no endpoints|no available provider|model.+not found|unavailable model/i.test(message)) return 'route_unavailable';
    if (response.status === 401 || /api key|authentication|unauthorized/i.test(message)) return 'authentication';
    if (response.status === 402) return 'balance';
    if ([400, 413, 422].includes(response.status)) return 'request_parameters';
  } catch { /* A malformed error body is not copied into logs. */ }
  finally { await reader?.cancel().catch(() => {}); }
  return 'unknown';
}

function part(value: unknown): ObjectValue {
  const b = object(value);
  if (b.type === 'text') return { type: 'text', text: string(b.text), ...(b.cache_control ? { cache_control: b.cache_control } : {}) };
  if (b.type === 'image') {
    const source = object(b.source);
    if (source.type !== 'base64') throw new Error('unsupported_image');
    return { type: 'image_url', image_url: { url: `data:${string(source.media_type)};base64,${string(source.data)}` } };
  }
  if (b.type === 'search_result') return { type: 'text', text: `Source: ${string(b.title)} — ${string(b.source)}\n`
    + array(b.content).map(v => string(object(v).text)).join('\n') };
  throw new Error('unsupported_content');
}

/** Stable system prefix cached for five minutes; action instructions follow it in the user message. Google caches
 * the entire system message, so keeping the dynamic tail in that message would invalidate it on every action. */
export function openRouterChatParams(params: Params): ObjectValue {
  const claude = isRouterClaude(params.model), deepseek = isRouterDeepSeek(params.model);
  if (params.model !== GEMINI_MODEL && !claude && !deepseek) throw new Error('unsupported_model');
  const blocks: Anthropic.Beta.Messages.BetaTextBlockParam[] = typeof params.system === 'string' ? [{ type: 'text', text: params.system }] : params.system ?? [];
  const boundary = blocks.findLastIndex(b => !!b.cache_control);
  const stable = boundary < 0 ? blocks : blocks.slice(0, boundary + 1);
  const tail = claude || deepseek || boundary < 0 ? '' : blocks.slice(boundary + 1).map(b => b.text).join('\n\n');
  const messages: ObjectValue[] = [{ role: 'system', content: deepseek ? blocks.map(b => ({ type: 'text', text: b.text })) : claude ? blocks.map(part) : [{ type: 'text', text: stable.map(b => b.text).join('\n\n'),
    ...(boundary >= 0 ? { cache_control: { type: 'ephemeral', ttl: '5m' } } : {}) }] }];
  for (const [index, m] of params.messages.entries()) {
    const content = typeof m.content === 'string' ? [{ type: 'text', text: m.content }] : m.content;
    const ordinary: ObjectValue[] = [], calls: ObjectValue[] = [], results: ObjectValue[] = [], reasoning: unknown[] = [];
    for (const raw of content) {
      const b = object(raw);
      if (b.type === 'tool_use') calls.push({ id: b.id, type: 'function', function: { name: b.name, arguments: JSON.stringify(b.input) } });
      else if (b.type === 'tool_result') results.push({ role: 'tool', tool_call_id: b.tool_use_id,
        content: typeof b.content === 'string' ? b.content : array(b.content).map(part) });
      else if (b.type === 'openrouter_reasoning') reasoning.push(...array(b.details));
      else ordinary.push(part(b));
    }
    if (tail && index === 0) ordinary.unshift({ type: 'text', text: tail });
    // Tool results precede a new user message, if the same Anthropic turn contains both.
    messages.push(...results);
    if (ordinary.length || calls.length || reasoning.length) messages.push({ role: m.role, content: ordinary.length ? ordinary : null,
      ...(calls.length ? { tool_calls: calls } : {}), ...(reasoning.length ? { reasoning_details: reasoning } : {}) });
  }
  const tools = (params.tools ?? []).map(t => {
    if (!('input_schema' in t)) throw new Error('native_tools_forbidden');
    return { type: 'function', function: { name: t.name, description: t.description, parameters: t.input_schema } };
  });
  const choice = params.tool_choice;
  // Vertex's Claude endpoint supports auto tools, but rejects named/required tool_choice. A single forced
  // auxiliary is an object with the same schema; validate it below and relay it through our existing tool contract.
  const forced = claude && choice?.type === 'tool' ? tools.find(t => t.function.name === choice.name) : undefined;
  if (claude && choice?.type === 'tool' && !forced) throw new Error('tool_invalid');
  const rates = deepseek ? routerDeepSeekRates(params.model) : claude ? routerClaudeRates(params.model, holdForParams(params).inputTokens) : GEMINI_RATES;
  const endpoint = deepseek ? ROUTER_DEEPSEEK_ENDPOINT : claude ? ROUTER_CLAUDE_ENDPOINT : GEMINI_ENDPOINT;
  const structured = params.output_config?.format?.type === 'json_schema' ? params.output_config.format.schema : null;
  return { model: deepseek || claude ? params.model : GEMINI_OPENROUTER_MODEL, messages, ...(forced ? { response_format: { type: 'json_schema', json_schema: { name: forced.function.name, strict: true, schema: { ...forced.function.parameters, additionalProperties: false } } } } : tools.length ? { tools } : {}),
    ...(!forced && structured ? { response_format: { type: 'json_schema', json_schema: { name: 'result', strict: true, schema: structured } } } : {}),
    ...(!forced && choice ? { tool_choice: choice.type === 'tool' ? { type: 'function', function: { name: choice.name } }
      : choice.type === 'any' ? 'required' : choice.type } : {}),
    max_tokens: params.max_tokens, stream: true, stream_options: { include_usage: true },
    reasoning: claude || deepseek ? params.thinking?.type === 'disabled' ? { enabled: false } : { effort: params.output_config?.effort ?? 'low' } : { effort: 'medium' },
    provider: { only: [endpoint], order: [endpoint], allow_fallbacks: false, require_parameters: true,
      data_collection: 'deny', zdr: true, max_price: { prompt: rates.input, completion: rates.output } } };
}

/** Final cost and token counters must both exist. Thinking is already included in completion_tokens. */
export function openRouterAttempt(value: unknown, model = GEMINI_MODEL, hourCache = false): ProviderAttempt | null {
  const u = object(value), details = object(u.prompt_tokens_details);
  const prompt = count(u.prompt_tokens), output = count(u.completion_tokens);
  const cached = count(details.cached_tokens === undefined ? 0 : details.cached_tokens);
  const written = count(details.cache_write_tokens === undefined ? 0 : details.cache_write_tokens);
  if (prompt === null || output === null || cached === null || written === null || cached > prompt || written > prompt || typeof u.cost !== 'number'
    || !Number.isFinite(u.cost) || u.cost < 0 || u.cost > 1_000_000) return null;
  const claude = isRouterClaude(model);
  if (claude && cached + written > prompt) return null;
  // Google's cache creation/storage counter can name the same tokens as cached_tokens. It is not a third,
  // disjoint input category (confirmed by the saved comparison bills); reported cost already includes storage.
  return { model, estimated: false, billedMicrousd: u.cost * 1_000_000,
    ...(!claude && model === GEMINI_MODEL && written ? { cacheStorageTokens: written } : {}),
    usage: { input: prompt - cached - (claude ? written : 0), cacheRead: cached, cacheWrite5m: claude && !hourCache ? written : 0, cacheWrite1h: claude && hourCache ? written : 0, output } };
}

export function openRouterChat(options: { apiKey: string; fetch?: typeof fetch; now?: () => number }) {
  return async (params: Params, stream: StreamOptions): Promise<ProviderOutcome> => {
    let id: string | null = null, attempt: ProviderAttempt | null = null;
    const failed = (exact = false, failure: ProviderOutcome['failure'] = 'provider_error'): ProviderOutcome => ({
      status: 'failed', failure, messageID: id, requestID: id, model: params.model, stopReason: null, refusalCategory: null,
      attempts: attempt ? [attempt] : exact ? [] : [{ model: params.model, estimated: true,
        usage: { ...emptyUsage(), input: stream.inputEstimateTokens, output: params.max_tokens } }], exact: exact || attempt !== null });
    if (stream.signal.aborted) return failed(true, 'aborted');
    // Reject locally before any network call. Price caps independently reject provider price increases.
    if ((options.now?.() ?? Date.now()) >= (isRouterClaude(params.model) ? ROUTER_CLAUDE_PRICE_EXPIRES : GEMINI_PRICE_EXPIRES)) return { ...failed(true), cause: 'server' };
    let body: ObjectValue;
    try { body = openRouterChatParams(params); } catch { return { ...failed(true), cause: 'server' }; }
    let response: Response;
    try {
      response = await openRouterPost(options, 'chat/completions', body, stream.signal, stream.attribution);
    } catch (error) { return failed(error instanceof OpenRouterNotDispatched, stream.signal.aborted ? 'aborted' : 'provider_error'); }
    id = response.headers.get('x-generation-id');
    if (!response.ok) {
      const reason = await rejectionReason(response);
      const exact = [400, 401, 402, 403, 404, 413, 422, 429].includes(response.status);
      const delay = Number(response.headers.get('retry-after'));
      return { ...failed(exact, response.status === 402 ? 'provider_billing' : response.status >= 500 || response.status === 429 ? 'provider_error' : 'provider_rejected'),
        httpStatus: response.status, rejectionReason: reason,
        retryAfterMs: Number.isFinite(delay) && delay > 0 ? Math.min(delay * 1000, 60_000) : null };
    }
    if (!response.body) return failed();
    const forced = isRouterClaude(params.model) && params.tool_choice?.type === 'tool' ? params.tool_choice.name : null;
    let text = '', finish = '', done = false, buffer = '', bytes = 0, provider = '';
    const calls = new Map<number, { id: string; name: string; arguments: string }>();
    const reasoning = new Map<number, ObjectValue>();
    const reader = response.body.getReader(), decoder = new TextDecoder();
    try {
      while (!done) {
        const chunk = await reader.read();
        if (chunk.done) break;
        bytes += chunk.value.byteLength;
        if (bytes > MAX_RESPONSE_BYTES) throw new Error('response_limit');
        buffer += decoder.decode(chunk.value, { stream: true });
        let newline: number;
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline).trim(); buffer = buffer.slice(newline + 1);
          if (!line.startsWith('data:')) continue;
          const data = line.slice(5).trim();
          if (data === '[DONE]') { done = true; break; }
          const event = object(JSON.parse(data));
          if (event.error) throw new Error('stream_error');
          if (typeof event.id === 'string') {
            if (id && id !== event.id) throw new Error('generation_changed');
            id = event.id;
          }
          if (event.model !== undefined && event.model !== body.model) throw new Error('model_changed');
          if (typeof event.provider === 'string' && /^[a-zA-Z0-9 ./_-]{1,80}$/.test(event.provider)) provider = event.provider;
          const choice = object(array(event.choices)[0]), delta = object(choice.delta);
          if (typeof delta.content === 'string') { text += delta.content; if (!forced) stream.onText(delta.content); }
          for (const raw of array(delta.tool_calls)) {
            const call = object(raw), index = count(call.index), fn = object(call.function);
            if (index === null || index > 31) throw new Error('tool_index');
            const previous = calls.get(index) ?? { id: '', name: '', arguments: '' };
            previous.id += string(call.id); previous.name += string(fn.name); previous.arguments += string(fn.arguments);
            calls.set(index, previous);
          }
          for (const raw of array(delta.reasoning_details)) {
            const detail = object(raw), index = count(detail.index) ?? 0, previous = reasoning.get(index);
            if (index > 127) throw new Error('reasoning_index');
            const next = { ...previous, ...detail };
            for (const key of ['text', 'data', 'signature', 'summary']) if (typeof detail[key] === 'string') next[key] = string(previous?.[key]) + detail[key];
            reasoning.set(index, next);
          }
          if (typeof choice.finish_reason === 'string') finish = choice.finish_reason;
          // Initial usage counters are not a final bill. Only accept usage at/after the finish event.
          if (finish && event.usage) attempt = openRouterAttempt(event.usage, params.model, Array.isArray(params.system) && params.system.some(b => b.cache_control?.ttl === '1h'));
        }
      }
      if (!done || !attempt || !id || !['stop', 'tool_calls', 'length', 'content_filter'].includes(finish)) return failed();
      const toolCalls = [...calls.values()].map(c => {
        if (!c.id || !c.name || !(params.tools ?? []).some(t => 'name' in t && t.name === c.name)) throw new Error('tool_invalid');
        return { id: c.id, name: c.name, input: JSON.parse(c.arguments) as unknown };
      });
      if (forced && finish === 'stop') {
        toolCalls.push({ id: `structured-${id}`, name: forced, input: JSON.parse(text) as unknown });
        text = ''; finish = 'tool_calls';
      }
      if (finish === 'tool_calls' && !toolCalls.length) return failed();
      if (provider && stream.attribution?.receipt) await stream.attribution.receipt({ generation_id: id, provider, model: String(body.model), total_cost_microusd: Math.ceil(attempt.billedMicrousd!) });
      return { status: 'complete', failure: null, messageID: id, requestID: id, model: params.model,
        stopReason: finish === 'stop' ? 'end_turn' : finish === 'tool_calls' ? 'tool_use' : finish === 'length' ? 'max_tokens' : 'refusal',
        refusalCategory: finish === 'content_filter' ? 'provider' : null, attempts: [attempt], exact: true, toolCalls,
        content: [...(reasoning.size ? [{ type: 'openrouter_reasoning', details: [...reasoning.values()] }] : []),
          ...(text ? [{ type: 'text', text }] : []), ...toolCalls.map(c => ({ type: 'tool_use', ...c }))] };
    } catch { return failed(false, stream.signal.aborted ? 'aborted' : 'provider_error'); }
    finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  };
}
