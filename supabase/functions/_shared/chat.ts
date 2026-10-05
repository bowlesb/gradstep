// Paid chat orchestration: validation, context, hold -> provider -> settle.
// Deno and Node compatible (no Deno globals). Never log request or answer
// text; logs carry only operation IDs, codes and counts.
import {
  CHAT_MAX_TOKENS, chatRequestParams, creditsFor, holdFor, priceAttempts, promptCharacters, RATE_VERSION,
  type ChatTurn, type PaperContext, type ProviderOutcome, type StreamOptions,
} from './anthropic.ts';
import type Anthropic from '@anthropic-ai/sdk';

export const CONSENT_VERSION = 'cloud-ai-v1';
export const MAX_BODY_BYTES = 512 * 1024;
export const MAX_TURNS = 60;
export const MAX_MESSAGE_BYTES = 200_000;
export const MAX_SELECTION_SCALARS = 4_000;
export const MAX_PAPER_BYTES = 2 * 1024 * 1024;
export const GENERATION_DEADLINE_MS = 130_000;

export type ChatErrorCode = 'insufficient_credits' | 'platform_budget_exhausted' | 'rate_limited' | 'document_unavailable'
  | 'provider_unavailable' | 'refused' | 'invalid_request' | 'operation_replayed' | 'service_unavailable';

export class ChatFailure extends Error {
  readonly code: ChatErrorCode;
  constructor(code: ChatErrorCode) { super(code); this.code = code; }
}
/** A database exception message (RAISE text) from PostgREST. */
export class RpcFailure extends Error {
  readonly reason: string;
  constructor(reason: string) { super('rpc_failed'); this.reason = reason; }
}

export interface ChatRequest {
  operationID: string;
  mode: 'paper' | 'general';
  documentID: string | null;
  turns: ChatTurn[];
  selection: string | null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
function invalid(): never { throw new ChatFailure('invalid_request'); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function onlyKeys(value: Record<string, unknown>, allowed: readonly string[]) {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) invalid();
}
function id(value: unknown): string {
  if (typeof value !== 'string' || !UUID.test(value)) invalid();
  return value.toLowerCase();
}

/** Strict, bounded validation. Unknown fields are rejected, not ignored. */
export function validateChatRequest(input: unknown): ChatRequest {
  const body = record(input);
  onlyKeys(body, ['operation_id', 'consent_version', 'mode', 'document_id', 'messages', 'selection']);
  if (body.consent_version !== CONSENT_VERSION) invalid();
  const mode = body.mode;
  if (mode !== 'paper' && mode !== 'general') invalid();
  const operationID = id(body.operation_id);
  let documentID: string | null = null;
  if (mode === 'paper') documentID = id(body.document_id);
  else if (body.document_id !== undefined && body.document_id !== null) invalid();
  if (!Array.isArray(body.messages) || body.messages.length < 1 || body.messages.length > MAX_TURNS) invalid();
  let bytes = 0;
  const turns = body.messages.map(raw => {
    const turn = record(raw);
    onlyKeys(turn, ['role', 'text']);
    if (turn.role !== 'user' && turn.role !== 'assistant') invalid();
    if (typeof turn.text !== 'string' || !turn.text.trim()) invalid();
    bytes += encoder.encode(turn.text).length;
    if (bytes > MAX_MESSAGE_BYTES) invalid();
    return { role: turn.role, text: turn.text } as ChatTurn;
  });
  if (turns[0].role !== 'user' || turns[turns.length - 1].role !== 'user') invalid();
  let selection: string | null = null;
  if (body.selection !== undefined && body.selection !== null) {
    const value = record(body.selection);
    onlyKeys(value, ['quote']);
    if (typeof value.quote !== 'string' || !value.quote.trim() || [...value.quote].length > MAX_SELECTION_SCALARS) invalid();
    selection = value.quote;
  }
  return { operationID, mode, documentID, turns, selection };
}

/** Fixed key order: the reservation's request digest. */
export function canonicalRequest(request: ChatRequest): string {
  return JSON.stringify({
    consent_version: CONSENT_VERSION, document_id: request.documentID,
    messages: request.turns.map(turn => ({ role: turn.role, text: turn.text })),
    mode: request.mode, operation_id: request.operationID,
    selection: request.selection === null ? null : { quote: request.selection },
  });
}

export async function readChatBody(request: Request, maximum = MAX_BODY_BYTES, timeoutMs = 20_000): Promise<unknown> {
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) invalid();
  if (!request.body) invalid();
  const reader = request.body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { void reader.cancel(); reject(new ChatFailure('invalid_request')); }, timeoutMs);
  });
  try {
    const parts: Uint8Array[] = []; let length = 0;
    while (true) {
      const { done, value } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      length += value.byteLength;
      if (length > maximum) { void reader.cancel(); invalid(); }
      parts.push(value);
    }
    const joined = new Uint8Array(length); let offset = 0;
    for (const part of parts) { joined.set(part, offset); offset += part.byteLength; }
    try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(joined)); }
    catch { return invalid(); }
  } finally { if (timer) clearTimeout(timer); reader.releaseLock(); }
}

