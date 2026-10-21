// A paper prepared on this device in the sandboxed reader frame (legacy MarkdownReader on verified bundles): the
// contents tree in the left rail with the current section, citation jumps with Back, find in the
// paper, the figure viewer, text size and a saved place. Selection actions and passage-linked chat use the same verified index.
import { type ReactNode, type MutableRefObject, lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import type { Activity } from '../lib/activity';
import { BackendError, functionPost } from '../lib/backend';
import { BundleError, type VerifiedBundle, loadBundle } from '../lib/bundle';
import { type ReaderPaper, readerCacheKey, readingSource } from '../lib/reader-paper';
import { prepareArxivReader, ArxivReaderError } from '../lib/arxiv-reader';
import { SELECTION_ACTIONS, type SelectionAction } from '../lib/chat';
import { bridgeAnchor, citationAnchor, citedMarker, passageAnchor, resolveQuote, type Selection } from '../lib/passage';
import { citedBlock } from '../lib/paper-context';
import { contentsEquations, contentsFigures, contentsTables, type ContentsEquation, type ContentsFigure } from '../lib/paper-contents';
import { equationNumbers } from '../lib/equation';
import type { TextAnchor } from '../lib/events';
import { effectiveTags } from '../lib/paper';
import { figureName, figureNoun } from '../lib/figure-view';
import { type FrameKey, type FrameMessage, type ReaderReference, type ReaderFigureReference, frameDocument, readFrameMessage } from '../reader/frame';
import { EquationTiles } from './EquationTiles';
import { FigureViewer } from './Figures';
import { ReaderVersionDialog, type ReaderUpdate } from './ReaderVersion';
import { Dialog, InfoTip, MenuButton, SheetTop } from './common';
import { Icon } from './icons';
import { readStored, writeStored } from './prefs';
import { useWorkspaceControls } from './Shell';
import type { EquationHost } from './EquationView';
import type { FigureHost } from './FigureView';
import { LINE_WIDTH_KEY, LineWidthControl, readLineWidth, type ReadingMode } from './ReadingMode';
import type { ComposerDraft } from './Notes';
import { SnippetOverlay, type Box } from './SnippetOverlay';
import { prepareSnippetImage, SnippetImageError } from '../lib/note-images';
import { paperSource, snippetAnchor } from '../lib/snippet-source';

// The equation view brings the math typesetter: loaded only when an equation is opened (EQUATION_VIEW.md).
const EquationView = lazy(() => import('./EquationView'));

export type ReaderCache = Map<string, VerifiedBundle>; // owned by one signed-in session, memory only
export interface ReaderCommands { find: () => void; escape: () => boolean; /** The next (1) or previous (-1) section. */ section?: (delta: number) => void;
  /** The paper's ⋯ › Reader version details (READER_VERSIONS.md). */ versionDetails?: () => void;
  /** The paper's ⋯ › Draw snippet (NOTES_AND_SNIPPETS.md). */ drawSnippet?: () => void }
/** Notes from this paper: whether notes can be written (and hold images) here, and the composer to open. */
export interface NoteCapture { writable: boolean; images: boolean; add: (draft: ComposerDraft, adjust?: () => void) => void }
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

/** A short code for why the paper couldn't be shown (READER_VERSIONS.md), for the failure screen's ⓘ. Never text. */
function failureCode(error: unknown): string {
  if (error instanceof ArxivReaderError) return error.code;
  if (error instanceof BackendError) return error.code;
  if (error instanceof BundleError) return 'package_invalid';
  return 'unknown';
}

function failure(error: unknown): string {
  if (error instanceof ArxivReaderError) return error.message;
  if (error instanceof BackendError) {
    if (error.code === 'connection') return 'Couldn’t reach Gradstep. Check your connection and try again.';
    if (error.code === 'reader_not_ready' || error.code === 'item_unavailable') return 'This paper isn’t ready to read yet.';
    // The server's paper copies were deleted on 2026-10-16 (DATA_HANDLING_AND_COSTS.md "Server paper copies: retired").
    if (error.code === 'reader_unavailable') return 'Gradstep’s servers don’t keep a reading copy of this paper.';
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
  /** A kept explanation reopened from Your assets: its equation view or figure page, once the paper is ready. */
  explainer?: { id: string; kind: 'equation' | 'figure'; targetID: string; at: number } | null; onExplainerHandled?: () => void;
  onSelection: (action: SelectionAction, quote: string, anchor: TextAnchor, paragraph?: number) => void; onMarkedChat: (id: string) => void;
  /** Prepares an unsent draft; true only once the host accepted/persisted it. Never a paid Send. */
  onDiscuss?: (quote: string, anchor: TextAnchor) => Promise<boolean>; onReferenceAdded?: () => void; paperMenu?: ReactNode;
  /** The equation view's requests (the chat's consent and cache); without it the view shows the equation only. */
  onEditTags?: () => void; onAuthorSearch?: (name: string) => void;
  /** A keyword chip's choices (builds 73 and 75): ML paper search for it, or the library's papers with that tag. */
  onTagSearch?: (tag: string) => void; onShowTagged?: (tag: string) => void;
  equations?: EquationHost;
  /** The figure view's requests (FIGURE_VIEW.md), the same way. */
  figureView?: FigureHost;
  /** After a chat citation closed the chat drawer: reopens it (PaperView's Back to chat). */
  onBackToChat?: () => void;
  /** An explainer's citation now offers Back to its explainer: the host drops an older Back to chat (one Back at a time). */
  onExplainerReturn?: () => void;
  /** Reading mode (READING_MODE.md): the toolbar becomes a quiet bar over the paper. */
  reading?: ReadingMode;
  /** Notes: Add to note from a selection, a figure, table or equation, and Draw snippet. */
  noteCapture?: NoteCapture;
  onActivity: (itemID: string, activity: Activity) => void; onKey: (key: FrameKey) => void; onContents: () => void };

export function Reader(props: ReaderProps) {
  const { account, item } = props;
  const identity = readerCacheKey(account,item);
  return <PaperReader key={identity} cacheKey={identity} {...props} />;
}

type Heading = { id: string; title: string; depth?: number };

function PaperReader({ listenAction, cache, cacheKey, account, item, saved, theme, contentsSlot, commands, onActivity, onKey, onContents, onSelection, marks, passage, onPassageHandled, explainer, onExplainerHandled, onMarkedChat, onDiscuss, onReferenceAdded, paperMenu, equations, figureView, onEditTags, onAuthorSearch, onTagSearch, onShowTagged, onBackToChat, onExplainerReturn, reading, noteCapture }: ReaderProps & { cacheKey: string }) {
  const workspace = useWorkspaceControls();
  const [bundle, setBundle] = useState<VerifiedBundle | null>(() => cache.get(cacheKey) ?? null);
  const [loaded, setLoaded] = useState(0);
  const [error, setError] = useState<string | null>(null);
  // Beside a failure: the paper's PDF from arXiv ('only': arXiv has no HTML for this version, so Try again can't help).
  // 'network': arXiv was busy or unreachable, where Try again is the useful action (the apps' "Couldn't reach arXiv").
  const [pdfOffer, setPdfOffer] = useState<'pdf' | 'only' | 'network' | null>(null);
  const [errorCode, setErrorCode] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [headings, setHeadings] = useState<Heading[]>([]);
  const [active, setActive] = useState<string | null>(null);
  // Back after a jump: offered with the section it returns to ('' when unknown), null when not offered.
  const [back, setBack] = useState<{ from: string } | null>(null);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [author, setAuthor] = useState<string | null>(null);
  const [keyword, setKeyword] = useState<string | null>(null);
  const [markedChats, setMarkedChats] = useState<string[]>([]);
  const [bridgeReady, setBridgeReady] = useState(false);
  const appliedPassage = useRef<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [contentsDiscovered, setContentsDiscovered] = useState(() => readStored('gradstep.contents.doubleTapDiscovered', false, v => typeof v === 'boolean'));
  const [reference, setReference] = useState<ReaderReference | null>(null);
  const [figureReference, setFigureReference] = useState<ReaderFigureReference | null>(null);
  // Contents › Tables: a table with its whole caption, and Show in paper (as a figure reference's view).
  // Back to the explainer a citation left (a table's says Table, as the apps). The most recent origin wins: a chat
  // citation's passage replaces it, and setting it drops the host's Back to chat (build 73: both Backs showed).
  const [explainerReturn,setExplainerReturnState]=useState<{kind:'equation'|'figure'|'table';id:string}|null>(null);
  const setExplainerReturn=(value:{kind:'equation'|'figure'|'table';id:string}|null)=>{setExplainerReturnState(value);if(value)onExplainerReturn?.();};
  const figureReturn=(id:string)=>({kind:bundle&&figureNoun(figureName(bundle,id))==='Table'?'table' as const:'figure' as const,id});
  useEffect(()=>{if(passage)setExplainerReturnState(null);},[passage?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const [tableDetail, setTableDetail] = useState<ReaderFigureReference | null>(null);
  const [referenceNotice, setReferenceNotice] = useState<{ text: string; operationID: string; message: string; kind: 'working' | 'done' | 'not_found' | 'failed' } | null>(null);
  const referenceRequest = useRef<AbortController | null>(null);
  useEffect(() => () => referenceRequest.current?.abort(), []);
  // `explain`: AI Explainer opened the page, so the walkthrough is asked for at once.
  const [figure, setFigure] = useState<{ id: string | null; open: boolean; explain?: boolean }>({ id: null, open: false });
  // The equation view: the equation shown, the passage Explain in Chat starts from, and whether AI Explainer opened it.
  const [equation, setEquation] = useState<{ id: string; quote: string; anchor: TextAnchor | null; explain: boolean } | null>(null);
  // Contents › Equations › View as tiles.
  const [equationTiles, setEquationTiles] = useState(false);
  // ⋯ › Reader version details, and its Update this paper (the copy on screen stays until the new one is ready).
  const [versionOpen, setVersionOpen] = useState(false);
  const [update, setUpdate] = useState<ReaderUpdate | null>(null);
  const updateRequest = useRef<AbortController | null>(null);
  useEffect(() => () => updateRequest.current?.abort(), []);
  // The updated copy reopens near the place read in the one it replaced (a different manifest, so the place is approximate).
  const restoreAcross = useRef(false);
  // Notes: Draw snippet's box (frame viewport px), whether this engine can make the image, and pending frame replies.
  const [snippet, setSnippet] = useState<{ box: Box | null; busy: boolean; issue: string | null } | null>(null);
  const [captureSupport, setCaptureSupport] = useState<boolean | null>(null);
  const captureReplies = useRef(new Map<string, (message: Extract<FrameMessage, { type: 'capture' | 'captureProbe' }>) => void>());
  const drawSnippet = useRef(() => {});
  const [finding, setFinding] = useState(false);
  const [findText, setFindText] = useState('');
  const [found, setFound] = useState<{ count: number; index: number; matches: {index:number; text:string}[] } | null>(null);
  const [findList, setFindList] = useState(false);
  const [findFocus, setFindFocus] = useState(0);
  const [font, setFont] = useState(readFont);
  const [lineWidth, setLineWidth] = useState(readLineWidth);
  // Reading mode: how far through the paper (whole percent) and whether the quiet bar shows.
  const [progress, setProgress] = useState(0);
  const [barShown, setBarShown] = useState(false);
  const barTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const frame = useRef<HTMLIFrameElement>(null);
  // A crowded toolbar scrolls within itself (a phone with Back to chat and Back); it starts at its start again whenever
  // those appear or go, so Contents and the paper's menu stay in view.
  const toolbar = useRef<HTMLElement>(null);
  useEffect(() => { toolbar.current?.scrollTo({ left: 0 }); }, [!!back, !!onBackToChat]); // eslint-disable-line react-hooks/exhaustive-deps
  const findField = useRef<HTMLInputElement>(null);
  const frameReady = useRef(false);
  const title = item.metadata?.title ?? 'Paper';
  const pdfSource = readingSource(item);
  const paperLine = publicationLine(item), paperTags = JSON.stringify({names:effectiveTags(item),source:('tags_customized' in item && item.tags_customized) ? 'Your keywords' : 'Gradstep'});
  const [initialPresentation] = useState(() => ({ paperLine, paperTags, fontSize: font, theme, lineWidth }));
  const appliedPresentation = useRef(initialPresentation);

  useEffect(() => { document.title = `${title} · Gradstep`; return () => { document.title = 'Gradstep'; }; }, [title]);

  useEffect(() => {
    if (cache.has(cacheKey)) { setBundle(cache.get(cacheKey)!); return; }
    const controller = new AbortController();
    setError(null); setPdfOffer(null); setLoaded(0);
    // An arXiv paper reads from its official HTML prepared on this device (owner direction 2026-10-13), a legacy
    // item included. Its server bundle was the fallback when arXiv has no usable HTML for that revision; the server's
    // copies are gone (2026-10-16), so it is asked only while the library still says available, and its refusal
    // leaves arXiv's own reason (and the PDF offer) on screen.
    const bundle = () => loadBundle(account, item.id, controller.signal, fraction => { if (!controller.signal.aborted) setLoaded(fraction); });
    const source = readingSource(item);
    const fallback = (reason: ArxivReaderError) => bundle().catch(e => Promise.reject(e instanceof BackendError && (e.code === 'reader_unavailable' || e.code === 'item_unavailable') ? reason : e));
    (source ? prepareArxivReader(source, controller.signal, setLoaded, { authors: item.metadata?.authors ?? [], title: item.metadata?.title })
      .catch(e => item.kind === 'item' && item.render_availability === 'available' && e instanceof ArxivReaderError && !controller.signal.aborted ? fallback(e) : Promise.reject(e))
      : bundle()).then(verified => {
      if (controller.signal.aborted) return;
      cache.set(cacheKey, verified);
      while (cache.size > 3) cache.delete(cache.keys().next().value!);
      setBundle(verified);
    }, e => {
      if (controller.signal.aborted) return;
      setError(failure(e)); setErrorCode(failureCode(e));
      setPdfOffer(source && e instanceof ArxivReaderError ? (e.kind === 'network' ? 'network' : e.kind === 'no-html' ? 'only' : 'pdf') : null);
    });
    return () => controller.abort();
  }, [account, item.id, cache, cacheKey, attempt]);

  // One document per bundle. Live presentation changes use the shared native bridge, preserving
  // the reading place, DOM selection and citation-return state instead of navigating the frame.
  const srcdoc = useMemo(() => bundle ? frameDocument(bundle, { parentOrigin: location.origin, paperLine: initialPresentation.paperLine,
    paperAuthors: item.metadata?.authors ?? [], paperTags: JSON.parse(initialPresentation.paperTags), fontSize: initialPresentation.fontSize, theme: initialPresentation.theme,
    lineWidth: initialPresentation.lineWidth }) : null, [bundle, initialPresentation]);
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
    if (previous.lineWidth !== lineWidth) command('lineWidth', lineWidth);
    appliedPresentation.current = { paperLine, paperTags, fontSize: font, theme, lineWidth };
  }, [command, paperLine, paperTags, font, theme, lineWidth]);

  useEffect(applyPresentation, [applyPresentation]);

  const closeFind = useCallback(() => { setFinding(false); setFindList(false); setFindText(''); setFound(null); command('findClear'); }, [command]);
  const openFind = useCallback(() => { setFinding(true); setFindFocus(n => n + 1); }, []);
  useEffect(() => { if (findFocus) { findField.current?.focus(); findField.current?.select(); } }, [findFocus]);
  useEffect(() => {
    commands.current = {
      find: openFind,
      escape: () => { if (snippet && !snippet.busy) { setSnippet(null); return true; } if (finding) { closeFind(); return true; } return false; },
      section: delta => sectionStep.current(delta),
      versionDetails: () => setVersionOpen(true),
      drawSnippet: () => drawSnippet.current(),
    };
    return () => { commands.current = null; };
  }, [commands, openFind, closeFind, finding, snippet]);
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
          if (saved?.location && (saved.manifest === bundle?.manifestSHA256 || restoreAcross.current)) command('restore', saved.location);
          restoreAcross.current = false;
          onActivity(item.id, { ...(saved ?? { progress: 0 }), opened: Date.now() });
          break;
        case 'position': {
          const now = Date.now();
          // The bridge already bounds scroll reports (120 ms plus scroll-end). Keep the final one:
          // an additional leading-only throttle can discard the place just before leaving the paper.
          // App owns debounced, ordered encrypted persistence independently of this in-memory update.
          const { block, fraction, height, y } = message;
          onActivity(item.id, { opened: now, progress: message.progress, location: { block, fraction, height, y }, manifest: bundle?.manifestSHA256 });
          setProgress(Math.round(message.progress * 100));
          let current: string | null = null;
          for (const h of headingBlocks) { if (h.block <= block) current = h.id; else break; }
          setActive(current);
          break;
        }
        case 'citation': setBack(message.back ? { from: message.from } : null); break;
        case 'selection': setSelection(message.selection); break;
        case 'marks': if (message.ids.length === 1) onMarkedChat(message.ids[0]); else setMarkedChats(message.ids); break;
        case 'passage': if (!message.found) setNotice('Couldn’t find the passage. The paper may have changed.'); onPassageHandled(); break;
        case 'figure': setFigure({ id: message.id, open: true }); break;
        case 'reference': setReference(message.reference); break;
        // An older bridge never emits figureref. Keep its existing figure gallery path unchanged.
        case 'figureref': setFigureReference(message.reference); break;
        case 'tags': onEditTags?.(); break;
        case 'tag': { const tag = effectiveTags(item).find(t => t.trim().slice(0, 60) === message.name); if (tag) setKeyword(tag); break; }
        case 'contentsGesture':
          setContentsDiscovered(true); writeStored('gradstep.contents.doubleTapDiscovered', true);
          if (!workspace?.left.open) onContents();
          break;
        case 'author': if (item.metadata?.authors.includes(message.name)) setAuthor(message.name); break;
        case 'invalid': setError('This paper couldn’t be shown.'); break;
        case 'find': setFound({ count: message.count, index: message.index, matches: message.matches }); break;
        case 'key': onKey(message.key); break;
        case 'capture': case 'captureProbe': { const reply = captureReplies.current.get(message.nonce); captureReplies.current.delete(message.nonce); reply?.(message); break; }
      }
    };
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, [bundle, command, item.id, onActivity, onKey, saved, applyPresentation, initialPresentation, headingBlocks, onMarkedChat, onPassageHandled, onContents, workspace?.left.open]);

  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(null), 5000); return () => clearTimeout(t); }, [notice]);

  // ---------- Notes: Add to note and Draw snippet (NOTES_AND_SNIPPETS.md) ----------
  const ask = useCallback(<T extends 'capture' | 'captureProbe'>(name: T, args: unknown[], wait: number) => new Promise<Extract<FrameMessage, { type: T }>>(resolve => {
    const nonce = crypto.randomUUID();
    const timer = setTimeout(() => { captureReplies.current.delete(nonce); resolve({ type: name, nonce, ok: false, reason: 'timeout' } as Extract<FrameMessage, { type: T }>); }, wait);
    captureReplies.current.set(nonce, message => { clearTimeout(timer); resolve(message as Extract<FrameMessage, { type: T }>); });
    command(name, nonce, ...args);
  }), [command]);
  // Whether this browser can make an image of the page here (a canvas it may read back), asked once per paper.
  useEffect(() => { if (bridgeReady && captureSupport === null) void ask('captureProbe', [], 8000).then(r => setCaptureSupport(r.ok)); }, [bridgeReady, captureSupport, ask]);
  const noteFailure = (error: unknown) => error instanceof SnippetImageError && error.code === 'image_too_large'
    ? 'This snippet is too large to keep as an image. Draw a smaller box.' : 'Couldn’t make an image of this here. Try again.';
  const imageNotes = (): string | null => !noteCapture ? 'Your notes are still opening.' : !noteCapture.writable ? 'Notes can’t be changed in this tab.'
    : !noteCapture.images ? 'Snippets with images need this browser’s encrypted storage, which isn’t active in this tab. Select text and choose Add to note instead.' : null;
  drawSnippet.current = () => {
    const blocked = imageNotes();
    if (blocked) { setNotice(blocked); return; }
    if (captureSupport === false) { setNotice('Draw snippet isn’t available in this browser: it can’t make an image of the page here. Select text and choose Add to note, or add a whole figure from its page.'); return; }
    if (!bundle || !bridgeReady) return;
    if (finding) closeFind();
    setSelection(null); command('clearSelection');
    setSnippet({ box: null, busy: false, issue: null });
  };
  const takeSnippet = async (box: Box) => {
    if (!bundle || !noteCapture) return;
    setSnippet({ box, busy: true, issue: null });
    const reply = await ask('capture', [box], 30_000);
    if (!reply.ok) { setSnippet({ box, busy: false, issue: reply.reason === 'tainted' ? 'This browser can’t make an image of the page here.' : 'Couldn’t make the image. Try again.' }); return; }
    try {
      const image = await prepareSnippetImage(new Blob([reply.png], { type: 'image/png' }));
      const [vw, vh] = reply.viewport, [x, y, w, h] = reply.box;
      const draft: ComposerDraft = { kind: 'region', image, capturedAt: Date.now(), source: paperSource(item, bundle.index, reply.blocks[0]),
        anchor: snippetAnchor(bundle, reply.blocks, { rect: [x / vw, y / vh, w / vw, h / vh], viewport: reply.viewport }) };
      setSnippet(null);
      noteCapture.add(draft, () => setSnippet({ box, busy: false, issue: null }));
    } catch (error) { setSnippet({ box, busy: false, issue: noteFailure(error) }); }
  };
  // A figure's own verified image (one asset), else the element rendered here like a drawn region; equations and HTML
  // tables are rendered from the paper as shown. The open figure or equation page closes when the composer opens.
  const addElement = async (elementID: string, blockID: string | undefined, label: string | null, close?: () => void) => {
    const blocked = imageNotes();
    if (blocked) { setNotice(blocked); return; }
    if (!bundle) return;
    try {
      const figure = bundle.index.figures.find(f => f.id === elementID);
      const member = figure?.asset_paths.length === 1 ? bundle.manifest.members.find(m => m.path === figure.asset_paths[0] && m.role === 'image') : undefined;
      let image;
      if (member) image = await prepareSnippetImage(new Blob([bundle.contents.get(member.path)!], { type: member.media_type }));
      else {
        if (captureSupport === false) { setNotice('This browser can’t make an image of the page here.'); return; }
        const reply = await ask('capture', [{ element: elementID }], 30_000);
        if (!reply.ok) { setNotice('Couldn’t make an image of this here. Try again.'); return; }
        image = await prepareSnippetImage(new Blob([reply.png], { type: 'image/png' }));
      }
      close?.();
      noteCapture!.add({ kind: 'region', image, capturedAt: Date.now(), source: paperSource(item, bundle.index, blockID, label), anchor: snippetAnchor(bundle, blockID ? [blockID] : []) });
    } catch (error) { setNotice(noteFailure(error)); }
  };
  // "Equation (7)" as printed (read from the paper's page once, when first needed).
  const printed = useRef<{ manifest: string; numbers: Map<string, string> } | null>(null);
  const equationLabel = (id: string) => {
    if (!bundle) return 'Equation';
    if (printed.current?.manifest !== bundle.manifestSHA256) printed.current = { manifest: bundle.manifestSHA256, numbers: equationNumbers(bundle) };
    const n = printed.current.numbers.get(id);
    return n ? `Equation ${n}` : 'Equation';
  };
  const addSelection = (current: Selection, text: string) => {
    if (!bundle) return;
    if (!noteCapture?.writable) { setNotice(noteCapture ? 'Notes can’t be changed in this tab.' : 'Your notes are still opening.'); return; }
    const blocks = current.parts.map(p => p.blockID);
    noteCapture.add({ kind: 'quote', quote: text, capturedAt: Date.now(), source: paperSource(item, bundle.index, blocks[0]), anchor: snippetAnchor(bundle, blocks, { quote: text }) });
    setSelection(null); command('clearSelection');
  };

  const marksJSON = useMemo(() => JSON.stringify(marks.slice(0, 500).map(m => bridgeAnchor(m.id, m.anchor, item.artifact_id ?? undefined, bundle?.manifestSHA256))), [marks, item.artifact_id, bundle?.manifestSHA256]);
  useEffect(() => { if (bridgeReady) command('setMarks', JSON.parse(marksJSON)); }, [bridgeReady, command, marksJSON]);
  useEffect(() => {
    if (!passage || !bridgeReady || appliedPassage.current === passage.id) return;
    appliedPassage.current = passage.id;
    if (Date.now() - passage.at > 60_000) { onPassageHandled(); return; }
    // An answer's citation names a block number; it is resolved against this paper's index before the bridge sees it.
    const marker = citedMarker(passage.anchor);
    // A note's drawn region has no quote: it lands on the first block it covered, only in the copy it was captured from.
    const captured = marker === null && !passage.anchor.quote && passage.anchor.elementID && passage.anchor.manifestSHA256 === bundle?.manifestSHA256
      && bundle?.index.blocks.some(b => b.id === passage.anchor.elementID) ? passage.anchor.elementID : undefined;
    if (marker === null && !passage.anchor.quote && !captured) { setNotice('This snippet came from another copy of this paper, so its place isn’t shown.'); onPassageHandled(); return; }
    const block = marker !== null && bundle ? citedBlock(bundle.index, marker)?.id : captured;
    if (marker !== null && !block) { setNotice('This answer cites a passage this paper doesn’t have.'); onPassageHandled(); return; }
    // A different compile of the same source (or another artifact) keeps the quote search: `same` only decides whether the block hint applies.
    command('goToPassage', bridgeAnchor(passage.id, passage.anchor, item.artifact_id ?? undefined, bundle?.manifestSHA256, block));
  }, [passage, bridgeReady, command, item.artifact_id, onPassageHandled, bundle]);
  const quote = bundle && selection ? resolveQuote(bundle, selection) : null;
  const appliedExplainer = useRef<string | null>(null);
  useEffect(() => {
    if (!explainer || !bundle || !bridgeReady || appliedExplainer.current === explainer.id) return;
    appliedExplainer.current = explainer.id;
    onExplainerHandled?.();
    if (Date.now() - explainer.at > 60_000) return;
    if (explainer.kind === 'equation') {
      const target = equationTarget(explainer.targetID);
      if (target) setEquation(target); else setNotice('This equation isn’t in this copy of the paper.');
    } else if (bundle.index.figures.some(f => f.id === explainer.targetID)) setFigure({ id: explainer.targetID, open: true });
    else setNotice('This figure isn’t in this copy of the paper.');
  }, [explainer, bundle, bridgeReady]); // eslint-disable-line react-hooks/exhaustive-deps

  const changeLineWidth = (next: typeof lineWidth) => { setLineWidth(next); writeStored(LINE_WIDTH_KEY, next); };
  // J / K and the bar's arrows: the next or previous section from the one being read.
  const sectionStep = useRef((_delta: number) => {});
  sectionStep.current = delta => {
    if (!headings.length) return;
    const at = headings.findIndex(h => h.id === active);
    const next = headings[Math.max(0, Math.min(headings.length - 1, at < 0 ? 0 : at + delta))];
    if (next && next.id !== active) jump(next.id);
  };
  // The quiet bar: shown on entering (so it can be found), near the top edge, with keyboard focus inside it, and
  // while Back or Find is offered; otherwise it steps aside after a moment.
  const showBar = useCallback((hold = 0) => {
    if (barTimer.current) clearTimeout(barTimer.current);
    setBarShown(true);
    if (hold) barTimer.current = setTimeout(() => setBarShown(false), hold);
  }, []);
  const hideBarSoon = useCallback(() => {
    if (barTimer.current) clearTimeout(barTimer.current);
    barTimer.current = setTimeout(() => setBarShown(false), 1200);
  }, []);
  useEffect(() => {
    if (!reading?.on) { setBarShown(false); return; }
    showBar(2500);
    // The paper takes the keyboard: Space, arrows and Page keys scroll it at once.
    const t = setTimeout(() => { frame.current?.focus(); frame.current?.contentWindow?.focus(); }, 50);
    return () => clearTimeout(t);
  }, [reading?.on, showBar]);
  useEffect(() => () => { if (barTimer.current) clearTimeout(barTimer.current); }, []);
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
  // Contents › Equations: the equation centred and highlighted in the paper, with Back (reader-bridge.js).
  const showEquation = (id: string) => {
    command('showEquation', id, reduced());
    if (workspace && !workspace.left.inline) workspace.show('left', false);
  };
  const updateCopy = () => {
    const source = readingSource(item);
    if (!source || update?.running) return;
    updateRequest.current?.abort();
    const controller = new AbortController(); updateRequest.current = controller;
    setUpdate({ running: true });
    prepareArxivReader(source, controller.signal, undefined, { authors: item.metadata?.authors ?? [], title: item.metadata?.title }).then(verified => {
      if (controller.signal.aborted) return;
      cache.set(cacheKey, verified);
      restoreAcross.current = true; frameReady.current = false; setBridgeReady(false);
      setError(null); setPdfOffer(null); setErrorCode(null);
      setBundle(verified); setUpdate({ running: false, updated: true });
    }, e => { if (!controller.signal.aborted) setUpdate({ running: false, failure: failure(e), code: failureCode(e) }); });
  };
  // An equation shown without being tapped (switched to in the equation view, a kept explanation): its passage as a
  // tap would make it, for Explain in Chat.
  const equationTarget = (id: string, explain = false) => {
    const e = bundle?.index.equations.find(x => x.id === id);
    if (!bundle || !e) return null;
    const tapped: Selection = { manifest: bundle.manifestSHA256, parts: [{ kind: 'equation', blockID: e.block_id, equationID: e.id }], context: null };
    const quote = resolveQuote(bundle, tapped) ?? e.latex;
    return { id, quote, anchor: passageAnchor(item.artifact_id, tapped, quote, item.kind === 'import' ? bundle.manifestSHA256 : undefined), explain };
  };
  // A paragraph the equation view names ("From the paper ¶12"): the reader lands on it with Back offered, as a chat citation does.
  const goToCited = (marker: number) => {
    const block = bundle ? citedBlock(bundle.index, marker)?.id : undefined;
    if (!bundle || !block) { setNotice('This paragraph isn’t in this paper.'); return; }
    command('goToPassage', bridgeAnchor(crypto.randomUUID(), citationAnchor(marker), item.artifact_id ?? undefined, bundle.manifestSHA256, block));
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
    <div className={`reader${reading?.on ? ' reading' : ''}${reading?.on && !(barShown || back || finding) ? ' bar-hidden' : ''}`} data-theme-frame={theme}>
      {reading?.on && <div className="reading-progress" style={{ transform: `scaleX(${progress / 100})` }} aria-hidden="true" />}
      {reading?.on && <div className="reading-hotzone" onMouseEnter={() => showBar()} onMouseLeave={hideBarSoon} aria-hidden="true" />}
      <header className="paper-toolbar" ref={toolbar} onMouseEnter={reading?.on ? () => showBar() : undefined} onMouseLeave={reading?.on ? hideBarSoon : undefined}
        onFocus={reading?.on ? () => showBar() : undefined} onBlur={reading?.on ? hideBarSoon : undefined}>
        <button className={`icon-button${contentsShown ? ' on' : ''}`} onClick={onContents} disabled={!bridgeReady} data-testid="contents"
          aria-label="Contents" aria-pressed={contentsShown} title="Contents ( [ )"><Icon name="list" /></button>
        <h1 className="reader-title" title={title}>{title}</h1>
        {reading?.on && <span className="reading-status" aria-live="off" data-testid="reading-status">
          {headings.find(h => h.id === active)?.title ?? ''}<span className="reading-percent">{progress}%</span></span>}
        <div className="reader-actions">
          {paperMenu}
          {listenAction}
          {onBackToChat && <button className="primary small" onClick={onBackToChat} data-testid="chat-back" aria-label="Back to chat" title="Back to chat"><Icon name="chevronLeft" size={14} /><span className="back-long">Back to chat</span><span className="back-short" aria-hidden="true">Chat</span></button>}
          {back && (() => { const label = back.from ? `Back to ${back.from}` : 'Back to where you were'; return <span className="citation-back">
            <button className="primary small" onClick={() => { setBack(null); command('citationBack'); }} data-testid="citation-back" aria-label={label} title={label}>
              <Icon name="chevronLeft" size={14} /><span className="back-long">{label}</span><span className="back-short" aria-hidden="true">Back</span></button>
            <button className="icon-button" onClick={() => { setBack(null); command('endCitation'); }} data-testid="citation-dismiss" aria-label="Dismiss Back" title="Dismiss Back"><Icon name="close" size={14} /></button>
          </span>; })()}
          <button className={`icon-button${finding ? ' on' : ''}`} onClick={() => (finding ? closeFind() : openFind())} disabled={!srcdoc} aria-label="Find in paper" title="Find in paper (⌘F)" data-testid="find"><Icon name="search" /></button>
          <button className="tool-button" onClick={() => setFigure({ id: null, open: true })} disabled={!figures.length} title="Figures" data-testid="figures">
            <Icon name="image" /><span>Figures</span>{figures.length > 0 && <span className="count">{figures.length}</span>}</button>
          <span className="font-buttons" role="group" aria-label="Text size">
            <button className="icon-button text-size" onClick={() => changeFont(-1)} aria-label="Smaller text" title="Smaller text" disabled={font <= 13}><span className="a-small">A</span></button>
            <button className="icon-button text-size" onClick={() => changeFont(1)} aria-label="Larger text" title="Larger text" disabled={font >= 28}><span className="a-large">A</span></button>
          </span>
          <LineWidthControl value={lineWidth} onChange={changeLineWidth} />
          <button className={`icon-button reading-toggle${reading?.on ? ' on' : ''}`} onClick={() => reading?.toggle()} disabled={!reading || !srcdoc}
            aria-pressed={!!reading?.on} data-testid="reading-mode" aria-label={reading?.on ? 'Exit reading mode' : 'Reading mode'}
            title={reading?.on ? 'Exit reading mode (Esc)' : 'Reading mode (F)'}><Icon name={reading?.on ? 'close' : 'book'} /></button>
          <button className={`tool-button${workspace?.right.open ? ' on' : ''}`} onClick={() => workspace?.toggle('right')} aria-pressed={!!workspace?.right.open}
            data-testid="ask" title="Chat ( ] )"><Icon name="chat" /><span>Chat</span></button>
        </div>
      </header>
      {explainerReturn && <button type="button" className="secondary small explainer-return" data-testid="explainer-return" onClick={()=>{if(explainerReturn.kind==='equation')setEquation(equationTarget(explainerReturn.id));else setFigure({id:explainerReturn.id,open:true});setExplainerReturn(null);}}>Back to {explainerReturn.kind==='equation'?'Equation':explainerReturn.kind==='table'?'Table':'Figure'} Explainer</button>}
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
          <button type="button" className="icon-button" disabled={!found?.count} aria-label="List occurrences" onClick={()=>setFindList(v=>!v)}><Icon name="list" /></button>
          <button type="button" className="icon-button" onClick={() => command('find', findText, 'previous')} disabled={!found?.count} aria-label="Previous match"><Icon name="chevronUp" /></button>
          <button type="button" className="icon-button" onClick={() => command('find', findText, 'next')} disabled={!found?.count} aria-label="Next match"><Icon name="chevronDown" /></button>
          <button type="button" className="link" onClick={closeFind}>Done</button>
        </form>
      )}
      {finding && findList && <div className="find-occurrences" role="list" aria-label="Occurrences">{found?.matches.map(m=><button type="button" key={m.index} onClick={()=>{command('find',findText,m.index);setFindList(false);}}>{m.index+1}. {m.text}</button>)}</div>}
      <div className="paper-stage">
        {error ? ((pdfOffer === 'pdf' || pdfOffer === 'only') && pdfSource ? (
          // One screen whatever stopped the reader (owner, build 62: "there should be just one"; "remove the try again"):
          // the paper's PDF, opened from arXiv by this browser (ARXIV_DEVICE_ONLY.md); the reason's code behind an ⓘ.
          <div className="empty reader-failure" data-testid="reader-failure" data-info-bounds>
            <Icon name="book" size={32} />
            <h2>Read this paper as its PDF</h2>
            <p role="alert">{pdfOffer === 'only' ? 'arXiv has no web version of this paper.' : 'Its web version couldn’t be prepared in this browser.'}</p>
            <div className="reader-failure-actions">
              <a className="primary" href={`https://arxiv.org/pdf/${pdfSource.sourceID}v${pdfSource.revision}`}
                target="_blank" rel="noopener noreferrer" data-testid="reader-open-pdf">Open PDF</a>
              {pdfOffer === 'pdf' && errorCode && <InfoTip text={`${error}\n\nCode: ${errorCode}`} testID="reader-failure-info" />}
            </div>
          </div>
        ) : (
          // arXiv busy or unreachable (its PDF would fail the same way), or a paper that isn't from arXiv: Try again.
          <div className="empty reader-failure" data-testid="reader-failure" data-info-bounds>
            {pdfOffer === 'network' && <h2>Couldn’t reach arXiv</h2>}
            <p role="alert">{error}</p>
            <div className="reader-failure-actions">
              <button className="primary" onClick={() => { setError(null); setPdfOffer(null); setErrorCode(null); setAttempt(a => a + 1); }}>Try again</button>
              {pdfOffer === 'network' && errorCode && <InfoTip text={`${error}\n\nCode: ${errorCode}`} testID="reader-failure-info" />}
            </div>
          </div>
        )) : srcdoc ? (
          <iframe ref={frame} className="reader-frame" title={title} sandbox="allow-scripts" srcDoc={srcdoc} data-testid="reader-frame" />
        ) : (
          <div className="empty" role="status"><p>{loaded < 0.8 ? 'Downloading…' : 'Preparing…'} {Math.floor(loaded * 100)}%</p>
            <progress max={1} value={loaded} aria-label={`${loaded < 0.8 ? 'Downloading' : 'Preparing'} ${Math.floor(loaded * 100)} percent`} /></div>
        )}
        {quote && selection && bundle && <div className="selection-bar" role="toolbar" aria-label="Selected passage">
          {SELECTION_ACTIONS.filter(({action}) => !(selection.parts.length === 1 && selection.parts[0].kind === 'equation') || ['define','similar'].includes(action)).flatMap(({ action, title }) => [<button key={action} className="secondary small" onClick={() => {
            const anchor = passageAnchor(item.artifact_id, selection, quote, item.kind === "import" ? bundle.manifestSHA256 : undefined);
            const paragraph = bundle.index.blocks.findIndex(b => b.id === selection.parts[0]?.blockID) + 1;
            if (action === 'define' && selection.parts.length === 1 && selection.parts[0].kind === 'equation' && selection.parts[0].equationID) { setEquation({ id:selection.parts[0].equationID,quote,anchor,explain:false }); setSelection(null); command('clearSelection'); return; }
            if (anchor) { onSelection(action, quote, anchor, paragraph > 0 ? paragraph : undefined); setSelection(null); command('clearSelection'); }
          }}>{action === 'define' && selection.parts.length === 1 && selection.parts[0].kind === 'equation' ? 'Chat about Equation' : title}</button>,
            // One tapped equation: AI Explainer, right after Explain, opens its view and asks at once (owner, build 62:
            // "Replace Explain with AI Explainer"; EQUATION_VIEW.md).
            ...(action === 'define' && selection.parts.length === 1 && selection.parts[0].kind === 'equation' && selection.parts[0].equationID ? [
              <button key="equation" className="secondary small" data-testid="equation-open" onClick={() => {
                const anchor = passageAnchor(item.artifact_id, selection, quote, item.kind === "import" ? bundle.manifestSHA256 : undefined);
                setEquation({ id: selection.parts[0].equationID!, quote, anchor, explain: true }); setSelection(null); command('clearSelection');
              }}>AI Explainer</button>] : [])])}
          {/* Notes: the selection as a quotation (no AI), or a tapped equation as its rendered image. */}
          {noteCapture && <button className="secondary small" data-testid="selection-add-to-note" onClick={() => {
            const part = selection.parts[0];
            if (selection.parts.length === 1 && part.kind === 'equation' && part.equationID) {
              const e = part.equationID; setSelection(null); command('clearSelection');
              void addElement(e, part.blockID, equationLabel(e));
            } else addSelection(selection, quote);
          }}>Add to note</button>}
        </div>}
        {snippet && srcdoc && !error && <SnippetOverlay initial={snippet.box} busy={snippet.busy} issue={snippet.issue} onUse={box => void takeSnippet(box)} onCancel={() => setSnippet(null)} />}
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
      {contentsSlot && bundle && bridgeReady && createPortal(<Contents discovered={contentsDiscovered} headings={headings} active={active} bundle={bundle} onJump={jump}
        onFigure={id => setFigure({ id, open: true })} onTiles={() => setFigure({ id: null, open: true })} onEquation={showEquation} onEquationTiles={() => setEquationTiles(true)}
        onTable={t => setTableDetail({ id: t.id, label: t.number ?? 'Table', goTitle: 'Show in paper' })} />, contentsSlot)}
      {reference && <ReferenceActions reference={reference} frame={frame.current} onClose={() => setReference(null)}
        onAdd={() => void addReference(reference.text)} onDiscuss={discuss ? () => discuss(reference.text, reference.blockID) : undefined} />}
      {bundle && figureReference && <FigureReferenceDetail bundle={bundle} reference={figureReference} theme={theme} fontSize={font}
        onClose={() => setFigureReference(null)} onGo={() => { setFigureReference(null); command('showFigure', figureReference.id, reduced(), true); }}
        onChat={figureView?.context ? () => { setFigureReference(null); setFigure({ id: figureReference.id, open: true }); } : undefined}
        onDiscuss={discuss} onExplain={figureView && bundle.index.figures.some(f => f.id === figureReference.id)
          ? () => { setFigureReference(null); setFigure({ id: figureReference.id, open: true, explain: true }); } : undefined} />}
      {bundle && tableDetail && <FigureReferenceDetail bundle={bundle} reference={tableDetail} theme={theme} fontSize={font}
        onAddToNote={noteCapture ? () => { const f = bundle.index.figures.find(x => x.id === tableDetail.id); const block = f?.block_id ?? tableDetail.id;
          void addElement(tableDetail.id, block, tableDetail.label, () => setTableDetail(null)); } : undefined}
        onChat={figureView?.context && bundle.index.figures.some(f => f.id === tableDetail.id) ? () => { setTableDetail(null); setFigure({ id: tableDetail.id, open: true }); } : undefined}
        onClose={() => setTableDetail(null)} onDiscuss={discuss} onExplain={figureView && bundle.index.figures.some(f => f.id === tableDetail.id)
          ? () => { setTableDetail(null); setFigure({ id: tableDetail.id, open: true, explain: true }); } : undefined} onGo={() => {
          setTableDetail(null); command('showFigure', tableDetail.id, reduced(), true); if (workspace && !workspace.left.inline) workspace.show('left', false);
        }} />}
      {/* A keyword chip (owner, builds 73 and 75: "an option right at the top to search ML papers based on this keyword";
          "ideally you can choose either external or internal"), the search first; editing stays one step away. */}
      <Dialog open={!!keyword} onClose={() => setKeyword(null)} title={keyword ?? 'Keyword'}>
        <h2>{keyword}</h2>
        <div className="keyword-actions" data-testid="keyword-actions">
          {onTagSearch && <button className="primary" onClick={() => { const tag = keyword; setKeyword(null); if (tag) onTagSearch(tag); }}>Search ML papers for “{keyword}”</button>}
          {onShowTagged && <button className="secondary" onClick={() => { const tag = keyword; setKeyword(null); if (tag) onShowTagged(tag); }}>Show library papers tagged “{keyword}”</button>}
          {onEditTags && <button className="secondary" onClick={() => { setKeyword(null); onEditTags(); }}>Edit keywords…</button>}
        </div>
      </Dialog>
      <Dialog open={!!author} onClose={() => setAuthor(null)} title="Author">
        <h2>{author}</h2><button className="primary" onClick={() => { if (author) onAuthorSearch?.(author); setAuthor(null); }}>Find papers by {author}</button>
      </Dialog>
      {bundle && equation && <Suspense fallback={null}><EquationView key={equation.id} bundle={bundle} equationID={equation.id} theme={theme} fontSize={font} host={equations}
        autoExplain={equation.explain} onSwitch={id => setEquation(equationTarget(id))}
        onClose={() => setEquation(null)} onCite={marker => { setExplainerReturn({kind:'equation',id:equation.id}); setEquation(null); goToCited(marker); }}
        onAsk={discuss && equation.anchor ? () => { const { quote: text, anchor } = equation; setEquation(null); void onDiscuss!(text, anchor!); } : undefined}
        onAddToNote={noteCapture ? () => { const e = bundle.index.equations.find(x => x.id === equation.id); void addElement(equation.id, e?.block_id, equationLabel(equation.id), () => setEquation(null)); } : undefined} /></Suspense>}
      {versionOpen && <ReaderVersionDialog bundle={bundle} update={update} onUpdate={updateCopy} onClose={() => setVersionOpen(false)} />}
      {bundle && equationTiles && <EquationTiles bundle={bundle} theme={theme} onClose={() => setEquationTiles(false)}
        onEquation={id => { setEquationTiles(false); showEquation(id); }} />}
      {bundle && figure.open && (
        <FigureViewer bundle={bundle} theme={theme} initial={figure.id} explain={figure.explain} onDiscuss={discuss} onClose={() => setFigure({ id: null, open: false })} figureView={figureView}
          onAddToNote={noteCapture ? id => { const f = bundle.index.figures.find(x => x.id === id); void addElement(id, f?.block_id, figureName(bundle, id), () => setFigure({ id: null, open: false })); } : undefined}
          onCite={(marker,id) => { setExplainerReturn(figureReturn(id)); setFigure({ id: null, open: false }); goToCited(marker); if (workspace && !workspace.left.inline) workspace.show('left', false); }}
          onShowInPaper={id => { setExplainerReturn(figureReturn(id)); setFigure({ id: null, open: false }); command('showFigure', id, reduced()); if (workspace && !workspace.left.inline) workspace.show('left', false); }} />
      )}
    </div>
  );
}

