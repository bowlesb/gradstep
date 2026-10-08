// IndexedDB access with a shared storage-lifecycle signal (docs/architecture/BROWSER_OFFLINE_STORAGE.md). Values are
// structured clones, so non-extractable CryptoKeys are stored as keys (usable after reload, never readable as bytes).
//
// Database `gradstep`: version 1 has `devices` and `activity`; version 2 adds `journal` (the encrypted private journal,
// lib/journal.ts). A browser with no Gradstep database starts at version 2. An existing version-1 profile stays at
// version 1 until the person confirms they finished or copied work in every other Gradstep tab and closed them; only
// then does `activateJournal` upgrade it. An unconfirmed upgrade is aborted, never forced.
//
// When another tab changes the database, this page retires its connection cooperatively: transactions it already
// accepted finish, the connection closes, and every later request from this page is refused with an explanation. It
// never reopens, reloads, deletes or downgrades storage by itself.
import type { Bytes } from './bytes';

const NAME = 'gradstep', LEGACY = 1, VERSION = 2;
export type Store = 'devices' | 'activity' | 'journal';

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
  /** The connected database version: 2 when the encrypted journal is available; null before opening. */
  readonly version: number | null;
}
export type StorageErrorCode = 'storage_update' | 'storage_upgraded' | 'storage_blocked' | 'storage_closed' | 'storage_unavailable' | 'storage_quota';
export class StorageError extends Error { constructor(readonly code: StorageErrorCode) { super(code); } }

let lifecycle: StorageLifecycle = { phase: 'open', issue: null, proposal: false, version: null };
const listeners = new Set<() => void>();
function update(next: Partial<StorageLifecycle>) {
  const merged = { ...lifecycle, ...next };
  if (merged.phase === lifecycle.phase && merged.issue === lifecycle.issue && merged.proposal === lifecycle.proposal && merged.version === lifecycle.version) return;
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
/** Set only while the person-confirmed activation upgrades this profile from version 1. */
let activating = false;
function settle() { if (lifecycle.phase === 'retiring' && active === 0) update({ phase: 'retired' }); }
function retire(issue: 'update' | 'closed', db: IDBDatabase | null) {
  if (lifecycle.phase !== 'open') return;
  update({ phase: 'retiring', issue, proposal: false });
  // close() lets every transaction already created complete, then closes; no new transaction can start.
  db?.close();
  settle();
}

/** The database's current version without opening it (0 when absent), or null when the browser can't say. */
async function existingVersion(): Promise<number | null> {
  try {
    if (typeof indexedDB.databases !== 'function') return null;
    const found = (await indexedDB.databases()).find(d => d.name === NAME);
    return found?.version ?? 0;
  } catch { return null; }
}

function openAt(version: number | undefined): Promise<IDBDatabase> {
  return new Promise<IDBDatabase>((resolve, reject) => {
    let request: IDBOpenDBRequest, refused = false;
    try { request = version === undefined ? indexedDB.open(NAME) : indexedDB.open(NAME, version); } catch { reject(new StorageError('storage_unavailable')); return; }
    request.onupgradeneeded = event => {
      const db = request.result;
      // Never upgrade an existing version-1 profile without the person's confirmation (activateJournal).
      if (event.oldVersion === LEGACY && !activating) { refused = true; request.transaction?.abort(); return; }
      for (const store of ['devices', 'activity']) if (!db.objectStoreNames.contains(store)) db.createObjectStore(store);
      if (db.version >= VERSION && !db.objectStoreNames.contains('journal')) db.createObjectStore('journal');
    };
    // An older connection elsewhere has not closed yet. Keep waiting (never delete); the page explains what to close.
    request.onblocked = () => { if (lifecycle.phase === 'open') update({ issue: 'blocked' }); };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = event => retire(event.newVersion === null ? 'closed' : 'update', db);
      db.onclose = () => retire('closed', null);
      update({ version: db.version, ...(lifecycle.issue === 'blocked' ? { issue: null } : {}) });
      resolve(db);
    };
    request.onerror = () => {
      if (lifecycle.issue === 'blocked') update({ issue: null });
      if (refused) { resolve(openAt(LEGACY)); return; } // another tab created version 1 meanwhile: stay there
      if (request.error?.name === 'VersionError') {
        // A newer release already changed the database. Never retry, downgrade or delete it from this page.
        update({ phase: 'retired', issue: 'upgraded', proposal: false });
        reject(refusal());
        return;
      }
      reject(new StorageError('storage_unavailable'));
    };
  });
}

