import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Dialog } from './common';
import { CopyButton } from './CopyButton';
import { decodeStoredFigureParts, type StoredFigureParts } from '../lib/chat-figures';

/** The document a visual answer is shown in: no scripts, no network (chat-visual.ts `visualDocument`, kept alike). */
export function visualDocument(html: string, dark: boolean): string {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">`
    + `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">`
    + `<style>:root{color-scheme:${dark ? 'dark' : 'light'}}html,body{margin:0;padding:0}body{padding:16px;font:15px/1.45 system-ui,sans-serif;background:${dark ? '#17171a' : '#fff'};color:${dark ? '#e6e6ea' : '#1b1b1f'};overflow-wrap:anywhere}`
    + `table{border-collapse:collapse;max-width:100%}td,th{border:1px solid rgba(128,128,128,.45);padding:4px 8px;vertical-align:top}th{text-align:left}svg{max-width:100%;height:auto}`
    + `pre,code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}pre{white-space:pre-wrap}h1,h2,h3{line-height:1.25}h1{font-size:1.35em}h2{font-size:1.2em}h3{font-size:1.05em}img,iframe,object,embed,video{display:none !important}</style>`
    + `</head><body>${html}</body></html>`;
}

/** A visual answer inline under the answer: a sandboxed frame without scripts; "Full size" opens it in a dialog. */
export function Visual({ title, html }: { title: string; html: string }) {
  const [open, setOpen] = useState(false);
  const dark = typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches;
  const doc = visualDocument(html, dark);
  return <div className="chat-visual" data-testid="chat-visual">
    <iframe title={title} className="visual-frame" sandbox="" srcDoc={doc} />
    <div className="visual-tools"><span className="fine">{title}</span><button className="link small" onClick={() => setOpen(true)}>Full size</button></div>
    <Dialog open={open} onClose={() => setOpen(false)} title={title} wide><div className="dialog-heading"><h2>{title}</h2><button className="link" onClick={() => setOpen(false)}>Done</button></div>
      <iframe title={title} className="visual-frame visual-frame-large" sandbox="" srcDoc={doc} />
    </Dialog></div>;
}

export function Diagram({ title, source, format, figureImage = null }: { title: string; source: string; format?: 'mermaid-v1' | 'html-v1' | 'figure-parts-v1'; figureImage?: Blob | null }) {
  const [open, setOpen] = useState(false);
  if (format === 'html-v1') return <Visual title={title} html={source} />;
  if (format === 'figure-parts-v1') return <FigureParts title={title} source={source} image={figureImage} />;
  // The diagram itself in the answer (owner, build 46: "If you bothered to create a diagram please show it"); full size on request.
  return <div className="chat-diagram">
    <div className="diagram-inline"><DiagramFrame source={source} compact /></div>
    <div className="visual-tools"><span className="fine">{title}</span><button className="link small" onClick={() => setOpen(true)}>Full size</button></div>
    <Dialog open={open} onClose={() => setOpen(false)} title={title} wide><div className="dialog-heading"><h2>{title}</h2><button className="link" onClick={() => setOpen(false)}>Done</button></div>
      <DiagramFrame source={source} fit="width" /><details><summary>Diagram source</summary><div className="diagram-source-tools"><CopyButton text={source} label="Copy Mermaid" /></div><pre>{source}</pre></details>
    </Dialog></div>;
}
/** `compact`: drawn in the answer, without zoom tools (they belong to Full size). `fit`: `width` (Full size) starts the
 * diagram across the width, never larger than it is drawn, scrolling down a tall one; `contain` shows all of it at once.
 * Outside `compact`: pinch (or ctrl/⌘ + wheel) zooms about the fingers or pointer, a drag pans, a double-click returns to
 * the start (owner, build 62: "Zooming with two fingers should work well here"). */
