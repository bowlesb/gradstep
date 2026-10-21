// The provider budget row for the current UTC month (review A3, 2026-10-21). v1_admin_overview lists every period,
// newest first, and since migration 060 next month's row exists ahead of time: the first row is not this month's.
export interface BudgetRow { period: string; limit_microusd: number; spent_microusd: number; reserved_microusd: number; work_enabled: boolean }

/** `YYYY-MM-01` for the UTC month containing `now`. */
export function currentPeriod(now: Date = new Date()): string {
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}-01`;
}

/** This UTC month's budget, or null when it is missing (paid work is then refused by the server). */
export function currentBudget<T extends BudgetRow>(budgets: readonly T[] | null | undefined, now: Date = new Date()): T | null {
  const period = currentPeriod(now);
  return budgets?.find(budget => budget.period.slice(0, 10) === period) ?? null;
}
