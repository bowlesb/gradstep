import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  activityLabel, activityName, creditsText, grouped, loadUsage, modelLabel, outcomeLabel, partLabel, periodLabel, recallProvenance, slicesSummary,
  reportsTokens, tokensText, totalsText, unreportedTokens, usageSlices, USAGE_INFO, USAGE_PERIODS, type UsageActivity, type UsageActivityCount, type UsageCursor, type UsageOperation,
  type UsageProvenance, type UsageSlice, type UsageTotals,
} from '../lib/ai-usage';
import { Dialog, formatDateTime, InfoTip, SheetTop } from './common';
import './usage.css';

const PERIOD_KEY = 'gradstep.usage-period';

/** Credits by activity for the All view, as the apps' AIUsageRing: a thin ring (largest first, clockwise from the top,
 * a surface gap between segments) and a legend with each name, its credits and share. A named segment or row chooses
 * that activity's chip; Other lists what it holds. The legend carries every value, so colour never stands alone. */
function UsageRing({ slices, total, onChoose }: { slices: UsageSlice[]; total: number; onChoose: (a: UsageActivity) => void }) {
  const R = 44, C = 2 * Math.PI * R, GAP = 2;
  const sum = slices.reduce((n, s) => n + s.credits, 0) || 1;
  let start = 0;
  const color = (s: UsageSlice) => `var(--viz-${s.slot === 'other' ? 'other' : s.slot + 1})`;
  return <figure className="usage-ring" data-testid="usage-ring">
    <div className="usage-ring-plot">
      <svg viewBox="0 0 112 112" role="img" aria-label={slicesSummary(slices)}>
        <g transform="rotate(-90 56 56)">
          {slices.map(s => {
            const length = s.credits / sum * C, offset = start; start += length;
            const choose = s.activity ? () => onChoose(s.activity!) : undefined;
            return <circle key={s.label} cx="56" cy="56" r={R} fill="none" stroke={color(s)} strokeWidth="14"
              strokeDasharray={`${Math.max(length - GAP, 0.75)} ${C}`} strokeDashoffset={-(offset + GAP / 2)}
              className={choose ? 'usage-ring-segment choosable' : 'usage-ring-segment'} onClick={choose} data-testid={`usage-ring-${s.activity ?? 'other'}`}>
              <title>{`${s.label}: ${grouped(s.credits)} ${s.credits === 1 ? 'credit' : 'credits'}, ${s.percent}`}</title>
            </circle>;
          })}
        </g>
      </svg>
      <div className="usage-ring-total" aria-hidden="true"><strong>{grouped(total)}</strong><span>{total === 1 ? 'credit' : 'credits'}</span></div>
    </div>
    <ul className="usage-legend" aria-label="Credits by activity">
      {slices.map(s => {
        const content = <><span className="usage-swatch" style={{ background: color(s) }} aria-hidden="true" />
          <span className="usage-legend-name">{s.label}{s.members.length > 0 && <span className="usage-legend-members">{s.members.join(', ')}</span>}</span>
          <span className="usage-legend-value">{grouped(s.credits)} <span className="muted">· {s.percent}</span></span></>;
        return <li key={s.label}>{s.activity
          ? <button type="button" className="usage-legend-row" onClick={() => onChoose(s.activity!)} data-testid={`usage-legend-${s.activity}`}
              aria-label={`${s.label}, ${grouped(s.credits)} ${s.credits === 1 ? 'credit' : 'credits'}, ${s.percent}. Show only ${s.label}`}>{content}</button>
          : <div className="usage-legend-row" data-testid="usage-legend-other">{content}</div>}</li>;
      })}
    </ul>
  </figure>;
}
function savedPeriod(): number {
  try { const n = Number(localStorage.getItem(PERIOD_KEY)); return (USAGE_PERIODS as readonly number[]).includes(n) ? n : 30; } catch { return 30; }
}

/** Account menu › AI credits › Your AI usage (owner, 2026-10-22), as the apps' AIUsageView: the reader's own metered
 * requests, newest first, one row each — when, the activity (and the paper, from this browser's library), the model, the
 * tokens and the credits — with a row's parts below it when opened. Filters by activity, a period, totals for the
 * period, more rows as the list scrolls. */
