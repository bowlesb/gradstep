// A part card as a viewport into the whole figure (owner, 2026-10-21: "present it as a crop of the whole thing, that they
// can expand, rather than an actual crop"; FIGURE_VIEW.md "Parts as viewports"). The whole figure, on its white margin,
// is placed so the part's frame (figure-framing.ts) fills the card: a tight frame looks as a crop did, a loose one shows
// some of the figure around the part (softly veiled, the part outlined), a low one the whole figure with the part
// outlined. Pinching, the − / + controls, or dragging move the view over the whole figure; a double-click returns to the
// frame; a click (or Open fullscreen) expands to the whole figure with the part outlined, starting from the frame.
// The same view, at rest, renders statically for chat's figure parts. Nothing here crops pixels away.
import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react';
import type { Rect } from '../lib/figure-crops';
import { framingLook, type FramedPart } from '../lib/figure-framing';
import { framingChanged } from '../lib/figure-framing-record';
import { Dialog, SheetTop } from './common';

export interface FigureSource { src: string; width: number; height: number }
type Part = Pick<FramedPart, 'frame' | 'region' | 'padX' | 'padY' | 'veil' | 'outlined' | 'level'> & { exact?: boolean };

/** The canvas (the figure and its white margin) in pixels of the figure, its origin at (−pad, −pad). */
const canvasOf = (part: Part, image: FigureSource) => {
  const px = part.padX * image.width, py = part.padY * image.height;
  return { x0: -px, y0: -py, w: image.width + 2 * px, h: image.height + 2 * py };
};
const framePixels = (part: Part, image: FigureSource): Rect =>
  [part.frame[0] * image.width, part.frame[1] * image.height, part.frame[2] * image.width, part.frame[3] * image.height];

/** A view: the rectangle of the figure (pixels) the card shows; its aspect is the card's. */
type View = Rect;
/** The view kept inside the canvas (centred where the canvas is smaller), between 8× the frame and the whole canvas. */
function clampView(v: View, part: Part, image: FigureSource, aspect: number): View {
  const c = canvasOf(part, image), f = framePixels(part, image);
  const most = c.w / c.h > aspect ? c.w : c.h * aspect, least = Math.min(f[2] - f[0], (f[3] - f[1]) * aspect) / 8;
  const w = Math.min(most, Math.max(least, v[2] - v[0])), h = w / aspect, cx = (v[0] + v[2]) / 2, cy = (v[1] + v[3]) / 2;
  const along = (center: number, size: number, start: number, length: number) =>
    size >= length ? start + (length - size) / 2 : Math.min(start + length - size, Math.max(start, center - size / 2));
  const x0 = along(cx, w, c.x0, c.w), y0 = along(cy, h, c.y0, c.h);
  return [x0, y0, x0 + w, y0 + h];
}
/** The frame grown to `aspect` about its centre (the fullscreen box's shape), kept inside the canvas. */
function fitted(r: Rect, aspect: number, part: Part, image: FigureSource): View {
  const w = r[2] - r[0], h = r[3] - r[1], cx = (r[0] + r[2]) / 2, cy = (r[1] + r[3]) / 2;
  const W = w / h > aspect ? w : h * aspect, H = W / aspect;
  return clampView([cx - W / 2, cy - H / 2, cx + W / 2, cy + H / 2], part, image, aspect);
}
const wholeView = (part: Part, image: FigureSource, aspect: number): View => {
  const c = canvasOf(part, image);
  return fitted([c.x0, c.y0, c.x0 + c.w, c.y0 + c.h], aspect, part, image);
};
const same = (a: View, b: View) => a.every((v, i) => Math.abs(v - b[i]) < 0.5);

