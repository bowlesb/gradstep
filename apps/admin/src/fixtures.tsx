import React, { useCallback, useMemo, useState } from 'react';
import type { Budget, Health as HealthData, PipelineMetrics, ProviderHour } from './backend';
import { ProviderHours } from './provider-hours';
import { Health } from './health';
import { Accounts, type AccountList, type AccountsApi, type AdminAccount, type AccountSort } from './accounts';
import { Reliability } from './reliability';
import { Shell } from './shell';
import { Purchases, type PurchasesApi, type PurchaseSubmission, type PurchaseTransaction } from './purchases';

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

/** Reliability's hourly provider table (RESILIENCE.md): two days, Google's voices throttled in the newest hours. */
function providerHoursFixture(empty: boolean): ProviderHour[] {
  if (empty) return [];
  const now = Date.now(), rows: ProviderHour[] = [];
  for (let h = 0; h < 48; h++) {
    const hour = new Date(Math.floor(now / 3_600_000 - h) * 3_600_000).toISOString();
    const busy = h < 2;
    rows.push({ hour, provider: 'anthropic', calls: 380 - h * 3, ok: 376 - h * 3, throttled: 2, failed: h === 30 ? 24 : 2, rejected: 0, breaker_open: 0,
      latency_ms_avg: 2_300, latency_ms_max: 41_000, retry_after_max_s: h === 30 ? 20 : null });
    rows.push({ hour, provider: 'google', calls: 31, ok: busy ? 18 : 31, throttled: busy ? 7 : 0, failed: 0, rejected: 0, breaker_open: busy ? 6 : 0,
      latency_ms_avg: 21_000, latency_ms_max: 74_000, retry_after_max_s: busy ? 60 : null });
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
    // Staging rates (2026-10-15): a chat answer about 2.5¢ with the paper cached, an episode about 11¢ (script review,
    // DeepSeek script, Google voices), a web search 0.8¢ on 6% of answers.
    const anthropic = chats * 25_000 + podcasts * 30_000, deepseek = podcasts * 4_000, google = podcasts * 80_000, tavily = chats * 0.06 * 8_000;
    return { day: iso(day), signups, active, papers, chats, chatting: Math.round(active * 0.6), podcasts, failedPapers, failedPodcasts,
      reports: !quiet && (i === 2 || i === 11) ? 1 : 0, by_provider: { anthropic, deepseek, google, tavily: Math.round(tavily) } };
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
    // Outside providers (RESILIENCE.md): a steady trickle of throttling, one bad Anthropic day, and (unless quiet) Google's
    // voices throttled in the last hour with their breaker open.
    providers: {
      daily: window.map((r, k) => ({ day: r.day, by_provider: empty ? {} as Record<string, never> : {
        anthropic: { calls: r.chats * 3, failed: quiet ? 0 : Math.round(r.chats * (k === window.length - 4 ? 0.06 : 0.004)), throttled: quiet ? 0 : Math.round(r.chats * 0.002), breaker_open: 0 },
        google: { calls: r.podcasts * 2, failed: 0, throttled: quiet || k < window.length - 1 ? 0 : Math.round(r.podcasts * 0.4), breaker_open: quiet || k < window.length - 1 ? 0 : 6 },
        crossref: { calls: Math.round(r.papers * 0.2), failed: quiet ? 0 : Math.round(r.papers * 0.002), throttled: 0, breaker_open: 0 } } })),
      last_hour: empty ? [] : [
        { provider: 'anthropic', calls: 412, failed: quiet ? 0 : 3, throttled: quiet ? 0 : 2, breaker_open: 0, latency_ms_avg: 2_400 },
        { provider: 'crossref', calls: 38, failed: 0, throttled: 0, breaker_open: 0, latency_ms_avg: 310 },
        { provider: 'google', calls: quiet ? 9 : 31, failed: 0, throttled: quiet ? 0 : 7, breaker_open: quiet ? 0 : 6, latency_ms_avg: 21_000 }],
      breakers: quiet || empty ? [] : [{ provider: 'google', state: 'open', reopen_at: new Date(Date.now() + 120_000).toISOString() }],
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
