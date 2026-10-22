import React, { useCallback, useEffect, useRef, useState } from 'react';
import { rpc } from './backend';
import { plural, Stat } from './charts';
import { cost } from './costs';

// Spend vs income (migration 0150; docs/RUNBOOK_SPENDING.md): this month's provider spend by funding, feature and model
// next to an estimate of App Store proceeds from verified transactions, the ratio and a straight-line forecast; the free
// AI pool; the owner's switches with a dry-run preview; and the spending alerts with how each was delivered. Owner + MFA:
// every call is refused by the database otherwise.

export interface ProceedsWindow {
  purchases: number; refunds: number; gross_microusd: number; refunded_microusd: number; proceeds_microusd: number;
  by_product: { product_id: string; purchases: number; gross_microusd: number; refunds: number; refunded_microusd: number }[];
}
export interface SpendAlert { kind: string; period: string; created_at: string; delivery: 'pending' | 'sent' | 'failed' | 'not_configured'; attempts: number; delivered_at: string | null; details: Record<string, number | string> }
export interface SpendIncome {
  period: string; generated_at: string; days_elapsed: number; days_in_month: number; email_configured: boolean;
  spend: { cost_microusd: number; held_microusd: number; by_funding: Record<string, number>;
    by_feature: { feature: string; cost_microusd: number; attempts: number }[]; by_model: { model: string; cost_microusd: number; attempts: number }[] };
  budget: { limit_microusd: number; spent_microusd: number; reserved_microusd: number; work_enabled: boolean } | null;
  fixed: { recorded_microusd: number; components_missing: number };
  income: { method: 'estimate'; commission_bp: number; production: ProceedsWindow; sandbox: ProceedsWindow; previous_month_production: ProceedsWindow };
  ratio: number | null;
  forecast: { spend_microusd: number; proceeds_microusd: number; early: boolean };
  free: { pool_microusd: number; used_microusd: number; account_microusd: number; monthly_credits: number; daily_credits: number; accounts: number; operations: number; suggested_pool_microusd: number };
  switches: { free_ai_paused: boolean; cheap_models_only: boolean; paused_features: string[]; all_ai_paused: boolean };
  alerts: { spend_income_ratio: number; min_proceeds_microusd: number; recent: SpendAlert[] };
}
export type SwitchName = 'free_ai' | 'podcasts' | 'recommendations' | 'figures' | 'equations' | 'cheap_models' | 'all_ai';
export interface SwitchPreview { switch: SwitchName; since: string; requests: number; accounts: number; paying_accounts: number; cost_microusd: number; all_cost_microusd: number; on: boolean }
export interface SpendIncomeApi {
  load(): Promise<SpendIncome>;
  preview(name: SwitchName): Promise<SwitchPreview>;
  set(name: SwitchName, on: boolean, reason: string): Promise<unknown>;
  setPool(microusd: number, reason: string): Promise<unknown>;
}
export const liveSpendIncomeApi: SpendIncomeApi = {
  load: () => rpc<SpendIncome>('v1_admin_spend_income'),
  preview: name => rpc<SwitchPreview>('v1_admin_ai_switch_preview', { p_switch: name }),
  set: (name, on, reason) => rpc('v1_admin_set_ai_switch', { p_switch: name, p_on: on, p_reason: reason }),
  setPool: (microusd, reason) => rpc('v1_admin_set_free_pool', { p_pool_microusd: microusd, p_reason: reason }),
};

const FUNDING: [string, string, string][] = [
  ['paid', 'Paid', 'Plan and pack credits bought in Production: readers prepaid this'],
  ['sandbox', 'Test purchases', 'Credits from Sandbox (TestFlight) purchases: no money came in'],
  ['free', 'Free AI', 'Free credits: your subsidy, capped by the pool'],
  ['testing', 'Your testing', 'Your unlimited testing allowance'],
  ['granted', 'Granted', 'Credits you or the checks granted (testers, workflow checks)'],
  ['platform', 'Platform', 'No reader credits: tags, catalog podcasts'],
];
const FEATURES: Record<string, string> = { chat: 'Chat', figure_explainer: 'Figure explainer', equation_explainer: 'Equation explainer',
  tags: 'Tags', podcasts: 'Podcasts', search: 'Web search', recommendations: 'Recommendations', ocr: 'OCR (retired)', other: 'Other' };
