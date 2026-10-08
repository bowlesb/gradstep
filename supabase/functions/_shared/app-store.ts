// App Store purchases: verification of signed transactions and server
// notifications with Apple's library (certificate chain to Apple Root CA - G3,
// bundle ID, environment), then recording through migration 018's functions.
// Every money effect happens in the database; this module only verifies and
// normalizes. See docs/architecture/PURCHASES.md.
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from '@apple/app-store-server-library';
import type { JWSTransactionDecodedPayload, ResponseBodyV2DecodedPayload } from '@apple/app-store-server-library';
import { Buffer } from 'node:buffer';
import { createHash, type KeyObject, X509Certificate } from 'node:crypto';

/** Apple Root CA - G3 (DER, base64), from https://www.apple.com/certificateauthority/. */
const APPLE_ROOT_CA_G3 = 'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQL'
  + 'DB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMw'
  + 'MTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRp'
  + 'ZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IA'
  + 'BJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqX'
  + 'l5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8w'
  + 'DgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWT'
  + 'xnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==';
/** Its published SHA-256 fingerprint; checked before use. */
export const APPLE_ROOT_CA_G3_SHA256 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';

export function appleRootCertificates(): Buffer[] {
  const der = Buffer.from(APPLE_ROOT_CA_G3, 'base64');
  if (createHash('sha256').update(der).digest('hex') !== APPLE_ROOT_CA_G3_SHA256) throw new Error('apple_root_mismatch');
  return [der];
}

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
  return { bundleID, environments: environments as StoreEnvironment[], appAppleID, onlineChecks: env('APP_STORE_ONLINE_CHECKS') !== 'false' };
}

export interface StoreVerifier {
  transaction(signed: string): Promise<JWSTransactionDecodedPayload>;
  notification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload>;
}

/** `verification_unavailable`: Apple's revocation check could not be reached
 * (retry later); the others are permanent for that data. */
export type VerificationCode = 'invalid' | 'environment_unavailable' | 'verification_unavailable';
export type VerificationStage = 'input' | 'environment' | 'certificate_chain' | 'revocation' | 'signature_or_payload'
  | 'application' | 'transaction_fields' | 'recording';
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

const APPLE_STATUSES: Readonly<Record<number, AppleVerificationStatus>> = {
  [VerificationStatus.VERIFICATION_FAILURE]: 'verification_failure',
  [VerificationStatus.RETRYABLE_VERIFICATION_FAILURE]: 'retryable_verification_failure',
  [VerificationStatus.INVALID_APP_IDENTIFIER]: 'invalid_app_identifier',
  [VerificationStatus.INVALID_ENVIRONMENT]: 'invalid_environment',
  [VerificationStatus.INVALID_CHAIN_LENGTH]: 'invalid_chain_length',
  [VerificationStatus.INVALID_CERTIFICATE]: 'invalid_certificate',
  [VerificationStatus.FAILURE]: 'failure',
};

/** Preserve the SDK's status and behavior while identifying the failed step.
 * Subclassing its protected methods changes no signature, chain or OCSP checks. */
class StageVerificationException extends VerificationException {
  readonly stage: VerificationStage;
  constructor(stage: VerificationStage, error: unknown) {
    const status = (error as Partial<VerificationException> | null)?.status;
    super(typeof status === 'number' && APPLE_STATUSES[status] ? status : VerificationStatus.VERIFICATION_FAILURE,
      error instanceof Error ? error : undefined);
    this.stage = error instanceof StageVerificationException ? error.stage : stage;
  }
}
class DiagnosticSignedDataVerifier extends SignedDataVerifier {
  protected override async verifyCertificateChain(roots: X509Certificate[], leaf: X509Certificate, intermediate: X509Certificate,
    effectiveDate: Date): Promise<KeyObject> {
    try { return await super.verifyCertificateChain(roots, leaf, intermediate, effectiveDate); }
    catch (error) { throw new StageVerificationException('certificate_chain', error); }
  }
  protected override async checkOCSPStatus(cert: X509Certificate, issuer: X509Certificate): Promise<void> {
    try { await super.checkOCSPStatus(cert, issuer); }
    catch (error) { throw new StageVerificationException('revocation', error); }
  }
}

