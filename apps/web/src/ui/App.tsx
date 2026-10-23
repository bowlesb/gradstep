import {parsePublicPaperLink,paperShareLinks} from '../lib/public-paper-link';
import {effectiveTags} from '../lib/paper';
import {useDevicePDFs} from './useDevicePDFs';
import type {ClientEntry, LibraryPaper} from '../lib/device-pdf';
import { localChatContext, observeArxivSources, prepareArxivReader } from '../lib/arxiv-reader';
import { sourceMetadataReporter } from '../lib/source-metadata';
import { type ReaderPaper, ReaderBundles, isLibraryPaper, isReaderPaper, isSourcePaper, paperIdentity, paperReference, readerCacheKey, readingSource } from '../lib/reader-paper';
import { type ComponentProps, type KeyboardEvent as ReactKeyboardEvent, type ReactNode, lazy, Suspense, useCallback, useEffect, useMemo, useReducer, useRef, useState, useSyncExternalStore } from 'react';
import { type Activity, ActivityStore, loadActivity, saveActivity } from '../lib/activity';
import { loadKept, saveKept } from '../lib/kept-explanations';
import { AuthError, type AuthIssue, type Session, auth, config, functionPost } from '../lib/backend';
import type { AnswerPapers } from './AnswerPapers';
import { type DeviceRecord, type Preparation, eraseDeletedAccount, forgetDevice, readDevice } from '../lib/keys';
import { TYPED_CONFIRMATION, deletionFailure, forgetAccountStorage, noteAccountDeleted, requestAccountDeletion } from '../lib/account-deletion';
import type { Item } from '../lib/library';
import type { Episode, Evidence } from '../lib/podcast';
import { clearPositions, evidenceAnchor } from '../lib/podcast-playback';
import { supportsX25519 } from '../lib/wire';
import type { FrameKey } from '../reader/frame';
import { ChatHistory, ChatPane, type PaperContext, summaryTitle, useChatUpdates } from './ChatPane';
import { ChatOptionsDialog, type ChatOptionsView } from './ChatProfile';
import { AI_USE_CASE_TITLES, aiDefaultsGuide, readVisualAnswers, writeVisualAnswers } from '../lib/chat-session';
import { prepareImageURL, type ChatFigureImage } from '../lib/chat-figures';
import type { ChatSession, Explanation, AIActivity } from '../lib/chat-session';
import { useChat } from './useChat';
import { actionFor, selectionPrompt, type SelectionAction } from '../lib/chat';
import type { TextAnchor } from '../lib/events';
import { Brand, Dialog, InfoTip, SheetTop } from './common';
import { DiagramsDialog } from './DiagramsDialog';
import { ExplanationsDialog } from './ExplanationsDialog';
import { AssetsExportDialog } from './AssetsExportDialog';
import { UsageDialog } from './UsageDialog';
import { FeedRail, FeedView, useFeed } from './Feed';
import { PaperSearchView, usePaperSearch } from './PaperSearch';
import { ScopeSwitch, SearchRail } from './SearchRail';
import { RAIL_CLOSED, carriedQuery, enterAction, escapeStep, libraryMatches, railReducer, restoreLeft } from '../lib/search-rail';
import type { Row } from '../lib/paper';
import { SettingsDialog, ShortcutList } from './Settings';
import { CatalogsDialog } from './Catalogs';
import { ListenView, PaperListen, PodcastDock, PodcastWriterDefault, usePodcasts, usePodcastPlayer } from './Podcast';
import type { MineRequest } from '../lib/podcast';
import { Icon, type IconName } from './icons';
import { KeySetup } from './Keys';
import { RegionBoundary } from './ErrorBoundary';
import { AddPaper, CompactLibrary, INITIAL_QUERY, libraryIsEmpty, type LibraryQuery, LibraryRail, LibraryView, useLibraryModel } from './Library';
import { LibraryActionSurface, PaperMenuButton, useLibraryActions } from './LibraryActions';
import { RecommendDialog, useRecommendations } from './Recommend';
import { readStored, type Route, type Theme, useMedia, useStored, useTheme, writeStored } from './prefs';
import { type ComposerDraft, NewNoteDialog, NoteComposer, NoteDetail, NotesList, useNotes } from './Notes';
import type { EntryView } from '../lib/notes';
/** Underline passages with chats (the apps' Settings › Reading; per browser, on unless turned off). */
const PASSAGE_MARKS_KEY = 'gradstep.reader.passageMarks';
/** The Library's status filter, remembered between visits (per browser, a convenience only). The tag isn't: every visit
 * starts with all tags, as the apps do (B3; owner: an old tag filter came back and the library looked empty). */
const LIBRARY_FILTER_KEY = 'gradstep.library.filter', OLD_LIBRARY_TAG_KEY = 'gradstep.library.tag';
import type { ReaderCache, ReaderCommands } from './Reader';
import type { EquationHost } from './EquationView';
import type { FigureHost } from './FigureView';
import type { PaperExplainerHost } from './PaperExplainer';
import { PaneHeader, Workspace, useWorkspace } from './Shell';
import { useReadingMode } from './ReadingMode';
import { SignIn } from './SignIn';
import { StorageNotice, storageGuidance } from './StorageNotice';
// Loaded when first needed (C5): the reader with its frame script, and dialogs opened from the account menu.
type ReaderModule = typeof import('./Reader');
let readerModule: ReaderModule | null = null;
const loadReader = () => import('./Reader').then(m => (readerModule = m));
const LazyReader = lazy(() => loadReader().then(m => ({ default: m.Reader })));
/** The reader, rendered directly once its chunk is here (fetched right after sign-in), so it mounts with the chat pane in
 * one commit; lazily before that. Chosen once per mount, so a reader never remounts when the chunk arrives. */
function Reader(props: ComponentProps<ReaderModule['Reader']>) {
  const [Chosen] = useState(() => readerModule?.Reader ?? LazyReader);
  return <Chosen {...props} />;
}
const ReportDialog = lazy(() => import('./SupportReports').then(m => ({ default: m.ReportDialog })));
const ReportsDialog = lazy(() => import('./SupportReports').then(m => ({ default: m.ReportsDialog })));
const HowGradstepWorks = lazy(() => import('./HowGradstepWorks').then(m => ({ default: m.HowGradstepWorks })));
const PrivacyData = lazy(() => import('./PrivacyData').then(m => ({ default: m.PrivacyData })));
import { useLibrary } from './useLibrary';
import { useCatalogs } from './useCatalogs';

type Ready = Extract<Preparation, { kind: 'ready' }>;

function usePath(): [string, (path: string) => void] {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => { const pop = () => setPath(location.pathname); addEventListener('popstate', pop); return () => removeEventListener('popstate', pop); }, []);
  const navigate = useCallback((next: string) => { if (next !== location.pathname) history.pushState(null, '', next); setPath(next); }, []);
  return [path, navigate];
}

