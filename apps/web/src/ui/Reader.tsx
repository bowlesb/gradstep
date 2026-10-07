// A converted paper in the sandboxed reader frame: contents, citation jumps with Back,
// figures, text size and a saved place. Chat and selection actions are Phase 2.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Activity } from '../lib/activity';
import { BackendError } from '../lib/backend';
import { BundleError, type VerifiedBundle, loadBundle } from '../lib/bundle';
import type { Item } from '../lib/library';
import { effectiveTags } from '../lib/paper';
import { type FrameMessage, frameDocument, readFrameMessage } from '../reader/frame';
import { Dialog, NOT_YET } from './common';

export type ReaderCache = Map<string, VerifiedBundle>; // owned by one signed-in session, memory only
const FONT_KEY = 'gradstep.reader.fontSize';
const readFont = () => { try { const v = Number(localStorage.getItem(FONT_KEY)); return v >= 13 && v <= 28 ? v : 18; } catch { return 18; } };

function publicationLine(item: Item): string | null {
  const m = item.metadata, parts: string[] = [];
  const year = m?.published_at ? Number(m.published_at.slice(0, 4)) : null;
  if (year && year >= 1000 && year <= 9999) parts.push(String(year));
  const venue = m?.venue?.split(/\s+/).join(' ').trim();
  if (venue) parts.push(venue.length > 80 ? venue.slice(0, 79) + '…' : venue);
  if (item.source_id) parts.push(item.source === 'web' ? 'Open access' : `arXiv ${item.source_id}${item.source_revision ? 'v' + item.source_revision : ''}`);
  return parts.length ? parts.join(' · ') : null;
}

function failure(error: unknown): string {
  if (error instanceof BackendError) {
    if (error.code === 'connection') return 'Couldn’t reach Gradstep. Check your connection and try again.';
    if (error.code === 'reader_not_ready' || error.code === 'item_unavailable' || error.code === 'reader_unavailable') return 'This paper isn’t ready to read yet.';
    if (error.code === 'origin_unavailable') return 'The reader service isn’t available to this website yet.';
  }
  if (error instanceof BundleError) return 'This paper’s files didn’t pass verification, so it isn’t shown.';
  return 'Couldn’t open this paper. Try again.';
}

type ReaderProps = { cache: ReaderCache; account: string; item: Item; saved?: Activity;
  onActivity: (itemID: string, activity: Activity) => void; onBack: () => void };

export function Reader(props: ReaderProps) {
  const { account, item } = props;
  const identity = JSON.stringify([account, item.id, item.artifact_id, item.readiness, item.render_availability, item.render_availability_revision]);
  return <PaperReader key={identity} cacheKey={identity} {...props} />;
}

