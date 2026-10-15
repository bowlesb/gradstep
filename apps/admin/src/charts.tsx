import React, { useCallback, useState, useRef } from 'react';

// The admin's chart kit (Reliability and Health): inline SVG measured to its container, a day cursor for pointer and
// keyboard, tooltips, headline stats and labelled bar lists. Colors come from the --viz palette in style.css.

export const humanize = (value: string) => { const text = value.replaceAll('_', ' '); return text.charAt(0).toUpperCase() + text.slice(1); };
export function duration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return '—';
  if (seconds < 10) return `${seconds.toFixed(1)}s`;
  const total = Math.round(seconds);
  if (total < 60) return `${total}s`;
  if (total < 3600) { const m = Math.floor(total / 60), s = total % 60; return s ? `${m}m ${String(s).padStart(2, '0')}s` : `${m}m`; }
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60);
  return m ? `${h}h ${m}m` : `${h}h`;
}
export const percent = (rate: number | null) => rate == null ? '—' : rate === 0 ? '0%' : rate < 0.1 ? `${(rate * 100).toFixed(1)}%` : `${Math.round(rate * 100)}%`;
export const plural = (n: number, one: string, many = one + 's') => `${n.toLocaleString()} ${n === 1 ? one : many}`;
export const dayShort = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
export const dayLong = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' });
export const moment = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
export const clock = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
export const formatDay = (day: string, format = dayShort) => format.format(new Date(day + 'T00:00:00Z'));


export function Stat({ label, value, note }: { label: string; value: string; note?: string }) {
  return <section className="metric"><p>{label}</p><strong>{value}</strong>{note && <small>{note}</small>}</section>;
}

export function Legend({ items }: { items: { tone: string; label: string; shape?: 'line' | 'rect' }[] }) {
  return <ul className="legend" aria-hidden="true">{items.map(item => <li key={item.tone}><span className={`key ${item.shape ?? 'rect'} tone-${item.tone}`} />{item.label}</li>)}</ul>;
}

// ── Chart geometry ───────────────────────────────────────────────────────────

export const MARGIN = { left: 46, right: 10 };

// Measures the chart container so SVG text stays at its real size at any width.
export function useWidth() {
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

export function timeScale(width: number, n: number) {
  const step = Math.max(1, width - MARGIN.left - MARGIN.right) / n;
  return { step, x: (i: number) => MARGIN.left + step * (i + 0.5), index: (px: number) => Math.min(n - 1, Math.max(0, Math.floor((px - MARGIN.left) / step))) };
}

export function niceTicks(max: number, steps: number[], target = 4) {
  const m = Math.max(max, steps[0]);
  const step = steps.find(s => m / s <= target) ?? Math.ceil(m / target);
  const top = Math.ceil(m / step) * step;
  return { top, ticks: Array.from({ length: Math.round(top / step) + 1 }, (_, i) => i * step) };
}
export const COUNT_STEPS = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
export const SECOND_STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400];
export const tickDuration = (s: number) => s === 0 ? '0' : s < 60 ? `${s}s` : s < 3600 ? `${s / 60}m` : `${s / 3600}h`;

// Runs of consecutive indexes with a value; a missing day breaks the line.
export function runs(values: (number | null)[]) {
  const out: number[][] = []; let current: number[] = [];
  values.forEach((v, i) => { if (v == null) { if (current.length) out.push(current); current = []; } else current.push(i); });
  if (current.length) out.push(current);
  return out;
}
export const point = (x: number, y: number) => `${x.toFixed(1)},${y.toFixed(1)}`;
export const linePath = (run: number[], x: (i: number) => number, y: (i: number) => number) => run.map((i, k) => `${k ? 'L' : 'M'}${point(x(i), y(i))}`).join('');

// A column with a rounded data end and a square baseline end.
export function columnPath(x: number, y: number, w: number, h: number, radius: number) {
  const r = Math.max(0, Math.min(radius, w / 2, h));
  return `M${x},${y + h}V${y + r}A${r},${r} 0 0 1 ${x + r},${y}H${x + w - r}A${r},${r} 0 0 1 ${x + w},${y + r}V${y + h}Z`;
}

export function XAxis({ days, x, step, y, width }: { days: { day: string }[]; x: (i: number) => number; step: number; y: number; width: number }) {
  const every = [1, 2, 3, 7, 14, 30].find(k => k * step >= 56) ?? 30;
  const ticks: number[] = [];
  for (let i = days.length - 1; i >= 0; i -= every) ticks.push(i);
  return <g className="axis">{ticks.map(i => {
    const px = x(i), anchor = px + 22 > width ? 'end' : px - 22 < 0 ? 'start' : 'middle';
    return <text key={i} x={px} y={y} textAnchor={anchor}>{formatDay(days[i].day)}</text>;
  })}</g>;
}

export function YGrid({ ticks, y, width, label }: { ticks: number[]; y: (v: number) => number; width: number; label: (v: number) => string }) {
  return <g className="grid">{ticks.map(t => <g key={t}>
    <line x1={MARGIN.left} x2={width - MARGIN.right} y1={y(t)} y2={y(t)} className={t === 0 ? 'baseline' : undefined} />
    <text x={MARGIN.left - 8} y={y(t)} dy="0.32em" textAnchor="end">{label(t)}</text>
  </g>)}</g>;
}

// Pointer and keyboard selection of a day, shared by both time charts.
export function useDayCursor(n: number, width: number) {
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

export type Cursor = ReturnType<typeof useDayCursor>;
export type TipRow = { tone: string; value: string; label: string };

export function ChartFrame({ frameRef, width, label, summary, height, cursor, tip, children }: {
  frameRef: (element: HTMLDivElement | null) => void; width: number; label: string; summary: string; height: number;
  cursor: Cursor; tip: React.ReactNode; children: React.ReactNode;
}) {
  return <div ref={frameRef} className="chart" tabIndex={0} role="group" aria-label={`${label}. Use the left and right arrow keys to read each day.`} {...cursor.keyboard}>
    {width > 0 ? <svg width={width} height={height} role="img" aria-label={summary}>{children}</svg> : <div className="chart-placeholder" style={{ height }} />}
    {width > 0 && tip}
  </div>;
}

export function Tooltip({ x, width, title, rows, note }: { x: number; width: number; title: string; rows: TipRow[]; note?: string }) {
  const flip = x > width / 2;
  return <div className="chart-tooltip" role="status" style={flip ? { right: width - x + 14 } : { left: x + 14 }}>
    <p>{title}</p>
    {rows.map(row => <div key={row.label}><span className={`key line tone-${row.tone}`} aria-hidden="true" /><strong>{row.value}</strong><span>{row.label}</span></div>)}
    {note && <p className="tip-note">{note}</p>}
  </div>;
}

// Horizontal bars as a labelled list; each bar is sized in percent of its own track, so it scales without measuring.
export function BarList({ rows, tone, noun, plural: many, empty }: { rows: { key: string; label: string; value: number }[]; tone: string; noun: string; plural?: string; empty: string }) {
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

