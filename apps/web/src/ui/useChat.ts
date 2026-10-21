import { useEffect, useState } from 'react';
import { auth, BackendError, config } from '../lib/backend';
import { cancellation } from '../lib/cancellation';
import { ChatSession, type JournalState } from '../lib/chat-session';
import { History } from '../lib/history';
import { storage } from '../lib/idb';
import { Journal, browserJournalDependencies } from '../lib/journal';
import { NotesStore, backendTransport } from '../lib/notes-store';
import { prepare, type Preparation } from '../lib/keys';

export function useChat(account: string, ready: Extract<Preparation, { kind: 'ready' }>) {
  const [chat, setChat] = useState<ChatSession | null>(null);
  useEffect(() => {
    const owner = cancellation([auth.snapshot().signal]);
    let cleanup = () => {};
    setChat(null);
    void (async () => {
    let opened: Awaited<ReturnType<typeof Journal.open>> | null = null, journalState: JournalState = 'inactive';
    try {
      if (await storage.journalReady()) {
        const deps = browserJournalDependencies();
        if (!deps || !ready.local) journalState = 'unsupported';
        else {
          opened = await Journal.open({ origin: config.url, environment: config.environment, account, deviceID: ready.deviceID,
            deviceKey: ready.local.fence.key, localKey: ready.local.key, lifetime: ready.local.fence.lifetime,
            fence: ready.local.fence, current: ready.local.current }, deps);
          journalState = 'active';
        }
      }
    } catch (error) {
      const code = (error as { code?: string }).code;
      journalState = code === 'journal_newer' ? 'newer' : code === 'journal_damaged' ? 'damaged' : 'unavailable';
    }
    if (owner.signal.aborted) { opened?.journal.retire(); return; }
    const history = new History(account, ready.deviceID, ready.ring, owner.signal, async () => {
      const refreshed = await prepare(account, owner.signal);
      if (refreshed.kind !== 'ready' || refreshed.deviceID !== ready.deviceID) throw new BackendError('key_authority_required');
      return refreshed.ring;
    }, opened?.journal);
    const session = new ChatSession(account, history, owner.signal, { journal: opened?.journal }, journalState);
    session.noteStore = new NotesStore(account, history, owner.signal, backendTransport(account));
    if (opened) {
      try { await history.restore(opened.snapshot); await session.restore(opened.snapshot.drafts, opened.snapshot.turns); }
      catch { opened.journal.retire(); session.lockJournal('damaged'); journalState = 'damaged'; }
    }
    if (owner.signal.aborted) { opened?.journal.retire(); return; }
    if (journalState !== 'active' && journalState !== 'inactive') {
      history.status = 'error'; history.issueBlocks = true; history.issue = 'This browser’s encrypted chat storage couldn’t be opened. Your stored data has been kept. Reload to retry; don’t clear site data if you need unsynced work.';
      session.lockJournal(journalState);
    }
    setChat(session);
    // A newer tab proposing a storage update waits while this page holds unsent work (BROWSER_OFFLINE_STORAGE.md).
    const unregister = storage.registerWork(() => session.hasVolatileContent);
    const review = () => storage.reviewProposal();
    const unwatchSession = session.subscribe(review), unwatchHistory = history.subscribe(review);
    const unwatch = () => { unwatchSession(); unwatchHistory(); };
    const refresh = () => { if (document.visibilityState === 'visible' && !session.storageRetired) { void history.sync().catch(() => {}); void session.refreshBalance(); } };
    refresh();
    const timer = setInterval(refresh, 30_000);
    const beforeUnload = (e: BeforeUnloadEvent) => { if (session.hasVolatileContent) { e.preventDefault(); e.returnValue = ''; } };
    window.addEventListener('focus', refresh); document.addEventListener('visibilitychange', refresh); window.addEventListener('beforeunload', beforeUnload);
    cleanup = () => { unwatch(); unregister(); clearInterval(timer); window.removeEventListener('focus', refresh); document.removeEventListener('visibilitychange', refresh); window.removeEventListener('beforeunload', beforeUnload); };
    })();
    return () => { cleanup(); owner.abort(); };
  }, [account, ready]);
  return chat;
}
