import React, { useCallback, useMemo, useRef, useState } from 'react';
import type { Budget, Health as HealthData, PipelineMetrics, ProviderHour } from './backend';
import { ProviderHours } from './provider-hours';
import { Health } from './health';
import { Accounts, type AccountList, type AccountsApi, type AdminAccount, type AccountSort } from './accounts';
import { Reliability } from './reliability';
import { Shell } from './shell';
import { Purchases, type PurchasesApi, type PurchaseSubmission, type PurchaseTransaction } from './purchases';
import { Costs, type AccountCost, type AccountCosts, type CostWindow } from './costs';
import { SpendVsIncome, type SpendAlert, type SpendIncome, type SpendIncomeApi, type SwitchName } from './spend-income';

// Development-only sample data for screenshots: `?fixture=reliability` (add `&state=empty`
// for empty states) and `?fixture=accounts`. main.tsx loads this module only when import.meta.env.DEV is true,
// so production builds contain neither the data nor the entry point.

const DAY = 86_400_000;
type Failure = { cause: string; stage: string };
// Days ago → failed imports. Day 12 is the render loop broken by three crashes.
const FAILURES: Record<number, Failure[]> = {
  2: [{ cause: 'download_failed', stage: 'download' }],
  5: [{ cause: 'conversion_failed', stage: 'render' }, { cause: 'too_large', stage: 'download' }],
  12: [{ cause: 'conversion_failed', stage: 'render' }],
  13: [{ cause: 'metadata_unavailable', stage: 'metadata' }],
  21: [{ cause: 'download_failed', stage: 'download' }],
  26: [{ cause: 'pdf_invalid', stage: 'download' }],
  41: [{ cause: 'insufficient_credits', stage: 'ocr_fund' }],
  55: [{ cause: 'download_failed', stage: 'download' }, { cause: 'rate_limited', stage: 'ocr_submit' }],
  70: [{ cause: 'metadata_unavailable', stage: 'metadata' }],
};
const CRASHES: Record<number, string[]> = { 0: ['render', 'render'], 3: ['download'], 12: ['render', 'render', 'render'], 24: ['ocr_wait'], 48: ['download'] };
const SOURCES = ['2610.03771', '2609.11402', '2610.00918', '2608.07733', '2609.15210', '2607.02264', 'openalex:W4391205522', '2609.04187', '2610.01559', '2606.18820', '2605.09931', '2608.13306'];

