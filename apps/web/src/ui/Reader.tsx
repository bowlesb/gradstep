// A converted paper in the sandboxed reader frame (legacy MarkdownReader on verified bundles): the
// contents tree in the left rail with the current section, citation jumps with Back, find in the
// paper, the figure viewer, text size and a saved place. Selection actions and passage-linked chat use the same verified index.
import { type ReactNode, type MutableRefObject, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import type { Activity } from '../lib/activity';
import { BackendError, functionPost } from '../lib/backend';
import { BundleError, type VerifiedBundle, loadBundle } from '../lib/bundle';
import { type ReaderPaper, paperReference, readerCacheKey } from '../lib/reader-paper';
import { prepareArxivReader, ArxivReaderError } from '../lib/arxiv-reader';
import { SELECTION_ACTIONS, type SelectionAction } from '../lib/chat';
import { bridgeAnchor, passageAnchor, resolveQuote, type Selection } from '../lib/passage';
import type { TextAnchor } from '../lib/events';
import { effectiveTags } from '../lib/paper';
import { type FrameKey, type FrameMessage, type ReaderReference, type ReaderFigureReference, frameDocument, readFrameMessage } from '../reader/frame';
import { FigureViewer } from './Figures';
import { Dialog } from './common';
import { Icon } from './icons';
import { readStored, writeStored } from './prefs';
import { useWorkspaceControls } from './Shell';

export type ReaderCache = Map<string, VerifiedBundle>; // owned by one signed-in session, memory only
export interface ReaderCommands { find: () => void; escape: () => boolean }
const FONT_KEY = 'gradstep.reader.fontSize';
const readFont = () => readStored(FONT_KEY, 18, v => typeof v === 'number' && v >= 13 && v <= 28);

function publicationLine(item: ReaderPaper): string | null {
  const m = item.metadata, parts: string[] = [];
  const year = m?.published_at ? Number(m.published_at.slice(0, 4)) : null;
  if (year && year >= 1000 && year <= 9999) parts.push(String(year));
  const venue = m?.venue?.split(/\s+/).join(' ').trim();
  if (venue) parts.push(venue.length > 80 ? venue.slice(0, 79) + '…' : venue);
  if (item.source_id) parts.push(item.source === 'web' ? 'Open access' : `arXiv ${item.source_id}${item.source_revision ? 'v' + item.source_revision : ''}`);
  return parts.length ? parts.join(' · ') : null;
}

function failure(error: unknown): string {
  if (error instanceof ArxivReaderError) return error.message;
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

type ReaderProps = { listenAction?: ReactNode; cache: ReaderCache; account: string; item: ReaderPaper; saved?: Activity; theme: 'light' | 'dark';
  contentsSlot: HTMLElement | null; commands: MutableRefObject<ReaderCommands | null>;
  marks: { id: string; anchor: TextAnchor }[]; passage: { id: string; anchor: TextAnchor; at: number } | null; onPassageHandled: () => void;
  onSelection: (action: SelectionAction, quote: string, anchor: TextAnchor) => void; onMarkedChat: (id: string) => void;
  /** Prepares an unsent draft; true only once the host accepted/persisted it. Never a paid Send. */
  onDiscuss?: (quote: string, anchor: TextAnchor) => Promise<boolean>; onReferenceAdded?: () => void; paperMenu?: ReactNode;
  onActivity: (itemID: string, activity: Activity) => void; onKey: (key: FrameKey) => void; onContents: () => void };

export function Reader(props: ReaderProps) {
  const { account, item } = props;
  const identity = readerCacheKey(account,item);
  return <PaperReader key={identity} cacheKey={identity} {...props} />;
}

type Heading = { id: string; title: string; depth?: number };

function PaperReader({ listenAction, cache, cacheKey, account, item, saved, theme, contentsSlot, commands, onActivity, onKey, onContents, onSelection, marks, passage, onPassageHandled, onMarkedChat, onDiscuss, onReferenceAdded, paperMenu }: ReaderProps & { cacheKey: string }) {
  const workspace = useWorkspaceControls();
  const [bundle, setBundle] = useState<VerifiedBundle | null>(() => cache.get(cacheKey) ?? null);
  const [loaded, setLoaded] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [headings, setHeadings] = useState<Heading[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [back, setBack] = useState(false);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [markedChats, setMarkedChats] = useState<string[]>([]);
  const [bridgeReady, setBridgeReady] = useState(false);
  const appliedPassage = useRef<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [reference, setReference] = useState<ReaderReference | null>(null);
  const [figureReference, setFigureReference] = useState<ReaderFigureReference | null>(null);
  const [referenceNotice, setReferenceNotice] = useState<{ text: string; operationID: string; message: string; kind: 'working' | 'done' | 'not_found' | 'failed' } | null>(null);
  const referenceRequest = useRef<AbortController | null>(null);
  useEffect(() => () => referenceRequest.current?.abort(), []);
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
    (item.kind === 'import' ? prepareArxivReader(paperReference(item)!, controller.signal, setLoaded)
      : loadBundle(account, item.id, controller.signal, fraction => { if (!controller.signal.aborted) setLoaded(fraction); })).then(verified => {
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
      const message: FrameMessage | null = readFrameMessage(event.data.value, bundle ?? undefined);
      if (!message) return;
      switch (message.type) {
        case 'headings':
          setHeadings(message.items);
          frameReady.current = true; setBridgeReady(true);
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
        case 'selection': setSelection(message.selection); break;
        case 'marks': if (message.ids.length === 1) onMarkedChat(message.ids[0]); else setMarkedChats(message.ids); break;
        case 'passage': if (!message.found) setNotice('Couldn’t find the passage. The paper may have changed.'); onPassageHandled(); break;
        case 'figure': setFigure({ id: message.id, open: true }); break;
        case 'reference': setReference(message.reference); break;
        // An older bridge never emits figureref. Keep its existing figure gallery path unchanged.
        case 'figureref': setFigureReference(message.reference); break;
        case 'tags': setNotice('Editing tags is not yet available in the browser.'); break;
        case 'invalid': setError('This paper couldn’t be shown.'); break;
        case 'find': setFound({ count: message.count, index: message.index }); break;
        case 'key': onKey(message.key); break;
      }
    };
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, [bundle, command, item.id, onActivity, onKey, saved, applyPresentation, initialPresentation, headingBlocks, onMarkedChat, onPassageHandled]);

  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(null), 5000); return () => clearTimeout(t); }, [notice]);

  const marksJSON = useMemo(() => JSON.stringify(marks.slice(0, 500).map(m => bridgeAnchor(m.id, m.anchor, item.artifact_id ?? undefined, bundle?.manifestSHA256))), [marks, item.artifact_id, bundle?.manifestSHA256]);
  useEffect(() => { if (bridgeReady) command('setMarks', JSON.parse(marksJSON)); }, [bridgeReady, command, marksJSON]);
  useEffect(() => {
    if (!passage || !bridgeReady || appliedPassage.current === passage.id) return;
    appliedPassage.current = passage.id;
    if (Date.now() - passage.at > 60_000) { onPassageHandled(); return; }
    // A different compile of the same source (or another artifact) keeps the quote search: `same` only decides whether the block hint applies.
    command('goToPassage', bridgeAnchor(passage.id, passage.anchor, item.artifact_id ?? undefined, bundle?.manifestSHA256));
  }, [passage, bridgeReady, command, item.artifact_id, onPassageHandled]);
  const quote = bundle && selection ? resolveQuote(bundle, selection) : null;

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
  const referenceAnchor = (text: string, blockID?: string): TextAnchor => ({ ...(item.artifact_id ? {artifactID:item.artifact_id} : {manifestSHA256:bundle!.manifestSHA256}), elementID: blockID, quote: text, prefix: '', suffix: '' });
  const discuss = onDiscuss ? (text: string, blockID?: string) => onDiscuss(text, referenceAnchor(text, blockID)) : undefined;
  const addReference = async (text: string, operationID: string = crypto.randomUUID()) => {
    referenceRequest.current?.abort();
    const controller = new AbortController(); referenceRequest.current = controller;
    setReference(null); setReferenceNotice({ text, operationID, kind: 'working', message: 'Adding to your library…' });
    try {
      // Match native's existing free catalog lookup; no cloud-search consent or chat request is implied.
      const result = await functionPost<{ status?: unknown; paper?: { title?: unknown } }>('add-reference', {
        operation_id: operationID, reference: [...text].slice(0, 2_000).join(''), capabilities: ['web_import'],
      }, { account, signal: controller.signal, maximum: 65_536 });
      if (controller.signal.aborted) return;
      const title = typeof result.paper?.title === 'string' && result.paper.title.length <= 1_000 ? `“${result.paper.title}”` : 'This paper';
      const messages: Record<string, string> = { added: `Added ${title}. It’s being prepared to read.`, present: `${title} is already in your library.`,
        closed: `${title} isn’t openly available, so it can’t be added.`, not_found: 'Couldn’t identify this reference.', needs_update: `${title} needs the latest version of Gradstep.` };
      const status = typeof result.status === 'string' ? result.status : '';
      setReferenceNotice({ text, operationID, kind: status === 'not_found' ? 'not_found' : Object.hasOwn(messages, status) ? 'done' : 'failed',
        message: Object.hasOwn(messages, status) ? messages[status] : 'Couldn’t add it right now.' });
      if (status === 'added') onReferenceAdded?.();
    } catch { if (!controller.signal.aborted) setReferenceNotice({ text, operationID, kind: 'failed', message: 'Couldn’t add it right now.' }); }
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
          {paperMenu}
          {listenAction}
          {back && <button className="primary small" onClick={() => command('citationBack')} data-testid="citation-back" aria-label="Back to where you were" title="Back to where you were"><Icon name="chevronLeft" size={14} />Back</button>}
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
        {quote && selection && bundle && <div className="selection-bar" role="toolbar" aria-label="Selected passage">
          {SELECTION_ACTIONS.map(({ action, title }) => <button key={action} className="secondary small" onClick={() => {
            const anchor = passageAnchor(item.artifact_id, selection, quote, item.kind === "import" ? bundle.manifestSHA256 : undefined);
            if (anchor) { onSelection(action, quote, anchor); setSelection(null); command('clearSelection'); }
          }}>{title}</button>)}
        </div>}
        {markedChats.length > 0 && <div className="selection-bar" role="group" aria-label="Chats about this passage">{markedChats.map((id, i) => <button key={id} className="secondary small" onClick={() => { onMarkedChat(id); setMarkedChats([]); }}>Chat {i + 1}</button>)}<button className="link" onClick={() => setMarkedChats([])}>Close</button></div>}
        {notice && <div className="toast" role="status">{notice}</div>}
        {referenceNotice && <div className="reader-reference-notice" role="status" data-testid="reference-notice">
          <span>{referenceNotice.message}</span>
          {referenceNotice.kind === 'not_found' && <button className="secondary small" onClick={() => {
            const text = referenceNotice.text; setReferenceNotice(null); onSelection('ingest', text, referenceAnchor(text));
          }}>Ask in chat</button>}
          {referenceNotice.kind === 'failed' && <button className="secondary small" onClick={() => void addReference(referenceNotice.text, referenceNotice.operationID)}>Try again</button>}
          {referenceNotice.kind !== 'working' && <button className="icon-button" aria-label="Dismiss reference message" onClick={() => setReferenceNotice(null)}><Icon name="close" size={14} /></button>}
        </div>}
      </div>
      {contentsSlot && headings.length > 0 && createPortal(<Contents headings={headings} active={active} onJump={jump} />, contentsSlot)}
      {reference && <ReferenceActions reference={reference} frame={frame.current} onClose={() => setReference(null)}
        onAdd={() => void addReference(reference.text)} onDiscuss={discuss ? () => discuss(reference.text, reference.blockID) : undefined} />}
      {bundle && figureReference && <FigureReferenceDetail bundle={bundle} reference={figureReference} theme={theme} fontSize={font}
        onClose={() => setFigureReference(null)} onGo={() => { setFigureReference(null); command('showFigure', figureReference.id, reduced(), true); }}
        onDiscuss={discuss} />}
      {bundle && figure.open && (
        <FigureViewer bundle={bundle} theme={theme} initial={figure.id} onDiscuss={discuss} onClose={() => setFigure({ id: null, open: false })}
          onShowInPaper={id => { setFigure({ id: null, open: false }); command('showFigure', id, reduced()); }} />
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


/** A compact, keyboard-accessible menu anchored to the bibliography entry, with no duplicate title row. */
function ReferenceActions({ reference, frame, onClose, onAdd, onDiscuss }: {
  reference: ReaderReference; frame: HTMLIFrameElement | null; onClose: () => void; onAdd: () => void; onDiscuss?: () => Promise<boolean>;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [busy, setBusy] = useState(false), [issue, setIssue] = useState<string | null>(null);
  useEffect(() => {
    const node = dialog.current;
    if (!node) return;
    if (!node.open) node.showModal();
    const host = frame?.getBoundingClientRect(), rect = reference.rect;
    const x = host && rect ? host.left + Math.max(0, Math.min(host.width, rect.x)) : innerWidth / 2;
    const y = host && rect ? host.top + Math.max(0, Math.min(host.height, rect.y + rect.height)) : innerHeight / 2;
    node.style.left = `${Math.max(8, Math.min(innerWidth - node.offsetWidth - 8, x))}px`;
    node.style.top = `${Math.max(8, Math.min(innerHeight - node.offsetHeight - 8, y + 6))}px`;
  }, [reference, frame, issue]);
  const prepare = async () => {
    if (!onDiscuss || busy) return;
    setBusy(true); setIssue(null);
    try { if (await onDiscuss()) onClose(); else setIssue('Couldn’t save the chat draft. The reference is still here.'); }
    catch { setIssue('Couldn’t save the chat draft. The reference is still here.'); }
    finally { setBusy(false); }
  };
  const copy = async () => {
    if (busy) return;
    try { await navigator.clipboard.writeText(reference.text); onClose(); }
    catch { setIssue('Couldn’t copy the reference. Try again.'); }
  };
  return <dialog ref={dialog} className="dialog reader-reference-menu" aria-label="Reference actions" onCancel={e => { e.preventDefault(); if (!busy) onClose(); }}
    onClick={e => { if (e.target === dialog.current && !busy) onClose(); }}>
    {reference.link && <a className="secondary small" href={reference.link.url} target="_blank" rel="noopener noreferrer" aria-disabled={busy || undefined} tabIndex={busy ? -1 : undefined} onClick={e => { if (busy) e.preventDefault(); else onClose(); }}>{reference.link.title}</a>}
    {onDiscuss && <button className="secondary small" disabled={busy} onClick={() => void prepare()}>{busy ? 'Saving draft…' : 'Discuss in chat'}</button>}
    <button className="secondary small" disabled={busy} onClick={onAdd}>Add to library</button>
    <button className="secondary small" disabled={busy} onClick={() => void copy()}>Copy</button>
    <button className="link small" disabled={busy} onClick={onClose}>Cancel</button>
    {issue && <p className="issue" role="alert">{issue}</p>}
  </dialog>;
}

/** Created only for a validated new-bridge message, so the legacy bridge never opens unsupported table/code detail. */
function FigureReferenceDetail({ bundle, reference, theme, fontSize, onClose, onGo, onDiscuss }: {
  bundle: VerifiedBundle; reference: ReaderFigureReference; theme: 'light' | 'dark'; fontSize: number;
  onClose: () => void; onGo: () => void; onDiscuss?: (text: string, blockID?: string) => Promise<boolean>;
}) {
  const doc = useMemo(() => frameDocument(bundle, { parentOrigin: location.origin, figureID: reference.id, theme, fontSize }), [bundle, reference.id, theme, fontSize]);
  const [busy, setBusy] = useState(false), [issue, setIssue] = useState<string | null>(null);
  const figure = bundle.index.figures.find(f => f.id === reference.id);
  const blockID = figure?.block_id ?? reference.id;
  const text = figure?.caption || bundle.index.blocks.find(b => b.id === blockID)?.text || reference.label;
  const discuss = async () => {
    if (!onDiscuss || busy) return;
    setBusy(true); setIssue(null);
    try { if (await onDiscuss(text, blockID)) onClose(); else setIssue('Couldn’t save the chat draft. Try again.'); }
    catch { setIssue('Couldn’t save the chat draft. Try again.'); }
    finally { setBusy(false); }
  };
  return <Dialog open onClose={() => { if (!busy) onClose(); }} title={reference.label} wide>
    <div className="reader-reference-detail">
      <div className="figure-head"><h2>{reference.label}</h2><button className="primary small" disabled={busy} onClick={onClose}>Done</button></div>
      <iframe className="figure-frame" title={reference.label} sandbox="allow-scripts" srcDoc={doc} />
      {issue && <p className="issue" role="alert">{issue}</p>}
      <div className="dialog-actions">
        {onDiscuss && <button className="secondary small" disabled={busy} onClick={() => void discuss()}>{busy ? 'Saving draft…' : 'Discuss in chat'}</button>}
        <button className="primary small" disabled={busy} onClick={onGo} data-testid="figure-reference-go">{reference.goTitle}</button>
      </div>
    </div>
  </Dialog>;
}
