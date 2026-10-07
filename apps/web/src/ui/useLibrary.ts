// Account-scoped library state: one bounded pull at a time, import polling on the native
// schedule, refresh on focus, and commands with operation-ID replay. Memory only.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { auth, BackendError } from '../lib/backend';
import { cancellation } from '../lib/cancellation';
import { type Command, type CommandResponse, type Entry, type Import, CommandRefreshError, receiptFloor, Reconciler, sendCommand } from '../lib/library';
import { type Mark, importStep, observe, pollDelay, retryingAutomatically } from '../lib/progress';

export type LoadState = 'loading' | 'ready' | 'error';

export function useLibrary(account: string) {
  const reconciler = useRef(new Reconciler(account));
  const running = useRef<Promise<void> | null>(null);
  const lifetime = useRef<ReturnType<typeof cancellation> | null>(null);
  const pendingKeys = useRef(new Map<string, object>());
  const receipts = useRef(new Map<string, { response: CommandResponse; owner: object }>());
  // The cursor belongs to the rendered complete snapshot, never the reconciler's partial work.
  const [snapshot, setSnapshot] = useState<{ entries: Entry[]; cursor: number | null }>({ entries: [], cursor: null });
  const { entries } = snapshot;
  const [state, setState] = useState<LoadState>('loading');
  const [marks, setMarks] = useState<Map<string, Mark>>(new Map());
  const [pending, setPending] = useState<Set<string>>(new Set());

  const publish = useCallback(() => {
    const list = [...reconciler.current.entries.values()];
    // Reconciliation preserves unchanged entry objects. Empty catch-up responses must not rebuild
    // the table, its search index and every row while an unrelated import is being polled.
    const cursor = reconciler.current.committed;
    setSnapshot(previous => {
      const entries = previous.entries.length === list.length && previous.entries.every((entry, i) => entry === list[i]) ? previous.entries : list;
      return entries === previous.entries && cursor === previous.cursor ? previous : { entries, cursor };
    });
    setMarks(previous => {
      const next = observe(previous, list.filter((e): e is Import => e.kind === 'import'), Date.now());
      return next.size === previous.size && [...next].every(([id, mark]) => previous.get(id) === mark) ? previous : next;
    });
  }, []);

  const refresh = useCallback((): Promise<void> => {
    const owner = lifetime.current;
    if (!owner || owner.signal.aborted) return Promise.reject(new BackendError('cancelled'));
    if (running.current) return running.current;
    // Only receipts already owned when this pull starts can be satisfied by its fresh boundary.
    const observedReceipts = [...receipts.current];
    const minimumCursor = Math.max(0, ...observedReceipts.map(([, receipt]) => receiptFloor(receipt.response)));
    const task = (async () => {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          await reconciler.current.pull(owner.signal, minimumCursor, observedReceipts.length > 0);
          if (owner.signal.aborted) return;
          for (const [, receipt] of observedReceipts) reconciler.current.requireReceipt(receipt.response);
          publish(); setState('ready');
          for (const [key, receipt] of observedReceipts) if (receipts.current.get(key) === receipt) {
            receipts.current.delete(key);
            if (pendingKeys.current.get(key) === receipt.owner) pendingKeys.current.delete(key);
          }
          setPending(previous => {
            const next = new Set([...previous].filter(key => pendingKeys.current.has(key)));
            return next.size === previous.size ? previous : next;
          });
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

  // Imports under way: poll fast at first, then slower (native importPollDelay).
  // Visible import rows own their clocks; ticking a progress bar must not render the whole library.
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
    return () => { disposed = true; clearTimeout(timer); };
  }, [active, refresh]);

  const command = useCallback(async (key: string, request: Command) => {
    const owner = lifetime.current;
    if (!owner || owner.signal.aborted) throw new BackendError('cancelled');
    if (pendingKeys.current.has(key)) throw new BackendError('library_command_pending');
    const intent = {};
    pendingKeys.current.set(key, intent);
    setPending(p => new Set(p).add(key));
    try {
      const response = await sendCommand(account, request, undefined, owner.signal);
      owner.signal.throwIfAborted();
      // The response contains only one entity from a possibly grouped transition. It is a
      // catch-up requirement, never a library update or authority to advance the account cursor.
      const receipt = { response, owner: intent };
      receipts.current.set(key, receipt);
      try {
        // Do not reuse a read that started before the response. Another command can start a
        // pull while we wait; each command still gets a cycle begun after its own receipt.
        while (receipts.current.get(key) === receipt && running.current) {
          await running.current.catch(() => {}); owner.signal.throwIfAborted();
        }
        if (receipts.current.get(key) === receipt) await refresh();
      } catch (error) {
        if (owner.signal.aborted) throw error;
        // Keep the pending receipt and last complete presentation; a later refresh resolves it
        // without submitting the mutation again. This queue is session-memory only (Phase 1).
        throw new CommandRefreshError(response);
      }
      if (response.result.status === 'revision_conflict') throw new BackendError('library_revision_conflict');
      return response;
    } finally {
      if (!owner.signal.aborted && pendingKeys.current.get(key) === intent && !receipts.current.has(key)) {
        pendingKeys.current.delete(key);
        setPending(p => { const n = new Set(p); n.delete(key); return n; });
      }
    }
  }, [account, refresh]);

  const addArxiv = useCallback((sourceID: string, revision: number | null) => {
    if (snapshot.cursor === null) return Promise.reject(new BackendError('library_not_ready'));
    return command('add', {
      endpoint: 'v2_begin_import', p_source_id: sourceID, p_requested_revision: revision, p_observed_cursor: snapshot.cursor,
    });
  }, [command, snapshot.cursor]);
  const retry = useCallback((i: Import) => command(i.id, { endpoint: 'v2_retry_import', p_import_id: i.id, p_expected_revision: i.intent_revision }), [command]);
  const remove = useCallback((i: Import) => command(i.id, { endpoint: 'v2_cancel_import', p_import_id: i.id, p_expected_revision: i.intent_revision }), [command]);

  return { entries, state, marks, pending, refresh, addArxiv, retry, remove };
}
