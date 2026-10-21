import React, { useEffect, useMemo, useRef, useState } from 'react';
import type { Budget, Health as HealthData } from './backend';
import { providerName } from './provider-hours';
import { BarList, ChartFrame, clock, columnPath, COUNT_STEPS, dayLong, formatDay, humanize, Legend, linePath, MARGIN, niceTicks, percent, plural, runs,
  Stat, timeScale, Tooltip, useDayCursor, useWidth, XAxis, YGrid } from './charts';

// The owner's Health tab (docs/architecture/ADMIN_HEALTH.md): are people coming and staying, what do they do, is it
// working, what does it cost. One read of v1_admin_health per window, refreshed every minute while the page is open.

type Series = { key: string; tone: string; label: string; values: number[] };

export const HEALTH_WINDOWS = [7, 30, 90];
const REFRESH_MS = 60_000;
const usd = (micro: number, digits = 2) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: digits, maximumFractionDigits: digits }).format(micro / 1_000_000);
// Sub-cent amounts (an overrun on one small request) in micro-USD, so they never read as $0.000.
const precise = (micro: number) => micro < 10_000 ? `${micro.toLocaleString()} micro-USD` : usd(micro, micro >= 1_000_000 ? 2 : 4);
const dollarsShort = (micro: number) => micro >= 100_000_000 ? usd(micro, 0) : micro >= 1_000_000 ? usd(micro, 2) : usd(micro, micro ? 3 : 0);
// Every model call goes through OpenRouter since 2026-10-18 (migration 089); the direct providers remain only as history.
const PROVIDERS: Record<string, string> = { openrouter: 'OpenRouter (all AI: chat, tags, podcasts)', anthropic: 'Anthropic direct (retired 2026-10-18)', deepseek: 'DeepSeek direct (retired 2026-10-18)', google: 'Google direct voices (retired 2026-10-18)',
  tavily: 'Tavily (web search)', mathpix: 'Mathpix (retired OCR)', ingest: 'Paper lookups' };
const providerTone = (p: string) => ['openrouter', 'anthropic', 'deepseek', 'google', 'tavily'].includes(p) ? `p-${p}` : 'p-other';
const CODES: Record<string, string> = { metadata_unavailable: 'Couldn’t find the paper', script_evidence_rejected: 'Script failed its evidence check',
  provider_unavailable: 'Provider unavailable', insufficient_credits: 'Not enough credits', script_incomplete: 'Script came back incomplete',
  speech_rejected: 'Voice provider refused the script', source_too_large: 'Paper too long for an episode', unknown: 'Unknown' };
const codeName = (code: string) => CODES[code] ?? humanize(code);

