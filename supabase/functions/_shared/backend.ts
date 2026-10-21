import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { exposedDatabaseError, PublicError } from './http.ts';

function required(name: string): string {
  const value = Deno.env.get(name); if (!value) throw new PublicError(503, 'service_unavailable'); return value;
}
const options = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  global: { fetch: (input: RequestInfo | URL, init?: RequestInit) => fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(20_000) }) },
};
export function serviceClient(): SupabaseClient { return createClient(required('SUPABASE_URL'), required('SUPABASE_SERVICE_ROLE_KEY'), options); }
export async function userClient(request: Request): Promise<{ user: SupabaseClient; accountID: string }> {
  const authorization = request.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ') || authorization.length > 16000) throw new PublicError(401, 'authentication_required');
  const token = authorization.slice(7);
  const user = createClient(required('SUPABASE_URL'), required('SUPABASE_ANON_KEY'), {
    ...options, global: { ...options.global, headers: { Authorization: authorization } },
  });
  // C6 (review 2026-10-21): Auth's check of the token and the account read run together (one round trip, not two);
  // the account answer is used only after Auth accepted the same token, and must name the same user.
  const [checked, context] = await Promise.all([user.auth.getUser(token),
    rpc<{ account_id: string }>(user, 'v1_account_context').then(value => ({ value }), error => ({ error }))]);
  if (checked.error || !checked.data.user) throw new PublicError(401, 'authentication_required');
  if ('error' in context) throw context.error;
  if (context.value.account_id !== checked.data.user.id) throw new PublicError(403, 'account_unavailable');
  return { user, accountID: context.value.account_id };
}
/** The caller's login ID from a valid token, without requiring an open
 * account (account deletion must resume for an account it already closed). */
export async function authenticatedUserID(request: Request): Promise<string> {
  const authorization = request.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ') || authorization.length > 16000) throw new PublicError(401, 'authentication_required');
  const user = createClient(required('SUPABASE_URL'), required('SUPABASE_ANON_KEY'), {
    ...options, global: { ...options.global, headers: { Authorization: authorization } },
  });
  const { data, error } = await user.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw new PublicError(401, 'authentication_required');
  return data.user.id;
}
export async function rpc<T>(client: SupabaseClient, name: string, params: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await client.rpc(name, params);
  if (error) throw exposedDatabaseError(error.message);
  return data as T;
}
export function cors(request: Request): Record<string, string> {
  const origin = request.headers.get('origin');
  const allowed = (Deno.env.get('ADMIN_ORIGINS') ?? '').split(',').map(s => s.trim()).filter(Boolean);
  if (origin && !allowed.includes(origin)) throw new PublicError(403, 'origin_unavailable');
  return {
    ...(origin ? { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' } : {}),
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Max-Age': '600',
    // A browser may read when to ask again (RESILIENCE.md, fix 6).
    'Access-Control-Expose-Headers': 'Retry-After',
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  };
}
