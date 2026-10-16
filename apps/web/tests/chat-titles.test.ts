// The chat session's use of profiles and topic titles (2026-10-08), against a fake encrypted history service.
import { readFileSync } from 'node:fs';
import { beforeEach, expect, it, vi } from 'vitest';
import { fromBytea, sha256, toBytea } from '../src/lib/bytes';
import { requestBody, type ChatRequest, type StreamEvent } from '../src/lib/chat';
const server = vi.hoisted(() => ({ rows: [] as any[], fail: false }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string, p: any) => {
    if (name === 'v1_append_event') {
      if (server.fail) throw new mod.BackendError('connection');
      const old = server.rows.find(e => e.id === p.p_id);
      if (old) return old.cursor;
      server.rows.push({ id: p.p_id, device_id: p.p_device_id, epoch: p.p_epoch, format: p.p_format, ciphertext: p.p_ciphertext,
        ciphertext_sha256: toBytea(await sha256(fromBytea(p.p_ciphertext))), cursor: server.rows.length + 1 }); return server.rows.length;
    }
    if (name === 'v3_pull_events') { const events = server.rows.filter(r => r.cursor > p.p_after).slice(0, p.p_limit); return { events, next_cursor: events.at(-1)?.cursor ?? p.p_after, has_more: false }; }
    if (name === 'v1_credit_balance') return { available: 100, reserved: 0 };
    return null;
  } };
});
const { ChatSession } = await import('../src/lib/chat-session');
const { History } = await import('../src/lib/history');
const { keyRing, generateBundle } = await import('../src/lib/wire');
// The table builds 57/58 shipped with (no additions) and the table staging serves since 2026-10-16 (auto, DeepSeek).
const published = JSON.parse(readFileSync(new URL('../../../tests/fixtures/chat-profiles-v1-build57.json', import.meta.url), 'utf8'));
const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001';
type Script = (request: ChatRequest) => StreamEvent[];

async function setup(script: Script, options: { table?: unknown; saved?: any; consent?: boolean; fetchProfiles?: () => Promise<unknown>; load?: boolean } = {}) {
  const owner = new AbortController(), ring = await keyRing(generateBundle(account));
  const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
  const requests: ChatRequest[] = [], written: any[] = [];
  let consent = options.consent !== false;
  const chat = new ChatSession(account, history, owner.signal, {
    readConsent: () => consent, writeConsent: () => { consent = true; },
    fetchProfiles: options.fetchProfiles ?? (async () => { if (options.table === null) throw new Error('old server'); return options.table ?? published; }),
    readDefault: () => options.saved ?? null, writeDefault: choice => written.push(choice),
    stream: async function* (_account, request) { requests.push(request); for (const event of script(request)) yield event; },
  });
  if (options.load !== false) await chat.profiles.load();
  return { chat, history, requests, written, ring, allow: () => { consent = true; } };
}
const answer = (title?: string, done: Partial<Extract<StreamEvent, { type: 'done' }>> = {}): Script => request => [
  { type: 'delta', text: 'An answer.' }, ...(title ? [{ type: 'title', text: title } as StreamEvent] : []),
  { type: 'done', stopReason: 'end_turn', credits: 2, model: 'claude-sonnet-5-5', profile: `${request.profile.model}-${request.profile.effort}-${request.profile.length}`, ...done },
];
beforeEach(() => { server.rows = []; server.fail = false; });

it('a new chat asks for a title, seals it with the answer and stops asking; the answer keeps its model and profile', async () => {
  const { chat, history, requests } = await setup(answer('Scaled attention explained'));
  const c = chat.current(null);
  chat.edit(c, 'Why scale by √d?'); await chat.send(c);
  expect(requests[0].topicTitle).toBe(true);
  expect(server.rows).toHaveLength(4); // root, question, answer and its title revision
  const summary = history.state.conversationSummaries()[0];
  expect([summary.title, summary.titleSource]).toEqual(['Scaled attention explained', 'generated']);
  expect(chat.branch(c)?.messages.at(-1)?.payload).toMatchObject({ model: 'claude-sonnet-5-5', profile: 'sonnet-low-standard' });
  chat.edit(c, 'And for small d?'); await chat.send(c);
  expect(requests[1].topicTitle).toBe(false);
  expect(history.state.revisions(c.conversationID!)).toHaveLength(1);
});

it('a renamed chat is never retitled; an untitled older chat gets one lazily', async () => {
  const { chat, history, requests } = await setup(answer('Generated later'));
  const c = chat.current(null);
  chat.edit(c, 'First'); await chat.send(c);
  expect(await chat.rename(c.conversationID!, '  My own name  ')).toBe(true);
  expect(history.state.conversationSummaries()[0]).toMatchObject({ title: 'My own name', titleSource: 'renamed' });
  // A title arriving for a chat renamed meanwhile is dropped.
  chat.edit(c, 'Again'); await chat.send(c);
  expect(requests[1].topicTitle).toBe(false);
  expect(history.state.conversationSummaries()[0].title).toBe('My own name');
});

