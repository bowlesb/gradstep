// Gate 1: real WebCrypto and spec IndexedDB. No hosted requests or provider calls.
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { JournalDependencies, JournalScope, StoredDraft } from '../src/lib/journal';
import type { PrivateEvent } from '../src/lib/events';
import { generateBundle, keyRing, open, seal, sealEvent } from '../src/lib/wire';
import { fromUtf8, utf8 } from '../src/lib/bytes';

const account = '11111111-2222-4333-8444-555555555555', deviceID = 'aaaaaaaa-0000-4000-8000-000000000001';
const origin = 'https://fixture.invalid', environment = 'test', deviceKey = `${environment}:${account}`;
const id = () => crypto.randomUUID();
let idb: typeof import('../src/lib/idb').idb, access: typeof import('../src/lib/idb').journalAccess;
let Journal: typeof import('../src/lib/journal').Journal, deps: JournalDependencies, scope: JournalScope;
let ring: Awaited<ReturnType<typeof keyRing>>;
const draft = (text = 'private draft secret'): StoredDraft => ({ id: id(), documentID: null, conversationID: null, head: null, revision: 1,
  textRevision: id(), text, editedAt: 100, branchRevision: id(), acknowledgedSubmissionID: null, receipt: null, discarded: false });
const root = (): PrivateEvent => ({ kind: 'conversation', entityID: id(), text: 'private title secret', parents: [], createdAt: 100 });
function locks(): JournalDependencies['lock'] {
  const tails = new Map<string, Promise<void>>();
  return async <T>(name: string, body: () => Promise<T>) => {
    const prior = tails.get(name) ?? Promise.resolve();
    let release!: () => void;
    const mine = new Promise<void>(resolve => { release = resolve; });
    tails.set(name, mine);
    await prior;
    try { return await body(); } finally { release(); if (tails.get(name) === mine) tails.delete(name); }
  };
}
async function newScope(lifetime = 'login-one', current = () => true): Promise<JournalScope> {
  const fence = await idb.admit(deviceKey, origin, lifetime, id(), current);
  return { ...scope, origin, environment, account, deviceKey, deviceID, localKey: scope?.localKey ?? await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']),
    lifetime, fence, current };
}
beforeEach(async () => {
  vi.resetModules(); vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange);
  ({ idb, journalAccess: access } = await import('../src/lib/idb'));
  ({ Journal } = await import('../src/lib/journal'));
  scope = undefined as never;
  scope = await newScope();
  await idb.putDevice(scope.fence, { deviceID, localKey: scope.localKey }, scope.current);
  deps = { access, lock: locks() }; ring = await keyRing(generateBundle(account));
});
afterEach(() => vi.unstubAllGlobals());

it('restores sealed drafts, exact local outbox bytes and a complete pull checkpoint', async () => {
  const first = await Journal.open(scope, deps), d = draft();
  await first.journal.checkpointDraft(d);
  const envelope = await sealEvent(root(), id(), deviceID, ring);
  await first.journal.appendLocal([envelope]);
  await first.journal.acknowledge([envelope.id]);
  const a = await Journal.open(await newScope(), deps);
  expect(a.snapshot.cursor).toBe(0); // append acknowledgement is never a complete pull cursor
  expect(a.snapshot.events[0].envelope).toEqual(envelope);
  expect(a.snapshot.drafts).toEqual([d]);
  await a.journal.commitPull([{ cursor: 1, envelope }], 1);
  const restored = await Journal.open(await newScope(), deps);
  expect(restored.snapshot.cursor).toBe(1); expect(restored.snapshot.outbox).toEqual([]);
  const raw = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  expect(JSON.stringify(raw)).not.toContain('private');
  expect(scope.localKey.extractable).toBe(false);
});