const BASE_INSTRUCTIONS = `You are the research assistant in Science Reader, an app people use to read machine-learning papers.
Lead with the answer, then the reasoning that supports it. Keep answers focused; use short Markdown sections or lists when they help.
Write mathematics in LaTeX with \\( ... \\) for inline math and \\[ ... \\] for display math. Do not use dollar-sign delimiters.
If you are unsure or something is outside what you can verify, say so plainly. Never invent citations, results, or paper details.`;
const PAPER_INSTRUCTIONS = `The reader is asking about the paper in the <paper> block (Mathpix Markdown of the full text).
Ground answers in the paper and point to where support comes from, such as "Section 3.2", "Eq. (4)", "Table 2" or "Figure 1". When the paper does not settle a question, say so and keep outside knowledge clearly separate from what the paper states.
A <selected_passage> block, when present, is the text the reader highlighted for this question.`;
const GENERAL_INSTRUCTIONS = `This is a general research conversation that is not tied to a specific paper. A <selected_passage> block, when present, is text the reader highlighted.`;

export function chatInstructions(mode: 'paper' | 'general'): string {
  return `${BASE_INSTRUCTIONS}\n\n${mode === 'paper' ? PAPER_INSTRUCTIONS : GENERAL_INSTRUCTIONS}`;
}

export type ChatEvent = { event: 'delta'; data: { text: string } }
  | { event: 'done'; data: { stop_reason: string; credits: number; usage: Record<string, number> } }
  | { event: 'error'; data: { code: ChatErrorCode } };

export function sseFrame(message: ChatEvent): string {
  return `event: ${message.event}\ndata: ${JSON.stringify(message.data)}\n\n`;
}

export type LogEntry = Record<string, string | number | boolean | null>;
export interface ChatDependencies {
  accountID: string;
  rpc(name: string, params: Record<string, unknown>): Promise<unknown>;
  /** Returns the stored object bytes, or null when it is missing. */
  loadPaper(bucket: string, path: string): Promise<Uint8Array | null>;
  /** Null when the provider is not configured in this environment. */
  generate: ((params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: StreamOptions) => Promise<ProviderOutcome>) | null;
  sha256Hex(bytes: Uint8Array): Promise<string>;
  log(entry: LogEntry): void;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  deadlineMs?: number;
}

const RESERVE_ERRORS: Record<string, ChatErrorCode> = {
  insufficient_credits: 'insufficient_credits', platform_budget_exhausted: 'platform_budget_exhausted',
  too_many_active_operations: 'rate_limited', operation_id_conflict: 'invalid_request',
  account_unavailable: 'service_unavailable', invalid_reservation: 'invalid_request',
};
function reason(error: unknown): string { return error instanceof RpcFailure ? error.reason : 'transport'; }

/**
 * Run one chat turn and emit SSE events. Resolves after settlement; never
 * rejects for ordinary failures (they become an `error` event).
 */
export async function runChat(deps: ChatDependencies, body: unknown, emit: (event: ChatEvent) => void, signal: AbortSignal): Promise<void> {
  try {
    await runChecked(deps, body, emit, signal);
  } catch (error) {
    const code = error instanceof ChatFailure ? error.code : 'service_unavailable';
    if (!(error instanceof ChatFailure)) deps.log({ event: 'chat_unexpected_failure' });
    if (!signal.aborted) emit({ event: 'error', data: { code } });
  }
}