/** Never serialize errors, messages, URLs, arbitrary codes or decoded claims. */
function transportCode(error: unknown): VerificationTransportCode | undefined {
  const seen = new Set<unknown>();
  let value = error;
  for (let i = 0; value && typeof value === 'object' && i < 8 && !seen.has(value); i++) {
    seen.add(value);
    const cause = value as { code?: unknown; type?: unknown; name?: unknown; cause?: unknown };
    if (['ETIMEDOUT', 'ESOCKETTIMEDOUT'].includes(typeof cause.code === 'string' ? cause.code : '') || ['request-timeout', 'body-timeout'].includes(typeof cause.type === 'string' ? cause.type : '')) return 'timeout';
    if (['ENOTFOUND', 'EAI_AGAIN'].includes(typeof cause.code === 'string' ? cause.code : '')) return 'dns';
    if (['ECONNREFUSED', 'ECONNRESET', 'EPIPE', 'ENETUNREACH', 'EHOSTUNREACH'].includes(typeof cause.code === 'string' ? cause.code : '')) return 'connection';
    if (['CERT_HAS_EXPIRED', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'ERR_TLS_CERT_ALTNAME_INVALID'].includes(typeof cause.code === 'string' ? cause.code : '')) return 'tls';
    if (['NotSupportedError', 'NotCapable'].includes(typeof cause.name === 'string' ? cause.name : '')
      || cause.code === 'ERR_NOT_IMPLEMENTED') return 'runtime';
    if (!cause.cause) return cause.name === 'FetchError' ? 'network' : i > 0 && !(value instanceof VerificationException) ? 'other' : undefined;
    value = cause.cause;
  }
  return undefined;
}
export function verificationError(error: unknown): StoreVerificationError {
  if (error instanceof StoreVerificationError) return error;
  // By status, not class: VerificationException may come from another copy of the library.
  const status = (error as Partial<VerificationException> | null)?.status;
  const appleStatus = typeof status === 'number' ? APPLE_STATUSES[status] : undefined;
  const stage = error instanceof StageVerificationException ? error.stage
    : status === VerificationStatus.INVALID_APP_IDENTIFIER ? 'application'
    : status === VerificationStatus.INVALID_ENVIRONMENT ? 'environment' : 'signature_or_payload';
  const transport = transportCode(error);
  return new StoreVerificationError(status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE ? 'verification_unavailable' : 'invalid',
    { stage, ...(appleStatus ? { apple_status: appleStatus } : {}), ...(transport ? { transport_code: transport } : {}) });
}

/** The environment a JWS claims, read before verification only to choose the
 * verifier; that verifier then checks it. */
export function claimedEnvironment(signed: string, notification: boolean): string | null {
  try {
    const part = signed.split('.')[1];
    if (!part || part.length > 64_000) return null;
    const body = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
    const value = notification ? body?.data?.environment ?? body?.summary?.environment : body?.environment;
    return typeof value === 'string' ? value : null;
  } catch { return null; }
}