it('a delayed submission merges newer typing and branch choice, and only exact receipt acknowledgement advances its head', async () => {
  const { journal } = await Journal.open(scope, deps), captured = draft('sent text');
  await journal.checkpointDraft(captured);
  const newer = { ...captured, revision: 2, textRevision: id(), text: 'later typed text' };
  await journal.checkpointDraft(newer);
  const conversationID = id(), question = id(), rootID = id();
  const receipt = { submissionID: question, eventIDs: [rootID, question], textRevision: captured.textRevision, revision: captured.revision, branchRevision: captured.branchRevision };
  const a = await sealEvent({ ...root(), entityID: conversationID }, rootID, deviceID, ring);
  const b = await sealEvent({ kind: 'message', entityID: id(), parents: [rootID], conversationID, role: 'user', status: 'complete', text: captured.text }, question, deviceID, ring);
  await journal.appendLocal([a, b], { draft: { ...captured, conversationID, head: question, receipt } });
  let restored = (await Journal.open(await newScope(), deps)).snapshot.drafts[0];
  expect(restored.text).toBe(newer.text); expect(restored.textRevision).toBe(newer.textRevision); expect(restored.revision).toBe(2);
  expect(restored.head).toBe(question); expect(restored.conversationID).toBe(conversationID);
  await journal.checkpointDraft({ ...newer, revision: 3, head: rootID, acknowledgedSubmissionID: id() });
  restored = (await Journal.open(await newScope(), deps)).snapshot.drafts[0];
  expect(restored.head).toBe(question); // an arbitrary receipt cannot roll back the captured Send head
  await journal.checkpointDraft({ ...newer, revision: 4, head: rootID, acknowledgedSubmissionID: question });
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts[0].head).toBe(rootID);
  await journal.appendLocal([a, b], { draft: { ...captured, conversationID, head: question, receipt } });
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts[0].text).toBe(newer.text); // exact retry cannot erase later typing
  await expect(journal.appendLocal([], { draft: { ...captured, conversationID, head: id(), receipt: { ...receipt, submissionID: id() } } })).rejects.toBeDefined();
});

it('discard retains a tombstone and rejects both delayed saves and deletion of a newer revision', async () => {
  const { journal } = await Journal.open(scope, deps), d = draft();
  await journal.checkpointDraft({ ...d, revision: 3 });
  await expect(journal.discardDraft(d.id, 2, d)).rejects.toMatchObject({ code: 'journal_stale' });
  await journal.discardDraft(d.id, 3, d);
  await expect(journal.checkpointDraft({ ...d, revision: 9 })).rejects.toMatchObject({ code: 'journal_discarded' });
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts[0]).toMatchObject({ discarded: true, text: '' });
});

it('same-login writers coexist; a later login fences stale opens, pending journal writes and key-record callbacks', async () => {
  const a = await Journal.open(scope, deps), peer = await newScope(), b = await Journal.open(peer, deps);
  await a.journal.checkpointDraft(draft('first tab')); await b.journal.checkpointDraft(draft('second tab'));
  const freshScope = await newScope('login-two'), fresh = await Journal.open(freshScope, deps);
  await expect(Journal.open(scope, deps)).rejects.toMatchObject({ code: 'journal_retired' });
  await expect(a.journal.checkpointDraft(draft('stale'))).rejects.toMatchObject({ code: 'journal_retired' });
  expect(await idb.putDevice(scope.fence, { deviceID: id() }, () => true)).toBe(false);
  await fresh.journal.checkpointDraft(draft('new login'));
  await idb.retireWriter(freshScope.fence);
  await expect(fresh.journal.checkpointDraft(draft('retired writer'))).rejects.toMatchObject({ code: 'journal_retired' });
  expect((await Journal.open(await newScope('login-two'), deps)).snapshot.drafts).toHaveLength(3);
});

it('Forget atomically retires keys and the account partition; late opens cannot recreate either', async () => {
  const { journal } = await Journal.open(scope, deps);
  await journal.checkpointDraft(draft());
  await idb.forgetDevice(deviceKey);
  await expect(journal.checkpointDraft(draft())).rejects.toMatchObject({ code: 'journal_retired' });
  await expect(Journal.open(scope, deps)).rejects.toMatchObject({ code: 'journal_retired' });
  expect(await idb.get('devices', deviceKey)).toBeUndefined();
  expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual([]);
  const next = await newScope();
  expect(next.fence.incarnation).not.toBe(scope.fence.incarnation);
  expect(await idb.putDevice(scope.fence, { deviceID }, () => true)).toBe(false);
});

it.each(['head', 'draft', 'event'])('a missing %s record is damaged, never an empty successful journal', async kind => {
  const { journal } = await Journal.open(scope, deps); await journal.checkpointDraft(draft());
  await journal.appendLocal([await sealEvent(root(), id(), deviceID, ring)]);
  const rows = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  const key = rows.find(([key]) => kind === 'head' ? key.endsWith(':head') : key.includes(kind === 'draft' ? ':d:' : ':e:'))![0];
  await idb.delete('journal', key);
  await expect(Journal.open(await newScope(), deps)).rejects.toMatchObject({ code: 'journal_damaged' });
  expect((await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).length).toBe(rows.length - 1);
});

