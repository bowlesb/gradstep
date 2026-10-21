// Automatic reconciliation of unresolved OpenRouter attempts (review A6, migration 0102; PROVIDER_SPENDING.md
// "Automatic reconciliation"). The pipeline worker runs this every minute: a bounded batch of dispatched attempts left
// `unknown` (a Stop, a dropped or broken stream, a timeout) is matched to OpenRouter's generation record and settled at
// its cost, releasing the rest of the held ceiling. One GET per attempt per run (a GET buys nothing); the database
// backs off and gives up after 12 tries, leaving the attempt reserved and named on Health. Counts only in logs.
import { lookupGeneration } from './openrouter-generation.ts';

export interface ReconcileDeps {
  rpc(name: string, params: Record<string, unknown>): Promise<unknown>;
  /** The OpenRouter key that can read this feature's generations (null: none configured). */
  keyFor(feature: string | null): string | null;
  fetch?: typeof fetch;
  now?: () => number;
  log?(event: string, fields: Record<string, string | number | boolean | null>): void;
}
interface Claim { attempt_id: string; account_id: string; operation_id: string; generation_id: string; transport_model: string | null; feature: string | null }
const PROVIDER = /^[a-zA-Z0-9 ./_-]{1,80}$/;

export async function reconcileOpenRouterAttempts(deps: ReconcileDeps, limits: { batch?: number; budgetMs?: number } = {}) {
  const now = deps.now ?? Date.now, started = now(), budget = limits.budgetMs ?? 30_000;
  const result = { claimed: 0, reconciled: 0, missing: 0, failed: 0 };
  const claims = await deps.rpc('worker_openrouter_reconcile_claim', { p_limit: limits.batch ?? 10 }) as Claim[] | null;
  if (!Array.isArray(claims)) return result;
  result.claimed = claims.length;
  for (const claim of claims) {
    if (now() - started > budget) break;
    const miss = async (outcome: 'not_found' | 'mismatch' | 'no_key') => {
      result.missing++;
      await deps.rpc('worker_openrouter_reconcile_miss', { p_attempt_id: claim.attempt_id, p_outcome: outcome }).catch(() => undefined);
    };
    const key = deps.keyFor(claim.feature);
    if (!key) { await miss('no_key'); continue; }
    const expected = claim.transport_model ?? '';
    const record = await lookupGeneration({ apiKey: key, fetch: deps.fetch }, claim.generation_id,
      { accountID: claim.account_id, operationID: claim.operation_id }, AbortSignal.timeout(10_000), 1);
    if (!record) { await miss('not_found'); continue; }
    if (!expected || !(record.model === expected || record.model.startsWith(`${expected}-`)) || !PROVIDER.test(record.provider)) { await miss('mismatch'); continue; }
    const cached = Math.min(record.cachedTokens, record.promptTokens);
    try {
      const done = await deps.rpc('worker_openrouter_reconcile', { p_attempt_id: claim.attempt_id, p_generation_id: claim.generation_id,
        p_receipt: { generation_id: claim.generation_id, provider: record.provider, model: expected,
          ...(record.model !== expected ? { resolved_model: record.model } : {}), total_cost_microusd: record.totalMicrousd },
        p_actual_microusd: record.totalMicrousd,
        p_units: { input_tokens: record.promptTokens - cached, cache_read_tokens: cached, output_tokens: record.completionTokens } }) as { reconciled?: boolean } | null;
      if (done?.reconciled) result.reconciled++;
    } catch { result.failed++; }
  }
  if (result.claimed) deps.log?.('openrouter_reconcile', { ...result, ms: now() - started });
  return result;
}
