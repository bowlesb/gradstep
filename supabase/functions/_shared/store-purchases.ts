// Portable App Store purchase rules and normalized records. No runtime Apple SDK
// or X509 import: hosted Edge callers use a trusted StoreRecordVerifier transport.
// Verification and SQL recording are distinct; only the recorder changes money.
import { createHash, randomUUID } from 'node:crypto';
import type { JWSTransactionDecodedPayload, ResponseBodyV2DecodedPayload } from '@apple/app-store-server-library';

export type StoreEnvironment = 'Sandbox' | 'Production';
export interface StoreConfig {
  bundleID: string;
  /** Environments this deployment accepts (staging: Sandbox only). */
  environments: StoreEnvironment[];
  /** The App Store's numeric app ID; required to accept Production data. */
  appAppleID?: number;
  /** Certificate revocation (OCSP) checks and expiry against the current time. */
  onlineChecks: boolean;
}

export function storeConfig(env: (name: string) => string | undefined): StoreConfig | null {
  const bundleID = env('APP_STORE_BUNDLE_ID');
  const environments = (env('APP_STORE_ENVIRONMENTS') ?? '').split(',').map(s => s.trim()).filter(Boolean);
  if (!bundleID || !environments.length || environments.some(e => e !== 'Sandbox' && e !== 'Production')) return null;
  const appAppleID = env('APP_STORE_APP_APPLE_ID') ? Number(env('APP_STORE_APP_APPLE_ID')) : undefined;
  if (environments.includes('Production') && !(appAppleID && Number.isSafeInteger(appAppleID))) return null;
  const onlineChecks = env('APP_STORE_ONLINE_CHECKS') !== 'false';
  if (environments.includes('Production') && !onlineChecks) return null;
  return { bundleID, environments: environments as StoreEnvironment[], appAppleID, onlineChecks };
}

export interface StoreVerifier {
  transaction(signed: string): Promise<JWSTransactionDecodedPayload>;
  notification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload>;
}

/** `verification_unavailable`: Apple's revocation check could not be reached
 * (retry later); the others are permanent for that data. */
export type VerificationCode = 'invalid' | 'environment_unavailable' | 'verification_unavailable';
export type VerificationStage = 'input' | 'environment' | 'certificate_chain' | 'revocation' | 'signature_or_payload'
  | 'application' | 'transaction_fields' | 'recording' | 'admission' | 'deferred';
export type AppleVerificationStatus = 'verification_failure' | 'retryable_verification_failure' | 'invalid_app_identifier'
  | 'invalid_environment' | 'invalid_chain_length' | 'invalid_certificate' | 'failure';
export type VerificationTransportCode = 'timeout' | 'dns' | 'connection' | 'tls' | 'network' | 'runtime' | 'other';
export interface VerificationDiagnostic {
  stage: VerificationStage;
  apple_status?: AppleVerificationStatus;
  transport_code?: VerificationTransportCode;
}
export class StoreVerificationError extends Error {
  readonly code: VerificationCode;
  readonly diagnostic: VerificationDiagnostic;
  constructor(code: VerificationCode, diagnostic: VerificationDiagnostic = { stage: 'signature_or_payload' }) {
    super(code); this.code = code; this.diagnostic = diagnostic;
  }
}

/** Database errors that reject one transaction's data (not a service failure):
 * reported for that item only, so other purchases in the request still record. */
export const REJECTED_DATA = /invalid_store_transaction|store_transaction_conflict|invalid_store_notification/;

/** The verified fields migration 018 records (it re-validates every shape). */
export interface StoreTransactionRecord {
  environment: string;
  transaction_id: string;
  original_transaction_id: string;
  product_id: string;
  type: string;
  purchase_date: number;
  expires_date?: number;
  revocation_date?: number;
  signed_date: number;
  app_account_token?: string;
  quantity?: number;
  ownership?: string;
  /** PURCHASE or RENEWAL. */
  reason?: string;
  /** One per Apple Account per app (the Sandbox cap counts by it too). */
  app_transaction_id?: string;
}

