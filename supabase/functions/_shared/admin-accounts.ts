// Owner-only account management for the private beta (admin site › Accounts; migration 028):
// add a tester (a confirmed login created through the Auth admin API, so sign-up stays
// invite-only and no email is sent), grant credits, and disable or re-enable sign-in.
//
// The caller must be an owner signed in with MFA: v1_admin_actor runs the same
// app_private.is_operator('owner') gate as every v1_admin_* function, on the caller's own token.
// Only then is the service role used, and the service functions re-check that the account they
// act for is an owner. Input is validated strictly; requests are rate limited per owner; logs
// carry the action and outcome only (no email, reason, token or account ID).
import { PublicError } from './http.ts';

export const MAX_GRANT = 2000;
export const MAX_BODY_BYTES = 4096;
export const RATE_ROUTE = 'admin-accounts';
/** Auth ban for a disabled account (Go duration; about 100 years). 'none' lifts it. */
export const BAN_DURATION = '876000h';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// ASCII addresses only, as Supabase Auth accepts: a dotted local part and a dotted host name.
const EMAIL = /^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/;
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

export type AdminAction =
  | { action: 'add_tester'; email: string; credits: number }
  | { action: 'grant_credits'; request_id: string; account_id: string; credits: number; reason: string }
  | { action: 'set_sign_in'; request_id: string; account_id: string; disabled: boolean; reason: string };

type DatabaseError = { message: string } | null;
export interface RpcClient {
  rpc(name: string, params?: Record<string, unknown>): PromiseLike<{ data: unknown; error: DatabaseError }>;
}
export interface AuthError { message?: string; status?: number; code?: string }
export interface AdminService extends RpcClient {
  auth: { admin: {
    createUser(attributes: { email: string; email_confirm: boolean }): PromiseLike<{ data: { user: { id: string } | null } | null; error: AuthError | null }>;
    updateUserById(id: string, attributes: { ban_duration: string }): PromiseLike<{ error: AuthError | null }>;
  } };
}
export interface AdminDeps {
  /** Validates the bearer token with Auth (getUser) and returns a client acting as the caller. */
  authenticate(request: Request): Promise<{ user: RpcClient; accountID: string }>;
  service(): AdminService;
  log?(entry: Record<string, unknown>): void;
}

export function normalizeEmail(value: unknown): string {
  if (typeof value !== 'string') throw new PublicError(400, 'invalid_email');
  const email = value.trim().toLowerCase();
  const local = email.split('@')[0] ?? '';
  if (email.length < 6 || email.length > 254 || local.length > 64 || !EMAIL.test(email)) throw new PublicError(400, 'invalid_email');
  return email;
}

function credits(value: unknown, minimum: number): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum || value > MAX_GRANT) throw new PublicError(400, 'invalid_credits');
  return value;
}

function reason(value: unknown): string {
  if (typeof value !== 'string') throw new PublicError(400, 'invalid_reason');
  const text = value.trim();
  if (text.length < 3 || [...text].length > 500 || CONTROL.test(text)) throw new PublicError(400, 'invalid_reason');
  return text;
}

function id(value: unknown, code: string): string {
  if (typeof value !== 'string' || !UUID.test(value)) throw new PublicError(400, code);
  return value.toLowerCase();
}

function exactKeys(body: Record<string, unknown>, keys: string[]) {
  const present = Object.keys(body);
  if (present.length !== keys.length || present.some(key => !keys.includes(key))) throw new PublicError(400, 'invalid_request');
}