export function App() {
  useEffect(()=>{if(parsePublicPaperLink(location.href))try{sessionStorage.setItem('gradstep.publicLink',location.href);}catch{}},[]);
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

const PLAIN_KEYS: Record<string, FrameKey> = { '/': 'search', '[': 'left', ']': 'right', '?': 'help', f: 'reading', j: 'next', k: 'previous' };

/** The activity the library views show: live while one is on screen, the last shown otherwise (C1). */
function useActivity(store: ActivityStore, live: boolean): Map<string, Activity> {
  const shown = useRef(store.snapshot());
  const snapshot = useCallback(() => (live ? (shown.current = store.snapshot()) : shown.current), [store, live]);
  return useSyncExternalStore(store.subscribe, snapshot);
}

function Signed({ session, ready }: { session: Session; ready: Ready }) {
  const account = session.user.id;
  // What this browser reads about a paper it prepares goes to the server only while it asks (ARXIV_DEVICE_ONLY.md §5.3).
  useEffect(() => observeArxivSources(sourceMetadataReporter(account)), [account]);
  const chat = useChat(account, ready);
  // The reader's chunk is fetched once the signed-in shell is on screen, off the first render's path, so opening a paper
  // mounts it at once: the reader and the chat's starter questions then share one arXiv request (C5).
  useEffect(() => { const t = setTimeout(() => { void loadReader().catch(() => {}); }, 0); return () => clearTimeout(t); }, []);
  const catalogs = useCatalogs(chat);
  const notes = useNotes(chat);
  // Add to note (a crop, a quote or text) and its "Saved to … · Open note" (NOTES_AND_SNIPPETS.md).
  const [composer, setComposer] = useState<{ draft: ComposerDraft; adjust?: () => void } | null>(null);
  const [savedNote, setSavedNote] = useState<{ noteID: string; title: string; offline: boolean } | null>(null);
  useEffect(() => { if (!savedNote) return; const t = setTimeout(() => setSavedNote(null), 8000); return () => clearTimeout(t); }, [savedNote]);
  const [newNote, setNewNote] = useState(false);
  // Phone widths use the apps' five destinations (Feed · Library · Paper · Chat · Notes) with Settings in the top-right ⋯.
  const phone = useMedia('(max-width: 640px)');
  const devicePDFs=useDevicePDFs(chat, catalogs);
  const library = useLibrary(account,devicePDFs,catalogs);
  // AI recommendations (AI_RECOMMENDATIONS.md): one request at a time for the page, outliving its dialog.
  const recommender = useRecommendations(account, library);
  // The reader has the same paper action surface as Library. Keeping a separate owner avoids
  // two portals competing when a library menu is still closing during navigation.
  // Its ⋯ also has Reader version details (READER_VERSIONS.md), for an arXiv paper the reader prepares.
  const readerCommands = useRef<ReaderCommands | null>(null);
  const readerActions = useLibraryActions(library, undefined, useMemo(() => [
    // The paper's AI Explainer (LEARNING_GUIDE.md, 2026-10-22): an arXiv paper this browser reads (its numbered text).
    { label: 'AI Explainer', testID: 'paper-explainer', applies: (paper: LibraryPaper) => isReaderPaper(paper) && !!readingSource(paper),
      run: () => readerCommands.current?.paperExplainer?.() },
    { label: 'Reader version details', testID: 'reader-version-details',
      applies: (paper: LibraryPaper) => isReaderPaper(paper) && !!readingSource(paper), run: () => readerCommands.current?.versionDetails?.() },
    // Notes: Paper ⋯ › Draw snippet (the always-available entry; NOTES_AND_SNIPPETS.md "Capture entry points"), after
    // the existing first item.
    { label: 'Draw snippet', testID: 'draw-snippet', applies: (paper: LibraryPaper) => isReaderPaper(paper), run: () => readerCommands.current?.drawSnippet?.() }], []),similar,recommender);
  const historyVersion = useSyncExternalStore(chat?.history.subscribe ?? (() => () => {}), chat?.history.getVersion ?? (() => 0));
  const [chatMode, setChatMode] = useState<'paper' | 'general'>('paper');
  const [orphanPaper, setOrphanPaper] = useState<PaperContext | null>(null);
  const [passage, setPassage] = useState<{ id: string; documentID: string; anchor: TextAnchor; at: number } | null>(null);
  // After a chat citation closed the chat drawer: the reader's Back to chat (ReaderModel.returnToChat), to the composer
  // that was showing (build 73, AHYZ: a promoted figure explainer's chat must come back as itself).
  const [chatReturn, setChatReturn] = useState<{ composer: string | null } | null>(null);
  const [path, moveTo] = usePath();
  const [navigationIssue, setNavigationIssue] = useState(false);
  const navigationIntent = useRef(0);
  const navigate = useCallback(async (next: string, arriving?: () => void): Promise<boolean> => {
    const intent = ++navigationIntent.current, owner = auth.snapshot();
    if (owner.signal.aborted) return false;
    // Capture and queue the draft now, but let its account-owned controller finish encryption/storage
    // after the route changes. Mounting another destination cannot retire that controller or lose the draft.
    const checkpoint = chat?.flushCheckpoints();
    arriving?.();
    moveTo(next);
    // Completion never navigates or installs a passage. Even an earlier navigation's failed save must
    // stay discoverable while this account is current. A successful drain checks every unsaved draft.
    void checkpoint?.then(() => {
      if (!owner.signal.aborted && navigationIntent.current === intent) setNavigationIssue(false);
    }, () => { if (!owner.signal.aborted) setNavigationIssue(true); });
    return true;
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
  // Reading activity lives outside React state (C1): while a paper is read, its place reports don't render the app.
  const [activityStore] = useState(() => new ActivityStore());
  const [activityLoaded, setActivityLoaded] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [forget, setForget] = useState(false);
  const [chats, setChats] = useState(false);
  // Settings (owner-approved 2026-10-22, audit S9) and its Library › Catalogs.
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [catalogsOpen, setCatalogsOpen] = useState(false);
  // Your assets › Download your assets (owner, build 82).
  const [assetsExportOpen, setAssetsExportOpen] = useState(false);
  const [howGradstepWorks, setHowGradstepWorks] = useState(false);
  const [privacy, setPrivacy] = useState(false);
  const [diagramsOpen, setDiagramsOpen] = useState(false);
  // Your assets › Equation explanations / Figure explanations, and the one a row reopens in its paper.
  const [explanationsOpen, setExplanationsOpen] = useState<Explanation['kind'] | null>(null);
  const [usageOpen, setUsageOpen] = useState(false);
  const [explainer, setExplainer] = useState<{ id: string; documentID: string; kind: Explanation['kind']; targetID: string; at: number } | null>(null);
  const [help, setHelp] = useState(false);
  const [reportOpen, setReportOpen] = useState(false);
  const report = useCallback(() => setReportOpen(true), []);
  const [reportsOpen, setReportsOpen] = useState(false);
  // AI chat options: closed, its Default options for new chats, or About AI chat options (Answer options' link, or the ⓘ).
  const [chatDefaults, setChatDefaults] = useState<false | ChatOptionsView>(false);
  const [adding, setAdding] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  // Delete account (owner, 2026-10-16), as the apps' Settings › Account › Delete account…
  const [deletingAccount, setDeletingAccount] = useState(false);
  const [deleteTyped, setDeleteTyped] = useState('');
  const [deleteBusy, setDeleteBusy] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const deleteField = useRef<HTMLInputElement>(null);
  // After a failure, focus returns to the field (it names the sentence), where Enter tries again.
  useEffect(() => { if (deleteError) deleteField.current?.focus(); }, [deleteError]);
  const [readerCache] = useState(() => new ReaderBundles());
  const readerCacheVersion = useSyncExternalStore(readerCache.subscribe, readerCache.getVersion);
  // Which papers this tab has prepared (the library row's check, PaperDeviceCopy).
  const prepared = useCallback((e: ClientEntry) => isReaderPaper(e) && readerCache.has(readerCacheKey(account, e)), [readerCache, account, readerCacheVersion]); // eslint-disable-line react-hooks/exhaustive-deps
  // A paper added from the Feed is prepared right away, as the apps do, so opening it doesn't download again. From Add
  // until it is ready the Feed shows the Library's spinner (owner, build 58), with the percent once preparation reports
  // one (sourceID → fraction, or null while the paper is still being added).
  const [feedPreparing, setFeedPreparing] = useState<Map<string, number | null>>(new Map());
  const feedAdded = useRef(new Map<string, number>()); // sourceID → when Add returned
  const settleFeedAdd = useCallback((sourceID: string) => {
    feedAdded.current.delete(sourceID);
    setFeedPreparing(m => { if (!m.has(sourceID)) return m; const next = new Map(m); next.delete(sourceID); return next; });
  }, []);
  const feedAdd = useCallback((sourceID: string) => {
    feedAdded.current.set(sourceID, Date.now()); setFeedPreparing(m => new Map(m).set(sourceID, null));
    // A paper that never becomes readable here (still adding after two minutes) stops spinning; its row says why.
    setTimeout(() => setFeedPreparing(m => { if (m.get(sourceID) !== null) return m; feedAdded.current.delete(sourceID); const next = new Map(m); next.delete(sourceID); return next; }), 120_000);
  }, []);
  const preparationScope = useRef(new AbortController());
  useEffect(() => () => preparationScope.current.abort(), []);
  useEffect(() => {
    for (const sourceID of [...feedAdded.current.keys()]) {
      const entries = library.entries.filter(e => e.visible && e.source_id === sourceID);
      // The paper the reader will open (a source paper, or an arXiv item read from its official HTML).
      const paper = entries.find((e): e is ReaderPaper => isReaderPaper(e) && !!readingSource(e));
      if (!paper) {
        // Settled without anything to prepare here: the add failed or was cancelled, or the paper reads another way.
        if (entries.some(e => e.kind === 'import' ? ['failed', 'cancelled', 'membership_conflict'].includes(e.phase) : !(isReaderPaper(e) && readingSource(e)))) settleFeedAdd(sourceID);
        continue;
      }
      feedAdded.current.delete(sourceID);
      const key = readerCacheKey(account, paper);
      if (readerCache.has(key)) { settleFeedAdd(sourceID); continue; }
      const progress = (fraction: number) => setFeedPreparing(m => new Map(m).set(sourceID, fraction));
      progress(0);
      void prepareArxivReader(readingSource(paper)!, preparationScope.current.signal, progress, { authors: paper.metadata?.authors ?? [], title: paper.metadata?.title })
        .then(bundle => { readerCache.set(key, bundle); while (readerCache.size > 3) readerCache.delete(readerCache.keys().next().value!); })
        .catch(() => { /* opening the paper prepares it again and says why if it can't */ })
        .finally(() => settleFeedAdd(sourceID));
    }
  }, [library.entries, account, readerCache, settleFeedAdd]);
  useEffect(()=>{
    if(!chat)return;
    chat.setSourcePapers(new Map(library.entries.filter(isSourcePaper).map(paper=>[paper.id,{reference:paperReference(paper)!,load:async()=>{
      const key=readerCacheKey(account,paper),saved=readerCache.get(key);if(saved)return saved;
      const bundle=await prepareArxivReader(paperReference(paper)!,chat.signal,undefined,{authors:paper.metadata?.authors??[],title:paper.metadata?.title});chat.signal.throwIfAborted();
      readerCache.set(key,bundle);while(readerCache.size>3)readerCache.delete(readerCache.keys().next().value!);return bundle;
    }}])));
    // arXiv papers from before the HTML-first reader: their chats keep the document id, their questions send this
    // device's text (the server's copy is gone).
    chat.setLegacyPapers(new Map(library.entries.filter((e):e is Item=>e.kind==='item'&&e.visible&&!!readingSource(e)).map(paper=>[paper.document_id,{reference:readingSource(paper)!,load:async()=>{
      const key=readerCacheKey(account,paper),saved=readerCache.get(key);if(saved)return saved;
      const bundle=await prepareArxivReader(readingSource(paper)!,chat.signal,undefined,{authors:paper.metadata?.authors??[],title:paper.metadata?.title});chat.signal.throwIfAborted();
      readerCache.set(key,bundle);while(readerCache.size>3)readerCache.delete(readerCache.keys().next().value!);return bundle;
    }}])));
  },[chat,library.entries,readerCache,account]);
  useEffect(()=>{if(chat&&library.state==='ready')chat.retainPromotedContexts(new Set(library.entries.filter((p):p is ReaderPaper=>isReaderPaper(p)&&p.visible).map(paperIdentity)));},[chat,library.state,library.entries]);
  // Library search, filters and sort survive opening a paper and coming back (UX_PARITY.md); the filter is remembered
  // between visits too (owner-approved follow-up, 2026-10-07). The tag is not, as on the apps since build 71 ("I open to
  // this screen": an empty tag view after relaunch); a tag an earlier build stored is forgotten (B3).
  const [view, setViewState] = useState<LibraryQuery>(() => {
    try { localStorage.removeItem(OLD_LIBRARY_TAG_KEY); } catch { /* storage unavailable */ }
    return { ...INITIAL_QUERY, filter: readStored<LibraryQuery['filter']>(LIBRARY_FILTER_KEY, 'all', v => typeof v === 'string' && ['all', 'unread', 'reading', 'failed', 'archived'].includes(v)) };
  });
  const setView = useCallback((next: LibraryQuery | ((q: LibraryQuery) => LibraryQuery)) => setViewState(previous => {
    const value = typeof next === 'function' ? next(previous) : next;
    if (value.filter !== previous.filter) writeStored(LIBRARY_FILTER_KEY, value.filter);
    return value;
  }), []);
  const clearTag = useCallback(() => setView(q => q.tag ? { ...q, tag: '' } : q), [setView]);
  const [railTab, setRailTab] = useState<'contents' | 'library'>('contents');
  const [contentsSlot, setContentsSlot] = useState<HTMLElement | null>(null);
  const [lastPaper, setLastPaper] = useState<string | null>(null);
  const { theme, resolved, setTheme } = useTheme();
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const search = useRef<HTMLInputElement>(null);
  // ML paper search (PaperSearch.tsx): in the left panel's search list beside the reading view (SearchRail.tsx), or on the
  // Library route in place of its table.
  const paperSearch = usePaperSearch(account);
  // Search beside the reading view (owner, 2026-10-22: "the search bar should probably be on the left … in the same area as
  // the list of articles would be"; lib/search-rail.ts): a mode of the left panel off the Library route, like Mail.
  const [rail, dispatchRail] = useReducer(railReducer, RAIL_CLOSED);
  const [railText, setRailText] = useState('');
  const railField = useRef<HTMLInputElement>(null);
  // The Library route's own search: its words filter the table; ML papers takes the table's place (as before, with the
  // switch in the Library's title row, never a row that pushes the page down).
  const [libraryML, setLibraryML] = useState(false);
  // Every way into ML paper search (find similar, an author, a keyword, a public link) answers where the reader is, and
  // starts without a library tag filter (owner, build 75: "I wonder if a search was not escaped").
  function searchPapers(text: string) {
    clearTag(); paperSearch.setQuery(text); paperSearch.run();
    if (route === 'library') setLibraryML(true); else openRailSearch(true);
  }
  // A keyword's "Show library papers tagged": the library with that tag and nothing else in the way.
  function showTagged(tag: string) {
    setLibraryML(false); search.current?.blur(); paperSearch.clear();
    setView(q => ({ ...q, query: '', filter: 'all', tag })); navigate('/');
  }
  function similar(paper:LibraryPaper) {
    const tags=effectiveTags(paper).slice(0,3); searchPapers(tags.length?tags.join(' '):paper.metadata?.title??'');
  }
  const openReader = useCallback((paper: ReaderPaper, anchor?: TextAnchor) => navigate(`/paper/${paper.id}`, () => {
    setLastPaper(paper.id);
    setPassage(anchor ? { id: crypto.randomUUID(), documentID: paperIdentity(paper), anchor, at: Date.now() } : null);
  }), [navigate]);

  const publicLinkHandled=useRef(false);
  useEffect(()=>{
    if(publicLinkHandled.current||library.state!=='ready')return;
    let raw=location.href;try{raw=sessionStorage.getItem('gradstep.publicLink')??raw;}catch{}
    const link=parsePublicPaperLink(raw);if(!link)return;publicLinkHandled.current=true;
    try{sessionStorage.removeItem('gradstep.publicLink');}catch{}
    const installed=library.entries.find((p):p is ReaderPaper=>isReaderPaper(p)&&p.visible&&parsePublicPaperLink(paperShareLinks(p).gradstep??'')?.identity===link.identity);
    if(installed)openReader(installed);else searchPapers(link.identity);
  },[library.state,library.entries,openReader,paperSearch,navigate]);
  useEffect(() => {
    let live = true;
    setActivityLoaded(false);
    readDevice(account).then(async record => {
      if (!record || record.deviceID !== ready.deviceID) return;
      const saved = await loadActivity(record);
      if (!live) return;
      setDevice(record); activityStore.replace(saved);
    }).catch(() => {}).finally(() => { if (live) setActivityLoaded(true); });
    return () => { live = false; if (saveTimer.current) clearTimeout(saveTimer.current); readerCache.clear(); };
  }, [account, ready.deviceID]);

  const openPaper = useCallback((paper:LibraryPaper,anchor?:TextAnchor) => {
    if(paper.kind==='local_pdf'){devicePDFs.open(paper);return Promise.resolve(true);}
    return openReader(paper,anchor);
  },[devicePDFs,openReader]);
  const record = useCallback((itemID: string, value: Activity) => {
    if (!activityLoaded || leaving) return;
    activityStore.set(itemID, value);
  }, [activityLoaded, leaving, activityStore]);

  // Kept explanations (B4): restored once the device's key and the chat are here; each new one saved (encrypted, here).
  useEffect(() => {
    if (!chat || !device || !ready.local || leaving) return;
    const local = ready.local;
    let live = true, timer: ReturnType<typeof setTimeout> | undefined;
    void loadKept(device).then(entries => { if (live && entries.length) chat.restoreKept(entries); });
    const unsubscribe = chat.onKept(() => { clearTimeout(timer); timer = setTimeout(() => { void saveKept(device, chat.keptEntries(), local).catch(() => {}); }, 300); });
    return () => { live = false; unsubscribe(); clearTimeout(timer); };
  }, [chat, device, leaving, ready.local]);
  // Saved half a second after the last change (encrypted, on this device), without rendering anything.
  useEffect(() => {
    if (!device || !ready.local || leaving) return;
    const local = ready.local;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const changed = () => {
      clearTimeout(timer);
      timer = setTimeout(() => { saveActivity(device, activityStore.snapshot(), local).catch(() => {}); }, 500);
      saveTimer.current = timer;
    };
    const unsubscribe = activityStore.subscribe(changed);
    return () => { unsubscribe(); clearTimeout(timer); };
  }, [device, leaving, ready.local, activityStore]);

  const readSaved = useCallback((itemID: string) => activityStore.get(itemID), [activityStore]);
  const match = /^\/paper\/([0-9a-f-]{36})$/.exec(path);
  const paperID = match?.[1] ?? null;
  const notesMatch = /^\/notes(?:\/([0-9a-f-]{36}))?$/.exec(path);
  const noteID = notesMatch?.[1] ?? null;
  const route: Route = paperID ? 'paper' : path === '/feed' ? 'feed' : notesMatch ? 'notes' : 'library';
  const item = paperID ? library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.id === paperID && e.visible) : undefined;
  useEffect(() => { if (path !== '/' && path !== '/feed' && !match && !notesMatch) navigate('/'); }, [path, match, notesMatch, navigate]);
  useEffect(() => { if (paperID) setLastPaper(paperID); setOrphanPaper(null); setChatMode(paperID ? 'paper' : 'general'); }, [paperID]);
  useEffect(() => { setLibraryML(false); setSettingsOpen(false); }, [route, paperID]);

  const ws = useWorkspace(route);
  // Back to chat goes away once the chat is open again or the paper is left.
  useEffect(() => { if (ws.right.open || route !== 'paper') setChatReturn(null); }, [ws.right.open, route]);
  const reading = useReadingMode(ws, route === 'paper' && !!item);
  // Opening search: the Library's own field there; elsewhere the left panel's search list, the panel opening if it was
  // closed (a drawer on narrow windows). What the panel showed comes back when search ends (reader audit R2).
  const openRailSearch = (ml?: boolean) => {
    dispatchRail({ type: 'open', route, leftOpen: ws.left.open, ml });
    if (!ws.left.open) ws.show('left');
    requestAnimationFrame(() => requestAnimationFrame(() => { railField.current?.focus(); railField.current?.select(); }));
  };
  const closeRailSearch = () => {
    const back = restoreLeft(rail, route, ws.left.inline);
    dispatchRail({ type: 'close' }); setRailText(''); paperSearch.clear();
    if (back !== null && back !== ws.left.open) ws.show('left', back);
  };
  const enterSearch = () => {
    if (route === 'library') { search.current?.focus(); search.current?.select(); } else openRailSearch();
  };
  // The list stays beside the paper it opened; on another route the panel opens for it, and the Library ends it (its
  // table is its list). Closing the panel itself ([, its edge) ends search too.
  const railRoute = useRef(route);
  useEffect(() => {
    const moved = railRoute.current !== route; railRoute.current = route;
    if (!rail.open) return;
    if (route === 'library') { dispatchRail({ type: 'route', route }); setRailText(''); return; }
    if (!ws.left.open) { if (moved) ws.show('left'); else dispatchRail({ type: 'close' }); }
  }, [rail.open, route, ws.left.open]); // eslint-disable-line react-hooks/exhaustive-deps
  const latest = useRef({ ws, route, paperID, reading, enterSearch });
  latest.current = { ws, route, paperID, reading, enterSearch };
  const libraryShown = route !== 'paper' || (railTab === 'library' && ws.left.open);
  const activity = useActivity(activityStore, libraryShown);
  const model = useLibraryModel(library, activity, view, libraryShown);
  const feed = useFeed(account, library.serverEntries);
  const podcasts = usePodcasts(account);
  const player = usePodcastPlayer(account);
  const [listening, setListening] = useState(false);
  // Try again from Listen: the paper opens with its Listen at the length that couldn't be made.
  const [listenAgain, setListenAgain] = useState<{ itemID: string; profile: string | null } | null>(null);
  const tryAgain = useCallback((request: MineRequest) => {
    const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && (e.id === request.documentID || e.document_id === request.documentID));
    if (!paper) return false;
    setListenAgain({ itemID: paper.id, profile: request.profile });
    void openPaper(paper);
    return true;
  }, [library.entries, openPaper]);

  const shortcut = useCallback((key: FrameKey) => {
    const { ws, route, reading } = latest.current;
    switch (key) {
      case 'reading': if (route === 'paper') reading.toggle(); break;
      case 'next': if (route === 'paper') readerCommands.current?.section?.(1); break;
      case 'previous': if (route === 'paper') readerCommands.current?.section?.(-1); break;
      case 'search': {
        const go = () => latest.current.enterSearch();
        // Reading mode hides the top bar: leave it first, then focus once the bar is back (the paper's frame, which held
        // the keyboard, may take focus back while it settles).
        if (reading.on) {
          reading.exit(); requestAnimationFrame(go);
          setTimeout(() => { if (document.activeElement !== search.current && document.activeElement !== railField.current) go(); }, 120);
        } else go();
        break;
      }
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
      else if (device && ready.local) await saveActivity(device, activityStore.snapshot(), ready.local).catch(() => {});
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

  /** The server deletes the account first; a failure changes nothing here. Only once it is deleted does this browser
   * forget everything it held for the account (the "remove this browser's keys" sign-out, plus the account's own
   * coordination record and stored keys), then sign out to the sign-in screen, which confirms it. */
  async function deleteAccount() {
    if (deleteBusy || deleteTyped !== TYPED_CONFIRMATION) return;
    const owner = auth.snapshot();
    setDeleteBusy(true); setDeleteError(null);
    try { await requestAccountDeletion(account); }
    catch (error) { if (!owner.signal.aborted) { setDeleteError(deletionFailure(error)); setDeleteBusy(false); } return; }
    if (saveTimer.current) clearTimeout(saveTimer.current);
    // The account no longer exists: each local removal is best effort, and signing out always follows.
    await chat?.settleBeforeSignOut().catch(() => {});
    await eraseDeletedAccount(account).catch(() => {});
    clearPositions(account);
    try { forgetAccountStorage(account, localStorage); forgetAccountStorage(account, sessionStorage); } catch { /* storage unavailable */ }
    noteAccountDeleted();
    ++navigationIntent.current;
    moveTo('/');
    await auth.signOut(owner.generation);
  }

  // The left panel's list: library matches (best first) for its words, or ML papers.
  const railMatches = useMemo(() => {
    if (!rail.open || rail.ml || !railText.trim()) return { shown: [] as Row[], total: 0 };
    const found = libraryMatches(model.all.filter(r => r.readable && isLibraryPaper(r.entry)).map(row => ({ row, title: row.title, authors: row.entry.metadata?.authors ?? [],
      tags: row.tags, source: row.source, venue: row.entry.metadata?.venue ?? null, added: row.added, archived: row.archived })), railText);
    return { shown: found.shown.map(m => m.row), total: found.total };
  }, [rail.open, rail.ml, railText, model.all]);
  // A result opens in the middle; beside it the list stays (the paper highlighted), over it (a drawer) search ends.
  const openFromRail = (paper: LibraryPaper) => {
    const inline = ws.left.inline;
    dispatchRail({ type: 'opened', inline });
    if (!inline) { setRailText(''); paperSearch.clear(); ws.show('left', false); }
    void openPaper(paper);
  };
  const openRailSource = (sourceID: string) => {
    const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID);
    if (paper) openFromRail(paper);
  };
  const railML = () => {
    const words = carriedQuery(railText, paperSearch.query);
    paperSearch.setQuery(words); if (words.trim()) paperSearch.run();
    dispatchRail({ type: 'ml' }); railField.current?.focus();
  };
  const railLibrary = () => { setRailText(carriedQuery(paperSearch.query, railText)); dispatchRail({ type: 'library' }); railField.current?.focus(); };
  const railKey = (e: ReactKeyboardEvent<HTMLInputElement>) => {
    const text = rail.ml ? paperSearch.query : railText;
    if (e.key === 'Enter') {
      const action = enterAction({ ml: rail.ml, query: text, matches: railMatches.total });
      if (!action) return;
      e.preventDefault();
      if (action === 'run-ml') paperSearch.run();
      else if (action === 'search-ml') railML();
      else { const first = railMatches.shown[0]; if (first && isLibraryPaper(first.entry)) openFromRail(first.entry); }
    } else if (e.key === 'Escape') {
      // Esc clears the words, then a second Esc ends search; the panel goes back to what it showed.
      e.preventDefault(); e.stopPropagation();
      if (escapeStep(text) === 'clear') { if (rail.ml) paperSearch.clear(); else setRailText(''); } else closeRailSearch();
    } else if (e.key === 'ArrowDown') {
      const first = document.querySelector<HTMLElement>('.search-rail-body button.search-rail-open');
      if (first) { e.preventDefault(); first.focus(); }
    }
  };
  // The Library route's field: its words filter the table live; ML papers takes the table's place.
  const libraryField = libraryML ? paperSearch.query : view.query;
  const searching = route === 'library' && (libraryML || !!view.query.trim());
  const toLibraryML = () => {
    paperSearch.setQuery(carriedQuery(view.query, paperSearch.query)); if (paperSearch.query.trim() || view.query.trim()) paperSearch.run();
    setLibraryML(true); setView(q => ({ ...q, query: '' })); search.current?.focus();
  };
  const toLibraryTable = () => { setView(q => ({ ...q, query: carriedQuery(paperSearch.query, q.query) })); setLibraryML(false); search.current?.focus(); };
  const cancelLibrarySearch = () => { setLibraryML(false); paperSearch.clear(); setView(q => ({ ...q, query: '', tag: '' })); search.current?.blur(); };
  const searchKey = (e: ReactKeyboardEvent<HTMLInputElement>) => {
    if (route !== 'library') return;
    if (e.key === 'Enter' && libraryML) { e.preventDefault(); paperSearch.run(); }
    else if (e.key === 'Escape') {
      // Clearing the Library's words is its Cancel: the tag filter ends with them (build 75, AOog); then ML papers ends.
      if (libraryField) { e.preventDefault(); if (libraryML) paperSearch.clear(); else setView(q => ({ ...q, query: '', tag: '' })); }
      else if (libraryML) { e.preventDefault(); cancelLibrarySearch(); }
      else e.currentTarget.blur();
    } else if (e.key === 'ArrowDown' && !libraryML) {
      const first = document.querySelector<HTMLElement>('#main a.title');
      if (first) { e.preventDefault(); first.focus(); }
    }
  };
  const scopeSwitch = <ScopeSwitch ml={libraryML} onLibrary={toLibraryTable} onML={toLibraryML} onCancel={cancelLibrarySearch} />;
  const onContents = () => {
    if (ws.left.open && railTab === 'contents') ws.show('left', false);
    else { setRailTab('contents'); ws.show('left'); }
  };
  const railVisible = ws.left.open && ws.left.inline;
  const paperContext = orphanPaper ?? (item ? { documentID: paperIdentity(item), title: item.metadata?.title ?? 'Paper', available: isSourcePaper(item) || !!readingSource(item) || (item.readiness === 'converted_ready' && item.render_availability === 'available') } : null);
  // Saved chats per paper for the library's Chats column (B9): one pass over the cached summaries per history change.
  const chatCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const c of chat?.history.state.conversationSummaries() ?? []) if (c.documentID) counts.set(c.documentID, (counts.get(c.documentID) ?? 0) + 1);
    return counts;
  }, [chat, historyVersion]); // eslint-disable-line react-hooks/exhaustive-deps
  // The account's sync state with Sync now (RootView's Account › Sync; B10): paused, syncing, waiting, synced.
  const syncState = chat ? {
    label: chat.history.issue ? 'Sync paused' : chat.history.syncing ? 'Syncing…' : chat.history.unsaved
      ? `${chat.history.unsaved.toLocaleString()} ${chat.history.unsaved === 1 ? 'change' : 'changes'} waiting to sync` : chat.history.status === 'ready' ? 'Synced' : 'Not synced yet',
    detail: chat.history.issue, canSync: !chat.history.syncing && (!!chat.history.issue || chat.history.unsaved > 0 || chat.history.status !== 'ready'),
    run: () => { void chat.history.sync().catch(() => {}); },
  } : null;
  const paperTopics = useMemo(() => new Map(library.entries.filter((e): e is ReaderPaper => isReaderPaper(e) && e.visible).map(e => [paperIdentity(e), effectiveTags(e)])), [library.entries]);
  const chatCount = useCallback((entry: ClientEntry) => chatCounts.get(isReaderPaper(entry) ? paperIdentity(entry) : entry.id) ?? 0, [chatCounts]);
  const paperNames = useMemo(() => new Map(library.entries.filter((e): e is ReaderPaper => isReaderPaper(e) && e.visible).map(e => [paperIdentity(e), e.metadata?.title ?? 'Paper'])), [library.entries]);
  // Papers an answer names (B2): in the library already (a paper or a visible import), opened or shown there; else added
  // as the Add paper dialog adds an arXiv ID, or a DOI through the reader's free reference lookup.
  const answerPapers = useMemo<AnswerPapers>(() => ({
    has: sourceID => library.entries.some(e => e.visible && e.source_id === sourceID),
    title: sourceID => library.entries.find(e => e.visible && e.source_id === sourceID)?.metadata?.title ?? null,
    open: sourceID => {
      const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID);
      if (paper && (isSourcePaper(paper) || readingSource(paper))) { void openPaper(paper); return; }
      setLibraryML(false); setView({ ...INITIAL_QUERY, query: sourceID }); void navigate('/');
    },
    addArxiv: (sourceID, revision) => library.addArxiv(sourceID, revision),
    addReference: (doi, operationID) => functionPost('add-reference', { operation_id: operationID, reference: doi, capabilities: ['web_import'] }, { account, maximum: 65_536 }),
  }), [library, openPaper, navigate, setView, account]);
  const openChatDocument = async (documentID: string | null, anchor?: TextAnchor) => {
    setSettingsOpen(false);
    const showing = anchor && documentID && chat ? chat.current(documentID).id : null;
    if (!documentID) setChatMode('general');
    else {
      const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && paperIdentity(e) === documentID);
      if (paper) { if (!await openPaper(paper, anchor)) return; setOrphanPaper(null); }
      else setOrphanPaper({ documentID, title: 'Paper no longer in library', available: false });
      setChatMode('paper');
    }
    // A citation from a chat that covers the paper (a drawer: phone, narrow window) closes it so the passage shows, and
    // the reader offers Back to chat (PaperView's reader.chat.back); beside the paper, the chat stays open.
    if (anchor && !latest.current.ws.right.inline) { latest.current.ws.show('right', false); setChatReturn({ composer: showing }); }
    else latest.current.ws.show('right');
  };
  const goToPassage = (documentID: string, anchor: TextAnchor) => {
    void openChatDocument(documentID, anchor);
  };
  // A note entry's Open in paper: the same paper in this library (its membership, else the same arXiv source and
  // revision), at the captured blocks when this copy is the one it was captured from. Never a guessed match.
  const openSource = (entry: EntryView): string | null => {
    const s = entry.record.source;
    if (!s) return 'This entry isn’t from a paper.';
    const papers = library.entries.filter((e): e is ReaderPaper => isReaderPaper(e) && e.visible);
    const paper = papers.find(e => !!s.membershipID && e.id === s.membershipID)
      ?? papers.find(e => s.kind === 'arxiv' && !!s.sourceID && e.source_id === s.sourceID && (!s.revision || e.source_revision === s.revision));
    if (!paper) {
      const other = s.kind === 'arxiv' && s.sourceID ? papers.find(e => e.source_id === s.sourceID) : undefined;
      if (other) { void openReader(other); return null; } // another revision: opened without claiming the captured place
      return s.kind === 'arxiv' && s.sourceID ? `This paper isn’t in your library here. Add arXiv ${s.sourceID}${s.revision ? `v${s.revision}` : ''} to open it.` : 'This paper isn’t on this device.';
    }
    const a = entry.record.anchor, block = a?.blockIDs[0];
    void openReader(paper, a?.manifestSHA256 && (block || entry.record.quote) ? { manifestSHA256: a.manifestSHA256, quote: entry.record.quote ?? '', prefix: '', suffix: '', elementID: block } : undefined);
    return null;
  };
  // A snippet's or quotation's Chat (owner, 2026-10-21: "a Chat option to launch and talk about the snippet";
  // NOTES_AND_SNIPPETS.md "Chat about a snippet"): a new chat, nothing sent, as Chat about Figure. A paper readable here:
  // its chat, with the drawn crop attached to every question as a named figure's image is (consent v3+, paper chats only)
  // and its source as the passage; a quotation is the passage itself. Otherwise a general chat with the source line as
  // context (the server takes images only in a paper's chat). The comment is the draft; Back to note returns.
  const chatAboutEntry = async (entry: EntryView) => {
    if (!chat || chat.storageRetired || !notes) return;
    const r = entry.record, s = r.source;
    if (r.kind === 'text') return;
    const papers = library.entries.filter((e): e is ReaderPaper => isReaderPaper(e) && e.visible);
    const paper = s ? papers.find(e => !!s.membershipID && e.id === s.membershipID)
      ?? papers.find(e => s.kind === 'arxiv' && !!s.sourceID && e.source_id === s.sourceID && (!s.revision || e.source_revision === s.revision)) : undefined;
    const documentID = paper && chat.readsPaper(paperIdentity(paper)) ? paperIdentity(paper) : null;
    const place = [s?.label ?? s?.section, s?.page ? `page ${s.page}` : null].filter(Boolean).join(', ');
    const title = s ? `“${s.title || 'Untitled paper'}”${place ? ` (${place})` : ''}` : 'a paper';
    const label = r.kind === 'region' ? `Snippet · ${s?.label ?? s?.section ?? s?.title ?? 'Snippets'}` : `Quote · ${s?.title || 'Snippets'}`;
    const block = r.anchor?.blockIDs[0];
    const paragraph = documentID ? await chat.noteParagraph(documentID, r.anchor?.manifestSHA256 ?? null, block) : null;
    let image: string | undefined, attachment: ChatFigureImage | undefined;
    if (r.kind === 'region' && r.media) {
      const prepared = await notes.image(r.media.full).then(prepareImageURL).catch(() => null);
      if (prepared) {
        image = `data:image/jpeg;base64,${prepared.data}`;
        // F3: the paper's own named figures take F1 and F2 (chatFigureImages, at most two).
        if (documentID) attachment = { id: 'F3', paragraph: paragraph ?? 1, caption: `A snippet the reader drew from ${title}`, mediaType: 'image/jpeg', data: prepared.data,
          width: prepared.width, height: prepared.height, blockID: '', assetPath: '', assetPaths: [] };
      }
    }
    const quote = [...(r.kind === 'quote' ? r.quote ?? '' : `A snippet the reader drew from ${title}${paragraph ? ` [¶${paragraph}]` : ''}.`
      + (attachment ? ' Its image is attached.' : ' Only its source is known here; the image stays on the reader’s device.'))].slice(0, 4000).join('');
    const anchor = documentID && r.anchor?.manifestSHA256 && block && (r.anchor.quote ?? r.quote)
      ? { manifestSHA256: r.anchor.manifestSHA256, quote: (r.anchor.quote ?? r.quote)!, prefix: '', suffix: '', elementID: block } : undefined;
    const visible = chat.current(chatMode === 'paper' && paperContext ? paperContext.documentID : null);
    const composer = chat.newChat(documentID, chat.profileFor(visible));
    chat.promoteContextual(composer, { label, quote, anchor, image, attachment, noteReturn: { noteID: r.noteID, entryID: entry.id }, imageSent: !!attachment });
    if (r.comment) chat.edit(composer, r.comment);
    if (documentID && paper) { if (!await openPaper(paper)) return; setChatMode('paper'); } else setChatMode('general');
    latest.current.ws.show('right');
    requestAnimationFrame(() => requestAnimationFrame(() => document.querySelector<HTMLTextAreaElement>(`textarea[data-composer-id="${composer.id}"]`)?.focus()));
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
    context: { chat, documentID: equationDocument, title: item?.metadata?.title ?? "Paper", onPromote:()=>{setChatMode('paper');latest.current.ws.show('right');} },
    consented: () => chat.cloudConsent, accept: () => chat.acceptCloudConsent(),
    saved: (manifest, equationID, action, choice) => chat.savedEquation(manifest, equationID, action, choice),
    run: (input, action, update, signal, choice) => chat.equation(equationDocument, input, action, update, signal, choice),
  } : undefined, [chat, equationDocument]);
  // The figure view's requests, the same way (FIGURE_VIEW.md).
  const figureHost = useMemo<FigureHost | undefined>(() => chat && equationDocument ? {
    context: { chat, documentID: equationDocument, title: item?.metadata?.title ?? "Paper", onPromote:()=>{setChatMode('paper');latest.current.ws.show('right');} },
    consented: () => chat.cloudConsent, accept: () => chat.acceptCloudConsent(),
    saved: (manifest, figureID, action, part, choice) => chat.savedFigure(manifest, figureID, action, part, choice),
    run: (input, action, update, signal, choice) => chat.figure(equationDocument, input, action, update, signal, choice),
    image: figureID => chat.keptFigureImage(equationDocument, figureID),
  } : undefined, [chat, equationDocument]);
  // The paper's AI Explainer's requests, the same way (LEARNING_GUIDE.md "Paper AI Explainer").
  const paperExplainerHost = useMemo<PaperExplainerHost | undefined>(() => chat && equationDocument ? {
    context: { chat, documentID: equationDocument, title: item?.metadata?.title ?? "Paper", onPromote:()=>{setChatMode('paper');latest.current.ws.show('right');} },
    consented: () => chat.cloudConsent, accept: () => chat.acceptCloudConsent(),
    saved: (manifest, choice) => chat.savedPaperExplainer(manifest, choice),
    run: (update, signal, choice) => chat.paperExplainer(equationDocument, update, signal, choice),
  } : undefined, [chat, equationDocument]);
  // Passages with chats are underlined unless the reader turned that off (Settings › Reading on the apps; B10).
  const [passageMarks, setPassageMarks] = useStored<boolean>(PASSAGE_MARKS_KEY, true, v => typeof v === 'boolean');
  const marks = useMemo(() => !passageMarks ? [] : chat?.history.state.conversationSummaries().filter(c => c.documentID === (item ? paperIdentity(item) : undefined) && c.anchor)
    .map(c => ({ id: c.id, anchor: c.anchor!, title: summaryTitle(c) || undefined, lastUsedAt: c.lastUsedAt })) ?? [], [chat, historyVersion, (item ? paperIdentity(item) : undefined), passageMarks]);

  const openPodcastEvidence = async (episode: Episode, evidence: Evidence): Promise<boolean | null> => {
    const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && paperIdentity(e) === episode.documentID);
    if (!paper) return false;
    return await openPaper(paper, evidenceAnchor(evidence)) ? true : null;
  };
  const addPodcastPaper = async (episode: Episode) => {
    if (!episode.source.arxivID) throw new Error('source_unavailable');
    await library.addArxiv(episode.source.arxivID, episode.source.version);
  };

  const left = rail.open && route !== 'library' ? (
    <SearchRail fieldRef={railField} text={rail.ml ? paperSearch.query : railText} ml={rail.ml}
      onText={text => { if (rail.ml) paperSearch.setQuery(text); else setRailText(text); }} onKey={railKey} onClose={closeRailSearch}
      onLibrary={railLibrary} onML={railML} matches={railMatches.shown} total={railMatches.total} currentID={paperID}
      onOpen={row => { if (isLibraryPaper(row.entry)) openFromRail(row.entry); }}
      search={paperSearch} library={library} preparing={feedPreparing} onAdded={feedAdd} onOpenSource={openRailSource} currentSource={item?.source_id ?? null} />
  ) : route === 'paper' ? (
    <>
      <PaneHeader title={<span className="tabs" role="tablist" aria-label="Side panel">
        <button role="tab" aria-selected={railTab === 'contents'} className={railTab === 'contents' ? 'tab on' : 'tab'} onClick={() => setRailTab('contents')}>Contents</button>
        <button role="tab" aria-selected={railTab === 'library'} className={railTab === 'library' ? 'tab on' : 'tab'} onClick={() => setRailTab('library')}>Library</button>
      </span>} onClose={() => ws.show('left', false)} closeLabel="Hide side panel" />
      <div className="rail-body" role="tabpanel">
        {railTab === 'contents' ? <div ref={setContentsSlot} className="contents-slot"><p className="fine rail-note">The contents appear when the paper opens.</p></div>
          : <CompactLibrary model={model} activity={activity} currentID={paperID} onOpen={openPaper} onSimilar={similar} recommender={recommender} query={view.query} prepared={prepared} />}
      </div>
    </>
  ) : route === 'notes' ? (
    <>
      {/* One way to start a collection (UX audit S19): the round + of this header, as the phone's list header has. */}
      <PaneHeader title="Snippets" onClose={() => ws.show('left', false)} closeLabel="Hide side panel">
        {notes && <button className="icon-button pane-new" onClick={() => setNewNote(true)} disabled={!notes.writable} aria-label="New collection" title="New collection" data-testid="new-note">
          <Icon name="plus" size={16} /></button>}
      </PaneHeader>
      <div className="rail-body">{notes ? <NotesList store={notes} current={noteID} rail onOpen={id => navigate(`/notes/${id}`)} onNew={() => setNewNote(true)} />
        : <p className="fine rail-note">Opening your snippets…</p>}</div>
    </>
  ) : (
    <>
      <PaneHeader title={route === 'feed' ? 'Feed' : 'Library'} onClose={() => ws.show('left', false)} closeLabel="Hide side panel" />
      <div className="rail-body">{route === 'feed' ? <FeedRail model={feed} listen={{ selected: listening, select: setListening, view: null }} /> : <LibraryRail model={model} view={view} setView={setView} onSearchTag={searchPapers} />}</div>
    </>
  );

  let center: ReactNode;
  if (paperID) {
    // A direct paper URL can finish loading the library before local decryption. Mounting the
    // reader then would record the top of the paper before its saved place could be restored.
    center = item && !activityLoaded ? <div className="empty" role="status" aria-label="Opening paper"><div className="spinner" /><p>Opening the paper…</p></div>
      : item ? <Suspense fallback={<div className="empty" role="status" aria-label="Opening paper"><div className="spinner" /><p>Opening the paper…</p></div>}><Reader paperMenu={<PaperMenuButton item={item} busy={library.pending.has(item.id)} expanded={readerActions.menuItemID === item.id} onOpen={readerActions.open} extra={!!readingSource(item)} />} listenAction={<PaperListen key={item.id} account={account} itemID={item.id} title={item.metadata?.title ?? 'Paper'} player={player} onBrowseShared={() => { setListening(true); void navigate('/feed'); }}
        onAsked={podcasts.asked} openWith={listenAgain?.itemID === item.id ? listenAgain : null} onOpened={() => setListenAgain(null)} deviceSource={readingSource(item) ? async signal => {
        // The paper's own text on this device (migration 066): the verified bundle's numbered context, as the chat sends it.
        // An arXiv paper from before the HTML-first reader sends it too, named by its library item (migration 081: the
        // server's copy was deleted), like its chat (setLegacyPapers); when it can't be prepared here nothing is sent,
        // and Listen says to open it first.
        const reference = (isSourcePaper(item) ? paperReference(item) : readingSource(item))!, legacy = !isSourcePaper(item);
        const key = readerCacheKey(account, item), saved = readerCache.get(key);
        let bundle;
        try { bundle = saved?.manifest.source.kind === 'arxiv-html' ? saved : await prepareArxivReader(reference, signal, undefined, { authors: item.metadata?.authors ?? [], title: item.metadata?.title }); }
        catch (e) { if (legacy && !signal.aborted) return null; throw e; }
        const context = localChatContext(reference, bundle);
        return { text: { format: 'paper-context-v2', text: context.text }, identity: { source: 'arxiv', source_id: context.source_id, revision: context.revision, manifest_sha256: context.manifest_sha256, title: item.metadata?.title ?? undefined, authors: item.metadata?.authors ?? [] } };
      } : undefined} />} cache={readerCache} account={account} item={item} saved={activityStore.get(item.id)} onActivity={record} theme={resolved}
        contentsSlot={railTab === 'contents' && ws.left.open && !rail.open ? contentsSlot : null} commands={readerCommands} onKey={shortcut} onContents={onContents} onSelection={selectAction} marks={marks}
        readSaved={readSaved}
        passage={passage?.documentID === paperIdentity(item) ? passage : null} onPassageHandled={() => setPassage(null)}
        explainer={explainer?.documentID === paperIdentity(item) ? explainer : null} onExplainerHandled={() => setExplainer(null)}
        onDiscuss={discuss} onReferenceAdded={() => { void library.refresh().catch(() => {}); }} equations={equationHost} figureView={figureHost} paperExplainer={paperExplainerHost}
        onEditTags={keyword => readerActions.editTags(item, keyword ? { name: keyword, search: searchPapers, showTagged } : undefined)}
        onAuthorSearch={name => searchPapers('author:' + name)}
        onBackToChat={chatReturn && !ws.right.open ? () => { const back = chatReturn.composer; setChatReturn(null); if (back) chat?.chooseDraft(back); setChatMode('paper'); ws.show('right'); } : undefined}
        onExplainerReturn={() => setChatReturn(null)}
        onMarkedChat={id => { if (chat?.open(id)) { setChatMode('paper'); ws.show('right'); } }} reading={reading}
        noteCapture={notes ? { writable: notes.writable, images: notes.canSaveImages, add: (draft, adjust) => setComposer({ draft, adjust }) } : undefined} /></Suspense>
      : library.state === 'loading' ? <div className="empty"><div className="spinner" aria-label="Loading" /></div>
        : <div className="empty"><p>This paper isn’t in your library.</p><button className="secondary" onClick={() => navigate('/')}>Back to library</button></div>;
  } else if (route === 'notes') {
    const listBeside = ws.left.open && ws.left.inline;
    center = !notes ? <div className="empty" role="status"><div className="spinner" /><p>Opening your snippets…</p></div>
      : noteID ? <NoteDetail key={noteID} store={notes} noteID={noteID} back={!listBeside} onBack={() => navigate('/notes')} onOpenSource={openSource} onChat={entry => void chatAboutEntry(entry)}
        onAddText={id => setComposer({ draft: { kind: 'text', source: null, anchor: null, capturedAt: Date.now(), destination: id } })} />
      : listBeside ? <div className="empty notes-choose"><Icon name="notes" size={28} /><p className="muted">Choose a collection.</p></div>
      : <NotesList store={notes} current={null} onOpen={id => navigate(`/notes/${id}`)} onNew={() => setNewNote(true)} />;
  } else if (route === 'feed') {
    center = <FeedView model={feed} library={library} showChips={!railVisible} preparing={feedPreparing} onLibrary={() => navigate('/')}
      onAdded={feedAdd}
      onOpen={sourceID => { const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID); if (paper) void openPaper(paper); }}
      listen={{ selected: listening, select: setListening, view: <ListenView podcasts={podcasts} player={player} onTryAgain={tryAgain} /> }} onReport={report} />;
  } else if (libraryML) {
    // ML papers on the Library route: in the table's place, with the switch in the title row (as before).
    center = <section className="library library-ml" aria-labelledby="library-ml-title">
      <div className="view-head library-head"><h1 id="library-ml-title">Library</h1>{scopeSwitch}</div>
      <PaperSearchView search={paperSearch} library={library} preparing={feedPreparing} onAdded={feedAdd} onLibrary={toLibraryTable}
        onOpen={sourceID => { const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && e.source_id === sourceID); if (paper) void openPaper(paper); }} />
    </section>;
  } else {
    center = <LibraryView library={library} model={model} activity={activity} view={view} setView={setView} showChips={!railVisible} prepared={prepared} onSearchTag={searchPapers}
      currentID={lastPaper} onOpen={openPaper} onSimilar={similar} recommender={recommender} onAdd={() => setAdding(true)} chatCount={chatCount} onReport={report}
      searchSwitch={view.query.trim() ? scopeSwitch : undefined} />;
  }

  // Paper (phone): the paper last open in this tab, else the one most recently opened on this device.
  const recentPaper = useMemo(() => {
    const visible = new Set(library.entries.filter(e => isReaderPaper(e) && e.visible).map(e => e.id));
    if (lastPaper && visible.has(lastPaper)) return lastPaper;
    return [...activity].filter(([id]) => visible.has(id)).sort((a, b) => (b[1].opened ?? 0) - (a[1].opened ?? 0))[0]?.[0] ?? null;
  }, [library.entries, lastPaper, activity]);
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
        {!phone && <nav className="topnav" aria-label="Main">
          {nav('/', 'Library', 'book', route === 'library', 'back-to-library')}
          {nav('/feed', 'Feed', 'feed', route === 'feed')}
          {nav('/notes', 'Snippets', 'notes', route === 'notes', 'nav-notes')}
          <button className="nav-link" onClick={() => setChats(true)} title="All chats"><Icon name="chats" /><span className="nav-label">Chats</span></button>
        </nav>}
        {/* The catalog to the left of the search (owner, build 75: "Move the catalog to the left of the search bar"): on the
            library, only once there is a choice (more than one catalog, or one renamed), and not while searching. */}
        {route === 'library' && !searching && library.catalogs && (library.catalogs.state.catalogs.length > 1 || library.catalogs.state.catalogs[0]?.name !== 'Default') &&
          <label className="topbar-catalog"><span className="visually-hidden">Catalog</span>
            <select aria-label="Current catalog" value={library.catalogs.currentID} onChange={e => library.catalogs?.select(e.target.value)} data-testid="catalog-select"
              title={library.catalogs.state.catalogs.find(c => c.id === library.catalogs?.currentID)?.name}>
              {library.catalogs.state.catalogs.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>}
        <div className="search-field">
          <Icon name="search" size={14} />
          <input ref={search} type="search" placeholder="Search papers" aria-label="Search papers" value={route === 'library' ? libraryField : ''} data-testid="search"
            data-mode={libraryML ? 'ml' : 'library'} enterKeyHint="search" aria-haspopup={route === 'library' ? undefined : 'true'}
            onChange={e => {
              const text = e.target.value;
              if (route !== 'library') { setRailText(text); if (!rail.open) openRailSearch(); else railField.current?.focus(); return; }
              if (libraryML) paperSearch.setQuery(text); else setView(q => ({ ...q, query: text, tag: text.trim() ? '' : q.tag }));
            }}
            onFocus={() => { if (route !== 'library') { if (rail.open) railField.current?.focus(); else openRailSearch(); } }} onKeyDown={searchKey} />
          <kbd aria-hidden="true">/</kbd>
        </div>
        <div className="topbar-actions">
          <button className="icon-button theme-toggle" onClick={() => setTheme(resolved === 'dark' ? 'light' : 'dark')} aria-label={resolved === 'dark' ? 'Use light appearance' : 'Use dark appearance'}
            title={resolved === 'dark' ? 'Light appearance' : 'Dark appearance'} data-testid="theme"><Icon name={resolved === 'dark' ? 'sun' : 'moon'} /></button>
          <button className={`icon-button chat-toggle${ws.right.open ? ' on' : ''}`} onClick={() => ws.toggle('right')} aria-label="Chat panel" aria-pressed={ws.right.open} title="Chat panel ( ] )">
            <Icon name="panelRight" /></button>
          <AccountMenu compact={phone} email={session.user.email} onSettings={() => setSettingsOpen(true)} onHelp={() => setHelp(true)} onReport={() => setReportOpen(true)}
            onSignOut={() => setSigningOut(true)} />
        </div>
      </header>
      <StorageNotice />
      {navigationIssue && <div className="storage-notice" role="alert" data-testid="navigation-save-issue">
        <span>Some chat edits couldn’t be saved on this device. They’re still available in All chats. Keep this tab open.</span>
        <button className="secondary small" onClick={() => setChats(true)}>Review drafts</button>
        <button className="icon-button" aria-label="Dismiss save notice" onClick={() => setNavigationIssue(false)}><Icon name="close" size={16} /></button>
      </div>}
      {/* Each region fails on its own (RESILIENCE.md fix 2): a malformed answer, feed row or episode never blanks the page. */}
      <Workspace controls={ws} leftLabel={rail.open && route !== 'library' ? 'Search papers' : route === 'paper' ? 'Side panel' : route === 'feed' ? 'Feed topics' : route === 'notes' ? 'Snippet collections' : 'Library filters'} rightLabel="Chat"
        left={route === 'library' && libraryIsEmpty(model) ? null : <RegionBoundary region="side" label="The side panel" compact resetKey={route} onReport={report}>{left}</RegionBoundary>}
        center={<RegionBoundary region={route === 'paper' ? 'reader' : route === 'feed' ? (listening ? 'listen' : 'feed') : route === 'notes' ? 'notes' : 'library'}
          label={route === 'paper' ? 'The reader' : route === 'feed' ? (listening ? 'Listen' : 'The feed') : route === 'notes' ? 'Snippets' : 'The library'}
          resetKey={`${route}:${item ? paperIdentity(item) : ''}:${listening}:${noteID ?? ''}`} onReport={report}>{center}</RegionBoundary>}
        right={<RegionBoundary region="chat" label="Chat" resetKey={paperContext?.documentID ?? chatMode} onReport={report}>
          <ChatPane chat={chat} paper={paperContext} mode={chatMode === 'paper' && paperContext ? 'paper' : 'general'} onMode={setChatMode} onAllChats={() => setChats(true)} onPassage={goToPassage} onChatOptions={() => setChatDefaults('about')} papers={answerPapers}
            onBackToNote={(noteID, entryID) => { void navigate(`/notes/${noteID}`); void entryID; if (!latest.current.ws.right.inline) latest.current.ws.show('right', false); }} />
        </RegionBoundary>} />
      {item && <RegionBoundary region="paper-actions" label="Paper actions" compact onReport={report}><LibraryActionSurface actions={readerActions} /></RegionBoundary>}
      <RegionBoundary region="player" label="The player" compact onReport={report}><PodcastDock player={player} onEvidence={openPodcastEvidence} onAdd={addPodcastPaper} onReport={report} /></RegionBoundary>
      {savedNote && <div className="notes-saved" role="status" data-testid="notes-saved"><span>Saved to {savedNote.title}{savedNote.offline ? ' · Waiting to sync' : ''}</span>
        <button className="link" onClick={() => { setSavedNote(null); void navigate(`/notes/${savedNote.noteID}`); }} data-testid="open-saved-note">Open</button>
        <button className="icon-button" aria-label="Dismiss" onClick={() => setSavedNote(null)}><Icon name="close" size={14} /></button></div>}
      {phone && <PhoneTabs route={route} chatOpen={ws.right.open} lastPaper={recentPaper}
        navigate={to => void navigate(to)} onChat={() => { if (route !== 'paper') setChatMode('general'); ws.show('right'); }} />}
      {notes && composer && <RegionBoundary region="note-composer" label="Save snippet" compact onReport={report}><NoteComposer store={notes} draft={composer.draft}
        onAdjust={composer.adjust ? () => { const adjust = composer.adjust!; setComposer(null); adjust(); } : undefined} onClose={() => setComposer(null)}
        onSaved={(id, title) => { const text = composer.draft.kind === 'text'; setComposer(null); if (text || route === 'notes') void navigate(`/notes/${id}`); else setSavedNote({ noteID: id, title, offline: typeof navigator !== 'undefined' && navigator.onLine === false }); }} /></RegionBoundary>}
      {notes && newNote && <NewNoteDialog store={notes} onClose={() => setNewNote(false)} onCreated={id => { setNewNote(false); void navigate(`/notes/${id}`); }} />}
      {devicePDFs.issue && <p role="status" className="library-action-notice">{devicePDFs.issue} <button className="link" onClick={devicePDFs.clearIssue}>Dismiss</button></p>}
      <RegionBoundary region="recommend" label="Recommended papers" compact resetKey={recommender.run} onReport={report}>
        <RecommendDialog recommender={recommender} />
      </RegionBoundary>
      <RegionBoundary region="add-paper" label="Add paper" compact resetKey={adding} onReport={report}>
        <AddPaper localPDFs={devicePDFs} open={adding} onClose={() => setAdding(false)} library={library} onOpen={paper => void openPaper(paper)} account={account} keys={{ ring: ready.ring, deviceID: ready.deviceID }} />
      </RegionBoundary>
      <RegionBoundary region="chats" label="All chats" compact resetKey={chats} onReport={report}>
        <ChatHistory chat={chat} open={chats} onClose={() => setChats(false)} papers={paperNames} currentDocument={(item ? paperIdentity(item) : undefined) ?? null} onOpen={openChatDocument} topics={paperTopics} />
      </RegionBoundary>
      {chat && <RegionBoundary region="chat-defaults" label="AI chat options" compact resetKey={chatDefaults} onReport={report}><ChatDefaults chat={chat} account={account} view={chatDefaults} onView={setChatDefaults} onClose={() => setChatDefaults(false)} /></RegionBoundary>}
      {chat && assetsExportOpen && <RegionBoundary region="assets-export" label="Download your assets" compact onReport={report}><AssetsExportDialog chat={chat} papers={paperNames} open onClose={() => setAssetsExportOpen(false)} /></RegionBoundary>}
      {chat && <RegionBoundary region="diagrams" label="All diagrams" compact resetKey={diagramsOpen} onReport={report}><DiagramsDialog chat={chat} open={diagramsOpen} onClose={() => setDiagramsOpen(false)} /></RegionBoundary>}
      {chat && explanationsOpen && <RegionBoundary region="explanations" label="Explanations" compact onReport={report}><ExplanationsDialog chat={chat} kind={explanationsOpen}
        onClose={() => setExplanationsOpen(null)}
        paperTitle={documentID => { const paper = library.entries.find((e): e is ReaderPaper => isReaderPaper(e) && e.visible && paperIdentity(e) === documentID); return paper ? paper.metadata?.title ?? 'Untitled paper' : null; }}
        onOpen={e => {
          const paper = library.entries.find((p): p is ReaderPaper => isReaderPaper(p) && p.visible && paperIdentity(p) === e.documentID);
          if (!paper) return false;
          setExplanationsOpen(null); setSettingsOpen(false);
          setExplainer({ id: crypto.randomUUID(), documentID: e.documentID, kind: e.kind, targetID: e.targetID, at: Date.now() });
          void openPaper(paper);
          return true;
        }} /></RegionBoundary>}
      {/* Your AI usage (owner, 2026-10-22): titles from this browser's library, matched by the paper's membership or document. */}
      {usageOpen && <RegionBoundary region="usage" label="Your AI usage" compact onReport={report}><UsageDialog account={account} onClose={() => setUsageOpen(false)}
        paperTitle={p => { const paper = library.entries.find(e => e.visible && ((p.membership && e.id === p.membership) || (p.document && isReaderPaper(e) && paperIdentity(e) === p.document)));
          return paper ? paper.metadata?.title ?? 'Untitled paper' : null; }} /></RegionBoundary>}
      <SettingsDialog open={settingsOpen} onClose={() => setSettingsOpen(false)} account={account} email={session.user.email} theme={theme} setTheme={setTheme}
        passageMarks={passageMarks} onPassageMarks={setPassageMarks} sync={syncState} onUsage={() => setUsageOpen(true)} onChatDefaults={chat ? () => setChatDefaults('defaults') : null}
        onCatalogs={library.catalogs ? () => setCatalogsOpen(true) : null} onChats={() => setChats(true)} onDiagrams={chat ? () => setDiagramsOpen(true) : null}
        onNotes={() => { setSettingsOpen(false); void navigate('/notes'); }} onExplanations={chat ? setExplanationsOpen : null} onDownloadAssets={chat ? () => setAssetsExportOpen(true) : null}
        onInfo={() => setHowGradstepWorks(true)} onPrivacy={() => setPrivacy(true)} onReport={() => setReportOpen(true)} onReports={() => setReportsOpen(true)}
        onDeleteAccount={() => { setDeleteTyped(''); setDeleteError(null); setDeletingAccount(true); }} onSignOut={() => setSigningOut(true)} />
      {catalogsOpen && <CatalogsDialog open onClose={() => setCatalogsOpen(false)} library={library} />}
      {reportOpen && <Suspense fallback={null}><ReportDialog open onClose={() => setReportOpen(false)} account={account} onSent={() => { setReportOpen(false); setReportsOpen(true); }} /></Suspense>}
      {reportsOpen && <Suspense fallback={null}><ReportsDialog open onClose={() => setReportsOpen(false)} account={account} /></Suspense>}
      <Dialog open={help} onClose={() => setHelp(false)} title="Keyboard shortcuts">
        <SheetTop onClose={() => setHelp(false)} testID="shortcuts-close"><h2>Keyboard shortcuts</h2></SheetTop>
        <ShortcutList />
      </Dialog>
      {howGradstepWorks && <Suspense fallback={null}><HowGradstepWorks open onClose={() => setHowGradstepWorks(false)} /></Suspense>}
      {privacy && <Suspense fallback={null}><PrivacyData open onClose={() => setPrivacy(false)} /></Suspense>}
      <Dialog open={deletingAccount} onClose={() => { if (!deleteBusy) setDeletingAccount(false); }} title="Delete account" className="delete-account">
        <h2>Delete account</h2>
        <p>This permanently deletes your account:</p>
        <ul className="delete-list">
          <li>Your library, conversations, snippets and diagrams, and your private podcast episodes</li>
          <li>Your support reports and screenshots</li>
          <li>This browser’s copy; other devices are signed out and your recovery code stops working</li>
        </ul>
        <p>Your beta invitation remains valid. Signing in again creates a new account; your deleted library, conversations and credits won’t return.</p>
        <p className="fine">Unused credits are forfeited. Records of credits and AI usage are kept without your email or name, for accounting.</p>
        <p className="fine">An App Store subscription isn’t cancelled by deleting your account; manage it in your Apple Account’s Subscriptions settings.</p>
        <label>Type {TYPED_CONFIRMATION} to confirm
          <input ref={deleteField} value={deleteTyped} readOnly={deleteBusy} autoComplete="off" autoCapitalize="characters" spellCheck={false} placeholder={TYPED_CONFIRMATION}
            onChange={e => setDeleteTyped(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); void deleteAccount(); } }}
            aria-describedby={deleteError ? 'delete-account-error' : undefined} data-testid="delete-account-confirmation" />
        </label>
        {deleteError && <p className="issue" role="alert" id="delete-account-error">{deleteError}</p>}
        <div className="dialog-actions">
          <button className="secondary" disabled={deleteBusy} onClick={() => setDeletingAccount(false)}>Cancel</button>
          <button className="primary danger" disabled={deleteBusy || deleteTyped !== TYPED_CONFIRMATION} onClick={() => void deleteAccount()} data-testid="confirm-delete-account">
            {deleteBusy ? 'Deleting…' : deleteError ? 'Try again' : 'Delete account'}</button>
        </div>
      </Dialog>
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

