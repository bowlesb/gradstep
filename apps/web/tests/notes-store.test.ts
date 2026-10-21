// Notes storage and sync: atomic local commit of blobs + note + entry in the encrypted journal, blob upload before the
// entry event, exact retries, quota/offline holds that never block chats, on-demand image fetch with verified bytes and
// revocable object URLs. Real WebCrypto and spec IndexedDB; the server log and note-assets function are fakes.
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { deflateSync } from 'node:zlib';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { type Bytes, fromBytea, sha256, sha256Hex, toBytea, utf8 } from '../src/lib/bytes';
import type { JournalDependencies, JournalScope } from '../src/lib/journal';
import type { BlobTransport } from '../src/lib/notes-store';
import { generateBundle, keyRing, openEvent } from '../src/lib/wire';

const server = vi.hoisted(() => ({ rows: [] as any[], appends: [] as string[] }));
vi.mock('../src/lib/backend', async original => {
  const actual = await original<typeof import('../src/lib/backend')>();
  return { ...actual, rpc: async (name: string, p: any) => {
    if (name === 'v1_append_event') {
      let row = server.rows.find(e => e.id === p.p_id);
      if (row && row.ciphertext !== p.p_ciphertext) throw new actual.BackendError('event_conflict');
      if (!row) { row = { id: p.p_id, device_id: p.p_device_id, epoch: p.p_epoch, format: p.p_format, ciphertext: p.p_ciphertext,
        ciphertext_sha256: toBytea(await sha256(fromBytea(p.p_ciphertext))), cursor: server.rows.length + 1 }; server.rows.push(row); }
      server.appends.push(p.p_id);
      return row.cursor;
    }
    if (name === 'v3_pull_events') { const events = server.rows.filter(e => e.cursor > p.p_after).slice(0, p.p_limit); return { events, next_cursor: events.at(-1)?.cursor ?? p.p_after, has_more: false }; }
    return null;
  } };
});

const account = '11111111-2222-4333-8444-555555555555', deviceID = 'aaaaaaaa-0000-4000-8000-000000000001';
const origin = 'https://fixture.invalid', environment = 'test', deviceKey = `${environment}:${account}`;
let idb: typeof import('../src/lib/idb').idb, access: typeof import('../src/lib/idb').journalAccess;
let Journal: typeof import('../src/lib/journal').Journal, History: typeof import('../src/lib/history').History, NotesStore: typeof import('../src/lib/notes-store').NotesStore;
let entryOperation: typeof import('../src/lib/notes-store').entryOperation, LIMITS: typeof import('../src/lib/journal').NOTE_BLOB_LIMITS;
let deps: JournalDependencies, scope: JournalScope, ring: Awaited<ReturnType<typeof keyRing>>;
const controllers: AbortController[] = [];