function database(): Promise<IDBDatabase> {
  if (lifecycle.phase !== 'open') return Promise.reject(refusal());
  connection ??= (async () => {
    const existing = await existingVersion();
    if (existing !== null && existing > VERSION) { update({ phase: 'retired', issue: 'upgraded', proposal: false }); throw refusal(); }
    // A version-1 profile stays at version 1 until activation; unknown means open whatever exists (or create version 1).
    return openAt(existing === LEGACY ? LEGACY : existing === null ? undefined : VERSION);
  })().catch(error => { if (lifecycle.phase === 'open') connection = null; throw error; });
  return connection;
}

/** One transaction. Success is reported on completion, never on a request's success. `cancel` aborts deliberately. */
function run<T>(stores: Store[] | ((db: IDBDatabase) => Store[]), mode: IDBTransactionMode,
  body: (tx: IDBTransaction, cancel: () => void) => () => T, retried = false): Promise<T> {
  const pending = database();
  return pending.then(db => new Promise<T>((resolve, reject) => {
    // A callback that resumes after retirement is refused, even though it began earlier.
    if (lifecycle.phase !== 'open') { reject(refusal()); return; }
    let tx: IDBTransaction;
    try { tx = db.transaction(typeof stores === 'function' ? stores(db) : stores, mode, mode === 'readwrite' ? { durability: 'strict' } : undefined); }
    catch {
      // This page's own activation replaced the connection meanwhile: use the new one once.
      if (!retried && connection && connection !== pending && lifecycle.phase === 'open') { resolve(run(stores, mode, body, true)); return; }
      reject(lifecycle.phase !== 'open' ? refusal() : new StorageError('storage_unavailable')); return;
    }
    active++;
    let finished = false, cancelled = false;
    const finish = () => { if (!finished) { finished = true; active--; settle(); } };
    let result: () => T;
    try { result = body(tx, () => { cancelled = true; tx.abort(); }); }
    catch { try { tx.abort(); } catch { /* already finished */ } finish(); reject(new StorageError('storage_unavailable')); return; }
    tx.oncomplete = () => { finish(); resolve(result()); };
    tx.onerror = event => { if (cancelled) event.preventDefault(); };
    tx.onabort = () => {
      finish();
      if (cancelled) { resolve(result()); return; }
      reject(new StorageError(tx.error?.name === 'QuotaExceededError' ? 'storage_quota' : 'storage_unavailable'));
    };
  }));
}

export const idb = {
  get: <T>(store: Store, key: string) => run<T | undefined>([store], 'readonly', tx => {
    const request = tx.objectStore(store).get(key);
    return () => request.result as T | undefined;
  }),
  put: (store: Store, key: string, value: unknown) => run<void>([store], 'readwrite', tx => { tx.objectStore(store).put(value, key); return () => undefined; }),
  delete: (store: Store, key: string) => run<void>([store], 'readwrite', tx => { tx.objectStore(store).delete(key); return () => undefined; }),
  /** A delayed encrypted save must not recreate data after its device was forgotten or replaced. */
  putActivity: (key: string, deviceID: string, value: unknown) => run<void>(['devices', 'activity'], 'readwrite', tx => {
    const device = tx.objectStore('devices').get(key);
    device.onsuccess = () => { if ((device.result as { deviceID?: string } | undefined)?.deviceID === deviceID) tx.objectStore('activity').put(value, key); };
    return () => undefined;
  }),
  /** Removes the device, its reading data and its whole journal partition in one transaction. */
  forgetDevice: (key: string) => run<void>(db => db.objectStoreNames.contains('journal') ? ['devices', 'activity', 'journal'] : ['devices', 'activity'], 'readwrite', tx => {
    tx.objectStore('devices').delete(key); tx.objectStore('activity').delete(key);
    if (tx.objectStoreNames.contains('journal')) tx.objectStore('journal').delete(IDBKeyRange.bound(`${key}:`, `${key}:￿`));
    return () => undefined;
  }),
};

