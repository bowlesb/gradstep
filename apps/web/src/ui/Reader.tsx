// A converted paper in the sandboxed reader frame (legacy MarkdownReader on verified bundles): the
// contents tree in the left rail with the current section, citation jumps with Back, find in the
// paper, the figure viewer, text size and a saved place. Chat and selection actions are Phase 2.
import { type MutableRefObject, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import type { Activity } from '../lib/activity';
import { BackendError } from '../lib/backend';
import { BundleError, type VerifiedBundle, loadBundle } from '../lib/bundle';
import type { Item } from '../lib/library';
import { effectiveTags } from '../lib/paper';
import { type FrameKey, type FrameMessage, frameDocument, readFrameMessage } from '../reader/frame';
import { FigureViewer } from './Figures';
import { Icon } from './icons';
import { readStored, writeStored } from './prefs';
import { useWorkspaceControls } from './Shell';

export type ReaderCache = Map<string, VerifiedBundle>; // owned by one signed-in session, memory only
export interface ReaderCommands { find: () => void; escape: () => boolean }
const FONT_KEY = 'gradstep.reader.fontSize';
const readFont = () => readStored(FONT_KEY, 18, v => typeof v === 'number' && v >= 13 && v <= 28);

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
    if (error.code === 'reader_transfer_limit') return 'Paper downloads are temporarily limited. Saved papers remain available.';
    if (error.code === 'reader_upgrade_required') return 'Reload Gradstep to update the reader. Saved papers remain available.';
    if (error.code === 'reader_grant_unavailable' || error.code === 'reader_grant_consumed') return 'The download needs to restart. Open the paper again.';
    if (error.code === 'asset_inventory_incomplete') return 'This paper is temporarily unavailable. Saved papers remain available.';
  }
  if (error instanceof BundleError) return 'This paper’s files didn’t pass verification, so it isn’t shown.';
  return 'Couldn’t open this paper. Try again.';
}

type ReaderProps = { cache: ReaderCache; account: string; item: Item; saved?: Activity; theme: 'light' | 'dark';
  contentsSlot: HTMLElement | null; commands: MutableRefObject<ReaderCommands | null>;
  onActivity: (itemID: string, activity: Activity) => void; onKey: (key: FrameKey) => void; onContents: () => void };

export function Reader(props: ReaderProps) {
  const { account, item } = props;
  const identity = JSON.stringify([account, item.id, item.artifact_id, item.readiness, item.render_availability, item.render_availability_revision]);
  return <PaperReader key={identity} cacheKey={identity} {...props} />;
}

type Heading = { id: string; title: string; depth?: number };