function locks(): JournalDependencies['lock'] {
  const tails = new Map<string, Promise<void>>();
  return async <T>(name: string, body: () => Promise<T>) => {
    const prior = tails.get(name) ?? Promise.resolve();
    let release!: () => void;
    const mine = new Promise<void>(resolve => { release = resolve; });
    tails.set(name, mine); await prior;
    try { return await body(); } finally { release(); if (tails.get(name) === mine) tails.delete(name); }
  };
}
async function newScope(lifetime = 'login-one'): Promise<JournalScope> {
  const current = () => true, fence = await idb.admit(deviceKey, origin, lifetime, crypto.randomUUID(), current);
  return { origin, environment, account, deviceKey, deviceID, localKey: scope?.localKey ?? await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']),
    lifetime, fence, current };
}
/** A fake note-assets function: blob ID → bytes, idempotent for the same digest. */
function assets() {
  const stored = new Map<string, Bytes>(), puts: { id: string; sha: string; bytes: number }[] = [];
  let failure: Error | null = null, tamper = false;
  const transport: BlobTransport = {
    async put(id, body, sha) {
      if (failure) throw failure;
      if (await sha256Hex(body) !== sha) throw new Error('digest mismatch');
      const prior = stored.get(id);
      if (prior && await sha256Hex(prior) !== sha) { const { BackendError } = await import('../src/lib/backend'); throw new BackendError('request_failed', 409); }
      stored.set(id, body.slice()); puts.push({ id, sha, bytes: body.length });
    },
    async get(id, bytes) {
      if (failure) throw failure;
      const body = stored.get(id); if (!body) { const { BackendError } = await import('../src/lib/backend'); throw new BackendError('request_failed', 404); }
      if (body.length !== bytes) throw new Error('length');
      const out = body.slice(); if (tamper) out[out.length - 1] ^= 1; return out;
    },
  };
  return { transport, stored, puts, fail: (e: Error | null) => { failure = e; }, tamper: (on: boolean) => { tamper = on; } };
}
function png(width: number, height: number): Bytes {
  const crc = (b: Uint8Array) => { let c = ~0; for (const x of b) { c ^= x; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); } return ~c >>> 0; };
  const chunk = (type: string, data: Uint8Array) => { const out = new Uint8Array(12 + data.length), v = new DataView(out.buffer);
    v.setUint32(0, data.length); out.set(utf8(type), 4); out.set(data, 8); v.setUint32(8 + data.length, crc(out.subarray(4, 8 + data.length))); return out; };
  const ihdr = new Uint8Array(13), v = new DataView(ihdr.buffer); v.setUint32(0, width); v.setUint32(4, height); ihdr.set([8, 2, 0, 0, 0], 8);
  return Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...chunk('IHDR', ihdr), ...chunk('IDAT', deflateSync(new Uint8Array((width * 3 + 1) * height))), ...chunk('IEND', new Uint8Array())]);
}
// The thumbnail is a JPEG header with matching SOF dimensions (only headers are checked without a browser decoder).
const jpeg = (w: number, h: number): Bytes => Uint8Array.from([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xff, 0xd9]);
const image = () => ({ full: { bytes: png(40, 20), type: 'image/png' as const, width: 40, height: 20 }, thumb: { bytes: jpeg(40, 20), type: 'image/jpeg' as const, width: 40, height: 20 } });
const source = { kind: 'arxiv' as const, title: 'Direct Preference Optimization', authors: ['Rafael Rafailov'], sourceID: '2305.18290', revision: 3, url: 'https://arxiv.org/abs/2305.18290v3', section: '4 Method', label: null };

async function session(fake = assets(), withJournal = true) {
  const owner = new AbortController(); controllers.push(owner);
  const opened = withJournal ? await Journal.open(await newScope(), deps) : null;
  const history = new History(account, deviceID, ring, owner.signal, async () => ring, opened?.journal);
  if (opened) await history.restore(opened.snapshot);
  const store = new NotesStore(account, history, owner.signal, fake.transport);
  return { owner, history, store, journal: opened?.journal ?? null, fake };
}
async function decrypted(id: string) { const row = server.rows.find(r => r.id === id); return openEvent({ id: row.id, deviceID: row.device_id, epoch: row.epoch, format: row.format, ciphertext: fromBytea(row.ciphertext) }, ring) as Promise<Record<string, any>>; }