/** Raw access for lib/journal.ts: reads, and a compare-and-swap commit fenced by the exact device record. */
export interface JournalAccess {
  get(key: string): Promise<Bytes | undefined>;
  range(lower: string, upper: string): Promise<[string, Bytes][]>;
  commit(headKey: string, expected: Bytes | null, put: [string, Bytes][], remove: string[], device?: { key: string; deviceID: string }): Promise<'committed' | 'conflict' | 'fenced'>;
}
const sameBytes = (a: unknown, b: Uint8Array | null) => {
  if (b === null) return a === undefined;
  if (!(a instanceof Uint8Array) || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
};
export const journalAccess: JournalAccess = {
  get: key => run<Bytes | undefined>(['journal'], 'readonly', tx => { const r = tx.objectStore('journal').get(key); return () => r.result as Bytes | undefined; }),
  range: (lower, upper) => run<[string, Bytes][]>(['journal'], 'readonly', tx => {
    const store = tx.objectStore('journal'), range = IDBKeyRange.bound(lower, upper);
    const names = store.getAllKeys(range), values = store.getAll(range);
    return () => names.result.map((name, i) => [name as string, values.result[i] as Bytes]);
  }),
  commit: (headKey, expected, put, remove, device) => {
    let outcome: 'committed' | 'conflict' | 'fenced' = 'committed';
    return run<'committed' | 'conflict' | 'fenced'>(['devices', 'journal'], 'readwrite', (tx, cancel) => {
      const journal = tx.objectStore('journal');
      const owner = device ? tx.objectStore('devices').get(device.key) : null;
      const head = journal.get(headKey);
      head.onsuccess = () => {
        if (device && (owner!.result as { deviceID?: string } | undefined)?.deviceID !== device.deviceID) { outcome = 'fenced'; cancel(); return; }
        if (!sameBytes(head.result, expected)) { outcome = 'conflict'; cancel(); return; }
        for (const key of remove) journal.delete(key);
        for (const [key, value] of put) journal.put(value, key);
      };
      return () => outcome;
    });
  },
};

// ---------- Cooperative update handshake ----------
// A newer release proposes a storage update over a BroadcastChannel before changing the database. Messages carry only
// random IDs and flags, never private text. A tab with unsent work asks it to wait and explains what to do. A reply is a
// hint: it cannot prove that every tab answered (older releases never do), so an upgrade still needs the person to
// confirm they finished or copied their work and closed other tabs.

const CHANNEL = 'gradstep.storage';
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export interface UpgradeProposal { kind: 'upgrade-proposal'; proposal: string; version: number }
export interface UpgradeReply { kind: 'upgrade-reply'; proposal: string; ready: boolean }
const works = new Set<() => boolean>();
let channel: BroadcastChannel | null = null;
let lastProposal: string | null = null;
const replyWaiters = new Set<(reply: UpgradeReply) => void>();
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
    const data = event.data as { kind?: unknown; proposal?: unknown; ready?: unknown; version?: unknown } | null;
    if (data?.kind === 'upgrade-reply' && typeof data.proposal === 'string' && typeof data.ready === 'boolean') {
      for (const waiter of [...replyWaiters]) waiter({ kind: 'upgrade-reply', proposal: data.proposal, ready: data.ready });
      return;
    }
    if (!data || data.kind !== 'upgrade-proposal' || typeof data.proposal !== 'string' || !ID.test(data.proposal)
      || !Number.isSafeInteger(data.version) || (data.version as number) <= (lifecycle.version ?? LEGACY)) return;
    lastProposal = data.proposal;
    reply(data.proposal);
  };
}

/**
 * Turns on the encrypted journal for an existing version-1 profile. Call only after the person confirmed they finished
 * or copied unsent work in every other Gradstep tab and closed them. A tab that answers with unsent work defers it
 * (`deferred`); an older tab that keeps its connection makes the upgrade wait (`blocked` issue) until it closes.
 */
export async function activateJournal(wait = 900): Promise<'active' | 'deferred'> {
  const db = await database();
  if (db.version >= VERSION) return 'active';
  listen();
  const proposal = crypto.randomUUID(), replies: UpgradeReply[] = [];
  const collect = (r: UpgradeReply) => { if (r.proposal === proposal) replies.push(r); };
  replyWaiters.add(collect);
  try { channel?.postMessage({ kind: 'upgrade-proposal', proposal, version: VERSION } satisfies UpgradeProposal); } catch { /* closed */ }
  await new Promise(resolve => setTimeout(resolve, wait));
  replyWaiters.delete(collect);
  if (replies.some(r => !r.ready)) return 'deferred';
  if (lifecycle.phase !== 'open') throw refusal();
  // Close this page's own version-1 connection without retiring the page; waiting requests use the new connection.
  activating = true;
  db.onversionchange = null; db.onclose = null; db.close();
  connection = openAt(VERSION).finally(() => { activating = false; });
  try { await connection; } catch (error) { connection = null; throw error; }
  return 'active';
}

export const storage = {
  version: VERSION,
  snapshot: (): StorageLifecycle => lifecycle,
  subscribe(listener: () => void): () => void { listeners.add(listener); return () => { listeners.delete(listener); }; },
  /** Whether this page may start new local writes, sends or consent continuations. */
  writable: () => lifecycle.phase === 'open',
  /** Opens the database (if needed) and reports whether the encrypted journal store exists. */
  async journalReady(): Promise<boolean> { return (await database()).version >= VERSION; },
  /** Registers a check for unsent work in this page, consulted when another tab proposes an update. */
  registerWork(check: () => boolean): () => void {
    listen();
    works.add(check);
    return () => { works.delete(check); storage.reviewProposal(); };
  },
  /** After this page's work changes: tell a waiting newer tab once nothing remains, and clear the notice. */
  reviewProposal() { if (lastProposal && lifecycle.proposal && !busy()) reply(lastProposal); },
};
