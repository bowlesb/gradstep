import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Dialog } from './common';
import { CopyButton } from './CopyButton';
import { decodeStoredFigureParts } from '../lib/chat-figures';

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
      <DiagramFrame source={source} /><details><summary>Diagram source</summary><div className="diagram-source-tools"><CopyButton text={source} label="Copy Mermaid" /></div><pre>{source}</pre></details>
    </Dialog></div>;
}
/** `compact`: drawn in the answer, without zoom tools (they belong to Full size). */
export function DiagramFrame({ source, compact = false }: { source: string; compact?: boolean }) {
  const [doc, setDoc] = useState<string | null>(null), [status, setStatus] = useState<'loading' | 'ready' | 'failed'>('loading');
  const [zoom, setZoom] = useState(1);
  const [requestID] = useState(() => crypto.randomUUID());
  const frame = useRef<HTMLIFrameElement>(null);
  const viewport = useRef<HTMLDivElement>(null), previousZoom = useRef(1);
  // Resize the opaque frame itself: zoom never grants access to its DOM or changes its protocol.
  useLayoutEffect(() => {
    const view = viewport.current, ratio = zoom / previousZoom.current;
    if (view) {
      view.scrollLeft = (view.scrollLeft + view.clientWidth / 2) * ratio - view.clientWidth / 2;
      view.scrollTop = (view.scrollTop + view.clientHeight / 2) * ratio - view.clientHeight / 2;
    }
    previousZoom.current = zoom;
  }, [zoom]);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => { if (live) { setStatus('failed'); setDoc(null); } }, 10_000);
    const receive = (e: MessageEvent) => {
      if (e.source !== frame.current?.contentWindow || e.data?.gradstep !== 'diagram-result' || typeof e.data.ok !== 'boolean' || e.data.requestID !== requestID || Object.keys(e.data).sort().join(',') !== 'gradstep,ok,requestID') return;
      clearTimeout(timer); setStatus(e.data.ok ? 'ready' : 'failed');
    };
    window.addEventListener('message', receive);
    import('virtual:diagram-frame').then(({ default: bundle }) => {
      if (!live) return;
      setDoc(`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${bundle.hash}'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><style>html{height:100%}body{box-sizing:border-box;height:100%;margin:0;padding:16px;overflow:hidden;font:14px system-ui;background:Canvas;color:CanvasText}#diagram{height:100%;display:flex;align-items:center;justify-content:center}#diagram>svg{width:100%;height:100%;max-width:100%!important;max-height:100%}</style><div id="diagram"></div><script>${bundle.script}</script>`);
    }, () => { if (live) setStatus('failed'); });
    return () => { live = false; clearTimeout(timer); window.removeEventListener('message', receive); };
  }, []);
  return <>{status === 'loading' && <p role="status">Drawing diagram…</p>}{status === 'failed' && <p role="alert">Couldn’t draw this diagram. Its source is available below.</p>}
    {status === 'ready' && !compact && <div className="diagram-tools" role="group" aria-label="Diagram zoom">
      <button className="secondary small" aria-label="Zoom out diagram" disabled={zoom <= 1} onClick={() => setZoom(z => Math.max(1, z - 0.5))}>−</button>
      <button className="secondary small" onClick={() => setZoom(1)} aria-label="Fit diagram">Fit</button>
      <button className="secondary small" aria-label="Zoom in diagram" disabled={zoom >= 4} onClick={() => setZoom(z => Math.min(4, z + 0.5))}>+</button>
    </div>}
    {doc && <div ref={viewport} className="diagram-viewport" {...(compact ? {} : { tabIndex: 0, role: 'region', 'aria-label': 'Diagram viewport' })}>
      <iframe ref={frame} title="Diagram" className="diagram-frame" style={{ width: `${zoom * 100}%`, height: `${zoom * 100}%` }} sandbox="allow-scripts" srcDoc={doc} onLoad={() => frame.current?.contentWindow?.postMessage({ gradstep: 'diagram', requestID, source, dark: (document.documentElement.dataset.theme === 'dark' || (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches)) }, '*')} />
    </div>}</>;
}

/** An answer's figure parts (CHAT.md "Figures in chat"): each part cropped from the paper's own figure with its
 * number and label under the answer; a click opens the whole figure with the parts outlined and each crop's note.
 * Without the paper on this device (`image` null), the notes alone. */
export function FigureParts({ title, source, image }: { title: string; source: string; image: Blob | null }) {
  const stored = decodeStoredFigureParts(source);
  const [url, setURL] = useState<string | null>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!image) { setURL(null); return; }
    // A data URL: the page's image policy admits 'self' and data: only (vite.config.ts), never blob:.
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
  if (!stored) return null;
  const crop = (box: [number, number, number, number], width: number) => {
    if (!url || !size) return null;
    // Fit within width × width (a tall part is not taller than it is wide here), never magnified past 3×.
    const [l, t, r, b] = box, cw = (r - l) * size.w, ch = (b - t) * size.h, scale = Math.min(width / cw, width / ch, 3);
    return <div className="figure-part-crop" style={{ width: Math.round(cw * scale), height: Math.round(ch * scale) }}>
      <img src={url} alt="" style={{ width: size.w * scale, height: size.h * scale, transform: `translate(${-l * size.w * scale}px, ${-t * size.h * scale}px)` }} /></div>;
  };
  return <div className="figure-parts" data-testid="figure-parts">
    <button type="button" className="figure-parts-strip" onClick={() => setOpen(true)} aria-label={`${title}: ${stored.parts.length} parts. Open the figure`}>
      {stored.parts.map((p, i) => <span key={i} className="figure-part-thumb">
        {crop(p.box, 120) ?? <span className="figure-part-number">{i + 1}</span>}
        <span className="fine">{i + 1}. {p.label}</span></span>)}
    </button>
    <div className="visual-tools"><span className="fine">{title}</span><button className="link small" onClick={() => setOpen(true)}>Open figure</button></div>
    <Dialog open={open} onClose={() => setOpen(false)} title={title} wide><div className="dialog-heading"><h2>{title}</h2><button className="link" onClick={() => setOpen(false)}>Done</button></div>
      {url && size && <div className="figure-parts-whole" style={{ width: `min(100%, ${Math.max(360, size.w)}px)`, aspectRatio: `${size.w} / ${size.h}` }}>
        <img src={url} alt={title} width={size.w} height={size.h} />
        {stored.parts.map((p, i) => <span key={i} className="figure-part-outline" style={{ left: `${p.box[0] * 100}%`, top: `${p.box[1] * 100}%`,
          width: `${(p.box[2] - p.box[0]) * 100}%`, height: `${(p.box[3] - p.box[1]) * 100}%` }}><span>{i + 1}</span></span>)}
      </div>}
      <ol className="figure-parts-notes">{stored.parts.map((p, i) => <li key={i}>{crop(p.box, 220)}<div><strong>{p.label}</strong><p>{p.note}</p></div></li>)}</ol>
    </Dialog></div>;
}