export function appleVerifier(config: StoreConfig, roots: Buffer[] = appleRootCertificates()): StoreVerifier {
  const verifiers = new Map(config.environments.map(e => [e, new DiagnosticSignedDataVerifier(roots, config.onlineChecks,
    e === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX, config.bundleID, e === 'Production' ? config.appAppleID : undefined)]));
  const pick = (signed: string, notification: boolean) => {
    if (typeof signed !== 'string' || signed.length < 20 || signed.length > 64_000 || signed.split('.').length !== 3) throw new StoreVerificationError('invalid', { stage: 'input' });
    const claimed = claimedEnvironment(signed, notification);
    const verifier = claimed ? verifiers.get(claimed as StoreEnvironment) : undefined;
    if (!verifier) throw new StoreVerificationError(claimed ? 'environment_unavailable' : 'invalid', { stage: claimed ? 'environment' : 'input' });
    return verifier;
  };
  return {
    async transaction(signed) {
      try { return await pick(signed, false).verifyAndDecodeTransaction(signed); }
      catch (error) { throw verificationError(error); }
    },
    async notification(signedPayload) {
      try { return await pick(signedPayload, true).verifyAndDecodeNotification(signedPayload); }
      catch (error) { throw verificationError(error); }
    },
  };
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
export interface SyncResult { transaction_id?: string; outcome: SyncOutcome; credits?: number }
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
    'application', 'transaction_fields', 'recording']);
  const transports: ReadonlySet<string> = new Set(['timeout', 'dns', 'connection', 'tls', 'network', 'runtime', 'other']);
  const diagnostic = (value && typeof value === 'object' ? value : {}) as Partial<VerificationDiagnostic>;
  const observation: StoreVerificationObservation = { outcome: typeof outcome === 'string' && outcomes.has(outcome) ? outcome as StoreVerificationObservation['outcome'] : 'unrecognized',
    stage: typeof diagnostic.stage === 'string' && stages.has(diagnostic.stage) ? diagnostic.stage : 'signature_or_payload' };
  if (diagnostic.apple_status && Object.values(APPLE_STATUSES).includes(diagnostic.apple_status)) observation.apple_status = diagnostic.apple_status;
  if (diagnostic.transport_code && transports.has(diagnostic.transport_code)) observation.transport_code = diagnostic.transport_code;
  if (typeof recordingCode === 'string' && ['invalid_store_transaction', 'store_transaction_conflict', 'invalid_store_notification'].includes(recordingCode)) observation.recording_code = recordingCode as StoreRecordingCode;
  return observation;
}

/** Identifies the actual runtime without echoing an arbitrary environment value. */
export function storeRuntimeDiagnostic(denoVersion: unknown) {
  return { release: 'purchase-diagnostics-v1', apple_library: '3.1.0',
    deno: typeof denoVersion === 'string' && /^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(denoVersion) ? denoVersion : 'unknown' };
}

/** Once-per-isolate, zero-network probe of public-certificate primitives used by
 * Apple's SDK. Standalone Deno can support APIs absent from hosted Edge runtimes.
 * Nothing from a customer transaction is accepted or returned here. */
export function storeCryptoCapabilities(createCertificate: (der: Buffer) => X509Certificate = der => new X509Certificate(der)) {
  const capabilities = { certificate_parse: false, certificate_string: false, certificate_raw: false,
    public_key_export: false, certificate_verify: false, certificate_info_access: false };
  let root: X509Certificate;
  try { root = createCertificate(appleRootCertificates()[0]); capabilities.certificate_parse = true; }
  catch { return capabilities; }
  try { capabilities.certificate_string = typeof root.toString() === 'string'; } catch { /* fixed boolean only */ }
  try { capabilities.certificate_raw = Buffer.isBuffer(root.raw) && root.raw.length > 0; } catch { /* fixed boolean only */ }
  try { capabilities.public_key_export = typeof root.publicKey.export({ type: 'spki', format: 'pem' }) === 'string'; } catch { /* fixed boolean only */ }
  try { capabilities.certificate_verify = root.verify(root.publicKey); } catch { /* fixed boolean only */ }
  try { void root.infoAccess; capabilities.certificate_info_access = true; } catch { /* fixed boolean only */ }
  return capabilities;
}

export interface StoreDeps {
  /** Content-free observability only; it must never change the purchase outcome. */
  observeVerification?(observation: StoreVerificationObservation): void;
  verifier: StoreVerifier;
  recordTransaction(accountID: string, record: StoreTransactionRecord): Promise<{ outcome: string; credits?: number; recordingCode?: StoreRecordingCode }>;
  recordNotification(input: { environment: string; notification_uuid: string; type: string; subtype: string | null;
    signed_at: string; transaction: StoreTransactionRecord | null }): Promise<{ outcome: string; duplicate?: boolean }>;
}

/** Records the caller's transactions (purchases from this device, renewals and
 * restores StoreKit reports). Database errors propagate (the app retries). */
