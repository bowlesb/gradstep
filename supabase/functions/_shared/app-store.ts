// App Store purchases: verification of signed transactions and server
// notifications with Apple's library (certificate chain to Apple Root CA - G3,
// bundle ID, environment), then recording through migration 018's functions.
// Every money effect happens in the database; this module only verifies and
// normalizes. See docs/architecture/PURCHASES.md.
import { Environment, SignedDataVerifier, VerificationStatus } from '@apple/app-store-server-library';
import type { VerificationException } from '@apple/app-store-server-library';
import type { JWSTransactionDecodedPayload, ResponseBodyV2DecodedPayload } from '@apple/app-store-server-library';
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';

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
export class StoreVerificationError extends Error {
  readonly code: VerificationCode;
  constructor(code: VerificationCode) { super(code); this.code = code; }
}
export function verificationError(error: unknown): StoreVerificationError {
  if (error instanceof StoreVerificationError) return error;
  // By status, not class: VerificationException may come from another copy of the library.
  if ((error as Partial<VerificationException> | null)?.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
    return new StoreVerificationError('verification_unavailable');
  }
  return new StoreVerificationError('invalid');
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
  const verifiers = new Map(config.environments.map(e => [e, new SignedDataVerifier(roots, config.onlineChecks,
    e === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX, config.bundleID, e === 'Production' ? config.appAppleID : undefined)]));
  const pick = (signed: string, notification: boolean) => {
    if (typeof signed !== 'string' || signed.length < 20 || signed.length > 64_000 || signed.split('.').length !== 3) throw new StoreVerificationError('invalid');
    const claimed = claimedEnvironment(signed, notification);
    const verifier = claimed ? verifiers.get(claimed as StoreEnvironment) : undefined;
    if (!verifier) throw new StoreVerificationError(claimed ? 'environment_unavailable' : 'invalid');
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

export interface StoreDeps {
  verifier: StoreVerifier;
  recordTransaction(accountID: string, record: StoreTransactionRecord): Promise<{ outcome: string; credits?: number }>;
  recordNotification(input: { environment: string; notification_uuid: string; type: string; subtype: string | null;
    signed_at: string; transaction: StoreTransactionRecord | null }): Promise<{ outcome: string; duplicate?: boolean }>;
}

/** Records the caller's transactions (purchases from this device, renewals and
 * restores StoreKit reports). Database errors propagate (the app retries). */
export async function syncTransactions(deps: StoreDeps, accountID: string, body: unknown): Promise<SyncResult[]> {
  const list = (body as { transactions?: unknown })?.transactions;
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_SYNC_TRANSACTIONS || list.some(s => typeof s !== 'string')) throw new Error('invalid_request');
  const results: SyncResult[] = [];
  for (const signed of list as string[]) {
    let decoded: JWSTransactionDecodedPayload;
    try { decoded = await deps.verifier.transaction(signed); }
    catch (error) { results.push({ outcome: error instanceof StoreVerificationError ? error.code : 'invalid' }); continue; }
    const record = transactionRecord(decoded);
    if (!record) { results.push({ outcome: 'invalid' }); continue; }
    const recorded = await deps.recordTransaction(accountID, record);
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
