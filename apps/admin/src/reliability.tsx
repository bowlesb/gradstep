import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PipelineMetrics } from './backend';

// Reliability tab: import timing and failure analytics from v1_admin_pipeline_metrics
// (docs/architecture/PIPELINE_RELIABILITY.md). Charts are inline SVG measured to their
// container; every value is also available in a table.

type Day = { day: string; started: number; ready: number; failed: number; cancelled: number; p50: number | null; p90: number | null };
type Loaded = { days: number; metrics: PipelineMetrics };

const WINDOWS = [7, 30, 90];
const DAY_MS = 86_400_000;

const CAUSES: Record<string, string> = {
  download_failed: 'Couldn’t download', conversion_failed: 'Conversion failed', metadata_unavailable: 'Couldn’t find the paper',
  too_large: 'Too large', pdf_invalid: 'Not a valid PDF', insufficient_credits: 'Not enough credits', rate_limited: 'Rate limited',
  license_unverified: 'License unverified', unknown: 'Unknown',
  // Migration 027: a scheduled automatic retry, and the download causes readers are told.
  download_retrying: 'Download failed (retry scheduled)', pdf_restricted: 'Sign-in or paywall', source_blocked: 'Blocked by the website',
  source_unavailable: 'Website not responding', not_pdf: 'No PDF at the link',
};
const STAGE_ORDER = ['metadata', 'private_split', 'download', 'ocr_fund', 'ocr_submit', 'ocr_wait', 'render', 'needs_credits', 'failed'];
const STAGES: Record<string, string> = {
  metadata: 'Finding the paper', private_split: 'Preparing private copy', download: 'Downloading PDF', ocr_fund: 'Reserving credits',
  ocr_submit: 'Sending to Mathpix', ocr_wait: 'Mathpix converting', render: 'Rendering',
  needs_credits: 'Waiting for credits', failed: 'Failed, awaiting retry', source_only: 'Metadata ready; reader on device', done: 'Done',
};
const KINDS: Record<string, string> = { crash: 'Worker crashed', import: 'Import failed', stage: 'Step failed' };

const humanize = (value: string) => { const text = value.replaceAll('_', ' '); return text.charAt(0).toUpperCase() + text.slice(1); };
const causeName = (code: string | null) => code ? CAUSES[code] ?? humanize(code) : 'Unknown';
const stageName = (stage: string | null) => stage ? STAGES[stage] ?? humanize(stage) : '—';
const stageRank = (stage: string) => { const i = STAGE_ORDER.indexOf(stage); return i < 0 ? STAGE_ORDER.length : i; };

export function duration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return '—';
  if (seconds < 10) return `${seconds.toFixed(1)}s`;
  const total = Math.round(seconds);
  if (total < 60) return `${total}s`;
  if (total < 3600) { const m = Math.floor(total / 60), s = total % 60; return s ? `${m}m ${String(s).padStart(2, '0')}s` : `${m}m`; }
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60);
  return m ? `${h}h ${m}m` : `${h}h`;
}
const minutes = (value: number) => value < 60 ? `${value} min` : duration(value * 60);
const percent = (rate: number | null) => rate == null ? '—' : rate === 0 ? '0%' : rate < 0.1 ? `${(rate * 100).toFixed(1)}%` : `${Math.round(rate * 100)}%`;
const plural = (n: number, one: string, many = one + 's') => `${n.toLocaleString()} ${n === 1 ? one : many}`;
const dayShort = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
const dayLong = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' });
const moment = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
const clock = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
const formatDay = (day: string, format = dayShort) => format.format(new Date(day + 'T00:00:00Z'));

// `daily` omits days without events; fill the whole window so gaps stay visible.
function fillDays(metrics: PipelineMetrics, count: number): Day[] {
  const start = Date.parse(metrics.since.slice(0, 10) + 'T00:00:00Z');
  const byDay = new Map(metrics.daily.map(d => [d.day.slice(0, 10), d]));
  return Array.from({ length: count }, (_, i) => {
    const day = new Date(start + i * DAY_MS).toISOString().slice(0, 10), d = byDay.get(day);
    return { day, started: d?.started ?? 0, ready: d?.ready ?? 0, failed: d?.failed ?? 0, cancelled: d?.cancelled ?? 0, p50: d?.ready_p50_s ?? null, p90: d?.ready_p90_s ?? null };
  });
}
const failureRate = (d: { ready: number; failed: number }) => d.ready + d.failed ? d.failed / (d.ready + d.failed) : null;

