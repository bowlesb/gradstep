// Minimal IndexedDB access. Values are structured clones, so non-extractable CryptoKeys
// are stored as keys (usable after reload, never readable as bytes).

const NAME = 'gradstep', VERSION = 1;
export type Store = 'devices' | 'activity';

let opening: Promise<IDBDatabase> | null = null;
function database(): Promise<IDBDatabase> {
  opening ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(NAME, VERSION);
    request.onupgradeneeded = () => {
      for (const store of ['devices', 'activity']) if (!request.result.objectStoreNames.contains(store)) request.result.createObjectStore(store);
    };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = () => { db.close(); opening = null; };
      resolve(db);
    };
    request.onerror = () => { opening = null; reject(new Error('storage_unavailable')); };
    request.onblocked = () => { opening = null; reject(new Error('storage_unavailable')); };
  });
  return opening;
}

function run<T>(store: Store, mode: IDBTransactionMode, body: (s: IDBObjectStore) => IDBRequest | null): Promise<T> {
  return database().then(db => new Promise<T>((resolve, reject) => {
    const tx = db.transaction(store, mode);
    const request = body(tx.objectStore(store));
    tx.oncomplete = () => resolve((request?.result ?? undefined) as T);
    tx.onerror = tx.onabort = () => reject(new Error('storage_unavailable'));
  }));
}

export const idb = {
  get: <T>(store: Store, key: string) => run<T | undefined>(store, 'readonly', s => s.get(key)),
  put: (store: Store, key: string, value: unknown) => run<void>(store, 'readwrite', s => s.put(value, key)),
  delete: (store: Store, key: string) => run<void>(store, 'readwrite', s => s.delete(key)),
};