export function Health({ load, budget, reloadKey, days, onDays }: {
  load: (days: number) => Promise<HealthData>; budget: Budget | null; reloadKey: number; days: number; onDays: (days: number) => void;
}) {
  const [data, setData] = useState<HealthData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [tick, setTick] = useState(0);
  const request = useRef(0);

  useEffect(() => {
    const id = ++request.current;
    setLoading(true); setError('');
    load(days).then(next => { if (id === request.current) setData(next); })
      .catch(e => { if (id === request.current) setError(e instanceof Error ? e.message : 'Health metrics are unavailable.'); })
      .finally(() => { if (id === request.current) setLoading(false); });
  }, [days, load, reloadKey, tick]);
  // A minute's refresh while the page is visible; a hidden tab waits and refreshes when it comes back.
  useEffect(() => {
    const timer = setInterval(() => { if (document.visibilityState === 'visible') setTick(n => n + 1); }, REFRESH_MS);
    const back = () => { if (document.visibilityState === 'visible') setTick(n => n + 1); };
    document.addEventListener('visibilitychange', back);
    return () => { clearInterval(timer); document.removeEventListener('visibilitychange', back); };
  }, []);

  const view = useMemo(() => data ? derive(data, budget) : null, [data, budget]);
  return <div className="health">
    <div className="toolbar">
      <div className="segmented" role="group" aria-label="Time window">
        {HEALTH_WINDOWS.map(w => <button key={w} type="button" aria-pressed={days === w} className={days === w ? 'selected' : ''} onClick={() => onDays(w)}>{w} days</button>)}
      </div>
      <span className="muted" role="status">{loading && !data ? 'Loading…' : data ? `Updated ${clock.format(new Date(data.generated_at))} · refreshes every minute · days are UTC` : ''}</span>
    </div>
    {error && <div className="error" role="alert">{error} <button type="button" className="quiet inline" onClick={() => setTick(n => n + 1)}>Try again</button></div>}
    {!view || !data ? (!error && <section className="panel"><p className="empty">Loading health…</p></section>) : <div className={loading ? 'refetching' : undefined}>
      <Attention items={view.attention} />

      <h2 className="group-title">People</h2>
      <div className="metrics headline">
        <Stat label="Accounts" value={data.people.accounts.toLocaleString()} note={`${plural(data.people.new_in_window, 'new account')} in ${data.days} days`} />
        <Stat label="Active this week" value={data.people.active_7d.toLocaleString()} note={data.people.accounts ? `${percent(data.people.active_7d / data.people.accounts)} of accounts` : 'No accounts yet'} />
        <Stat label="Active in 30 days" value={data.people.active_30d.toLocaleString()} note={data.people.accounts ? `${percent(data.people.active_30d / data.people.accounts)} of accounts` : '—'} />
        <Stat label="Came back this week" value={data.people.returning_7d.toLocaleString()} note="Active this week, joined before it" />
        <Stat label="Sign-ups" value={data.people.new_in_window.toLocaleString()} note={`Last ${data.days} days`} />
      </div>
      <section className="panel" aria-labelledby="active-title">
        <div className="chart-heading"><div><h2 id="active-title">Active accounts</h2><p className="muted">Accounts that used the service each day (any request: library, sync, chat, feed, podcasts). The line counts the 7 days to each day.</p></div>
          <Legend items={[{ tone: 'ready', label: 'Active that day' }, { tone: 'p90', label: 'Active in 7 days', shape: 'line' }]} /></div>
        <DailyBars name="Active accounts" days={view.people} series={[{ key: 'active', tone: 'ready', label: 'active that day', values: data.people.daily.map(d => d.active) }]}
          line={{ tone: 'p90', label: 'active in 7 days', values: data.people.daily.map(d => d.active_7d) }} empty="No activity recorded in this window yet." />
      </section>
      <div className="two-columns">
        <section className="panel" aria-labelledby="signups-title"><h2 id="signups-title">Sign-ups per day</h2>
          <p className="muted">{plural(data.people.daily.slice(-7).reduce((n, d) => n + d.new, 0), 'sign-up')} in the last 7 days; {(data.people.new_in_window / data.days).toFixed(1)} a day over {data.days} days.</p>
          <DailyBars name="Sign-ups" compact days={view.people} series={[{ key: 'new', tone: 'p50', label: 'new accounts', values: data.people.daily.map(d => d.new) }]} empty="No sign-ups in this window." />
        </section>
        <section className="panel" aria-labelledby="use-title"><h2 id="use-title">What people do</h2>
          <div className="mini-stats"><Stat label="Papers added" value={data.use.papers_added.toLocaleString()} />
            <Stat label="Chat answers" value={data.use.chat_answers.toLocaleString()} note={plural(data.use.chatting_accounts, 'account')} />
            <Stat label="Podcasts started" value={data.use.podcasts_started.toLocaleString()} /></div>
          <DailyBars name="Use per day" compact days={view.people} series={[
            { key: 'papers', tone: 'p50', label: 'papers added', values: data.use.daily.map(d => d.papers) },
            { key: 'chats', tone: 'p-deepseek', label: 'chat answers', values: data.use.daily.map(d => d.chats) },
            { key: 'podcasts', tone: 'p-google', label: 'podcasts', values: data.use.daily.map(d => d.podcasts) }]} empty="Nothing used in this window." />
          <Legend items={[{ tone: 'p50', label: 'Papers added' }, { tone: 'p-deepseek', label: 'Chat answers' }, { tone: 'p-google', label: 'Podcasts' }]} />
        </section>
      </div>

      <h2 className="group-title">Is it working?</h2>
      <div className="metrics headline">
        <Stat label="Paper adds failed" value={data.reliability.papers_failed.toLocaleString()} note={data.use.papers_added ? `${percent(data.reliability.papers_failed / data.use.papers_added)} of ${data.use.papers_added.toLocaleString()}` : 'No papers added'} />
        <Stat label="Podcasts failed" value={data.reliability.podcasts_failed.toLocaleString()} note={data.use.podcasts_started ? `${percent(data.reliability.podcasts_failed / data.use.podcasts_started)} of ${data.use.podcasts_started}; ${data.reliability.podcasts_ready} ready` : 'No podcasts started'} />
        {data.early_endings
          ? <Stat label="Answers not charged" value={data.early_endings.uncharged.toLocaleString()}
            note={`Ended early (provider, server, limits, dropped, refused): ${usd(data.early_endings.absorbed_microusd)} paid by Gradstep${data.reliability.chats_unsettled ? `; ${plural(data.reliability.chats_unsettled, 'answer')} still open` : ''}`} />
          : <Stat label="Chat answers not charged" value={data.reliability.chats_unsettled.toLocaleString()} note="Still in progress, or released after a failure" />}
        <Stat label="Open reports" value={data.reliability.reports_open.toLocaleString()} note="In Support" />
        <Stat label="Reader on the device" value="—" note="Not visible here: papers are prepared on the device. TestFlight and reports carry those failures." />
      </div>
      <div className="two-columns">
        <section className="panel" aria-labelledby="paper-failures-title"><h2 id="paper-failures-title">Why paper adds fail</h2>
          <BarList tone="failed" noun="failed add" empty="No paper adds failed in this window." rows={Object.entries(data.reliability.paper_failure_codes).map(([code, n]) => ({ key: code, label: codeName(code), value: n }))} />
        </section>
        <section className="panel" aria-labelledby="podcast-failures-title"><h2 id="podcast-failures-title">Why podcasts fail</h2>
          <BarList tone="failed" noun="failed episode" empty="No podcast failed in this window." rows={Object.entries(data.reliability.podcast_failure_codes).map(([code, n]) => ({ key: code, label: codeName(code), value: n }))} />
        </section>
      </div>

      {data.providers && <section className="panel" aria-labelledby="provider-errors-title">
        <div className="chart-heading"><div><h2 id="provider-errors-title">Provider errors</h2><p className="muted">Calls to outside providers that failed (overloaded, 5xx,
          timeouts, dropped connections) or were throttled (429s), per day. Each failure costs one feature, never the app; the hour-by-hour table is on Reliability.</p></div>
          <Legend items={view.errorProviders.map(p => ({ tone: providerTone(p), label: providerName(p) }))} /></div>
        <DailyBars name="Provider errors" compact days={view.people} series={view.errorProviders.map(p => ({ key: p, tone: providerTone(p), label: `${providerName(p)} errors`,
          values: data.providers!.daily.map(d => (d.by_provider[p]?.failed ?? 0) + (d.by_provider[p]?.throttled ?? 0)) }))} empty="No provider errors in this window." />
        {data.providers.last_hour.length > 0 && <ul className="provider-hour" aria-label="Last hour by provider">{data.providers.last_hour.map(r => {
          const errors = r.failed + r.throttled, open = data.providers!.breakers.find(b => b.provider === r.provider);
          return <li key={r.provider} className={open ? 'open' : r.calls >= 20 && errors / r.calls >= 0.05 ? 'bad' : undefined}>
            <strong>{providerName(r.provider)}</strong>
            <span>{r.calls.toLocaleString()} calls in the last hour</span>
            <span>{errors ? `${percent(errors / r.calls)} failed or throttled` : 'no errors'}</span>
            <span>{r.latency_ms_avg == null ? '' : `${(r.latency_ms_avg / 1000).toFixed(1)} s average`}</span>
            {open && <span className="badge warning">Paused · {open.state === 'half_open' ? 'testing' : 'cooling off'}</span>}
          </li>;
        })}</ul>}
      </section>}

      <h2 className="group-title">What it costs</h2>
      <div className="metrics headline">
        <Stat label="This month" value={usd(data.money.month_to_date_microusd)} note={budget ? `of ${usd(budget.limit_microusd, 0)} provider budget` : 'Provider usage'} />
        <Stat label="Month forecast" value={usd(view.forecast)} note={`At this month's pace${budget ? `; ${percent(view.forecast / Math.max(1, budget.limit_microusd))} of budget` : ''}`} />
        <Stat label="Per active account" value={view.perActive == null ? '—' : usd(view.perActive)} note={`Last ${data.days} days of spend ÷ accounts active in 30 days`} />
        <Stat label="Chat paper cache" value={view.cacheShare == null ? '—' : percent(view.cacheShare)} note="Of chat input read from the prompt cache (cheapest)" />
        <Stat label="Credits used" value={data.money.credits_consumed.toLocaleString()} note={`${data.money.credits_granted.toLocaleString()} granted in ${data.days} days`} />
      </div>
      <section className="panel" aria-labelledby="spend-title">
        <div className="chart-heading"><div><h2 id="spend-title">Provider spend per day</h2><p className="muted">Estimated from each call's usage at the provider's rates; includes test runs, which cost real money.</p></div>
          <Legend items={view.providers.map(p => ({ tone: providerTone(p), label: PROVIDERS[p] ?? humanize(p) }))} /></div>
        <DailyBars name="Provider spend" money days={view.people} series={view.providers.map(p => ({ key: p, tone: providerTone(p), label: PROVIDERS[p] ?? humanize(p),
          values: data.money.daily.map(d => d.by_provider[p] ?? 0) }))} empty="No provider spend in this window." />
      </section>
      <section className="panel" aria-labelledby="scale-title"><h2 id="scale-title">At 100 and 1,000 active accounts</h2>
        {view.perActive == null ? <p className="empty">Projections start once accounts are active.</p> : <>
          <div className="scale-rows">{[100, 1000].map(n => { const month = view.perActiveMonth! * n; return <div key={n}>
            <span>{n.toLocaleString()} active accounts</span><strong>{usd(month, 0)} a month</strong>
            <span className={budget && month > budget.limit_microusd ? 'bad' : 'muted'}>{budget ? (month > budget.limit_microusd ? `${(month / budget.limit_microusd).toFixed(1)}× the provider budget` : 'within the provider budget') : ''}</span></div>; })}</div>
          <p className="muted">A straight line from the last {data.days} days: {usd(view.perActiveMonth!)} per active account per month. Real costs bend with how much each person chats, how many episodes they make, and the paper cache.</p>
        </>}
      </section>
    </div>}
  </div>;
}

