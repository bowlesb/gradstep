import React, { useMemo, useRef, useState } from 'react';
import { Shell } from './shell';
import { Spending, type SpendingApi, type SpendingDetail, type SpendingOperation, type SpendingSummary } from './spending';
import type { SpendingObservationRequest, SpendingObservationReceipt } from '../../../supabase/functions/_shared/spending-observations.ts';

// Imported only in Vite development mode. Values are synthetic, never hosted financial records.
const ACCOUNT_A = '11000000-0000-4000-8000-000000000001';
const ACCOUNT_B = '22000000-0000-4000-8000-000000000002';
const stamp = '2026-10-07T20:00:00Z';
const operations: SpendingOperation[] = [
  { id: '34000001-0000-4000-8000-000000000001', account_id: ACCOUNT_A, kind: 'chat', state: 'settled', created_at: stamp,
    settled_at: stamp, credit_ceiling: 50, actual_credits: 0, spend_ceiling_microusd: 250_000, settled_microusd: 0,
    provider_liability_microusd: 250_000, attempt_accounting: true, attempts: 2, current_provider_microusd: 0 },
  { id: '34000002-0000-4000-8000-000000000002', account_id: ACCOUNT_B, kind: 'ocr', state: 'settled', created_at: stamp,
    settled_at: stamp, credit_ceiling: 80, actual_credits: 27, spend_ceiling_microusd: 400_000, settled_microusd: 135_000,
    provider_liability_microusd: 0, attempt_accounting: true, attempts: 1, current_provider_microusd: 135_000 },
  { id: '34000003-0000-4000-8000-000000000003', account_id: ACCOUNT_A, kind: 'metadata', state: 'settled', created_at: stamp,
    settled_at: stamp, credit_ceiling: 0, actual_credits: 0, spend_ceiling_microusd: 40_000, settled_microusd: 4_000,
    provider_liability_microusd: 0, attempt_accounting: true, attempts: 1, current_provider_microusd: 4_000 },
];
const oldUnknown: SpendingOperation = { ...operations[0], id: '34000004-0000-4000-8000-000000000004',
  kind: 'metadata', created_at: '2026-01-01T00:00:00Z', spend_ceiling_microusd: 0, provider_liability_microusd: 0, attempts: 1 };

function summary(account: string | null, empty: boolean): SpendingSummary {
  return {
    since: '2026-09-07T00:00:00Z', generated_at: stamp, account_id: account, coverage_started_at: stamp, budget: null,
    attempts: { total: empty ? 0 : 4, admitted: 0, unknown: empty ? 0 : 1, denied: 0,
      reported_microusd: empty ? 0 : 139_000, estimated_microusd: 0, held_microusd: empty ? 0 : 250_000 },
    unresolved: { total: empty ? 0 : 2, held_microusd: empty ? 0 : 250_000, aged_over_hour: empty ? 0 : 2, oldest_at: empty ? null : oldUnknown.created_at },
    providers: empty ? [] : [
      { provider: 'anthropic', model: 'claude-sonnet-5-5', route: 'chat', attempts: 2, reported_microusd: 0,
        estimated_microusd: 0, held_microusd: 250_000, prepaid_used: 0, prepaid_held: 0 },
      { provider: 'mathpix', model: 'pdf', route: 'ocr', attempts: 1, reported_microusd: 135_000,
        estimated_microusd: 0, held_microusd: 0, prepaid_used: 0, prepaid_held: 0 },
      { provider: 'anthropic', model: 'claude-haiku-4-5-20251001', route: 'catalog_tags', attempts: 1, reported_microusd: 4_000,
        estimated_microusd: 0, held_microusd: 0, prepaid_used: 0, prepaid_held: 0 },
    ], provider_group_limit: 100,
    customers: { settled_credits: empty ? 0 : account === ACCOUNT_A ? 11 : account === ACCOUNT_B ? 22 : 27, platform_funded_operations: 1, held_credits: 0 },
    legacy: { usage_records: empty ? 0 : 42, estimated_microusd: empty ? 0 : 925_000, reconciliation_microusd: 0 }, allowances: [],
    forecast: { period: '2026-10-01', operating_limit_microusd: 100_000_000, provider_allocation_microusd: 25_000_000,
      overhead_allocation_microusd: 10_000_000, funded_plan_microusd: 35_000_000, complete: false, missing_components: 7,
      components: [{ id: 'tavily_subscription', label: 'Tavily subscription', observation_id: 'synthetic-observation', measure: 'commitment',
        amount_microusd: 10_000_000, complete: true, observed_at: stamp, source: 'fixture', evidence_reference: 'sample-plan-2026-10' },
        { id: 'cloud_run', label: 'Cloud Run', observation_id: null, measure: null, amount_microusd: null, complete: null,
          observed_at: null, source: null, evidence_reference: null }] },
    external_observations: [], anomalies: { budget_paused: false, budget_eighty_percent: false, forecast_incomplete: true,
      funded_plan_over_budget: false, tavily_unverified: true, native_search_gated: true, attempt_capacity_eighty_percent: false },
  };
}

