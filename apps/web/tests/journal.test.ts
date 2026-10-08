// Gate 1: real WebCrypto and spec IndexedDB. No hosted requests or provider calls.
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { JournalDependencies, JournalScope, StoredDraft } from '../src/lib/journal';
import type { PrivateEvent } from '../src/lib/events';
import { generateBundle, keyRing, open, seal, sealEvent } from '../src/lib/wire';
import { fromUtf8, utf8, fromBytea, toBytea, sha256 } from '../src/lib/bytes';
const server = vi.hoisted(() => ({ rows: [] as any[], fail: false, loseAck: false, requests: 0 }));
vi.mock('../src/lib/backend', async original => {
  const actual = await original<typeof import('../src/lib/backend')>();
  return { ...actual, rpc: async (name: string, p: any) => {
    if (name === 'v1_append_event') {
      if (server.fail) throw new actual.BackendError('connection');
      let row = server.rows.find(e => e.id === p.p_id);
      if (row && row.ciphertext !== p.p_ciphertext) throw new actual.BackendError('event_conflict');
      if (!row) { row = { id: p.p_id, device_id: p.p_device_id, epoch: p.p_epoch, format: p.p_format, ciphertext: p.p_ciphertext,
        ciphertext_sha256: toBytea(await sha256(fromBytea(p.p_ciphertext))), cursor: server.rows.length + 1 }; server.rows.push(row); }
      if (server.loseAck) { server.loseAck = false; throw new actual.BackendError('connection'); }
      return row.cursor;
    }
    if (name === 'v2_pull_events') { const events = server.rows.filter(e => e.cursor > p.p_after).slice(0, p.p_limit); return { events, next_cursor: events.at(-1)?.cursor ?? p.p_after, has_more: false }; }
    if (name === 'v1_credit_balance') return { available: 100, reserved: 0 };
    return null;
  } };
});