const PRODUCTS: Record<string, string> = { 'com.sciencereader.ios.standard.monthly': 'Plus monthly', 'com.sciencereader.ios.standard.annual': 'Plus yearly',
  'com.sciencereader.ios.pro.monthly': 'Pro monthly', 'com.sciencereader.ios.pro.annual': 'Pro yearly', 'com.sciencereader.ios.credits.300': '300 credits',
  'com.sciencereader.ios.credits.700': '700 credits', 'com.sciencereader.ios.credits.400': '400 credits (retired)' };
const ALERTS: Record<string, string> = { budget_50: '50% of the provider limit', budget_80: '80% of the provider limit', budget_100: 'Provider limit reached',
  free_pool_exhausted: 'Free AI pool used up', spend_over_income: 'Spend high vs income' };
const DELIVERY: Record<SpendAlert['delivery'], string> = { pending: 'Sending', sent: 'Emailed', failed: 'Email failed', not_configured: 'Not emailed (no address or key)' };

/** Least user impact first (docs/RUNBOOK_SPENDING.md "Actions"). `on` reads the switch from the figures. */
export const SWITCHES: { name: SwitchName; title: string; sees: string; on: (s: SpendIncome['switches']) => boolean; onLabel: string; offLabel: string }[] = [
  { name: 'free_ai', title: 'Pause free AI', sees: 'Free readers: "Free AI is paused for now." Paying readers are unaffected.', on: s => s.free_ai_paused, onLabel: 'Resume free AI', offLabel: 'Pause free AI' },
  { name: 'podcasts', title: 'Pause podcast generation', sees: 'Generating an episode says it is paused. Ready episodes still play.', on: s => s.paused_features.includes('podcasts'), onLabel: 'Resume podcasts', offLabel: 'Pause podcasts' },
  { name: 'recommendations', title: 'Pause recommendations', sees: '"Find similar papers" says AI features are paused. Nothing is charged.', on: s => s.paused_features.includes('recommendations'), onLabel: 'Resume recommendations', offLabel: 'Pause recommendations' },
  { name: 'figures', title: 'Pause figure explainer', sees: 'Figure walkthroughs say AI is paused. Chat still works.', on: s => s.paused_features.includes('figures'), onLabel: 'Resume figures', offLabel: 'Pause figures' },
  { name: 'equations', title: 'Pause equation explainer', sees: 'Equation explanations say AI is paused. Chat still works.', on: s => s.paused_features.includes('equations'), onLabel: 'Resume equations', offLabel: 'Pause equations' },
  { name: 'cheap_models', title: 'Cheaper models only', sees: 'Every default becomes Gemini Flash; Sonnet and Opus say they are unavailable right now.', on: s => s.cheap_models_only, onLabel: 'Allow premium models', offLabel: 'Cheaper models only' },
  { name: 'all_ai', title: 'Pause all AI', sees: 'Every AI request says "AI answers are paused right now." Reading is unaffected.', on: s => s.all_ai_paused, onLabel: 'Resume all AI', offLabel: 'Pause all AI' },
];

