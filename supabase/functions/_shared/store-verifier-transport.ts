// One durable start, one authenticated send. This adapter has no Apple SDK
// runtime dependency; it accepts only the bound normalized protocol reply.
import { createHash, randomBytes } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { type StoreConfig, type StoreRecordVerifier, StoreVerificationError } from './store-purchases.ts';
import { MAX_BODY_BYTES, parseReply, parseRequest, POLICY_ID, type VerificationRequest } from './store-verifier-protocol.ts';
import { storeVerifierAudience, type StoreGoogleIdentity } from './store-google-auth.ts';

export const STORE_REQUEST_BUDGET_MS = 115_000;
const SEND_BUDGET = { transaction: 50_000, notification: 80_000 } as const;
const MINIMUM_REMAINING = { transaction: 70_000, notification: 100_000 } as const;
const unavailable = () => new StoreVerificationError('verification_unavailable', { stage: 'signature_or_payload', transport_code: 'runtime' });

export function privateStorePolicy(config: StoreConfig | null): boolean {
  return config !== null && config.bundleID === 'com.sciencereader.ios' && config.onlineChecks === true
    && config.environments.length === 1 && config.environments[0] === 'Sandbox';
}

/** RFC9562 UUIDv7: timestamp plus cryptographically random bits. SQL validates
 * the encoded timestamp, so retention cannot re-arm an old request identity. */
export function storeVerificationAttemptID(now = Date.now()): string {
  if (!Number.isSafeInteger(now) || now < 0 || now > 0xffffffffffff) throw unavailable();
  const bytes = randomBytes(16);
  bytes.writeUIntBE(now, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** An ambiguous RPC outcome must end this operation, even if its underlying
 * response arrives later. Callers never attach a send continuation to it. */
export async function storeBoundedOperation<T>(operation: (signal: AbortSignal) => PromiseLike<T>, milliseconds: number,
  parent?: AbortSignal): Promise<T> {
  const controller = new AbortController();
  let rejectAborted!: (error: Error) => void;
  const cancelled = new Promise<never>((_, reject) => { rejectAborted = reject; });
  const abort = () => { controller.abort(); rejectAborted(unavailable()); };
  const timer = setTimeout(abort, milliseconds);
  parent?.addEventListener('abort', abort, { once: true });
  try {
    if (parent?.aborted) { abort(); await cancelled; }
    return await Promise.race([operation(controller.signal), cancelled]);
  } finally {
    clearTimeout(timer);
    parent?.removeEventListener('abort', abort);
  }
}

/** Used for /verify and the operator's receipt-free /health probe. Redirects
 * and automatic retries are never permitted, even for a rejected IAM token. */
export async function storePrivateJSON(audience: string, path: '/verify' | '/health', token: string,
  options: { body?: string; timeout: number; maximum: number; signal?: AbortSignal; fetch?: typeof fetch }): Promise<{ status: number; value: unknown }> {
  storeVerifierAudience(audience);
  if (typeof token !== 'string' || !token || token.length > 16_384) throw unavailable();
  return storeBoundedOperation(async signal => {
    const response = await (options.fetch ?? fetch)(audience + path, {
      method: options.body === undefined ? 'GET' : 'POST',
      headers: { authorization: `Bearer ${token}`, accept: 'application/json', ...(options.body === undefined ? {} : { 'content-type': 'application/json' }) },
      ...(options.body === undefined ? {} : { body: options.body }), redirect: 'error', signal,
    });
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel().catch(() => {});
      return { status: response.status, value: null };
    }
    if (response.status !== 200 && response.status !== 503 || !response.body
      || response.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json') {
      await response.body?.cancel().catch(() => {}); throw unavailable();
    }
    const length = response.headers.get('content-length');
    if (length !== null && (!/^\d+$/.test(length) || Number(length) > options.maximum)) {
      await response.body.cancel().catch(() => {}); throw unavailable();
    }
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    const cancel = () => { void reader.cancel().catch(() => {}); };
    signal.addEventListener('abort', cancel, { once: true });
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > options.maximum) throw unavailable();
        chunks.push(value);
      }
      if (signal.aborted) throw unavailable();
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      return { status: response.status, value };
    } catch { cancel(); throw unavailable(); }
    finally { signal.removeEventListener('abort', cancel); reader.releaseLock(); }
  }, options.timeout, options.signal);
}

