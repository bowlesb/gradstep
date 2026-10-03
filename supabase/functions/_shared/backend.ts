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
  const { data, error } = await user.auth.getUser(token);
  if (error || !data.user) throw new PublicError(401, 'authentication_required');
  const context = await rpc<{ account_id: string }>(user, 'v1_account_context');
  if (context.account_id !== data.user.id) throw new PublicError(403, 'account_unavailable');
  return { user, accountID: context.account_id };
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
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  };
}
