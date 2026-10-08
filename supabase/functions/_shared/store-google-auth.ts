// Google-issued identity for the private purchase verifier. This module never
// discovers credentials, accepts a client URL, or calls the verifier itself.
import { JWT } from 'google-auth-library';
import { Buffer } from 'node:buffer';

export const STORE_GOOGLE_CALLER = 'gradstep-store-caller@gradstep.iam.gserviceaccount.com';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const TOKEN_TIMEOUT_MS = 8_000;
const TOKEN_MAX_BYTES = 16_384;
const REFRESH_MARGIN_MS = 120_000;

export class StoreGoogleIdentityUnavailable extends Error {
  constructor() { super('store_google_identity_unavailable'); }
}

export interface StoreGoogleCredentials {
  readonly email: string;
  readonly clientID: string;
  readonly privateKey: string;
  readonly keyID: string;
}

/** Only the deployment's canonical service origin, never a route or a redirect.
 * Deployment tooling additionally binds this value to Google's service readback. */
export function storeVerifierAudience(value: unknown): string {
  if (typeof value !== 'string' || value.length > 256) throw new StoreGoogleIdentityUnavailable();
  let parsed: URL;
  try { parsed = new URL(value); } catch { throw new StoreGoogleIdentityUnavailable(); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.port || parsed.search || parsed.hash
    || parsed.origin !== value || parsed.pathname !== '/'
    || !/^gradstep-store-verifier-[a-z0-9-]+(?:\.us-west1\.run\.app|\.a\.run\.app)$/.test(parsed.hostname)) {
    throw new StoreGoogleIdentityUnavailable();
  }
  return value;
}

/** Parse only a dedicated service-account key; never pass arbitrary credential
 * configuration to the library's ADC/external-account loaders. */
export function storeGoogleCredentials(value: unknown): StoreGoogleCredentials {
  if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') > 16_384) throw new StoreGoogleIdentityUnavailable();
  let raw: Record<string, unknown>;
  try { raw = JSON.parse(value); } catch { throw new StoreGoogleIdentityUnavailable(); }
  const allowed = new Set(['type', 'project_id', 'private_key_id', 'private_key', 'client_email', 'client_id',
    'auth_uri', 'token_uri', 'auth_provider_x509_cert_url', 'client_x509_cert_url', 'universe_domain']);
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).some(key => !allowed.has(key))
    || raw.type !== 'service_account' || raw.project_id !== 'gradstep' || raw.client_email !== STORE_GOOGLE_CALLER
    || raw.token_uri !== TOKEN_URL || (raw.universe_domain !== undefined && raw.universe_domain !== 'googleapis.com')
    || typeof raw.client_id !== 'string' || !/^\d{10,40}$/.test(raw.client_id)
    || typeof raw.private_key_id !== 'string' || !/^[a-f0-9]{40}$/.test(raw.private_key_id)
    || typeof raw.private_key !== 'string' || raw.private_key.length > 8_192
    || !/^-----BEGIN PRIVATE KEY-----\n[A-Za-z0-9+/=\n]+\n-----END PRIVATE KEY-----\n?$/.test(raw.private_key)) {
    throw new StoreGoogleIdentityUnavailable();
  }
  return Object.freeze({ email: STORE_GOOGLE_CALLER, clientID: raw.client_id,
    privateKey: raw.private_key, keyID: raw.private_key_id });
}

async function tokenResponse(response: Response): Promise<Response> {
  if (response.status >= 300 && response.status < 400 || !response.body) throw new StoreGoogleIdentityUnavailable();
  const length = response.headers.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > TOKEN_MAX_BYTES)) {
    await response.body.cancel().catch(() => {});
    throw new StoreGoogleIdentityUnavailable();
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let count = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > TOKEN_MAX_BYTES) throw new StoreGoogleIdentityUnavailable();
      chunks.push(value);
    }
  } catch {
    await reader.cancel().catch(() => {});
    throw new StoreGoogleIdentityUnavailable();
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  // Preserve only what the authentication library needs; don't retain arbitrary
  // provider headers or an unbounded response/error stream.
  return new Response(bytes, { status: response.status, headers: { 'content-type': 'application/json' } });
}

