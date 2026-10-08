import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Dialog } from './common';
import { CopyButton } from './CopyButton';

export function Diagram({ title, source }: { title: string; source: string }) {
  const [open, setOpen] = useState(false);
  return <div className="chat-diagram"><button className="secondary small" onClick={() => setOpen(true)}><span aria-hidden="true">◇</span> View diagram · {title}</button>
    <Dialog open={open} onClose={() => setOpen(false)} title={title} wide><div className="dialog-heading"><h2>{title}</h2><button className="link" onClick={() => setOpen(false)}>Done</button></div>
      <DiagramFrame source={source} /><details><summary>Diagram source</summary><div className="diagram-source-tools"><CopyButton text={source} label="Copy Mermaid" /></div><pre>{source}</pre></details>
    </Dialog></div>;
}
function DiagramFrame({ source }: { source: string }) {
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
    {status === 'ready' && <div className="diagram-tools" role="group" aria-label="Diagram zoom">
      <button className="secondary small" aria-label="Zoom out diagram" disabled={zoom <= 1} onClick={() => setZoom(z => Math.max(1, z - 0.5))}>−</button>
      <button className="secondary small" onClick={() => setZoom(1)} aria-label="Fit diagram">Fit</button>
      <button className="secondary small" aria-label="Zoom in diagram" disabled={zoom >= 4} onClick={() => setZoom(z => Math.min(4, z + 0.5))}>+</button>
    </div>}
    {doc && <div ref={viewport} className="diagram-viewport" tabIndex={0} role="region" aria-label="Diagram viewport">
      <iframe ref={frame} title="Diagram" className="diagram-frame" style={{ width: `${zoom * 100}%`, height: `${zoom * 100}%` }} sandbox="allow-scripts" srcDoc={doc} onLoad={() => frame.current?.contentWindow?.postMessage({ gradstep: 'diagram', requestID, source, dark: (document.documentElement.dataset.theme === 'dark' || (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches)) }, '*')} />
    </div>}</>;
}