it('the chat follows its newest answer\'s profile; a change applies to the next answer; new chats use the browser default', async () => {
  const { chat, requests, written } = await setup(answer(), { saved: { model: 'haiku', effort: 'medium', length: 'brief' } });
  const c = chat.current(null);
  expect(chat.profileFor(c)).toEqual({ model: 'haiku', effort: 'medium', length: 'brief' });
  chat.setProfile(c, { model: 'opus', effort: 'high', length: 'detailed' });
  chat.edit(c, 'Q1'); await chat.send(c);
  expect(requests[0].profile).toEqual({ model: 'opus', effort: 'high', length: 'detailed' });
  c.profile = null; // a reload: the chat's choice comes back from its answer
  expect(chat.profileFor(c)).toEqual({ model: 'opus', effort: 'high', length: 'detailed' });
  const fresh = chat.newChat(null);
  expect(chat.profileFor(fresh)).toEqual({ model: 'haiku', effort: 'medium', length: 'brief' });
  chat.setDefaultProfile({ model: 'sonnet', effort: 'high', length: 'standard' });
  expect(written.at(-1)).toEqual({ model: 'sonnet', effort: 'high', length: 'standard' });
  expect(chat.profileFor(chat.newChat(null))).toEqual({ model: 'sonnet', effort: 'high', length: 'standard' });
  // A selection action carries the visible choice.
  expect(chat.profileFor(chat.newChat('dddddddd-0000-4000-8000-000000000001', { model: 'opus', effort: 'low', length: 'brief' }))).toEqual({ model: 'opus', effort: 'low', length: 'brief' });
});

it('without the published table (an older server) requests stay exactly as before', async () => {
  const { chat, requests, history } = await setup(answer('Never used'), { table: null });
  const c = chat.current(null);
  expect(chat.profileTable).toBeNull();
  chat.setProfile(c, { model: 'opus', effort: 'high', length: 'detailed' });
  chat.edit(c, 'Q'); await chat.send(c);
  expect(requests[0].topicTitle).toBe(false); expect(requests[0].profile).toEqual({ model: 'sonnet', effort: 'low', length: 'standard' });
  // A title nobody asked for is ignored.
  expect(history.state.conversationSummaries()[0].titleSource).toBeUndefined();
});

it('a title is kept only with a complete answer', async () => {
  const { chat, history } = await setup(answer('Partial title', { stopReason: 'max_tokens' }));
  const c = chat.current(null); chat.edit(c, 'Q'); await chat.send(c);
  expect(chat.branch(c)?.messages.at(-1)?.payload.status).toBe('interrupted');
  expect(history.state.conversationSummaries()[0].titleSource).toBeUndefined();
});

const expensive = { model: 'opus', effort: 'high', length: 'detailed' } as const;
const small = { model: 'haiku', effort: 'low', length: 'brief' } as const;
it('Send captures settings before saving, and keeps them through consent despite later control edits', async () => {
  const { chat, history, requests } = await setup(answer(), { consent: false }), c = chat.current(null);
  chat.setProfile(c, expensive); chat.edit(c, 'Question with captured choice');
  const started = Promise.withResolvers<void>(), release = Promise.withResolvers<void>(), append = history.append.bind(history);
  vi.spyOn(history, 'append').mockImplementationOnce(async (...args) => { started.resolve(); await release.promise; return append(...args); });
  const sending = chat.send(c); await started.promise;
  chat.setProfile(c, small); release.resolve(); await sending;
  expect(requests).toHaveLength(0); expect(c.phase).toBe('consent'); expect(chat.retryProfile(c)).toEqual(expensive);
  await chat.consent(c, true);
  expect(requests).toHaveLength(1); expect(requests[0].profile).toEqual(expensive);
  expect(chat.profileFor(c)).toEqual(small); // the newer choice is for a later question
});

it('Get answer for an unknown other-device question captures the visible choice before sync', async () => {
  const { chat, history, requests, allow } = await setup(answer(), { consent: false }), c = chat.current(null);
  chat.edit(c, 'Question from an older client'); await chat.send(c); await chat.consent(c, false);
  c.question = null; c.requestedAnswer = undefined; chat.setProfile(c, small); allow();
  const started = Promise.withResolvers<void>(), release = Promise.withResolvers<void>(), flush = history.flush.bind(history);
  vi.spyOn(history, 'flush').mockImplementationOnce(async (...args) => { started.resolve(); await release.promise; return flush(...args); });
  const retrying = chat.retry(c); await started.promise;
  chat.setProfile(c, expensive); release.resolve(); await retrying;
  expect(requests).toHaveLength(1); expect(requests[0].profile).toEqual(small);
});

