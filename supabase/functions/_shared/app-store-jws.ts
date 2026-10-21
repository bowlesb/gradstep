// App Store Server Notification authentication before any admission (review A8, 2026-10-21;
// docs/architecture/PURCHASE_VERIFICATION_RUNTIME.md "Notification authentication before admission").
//
// The public notification URL consumed the global notification quota (migration 033) before the private verifier
// checked Apple's signature, so anyone could post JWS-shaped junk and exhaust it. This module checks, in the Edge
// function and before the database is touched, what Apple's library checks on the outer JWS: ES256, an x5c chain of
// exactly three certificates whose root is byte-identical to the pinned Apple Root CA - G3, the intermediate signed by
// that root and marked as Apple's WWDR intermediate (1.2.840.113635.100.6.2.1, a CA), the leaf signed by the
// intermediate and marked as App Store receipt signing (1.2.840.113635.100.6.11.1), every certificate valid now within
// 60 s, the JWS signature under the leaf key, and the payload naming our bundle and an allowed environment. It decides
// only whether a request may consume admission; the private verifier still runs Apple's SDK with OCSP, the inner
// transaction and every financial rule. Nothing here authorizes a purchase.
//
// WebCrypto ECDSA and a minimal bounded DER reader only: no Apple SDK and no node:crypto X509Certificate (its verify,
// raw and toString are unavailable in the hosted Edge runtime). No JWS, certificate or claim is logged or returned.

/** Apple Root CA - G3 (DER, base64), from https://www.apple.com/certificateauthority/; the same bytes as app-store.ts
 * (the private verifier's root; tests assert they are identical). Checked against its published SHA-256 before use. */
const APPLE_ROOT_CA_G3 = 'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQL'
  + 'DB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMw'
  + 'MTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRp'
  + 'ZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IA'
  + 'BJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqX'
  + 'l5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8w'
  + 'DgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWT'
  + 'xnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==';
export const APPLE_ROOT_CA_G3_SHA256 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';

const MAX_SIGNED = 64_000;
const MAX_CERTIFICATE_BASE64 = 12_000;
const MAX_SKEW_MS = 60_000;
const LEAF_MARKER = '1.2.840.113635.100.6.11.1';
const INTERMEDIATE_MARKER = '1.2.840.113635.100.6.2.1';
const BASIC_CONSTRAINTS = '2.5.29.19';
const HASHES: Record<string, 'SHA-256' | 'SHA-384'> = { '1.2.840.10045.4.3.2': 'SHA-256', '1.2.840.10045.4.3.3': 'SHA-384' };
const CURVES: Record<string, 'P-256' | 'P-384'> = { '1.2.840.10045.3.1.7': 'P-256', '1.3.132.0.34': 'P-384' };
const EC_PUBLIC_KEY = '1.2.840.10045.2.1';

/** Why a notification was refused before admission (fixed codes; safe to log). */
export type NotificationAuthFailure = 'framing' | 'header' | 'chain_length' | 'root' | 'certificate' | 'chain' | 'marker' | 'validity'
  | 'signature' | 'claims';
export type NotificationAuthResult = { ok: true } | { ok: false; failure: NotificationAuthFailure };
export interface NotificationAuthPolicy { bundleID: string; environments: readonly string[] }

class Refused extends Error {
  readonly failure: NotificationAuthFailure;
  constructor(failure: NotificationAuthFailure) { super(failure); this.failure = failure; }
}
function refuse(failure: NotificationAuthFailure): never { throw new Refused(failure); }

/** A copy backed by its own ArrayBuffer (WebCrypto's BufferSource). */
const owned = (bytes: Uint8Array): Uint8Array<ArrayBuffer> => new Uint8Array(bytes);
const equal = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((value, index) => value === b[index]);

