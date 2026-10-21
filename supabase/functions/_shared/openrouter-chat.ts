import { isRouterDeepSeek, routerDeepSeekRates, ROUTER_DEEPSEEK_ENDPOINT } from "./openrouter-deepseek-pricing.ts";
import { openRouterPost, OpenRouterNotDispatched } from "./openrouter-transport.ts";
import { isRouterClaude, routerClaudeRates, ROUTER_CLAUDE_ENDPOINT } from './openrouter-claude-pricing.ts';
// The one model adapter: every chat answer, title, suggestion, Study map, tag and podcast script goes to OpenRouter on a
// pinned route (Claude and Gemini through Google Vertex, DeepSeek through DeepInfra). No retries or alternate routes.
// It translates our request shape (model-request.ts) into OpenRouter's chat/completions body. Chat orchestration still
// owns tools, consent, admission and settlement. Content/signatures live only in memory.
import type { ModelRequest, TextBlock } from './model-request.ts';
import { emptyUsage, ESTIMATED_OUTPUT_TOKENS_PER_SECOND, holdForParams, type ProviderAttempt, type ProviderOutcome, type StreamOptions } from './inference.ts';
import { lookupGeneration, type GenerationLookupOptions, type GenerationRecord } from './openrouter-generation.ts';
import { GEMINI_MODEL, GEMINI_OPENROUTER_MODEL, GEMINI_ENDPOINT, GEMINI_RATES } from './gemini-pricing.ts';

type Params = ModelRequest;
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

/** The model and pinned endpoint a chat request is sent as (one source for the request body and its dispatch record). */
export function openRouterTransportFor(model: string): { transport_model: string; endpoint: string } | null {
  if (isRouterDeepSeek(model)) return { transport_model: model, endpoint: ROUTER_DEEPSEEK_ENDPOINT };
  if (isRouterClaude(model)) return { transport_model: model, endpoint: ROUTER_CLAUDE_ENDPOINT };
  if (model === GEMINI_MODEL) return { transport_model: GEMINI_OPENROUTER_MODEL, endpoint: GEMINI_ENDPOINT };
  return null;
}

/** Stable system prefix cached for five minutes; action instructions follow it in the user message. Google caches
 * the entire system message, so keeping the dynamic tail in that message would invalidate it on every action. */
