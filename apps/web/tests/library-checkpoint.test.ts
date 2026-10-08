import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Item, Import } from '../src/lib/library';

const account = '11111111-2222-4333-8444-555555555555';
const origin = 'https://fixture.invalid';
const epoch = '99999999-0000-4000-8000-000000000001';
const at = '2026-10-07T09:00:00.123+00:00';
const item = (id = 'aaaaaaaa-0000-4000-8000-000000000001'): Item => ({
  kind: 'item', id, document_id: 'dddddddd-0000-4000-8000-000000000001', created_seq: 3, state_seq: 5,
  membership_revision: 1, visible: true, added_at: at as unknown as number, last_remove_seq: 0,
  approval_id: 'eeeeeeee-0000-4000-8000-000000000001', version_id: 'eeeeeeee-0000-4000-8000-000000000002',
  metadata_id: 'eeeeeeee-0000-4000-8000-000000000003', source: 'arxiv', source_id: '2305.18290', source_revision: 3,
  metadata: { title: 'DPO', authors: ['Rafael Rafailov'], categories: ['cs.LG'] }, metadata_recorded_at: at as unknown as number,
  source_url: 'https://arxiv.org/abs/2305.18290v3', scope: 'shared_catalog', page_count: 27,
  original_object_id: 'eeeeeeee-0000-4000-8000-000000000004', artifact_id: 'eeeeeeee-0000-4000-8000-000000000005',
  readiness: 'converted_ready',
});
const imported = (id = 'bbbbbbbb-0000-4000-8000-000000000001'): Import => ({
  kind: 'import', id, created_seq: 7, state_seq: 9, intent_revision: 1, visible: true, phase: 'acquiring',
  source: 'arxiv', source_id: '1706.03762', requested_revision: undefined, source_url: 'https://arxiv.org/abs/1706.03762', retryable: false,
});

describe('encrypted browser library checkpoints', () => {
  beforeEach(() => { vi.resetModules(); vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange); });
  afterEach(() => { vi.unstubAllGlobals(); });

  async function prepared() {
    const idb = await import('../src/lib/idb');
    expect(await idb.activateLibraryStorage(0)).toBe('active');
    const fence = await idb.idb.admit(account, origin, 'login', '33333333-0000-4000-8000-000000000001', () => true);
    const deviceID = '22222222-0000-4000-8000-000000000001';
    expect(await idb.idb.putDevice(fence, { deviceID }, () => true)).toBe(true);
    const localKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    return {
      idb,
      scope: { origin, environment: 'test', account, deviceKey: account, deviceID, localKey, fence, current: () => true },
    };
  }

  it('seals and reloads a complete checkpoint with no plaintext titles in keys', async () => {
    const { idb, scope } = await prepared();
    const storage = await import('../src/lib/library-storage');
    const saved = await storage.saveLibraryCheckpoint(scope, [item(), imported()], { through: 9, kind: 'v5' }, epoch);
    expect(saved.entries.map(entry => entry.kind)).toEqual(['item', 'import']);
    const loaded = await storage.loadLibraryCheckpoint(scope);
    expect(loaded).toMatchObject({ revision: 1, datasetEpoch: epoch, cursor: { through: 9, kind: 'v5' } });
    expect(loaded?.entries).toEqual(saved.entries);
    const publicKeys = await idb.libraryAccess.keys('library', `test:${account}:library:`, `test:${account}:library:\uffff`, 4_000);
    expect(publicKeys.length).toBe(3);
    expect(publicKeys.join('\n')).not.toContain('DPO');
    expect(publicKeys.join('\n')).not.toContain(origin);
  });

  it('refuses tampered and incomplete checkpoints instead of returning an empty library', async () => {
    const { idb, scope } = await prepared();
    const storage = await import('../src/lib/library-storage');
    await storage.saveLibraryCheckpoint(scope, [item()], null, epoch);
    const domainKeys = await idb.libraryAccess.keys('library', `test:${account}:library:`, `test:${account}:library:\uffff`, 4_000);
    const child = domainKeys.find(key => key.includes(':row:'))!;
    const head = domainKeys.find(key => key.endsWith(':head'))!;
    expect(await idb.libraryAccess.commit([], [], [{ store: 'library', key: child }])).toBe('committed');
    await expect(storage.loadLibraryCheckpoint(scope)).rejects.toMatchObject({ code: 'library_damaged' });

    // Removing the head while leaving a child is also damage; it must not be interpreted as a first-run account.
    await storage.saveLibraryCheckpoint(scope, [item()], null, epoch);
    const keys = await idb.libraryAccess.keys('library', `test:${account}:library:`, `test:${account}:library:\uffff`, 4_000);
    const head2 = keys.find(key => key.endsWith(':head'))!;
    expect(await idb.libraryAccess.commit([], [], [{ store: 'library', key: head2 }])).toBe('committed');
    await expect(storage.loadLibraryCheckpoint(scope)).rejects.toMatchObject({ code: 'library_damaged' });
  });

  it('maps a stale compare-and-swap and a retired writer to explicit outcomes', async () => {
    const { idb, scope } = await prepared();
    const storage = await import('../src/lib/library-storage');
    await storage.saveLibraryCheckpoint(scope, [item()], null, epoch);
    const keys = await idb.libraryAccess.keys('library', `test:${account}:library:`, `test:${account}:library:\uffff`, 4_000);
    const head = keys.find(key => key.endsWith(':head'))!;
    const current = (await idb.libraryAccess.read([{ store: 'library', key: head }]))[0]!;
    expect(await idb.libraryAccess.commit([{ store: 'library', key: head, expected: current }], [{ store: 'library', key: head, value: current }], [])).toBe('committed');
    // A second save sees the exact head and succeeds; the direct stale CAS below proves the conflict boundary.
    await storage.saveLibraryCheckpoint(scope, [item()], null, epoch);
    expect(await idb.libraryAccess.commit([{ store: 'library', key: head, expected: new TextEncoder().encode('stale') }], [{ store: 'library', key: head, value: current }], [])).toBe('conflict');
    const retired = { ...scope, current: () => false };
    await expect(storage.saveLibraryCheckpoint(retired, [item()], null, epoch)).rejects.toMatchObject({ code: 'library_fenced' });
  });

  it('enforces the bounded row count before spending encryption work', async () => {
    const { scope } = await prepared();
    const storage = await import('../src/lib/library-storage');
    const entries = Array.from({ length: 4_001 }, (_, i) => imported(`bbbbbbbb-0000-4000-8000-${String(i + 1).padStart(12, '0')}`));
    await expect(storage.saveLibraryCheckpoint(scope, entries, null, epoch)).rejects.toMatchObject({ code: 'library_capacity' });
  });
});

