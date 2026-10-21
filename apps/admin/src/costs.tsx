import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { rpc } from './backend';
import { plural, Stat } from './charts';

// The owner's Costs tab (migration 0141, docs/architecture/OPERATIONS_AND_BILLING.md "Cost per account"): AI cost per
// account from our own ledger, this UTC month and the last 30 UTC days, by feature and by model. Every model call goes
// through OpenRouter with the account's UUID as its `user`, so a row here can be checked against OpenRouter's Activity.

export interface CostWindow {
  cost_microusd: number; reported_microusd: number; estimated_microusd: number; held_microusd: number; attempts: number;
  searches: number; search_list_microusd: number; legacy_microusd: number; credits_charged?: number;
}
export interface CostByFeature { feature: string; month: CostWindow; last_30_days: CostWindow }
export interface CostByModel { provider: string; model: string; legacy: boolean; month: CostWindow; last_30_days: CostWindow }
export interface AccountCost {
  account_id: string; email: string | null; synthetic: boolean; test: boolean; closed: boolean;
  month: CostWindow; last_30_days: CostWindow; by_feature: CostByFeature[]; by_model: CostByModel[];
}
export interface AccountCosts {
  generated_at: string; month_start: string; since: string; limit: number; accounts_with_activity: number; truncated: boolean;
  totals: { month: CostWindow; last_30_days: CostWindow; by_feature: CostByFeature[]; by_model: CostByModel[] };
  accounts: AccountCost[];
}
export interface CostsApi { load(): Promise<AccountCosts> }
export const liveCostsApi: CostsApi = { load: () => rpc<AccountCosts>('v1_admin_account_costs', { p_limit: 500 }) };

type WindowKey = 'month' | 'last_30_days';
type SortKey = 'account' | 'month' | 'last_30_days' | 'held' | 'attempts' | 'charged';
const FEATURES: Record<string, string> = { chat: 'Chat', figure_explainer: 'Figure explainer', equation_explainer: 'Equation explainer',
  tags: 'Tags', podcasts: 'Podcasts', search: 'Web search', recommendations: 'Recommendations', ocr: 'OCR (retired)', other: 'Other' };
const featureName = (f: string) => FEATURES[f] ?? f;
const PROVIDERS: Record<string, string> = { openrouter: 'OpenRouter', tavily: 'Tavily', anthropic: 'Anthropic direct (legacy)',
  deepseek: 'DeepSeek direct (legacy)', google: 'Google direct (legacy)', mathpix: 'Mathpix (legacy)' };
// Micro-USD as dollars: cents for whole dollars, more digits below a cent so a small account never reads as $0.00.
export const cost = (micro: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD',
  minimumFractionDigits: micro >= 1_000_000 || micro === 0 ? 2 : 4, maximumFractionDigits: micro >= 1_000_000 || micro === 0 ? 2 : 4 }).format(micro / 1_000_000);
const short = (id: string) => id.slice(0, 8);
const accountName = (a: AccountCost) => a.email ?? `deleted account ${short(a.account_id)}`;
const WINDOW_NAMES: Record<WindowKey, string> = { month: 'This month', last_30_days: 'Last 30 days' };

function value(a: AccountCost, key: SortKey, window: WindowKey): number | string {
  switch (key) {
    case 'account': return accountName(a).toLowerCase();
    case 'month': return a.month.cost_microusd;
    case 'last_30_days': return a.last_30_days.cost_microusd;
    case 'held': return a[window].held_microusd;
    case 'attempts': return a[window].attempts;
    case 'charged': return a[window].credits_charged ?? 0;
  }
}