function PaperReader({ cache, cacheKey, account, item, saved, theme, contentsSlot, commands, onActivity, onKey, onContents }: ReaderProps & { cacheKey: string }) {
  const workspace = useWorkspaceControls();
  const [bundle, setBundle] = useState<VerifiedBundle | null>(() => cache.get(cacheKey) ?? null);
  const [loaded, setLoaded] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [headings, setHeadings] = useState<Heading[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [back, setBack] = useState(false);
  const [selection, setSelection] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [figure, setFigure] = useState<{ id: string | null; open: boolean }>({ id: null, open: false });
  const [finding, setFinding] = useState(false);
  const [findText, setFindText] = useState('');
  const [found, setFound] = useState<{ count: number; index: number } | null>(null);
  const [findFocus, setFindFocus] = useState(0);
  const [font, setFont] = useState(readFont);
  const frame = useRef<HTMLIFrameElement>(null);
  const findField = useRef<HTMLInputElement>(null);
  const frameReady = useRef(false);
  const title = item.metadata?.title ?? 'Paper';
  const paperLine = publicationLine(item), paperTags = JSON.stringify(effectiveTags(item));
  const [initialPresentation] = useState(() => ({ paperLine, paperTags, fontSize: font, theme }));
  const appliedPresentation = useRef(initialPresentation);

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

  // One document per bundle. Live presentation changes use the shared native bridge, preserving
  // the reading place, DOM selection and citation-return state instead of navigating the frame.
  const srcdoc = useMemo(() => bundle ? frameDocument(bundle, { parentOrigin: location.origin, paperLine: initialPresentation.paperLine,
    paperTags: JSON.parse(initialPresentation.paperTags) as string[], fontSize: initialPresentation.fontSize, theme: initialPresentation.theme }) : null, [bundle, initialPresentation]);
  // Where each heading sits in the bundle's block order, for the current section.
  const headingBlocks = useMemo(() => {
    const blocks = new Map(bundle?.index.blocks.map((b, i) => [b.id, i]) ?? []);
    return headings.map(h => ({ id: h.id, block: blocks.get(h.id) ?? -1 })).filter(h => h.block >= 0);
  }, [bundle, headings]);

  const command = useCallback((name: string, ...args: unknown[]) => {
    frame.current?.contentWindow?.postMessage({ gradstep: 'command', name, args }, '*');
  }, []);

  const applyPresentation = useCallback(() => {
    if (!frameReady.current) return;
    const previous = appliedPresentation.current;
    if (previous.paperLine !== paperLine) command('paperLine', paperLine);
    if (previous.paperTags !== paperTags) command('paperTags', JSON.parse(paperTags));
    if (previous.fontSize !== font) command('fontSize', font);
    if (previous.theme !== theme) command('theme', theme);
    appliedPresentation.current = { paperLine, paperTags, fontSize: font, theme };
  }, [command, paperLine, paperTags, font, theme]);

  useEffect(applyPresentation, [applyPresentation]);

  const closeFind = useCallback(() => { setFinding(false); setFindText(''); setFound(null); command('findClear'); }, [command]);
  const openFind = useCallback(() => { setFinding(true); setFindFocus(n => n + 1); }, []);
  useEffect(() => { if (findFocus) { findField.current?.focus(); findField.current?.select(); } }, [findFocus]);
  useEffect(() => {
    commands.current = {
      find: openFind,
      escape: () => { if (finding) { closeFind(); return true; } return false; },
    };
    return () => { commands.current = null; };
  }, [commands, openFind, closeFind, finding]);
  // A short pause while typing, then the frame searches from the reading place.
  useEffect(() => {
    if (!finding || !frameReady.current) return;
    const t = setTimeout(() => command('find', findText, 'first'), 160);
    return () => clearTimeout(t);
  }, [finding, findText, command]);

  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (!frame.current || event.source !== frame.current.contentWindow || event.data?.gradstep !== 'reader') return;
      const message: FrameMessage | null = readFrameMessage(event.data.value);
      if (!message) return;
      switch (message.type) {
        case 'headings':
          setHeadings(message.items);
          frameReady.current = true;
          appliedPresentation.current = initialPresentation;
          // Updates that arrived while the bundle loaded must precede the saved-place restoration.
          applyPresentation();
          if (saved?.location && saved.manifest === bundle?.manifestSHA256) command('restore', saved.location);
          onActivity(item.id, { ...(saved ?? { progress: 0 }), opened: Date.now() });
          break;
        case 'position': {
          const now = Date.now();
          // The bridge already bounds scroll reports (120 ms plus scroll-end). Keep the final one:
          // an additional leading-only throttle can discard the place just before leaving the paper.
          // App owns debounced, ordered encrypted persistence independently of this in-memory update.
          const { block, fraction, height, y } = message;
          onActivity(item.id, { opened: now, progress: message.progress, location: { block, fraction, height, y }, manifest: bundle?.manifestSHA256 });
          let current: string | null = null;
          for (const h of headingBlocks) { if (h.block <= block) current = h.id; else break; }
          setActive(current);
          break;
        }
        case 'citation': setBack(message.state === 'jumped'); break;
        case 'selection': setSelection(!message.empty); break;
        case 'figure': setFigure({ id: message.id, open: true }); break;
        case 'reference': setNotice('Reference actions (add to library, open) are not yet available in the browser.'); break;
        case 'tags': setNotice('Editing tags is not yet available in the browser.'); break;
        case 'invalid': setError('This paper couldn’t be shown.'); break;
        case 'find': setFound({ count: message.count, index: message.index }); break;
        case 'key': onKey(message.key); break;
      }
    };
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, [bundle, command, item.id, onActivity, onKey, saved, applyPresentation, initialPresentation, headingBlocks]);

  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(null), 5000); return () => clearTimeout(t); }, [notice]);

  const changeFont = (delta: number) => {
    const next = Math.min(28, Math.max(13, font + delta));
    setFont(next); writeStored(FONT_KEY, next);
  };
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const jump = (id: string) => {
    command('jump', id, reduced());
    setActive(id);
    if (workspace && !workspace.left.inline) workspace.show('left', false);
  };
  const figures = bundle?.index.figures ?? [];
  const contentsShown = !!workspace?.left.open && !!contentsSlot;

  return (
    <div className="reader" data-theme-frame={theme}>
      <header className="paper-toolbar">
        <button className={`icon-button${contentsShown ? ' on' : ''}`} onClick={onContents} disabled={!headings.length} data-testid="contents"
          aria-label="Contents" aria-pressed={contentsShown} title="Contents ( [ )"><Icon name="list" /></button>
        <h1 className="reader-title" title={title}>{title}</h1>
        <div className="reader-actions">
          {back && <button className="primary small" onClick={() => command('citationBack')} data-testid="citation-back"><Icon name="chevronLeft" size={14} />Back</button>}
          <button className={`icon-button${finding ? ' on' : ''}`} onClick={() => (finding ? closeFind() : openFind())} disabled={!srcdoc} aria-label="Find in paper" title="Find in paper (⌘F)" data-testid="find"><Icon name="search" /></button>
          <button className="tool-button" onClick={() => setFigure({ id: null, open: true })} disabled={!figures.length} title="Figures" data-testid="figures">
            <Icon name="image" /><span>Figures</span>{figures.length > 0 && <span className="count">{figures.length}</span>}</button>
          <span className="font-buttons" role="group" aria-label="Text size">
            <button className="icon-button text-size" onClick={() => changeFont(-1)} aria-label="Smaller text" title="Smaller text" disabled={font <= 13}><span className="a-small">A</span></button>
            <button className="icon-button text-size" onClick={() => changeFont(1)} aria-label="Larger text" title="Larger text" disabled={font >= 28}><span className="a-large">A</span></button>
          </span>
          <button className={`tool-button${workspace?.right.open ? ' on' : ''}`} onClick={() => workspace?.toggle('right')} aria-pressed={!!workspace?.right.open}
            data-testid="ask" title="Chat ( ] )"><Icon name="chat" /><span>Chat</span></button>
        </div>
      </header>
      {finding && (
        <form className="find-bar" role="search" aria-label="Find in paper" onSubmit={e => e.preventDefault()}>
          <Icon name="search" size={14} />
          <input ref={findField} type="search" value={findText} placeholder="Find in paper" aria-label="Find in paper" data-testid="find-input"
            onChange={e => setFindText(e.target.value)}
            onKeyDown={e => {
              if (e.key === 'Enter') { e.preventDefault(); command('find', findText, e.shiftKey ? 'previous' : 'next'); }
              if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFind(); }
            }} />
          <span className="find-count" aria-live="polite" data-testid="find-count">{found && findText.trim() ? (found.count ? `${found.index + 1} of ${found.count}${found.count >= 1000 ? '+' : ''}` : 'No matches') : ''}</span>
          <button type="button" className="icon-button" onClick={() => command('find', findText, 'previous')} disabled={!found?.count} aria-label="Previous match"><Icon name="chevronUp" /></button>
          <button type="button" className="icon-button" onClick={() => command('find', findText, 'next')} disabled={!found?.count} aria-label="Next match"><Icon name="chevronDown" /></button>
          <button type="button" className="link" onClick={closeFind}>Done</button>
        </form>
      )}
      <div className="paper-stage">
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
      </div>
      {contentsSlot && headings.length > 0 && createPortal(<Contents headings={headings} active={active} onJump={jump} />, contentsSlot)}
      {bundle && figure.open && (
        <FigureViewer bundle={bundle} theme={theme} initial={figure.id} onClose={() => setFigure({ id: null, open: false })}
          onShowInPaper={id => { setFigure({ id: null, open: false }); command('showFigure', id); }} />
      )}
    </div>
  );
}

/** The paper's contents as a tree (the bridge's outline depths), the current section marked. */
function Contents({ headings, active, onJump }: { headings: Heading[]; active: string | null; onJump: (id: string) => void }) {
  const list = useRef<HTMLOListElement>(null);
  useEffect(() => { list.current?.querySelector('[aria-current="location"]')?.scrollIntoView({ block: 'nearest' }); }, [active]);
  return (
    <nav className="contents-tree" aria-label="Contents">
      <ol ref={list}>
        {headings.map(h => (
          <li key={h.id}>
            <button className={`toc-item depth-${h.depth ?? 0}`} aria-current={h.id === active ? 'location' : undefined} onClick={() => onJump(h.id)} title={h.title}>{h.title}</button>
          </li>
        ))}
      </ol>
    </nav>
  );
}
