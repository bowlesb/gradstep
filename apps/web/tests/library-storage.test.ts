import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { LibraryStore } from '../src/lib/idb';

const account = 'test:11111111-2222-4333-8444-555555555555';
const other = 'test:aaaaaaaa-2222-4333-8444-555555555555';
const bytes = (text: string) => new TextEncoder().encode(text) as Uint8Array<ArrayBuffer>;

describe('gate-2 library storage', () => {
  beforeEach(() => { vi.resetModules(); vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange); });
  afterEach(() => { vi.unstubAllGlobals(); });

  async function openLibrary() {
    const mod = await import('../src/lib/idb');
    expect(await mod.idb.get('devices', 'opened')).toBeUndefined();
    expect(await mod.storage.journalReady()).toBe(true);
    expect(await mod.storage.libraryReady()).toBe(false);
    expect(await mod.activateLibraryStorage(0)).toBe('active');
    expect(await mod.storage.libraryReady()).toBe(true);
    return mod;
  }

  it('keeps schema 3 behind explicit activation and reads heads in one ordered transaction', async () => {
    const { libraryAccess } = await openLibrary();
    const first = { store: 'library' as LibraryStore, key: `${account}:library:head` };
    const second = { store: 'libraryDescriptors' as LibraryStore, key: `${account}:descriptors:head` };
    expect(await libraryAccess.read([first, second])).toEqual([undefined, undefined]);
    expect(await libraryAccess.commit([], [
      { ...first, value: bytes('library-head') },
      { ...second, value: bytes('descriptor-head') },
    ], [])).toBe('committed');
    expect(await libraryAccess.read([second, first])).toEqual([bytes('descriptor-head'), bytes('library-head')]);
  });

  it('uses exact compare-and-swap and a bounded key inventory', async () => {
    const { libraryAccess } = await openLibrary();
    const head = { store: 'library' as LibraryStore, key: `${account}:library:head` };
    const row1 = { store: 'library' as LibraryStore, key: `${account}:library:row:001` };
    const row2 = { store: 'library' as LibraryStore, key: `${account}:library:row:002` };
    await libraryAccess.commit([], [
      { ...head, value: bytes('h1') }, { ...row1, value: bytes('r1') }, { ...row2, value: bytes('r2') },
    ], []);
    expect(await libraryAccess.commit([{ ...head, expected: bytes('wrong') }], [{ ...head, value: bytes('h2') }], [])).toBe('conflict');
    expect(await libraryAccess.read([head])).toEqual([bytes('h1')]);
    expect(await libraryAccess.keys('library', `${account}:library:row:`, `${account}:library:row:\uffff`, 1)).toEqual([row1.key]);
    expect(await libraryAccess.keys('library', `${account}:library:row:`, `${account}:library:row:\uffff`, 8)).toEqual([row1.key, row2.key]);
  });

  it('checks the device fence in the same transaction and forgets all account domains', async () => {
    const { idb, libraryAccess } = await openLibrary();
    const origin = 'https://fixture.invalid';
    const fence = await idb.admit(account, origin, 'login', 'writer', () => true);
    expect(await idb.putDevice(fence, { deviceID: 'device-one' }, () => true)).toBe(true);
    const head = { store: 'library' as LibraryStore, key: `${account}:library:head` };
    const peer = { store: 'readerCopies' as LibraryStore, key: `${account}:copies:one` };
    const otherHead = { store: 'library' as LibraryStore, key: `${other}:library:head` };
    await libraryAccess.commit([], [{ ...head, value: bytes('private') }, { ...peer, value: bytes('copy') }, { ...otherHead, value: bytes('keep') }], [], { key: account, deviceID: 'device-one', fence, current: () => true });
    expect(await libraryAccess.commit([{ ...head, expected: bytes('private') }], [{ ...head, value: bytes('late') }], [], { key: account, deviceID: 'device-one', fence, current: () => false })).toBe('fenced');
    await idb.forgetDevice(account, fence, () => true);
    expect(await libraryAccess.read([head, peer, otherHead])).toEqual([undefined, undefined, bytes('keep')]);
  });
});