export function Costs({ api = liveCostsApi, reloadKey }: { api?: CostsApi; reloadKey: number }) {
  const [data, setData] = useState<AccountCosts | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [window, setWindow] = useState<WindowKey>('last_30_days');
  const [sort, setSort] = useState<SortKey>('last_30_days');
  const [ascending, setAscending] = useState(false);
  const [hideTests, setHideTests] = useState(false);
  const generation = useRef(0);

  const load = useCallback(async () => {
    const mine = ++generation.current;
    setLoading(true); setError('');
    try { const next = await api.load(); if (mine === generation.current) setData(next); }
    catch (e) { if (mine === generation.current) setError(e instanceof Error ? e.message : 'Costs could not be loaded.'); }
    finally { if (mine === generation.current) setLoading(false); }
  }, [api]);
  useEffect(() => { void load(); }, [load, reloadKey]);

  const rows = useMemo(() => {
    const list = (data?.accounts ?? []).filter(a => !hideTests || !a.test);
    return [...list].sort((a, b) => {
      const x = value(a, sort, window), y = value(b, sort, window);
      const order = typeof x === 'string' && typeof y === 'string' ? x.localeCompare(y) : (x as number) - (y as number);
      return (ascending ? order : -order) || a.account_id.localeCompare(b.account_id);
    });
  }, [data, sort, ascending, window, hideTests]);
  const sortBy = (key: SortKey) => { if (key === sort) setAscending(v => !v); else { setSort(key); setAscending(key === 'account'); } };
  const ariaSort = (key: SortKey) => sort === key ? (ascending ? 'ascending' : 'descending') : undefined;
  const header = (key: SortKey, label: string, numeric = true) => <th scope="col" className={numeric ? 'num' : undefined} aria-sort={ariaSort(key)}>
    <button className="sort" onClick={() => sortBy(key)}>{label}<span className={'sort-mark' + (sort === key ? ' active' : '')} aria-hidden="true">{sort === key ? (ascending ? '↑' : '↓') : '↕'}</span></button></th>;
  const totals = data?.totals[window];
  const tests = data?.accounts.filter(a => a.test).length ?? 0;

  return <div className="costs">
    <section className="panel" aria-labelledby="costs-title">
      <div className="section-heading"><h2 id="costs-title">Cost per account</h2>
        <div className="segmented" role="group" aria-label="Time window">
          {(Object.keys(WINDOW_NAMES) as WindowKey[]).map(w => <button key={w} type="button" aria-pressed={window === w} className={window === w ? 'selected' : ''}
            onClick={() => { setWindow(w); if (sort === 'month' || sort === 'last_30_days') setSort(w); }}>{WINDOW_NAMES[w]}</button>)}
        </div></div>
      {error && <p className="error" role="alert">{error}</p>}
      {!data && loading && <p className="empty" role="status">Loading costs…</p>}
      {data && totals && <>
        <div className="metrics">
          <Stat label="AI cost" value={cost(totals.cost_microusd)} note={totals.estimated_microusd ? `${cost(totals.estimated_microusd)} of it estimated` : 'All reported by OpenRouter'} />
          <Stat label="Held, not yet resolved" value={cost(totals.held_microusd)} note="Ceilings of attempts awaiting their bill" />
          <Stat label="Web searches" value={totals.searches.toLocaleString()} note={`Prepaid plan; ${cost(totals.search_list_microusd)} at list price`} />
          <Stat label="Credits charged" value={(totals.credits_charged ?? 0).toLocaleString()} note={plural(data.accounts_with_activity, 'account') + ' with activity'} />
        </div>
        {totals.legacy_microusd > 0 && <p className="notice" role="status">{cost(totals.legacy_microusd)} of this is from legacy direct-provider attempts (before every model call went through OpenRouter on 2026-10-18). They stay in the totals and are marked below.</p>}
        <div className="two-columns">
          <BreakdownTable caption="By feature" rows={data.totals.by_feature.map(f => ({ key: f.feature, label: featureName(f.feature), window: f[window] }))} />
          <BreakdownTable caption="By model" rows={data.totals.by_model.map(m => ({ key: m.provider + ':' + m.model, label: m.model, note: PROVIDERS[m.provider] ?? m.provider, legacy: m.legacy, window: m[window] }))} />
        </div>
      </>}
    </section>
    {data && <section className="panel" aria-labelledby="costs-accounts-title">
      <div className="section-heading"><h2 id="costs-accounts-title">Accounts</h2>
        {tests > 0 && <label className="check"><input type="checkbox" checked={hideTests} onChange={e => setHideTests(e.target.checked)} />Hide {plural(tests, 'test account')}</label>}</div>
      <div className={'table-scroll' + (loading ? ' refetching' : '')}>
        <table className="costs-table">
          <caption className="sr-only">AI cost per account, sorted by {sort.replaceAll('_', ' ')}, {ascending ? 'ascending' : 'descending'}</caption>
          <thead><tr>
            {header('account', 'Account', false)}{header('month', 'This month')}{header('last_30_days', 'Last 30 days')}
            {header('held', 'Held')}{header('attempts', 'Calls')}{header('charged', 'Credits charged')}
          </tr></thead>
          <tbody>{rows.map(a => <AccountRow key={a.account_id} account={a} window={window} />)}</tbody>
        </table>
      </div>
      {!rows.length && <p className="empty">{data.accounts.length ? 'Only test accounts had activity.' : 'No AI activity in the last 30 days.'}</p>}
      {data.truncated && <p className="notice" role="status">Showing the {plural(data.accounts.length, 'account')} with the highest cost of {plural(data.accounts_with_activity, 'account')} with activity.</p>}
      <p className="footnote">From Gradstep's ledger: each model call's cost as OpenRouter reported it, an estimate where no bill arrived, and the ceiling still held by calls not yet resolved (not counted as cost). "Held", "Calls" and "Credits charged" follow the selected window. Titles, suggestions and Study maps count as chat. Web searches use the prepaid Tavily plan. Accounts are named by their pseudonymous ID; OpenRouter receives that ID as each request's <code>user</code>, so its Activity page filters to the same account.</p>
    </section>}
  </div>;
}

