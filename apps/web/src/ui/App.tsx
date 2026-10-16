import {useDevicePDFs} from './useDevicePDFs';
import type {ClientEntry, LibraryPaper} from '../lib/device-pdf';
import { localChatContext, observeArxivSources, prepareArxivReader } from '../lib/arxiv-reader';
import { sourceMetadataReporter } from '../lib/source-metadata';
import { type ReaderPaper, ReaderBundles, isReaderPaper, isSourcePaper, paperIdentity, paperReference, readerCacheKey, readingSource } from '../lib/reader-paper';
import { type FocusEvent as ReactFocusEvent, type ReactNode, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { type Activity, loadActivity, saveActivity } from '../lib/activity';
import { AuthError, type AuthIssue, type Session, auth, config, operationsDashboard, operatorRoles } from '../lib/backend';
import { type DeviceRecord, type Preparation, forgetDevice, readDevice } from '../lib/keys';
import type { Item } from '../lib/library';
import type { Episode, Evidence } from '../lib/podcast';
import { clearPositions, evidenceAnchor } from '../lib/podcast-playback';
import { supportsX25519 } from '../lib/wire';
import type { FrameKey } from '../reader/frame';
import { ChatHistory, ChatPane, type PaperContext, useChatUpdates } from './ChatPane';
import { ChatDefaultsDialog } from './ChatProfile';
import { readVisualAnswers, writeVisualAnswers } from '../lib/chat-session';
import type { ChatSession } from '../lib/chat-session';
import { useChat } from './useChat';
import { actionFor, selectionPrompt, type SelectionAction } from '../lib/chat';
import type { TextAnchor } from '../lib/events';
import { Brand, Dialog } from './common';
import { FeedRail, FeedView, useFeed } from './Feed';
import { PaperSearchView, usePaperSearch } from './PaperSearch';
import { ListenView, PaperListen, PodcastDock, usePodcasts, usePodcastPlayer } from './Podcast';
import { Icon, type IconName } from './icons';
import { KeySetup } from './Keys';
import { RegionBoundary } from './ErrorBoundary';
import { AddPaper, CompactLibrary, INITIAL_QUERY, type LibraryQuery, LibraryRail, LibraryView, useLibraryModel } from './Library';
import { LibraryActionSurface, PaperMenuButton, useLibraryActions } from './LibraryActions';
import { readStored, type Route, type Theme, useTheme, writeStored } from './prefs';
/** The Library's filter and tag, remembered between visits (per browser, a convenience only). */
const LIBRARY_FILTER_KEY = 'gradstep.library.filter', LIBRARY_TAG_KEY = 'gradstep.library.tag';
import { type ReaderCache, type ReaderCommands, Reader } from './Reader';
import type { EquationHost } from './EquationView';
import { PaneHeader, Workspace, useWorkspace } from './Shell';
import { useReadingMode } from './ReadingMode';
import { SignIn } from './SignIn';
import { StorageNotice, storageGuidance } from './StorageNotice';
import { ReportDialog, ReportsDialog } from './SupportReports';
import { HowGradstepWorks } from './HowGradstepWorks';
import { useLibrary } from './useLibrary';

type Ready = Extract<Preparation, { kind: 'ready' }>;

function usePath(): [string, (path: string) => void] {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => { const pop = () => setPath(location.pathname); addEventListener('popstate', pop); return () => removeEventListener('popstate', pop); }, []);
  const navigate = useCallback((next: string) => { if (next !== location.pathname) history.pushState(null, '', next); setPath(next); }, []);
  return [path, navigate];
}

export function App() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const [oauth, setOAuth] = useState<{ working: boolean; issue: AuthIssue | null }>({ working: location.pathname === '/auth/callback', issue: null });
  const { session, generation } = useSyncExternalStore(auth.subscribe, auth.snapshot);

  useEffect(() => {
    (async () => setSupported(!!config.url && typeof indexedDB !== 'undefined' && !!crypto?.subtle && await supportsX25519()))();
  }, []);

  useEffect(() => {
    if (location.pathname !== '/auth/callback') return;
    let live = true;
    void auth.completeOAuth().then(() => { if (live) setOAuth({ working: false, issue: null }); })
      .catch(error => { if (live) setOAuth({ working: false, issue: error instanceof AuthError ? error.issue : 'oauth_invalid' }); });
    return () => { live = false; };
  }, []);

  if (supported === null) return null;
  if (!supported) return <Unsupported />;
  if (oauth.working) return <OAuthCallback />;
  if (!session) return <SignIn initialIssue={oauth.issue} />;
  return <AccountSession key={generation} session={session} />;
}

function OAuthCallback() {
  return <main className="auth-shell"><section className="card auth-card" aria-live="polite"><Brand />
    <h1>Completing sign-in</h1><p className="muted">Returning securely from your provider…</p><span className="spinner" aria-label="Working" />
  </section></main>;
}

/** Refreshing tokens preserves this tree; signing out or starting another login always retires it. */
function AccountSession({ session }: { session: Session }) {
  const [ready, setReady] = useState<Ready | null>(null);
  if (!ready) return <KeySetup account={session.user.id} email={session.user.email} onReady={setReady} onSignOut={() => void auth.signOut()} />;
  return <Signed session={session} ready={ready} />;
}

function Unsupported() {
  return (
    <main className="auth-shell"><section className="card auth-card"><Brand />
      <h1>This browser isn’t supported</h1>
      <p className="muted">Gradstep needs encryption and local key storage, with site data allowed. Try another current browser, or use Gradstep on iPhone, iPad or Mac. Private windows may not work.</p>
    </section></main>
  );
}