function random(seed: number) {
  let state = seed;
  return () => { state = (state + 0x6d2b79f5) | 0; let t = Math.imul(state ^ (state >>> 15), 1 | state); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

export function fixtureMetrics(days: number, now = new Date()): PipelineMetrics {
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const since = today - (days - 1) * DAY;
  const daily: PipelineMetrics['daily'] = [];
  const causes: Record<string, number> = {}, crashes: Record<string, number> = {}, stageFailures: Record<string, number> = {};
  const recent: PipelineMetrics['recent_failures'] = [];
  let finished = 0, readyTotal = 0, sourceIndex = 0;
  const stamp = (t: number, r: () => number) => new Date(Math.min(now.getTime() - 60_000, t + (7 + r() * 14) * 3_600_000)).toISOString();
  const source = () => SOURCES[sourceIndex++ % SOURCES.length];

  for (let i = 0; i < days; i++) {
    const t = since + i * DAY, ago = Math.round((today - t) / DAY), r = random(Math.floor(t / DAY));
    // Today's crashes belong to the stuck paper; a day's crashes and its first failure share a paper.
    const crashed = ago === 0 ? '2610.02287' : source(), base = stamp(t, r);
    (CRASHES[ago] ?? []).forEach((stage, k) => {
      crashes[stage] = (crashes[stage] ?? 0) + 1;
      const at = ago === 0 ? new Date(now.getTime() - (34 - 9 * k) * 60_000).toISOString() : new Date(Date.parse(base) - (40 - 12 * k) * 60_000).toISOString();
      recent.push({ at, kind: 'crash', source: crashed, stage, error_code: null, private: false });
    });
    if (ago >= 17 && ago <= 19) continue; // A quiet stretch with no imports at all.
    const failures = FAILURES[ago] ?? [];
    for (const [k, f] of failures.entries()) {
      causes[f.cause] = (causes[f.cause] ?? 0) + 1; stageFailures[f.stage] = (stageFailures[f.stage] ?? 0) + 1;
      const at = k ? stamp(t, r) : base, paper = k ? source() : crashed, privateCopy = r() < 0.25;
      recent.push({ at, kind: 'import', source: paper, stage: 'failed', error_code: f.cause, private: null });
      recent.push({ at, kind: 'stage', source: paper, stage: f.stage, error_code: f.cause, private: privateCopy });
    }
    if (ago === 9) { daily.push({ day: new Date(t).toISOString().slice(0, 10), started: 2, ready: 0, failed: 0, cancelled: 1, ready_p50_s: null, ready_p90_s: null }); continue; }
    const started = 4 + Math.floor(r() * 8) + (ago < 10 ? 4 : 0);
    const cancelled = r() < 0.18 ? 1 : 0;
    const ready = Math.max(1, started - failures.length - cancelled - (r() < 0.3 ? 1 : 0));
    const p50 = Math.round((66 + r() * 38 + (ago < 7 ? -8 : 0)) * 10) / 10;
    const p90 = ago === 12 ? 694.2 : ago === 5 ? 402.6 : Math.round(p50 * (1.6 + r() * 0.9) * 10) / 10;
    daily.push({ day: new Date(t).toISOString().slice(0, 10), started, ready, failed: failures.length, cancelled, ready_p50_s: p50, ready_p90_s: p90 });
    finished += ready + failures.length; readyTotal += ready;
  }

  const stage = (name: string, share: number, p50: number, p90: number) => ({ stage: name, count: Math.round(finished * share), p50_s: p50, p90_s: p90, failed: stageFailures[name] ?? 0 });
  return {
    since: new Date(since).toISOString().replace('.000Z', '+00:00'), generated_at: now.toISOString(),
    daily,
    stages: finished ? [
      stage('download', 0.97, 2.6, 9.8), stage('metadata', 1.02, 0.8, 2.1), stage('ocr_fund', 0.95, 0.3, 0.9),
      stage('ocr_submit', 0.95, 1.9, 4.2), stage('ocr_wait', 0.95, 64.2, 171.5), stage('private_split', 0.14, 1.2, 3.4),
      { stage: 'render', count: readyTotal + (stageFailures.render ?? 0) + 3, p50_s: 4.8, p90_s: 14.6, failed: stageFailures.render ?? 0 },
    ] : [],
    crashes, failure_causes: causes,
    recent_failures: recent.sort((a, b) => b.at.localeCompare(a.at)).slice(0, 25),
    stuck: days >= 1 ? [{ id: 'fixture-stuck', source: '2610.02287v1', private: false, stage: 'render', since: new Date(now.getTime() - 47 * 60_000).toISOString(), minutes: 47, claims: 3, crashes: 2, leased: false }] : [],
  };
}

function emptyMetrics(days: number, now = new Date()): PipelineMetrics {
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return { since: new Date(today - (days - 1) * DAY).toISOString(), generated_at: now.toISOString(), daily: [], stages: [], crashes: {}, failure_causes: {}, recent_failures: [], stuck: [] };
}

export function ReliabilityFixture() {
  const [reloads, setReloads] = useState(0);
  const empty = new URLSearchParams(location.search).get('state') === 'empty';
  const load = useCallback((days: number) => new Promise<PipelineMetrics>(resolve => setTimeout(() => resolve(empty ? emptyMetrics(days) : fixtureMetrics(days)), 120)), [empty]);
  const loadHours = useCallback(() => new Promise<ProviderHour[]>(resolve => setTimeout(() => resolve(providerHoursFixture(empty)), 120)), [empty]);
  return <Shell tabs={['Overview', 'Spending', 'Processing', 'Reliability', 'Accounts', 'Support']} tab="Reliability" onTab={() => undefined} counts={{ Support: 2 }}
    email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Reliability load={load} reloadKey={reloads} />
    <ProviderHours load={loadHours} reloadKey={reloads} />
  </Shell>;
}

/** Reliability's hourly provider table (RESILIENCE.md): two days of OpenRouter (every model call) and Tavily, search
 * throttled in the newest hours. */
function providerHoursFixture(empty: boolean): ProviderHour[] {
  if (empty) return [];
  const now = Date.now(), rows: ProviderHour[] = [];
  for (let h = 0; h < 48; h++) {
    const hour = new Date(Math.floor(now / 3_600_000 - h) * 3_600_000).toISOString();
    const busy = h < 2;
    rows.push({ hour, provider: 'openrouter', calls: 380 - h * 3, ok: 376 - h * 3, throttled: 2, failed: h === 30 ? 24 : 2, rejected: 0, breaker_open: 0,
      latency_ms_avg: 2_300, latency_ms_max: 41_000, retry_after_max_s: h === 30 ? 20 : null });
    rows.push({ hour, provider: 'tavily', calls: 31, ok: busy ? 18 : 31, throttled: busy ? 7 : 0, failed: 0, rejected: 0, breaker_open: busy ? 6 : 0,
      latency_ms_avg: 1_900, latency_ms_max: 15_000, retry_after_max_s: busy ? 60 : null });
  }
  return rows;
}

export function PurchasesFixture() {
  const [reloads, setReloads] = useState(0);
  const scenario = new URLSearchParams(location.search).get('state');
  const api = useMemo<PurchasesApi>(() => {
    const now = new Date().toISOString();
    const account = '38000000-0000-0000-0000-000000000001';
    const otherAccount = '38000000-0000-0000-0000-000000000002';
    const rows: PurchaseSubmission[] = scenario === 'empty' ? [] : [
      { account_id: account, reference: '38'.repeat(32), first_at: now, last_at: now, finished_at: now, attempts: 3,
        state: 'pending', outcome: 'verification_unavailable', stage: 'revocation', apple_status: 'retryable_verification_failure', transport_code: 'timeout' },
      { account_id: account, reference: '39'.repeat(32), first_at: now, last_at: now, finished_at: null, attempts: 1,
        state: 'interrupted', outcome: 'started', stage: null, apple_status: null, transport_code: null },
      { account_id: account, reference: '40'.repeat(32), first_at: now, last_at: now, finished_at: now, attempts: 1,
        state: 'refused', outcome: 'invalid', stage: 'certificate_chain', apple_status: 'invalid_certificate', transport_code: null },
      { account_id: account, reference: '41'.repeat(32), first_at: now, last_at: now, finished_at: now, attempts: 1,
        state: 'confirmed', outcome: 'recorded', stage: null, apple_status: null, transport_code: null },
      { account_id: otherAccount, reference: '42'.repeat(32), first_at: now, last_at: now, finished_at: now, attempts: 1,
        state: 'confirmed', outcome: 'already_recorded', stage: null, apple_status: null, transport_code: null },
    ];
    const previous = new Date(Date.now() - 86_400_000).toISOString();
    const period = now.slice(0, 7) + '-01';
    const transaction = (id: string, extra: Partial<PurchaseTransaction> = {}): PurchaseTransaction => ({
      environment: 'Sandbox', transaction_id: id, original_transaction_id: id, product_id: 'com.sciencereader.ios.credits.400',
      quantity: 1, purchased_at: now, recorded_at: now, granted_at: now, expires_at: null, revoked_at: null,
      credits: { granted: 400, balance: 400, reserved: 0, spendable: 400, state: 'active', starts_at: now, expires_at: null, revoked_at: null },
      sandbox_decision: null, ...extra,
    });
    const rowsOfCredits = [
      transaction('91006', { granted_at: null,
        credits: { granted: 0, balance: 0, reserved: 0, spendable: 0, state: 'no_grant', starts_at: null, expires_at: null, revoked_at: null },
        sandbox_decision: { recorded_at: now, period, requested_credits: 400, granted_credits: 0, credit_cap: 1000, reason: 'both_allowances_exhausted' } }),
      transaction('91005', {
        credits: { granted: 200, balance: 160, reserved: 20, spendable: 140, state: 'active', starts_at: now, expires_at: null, revoked_at: null },
        sandbox_decision: { recorded_at: now, period, requested_credits: 400, granted_credits: 200, credit_cap: 1000, reason: 'partial_allowance' } }),
      transaction('91004', { environment: 'Production', revoked_at: now,
        credits: { granted: 400, balance: 40, reserved: 40, spendable: 0, state: 'revoked', starts_at: previous, expires_at: null, revoked_at: now } }),
      transaction('91003', { environment: 'Production', product_id: 'com.sciencereader.ios.standard.monthly', expires_at: previous,
        credits: { granted: 800, balance: 600, reserved: 20, spendable: 0, state: 'expired', starts_at: previous, expires_at: previous, revoked_at: null } }),
      transaction('91002', { environment: 'Production',
        credits: { granted: 400, balance: 0, reserved: 0, spendable: 0, state: 'spent', starts_at: previous, expires_at: null, revoked_at: null } }),
      transaction('91001', { granted_at: null,
        credits: { granted: 0, balance: 0, reserved: 0, spendable: 0, state: 'no_grant', starts_at: null, expires_at: null, revoked_at: null } }),
    ];
    let ledgerFailureAcknowledged = false;
    return {
      async list(filter, reference) {
        if (scenario === 'error') throw Error('synthetic_failure');
        const matched = rows.filter(row => (!reference || row.reference.startsWith(reference)) &&
          (filter === 'all' || row.state === filter || (filter === 'unconfirmed' && ['pending', 'interrupted', 'verifying'].includes(row.state))));
        return { generated_at: now, matched: matched.length, counts: { pending: 1, interrupted: 1, refused: 1, confirmed: 2 }, submissions: matched,
          readiness: { retained: 5, policy: { retention_days: 30, account_rows: 2048, environment_rows: 50000 },
            cleanup: { active: scenario !== 'cleanup', expected_command: true, schedule: '17 * * * *' } } };
      },
      async transactions(accountID, cursor) {
        // All overlapping initial reads fail together, including Strict Mode's
        // extra development effect. A deliberate retry receives fresh data.
        const failThisRead = scenario === 'ledger_retry' && !ledgerFailureAcknowledged;
        const delay = (scenario === 'ledger_race' && accountID === account) || (scenario === 'older_race' && cursor) ? 750 : 25;
        await new Promise(resolve => setTimeout(resolve, delay));
        if (scenario === 'ledger_error' || failThisRead) { ledgerFailureAcknowledged = true; throw Error('synthetic_ledger_failure'); }
        if (cursor && cursor.account_id !== accountID) throw Error('synthetic_invalid_cursor');
        const transactions = scenario === 'ledger_empty' ? [] : accountID === otherAccount
          ? [transaction('92001', { environment: 'Production' })] : rowsOfCredits.slice(cursor ? 3 : 0, cursor ? 6 : 3);
        return { account_id: scenario === 'ledger_wrong_account' ? otherAccount : accountID, generated_at: now, transactions,
          next_cursor: scenario !== 'ledger_empty' && accountID === account && !cursor
            ? { version: 1, account_id: accountID, recorded_at: now, environment: 'Production', transaction_id: '91004' } : null };
      },
      async attempts(_account, reference) {
        const submission = rows.find(row => row.reference === reference);
        return Array.from({ length: submission?.attempts ?? 0 }, (_, n) => ({
          id: `fixture-attempt-${n}`, admitted_at: now, finished_at: submission?.finished_at ?? null, outcome: submission?.outcome ?? 'started',
          stage: submission?.stage ?? null, apple_status: submission?.apple_status ?? null, transport_code: submission?.transport_code ?? null,
        }));
      },
    };
  }, [scenario]);
  return <Shell tabs={['Overview', 'Spending', 'Processing', 'Reliability', 'Accounts', 'Purchases', 'Support']} tab="Purchases" onTab={() => undefined}
    email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Purchases api={api} reloadKey={reloads} />
  </Shell>;
}

// ── Accounts (`?fixture=accounts`) ── example addresses only; changes stay in memory.
const ago = (days: number, hours = 0) => new Date(Date.now() - (days * 24 + hours) * 3_600_000).toISOString();
const person = (id: number, email: string | null, created: number, last: number | null, extra: Partial<AdminAccount> = {}): AdminAccount => ({
  id: `31000000-0000-4000-8000-${String(id).padStart(12, '0')}`, email, synthetic: !!email?.endsWith('@example.invalid'), created_at: ago(created),
  last_sign_in_at: last === null ? null : ago(last, 3), providers: ['email'], status: 'active', roles: [], plan: null,
  credits: { available: 0, reserved: 0 }, library_items: 0, ...extra });
const ACCOUNTS: AdminAccount[] = [
  person(1, 'owner@example.com', 34, 0, { roles: ['owner'], providers: ['email', 'apple'], credits: { available: 1412, reserved: 40 }, library_items: 46,
    plan: { plan: 'pro', environment: 'Sandbox', expires_at: ago(-21) } }),
  person(2, 'mira.okafor@example.org', 6, 0, { providers: ['email', 'google'], credits: { available: 873, reserved: 0 }, library_items: 18 }),
  person(3, 'j.lindqvist@example.net', 6, 2, { providers: ['apple'], credits: { available: 1000, reserved: 0 }, library_items: 3 }),
  person(4, 'priya.raman@example.org', 5, null, { credits: { available: 1000, reserved: 0 } }),
  person(5, 'tomas.ferreira@example.net', 12, 9, { status: 'disabled', credits: { available: 212, reserved: 0 }, library_items: 7 }),
  person(6, 'gradstep-check-import-8f0c1e2a@example.invalid', 0, 0, { credits: { available: 300, reserved: 27 }, library_items: 1 }),
  person(7, 'gradstep-check-chat-41b9d7c3@example.invalid', 0, 0, { credits: { available: 189, reserved: 0 } }),
  person(8, 'science-reader-journey-5a2e@example.invalid', 3, 3, { credits: { available: 74, reserved: 0 }, library_items: 2 }),
  person(9, 'leaving@example.org', 20, 4, { status: 'closing', credits: { available: 0, reserved: 0 } }),
  person(10, null, 27, null, { status: 'closed', providers: [] }),
];

export function AccountsFixture() {
  const [reloads, setReloads] = useState(0);
  const empty = new URLSearchParams(location.search).get('state') === 'empty';
  const [accounts, setAccounts] = useState(empty ? [] : ACCOUNTS);
  const wait = <T,>(value: T) => new Promise<T>(resolve => setTimeout(() => resolve(value), 150));
  const api = useMemo<AccountsApi>(() => ({
    list: (search: string, sort: AccountSort, ascending: boolean) => {
      const key = (a: AdminAccount) => (sort === 'created' ? a.created_at : a.last_sign_in_at);
      const matched = accounts.filter(a => !search || (a.email ?? '').includes(search.toLowerCase())).sort((a, b) => {
        const x = key(a), y = key(b);
        if (!x || !y) return x === y ? 0 : x ? -1 : 1; // never signed in: last either way
        return ascending ? x.localeCompare(y) : y.localeCompare(x);
      });
      return wait<AccountList>({ generated_at: new Date().toISOString(), total: accounts.length, matched: matched.length, accounts: matched });
    },
    addTester: (email: string, credits: number) => {
      const existing = accounts.find(a => a.email === email.toLowerCase());
      if (existing) return wait({ account_id: existing.id, email, created: false, status: existing.status, starting_credits: 0, starting_granted: false });
      const added = person(100 + accounts.length, email.toLowerCase(), 0, null, { credits: { available: credits, reserved: 0 } });
      setAccounts(list => [added, ...list]);
      return wait({ account_id: added.id, email: added.email!, created: true, status: 'active' as const, starting_credits: credits, starting_granted: credits > 0 });
    },
    grant: (id: string, credits: number) => {
      setAccounts(list => list.map(a => a.id === id ? { ...a, credits: { ...a.credits, available: a.credits.available + credits } } : a));
      return wait({ credits, replayed: false });
    },
    setSignIn: (id: string, disabled: boolean) => {
      setAccounts(list => list.map(a => a.id === id ? { ...a, status: disabled ? 'disabled' as const : 'active' as const } : a));
      return wait({ disabled });
    },
    revokeAdmission: (email: string) => wait({ existing_login: accounts.some(a => a.email === email.toLowerCase() && a.status !== 'closed') }),
  }), [accounts]);
  return <Shell tabs={['Overview', 'Spending', 'Processing', 'Reliability', 'Accounts', 'Support']} tab="Accounts" onTab={() => undefined} counts={{ Support: 2 }}
    email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Accounts api={api} reloadKey={reloads} />
  </Shell>;
}

// `?fixture=health`: a service growing from about 100 to 1,000 accounts over 90 days (`&state=empty` for a new
// service, `&state=quiet` for nothing needing attention). Deterministic, so screenshots compare.
function healthFixture(days: number, state: string | null): HealthData {
  const now = new Date(); const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const monthStart = iso(new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1)));
  let seed = 7; const rand = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
  const empty = state === 'empty', quiet = state === 'quiet';
  const all = Array.from({ length: 120 }, (_, k) => { // 120 days so 7-day windows have history
    const i = 119 - k, day = new Date(today.getTime() - i * DAY); const t = (120 - i) / 120;
    const weekend = [0, 6].includes(day.getUTCDay()) ? 0.72 : 1;
    const base = empty ? 0 : quiet ? 40 + 60 * t : 100 + 900 * t * t;
    const signups = empty ? 0 : Math.round((4 + 22 * t) * weekend * (0.7 + 0.6 * rand()) + (i === 9 ? 60 : 0));
    const active = Math.round(base * 0.31 * weekend * (0.85 + 0.3 * rand()));
    const papers = Math.round(active * 0.9 * (0.8 + 0.4 * rand()));
    const chats = Math.round(active * 2.4 * (0.75 + 0.5 * rand()));
    const podcasts = Math.round(active * 0.05 * (0.6 + 0.8 * rand()));
    const failedPapers = quiet ? Math.round(papers * 0.01) : i === 3 ? Math.round(papers * 0.18) : Math.round(papers * 0.02 * rand());
    const failedPodcasts = quiet ? 0 : Math.round(podcasts * 0.12 * rand());
    // Staging rates: a chat answer about 2.5¢ with the paper cached, an episode about 11¢ (script, review and voices, all
    // through OpenRouter), a web search 0.8¢ list value on 6% of answers (prepaid).
    const openrouter = chats * 25_000 + podcasts * 114_000, tavily = chats * 0.06 * 8_000;
    return { day: iso(day), signups, active, papers, chats, chatting: Math.round(active * 0.6), podcasts, failedPapers, failedPodcasts,
      reports: !quiet && (i === 2 || i === 11) ? 1 : 0, by_provider: { openrouter, tavily: Math.round(tavily) } };
  });
  const sum = (rows: typeof all, f: (r: typeof all[number]) => number) => rows.reduce((n, r) => n + f(r), 0);
  const window = all.slice(-days), last7 = all.slice(-7), last30 = all.slice(-30);
  const cost = (r: typeof all[number]) => Object.values(r.by_provider).reduce((a, b) => a + b, 0);
  const month = all.filter(r => r.day >= monthStart);
  const providerTotals = (rows: typeof all) => rows.reduce<Record<string, number>>((acc, r) => { for (const [k, v] of Object.entries(r.by_provider)) acc[k] = (acc[k] ?? 0) + v; return acc; }, {});
  const accounts = empty ? 0 : 100 + sum(all, r => r.signups);
  return {
    generated_at: now.toISOString(), since: window[0].day, today: iso(today), days, month_start: monthStart,
    people: { accounts, new_in_window: sum(window, r => r.signups), active_7d: empty ? 0 : Math.round(sum(last7, r => r.active) * 0.42),
      active_30d: empty ? 0 : Math.round(sum(last30, r => r.active) * 0.17), returning_7d: empty ? 0 : Math.round(sum(last7, r => r.active) * 0.33),
      daily: window.map((r, k) => ({ day: r.day, new: r.signups, active: r.active, active_7d: Math.round(sum(all.slice(all.length - days + k - 6, all.length - days + k + 1), x => x.active) * 0.42) })) },
    use: { papers_added: sum(window, r => r.papers), chat_answers: sum(window, r => r.chats), chatting_accounts: empty ? 0 : Math.round(accounts * 0.38), podcasts_started: sum(window, r => r.podcasts),
      daily: window.map(r => ({ day: r.day, papers: r.papers, chats: r.chats, chatting: r.chatting, podcasts: r.podcasts })) },
    reliability: { papers_failed: sum(window, r => r.failedPapers), paper_failure_codes: empty ? {} : { metadata_unavailable: Math.round(sum(window, r => r.failedPapers) * 0.7), provider_unavailable: Math.round(sum(window, r => r.failedPapers) * 0.3) },
      chats_unsettled: empty ? 0 : 3, podcasts_ready: sum(window, r => r.podcasts - r.failedPodcasts), podcasts_failed: sum(window, r => r.failedPodcasts),
      podcast_failure_codes: quiet || empty ? {} : { script_evidence_rejected: Math.ceil(sum(window, r => r.failedPodcasts) * 0.6), provider_unavailable: Math.floor(sum(window, r => r.failedPodcasts) * 0.4) },
      reports_open: sum(window, r => r.reports), daily: window.map(r => ({ day: r.day, papers_failed: r.failedPapers, podcasts_failed: r.failedPodcasts, reports: r.reports })) },
    money: { month_to_date_microusd: Math.round(sum(month, cost)), window_microusd: Math.round(sum(window, cost)), by_provider: providerTotals(window),
      credits_consumed: sum(window, r => r.chats * 5 + r.podcasts * 40), credits_granted: sum(window, r => r.signups * 500),
      chat_cache: empty ? { read_tokens: 0, write_tokens: 0, input_tokens: 0 } : { read_tokens: 61_000_000, write_tokens: 19_000_000, input_tokens: 8_000_000 },
      daily: window.map(r => ({ day: r.day, microusd: Math.round(cost(r)), by_provider: r.by_provider, credits_consumed: r.chats * 5 + r.podcasts * 40 })) },
    // Outside providers (RESILIENCE.md): a steady trickle of throttling, one bad OpenRouter day, and (unless quiet)
    // OpenRouter's podcast voices throttled in the last hour with their scoped breaker open.
    providers: {
      daily: window.map((r, k) => ({ day: r.day, by_provider: empty ? {} as Record<string, never> : {
        openrouter: { calls: r.chats * 3 + r.podcasts * 4, failed: quiet ? 0 : Math.round(r.chats * (k === window.length - 4 ? 0.06 : 0.004)), throttled: quiet || k < window.length - 1 ? 0 : Math.round(r.podcasts * 0.4), breaker_open: quiet || k < window.length - 1 ? 0 : 6 },
        tavily: { calls: Math.round(r.chats * 0.06), failed: 0, throttled: 0, breaker_open: 0 },
        crossref: { calls: Math.round(r.papers * 0.2), failed: quiet ? 0 : Math.round(r.papers * 0.002), throttled: 0, breaker_open: 0 } } })),
      last_hour: empty ? [] : [
        { provider: 'openrouter', calls: 443, failed: quiet ? 0 : 3, throttled: quiet ? 0 : 9, breaker_open: quiet ? 0 : 6, latency_ms_avg: 2_400 },
        { provider: 'crossref', calls: 38, failed: 0, throttled: 0, breaker_open: 0, latency_ms_avg: 310 },
        { provider: 'tavily', calls: quiet ? 4 : 11, failed: 0, throttled: 0, breaker_open: 0, latency_ms_avg: 1_900 }],
      breakers: quiet || empty ? [] : [{ provider: 'openrouter', scope: 'podcast_speech', state: 'open', reopen_at: new Date(Date.now() + 120_000).toISOString() }],
    },
    // Migration 079: one chat answer over its ceiling today (recorded, not paused), and one account with many unpaid
    // early endings (unless quiet); about 3 % of answers end early, Gradstep paying for them.
    anomalies: { pause_after: 5, window_minutes: 60, in_window: quiet || empty ? 0 : 1, last_24h: quiet || empty ? 0 : 1, last_24h_test: 0,
      recent: quiet || empty ? [] : [{ at: new Date(Date.now() - 40 * 60_000).toISOString(), kind: 'operation_over_ceiling', operation_kind: 'chat',
        ceiling_microusd: 242, observed_microusd: 271, paused_month: false, test_account: false }] },
    early_endings: { attention_daily: 20, answers: sum(window, r => r.chats), uncharged: Math.round(sum(window, r => r.chats) * 0.03),
      absorbed_microusd: Math.round(sum(window, r => r.chats) * 0.03 * 12_000),
      by_ending: empty ? {} : { completed: Math.round(sum(window, r => r.chats) * 0.95), stopped: Math.round(sum(window, r => r.chats) * 0.02),
        provider: Math.round(sum(window, r => r.chats) * 0.015), limit: Math.round(sum(window, r => r.chats) * 0.01), connection: Math.round(sum(window, r => r.chats) * 0.005) },
      today: { uncharged: empty ? 0 : 31, absorbed_microusd: empty ? 0 : 380_000 },
      accounts_over_today: quiet || empty ? [] : [{ account_id: '5f0c2a91-7d3e-4b8a-9c11-2e6f8a4b7c90', uncharged: 24, absorbed_microusd: 290_000 }] },
    // Migrations 0102/0140/0162: nothing manual; unless empty, the three 2026-10-24/25 Gemini attempts settled at $0 (no
    // output, no OpenRouter record after 12 tries) and still read daily for a late record.
    reconciliation: { automatic_pending: 0, gave_up: 0, without_generation: 0, other_providers: 0, manual_held_microusd: 0, reconciled_24h: empty ? 0 : 2,
      legacy: { attempts: 0, held_microusd: 0, oldest_at: null, by_provider: {} }, search_unresolved: 0,
      assumed_zero: { month_start: monthStart, attempts: empty ? 0 : 3, ceiling_microusd: empty ? 0 : 391_419, corrected: 0, corrected_microusd: 0,
        checking: empty ? 0 : 3, contradicted: 0 } },
    // Migration 0161: the 2026-10-25 staging day (Flash on Vertex US answering 8 of 12, slow to start; Haiku all), unless quiet.
    models: { window_hours: 24, thresholds: { min_calls: 10, success_rate: 0.9, p90_first_data_ms: 20_000 },
      models: empty ? [] : [
        { model: 'gemini-3.8-flash', calls: 12, answered: quiet ? 12 : 8, failed: quiet ? 0 : 4, other: 1, success_rate: quiet ? 1 : 0.6667, timed: quiet ? 12 : 8,
          p50_first_data_ms: 6_000, p90_first_data_ms: quiet ? 12_000 : 36_000, p90_ms: 68_900, failures: quiet ? {} : { provider_error: 4, aborted: 1 } },
        { model: 'anthropic/claude-haiku-5.5', calls: 37, answered: 37, failed: 0, other: 0, success_rate: 1, timed: 37, p50_first_data_ms: 1_300,
          p90_first_data_ms: 2_100, p90_ms: 3_500, failures: {} }],
      attention: quiet || empty ? [] : [
        { kind: 'model_slow_start', model: 'gemini-3.8-flash', timed: 8, p90_first_data_ms: 36_000 },
        { kind: 'model_success_rate', model: 'gemini-3.8-flash', calls: 12, answered: 8, success_rate: 0.6667, failures: { provider_error: 4, aborted: 1 } }] },
  };
}

