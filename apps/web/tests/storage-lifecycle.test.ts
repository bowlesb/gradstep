// Compatibility checkpoint (docs/architecture/BROWSER_OFFLINE_STORAGE.md): the eight lifecycle/controller cases.
// idb.ts runs against a spec IndexedDB (fake-indexeddb); the two-tab browser journeys use real Chromium (e2e/storage-update.spec.ts).
import { IDBFactory } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fromBytea, sha256, toBytea } from '../src/lib/bytes';
import type { StreamEvent } from '../src/lib/chat';
import type { StorageLifecycle } from '../src/lib/idb';

const server = vi.hoisted(() => ({ rows: [] as any[], fail: false, pause: null as null | (() => Promise<void>), requests: [] as any[] }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string, p: any) => {
    if (name === 'v1_append_event') {
      if (server.pause) await server.pause();
      if (server.fail) throw new mod.BackendError('connection');
      const old = server.rows.find(e => e.id === p.p_id);
      if (old) { if (old.ciphertext !== p.p_ciphertext) throw new Error('changed bytes'); return old.cursor; }
      server.rows.push({ id: p.p_id, device_id: p.p_device_id, epoch: p.p_epoch, format: p.p_format, ciphertext: p.p_ciphertext,
        ciphertext_sha256: toBytea(await sha256(fromBytea(p.p_ciphertext))), cursor: server.rows.length + 1 }); return server.rows.length;
    }
    if (name === 'v2_pull_events') { const events = server.rows.filter(r => r.cursor > p.p_after).slice(0, p.p_limit); return { events, next_cursor: events.at(-1)?.cursor ?? p.p_after, has_more: false }; }
    if (name === 'v1_credit_balance') return { available: 100, reserved: 0 };
    return null;
  } };
});

const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001';
/** This release's database is version 2 (the journal); a future release stands in as version 3. */
const NEWER = 3;
const done: StreamEvent = { type: 'done', stopReason: 'end_turn', credits: 3 };
const delay = () => { let resolve!: () => void; const promise = new Promise<void>(r => { resolve = r; }); return { promise, resolve }; };

/** The signal a newer tab produces in this page, without IndexedDB (controller cases). */
function lifecycle() {
  let state: StorageLifecycle = { phase: 'open', issue: null, proposal: false, version: 2 };
  const listeners = new Set<() => void>();
  return {
    snapshot: () => state, subscribe: (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; },
    retire() { state = { ...state, phase: 'retiring', issue: 'update', proposal: false }; for (const l of [...listeners]) l(); },
  };
}
async function session(stream: (signal: AbortSignal) => AsyncIterable<StreamEvent>, consent = true) {
  const { ChatSession } = await import('../src/lib/chat-session');
  const { History } = await import('../src/lib/history');
  const { keyRing, generateBundle } = await import('../src/lib/wire');
  const owner = new AbortController(), ring = await keyRing(generateBundle(account)), storage = lifecycle();
  const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
  let accepted = consent;
  const chat = new ChatSession(account, history, owner.signal, { storage, readConsent: () => accepted, writeConsent: () => { accepted = true; },
    stream: (_account, request, signal) => { server.requests.push(request); return stream(signal); } });
  return { chat, history, owner, storage };
}
const untilAborted = (signal: AbortSignal) => new Promise<never>((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));

beforeEach(() => { server.rows = []; server.fail = false; server.pause = null; server.requests = []; });

