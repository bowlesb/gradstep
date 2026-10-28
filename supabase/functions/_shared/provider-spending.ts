import { rpcAttribution, type OpenRouterDispatch } from "./openrouter-transport.ts";
import { openRouterTransportFor } from './openrouter-chat.ts';
// Durable admission around one provider transport request. No prompts, queries,
// answers or raw errors are stored/logged; only domain-bound digests and counts.
import type { ModelRequest } from './model-request.ts';
import { holdForParams, priceAttempts, type ProviderOutcome, type StreamOptions } from './inference.ts';
import { providerRequestID, tavilySearch, type SearchInput, type SearchOutcome } from './tavily.ts';
import { CONSENT_VERSION } from './chat.ts';

export interface SpendingDependencies {
  feature?: string;
  accountID: string;
  operationID: string;
  rpc(name: string, params: Record<string, unknown>): Promise<unknown>;
  sha256Hex(bytes: Uint8Array): Promise<string>;
  log?(entry: Record<string, string | number | boolean | null>): void;
}
type Route = 'chat' | 'chat_search' | 'ingest_lookup' | 'reference_lookup';
type Units = Record<string, number>;
type State = 'succeeded' | 'rejected' | 'unknown';
const encoder = new TextEncoder();

/** UUIDs are stable within an operation/route; replaying an admission never sends again. */
async function identity(deps: SpendingDependencies, route: Route, ordinal: number, request: unknown) {
  const id = await deps.sha256Hex(encoder.encode(JSON.stringify(['gradstep/provider-attempt/v1', deps.operationID, route, ordinal])));
  const requestSHA = await deps.sha256Hex(encoder.encode(JSON.stringify(['gradstep/provider-request/v1', deps.operationID, route, request])));
  return { id: `${id.slice(0, 8)}-${id.slice(8, 12)}-4${id.slice(13, 16)}-8${id.slice(17, 20)}-${id.slice(20, 32)}`,
    requestSHA: `\\x${requestSHA}` };
}

/** Whether the database granted this send; `reason` is its refusal (`operation_ceiling`: the request no longer fits the
 * operation's hold), null when granted or when the admission itself could not be read. `after`: a fallback's first request
 * names the attempt it follows, and the database carries that attempt's ceiling for Gradstep when it was silent
 * (migration 0163: `carried` µ$, or why the month could not take it). */
async function admission(deps: SpendingDependencies, attempt: Awaited<ReturnType<typeof identity>>, provider: string,
  route: Route, model: string, ceiling: number, units: Units, dispatch?: OpenRouterDispatch, after?: string)
  : Promise<{ granted: boolean; reason: string | null; dispatched: boolean; carried: number; carryRefused: string | null }> {
  const begin = { p_account_id: deps.accountID, p_operation_id: deps.operationID, p_attempt_id: attempt.id,
    p_route: route, p_model: model, p_request_sha256: attempt.requestSHA, p_ceiling_microusd: ceiling, p_reserved_units: units };
  try {
    // C6 (migration 0107): an OpenRouter request is admitted and dispatched in one transaction (one round trip).
    const result = (dispatch && after
      ? await deps.rpc('worker_openrouter_admit_fallback', { ...begin, p_metadata: dispatch, p_after_attempt_id: after })
      : dispatch
      ? await deps.rpc('worker_openrouter_admit', { ...begin, p_metadata: dispatch })
      : await deps.rpc('worker_provider_attempt_begin', { ...begin, p_provider: provider })) as
        { granted?: unknown; reason?: unknown; dispatched?: unknown; carried_microusd?: unknown; carry_refused?: unknown } | null;
    const code = (value: unknown) => typeof value === 'string' && /^[a-z_]{1,64}$/.test(value) ? value : null;
    return { granted: result?.granted === true, reason: typeof result?.reason === 'string' ? result.reason : null, dispatched: result?.dispatched === true,
      carried: Number.isSafeInteger(result?.carried_microusd) ? result!.carried_microusd as number : 0, carryRefused: code(result?.carry_refused) };
  } catch {
    // The transaction may have committed. Never retry into another send grant.
    deps.log?.({ event: 'provider_admission_unavailable', operation_id: deps.operationID, attempt_id: attempt.id, provider, route });
    return { granted: false, reason: null, dispatched: false, carried: 0, carryRefused: null };
  }
}
async function admit(deps: SpendingDependencies, attempt: Awaited<ReturnType<typeof identity>>, provider: string,
  route: Route, model: string, ceiling: number, units: Units): Promise<boolean> {
  return (await admission(deps, attempt, provider, route, model, ceiling, units)).granted;
}

