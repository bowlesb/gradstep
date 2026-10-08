import { useEffect, useState } from 'react';
import { auth, BackendError } from '../lib/backend';
import { cancellation } from '../lib/cancellation';
import { ChatSession } from '../lib/chat-session';
import { History } from '../lib/history';
import { prepare, type Preparation } from '../lib/keys';

export function useChat(account: string, ready: Extract<Preparation, { kind: 'ready' }>) {
  const [chat, setChat] = useState<ChatSession | null>(null);
  useEffect(() => {
    const owner = cancellation([auth.snapshot().signal]);
    const history = new History(account, ready.deviceID, ready.ring, owner.signal, async () => {
      const refreshed = await prepare(account, owner.signal);
      if (refreshed.kind !== 'ready' || refreshed.deviceID !== ready.deviceID) throw new BackendError('key_authority_required');
      return refreshed.ring;
    });
    const session = new ChatSession(account, history, owner.signal);
    setChat(session);
    const refresh = () => { if (document.visibilityState === 'visible') { void history.sync().catch(() => {}); void session.refreshBalance(); } };
    refresh();
    const timer = setInterval(refresh, 30_000);
    const beforeUnload = (e: BeforeUnloadEvent) => { if (session.hasVolatileContent) { e.preventDefault(); e.returnValue = ''; } };
    window.addEventListener('focus', refresh); document.addEventListener('visibilitychange', refresh); window.addEventListener('beforeunload', beforeUnload);
    return () => { owner.abort(); clearInterval(timer); window.removeEventListener('focus', refresh); document.removeEventListener('visibilitychange', refresh); window.removeEventListener('beforeunload', beforeUnload); };
  }, [account, ready]);
  return chat;
}