function PaperReader({ cache, cacheKey, account, item, saved, onActivity, onBack }: ReaderProps & { cacheKey: string }) {
  const [bundle, setBundle] = useState<VerifiedBundle | null>(() => cache.get(cacheKey) ?? null);
  const [loaded, setLoaded] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [headings, setHeadings] = useState<{ id: string; title: string }[]>([]);
  const [contents, setContents] = useState(false);
  const [back, setBack] = useState(false);
  const [selection, setSelection] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [figure, setFigure] = useState<string | null>(null);
  const [font, setFont] = useState(readFont);
  const frame = useRef<HTMLIFrameElement>(null);
  const restored = useRef(false);
  const lastSave = useRef(0);
  const title = item.metadata?.title ?? 'Paper';

  useEffect(() => { document.title = `${title} · Gradstep`; return () => { document.title = 'Gradstep'; }; }, [title]);

  useEffect(() => {
    if (cache.has(cacheKey)) { setBundle(cache.get(cacheKey)!); return; }
    const controller = new AbortController();
    setError(null); setLoaded(0);
    loadBundle(account, item.id, controller.signal, fraction => { if (!controller.signal.aborted) setLoaded(fraction); }).then(verified => {
      if (controller.signal.aborted) return;
      cache.set(cacheKey, verified);
      while (cache.size > 3) cache.delete(cache.keys().next().value!);
      setBundle(verified);
    }, e => { if (!controller.signal.aborted) setError(failure(e)); });
    return () => controller.abort();
  }, [account, item.id, cache, cacheKey, attempt]);

  // Built once per bundle: later font changes go through the bridge, so the place is kept.
  const paperLine = publicationLine(item), paperTags = JSON.stringify(effectiveTags(item));
  const srcdoc = useMemo(() => bundle ? frameDocument(bundle, { parentOrigin: location.origin, paperLine,
    paperTags: JSON.parse(paperTags) as string[], fontSize: readFont() }) : null, [bundle, paperLine, paperTags]);
  const figureDoc = useMemo(() => bundle && figure ? frameDocument(bundle, { parentOrigin: location.origin, figureID: figure }) : null, [bundle, figure]);

  const command = useCallback((name: string, ...args: unknown[]) => {
    frame.current?.contentWindow?.postMessage({ gradstep: 'command', name, args }, '*');
  }, []);

  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (!frame.current || event.source !== frame.current.contentWindow || event.data?.gradstep !== 'reader') return;
      const message: FrameMessage | null = readFrameMessage(event.data.value);
      if (!message) return;
      switch (message.type) {
        case 'headings':
          setHeadings(message.items);
          if (!restored.current) {
            restored.current = true;
            if (saved?.location && saved.manifest === bundle?.manifestSHA256) command('restore', saved.location);
            onActivity(item.id, { ...(saved ?? { progress: 0 }), opened: Date.now() });
          }
          break;
        case 'position': {
          const now = Date.now();
          if (now - lastSave.current < 2000) break;
          lastSave.current = now;
          const { block, fraction, height, y } = message;
          onActivity(item.id, { opened: now, progress: message.progress, location: { block, fraction, height, y }, manifest: bundle?.manifestSHA256 });
          break;
        }
        case 'citation': setBack(message.state === 'jumped'); break;
        case 'selection': setSelection(!message.empty); break;
        case 'figure': setFigure(message.id); break;
        case 'reference': setNotice('Reference actions (add to library, open) are not yet available in the browser.'); break;
        case 'tags': setNotice('Editing tags is not yet available in the browser.'); break;
        case 'invalid': setError('This paper couldn’t be shown.'); break;
      }
    };
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, [bundle, command, item.id, onActivity, saved]);

  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(null), 5000); return () => clearTimeout(t); }, [notice]);

  const changeFont = (delta: number) => {
    const next = Math.min(28, Math.max(13, font + delta));
    setFont(next);
    try { localStorage.setItem(FONT_KEY, String(next)); } catch { /* per-viewer convenience only */ }
    command('fontSize', next);
  };
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

  return (
    <div className="reader">
      <header className="reader-bar">
        <button className="secondary small" onClick={onBack} data-testid="back-to-library" aria-label="Back to library">‹ Library</button>
        <h1 className="reader-title" title={title}>{title}</h1>
        <div className="reader-actions">
          {back && <button className="primary small" onClick={() => command('citationBack')} data-testid="citation-back">Back</button>}
          <button className="secondary small" onClick={() => setContents(true)} disabled={!headings.length} data-testid="contents">Contents</button>
          <span className="font-buttons" role="group" aria-label="Text size">
            <button className="secondary small" onClick={() => changeFont(-1)} aria-label="Smaller text" disabled={font <= 13}>A−</button>
            <button className="secondary small" onClick={() => changeFont(1)} aria-label="Larger text" disabled={font >= 28}>A+</button>
          </span>
          <button className="secondary small" onClick={() => setNotice('Chat is ' + NOT_YET.charAt(0).toLowerCase() + NOT_YET.slice(1))} aria-disabled="true" data-testid="ask">Ask</button>
        </div>
      </header>
      {error ? (
        <div className="empty"><p role="alert">{error}</p><button className="secondary" onClick={() => { setError(null); setAttempt(a => a + 1); }}>Try again</button></div>
      ) : srcdoc ? (
        <iframe ref={frame} className="reader-frame" title={title} sandbox="allow-scripts" srcDoc={srcdoc} data-testid="reader-frame" />
      ) : (
        <div className="empty" role="status"><p>Opening the paper…</p>
          <progress max={1} value={loaded} aria-label="Downloading the paper" /></div>
      )}
      {selection && <div className="selection-bar" role="status">Explain, ask and save for a selection are not yet available in the browser.</div>}
      {notice && <div className="toast" role="status">{notice}</div>}
      <Dialog open={contents} onClose={() => setContents(false)} title="Contents">
        <h2>Contents</h2>
        <nav className="contents" aria-label="Contents">
          {headings.map(h => <button key={h.id} className="link" onClick={() => { setContents(false); command('jump', h.id, reduced()); }}>{h.title}</button>)}
        </nav>
      </Dialog>
      <Dialog open={!!figure} onClose={() => setFigure(null)} title="Figure" wide>
        {figureDoc && <iframe className="figure-frame" title="Figure" sandbox="allow-scripts" srcDoc={figureDoc} />}
        <div className="dialog-actions"><button className="secondary" onClick={() => setFigure(null)}>Done</button></div>
      </Dialog>
    </div>
  );
}