/** The figure placed in a box showing `view`, with the veil over the rest of the figure and the part's outline. */
function Canvas({ image, part, view, look, animate = false }: { image: FigureSource; part: Part; view: View; look: { veil: number; outlined: boolean }; animate?: boolean }) {
  const c = canvasOf(part, image), vw = view[2] - view[0], vh = view[3] - view[1];
  const pct = (n: number) => `${Math.round(n * 1e6) / 1e4}%`;
  const style: CSSProperties = { position: 'absolute', left: pct((c.x0 - view[0]) / vw), top: pct((c.y0 - view[1]) / vh), width: pct(c.w / vw), height: pct(c.h / vh),
    background: '#fff', ...(animate ? { transition: 'left .45s ease, top .45s ease, width .45s ease, height .45s ease' } : {}) };
  const r = part.region, at = (x: number, y: number) => ({ left: pct((x - c.x0) / c.w), top: pct((y - c.y0) / c.h) });
  const region: CSSProperties = { position: 'absolute', ...at(r[0] * image.width, r[1] * image.height),
    width: pct(((r[2] - r[0]) * image.width) / c.w), height: pct(((r[3] - r[1]) * image.height) / c.h) };
  return <div className="viewport-canvas" style={style}>
    <img src={image.src} alt="" draggable={false} style={{ position: 'absolute', ...at(0, 0), width: pct(image.width / c.w), height: pct(image.height / c.h), maxWidth: 'none' }} />
    {look.veil > 0 && <div className="viewport-veil" style={{ ...region, boxShadow: `0 0 0 400vmax rgba(255,255,255,${look.veil})` }} />}
    <div className="viewport-outline" data-testid="part-outline" hidden={!look.outlined} style={region} />
  </div>;
}

/** A part at rest (chat's figure parts): the frame fitted within `size` × `size`, never magnified past 3×. */
export function FramedFigure({ image, part, size }: { image: FigureSource; part: Part; size: number }) {
  const f = framePixels(part, image), fw = f[2] - f[0], fh = f[3] - f[1], scale = Math.min(size / fw, size / fh, 3);
  return <div className="figure-viewport figure-viewport-static" data-level={part.level} style={{ width: Math.round(fw * scale), height: Math.round(fh * scale) }}>
    <Canvas image={image} part={part} view={f} look={framingLook(part, false)} />
  </div>;
}

