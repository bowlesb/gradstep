import type { LibraryPaper, ClientEntry } from '../lib/device-pdf';
import type { DevicePDFs } from './useDevicePDFs';
import type { CatalogController } from './useCatalogs';
import { arxivCatalogKey, entryCatalogKey } from '../lib/library-catalogs';
import { type ReaderPaper } from '../lib/reader-paper';
import { isUUID } from '../lib/bytes';
// Account-scoped library state: one bounded pull at a time, import polling on the native
// schedule, refresh on focus, and commands with operation-ID replay. Memory only.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { auth, BackendError, rpc } from '../lib/backend';
import { cancellation } from '../lib/cancellation';
import { type Command, type CommandResponse, type Entry, type Import, type Item, CommandRefreshError, receiptFloor, Reconciler, sendCommand } from '../lib/library';
import { editedTags } from '../lib/paper-tags';
import { type Mark, importStep, observe, pollDelay, retryingAutomatically } from '../lib/progress';
import { backoffDelay, jittered, retryAfterMs } from '../lib/retry';

export type LoadState = 'loading' | 'ready' | 'error';

export function useLibrary(account: string, devicePDFs?:DevicePDFs, catalogs?:CatalogController) {
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

  // Consecutive failed pulls and the server's last requested wait: polls slow down while the server struggles and
  // add jitter while it's healthy, so browsers don't come back in step (RESILIENCE.md fix 8).
  const failures = useRef(0), serverWait = useRef<number | undefined>(undefined);
  const pull = useCallback(() => refresh().then(() => { failures.current = 0; serverWait.current = undefined; },
    error => { failures.current += 1; serverWait.current = retryAfterMs(error); throw error; }), [refresh]);
  const nextDelay = useCallback((cadenceMs: number) => failures.current === 0 ? jittered(cadenceMs)
    : backoffDelay(failures.current, Math.max(cadenceMs, 4_000), 300_000, serverWait.current), []);

  useEffect(() => {
    const owner = cancellation([auth.snapshot().signal]);
    lifetime.current = owner;
    running.current = null;
    failures.current = 0;
    pull().catch(() => {});
    const focus = () => { if (document.visibilityState === 'visible') pull().catch(() => {}); };
    document.addEventListener('visibilitychange', focus);
    window.addEventListener('focus', focus);
    let slow: ReturnType<typeof setTimeout>;
    const schedule = () => { slow = setTimeout(() => { focus(); schedule(); }, nextDelay(60_000)); };
    schedule();
    return () => { owner.abort(); document.removeEventListener('visibilitychange', focus); window.removeEventListener('focus', focus); clearTimeout(slow); };
  }, [pull, nextDelay]);

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
        if (document.visibilityState === 'visible') await pull().catch(() => {});
        tick();
      }, nextDelay(pollDelay((Date.now() - started) / 1000) * 1000));
    };
    tick();
    return () => { disposed = true; clearTimeout(timer); };
  }, [active, pull, nextDelay]);

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

  const addArxiv = useCallback(async (sourceID: string, revision: number | null) => {
    if (snapshot.cursor === null) return Promise.reject(new BackendError('library_not_ready'));
    // The same paper never joins twice (build 75: two "TreeCut" rows): any version of it already here is the paper.
    if (existingArxiv(entries, sourceID)) throw new BackendError('library_already_present');
    if (pendingKeys.current.has('add')) throw new BackendError('library_command_pending');
    const key = arxivCatalogKey(sourceID);
    if (key && catalogs && !entries.some(e => e.visible && entryCatalogKey(e) === key)) await catalogs.assign(key);
    return command('add', {
      endpoint: 'v2_begin_import', p_source_id: sourceID, p_requested_revision: revision, p_observed_cursor: snapshot.cursor,
    });
  }, [command, snapshot.cursor, catalogs, entries]);
  const retry = useCallback((i: Import) => command(i.id, { endpoint: 'v2_retry_import', p_import_id: i.id, p_expected_revision: i.intent_revision }), [command]);
  const remove = useCallback((i: Import) => command(i.id, { endpoint: 'v2_cancel_import', p_import_id: i.id, p_expected_revision: i.intent_revision }), [command]);
  // These v2 commands belong to the current public-library path. Private uploads need the
  // separately reviewed v5 client and must not be enabled by adding a menu to generic Item rows.
  const itemCommand = useCallback((item: Item, request: Command) => !item.visible || item.scope !== 'shared_catalog'
    ? Promise.reject(new BackendError('item_unavailable')) : command(item.id, request), [command]);
  const sourceDetails = useCallback(async (item: ReaderPaper, archived: boolean, tags: string[]) => {
    if (item.kind !== 'import' || !item.visible) throw new BackendError('item_unavailable');
    const signal=lifetime.current?.signal;
    const caps=await rpc<{account_id:string;library:{dataset_epoch:string};device_reader?:{protocol:string}}>('v1_reader_capabilities',{}, {account,signal});
    if (signal?.aborted || caps.account_id !== account || caps.device_reader?.protocol !== 'source-membership-v1' || !isUUID(caps.library?.dataset_epoch)) throw new BackendError('reader_upgrade_required');
    return command(item.id,{endpoint:'v5_set_source_details',p_dataset_epoch:caps.library.dataset_epoch,p_import_id:item.id,p_archived:archived,p_tags:tags,p_expected_revision:item.intent_revision});
  },[account,command]);
  const archive = useCallback((item: LibraryPaper, archived: boolean) => item.kind === 'local_pdf' ? devicePDFs!.mutate(item,{archived}) : item.kind === 'import' ? sourceDetails(item,archived,item.user_tags??[]) : itemCommand(item, { endpoint: 'v2_set_item_archived', expectedItemID: item.id,
    p_document_id: item.document_id, p_archived: archived, p_expected_revision: item.membership_revision }), [itemCommand,sourceDetails,devicePDFs]);
  const removePaper = useCallback((item: LibraryPaper) => item.kind === 'local_pdf' ? devicePDFs!.mutate(item,{remove:true}) : item.kind === 'import' ? command(item.id,{endpoint:'v2_cancel_import',p_import_id:item.id,p_expected_revision:item.intent_revision}) : itemCommand(item, { endpoint: 'v2_set_library_item', expectedItemID: item.id,
    p_document_id: item.document_id, p_present: false, p_expected_revision: item.membership_revision }), [itemCommand,command,devicePDFs]);
  const setTags = useCallback((item: LibraryPaper, desired: string[]) => {
    if(item.kind==='local_pdf')return devicePDFs!.mutate(item,{tags:desired});
    if (item.kind === 'import') return sourceDetails(item,item.archived===true,desired);
    const change = editedTags(item.tags ?? [], desired);
    return itemCommand(item, { endpoint: 'v2_set_item_tags', expectedItemID: item.id, p_document_id: item.document_id,
      p_tags: change.own, p_hidden_tags: change.hidden, p_expected_revision: item.membership_revision });
  }, [itemCommand,sourceDetails,devicePDFs]);

  const present = useCallback((sourceID: string) => existingArxiv(entries, sourceID), [entries]);
  const displayed:ClientEntry[]=useMemo(()=>[...entries,...(devicePDFs?.rows??[])],[entries,devicePDFs?.rows]);
  const latest = useRef(displayed); latest.current = displayed;
  const catalogEntries = (id: string) => {
    const state = catalogs?.currentState();
    return [...new Map(latest.current.filter(e => e.visible && state?.catalogFor(entryCatalogKey(e)) === id).map(e => [entryCatalogKey(e), e])).values()];
  };
  const deleteCatalogPapers = async (id: string, progress: (done: number, total: number) => void) => {
    if (!catalogs?.ready) throw Error('Unlock your library before changing catalogs.');
    const owner = lifetime.current; if (!owner || owner.signal.aborted) throw new BackendError('cancelled');
    // Capture exactly the confirmed papers and revision preconditions. New arrivals never join this batch.
    const plan = latest.current.filter(e => e.visible && catalogs.currentState().catalogFor(entryCatalogKey(e)) === id);
    for (const [i, entry] of plan.entries()) {
      owner.signal.throwIfAborted();
      if (catalogs.currentState().catalogFor(entryCatalogKey(entry)) !== id) continue;
      if (entry.kind !== 'local_pdf' && !reconciler.current.entries.get(entry.kind + ':' + entry.id)?.visible) continue;
      if (pendingKeys.current.has(entry.id)) throw Error('A paper change is still syncing. The catalog is still here with its remaining papers.');
      progress(i + 1, plan.length);
      if (entry.kind === 'import') await remove(entry); else await removePaper(entry);
    }
    owner.signal.throwIfAborted();
    // Reconciler is authoritative immediately after catch-up, before React publishes its render.
    const remaining = [...reconciler.current.entries.values()].some(e => e.visible && catalogs.currentState().catalogFor(entryCatalogKey(e)) === id);
    const localRemaining = catalogEntries(id).some(e => e.kind === 'local_pdf' && !plan.some(p => p.id === e.id));
    if (remaining || localRemaining) throw Error('Papers were added to this catalog during deletion. Review the remaining papers before deleting it.');
    const destination = catalogs.currentState().catalogs.find(c => c.id !== id)?.id;
    await catalogs.retire(id, destination, destination ? undefined : 'Default');
  };
  return { ...(catalogs ? { catalogs } : {}), catalogEntries, deleteCatalogPapers, entries:displayed, serverEntries:entries, cursor: snapshot.cursor, state, marks, pending, refresh, present, addArxiv, retry, remove, archive, removePaper, setTags };
}

/** The visible library entry for this arXiv paper (any version), unless it was cancelled: adding it again would only
 * duplicate it (build 75). The server's own idempotency is separate. */
export function existingArxiv(entries: readonly Entry[], sourceID: string): Entry | undefined {
  return entries.find(e => e.visible && e.source === 'arxiv' && e.source_id === sourceID && !(e.kind === 'import' && e.phase === 'cancelled'));
}