function ChatDefaults({ chat, account, view, onView, onClose }: { chat: ChatSession; account: string; view: false | ChatOptionsView; onView: (view: ChatOptionsView) => void; onClose: () => void }) {
  useChatUpdates(chat);
  const [visualAnswers, setVisualAnswers] = useState(() => readVisualAnswers());
  const [scenario,setScenario] = useState<AIActivity>('general');
  const chatScenario = scenario === 'podcasts' ? 'general' : scenario;
  // Each activity's ⓘ says what to weigh and when to change it (owner, 2026-10-21; the apps' AIDefaultsGuide). Podcasts
  // chooses who writes new episodes (owner, 2026-10-21: "Podcasts is missing from defaults in model settings").
  const activity = <div className="activity-field">
    <span className="with-info"><label htmlFor="chat-activity">Activity</label><InfoTip text={aiDefaultsGuide(scenario)} testID="activity-guide" /></span>
    <select id="chat-activity" value={scenario} onChange={e=>setScenario(e.target.value as AIActivity)}>
      {Object.entries(AI_USE_CASE_TITLES).map(([value, title]) => <option key={value} value={value}>{title}</option>)}<option value="podcasts">Podcasts</option></select></div>;
  return <ChatOptionsDialog open={!!view} view={view || 'defaults'} onView={onView} onClose={onClose} table={chat.profileTable} choice={chat.scenarioProfile(chatScenario)} onChange={next => chat.setScenarioProfile(chatScenario,next)}
    scenarioControl={activity} picker={scenario === 'podcasts' ? <PodcastWriterDefault account={account} /> : undefined}
    visualAnswers={visualAnswers} onVisualAnswers={on => { writeVisualAnswers(on); setVisualAnswers(on); }} onRetry={() => chat.reloadProfiles()} />;
}

