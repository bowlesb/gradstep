// A part card as a viewport into the whole figure (owner, 2026-10-21: "present it as a crop of the whole thing, that they
// can expand, rather than an actual crop"; FIGURE_VIEW.md "Parts as viewports"). The whole figure, on its white margin,
// is placed so the part's frame (figure-framing.ts) fills the card: a tight frame looks as a crop did, a loose one shows
// some of the figure around the part (softly veiled, the part outlined), a low one the whole figure with the part
// outlined. The same view, at rest, renders statically for chat's figure parts. Nothing here crops pixels away.
//
// Full screen on any interaction (owner, 2026-10-22: "whenever you try to interact with it, it becomes a full screen
// thing, with the outline fading away so you can see where the subfigure was in relation to the entire figure … with not
// really any in-between"; FIGURE_VIEW.md "Full screen on any interaction"). The card never zooms or pans in place: a tap,
// a double tap, a pinch, a sideways drag, ⌃/⌘ + wheel, Enter or Space, or its Full screen button opens the full-screen
// viewer at once. It opens in one step from the card (the figure framed exactly as the card shows it, at the card's
// place, grows to the whole screen still framed on the part), the part's outline then fades over about a second, and the
// reader has the whole figure to pan and zoom across the screen; a double tap toggles the whole figure and the part.
// Closing (X, Esc, a swipe down at the whole figure) goes back into the card. Reduce Motion: a cross-fade, and the
// outline shows for a second, then goes without a fade.
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import type { Rect } from '../lib/figure-crops';
import { framingLook, type FramedPart } from '../lib/figure-framing';
import { framingChanged, type OpenGesture } from '../lib/figure-framing-record';
import { Icon } from './icons';

export interface FigureSource { src: string; width: number; height: number }
type Part = Pick<FramedPart, 'frame' | 'region' | 'padX' | 'padY' | 'veil' | 'outlined' | 'level'> & { exact?: boolean };

/** The open and close transition, and the zoom/part toggle (ms). The outline's fade follows the opening (style.css). */
const DURATION = 350;

/** The canvas (the figure and its white margin) in pixels of the figure, its origin at (−pad, −pad). */
const canvasOf = (part: Part, image: FigureSource) => {
  const px = part.padX * image.width, py = part.padY * image.height;
  return { x0: -px, y0: -py, w: image.width + 2 * px, h: image.height + 2 * py };
};
const framePixels = (part: Part, image: FigureSource): Rect =>
  [part.frame[0] * image.width, part.frame[1] * image.height, part.frame[2] * image.width, part.frame[3] * image.height];