const ZOOM = { min: 0.25, max: 6 };
export function DiagramFrame({ source, compact = false, fit = 'contain' }: { source: string; compact?: boolean; fit?: 'contain' | 'width' }) {
  const [doc, setDoc] = useState<string | null>(null), [status, setStatus] = useState<'loading' | 'ready' | 'failed'>('loading');
  const [zoom, setZoom] = useState(1);
  // The diagram's own size (its drawing's viewBox), as the frame reported it, and the viewport's.
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(null);
  const [room, setRoom] = useState<{ w: number; h: number } | null>(null);
  const [requestID] = useState(() => crypto.randomUUID());
  const frame = useRef<HTMLIFrameElement>(null);
  const viewport = useRef<HTMLDivElement>(null), previousZoom = useRef(1);
  // Where a zoom keeps still (the pointer or the fingers' midpoint, in viewport coordinates); the centre otherwise.
  const focus = useRef<{ x: number; y: number } | 'start' | null>(null);
  const zoomRef = useRef(zoom); zoomRef.current = zoom;
  const lowest = useRef(1);
  const zoomTo = (next: number, at?: { x: number; y: number }) => {
    const clamped = Math.min(ZOOM.max, Math.max(lowest.current, next));
    if (Math.abs(clamped - zoomRef.current) < 0.001) return;
    focus.current = at ?? null; setZoom(clamped);
  };
  // Resize the opaque frame itself: zoom never grants access to its DOM or changes its protocol.
  useLayoutEffect(() => {
    const view = viewport.current, ratio = zoom / previousZoom.current, held = focus.current;
    if (view && held === 'start') { view.scrollLeft = 0; view.scrollTop = 0; }
    else if (view) {
      const at = held && held !== 'start' ? held : { x: view.clientWidth / 2, y: view.clientHeight / 2 };
      view.scrollLeft = (view.scrollLeft + at.x) * ratio - at.x;
      view.scrollTop = (view.scrollTop + at.y) * ratio - at.y;
    }
    focus.current = null;
    previousZoom.current = zoom;
  }, [zoom]);
  useEffect(() => {
    const view = viewport.current;
    if (!view || compact) return;
    const measure = () => setRoom({ w: view.clientWidth, h: view.clientHeight });
    measure();
    const observer = new ResizeObserver(measure); observer.observe(view);
    return () => observer.disconnect();
  }, [compact, doc]);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => { if (live) { setStatus('failed'); setDoc(null); } }, 10_000);
    const receive = (e: MessageEvent) => {
      if (e.source !== frame.current?.contentWindow || e.data?.gradstep !== 'diagram-result' || typeof e.data.ok !== 'boolean' || e.data.requestID !== requestID || Object.keys(e.data).sort().join(',') !== 'gradstep,ok,requestID,size') return;
      const size = e.data.size;
      if (Array.isArray(size) && size.length === 2 && size.every((n: unknown) => typeof n === 'number' && Number.isFinite(n) && n >= 1 && n <= 100_000)) setNatural({ w: size[0], h: size[1] });
      clearTimeout(timer); setStatus(e.data.ok ? 'ready' : 'failed');
    };
    window.addEventListener('message', receive);
    import('virtual:diagram-frame').then(({ default: bundle }) => {
      if (!live) return;
      setDoc(`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${bundle.hash}'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><style>html{height:100%}body{box-sizing:border-box;height:100%;margin:0;padding:16px;overflow:hidden;font:14px system-ui;background:Canvas;color:CanvasText}#diagram{height:100%;display:flex;align-items:center;justify-content:center}#diagram>svg{width:100%;height:100%;max-width:100%!important;max-height:100%}</style><div id="diagram"></div><script>${bundle.script}</script>`);
    }, () => { if (live) setStatus('failed'); });
    return () => { live = false; clearTimeout(timer); window.removeEventListener('message', receive); };
  }, []);

  // The frame's size. Across the width: the drawing scaled to the viewport's width (16 px margins), never above its own
  // size, at `zoom` times that; it can zoom out until all of it is in view. Otherwise the viewport's size times `zoom`.
  const PAD = 32;
  let size: { width: string | number; height: string | number } = { width: `${zoom * 100}%`, height: `${zoom * 100}%` };
  lowest.current = 1;
  if (!compact && fit === 'width' && natural && room && room.w > PAD) {
    const base = Math.min(1, (room.w - PAD) / natural.w);
    const whole = Math.min((room.w - PAD) / natural.w, (room.h - PAD) / natural.h) / base;
    lowest.current = Math.max(ZOOM.min, Math.min(1, whole));
    size = { width: Math.round(natural.w * base * zoom + PAD), height: Math.round(natural.h * base * zoom + PAD) };
  }

  // Back to the start: zoom 1, scrolled to the top left (also when already at zoom 1).
  const reset = () => {
    focus.current = 'start'; setZoom(1);
    if (zoomRef.current === 1 && viewport.current) { viewport.current.scrollLeft = 0; viewport.current.scrollTop = 0; focus.current = null; }
  };
  // Gestures over the frame (it is opaque and takes no input of its own): a layer above it reads them.
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef<{ distance: number; zoom: number } | null>(null);
  const drag = useRef<{ x: number; y: number; left: number; top: number } | null>(null);
  const local = (x: number, y: number) => { const r = viewport.current!.getBoundingClientRect(); return { x: x - r.left, y: y - r.top }; };
  const startDrag = (p: { x: number; y: number }) => { const v = viewport.current!; drag.current = { ...p, left: v.scrollLeft, top: v.scrollTop }; };
  const twoFingers = () => {
    const [a, b] = [...pointers.current.values()];
    return { distance: Math.hypot(a.x - b.x, a.y - b.y), middle: local((a.x + b.x) / 2, (a.y + b.y) / 2) };
  };
  useEffect(() => {
    const view = viewport.current;
    if (!view || compact) return;
    // A trackpad pinch arrives as a wheel with ctrlKey (Chrome, Firefox, Edge); ⌘ + wheel zooms too.
    const wheel = (e: WheelEvent) => {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      zoomTo(zoomRef.current * Math.exp(-e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.01)), local(e.clientX, e.clientY));
    };
    // Safari's trackpad pinch.
    let gestureStart = 1;
    const gestureBegin = (e: Event) => { e.preventDefault(); gestureStart = zoomRef.current; };
    const gesture = (e: Event) => { e.preventDefault(); const g = e as Event & { scale: number; clientX: number; clientY: number }; zoomTo(gestureStart * g.scale, local(g.clientX, g.clientY)); };
    view.addEventListener('wheel', wheel, { passive: false });
    view.addEventListener('gesturestart', gestureBegin); view.addEventListener('gesturechange', gesture);
    return () => { view.removeEventListener('wheel', wheel); view.removeEventListener('gesturestart', gestureBegin); view.removeEventListener('gesturechange', gesture); };
  }, [compact, doc]); // eslint-disable-line react-hooks/exhaustive-deps
  const gestures = compact ? null : <div className="diagram-gesture" data-testid="diagram-gesture" aria-hidden="true"
    onPointerDown={e => {
      try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* a pointer the browser no longer tracks */ }
      pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.current.size === 2) { drag.current = null; pinch.current = { distance: twoFingers().distance, zoom: zoomRef.current }; }
      else if (pointers.current.size === 1) startDrag({ x: e.clientX, y: e.clientY });
    }}
    onPointerMove={e => {
      if (!pointers.current.has(e.pointerId)) return;
      pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pinch.current && pointers.current.size >= 2) {
        const { distance, middle } = twoFingers();
        if (pinch.current.distance > 0) zoomTo(pinch.current.zoom * distance / pinch.current.distance, middle);
      } else if (drag.current) {
        const v = viewport.current!;
        v.scrollLeft = drag.current.left - (e.clientX - drag.current.x); v.scrollTop = drag.current.top - (e.clientY - drag.current.y);
      }
    }}
    onPointerUp={e => {
      pointers.current.delete(e.pointerId);
      if (pointers.current.size < 2) pinch.current = null;
      const rest = [...pointers.current.values()][0];
      if (rest) startDrag(rest); else drag.current = null;
    }}
    onPointerCancel={e => { pointers.current.delete(e.pointerId); pinch.current = null; drag.current = null; }}
    onDoubleClick={reset} />;

  return <>{status === 'loading' && <p role="status">Drawing diagram…</p>}{status === 'failed' && <p role="alert">Couldn’t draw this diagram. Its source is available below.</p>}
    {status === 'ready' && !compact && <div className="diagram-tools" role="group" aria-label="Diagram zoom">
      <span className="fine diagram-hint">Pinch or drag · double-click to fit</span>
      <button className="secondary small" aria-label="Zoom out diagram" disabled={zoom <= lowest.current + 0.001} onClick={() => zoomTo(zoom - 0.5 >= 1 ? zoom - 0.5 : zoom / 1.5)}>−</button>
      <button className="secondary small" onClick={reset} aria-label="Fit diagram">Fit</button>
      <button className="secondary small" aria-label="Zoom in diagram" disabled={zoom >= ZOOM.max} onClick={() => zoomTo(zoom < 1 ? Math.min(1, zoom * 1.5) : zoom + 0.5)}>+</button>
    </div>}
    {doc && <div ref={viewport} className={`diagram-viewport${fit === 'width' && !compact ? ' fit-width' : ''}`} {...(compact ? {} : { tabIndex: 0, role: 'region', 'aria-label': 'Diagram viewport' })}>
      <div className="diagram-canvas" style={{ width: size.width, height: size.height }}>
        <iframe ref={frame} title="Diagram" className="diagram-frame" sandbox="allow-scripts" srcDoc={doc} onLoad={() => frame.current?.contentWindow?.postMessage({ gradstep: 'diagram', requestID, source, dark: (document.documentElement.dataset.theme === 'dark' || (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches)) }, '*')} />
        {status === 'ready' && gestures}
      </div>
    </div>}</>;
}