/** A part card the reader can zoom, pan and expand (the walkthrough's parts and extracted parts). */
export function ViewportCard({ image, part, label, testID, width, recordKey, register, fullscreen = false }: {
  image: FigureSource; part: Part; label: string; testID: string;
  /** The card's CSS width (its height follows the frame's aspect). */
  width?: string;
  /** The card's framing record (figure-framing-record.ts), when it has one. */
  recordKey?: string;
  /** Hands the parent a way to draw what the card shows (Save snippet). */
  register?: (capture: (() => Promise<Blob | null>) | null) => void;
  fullscreen?: boolean;
}) {
  const f = framePixels(part, image), frameAspect = (f[2] - f[0]) / (f[3] - f[1]);
  const c = canvasOf(part, image), aspect = fullscreen ? c.w / c.h : frameAspect;
  const rest = fullscreen ? fitted(f, aspect, part, image) : f;
  const [view, setView] = useState<View>(rest), [expanded, setExpanded] = useState(false), [animate, setAnimate] = useState(false);
  const held = useRef(view); held.current = view;
  const box = useRef<HTMLDivElement>(null);
  const zoom = (f[2] - f[0]) / (view[2] - view[0]) / (fullscreen ? (f[2] - f[0]) / (rest[2] - rest[0]) : 1);
  const revealed = fullscreen || !same(view, rest);
  const look = framingLook(part, revealed);
  const whole = wholeView(part, image, aspect);
  const lowest = (whole[2] - whole[0]) <= (rest[2] - rest[0]) ? 1 : (rest[2] - rest[0]) / (whole[2] - whole[0]);
  const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
  // Fullscreen opens on the frame, then widens to the whole figure (at once with Reduce Motion).
  const [shown, setShown] = useState<'part' | 'whole' | 'custom'>(fullscreen ? 'part' : 'custom');
  useEffect(() => {
    if (!fullscreen) return;
    const go = () => { setAnimate(!reduced()); setView(whole); setShown('whole'); };
    if (reduced()) { go(); return; }
    let second = 0;
    const first = requestAnimationFrame(() => { second = requestAnimationFrame(go); });
    return () => { cancelAnimationFrame(first); cancelAnimationFrame(second); };
  }, [fullscreen]); // eslint-disable-line react-hooks/exhaustive-deps
  useLayoutEffect(() => { if (!animate) return; const t = setTimeout(() => setAnimate(false), 500); return () => clearTimeout(t); }, [animate]);

  const set = (next: View, kind: 'zoomed' | 'panned' | null) => {
    const v = clampView(next, part, image, aspect);
    setView(v); setShown('custom');
    if (recordKey && kind) framingChanged(recordKey, { view: v.map((n, i) => n / (i % 2 ? image.height : image.width)) as Rect, [kind]: true });
  };
  /** Zoom by `factor` about a point of the card (fractions of it; the centre by default). */
  const zoomBy = (factor: number, at = { x: 0.5, y: 0.5 }) => {
    const v = held.current, w = v[2] - v[0], h = v[3] - v[1], px = v[0] + at.x * w, py = v[1] + at.y * h;
    set([px - at.x * w / factor, py - at.y * h / factor, px + (1 - at.x) * w / factor, py + (1 - at.y) * h / factor], 'zoomed');
  };
  const toZoom = (target: number) => zoomBy(target / zoom);
  const reset = () => { setAnimate(!reduced()); setView(rest); setShown(fullscreen ? 'part' : 'custom'); };

  const points = useRef(new Map<number, { x: number; y: number }>()), previous = useRef<{ x: number; y: number; distance: number } | null>(null);
  const moved = useRef(0), clickTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const center = () => { const p = [...points.current.values()]; return p.length ? { x: p.reduce((s, q) => s + q.x, 0) / p.length, y: p.reduce((s, q) => s + q.y, 0) / p.length, distance: p.length === 2 ? Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y) : 0 } : null; };
  const local = (x: number, y: number) => { const r = box.current!.getBoundingClientRect(); return { x: (x - r.left) / r.width, y: (y - r.top) / r.height, width: r.width }; };
  useEffect(() => () => { if (clickTimer.current) clearTimeout(clickTimer.current); }, []);

  // Save snippet: what the card shows, drawn at the figure's own resolution (at least the card's on-screen size).
  useEffect(() => {
    if (!register) return;
    register(() => drawView(image, part, held.current, framingLook(part, fullscreen || !same(held.current, rest)), box.current?.getBoundingClientRect().width ?? 0));
    return () => register(null);
  });

  const expand = () => { setExpanded(true); if (recordKey) framingChanged(recordKey, { expanded: true }); };
  return <>
    <div className="zoom-crop" style={{ width: width ?? '100%', maxWidth: '100%' }}>
      <div ref={box} role="img" aria-label={label} data-testid={testID} data-scale={Math.round(zoom * 100) / 100} data-level={part.level} data-exact={part.exact ? "true" : undefined} data-view={shown}
        className="figure-viewport" style={{ aspectRatio: String(aspect), '--aspect': aspect, touchAction: revealed ? 'none' : 'pan-y' } as CSSProperties}
        onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); points.current.set(e.pointerId, { x: e.clientX, y: e.clientY }); previous.current = center(); moved.current = 0; }}
        onPointerMove={e => {
          if (!points.current.has(e.pointerId)) return;
          points.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
          const now = center(), before = previous.current;
          if (now && before) {
            const r = box.current!.getBoundingClientRect(), v = held.current, scale = (v[2] - v[0]) / r.width;
            moved.current += Math.hypot(now.x - before.x, now.y - before.y);
            if (now.distance && before.distance) { const at = local(now.x, now.y); zoomBy(now.distance / before.distance, at); }
            else if (moved.current > 3) set([v[0] - (now.x - before.x) * scale, v[1] - (now.y - before.y) * scale, v[2] - (now.x - before.x) * scale, v[3] - (now.y - before.y) * scale], 'panned');
          }
          previous.current = center();
        }}
        onPointerUp={e => {
          const single = points.current.size === 1;
          points.current.delete(e.pointerId); previous.current = center();
          // A tap (no movement) expands the card; wait a moment so a double tap/click can return to the frame instead.
          if (!fullscreen && single && moved.current <= 3) { if (clickTimer.current) clearTimeout(clickTimer.current); clickTimer.current = setTimeout(expand, 260); }
        }}
        onPointerCancel={e => { points.current.delete(e.pointerId); previous.current = center(); }}
        onDoubleClick={e => {
          if (clickTimer.current) { clearTimeout(clickTimer.current); clickTimer.current = null; }
          if (revealed && !fullscreen) reset(); else { const at = local(e.clientX, e.clientY); zoomBy(2, at); }
        }}>
        <Canvas image={image} part={part} view={view} look={look} animate={animate} />
      </div>
      <div className="crop-zoom-controls">
        <button type="button" className="icon-button" aria-label="Zoom out of crop" disabled={zoom <= lowest + 0.001} onClick={() => toZoom(zoom > 1 ? Math.max(1, zoom - 0.5) : Math.max(lowest, zoom / 1.5))}>−</button>
        <button type="button" className="icon-button" aria-label="Zoom into crop" disabled={zoom >= 8} onClick={() => toZoom(zoom < 1 ? Math.min(1, zoom * 1.5) : Math.min(8, zoom + 0.5))}>+</button>
        <output aria-live="polite">{Math.round(zoom * 100)}%</output>
        {!fullscreen && <button type="button" className="secondary small" onClick={expand}>Open fullscreen</button>}
      </div>
    </div>
    {expanded && <Dialog open onClose={() => setExpanded(false)} title={label} wide className="fullscreen-figure">
      <FullscreenViewport image={image} part={part} label={label} onClose={() => setExpanded(false)} recordKey={recordKey} />
    </Dialog>}
  </>;
}

