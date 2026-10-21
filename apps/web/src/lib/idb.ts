// IndexedDB access with a shared storage-lifecycle signal (docs/architecture/BROWSER_OFFLINE_STORAGE.md). Values are
// structured clones, so non-extractable CryptoKeys are stored as keys (usable after reload, never readable as bytes).
//
// Database `gradstep`: version 1 has `devices` and `activity`; version 2 adds `journal` (the encrypted private journal,
// lib/journal.ts); version 3 adds the three encrypted library domains. A browser with no Gradstep database starts at
// version 2. Existing profiles stay at their current version until the person confirms they finished or copied work
// in every other Gradstep tab and closed them; only then do the explicit activation functions upgrade them. An
// unconfirmed upgrade is aborted, never forced. The library domains are deliberately not enabled by merely opening
// the journal: this keeps the reviewed gate-1 compatibility release safe while gate 2 is introduced.
//
// When another tab changes the database, this page retires its connection cooperatively: transactions it already
// accepted finish, the connection closes, and every later request from this page is refused with an explanation. It
// never reopens, reloads, deletes or downgrades storage by itself.
import type { Bytes } from './bytes';

const NAME = 'gradstep', LEGACY = 1, JOURNAL_VERSION = 2, LIBRARY_VERSION = 3, VERSION = LIBRARY_VERSION;
export type Store = 'devices' | 'activity' | 'journal' | 'library' | 'libraryDescriptors' | 'readerCopies';
export type LibraryStore = 'library' | 'libraryDescriptors' | 'readerCopies';
const LIBRARY_STORES: readonly LibraryStore[] = ['library', 'libraryDescriptors', 'readerCopies'];

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
      // Never upgrade an existing profile without the person's explicit activation. A newer release may still
      // propose an upgrade to this page; this tab retires through onversionchange rather than accepting it.
      if ((event.oldVersion === LEGACY || (event.oldVersion === JOURNAL_VERSION && (event.newVersion ?? 0) >= LIBRARY_VERSION))
        && !activating) { refused = true; request.transaction?.abort(); return; }
      for (const store of ['devices', 'activity']) if (!db.objectStoreNames.contains(store)) db.createObjectStore(store);
      const next = event.newVersion ?? db.version;
      if (next >= JOURNAL_VERSION && !db.objectStoreNames.contains('journal')) db.createObjectStore('journal');
      if (next >= LIBRARY_VERSION) for (const store of LIBRARY_STORES) if (!db.objectStoreNames.contains(store)) db.createObjectStore(store);
    };
    // An older connection elsewhere has not closed yet. Keep waiting (never delete); the page explains what to close.
    request.onblocked = () => { if (lifecycle.phase === 'open') update({ issue: 'blocked' }); };
    request.onsuccess = () => {
      const db = request.result;
      // Without version enumeration, open(NAME) can return a newer database without VersionError.
      // Refuse it before exposing a connection: this release cannot safely write or Forget unknown stores.
      if (db.version > VERSION) {
        db.close();
        update({ phase: 'retired', issue: 'upgraded', proposal: false });
        reject(refusal());
        return;
      }
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
    // A version-1 profile stays at version 1 until activation. When enumeration is unavailable, asking for v2
    // intentionally falls back to v1 if an old profile exists (openAt's refused path); a new database becomes v2.
    const target = existing === LEGACY ? LEGACY : existing !== null && existing >= LIBRARY_VERSION ? LIBRARY_VERSION : existing === null ? undefined : JOURNAL_VERSION;
    return openAt(target);
  })().catch(error => { if (lifecycle.phase === 'open') connection = null; throw error; });
  return connection;
}

