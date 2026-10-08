// IndexedDB access with a shared storage-lifecycle signal (docs/architecture/BROWSER_OFFLINE_STORAGE.md, "Next
// implementation checkpoint: compatibility only"). Values are structured clones, so non-extractable CryptoKeys are
// stored as keys (usable after reload, never readable as bytes).
//
// This release keeps database version 1 and its two stores. When a newer Gradstep tab changes the database, this page
// retires its connection cooperatively: transactions it already accepted finish, the connection closes, and every later
// request from this page is refused with an explanation. It never reopens, reloads, deletes or upgrades storage itself.

const NAME = 'gradstep', VERSION = 1;
export type Store = 'devices' | 'activity';

/**
 * - `update`: another tab is changing the database (an upgrade); this page has stopped using it.
 * - `upgraded`: the database is newer than this page understands; reloading picks up the newer release.
 * - `blocked`: this page is waiting for an older tab to release the database (the request keeps waiting).
 * - `closed`: the browser closed or deleted the database (for example, site data was cleared).
 */
export type StorageIssue = 'update' | 'upgraded' | 'blocked' | 'closed';
export interface StorageLifecycle {
  /** `retiring`: refusing new work while transactions accepted earlier finish. `retired`: closed for this page. */
  readonly phase: 'open' | 'retiring' | 'retired';
  readonly issue: StorageIssue | null;
  /** Another tab proposed a storage update and this tab asked it to wait, because it holds unsent work. */
  readonly proposal: boolean;
}
export type StorageErrorCode = 'storage_update' | 'storage_upgraded' | 'storage_blocked' | 'storage_closed' | 'storage_unavailable';
export class StorageError extends Error { constructor(readonly code: StorageErrorCode) { super(code); } }

let lifecycle: StorageLifecycle = { phase: 'open', issue: null, proposal: false };
const listeners = new Set<() => void>();
function update(next: Partial<StorageLifecycle>) {
  const merged = { ...lifecycle, ...next };
  if (merged.phase === lifecycle.phase && merged.issue === lifecycle.issue && merged.proposal === lifecycle.proposal) return;
  lifecycle = merged;
  for (const listener of [...listeners]) listener();
}
function refusal(): StorageError {
  switch (lifecycle.issue) {
    case 'update': return new StorageError('storage_update');
    case 'upgraded': return new StorageError('storage_upgraded');
    case 'closed': return new StorageError('storage_closed');
    default: return new StorageError('storage_unavailable');
  }
}

let connection: Promise<IDBDatabase> | null = null;
/** Transactions created on this page's connection that have not yet completed or aborted. */
let active = 0;
function settle() { if (lifecycle.phase === 'retiring' && active === 0) update({ phase: 'retired' }); }
function retire(issue: 'update' | 'closed', db: IDBDatabase | null) {
  if (lifecycle.phase !== 'open') return;
  update({ phase: 'retiring', issue, proposal: false });
  // close() lets every transaction already created complete, then closes; no new transaction can start.
  db?.close();
  settle();
}

function database(): Promise<IDBDatabase> {
  if (lifecycle.phase !== 'open') return Promise.reject(refusal());
  connection ??= new Promise<IDBDatabase>((resolve, reject) => {
    let request: IDBOpenDBRequest;
    try { request = indexedDB.open(NAME, VERSION); } catch { connection = null; reject(new StorageError('storage_unavailable')); return; }
    request.onupgradeneeded = () => {
      for (const store of ['devices', 'activity']) if (!request.result.objectStoreNames.contains(store)) request.result.createObjectStore(store);
    };
    // An older connection elsewhere has not closed yet. Keep waiting (never delete); the page explains what to close.
    request.onblocked = () => { if (lifecycle.phase === 'open') update({ issue: 'blocked' }); };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = event => retire(event.newVersion === null ? 'closed' : 'update', db);
      db.onclose = () => retire('closed', null);
      if (lifecycle.issue === 'blocked') update({ issue: null });
      resolve(db);
    };
    request.onerror = () => {
      if (request.error?.name === 'VersionError') {
        // A newer release already changed the database. Never retry, downgrade or delete it from this page.
        update({ phase: 'retired', issue: 'upgraded', proposal: false });
        reject(refusal());
        return;
      }
      connection = null;
      if (lifecycle.issue === 'blocked') update({ issue: null });
      reject(new StorageError('storage_unavailable'));
    };
  });
  return connection;
}