const share = (part: number, whole: number) => whole > 0 ? `${Math.round(part * 100 / whole)}%` : '—';
const ratioText = (r: number | null) => r == null ? '—' : `${r.toFixed(2)}×`;
const when = (iso: string) => new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export function SpendVsIncome({ api = liveSpendIncomeApi, reloadKey }: { api?: SpendIncomeApi; reloadKey: number }) {
  const [data, setData] = useState<SpendIncome | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const mine = ++generation.current; setLoading(true); setError('');
    try { const next = await api.load(); if (mine === generation.current) setData(next); }
    catch (e) { if (mine === generation.current) setError(e instanceof Error ? e.message : 'Spend vs income could not be loaded.'); }
    finally { if (mine === generation.current) setLoading(false); }
  }, [api]);
  useEffect(() => { void load(); }, [load, reloadKey]);

  if (!data) return <section className="panel">{error ? <p className="error" role="alert">{error}</p> : <p className="empty" role="status">{loading ? 'Loading spend and income…' : 'Nothing to show.'}</p>}</section>;
  const spend = data.spend.cost_microusd, proceeds = data.income.production.proceeds_microusd;
  const budget = data.budget, used = budget ? budget.spent_microusd + budget.reserved_microusd : 0;
  const month = new Date(data.period + 'T00:00:00Z').toLocaleString('en-US', { month: 'long', timeZone: 'UTC' });
  const over = data.ratio != null && data.ratio > data.alerts.spend_income_ratio;
  return <div className="spend-income">
    {error && <p className="error" role="alert">{error}</p>}
    <section className="panel" aria-labelledby="si-title">
      <div className="section-heading"><h2 id="si-title">{month}: AI spend vs App Store income</h2>
        <span className="muted">Day {Math.floor(data.days_elapsed) + 1} of {Math.round(data.days_in_month)}</span></div>
      <div className="metrics headline">
        <Stat label="AI spend this month" value={cost(spend)} note={data.spend.held_microusd ? `+ ${cost(data.spend.held_microusd)} still held` : 'Nothing held'} />
        <Stat label="Estimated proceeds" value={cost(proceeds)} note={`${plural(data.income.production.purchases, 'purchase')} · after Apple's ${data.income.commission_bp / 100}%`} />
        <Stat label="Spend ÷ proceeds" value={ratioText(data.ratio)} note={data.ratio == null ? 'No Production income yet' : `Alert above ${data.alerts.spend_income_ratio}×`} />
        <Stat label="Forecast to month end" value={cost(data.forecast.spend_microusd)} note={`vs ${cost(data.forecast.proceeds_microusd)} proceeds${data.forecast.early ? ' · early in the month' : ''}`} />
        <Stat label="Provider limit used" value={budget ? share(used, budget.limit_microusd) : '—'} note={budget ? `${cost(used)} of ${cost(budget.limit_microusd)}${budget.work_enabled ? '' : ' · AI paused'}` : 'No budget row'} />
      </div>
      {over && <p className="notice" role="status"><span aria-hidden="true">!</span>Spend is above {data.alerts.spend_income_ratio}× proceeds. See the runbook's first steps below.</p>}
      <div className="two-columns">
        <div className="table-scroll"><table className="breakdown"><caption>By who pays</caption>
          <thead><tr><th scope="col">Funding</th><th scope="col" className="num">Spend</th><th scope="col" className="num">Share</th></tr></thead>
          <tbody>{FUNDING.map(([key, label, note]) => <tr key={key}><th scope="row">{label}<small>{note}</small></th>
            <td className="num">{cost(data.spend.by_funding[key] ?? 0)}</td><td className="num">{share(data.spend.by_funding[key] ?? 0, spend)}</td></tr>)}</tbody>
        </table></div>
        <div className="table-scroll"><table className="breakdown"><caption>By feature</caption>
          <thead><tr><th scope="col">Feature</th><th scope="col" className="num">Spend</th><th scope="col" className="num">Calls</th></tr></thead>
          <tbody>{data.spend.by_feature.map(f => <tr key={f.feature}><th scope="row">{FEATURES[f.feature] ?? f.feature}</th>
            <td className="num">{cost(f.cost_microusd)}</td><td className="num">{f.attempts.toLocaleString()}</td></tr>)}</tbody>
        </table>{!data.spend.by_feature.length && <p className="empty">No AI calls this month.</p>}</div>
      </div>
      <div className="two-columns">
        <div className="table-scroll"><table className="breakdown"><caption>By model</caption>
          <thead><tr><th scope="col">Model</th><th scope="col" className="num">Spend</th><th scope="col" className="num">Calls</th></tr></thead>
          <tbody>{data.spend.by_model.map(m => <tr key={m.model}><th scope="row">{m.model}</th><td className="num">{cost(m.cost_microusd)}</td><td className="num">{m.attempts.toLocaleString()}</td></tr>)}</tbody>
        </table></div>
        <div className="table-scroll"><table className="breakdown"><caption>Income by product (Production)</caption>
          <thead><tr><th scope="col">Product</th><th scope="col" className="num">Bought</th><th scope="col" className="num">Gross</th><th scope="col" className="num">Refunds</th></tr></thead>
          <tbody>{data.income.production.by_product.map(p => <tr key={p.product_id}><th scope="row">{PRODUCTS[p.product_id] ?? p.product_id}</th>
            <td className="num">{p.purchases}</td><td className="num">{cost(p.gross_microusd)}</td><td className="num">{p.refunds ? `${p.refunds} · ${cost(p.refunded_microusd)}` : '—'}</td></tr>)}</tbody>
        </table>{!data.income.production.by_product.length && <p className="empty">No Production purchases this month.{data.income.sandbox.purchases ? ` ${plural(data.income.sandbox.purchases, 'Sandbox purchase')} (TestFlight, no money).` : ''}</p>}</div>
      </div>
      <p className="footnote">Spend is the provider cost Gradstep recorded for this UTC month (OpenRouter's reported cost, estimates where no bill came), excluding fixed costs{data.fixed.recorded_microusd ? ` (${cost(data.fixed.recorded_microusd)} recorded on Spending)` : ''}{data.fixed.components_missing ? `; ${plural(data.fixed.components_missing, 'fixed component')} not recorded` : ''}. Proceeds are an <strong>estimate</strong> from verified App Store transactions: each purchase or renewal at its configured US price (a plan's first month at the introductory price), less refunds made this month, after Apple's commission. They are not Apple's financial report: no VAT, currency or payment timing. Sandbox purchases are test money and never count. The forecast extends this month so far to the whole month.</p>
    </section>

    <FreePool data={data} api={api} onChanged={load} />
    <Switches data={data} api={api} onChanged={load} />

    <section className="panel" aria-labelledby="si-alerts">
      <div className="section-heading"><h2 id="si-alerts">Alerts</h2>
        <span className={'badge' + (data.email_configured ? ' positive' : ' warning')}>{data.email_configured ? 'Email on' : 'No email address'}</span></div>
      <p className="muted">Emailed once a month each: 50%, 80% and 100% of the provider limit, the free AI pool used up, and spend above {data.alerts.spend_income_ratio}× proceeds once proceeds pass {cost(data.alerts.min_proceeds_microusd)}. Checked every 10 minutes.</p>
      {data.alerts.recent.length ? <ul className="event-list alerts-list">{data.alerts.recent.map(a => <li key={a.kind + a.period}>
        <time dateTime={a.created_at}>{when(a.created_at)}</time><strong>{ALERTS[a.kind] ?? a.kind}</strong>
        <span>{alertDetail(a)}</span><span className={'badge plain' + (a.delivery === 'sent' ? ' positive' : a.delivery === 'pending' ? '' : ' warning')}>{DELIVERY[a.delivery]}</span>
      </li>)}</ul> : <p className="empty">No alerts yet.</p>}
    </section>
  </div>;
}