// Older servers have no window summary: the headline then falls back to daily medians weighted by imports.
function weightedMedian(points: [number, number][]): number | null {
  const sorted = points.filter(([, w]) => w > 0).sort((a, b) => a[0] - b[0]);
  const total = sorted.reduce((sum, [, w]) => sum + w, 0);
  let seen = 0;
  for (const [value, weight] of sorted) { seen += weight; if (seen >= total / 2) return value; }
  return null;
}

export function Reliability({ load, reloadKey }: { load: (days: number) => Promise<PipelineMetrics>; reloadKey: number }) {
  const [days, setDays] = useState(30);
  const [data, setData] = useState<Loaded | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [attempt, setAttempt] = useState(0);
  const request = useRef(0);

  useEffect(() => {
    const id = ++request.current;
    setLoading(true); setError('');
    load(days).then(metrics => { if (id === request.current) setData({ days, metrics }); })
      .catch(e => { if (id === request.current) setError(e instanceof Error ? e.message : 'Reliability metrics are unavailable.'); })
      .finally(() => { if (id === request.current) setLoading(false); });
  }, [days, load, reloadKey, attempt]);

  const view = useMemo(() => {
    if (!data) return null;
    const series = fillDays(data.metrics, data.days);
    const totals = series.reduce((t, d) => ({ started: t.started + d.started, ready: t.ready + d.ready, failed: t.failed + d.failed, cancelled: t.cancelled + d.cancelled }), { started: 0, ready: 0, failed: 0, cancelled: 0 });
    const exact = data.metrics.summary;
    const median = exact ? exact.ready_p50_s : weightedMedian(series.filter(d => d.p50 != null).map(d => [d.p50!, d.ready]));
    return { series, totals, median, exact: exact != null, p90: exact?.ready_p90_s ?? null, rate: failureRate(totals), metrics: data.metrics, days: data.days };
  }, [data]);

  return <div className="reliability">
    <div className="toolbar">
      <div className="segmented" role="group" aria-label="Time window">
        {WINDOWS.map(w => <button key={w} type="button" aria-pressed={days === w} className={days === w ? 'selected' : ''} onClick={() => setDays(w)}>{w} days</button>)}
      </div>
      <span className="muted" role="status">{loading ? 'Updating…' : view ? `Updated ${clock.format(new Date(view.metrics.generated_at))} · days are UTC` : ''}</span>
    </div>
    {error && <div className="error" role="alert">{error} <button type="button" className="quiet inline" onClick={() => setAttempt(n => n + 1)}>Try again</button></div>}
    {!view ? (!error && <section className="panel"><p className="empty">Loading reliability metrics…</p></section>) : <div className={loading ? 'refetching' : undefined}>
      <div className="metrics headline">
        <Stat label="Imports started" value={view.totals.started.toLocaleString()} note={`Last ${view.days} days`} />
        <Stat label="Ready" value={view.totals.ready.toLocaleString()} note={`${view.totals.cancelled.toLocaleString()} cancelled`} />
        <Stat label="Failed" value={view.totals.failed.toLocaleString()} note={view.metrics.stuck.length ? `${view.metrics.stuck.length} stuck now` : 'Nothing stuck now'} />
        <Stat label="Failure rate" value={percent(view.rate)} note={view.rate == null ? 'No imports finished' : `${view.totals.failed} of ${(view.totals.ready + view.totals.failed).toLocaleString()} finished`} />
        <Stat label="Median time to ready" value={duration(view.median)} note={view.exact ? (view.p90 != null ? `90th percentile ${duration(view.p90)}` : 'Over this window') : 'Approx., from daily medians'} />
      </div>
      {view.metrics.stuck.length > 0 && <p className="notice" role="note"><span aria-hidden="true">!</span><span>{plural(view.metrics.stuck.length, 'paper has', 'papers have')} been in one step for more than 15 minutes. <a href="#stuck-now">Review stuck papers</a></span></p>}

      <section className="panel" aria-labelledby="ttr-title">
        <div className="chart-heading"><div><h2 id="ttr-title">Time to ready</h2><p className="muted">From Add to readable, per day. Gaps are days when no import finished.</p></div>
          {view.median != null && <Legend items={[{ tone: 'p50', label: 'Median', shape: 'line' }, { tone: 'p90', label: '90th percentile', shape: 'line' }]} />}</div>
        <TimeToReady days={view.series} />
      </section>

      <section className="panel" aria-labelledby="outcomes-title">
        <div className="chart-heading"><div><h2 id="outcomes-title">Outcomes per day</h2><p className="muted">Imports reaching an outcome each day. Failure rate is failed ÷ (ready + failed).</p></div>
          {view.totals.ready + view.totals.failed + view.totals.cancelled > 0 && <Legend items={[{ tone: 'ready', label: 'Ready' }, { tone: 'failed', label: 'Failed' }, { tone: 'cancelled', label: 'Cancelled' }, { tone: 'rate', label: 'Failure rate', shape: 'line' }]} />}</div>
        <Outcomes days={view.series} />
        {view.series.some(d => d.started + d.ready + d.failed + d.cancelled > 0) && <DailyTable days={view.series} />}
      </section>

      <div className="two-columns">
        <section className="panel" aria-labelledby="causes-title"><h2 id="causes-title">Why imports fail</h2>
          <BarList tone="failed" noun="failed import" empty="No imports failed in this window."
            rows={Object.entries(view.metrics.failure_causes).map(([code, n]) => ({ key: code, label: causeName(code), value: n }))} />
        </section>
        <section className="panel" aria-labelledby="crashes-title"><h2 id="crashes-title">Worker crashes by step</h2>
          <BarList tone="crash" noun="crash" plural="crashes" empty="No worker crashes in this window."
            rows={Object.entries(view.metrics.crashes).map(([stage, n]) => ({ key: stage, label: stageName(stage), value: n }))} />
          <p className="muted">New imports stop at metadata; HTML readers and PDFs are prepared on the reader’s device. Earlier PDF/OCR stages remain visible as historical records. A crash records an expired worker lease.</p>
        </section>
      </div>

      <StepDurations stages={view.metrics.stages} />
      <Stuck stuck={view.metrics.stuck} />
      <RecentFailures failures={view.metrics.recent_failures} />
    </div>}
  </div>;
}