export function UsageDialog({ account, paperTitle, onClose }: {
  account: string;
  /** The paper's title in this browser's library, or null (never sent anywhere). */
  paperTitle: (p: UsageProvenance) => string | null;
  onClose: () => void;
}) {
  const [days, setDays] = useState(savedPeriod);
  const [activity, setActivity] = useState<UsageActivity | null>(null);
  const [rows, setRows] = useState<UsageOperation[]>([]);
  const [totals, setTotals] = useState<UsageTotals | null>(null);
  const [activities, setActivities] = useState<UsageActivityCount[]>([]);
  const [next, setNext] = useState<UsageCursor | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'more' | 'failed'>('loading');
  const [open, setOpen] = useState<string | null>(null);
  const provenance = useMemo(() => recallProvenance(account), [account, rows]);
  const generation = useRef(0);
  const abort = useRef<AbortController | null>(null);

  const load = useCallback((before: UsageCursor | null) => {
    abort.current?.abort();
    const controller = new AbortController(); abort.current = controller;
    const mine = ++generation.current;
    setState(before ? 'more' : 'loading');
    loadUsage(account, { days, activity, before }, controller.signal).then(page => {
      if (mine !== generation.current) return;
      setRows(r => before ? [...r, ...page.operations.filter(o => !r.some(x => x.id === o.id))] : page.operations);
      if (!before) { setTotals(page.totals); if (!activity) setActivities(page.activities ?? []); }
      setNext(page.next); setState('ready');
    }, () => { if (mine === generation.current && !controller.signal.aborted) setState('failed'); });
  }, [account, days, activity]);

  useEffect(() => { setRows([]); setNext(null); setOpen(null); load(null); return () => abort.current?.abort(); }, [load]);

  // More rows as the list's end comes into view.
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const target = sentinel.current;
    if (!target || !next || state !== 'ready' || typeof IntersectionObserver === 'undefined') return;
    const observer = new IntersectionObserver(entries => { if (entries.some(e => e.isIntersecting)) load(next); }, { rootMargin: '200px' });
    observer.observe(target);
    return () => observer.disconnect();
  }, [next, state, load]);

  const choosePeriod = (value: number) => {
    setDays(value);
    try { localStorage.setItem(PERIOD_KEY, String(value)); } catch { /* a per-browser convenience only */ }
  };
  const chips = activities.length > 1 ? activities : [];
  // The All view's credits by activity (owner, build 82), from the period's per-activity totals (the whole window).
  const slices = useMemo(() => activity ? [] : usageSlices(activities), [activity, activities]);

  return <Dialog open onClose={onClose} title="Your AI usage" className="usage-dialog" wide>
    <SheetTop onClose={onClose} testID="usage-close" trailing={
      <label className="usage-period"><span className="visually-hidden">Period</span>
        <select value={days} onChange={e => choosePeriod(Number(e.target.value))} data-testid="usage-period">
          {USAGE_PERIODS.map(d => <option key={d} value={d}>{periodLabel(d)}</option>)}
        </select></label>}>
      <h2>Your AI usage</h2><InfoTip text={USAGE_INFO} testID="usage-info" />
    </SheetTop>
    <p className="usage-totals" data-testid="usage-totals" aria-live="polite">
      {totals ? <><strong>{periodLabel(days)}</strong>{activity ? ` · ${activityName(activity)}` : ''}: {totalsText(totals)}</> : state === 'failed' ? '' : 'Loading…'}
    </p>
    {chips.length > 0 && <div className="chips usage-chips" role="toolbar" aria-label="Filter by activity">
      <button className={activity === null ? 'chip selected' : 'chip'} aria-pressed={activity === null} onClick={() => setActivity(null)} data-testid="usage-chip-all">All</button>
      {chips.map(a => <button key={a.activity} className={activity === a.activity ? 'chip selected' : 'chip'} aria-pressed={activity === a.activity}
        onClick={() => setActivity(a.activity)} data-testid={`usage-chip-${a.activity}`}>{activityName(a.activity)}</button>)}
    </div>}
    {slices.length > 0 && totals && <UsageRing slices={slices} total={totals.credits} onChoose={setActivity} />}
    {state === 'failed' && !rows.length ? <div className="usage-empty" data-testid="usage-error"><p className="issue" role="alert">Couldn’t load your AI usage.</p>
      <button className="secondary small" onClick={() => load(null)}>Try again</button></div>
      : state === 'loading' && !rows.length ? <div className="usage-empty" role="status" aria-label="Loading your AI usage"><div className="spinner" /></div>
      : !rows.length ? <div className="usage-empty" data-testid="usage-empty"><p><strong>No AI usage {days === 365 ? 'in the last 12 months' : `in the last ${days} days`}</strong></p>
        <p className="muted">Answers, explainers, podcasts and searches you ask for appear here with what they cost.</p></div>
      : <div className="usage-table" data-testid="usage-table">
        <div className="usage-row usage-head" aria-hidden="true">
          <span>Time</span><span>Activity</span><span>Model</span><span>Tokens</span><span className="usage-num">Cost</span>
        </div>
        <ul className="usage-list" aria-label="AI usage, newest first">
        {rows.map(op => {
          const p = provenance.get(op.id) ?? null;
          const title = p ? paperTitle(p) : null;
          const outcome = outcomeLabel(op.outcome);
          const expanded = open === op.id;
          return <li key={op.id} className={`usage-item${expanded ? ' open' : ''}`}>
            <button type="button" className="usage-row" aria-expanded={expanded} onClick={() => setOpen(expanded ? null : op.id)}
              data-testid={`usage-row-${op.id}`} data-outcome={op.outcome}>
              <span className="usage-time">{formatDateTime(Date.parse(op.created_at))}</span>
              <span className="usage-activity"><strong>{activityLabel(op.activity, p)}</strong>
                {title && <span className="usage-paper">{title}</span>}</span>
              <span className="usage-model">{modelLabel(op.model)}</span>
              <span className="usage-tokens">{reportsTokens(op.outcome) ? tokensText(op) : '—'}</span>
              <span className="usage-num usage-cost"><strong>{creditsText(op)}</strong>
                {outcome && <span className={`usage-outcome ${op.outcome}`}>{outcome}</span>}</span>
              {/* A phone's second line: the three columns above in one line of fine print. */}
              <span className="usage-meta">{[formatDateTime(Date.parse(op.created_at)), modelLabel(op.model), reportsTokens(op.outcome) ? tokensText(op) : '—']
                .filter(x => x !== '—').join(' · ')}</span>
            </button>
            {expanded && <ul className="usage-parts" data-testid={`usage-parts-${op.id}`}>
              {op.parts.map(part => <li key={`${part.part}/${part.model}`}>
                <span>{partLabel(part.part)}{part.calls > 1 ? ` ×${part.calls}` : ''}</span><span className="muted">{modelLabel(part.model)}</span>
                {reportsTokens(op.outcome) && <span className="usage-tokens">{tokensText(part, true)}{part.pending ? ' · still being counted' : ''}</span>}</li>)}
              {!op.parts.length && <li><span className="muted">No model was called.</span></li>}
              <li className="fine">{unreportedTokens(op.outcome) ?? (op.paid_by === 'gradstep' ? 'Paid by Gradstep, not your credits.' : op.parts.length > 1
                ? 'One charge for the whole request; the parts show where its tokens went.' : 'Charged from the tokens the provider reported.')}</li>
            </ul>}
          </li>;
        })}
        </ul>
        {next && <div ref={sentinel} className="usage-more">
          {state === 'failed' ? <><span className="issue">Couldn’t load more.</span> <button className="link" onClick={() => load(next)}>Try again</button></>
            : <button className="link" onClick={() => load(next)} disabled={state === 'more'} data-testid="usage-more">{state === 'more' ? 'Loading…' : 'Show more'}</button>}
        </div>}
      </div>}
  </Dialog>;
}