/** The whole figure, fullscreen, the part outlined: it opens on the part's frame and widens to the whole figure. */
function FullscreenViewport({ image, part, label, onClose, recordKey }: { image: FigureSource; part: Part; label: string; onClose: () => void; recordKey?: string }) {
  const [key, setKey] = useState(0), [toPart, setToPart] = useState(false);
  return <>
    <SheetTop onClose={onClose}><h2>{label}</h2>
      <button className="secondary small" onClick={() => { setToPart(p => !p); setKey(k => k + 1); }}>{toPart ? 'Whole figure' : 'Show part'}</button></SheetTop>
    {toPart ? <PartView key={key} image={image} part={part} label={label} />
      : <ViewportCard key={key} image={image} part={part} label={label} testID="fullscreen-crop" fullscreen recordKey={recordKey} />}
  </>;
}
/** Fullscreen, on the part's frame (Show part). */
function PartView({ image, part, label }: { image: FigureSource; part: Part; label: string }) {
  const c = canvasOf(part, image), aspect = c.w / c.h, view = fitted(framePixels(part, image), aspect, part, image);
  return <div className="zoom-crop"><div role="img" aria-label={label} data-testid="fullscreen-crop" data-view="part" className="figure-viewport" style={{ aspectRatio: String(aspect), '--aspect': aspect } as CSSProperties}>
    <Canvas image={image} part={part} view={view} look={framingLook(part, true)} /></div></div>;
}

/** What a view shows, as a PNG: the figure, its veil and the part's outline, at the figure's resolution or the card's
 * on-screen size (device pixels), whichever is larger, at most 4,096 pixels a side. */
export async function drawView(image: FigureSource, part: Part, view: View, look: { veil: number; outlined: boolean }, cardWidth: number): Promise<Blob | null> {
  const img = new Image(); img.src = image.src;
  try { await img.decode(); } catch { return null; }
  const vw = view[2] - view[0], vh = view[3] - view[1], device = typeof devicePixelRatio === 'number' ? devicePixelRatio : 1;
  let scale = Math.max(1, (cardWidth * device) / vw);
  scale = Math.min(scale, 4096 / Math.max(vw, vh));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(vw * scale)); canvas.height = Math.max(1, Math.round(vh * scale));
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(scale, 0, 0, scale, -view[0] * scale, -view[1] * scale);
  ctx.drawImage(img, 0, 0, image.width, image.height);
  const r = part.region, rx = r[0] * image.width, ry = r[1] * image.height, rw = (r[2] - r[0]) * image.width, rh = (r[3] - r[1]) * image.height;
  if (look.veil > 0) {
    ctx.fillStyle = `rgba(255,255,255,${look.veil})`; ctx.beginPath();
    ctx.rect(view[0] - 1, view[1] - 1, vw + 2, vh + 2); ctx.rect(rx, ry, rw, rh); ctx.fill('evenodd');
  }
  if (look.outlined) {
    ctx.strokeStyle = '#4f52cf'; // the light accent: the outline sits on the white figure (style.css .viewport-outline)
    ctx.lineWidth = (2 * device) / scale; ctx.strokeRect(rx - ctx.lineWidth, ry - ctx.lineWidth, rw + 2 * ctx.lineWidth, rh + 2 * ctx.lineWidth);
  }
  return new Promise(resolve => canvas.toBlob(blob => resolve(blob), 'image/png'));
}
