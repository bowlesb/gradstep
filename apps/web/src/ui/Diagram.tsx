import { useEffect, useRef, useState } from 'react';
import { Dialog } from './common';

export function Diagram({ title, source }: { title: string; source: string }) {
  const [open, setOpen] = useState(false);
  return <div className="chat-diagram"><button className="secondary small" onClick={() => setOpen(true)}><span aria-hidden="true">◇</span> View diagram · {title}</button>
    <Dialog open={open} onClose={() => setOpen(false)} title={title} wide><div className="dialog-heading"><h2>{title}</h2><button className="link" onClick={() => setOpen(false)}>Done</button></div>
      <DiagramFrame source={source} /><details><summary>Diagram source</summary><pre>{source}</pre></details>
    </Dialog></div>;
}
function DiagramFrame({ source }: { source: string }) {
  const [doc, setDoc] = useState<string | null>(null), [status, setStatus] = useState<'loading' | 'ready' | 'failed'>('loading');
  const [requestID] = useState(() => crypto.randomUUID());
  const frame = useRef<HTMLIFrameElement>(null);
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
      setDoc(`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${bundle.hash}'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><style>body{margin:0;padding:16px;font:14px system-ui;background:Canvas;color:CanvasText}#diagram{display:flex;justify-content:center}svg{max-width:100%;height:auto}</style><div id="diagram"></div><script>${bundle.script}</script>`);
    }, () => { if (live) setStatus('failed'); });
    return () => { live = false; clearTimeout(timer); window.removeEventListener('message', receive); };
  }, []);
  return <>{status === 'loading' && <p role="status">Drawing diagram…</p>}{status === 'failed' && <p role="alert">Couldn’t draw this diagram. Its source is available below.</p>}
    {doc && <iframe ref={frame} title="Diagram" className="diagram-frame" sandbox="allow-scripts" srcDoc={doc} onLoad={() => frame.current?.contentWindow?.postMessage({ gradstep: 'diagram', requestID, source, dark: (document.documentElement.dataset.theme === 'dark' || (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches)) }, '*')} />}</>;
}