export function transactionRecord(t: JWSTransactionDecodedPayload): StoreTransactionRecord | null {
  const millis = (v: unknown) => typeof v === 'number' && Number.isSafeInteger(v) && v > 0;
  if (typeof t.environment !== 'string' || typeof t.transactionId !== 'string' || typeof t.originalTransactionId !== 'string'
    || typeof t.productId !== 'string' || typeof t.type !== 'string' || !millis(t.purchaseDate) || !millis(t.signedDate)
    || (t.expiresDate !== undefined && !millis(t.expiresDate)) || (t.revocationDate !== undefined && !millis(t.revocationDate))) return null;
  return {
    environment: t.environment, transaction_id: t.transactionId, original_transaction_id: t.originalTransactionId,
    product_id: t.productId, type: t.type, purchase_date: t.purchaseDate!, signed_date: t.signedDate!,
    ...(t.expiresDate !== undefined ? { expires_date: t.expiresDate } : {}),
    ...(t.revocationDate !== undefined ? { revocation_date: t.revocationDate } : {}),
    ...(typeof t.appAccountToken === 'string' && t.appAccountToken ? { app_account_token: t.appAccountToken.toLowerCase() } : {}),
    ...(typeof t.quantity === 'number' ? { quantity: t.quantity } : {}),
    ...(typeof t.inAppOwnershipType === 'string' ? { ownership: t.inAppOwnershipType } : {}),
    ...(t.transactionReason === 'PURCHASE' || t.transactionReason === 'RENEWAL' ? { reason: t.transactionReason } : {}),
    ...(typeof t.appTransactionId === 'string' && /^[0-9]{1,32}$/.test(t.appTransactionId) ? { app_transaction_id: t.appTransactionId } : {}),
  };
}

export type SyncOutcome = 'recorded' | 'updated' | 'already_recorded' | 'linked_to_another_account' | 'account_closed'
  | 'unknown_product' | 'unsupported' | 'unattributed' | VerificationCode;
export interface SyncResult { transaction_id?: string; outcome: SyncOutcome; credits?: number; support_reference?: string; diagnostic?: VerificationDiagnostic }
/** Outcomes after which the app finishes the StoreKit transaction. */
export const FINAL_OUTCOMES: ReadonlySet<SyncOutcome> = new Set(['recorded', 'updated', 'already_recorded']);
export const MAX_SYNC_TRANSACTIONS = 25;

export type StoreRecordingCode = 'invalid_store_transaction' | 'store_transaction_conflict' | 'invalid_store_notification';
export interface StoreVerificationObservation extends VerificationDiagnostic {
  outcome: SyncOutcome | 'recording_unavailable' | 'unrecognized';
  recording_code?: StoreRecordingCode;
}

/** Finite SQL refusal categories only; the private database message stays local. */
export function storeRecordingCode(message: string): StoreRecordingCode | undefined {
  return message.match(REJECTED_DATA)?.[0] as StoreRecordingCode | undefined;
}

/** A closed output schema, even if a runtime dependency returns extra properties. */
export function storeVerificationObservation(outcome: unknown, value: unknown,
  recordingCode?: unknown): StoreVerificationObservation {
  const outcomes: ReadonlySet<string> = new Set(['recorded', 'updated', 'already_recorded', 'linked_to_another_account',
    'account_closed', 'unknown_product', 'unsupported', 'unattributed', 'invalid', 'environment_unavailable',
    'verification_unavailable', 'recording_unavailable']);
  const stages: ReadonlySet<string> = new Set(['input', 'environment', 'certificate_chain', 'revocation', 'signature_or_payload',
    'application', 'transaction_fields', 'recording', 'admission', 'deferred']);
  const transports: ReadonlySet<string> = new Set(['timeout', 'dns', 'connection', 'tls', 'network', 'runtime', 'other']);
  const diagnostic = (value && typeof value === 'object' ? value : {}) as Partial<VerificationDiagnostic>;
  const observation: StoreVerificationObservation = { outcome: typeof outcome === 'string' && outcomes.has(outcome) ? outcome as StoreVerificationObservation['outcome'] : 'unrecognized',
    stage: typeof diagnostic.stage === 'string' && stages.has(diagnostic.stage) ? diagnostic.stage : 'signature_or_payload' };
  if (diagnostic.apple_status && ['verification_failure', 'retryable_verification_failure', 'invalid_app_identifier', 'invalid_environment', 'invalid_chain_length', 'invalid_certificate', 'failure'].includes(diagnostic.apple_status)) observation.apple_status = diagnostic.apple_status;
  if (diagnostic.transport_code && transports.has(diagnostic.transport_code)) observation.transport_code = diagnostic.transport_code;
  if (typeof recordingCode === 'string' && ['invalid_store_transaction', 'store_transaction_conflict', 'invalid_store_notification'].includes(recordingCode)) observation.recording_code = recordingCode as StoreRecordingCode;
  return observation;
}

