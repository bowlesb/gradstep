// A receipt-free operator probe for the exact hosted Edge -> Google IAM ->
// Node path. End-user tokens and the anon key confer no authority here.
import { timingSafeEqual } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { configuredStoreGoogleIdentity } from './store-google-auth.ts';
import { storeBoundedOperation, storePrivateJSON } from './store-verifier-transport.ts';
import { POLICY_ID } from './store-verifier-protocol.ts';

export const STORE_SDK_SOURCE_SHA256 = '2ab29caa890958dcfc6dc4789fd5a500e8249102e037045525d35e5c15541bf1';
export const STORE_SDK_PATCHED_SHA256 = 'e2bbd098d9572596e6fa7572b69ee96fa4c34d5db5479672bc3a91a2c47241ad';
const capabilityKeys = ['certificate_parse', 'certificate_string', 'certificate_raw', 'public_key_export', 'certificate_verify', 'certificate_info_access'];
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function fields(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
export function isStoreVerifierHealth(value: unknown): boolean {
  if (!object(value) || !fields(value, ['version', 'ok', 'policy_id', 'policy_valid', 'maintenance', 'ready', 'revision', 'runtime'])
    || value.version !== 1 || value.ok !== true || value.policy_id !== POLICY_ID
    || !['policy_valid', 'maintenance', 'ready'].every(key => typeof value[key] === 'boolean')
    || (value.revision !== null && !(typeof value.revision === 'string' && value.revision.length <= 63
      && !/[^a-z0-9-]/.test(value.revision)
      && /^gradstep-store-verifier-[a-z0-9-]{1,39}$/.test(value.revision)))
    || !object(value.runtime) || !fields(value.runtime, ['node', 'apple_library', 'capabilities', 'ocsp_freshness'])) return false;
  const runtime = value.runtime;
  if (typeof runtime.node !== 'string' || /[^0-9.]/.test(runtime.node) || !/^24\.\d{1,3}\.\d{1,3}$/.test(runtime.node) || runtime.apple_library !== '3.1.0'
    || !object(runtime.capabilities) || !fields(runtime.capabilities, capabilityKeys)
    || !Object.values(runtime.capabilities).every(flag => typeof flag === 'boolean')
    || !object(runtime.ocsp_freshness) || !fields(runtime.ocsp_freshness, ['policy', 'applied', 'source_sha256', 'patched_sha256'])) return false;
  const patch = runtime.ocsp_freshness;
  if (patch.policy !== 'strict-utc-v1' || typeof patch.applied !== 'boolean'
    || patch.source_sha256 !== STORE_SDK_SOURCE_SHA256 || patch.patched_sha256 !== STORE_SDK_PATCHED_SHA256) return false;
  // Shutdown may independently make a healthy service unready, but no response
  // may claim readiness without all fixed policy and crypto prerequisites.
  return !value.ready || (value.policy_valid === true && value.maintenance === false && patch.applied === true
    && Object.values(runtime.capabilities).every(flag => flag === true) && value.revision !== null);
}

export function createStoreVerifierHealthHandler(env: (name: string) => string | undefined,
  deps: { connection?: () => ReturnType<typeof configuredStoreGoogleIdentity>; fetch?: typeof fetch; now?: () => number } = {}) {
  let connection: ReturnType<typeof configuredStoreGoogleIdentity> | undefined;
  const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  const answer = (status: number, code: string) => Response.json({ code }, { status, headers });
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'GET') return answer(405, 'method_unavailable');
    const expected = env('SUPABASE_SERVICE_ROLE_KEY');
    const authorization = request.headers.get('authorization');
    if (typeof expected !== 'string' || expected.length < 32 || expected.length > 16_384) return answer(503, 'service_unavailable');
    const actual = authorization?.startsWith('Bearer ') ? authorization.slice(7) : '';
    if (!actual || Buffer.byteLength(actual) !== Buffer.byteLength(expected)
      || !timingSafeEqual(Buffer.from(actual), Buffer.from(expected))) return answer(401, 'authentication_required');
    const probe = request.headers.get('x-verifier-probe-id');
    if (!probe || probe.length !== 36 || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(probe)
      || request.body !== null || ![null, '0'].includes(request.headers.get('content-length'))
      || request.headers.has('transfer-encoding') || new URL(request.url).search) return answer(400, 'invalid_request');
    try {
      connection ??= (deps.connection ?? (() => configuredStoreGoogleIdentity(env)))();
      const token = await storeBoundedOperation(() => connection!.identity.token(), 8_500, request.signal);
      const result = await storePrivateJSON(connection.audience, '/health', token, { timeout: 12_000, maximum: 8_192,
        signal: request.signal, fetch: deps.fetch });
      if (result.status === 401 || result.status === 403) connection.identity.invalidate();
      if (result.status !== 200 || !isStoreVerifierHealth(result.value)) return answer(503, 'service_unavailable');
      return Response.json({ version: 1, probe_id: probe, observed_at: new Date((deps.now ?? Date.now)()).toISOString(), health: result.value }, { headers });
    } catch { return answer(503, 'service_unavailable'); }
  };
}