type Item = { tone: 'warning' | 'info'; text: string };
function derive(data: HealthData, budget: Budget | null) {
  const today = new Date(data.today + 'T00:00:00Z'), monthStart = new Date(data.month_start + 'T00:00:00Z');
  const elapsed = Math.max(1, Math.round((today.getTime() - monthStart.getTime()) / 86_400_000) + 1);
  const monthDays = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() + 1, 0)).getUTCDate();
  const forecast = data.money.month_to_date_microusd / elapsed * monthDays;
  const perActive = data.people.active_30d ? data.money.window_microusd / data.people.active_30d : null;
  const perActiveMonth = perActive == null ? null : perActive * 30 / data.days;
  const cache = data.money.chat_cache, cacheTotal = cache.read_tokens + cache.write_tokens + cache.input_tokens;
  const providers = Object.entries(data.money.by_provider).filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1]).map(([p]) => p);
  const attention: Item[] = [];
  // Migration 079: an overrun is recorded, not a pause; more than `pause_after` in the window pause the month (the tripwire).
  const anomalies = data.anomalies, tripped = anomalies?.recent.find(a => a.paused_month);
  if (budget && !budget.work_enabled) attention.push({ tone: 'warning', text: tripped
    ? `New paid work (chat answers, podcasts) is paused: more than ${anomalies!.pause_after} operations cost more than their ceiling within ${anomalies!.window_minutes} minutes (the overrun tripwire, ${clock.format(new Date(tripped.at))}). Check Spending, then resume it on Overview.`
    : 'New paid work (chat answers, podcasts) is paused. Resume it on Overview.' });
  if (anomalies && anomalies.last_24h > 0) {
    const worst = [...anomalies.recent].sort((a, b) => (b.observed_microusd - b.ceiling_microusd) - (a.observed_microusd - a.ceiling_microusd))[0];
    const tests = anomalies.last_24h_test ? ` (${anomalies.last_24h_test} on test accounts)` : '';
    attention.push({ tone: 'warning', text: `${plural(anomalies.last_24h, 'operation')} cost more than ${anomalies.last_24h === 1 ? 'its' : 'their'} ceiling in the last 24 hours${tests}; recorded, not paused${worst ? ` (largest: ${precise(worst.observed_microusd)} against a ${precise(worst.ceiling_microusd)} ceiling, ${humanize(worst.operation_kind)})` : ''}. ${anomalies.in_window} of ${anomalies.pause_after} toward the hourly tripwire.` });
  }
  // CHAT.md "When an answer stops early": an account with many unpaid early endings today is shown, never blocked.
  for (const a of data.early_endings?.accounts_over_today ?? []) {
    attention.push({ tone: 'warning', text: `Account ${a.account_id.slice(0, 8)} had ${a.uncharged} answers end early without charge today (more than ${data.early_endings!.attention_daily}); Gradstep paid ${dollarsShort(a.absorbed_microusd)}. They are still served: look it up on Accounts.` });
  }
  if (budget && forecast > budget.limit_microusd) attention.push({ tone: 'warning', text: `At this pace the month ends near ${usd(forecast, 0)}, over the ${usd(budget.limit_microusd, 0)} provider budget.` });
  else if (budget && budget.spent_microusd + budget.reserved_microusd > 0.8 * budget.limit_microusd) attention.push({ tone: 'warning', text: `${percent((budget.spent_microusd + budget.reserved_microusd) / budget.limit_microusd)} of this month's provider budget is used or reserved.` });
  const badDay = data.use.daily.map((d, i) => ({ d, failed: data.reliability.daily[i]?.papers_failed ?? 0 })).filter(x => x.d.papers >= 5 && x.failed / x.d.papers > 0.1).pop();
  if (badDay) attention.push({ tone: 'warning', text: `${badDay.failed} of ${badDay.d.papers} paper adds failed on ${formatDay(badDay.d.day, dayLong)}.` });
  if (data.reliability.podcasts_failed && data.reliability.podcasts_failed / Math.max(1, data.use.podcasts_started) > 0.2) {
    const top = Object.entries(data.reliability.podcast_failure_codes).sort((a, b) => b[1] - a[1])[0];
    attention.push({ tone: 'warning', text: `${data.reliability.podcasts_failed} of ${data.use.podcasts_started} podcast episodes failed${top ? `, most often “${codeName(top[0])}”` : ''}.` });
  }
  // Our servers never contact arXiv (ARXIV_DEVICE_ONLY.md §6.5): any attempt in the last hour, refused or not, is shown.
  const arxiv = (data.providers?.last_hour ?? []).find(r => r.provider === 'arxiv');
  if (arxiv && arxiv.calls > 0) attention.push({ tone: 'warning', text: `Our servers tried to reach arXiv ${arxiv.calls.toLocaleString()} time${arxiv.calls === 1 ? '' : 's'} in the last hour. They must never contact arXiv: find the caller in the logs (event arxiv_egress).` });
  // Outside providers (RESILIENCE.md): a breaker open now, or 5 % or more of the last hour's calls failing (with 20 or more calls).
  for (const breaker of data.providers?.breakers ?? []) {
    attention.push({ tone: 'warning', text: `${providerName(breaker.provider)} kept failing, so calls to it are paused${breaker.reopen_at && breaker.state === 'open'
      ? ` until ${clock.format(new Date(breaker.reopen_at))}` : ' while one test call checks it'}; only the features that use it are affected.` });
  }
  for (const r of data.providers?.last_hour ?? []) {
    const errors = r.failed + r.throttled;
    if (r.calls >= 20 && errors / r.calls >= 0.05 && !data.providers!.breakers.some(b => b.provider === r.provider)) {
      attention.push({ tone: 'warning', text: `${percent(errors / r.calls)} of ${r.calls.toLocaleString()} calls to ${providerName(r.provider)} failed or were throttled in the last hour.` });
    }
  }
  // These groups name the logical provider, including historical direct calls. Current model calls bill through
  // OpenRouter; use the attempt's transport metadata rather than telling an operator to fund the model maker.
  const billing = data.provider_billing;
  if (billing && billing.last_24h > 0) {
    const who = Object.entries(billing.by_provider).sort((a, b) => b[1] - a[1]).map(([p, n]) => `${providerName(p)} (${n.toLocaleString()})`).join(', ');
    attention.push({ tone: 'warning', text: billing.last_hour > 0
      ? `Billing refusals in the last hour: ${who}. Current model calls use OpenRouter. Inspect the affected attempts in Spending and check the recorded billing provider's credit balance.`
      : `Billing refusals in the last 24 hours: ${who} (last at ${billing.last_at ? new Date(billing.last_at).toLocaleTimeString() : 'unknown'}). Current model calls use OpenRouter; check the attempts in Spending for their billing provider.` });
  }
  // Account deletion (migration 128): the worker's sweep retries with back-off; a deletion unfinished 30 days after the
  // account closed still holds personal rows or files and needs a look (scripts/finish-account-deletion.mjs).
  const deletions = data.account_deletions;
  if (deletions && deletions.stalled > 0) attention.push({ tone: 'warning', text: `${plural(deletions.stalled, 'account deletion has', 'account deletions have')} not finished more than 30 days after the account closed${deletions.top_code ? ` (most often “${codeName(deletions.top_code)}”)` : ''}. Personal data or files remain; check worker_account_deletion_status.` });
  if (data.reliability.reports_open) attention.push({ tone: 'info', text: `${plural(data.reliability.reports_open, 'support report is', 'support reports are')} open.` });
  const errorTotals = new Map<string, number>();
  for (const day of data.providers?.daily ?? []) for (const [p, n] of Object.entries(day.by_provider)) errorTotals.set(p, (errorTotals.get(p) ?? 0) + n.failed + n.throttled);
  const errorProviders = [...errorTotals].filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1]).map(([p]) => p);
  return { people: data.people.daily, forecast, perActive, perActiveMonth, cacheShare: cacheTotal ? cache.read_tokens / cacheTotal : null, providers, errorProviders, attention };
}

