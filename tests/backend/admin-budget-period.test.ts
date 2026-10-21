import test from 'node:test';
import assert from 'node:assert/strict';
import { currentBudget, currentPeriod } from '../../apps/admin/src/budget-period.ts';

const row = (period: string, work_enabled = true, spent_microusd = 0) => ({ period, limit_microusd: 50_000_000, spent_microusd, reserved_microusd: 0, work_enabled });

test('A3: Overview and Health read this UTC month, not the next month listed first', () => {
  // v1_admin_overview sorts newest first and next month's row exists ahead of time (migration 060).
  const budgets = [row('2026-11-01', true, 0), row('2026-10-01', false, 12_340_000), row('2026-09-01')];
  assert.equal(currentBudget(budgets, new Date('2026-10-21T08:00:00Z'))?.period, '2026-10-01');
  assert.equal(currentBudget(budgets, new Date('2026-10-21T08:00:00Z'))?.work_enabled, false, 'a paused month shows as paused');
  // UTC, not the operator's local evening: 23:30 on Oct 31 in Los Angeles is already November in UTC.
  assert.equal(currentPeriod(new Date('2026-11-01T06:30:00Z')), '2026-11-01');
  assert.equal(currentPeriod(new Date('2026-10-31T23:59:59Z')), '2026-10-01');
  assert.equal(currentBudget([row('2026-11-01')], new Date('2026-10-21T00:00:00Z')), null, 'a missing month is not replaced by another');
  assert.equal(currentBudget(null), null);
});