/** Identifies the actual runtime without echoing an arbitrary environment value. */
export function storeRuntimeDiagnostic(denoVersion: unknown) {
  return { release: 'purchase-diagnostics-v1', apple_library: '3.1.0',
    deno: typeof denoVersion === 'string' && /^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(denoVersion) ? denoVersion : 'unknown' };
}

export interface StoreNotificationRecord {
  environment: string;
  notification_uuid: string;
  type: string;
  subtype: string | null;
  signed_at: string;
  transaction: StoreTransactionRecord | null;
}

/** The trust boundary supplies verified, normalized records, never decoded JWS
 * lookalikes. A remote implementation must authenticate and validate its reply. */
export interface StoreRecordVerifier {
  transaction(signed: string): Promise<StoreTransactionRecord>;
  notification(signed: string): Promise<StoreNotificationRecord>;
}

function finiteVerificationError(error: unknown): StoreVerificationError {
  return error instanceof StoreVerificationError ? error : new StoreVerificationError('invalid');
}

/** The low-level Node adapter maps SDK errors before they cross this boundary. */
export async function verifyTransactionRecord(verifier: StoreVerifier, signed: string): Promise<StoreTransactionRecord> {
  let decoded: JWSTransactionDecodedPayload;
  try { decoded = await verifier.transaction(signed); }
  catch (error) { throw finiteVerificationError(error); }
  const record = transactionRecord(decoded);
  if (!record) throw new StoreVerificationError('invalid', { stage: 'transaction_fields' });
  return record;
}

/** Pure outer + inner verification, including environment agreement. It has no
 * recorder callback, database access or notification acknowledgement side effect. */
export async function verifyNotificationRecord(verifier: StoreVerifier, signed: string): Promise<StoreNotificationRecord> {
  let decoded: ResponseBodyV2DecodedPayload;
  try { decoded = await verifier.notification(signed); }
  catch (error) { throw finiteVerificationError(error); }
  const environment = decoded.data?.environment ?? decoded.summary?.environment;
  if (typeof decoded.notificationUUID !== 'string' || typeof decoded.notificationType !== 'string' || typeof environment !== 'string'
    || typeof decoded.signedDate !== 'number') throw new StoreVerificationError('invalid', { stage: 'transaction_fields' });
  const signedTransaction = decoded.data?.signedTransactionInfo;
  const transaction = typeof signedTransaction === 'string' ? await verifyTransactionRecord(verifier, signedTransaction) : null;
  if (transaction && transaction.environment !== environment) throw new StoreVerificationError('invalid', { stage: 'transaction_fields' });
  return { environment, notification_uuid: decoded.notificationUUID, type: decoded.notificationType,
    subtype: typeof decoded.subtype === 'string' ? decoded.subtype : null,
    signed_at: new Date(decoded.signedDate).toISOString(), transaction };
}

interface StoreRecorders {
  /** Content-free console observability; failure must never alter purchase processing. */
  observeVerification?(observation: StoreVerificationObservation): void;
  /** Durable per-account attempt records (migration 038), required together by the production store-sync
   * adapter; optional for standalone verification tests. Separate from 033's transport admission. */
  beginVerification?(accountID: string, attemptID: string, submissionSHA256: string): Promise<boolean>;
  finishVerification?(accountID: string, attemptID: string, outcome: SyncOutcome | 'recording_unavailable', diagnostic?: VerificationDiagnostic): Promise<void>;
  recordTransaction(accountID: string, record: StoreTransactionRecord): Promise<{ outcome: string; credits?: number; recordingCode?: StoreRecordingCode }>;
  recordNotification(input: StoreNotificationRecord): Promise<{ outcome: string; duplicate?: boolean }>;
}
export type StoreDeps = StoreRecorders & (
  { verifier: StoreVerifier; recordVerifier?: never } | { recordVerifier: StoreRecordVerifier; verifier?: never }
);

function recordVerifier(deps: StoreDeps): StoreRecordVerifier {
  if (Boolean(deps.verifier) === Boolean(deps.recordVerifier)) throw new Error('invalid_store_verifier_configuration');
  return deps.recordVerifier ?? {
    transaction: signed => verifyTransactionRecord(deps.verifier!, signed),
    notification: signed => verifyNotificationRecord(deps.verifier!, signed),
  };
}

