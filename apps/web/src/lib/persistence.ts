// Storage persistence (sync audit 2026-10-14, item 4). The browser decides whether this origin's storage is protected
// from eviction; the answer used to be discarded. It is kept here so the draft hint can be honest ("Saved on this
// device" only when the browser agreed), and asked again on every visit, since a browser may grant it later.
export type PersistenceState = 'unknown' | 'persisted' | 'best-effort' | 'unsupported';
let state: PersistenceState = 'unknown';
const listeners = new Set<() => void>();
const set = (next: PersistenceState) => { if (next === state) return; state = next; for (const listener of listeners) listener(); };

export const persistenceState = () => state;
export function subscribePersistence(listener: () => void): () => void { listeners.add(listener); return () => { listeners.delete(listener); }; }

/** Asks the browser for persistent storage (a prompt in some browsers) and records its answer. Never throws. */
export async function requestPersistence(storage: Pick<StorageManager, 'persist' | 'persisted'> | undefined = globalThis.navigator?.storage): Promise<PersistenceState> {
  if (!storage || typeof storage.persist !== 'function') { set('unsupported'); return state; }
  try {
    if (typeof storage.persisted === 'function' && await storage.persisted()) { set('persisted'); return state; }
    set(await storage.persist() ? 'persisted' : 'best-effort');
  } catch { set('best-effort'); }
  return state;
}

/** Tests: start over. */
export function resetPersistence() { set('unknown'); }
