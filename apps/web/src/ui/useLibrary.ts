// Account-scoped library state: one bounded pull at a time, import polling on the native
// schedule, refresh on focus, and commands with operation-ID replay. Memory only.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackendError } from '../lib/backend';
import { type Command, type Entry, type Import, Reconciler, sendCommand } from '../lib/library';
import { type Mark, importStep, observe, pollDelay, retryingAutomatically } from '../lib/progress';

export type LoadState = 'loading' | 'ready' | 'error';

export function useLibrary(account: string) {
  const reconciler = useRef(new Reconciler(account));
  const running = useRef<Promise<void> | null>(null);
  const alive = useRef(true);
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
    if (running.current) return running.current;
    const task = (async () => {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          reconciler.current.prepareCatchUp();
          await reconciler.current.pull();
          if (!alive.current) return;
          publish(); setState('ready');
          return;
        } catch (error) {
          if (error instanceof BackendError && error.code === 'library_resync_required' && attempt === 0) { reconciler.current = new Reconciler(account); continue; }
          if (alive.current) setState(s => (s === 'ready' ? 'ready' : 'error'));
          throw error;
        }
      }
    })().finally(() => { running.current = null; });
    running.current = task;
    return task;
  }, [account, publish]);

  useEffect(() => {
    alive.current = true;
    refresh().catch(() => {});
    const focus = () => { if (document.visibilityState === 'visible') refresh().catch(() => {}); };
    document.addEventListener('visibilitychange', focus);
    window.addEventListener('focus', focus);
    const slow = setInterval(focus, 60_000);
    return () => { alive.current = false; document.removeEventListener('visibilitychange', focus); window.removeEventListener('focus', focus); clearInterval(slow); };
  }, [refresh]);

  // Imports under way: poll fast at first, then slower (native importPollDelay); tick the bars every second.
  const active = useMemo(() => entries.some(e => e.kind === 'import' && e.visible && (importStep(e) || retryingAutomatically(e))), [entries]);
  useEffect(() => {
    if (!active) return;
    const started = Date.now();
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => {
      timer = setTimeout(async () => {
        if (document.visibilityState === 'visible') await refresh().catch(() => {});
        tick();
      }, pollDelay((Date.now() - started) / 1000) * 1000);
    };
    tick();
    const clock = setInterval(() => setNow(Date.now()), 1000);
    return () => { clearTimeout(timer); clearInterval(clock); };
  }, [active, refresh]);

  const command = useCallback(async (key: string, make: () => Command) => {
    setPending(p => new Set(p).add(key));
    try {
      if (reconciler.current.committed === null) await refresh();
      const response = await sendCommand(account, make());
      reconciler.current.accept(response);
      publish();
      await refresh().catch(() => {});
      return response;
    } finally {
      setPending(p => { const n = new Set(p); n.delete(key); return n; });
    }
  }, [account, publish, refresh]);

  const addArxiv = useCallback((sourceID: string, revision: number | null) => command('add', () => ({
    endpoint: 'v2_begin_import', p_source_id: sourceID, p_requested_revision: revision, p_observed_cursor: reconciler.current.committed ?? 0,
  })), [command]);
  const retry = useCallback((i: Import) => command(i.id, () => ({ endpoint: 'v2_retry_import', p_import_id: i.id, p_expected_revision: i.intent_revision })), [command]);
  const remove = useCallback((i: Import) => command(i.id, () => ({ endpoint: 'v2_cancel_import', p_import_id: i.id, p_expected_revision: i.intent_revision })), [command]);

  return { entries, state, marks, now, pending, refresh, addArxiv, retry, remove };
}