/** Stable correlation for this account's exact submission, without exposing Apple identity. */
export function storeSubmissionReference(accountID: string, signed: string): string {
  return createHash('sha256').update('science-reader:store-verification:v1\0').update(accountID.toLowerCase()).update('\0').update(signed).digest('hex');
}

/** Records the caller's transactions (purchases from this device, renewals and
 * restores StoreKit reports). Database errors propagate (the app retries). */
export async function syncTransactions(deps: StoreDeps, accountID: string, body: unknown): Promise<SyncResult[]> {
  const verifier = recordVerifier(deps);
  const list = (body as { transactions?: unknown })?.transactions;
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_SYNC_TRANSACTIONS || list.some(s => typeof s !== 'string')) throw new Error('invalid_request');
  if (!!deps.beginVerification !== !!deps.finishVerification) throw new Error('verification_observation_configuration');
  // Durable begin/finish is mandatory in production; console observations
  // are separate and may never turn a confirmed database write into a failure.
  const observe = (outcome: string, diagnostic: VerificationDiagnostic, recordingCode?: StoreRecordingCode) => {
    try { deps.observeVerification?.(storeVerificationObservation(outcome, diagnostic, recordingCode)); } catch { /* observability is nonfinancial */ }
  };
  const results: SyncResult[] = [];
  let deferred = false;
  for (const signed of list as string[]) {
    const reference = storeSubmissionReference(accountID, signed);
    if (deferred) {
      results.push({ support_reference: reference, outcome: 'verification_unavailable', diagnostic: { stage: 'deferred' } }); continue;
    }
    const attemptID = randomUUID();
    if (deps.beginVerification && !await deps.beginVerification(accountID, attemptID, reference)) {
      results.push({ support_reference: reference, outcome: 'verification_unavailable', diagnostic: { stage: 'admission' } });
      deferred = true; continue;
    }
    const complete = async (result: SyncResult, recordingCode?: StoreRecordingCode) => {
      await deps.finishVerification?.(accountID, attemptID, result.outcome, result.diagnostic);
      observe(result.outcome, result.diagnostic ?? { stage: 'recording' }, recordingCode);
      results.push({ ...result, support_reference: reference });
      if (result.outcome === 'verification_unavailable') deferred = true;
    };
    let record: StoreTransactionRecord;
    try { record = await verifier.transaction(signed); }
    catch (error) {
      // Unexpected verifier/transport failures remain HTTP 503/unconfirmed; only
      // the verifier's finite refusals become a completed diagnostic attempt.
      if (!(error instanceof StoreVerificationError)) throw error;
      await complete({ outcome: error.code, diagnostic: error.diagnostic });
      continue;
    }
    let recorded: Awaited<ReturnType<StoreDeps['recordTransaction']>>;
    try { recorded = await deps.recordTransaction(accountID, record); }
    catch (error) {
      // Keep recorder errors outside the verifier catch: a shared error class
      // must not relabel a database outage or finish the same attempt twice.
      await deps.finishVerification?.(accountID, attemptID, 'recording_unavailable', { stage: 'recording' });
      observe('recording_unavailable', { stage: 'recording' });
      throw error;
    }
    await complete({ transaction_id: record.transaction_id, outcome: recorded.outcome as SyncOutcome,
      ...(typeof recorded.credits === 'number' ? { credits: recorded.credits } : {}),
      ...(!FINAL_OUTCOMES.has(recorded.outcome as SyncOutcome) ? { diagnostic: { stage: 'recording' as const } } : {}) }, recorded.recordingCode);
  }
  return results;
}

/** Acknowledges Apple only after recording. Verification outages return 503;
 * recorder errors propagate so the HTTP entrypoint also returns 503. */
export async function handleNotification(deps: StoreDeps, body: unknown): Promise<{ status: number; outcome: string; diagnostic?: VerificationDiagnostic }> {
  const verifier = recordVerifier(deps);
  const signedPayload = (body as { signedPayload?: unknown })?.signedPayload;
  if (typeof signedPayload !== 'string') return { status: 400, outcome: 'invalid' };
  let record: StoreNotificationRecord;
  try { record = await verifier.notification(signedPayload); }
  catch (error) {
    // Preserve the original normalizer's out-of-range-date failure behavior.
    if (error instanceof RangeError) throw error;
    const failure = finiteVerificationError(error);
    return { status: failure.code === 'verification_unavailable' ? 503 : 400, outcome: failure.code, diagnostic: failure.diagnostic };
  }
  const recorded = await deps.recordNotification(record);
  return { status: 200, outcome: recorded.outcome };
}