/** A view: the rectangle of the figure (pixels) a box shows; its aspect is the box's. */
type View = Rect;
/** The view kept inside the canvas (centred where the canvas is smaller), its width between `least` and the whole canvas. */
function clampView(v: View, part: Part, image: FigureSource, aspect: number, least?: number): View {
  const c = canvasOf(part, image), f = framePixels(part, image);
  const most = c.w / c.h > aspect ? c.w : c.h * aspect;
  const smallest = least ?? Math.min(f[2] - f[0], (f[3] - f[1]) * aspect) / 8;
  const w = Math.min(most, Math.max(smallest, v[2] - v[0])), h = w / aspect, cx = (v[0] + v[2]) / 2, cy = (v[1] + v[3]) / 2;
  const along = (center: number, size: number, start: number, length: number) =>
    size >= length ? start + (length - size) / 2 : Math.min(start + length - size, Math.max(start, center - size / 2));
  const x0 = along(cx, w, c.x0, c.w), y0 = along(cy, h, c.y0, c.h);
  return [x0, y0, x0 + w, y0 + h];
}
/** The frame grown to `aspect` about its centre (the full screen's shape), kept inside the canvas. */
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
const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** The figure placed in a box showing `view`, with the veil over the rest of the figure and the part's outline. */
function Canvas({ image, part, view, look, animate = false }: { image: FigureSource; part: Part; view: View; look: { veil: number; outlined: boolean }; animate?: boolean }) {
  const c = canvasOf(part, image), vw = view[2] - view[0], vh = view[3] - view[1];
  const pct = (n: number) => `${Math.round(n * 1e6) / 1e4}%`;
  const style: CSSProperties = { position: 'absolute', left: pct((c.x0 - view[0]) / vw), top: pct((c.y0 - view[1]) / vh), width: pct(c.w / vw), height: pct(c.h / vh),
    background: '#fff', ...(animate ? { transition: `left ${DURATION}ms ease-out, top ${DURATION}ms ease-out, width ${DURATION}ms ease-out, height ${DURATION}ms ease-out` } : {}) };
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

/** A part card (the walkthrough's parts): its frame at rest, and any interaction opens the full-screen viewer. */
export function ViewportCard({ image, part, label, title, testID, width, recordKey, register }: {
  image: FigureSource; part: Part; label: string; testID: string;
  /** The full screen's visible title (the part's heading); `label` when absent. */
  title?: string;
  /** The card's CSS width (its height follows the frame's aspect). */
  width?: string;
  /** The card's framing record (figure-framing-record.ts), when it has one. */
  recordKey?: string;
  /** Hands the parent a way to draw what the card shows (Save snippet). */
  register?: (capture: (() => Promise<Blob | null>) | null) => void;
}) {
  const f = framePixels(part, image), aspect = (f[2] - f[0]) / (f[3] - f[1]);
  const box = useRef<HTMLDivElement>(null);
  const [from, setFrom] = useState<DOMRect | null>(null);
  const shown = useRef(false); shown.current = !!from;
  // Save snippet: what the card shows (its frame at rest), at the figure's resolution (at least the card's on-screen size).
  useEffect(() => {
    if (!register) return;
    register(() => drawView(image, part, f, framingLook(part, false), box.current?.getBoundingClientRect().width ?? 0));
    return () => register(null);
  });
  const open = useCallback((gesture: OpenGesture) => {
    if (shown.current || !box.current) return;
    shown.current = true;
    setFrom(box.current.getBoundingClientRect());
    if (recordKey) framingChanged(recordKey, { opened: gesture });
  }, [recordKey]);
  // A pinch on a trackpad is a wheel with ⌃ (⌘ in some browsers): it opens instead of zooming the page.
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const wheel = (e: WheelEvent) => { if (e.ctrlKey || e.metaKey) { e.preventDefault(); open('pinch'); } };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  }, [open]);
  const pointers = useRef(new Map<number, { x: number; y: number }>()), moved = useRef(false);
  return <>
    <div className="zoom-crop" style={{ width: width ?? '100%', maxWidth: '100%' }}>
      <div ref={box} role="button" tabIndex={0} aria-label={`Open ${label} full screen`} data-testid={testID} data-level={part.level} data-exact={part.exact ? 'true' : undefined}
        className="figure-viewport" style={{ aspectRatio: String(aspect), touchAction: 'pan-y' } as CSSProperties}
        onPointerDown={e => { pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY }); if (pointers.current.size === 1) moved.current = false; else open('pinch'); }}
        onPointerMove={e => {
          const start = pointers.current.get(e.pointerId);
          if (!start || pointers.current.size !== 1) return;
          const dx = e.clientX - start.x, dy = e.clientY - start.y;
          // A sideways drag opens; an upward or downward one is the page's (touch-action: pan-y scrolls it, then cancels).
          if (Math.hypot(dx, dy) > 8) { moved.current = true; if (Math.abs(dx) > Math.abs(dy)) { pointers.current.clear(); open('drag'); } }
        }}
        onPointerUp={e => { const was = pointers.current.delete(e.pointerId); if (was && !moved.current && pointers.current.size === 0) open('tap'); }}
        onPointerCancel={e => { pointers.current.delete(e.pointerId); }}
        onDoubleClick={() => open('double_tap')}
        onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open('keyboard'); } }}>
        <Canvas image={image} part={part} view={f} look={framingLook(part, false)} />
      </div>
      <div className="crop-zoom-controls">
        <button type="button" className="secondary small" onClick={() => open('button')}>Full screen</button>
      </div>
    </div>
    {from && <FullscreenViewer image={image} part={part} label={label} title={title ?? label} from={from} card={box} recordKey={recordKey}
      onClosed={() => { setFrom(null); box.current?.focus({ preventScroll: true }); }} />}
  </>;
}

/** Where `frame` (pixels of the figure) sits in a W × H box showing `view`. */
function placed(frame: Rect, view: View, W: number, H: number) {
  const sx = W / (view[2] - view[0]), sy = H / (view[3] - view[1]);
  return { left: (frame[0] - view[0]) * sx, top: (frame[1] - view[1]) * sy, width: (frame[2] - frame[0]) * sx, height: (frame[3] - frame[1]) * sy };
}
/** The layer's transform and clip that put `frame` (as shown in the full screen) exactly on `to` (the card). */
function onto(frame: { left: number; top: number; width: number; height: number }, to: DOMRect, W: number, H: number) {
  const s = to.width / Math.max(1, frame.width);
  return { transform: `translate(${to.left - frame.left * s}px, ${to.top - frame.top * s}px) scale(${s})`,
    clipPath: `inset(${frame.top}px ${W - frame.left - frame.width}px ${H - frame.top - frame.height}px ${frame.left}px round ${10 / s}px)` };
}
const FULL = { transform: 'translate(0px, 0px) scale(1)', clipPath: 'inset(0px 0px 0px 0px round 0px)' };