/** Strict request parsing: exact keys per action, bounded values, nothing else accepted. */
export function parseAdminAction(text: string): AdminAction {
  let body: unknown;
  try { body = JSON.parse(text); } catch { throw new PublicError(400, 'invalid_request'); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new PublicError(400, 'invalid_request');
  const fields = body as Record<string, unknown>;
  switch (fields.action) {
    case 'add_tester':
      exactKeys(fields, ['action', 'email', 'credits']);
      return { action: 'add_tester', email: normalizeEmail(fields.email), credits: credits(fields.credits, 0) };
    case 'grant_credits':
      exactKeys(fields, ['action', 'request_id', 'account_id', 'credits', 'reason']);
      return { action: 'grant_credits', request_id: id(fields.request_id, 'invalid_request_id'), account_id: id(fields.account_id, 'invalid_account'),
        credits: credits(fields.credits, 1), reason: reason(fields.reason) };
    case 'set_sign_in':
      exactKeys(fields, ['action', 'request_id', 'account_id', 'disabled', 'reason']);
      if (typeof fields.disabled !== 'boolean') throw new PublicError(400, 'invalid_request');
      return { action: 'set_sign_in', request_id: id(fields.request_id, 'invalid_request_id'), account_id: id(fields.account_id, 'invalid_account'),
        disabled: fields.disabled, reason: reason(fields.reason) };
    default:
      throw new PublicError(400, 'invalid_request');
  }
}

export async function readBody(request: Request, maximum = MAX_BODY_BYTES): Promise<string> {
  if (!(request.headers.get('content-type') ?? '').toLowerCase().startsWith('application/json')) throw new PublicError(415, 'json_required');
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) throw new PublicError(413, 'request_too_large');
  if (!request.body) throw new PublicError(400, 'invalid_request');
  const reader = request.body.getReader();
  const parts: Uint8Array[] = []; let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximum) { await reader.cancel().catch(() => {}); throw new PublicError(413, 'request_too_large'); }
      parts.push(value);
    }
  } finally { reader.releaseLock(); }
  const joined = new Uint8Array(length); let offset = 0;
  for (const part of parts) { joined.set(part, offset); offset += part.byteLength; }
  try { return new TextDecoder('utf-8', { fatal: true }).decode(joined); } catch { throw new PublicError(400, 'invalid_request'); }
}

// Database errors the page can act on; anything else is a generic failure.
const DATABASE_ERRORS: Record<string, [number, string]> = {
  owner_required: [403, 'owner_mfa_required'], owner_mfa_required: [403, 'owner_mfa_required'],
  request_rate_limit: [429, 'rate_limited'], account_unavailable: [404, 'account_unavailable'], account_closed: [409, 'account_closed'],
  owner_cannot_be_disabled: [409, 'owner_cannot_be_disabled'], request_id_conflict: [409, 'request_id_conflict'], grant_id_conflict: [409, 'request_id_conflict'],
  invalid_email: [400, 'invalid_email'], invalid_reason: [400, 'invalid_reason'], invalid_grant: [400, 'invalid_credits'],
  invalid_tester: [400, 'invalid_credits'], invalid_sign_in_change: [400, 'invalid_request'],
  account_disabled: [409, 'account_disabled'],
};
export function databaseError(error: { message: string }): PublicError {
  const known = DATABASE_ERRORS[error.message];
  return known ? new PublicError(known[0], known[1]) : new PublicError(503, 'service_unavailable');
}

async function call<T>(client: RpcClient, name: string, params: Record<string, unknown>): Promise<T> {
  const { data, error } = await client.rpc(name, params);
  if (error) throw databaseError(error);
  return data as T;
}

/** The owner gate, on the caller's own token: same check as every v1_admin_* function. */
export async function ownerActor(user: RpcClient, accountID: string): Promise<string> {
  const { data, error } = await user.rpc('v1_admin_actor', {});
  if (error) throw error.message === 'owner_mfa_required' ? new PublicError(403, 'owner_mfa_required') : new PublicError(503, 'service_unavailable');
  if (typeof data !== 'string' || data.toLowerCase() !== accountID.toLowerCase()) throw new PublicError(403, 'owner_mfa_required');
  return accountID.toLowerCase();
}

type Login = { account_id: string; closed: boolean } | null;