function Stat({ label, value, note }: { label: string; value: string; note?: string }) {
  return <section className="metric"><p>{label}</p><strong>{value}</strong>{note && <small>{note}</small>}</section>;
}

function Legend({ items }: { items: { tone: string; label: string; shape?: 'line' | 'rect' }[] }) {
  return <ul className="legend" aria-hidden="true">{items.map(item => <li key={item.tone}><span className={`key ${item.shape ?? 'rect'} tone-${item.tone}`} />{item.label}</li>)}</ul>;
}

// ── Chart geometry ───────────────────────────────────────────────────────────

const MARGIN = { left: 46, right: 10 };

// Measures the chart container so SVG text stays at its real size at any width.
function useWidth() {
  const [width, setWidth] = useState(0);
  const observer = useRef<ResizeObserver | null>(null);
  const ref = useCallback((element: HTMLDivElement | null) => {
    observer.current?.disconnect(); observer.current = null;
    if (!element) return;
    const update = () => setWidth(Math.floor(element.getBoundingClientRect().width));
    update();
    observer.current = new ResizeObserver(update); observer.current.observe(element);
  }, []);
  return [ref, width] as const;
}

function timeScale(width: number, n: number) {
  const step = Math.max(1, width - MARGIN.left - MARGIN.right) / n;
  return { step, x: (i: number) => MARGIN.left + step * (i + 0.5), index: (px: number) => Math.min(n - 1, Math.max(0, Math.floor((px - MARGIN.left) / step))) };
}

