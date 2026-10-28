// Code-only same-tab S256 protocol. No credentials owner or provider SDK lives here.
import { isUUID } from './bytes';
import { validClaim, type AuthScope, type OAuthClaim, type OAuthProvider } from './auth-state';
export type OAuthIssue = 'oauth_cancelled' | 'oauth_expired' | 'oauth_rejected' | 'oauth_unavailable';
export class OAuthError extends Error { constructor(readonly issue: OAuthIssue) { super(issue); } }
export interface OAuthAttempt extends Omit<OAuthClaim, 'phase'> { version: 1; boundary: string; origin: string; environment: string; callback: string; verifier: string }
export const oauthProviders = {
  google: import.meta.env.VITE_GOOGLE_OAUTH_ENABLED === 'true',
  apple: import.meta.env.VITE_APPLE_OAUTH_ENABLED === 'true',
};
export const oauthStorageKey = (scope: AuthScope) => `gradstep.${scope.environment}.oauth.v1`;
function webOrigin(value: string): string {
  let url: URL; try { url = new URL(value); } catch { throw new OAuthError('oauth_rejected'); }
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/' || (url.protocol !== 'https:'
    && !(url.protocol === 'http:' && ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname)))) throw new OAuthError('oauth_rejected');
  return url.origin;
}
export const callbackURL = (origin: string) => `${webOrigin(origin)}/auth/callback`;
const base64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export async function pkceChallenge(verifier: string): Promise<string> {
  if (!/^[A-Za-z0-9_-]{43,128}$/.test(verifier)) throw new OAuthError('oauth_rejected');
  return base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
}
export function newAttempt(provider: OAuthProvider, scope: AuthScope, origin: string, boundary: string, now = Date.now()): OAuthAttempt {
  if (!isUUID(boundary) || !Number.isSafeInteger(now) || now <= 0) throw new OAuthError('oauth_rejected');
  return { version: 1, id: crypto.randomUUID(), boundary, provider, origin: scope.url, environment: scope.environment,
    callback: callbackURL(origin), createdAt: now, expiresAt: now + 600_000, verifier: base64url(crypto.getRandomValues(new Uint8Array(32))) };
}
export function parseAttempt(raw: string | null, scope: AuthScope, origin: string, now = Date.now()): OAuthAttempt {
  if (!raw || new TextEncoder().encode(raw).length > 4096) throw new OAuthError('oauth_rejected');
  let a: OAuthAttempt; try { a = JSON.parse(raw); } catch { throw new OAuthError('oauth_rejected'); }
  if (!a || a.version !== 1 || Object.keys(a).some(k => !['version', 'id', 'boundary', 'provider', 'origin', 'environment', 'callback', 'createdAt', 'expiresAt', 'verifier'].includes(k))
    || !validClaim({ id: a.id, provider: a.provider, phase: 'redirect', createdAt: a.createdAt, expiresAt: a.expiresAt }) || !isUUID(a.boundary)
    || a.origin !== scope.url || a.environment !== scope.environment || a.callback !== callbackURL(origin) || !/^[A-Za-z0-9_-]{43}$/.test(a.verifier)) throw new OAuthError('oauth_rejected');
  if (now < a.createdAt || now >= a.expiresAt) throw new OAuthError('oauth_expired');
  return a;
}
export async function authorizeURL(attempt: OAuthAttempt): Promise<string> {
  const url = new URL('/auth/v1/authorize', webOrigin(attempt.origin));
  url.search = new URLSearchParams({ provider: attempt.provider, redirect_to: attempt.callback, code_challenge: await pkceChallenge(attempt.verifier), code_challenge_method: 's256' }).toString();
  return url.toString();
}
export function callbackCode(raw: string, origin: string): string {
  if (new TextEncoder().encode(raw).length > 8192 || raw.includes('#')) throw new OAuthError('oauth_rejected');
  let url: URL; try { url = new URL(raw); } catch { throw new OAuthError('oauth_rejected'); }
  if (url.origin + url.pathname !== callbackURL(origin) || url.username || url.password || url.hash) throw new OAuthError('oauth_rejected');
  const keys = [...url.searchParams.keys()];
  if (keys.length !== new Set(keys).size || keys.some(k => !['code', 'error', 'error_code', 'error_description'].includes(k))) throw new OAuthError('oauth_rejected');
  if (url.searchParams.has('error') || url.searchParams.has('error_code') || url.searchParams.has('error_description')) {
    if (url.searchParams.has('code')) throw new OAuthError('oauth_rejected');
    throw new OAuthError(url.searchParams.get('error') === 'access_denied' ? 'oauth_cancelled' : 'oauth_rejected');
  }
  const code = url.searchParams.get('code');
  if (keys.length !== 1 || !code || code.length > 2048 || !/^[A-Za-z0-9._~-]+$/.test(code)) throw new OAuthError('oauth_rejected');
  return code;
}