async function finish(deps: SpendingDependencies, attemptID: string, state: State, requestID: string | null,
  microusd: number | null, units: Units, failure: string | null): Promise<boolean> {
  const params = { p_account_id: deps.accountID, p_operation_id: deps.operationID, p_attempt_id: attemptID,
    p_state: state, p_provider_request_id: providerRequestID(requestID), p_actual_microusd: microusd,
    p_actual_units: units, p_failure_code: failure };
  // Finish is idempotent for the same evidence. A retry may acknowledge an
  // already-committed result; it never repeats the provider request.
  for (let n = 0; n < 3; n++) {
    try { await deps.rpc('worker_provider_attempt_finish', params); return true; } catch { /* leave the grant reserved */ }
  }
  deps.log?.({ event: 'provider_result_unrecorded', operation_id: deps.operationID, attempt_id: attemptID, state });
  return false;
}

function unavailable(): ProviderOutcome {
  return { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null,
    refusalCategory: null, attempts: [], exact: true };
}

/** Each model round of a chat operation (the answer's rounds, its title, suggestions and Study map) has its own grant.
 * Every one goes to OpenRouter (provider `openrouter`, migration 089): admitted and dispatched in one transaction with
 * its attribution (account UUID, operation, attempt, feature), so per-account and per-feature spend is in our ledger
 * before the request leaves. A model without a reviewed OpenRouter route is never admitted. One ordinal sequence per
 * operation keeps every attempt's identity distinct. */
export function admittedModelCalls(deps: SpendingDependencies,
  generate: (params: ModelRequest, options: StreamOptions) => Promise<ProviderOutcome>) {
  let ordinal = 0;
  return async (params: ModelRequest, options: StreamOptions): Promise<ProviderOutcome> => {
    if (options.signal.aborted) return unavailable();
    // Our own function tools only: a provider-native (server-side) tool's cost cannot be bounded before the request.
    if ((params.tools ?? []).some(tool => !('input_schema' in tool))) return { ...unavailable(), cause: 'server' };
    const transport = openRouterTransportFor(params.model);
    if (!transport) return { ...unavailable(), cause: 'server' };
    const attempt = await identity(deps, 'chat', ++ordinal, params);
    // The requested model's own hold rule (chat profiles, the title's Haiku request), never a fixed Sonnet card.
    const ceiling = holdForParams(params).microusd;
    const feature = options.purpose ?? (params.tool_choice?.type === 'tool' ? params.tool_choice.name : deps.feature ?? 'chat');
    const dispatch = { ...transport, feature, caller: 'chat' };
    const granted = await admission(deps, attempt, 'openrouter', 'chat', params.model, ceiling,
      { output_tokens: params.max_tokens, web_searches: 0 }, dispatch, options.afterAttemptID);
    // What the fallback's admission did with the silent attempt it follows (migration 0163), for the caller's log.
    const carry = { ...(granted.carried > 0 ? { carriedMicrousd: granted.carried } : {}), ...(granted.carryRefused ? { carryRefused: granted.carryRefused } : {}) };
    const refused = { ...(granted.reason && /^[a-z_]{1,64}$/.test(granted.reason) ? { refusedBy: granted.reason } : {}), ...carry };
    // Not sent: our own bound when the round no longer fits the hold, else our server (a pause, capacity, a lost reply).
    // A lapsed price card (A4, migration 0101) is the model's unavailability, not a fault to retry.
    if (!granted.granted && granted.reason === 'tariff_expired') return { ...unavailable(), failure: 'provider_rejected', rejectionReason: 'tariff_expired', cause: 'server', ...refused };
    if (!granted.granted) return { ...unavailable(), cause: granted.reason === 'operation_ceiling' ? 'limit' : 'server', ...refused };
    let outcome: ProviderOutcome;
    try { outcome = await generate(params, { ...options, attribution: rpcAttribution(deps, attempt.id, feature, 'chat',
      granted.dispatched ? dispatch : undefined) }); }
    catch {
      await finish(deps, attempt.id, 'unknown', null, null, {}, 'transport_unknown');
      return { ...unavailable(), exact: false, cause: 'server', attemptID: attempt.id, ...carry };
    }
    const units: Units = outcome.attempts.reduce((sum, item) => ({
      input_tokens: sum.input_tokens + item.usage.input,
      cache_write_5m_tokens: sum.cache_write_5m_tokens + item.usage.cacheWrite5m,
      cache_write_1h_tokens: sum.cache_write_1h_tokens + item.usage.cacheWrite1h,
      cache_read_tokens: sum.cache_read_tokens + item.usage.cacheRead,
      output_tokens: sum.output_tokens + item.usage.output,
    }), { input_tokens: 0, cache_write_5m_tokens: 0, cache_write_1h_tokens: 0, cache_read_tokens: 0, output_tokens: 0 });
    const storage = outcome.attempts.reduce((sum, item) => sum + (item.cacheStorageTokens ?? 0), 0);
    if (storage) units.cache_storage_tokens = storage;
    const cost = Math.ceil(priceAttempts(outcome.attempts));
    const state: State = !outcome.exact ? 'unknown' : outcome.attempts.length ? 'succeeded' : 'rejected';
    // The receipt (still being written, C6) and the finish run together; the receipt never decides the outcome.
    // How soon the model's first output came (migration 0161: the model health signal's p90, Health and `models.health`).
    const firstData: Units = Number.isSafeInteger(outcome.firstDataMs) && outcome.firstDataMs! >= 0 ? { first_data_ms: Math.min(outcome.firstDataMs!, 3_600_000) } : {};
    const [recorded] = await Promise.all([finish(deps, attempt.id, state, outcome.requestID ?? outcome.messageID, state === 'unknown' ? null : cost,
      { ...units, web_searches: 0, attempts: outcome.attempts.length, ...firstData }, outcome.failure), outcome.receipt ?? Promise.resolve(true)]);
    // Stop here when the exact result could not be recorded, instead of sending
    // another round under headroom the database cannot know is available.
    const result: ProviderOutcome = recorded ? outcome : { ...outcome, status: 'failed', failure: 'provider_error', exact: false, cause: 'server' };
    return { ...result, attemptID: attempt.id, ...carry };
  };
}