export interface StoreStartInput {
  p_channel: 'app' | 'notification';
  p_account_id: string | null;
  p_attempt_id: string;
  p_payload_bytes: number;
  p_policy_id: typeof POLICY_ID;
}
export interface StoreTransportDependencies {
  identity: StoreGoogleIdentity;
  start(input: StoreStartInput, signal: AbortSignal): PromiseLike<unknown>;
  finish(input: { p_attempt_id: string; p_outcome: string; p_duration_ms: number }, signal: AbortSignal): PromiseLike<unknown>;
  fetch?: typeof fetch;
  now?: () => number;
  observationUnavailable?(): void;
}
function granted(value: unknown, attempt: string): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return Object.keys(v).length === 3 && v.granted === true && v.attempt_id === attempt && v.policy_id === POLICY_ID;
}

export function createStoreRecordTransport(config: { audience: string; channel: 'app' | 'notification'; accountID: string | null;
  deadline: number; signal?: AbortSignal }, deps: StoreTransportDependencies): StoreRecordVerifier {
  const audience = storeVerifierAudience(config.audience);
  if ((config.channel === 'app') !== (config.accountID !== null)
    || (config.accountID !== null && (config.accountID.length !== 36 || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(config.accountID)))
    || !Number.isFinite(config.deadline)) throw unavailable();
  const now = deps.now ?? Date.now;
  let admissionClosed = false;
  let busy = false;
  async function verify(kind: VerificationRequest['kind'], signed: string) {
    if (typeof signed !== 'string' || signed.length < 20 || signed.length > 64_000
      || /[^A-Za-z0-9_.-]/.test(signed)
      || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(signed)) {
      throw new StoreVerificationError('invalid', { stage: 'input' });
    }
    if (busy || admissionClosed || config.signal?.aborted || config.deadline - now() < MINIMUM_REMAINING[kind]
      || (kind === 'transaction') !== (config.channel === 'app')) throw unavailable();
    busy = true;
    let admitted = false;
    let attempt: VerificationRequest | undefined;
    const started = now();
    let outcome = 'verification_unavailable';
    try {
      attempt = parseRequest({ version: 1, attempt_id: storeVerificationAttemptID(started), kind, policy_id: POLICY_ID,
        signed_payload: signed, signed_sha256: createHash('sha256').update(signed, 'ascii').digest('hex') }) ?? undefined;
      if (!attempt) throw unavailable();
      const permission = await storeBoundedOperation(signal => deps.start({ p_channel: config.channel,
        p_account_id: config.accountID, p_attempt_id: attempt!.attempt_id, p_payload_bytes: Buffer.byteLength(signed, 'utf8'),
        p_policy_id: POLICY_ID }, signal), 5_000, config.signal);
      if (!granted(permission, attempt.attempt_id)) { admissionClosed = true; throw unavailable(); }
      admitted = true;
      const token = await storeBoundedOperation(() => deps.identity.token(), 8_500, config.signal);
      if (config.signal?.aborted || config.deadline - now() < SEND_BUDGET[kind] + 7_000) throw unavailable();
      const result = await storePrivateJSON(audience, '/verify', token, { body: JSON.stringify(attempt),
        timeout: SEND_BUDGET[kind], maximum: MAX_BODY_BYTES, signal: config.signal, fetch: deps.fetch });
      if (result.status === 401 || result.status === 403) { deps.identity.invalidate(); throw unavailable(); }
      const reply = parseReply(result.value, attempt);
      if (!reply || (result.status === 503) !== (reply.status === 'failed' && reply.code === 'verification_unavailable')) throw unavailable();
      if (reply.status === 'failed') {
        outcome = reply.code;
        throw new StoreVerificationError(reply.code, reply.diagnostic);
      }
      outcome = 'verified';
      return reply;
    } catch (error) {
      if (!admitted) admissionClosed = true;
      // No SDK/provider/database message, header, payload or cause escapes.
      throw error instanceof StoreVerificationError ? error : unavailable();
    } finally {
      if (admitted && attempt) {
        try {
          await storeBoundedOperation(signal => deps.finish({ p_attempt_id: attempt!.attempt_id, p_outcome: outcome,
            p_duration_ms: Math.min(120_000, Math.max(0, Math.floor(now() - started))) }, signal), 2_000);
        } catch { try { deps.observationUnavailable?.(); } catch { /* Nonfinancial observation. */ } }
      }
      busy = false;
    }
  }
  return {
    async transaction(signed) { const reply = await verify('transaction', signed); if (!('transaction' in reply)) throw unavailable(); return reply.transaction; },
    async notification(signed) { const reply = await verify('notification', signed); if (!('notification' in reply)) throw unavailable(); return reply.notification; },
  };
}
