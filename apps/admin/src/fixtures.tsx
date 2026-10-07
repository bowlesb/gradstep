import React, { useCallback, useMemo, useState } from 'react';
import type { PipelineMetrics } from './backend';
import { Accounts, type AccountList, type AccountsApi, type AdminAccount, type AccountSort } from './accounts';
import { Reliability } from './reliability';
import { Shell } from './shell';

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
  return <Shell tabs={['Overview', 'Usage', 'Processing', 'Reliability', 'Accounts', 'Support']} tab="Reliability" onTab={() => undefined} counts={{ Support: 2 }}
    email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Reliability load={load} reloadKey={reloads} />
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
  return <Shell tabs={['Overview', 'Usage', 'Processing', 'Reliability', 'Accounts', 'Support']} tab="Accounts" onTab={() => undefined} counts={{ Support: 2 }}
    email="owner@example.com" onSignOut={() => undefined} loading={false} onRefresh={() => setReloads(n => n + 1)}>
    <Accounts api={api} reloadKey={reloads} />
  </Shell>;
}