/** A figure image as a data URL with its natural size (the page's image policy admits 'self' and data: only, never blob:). */
export function useFigureDataURL(image: Blob | null): { url: string | null; size: { w: number; h: number } | null } {
  const [url, setURL] = useState<string | null>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  useEffect(() => {
    if (!image) { setURL(null); setSize(null); return; }
    let live = true;
    const reader = new FileReader();
    reader.onload = () => {
      if (!live || typeof reader.result !== 'string') return;
      const made = reader.result; setURL(made);
      const probe = new Image(); probe.onload = () => { if (live) setSize({ w: probe.naturalWidth, h: probe.naturalHeight }); }; probe.src = made;
    };
    reader.readAsDataURL(image);
    return () => { live = false; };
  }, [image]);
  return { url, size };
}

/** One part cropped from the figure, fitted within `width` × `width` and never magnified past 3×. */
function Crop({ url, size, box, width }: { url: string; size: { w: number; h: number }; box: [number, number, number, number]; width: number }) {
  const [l, t, r, b] = box, cw = (r - l) * size.w, ch = (b - t) * size.h, scale = Math.min(width / cw, width / ch, 3);
  return <div className="figure-part-crop" style={{ width: Math.round(cw * scale), height: Math.round(ch * scale) }}>
    <img src={url} alt="" style={{ width: size.w * scale, height: size.h * scale, transform: `translate(${-l * size.w * scale}px, ${-t * size.h * scale}px)` }} /></div>;
}