async function addTester(service: AdminService, actor: string, request: Extract<AdminAction, { action: 'add_tester' }>) {
  const find = () => call<Login>(service, 'worker_admin_find_login', { p_email: request.email });
  let login = await find(), created = false;
  if (login?.closed) throw new PublicError(409, 'account_closed');
  await call(service, 'worker_admin_admit_email', { p_actor_id: actor, p_email: request.email });
  if (!login) {
    // No password and no invitation: the login exists with its email confirmed, and the tester
    // signs in with an email code (or Apple/Google with the same address).
    const { data, error } = await service.auth.admin.createUser({ email: request.email, email_confirm: true });
    created = !error && typeof data?.user?.id === 'string' && UUID.test(data.user.id);
    // The auth.users trigger created the account row with the login; read it back. After an
    // error (for example the same tester added at the same moment) use whatever exists.
    login = await find();
    if (!login) {
      throw error && ['email_address_invalid', 'validation_failed'].includes(error.code ?? '')
        ? new PublicError(400, 'invalid_email') : new PublicError(503, 'service_unavailable');
    }
  }
  if (login.closed) throw new PublicError(409, 'account_closed');
  const result = await call<{ account_id: string; status: string; starting_credits: number; starting_granted: boolean }>(service, 'worker_admin_add_tester',
    { p_actor_id: actor, p_account_id: login.account_id, p_created: created, p_credits: request.credits });
  return { account_id: result.account_id, email: request.email, created, status: result.status,
    starting_credits: result.starting_credits, starting_granted: result.starting_granted };
}

async function grantCredits(service: AdminService, actor: string, request: Extract<AdminAction, { action: 'grant_credits' }>) {
  const result = await call<{ bucket_id: string; credits: number; replayed: boolean }>(service, 'worker_admin_grant_credits', {
    p_actor_id: actor, p_request_id: request.request_id, p_account_id: request.account_id, p_credits: request.credits, p_reason: request.reason });
  return { account_id: request.account_id, credits: result.credits, replayed: result.replayed };
}

async function setSignIn(service: AdminService, actor: string, request: Extract<AdminAction, { action: 'set_sign_in' }>) {
  // The audit row commits first: a failed Auth change leaves a record of the request, never an
  // unrecorded change. Retrying the same request ID reapplies it without a second row.
  const result = await call<{ auth_user_id: string; disabled: boolean; replayed: boolean }>(service, 'worker_admin_set_sign_in', {
    p_actor_id: actor, p_request_id: request.request_id, p_account_id: request.account_id, p_disabled: request.disabled, p_reason: request.reason });
  if (typeof result?.auth_user_id !== 'string' || !UUID.test(result.auth_user_id) || typeof result.disabled !== 'boolean') throw new PublicError(503, 'service_unavailable');
  // A14: Auth follows the database's current state, never the request's intent. A replayed request ID returns the state
  // now, which a newer change may have reversed; applying the old intent would ban an enabled account (or the reverse).
  const { error } = await service.auth.admin.updateUserById(result.auth_user_id, { ban_duration: result.disabled ? BAN_DURATION : 'none' });
  if (error) throw new PublicError(503, 'sign_in_change_unconfirmed');
  // A replay whose intent no longer matches: Auth is in step with the database, and the page is told it was superseded.
  if (result.replayed && result.disabled !== request.disabled) throw new PublicError(409, 'request_superseded');
  return { account_id: request.account_id, disabled: result.disabled, replayed: result.replayed };
}

/** Handles one request; `headers` (CORS etc.) are added to every response. */
export async function adminAccounts(request: Request, deps: AdminDeps, headers: Record<string, string> = {}): Promise<Response> {
  const started = Date.now();
  let action = 'unknown';
  const reply = (status: number, body: unknown, outcome: string) => {
    deps.log?.({ function: 'admin-accounts', action, status, outcome, ms: Date.now() - started });
    return Response.json(body, { status, headers });
  };
  try {
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const { user, accountID } = await deps.authenticate(request);
    const actor = await ownerActor(user, accountID);
    const parsed = parseAdminAction(await readBody(request));
    action = parsed.action;
    const service = deps.service();
    await call(service, 'worker_consume_request', { p_account_id: actor, p_route: RATE_ROUTE });
    const body = parsed.action === 'add_tester' ? await addTester(service, actor, parsed)
      : parsed.action === 'grant_credits' ? await grantCredits(service, actor, parsed)
      : await setSignIn(service, actor, parsed);
    return reply(200, body, 'replayed' in body && body.replayed ? 'replayed' : 'ok');
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return reply(failure.status, { code: failure.code }, failure.code);
  }
}