type ContentsTab = 'contents' | 'figures' | 'tables' | 'equations';
const CONTENTS_TABS: readonly [ContentsTab, string][] = [['contents', 'Contents'], ['figures', 'Figures'], ['tables', 'Tables'], ['equations', 'Equations']];

/** The paper's contents (a tree with the current section marked) beside its Figures, Tables and Equations (owner,
 * build 59: "four tabs… The default selected when you enter should be contents… minimalistic but nicely designed…
 * consistent styling in the rows and be clickable into the paper"), as the app's PaperContentsSheet. A figure or table
 * row opens that figure or table with its whole caption; an equation row goes to it in the paper with Back. Tables are
 * the captioned tables the index lists (revision 16) beside those arXiv published as images (contentsTables). */
function Contents({ discovered, headings, active, bundle, onJump, onFigure, onTable, onTiles, onEquation, onEquationTiles }: {
  discovered: boolean; headings: Heading[]; active: string | null; bundle: VerifiedBundle; onJump: (id: string) => void;
  onFigure: (id: string) => void; onTable: (table: ContentsFigure) => void; onTiles: () => void; onEquation: (id: string) => void; onEquationTiles: () => void;
}) {
  const [tab, setTab] = useState<ContentsTab>('contents');
  const list = useRef<HTMLOListElement>(null), tabs = useRef<HTMLDivElement>(null);
  useEffect(() => { if (tab === 'contents') list.current?.querySelector('[aria-current="location"]')?.scrollIntoView({ block: 'nearest' }); }, [active, tab]);
  const figures = useMemo(() => contentsFigures(bundle.index), [bundle]);
  const tables = useMemo(() => contentsTables(bundle.index), [bundle]);
  // The equations' printed numbers come from reading the paper's page: only once its tab is opened.
  const [equations, setEquations] = useState<ContentsEquation[] | null>(null);
  useEffect(() => {
    if (tab !== 'equations' || equations) return;
    const numbers = equationNumbers(bundle);
    setEquations(contentsEquations(bundle.index, id => numbers.get(id) ?? null));
  }, [tab, equations, bundle]);
  // Arrow keys move between the tabs (the ARIA tabs pattern); the chosen tab takes focus.
  const step = (event: React.KeyboardEvent, index: number) => {
    const to = event.key === 'ArrowRight' ? index + 1 : event.key === 'ArrowLeft' ? index - 1 : event.key === 'Home' ? 0 : event.key === 'End' ? CONTENTS_TABS.length - 1 : null;
    if (to === null) return;
    event.preventDefault();
    const next = (to + CONTENTS_TABS.length) % CONTENTS_TABS.length;
    setTab(CONTENTS_TABS[next][0]);
    tabs.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus();
  };
  const rows = tab === 'figures' ? figures.filter(f => !f.table) : tab === 'tables' ? tables : [];
  return (
    <div className="contents-panel">
      {!discovered && <p className="contents-touch-hint">Double tap anywhere while reading the article for this menu</p>}
      <div className="contents-tabbar">
        <div className="contents-tabs" role="tablist" aria-label="Show" ref={tabs}>
          {CONTENTS_TABS.map(([id, title], index) => <button key={id} role="tab" id={`contents-tab-${id}`} aria-selected={tab === id} aria-controls="contents-tabpanel"
            tabIndex={tab === id ? 0 : -1} onClick={() => setTab(id)} onKeyDown={e => step(e, index)} data-testid={`contents-tab-${id}`}>{title}</button>)}
        </div>
      </div>
      <div className="contents-tabpanel" id="contents-tabpanel" role="tabpanel" aria-labelledby={`contents-tab-${tab}`}>
        {tab === 'contents' ? (headings.length ? <nav className="contents-tree" aria-label="Contents">
          <ol ref={list}>
            {headings.map(h => (
              <li key={h.id}>
                <button className={`toc-item depth-${h.depth ?? 0}`} aria-current={h.id === active ? 'location' : undefined} onClick={() => onJump(h.id)} title={h.title}>{h.title}</button>
              </li>
            ))}
          </ol>
        </nav> : <p className="contents-empty">No sections</p>)
        : tab === 'equations' ? (!equations ? <p className="contents-empty" role="status">Preparing…</p> : equations.length ? <ul className="contents-rows" aria-label="Equations">
          {/* Owner, build 62: "Equation 1, Equation 2" without the equation's text, and a tile view like Figures'. */}
          <li><button className="contents-tiles" onClick={onEquationTiles} data-testid="contents-equation-tiles"><Icon name="grid" size={14} />View as tiles</button></li>
          {equations.map((e, i) => <li key={e.id}><button className="contents-row" onClick={() => onEquation(e.id)} data-testid={`contents-equation-${i}`}>
            <span className="contents-row-title">{e.label}</span></button></li>)}
        </ul> : <p className="contents-empty">No equations</p>)
        : rows.length ? <ul className="contents-rows" aria-label={tab === 'tables' ? 'Tables' : 'Figures'}>
          {/* Owner, build 59: "a link to the same squares based view". */}
          {tab === 'figures' && <li><button className="contents-tiles" onClick={onTiles} data-testid="contents-figure-tiles"><Icon name="grid" size={14} />View as tiles</button></li>}
          {/* "Figure 1 — Subplots of …", the caption cut at two lines; the row opens the figure with its whole caption. */}
          {rows.map((f, i) => <li key={f.id}><button className="contents-row" onClick={() => f.block ? onTable(f) : onFigure(f.id)} data-testid={`contents-${tab === 'tables' ? 'table' : 'figure'}-${i}`}>
            <span className="contents-row-caption"><strong>{f.number ?? (tab === 'tables' ? 'Table' : 'Figure')}</strong>{f.caption && <span className="contents-row-detail"> — {f.caption}</span>}</span>
          </button></li>)}
        </ul> : <p className="contents-empty">{tab === 'tables' ? 'No tables' : 'No figures'}</p>}
      </div>
    </div>
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
/** A figure, table or code block on its own: one top row — Explain in Chat and, for a figure or table the figure view
 * can read, AI Explainer (its walkthrough on the figure page) — and the X (owner, build 62; DESIGN.md "Sheet top row");
 * Show in paper (or Go to …) under it. */
function FigureReferenceDetail({ bundle, reference, theme, fontSize, onClose, onGo, onDiscuss, onExplain, onChat, onAddToNote }: {
  bundle: VerifiedBundle; reference: ReaderFigureReference; theme: 'light' | 'dark'; fontSize: number;
  onClose: () => void; onGo: () => void; onDiscuss?: (text: string, blockID?: string) => Promise<boolean>; onExplain?: () => void; onChat?: () => void;
  /** Notes: this table (or figure) as an image into the composer. */ onAddToNote?: () => void;
}) {
  const doc = useMemo(() => frameDocument(bundle, { parentOrigin: location.origin, figureID: reference.id, theme, fontSize }), [bundle, reference.id, theme, fontSize]);
  const [busy, setBusy] = useState(false), [issue, setIssue] = useState<string | null>(null);
  const figure = bundle.index.figures.find(f => f.id === reference.id);
  const blockID = figure?.block_id ?? reference.id;
  const text = figure?.caption || bundle.index.blocks.find(b => b.id === blockID)?.text || reference.label;
  const noun = figureNoun(figure ? figureName(bundle, figure.id) : reference.label);
  const discuss = async () => {
    if (!onDiscuss || busy) return;
    setBusy(true); setIssue(null);
    try { if (await onDiscuss(text, blockID)) onClose(); else setIssue('Couldn’t save the chat draft. Try again.'); }
    catch { setIssue('Couldn’t save the chat draft. Try again.'); }
    finally { setBusy(false); }
  };
  return <Dialog open onClose={() => { if (!busy) onClose(); }} title={reference.label} wide>
    <div className="reader-reference-detail">
      <SheetTop onClose={onClose} closeDisabled={busy} testID="figure-reference-close">
        {(onChat || onDiscuss) && <button className="sheet-action" disabled={busy} onClick={() => onChat ? onChat() : void discuss()} data-testid="figure-reference-ask"
          title={`Ask about this ${noun.toLowerCase()}; nothing is sent`}><Icon name="chat" size={15} />{busy ? 'Saving draft…' : `Chat about ${noun}`}</button>}
        {onExplain && <button className="sheet-action" disabled={busy} onClick={onExplain} data-testid="figure-reference-explain"
          title="Walks through it part by part. Uses credits."><Icon name="sparkles" size={15} />AI Explainer</button>}
        {onAddToNote && <button className="sheet-action" disabled={busy} onClick={onAddToNote} data-testid="table-add-to-note" title="Save this in a note"><Icon name="notes" size={15} />Add to note</button>}
        {!onDiscuss && !onExplain && !onAddToNote && <h2>{reference.label}</h2>}
      </SheetTop>
      <iframe className="figure-frame" title={reference.label} sandbox="allow-scripts" srcDoc={doc} />
      {issue && <p className="issue" role="alert">{issue}</p>}
      <div className="figure-nav">
        <button className="secondary small" disabled={busy} onClick={onGo} data-testid="figure-reference-go">{reference.goTitle}</button>
      </div>
    </div>
  </Dialog>;
}