/** One part inline in an answer, where the answer discusses it: its number, label and crop (no note: the prose is it).
 * Without the paper on this device, the number and label only. */
export function FigurePartInline({ number, part, url, size }: { number: number; part: StoredFigureParts['parts'][number]; url: string | null; size: { w: number; h: number } | null }) {
  return <figure className="figure-part-inline" data-testid="figure-part-inline" aria-label={`Part ${number}: ${part.label}`}>
    <figcaption><span className="figure-part-badge">{number}</span>{part.label}</figcaption>
    {url && size && <Crop url={url} size={size} box={part.box} width={280} />}
  </figure>;
}

/** The whole figure with its parts outlined and numbered, and every part with its note (the full view). */
function WholeFigureDialog({ title, stored, url, size, open, onClose }: { title: string; stored: StoredFigureParts; url: string | null; size: { w: number; h: number } | null; open: boolean; onClose: () => void }) {
  return <Dialog open={open} onClose={onClose} title={title} wide><div className="dialog-heading"><h2>{title}</h2><button className="link" onClick={onClose}>Done</button></div>
    {url && size && <OutlinedFigure stored={stored} url={url} size={size} title={title} width={`min(100%, ${Math.max(360, size.w)}px)`} />}
    <ol className="figure-parts-notes">{stored.parts.map((p, i) => <li key={i}>{url && size && <Crop url={url} size={size} box={p.box} width={220} />}<div><strong>{p.label}</strong><p>{p.note}</p></div></li>)}</ol>
  </Dialog>;
}
function OutlinedFigure({ stored, url, size, title, width }: { stored: StoredFigureParts; url: string; size: { w: number; h: number }; title: string; width: string }) {
  return <div className="figure-parts-whole" style={{ width, aspectRatio: `${size.w} / ${size.h}` }}>
    <img src={url} alt={title} width={size.w} height={size.h} />
    {stored.parts.map((p, i) => <span key={i} className="figure-part-outline" style={{ left: `${p.box[0] * 100}%`, top: `${p.box[1] * 100}%`,
      width: `${(p.box[2] - p.box[0]) * 100}%`, height: `${(p.box[3] - p.box[1]) * 100}%` }}><span>{i + 1}</span></span>)}
  </div>;
}

