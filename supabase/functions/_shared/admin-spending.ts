import { ownerActor, readBody, type RpcClient } from './admin-accounts.ts';
import { PublicError } from './http.ts';
import { parseSpendingObservation, spendingReceipt, SpendingInputError } from './spending-observations.ts';

export interface AdminSpendingDeps {
  authenticate(request: Request): Promise<{ user: RpcClient; accountID: string }>;
  service(): RpcClient;
  log?(entry: Record<string, unknown>): void;
}
const SQL_ERRORS: Record<string, [number, string]> = {
  owner_required: [403, 'owner_mfa_required'], owner_mfa_required: [403, 'owner_mfa_required'],
  request_rate_limit: [429, 'rate_limited'], spending_observation_id_conflict: [409, 'observation_id_conflict'],
  spending_observation_capacity: [409, 'observation_capacity'], spending_component_unavailable: [400, 'invalid_component'],
  invalid_spending_observation: [400, 'invalid_observation'], invalid_spending_metric: [400, 'invalid_observation'],
};
async function call(service: RpcClient, name: string, params: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await service.rpc(name, params);
  if (error) {
    const known = SQL_ERRORS[error.message];
    throw known ? new PublicError(...known) : new PublicError(503, 'service_unavailable');
  }
  return data;
}

/** Append evidence only. No actor, SQL name, source, numeric units or budget action is supplied by the browser. */
export async function adminSpending(request: Request, deps: AdminSpendingDeps, headers: Record<string, string> = {}): Promise<Response> {
  const started = Date.now();
  const reply = (status: number, body: unknown, outcome: string) => {
    // A diagnostic failure cannot turn an acknowledged append into an apparent failure.
    try { deps.log?.({ function: 'admin-spending', status, outcome, ms: Math.max(0, Date.now() - started) }); } catch { /* best effort */ }
    return Response.json(body, { status, headers: { ...headers, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
  };
  try {
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const { user, accountID } = await deps.authenticate(request);
    const actor = await ownerActor(user, accountID);
    if ((request.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') throw new PublicError(415, 'json_required');
    let value: unknown;
    const text = await readBody(request, 4096);
    try { value = JSON.parse(text); } catch { throw new PublicError(400, 'invalid_request'); }
    const observation = parseSpendingObservation(value);
    // Lazy construction: the service role is unavailable until the caller's own MFA gate succeeds.
    const service = deps.service();
    await call(service, 'worker_consume_request', { p_account_id: actor, p_route: 'admin-spending' });
    const recorded = await call(service, 'worker_record_spending_observation', {
      p_actor_id: actor, p_id: observation.request_id, p_component: observation.component, p_period: observation.period,
      p_measure: observation.measure, p_amount_microusd: observation.amount_microusd, p_complete: observation.complete,
      p_observed_at: observation.observed_at, p_source: 'owner-entry', p_evidence_reference: observation.evidence_reference, p_units: {},
    });
    const result = spendingReceipt(recorded, observation.request_id);
    if (!result) throw new PublicError(503, 'service_unavailable');
    return reply(200, result, result.replayed ? 'replayed' : 'recorded');
  } catch (error) {
    const failure = error instanceof SpendingInputError ? new PublicError(400, error.code)
      : error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return reply(failure.status, { code: failure.code }, failure.code);
  }
}