export function SpendingFixture() {
  const [reloads, setReloads] = useState(0);
  const recorded = useRef<SpendingObservationRequest[]>([]);
  const state = new URLSearchParams(location.search).get('state');
  const api = useMemo<SpendingApi>(() => {
    const delay = <T,>(value: T, account?: string | null) => new Promise<T>(resolve => setTimeout(() => resolve(value), account === ACCOUNT_A ? 500 : 40));
    return {
      record: async (_ownerID, observation) => {
        // The loopback browser check intercepts this synthetic endpoint, retaining its fake ledger across a reload.
        const response = await fetch('/__fixture-spending-entry', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(observation) })
          .catch(() => { throw new Error('The observation was not confirmed. Retry the same entry; it will not be added twice.'); });
        if (!response.ok) throw new Error('This entry conflicts with its recorded receipt.');
        const receipt = await response.json() as SpendingObservationReceipt;
        if (!recorded.current.some(row => row.request_id === observation.request_id)) recorded.current.push(observation);
        return receipt;
      },
      summary: (_days, account) => {
        if (state === 'error') return Promise.reject(new Error('Spending records could not be loaded.'));
        const value = summary(account, state === 'empty');
        value.external_observations = recorded.current.map(row => ({ ...row, id: row.request_id, source: 'owner-entry', units: {} })).reverse();
        for (const row of recorded.current) if (row.period === value.forecast.period && ['commitment', 'forecast'].includes(row.measure)) {
          const component = value.forecast.components.find(c => c.id === row.component);
          if (component) { value.forecast.overhead_allocation_microusd += (row.amount_microusd ?? 0) - (component.amount_microusd ?? 0);
            Object.assign(component, row, { observation_id: row.request_id, source: 'owner-entry' }); }
        }
        value.forecast.funded_plan_microusd = 25_000_000 + value.forecast.overhead_allocation_microusd;
        return delay(value, account);
      },
      operations: (_days, account, cursor, unresolved) => {
        const candidates = state === 'empty' ? [] : (unresolved ? [operations[0], oldUnknown] : operations).filter(row => !account || row.account_id === account);
        const start = cursor ? candidates.findIndex(row => row.id === cursor.id) + 1 : 0;
        const rows = candidates.slice(start, start + 2), last = rows.at(-1);
        return delay({ operations: rows, next: start + rows.length < candidates.length && last ? { id: last.id, created_at: last.created_at, account_id: last.account_id } : null }, account);
      },
      detail: (account, id) => {
        const row = [...operations, oldUnknown].find(value => value.id === id)!;
        const detail: SpendingDetail = { operation: { ...row, actual_microusd: row.settled_microusd, period: '2026-10-01', rate_version: 'beta-credits-v1' },
          account: { id: account, closed: false, spending_suspended: false }, record_counts: { events: 3, credits: 2, adjustments: 1, legacy_usage: 0 },
          attempts: [{ id: '34000005-0000-4000-8000-000000000005', provider: 'anthropic', route: 'chat', model: 'claude-sonnet-5-5',
            state: 'unknown', provider_request_id: null, actual_microusd: null, ceiling_microusd: 250_000,
            actual_units: {}, reserved_units: { input_tokens: 10_000, output_tokens: 4_000 }, failure_code: 'transport_lost', created_at: stamp,
            pricing_snapshot: { currency: 'USD', input_microusd_per_million: 3_000_000 } }] };
        return delay(detail);
      },
      records: (_account, _id, kind, cursor) => delay({ kind,
        records: kind === 'legacy_usage' ? [] : [{ at: stamp, key: `${kind}-${cursor ? 2 : 1}`,
          entry: kind === 'credits' ? { kind: 'refund', credits: 50 } : kind === 'adjustments' ? { kind: 'reconciliation', provider_microusd: 0, reason: 'verified_vendor_statement' } : { state: cursor ? 'admitted' : 'unknown', failure_code: 'transport_lost' } }],
        next: kind === 'events' && !cursor ? { at: stamp, id: '34000006-0000-4000-8000-000000000006' } : null }),
    };
  }, [state]);
  return <Shell tabs={['Overview', 'Spending', 'Processing', 'Reliability', 'Accounts', 'Support']} tab="Spending"
    onTab={() => undefined} email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Spending ownerID={ACCOUNT_A} api={api} reloadKey={reloads} />
  </Shell>;
}