function tokenExpiry(token: unknown, credentials: StoreGoogleCredentials, audience: string, now: number): number {
  if (typeof token !== 'string' || token.length > TOKEN_MAX_BYTES || /[^A-Za-z0-9_.-]/.test(token)
    || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) {
    throw new StoreGoogleIdentityUnavailable();
  }
  let payload: Record<string, unknown>;
  try { payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8')); }
  catch { throw new StoreGoogleIdentityUnavailable(); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)
    || !['https://accounts.google.com', 'accounts.google.com'].includes(String(payload.iss))
    || payload.aud !== audience || payload.sub !== credentials.clientID
    || (payload.email !== undefined && payload.email !== credentials.email)
    || typeof payload.exp !== 'number' || !Number.isSafeInteger(payload.exp)
    || payload.exp * 1000 <= now + REFRESH_MARGIN_MS || payload.exp * 1000 > now + 3_900_000) {
    throw new StoreGoogleIdentityUnavailable();
  }
  // These are cache sanity checks on the response received directly from Google.
  // Cloud Run, not this decoded payload, verifies the token and grants invocation.
  return payload.exp * 1000;
}

export interface StoreGoogleIdentity {
  token(): Promise<string>;
  /** A rejected token is discarded for the next admitted request, never retried
   * automatically with the current request's one-use forwarding permission. */
  invalidate(): void;
}

export function configuredStoreGoogleIdentity(env: (name: string) => string | undefined): { audience: string; identity: StoreGoogleIdentity } {
  const audience = storeVerifierAudience(env('STORE_VERIFIER_URL'));
  const credentials = storeGoogleCredentials(env('STORE_VERIFIER_GOOGLE_CREDENTIALS'));
  return { audience, identity: createStoreGoogleIdentity(credentials, audience) };
}

export function createStoreGoogleIdentity(credentials: StoreGoogleCredentials, configuredAudience: string,
  deps: { fetch?: typeof fetch; now?: () => number } = {}): StoreGoogleIdentity {
  const audience = storeVerifierAudience(configuredAudience);
  const send = deps.fetch ?? fetch;
  const now = deps.now ?? Date.now;
  let cached: { token: string; expiresAt: number } | undefined;
  let pending: Promise<string> | undefined;
  let generation = 0;
  const client = new JWT({ email: credentials.email, key: credentials.privateKey, keyId: credentials.keyID,
    transporterOptions: {
      // The SDK supplies per-call retry options. Apply our limits after that
      // merge, to the same prepared object used by Gaxios's error/retry handler.
      adapter: async (options, defaultAdapter) => {
        if (String(options.url) !== TOKEN_URL || options.method !== 'POST') throw new StoreGoogleIdentityUnavailable();
        options.retry = false;
        options.retryConfig = { retry: 0, noResponseRetries: 0 };
        options.maxRedirects = 0;
        options.timeout = TOKEN_TIMEOUT_MS;
        options.signal = AbortSignal.timeout(TOKEN_TIMEOUT_MS);
        options.fetchImplementation = async (input, init) => {
          const url = input instanceof Request ? input.url : String(input);
          if (url !== TOKEN_URL || init?.method !== 'POST') throw new StoreGoogleIdentityUnavailable();
          return tokenResponse(await send(input, { ...init, redirect: 'error', signal: options.signal }));
        };
        return defaultAdapter(options);
      },
    },
  });
  return {
    token() {
      if (cached && cached.expiresAt - REFRESH_MARGIN_MS > now()) return Promise.resolve(cached.token);
      if (pending) return pending;
      const selectedGeneration = generation;
      const flight = (async () => {
        try {
          const token = await client.fetchIdToken(audience);
          const expiresAt = tokenExpiry(token, credentials, audience, now());
          if (selectedGeneration !== generation) throw new StoreGoogleIdentityUnavailable();
          cached = { token, expiresAt };
          return token;
        } catch {
          // Library errors may contain credentials, a signed assertion, response
          // bodies or URLs. None escapes this boundary, including in a cause.
          throw new StoreGoogleIdentityUnavailable();
        }
      })();
      pending = flight;
      void flight.finally(() => { if (pending === flight) pending = undefined; }).catch(() => {});
      return flight;
    },
    invalidate() { generation++; cached = undefined; pending = undefined; },
  };
}
