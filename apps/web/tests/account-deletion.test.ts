// Deleting the account from the browser (lib/account-deletion.ts): the request, the one-sentence failures, and that
// this browser keeps nothing of the account afterwards (storage keys, and every IndexedDB record incl. coordination).
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { BackendError } from '../src/lib/backend';
import { DELETION_CONFIRMATION, deletionFailure, forgetAccountStorage, noteAccountDeleted, requestAccountDeletion, takeAccountDeletedNotice } from '../src/lib/account-deletion';

const account = '11111111-2222-4333-8444-555555555555', other = '99999999-2222-4333-8444-555555555555';

describe('the request', () => {
  it('posts the confirmation the function requires and accepts a deletion the sweep finishes later', async () => {
    const post = vi.fn(async () => ({ deleted: true, complete: false }));
    await requestAccountDeletion(account, post as never);
    expect(post).toHaveBeenCalledWith('account-delete', { confirm: DELETION_CONFIRMATION }, expect.objectContaining({ account }));
    expect(DELETION_CONFIRMATION).toBe('delete my account');
  });
  it('refuses an answer that does not say deleted, so nothing local is erased', async () => {
    await expect(requestAccountDeletion(account, (async () => ({ ok: true })) as never)).rejects.toMatchObject({ code: 'invalid_response' });
  });
});

describe('failures are one plain sentence', () => {
  it.each([
    [new BackendError('connection'), 'Couldn’t reach Gradstep. Check your connection and try again.'],
    [new BackendError('throttled', 429, 12), 'Too many requests right now. Try again in 12 seconds.'],
    [new BackendError('throttled', 429), 'Too many requests right now. Try again in a moment.'],
    [new BackendError('account_busy', 409), 'An episode or another task is still finishing. Try again in a moment.'],
    [new BackendError('sign_in_required', 401), 'Your sign-in has expired. Sign in again, then delete the account.'],
    [new BackendError('service_unavailable', 503), 'The account couldn’t be deleted. Try again.'],
    [new Error('anything'), 'The account couldn’t be deleted. Try again.'],
  ])('%s', (error, sentence) => expect(deletionFailure(error)).toBe(sentence));
});

describe('stored keys', () => {
  const store = (entries: Record<string, string>) => {
    const map = new Map(Object.entries(entries));
    return { map, length: 0, get size() { return map.size; },
      key: (i: number) => [...map.keys()][i] ?? null, removeItem: (k: string) => { map.delete(k); } } as unknown as Storage & { map: Map<string, string> };
  };
  it('removes every key carrying the account and nothing else', () => {
    const local = store({
      [`gradstep.staging.${account}.cloud-ai-consent`]: 'v3',
      [`gradstep.staging.feed-offer.${account}`]: 'yes',
      [`gradstep.staging.podcast-positions.https%3A%2F%2Fx.supabase.co.${account}.v2.life.ep1`]: '{}',
      [`gradstep.staging.${other}.cloud-ai-consent`]: 'v3',
      'gradstep.staging.session': '{}', 'gradstep.theme': 'dark', 'gradstep.library-columns': '[]', 'unrelated': account,
      // The Library's tag filter is one of the account's tags; the status filter is a setting.
      'gradstep.library.tag': '"thesis"', 'gradstep.library.filter': '"unread"',
    });
    Object.defineProperty(local, 'length', { get: () => local.map.size });
    const removed = forgetAccountStorage(account.toUpperCase(), local);
    expect(removed).toHaveLength(4);
    expect([...local.map.keys()].sort()).toEqual([`gradstep.staging.${other}.cloud-ai-consent`, 'gradstep.library-columns', 'gradstep.library.filter', 'gradstep.staging.session', 'gradstep.theme', 'unrelated'].sort());
  });
});

describe('IndexedDB', () => {
  beforeEach(() => { vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange); vi.resetModules(); });
  afterEach(() => { vi.unstubAllGlobals(); });
  it('forgetDevice then forgetAdmission leave no record of the account, and another account’s stay', async () => {
    // A current browser's database (library version, every store), as idb.ts leaves it.
    const stores = ['devices', 'activity', 'journal', 'library', 'libraryDescriptors', 'readerCopies'];
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const r = indexedDB.open('gradstep', 3);
      r.onupgradeneeded = () => { for (const s of stores) r.result.createObjectStore(s); };
      r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
    });
    const key = `test:${account}`, keep = `test:${other}`;
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(stores, 'readwrite');
      for (const k of [key, keep]) {
        tx.objectStore('devices').put({ deviceID: 'd' }, k);
        tx.objectStore('devices').put({ format: 1, origin: 'o', incarnation: 'i', lifetime: null, generation: 1, writers: [] }, `${k}:admission`);
        tx.objectStore('activity').put({}, k);
        for (const s of ['journal', 'library', 'libraryDescriptors', 'readerCopies']) tx.objectStore(s).put({ sealed: true }, `${k}:row`);
      }
      tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error);
    });
    db.close();
    const { idb } = await import('../src/lib/idb');
    await idb.forgetDevice(key);
    await idb.forgetAdmission(key);
    const reopened = await new Promise<IDBDatabase>((resolve, reject) => { const r = indexedDB.open('gradstep'); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    const keys = async (store: string) => new Promise<string[]>(resolve => { const r = reopened.transaction(store).objectStore(store).getAllKeys(); r.onsuccess = () => resolve(r.result as string[]); });
    for (const store of stores) {
      const left = await keys(store);
      expect(left.filter(k => k.includes(account)), store).toEqual([]);
      expect(left.some(k => k.includes(other)), store).toBe(true);
    }
    reopened.close();
  });
});

describe('the confirmation', () => {
  it('is shown once on the sign-in screen', () => {
    expect(takeAccountDeletedNotice()).toBe(false);
    noteAccountDeleted();
    expect(takeAccountDeletedNotice()).toBe(true);
    expect(takeAccountDeletedNotice()).toBe(false);
  });
});