const account = '11111111-2222-4333-8444-555555555555', deviceID = 'aaaaaaaa-0000-4000-8000-000000000001';
const origin = 'https://fixture.invalid', environment = 'test', deviceKey = `${environment}:${account}`;
const id = () => crypto.randomUUID();
const published = JSON.parse(readFileSync(new URL('./fixtures/chat-profiles-v1.json', import.meta.url), 'utf8'));
let idb: typeof import('../src/lib/idb').idb, access: typeof import('../src/lib/idb').journalAccess;
let Journal: typeof import('../src/lib/journal').Journal, deps: JournalDependencies, scope: JournalScope;
let ring: Awaited<ReturnType<typeof keyRing>>;
let bundle: ReturnType<typeof generateBundle>;
const controllers: AbortController[] = [];
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
  deps = { access, lock: locks() }; bundle = generateBundle(account); ring = await keyRing(bundle);
  server.rows = []; server.fail = false; server.loseAck = false; server.requests = 0;
});
afterEach(() => { for (const c of controllers.splice(0)) c.abort(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

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
  const choice = { model: 'opus', effort: 'high', length: 'detailed' } as const;
  const d = { ...draft(), conversationID: conversation, head: rootID, requestedAnswer: { questionID: rootID, choice } }; await journal.checkpointDraft(d);
  const turn = { id: id(), entityID: id(), composerID: d.id, conversationID: conversation, documentID: null, questionID: rootID, operationID: id(), requestDigest: 'a'.repeat(64), requestedProfile: choice, text: 'partial', startedAt: 100, updatedAt: 200 };
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
  expect(saved.drafts[0].requestedAnswer).toEqual({ questionID: replacement.id, choice }); expect(saved.turns[0].requestedProfile).toEqual(choice);
  // A checkpoint captured before the mapping cannot restore retired references or change the captured choice.
  await journal.checkpointDraft({ ...d, revision: 2, textRevision: id(), text: 'new typing with a pre-rebase snapshot' });
  expect(await journal.draft(d.id)).toMatchObject({ head: replacement.id, requestedAnswer: { questionID: replacement.id, choice } });
  await expect(journal.checkpointDraft({ ...d, revision: 3, requestedAnswer: { questionID: rootID, choice: { ...choice, model: 'haiku' } } })).rejects.toMatchObject({ code: 'journal_conflict' });
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

// Controller journeys use the same durable journal, not a fake save API.
function editorLocks() {
  const held = new Set<string>();
  const acquire = (name: string) => { held.add(name); return () => { held.delete(name); }; };
  return { hold: async (name: string) => { if (held.has(name)) throw new Error('already owned'); return acquire(name); },
    tryHold: async (name: string) => held.has(name) ? null : acquire(name) };
}
async function controller(options: { stream?: (...args: any[]) => AsyncIterable<any>; consent?: boolean; localLocks?: ReturnType<typeof editorLocks>; scope?: JournalScope; profiles?: boolean } = {}) {
  const { History } = await import('../src/lib/history'), { ChatSession } = await import('../src/lib/chat-session');
  const owner = new AbortController(); controllers.push(owner);
  const opened = await Journal.open(options.scope ?? await newScope(), deps);
  const history = new History(account, deviceID, ring, owner.signal, async () => ring, opened.journal);
  await history.restore(opened.snapshot);
  const chat = new ChatSession(account, history, owner.signal, { journal: opened.journal, locks: options.localLocks ?? editorLocks(),
    readConsent: () => options.consent !== false, writeConsent: () => {},
    fetchProfiles: async () => options.profiles ? published : null,
    stream: options.stream ?? async function* () { server.requests++; yield { type: 'delta', text: 'A saved answer' }; yield { type: 'done', stopReason: 'end_turn', credits: 3 }; } });
  await chat.restore(opened.snapshot.drafts, opened.snapshot.turns); await history.sync();
  return { ...opened, chat, history, owner };
}
const gate = () => Promise.withResolvers<void>();

it('Discuss retries the same failed device save without adding the selected quote twice or sending', async () => {
  const { chat } = await controller(), documentID = id(), c = chat.current(documentID), anchor = { artifactID: id(), quote: 'selected passage', prefix: 'before', suffix: 'after', elementID: 'fig-2', page: 2 };
  chat.edit(c, 'my existing draft'); await chat.flushCheckpoints();
  const commit = access.commit;
  let fail = true;
  deps.access = { ...access, commit: async (...args) => { if (fail) { fail = false; throw new Error('storage_quota'); } return commit(...args); } };
  expect(await chat.discuss(documentID, 'selected passage', anchor)).toBeNull();
  expect(c.draft).toBe('About “selected passage”: my existing draft');
  expect(c.anchor).toEqual(anchor);
  expect(await chat.discuss(documentID, 'selected passage', anchor)).toBe(c);
  expect(c.draft).toBe('About “selected passage”: my existing draft');
  expect(server.requests).toBe(0); expect(server.rows).toHaveLength(0);
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts[0]).toMatchObject({ text: c.draft, anchor });
});

it('Discuss retains its passage across a cold restore and sends it only with the conversation root', async () => {
  const first = await controller(), documentID = id(), anchor = { artifactID: id(), quote: 'figure caption', prefix: '', suffix: '', elementID: 'fig-2', page: 3 };
  const prepared = await first.chat.discuss(documentID, anchor.quote, anchor);
  expect(prepared?.draft).toBe('About “figure caption”: '); expect(server.requests).toBe(0);
  first.owner.abort();
  const next = await controller({ consent: false }), c = next.chat.current(documentID);
  expect(c.anchor).toEqual(anchor); expect(c.draft).toBe(prepared!.draft);
  next.chat.edit(c, `${c.draft}Why does this differ?`); await next.chat.send(c);
  expect(next.history.state.conversationSummaries()[0].anchor).toEqual(anchor);
  expect(next.history.state.conversationBranches(c.conversationID!)[0].messages[0].payload.anchor).toBeUndefined();
  expect(server.requests).toBe(0);
});

it('a malformed Discuss anchor leaves the existing editable draft and saved checkpoint intact', async () => {
  const { chat, journal } = await controller(), documentID = id(), c = chat.current(documentID);
  chat.edit(c, 'keep my draft'); await chat.flushCheckpoints();
  const before = await journal.draft(c.id);
  expect(await chat.discuss(documentID, 'bad quote', { artifactID: id(), quote: 'bad quote', prefix: '', suffix: '', page: 251 })).toBeNull();
  expect(c.draft).toBe('keep my draft'); expect(await journal.draft(c.id)).toEqual(before); expect(journal.active).toBe(true);
});

it.each(['anchor', 'requestedAnswer'] as const)('rejects malformed sealed draft %s fields without replacing the previous record', async field => {
  const { journal } = await Journal.open(scope, deps), d = { ...draft(), documentID: id() };
  await journal.checkpointDraft(d);
  const before = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  const bad = field === 'anchor' ? { anchor: { artifactID: id(), quote: 'x', prefix: 'x'.repeat(1001), suffix: '' } }
    : { requestedAnswer: { questionID: id(), choice: { model: 'unknown', effort: 'high', length: 'detailed' } } };
  await expect(journal.checkpointDraft({ ...d, revision: 2, ...bad } as StoredDraft)).rejects.toMatchObject({ code: 'journal_damaged' });
  expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual(before);
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts).toEqual([d]);
});

it('the local question binding survives a lost acknowledgement, newer edits and reload; explicit retry uses it', async () => {
  const first = await controller({ profiles: true }), c = first.chat.current(null);
  const choice = { model: 'opus', effort: 'high', length: 'detailed' } as const;
  await first.chat.profiles.load(); first.chat.setProfile(c, choice); first.chat.edit(c, 'Keep these answer settings');
  const started = gate(), release = gate(), commit = first.history.commit.bind(first.history);
  vi.spyOn(first.history, 'commit').mockImplementationOnce(async (...args) => { started.resolve(); await release.promise; return commit(...args); });
  server.loseAck = true; const sending = first.chat.send(c); await started.promise;
  first.chat.setProfile(c, { model: 'haiku', effort: 'low', length: 'brief' }); first.chat.edit(c, 'A newer unsent question'); await first.chat.flushCheckpoints();
  release.resolve(); await sending; await first.chat.flushCheckpoints();
  const saved = (await Journal.open(await newScope(), deps)).snapshot.drafts[0];
  expect(saved).toMatchObject({ text: 'A newer unsent question', requestedAnswer: { questionID: c.question!.id, choice } });
  expect(first.history.state.events.get(c.question!.id)?.payload.profile).toBeUndefined(); expect(server.requests).toBe(0);
  first.owner.abort();
  const requests: any[] = [], next = await controller({ profiles: true, stream: async function* (_account, request) {
    requests.push(request); server.requests++;
    yield { type: 'delta', text: 'Explicit answer' }; yield { type: 'done', stopReason: 'end_turn', credits: 1 };
  } });
  const restored = next.chat.current(null), turn = vi.spyOn(next.journal, 'beginTurn');
  expect(restored.draft).toBe('A newer unsent question'); expect(next.chat.retryProfile(restored)).toEqual(choice);
  expect(server.requests).toBe(0); next.chat.setProfile(restored, { model: 'haiku', effort: 'low', length: 'brief' });
  await next.chat.retry(restored);
  expect(requests).toHaveLength(1); expect(requests[0].profile).toEqual(choice);
  expect(turn.mock.calls[0][0].requestedProfile).toEqual(choice); expect(restored.draft).toBe('A newer unsent question');
});

it('discarding later unsent text atomically transfers the saved question choice to an owned empty composer', async () => {
  const owned = editorLocks(), first = await controller({ profiles: true, consent: false, localLocks: owned });
  const c = first.chat.current(null), choice = { model: 'opus', effort: 'high', length: 'detailed' } as const;
  await first.chat.profiles.load(); first.chat.setProfile(c, choice); first.chat.edit(c, 'Saved question'); await first.chat.send(c); await first.chat.consent(c, false);
  first.chat.edit(c, 'Later text to discard'); await first.chat.flushCheckpoints(); await first.chat.discardDraft(c.id);
  const replacement = first.chat.current(null);
  expect(replacement.id).not.toBe(c.id); expect(replacement.draft).toBe(''); expect(await owned.tryHold(`gradstep.composer.${replacement.id}`)).toBeNull();
  const saved = (await Journal.open(await newScope(), deps)).snapshot.drafts;
  expect(saved.find(d => d.id === c.id)?.discarded).toBe(true);
  expect(saved.find(d => d.id === replacement.id)).toMatchObject({ text: '', requestedAnswer: { questionID: c.question!.id, choice } });
  first.owner.abort(); const next = await controller({ profiles: true });
  expect(next.chat.current(null).id).toBe(replacement.id); expect(next.chat.retryProfile(next.chat.current(null))).toEqual(choice); expect(server.requests).toBe(0);
});

it.each(['generated', 'renamed'] as const)('a delayed %s title replans after a peer revision, preserving a rename', async source => {
  const first = await controller({ consent: false }), c = first.chat.current(null);
  first.chat.edit(c, 'Untitled question'); await first.chat.send(c);
  const peer = await controller({ consent: false }), peerSource = source === 'generated' ? 'renamed' : 'generated';
  const peerID = id(), titleID = id(), answerID = id(), append = first.journal.appendLocal.bind(first.journal);
  vi.spyOn(first.journal, 'appendLocal').mockImplementationOnce(async (...args) => {
    await peer.history.commit([], { title: { id: peerID, conversationID: c.conversationID!, text: peerSource === 'renamed' ? 'My title' : 'Automatic title', source: peerSource } });
    return append(...args);
  });
  await first.history.commit([{ id: answerID, event: { kind: 'message', entityID: id(), parents: [c.question!.id], conversationID: c.conversationID!, role: 'assistant', status: 'complete', text: 'saved answer' } }],
    { title: { id: titleID, conversationID: c.conversationID!, text: source === 'renamed' ? 'My title' : 'Automatic title', source } });
  await first.history.sync();
  expect(first.history.state.conversationSummaries()[0]).toMatchObject({ title: 'My title', titleSource: 'renamed' });
  if (source === 'generated') expect(first.history.state.events.has(titleID)).toBe(false);
  else expect(first.history.state.events.get(titleID)?.payload.parents).toEqual([peerID]);
  const opened = await Journal.open(await newScope(), deps), cold = await restorer(opened);
  expect(cold.history.state.conversationSummaries()[0]).toMatchObject({ title: 'My title', titleSource: 'renamed' });
  expect(opened.snapshot.outbox).toEqual([]); expect(server.requests).toBe(0);
});

it('typing committed while a captured Send waits survives both its receipt and controller restoration', async () => {
  const { chat, history } = await controller({ consent: false }), c = chat.current(null);
  chat.edit(c, 'captured question'); await chat.flushCheckpoints();
  const started = gate(), release = gate(), commit = history.commit.bind(history);
  vi.spyOn(history, 'commit').mockImplementation(async (...args) => { started.resolve(); await release.promise; return commit(...args); });
  const sending = chat.send(c); await started.promise;
  chat.edit(c, 'newer text typed during encryption'); await chat.flushCheckpoints();
  release.resolve(); await sending;
  expect(c.draft).toBe('newer text typed during encryption'); expect(server.requests).toBe(0);
  const saved = (await Journal.open(await newScope(), deps)).snapshot.drafts[0];
  expect(saved.text).toBe(c.draft); expect(saved.conversationID).toBe(c.conversationID); expect(saved.receipt!.submissionID).toBe(c.question!.id);
});

it('failed discard leaves text reachable; an edit during successful discard gets a new composer identity', async () => {
  const { chat, journal } = await controller(), c = chat.current(null);
  chat.edit(c, 'retain on failed deletion'); await chat.flushCheckpoints();
  const discard = journal.discardDraft.bind(journal);
  vi.spyOn(journal, 'discardDraft').mockRejectedValueOnce(new Error('storage_quota'));
  await chat.discardDraft(c.id); expect(chat.composers.get(c.id)?.draft).toBe('retain on failed deletion');
  const started = gate(), release = gate();
  vi.spyOn(journal, 'discardDraft').mockImplementation(async (...args) => { started.resolve(); await release.promise; return discard(...args); });
  const deleting = chat.discardDraft(c.id); await started.promise; chat.edit(c, 'newer text during discard'); release.resolve(); await deleting;
  const newer = chat.current(null); expect(newer.id).not.toBe(c.id); expect(newer.draft).toBe('newer text during discard'); await chat.flushCheckpoints();
  const saved = (await Journal.open(await newScope(), deps)).snapshot.drafts;
  expect(saved.find(d => d.id === c.id)?.discarded).toBe(true); expect(saved.find(d => d.id === newer.id)?.text).toBe(newer.draft);
});

it('lost append acknowledgement restores exact outbox bytes and never automatically requests an answer', async () => {
  const first = await controller(), c = first.chat.current(null);
  first.chat.edit(c, 'question saved before failure'); server.loseAck = true; await first.chat.send(c);
  expect(c.issue).toBe('question_unsaved'); expect(server.requests).toBe(0);
  const exact = { ...server.rows[0] }, before = (await Journal.open(await newScope(), deps)).snapshot;
  expect(before.outbox).toHaveLength(2);
  first.owner.abort(); await Promise.resolve();
  const next = await controller();
  expect(server.rows[0]).toEqual(exact); expect(server.rows).toHaveLength(2); expect(server.requests).toBe(0);
  expect(next.history.unsaved).toBe(0); await next.chat.retry(next.chat.current(null));
  expect(server.requests).toBe(1); await next.history.sync(); expect(server.rows).toHaveLength(3);
});

it('a live turn owner prevents recovery; once abandoned it reopens interrupted without a request', async () => {
  const owned = editorLocks(), first = await controller({ consent: false, localLocks: owned }), c = first.chat.current(null);
  first.chat.edit(c, 'saved question'); await first.chat.send(c);
  const turn = { id: id(), entityID: id(), composerID: c.id, conversationID: c.conversationID!, documentID: null, questionID: c.question!.id,
    operationID: id(), requestDigest: 'b'.repeat(64), text: 'committed partial', startedAt: 100, updatedAt: 200 };
  const release = await owned.hold(`gradstep.turn.${turn.id}`); await first.journal.beginTurn(turn);
  await controller({ localLocks: owned }); expect(server.rows).toHaveLength(2); expect(server.requests).toBe(0);
  release(); const recovered = await controller({ localLocks: owned });
  expect(recovered.history.state.events.get(turn.id)?.payload).toMatchObject({ text: turn.text, status: 'interrupted' });
  expect(server.requests).toBe(0); expect(server.rows).toHaveLength(3);
  expect((await Journal.open(await newScope(), deps)).snapshot.turns).toEqual([]);
});

it('a failed final save keeps its turn owned; retry saves the answer without buying a second request', async () => {
  const owned = editorLocks(), { chat, history } = await controller({ localLocks: owned }), c = chat.current(null);
  const commit = access.commit; let fail = true;
  deps.access = { ...access, commit: async (...args) => { if (fail && args[3].some(key => key.includes(':t:'))) { fail = false; throw new Error('storage_quota'); } return commit(...args); } };
  chat.edit(c, 'save the final response'); await chat.send(c); expect(c.answer).not.toBeNull(); expect(server.requests).toBe(1);
  await controller({ localLocks: owned }); expect(server.rows).toHaveLength(2);
  await chat.retry(c); await history.sync(); expect(c.answer).toBeNull(); expect(server.requests).toBe(1); expect(server.rows).toHaveLength(3);
  expect((await Journal.open(await newScope(), deps)).snapshot.turns).toEqual([]);
});

it('a failed refused-turn cleanup stays owned and its retry only erases the checkpoint', async () => {
  const owned = editorLocks(), { chat } = await controller({ localLocks: owned, stream: async function* () {
    server.requests++; yield { type: 'delta', text: 'must be discarded' }; yield { type: 'error', code: 'refused' };
  } }), c = chat.current(null);
  const commit = access.commit; let fail = true;
  deps.access = { ...access, commit: async (...args) => { if (fail && args[3].some(key => key.includes(':t:'))) { fail = false; throw new Error('storage_quota'); } return commit(...args); } };
  chat.edit(c, 'refused question'); await chat.send(c); expect(c.liveText).toBe(''); expect(c.issue).toBe('local_save');
  chat.edit(c, 'later text while cleanup is pending'); await chat.flushCheckpoints();
  await chat.discardDraft(c.id);
  expect(chat.composers.has(c.id)).toBe(true); expect(c.draft).toBe('later text while cleanup is pending'); // the cleanup action stays reachable
  await controller({ localLocks: owned }); expect(server.rows).toHaveLength(2);
  await chat.retry(c); expect(server.requests).toBe(1); expect(server.rows).toHaveLength(2);
  expect((await Journal.open(await newScope(), deps)).snapshot.turns).toEqual([]);
});

it('rotation pulls a lost acknowledgement first, then rebases only absent events and dependent local descendants', async () => {
  const { history, journal } = await controller(), rootID = id(), questionID = id(), conversationID = id();
  await history.commit([{ id: rootID, event: { ...root(), entityID: conversationID } }, { id: questionID, event: { kind: 'message', entityID: id(), parents: [rootID], conversationID, role: 'user', status: 'complete', text: 'old epoch question' } }]);
  const before = (await Journal.open(await newScope(), deps)).snapshot, oldRoot = before.events.find(e => e.envelope.id === rootID)!.envelope;
  server.rows.push({ id: rootID, device_id: deviceID, epoch: 1, format: 1, ciphertext: toBytea(oldRoot.ciphertext), ciphertext_sha256: toBytea(await sha256(oldRoot.ciphertext)), cursor: 1 });
  const secondKeys = generateBundle(account);
  ring = await keyRing({ ...bundle, epoch: 2, contentKeys: { ...bundle.contentKeys, 2: secondKeys.contentKeys[1] } });
  const descendantID = id(), peer = await controller(); // this complete sync also resolves the existing absent question
  await peer.history.commit([{ id: descendantID, event: { kind: 'message', entityID: id(), parents: [peer.history.resolve(questionID)], conversationID, role: 'assistant', status: 'interrupted', text: 'local child' } }]);
  await history.sync();
  expect(server.rows[0].id).toBe(rootID); expect(server.rows[0].ciphertext).toBe(toBytea(oldRoot.ciphertext));
  expect(history.resolve(questionID)).not.toBe(questionID); expect(server.requests).toBe(0);
  const reopened = await controller(); expect(reopened.history.state.conversationBranches(conversationID)[0].messages.map(e => e.payload.text)).toEqual(['old epoch question', 'local child']);
  expect((await Journal.open(await newScope(), deps)).snapshot.outbox).toEqual([]); expect(journal.active).toBe(true);
});

it('winning owner locks re-reads newer durable drafts and partials instead of consuming the stale open snapshot', async () => {
  const { History } = await import('../src/lib/history'), { ChatSession } = await import('../src/lib/chat-session');
  const a = (await Journal.open(scope, deps)).journal, conversationID = id(), rootID = id(), questionID = id();
  const eventRoot = await sealEvent({ ...root(), entityID: conversationID }, rootID, deviceID, ring);
  const question = await sealEvent({ kind: 'message', entityID: id(), parents: [rootID], conversationID, text: 'question', role: 'user', status: 'complete' }, questionID, deviceID, ring);
  await a.appendLocal([eventRoot, question]);
  const old = { ...draft('old draft'), conversationID, head: questionID }; await a.checkpointDraft(old);
  const turn = { id: id(), entityID: id(), composerID: old.id, conversationID, documentID: null, questionID, operationID: id(), requestDigest: 'c'.repeat(64), text: 'old partial', startedAt: 100, updatedAt: 200 };
  await a.beginTurn(turn);
  const b = await Journal.open(await newScope(), deps); // B has not yet acquired either owner lock
  await a.checkpointDraft({ ...old, revision: 2, textRevision: id(), text: 'newer durable draft' });
  await a.checkpointTurn({ ...turn, text: 'newer durable partial', updatedAt: 300 });
  const owner = new AbortController(); controllers.push(owner);
  const history = new History(account, deviceID, ring, owner.signal, async () => ring, b.journal); await history.restore(b.snapshot);
  const chat = new ChatSession(account, history, owner.signal, { journal: b.journal, locks: editorLocks() });
  await chat.restore(b.snapshot.drafts, b.snapshot.turns);
  expect(chat.current(null).draft).toBe('newer durable draft');
  expect(history.state.events.get(turn.id)?.payload).toMatchObject({ text: 'newer durable partial', status: 'interrupted' });
  expect((await Journal.open(await newScope(), deps)).snapshot.turns).toEqual([]); expect(server.requests).toBe(0);
});

async function restorer(opened: Awaited<ReturnType<typeof Journal.open>>, owned = editorLocks()) {
  const { History } = await import('../src/lib/history'), { ChatSession } = await import('../src/lib/chat-session');
  const owner = new AbortController(); controllers.push(owner);
  const history = new History(account, deviceID, ring, owner.signal, async () => ring, opened.journal); await history.restore(opened.snapshot);
  return { owner, history, owned, chat: new ChatSession(account, history, owner.signal, { journal: opened.journal, locks: owned }) };
}

it.each(['', 'older partial'])('turn recovery compares its exact %j checkpoint before retiring it', async text => {
  const first = await controller({ consent: false }), c = first.chat.current(null);
  first.chat.edit(c, 'question'); await first.chat.send(c);
  const turn = { id: id(), entityID: id(), composerID: c.id, conversationID: c.conversationID!, documentID: null, questionID: c.question!.id,
    operationID: id(), requestDigest: 'd'.repeat(64), text, startedAt: 100, updatedAt: 200 };
  await first.journal.beginTurn(turn);
  const opened = await Journal.open(await newScope(), deps), next = await restorer(opened);
  const read = opened.journal.turn.bind(opened.journal);
  vi.spyOn(opened.journal, 'turn').mockImplementationOnce(async id => {
    const captured = await read(id);
    await first.journal.checkpointTurn({ ...turn, text: 'newest durable partial', updatedAt: 300 });
    return captured;
  });
  await next.chat.restore(opened.snapshot.drafts, opened.snapshot.turns);
  expect(next.history.state.events.get(turn.id)?.payload).toMatchObject({ text: 'newest durable partial', status: 'interrupted' });
  expect((await Journal.open(await newScope(), deps)).snapshot.turns).toEqual([]); expect(server.requests).toBe(0);
});

it('recovery rereads a turn remapped by rebase after its canonical read', async () => {
  const first = await controller({ consent: false }), c = first.chat.current(null);
  server.fail = true; first.chat.edit(c, 'pending question'); await first.chat.send(c);
  const turn = { id: id(), entityID: id(), composerID: c.id, conversationID: c.conversationID!, documentID: null, questionID: c.question!.id,
    operationID: id(), requestDigest: 'd'.repeat(64), text: 'recovered after rotation', startedAt: 100, updatedAt: 200 };
  await first.journal.beginTurn(turn);
  const opened = await Journal.open(await newScope(), deps), next = await restorer(opened), freshRoot = id(), freshQuestion = id();
  const read = opened.journal.turn.bind(opened.journal);
  vi.spyOn(opened.journal, 'turn').mockImplementationOnce(async id => {
    const captured = await read(id);
    const [root, question] = c.question!.entries;
    const replacements = [
      { old: root.id, envelope: await sealEvent(root.event, freshRoot, deviceID, ring) },
      { old: question.id, envelope: await sealEvent({ ...question.event, parents: [freshRoot] }, freshQuestion, deviceID, ring) },
    ];
    await first.journal.refresh(); await first.journal.rebase(replacements, deviceID, first.journal.revision);
    return captured;
  });
  await next.chat.restore(opened.snapshot.drafts, opened.snapshot.turns);
  expect(next.history.state.events.get(turn.id)?.payload).toMatchObject({ text: turn.text, parents: [freshQuestion] });
  const reopened = await Journal.open(await newScope(), deps), cold = await restorer(reopened);
  expect(cold.history.state.conversationBranches(c.conversationID!)[0].complete).toBe(true);
  expect(reopened.snapshot.turns).toEqual([]); expect(server.requests).toBe(0);
});

it.each(['draft', 'turn'] as const)('canonical %s reads latch integrity failure and preserve all remaining bytes', async kind => {
  const { journal } = await Journal.open(scope, deps), d = draft(); await journal.checkpointDraft(d);
  const turn = { id: id(), entityID: id(), composerID: d.id, conversationID: id(), documentID: null, questionID: id(),
    operationID: id(), requestDigest: 'e'.repeat(64), text: 'partial', startedAt: 100, updatedAt: 200 };
  await journal.beginTurn(turn);
  const rows = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`), key = rows.find(([key]) => key.includes(kind === 'draft' ? ':d:' : ':t:'))![0];
  await idb.delete('journal', key);
  const before = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  await expect(kind === 'draft' ? journal.draft(d.id) : journal.turn(turn.id)).rejects.toMatchObject({ code: 'journal_damaged' });
  expect(journal.active).toBe(false);
  await expect(journal.checkpointDraft(draft())).rejects.toMatchObject({ code: 'journal_retired' });
  expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual(before);
});

it('an aborted restore waiting for a canonical draft read releases ownership without adopting the draft', async () => {
  const a = (await Journal.open(scope, deps)).journal, d = draft(); await a.checkpointDraft(d);
  const opened = await Journal.open(await newScope(), deps), next = await restorer(opened), started = gate(), release = gate();
  const read = opened.journal.draft.bind(opened.journal);
  vi.spyOn(opened.journal, 'draft').mockImplementationOnce(async id => { const d = await read(id); started.resolve(); await release.promise; return d; });
  const restoring = next.chat.restore(opened.snapshot.drafts, []); await started.promise;
  next.owner.abort(); await Promise.resolve(); release.resolve();
  await expect(restoring).rejects.toMatchObject({ name: 'AbortError' });
  expect(next.chat.composers.size).toBe(0);
  const acquired = await next.owned.tryHold(`gradstep.composer.${d.id}`); expect(acquired).not.toBeNull(); acquired?.();
});

it('a later corrupt draft releases every earlier reclamation lock without collecting any records', async () => {
  const a = (await Journal.open(scope, deps)).journal, empty = draft(''), bad = draft();
  await a.checkpointDraft(empty); await a.checkpointDraft(bad);
  const opened = await Journal.open(await newScope(), deps), next = await restorer(opened);
  const rows = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`), badKey = rows.find(([key]) => key.endsWith(`:d:${bad.id}`))![0];
  await idb.delete('journal', badKey);
  const before = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  await expect(next.chat.restore([empty, bad], [])).rejects.toMatchObject({ code: 'journal_damaged' });
  for (const d of [empty, bad]) { const release = await next.owned.tryHold(`gradstep.composer.${d.id}`); expect(release).not.toBeNull(); release?.(); }
  expect(next.chat.storageRetired).toBe(true); expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual(before);
});