/** One admitted prepaid search, shared by chat and both paper-finding paths. */
export function admittedTavily(deps: SpendingDependencies, route: Exclude<Route, 'chat'>,
  fetcher: typeof fetch, apiKey: string) {
  let ordinal = 0;
  return async (input: SearchInput, signal: AbortSignal): Promise<SearchOutcome> => {
    const failed: SearchOutcome = { status: 'failed', failure: 'unavailable', retryAfterMs: null };
    if (signal.aborted) return failed;
    const attempt = await identity(deps, route, ++ordinal, input);
    if (!await admit(deps, attempt, 'tavily', route, 'search-basic', 0, { credits: 1 })) return failed;
    const { billing, ...outcome } = await tavilySearch(fetcher, apiKey, input, signal);
    const recorded = await finish(deps, attempt.id, billing.state, billing.requestID,
      billing.state === 'unknown' ? null : 0,
      billing.credits === null ? {} : { credits: billing.credits, searches: outcome.status === 'ok' ? 1 : 0 }, billing.failureCode);
    return recorded ? outcome : failed;
  };
}

/** Free reference discovery has its own replay-fenced zero-credit operation.
 * The provider unit policy limits its platform-funded searches independently
 * of paid chat. Missing consent, pause and replay retain free catalog lookup. */
export async function referenceLookupSpending(deps: SpendingDependencies, input: {
  reference: string; web: boolean; consentVersion: unknown; enabled: boolean; apiKey?: string; fetcher: typeof fetch;
}) {
  const free = { search: undefined as ReturnType<typeof admittedTavily> | undefined, finish: async () => {} };
  if (!input.enabled || !input.apiKey || input.consentVersion !== CONSENT_VERSION) return free;
  const digest = await deps.sha256Hex(encoder.encode(JSON.stringify(['gradstep/reference-lookup/v1', deps.operationID, input.reference, input.web])));
  try {
    const reservation = await deps.rpc('worker_reserve_operation', { p_account_id: deps.accountID, p_id: deps.operationID, p_kind: 'metadata',
      p_request_sha256: `\\x${digest}`, p_rate_version: 'beta-credits-v1', p_credits: 0, p_microusd: 0 }) as { replayed?: boolean } | null;
    if (reservation?.replayed !== false) return free;
  } catch { return free; }
  return { search: admittedTavily(deps, 'reference_lookup', input.fetcher, input.apiKey), finish: async () => {
    // Dollar settlement is independent of outstanding prepaid units.
    for (let n = 0; n < 3; n++) {
      try { await deps.rpc('worker_settle_operation', { p_account_id: deps.accountID, p_id: deps.operationID, p_actual_credits: 0, p_actual_microusd: 0 }); return; }
      catch { /* exact settlement retry only; never repeat lookup */ }
    }
    deps.log?.({ event: 'reference_settlement_unrecorded', operation_id: deps.operationID });
  } };
}