function niceTicks(max: number, steps: number[], target = 4) {
  const m = Math.max(max, steps[0]);
  const step = steps.find(s => m / s <= target) ?? Math.ceil(m / target);
  const top = Math.ceil(m / step) * step;
  return { top, ticks: Array.from({ length: Math.round(top / step) + 1 }, (_, i) => i * step) };
}
const COUNT_STEPS = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
const SECOND_STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400];
const tickDuration = (s: number) => s === 0 ? '0' : s < 60 ? `${s}s` : s < 3600 ? `${s / 60}m` : `${s / 3600}h`;

// Runs of consecutive indexes with a value; a missing day breaks the line.
function runs(values: (number | null)[]) {
  const out: number[][] = []; let current: number[] = [];
  values.forEach((v, i) => { if (v == null) { if (current.length) out.push(current); current = []; } else current.push(i); });
  if (current.length) out.push(current);
  return out;
}
const point = (x: number, y: number) => `${x.toFixed(1)},${y.toFixed(1)}`;
const linePath = (run: number[], x: (i: number) => number, y: (i: number) => number) => run.map((i, k) => `${k ? 'L' : 'M'}${point(x(i), y(i))}`).join('');

// A column with a rounded data end and a square baseline end.
function columnPath(x: number, y: number, w: number, h: number, radius: number) {
  const r = Math.max(0, Math.min(radius, w / 2, h));
  return `M${x},${y + h}V${y + r}A${r},${r} 0 0 1 ${x + r},${y}H${x + w - r}A${r},${r} 0 0 1 ${x + w},${y + r}V${y + h}Z`;
}

function XAxis({ days, x, step, y, width }: { days: Day[]; x: (i: number) => number; step: number; y: number; width: number }) {
  const every = [1, 2, 3, 7, 14, 30].find(k => k * step >= 56) ?? 30;
  const ticks: number[] = [];
  for (let i = days.length - 1; i >= 0; i -= every) ticks.push(i);
  return <g className="axis">{ticks.map(i => {
    const px = x(i), anchor = px + 22 > width ? 'end' : px - 22 < 0 ? 'start' : 'middle';
    return <text key={i} x={px} y={y} textAnchor={anchor}>{formatDay(days[i].day)}</text>;
  })}</g>;
}

function YGrid({ ticks, y, width, label }: { ticks: number[]; y: (v: number) => number; width: number; label: (v: number) => string }) {
  return <g className="grid">{ticks.map(t => <g key={t}>
    <line x1={MARGIN.left} x2={width - MARGIN.right} y1={y(t)} y2={y(t)} className={t === 0 ? 'baseline' : undefined} />
    <text x={MARGIN.left - 8} y={y(t)} dy="0.32em" textAnchor="end">{label(t)}</text>
  </g>)}</g>;
}

// Pointer and keyboard selection of a day, shared by both time charts.
function useDayCursor(n: number, width: number) {
  const [selected, setActive] = useState<number | null>(null);
  const active = selected != null && selected < n ? selected : null;
  const scale = timeScale(width, n);
  const pick = (e: React.PointerEvent<SVGRectElement>) => setActive(scale.index(e.clientX - e.currentTarget.ownerSVGElement!.getBoundingClientRect().left));
  return {
    active,
    // A tap selects the tapped day and keeps it until focus leaves the chart; a mouse clears it on leaving.
    pointer: { onPointerMove: pick, onPointerDown: pick, onPointerLeave: (e: React.PointerEvent) => { if (e.pointerType === 'mouse') setActive(null); } },
    keyboard: {
      onFocus: (e: React.FocusEvent) => { if (e.target === e.currentTarget) setActive(i => i ?? n - 1); },
      onBlur: () => setActive(null),
      onKeyDown: (e: React.KeyboardEvent) => {
        if (e.key === 'Escape') { setActive(null); return; }
        const moves: Record<string, (i: number) => number> = { ArrowLeft: i => i - 1, ArrowRight: i => i + 1, Home: () => 0, End: () => n - 1 };
        const move = moves[e.key]; if (!move) return;
        e.preventDefault(); setActive(i => Math.min(n - 1, Math.max(0, move(i != null && i < n ? i : n - 1))));
      },
    },
  };
}