it('a profile table arriving after Send cannot upgrade the visibly offered default', async () => {
  const release = Promise.withResolvers<unknown>();
  const { chat, requests } = await setup(answer(), { fetchProfiles: () => release.promise, load: false, saved: expensive });
  const c = chat.current(null); chat.edit(c, 'Question while options load');
  expect(chat.profileFor(c)).toEqual({ model: 'sonnet', effort: 'low', length: 'standard' });
  const sending = chat.send(c); chat.setProfile(c, expensive); release.resolve(published); await sending;
  expect(requests[0].profile).toEqual({ model: 'sonnet', effort: 'low', length: 'standard' });
});

it('a recorded nondefault choice never silently changes when capabilities become unavailable', async () => {
  const { chat, requests } = await setup(answer(), { consent: false }), c = chat.current(null);
  chat.setProfile(c, expensive); chat.edit(c, 'Exact profile'); await chat.send(c);
  chat.profiles.table = null; vi.spyOn(chat.profiles, 'load').mockResolvedValue(null);
  await chat.consent(c, true);
  expect(requests).toHaveLength(0); expect(c.issue).toBe('profile_unavailable'); expect(chat.retryProfile(c)).toEqual(expensive);
});

it('capability waits reserve the three-answer limit before any provider request', async () => {
  const release = Promise.withResolvers<unknown>();
  const { chat, requests } = await setup(answer(), { fetchProfiles: () => release.promise, load: false });
  const composers = Array.from({ length: 4 }, () => { const c = chat.newChat(null); chat.edit(c, 'Question'); return c; });
  const sending = composers.map(c => chat.send(c));
  await vi.waitFor(() => expect(composers.filter(c => c.issue === 'rate_limited')).toHaveLength(1));
  expect(requests).toHaveLength(0); release.resolve(published); await Promise.all(sending);
  expect(requests).toHaveLength(3);
});

it('a deferred version-1 tab replans a generated title when a rename arrives during encryption', async () => {
  const { chat, history, ring } = await setup(answer('Late generated title'), { consent: false }), c = chat.current(null);
  chat.edit(c, 'Untitled older tab'); await chat.send(c);
  const peer = new History(account, device, ring, new AbortController().signal, async () => ring); await peer.sync();
  const encrypt = crypto.subtle.encrypt.bind(crypto.subtle);
  vi.spyOn(crypto.subtle, 'encrypt').mockImplementationOnce(async (...args) => {
    const sealed = await encrypt(...args);
    await peer.append([], { title: { id: crypto.randomUUID(), conversationID: c.conversationID!, text: 'Renamed while encrypting', source: 'renamed' } });
    await history.sync(); return sealed;
  });
  await chat.consent(c, true);
  expect(history.state.conversationSummaries()[0]).toMatchObject({ title: 'Renamed while encrypting', titleSource: 'renamed' });
  expect([...history.state.events.values()].some(e => e.payload.titleSource === 'generated')).toBe(false);
});

// Chat redesign from build 57 (CHAT.md, 2026-10-16): with the server's `auto` profiles every new request asks for
// automatic effort; without them (today's staging) requests keep the stored effort.
const publishedAuto = JSON.parse(readFileSync(new URL('./fixtures/chat-profiles-v1.json', import.meta.url), 'utf8'));
it('requests effort auto when the table offers it, and the stored effort when it does not', async () => {
  const withAuto = await setup(answer(), { table: publishedAuto }), a = withAuto.chat.current(null);
  expect(withAuto.chat.defaultProfile).toEqual({ model: 'sonnet', effort: 'low', length: 'standard' });
  withAuto.chat.edit(a, 'Q'); await withAuto.chat.send(a);
  expect(withAuto.requests[0].autoEffort).toBe(true);
  expect(requestBody(withAuto.requests[0]).profile).toEqual({ model: 'sonnet', effort: 'auto', length: 'standard' });
  withAuto.chat.setProfile(a, { model: 'deepseek', effort: 'low', length: 'brief' }); withAuto.chat.edit(a, 'Q2'); await withAuto.chat.send(a);
  expect(requestBody(withAuto.requests[1]).profile).toEqual({ model: 'deepseek', effort: 'auto', length: 'brief' });
  // The stored choice keeps its concrete effort (journals and older tabs read it unchanged).
  expect(withAuto.requests[1].profile).toEqual({ model: 'deepseek', effort: 'low', length: 'brief' });

  server.rows = []; // another account's keys
  const without = await setup(answer()), b = without.chat.current(null);
  without.chat.setProfile(b, expensive); without.chat.edit(b, 'Q'); await without.chat.send(b);
  expect(without.requests[0].autoEffort).toBeUndefined();
  expect(requestBody(without.requests[0]).profile).toEqual(expensive);
  // A table that doesn't list DeepSeek doesn't offer it: the chat keeps a choice it can answer.
  without.chat.setProfile(b, { model: 'deepseek', effort: 'low', length: 'brief' });
  expect(without.chat.profileFor(b)).toEqual(expensive);
});