export function HealthFixture() {
  const [reloads, setReloads] = useState(0);
  const [days, setDays] = useState(30);
  const state = new URLSearchParams(location.search).get('state');
  const load = useCallback((n: number) => new Promise<HealthData>(resolve => setTimeout(() => resolve(healthFixture(n, state)), 120)), [state]);
  const now = new Date();
  const budget: Budget = { period: now.toISOString().slice(0, 7) + '-01', limit_microusd: 100_000_000, spent_microusd: 41_000_000, reserved_microusd: 600_000, work_enabled: true };
  return <Shell tabs={['Health', 'Overview', 'Spending', 'Processing', 'Reliability', 'Accounts', 'Purchases', 'Support']} tab="Health" onTab={() => undefined} counts={{ Support: 2 }}
    email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Health load={load} budget={state === 'empty' ? null : budget} reloadKey={reloads} days={days} onDays={setDays} />
  </Shell>;
}

// `?fixture=costs` (`&state=empty`): the Costs tab (migration 0141) for a small beta. Amounts in micro-USD.
const costWindow = (cost: number, extra: Partial<CostWindow> = {}): CostWindow => ({ cost_microusd: cost, reported_microusd: cost - (extra.estimated_microusd ?? 0),
  estimated_microusd: 0, held_microusd: 0, attempts: Math.max(1, Math.round(cost / 6_000)), searches: 0, search_list_microusd: 0, legacy_microusd: 0, ...extra });