/** One transaction. Success is reported on completion, never on a request's success. `cancel` aborts deliberately. */
function run<T>(stores: Store[] | ((db: IDBDatabase) => Store[]), mode: IDBTransactionMode,
  body: (tx: IDBTransaction, cancel: () => void) => () => T, retried = false, minimumVersion = LEGACY): Promise<T> {
  const pending = database();
  return pending.then(db => new Promise<T>((resolve, reject) => {
    // A callback that resumes after retirement is refused, even though it began earlier.
    if (lifecycle.phase !== 'open') { reject(refusal()); return; }
    if (db.version < minimumVersion) { reject(new StorageError('storage_unavailable')); return; }
    const names = typeof stores === 'function' ? stores(db) : stores;
    if (names.some(store => !db.objectStoreNames.contains(store))) { reject(new StorageError('storage_unavailable')); return; }
    let tx: IDBTransaction;
    try { tx = db.transaction(names, mode, mode === 'readwrite' ? { durability: 'strict' } : undefined); }
    catch {
      // This page's own activation replaced the connection meanwhile: use the new one once.
      if (!retried && connection && connection !== pending && lifecycle.phase === 'open') { resolve(run(stores, mode, body, true, minimumVersion)); return; }
      reject(lifecycle.phase !== 'open' ? refusal() : new StorageError('storage_unavailable')); return;
    }
    active++;
    let finished = false, cancelled = false;
    const finish = () => { if (!finished) { finished = true; active--; settle(); } };
    let result: () => T;
    try { result = body(tx, () => { cancelled = true; tx.abort(); }); }
    catch (error) { try { tx.abort(); } catch { /* already finished */ } finish(); reject(new StorageError(error instanceof DOMException && error.name === 'QuotaExceededError' ? 'storage_quota' : 'storage_unavailable')); return; }
    const resolveResult = () => { try { resolve(result()); } catch (error) { reject(error); } };
    tx.oncomplete = () => { finish(); resolveResult(); };
    tx.onerror = event => { if (cancelled) event.preventDefault(); };
    tx.onabort = () => {
      finish();
      if (cancelled) { resolveResult(); return; }
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
  /** Atomically admit a captured login/writer. `current` is synchronous and checks the live and persisted login. */
  admit: (key: string, origin: string, lifetime: string, writer: string, current: () => boolean) => run<WriterFence>(['devices'], 'readwrite', (tx, cancel) => {
    let result: WriterFence;
    const request = tx.objectStore('devices').get(admissionKey(key));
    request.onsuccess = () => {
      if (!current()) { cancel(); return; }
      const old = request.result as Admission | undefined;
      if (old && (old.format !== 1 || old.origin !== origin || !Number.isSafeInteger(old.generation) || !Array.isArray(old.writers))) { cancel(); return; }
      const same = old?.lifetime === lifetime;
      const next: Admission = { format: 1, origin, incarnation: old?.incarnation ?? crypto.randomUUID(), lifetime,
        generation: same ? old!.generation : (old?.generation ?? 0) + 1, writers: same ? [...old!.writers] : [] };
      if (!next.writers.includes(writer)) next.writers.push(writer);
      if (next.writers.length > 128) { cancel(); return; }
      result = { key, origin, incarnation: next.incarnation, lifetime, generation: next.generation, writer };
      tx.objectStore('devices').put(next, admissionKey(key));
    };
    return () => { if (!result!) throw new StorageError('storage_unavailable'); return result; };
  }),
  /** Retiring one writer leaves legitimate peers admitted. Retiring a login fences every tab in that login. */
  retireWriter: (fence: WriterFence, login = false) => run<void>(['devices'], 'readwrite', tx => {
    const request = tx.objectStore('devices').get(admissionKey(fence.key));
    request.onsuccess = () => {
      const value = request.result as Admission | undefined;
      if (!matchesFence(value, fence)) return;
      tx.objectStore('devices').put({ ...value, lifetime: login ? null : value!.lifetime,
        writers: login ? [] : value!.writers.filter(w => w !== fence.writer) }, admissionKey(fence.key));
    };
    return () => undefined;
  }),
  reapWriters: (key: string, generation: number, dead: string[]) => run<void>(['devices'], 'readwrite', tx => {
    const request = tx.objectStore('devices').get(admissionKey(key));
    request.onsuccess = () => {
      const value = request.result as Admission | undefined;
      if (value?.generation === generation) tx.objectStore('devices').put({ ...value, writers: value.writers.filter(id => !dead.includes(id)) }, admissionKey(key));
    };
    return () => undefined;
  }),
  /** The admission captured before encryption/network work is checked again in the key-write transaction. */
  putDevice: (fence: WriterFence, value: unknown, current: () => boolean) => run<boolean>(['devices'], 'readwrite', tx => {
    let committed = false;
    const request = tx.objectStore('devices').get(admissionKey(fence.key));
    request.onsuccess = () => {
      if (!current() || !matchesFence(request.result, fence)) return;
      tx.objectStore('devices').put(value, fence.key); committed = true;
    };
    return () => committed;
  }),
  /** A delayed save must prove its exact writer/login as well as its retained device in the write transaction. */
  /** `suffix`: another record of the same device (its kept explanations, ':explanations'), fenced the same way. */
  putActivity: (key: string, deviceID: string, value: unknown, fence: WriterFence, current: () => boolean, suffix = '') => run<void>(['devices', 'activity'], 'readwrite', tx => {
    const device = tx.objectStore('devices').get(key), admission = tx.objectStore('devices').get(admissionKey(key));
    admission.onsuccess = () => {
      if (key === fence.key && current() && matchesFence(admission.result, fence) && (device.result as { deviceID?: string } | undefined)?.deviceID === deviceID)
        tx.objectStore('activity').put(value, key + suffix);
    };
    return () => undefined;
  }),
  /** After the account itself was deleted (account-deletion.ts): its coordination record as well, which
   * forgetDevice keeps (with a new incarnation) so other tabs of a still-existing account stay fenced. */
  forgetAdmission: (key: string) => run<void>(['devices'], 'readwrite', tx => { tx.objectStore('devices').delete(admissionKey(key)); return () => undefined; }),
  /** Removes the device, its reading data and every account-domain partition in one transaction. */
  forgetDevice: (key: string, fence?: WriterFence, current?: () => boolean) => run<void>(db => {
    const stores: Store[] = ['devices', 'activity'];
    if (db.objectStoreNames.contains('journal')) stores.push('journal');
    for (const store of LIBRARY_STORES) if (db.objectStoreNames.contains(store)) stores.push(store);
    return stores;
  }, 'readwrite', (tx, cancel) => {
    let refused = false;
    const request = tx.objectStore('devices').get(admissionKey(key));
    request.onsuccess = () => {
      const old = request.result as Admission | undefined;
      if ((fence && !matchesFence(old, fence)) || (current && !current())) { refused = true; cancel(); return; }
      tx.objectStore('devices').delete(key); tx.objectStore('activity').delete(key);
      tx.objectStore('activity').delete(IDBKeyRange.bound(`${key}:`, `${key}:\uffff`)); // its kept explanations too
      if (tx.objectStoreNames.contains('journal')) tx.objectStore('journal').delete(IDBKeyRange.bound(`${key}:`, `${key}:￿`));
      for (const store of LIBRARY_STORES) if (tx.objectStoreNames.contains(store)) tx.objectStore(store).delete(IDBKeyRange.bound(`${key}:`, `${key}:￿`));
      if (old) tx.objectStore('devices').put({ ...old, incarnation: crypto.randomUUID(), generation: old.generation + 1, lifetime: null, writers: [] }, admissionKey(key));
    };
    return () => { if (refused) throw new StorageError('storage_unavailable'); };
  }),
};

/** Opaque coordination metadata only. Private journal content remains authenticated under the local AES key. */
interface Admission { format: 1; origin: string; incarnation: string; lifetime: string | null; generation: number; writers: string[] }
export interface WriterFence { key: string; origin: string; incarnation: string; lifetime: string; generation: number; writer: string }
const admissionKey = (key: string) => `${key}:admission`;
const matchesFence = (value: unknown, fence: WriterFence): boolean => {
  const a = value as Admission | undefined;
  return !!a && a.format === 1 && a.origin === fence.origin && a.incarnation === fence.incarnation && a.lifetime === fence.lifetime
    && a.generation === fence.generation && Array.isArray(a.writers) && a.writers.includes(fence.writer);
};

/** Raw access for lib/journal.ts: reads, and a compare-and-swap commit fenced by the exact device record. */
export interface JournalAccess {
  get(key: string): Promise<Bytes | undefined>;
  range(lower: string, upper: string): Promise<[string, Bytes][]>;
  /** How many records are in the range, without reading them (C8). */
  count?(lower: string, upper: string): Promise<number>;
  commit(headKey: string, expected: Bytes | null, put: [string, Bytes][], remove: string[], device?: { key: string; deviceID: string; fence?: WriterFence; current?: () => boolean }): Promise<'committed' | 'conflict' | 'fenced'>;
}
const sameBytes = (a: unknown, b: Uint8Array | null) => {
  if (b === null) return a === undefined;
  if (!(a instanceof Uint8Array) || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
};
export const journalAccess: JournalAccess = {
  get: key => run<Bytes | undefined>(['journal'], 'readonly', tx => { const r = tx.objectStore('journal').get(key); return () => r.result as Bytes | undefined; }, false, JOURNAL_VERSION),
  range: (lower, upper) => run<[string, Bytes][]>(['journal'], 'readonly', tx => {
    const store = tx.objectStore('journal'), range = IDBKeyRange.bound(lower, upper);
    const names = store.getAllKeys(range), values = store.getAll(range);
    return () => names.result.map((name, i) => [name as string, values.result[i] as Bytes]);
  }, false, JOURNAL_VERSION),
  count: (lower, upper) => run<number>(['journal'], 'readonly', tx => {
    const request = tx.objectStore('journal').count(IDBKeyRange.bound(lower, upper));
    return () => request.result;
  }, false, JOURNAL_VERSION),
  commit: (headKey, expected, put, remove, device) => {
    let outcome: 'committed' | 'conflict' | 'fenced' = 'committed';
    return run<'committed' | 'conflict' | 'fenced'>(['devices', 'journal'], 'readwrite', (tx, cancel) => {
      const journal = tx.objectStore('journal');
      const owner = device ? tx.objectStore('devices').get(device.key) : null;
      const admission = device?.fence ? tx.objectStore('devices').get(admissionKey(device.key)) : null;
      const head = journal.get(headKey);
      head.onsuccess = () => {
        if (device && ((owner!.result as { deviceID?: string } | undefined)?.deviceID !== device.deviceID
          || (device.fence && !matchesFence(admission!.result, device.fence)) || (device.current && !device.current()))) { outcome = 'fenced'; cancel(); return; }
        if (!sameBytes(head.result, expected)) { outcome = 'conflict'; cancel(); return; }
        for (const key of remove) journal.delete(key);
        for (const [key, value] of put) journal.put(value, key);
      };
      return () => outcome;
    }, false, JOURNAL_VERSION);
  },
};

/** A public key inside one of the gate-2 encrypted domains. The value is always an opaque sealed record. */
export interface LibraryKey { store: LibraryStore; key: string }
export interface LibraryCompare extends LibraryKey { expected: Bytes | null }
export interface LibraryPut extends LibraryKey { value: Bytes }
export interface LibraryRemove extends LibraryKey {}
export interface LibraryDeviceGuard { key: string; deviceID: string; fence?: WriterFence; current?: () => boolean }
export interface LibraryAccess {
  /** Reads all requested heads in one readonly transaction, preserving request order. */
  read(keys: readonly LibraryKey[]): Promise<(Bytes | undefined)[]>;
  /** Returns only bounded public IDB keys; callers must use a scoped lower/upper range. */
  keys(store: LibraryStore, lower: string, upper: string, limit?: number): Promise<string[]>;
  /** Compares exact predecessor ciphertexts and applies the finite mutation atomically. */
  commit(compare: readonly LibraryCompare[], put: readonly LibraryPut[], remove: readonly LibraryRemove[], device?: LibraryDeviceGuard): Promise<'committed' | 'conflict' | 'fenced'>;
}

function validLibraryKey(value: LibraryKey): void {
  if (!LIBRARY_STORES.includes(value.store) || typeof value.key !== 'string' || value.key.length === 0 || value.key.length > 1_024)
    throw new StorageError('storage_unavailable');
}
function validBytes(value: unknown): value is Bytes {
  return value instanceof Uint8Array && value.byteLength <= 16 * 1024 * 1024;
}
function duplicateKey(value: LibraryKey): string { return `${value.store}\u0000${value.key}`; }

export const libraryAccess: LibraryAccess = {
  read: keys => {
    if (!keys.length) return Promise.resolve([]);
    for (const key of keys) validLibraryKey(key);
    return run<(Bytes | undefined)[]>([...new Set(keys.map(key => key.store))], 'readonly', tx => {
      const requests = keys.map(key => tx.objectStore(key.store).get(key.key));
      return () => requests.map(request => request.result as Bytes | undefined);
    }, false, LIBRARY_VERSION);
  },
  keys: (store, lower, upper, limit = 256) => {
    if (!LIBRARY_STORES.includes(store) || typeof lower !== 'string' || typeof upper !== 'string' || lower > upper
      || !Number.isSafeInteger(limit) || limit < 1 || limit > 4_000) return Promise.reject(new StorageError('storage_unavailable'));
    return run<string[]>([store], 'readonly', tx => {
      const request = tx.objectStore(store).getAllKeys(IDBKeyRange.bound(lower, upper), limit);
      return () => request.result.map(key => String(key));
    }, false, LIBRARY_VERSION);
  },
  commit: (compare, put, remove, device) => {
    const all = [...compare, ...put, ...remove];
    if (!all.length && !device) return Promise.resolve('committed');
    for (const key of all) validLibraryKey(key);
    if (compare.some(item => item.expected !== null && !validBytes(item.expected))
      || put.some(item => !validBytes(item.value))) return Promise.reject(new StorageError('storage_unavailable'));
    const compareIDs = new Set(compare.map(duplicateKey));
    const putIDs = new Set(put.map(duplicateKey));
    const removeIDs = new Set(remove.map(duplicateKey));
    if (compareIDs.size !== compare.length || putIDs.size !== put.length || removeIDs.size !== remove.length
      || [...putIDs].some(id => removeIDs.has(id))) return Promise.reject(new StorageError('storage_unavailable'));
    const stores = [...new Set([...all.map(item => item.store), ...(device ? ['devices' as Store] : [])])];
    let outcome: 'committed' | 'conflict' | 'fenced' = 'committed';
    return run<'committed' | 'conflict' | 'fenced'>(stores, 'readwrite', (tx, cancel) => {
      const requests = compare.map(item => ({ item, request: tx.objectStore(item.store).get(item.key) }));
      const owner = device ? tx.objectStore('devices').get(device.key) : null;
      const admission = device?.fence ? tx.objectStore('devices').get(admissionKey(device.key)) : null;
      let remaining = requests.length + (owner ? 1 : 0) + (admission ? 1 : 0);
      let checked = false;
      const check = () => {
        if (remaining > 0) { remaining--; }
        if (remaining > 0 || checked) return;
        checked = true;
        if (device && ((owner!.result as { deviceID?: string } | undefined)?.deviceID !== device.deviceID
          || (device.fence && !matchesFence(admission!.result, device.fence)) || (device.current && !device.current()))) {
          outcome = 'fenced'; cancel(); return;
        }
        if (requests.some(({ item, request }) => !sameBytes(request.result, item.expected))) { outcome = 'conflict'; cancel(); return; }
        for (const item of remove) tx.objectStore(item.store).delete(item.key);
        for (const item of put) tx.objectStore(item.store).put(item.value, item.key);
      };
      for (const { request } of requests) request.onsuccess = check;
      if (owner) owner.onsuccess = check;
      if (admission) admission.onsuccess = check;
      // No compare and no guard still needs to perform the finite mutation.
      if (!requests.length && !owner && !admission) check();
      return () => outcome;
    }, false, LIBRARY_VERSION);
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
async function activateVersion(target: number, wait: number): Promise<'active' | 'deferred'> {
  const db = await database();
  if (db.version >= target) return 'active';
  listen();
  const proposal = crypto.randomUUID(), replies: UpgradeReply[] = [];
  const collect = (r: UpgradeReply) => { if (r.proposal === proposal) replies.push(r); };
  replyWaiters.add(collect);
  try { channel?.postMessage({ kind: 'upgrade-proposal', proposal, version: target } satisfies UpgradeProposal); } catch { /* closed */ }
  await new Promise(resolve => setTimeout(resolve, wait));
  replyWaiters.delete(collect);
  if (replies.some(r => !r.ready)) return 'deferred';
  if (lifecycle.phase !== 'open') throw refusal();
  // Close this page's own connection without retiring the page; waiting requests use the new connection.
  activating = true;
  db.onversionchange = null; db.onclose = null; db.close();
  connection = openAt(target).finally(() => { activating = false; });
  try { await connection; } catch (error) { connection = null; throw error; }
  return 'active';
}

/** Turns on the encrypted journal for a version-1 profile after the explicit update handshake. */
export function activateJournal(wait = 900): Promise<'active' | 'deferred'> {
  return activateVersion(JOURNAL_VERSION, wait);
}

/** Turns on the gate-2 library stores. A version-1 profile is first brought to the reviewed journal schema. */
export async function activateLibraryStorage(wait = 900): Promise<'active' | 'deferred'> {
  const current = await database();
  if (current.version < JOURNAL_VERSION) {
    const journal = await activateVersion(JOURNAL_VERSION, wait);
    if (journal === 'deferred') return journal;
  }
  return activateVersion(LIBRARY_VERSION, wait);
}

export const storage = {
  /** Highest schema understood by this release. Existing profiles are not upgraded implicitly. */
  version: VERSION,
  journalVersion: JOURNAL_VERSION,
  libraryVersion: LIBRARY_VERSION,
  snapshot: (): StorageLifecycle => lifecycle,
  subscribe(listener: () => void): () => void { listeners.add(listener); return () => { listeners.delete(listener); }; },
  /** Whether this page may start new local writes, sends or consent continuations. */
  writable: () => lifecycle.phase === 'open',
  /** Opens the database (if needed) and reports whether the encrypted journal store exists. */
  async journalReady(): Promise<boolean> { return (await database()).version >= JOURNAL_VERSION; },
  /** Reports whether the explicit gate-2 activation has installed all library stores. */
  async libraryReady(): Promise<boolean> {
    const db = await database();
    return db.version >= LIBRARY_VERSION && LIBRARY_STORES.every(store => db.objectStoreNames.contains(store));
  },
  /** Registers a check for unsent work in this page, consulted when another tab proposes an update. */
  registerWork(check: () => boolean): () => void {
    listen();
    works.add(check);
    return () => { works.delete(check); storage.reviewProposal(); };
  },
  /** After this page's work changes: tell a waiting newer tab once nothing remains, and clear the notice. */
  reviewProposal() { if (lastProposal && lifecycle.proposal && !busy()) reply(lastProposal); },
};