/** Phone widths (owner direction for Notes, matching the apps): Feed · Library · Paper · Chat · Notes, in that order. */
function PhoneTabs({ route, chatOpen, lastPaper, navigate, onChat }: { route: Route; chatOpen: boolean; lastPaper: string | null; navigate: (to: string) => void; onChat: () => void }) {
  const current = chatOpen ? 'chat' : route;
  const link = (to: string, label: string, icon: IconName, key: string, testID?: string) => <a href={to} className={`phone-tab${current === key ? ' on' : ''}`} aria-current={current === key ? 'page' : undefined}
    data-testid={testID} onClick={e => { e.preventDefault(); navigate(to); }}><Icon name={icon} size={19} /><span>{label}</span></a>;
  return <nav className="phone-tabs" aria-label="Main">
    {link('/feed', 'Feed', 'feed', 'feed')}
    {link('/', 'Library', 'book', 'library', 'back-to-library')}
    {lastPaper ? link(`/paper/${lastPaper}`, 'Paper', 'paper', 'paper', 'phone-paper')
      : <button className={`phone-tab${current === 'paper' ? ' on' : ''}`} disabled title="Open a paper from your library first" data-testid="phone-paper"><Icon name="paper" size={19} /><span>Paper</span></button>}
    <button className={`phone-tab${current === 'chat' ? ' on' : ''}`} aria-pressed={chatOpen} onClick={onChat} data-testid="phone-chat"><Icon name="chat" size={19} /><span>Chat</span></button>
    {link('/notes', 'Snippets', 'notes', 'notes', 'nav-notes')}
  </nav>;
}

