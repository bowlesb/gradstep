import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { type Activity, loadActivity, saveActivity } from '../lib/activity';
import { type Session, auth, config } from '../lib/backend';
import { type DeviceRecord, type Preparation, forgetDevice, readDevice } from '../lib/keys';
import type { Item } from '../lib/library';
import type { Episode, Evidence } from '../lib/podcast';
import { clearPositions, evidenceAnchor } from '../lib/podcast-playback';
import { supportsX25519 } from '../lib/wire';
import type { FrameKey } from '../reader/frame';
import { ChatHistory, ChatPane, type PaperContext, useChatUpdates } from './ChatPane';
import { ChatDefaultsDialog } from './ChatProfile';
import type { ChatSession } from '../lib/chat-session';
import { useChat } from './useChat';
import { actionFor, selectionPrompt, type SelectionAction } from '../lib/chat';
import type { TextAnchor } from '../lib/events';
import { Brand, Dialog } from './common';
import { FeedRail, FeedView, useFeed } from './Feed';
import { ListenView, PaperListen, PodcastDock, usePodcasts, usePodcastPlayer } from './Podcast';
import { Icon, type IconName } from './icons';
import { KeySetup } from './Keys';
import { AddPaper, CompactLibrary, INITIAL_QUERY, type LibraryQuery, LibraryRail, LibraryView, useLibraryModel } from './Library';
import { LibraryActionSurface, PaperMenuButton, useLibraryActions } from './LibraryActions';
import { type Route, type Theme, useTheme } from './prefs';
import { type ReaderCache, type ReaderCommands, Reader } from './Reader';
import { PaneHeader, Workspace, useWorkspace } from './Shell';
import { SignIn } from './SignIn';
import { StorageNotice, storageGuidance } from './StorageNotice';
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
  const { session, generation } = useSyncExternalStore(auth.subscribe, auth.snapshot);

  useEffect(() => {
    (async () => setSupported(!!config.url && typeof indexedDB !== 'undefined' && !!crypto?.subtle && await supportsX25519()))();
  }, []);

  if (supported === null) return null;
  if (!supported) return <Unsupported />;
  if (!session) return <SignIn />;
  return <AccountSession key={generation} session={session} />;
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

const SHORTCUTS = [['/ or ⌘K', 'Search the library'], ['⌘F', 'Find in the paper'], ['[', 'Show or hide the side panel'], [']', 'Show or hide the chat panel'],
  ['↑ ↓', 'Move between papers'], ['← →', 'Previous or next figure'], ['Esc', 'Close, or clear the search'], ['?', 'These shortcuts']] as const;
const PLAIN_KEYS: Record<string, FrameKey> = { '/': 'search', '[': 'left', ']': 'right', '?': 'help' };