const SHORTCUTS = [['/ or ⌘K', 'Search the library or ML papers'], ['⌘F', 'Find in the paper'], ['[', 'Show or hide the side panel'], [']', 'Show or hide the chat panel'],
  ['F', 'Reading mode (Esc leaves it)'], ['J K', 'Next or previous section'], ['Space', 'Page down in the paper (Shift: up)'],
  ['↑ ↓', 'Move between papers'], ['← →', 'Previous or next figure'], ['Esc', 'Close, or clear the search'], ['?', 'These shortcuts']] as const;
const PLAIN_KEYS: Record<string, FrameKey> = { '/': 'search', '[': 'left', ']': 'right', '?': 'help', f: 'reading', j: 'next', k: 'previous' };

function Signed({ session, ready }: { session: Session; ready: Ready }) {
  const account = session.user.id;
  // What this browser reads about a paper it prepares goes to the server only while it asks (ARXIV_DEVICE_ONLY.md §5.3).
  useEffect(() => observeArxivSources(sourceMetadataReporter(account)), [account]);
  const chat = useChat(account, ready);
  const devicePDFs=useDevicePDFs(chat);
  const library = useLibrary(account,devicePDFs);
  // The reader has the same paper action surface as Library. Keeping a separate owner avoids
  // two portals competing when a library menu is still closing during navigation.
  const readerActions = useLibraryActions(library);
  const historyVersion = useSyncExternalStore(chat?.history.subscribe ?? (() => () => {}), chat?.history.getVersion ?? (() => 0));
  const [chatMode, setChatMode] = useState<'paper' | 'general'>('paper');
  const [orphanPaper, setOrphanPaper] = useState<PaperContext | null>(null);
  const [passage, setPassage] = useState<{ id: string; documentID: string; anchor: TextAnchor; at: number } | null>(null);
  // After a chat citation closed the chat drawer: the reader's Back to chat (ReaderModel.returnToChat).
  const [chatReturn, setChatReturn] = useState(false);
  const [path, moveTo] = usePath();
  const [navigationIssue, setNavigationIssue] = useState(false);
  const navigationIntent = useRef(0);
  const navigate = useCallback(async (next: string, arriving?: () => void): Promise<boolean> => {
    const intent = ++navigationIntent.current, owner = auth.snapshot();
    let failed = false;
    try { await chat?.flushCheckpoints(); } catch { failed = true; }
    if (owner.signal.aborted || navigationIntent.current !== intent) return false;
    // Install a passage only when this navigation wins. A later click, Back or sign-out cannot
    // leave a deferred passage behind to jump during an unrelated future paper open.
    arriving?.();
    // A failed local save stays in the account-owned controller and All chats; navigation still
    // honors the click. A later click or sign-out supersedes this continuation.
    setNavigationIssue(failed); moveTo(next); return true;
  }, [chat, moveTo]);
  useEffect(() => {
    const pop = () => {
      ++navigationIntent.current; // browser Back/Forward wins over a pending app navigation
      const owner = auth.snapshot();
      void chat?.flushCheckpoints().catch(() => { if (!owner.signal.aborted) setNavigationIssue(true); });
    };
    addEventListener('popstate', pop);
    return () => { ++navigationIntent.current; removeEventListener('popstate', pop); };
  }, [chat]);
  const [device, setDevice] = useState<DeviceRecord | null>(null);
  const [activity, setActivity] = useState<Map<string, Activity>>(new Map());
  const [activityLoaded, setActivityLoaded] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [forget, setForget] = useState(false);
  const [chats, setChats] = useState(false);
  const [howGradstepWorks, setHowGradstepWorks] = useState(false);
  const [help, setHelp] = useState(false);
  const [reportOpen, setReportOpen] = useState(false);
  const report = useCallback(() => setReportOpen(true), []);
  const [reportsOpen, setReportsOpen] = useState(false);
  const [chatDefaults, setChatDefaults] = useState(false);
  const [adding, setAdding] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  const [readerCache] = useState(() => new ReaderBundles());
  const readerCacheVersion = useSyncExternalStore(readerCache.subscribe, readerCache.getVersion);
  // Which papers this tab has prepared (the library row's check, PaperDeviceCopy).
  const prepared = useCallback((e: ClientEntry) => isReaderPaper(e) && readerCache.has(readerCacheKey(account, e)), [readerCache, account, readerCacheVersion]); // eslint-disable-line react-hooks/exhaustive-deps
  // A paper added from the Feed is prepared right away, as the apps do, so opening it doesn't download again; the
  // Feed shows the percent meanwhile (sourceID → fraction).
  const [feedPreparing, setFeedPreparing] = useState<Map<string, number>>(new Map());
  const feedAdded = useRef(new Set<string>());
  const preparationScope = useRef(new AbortController());
  useEffect(() => () => preparationScope.current.abort(), []);
  useEffect(() => {
    for (const sourceID of [...feedAdded.current]) {
      // The paper the reader will open (a source paper, or an arXiv item read from its official HTML).
      const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID && !!readingSource(e));
      if (!paper) continue;
      feedAdded.current.delete(sourceID);
      const key = readerCacheKey(account, paper);
      if (readerCache.has(key)) continue;
      const progress = (fraction: number) => setFeedPreparing(m => new Map(m).set(sourceID, fraction));
      progress(0);
      void prepareArxivReader(readingSource(paper)!, preparationScope.current.signal, progress, { authors: paper.metadata?.authors ?? [], title: paper.metadata?.title })
        .then(bundle => { readerCache.set(key, bundle); while (readerCache.size > 3) readerCache.delete(readerCache.keys().next().value!); })
        .catch(() => { /* opening the paper prepares it again and says why if it can't */ })
        .finally(() => setFeedPreparing(m => { const next = new Map(m); next.delete(sourceID); return next; }));
    }
  }, [library.entries, account, readerCache]);
  useEffect(()=>{
    if(!chat)return;
    chat.setSourcePapers(new Map(library.entries.filter(isSourcePaper).map(paper=>[paper.id,{reference:paperReference(paper)!,load:async()=>{
      const key=readerCacheKey(account,paper),saved=readerCache.get(key);if(saved)return saved;
      const bundle=await prepareArxivReader(paperReference(paper)!,chat.signal,undefined,{authors:paper.metadata?.authors??[],title:paper.metadata?.title});chat.signal.throwIfAborted();
      readerCache.set(key,bundle);while(readerCache.size>3)readerCache.delete(readerCache.keys().next().value!);return bundle;
    }}])));
  },[chat,library.entries,readerCache,account]);
  // Library search, filters and sort survive opening a paper and coming back (UX_PARITY.md); the filter and the tag are
  // remembered between visits too, as the apps remember them (owner-approved follow-up, 2026-10-07).
  const [view, setViewState] = useState<LibraryQuery>(() => ({ ...INITIAL_QUERY,
    filter: readStored<LibraryQuery['filter']>(LIBRARY_FILTER_KEY, 'all', v => typeof v === 'string' && ['all', 'unread', 'reading', 'failed', 'archived'].includes(v)),
    tag: readStored<string>(LIBRARY_TAG_KEY, '', v => typeof v === 'string' && v.length <= 200) }));
  const setView = useCallback((next: LibraryQuery | ((q: LibraryQuery) => LibraryQuery)) => setViewState(previous => {
    const value = typeof next === 'function' ? next(previous) : next;
    if (value.filter !== previous.filter) writeStored(LIBRARY_FILTER_KEY, value.filter);
    if (value.tag !== previous.tag) writeStored(LIBRARY_TAG_KEY, value.tag);
    return value;
  }), []);
  const [railTab, setRailTab] = useState<'contents' | 'library'>('contents');
  const [contentsSlot, setContentsSlot] = useState<HTMLElement | null>(null);
  const [lastPaper, setLastPaper] = useState<string | null>(null);
  const { theme, resolved, setTheme } = useTheme();
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const search = useRef<HTMLInputElement>(null);
  // Paper search beside the library search (native RootView: the Library / arXiv switch under the field while
  // searching; PaperSearch.tsx). Each side keeps its own query, as native libraryQuery and discoveryQuery do.
  const paperSearch = usePaperSearch(account);
  const [searchExternal, setSearchExternal] = useState(false);
  const [searchFocus, setSearchFocus] = useState(false);
  const scope = useRef<HTMLDivElement>(null);
  const pointerDown = useRef(false);
  useEffect(() => {
    const down = () => { pointerDown.current = true; }, up = () => { pointerDown.current = false; };
    addEventListener('pointerdown', down, true); addEventListener('pointerup', up, true); addEventListener('pointercancel', up, true);
    return () => { removeEventListener('pointerdown', down, true); removeEventListener('pointerup', up, true); removeEventListener('pointercancel', up, true); };
  }, []);
  const readerCommands = useRef<ReaderCommands | null>(null);
  const openReader = useCallback((paper: ReaderPaper, anchor?: TextAnchor) => navigate(`/paper/${paper.id}`, () => {
    setLastPaper(paper.id);
    setPassage(anchor ? { id: crypto.randomUUID(), documentID: paperIdentity(paper), anchor, at: Date.now() } : null);
  }), [navigate]);

  useEffect(() => {
    let live = true;
    setActivityLoaded(false);
    readDevice(account).then(async record => {
      if (!record || record.deviceID !== ready.deviceID) return;
      const saved = await loadActivity(record);
      if (!live) return;
      setDevice(record); setActivity(saved);
    }).catch(() => {}).finally(() => { if (live) setActivityLoaded(true); });
    return () => { live = false; if (saveTimer.current) clearTimeout(saveTimer.current); readerCache.clear(); };
  }, [account, ready.deviceID]);

  const openPaper = useCallback((paper:LibraryPaper,anchor?:TextAnchor) => {
    if(paper.kind==='local_pdf'){devicePDFs.open(paper);return Promise.resolve(true);}
    return openReader(paper,anchor);
  },[devicePDFs,openReader]);
  const record = useCallback((itemID: string, value: Activity) => {
    if (!activityLoaded || leaving) return;
    setActivity(previous => {
      const next = new Map(previous); next.set(itemID, value);
      return next;
    });
  }, [activityLoaded, leaving]);

  useEffect(() => {
    if (!device || !ready.local || leaving) return;
    const local = ready.local;
    const timer = setTimeout(() => { saveActivity(device, activity, local).catch(() => {}); }, 500);
    saveTimer.current = timer;
    return () => clearTimeout(timer);
  }, [device, activity, leaving, ready.local]);

  const match = /^\/paper\/([0-9a-f-]{36})$/.exec(path);
  const paperID = match?.[1] ?? null;
  const route: Route = paperID ? 'paper' : path === '/feed' ? 'feed' : 'library';
  const item = paperID ? library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.id === paperID && e.visible) : undefined;
  useEffect(() => { if (path !== '/' && path !== '/feed' && !match) navigate('/'); }, [path, match, navigate]);
  useEffect(() => { if (paperID) setLastPaper(paperID); setOrphanPaper(null); setChatMode(paperID ? 'paper' : 'general'); }, [paperID]);

  const ws = useWorkspace(route);
  // Back to chat goes away once the chat is open again or the paper is left.
  useEffect(() => { if (ws.right.open || route !== 'paper') setChatReturn(false); }, [ws.right.open, route]);
  const reading = useReadingMode(ws, route === 'paper' && !!item);
  const latest = useRef({ ws, route, paperID, reading });
  latest.current = { ws, route, paperID, reading };
  const model = useLibraryModel(library, activity, view, route !== 'paper' || (railTab === 'library' && ws.left.open));
  const feed = useFeed(account, library.serverEntries);
  const podcasts = usePodcasts(account);
  const player = usePodcastPlayer(account);
  const [listening, setListening] = useState(false);

  const shortcut = useCallback((key: FrameKey) => {
    const { ws, route, reading } = latest.current;
    switch (key) {
      case 'reading': if (route === 'paper') reading.toggle(); break;
      case 'next': if (route === 'paper') readerCommands.current?.section?.(1); break;
      case 'previous': if (route === 'paper') readerCommands.current?.section?.(-1); break;
      case 'search': search.current?.focus(); search.current?.select(); break;
      case 'find': if (route === 'paper') readerCommands.current?.find(); break;
      case 'left': ws.toggle('left'); break;
      case 'right': ws.toggle('right'); break;
      case 'help': setHelp(true); break;
      case 'escape':
        if (readerCommands.current?.escape()) break;
        if (ws.overlay) ws.show(ws.overlay, false);
        // Reading mode: a slide-over closes first, then reading mode ends.
        else if (reading.on && (ws.left.open || ws.right.open)) { if (ws.right.open) ws.show('right', false); if (ws.left.open) ws.show('left', false); }
        else if (reading.on) reading.exit();
        break;
    }
  }, []);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented || document.querySelector('dialog[open]')) return;
      const target = event.target as HTMLElement | null;
      const typing = !!target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
      const command = (event.metaKey || event.ctrlKey) && !event.altKey;
      let action: FrameKey | null = null;
      if (command && event.key.toLowerCase() === 'k') action = 'search';
      else if (command && event.key.toLowerCase() === 'f' && latest.current.route === 'paper') action = 'find';
      else if (event.key === 'Escape') action = 'escape';
      else if (!typing && !command && !event.altKey) action = PLAIN_KEYS[event.key] ?? null;
      if (!action) return;
      if (action !== 'escape') event.preventDefault();
      shortcut(action);
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [shortcut]);

  async function signOut() {
    if (leaving) return;
    const owner = auth.snapshot();
    setLeaving(true); setSignOutError(null);
    if (saveTimer.current) clearTimeout(saveTimer.current);
    try {
      // Finish local removal before another login can prepare this device. Failure stays visible and retryable.
      await chat?.settleBeforeSignOut();
      owner.signal.throwIfAborted();
      if (forget) await forgetDevice(account, owner.signal);
      else if (device && ready.local) await saveActivity(device, activity, ready.local).catch(() => {});
      if (!forget) await chat?.retireJournal();
      if (owner.signal.aborted || owner.generation !== auth.snapshot().generation) return;
      if (forget) clearPositions(account);
      ++navigationIntent.current;
      moveTo('/'); // settleBeforeSignOut already drained; the journal is now retired
      await auth.signOut(owner.generation);
    } catch (error) {
      if (!owner.signal.aborted) {
        chat?.resumeAfterSignOutFailure();
        setSignOutError(storageGuidance(error) ? 'This tab can’t change Gradstep’s storage after the update in another tab. Sign out from the updated tab instead.'
          : forget ? 'Couldn’t remove this browser’s keys. Try again.' : 'Some work couldn’t be saved on this device. Keep this tab open, copy any unsaved text, and retry the save before signing out.');
        setLeaving(false);
      }
    }
  }

  const searchText = searchExternal ? paperSearch.query : view.query;
  const searching = searchFocus || !!searchText || searchExternal;
  // Focus may move between the field and its switch without ending the search (native searchFocused). When a click
  // elsewhere takes focus, the switch stays until that click has landed, so nothing moves under the pointer.
  const inSearch = (node: Node | null) => !!node && (!!search.current?.contains(node) || !!scope.current?.contains(node));
  const leaveSearch = (event: ReactFocusEvent) => {
    if (inSearch(event.relatedTarget as Node | null)) return;
    if (!pointerDown.current) { setSearchFocus(false); return; }
    const settle = () => {
      removeEventListener('pointerup', settle, true); removeEventListener('pointercancel', settle, true);
      setTimeout(() => { if (!inSearch(document.activeElement)) setSearchFocus(false); }, 0);
    };
    addEventListener('pointerup', settle, true); addEventListener('pointercancel', settle, true);
  };
  const chooseScope = (external: boolean) => {
    setSearchExternal(external);
    if (external) {
      if (route !== 'library') navigate('/');
      // Switching with a query that wasn't searched yet searches it (native onChange of searchExternal).
      if (paperSearch.state.kind === 'idle' && paperSearch.query.trim()) paperSearch.run();
    }
  };
  const cancelSearch = () => {
    setSearchExternal(false); setView(q => ({ ...q, query: '' })); paperSearch.setQuery(''); setSearchFocus(false); search.current?.blur();
  };
  const query = (text: string) => {
    setView(q => ({ ...q, query: text }));
    // Beside a paper, the library search shows its results in the rail; from the Feed it returns to the library.
    if (route === 'paper' && text.trim()) { setRailTab('library'); if (!ws.left.open) ws.show('left'); }
    if (route === 'feed' && text.trim()) navigate('/');
  };
  const onContents = () => {
    if (ws.left.open && railTab === 'contents') ws.show('left', false);
    else { setRailTab('contents'); ws.show('left'); }
  };
  const railVisible = ws.left.open && ws.left.inline;
  const paperContext = orphanPaper ?? (item ? { documentID: paperIdentity(item), title: item.metadata?.title ?? 'Paper', available: isSourcePaper(item) || (item.readiness === 'converted_ready' && item.render_availability === 'available') } : null);
  const paperNames = useMemo(() => new Map(library.entries.filter((e): e is ReaderPaper => isReaderPaper(e) && e.visible).map(e => [paperIdentity(e), e.metadata?.title ?? 'Paper'])), [library.entries]);
  const openChatDocument = async (documentID: string | null, anchor?: TextAnchor) => {
    if (!documentID) setChatMode('general');
    else {
      const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && paperIdentity(e) === documentID);
      if (paper) { if (!await openPaper(paper, anchor)) return; setOrphanPaper(null); }
      else setOrphanPaper({ documentID, title: 'Paper no longer in library', available: false });
      setChatMode('paper');
    }
    // A citation from a chat that covers the paper (a drawer: phone, narrow window) closes it so the passage shows, and
    // the reader offers Back to chat (PaperView's reader.chat.back); beside the paper, the chat stays open.
    if (anchor && !latest.current.ws.right.inline) { latest.current.ws.show('right', false); setChatReturn(true); }
    else latest.current.ws.show('right');
  };
  const goToPassage = (documentID: string, anchor: TextAnchor) => {
    void openChatDocument(documentID, anchor);
  };
  const selectAction = (action: SelectionAction, quote: string, anchor: TextAnchor, paragraph?: number) => {
    if (!chat || chat.storageRetired || !item) return; // the storage notice explains why nothing is sent
    // The new conversation answers with the model, effort and length the chat pane shows right now.
    const visible = chat.current(chatMode === 'paper' && paperContext ? paperContext.documentID : null);
    const composer = chat.newChat(paperIdentity(item), chat.profileFor(visible));
    chat.edit(composer, selectionPrompt(action, quote, paragraph)); setChatMode('paper'); ws.show('right');
    void chat.send(composer, quote, actionFor[action], anchor).then(() => { if (action === 'ingest') void library.refresh().catch(() => {}); });
  };
  const discuss = async (quote: string, anchor: TextAnchor): Promise<boolean> => {
    if (!chat || chat.storageRetired || !item) return false;
    const owner = auth.snapshot(), sourcePaper = item.id;
    const composer = await chat.discuss(paperIdentity(item), quote, anchor);
    if (!composer || owner.signal.aborted || latest.current.paperID !== sourcePaper) return false;
    setChatMode('paper'); latest.current.ws.show('right');
    // The reader closes its modal only after this promise resolves. Focus on the next paint, when
    // the composer is no longer inert; never submit a provider request from Discuss.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!owner.signal.aborted && latest.current.paperID === sourcePaper && chat.current(paperIdentity(item)).id === composer.id) {
        document.querySelector<HTMLTextAreaElement>('.chat-composer textarea')?.focus();
      }
    }));
    return true;
  };
  // The equation view's requests: the chat's consent, default model and cache for this paper (EQUATION_VIEW.md).
  const equationDocument = item ? paperIdentity(item) : null;
  const equationHost = useMemo<EquationHost | undefined>(() => chat && equationDocument ? {
    consented: () => chat.cloudConsent, accept: () => chat.acceptCloudConsent(),
    saved: (manifest, equationID, action) => chat.savedEquation(manifest, equationID, action),
    run: (input, action, update, signal) => chat.equation(equationDocument, input, action, update, signal),
  } : undefined, [chat, equationDocument]);
  const marks = useMemo(() => chat?.history.state.conversationSummaries().filter(c => c.documentID === (item ? paperIdentity(item) : undefined) && c.anchor).map(c => ({ id: c.id, anchor: c.anchor! })) ?? [], [chat, historyVersion, (item ? paperIdentity(item) : undefined)]);

  const openPodcastEvidence = async (episode: Episode, evidence: Evidence): Promise<boolean | null> => {
    const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && paperIdentity(e) === episode.documentID);
    if (!paper) return false;
    return await openPaper(paper, evidenceAnchor(evidence)) ? true : null;
  };
  const addPodcastPaper = async (episode: Episode) => {
    if (!episode.source.arxivID) throw new Error('source_unavailable');
    await library.addArxiv(episode.source.arxivID, episode.source.version);
  };

  const left = route === 'paper' ? (
    <>
      <PaneHeader title={<span className="tabs" role="tablist" aria-label="Side panel">
        <button role="tab" aria-selected={railTab === 'contents'} className={railTab === 'contents' ? 'tab on' : 'tab'} onClick={() => setRailTab('contents')}>Contents</button>
        <button role="tab" aria-selected={railTab === 'library'} className={railTab === 'library' ? 'tab on' : 'tab'} onClick={() => setRailTab('library')}>Library</button>
      </span>} onClose={() => ws.show('left', false)} closeLabel="Hide side panel" />
      <div className="rail-body" role="tabpanel">
        {railTab === 'contents' ? <div ref={setContentsSlot} className="contents-slot"><p className="fine rail-note">The contents appear when the paper opens.</p></div>
          : <CompactLibrary model={model} activity={activity} currentID={paperID} onOpen={openPaper} query={view.query} prepared={prepared} />}
      </div>
    </>
  ) : (
    <>
      <PaneHeader title={route === 'feed' ? 'Feed' : 'Library'} onClose={() => ws.show('left', false)} closeLabel="Hide side panel" />
      <div className="rail-body">{route === 'feed' ? <FeedRail model={feed} listen={{ selected: listening, select: setListening, view: null }} /> : <LibraryRail model={model} view={view} setView={next => { setSearchExternal(false); setView(next); }} />}</div>
    </>
  );

  let center: ReactNode;
  if (paperID) {
    // A direct paper URL can finish loading the library before local decryption. Mounting the
    // reader then would record the top of the paper before its saved place could be restored.
    center = item && !activityLoaded ? <div className="empty" role="status" aria-label="Opening paper"><div className="spinner" /><p>Opening the paper…</p></div>
      : item ? <Reader paperMenu={<PaperMenuButton item={item} busy={library.pending.has(item.id)} expanded={readerActions.menuItemID === item.id} onOpen={readerActions.open} />} listenAction={<PaperListen key={item.id} account={account} itemID={item.id} title={item.metadata?.title ?? 'Paper'} player={player} onBrowseShared={() => { setListening(true); void navigate('/feed'); }} deviceSource={isSourcePaper(item) ? async signal => {
        // The paper's own text on this device (migration 066): the verified bundle's numbered context, as the chat sends it.
        const key = readerCacheKey(account, item); const bundle = readerCache.get(key) ?? await prepareArxivReader(paperReference(item)!, signal, undefined, { authors: item.metadata?.authors ?? [], title: item.metadata?.title });
        const context = localChatContext(paperReference(item)!, bundle);
        return { text: { format: 'paper-context-v2', text: context.text }, identity: { source: 'arxiv', source_id: context.source_id, revision: context.revision, manifest_sha256: context.manifest_sha256, title: item.metadata?.title ?? undefined, authors: item.metadata?.authors ?? [] } };
      } : undefined} />} cache={readerCache} account={account} item={item} saved={activity.get(item.id)} onActivity={record} theme={resolved}
        contentsSlot={railTab === 'contents' && ws.left.open ? contentsSlot : null} commands={readerCommands} onKey={shortcut} onContents={onContents} onSelection={selectAction} marks={marks}
        passage={passage?.documentID === paperIdentity(item) ? passage : null} onPassageHandled={() => setPassage(null)}
        onDiscuss={discuss} onReferenceAdded={() => { void library.refresh().catch(() => {}); }} equations={equationHost}
        onBackToChat={chatReturn && !ws.right.open ? () => { setChatReturn(false); ws.show('right'); } : undefined}
        onMarkedChat={id => { if (chat?.open(id)) { setChatMode('paper'); ws.show('right'); } }} reading={reading} />
      : library.state === 'loading' ? <div className="empty"><div className="spinner" aria-label="Loading" /></div>
        : <div className="empty"><p>This paper isn’t in your library.</p><button className="secondary" onClick={() => navigate('/')}>Back to library</button></div>;
  } else if (route === 'feed') {
    center = <FeedView model={feed} library={library} showChips={!railVisible} preparing={feedPreparing}
      onAdded={sourceID => { feedAdded.current.add(sourceID); }}
      onOpen={sourceID => { const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID); if (paper) void openPaper(paper); }}
      listen={{ selected: listening, select: setListening, view: <ListenView podcasts={podcasts} player={player} /> }} />;
  } else if (searchExternal) {
    center = <PaperSearchView search={paperSearch} library={library} preparing={feedPreparing} onAdded={sourceID => { feedAdded.current.add(sourceID); }}
      onOpen={sourceID => { const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID); if (paper) void openPaper(paper); }} />;
  } else {
    center = <LibraryView library={library} model={model} activity={activity} view={view} setView={setView} showChips={!railVisible} prepared={prepared}
      currentID={lastPaper} onOpen={openPaper} onAdd={() => setAdding(true)} />;
  }

  const nav = (to: string, label: string, icon: IconName, current: boolean, testID?: string) => (
    <a href={to} className={current ? 'nav-link on' : 'nav-link'} aria-current={current ? 'page' : undefined} data-testid={testID} title={label}
      onClick={e => { e.preventDefault(); navigate(to); }}><Icon name={icon} /><span className="nav-label">{label}</span></a>
  );

  return (
    <div className={`app${reading.on ? ' reading' : ''}`}>
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="topbar">
        <button className={`icon-button${ws.left.open ? ' on' : ''}`} onClick={() => ws.toggle('left')} aria-label="Side panel" aria-pressed={ws.left.open} title="Side panel ( [ )">
          <Icon name="sidebar" /></button>
        <a href="/" className="brand-link" onClick={e => { e.preventDefault(); navigate('/'); }}><Brand small /></a>
        <span className="environment" title="This browser reader uses the staging backend">{config.environment === 'production' ? '' : 'Beta'}</span>
        <nav className="topnav" aria-label="Main">
          {nav('/', 'Library', 'book', route === 'library', 'back-to-library')}
          {nav('/feed', 'Feed', 'feed', route === 'feed')}
          <button className="nav-link" onClick={() => setChats(true)} title="All chats"><Icon name="chats" /><span className="nav-label">Chats</span></button>
        </nav>
        <div className="search-field">
          <Icon name="search" size={14} />
          <input ref={search} type="search" placeholder={searchExternal ? 'Search ML papers' : 'Search library'} aria-label={searchExternal ? 'ML paper search' : 'Search library'}
            value={searchText} data-testid="search" enterKeyHint={searchExternal ? 'search' : undefined}
            onChange={e => { if (searchExternal) paperSearch.setQuery(e.target.value); else query(e.target.value); }}
            onFocus={() => setSearchFocus(true)} onBlur={leaveSearch}
            onKeyDown={e => {
              if (e.key === 'Enter' && searchExternal) { e.preventDefault(); if (route !== 'library') navigate('/'); paperSearch.run(); }
              if (e.key === 'Escape') {
                if (searchText) { e.preventDefault(); if (searchExternal) paperSearch.setQuery(''); else query(''); }
                else if (searchExternal) { e.preventDefault(); cancelSearch(); }
                else e.currentTarget.blur();
              }
              if (e.key === 'ArrowDown') { const first = document.querySelector<HTMLElement>('#main a.title, #main a.feed-title, .compact-list a'); if (first) { e.preventDefault(); first.focus(); } }
            }} />
          <kbd aria-hidden="true">/</kbd>
        </div>
        <div className="topbar-actions">
          <button className="primary small add-button" onClick={() => setAdding(true)} disabled={library.state !== 'ready'} data-testid="add-paper" title="Add paper">
            <Icon name="plus" size={14} /><span>Add paper</span></button>
          <button className="icon-button theme-toggle" onClick={() => setTheme(resolved === 'dark' ? 'light' : 'dark')} aria-label={resolved === 'dark' ? 'Use light appearance' : 'Use dark appearance'}
            title={resolved === 'dark' ? 'Light appearance' : 'Dark appearance'} data-testid="theme"><Icon name={resolved === 'dark' ? 'sun' : 'moon'} /></button>
          <button className={`icon-button chat-toggle${ws.right.open ? ' on' : ''}`} onClick={() => ws.toggle('right')} aria-label="Chat panel" aria-pressed={ws.right.open} title="Chat panel ( ] )">
            <Icon name="panelRight" /></button>
          <AccountMenu account={session.user.id} email={session.user.email} theme={theme} setTheme={setTheme} onHelp={() => setHelp(true)} onInfo={() => setHowGradstepWorks(true)} onReport={() => setReportOpen(true)} onReports={() => setReportsOpen(true)} onSignOut={() => setSigningOut(true)}
            onChatDefaults={chat ? () => setChatDefaults(true) : null} />
        </div>
      </header>
      {searching && <div className="search-scope" ref={scope} onFocus={() => setSearchFocus(true)} onBlur={leaveSearch} data-testid="search-scope">
        <span className="segmented" role="group" aria-label="Search">
          {([false, true] as const).map(external => <button key={String(external)} className={`segment${searchExternal === external ? ' on' : ''}`} aria-pressed={searchExternal === external}
            onMouseDown={e => e.preventDefault()} onClick={() => chooseScope(external)} data-testid={external ? 'search-scope-arxiv' : 'search-scope-library'}>
            {external ? 'ML paper search' : 'Library'}</button>)}
        </span>
        <button className="link small-link" onMouseDown={e => e.preventDefault()} onClick={cancelSearch} data-testid="search-cancel">Cancel</button>
      </div>}
      <StorageNotice />
      {navigationIssue && <div className="storage-notice" role="alert" data-testid="navigation-save-issue">
        <span>Some chat edits couldn’t be saved on this device. They’re still available in All chats. Keep this tab open.</span>
        <button className="secondary small" onClick={() => setChats(true)}>Review drafts</button>
        <button className="icon-button" aria-label="Dismiss save notice" onClick={() => setNavigationIssue(false)}><Icon name="close" size={16} /></button>
      </div>}
      {/* Each region fails on its own (RESILIENCE.md fix 2): a malformed answer, feed row or episode never blanks the page. */}
      <Workspace controls={ws} leftLabel={route === 'paper' ? 'Side panel' : route === 'feed' ? 'Feed topics' : 'Library filters'} rightLabel="Chat"
        left={<RegionBoundary region="side" label="The side panel" compact resetKey={route} onReport={report}>{left}</RegionBoundary>}
        center={<RegionBoundary region={route === 'paper' ? 'reader' : route === 'feed' ? (listening ? 'listen' : 'feed') : 'library'}
          label={route === 'paper' ? 'The reader' : route === 'feed' ? (listening ? 'Listen' : 'The feed') : 'The library'}
          resetKey={`${route}:${item ? paperIdentity(item) : ''}:${listening}`} onReport={report}>{center}</RegionBoundary>}
        right={<RegionBoundary region="chat" label="Chat" resetKey={paperContext?.documentID ?? chatMode} onReport={report}>
          <ChatPane chat={chat} paper={paperContext} mode={chatMode === 'paper' && paperContext ? 'paper' : 'general'} onMode={setChatMode} onAllChats={() => setChats(true)} onPassage={goToPassage} />
        </RegionBoundary>} />
      {item && <RegionBoundary region="paper-actions" label="Paper actions" compact onReport={report}><LibraryActionSurface actions={readerActions} /></RegionBoundary>}
      <RegionBoundary region="player" label="The player" compact onReport={report}><PodcastDock player={player} onEvidence={openPodcastEvidence} onAdd={addPodcastPaper} /></RegionBoundary>
      {devicePDFs.issue && <p role="status" className="library-action-notice">{devicePDFs.issue} <button onClick={devicePDFs.clearIssue}>Dismiss</button></p>}
      <RegionBoundary region="add-paper" label="Add paper" compact resetKey={adding} onReport={report}>
        <AddPaper localPDFs={devicePDFs} open={adding} onClose={() => setAdding(false)} library={library} account={account} keys={{ ring: ready.ring, deviceID: ready.deviceID }} />
      </RegionBoundary>
      <RegionBoundary region="chats" label="All chats" compact resetKey={chats} onReport={report}>
        <ChatHistory chat={chat} open={chats} onClose={() => setChats(false)} papers={paperNames} currentDocument={(item ? paperIdentity(item) : undefined) ?? null} onOpen={openChatDocument} />
      </RegionBoundary>
      {chat && <RegionBoundary region="chat-defaults" label="Chat defaults" compact resetKey={chatDefaults} onReport={report}><ChatDefaults chat={chat} open={chatDefaults} onClose={() => setChatDefaults(false)} /></RegionBoundary>}
      <ReportDialog open={reportOpen} onClose={() => setReportOpen(false)} account={account} onSent={() => { setReportOpen(false); setReportsOpen(true); }} />
      <ReportsDialog open={reportsOpen} onClose={() => setReportsOpen(false)} account={account} />
      <Dialog open={help} onClose={() => setHelp(false)} title="Keyboard shortcuts">
        <h2>Keyboard shortcuts</h2>
        <dl className="shortcuts">
          {SHORTCUTS.map(([k, d]) => <div key={k}><dt><kbd>{k}</kbd></dt><dd>{d}</dd></div>)}
        </dl>
        <p className="fine">On Windows and Linux, use Ctrl for ⌘.</p>
        <div className="dialog-actions"><button className="primary" onClick={() => setHelp(false)}>Done</button></div>
      </Dialog>
      <HowGradstepWorks open={howGradstepWorks} onClose={() => setHowGradstepWorks(false)} />
      <Dialog open={signingOut} onClose={() => { if (!leaving) setSigningOut(false); }} title="Sign out">
        <h2>Sign out?</h2>
        <p className="muted">This browser stays approved, so signing in again won’t need your recovery code.</p>
        {chat?.durable ? <p className="fine">Drafts and pending chat saves stay encrypted in this browser. Active answers stop and their committed partial text can be reopened after signing in.</p>
          : chat?.hasVolatileContent && <p className="issue">Unsent drafts and any changes that haven’t synced will be lost. Active answers will be stopped and their partial text saved when possible.</p>}
        {forget && chat?.durable && <p className="issue">Removing this browser’s keys also removes its drafts and pending chat saves. Work that hasn’t synced cannot be recovered with a recovery code.</p>}
        <label className="check"><input type="checkbox" checked={forget} disabled={leaving} onChange={e => setForget(e.target.checked)} data-testid="forget-device" />
          Also remove this browser’s keys, saved drafts and reading places (use on a shared computer)</label>
        {signOutError && <p className="issue" role="alert">{signOutError}</p>}
        <div className="dialog-actions">
          <button className="secondary" disabled={leaving} onClick={() => setSigningOut(false)}>Cancel</button>
          <button className="primary" disabled={leaving} onClick={() => void signOut()} data-testid="confirm-sign-out">{leaving ? 'Signing out…' : 'Sign out'}</button>
        </div>
      </Dialog>
    </div>
  );
}