/** The whole figure across the whole screen, opened from a card (`from`, its place when it was opened) and framed on the
 * part, which is outlined and then fades; pan, zoom (pinch, wheel, − / +, keys) and a double tap between the whole figure
 * and the part. Closes back into the card (`card`). */
function FullscreenViewer({ image, part, label, title, from, card, recordKey, onClosed }: {
  image: FigureSource; part: Part; label: string; title: string; from: DOMRect; card: RefObject<HTMLDivElement | null>; recordKey?: string; onClosed: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null), layer = useRef<HTMLDivElement>(null), backdrop = useRef<HTMLDivElement>(null), stage = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState(() => ({ w: innerWidth, h: innerHeight }));
  const aspect = size.w / size.h, f = framePixels(part, image);
  const rest = fitted(f, aspect, part, image), whole = wholeView(part, image, aspect);
  // Zoom limits sized to the whole figure: out to all of it, in to 8× that (and at least 3× the part's frame).
  const most = whole[2] - whole[0], least = Math.min(most / 8, (rest[2] - rest[0]) / 3);
  const clamp = (v: View) => clampView(v, part, image, aspect, least);
  const [view, setView] = useState<View>(rest), [animate, setAnimate] = useState(false);
  const [phase, setPhase] = useState<'opening' | 'open' | 'closing'>('opening');
  const [outline, setOutline] = useState<'shown' | 'fading'>('shown');
  const held = useRef(view); held.current = view;
  const closing = useRef(false), touched = useRef({ zoomed: false, panned: false });
  const reduced = reducedMotion();
  const look = framingLook(part, true);
  const atWhole = (v: View) => v[2] - v[0] >= most - 0.5;
  const shown: 'part' | 'whole' | 'custom' = same(view, rest) ? 'part' : atWhole(view) ? 'whole' : 'custom';

  useEffect(() => {
    const resize = () => setSize({ w: innerWidth, h: innerHeight });
    addEventListener('resize', resize);
    return () => removeEventListener('resize', resize);
  }, []);
  // Another window shape: the same middle and scale, refitted.
  const shape = useRef(aspect);
  useEffect(() => {
    if (shape.current === aspect) return;
    shape.current = aspect;
    setView(v => clamp(fitted(v, aspect, part, image)));
  }); // eslint-disable-line react-hooks/exhaustive-deps

  // Opening: in the top layer at once, the figure exactly where and as the card shows it, then one transition to the
  // full screen; the outline fades after it (style.css: its own delay), or shows a second and goes (Reduce Motion).
  useLayoutEffect(() => {
    const d = dialog.current, el = layer.current, back = backdrop.current;
    if (!d || !el || !back) return;
    if (!d.open) d.showModal();
    stage.current?.focus({ preventScroll: true });
    const W = innerWidth, H = innerHeight;
    const finished = () => { if (closing.current) return; el.style.transition = ''; setPhase('open'); };
    // The outline's shown style is computed before it is told to fade, so the fade is a transition.
    const settled = () => stage.current?.querySelectorAll('.viewport-outline, .viewport-veil').forEach(n => void getComputedStyle(n).opacity);
    if (reduced) {
      d.style.opacity = '0'; void getComputedStyle(d).opacity;
      d.style.transition = 'opacity 150ms linear'; d.style.opacity = '1';
      Object.assign(el.style, FULL);
      settled(); setOutline('fading');
      const t = setTimeout(finished, 160);
      return () => clearTimeout(t);
    }
    const start = onto(placed(f, rest, W, H), from, W, H);
    el.style.transformOrigin = '0 0';
    Object.assign(el.style, start); back.style.opacity = '0';
    void getComputedStyle(el).transform; void getComputedStyle(back).opacity;
    el.style.transition = `transform ${DURATION}ms cubic-bezier(.2,.8,.2,1), clip-path ${DURATION}ms cubic-bezier(.2,.8,.2,1)`;
    back.style.transition = `opacity ${DURATION}ms ease-out`;
    Object.assign(el.style, FULL); back.style.opacity = '1';
    settled(); setOutline('fading');
    const end = (e: TransitionEvent) => { if (e.target === el && e.propertyName === 'transform') finished(); };
    el.addEventListener('transitionend', end);
    const fallback = setTimeout(finished, 5_000);
    return () => { el.removeEventListener('transitionend', end); clearTimeout(fallback); };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const fraction = (v: View): Rect => v.map((n, i) => n / (i % 2 ? image.height : image.width)) as Rect;
  const close = () => {
    if (closing.current) return;
    closing.current = true; setPhase('closing');
    if (recordKey) framingChanged(recordKey, { view: fraction(held.current) });
    const d = dialog.current, el = layer.current, back = backdrop.current;
    let done = false;
    const finish = () => { if (done) return; done = true; d?.close(); onClosed(); };
    const to = card.current?.getBoundingClientRect();
    if (!d || !el || !back) { finish(); return; }
    if (reduced || !to || !to.width || !to.height) {
      d.style.transition = 'opacity 150ms linear'; d.style.opacity = '0';
      setTimeout(finish, 160); return;
    }
    // Back into the card: the view returns to the part's frame while the layer shrinks onto the card, in one step.
    const W = innerWidth, H = innerHeight, target = onto(placed(f, rest, W, H), to, W, H);
    setAnimate(true); setView(rest);
    el.style.transformOrigin = '0 0';
    el.style.transition = `transform ${DURATION}ms cubic-bezier(.4,0,.2,1), clip-path ${DURATION}ms cubic-bezier(.4,0,.2,1)`;
    back.style.transition = `opacity ${DURATION}ms ease-in`;
    Object.assign(el.style, target); back.style.opacity = '0';
    el.addEventListener('transitionend', e => { if (e.target === el && e.propertyName === 'transform') finish(); });
    setTimeout(finish, 5_000);
  };

  const set = (next: View, kind: 'zoomed' | 'panned') => {
    const v = clamp(next);
    setAnimate(false); setView(v);
    touched.current[kind] = true;
    if (recordKey) framingChanged(recordKey, { [kind]: true });
  };
  /** Zoom by `factor` about a point of the screen (fractions of it; the centre by default). */
  const zoomBy = (factor: number, at = { x: 0.5, y: 0.5 }) => {
    const v = held.current, w = v[2] - v[0], h = v[3] - v[1], px = v[0] + at.x * w, py = v[1] + at.y * h;
    set([px - at.x * w / factor, py - at.y * h / factor, px + (1 - at.x) * w / factor, py + (1 - at.y) * h / factor], 'zoomed');
  };
  const panBy = (dx: number, dy: number) => { const v = held.current; set([v[0] + dx, v[1] + dy, v[2] + dx, v[3] + dy], 'panned'); };
  /** The whole figure ↔ the part (a double tap, the toggle); going to the part shows its outline again, then fades it. */
  const toggle = () => {
    const target = atWhole(held.current) ? rest : whole;
    setAnimate(!reduced); setView(target);
    if (target === rest) { setOutline('shown'); requestAnimationFrame(() => requestAnimationFrame(() => setOutline('fading'))); }
  };

  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      zoomBy(Math.exp(-e.deltaY * (e.ctrlKey || e.metaKey ? 0.01 : 0.002)), { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height });
    };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  });

  const points = useRef(new Map<number, { x: number; y: number }>()), previous = useRef<{ x: number; y: number; distance: number } | null>(null);
  const moved = useRef(0), lastTap = useRef<{ t: number; x: number; y: number } | null>(null), swipe = useRef<{ y0: number; dy: number; t: number } | null>(null);
  const center = () => { const p = [...points.current.values()]; return p.length ? { x: p.reduce((s, q) => s + q.x, 0) / p.length, y: p.reduce((s, q) => s + q.y, 0) / p.length, distance: p.length === 2 ? Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y) : 0 } : null; };
  const settleSwipe = (dismiss: boolean) => {
    const el = layer.current, back = backdrop.current, s = swipe.current;
    swipe.current = null;
    if (!el || !back || !s) return;
    if (dismiss) { close(); return; }
    el.style.transition = `transform 200ms ease-out`; back.style.transition = 'opacity 200ms ease-out';
    Object.assign(el.style, FULL); back.style.opacity = '1';
  };

  return createPortal(<dialog ref={dialog} className="figure-fullscreen" aria-label={label} data-testid="figure-fullscreen" data-phase={phase}
    onCancel={e => { e.preventDefault(); close(); }}>
    <div ref={backdrop} className="figure-fullscreen-backdrop" />
    <div ref={layer} className="figure-fullscreen-layer" data-testid="figure-fullscreen-layer">
      <div ref={stage} className={`figure-fullscreen-stage outline-${outline}`} role="img" aria-label={label} tabIndex={0} data-testid="fullscreen-crop" data-view={shown}
        data-outline={outline} aria-roledescription="Zoomable figure"
        onPointerDown={e => {
          if (closing.current) return;
          try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* a pointer the browser no longer tracks */ }
          points.current.set(e.pointerId, { x: e.clientX, y: e.clientY }); previous.current = center(); moved.current = 0;
          if (e.pointerType === 'touch' && points.current.size === 1 && atWhole(held.current)) swipe.current = { y0: e.clientY, dy: 0, t: performance.now() };
          else swipe.current = null;
        }}
        onPointerMove={e => {
          if (!points.current.has(e.pointerId) || closing.current) return;
          points.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
          const now = center(), before = previous.current;
          if (now && before) {
            moved.current += Math.hypot(now.x - before.x, now.y - before.y);
            const s = swipe.current;
            if (s && points.current.size === 1) {
              // At the whole figure, a downward swipe drags the figure away (released far enough, it closes).
              s.dy = Math.max(0, e.clientY - s.y0);
              if (s.dy > 0 && layer.current && backdrop.current) {
                layer.current.style.transition = ''; backdrop.current.style.transition = '';
                layer.current.style.transform = `translate(0px, ${s.dy}px) scale(${Math.max(0.85, 1 - s.dy / 1500)})`;
                backdrop.current.style.opacity = String(Math.max(0.2, 1 - s.dy / 400));
              }
            } else if (now.distance && before.distance) {
              const r = stage.current!.getBoundingClientRect();
              zoomBy(now.distance / before.distance, { x: (now.x - r.left) / r.width, y: (now.y - r.top) / r.height });
            } else if (moved.current > 3) {
              const r = stage.current!.getBoundingClientRect(), v = held.current, scale = (v[2] - v[0]) / r.width;
              panBy(-(now.x - before.x) * scale, -(now.y - before.y) * scale);
            }
          }
          if (points.current.size > 1) swipe.current = null;
          previous.current = center();
        }}
        onPointerUp={e => {
          const single = points.current.size === 1;
          points.current.delete(e.pointerId); previous.current = center();
          const s = swipe.current;
          if (s && single && s.dy > 0) { settleSwipe(s.dy > 100 || s.dy / Math.max(1, performance.now() - s.t) > 0.8); return; }
          swipe.current = null;
          // A double tap or double-click (two taps without moving, close in time and place): the whole figure ↔ the part.
          if (single && moved.current <= 6) {
            const t = performance.now(), last = lastTap.current;
            if (last && t - last.t < 320 && Math.hypot(e.clientX - last.x, e.clientY - last.y) < 30) { lastTap.current = null; toggle(); }
            else lastTap.current = { t, x: e.clientX, y: e.clientY };
          }
        }}
        onPointerCancel={e => { points.current.delete(e.pointerId); previous.current = center(); if (swipe.current) settleSwipe(false); }}
        onKeyDown={e => {
          const v = held.current, step = (v[2] - v[0]) * 0.1;
          const keys: Record<string, () => void> = { '+': () => zoomBy(1.25), '=': () => zoomBy(1.25), '-': () => zoomBy(0.8), '0': toggle,
            ArrowLeft: () => panBy(-step, 0), ArrowRight: () => panBy(step, 0), ArrowUp: () => panBy(0, -step), ArrowDown: () => panBy(0, step) };
          const act = keys[e.key];
          if (act) { e.preventDefault(); act(); }
        }}>
        <Canvas image={image} part={part} view={view} look={look} animate={animate} />
      </div>
    </div>
    <header className="figure-fullscreen-bar" data-phase={phase}>
      <h2>{title}</h2>
      <button type="button" className="secondary small" onClick={toggle} data-testid="fullscreen-toggle">{shown === 'whole' ? 'Show part' : 'Whole figure'}</button>
      <button type="button" className="icon-button" aria-label="Zoom out" disabled={atWhole(view)} onClick={() => zoomBy(0.8)}>−</button>
      <button type="button" className="icon-button" aria-label="Zoom in" disabled={view[2] - view[0] <= least + 0.5} onClick={() => zoomBy(1.25)}>+</button>
      <button type="button" className="icon-button sheet-close" aria-label="Close" title="Close" onClick={close} data-testid="fullscreen-close"><Icon name="close" /></button>
    </header>
  </dialog>, document.body);
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