type Cursor = ReturnType<typeof useDayCursor>;
type TipRow = { tone: string; value: string; label: string };

function ChartFrame({ frameRef, width, label, summary, height, cursor, tip, children }: {
  frameRef: (element: HTMLDivElement | null) => void; width: number; label: string; summary: string; height: number;
  cursor: Cursor; tip: React.ReactNode; children: React.ReactNode;
}) {
  return <div ref={frameRef} className="chart" tabIndex={0} role="group" aria-label={`${label}. Use the left and right arrow keys to read each day.`} {...cursor.keyboard}>
    {width > 0 ? <svg width={width} height={height} role="img" aria-label={summary}>{children}</svg> : <div className="chart-placeholder" style={{ height }} />}
    {width > 0 && tip}
  </div>;
}

function Tooltip({ x, width, title, rows, note }: { x: number; width: number; title: string; rows: TipRow[]; note?: string }) {
  const flip = x > width / 2;
  return <div className="chart-tooltip" role="status" style={flip ? { right: width - x + 14 } : { left: x + 14 }}>
    <p>{title}</p>
    {rows.map(row => <div key={row.label}><span className={`key line tone-${row.tone}`} aria-hidden="true" /><strong>{row.value}</strong><span>{row.label}</span></div>)}
    {note && <p className="tip-note">{note}</p>}
  </div>;
}

// ── Time to ready ───────────────────────────────────────────────────────────

function TimeToReady({ days }: { days: Day[] }) {
  const [ref, width] = useWidth();
  const cursor = useDayCursor(days.length, width);
  const finished = days.filter(d => d.p50 != null);
  if (!finished.length) return <p className="empty">No imports finished in this window.</p>;

  const height = 224, top = 12, bottom = 30, plotH = height - top - bottom;
  const { top: yMax, ticks } = niceTicks(Math.max(...finished.map(d => d.p90 ?? d.p50!)), SECOND_STEPS);
  const y = (v: number) => top + plotH - (v / yMax) * plotH;
  const s = timeScale(width, days.length), x = s.x, a = cursor.active;
  const p50 = days.map(d => d.p50), p90 = days.map(d => d.p90);
  const medians = finished.map(d => d.p50!);
  const summary = `Time to ready over the last ${days.length} days. The daily median ranged from ${duration(Math.min(...medians))} to ${duration(Math.max(...medians))}; ` +
    `the slowest daily 90th percentile was ${duration(Math.max(...finished.map(d => d.p90 ?? d.p50!)))}. Imports finished on ${finished.length} of ${days.length} days.`;
  const tip = a == null ? null : <Tooltip x={x(a)} width={width} title={formatDay(days[a].day, dayLong)} note={days[a].p50 == null ? 'No imports finished' : undefined} rows={days[a].p50 == null ? []
    : [{ tone: 'p50', value: duration(days[a].p50), label: 'median' }, { tone: 'p90', value: duration(days[a].p90), label: '90th percentile' }, { tone: 'none', value: days[a].ready.toLocaleString(), label: 'ready' }]} />;

  return <ChartFrame frameRef={ref} width={width} label="Time to ready chart" summary={summary} height={height} cursor={cursor} tip={tip}>
    <YGrid ticks={ticks} y={y} width={width} label={tickDuration} />
    {a != null && <line className="crosshair" x1={x(a)} x2={x(a)} y1={top} y2={top + plotH} />}
    {runs(days.map(d => d.p50 != null && d.p90 != null ? 1 : null)).filter(r => r.length > 1).map(r =>
      <path key={r[0]} className="band" d={linePath(r, x, i => y(p90[i]!)) + [...r].reverse().map(i => 'L' + point(x(i), y(p50[i]!))).join('') + 'Z'} />)}
    {([['p90', p90], ['p50', p50]] as const).map(([tone, values]) => <g key={tone} className={`series tone-${tone}`}>
      {runs(values).map(r => r.length > 1 ? <path key={r[0]} d={linePath(r, x, i => y(values[i]!))} /> : <circle key={r[0]} cx={x(r[0])} cy={y(values[r[0]]!)} r={4} />)}
      {a != null && values[a] != null && <circle className="focus-dot" cx={x(a)} cy={y(values[a]!)} r={5} />}
    </g>)}
    <XAxis days={days} x={x} step={s.step} y={height - 8} width={width} />
    <rect className="hit" x={MARGIN.left} y={0} width={Math.max(0, width - MARGIN.left - MARGIN.right)} height={top + plotH} {...cursor.pointer} />
  </ChartFrame>;
}