function base64(text: string, url: boolean): Uint8Array {
  if (!(url ? /^[A-Za-z0-9_-]*$/ : /^[A-Za-z0-9+/]*={0,2}$/).test(text)) throw new Error('base64');
  // Forgiving base64 (atob) accepts the unpadded base64url of JOSE once its alphabet is mapped.
  const binary = atob(url ? text.replaceAll('-', '+').replaceAll('_', '/') : text);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

// ---------------------------------------------------------------------------
// A minimal DER reader: single-byte tags, definite lengths up to 3 bytes, bounded children.
// ---------------------------------------------------------------------------
interface Node { tag: number; start: number; body: number; end: number }
function node(bytes: Uint8Array, at: number, limit: number): Node {
  if (at + 2 > limit) throw new Error('der');
  const tag = bytes[at];
  if ((tag & 0x1f) === 0x1f) throw new Error('der');
  let length = bytes[at + 1], body = at + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 3 || body + count > limit) throw new Error('der');
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[body + i];
    body += count;
  }
  if (body + length > limit) throw new Error('der');
  return { tag, start: at, body, end: body + length };
}
function children(bytes: Uint8Array, parent: Node): Node[] {
  const out: Node[] = [];
  for (let at = parent.body; at < parent.end;) {
    const child = node(bytes, at, parent.end);
    out.push(child); at = child.end;
    if (out.length > 64) throw new Error('der');
  }
  return out;
}
function expect(value: Node | undefined, tag: number): Node {
  if (!value || value.tag !== tag) throw new Error('der');
  return value;
}
function oid(bytes: Uint8Array, value: Node | undefined): string {
  const field = expect(value, 0x06), raw = bytes.subarray(field.body, field.end);
  if (!raw.length || raw.length > 64 || raw[raw.length - 1] & 0x80) throw new Error('der');
  const parts: number[] = [];
  let current = 0;
  for (const byte of raw) {
    current = current * 128 + (byte & 0x7f);
    if (current > 2 ** 40) throw new Error('der');
    if (!(byte & 0x80)) { parts.push(current); current = 0; }
  }
  const first = parts.shift()!, arc = first < 40 ? 0 : first < 80 ? 1 : 2;
  return [arc, first - arc * 40, ...parts].join('.');
}
function time(bytes: Uint8Array, value: Node | undefined): number {
  if (!value || (value.tag !== 0x17 && value.tag !== 0x18)) throw new Error('der');
  const text = String.fromCharCode(...bytes.subarray(value.body, value.end));
  const match = value.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text) : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
  if (!match) throw new Error('der');
  const year = value.tag === 0x17 ? (Number(match[1]) >= 50 ? 1900 : 2000) + Number(match[1]) : Number(match[1]);
  return Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
}

/** The parts of an X.509 certificate this check needs (RFC 5280). */
export interface Certificate {
  tbs: Uint8Array; hash: 'SHA-256' | 'SHA-384'; signature: Uint8Array; issuer: Uint8Array; subject: Uint8Array;
  notBefore: number; notAfter: number; spki: Uint8Array; curve: 'P-256' | 'P-384'; ca: boolean; extensions: Set<string>;
}
export function parseCertificate(der: Uint8Array): Certificate {
  const top = expect(node(der, 0, der.length), 0x30);
  if (top.end !== der.length) throw new Error('der');
  const [tbsNode, algorithm, signatureBits, ...rest] = children(der, top);
  if (rest.length) throw new Error('der');
  expect(tbsNode, 0x30); expect(algorithm, 0x30);
  const hash = HASHES[oid(der, children(der, algorithm)[0])] ?? (() => { throw new Error('der'); })();
  const bits = expect(signatureBits, 0x03);
  if (der[bits.body] !== 0) throw new Error('der');
  const fields = children(der, tbsNode);
  let i = 0;
  if (fields[i]?.tag === 0xa0) i++;
  expect(fields[i++], 0x02);
  const inner = expect(fields[i++], 0x30);
  if (oid(der, children(der, inner)[0]) !== oid(der, children(der, algorithm)[0])) throw new Error('der');
  const issuer = expect(fields[i++], 0x30), validity = children(der, expect(fields[i++], 0x30));
  const subject = expect(fields[i++], 0x30), spki = expect(fields[i++], 0x30);
  const [keyAlgorithm, keyBits] = children(der, spki);
  const keyParts = children(der, expect(keyAlgorithm, 0x30));
  expect(keyBits, 0x03);
  if (oid(der, keyParts[0]) !== EC_PUBLIC_KEY) throw new Error('der');
  const curve = CURVES[oid(der, keyParts[1])] ?? (() => { throw new Error('der'); })();
  const extensions = new Set<string>();
  let ca = false;
  for (; i < fields.length; i++) {
    if (fields[i].tag === 0x81 || fields[i].tag === 0x82 || fields[i].tag === 0xa1 || fields[i].tag === 0xa2) continue;
    if (fields[i].tag !== 0xa3) throw new Error('der');
    for (const extension of children(der, expect(children(der, fields[i])[0], 0x30))) {
      const parts = children(der, expect(extension, 0x30));
      const id = oid(der, parts[0]);
      if (extensions.has(id)) throw new Error('der');
      extensions.add(id);
      const value = expect(parts.at(-1), 0x04);
      if (id === BASIC_CONSTRAINTS) {
        const constraints = node(der, value.body, value.end);
        const flags = children(der, expect(constraints, 0x30));
        ca = flags[0]?.tag === 0x01 && flags[0].end - flags[0].body === 1 && der[flags[0].body] !== 0;
      }
    }
  }
  return { tbs: der.subarray(tbsNode.start, tbsNode.end), hash, signature: der.subarray(bits.body + 1, bits.end),
    issuer: der.subarray(issuer.start, issuer.end), subject: der.subarray(subject.start, subject.end),
    notBefore: time(der, validity[0]), notAfter: time(der, validity[1]), spki: der.subarray(spki.start, spki.end), curve, ca, extensions };
}

/** A DER ECDSA-Sig-Value as WebCrypto's fixed-width r||s. */
function rawSignature(der: Uint8Array, size: number): Uint8Array<ArrayBuffer> {
  const sequence = expect(node(der, 0, der.length), 0x30);
  if (sequence.end !== der.length) throw new Error('der');
  const parts = children(der, sequence);
  if (parts.length !== 2) throw new Error('der');
  const out = new Uint8Array(size * 2);
  parts.forEach((part, index) => {
    let value = der.subarray(expect(part, 0x02).body, part.end);
    while (value.length > 1 && value[0] === 0) value = value.subarray(1);
    if (!value.length || value.length > size) throw new Error('der');
    out.set(value, (index + 1) * size - value.length);
  });
  return out;
}