function AccountRow({ account, window }: { account: AccountCost; window: WindowKey }) {
  const [open, setOpen] = useState(false);
  const w = account[window];
  return <>
    <tr className={account.test ? 'synthetic' : undefined}>
      <th scope="row">
        <button className="quiet inline" aria-expanded={open} onClick={() => setOpen(v => !v)}>{open ? '▾' : '▸'} <span className={account.email ? 'email' : 'email muted'}>{accountName(account)}</span></button>
        <small><code title={account.account_id}>{account.account_id}</code></small>
        {(account.test || account.closed || w.legacy_microusd > 0) && <span className="tags">{account.test && <span className="badge plain test">Test</span>}{account.closed && <span className="badge plain">Closed</span>}{w.legacy_microusd > 0 && <span className="badge plain" title="Includes attempts of a retired direct provider">Legacy {cost(w.legacy_microusd)}</span>}</span>}
      </th>
      <td className="num">{cost(account.month.cost_microusd)}</td>
      <td className="num">{cost(account.last_30_days.cost_microusd)}</td>
      <td className="num">{w.held_microusd ? cost(w.held_microusd) : <span className="muted">—</span>}</td>
      <td className="num">{w.attempts.toLocaleString()}{w.searches ? <small>{plural(w.searches, 'search', 'searches')}</small> : null}</td>
      <td className="num">{(w.credits_charged ?? 0).toLocaleString()}</td>
    </tr>
    {open && <tr className="cost-detail"><td colSpan={6}>
      <div className="two-columns">
        <BreakdownTable caption={`${accountName(account)} by feature`} rows={account.by_feature.map(f => ({ key: f.feature, label: featureName(f.feature), window: f[window] }))} />
        <BreakdownTable caption={`${accountName(account)} by model`} rows={account.by_model.map(m => ({ key: m.provider + ':' + m.model, label: m.model, note: PROVIDERS[m.provider] ?? m.provider, legacy: m.legacy, window: m[window] }))} />
      </div>
    </td></tr>}
  </>;
}

function BreakdownTable({ caption, rows }: { caption: string; rows: { key: string; label: string; note?: string; legacy?: boolean; window: CostWindow }[] }) {
  const shown = rows.filter(r => r.window.attempts > 0 || r.window.held_microusd > 0).sort((a, b) => b.window.cost_microusd - a.window.cost_microusd || a.label.localeCompare(b.label));
  return <div className="table-scroll"><table className="breakdown">
    <caption>{caption}</caption>
    <thead><tr><th scope="col">Name</th><th scope="col" className="num">Cost</th><th scope="col" className="num">Held</th><th scope="col" className="num">Calls</th></tr></thead>
    <tbody>{shown.map(r => <tr key={r.key}>
      <th scope="row">{r.label}{(r.note || r.legacy) && <small>{r.note}{r.legacy && r.note !== undefined && !r.note.includes('legacy') ? ' · legacy' : ''}</small>}</th>
      <td className="num">{cost(r.window.cost_microusd)}{r.window.searches ? <small>{plural(r.window.searches, 'search', 'searches')} · {cost(r.window.search_list_microusd)} list</small> : null}</td>
      <td className="num">{r.window.held_microusd ? cost(r.window.held_microusd) : <span className="muted">—</span>}</td>
      <td className="num">{r.window.attempts.toLocaleString()}</td>
    </tr>)}</tbody>
  </table>{!shown.length && <p className="empty">Nothing in this window.</p>}</div>;
}