const costAccount = (n: number, email: string | null, month: number, d30: number, extra: Partial<AccountCost> = {}, details: Partial<CostWindow> = {}): AccountCost => {
  const id = `${(0x7c00a000 + n).toString(16)}-1f2e-4d3c-8b4a-${n.toString(16).padStart(12, '0')}`;
  const chat = Math.round(d30 * 0.62), figures = Math.round(d30 * 0.14), equations = Math.round(d30 * 0.06), podcasts = d30 - chat - figures - equations;
  return { account_id: id, email, synthetic: false, test: false, closed: false,
    month: costWindow(month, { searches: 6, search_list_microusd: 48_000, ...details, credits_charged: Math.round(month / 2_500) }),
    last_30_days: costWindow(d30, { searches: 9, search_list_microusd: 72_000, ...details, credits_charged: Math.round(d30 / 2_500) }),
    by_feature: [
      { feature: 'chat', month: costWindow(Math.round(month * 0.62), details), last_30_days: costWindow(chat, details) },
      { feature: 'figure_explainer', month: costWindow(Math.round(month * 0.14)), last_30_days: costWindow(figures) },
      { feature: 'equation_explainer', month: costWindow(Math.round(month * 0.06)), last_30_days: costWindow(equations) },
      { feature: 'podcasts', month: costWindow(month - Math.round(month * 0.82)), last_30_days: costWindow(podcasts) },
      { feature: 'search', month: costWindow(0, { attempts: 6, searches: 6, search_list_microusd: 48_000 }), last_30_days: costWindow(0, { attempts: 9, searches: 9, search_list_microusd: 72_000 }) },
    ],
    by_model: [
      { provider: 'openrouter', model: 'gemini-3.8-flash', legacy: false, month: costWindow(Math.round(month * 0.55)), last_30_days: costWindow(Math.round(d30 * 0.55)) },
      { provider: 'openrouter', model: 'anthropic/claude-sonnet-5.5', legacy: false, month: costWindow(Math.round(month * 0.3), details), last_30_days: costWindow(Math.round(d30 * 0.3), details) },
      { provider: 'openrouter', model: 'anthropic/claude-haiku-5.5', legacy: false, month: costWindow(Math.round(month * 0.15)), last_30_days: costWindow(d30 - Math.round(d30 * 0.85)) },
      { provider: 'tavily', model: 'search-basic', legacy: false, month: costWindow(0, { attempts: 6, searches: 6, search_list_microusd: 48_000 }), last_30_days: costWindow(0, { attempts: 9, searches: 9, search_list_microusd: 72_000 }) },
    ], ...extra };
};
const COST_ACCOUNTS: AccountCost[] = [
  costAccount(1, 'owner@example.com', 4_210_000, 6_870_000, {}, { held_microusd: 88_000 }),
  costAccount(2, 'alex.reader@example.org', 1_340_000, 2_115_000),
  costAccount(3, 'sam@example.edu', 612_000, 1_480_000, {}, { estimated_microusd: 21_000 }),
  costAccount(4, 'gradstep-check-chat-41b9d7c3@example.invalid', 48_000, 96_000, { synthetic: true, test: true }),
  costAccount(5, null, 0, 310_000, { closed: true }),
  { ...costAccount(6, 'early-tester@example.org', 0, 138, {}, { legacy_microusd: 138 }), by_feature: [{ feature: 'chat', month: costWindow(0, { attempts: 0 }),
    last_30_days: costWindow(138, { attempts: 1, legacy_microusd: 138 }) }], by_model: [{ provider: 'anthropic', model: 'claude-sonnet-5-5', legacy: true,
    month: costWindow(0, { attempts: 0 }), last_30_days: costWindow(138, { attempts: 1, legacy_microusd: 138 }) }] },
];
function costTotals(accounts: AccountCost[], key: 'month' | 'last_30_days'): CostWindow {
  const sum = (f: (w: CostWindow) => number) => accounts.reduce((n, a) => n + f(a[key]), 0);
  return { cost_microusd: sum(w => w.cost_microusd), reported_microusd: sum(w => w.reported_microusd), estimated_microusd: sum(w => w.estimated_microusd),
    held_microusd: sum(w => w.held_microusd), attempts: sum(w => w.attempts), searches: sum(w => w.searches), search_list_microusd: sum(w => w.search_list_microusd),
    legacy_microusd: sum(w => w.legacy_microusd), credits_charged: sum(w => w.credits_charged ?? 0) };
}
function groupBreakdown<T extends { month: CostWindow; last_30_days: CostWindow }>(rows: T[], key: (row: T) => string): T[] {
  const groups = new Map<string, T>();
  for (const row of rows) {
    const k = key(row), seen = groups.get(k);
    if (!seen) { groups.set(k, { ...row, month: { ...row.month }, last_30_days: { ...row.last_30_days } }); continue; }
    for (const w of ['month', 'last_30_days'] as const) for (const field of Object.keys(row[w]) as (keyof CostWindow)[]) {
      (seen[w][field] as number) = ((seen[w][field] as number | undefined) ?? 0) + ((row[w][field] as number | undefined) ?? 0);
    }
  }
  return [...groups.values()];
}
export function CostsFixture() {
  const [reloads, setReloads] = useState(0);
  const empty = new URLSearchParams(location.search).get('state') === 'empty';
  const api = useMemo(() => ({ load: () => new Promise<AccountCosts>(resolve => setTimeout(() => {
    const accounts = empty ? [] : COST_ACCOUNTS, now = new Date();
    resolve({ generated_at: now.toISOString(), month_start: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString(),
      since: new Date(now.getTime() - 29 * DAY).toISOString(), limit: 500, accounts_with_activity: accounts.length, truncated: false, accounts,
      totals: { month: costTotals(accounts, 'month'), last_30_days: costTotals(accounts, 'last_30_days'),
        by_feature: groupBreakdown(accounts.flatMap(a => a.by_feature), f => f.feature),
        by_model: groupBreakdown(accounts.flatMap(a => a.by_model), m => m.provider + ':' + m.model) } });
  }, 120)) }), [empty]);
  return <Shell tabs={['Health', 'Overview', 'Spending', 'Costs', 'Processing', 'Reliability', 'Accounts', 'Purchases', 'Support']} tab="Costs" onTab={() => undefined}
    counts={{ Support: 2 }} email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Costs api={api} reloadKey={reloads} />
  </Shell>;
}

