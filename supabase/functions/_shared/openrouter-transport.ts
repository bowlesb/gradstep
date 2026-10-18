// The single paid OpenRouter transport. Attribution is required and durably recorded before POST.
// Content stays in memory; the ledger receives only closed metadata, identifiers and numeric usage.
export interface OpenRouterAttribution {
  accountID: string;
  operationID: string;
  attemptID: string;
  feature: string;
  caller: string;
  dispatch(metadata: OpenRouterDispatch): Promise<boolean>;
  receipt?(metadata: OpenRouterReceipt): Promise<boolean>;
}
export interface OpenRouterDispatch {
  transport_model: string;
  endpoint: string;
  feature: string;
  caller: string;
}
export interface OpenRouterReceipt { generation_id: string; provider: string; model: string; resolved_model?: string; total_cost_microusd?: number }
export class OpenRouterNotDispatched extends Error {
  constructor() { super('openrouter_attribution_unavailable'); }
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LABEL = /^[a-z][a-z0-9_/-]{0,63}$/;
export function rpcAttribution(deps: { accountID: string; operationID: string; rpc(name: string, params: Record<string, unknown>): Promise<unknown> },
  attemptID: string, feature: string, caller: string): OpenRouterAttribution {
  return { accountID: deps.accountID, operationID: deps.operationID, attemptID, feature, caller,
    async dispatch(metadata) {
      try {
        return await deps.rpc('worker_openrouter_dispatch', { p_account_id: deps.accountID, p_operation_id: deps.operationID,
          p_attempt_id: attemptID, p_metadata: metadata }) === true;
      } catch { return false; } // A lost acknowledgement never becomes a second send.
    },
    async receipt(metadata) {
      try { return await deps.rpc('worker_openrouter_receipt', { p_account_id: deps.accountID, p_operation_id: deps.operationID,
        p_attempt_id: attemptID, p_metadata: metadata }) === true; } catch { return false; }
    } };
}
export async function openRouterPost(options: { apiKey: string; fetch?: typeof fetch }, endpoint: 'chat/completions' | 'audio/speech',
  body: Record<string, unknown>, signal: AbortSignal, attribution: OpenRouterAttribution | undefined): Promise<Response> {
  if (!attribution || ![attribution.accountID, attribution.operationID, attribution.attemptID].every(id => UUID.test(id))
    || !LABEL.test(attribution.feature) || !LABEL.test(attribution.caller) || typeof body.model !== 'string'
    || !/^[a-z0-9./-]{1,128}$/.test(body.model)) throw new OpenRouterNotDispatched();
  const policy = body.provider as { only?: string[] } | undefined;
  const route = endpoint === 'audio/speech' ? 'speech/zdr' : policy?.only?.length === 1 ? policy.only[0] : '';
  if (!/^[a-z0-9./-]{1,128}$/.test(route) || signal.aborted) throw new OpenRouterNotDispatched();
  const metadata: OpenRouterDispatch = { transport_model: body.model, endpoint: route, feature: attribution.feature, caller: attribution.caller };
  if (!await attribution.dispatch(metadata)) throw new OpenRouterNotDispatched();
  return await (options.fetch ?? fetch)(`https://openrouter.ai/api/v1/${endpoint}`, {
    method: 'POST', signal, redirect: 'error', headers: { authorization: `Bearer ${options.apiKey}`, 'content-type': 'application/json',
      'X-Title': 'Gradstep', 'X-OpenRouter-Cache': 'false', 'X-Session-ID': attribution.operationID },
    body: JSON.stringify({ ...body, user: attribution.accountID, session_id: attribution.operationID,
      trace: { attempt_id: attribution.attemptID, feature: attribution.feature, caller: attribution.caller, sent_at: new Date().toISOString() } }),
  });
}