function AccountMenu({ compact = false, email, onSettings, onHelp, onReport, onSignOut }: {
  compact?: boolean; email: string | null; onSettings: () => void; onHelp: () => void; onReport: () => void; onSignOut: () => void }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false); };
    document.addEventListener('pointerdown', away); document.addEventListener('keydown', key);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', key); };
  }, [open]);
  const item = (label: string, icon: IconName | null, run: () => void, testID: string) => <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); run(); }} data-testid={testID}>
    {icon ? <Icon name={icon} size={14} /> : <span className="menu-icon-space" aria-hidden="true" />} {label}</button>;
  return (
    <div className="account" ref={box}>
      <button className="icon-button account-button" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(o => !o)} data-testid="account-menu"
        title={compact ? 'Account and Settings' : email ?? 'Account'} aria-label={compact ? 'Account and Settings' : undefined}>
        <Icon name="user" />{!compact && <span className="account-email">{email ?? 'Account'}</span>}
      </button>
      {open && (
        <div className="menu account-menu" role="menu" aria-label="Account">
          <p className="menu-email" data-testid="account-email">{email}</p>
          {item('Settings…', 'gear', onSettings, 'open-settings')}
          {item('Keyboard shortcuts', 'keyboard', onHelp, 'keyboard-shortcuts')}
          {item('Report this screen…', 'bug', onReport, 'report-issue')}
          {item('Sign out…', null, onSignOut, 'sign-out')}
        </div>
      )}
    </div>
  );
}
