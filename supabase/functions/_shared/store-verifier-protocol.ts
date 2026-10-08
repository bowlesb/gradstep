// Private, versioned protocol. Receipt content is never a log field.
import { createHash } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { storeVerificationObservation, type StoreNotificationRecord, type StoreTransactionRecord,
  type VerificationCode, type VerificationDiagnostic } from './store-purchases.ts';

export const POLICY_ID = 'app-store-sandbox-v1';
export const MAX_BODY_BYTES = 72 * 1024;
export const MAX_SIGNED_BYTES = 64_000;
export interface VerificationRequest {
  version: 1;
  attempt_id: string;
  kind: 'transaction' | 'notification';
  policy_id: typeof POLICY_ID;
  signed_payload: string;
  signed_sha256: string;
}
export type VerificationDecision =
  | { status: 'verified'; transaction: StoreTransactionRecord }
  | { status: 'verified'; notification: StoreNotificationRecord }
  | { status: 'failed'; code: VerificationCode; diagnostic: VerificationDiagnostic };
export type VerificationReply = Omit<VerificationRequest, 'signed_payload'> & VerificationDecision;

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function fields(value: Record<string, unknown>, required: string[], optional: string[] = []): boolean {
  const allowed = new Set([...required, ...optional]);
  return required.every(k => Object.hasOwn(value, k)) && Object.keys(value).every(k => allowed.has(k));
}
export function parseRequest(value: unknown): VerificationRequest | null {
  if (!object(value) || !fields(value, ['version', 'attempt_id', 'kind', 'policy_id', 'signed_payload', 'signed_sha256'])) return null;
  if (value.version !== 1 || value.policy_id !== POLICY_ID || (value.kind !== 'transaction' && value.kind !== 'notification')
    || typeof value.attempt_id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value.attempt_id)
    || typeof value.signed_sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(value.signed_sha256)
    || typeof value.signed_payload !== 'string' || value.signed_payload.length < 20 || value.signed_payload.length > MAX_SIGNED_BYTES
    || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value.signed_payload)) return null;
  if (createHash('sha256').update(value.signed_payload, 'ascii').digest('hex') !== value.signed_sha256) return null;
  return value as unknown as VerificationRequest;
}
function transaction(value: unknown): value is StoreTransactionRecord {
  if (!object(value) || !fields(value, ['environment', 'transaction_id', 'original_transaction_id', 'product_id', 'type', 'purchase_date', 'signed_date'],
    ['expires_date', 'revocation_date', 'app_account_token', 'quantity', 'ownership', 'reason', 'app_transaction_id'])) return false;
  if (value.environment !== 'Sandbox' || !['transaction_id', 'original_transaction_id', 'product_id', 'type'].every(k => typeof value[k] === 'string')) return false;
  for (const k of ['purchase_date', 'signed_date', 'expires_date', 'revocation_date']) {
    if (k in value && !(typeof value[k] === 'number' && Number.isSafeInteger(value[k]) && value[k] > 0)) return false;
  }
  if ('app_account_token' in value && !(typeof value.app_account_token === 'string' && value.app_account_token.length > 0 && value.app_account_token === value.app_account_token.toLowerCase())) return false;
  if ('ownership' in value && typeof value.ownership !== 'string') return false;
  if ('quantity' in value && !(typeof value.quantity === 'number' && Number.isFinite(value.quantity))) return false;
  if ('reason' in value && value.reason !== 'PURCHASE' && value.reason !== 'RENEWAL') return false;
  if ('app_transaction_id' in value && !(typeof value.app_transaction_id === 'string' && /^[0-9]{1,32}$/.test(value.app_transaction_id))) return false;
  return true;
}
function notification(value: unknown): value is StoreNotificationRecord {
  if (!object(value) || !fields(value, ['environment', 'notification_uuid', 'type', 'subtype', 'signed_at', 'transaction'])) return false;
  if (value.environment !== 'Sandbox' || typeof value.notification_uuid !== 'string' || typeof value.type !== 'string'
    || (value.subtype !== null && typeof value.subtype !== 'string') || typeof value.signed_at !== 'string') return false;
  const date = new Date(value.signed_at);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== value.signed_at) return false;
  return value.transaction === null || transaction(value.transaction);
}
export function isDecision(value: unknown, kind: VerificationRequest['kind']): value is VerificationDecision {
  if (!object(value)) return false;
  if (value.status === 'verified') return kind === 'transaction'
    ? fields(value, ['status', 'transaction']) && transaction(value.transaction)
    : fields(value, ['status', 'notification']) && notification(value.notification);
  if (value.status !== 'failed' || !fields(value, ['status', 'code', 'diagnostic'])
    || !['invalid', 'environment_unavailable', 'verification_unavailable'].includes(value.code as string)
    || !object(value.diagnostic) || !fields(value.diagnostic, ['stage'], ['apple_status', 'transport_code'])) return false;
  const { outcome: _outcome, ...safe } = storeVerificationObservation(value.code, value.diagnostic);
  return Object.keys(safe).length === Object.keys(value.diagnostic).length
    && Object.entries(safe).every(([key, val]) => value.diagnostic && (value.diagnostic as Record<string, unknown>)[key] === val);
}
export function unavailable(transport: 'timeout' | 'runtime' | 'other' = 'runtime'): VerificationDecision {
  return { status: 'failed', code: 'verification_unavailable', diagnostic: { stage: 'signature_or_payload', transport_code: transport } };
}
/** The parent owns bindings; an unexpected worker message never gets echoed. */
export function replyFor(request: VerificationRequest, candidate: unknown): { status: number; body: string } {
  const decision = isDecision(candidate, request.kind) ? candidate : unavailable();
  const { version, attempt_id, kind, policy_id, signed_sha256 } = request;
  const binding = { version, attempt_id, kind, policy_id, signed_sha256 };
  let body = JSON.stringify({ ...binding, ...decision });
  if (Buffer.byteLength(body) > MAX_BODY_BYTES) body = JSON.stringify({ ...binding, ...unavailable() });
  return { status: JSON.parse(body).code === 'verification_unavailable' ? 503 : 200, body };
}

/** Closed authenticated transport reply. The caller supplies the request it sent;
 * every binding must match before a normalized record can reach purchase SQL. */
export function parseReply(value: unknown, expected: VerificationRequest): VerificationReply | null {
  if (!object(value)) return null;
  const { version, attempt_id, kind, policy_id, signed_sha256, ...decision } = value;
  if (version !== expected.version || attempt_id !== expected.attempt_id || kind !== expected.kind
    || policy_id !== expected.policy_id || signed_sha256 !== expected.signed_sha256 || !isDecision(decision, expected.kind)) return null;
  return value as unknown as VerificationReply;
}