export function openRouterChatParams(params: Params): ObjectValue {
  const claude = isRouterClaude(params.model), deepseek = isRouterDeepSeek(params.model);
  if (params.model !== GEMINI_MODEL && !claude && !deepseek) throw new Error('unsupported_model');
  const blocks: TextBlock[] = typeof params.system === 'string' ? [{ type: 'text', text: params.system }] : params.system ?? [];
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
    // Tool results precede a new user message, if the same turn contains both.
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

/** Reads for a generation's record after a stream was cut short (a Stop, a dropped connection, our deadline): OpenRouter
 * writes it a few seconds after the generation ends. Bounded so settlement still finishes inside the function's time. */
export const STOPPED_RECEIPT_WAIT_MS = 7_000;
const STOPPED_RECEIPT_TRIES = 6;

function routeRates(model: string, promptTokens: number) {
  return isRouterDeepSeek(model) ? routerDeepSeekRates(model) : isRouterClaude(model) ? routerClaudeRates(model, promptTokens) : GEMINI_RATES;
}

/** What the reader pays for an answer cut short (PROVIDER_SPENDING.md "Stopped answers and unresolved attempts"): the
 * part that was written, never the whole hold. With OpenRouter's record: its input cost (at most the whole bill) plus
 * its output cost in proportion to the output observed before the stop (a route that keeps generating after a cancel
 * bills the rest; that remainder is Gradstep's). Without the record: the observed output at the route's output rate.
 * Nothing when no text or tool call reached us. Micro-USD, not rounded. */
export function stoppedReaderMicrousd(model: string, observedOutputTokens: number, delivered: boolean, record: GenerationRecord | null): number {
  if (!delivered) return 0;
  if (!record) return observedOutputTokens * routeRates(model, 0).output;
  const rates = routeRates(model, record.promptTokens);
  const cached = Math.min(record.cachedTokens, record.promptTokens);
  const input = Math.min(record.totalMicrousd, (record.promptTokens - cached) * rates.input + cached * rates.cacheRead);
  const share = record.completionTokens > 0 ? Math.min(1, observedOutputTokens / record.completionTokens) : 1;
  return Math.min(record.totalMicrousd, input + (record.totalMicrousd - input) * share);
}

/** The transport model a request is sent as (a generation record names it, possibly with a dated suffix). */
function transportModel(model: string): string {
  return isRouterDeepSeek(model) || isRouterClaude(model) ? model : GEMINI_OPENROUTER_MODEL;
}

/** The tool calls of a finished turn (A23). A call that names no offered tool, has no id or whose arguments don't parse
 * (for example a `length` stop inside a large create_visual call) is dropped and the streamed text is kept: a provider
 * quirk never turns an answer already on the reader's screen into a failure. */
function finishedCalls(calls: Iterable<{ id: string; name: string; arguments: string }>, params: Params): { id: string; name: string; input: unknown }[] {
  const out: { id: string; name: string; input: unknown }[] = [];
  for (const c of calls) {
    if (!c.id || !c.name || !(params.tools ?? []).some(t => 'name' in t && t.name === c.name)) continue;
    try { out.push({ id: c.id, name: c.name, input: JSON.parse(c.arguments) as unknown }); } catch { /* dropped */ }
  }
  return out;
}

export function openRouterChat(options: { apiKey: string; fetch?: typeof fetch; now?: () => number;
  /** Waits between generation-record reads (tests replace it). */
  sleep?: GenerationLookupOptions['sleep']; receiptWaitMs?: number }) {
  return async (params: Params, stream: StreamOptions): Promise<ProviderOutcome> => {
    const clock = options.now ?? Date.now;
    let id: string | null = null, attempt: ProviderAttempt | null = null, dispatched = false;
    // What this stream produced before it ended: characters of text, tool arguments and reasoning, when the first chunk
    // came, and whether any text or tool call reached us (a stopped answer with none costs the reader nothing). As the
    // direct adapter estimated output before 2026-10-18: a token per 3 characters or 100 per second, whichever is more.
    let observedChars = 0, firstChunkAt: number | null = null, delivered = false;
    const observedOutput = () => Math.min(params.max_tokens, Math.max(Math.ceil(observedChars / 3),
      firstChunkAt === null ? 0 : Math.ceil(Math.max(0, clock() - firstChunkAt) / 1000 * ESTIMATED_OUTPUT_TOKENS_PER_SECOND)));
    const failed = (exact = false, failure: ProviderOutcome['failure'] = 'provider_error'): ProviderOutcome => ({
      status: 'failed', failure, messageID: id, requestID: id, model: params.model, stopReason: null, refusalCategory: null,
      // The conservative estimate (every input byte, the whole output allowance) is the platform's liability only.
      attempts: attempt ? [attempt] : exact ? [] : [{ model: params.model, estimated: true,
        usage: { ...emptyUsage(), input: stream.inputEstimateTokens, output: params.max_tokens },
        readerMicrousd: stoppedReaderMicrousd(params.model, observedOutput(), delivered, null) }], exact: exact || attempt !== null });
    // A dispatched stream that was cut short: OpenRouter's record of the generation is the exact bill (the attempt
    // settles as succeeded, nothing left to reconcile); without it the estimate keeps the whole ceiling unresolved.
    const cutShort = async (failure: ProviderOutcome['failure']): Promise<ProviderOutcome> => {
      if (attempt || !dispatched || !id || !stream.attribution) return failed(false, failure);
      const record = await lookupGeneration({ apiKey: options.apiKey, fetch: options.fetch, sleep: options.sleep }, id, stream.attribution,
        AbortSignal.timeout(options.receiptWaitMs ?? STOPPED_RECEIPT_WAIT_MS), STOPPED_RECEIPT_TRIES);
      const expected = transportModel(params.model);
      if (!record || !(record.model === expected || record.model.startsWith(`${expected}-`))) return failed(false, failure);
      const recorded = stream.attribution.receipt ? await stream.attribution.receipt({ generation_id: id, provider: record.provider, model: expected,
        ...(record.model !== expected ? { resolved_model: record.model } : {}), total_cost_microusd: record.totalMicrousd }) : true;
      if (!recorded) return failed(false, failure);
      const cached = Math.min(record.cachedTokens, record.promptTokens);
      attempt = { model: params.model, estimated: false, billedMicrousd: record.totalMicrousd,
        usage: { ...emptyUsage(), input: record.promptTokens - cached, cacheRead: cached, output: record.completionTokens },
        readerMicrousd: stoppedReaderMicrousd(params.model, observedOutput(), delivered, record) };
      return failed(true, failure);
    };
    if (stream.signal.aborted) return failed(true, 'aborted');
    // A card's validity (app_private.openrouter_tariffs, migration 0101) is decided by admission before this adapter
    // runs; the price caps in every request independently reject a provider price increase.
    let body: ObjectValue;
    try { body = openRouterChatParams(params); } catch { return { ...failed(true), cause: 'server' }; }
    let response: Response;
    try {
      response = await openRouterPost(options, 'chat/completions', body, stream.signal, stream.attribution);
    } catch (error) { return failed(error instanceof OpenRouterNotDispatched, stream.signal.aborted ? 'aborted' : 'provider_error'); }
    dispatched = true;
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
          firstChunkAt ??= clock();
          if (typeof delta.content === 'string') {
            text += delta.content; observedChars += delta.content.length;
            if (delta.content.trim()) delivered = true;
            if (!forced) stream.onText(delta.content);
          }
          for (const raw of array(delta.tool_calls)) {
            const call = object(raw), index = count(call.index), fn = object(call.function);
            if (index === null || index > 31) throw new Error('tool_index');
            const previous = calls.get(index) ?? { id: '', name: '', arguments: '' };
            previous.id += string(call.id); previous.name += string(fn.name); previous.arguments += string(fn.arguments);
            observedChars += string(fn.arguments).length; delivered = true;
            calls.set(index, previous);
          }
          for (const raw of array(delta.reasoning_details)) {
            const detail = object(raw), index = count(detail.index) ?? 0, previous = reasoning.get(index);
            if (index > 127) throw new Error('reasoning_index');
            const next = { ...previous, ...detail };
            for (const key of ['text', 'data', 'signature', 'summary']) if (typeof detail[key] === 'string') next[key] = string(previous?.[key]) + detail[key];
            observedChars += string(detail.text).length + string(detail.summary).length;
            reasoning.set(index, next);
          }
          if (typeof choice.finish_reason === 'string') finish = choice.finish_reason;
          // Initial usage counters are not a final bill. Only accept usage at/after the finish event.
          if (finish && event.usage) attempt = openRouterAttempt(event.usage, params.model, Array.isArray(params.system) && params.system.some(b => b.cache_control?.ttl === '1h'));
        }
      }
    } catch { /* a broken or stopped stream: below */ }
    finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
    if (!done || !attempt || !id || !['stop', 'tool_calls', 'length', 'content_filter'].includes(finish)) {
      return await cutShort(stream.signal.aborted ? 'aborted' : 'provider_error');
    }
    const toolCalls = finishedCalls(calls.values(), params);
    if (forced && finish === 'stop') {
      // The forced auxiliary's object; unparsable leaves the turn with nothing usable (its caller decides, unpaid).
      try { toolCalls.push({ id: `structured-${id}`, name: forced, input: JSON.parse(text) as unknown }); } catch { /* dropped */ }
      text = ''; finish = 'tool_calls';
    }
    // A turn that asked only for calls we drop ends as written (its text, if any); a cut-off call stays a length stop.
    if (finish === 'tool_calls' && !toolCalls.length) finish = 'stop';
    // C6: the receipt is written while the caller records the attempt's finish (provider-spending awaits both), not
    // before the outcome returns: one round trip fewer between the last token and `done`.
    const receipt = provider && stream.attribution?.receipt
      ? stream.attribution.receipt({ generation_id: id, provider, model: String(body.model), total_cost_microusd: Math.ceil(attempt.billedMicrousd!) }).catch(() => false)
      : undefined;
    return { status: 'complete', failure: null, messageID: id, requestID: id, model: params.model, ...(receipt ? { receipt } : {}),
      stopReason: finish === 'stop' ? 'end_turn' : finish === 'tool_calls' ? 'tool_use' : finish === 'length' ? 'max_tokens' : 'refusal',
      refusalCategory: finish === 'content_filter' ? 'provider' : null, attempts: [attempt], exact: true, toolCalls,
      content: [...(reasoning.size ? [{ type: 'openrouter_reasoning', details: [...reasoning.values()] }] : []),
        ...(text ? [{ type: 'text', text }] : []), ...toolCalls.map(c => ({ type: 'tool_use', ...c }))] };
  };
}