// ── Outcomes per day ────────────────────────────────────────────────────────

const OUTCOMES = ['ready', 'failed', 'cancelled'] as const;

function Outcomes({ days }: { days: Day[] }) {
  const [ref, width] = useWidth();
  const cursor = useDayCursor(days.length, width);
  const totals = days.map(d => d.ready + d.failed + d.cancelled);
  if (!totals.some(Boolean)) return <p className="empty">No imports reached an outcome in this window.</p>;

  const top = 10, barsH = 150, gap = 44, stripH = 44, bottom = 30;
  const height = top + barsH + gap + stripH + bottom, base = top + barsH, stripTop = base + gap;
  const rates = days.map(failureRate);
  const { top: yMax, ticks } = niceTicks(Math.max(...totals), COUNT_STEPS);
  const rateMax = [0.05, 0.1, 0.2, 0.25, 0.5, 1].find(v => v >= Math.max(0, ...rates.map(r => r ?? 0))) ?? 1;
  const y = (v: number) => base - (v / yMax) * barsH;
  const yRate = (v: number) => stripTop + stripH - (v / rateMax) * stripH;
  const s = timeScale(width, days.length), x = s.x, a = cursor.active, barW = Math.max(2, Math.min(24, s.step * 0.62));
  const sum = (key: 'ready' | 'failed' | 'cancelled') => days.reduce((n, d) => n + d[key], 0);
  const worst = days.reduce<Day | null>((w, d) => (failureRate(d) ?? 0) > (w ? failureRate(w) ?? 0 : 0) ? d : w, null);
  const summary = `Outcomes per day over the last ${days.length} days: ${sum('ready')} ready, ${sum('failed')} failed, ${sum('cancelled')} cancelled.` +
    (worst ? ` The highest daily failure rate was ${percent(failureRate(worst))} on ${formatDay(worst.day, dayLong)}.` : ' No imports failed.');
  const d = a == null ? null : days[a];
  const tip = a == null || !d ? null : <Tooltip x={x(a)} width={width} title={formatDay(d.day, dayLong)} rows={[
    { tone: 'ready', value: d.ready.toLocaleString(), label: 'ready' }, { tone: 'failed', value: d.failed.toLocaleString(), label: 'failed' },
    { tone: 'cancelled', value: d.cancelled.toLocaleString(), label: 'cancelled' }, { tone: 'rate', value: percent(failureRate(d)), label: 'failure rate' },
    { tone: 'none', value: d.started.toLocaleString(), label: 'started' }]} />;

  return <ChartFrame frameRef={ref} width={width} label="Outcomes per day chart" summary={summary} height={height} cursor={cursor} tip={tip}>
    {a != null && <rect className="hover-band" x={x(a) - s.step / 2} y={top - 6} width={s.step} height={height - bottom - top + 6} />}
    <YGrid ticks={ticks} y={y} width={width} label={t => t.toLocaleString()} />
    {days.map((day, i) => {
      const parts = OUTCOMES.filter(key => day[key] > 0);
      let below = 0;
      return <g key={day.day}>{parts.map((key, k) => {
        const y0 = y(below), y1 = y(below + day[key]); below += day[key];
        return <path key={key} className={`fill tone-${key}`} d={columnPath(x(i) - barW / 2, y1, barW, Math.max(1, y0 - y1 - (k ? 2 : 0)), k === parts.length - 1 ? 4 : 0)} />;
      })}</g>;
    })}
    <text className="strip-label" x={MARGIN.left} y={stripTop - 14}>Failure rate</text>
    <YGrid ticks={[0, rateMax]} y={yRate} width={width} label={percent} />
    <g className="series tone-rate">
      {runs(rates).map(r => r.length > 1 ? <path key={r[0]} d={linePath(r, x, i => yRate(rates[i]!))} /> : <circle key={r[0]} cx={x(r[0])} cy={yRate(rates[r[0]]!)} r={4} />)}
      {a != null && rates[a] != null && <circle className="focus-dot" cx={x(a)} cy={yRate(rates[a]!)} r={5} />}
    </g>
    <XAxis days={days} x={x} step={s.step} y={height - 8} width={width} />
    <rect className="hit" x={MARGIN.left} y={0} width={Math.max(0, width - MARGIN.left - MARGIN.right)} height={height - bottom} {...cursor.pointer} />
  </ChartFrame>;
}


