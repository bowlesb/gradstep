// Pure, bounded persisted-auth codec. backend.ts is the only storage/credential owner.
import { isUUID } from './bytes';
import type { Session } from './backend';
export type OAuthProvider = 'google' | 'apple';
export interface OAuthClaim { id: string; provider: OAuthProvider; phase: 'redirect' | 'claimed'; createdAt: number; expiresAt: number }
export interface AuthEnvelope { version: 2; origin: string; environment: string; boundary: string; session: Session | null; oauth?: OAuthClaim }
export interface AuthScope { url: string; environment: string }
export type StoredAuth = { kind: 'empty'; raw: null } | { kind: 'invalid'; raw: string } | { kind: 'legacy'; raw: string; session: Session }
  | { kind: 'envelope'; raw: string; envelope: AuthEnvelope };
export const AUTH_MAX = 65_536;
const record = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const token = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 16_384 && !/[\s\u0000-\u001f\u007f-\u009f]/.test(v);
const email = (v: unknown): v is string | null => v === null || typeof v === 'string' && new TextEncoder().encode(v).length <= 320 && !/[\u0000-\u001f\u007f]/.test(v);
export function storedSession(v: unknown, legacy = false): Session | null {
  if (!record(v) || !token(v.accessToken) || !token(v.refreshToken) || typeof v.expiresAt !== 'number' || !Number.isFinite(v.expiresAt)
    || v.expiresAt < 0 || v.expiresAt > 2 ** 52 || !record(v.user) || !isUUID(v.user.id) || !email(v.user.email)) return null;
  const lifetime = v.lifetime === undefined && legacy ? 'legacy' : v.lifetime;
  if (typeof lifetime !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(lifetime)) return null;
  return { accessToken: v.accessToken, refreshToken: v.refreshToken, expiresAt: v.expiresAt, lifetime,
    user: { id: v.user.id.toLowerCase(), email: v.user.email } };
}
export function validClaim(v: unknown): v is OAuthClaim {
  return record(v) && Object.keys(v).every(k => ['id', 'provider', 'phase', 'createdAt', 'expiresAt'].includes(k)) && isUUID(v.id)
    && (v.provider === 'google' || v.provider === 'apple') && (v.phase === 'redirect' || v.phase === 'claimed')
    && Number.isSafeInteger(v.createdAt) && Number.isSafeInteger(v.expiresAt) && (v.createdAt as number) > 0
    && (v.expiresAt as number) - (v.createdAt as number) === 600_000;
}
export function parseStoredAuth(raw: string | null, scope: AuthScope): StoredAuth {
  if (raw === null) return { kind: 'empty', raw };
  const invalid = { kind: 'invalid', raw } as const;
  if (new TextEncoder().encode(raw).length > AUTH_MAX) return invalid;
  let v: unknown; try { v = JSON.parse(raw); } catch { return invalid; }
  if (!record(v)) return invalid;
  if (!('version' in v)) { const session = storedSession(v, true); return session ? { kind: 'legacy', raw, session } : invalid; }
  if (v.version !== 2 || !Object.keys(v).every(k => ['version', 'origin', 'environment', 'boundary', 'session', 'oauth'].includes(k))
    || v.origin !== scope.url || v.environment !== scope.environment || !isUUID(v.boundary)) return invalid;
  const session = v.session === null ? null : storedSession(v.session);
  if (v.session !== null && !session || v.oauth !== undefined && (!validClaim(v.oauth) || session !== null)) return invalid;
  return { kind: 'envelope', raw, envelope: { version: 2, origin: scope.url, environment: scope.environment, boundary: v.boundary, session,
    ...(v.oauth === undefined ? {} : { oauth: v.oauth as OAuthClaim }) } };
}