function Signed({ session, ready }: { session: Session; ready: Ready }) {
  const account = session.user.id;
  const library = useLibrary(account);
  // The reader has the same paper action surface as Library. Keeping a separate owner avoids
  // two portals competing when a library menu is still closing during navigation.
  const readerActions = useLibraryActions(library);
  const chat = useChat(account, ready);
  const historyVersion = useSyncExternalStore(chat?.history.subscribe ?? (() => () => {}), chat?.history.getVersion ?? (() => 0));
  const [chatMode, setChatMode] = useState<'paper' | 'general'>('paper');
  const [orphanPaper, setOrphanPaper] = useState<PaperContext | null>(null);
  const [passage, setPassage] = useState<{ id: string; documentID: string; anchor: TextAnchor; at: number } | null>(null);
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
  const [help, setHelp] = useState(false);
  const [chatDefaults, setChatDefaults] = useState(false);
  const [adding, setAdding] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  const [readerCache] = useState<ReaderCache>(() => new Map());
  // Library search, filters and sort survive opening a paper and coming back (UX_PARITY.md).
  const [view, setView] = useState<LibraryQuery>(INITIAL_QUERY);
  const [railTab, setRailTab] = useState<'contents' | 'library'>('contents');
  const [contentsSlot, setContentsSlot] = useState<HTMLElement | null>(null);
  const [lastPaper, setLastPaper] = useState<string | null>(null);
  const { theme, resolved, setTheme } = useTheme();
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const search = useRef<HTMLInputElement>(null);
  const readerCommands = useRef<ReaderCommands | null>(null);
  const openPaper = useCallback((paper: Item, anchor?: TextAnchor) => navigate(`/paper/${paper.id}`, () => {
    setLastPaper(paper.id);
    setPassage(anchor ? { id: crypto.randomUUID(), documentID: paper.document_id, anchor, at: Date.now() } : null);
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
  const item = paperID ? library.entries.find((e): e is Item => e.kind === 'item' && e.id === paperID && e.visible) : undefined;
  useEffect(() => { if (path !== '/' && path !== '/feed' && !match) navigate('/'); }, [path, match, navigate]);
  useEffect(() => { if (paperID) setLastPaper(paperID); setOrphanPaper(null); setChatMode(paperID ? 'paper' : 'general'); }, [paperID]);

  const ws = useWorkspace(route);
  const latest = useRef({ ws, route, paperID });
  latest.current = { ws, route, paperID };
  const model = useLibraryModel(library, activity, view, route !== 'paper' || (railTab === 'library' && ws.left.open));
  const feed = useFeed(account, library.entries);
  const podcasts = usePodcasts(account);
  const player = usePodcastPlayer(account);
  const [listening, setListening] = useState(false);

  const shortcut = useCallback((key: FrameKey) => {
    const { ws, route } = latest.current;
    switch (key) {
      case 'search': search.current?.focus(); search.current?.select(); break;
      case 'find': if (route === 'paper') readerCommands.current?.find(); break;
      case 'left': ws.toggle('left'); break;
      case 'right': ws.toggle('right'); break;
      case 'help': setHelp(true); break;
      case 'escape':
        if (readerCommands.current?.escape()) break;
        if (ws.overlay) ws.show(ws.overlay, false);
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
  const paperContext = orphanPaper ?? (item?.document_id ? { documentID: item.document_id, title: item.metadata?.title ?? 'Paper', available: item.readiness === 'converted_ready' && item.render_availability === 'available' } : null);
  const paperNames = useMemo(() => new Map(library.entries.filter((e): e is Item => e.kind === 'item' && e.visible).map(e => [e.document_id, e.metadata?.title ?? 'Paper'])), [library.entries]);
  const openChatDocument = async (documentID: string | null, anchor?: TextAnchor) => {
    if (!documentID) setChatMode('general');
    else {
      const paper = library.entries.find((e): e is Item => e.kind === 'item' && e.visible && e.document_id === documentID);
      if (paper) { if (!await openPaper(paper, anchor)) return; setOrphanPaper(null); }
      else setOrphanPaper({ documentID, title: 'Paper no longer in library', available: false });
      setChatMode('paper');
    }
    latest.current.ws.show('right');
  };
  const goToPassage = (documentID: string, anchor: TextAnchor) => {
    void openChatDocument(documentID, anchor);
  };
  const selectAction = (action: SelectionAction, quote: string, anchor: TextAnchor) => {
    if (!chat || chat.storageRetired || !item?.document_id) return; // the storage notice explains why nothing is sent
    // The new conversation answers with the model, effort and length the chat pane shows right now.
    const visible = chat.current(chatMode === 'paper' && paperContext ? paperContext.documentID : null);
    const composer = chat.newChat(item.document_id, chat.profileFor(visible));
    chat.edit(composer, selectionPrompt(action, quote)); setChatMode('paper'); ws.show('right');
    void chat.send(composer, quote, actionFor[action], anchor).then(() => { if (action === 'ingest') void library.refresh().catch(() => {}); });
  };
  const discuss = async (quote: string, anchor: TextAnchor): Promise<boolean> => {
    if (!chat || chat.storageRetired || !item?.document_id) return false;
    const owner = auth.snapshot(), sourcePaper = item.id;
    const composer = await chat.discuss(item.document_id, quote, anchor);
    if (!composer || owner.signal.aborted || latest.current.paperID !== sourcePaper) return false;
    setChatMode('paper'); latest.current.ws.show('right');
    // The reader closes its modal only after this promise resolves. Focus on the next paint, when
    // the composer is no longer inert; never submit a provider request from Discuss.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!owner.signal.aborted && latest.current.paperID === sourcePaper && chat.current(item.document_id).id === composer.id) {
        document.querySelector<HTMLTextAreaElement>('.chat-composer textarea')?.focus();
      }
    }));
    return true;
  };
  const marks = useMemo(() => chat?.history.state.conversationSummaries().filter(c => c.documentID === item?.document_id && c.anchor).map(c => ({ id: c.id, anchor: c.anchor! })) ?? [], [chat, historyVersion, item?.document_id]);

  const openPodcastEvidence = async (episode: Episode, evidence: Evidence): Promise<boolean | null> => {
    const paper = library.entries.find((e): e is Item => e.kind === 'item' && e.visible && e.document_id === episode.documentID);
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
          : <CompactLibrary model={model} activity={activity} currentID={paperID} onOpen={openPaper} query={view.query} />}
      </div>
    </>
  ) : (
    <>
      <PaneHeader title={route === 'feed' ? 'Feed' : 'Library'} onClose={() => ws.show('left', false)} closeLabel="Hide side panel" />
      <div className="rail-body">{route === 'feed' ? <FeedRail model={feed} listen={{ selected: listening, select: setListening, view: null }} /> : <LibraryRail model={model} view={view} setView={setView} />}</div>
    </>
  );

  let center: ReactNode;
  if (paperID) {
    // A direct paper URL can finish loading the library before local decryption. Mounting the
    // reader then would record the top of the paper before its saved place could be restored.
    center = item && !activityLoaded ? <div className="empty" role="status" aria-label="Opening paper"><div className="spinner" /><p>Opening the paper…</p></div>
      : item ? <Reader paperMenu={<PaperMenuButton item={item} busy={library.pending.has(item.id)} expanded={readerActions.menuItemID === item.id} onOpen={readerActions.open} />} listenAction={<PaperListen key={item.id} account={account} itemID={item.id} title={item.metadata?.title ?? 'Paper'} player={player} />} cache={readerCache} account={account} item={item} saved={activity.get(item.id)} onActivity={record} theme={resolved}
        contentsSlot={railTab === 'contents' && ws.left.open ? contentsSlot : null} commands={readerCommands} onKey={shortcut} onContents={onContents} onSelection={selectAction} marks={marks}
        passage={passage?.documentID === item.document_id ? passage : null} onPassageHandled={() => setPassage(null)}
        onDiscuss={discuss} onReferenceAdded={() => { void library.refresh().catch(() => {}); }}
        onMarkedChat={id => { if (chat?.open(id)) { setChatMode('paper'); ws.show('right'); } }} />
      : library.state === 'loading' ? <div className="empty"><div className="spinner" aria-label="Loading" /></div>
        : <div className="empty"><p>This paper isn’t in your library.</p><button className="secondary" onClick={() => navigate('/')}>Back to library</button></div>;
  } else if (route === 'feed') {
    center = <FeedView model={feed} library={library} showChips={!railVisible}
      listen={{ selected: listening, select: setListening, view: <ListenView podcasts={podcasts} player={player} /> }} />;
  } else {
    center = <LibraryView library={library} model={model} activity={activity} view={view} setView={setView} showChips={!railVisible}
      currentID={lastPaper} onOpen={openPaper} onAdd={() => setAdding(true)} />;
  }

  const nav = (to: string, label: string, icon: IconName, current: boolean, testID?: string) => (
    <a href={to} className={current ? 'nav-link on' : 'nav-link'} aria-current={current ? 'page' : undefined} data-testid={testID} title={label}
      onClick={e => { e.preventDefault(); navigate(to); }}><Icon name={icon} /><span className="nav-label">{label}</span></a>
  );

  return (
    <div className="app">
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
          <input ref={search} type="search" placeholder="Search library" aria-label="Search library" value={view.query} data-testid="search"
            onChange={e => query(e.target.value)}
            onKeyDown={e => {
              if (e.key === 'Escape') { if (view.query) { e.preventDefault(); query(''); } else e.currentTarget.blur(); }
              if (e.key === 'ArrowDown') { const first = document.querySelector<HTMLElement>('#main a.title, .compact-list a'); if (first) { e.preventDefault(); first.focus(); } }
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
          <AccountMenu email={session.user.email} theme={theme} setTheme={setTheme} onHelp={() => setHelp(true)} onSignOut={() => setSigningOut(true)}
            onChatDefaults={chat ? () => setChatDefaults(true) : null} />
        </div>
      </header>
      <StorageNotice />
      {navigationIssue && <div className="storage-notice" role="alert" data-testid="navigation-save-issue">
        <span>Some chat edits couldn’t be saved on this device. They’re still available in All chats. Keep this tab open.</span>
        <button className="secondary small" onClick={() => setChats(true)}>Review drafts</button>
        <button className="icon-button" aria-label="Dismiss save notice" onClick={() => setNavigationIssue(false)}><Icon name="close" size={16} /></button>
      </div>}
      <Workspace controls={ws} leftLabel={route === 'paper' ? 'Side panel' : route === 'feed' ? 'Feed topics' : 'Library filters'} rightLabel="Chat"
        left={left} center={center} right={<ChatPane chat={chat} paper={paperContext} mode={chatMode === 'paper' && paperContext ? 'paper' : 'general'} onMode={setChatMode} onAllChats={() => setChats(true)} onPassage={goToPassage} />} />
      {item && <LibraryActionSurface actions={readerActions} />}
      <PodcastDock player={player} onEvidence={openPodcastEvidence} onAdd={addPodcastPaper} />
      <AddPaper open={adding} onClose={() => setAdding(false)} library={library} account={account} />
      <ChatHistory chat={chat} open={chats} onClose={() => setChats(false)} papers={paperNames} currentDocument={item?.document_id ?? null} onOpen={openChatDocument} />
      {chat && <ChatDefaults chat={chat} open={chatDefaults} onClose={() => setChatDefaults(false)} />}
      <Dialog open={help} onClose={() => setHelp(false)} title="Keyboard shortcuts">
        <h2>Keyboard shortcuts</h2>
        <dl className="shortcuts">
          {SHORTCUTS.map(([k, d]) => <div key={k}><dt><kbd>{k}</kbd></dt><dd>{d}</dd></div>)}
        </dl>
        <p className="fine">On Windows and Linux, use Ctrl for ⌘.</p>
        <div className="dialog-actions"><button className="primary" onClick={() => setHelp(false)}>Done</button></div>
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

function ChatDefaults({ chat, open, onClose }: { chat: ChatSession; open: boolean; onClose: () => void }) {
  useChatUpdates(chat);
  return <ChatDefaultsDialog open={open} onClose={onClose} table={chat.profileTable} choice={chat.defaultProfile} onChange={next => chat.setDefaultProfile(next)} onRetry={() => chat.reloadProfiles()} />;
}

function AccountMenu({ email, theme, setTheme, onHelp, onSignOut, onChatDefaults }: { email: string | null; theme: Theme; setTheme: (t: Theme) => void; onHelp: () => void; onSignOut: () => void;
  onChatDefaults: (() => void) | null }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
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
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onHelp(); }}><Icon name="keyboard" size={14} /> Keyboard shortcuts</button>
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); onSignOut(); }} data-testid="sign-out">Sign out…</button>
        </div>
      )}
    </div>
  );
}