function DailyTable({ days }: { days: Day[] }) {
  const active = days.filter(d => d.started + d.ready + d.failed + d.cancelled > 0).reverse();
  return <details className="table-view"><summary>Daily numbers</summary>
    <div className="table-scroll"><table>
      <caption className="sr-only">Imports per day, newest first. Days without imports are omitted.</caption>
      <thead><tr><th scope="col">Day</th><th scope="col" className="num">Started</th><th scope="col" className="num">Ready</th><th scope="col" className="num">Failed</th><th scope="col" className="num">Cancelled</th><th scope="col" className="num">Failure rate</th><th scope="col" className="num">Median</th><th scope="col" className="num">90th pct.</th></tr></thead>
      <tbody>{active.map(d => <tr key={d.day}><th scope="row">{formatDay(d.day, dayLong)}</th><td className="num">{d.started}</td><td className="num">{d.ready}</td><td className="num">{d.failed}</td><td className="num">{d.cancelled}</td><td className="num">{percent(failureRate(d))}</td><td className="num">{duration(d.p50)}</td><td className="num">{duration(d.p90)}</td></tr>)}</tbody>
    </table></div>
    <p className="muted">Days without imports are omitted.</p>
  </details>;
}

// ── Horizontal bars, steps, stuck, recent ──────────────────────────────────

// Horizontal bars as a labelled list; each bar is sized in percent of its own track, so it scales without measuring.
function BarList({ rows, tone, noun, plural: many, empty }: { rows: { key: string; label: string; value: number }[]; tone: string; noun: string; plural?: string; empty: string }) {
  const sorted = [...rows].filter(r => r.value > 0).sort((a, b) => b.value - a.value || a.label.localeCompare(b.label));
  if (!sorted.length) return <p className="empty">{empty}</p>;
  const total = sorted.reduce((n, r) => n + r.value, 0), max = sorted[0].value;
  const summary = `${plural(total, noun, many)} by ${noun === 'crash' ? 'step' : 'cause'}: ` + sorted.map(r => `${r.label} ${r.value}`).join(', ') + '.';
  return <ul className="bar-list" aria-label={summary}>{sorted.map(r => <li key={r.key}>
    <span className="bar-label">{r.label}</span>
    <svg className="bar" width="100%" height="10" aria-hidden="true"><rect className={`fill tone-${tone}`} width={`${(r.value / max) * 100}%`} height="10" rx="3" /><rect className={`fill tone-${tone}`} width="4" height="10" /></svg>
    <span className="bar-value"><strong>{r.value.toLocaleString()}</strong> <span className="muted">{percent(r.value / total)}</span></span>
  </li>)}</ul>;
}

function StepDurations({ stages }: { stages: PipelineMetrics['stages'] }) {
  const sorted = [...stages].sort((a, b) => stageRank(a.stage) - stageRank(b.stage) || a.stage.localeCompare(b.stage));
  return <section className="panel" aria-labelledby="steps-title"><h2 id="steps-title">Step durations</h2>
    <p className="muted">Time spent in each step by papers that left it in this window, including retries and waits.</p>
    {!sorted.length ? <p className="empty">No steps finished in this window.</p> : <div className="table-scroll"><table>
      <thead><tr><th scope="col">Step</th><th scope="col" className="num">Runs</th><th scope="col" className="num">Median</th><th scope="col" className="num"><abbr title="90th percentile">90th pct.</abbr></th><th scope="col" className="num">Failed</th></tr></thead>
      <tbody>{sorted.map(s => <tr key={s.stage}><th scope="row">{stageName(s.stage)}</th><td className="num">{s.count.toLocaleString()}</td><td className="num">{duration(s.p50_s)}</td><td className="num">{duration(s.p90_s)}</td><td className="num">{s.failed ? <strong className="bad">{s.failed}</strong> : <span className="muted">0</span>}</td></tr>)}</tbody>
    </table></div>}
  </section>;
}