beforeEach(async () => {
  vi.resetModules(); vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange);
  ({ idb, journalAccess: access } = await import('../src/lib/idb'));
  ({ Journal, NOTE_BLOB_LIMITS: LIMITS } = await import('../src/lib/journal'));
  ({ History } = await import('../src/lib/history'));
  ({ NotesStore, entryOperation } = await import('../src/lib/notes-store'));
  scope = undefined as never; scope = await newScope();
  await idb.putDevice(scope.fence, { deviceID, localKey: scope.localKey }, scope.current);
  deps = { access, lock: locks() }; ring = await keyRing(generateBundle(account));
  server.rows = []; server.appends = [];
});
afterEach(() => { for (const c of controllers.splice(0)) c.abort(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

it('commits the blobs, a new note and the entry together, then uploads the blobs before the entry event', async () => {
  const s = await session();
  s.fake.fail(Object.assign(new (await import('../src/lib/backend')).BackendError('connection')));
  const op = entryOperation(), img = image();
  const saved = await s.store.saveEntry({ destination: { newTitle: 'Preference learning' }, kind: 'region', comment: 'A margin', capturedAt: 1792900060000,
    source, anchor: null, quote: null, image: img }, op);
  expect(saved).toEqual({ noteID: op.noteID, entryID: op.entryID });
  // Durable before any network: a fresh tab finds the note, the entry and both encrypted blobs.
  const reopened = await Journal.open(await newScope(), deps);
  expect(reopened.snapshot.outbox).toEqual([op.noteEventID, op.entryEventID]);
  expect(Object.values(reopened.journal.noteBlobs).map(b => b.state)).toEqual(['local', 'local']);
  const raw = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  expect(JSON.stringify(raw)).not.toContain('A margin');
  // Offline: the note root goes, the entry waits; the store says why.
  await s.history.sync();
  expect(server.appends).toEqual([op.noteEventID]);
  expect(s.history.held.has(op.entryEventID)).toBe(true);
  expect(s.store.issue).toBe('offline');
  const entry = s.store.note(op.noteID)!.entries[0];
  expect(s.store.entryState(entry)).toEqual({ pending: true, uploading: true });
  // Back online: the same blob IDs and bytes are uploaded, then the entry event.
  s.fake.fail(null); await s.store.retry();
  expect(s.fake.puts.map(p => p.id)).toEqual([entry.record.media!.full.blobID, entry.record.media!.thumb!.blobID]);
  expect(server.appends).toEqual([op.noteEventID, op.entryEventID]);
  expect(s.store.issue).toBeNull();
  expect(s.store.entryState(s.store.note(op.noteID)!.entries[0])).toEqual({ pending: false, uploading: false });
  const sent = await decrypted(op.entryEventID);
  expect(JSON.parse(sent.text)).toMatchObject({ format: 'gradstep-notes-v1', record: 'entry', entryID: op.entryID, noteID: op.noteID, counter: 1, kind: 'region' });
  expect(sent.documentID).toBeUndefined(); expect(sent.paperReference).toBeUndefined();
  // The server only ever saw ciphertext: the stored blob isn't the PNG.
  expect([...s.fake.stored.values()].some(b => b.subarray(12, 20).join() === img.full.bytes.subarray(0, 8).join())).toBe(false);
});

it('repeats Save with one identity, and sends unrelated chats while an upload is held', async () => {
  const s = await session(); const { BackendError } = await import('../src/lib/backend');
  const op = entryOperation(), img = image();
  const input = { destination: { newTitle: 'Notes' }, kind: 'region' as const, comment: '', capturedAt: 1, source, anchor: null, quote: null, image: img };
  await s.store.saveEntry(input, op); await s.store.saveEntry(input, op);
  expect(s.store.view().notes).toHaveLength(1); expect(s.store.view().notes[0].entries).toHaveLength(1);
  s.fake.fail(new BackendError('throttled', 429));
  const chat = crypto.randomUUID();
  await s.history.commit([{ id: chat, event: { kind: 'conversation', entityID: crypto.randomUUID(), parents: [], text: 'A chat', createdAt: 2 } }]);
  await s.history.sync();
  expect(server.appends).toEqual([op.noteEventID, chat]);
  expect(s.store.issue).toBe('quota');
  // A comment edit made while the entry waits, waits with it (it names the held event as its parent).
  await s.store.editComment(op.entryID, 'Later thought');
  await s.history.sync();
  expect(server.appends).toEqual([op.noteEventID, chat]);
  s.fake.fail(null); await s.store.retry();
  expect(server.appends.slice(2)).toHaveLength(2);
  expect(server.appends[2]).toBe(op.entryEventID);
  expect(s.fake.puts).toHaveLength(2);
  expect(s.store.note(op.noteID)!.entries[0].record.comment).toBe('Later thought');
});

it('adds to an existing note at the next counter; text entries need no blob or journal', async () => {
  const s = await session(assets(), false);
  await s.history.sync(); // without the journal, writes wait for a completed sync
  const noteID = await s.store.createNote('Reading');
  await s.store.saveEntry({ destination: { noteID }, kind: 'text', comment: 'First', capturedAt: 1, source: null, anchor: null, quote: null }, entryOperation());
  await s.store.saveEntry({ destination: { noteID }, kind: 'quote', comment: '', capturedAt: 2, source, quote: 'A passage', anchor: { manifestSHA256: null, rendererRevision: null, blockIDs: ['b-1'], rects: [], viewport: null, quote: 'A passage' } }, entryOperation());
  expect(s.store.note(noteID)!.entries.map(e => [e.record.counter, e.record.kind])).toEqual([[1, 'text'], [2, 'quote']]);
  await expect(s.store.saveEntry({ destination: { noteID }, kind: 'region', comment: '', capturedAt: 3, source, anchor: null, quote: null, image: image() }, entryOperation()))
    .rejects.toMatchObject({ code: 'needs_storage' });
  await s.store.deleteEntry(s.store.note(noteID)!.entries[0].id);
  await s.store.saveEntry({ destination: { noteID }, kind: 'text', comment: 'Third', capturedAt: 4, source: null, anchor: null, quote: null }, entryOperation());
  expect(s.store.note(noteID)!.entries.map(e => e.record.counter)).toEqual([2, 3]);
  await s.store.renameNote(noteID, '  Reading list ');
  expect(s.store.note(noteID)!.title).toBe('Reading list');
  await s.store.deleteNote(noteID);
  expect(s.store.view().notes).toEqual([]);
});

it('fetches images on demand: local first, then downloaded, verified and cached encrypted; revokes URLs on retire', async () => {
  const fake = assets(), a = await session(fake);
  const op = entryOperation(), img = image();
  await a.store.saveEntry({ destination: { newTitle: 'Figures' }, kind: 'region', comment: '', capturedAt: 1, source, anchor: null, quote: null, image: img }, op);
  await a.history.sync();
  const media = a.store.note(op.noteID)!.entries[0].record.media!;
  const created: string[] = [], revoked: string[] = [];
  vi.spyOn(URL, 'createObjectURL').mockImplementation(() => { const u = `blob:test/${created.length}`; created.push(u); return u; });
  vi.spyOn(URL, 'revokeObjectURL').mockImplementation(u => { revoked.push(u); });
  const get = vi.spyOn(fake.transport, 'get');
  expect(await a.store.image(media.full)).toBe('blob:test/0');
  expect(await a.store.image(media.full)).toBe('blob:test/0'); // memory cache
  expect(get).not.toHaveBeenCalled();
  a.store.retire();
  await Promise.resolve(); await Promise.resolve();
  expect(revoked).toEqual(['blob:test/0']);
  // Another browser of the same account: nothing local, so it downloads, checks and keeps an encrypted copy.
  await idb.forgetDevice(deviceKey);
  scope = await newScope('login-two'); await idb.putDevice(scope.fence, { deviceID, localKey: scope.localKey }, scope.current);
  const b = await session(fake);
  await b.history.sync();
  const remote = b.store.note(op.noteID)!.entries[0].record.media!;
  fake.tamper(true);
  await expect(b.store.image(remote.thumb!)).rejects.toMatchObject({ code: 'blob_digest' });
  fake.tamper(false);
  await b.store.image(remote.thumb!);
  expect(get).toHaveBeenCalledTimes(2);
  await vi.waitFor(() => expect(b.journal!.noteBlobs[remote.thumb!.blobID]?.state).toBe('ready'));
  expect(await b.journal!.readBlob(remote.thumb!.blobID)).toEqual(fake.stored.get(remote.thumb!.blobID));
});

it('keeps blob records outside the journal range an older release counts, and forgetting the browser removes them', async () => {
  const s = await session();
  await s.store.saveEntry({ destination: { newTitle: 'Notes' }, kind: 'region', comment: '', capturedAt: 1, source, anchor: null, quote: null, image: image() }, entryOperation());
  const { journalPrefix } = await import('../src/lib/journal');
  const prefix = journalPrefix(environment, account, origin), opened = await Journal.open(await newScope(), deps);
  // An older release requires exactly head + events + drafts + turns under its prefix.
  expect((await access.range(prefix, `${prefix}\uffff`)).length).toBe(1 + opened.snapshot.events.length);
  expect((await access.range(`${deviceKey}:notes:`, `${deviceKey}:notes:\uffff`)).length).toBe(2);
  await idb.forgetDevice(deviceKey);
  expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual([]);
});

it('evicts only confirmed copies when the cache is full; unsynced crops stay', async () => {
  const fake = assets(), s = await session(fake);
  const before = { ...LIMITS };
  try {
    const keep = entryOperation();
    await s.store.saveEntry({ destination: { newTitle: 'Notes' }, kind: 'region', comment: '', capturedAt: 1, source, anchor: null, quote: null, image: image() }, keep);
    const local = Object.keys(s.journal!.noteBlobs);
    LIMITS.readyBytes = 300;
    for (let i = 0; i < 3; i++) await s.journal!.cacheBlob(crypto.randomUUID(), new Uint8Array(200).fill(i));
    const states = Object.entries(s.journal!.noteBlobs);
    expect(states.filter(([, b]) => b.state === 'local').map(([id]) => id).sort()).toEqual(local.sort());
    expect(states.filter(([, b]) => b.state === 'ready')).toHaveLength(1);
    LIMITS.localBytes = 10;
    await expect(s.store.saveEntry({ destination: { newTitle: 'More' }, kind: 'region', comment: '', capturedAt: 1, source, anchor: null, quote: null, image: image() }, entryOperation()))
      .rejects.toMatchObject({ code: 'local_capacity' });
    expect(s.store.view().notes.map(n => n.title)).toEqual(['Notes']); // nothing partial was committed
  } finally { Object.assign(LIMITS, before); }
});