async function runChecked(deps: ChatDependencies, body: unknown, emit: (event: ChatEvent) => void, signal: AbortSignal) {
  try { await deps.rpc('worker_consume_request', { p_account_id: deps.accountID, p_route: 'chat' }); }
  catch (error) { throw new ChatFailure(reason(error) === 'request_rate_limit' ? 'rate_limited' : 'service_unavailable'); }
  const request = validateChatRequest(body);

  let paper: PaperContext | null = null;
  if (request.mode === 'paper') {
    let context: { bucket?: unknown; path?: unknown; title?: unknown };
    try { context = await deps.rpc('worker_chat_context', { p_account_id: deps.accountID, p_document_id: request.documentID }) as typeof context; }
    catch (error) { throw new ChatFailure(reason(error) === 'document_unavailable' ? 'document_unavailable' : 'service_unavailable'); }
    if (!context || typeof context.bucket !== 'string' || typeof context.path !== 'string') throw new ChatFailure('document_unavailable');
    const bytes = await deps.loadPaper(context.bucket, context.path);
    if (!bytes || !bytes.length || bytes.length > MAX_PAPER_BYTES) throw new ChatFailure('document_unavailable');
    let text: string;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { throw new ChatFailure('document_unavailable'); }
    paper = { title: typeof context.title === 'string' ? context.title : null, text };
  }
  if (!deps.generate) throw new ChatFailure('provider_unavailable');
  const params = chatRequestParams({ instructions: chatInstructions(request.mode), paper, turns: request.turns, selection: request.selection });
  const hold = holdFor(promptCharacters(params), CHAT_MAX_TOKENS);
  const digest = await deps.sha256Hex(encoder.encode(canonicalRequest(request)));
  if (signal.aborted) return;

  let reservation: { replayed?: unknown; state?: unknown };
  try {
    reservation = await deps.rpc('worker_reserve_operation', {
      p_account_id: deps.accountID, p_id: request.operationID, p_kind: 'chat', p_request_sha256: `\\x${digest}`,
      p_rate_version: RATE_VERSION, p_credits: hold.credits, p_microusd: hold.microusd,
    }) as typeof reservation;
  } catch (error) {
    const code = RESERVE_ERRORS[reason(error)];
    // An ambiguous transport failure may have committed the hold; leave it
    // for reconciliation instead of guessing which invocation owns it.
    if (!code) deps.log({ event: 'chat_reserve_uncertain', operation_id: request.operationID });
    throw new ChatFailure(code ?? 'service_unavailable');
  }
  if (!reservation || reservation.replayed !== false) throw new ChatFailure('operation_replayed');

  // From here the hold exists: settle exactly once on every path.
  const now = deps.now ?? Date.now;
  const deadline = new AbortController();
  const timer = setTimeout(() => deadline.abort(), deps.deadlineMs ?? GENERATION_DEADLINE_MS);
  const stop = () => deadline.abort();
  signal.addEventListener('abort', stop, { once: true });
  let outcome: ProviderOutcome;
  try {
    outcome = await deps.generate(params, {
      signal: deadline.signal, inputEstimateTokens: hold.inputTokens, now,
      onText: text => { if (!signal.aborted && text) emit({ event: 'delta', data: { text } }); },
    });
  } catch {
    outcome = { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null, refusalCategory: null,
      attempts: [{ model: null, estimated: true, usage: { input: hold.inputTokens, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }], exact: false };
  } finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', stop);
  }

  const actual = Math.ceil(priceAttempts(outcome.attempts));
  // The customer is never charged above the hold, but the platform budget
  // records the true provider cost: an overrun freezes new paid work.
  const credits = Math.min(creditsFor(actual), hold.credits);
  if (actual > hold.microusd) deps.log({ event: 'chat_usage_exceeded_hold', operation_id: request.operationID, actual_microusd: actual, hold_microusd: hold.microusd });
  await settle(deps, request.operationID, credits, actual);
  await recordUsage(deps, request.operationID, outcome, actual);

  if (signal.aborted) return;
  if (outcome.status === 'complete') {
    if (outcome.stopReason === 'refusal') { emit({ event: 'error', data: { code: 'refused' } }); return; }
    const usage = outcome.attempts.reduce((sum, attempt) => ({
      input_tokens: sum.input_tokens + attempt.usage.input,
      cache_creation_input_tokens: sum.cache_creation_input_tokens + attempt.usage.cacheWrite5m + attempt.usage.cacheWrite1h,
      cache_read_input_tokens: sum.cache_read_input_tokens + attempt.usage.cacheRead,
      output_tokens: sum.output_tokens + attempt.usage.output,
    }), { input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0 });
    emit({ event: 'done', data: { stop_reason: outcome.stopReason ?? 'end_turn', credits, usage } });
    return;
  }
  emit({ event: 'error', data: { code: 'provider_unavailable' } });
}

async function settle(deps: ChatDependencies, operationID: string, credits: number, microusd: number) {
  const sleep = deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms)));
  // Settlement is idempotent for identical amounts, so a lost acknowledgement
  // may be retried. It is never repeated with different amounts.
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await deps.rpc('worker_settle_operation', { p_account_id: deps.accountID, p_id: operationID, p_actual_credits: credits, p_actual_microusd: microusd });
      return;
    } catch (error) {
      const failure = reason(error);
      if (failure !== 'transport' || attempt === 3) {
        deps.log({ event: 'chat_settle_failed', operation_id: operationID, reason: failure === 'transport' ? 'transport' : 'rejected' });
        return;
      }
      await sleep(250 * attempt);
    }
  }
}

async function recordUsage(deps: ChatDependencies, operationID: string, outcome: ProviderOutcome, microusd: number) {
  if (!outcome.attempts.length) return;
  const units = {
    estimated: !outcome.exact, stop_reason: outcome.stopReason, refusal_category: outcome.refusalCategory, failure: outcome.failure,
    attempts: outcome.attempts.map(attempt => ({ model: attempt.model, estimated: attempt.estimated, input_tokens: attempt.usage.input,
      cache_write_5m_tokens: attempt.usage.cacheWrite5m, cache_write_1h_tokens: attempt.usage.cacheWrite1h,
      cache_read_tokens: attempt.usage.cacheRead, output_tokens: attempt.usage.output })),
  };
  try {
    await deps.rpc('worker_record_provider_usage', {
      p_account_id: deps.accountID, p_operation_id: operationID, p_provider: 'anthropic',
      p_provider_event_id: outcome.messageID ?? `operation:${operationID}`,
      p_model: outcome.model ?? outcome.attempts[0].model ?? 'unknown', p_units: units, p_microusd: microusd,
    });
  } catch { deps.log({ event: 'chat_usage_record_failed', operation_id: operationID }); }
}
