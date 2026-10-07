// Account-scoped library state: one bounded pull at a time, import polling on the native
// schedule, refresh on focus, and commands with operation-ID replay. Memory only.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { auth, BackendError } from '../lib/backend';
import { cancellation } from '../lib/cancellation';
import { type Command, type Entry, type Import, Reconciler, sendCommand } from '../lib/library';
import { type Mark, importStep, observe, pollDelay, retryingAutomatically } from '../lib/progress';

export type LoadState = 'loading' | 'ready' | 'error';

export function useLibrary(account: string) {
  const reconciler = useRef(new Reconciler(account));
  const running = useRef<Promise<void> | null>(null);
  const lifetime = useRef<ReturnType<typeof cancellation> | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [state, setState] = useState<LoadState>('loading');
  const [marks, setMarks] = useState<Map<string, Mark>>(new Map());
  const [now, setNow] = useState(() => Date.now());
  const [pending, setPending] = useState<Set<string>>(new Set());

  const publish = useCallback(() => {
    const list = [...reconciler.current.entries.values()];
    setEntries(list);
    setMarks(previous => observe(previous, list.filter((e): e is Import => e.kind === 'import'), Date.now()));
  }, []);

  const refresh = useCallback((): Promise<void> => {
    const owner = lifetime.current;
    if (!owner || owner.signal.aborted) return Promise.reject(new BackendError('cancelled'));
    if (running.current) return running.current;
    const task = (async () => {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          reconciler.current.prepareCatchUp();
          await reconciler.current.pull(owner.signal);
          if (owner.signal.aborted) return;
          publish(); setState('ready');
          return;
        } catch (error) {
          if (owner.signal.aborted) throw error;
          if (error instanceof BackendError && error.code === 'library_resync_required' && attempt === 0) { reconciler.current = new Reconciler(account); continue; }
          setState(s => (s === 'ready' ? 'ready' : 'error'));
          throw error;
        }
      }
    })().finally(() => { if (running.current === task) running.current = null; });
    running.current = task;
    return task;
  }, [account, publish]);

  useEffect(() => {
    const owner = cancellation([auth.snapshot().signal]);
    lifetime.current = owner;
    running.current = null;
    refresh().catch(() => {});
    const focus = () => { if (document.visibilityState === 'visible') refresh().catch(() => {}); };
    document.addEventListener('visibilitychange', focus);
    window.addEventListener('focus', focus);
    const slow = setInterval(focus, 60_000);
    return () => { owner.abort(); document.removeEventListener('visibilitychange', focus); window.removeEventListener('focus', focus); clearInterval(slow); };
  }, [refresh]);

  // Imports under way: poll fast at first, then slower (native importPollDelay); tick the bars every second.
  const active = useMemo(() => entries.some(e => e.kind === 'import' && e.visible && (importStep(e) || retryingAutomatically(e))), [entries]);
  useEffect(() => {
    if (!active) return;
    const started = Date.now();
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => {
      if (disposed) return;
      timer = setTimeout(async () => {
        if (document.visibilityState === 'visible') await refresh().catch(() => {});
        tick();
      }, pollDelay((Date.now() - started) / 1000) * 1000);
    };
    tick();
    const clock = setInterval(() => setNow(Date.now()), 1000);
    return () => { disposed = true; clearTimeout(timer); clearInterval(clock); };
  }, [active, refresh]);

  const command = useCallback(async (key: string, make: () => Command) => {
    const owner = lifetime.current;
    if (!owner || owner.signal.aborted) throw new BackendError('cancelled');
    setPending(p => new Set(p).add(key));
    try {
      if (reconciler.current.committed === null) await refresh();
      owner.signal.throwIfAborted();
      const response = await sendCommand(account, make(), undefined, owner.signal);
      owner.signal.throwIfAborted();
      reconciler.current.accept(response);
      publish();
      await refresh().catch(() => {});
      return response;
    } finally {
      if (!owner.signal.aborted) setPending(p => { const n = new Set(p); n.delete(key); return n; });
    }
  }, [account, publish, refresh]);

  const addArxiv = useCallback((sourceID: string, revision: number | null) => command('add', () => ({
    endpoint: 'v2_begin_import', p_source_id: sourceID, p_requested_revision: revision, p_observed_cursor: reconciler.current.committed ?? 0,
  })), [command]);
  const retry = useCallback((i: Import) => command(i.id, () => ({ endpoint: 'v2_retry_import', p_import_id: i.id, p_expected_revision: i.intent_revision })), [command]);
  const remove = useCallback((i: Import) => command(i.id, () => ({ endpoint: 'v2_cancel_import', p_import_id: i.id, p_expected_revision: i.intent_revision })), [command]);

  return { entries, state, marks, now, pending, refresh, addArxiv, retry, remove };
}
