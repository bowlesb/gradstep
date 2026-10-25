// Automatic reconciliation of unresolved OpenRouter attempts (review A6, migration 0102; PROVIDER_SPENDING.md
// "Automatic reconciliation"). The pipeline worker runs this every minute: a bounded batch of dispatched attempts left
// `unknown` (a Stop, a dropped or broken stream, a timeout) is matched to OpenRouter's generation record and settled at
// its cost, releasing the rest of the held ceiling. One GET per attempt per run (a GET buys nothing); the database
// backs off and gives up after 12 tries, leaving the attempt reserved and named on Health. Counts only in logs.
// Assumed zero (migration 0162, JUDGMENT_LOG 21): when OpenRouter answers 404 on or after an attempt's 12th try (or no
// generation id was ever issued) the database may settle it at zero if no output of the model ever reached us; such an
// attempt is read once a day afterwards and a late record corrects it. A read that is not a clean 404 never counts.
import { readGeneration, type GenerationRead } from './openrouter-generation.ts';

export interface ReconcileDeps {
  rpc(name: string, params: Record<string, unknown>): Promise<unknown>;
  /** The OpenRouter key that can read this feature's generations (null: none configured). */
  keyFor(feature: string | null): string | null;
  fetch?: typeof fetch;
  now?: () => number;
  log?(event: string, fields: Record<string, string | number | boolean | null>): void;
}
interface Claim { attempt_id: string; account_id: string; operation_id: string; generation_id: string | null; transport_model: string | null; feature: string | null;
  /** Migration 0162: a clean 404 now may settle it at zero (the database decides), and whether it already was. */
  final?: boolean; assumed_zero?: boolean }
const PROVIDER = /^[a-zA-Z0-9 ./_-]{1,80}$/;
/** The record's model is the one dispatched: the same slug, a longer release of it ("…-flash" → "…-flash-20261017"), the
 * slug without the date it was dispatched under ("…-v4.1-flash-1017" read back as "…-v4.1-flash"), or the same date
 * written in full ("…-v4.1-flash-1017" read back as "…-v4.1-flash-20261017": OpenRouter's record of 2026-10-22's DeepSeek
 * attempt, which stayed `mismatch` for eleven tries; looked up 2026-10-25). Only a trailing date or release number may
 * differ, and a shortened date must be the end of the full one. */
export function sameModel(recorded: string, expected: string): boolean {
  if (recorded === expected || recorded.startsWith(`${expected}-`)) return true;
  if (expected.startsWith(`${recorded}-`) && /^\d{3,8}$/.test(expected.slice(recorded.length + 1))) return true;
  const dated = /^(.+)-(\d{3,8})$/, a = dated.exec(recorded), b = dated.exec(expected);
  return !!a && !!b && a[1] === b[1] && (a[2].endsWith(b[2]) || b[2].endsWith(a[2]));
}

export async function reconcileOpenRouterAttempts(deps: ReconcileDeps, limits: { batch?: number; budgetMs?: number } = {}) {
  const now = deps.now ?? Date.now, started = now(), budget = limits.budgetMs ?? 30_000;
  const result = { claimed: 0, reconciled: 0, missing: 0, failed: 0, assumedZero: 0 };
  const claims = await deps.rpc('worker_openrouter_reconcile_claim', { p_limit: limits.batch ?? 10 }) as Claim[] | null;
  if (!Array.isArray(claims)) return result;
  result.claimed = claims.length;
  for (const claim of claims) {
    if (now() - started > budget) break;
    const miss = async (outcome: 'not_found' | 'mismatch' | 'no_key' | 'unreadable') => {
      result.missing++;
      await deps.rpc('worker_openrouter_reconcile_miss', { p_attempt_id: claim.attempt_id, p_outcome: outcome }).catch(() => undefined);
    };
    let read: GenerationRead;
    // No generation id was issued (the request was lost before OpenRouter named it): no record can be read; it counts as
    // none (JUDGMENT_LOG 21), and the database alone decides whether that settles anything.
    if (!claim.generation_id) read = { missing: 'absent' };
    else {
      const key = deps.keyFor(claim.feature);
      if (!key) { await miss('no_key'); continue; }
      read = await readGeneration({ apiKey: key, fetch: deps.fetch }, claim.generation_id,
        { accountID: claim.account_id, operationID: claim.operation_id }, AbortSignal.timeout(10_000), 1);
    }
    if (!('record' in read)) {
      if (read.missing === 'absent' && claim.final && !claim.assumed_zero) {
        // Recorded either way by the database: `assumed_zero` when every condition holds, else this read as `not_found`.
        try {
          const done = await deps.rpc('worker_openrouter_reconcile_absent', { p_attempt_id: claim.attempt_id, p_generation_id: claim.generation_id }) as { settled?: boolean } | null;
          if (done?.settled) result.assumedZero++; else result.missing++;
        } catch { result.failed++; }
        continue;
      }
      // A record that fails the identity checks is still a record: never "not found".
      await miss(read.missing === 'absent' ? 'not_found' : read.missing === 'invalid' ? 'mismatch' : 'unreadable');
      continue;
    }
    const record = read.record, expected = claim.transport_model ?? '';
    if (!expected || !sameModel(record.model, expected) || !PROVIDER.test(record.provider)) { await miss('mismatch'); continue; }
    const cached = Math.min(record.cachedTokens, record.promptTokens);
    try {
      // Also corrects an attempt assumed zero to the record's cost (the database recognizes it).
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