export async function syncTransactions(deps: StoreDeps, accountID: string, body: unknown): Promise<SyncResult[]> {
  const list = (body as { transactions?: unknown })?.transactions;
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_SYNC_TRANSACTIONS || list.some(s => typeof s !== 'string')) throw new Error('invalid_request');
  // A logging failure cannot prevent recording or change which purchases finish.
  const observe = (outcome: string, diagnostic: VerificationDiagnostic, recordingCode?: StoreRecordingCode) => {
    try { deps.observeVerification?.(storeVerificationObservation(outcome, diagnostic, recordingCode)); } catch { /* observability is nonfinancial */ }
  };
  const results: SyncResult[] = [];
  for (const signed of list as string[]) {
    let decoded: JWSTransactionDecodedPayload;
    try { decoded = await deps.verifier.transaction(signed); }
    catch (error) {
      const failure = verificationError(error);
      const outcome = error instanceof StoreVerificationError ? error.code : 'invalid';
      observe(outcome, failure.diagnostic);
      results.push({ outcome }); continue;
    }
    const record = transactionRecord(decoded);
    if (!record) { observe('invalid', { stage: 'transaction_fields' }); results.push({ outcome: 'invalid' }); continue; }
    let recorded: Awaited<ReturnType<StoreDeps['recordTransaction']>>;
    try { recorded = await deps.recordTransaction(accountID, record); }
    catch (error) { observe('recording_unavailable', { stage: 'recording' }); throw error; }
    observe(recorded.outcome, { stage: 'recording' }, recorded.recordingCode);
    results.push({ transaction_id: record.transaction_id, outcome: recorded.outcome as SyncOutcome,
      ...(typeof recorded.credits === 'number' ? { credits: recorded.credits } : {}) });
  }
  return results;
}

/** An App Store Server Notification V2. Returns the HTTP status for Apple:
 * 200 once recorded (or deliberately ignored), 503 when Apple's revocation
 * check is unreachable, 400 for data that does not verify. Database errors
 * propagate (503). Apple retries failed production notifications for a few
 * days; sandbox notifications are not retried, so the app's own reports and
 * the planned reconciliation are the backstop. */
export async function handleNotification(deps: StoreDeps, body: unknown): Promise<{ status: number; outcome: string }> {
  const signedPayload = (body as { signedPayload?: unknown })?.signedPayload;
  if (typeof signedPayload !== 'string') return { status: 400, outcome: 'invalid' };
  let decoded: ResponseBodyV2DecodedPayload;
  try { decoded = await deps.verifier.notification(signedPayload); }
  catch (error) {
    const code = error instanceof StoreVerificationError ? error.code : 'invalid';
    return { status: code === 'verification_unavailable' ? 503 : 400, outcome: code };
  }
  const environment = decoded.data?.environment ?? decoded.summary?.environment;
  if (typeof decoded.notificationUUID !== 'string' || typeof decoded.notificationType !== 'string' || typeof environment !== 'string'
    || typeof decoded.signedDate !== 'number') return { status: 400, outcome: 'invalid' };
  let transaction: StoreTransactionRecord | null = null;
  const signedTransaction = decoded.data?.signedTransactionInfo;
  if (typeof signedTransaction === 'string') {
    let inner: JWSTransactionDecodedPayload;
    try { inner = await deps.verifier.transaction(signedTransaction); }
    catch (error) {
      const code = error instanceof StoreVerificationError ? error.code : 'invalid';
      return { status: code === 'verification_unavailable' ? 503 : 400, outcome: code };
    }
    transaction = transactionRecord(inner);
    if (!transaction || transaction.environment !== environment) return { status: 400, outcome: 'invalid' };
  }
  const recorded = await deps.recordNotification({ environment, notification_uuid: decoded.notificationUUID,
    type: decoded.notificationType, subtype: typeof decoded.subtype === 'string' ? decoded.subtype : null,
    signed_at: new Date(decoded.signedDate).toISOString(), transaction });
  return { status: 200, outcome: recorded.outcome };
}
