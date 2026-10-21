// Draw snippet (NOTES_AND_SNIPPETS.md "Drawing"): over the paper frame, which stays where it is (the overlay takes the
// pointer, so the page can't scroll while the box is drawn). One drag makes a box in either direction; release shows
// four corner handles (44 px targets, small marks) and dragging inside moves it. Outside the box is dimmed. Keyboard
// and assistive technology use Whole view and the labelled edge controls, or arrow keys on a focused corner; freehand
// dragging is never the only way. Escape or Cancel restores reading. A resize invalidates the box (never a silent recrop).
import { type KeyboardEvent, type PointerEvent, useEffect, useRef, useState } from 'react';
import { Icon } from './icons';

export interface Box { x: number; y: number; width: number; height: number }
type Corner = 'nw' | 'ne' | 'sw' | 'se';
const CORNERS: [Corner, string][] = [['nw', 'top left'], ['ne', 'top right'], ['sw', 'bottom left'], ['se', 'bottom right']];
const MIN = 24;
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export function SnippetOverlay({ initial, busy, issue, onUse, onCancel }: {
  initial: Box | null; busy: boolean; issue: string | null; onUse: (box: Box) => void; onCancel: () => void;
}) {
  const stage = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState<Box | null>(initial);
  const [size, setSize] = useState<{ width: number; height: number } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const drag = useRef<{ kind: 'new' | 'move' | Corner; x: number; y: number; base: Box | null } | null>(null);
  const announce = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const element = stage.current; if (!element) return;
    let first = true;
    const observer = new ResizeObserver(([entry]) => {
      const next = { width: Math.round(entry.contentRect.width), height: Math.round(entry.contentRect.height) };
      setSize(previous => {
        if (!first && previous && (previous.width !== next.width || previous.height !== next.height)) { setBox(null); setNotice('The page changed size. Draw the box again.'); }
        first = false; return next;
      });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    const key = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape' && !busy) { event.preventDefault(); event.stopPropagation(); onCancel(); } };
    addEventListener('keydown', key, true);
    return () => removeEventListener('keydown', key, true);
  }, [busy, onCancel]);
  const width = size?.width ?? 0, height = size?.height ?? 0;
  const fit = (b: Box): Box => {
    const x = clamp(b.x, 0, width), y = clamp(b.y, 0, height);
    return { x, y, width: clamp(b.width, 0, width - x), height: clamp(b.height, 0, height - y) };
  };
  const corner = (c: Corner, base: Box, dx: number, dy: number): Box => {
    let x1 = base.x, y1 = base.y, x2 = base.x + base.width, y2 = base.y + base.height;
    if (c.includes('w')) x1 = clamp(x1 + dx, 0, x2 - MIN); else x2 = clamp(x2 + dx, x1 + MIN, width);
    if (c.includes('n')) y1 = clamp(y1 + dy, 0, y2 - MIN); else y2 = clamp(y2 + dy, y1 + MIN, height);
    return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
  };
  const point = (event: PointerEvent) => { const r = stage.current!.getBoundingClientRect(); return { x: clamp(event.clientX - r.left, 0, r.width), y: clamp(event.clientY - r.top, 0, r.height) }; };
  const down = (event: PointerEvent<HTMLDivElement>) => {
    if (busy || event.button !== 0) return;
    event.preventDefault();
    const p = point(event), handle = (event.target as HTMLElement).closest<HTMLElement>('[data-corner]')?.dataset.corner as Corner | undefined;
    const inside = !!box && p.x >= box.x && p.x <= box.x + box.width && p.y >= box.y && p.y <= box.y + box.height;
    drag.current = { kind: handle ?? (inside ? 'move' : 'new'), x: p.x, y: p.y, base: box };
    if (!handle && !inside) setBox({ x: p.x, y: p.y, width: 0, height: 0 });
    setNotice(null);
    event.currentTarget.setPointerCapture(event.pointerId);
  };
  const move = (event: PointerEvent<HTMLDivElement>) => {
    const d = drag.current; if (!d) return;
    const p = point(event), dx = p.x - d.x, dy = p.y - d.y;
    if (d.kind === 'new') setBox({ x: Math.min(p.x, d.x), y: Math.min(p.y, d.y), width: Math.abs(dx), height: Math.abs(dy) });
    else if (d.kind === 'move' && d.base) setBox({ ...d.base, x: clamp(d.base.x + dx, 0, width - d.base.width), y: clamp(d.base.y + dy, 0, height - d.base.height) });
    else if (d.base) setBox(corner(d.kind as Corner, d.base, dx, dy));
  };
  const up = (event: PointerEvent<HTMLDivElement>) => {
    if (!drag.current) return;
    drag.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  };
  const nudge = (c: Corner) => (event: KeyboardEvent<HTMLButtonElement>) => {
    const step = event.shiftKey ? 20 : 4, dx = event.key === 'ArrowLeft' ? -step : event.key === 'ArrowRight' ? step : 0, dy = event.key === 'ArrowUp' ? -step : event.key === 'ArrowDown' ? step : 0;
    if ((!dx && !dy) || !box) return;
    event.preventDefault(); setBox(corner(c, box, dx, dy));
  };
  const edge = (name: 'left' | 'right' | 'top' | 'bottom', value: number) => {
    const b = box ?? { x: width * 0.1, y: height * 0.1, width: width * 0.8, height: height * 0.5 };
    const right = b.x + b.width, bottom = b.y + b.height;
    if (name === 'left') setBox({ ...b, x: Math.min(value, right - MIN), width: right - Math.min(value, right - MIN) });
    if (name === 'right') setBox({ ...b, width: Math.max(MIN, value - b.x) });
    if (name === 'top') setBox({ ...b, y: Math.min(value, bottom - MIN), height: bottom - Math.min(value, bottom - MIN) });
    if (name === 'bottom') setBox({ ...b, height: Math.max(MIN, value - b.y) });
  };
  const shown = box && fit(box), usable = !!shown && shown.width >= MIN && shown.height >= MIN;
  const small = !!shown && (shown.width < 88 || shown.height < 88);
  useEffect(() => { if (announce.current) announce.current.textContent = shown && !drag.current ? `${Math.round(shown.width)} by ${Math.round(shown.height)}` : ''; }, [shown?.width, shown?.height]); // eslint-disable-line react-hooks/exhaustive-deps
  return <div className="snippet-capture" data-testid="snippet-capture">
    <div ref={stage} className={`snippet-stage${shown ? ' has-box' : ''}`} onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up}
      aria-label="Paper. Drag to draw a box around what you want to keep." data-testid="snippet-stage">
      {shown && <div className="snippet-box" style={{ left: shown.x, top: shown.y, width: shown.width, height: shown.height }} data-testid="snippet-box">
        {!small && CORNERS.map(([c, label]) => <button key={c} type="button" className={`snippet-handle ${c}`} data-corner={c} aria-label={`Adjust the ${label} corner with the arrow keys`} onKeyDown={nudge(c)} />)}
      </div>}
    </div>
    <div className="snippet-bar" role="toolbar" aria-label="Draw snippet">
      <button className="secondary small" onClick={onCancel} disabled={busy} data-testid="snippet-cancel">Cancel</button>
      <span className="snippet-title"><strong>Draw snippet</strong><span className="fine">{notice ?? issue ?? (shown ? (small ? 'Use the edge controls to refine' : 'Drag the corners to adjust') : 'Drag around anything on the page')}</span></span>
      <span className="visually-hidden" aria-live="polite" ref={announce} />
      <details className="snippet-edges"><summary>Edges</summary>
        <div className="snippet-edge-grid">
          {(['left', 'right', 'top', 'bottom'] as const).map(name => {
            const value = !shown ? 0 : name === 'left' ? shown.x : name === 'right' ? shown.x + shown.width : name === 'top' ? shown.y : shown.y + shown.height;
            return <label key={name}>{name[0].toUpperCase() + name.slice(1)} edge<input type="range" min={0} max={name === 'left' || name === 'right' ? width : height} value={Math.round(value)}
              onChange={e => edge(name, Number(e.target.value))} data-testid={`snippet-edge-${name}`} /></label>;
          })}
          <button type="button" className="secondary small" onClick={() => setBox({ x: 0, y: 0, width, height })} data-testid="snippet-whole">Whole view</button>
        </div>
      </details>
      <button className="primary small" onClick={() => shown && onUse({ x: Math.round(shown.x), y: Math.round(shown.y), width: Math.round(shown.width), height: Math.round(shown.height) })}
        disabled={!usable || busy} data-testid="snippet-use">{busy ? <><span className="spinner small" /> Making image…</> : <><Icon name="scan" size={14} /> Use snippet</>}</button>
    </div>
  </div>;
}