function Attention({ items }: { items: Item[] }) {
  if (!items.length) return <p className="all-clear" role="status"><span aria-hidden="true">✓</span>Nothing needs attention.</p>;
  return <ul className="attention" aria-label="Needs attention">{items.map((item, i) => <li key={i} className={item.tone}><span aria-hidden="true">{item.tone === 'warning' ? '!' : 'i'}</span>{item.text}</li>)}</ul>;
}

// Stacked daily columns (counts or dollars) with an optional line on the same scale.
function DailyBars({ name, days, series, line, money = false, compact = false, empty }: {
  name: string; days: { day: string }[]; series: Series[]; line?: { tone: string; label: string; values: number[] }; money?: boolean; compact?: boolean; empty: string;
}) {
  const [ref, width] = useWidth();
  const cursor = useDayCursor(days.length, width);
  const totals = days.map((_, i) => series.reduce((n, s) => n + (s.values[i] ?? 0), 0));
  if (!totals.some(Boolean) && !(line?.values.some(Boolean))) return <p className="empty">{empty}</p>;
  const top = 10, plotH = compact ? 120 : 170, bottom = 30, height = top + plotH + bottom, base = top + plotH;
  const format = (v: number) => money ? dollarsShort(v) : v.toLocaleString();
  const max = Math.max(...totals, ...(line?.values ?? [0]));
  const { top: yMax, ticks } = money ? niceTicks(max / 10_000, COUNT_STEPS) : niceTicks(max, COUNT_STEPS);
  const scale = money ? 10_000 : 1;
  const y = (v: number) => base - (v / scale / yMax) * plotH;
  const s = timeScale(width, days.length), x = s.x, a = cursor.active, barW = Math.max(2, Math.min(22, s.step * 0.62));
  const summary = `${name} over ${days.length} days: ${series.map(se => `${format(se.values.reduce((n, v) => n + v, 0))} ${se.label}`).join(', ')}.`;
  const tip = a == null ? null : <Tooltip x={x(a)} width={width} title={formatDay(days[a].day, dayLong)} rows={[
    ...series.map(se => ({ tone: se.tone, value: format(se.values[a] ?? 0), label: se.label })),
    ...(line ? [{ tone: line.tone, value: format(line.values[a] ?? 0), label: line.label }] : [])]} />;
  return <ChartFrame frameRef={ref} width={width} label={`${name} chart`} summary={summary} height={height} cursor={cursor} tip={tip}>
    {a != null && <rect className="hover-band" x={x(a) - s.step / 2} y={top - 6} width={s.step} height={plotH + 6} />}
    <YGrid ticks={ticks} y={v => y(v * scale)} width={width} label={t => money ? dollarsShort(t * scale) : t.toLocaleString()} />
    {days.map((day, i) => {
      const parts = series.filter(se => (se.values[i] ?? 0) > 0);
      let below = 0;
      return <g key={day.day}>{parts.map((se, k) => {
        const v = se.values[i], y0 = y(below), y1 = y(below + v); below += v;
        return <path key={se.key} className={`fill tone-${se.tone}`} d={columnPath(x(i) - barW / 2, y1, barW, Math.max(1, y0 - y1 - (k ? 2 : 0)), k === parts.length - 1 ? 3 : 0)} />;
      })}</g>;
    })}
    {line && <g className={`series tone-${line.tone}`}>{runs(line.values.map(v => v)).map(r => r.length > 1
      ? <path key={r[0]} d={linePath(r, x, i => y(line.values[i]))} /> : <circle key={r[0]} cx={x(r[0])} cy={y(line.values[r[0]])} r={3} />)}</g>}
    <XAxis days={days} x={x} step={s.step} y={height - 8} width={width} />
    <rect className="hit" x={MARGIN.left} y={0} width={Math.max(0, width - MARGIN.left - MARGIN.right)} height={base} {...cursor.pointer} />
  </ChartFrame>;
}