// `?fixture=spend-income` (add `&state=over` for a month where spend is above the alert share of proceeds).
export function SpendIncomeFixture() {
  const [reloads, setReloads] = useState(0);
  const over = new URLSearchParams(location.search).get('state') === 'over';
  const [state, setState] = useState<SpendIncome>(() => {
    const now = new Date(), period = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}-01`;
    const at = (hours: number) => new Date(now.getTime() - hours * 3_600_000).toISOString();
    const empty = { purchases: 0, refunds: 0, gross_microusd: 0, refunded_microusd: 0, proceeds_microusd: 0, by_product: [] };
    const production = { purchases: 14, refunds: 1, gross_microusd: 117_860_000, refunded_microusd: 7_990_000, proceeds_microusd: 93_389_500, by_product: [
      { product_id: 'com.sciencereader.ios.standard.monthly', purchases: 7, gross_microusd: 47_930_000, refunds: 1, refunded_microusd: 7_990_000 },
      { product_id: 'com.sciencereader.ios.pro.monthly', purchases: 2, gross_microusd: 39_980_000, refunds: 0, refunded_microusd: 0 },
      { product_id: 'com.sciencereader.ios.credits.300', purchases: 4, gross_microusd: 19_960_000, refunds: 0, refunded_microusd: 0 },
      { product_id: 'com.sciencereader.ios.credits.700', purchases: 1, gross_microusd: 9_990_000, refunds: 0, refunded_microusd: 0 }] };
    const spend = over ? 71_400_000 : 24_180_000;
    return { period, generated_at: now.toISOString(), days_elapsed: 21.4, days_in_month: 31, email_configured: true,
      spend: { cost_microusd: spend, held_microusd: 412_000, by_funding: { paid: Math.round(spend * 0.71), free: Math.round(spend * 0.18), testing: Math.round(spend * 0.07), granted: Math.round(spend * 0.03), platform: Math.round(spend * 0.01) },
        by_feature: [{ feature: 'chat', cost_microusd: Math.round(spend * 0.52), attempts: 2140 }, { feature: 'figure_explainer', cost_microusd: Math.round(spend * 0.21), attempts: 610 },
          { feature: 'podcasts', cost_microusd: Math.round(spend * 0.16), attempts: 41 }, { feature: 'equation_explainer', cost_microusd: Math.round(spend * 0.06), attempts: 330 },
          { feature: 'recommendations', cost_microusd: Math.round(spend * 0.03), attempts: 88 }, { feature: 'tags', cost_microusd: Math.round(spend * 0.02), attempts: 240 }],
        by_model: [{ model: 'anthropic/claude-sonnet-5.5', cost_microusd: Math.round(spend * 0.48), attempts: 940 }, { model: 'google/gemini-3.8-flash', cost_microusd: Math.round(spend * 0.33), attempts: 2210 },
          { model: 'deepseek/deepseek-v4-pro', cost_microusd: Math.round(spend * 0.12), attempts: 60 }, { model: 'anthropic/claude-haiku-5.5', cost_microusd: Math.round(spend * 0.07), attempts: 1180 }] },
      budget: { limit_microusd: 100_000_000, spent_microusd: spend, reserved_microusd: 412_000, work_enabled: true },
      fixed: { recorded_microusd: 47_600_000, components_missing: 2 },
      income: { method: 'estimate', commission_bp: 1500, production, sandbox: { ...empty, purchases: 3 }, previous_month_production: { ...production, proceeds_microusd: 81_200_000 } },
      ratio: Math.round(spend / production.proceeds_microusd * 1000) / 1000,
      forecast: { spend_microusd: Math.round(spend * 31 / 21.4), proceeds_microusd: Math.round(production.proceeds_microusd * 31 / 21.4), early: false },
      free: { pool_microusd: 15_000_000, used_microusd: over ? 14_610_000 : 4_352_000, account_microusd: 250_000, monthly_credits: 50, daily_credits: 20, accounts: 311, operations: 2_904, suggested_pool_microusd: 15_000_000 },
      switches: { free_ai_paused: false, cheap_models_only: false, paused_features: over ? ['podcasts'] : [], all_ai_paused: false },
      alerts: { spend_income_ratio: 0.6, min_proceeds_microusd: 20_000_000, recent: ([
        ...(over ? [{ kind: 'spend_over_income', period, created_at: at(2), delivery: 'sent' as const, attempts: 1, delivered_at: at(2), details: { spend_microusd: spend, proceeds_microusd: production.proceeds_microusd, ratio: 0.765, threshold: 0.6 } },
          { kind: 'free_pool_exhausted', period, created_at: at(5), delivery: 'sent' as const, attempts: 1, delivered_at: at(5), details: { pool_microusd: 15_000_000, used_microusd: 14_610_000, accounts: 311 } }] : []),
        { kind: 'budget_50', period, created_at: at(80), delivery: 'not_configured' as const, attempts: 0, delivered_at: null, details: { spent_microusd: 50_100_000, reserved_microusd: 0, limit_microusd: 100_000_000, percent: 50.1 } }] as SpendAlert[]) } };
  });
  // Reads the latest state at resolve time: a reload started before React re-rendered still sees the change.
  const latest = useRef(state);
  const api = useMemo<SpendIncomeApi>(() => ({
    load: () => new Promise(resolve => setTimeout(() => resolve(latest.current), 120)),
    preview: (name: SwitchName) => new Promise(resolve => setTimeout(() => resolve({ switch: name, since: new Date(Date.now() - 6 * DAY).toISOString(),
      requests: { free_ai: 1210, podcasts: 12, recommendations: 41, figures: 280, equations: 140, cheap_models: 460, all_ai: 4100 }[name],
      accounts: { free_ai: 188, podcasts: 7, recommendations: 22, figures: 96, equations: 61, cheap_models: 74, all_ai: 402 }[name],
      paying_accounts: { free_ai: 0, podcasts: 6, recommendations: 9, figures: 40, equations: 20, cheap_models: 60, all_ai: 91 }[name],
      cost_microusd: { free_ai: 1_420_000, podcasts: 3_800_000, recommendations: 52_000, figures: 2_100_000, equations: 610_000, cheap_models: 6_900_000, all_ai: 9_300_000 }[name],
      all_cost_microusd: 9_300_000, on: false }), 120)),
    set: async (name: SwitchName, on: boolean) => {
      const s = latest.current;
      latest.current = { ...s, switches: name === 'free_ai' ? { ...s.switches, free_ai_paused: on }
        : name === 'cheap_models' ? { ...s.switches, cheap_models_only: on } : name === 'all_ai' ? { ...s.switches, all_ai_paused: on }
        : { ...s.switches, paused_features: on ? [...s.switches.paused_features, name] : s.switches.paused_features.filter(f => f !== name) } };
      setState(latest.current);
    },
    setPool: async (microusd: number) => { latest.current = { ...latest.current, free: { ...latest.current.free, pool_microusd: microusd } }; setState(latest.current); },
  }), []);
  return <Shell tabs={['Health', 'Overview', 'Spend vs income', 'Spending', 'Costs', 'Processing', 'Reliability', 'Accounts', 'Purchases', 'Support']} tab="Spend vs income" onTab={() => undefined}
    counts={{ Support: 2 }} email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <SpendVsIncome api={api} reloadKey={reloads} />
  </Shell>;
}