async function publicKey(certificate: Certificate): Promise<CryptoKey> {
  return await crypto.subtle.importKey('spki', owned(certificate.spki), { name: 'ECDSA', namedCurve: certificate.curve }, false, ['verify']);
}
/** Whether `child` names `issuer` as its issuer and carries a valid signature by its key. */
export async function signedBy(child: Certificate, issuer: Certificate): Promise<boolean> {
  if (!equal(child.issuer, issuer.subject)) return false;
  try {
    return await crypto.subtle.verify({ name: 'ECDSA', hash: child.hash }, await publicKey(issuer),
      rawSignature(child.signature, issuer.curve === 'P-256' ? 32 : 48), owned(child.tbs));
  } catch { return false; }
}

/** The pinned root's DER bytes, checked against the published fingerprint. */
export async function appleRootG3(): Promise<Uint8Array> {
  const der = base64(APPLE_ROOT_CA_G3, false);
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', owned(der))), byte => byte.toString(16).padStart(2, '0')).join('');
  if (digest !== APPLE_ROOT_CA_G3_SHA256) throw new Error('apple_root_mismatch');
  return der;
}

/** The bundle and environment a notification names (Apple's library reads data, summary, externalPurchaseToken, appData). */
function claims(payload: Record<string, unknown>): { bundleID: unknown; environment: unknown } {
  const part = (key: string) => payload[key] && typeof payload[key] === 'object' ? payload[key] as Record<string, unknown> : null;
  const data = part('data') ?? part('summary') ?? part('appData');
  if (data) return { bundleID: data.bundleId, environment: data.environment };
  const token = part('externalPurchaseToken');
  if (token) return { bundleID: token.bundleId, environment: typeof token.externalPurchaseId === 'string' && token.externalPurchaseId.startsWith('SANDBOX') ? 'Sandbox' : 'Production' };
  return { bundleID: undefined, environment: undefined };
}

/**
 * Authenticates a notification's `signedPayload` before admission. `options.root` and `options.now` exist for tests
 * only: the Edge function passes neither, so production always uses the pinned root and the current time.
 */
export async function authenticateAppleNotification(signed: unknown, policy: NotificationAuthPolicy,
  options: { root?: Uint8Array; now?: number } = {}): Promise<NotificationAuthResult> {
  try {
    if (typeof signed !== 'string' || signed.length < 20 || signed.length > MAX_SIGNED
      || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(signed)) refuse('framing');
    const [encodedHeader, encodedPayload, encodedSignature] = (signed as string).split('.');
    let header: { alg?: unknown; x5c?: unknown };
    try { header = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(base64(encodedHeader, true))); } catch { return refuse('header'); }
    if (!header || typeof header !== 'object' || header.alg !== 'ES256') refuse('header');
    const chain = header.x5c;
    if (!Array.isArray(chain) || chain.length !== 3) refuse('chain_length');
    let ders: Uint8Array[];
    try {
      ders = (chain as unknown[]).map(entry => {
        if (typeof entry !== 'string' || entry.length > MAX_CERTIFICATE_BASE64) throw new Error('certificate');
        return base64(entry, false);
      });
    } catch { return refuse('certificate'); }
    const root = options.root ?? await appleRootG3();
    if (!equal(ders[2], root)) refuse('root');
    let leaf: Certificate, intermediate: Certificate, anchor: Certificate;
    try { [leaf, intermediate, anchor] = ders.map(parseCertificate); } catch { return refuse('certificate'); }
    if (!await signedBy(intermediate, anchor) || !await signedBy(leaf, intermediate) || !intermediate.ca) refuse('chain');
    if (!leaf.extensions.has(LEAF_MARKER) || !intermediate.extensions.has(INTERMEDIATE_MARKER)) refuse('marker');
    const now = options.now ?? Date.now();
    if ([leaf, intermediate, anchor].some(c => c.notBefore > now + MAX_SKEW_MS || c.notAfter < now - MAX_SKEW_MS)) refuse('validity');
    if (leaf.curve !== 'P-256') refuse('signature');
    let signature: Uint8Array;
    try { signature = base64(encodedSignature, true); } catch { return refuse('signature'); }
    if (signature.length !== 64 || !await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, await publicKey(leaf), owned(signature),
      owned(new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`)))) refuse('signature');
    let payload: Record<string, unknown>;
    try { payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(base64(encodedPayload, true))); } catch { return refuse('claims'); }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) refuse('claims');
    const named = claims(payload);
    if (named.bundleID !== policy.bundleID || typeof named.environment !== 'string' || !policy.environments.includes(named.environment)) refuse('claims');
    return { ok: true };
  } catch (error) {
    return { ok: false, failure: error instanceof Refused ? error.failure : 'certificate' };
  }
}