describe('storage lifecycle in idb.ts (spec IndexedDB)', () => {
  let factory: IDBFactory;
  beforeEach(() => { factory = new IDBFactory(); vi.stubGlobal('indexedDB', factory); vi.resetModules(); });
  afterEach(() => { vi.unstubAllGlobals(); });
  /** Another tab running a newer release: opens the database at a higher version and keeps its connection. */
  const newerTab = (version = NEWER) => new Promise<IDBDatabase>((resolve, reject) => {
    const request = factory.open('gradstep', version);
    request.onupgradeneeded = () => { for (const name of ['devices', 'activity', 'journal', 'newer']) if (!request.result.objectStoreNames.contains(name)) request.result.createObjectStore(name); };
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  const read = (db: IDBDatabase, store: string, key: string) => new Promise<unknown>(resolve => {
    const r = db.transaction(store).objectStore(store).get(key); r.onsuccess = () => resolve(r.result);
  });

  it('1. a write accepted before the update completes; a later callback from this page is refused and writes nothing', async () => {
    const { idb, storage } = await import('../src/lib/idb');
    expect(await idb.get('devices', 'k')).toBeUndefined(); // the connection is open
    const accepted = idb.put('devices', 'k', { deviceID: 'accepted' });
    await Promise.resolve(); await Promise.resolve(); // the transaction is created before the newer tab arrives
    const upgrading = newerTab();
    await accepted;
    const newer = await upgrading;
    expect(await read(newer, 'devices', 'k')).toEqual({ deviceID: 'accepted' });
    expect(storage.snapshot()).toMatchObject({ phase: 'retired', issue: 'update', proposal: false });
    await expect(idb.put('devices', 'late', { deviceID: 'late' })).rejects.toMatchObject({ code: 'storage_update' });
    await expect(idb.putActivity('k', 'accepted', new Uint8Array(1))).rejects.toMatchObject({ code: 'storage_update' });
    expect(await read(newer, 'devices', 'late')).toBeUndefined();
    expect(await read(newer, 'activity', 'k')).toBeUndefined();
    expect(storage.writable()).toBe(false);
    newer.close();
  });

  it('7. a proposed update waits while this tab has unsent work, and our own blocked open waits with guidance instead of failing', async () => {
    const { idb, storage } = await import('../src/lib/idb');
    await idb.get('devices', 'open'); // this page is connected at version 2
    let work = true;
    const unregister = storage.registerWork(() => work);
    const newer = new BroadcastChannel('gradstep.storage'), replies: unknown[] = [];
    newer.onmessage = event => replies.push(event.data);
    try {
      const proposal = crypto.randomUUID();
      newer.postMessage({ kind: 'upgrade-proposal', proposal: 'not-an-id', version: 2 });
      newer.postMessage({ kind: 'upgrade-proposal', proposal, version: 2 }); // not newer than this page's version 2
      newer.postMessage({ kind: 'upgrade-proposal', proposal, version: NEWER });
      await vi.waitFor(() => expect(replies).toEqual([{ kind: 'upgrade-reply', proposal, ready: false }]));
      expect(storage.snapshot()).toMatchObject({ phase: 'open', proposal: true });
      await idb.put('devices', 'still-writable', 1); // deferring is not retirement
      work = false; storage.reviewProposal();
      await vi.waitFor(() => expect(replies).toHaveLength(2));
      expect(replies[1]).toEqual({ kind: 'upgrade-reply', proposal, ready: true });
      expect(storage.snapshot().proposal).toBe(false);
      expect(JSON.stringify(replies)).not.toMatch(/still-writable|devices/);
    } finally { unregister(); newer.close(); }
    // Our open request reported as blocked: keep waiting (never delete, never claim the browser is unsupported).
    vi.resetModules();
    const fresh = new IDBFactory(), seen: string[] = [];
    vi.stubGlobal('indexedDB', { databases: () => fresh.databases(), open: (name: string, version: number) => {
      const request = fresh.open(name, version);
      queueMicrotask(() => request.onblocked?.(new Event('blocked') as IDBVersionChangeEvent));
      return request;
    } });
    const second = await import('../src/lib/idb');
    second.storage.subscribe(() => seen.push(second.storage.snapshot().issue ?? 'none'));
    await second.idb.put('devices', 'after-blocked', 2);
    expect(seen).toContain('blocked'); expect(seen.at(-1)).toBe('none');
    expect(second.storage.snapshot()).toMatchObject({ phase: 'open', issue: null, proposal: false, version: 2 });
  });

  it('8. a legacy version-1 page never reopens after retirement, and reports a newer database as an update, not a missing capability', async () => {
    const first = await import('../src/lib/idb');
    await first.idb.put('devices', 'kept', { deviceID: 'kept' });
    const newer = await newerTab();
    await vi.waitFor(() => expect(first.storage.snapshot().phase).toBe('retired'));
    newer.close(); // even with the newer connection gone, the retired page does not reopen version 1
    const opened = vi.spyOn(factory, 'open');
    await expect(first.idb.get('devices', 'kept')).rejects.toMatchObject({ code: 'storage_update' });
    expect(opened).not.toHaveBeenCalled();
    opened.mockRestore();
    // A page that loads after the update: VersionError becomes 'upgraded', and the newer data is untouched.
    vi.resetModules();
    const late = await import('../src/lib/idb');
    await expect(late.idb.get('devices', 'kept')).rejects.toMatchObject({ code: 'storage_upgraded' });
    expect(late.storage.snapshot()).toMatchObject({ phase: 'retired', issue: 'upgraded', proposal: false });
    const again = vi.spyOn(factory, 'open');
    await expect(late.idb.get('devices', 'kept')).rejects.toMatchObject({ code: 'storage_upgraded' });
    expect(again).not.toHaveBeenCalled();
    const check = await newerTab();
    expect(check.version).toBe(NEWER);
    expect(await read(check, 'devices', 'kept')).toEqual({ deviceID: 'kept' });
    check.close();
  });
});

describe('storage retirement in the chat controller', () => {
  it('2. refuses a new Send, a consent continuation, a retry and edits; nothing is saved or requested', async () => {
    const { chat, storage } = await session(async function* () { yield { type: 'delta', text: 'never' }; yield done; }, false);
    const waiting = chat.current(null);
    chat.edit(waiting, 'Awaiting consent'); await chat.send(waiting);
    expect(waiting.phase).toBe('consent'); expect(server.rows).toHaveLength(2);
    const other = chat.newChat('dddddddd-0000-4000-8000-000000000001'); chat.edit(other, 'Unsent paper question');
    storage.retire();
    expect(chat.storageRetired).toBe(true);
    expect(waiting.phase).toBe('idle'); expect(waiting.issue).toBe('storage_retired');
    await chat.consent(waiting, true);
    await chat.send(other); await chat.retry(waiting);
    expect(chat.edit(other, 'Changed')).toBe(false);
    expect(other.draft).toBe('Unsent paper question');
    expect(server.requests).toHaveLength(0); expect(server.rows).toHaveLength(2);
  });

  it('3. stops an active answer through the existing partial-save path, with exactly one request', async () => {
    const { chat, storage } = await session(async function* (signal) { yield { type: 'delta', text: 'A partial answer' }; await untilAborted(signal); });
    const c = chat.current(null); chat.edit(c, 'Question'); const sending = chat.send(c);
    await vi.waitFor(() => expect(c.liveText).toBe('A partial answer'));
    storage.retire(); await sending;
    expect(chat.branch(c)?.messages.at(-1)?.payload).toMatchObject({ role: 'assistant', text: 'A partial answer', status: 'interrupted' });
    expect(server.rows).toHaveLength(3); expect(server.requests).toHaveLength(1); expect(c.phase).toBe('idle');
    await chat.retry(c); expect(server.requests).toHaveLength(1);
  });

  it('4. keeps a newer draft typed during an in-flight save, and other composers, visible after retirement', async () => {
    const { chat, storage } = await session(async function* () { yield { type: 'delta', text: 'unrequested' }; yield done; });
    const c = chat.current(null), gate = delay();
    const other = chat.newChat('dddddddd-0000-4000-8000-000000000002'); chat.edit(other, 'Other draft');
    chat.chooseDraft(c.id); chat.edit(c, 'First question'); server.pause = () => gate.promise;
    const sending = chat.send(c);
    await vi.waitFor(() => expect(c.phase).toBe('saving'));
    chat.edit(c, 'Newer follow-up');
    storage.retire(); server.pause = null; gate.resolve(); await sending;
    expect(c.draft).toBe('Newer follow-up'); expect(other.draft).toBe('Other draft');
    expect(c.issue).toBe('storage_retired'); expect(server.requests).toHaveLength(0);
    expect(chat.hasVolatileContent).toBe(true);
    expect(chat.edit(c, 'x')).toBe(false); expect(c.draft).toBe('Newer follow-up');
  });

  it('5. keeps a failed answer save visible; it is acknowledged later without another provider request', async () => {
    let calls = 0;
    const { chat, history, storage } = await session(async function* () { calls++; yield { type: 'delta', text: 'Save me' }; server.fail = true; yield done; });
    const c = chat.current(null); chat.edit(c, 'Q'); await chat.send(c);
    expect(c.issue).toBe('storage'); expect(c.answer?.[0].event.text).toBe('Save me');
    storage.retire();
    expect(c.answer?.[0].event.text).toBe('Save me'); // still readable and copyable
    await chat.retry(c); expect(calls).toBe(1);
    server.fail = false; await history.sync(); // background sync finishes work accepted before retirement
    expect(c.answer).toBeNull(); expect(calls).toBe(1); expect(server.rows).toHaveLength(3);
  });

  it('6. storage retirement keeps the account; account retirement still stops every write and notification', async () => {
    const { chat, owner, storage } = await session(async function* (signal) { yield { type: 'delta', text: 'Secret partial' }; await untilAborted(signal); });
    const c = chat.current(null); chat.edit(c, 'Question'); const sending = chat.send(c);
    await vi.waitFor(() => expect(c.liveText).toBe('Secret partial'));
    const listener = vi.fn(); chat.subscribe(listener);
    owner.abort(); // the login ended (another tab signed out) before the newer tab's update arrived
    storage.retire(); await sending;
    expect(listener).not.toHaveBeenCalled(); expect(server.rows).toHaveLength(2); expect(c.answer).toBeNull();
    // A retired page that is still signed in keeps its history readable and syncing.
    server.rows = [];
    const live = await session(async function* () { yield { type: 'delta', text: 'Answer' }; yield done; });
    const d = live.chat.current(null); live.chat.edit(d, 'Kept'); await live.chat.send(d);
    live.storage.retire();
    await live.history.sync();
    expect(live.chat.history.state.conversationSummaries()).toHaveLength(1);
    expect(live.chat.open(live.chat.history.state.conversationSummaries()[0].id)).not.toBeNull();
  });
});