/** One transaction. Success is reported on completion, never on a request's success. */
function run<T>(stores: Store | Store[], mode: IDBTransactionMode, body: (tx: IDBTransaction) => () => T): Promise<T> {
  return database().then(db => new Promise<T>((resolve, reject) => {
    // A callback that resumes after retirement is refused, even though it began earlier.
    if (lifecycle.phase !== 'open') { reject(refusal()); return; }
    let tx: IDBTransaction;
    try { tx = db.transaction(stores, mode, mode === 'readwrite' ? { durability: 'strict' } : undefined); }
    catch { reject(lifecycle.phase !== 'open' ? refusal() : new StorageError('storage_unavailable')); return; }
    active++;
    let finished = false;
    const finish = () => { if (!finished) { finished = true; active--; settle(); } };
    let result: () => T;
    try { result = body(tx); } catch { try { tx.abort(); } catch { /* already finished */ } finish(); reject(new StorageError('storage_unavailable')); return; }
    tx.oncomplete = () => { finish(); resolve(result()); };
    tx.onerror = tx.onabort = () => { finish(); reject(new StorageError('storage_unavailable')); };
  }));
}

export const idb = {
  get: <T>(store: Store, key: string) => run<T | undefined>(store, 'readonly', tx => {
    const request = tx.objectStore(store).get(key);
    return () => request.result as T | undefined;
  }),
  put: (store: Store, key: string, value: unknown) => run<void>(store, 'readwrite', tx => { tx.objectStore(store).put(value, key); return () => undefined; }),
  delete: (store: Store, key: string) => run<void>(store, 'readwrite', tx => { tx.objectStore(store).delete(key); return () => undefined; }),
  /** A delayed encrypted save must not recreate data after its device was forgotten or replaced. */
  putActivity: (key: string, deviceID: string, value: unknown) => run<void>(['devices', 'activity'], 'readwrite', tx => {
    const device = tx.objectStore('devices').get(key);
    device.onsuccess = () => { if ((device.result as { deviceID?: string } | undefined)?.deviceID === deviceID) tx.objectStore('activity').put(value, key); };
    return () => undefined;
  }),
  forgetDevice: (key: string) => run<void>(['devices', 'activity'], 'readwrite', tx => {
    tx.objectStore('devices').delete(key); tx.objectStore('activity').delete(key);
    return () => undefined;
  }),
};

// ---------- Cooperative update handshake ----------
// A newer release proposes a storage update over a BroadcastChannel before changing the database. Messages carry only
// random IDs and flags, never private text. A tab with unsent work asks it to wait and explains what to do. A reply is a
// hint: it cannot prove that every tab answered (older releases never do), so a newer release still needs the person to
// confirm they finished or copied their work and closed other tabs.

const CHANNEL = 'gradstep.storage';
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export interface UpgradeProposal { kind: 'upgrade-proposal'; proposal: string; version: number }
export interface UpgradeReply { kind: 'upgrade-reply'; proposal: string; ready: boolean }
const works = new Set<() => boolean>();
let channel: BroadcastChannel | null = null;
let lastProposal: string | null = null;
const busy = () => [...works].some(check => { try { return check(); } catch { return true; } });

function reply(proposal: string) {
  const ready = !busy();
  if (lifecycle.phase === 'open') update({ proposal: !ready });
  try { channel?.postMessage({ kind: 'upgrade-reply', proposal, ready } satisfies UpgradeReply); } catch { /* channel closed */ }
}
function listen() {
  if (channel || typeof BroadcastChannel === 'undefined') return;
  channel = new BroadcastChannel(CHANNEL);
  (channel as unknown as { unref?: () => void }).unref?.(); // Node test runtime: never keep the process alive
  channel.onmessage = event => {
    const data = event.data as Partial<UpgradeProposal> | null;
    if (!data || data.kind !== 'upgrade-proposal' || typeof data.proposal !== 'string' || !ID.test(data.proposal)
      || !Number.isSafeInteger(data.version) || (data.version as number) <= VERSION) return;
    lastProposal = data.proposal;
    reply(data.proposal);
  };
}

export const storage = {
  version: VERSION,
  snapshot: (): StorageLifecycle => lifecycle,
  subscribe(listener: () => void): () => void { listeners.add(listener); return () => { listeners.delete(listener); }; },
  /** Whether this page may start new local writes, sends or consent continuations. */
  writable: () => lifecycle.phase === 'open',
  /** Registers a check for unsent work in this page, consulted when another tab proposes an update. */
  registerWork(check: () => boolean): () => void {
    listen();
    works.add(check);
    return () => { works.delete(check); storage.reviewProposal(); };
  },
  /** After this page's work changes: tell a waiting newer tab once nothing remains, and clear the notice. */
  reviewProposal() { if (lastProposal && lifecycle.proposal && !busy()) reply(lastProposal); },
};
