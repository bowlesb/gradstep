// Durable admission around one provider transport request. No prompts, queries,
// answers or raw errors are stored/logged; only domain-bound digests and counts.
import type Anthropic from '@anthropic-ai/sdk';
import { holdForParams, priceAttempts, WEB_SEARCH_MICROUSD, webSearchHoldMicrousd,
  type ProviderOutcome, type StreamOptions } from './anthropic.ts';
import { providerRequestID, tavilySearch, type SearchInput, type SearchOutcome } from './tavily.ts';
import { CONSENT_VERSION } from './chat.ts';

export interface SpendingDependencies {
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

async function admit(deps: SpendingDependencies, attempt: Awaited<ReturnType<typeof identity>>, provider: string,
  route: Route, model: string, ceiling: number, units: Units): Promise<boolean> {
  try {
    const result = await deps.rpc('worker_provider_attempt_begin', {
      p_account_id: deps.accountID, p_operation_id: deps.operationID, p_attempt_id: attempt.id,
      p_provider: provider, p_route: route, p_model: model, p_request_sha256: attempt.requestSHA,
      p_ceiling_microusd: ceiling, p_reserved_units: units,
    }) as { granted?: unknown } | null;
    return result?.granted === true;
  } catch {
    // The transaction may have committed. Never retry into another send grant.
    deps.log?.({ event: 'provider_admission_unavailable', operation_id: deps.operationID, attempt_id: attempt.id, provider, route });
    return false;
  }
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

/** Each model round, including pause_turn continuations, has its own grant. */
export function admittedAnthropic(deps: SpendingDependencies,
  generate: (params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: StreamOptions) => Promise<ProviderOutcome>) {
  let ordinal = 0;
  return async (params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: StreamOptions): Promise<ProviderOutcome> => {
    if (options.signal.aborted) return unavailable();
    const attempt = await identity(deps, 'chat', ++ordinal, params);
    const search = params.tools?.find(tool => 'name' in tool && tool.name === 'web_search') as { max_uses?: number } | undefined;
    const maxSearches = Math.max(0, search?.max_uses ?? 0);
    // web_search_20250305 has no enforceable result-token ceiling. The old
    // 30k estimate is not a hard cap. A policy flag alone cannot bypass the
    // missing context-bound quote: keep this route gated until implemented.
    if (search) return unavailable();
    // The requested model's own hold rule (chat profiles, the title's Haiku request), never a fixed Sonnet card.
    const hold = holdForParams(params);
    const ceiling = hold.microusd + (maxSearches ? webSearchHoldMicrousd(hold.inputTokens, maxSearches, params.model) : 0);
    if (!await admit(deps, attempt, 'anthropic', 'chat', params.model, ceiling,
      { output_tokens: params.max_tokens, web_searches: maxSearches })) return unavailable();
    let outcome: ProviderOutcome;
    try { outcome = await generate(params, options); }
    catch {
      await finish(deps, attempt.id, 'unknown', null, null, {}, 'transport_unknown');
      return { ...unavailable(), exact: false };
    }
    const units = outcome.attempts.reduce((sum, item) => ({
      input_tokens: sum.input_tokens + item.usage.input,
      cache_write_5m_tokens: sum.cache_write_5m_tokens + item.usage.cacheWrite5m,
      cache_write_1h_tokens: sum.cache_write_1h_tokens + item.usage.cacheWrite1h,
      cache_read_tokens: sum.cache_read_tokens + item.usage.cacheRead,
      output_tokens: sum.output_tokens + item.usage.output,
    }), { input_tokens: 0, cache_write_5m_tokens: 0, cache_write_1h_tokens: 0, cache_read_tokens: 0, output_tokens: 0 });
    const cost = Math.ceil(priceAttempts(outcome.attempts) + (outcome.webSearches ?? 0) * WEB_SEARCH_MICROUSD);
    const state: State = !outcome.exact ? 'unknown' : outcome.attempts.length ? 'succeeded' : 'rejected';
    const recorded = await finish(deps, attempt.id, state, outcome.requestID ?? outcome.messageID, state === 'unknown' ? null : cost,
      { ...units, web_searches: outcome.webSearches ?? 0, attempts: outcome.attempts.length }, outcome.failure);
    // Stop here when the exact result could not be recorded, instead of sending
    // another round under headroom the database cannot know is available.
    return recorded ? outcome : { ...outcome, status: 'failed', failure: 'provider_error', exact: false };
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