it.each([true, false])('cold history refreshes a missing epoch exactly once; refresh resolves it: %s', async available => {
  const { History } = await import('../src/lib/history'), oldRing = ring;
  const secondKeys = generateBundle(account);
  ring = await keyRing({ ...bundle, epoch: 2, contentKeys: { ...bundle.contentKeys, 2: secondKeys.contentKeys[1] } });
  const a = (await Journal.open(scope, deps)).journal, eventID = id();
  await a.appendLocal([await sealEvent(root(), eventID, deviceID, ring)]);
  const opened = await Journal.open(await newScope(), deps), owner = new AbortController(); controllers.push(owner);
  const refresh = vi.fn(async () => available ? ring : oldRing);
  const history = new History(account, deviceID, oldRing, owner.signal, refresh, opened.journal);
  const before = await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`);
  if (available) { await history.restore(opened.snapshot); expect(history.state.events.has(eventID)).toBe(true); }
  else { await expect(history.restore(opened.snapshot)).rejects.toMatchObject({ code: 'missing_key' }); expect(history.state.events.size).toBe(0); }
  expect(refresh).toHaveBeenCalledTimes(1); expect(await access.range(`${deviceKey}:`, `${deviceKey}:\uffff`)).toEqual(before);
});

it('a retained device cannot admit a late reading-place write from a retired login or writer', async () => {
  const first = new Uint8Array([1]), late = new Uint8Array([2]);
  await idb.putActivity(deviceKey, deviceID, first, scope.fence, () => true);
  await idb.retireWriter(scope.fence, true);
  expect(await idb.get('devices', deviceKey)).toBeDefined(); // normal sign-out keeps the same device key
  await idb.putActivity(deviceKey, deviceID, late, scope.fence, () => true);
  expect(await idb.get('activity', deviceKey)).toEqual(first);
  const fresh = await newScope('second-login');
  await idb.putActivity(deviceKey, deviceID, late, scope.fence, () => true);
  expect(await idb.get('activity', deviceKey)).toEqual(first);
  await idb.putActivity(deviceKey, deviceID, late, fresh.fence, () => false);
  expect(await idb.get('activity', deviceKey)).toEqual(first); // persisted login changed before its storage event arrived
  await idb.putActivity(deviceKey, deviceID, late, fresh.fence, () => true);
  expect(await idb.get('activity', deviceKey)).toEqual(late);
  await idb.retireWriter(fresh.fence);
  await idb.putActivity(deviceKey, deviceID, first, fresh.fence, () => true);
  expect(await idb.get('activity', deviceKey)).toEqual(late);
});

it('a reading-place save suspended in encryption cannot cross a retained-device login boundary', async () => {
  const { config } = await import('../src/lib/backend'), { saveActivity, loadActivity } = await import('../src/lib/activity');
  const key = `${config.environment}:${account}`, fence = await idb.admit(key, config.url, 'first-login', id(), () => true);
  const device = { accountID: account, deviceID, localKey: scope.localKey } as import('../src/lib/keys').DeviceRecord;
  await idb.putDevice(fence, device, () => true);
  const local = { key: scope.localKey, fence, current: () => true }, baseline = new Map([['paper', { opened: 100, progress: 0.1 }]]);
  await saveActivity(device, baseline, local);
  const started = gate(), release = gate(), encrypt = crypto.subtle.encrypt.bind(crypto.subtle);
  vi.spyOn(crypto.subtle, 'encrypt').mockImplementationOnce(async (...args) => { const sealed = await encrypt(...args); started.resolve(); await release.promise; return sealed; });
  const saving = saveActivity(device, new Map([['paper', { opened: 200, progress: 0.9 }]]), local);
  await started.promise; await idb.retireWriter(fence, true);
  await idb.admit(key, config.url, 'second-login', id(), () => true);
  release.resolve(); await saving;
  expect(await loadActivity(device)).toEqual(baseline); expect(await idb.get('devices', key)).toBeDefined();
});

it('clearing a draft during an accepted save and switching composers retains its lock until the clearing checkpoint', async () => {
  const owned = editorLocks(), { chat, journal } = await controller({ localLocks: owned }), c = chat.current(null);
  const started = gate(), release = gate(), checkpoint = journal.checkpointDraft.bind(journal);
  vi.spyOn(journal, 'checkpointDraft').mockImplementationOnce(async d => { started.resolve(); await release.promise; return checkpoint(d); });
  chat.edit(c, 'text being saved'); const saving = chat.flushCheckpoints(); await started.promise;
  chat.edit(c, ''); chat.newChat(id());
  expect(await owned.tryHold(`gradstep.composer.${c.id}`)).toBeNull();
  release.resolve(); await saving; await chat.flushCheckpoints();
  expect((await Journal.open(await newScope(), deps)).snapshot.drafts.find(d => d.id === c.id)?.text).toBe('');
});

it('a retried final save later acknowledged by sync releases its retained owner without another paid request', async () => {
  const { chat, history } = await controller(), c = chat.current(null), commit = access.commit;
  let fail = true;
  deps.access = { ...access, commit: async (...args) => { if (fail && args[3].some(key => key.includes(':t:'))) { fail = false; throw new Error('storage_quota'); } return commit(...args); } };
  chat.edit(c, 'save the final response'); await chat.send(c);
  expect(chat.hasUnresolvedTurn(c)).toBe(true);
  server.fail = true; await chat.retry(c); expect(c.answer).not.toBeNull();
  server.fail = false; await history.sync();
  expect(c.answer).toBeNull(); expect(chat.hasUnresolvedTurn(c)).toBe(false); expect(server.requests).toBe(1);
});