function alertDetail(a: SpendAlert): string {
  const d = a.details, n = (k: string) => Number(d[k] ?? 0);
  if (a.kind.startsWith('budget_')) return `${cost(n('spent_microusd') + n('reserved_microusd'))} of ${cost(n('limit_microusd'))} (${d.percent}%)`;
  if (a.kind === 'free_pool_exhausted') return `${cost(n('used_microusd'))} of ${cost(n('pool_microusd'))}, ${plural(n('accounts'), 'account')}`;
  return `${cost(n('spend_microusd'))} spend vs ${cost(n('proceeds_microusd'))} proceeds (${d.ratio}×)`;
}

function FreePool({ data, api, onChanged }: { data: SpendIncome; api: SpendIncomeApi; onChanged: () => Promise<void> }) {
  const f = data.free;
  const [dollars, setDollars] = useState(''); const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const amount = Number(dollars);
  const valid = dollars.trim() !== '' && Number.isFinite(amount) && amount >= 0 && amount <= 50 && reason.trim().length >= 3;
  return <section className="panel" aria-labelledby="si-free">
    <div className="section-heading"><h2 id="si-free">Free AI pool</h2>
      <span className={'badge' + (data.switches.free_ai_paused ? ' warning' : ' positive')}>{data.switches.free_ai_paused ? 'Paused' : 'On'}</span></div>
    <div className="budget-values"><div><span>Used (settled + held)</span><strong>{cost(f.used_microusd)}</strong></div>
      <div><span>Pool this month</span><strong>{cost(f.pool_microusd)}</strong></div>
      <div><span>Readers using it</span><strong>{f.accounts.toLocaleString()}</strong></div></div>
    <progress max={Math.max(1, f.pool_microusd)} value={Math.min(f.pool_microusd, f.used_microusd)} aria-label="Free AI pool used" />
    <p className="muted">{f.monthly_credits} credits a month per free account (at most {f.daily_credits} a day, {cost(f.account_microusd)} of provider cost), fast models only. Requests are refused before any model call once the pool can't hold their worst case. Growth rule (owner applies it): max($15, 10% of last month's proceeds) = <strong>{cost(f.suggested_pool_microusd)}</strong>.</p>
    <form className="inline-form" onSubmit={async event => {
      event.preventDefault(); if (!valid) return; setBusy(true); setError('');
      try { await api.setPool(Math.round(amount * 1_000_000), reason.trim()); setDollars(''); setReason(''); await onChanged(); }
      catch (e) { setError(e instanceof Error ? e.message : 'The pool was not changed.'); } finally { setBusy(false); }
    }}>
      <label className="narrow">New pool, US$<input inputMode="decimal" value={dollars} onChange={e => setDollars(e.target.value)} placeholder={(f.pool_microusd / 1e6).toFixed(2)} /></label>
      <label>Reason<input minLength={3} maxLength={500} value={reason} onChange={e => setReason(e.target.value)} placeholder="Recorded in the audit log" /></label>
      <button className="secondary" disabled={busy || !valid}>{busy ? 'Saving…' : 'Set pool'}</button>
    </form>
    {error && <p className="error" role="alert">{error}</p>}
  </section>;
}