function ChatDefaults({ chat, open, onClose }: { chat: ChatSession; open: boolean; onClose: () => void }) {
  useChatUpdates(chat);
  const [visualAnswers, setVisualAnswers] = useState(() => readVisualAnswers());
  return <ChatDefaultsDialog open={open} onClose={onClose} table={chat.profileTable} choice={chat.defaultProfile} onChange={next => chat.setDefaultProfile(next)} visualAnswers={visualAnswers} onVisualAnswers={on => { writeVisualAnswers(on); setVisualAnswers(on); }} onRetry={() => chat.reloadProfiles()} />;
}

function AccountMenu({ account, email, theme, setTheme, onHelp, onInfo, onReport, onReports, onSignOut, onChatDefaults }: { account: string; email: string | null; theme: Theme; setTheme: (t: Theme) => void; onHelp: () => void; onInfo: () => void; onReport: () => void; onReports: () => void; onSignOut: () => void;
  onChatDefaults: (() => void) | null }) {
  const [open, setOpen] = useState(false);
  const [roles, setRoles] = useState<string[]>([]);
  const box = useRef<HTMLDivElement>(null);
  // Operators (owner, support) get a link to the admin site; readers never see it.
  useEffect(() => {
    const abort = new AbortController(); setRoles([]);
    operatorRoles(account, abort.signal).then(setRoles, () => undefined);
    return () => abort.abort();
  }, [account]);
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false); };
    document.addEventListener('pointerdown', away); document.addEventListener('keydown', key);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', key); };
  }, [open]);
  return (
    <div className="account" ref={box}>
      <button className="icon-button account-button" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(o => !o)} data-testid="account-menu" title={email ?? 'Account'}>
        <Icon name="user" /><span className="account-email">{email ?? 'Account'}</span>
      </button>
      {open && (
        <div className="menu" role="menu">
          <p className="menu-email">{email}</p>
          <p className="fine">This browser is an approved device.</p>
          <div className="menu-row" role="group" aria-label="Appearance">
            {(['system', 'light', 'dark'] as const).map(t => <button key={t} role="menuitemradio" aria-checked={theme === t} className={theme === t ? 'seg on' : 'seg'} onClick={() => setTheme(t)}>
              {t === 'system' ? 'System' : t === 'light' ? 'Light' : 'Dark'}</button>)}
          </div>
          <button role="menuitem" className="menu-item" disabled={!onChatDefaults} onClick={() => { setOpen(false); onChatDefaults?.(); }} data-testid="chat-defaults"><Icon name="chat" size={14} /> Chat defaults…</button>
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onInfo(); }} data-testid="how-gradstep-works"><Icon name="info" size={14} /> How Gradstep works</button>
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onReport(); }} data-testid="report-issue"><Icon name="bug" size={14} /> Report this screen…</button>
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onReports(); }} data-testid="my-reports"><Icon name="bubble" size={14} /> My reports</button>
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onHelp(); }}><Icon name="keyboard" size={14} /> Keyboard shortcuts</button>
          {roles.length > 0 && <a role="menuitem" className="menu-item" href={operationsDashboard(roles)} target="_blank" rel="noreferrer" onClick={() => setOpen(false)} data-testid="operations-dashboard"><Icon name="external" size={14} /> Operations dashboard</a>}
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onSignOut(); }} data-testid="sign-out">Sign out…</button>
        </div>
      )}
    </div>
  );
}
