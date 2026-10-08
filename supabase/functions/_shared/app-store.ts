// App Store purchases: verification of signed transactions and server
// notifications with Apple's library (certificate chain to Apple Root CA - G3,
// bundle ID, environment), then recording through migration 018's functions.
// Every money effect happens in the database; this module only verifies and
// normalizes. See docs/architecture/PURCHASES.md.
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from '@apple/app-store-server-library';
export * from './store-purchases.ts';
import { StoreVerificationError, type StoreConfig, type StoreVerifier, type StoreEnvironment,
  type VerificationStage, type AppleVerificationStatus, type VerificationTransportCode } from './store-purchases.ts';
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