it('unknown authenticated formats preserve bytes and ask for a newer reader', async () => {
  await Journal.open(scope, deps);
  const [key, bytes] = (await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`))[0];
  const aad = utf8(`gradstep/web-journal/v1/head\n${environment}\n${account}\n${origin}\n`);
  const head = JSON.parse(fromUtf8(await open(scope.localKey, bytes, aad)));
  const newer = await seal(scope.localKey, utf8(JSON.stringify({ ...head, format: 2 })), aad);
  await idb.put('journal', key, newer);
  await expect(Journal.open(await newScope(), deps)).rejects.toMatchObject({ code: 'journal_newer' });
  expect(await access.get(key)).toEqual(newer);
});

it('quota abort keeps the previous checkpoint; ambiguous successful completion reconciles its exact sealed receipt', async () => {
  const { journal } = await Journal.open(scope, deps), d = draft(); await journal.checkpointDraft(d);
  const commit = deps.access.commit.bind(deps.access);
  deps.access = { ...access, commit: async () => { throw Object.assign(new Error('storage_quota'), { code: 'storage_quota' }); } };
  await expect(journal.checkpointDraft({ ...d, revision: 2, text: 'quota update', textRevision: id() })).rejects.toMatchObject({ code: 'journal_quota' });
  deps.access = access;
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts[0].text).toBe(d.text);
  deps.access = { ...access, commit: async (...args) => { await commit(...args); throw new Error('lost completion'); } };
  const newest = { ...d, revision: 3, textRevision: id(), text: 'committed despite callback loss' };
  await journal.checkpointDraft(newest);
  deps.access = access;
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts[0].text).toBe(newest.text);
});

it('rebase rejects a plan after a concurrent descendant and remaps drafts/turns atomically when replanned', async () => {
  const { journal } = await Journal.open(scope, deps), rootID = id(), conversation = id(), childID = id();
  const original = await sealEvent({ ...root(), entityID: conversation }, rootID, deviceID, ring);
  await journal.appendLocal([original]);
  const d = { ...draft(), conversationID: conversation, head: rootID }; await journal.checkpointDraft(d);
  const turn = { id: id(), entityID: id(), composerID: d.id, conversationID: conversation, documentID: null, questionID: rootID, operationID: id(), requestDigest: 'a'.repeat(64), text: 'partial', startedAt: 100, updatedAt: 200 };
  await journal.beginTurn(turn);
  const expected = journal.revision;
  const peer = (await Journal.open(await newScope(), deps)).journal;
  const child = await sealEvent({ kind: 'message', entityID: id(), parents: [rootID], conversationID: conversation, role: 'user', status: 'complete', text: 'child' }, childID, deviceID, ring);
  await peer.appendLocal([child]);
  const replacement = await sealEvent({ ...root(), entityID: conversation }, id(), deviceID, ring);
  await expect(journal.rebase([{ old: rootID, envelope: replacement }], deviceID, expected)).rejects.toMatchObject({ code: 'journal_conflict' });
  await journal.refresh();
  const newChild = await sealEvent({ kind: 'message', entityID: id(), parents: [replacement.id], conversationID: conversation, role: 'user', status: 'complete', text: 'child' }, id(), deviceID, ring);
  await journal.rebase([{ old: rootID, envelope: replacement }, { old: childID, envelope: newChild }], deviceID, journal.revision);
  const saved = (await Journal.open(await newScope(), deps)).snapshot;
  expect(saved.outbox).toEqual([replacement.id, newChild.id]);
  expect(saved.drafts[0].head).toBe(replacement.id); expect(saved.turns[0].questionID).toBe(replacement.id);
});

it('a direct refresh latches authenticated-history decoder failure and refuses further private writes', async () => {
  const { journal } = await Journal.open(scope, deps);
  journal.subscribe(() => { throw Object.assign(new Error('invalid encrypted payload'), { code: 'invalid_event' }); });
  const faults: unknown[] = []; journal.subscribeFault(error => faults.push(error));
  const peer = (await Journal.open(await newScope(), deps)).journal;
  await peer.appendLocal([await sealEvent(root(), id(), deviceID, ring)]);
  const before = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  await expect(journal.refresh()).rejects.toMatchObject({ code: 'journal_damaged' });
  expect(journal.active).toBe(false); expect(faults).toHaveLength(1);
  await expect(journal.checkpointDraft(draft())).rejects.toMatchObject({ code: 'journal_retired' });
  expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual(before);
});