function Switches({ data, api, onChanged }: { data: SpendIncome; api: SpendIncomeApi; onChanged: () => Promise<void> }) {
  return <section className="panel" aria-labelledby="si-switches">
    <div className="section-heading"><h2 id="si-switches">Safety switches</h2></div>
    <p className="muted">In order of least effect on readers. Each change is recorded in the audit log with your reason and can be undone here. Preview first: it shows what the switch would have stopped over the last 7 days.</p>
    <ul className="switch-list">{SWITCHES.map(s => <SwitchRow key={s.name} spec={s} on={s.on(data.switches)} api={api} onChanged={onChanged} />)}</ul>
  </section>;
}

function SwitchRow({ spec, on, api, onChanged }: { spec: typeof SWITCHES[number]; on: boolean; api: SpendIncomeApi; onChanged: () => Promise<void> }) {
  const [preview, setPreview] = useState<SwitchPreview | null>(null); const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState(''); const [confirming, setConfirming] = useState(false);
  const id = `switch-${spec.name}`;
  return <li className={on ? 'switch-on' : undefined} aria-labelledby={id}>
    <div className="switch-head"><strong id={id}>{spec.title}</strong><span className={'badge plain' + (on ? ' warning' : '')}>{on ? 'On' : 'Off'}</span></div>
    <p className="muted">{spec.sees}</p>
    {preview && <p className="switch-preview" role="status">Last 7 days: {plural(preview.requests, 'request')} from {plural(preview.accounts, 'account')}{preview.paying_accounts ? ` (${preview.paying_accounts} paying)` : ''}, {cost(preview.cost_microusd)} ({share(preview.cost_microusd, preview.all_cost_microusd)} of AI spend).</p>}
    <form className="inline-form" onSubmit={async event => {
      event.preventDefault();
      if (!confirming) { setConfirming(true); return; }
      setBusy(true); setError('');
      try { await api.set(spec.name, !on, reason.trim()); setReason(''); setConfirming(false); setPreview(null); await onChanged(); }
      catch (e) { setError(e instanceof Error ? e.message : 'The switch was not changed.'); } finally { setBusy(false); }
    }}>
      <button type="button" className="secondary" disabled={busy} onClick={async () => {
        setBusy(true); setError('');
        try { setPreview(await api.preview(spec.name)); } catch (e) { setError(e instanceof Error ? e.message : 'The preview could not be loaded.'); } finally { setBusy(false); }
      }}>Preview</button>
      <label>Reason<input minLength={3} maxLength={500} value={reason} onChange={e => { setReason(e.target.value); setConfirming(false); }} placeholder="Recorded in the audit log" /></label>
      <button className={on ? 'secondary' : 'danger'} disabled={busy || reason.trim().length < 3}>{busy ? 'Saving…' : confirming ? `Confirm: ${on ? spec.onLabel : spec.offLabel}` : on ? spec.onLabel : spec.offLabel}</button>
    </form>
    {error && <p className="error" role="alert">{error}</p>}
  </li>;
}