/** Under an answer whose parts are inline: the whole figure, small, its parts outlined; a click opens the full view. */
export function FigurePartsOverview({ title, stored, url, size }: { title: string; stored: StoredFigureParts; url: string | null; size: { w: number; h: number } | null }) {
  const [open, setOpen] = useState(false);
  return <div className="figure-parts figure-parts-overview" data-testid="figure-parts-overview">
    <button type="button" className="figure-parts-overview-button" onClick={() => setOpen(true)} aria-label={`Whole figure: ${title}, ${stored.parts.length} parts outlined. Open it`}>
      {url && size && <OutlinedFigure stored={stored} url={url} size={size} title={title} width={`${Math.min(240, size.w)}px`} />}
      <span className="fine">{title} · whole figure</span>
    </button>
    <WholeFigureDialog title={title} stored={stored} url={url} size={size} open={open} onClose={() => setOpen(false)} />
  </div>;
}

/** An answer's figure parts saved before the inline crops (no markers in its text): each part cropped under the answer
 * with its number and label; a click opens the whole figure with the parts outlined and each crop's note. Without the
 * paper on this device (`image` null), the notes alone. */
export function FigureParts({ title, source, image }: { title: string; source: string; image: Blob | null }) {
  const stored = decodeStoredFigureParts(source);
  const { url, size } = useFigureDataURL(image);
  const [open, setOpen] = useState(false);
  if (!stored) return null;
  return <div className="figure-parts" data-testid="figure-parts">
    <button type="button" className="figure-parts-strip" onClick={() => setOpen(true)} aria-label={`${title}: ${stored.parts.length} parts. Open the figure`}>
      {stored.parts.map((p, i) => <span key={i} className="figure-part-thumb">
        {url && size ? <Crop url={url} size={size} box={p.box} width={120} /> : <span className="figure-part-number">{i + 1}</span>}
        <span className="fine">{i + 1}. {p.label}</span></span>)}
    </button>
    <div className="visual-tools"><span className="fine">{title}</span><button className="link small" onClick={() => setOpen(true)}>Open figure</button></div>
    <WholeFigureDialog title={title} stored={stored} url={url} size={size} open={open} onClose={() => setOpen(false)} />
  </div>;
}