function Stuck({ stuck }: { stuck: PipelineMetrics['stuck'] }) {
  return <section className="panel" id="stuck-now" aria-labelledby="stuck-title">
    <div className="section-heading"><h2 id="stuck-title">Stuck now</h2><span className={'badge plain' + (stuck.length ? ' warning' : ' positive')}>{stuck.length ? `${stuck.length} stuck` : 'Clear'}</span></div>
    <p className="muted">Papers in one step for more than 15 minutes.</p>
    {!stuck.length ? <p className="empty">Nothing stuck.</p> : <div className="table-scroll"><table className="compact">
      <thead><tr><th scope="col">Paper</th><th scope="col">Step</th><th scope="col" className="num">In step</th><th scope="col" className="num">Crashes</th><th scope="col" className="num">Claims</th></tr></thead>
      <tbody>{stuck.map(p => <tr key={p.id}>
        <th scope="row"><code>{p.source}</code><small>{p.private ? 'Private copy' : 'Shared'}</small></th>
        <td>{stageName(p.stage)}<small>{p.leased ? 'Worker active' : 'Waiting to retry'}</small></td>
        <td className="num">{minutes(p.minutes)}</td><td className="num">{p.crashes ? <strong className="bad">{p.crashes}</strong> : 0}</td><td className="num">{p.claims}</td>
      </tr>)}</tbody>
    </table></div>}
  </section>;
}

type FailureRow = { key: string; at: string; crash: boolean; events: number; imports: number; step: string | null; error: string | null; source: string | null; private: boolean | null };

// A failed step and the imports it failed arrive as separate events (and a stuck paper crashes
// repeatedly); adjacent events for the same paper and cause become one row.
function groupFailures(events: PipelineMetrics['recent_failures']): FailureRow[] {
  const rows: FailureRow[] = [];
  for (const e of events) {
    const crash = e.kind === 'crash', key = crash ? `crash|${e.source}|${e.stage}` : `failure|${e.source}|${e.error_code}`;
    const last = rows[rows.length - 1];
    if (last?.key === key) {
      last.events += 1; if (e.kind === 'import') last.imports += 1;
      if (e.kind === 'stage') { last.step ??= e.stage; last.private ??= e.private; }
      continue;
    }
    rows.push({ key, at: e.at, crash, events: 1, imports: e.kind === 'import' ? 1 : 0, step: e.kind === 'import' ? null : e.stage, error: e.error_code, source: e.source, private: e.private });
  }
  return rows;
}

function RecentFailures({ failures }: { failures: PipelineMetrics['recent_failures'] }) {
  const rows = groupFailures(failures);
  return <section className="panel" aria-labelledby="recent-title"><h2 id="recent-title">Recent failures</h2>
    {!rows.length ? <p className="empty">No failures or crashes in this window.</p> : <ol className="event-list">{rows.map((r, i) => <li key={r.at + i}>
      <time dateTime={r.at}>{moment.format(new Date(r.at))}</time>
      <span className={`event-kind kind-${r.crash ? 'crash' : 'failure'}`}>{r.crash ? KINDS.crash + (r.events > 1 ? ` ×${r.events}` : '') : r.imports > 1 ? `${r.imports} imports failed` : r.imports ? KINDS.import : KINDS.stage}</span>
      <span className="event-what">{r.crash ? stageName(r.step) : causeName(r.error)}{!r.crash && r.step ? <span className="muted"> · {stageName(r.step)}</span> : null}</span>
      <span className="event-source">{r.source ? <code>{r.source}</code> : '—'}{r.private != null && <span className="muted"> · {r.private ? 'private' : 'shared'}</span>}</span>
    </li>)}</ol>}
  </section>;
}
