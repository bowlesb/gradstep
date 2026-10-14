import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fromBytea, sha256, toBytea } from '../src/lib/bytes';
import type { StreamEvent } from '../src/lib/chat';
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
    if (name === 'v3_pull_events') { const events = server.rows.filter(r => r.cursor > p.p_after).slice(0, p.p_limit); return { events, next_cursor: events.at(-1)?.cursor ?? p.p_after, has_more: false }; }
    if (name === 'v1_credit_balance') return { available: 100, reserved: 4 };
    return null;
  } };
});
const { ChatSession } = await import('../src/lib/chat-session');
const { History } = await import('../src/lib/history');
const { keyRing, generateBundle } = await import('../src/lib/wire');
const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001';
const done: StreamEvent = { type: 'done', stopReason: 'end_turn', credits: 3 };
const delay = () => { let resolve!: () => void; const promise = new Promise<void>(r => { resolve = r; }); return { promise, resolve }; };
async function setup(events: StreamEvent[] = [{ type: 'delta', text: 'A clear answer.' }, done], consent = true) {
  const owner = new AbortController(), ring = await keyRing(generateBundle(account));
  const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
  let accepted = consent;
  const chat = new ChatSession(account, history, owner.signal, {
    readConsent: () => accepted, writeConsent: () => { accepted = true; },
    stream: async function* (_account, request, signal) { server.requests.push({ request, signal, count: server.rows.length }); for (const event of events) yield event; },
  });
  return { chat, history, owner };
}
beforeEach(() => { server.rows = []; server.fail = false; server.pause = null; server.requests = []; });
describe('account-owned chat transactions', () => {
  it('acknowledges the encrypted question before consent and one paid send, and synchronizes the answer', async () => {
    const { chat, history } = await setup(undefined, false), c = chat.current(null);
    chat.edit(c, 'Explain β'); await chat.send(c);
    expect(c.phase).toBe('consent'); expect(server.requests).toHaveLength(0); expect(server.rows).toHaveLength(2);
    expect(JSON.stringify(server.rows)).not.toContain('Explain');
    await chat.consent(c, true);
    expect(server.requests[0].count).toBe(2); expect(server.rows).toHaveLength(3);
    expect(chat.branch(c)?.messages.map(e => e.payload.text)).toEqual(['Explain β', 'A clear answer.']); expect(history.unsaved).toBe(0);
    expect(chat.balance).toEqual({ available: 100, reserved: 4 });
  });
  it('failed append sends nothing; retry uses the same event bytes and preserves an identical newer draft', async () => {
    const { chat, history } = await setup(), c = chat.current(null);
    chat.edit(c, 'Keep my draft'); server.fail = true; await chat.send(c);
    expect(server.requests).toHaveLength(0); expect(history.unsaved).toBe(2);
    const ids = [...history.state.events.keys()];
    chat.edit(c, 'Different'); chat.edit(c, 'Keep my draft');
    server.fail = false; await chat.retry(c);
    expect(server.rows.slice(0, 2).map(r => r.id)).toEqual(ids); expect(server.requests).toHaveLength(1); expect(c.draft).toBe('Keep my draft');
  });
  it('typing or switching paper while a save waits cannot consume or select the newer composer', async () => {
    const { chat } = await setup(), c = chat.current(null), gate = delay();
    chat.edit(c, 'First question'); server.pause = () => gate.promise; const sending = chat.send(c);
    await vi.waitFor(() => expect(c.phase).toBe('saving'));
    chat.edit(c, 'New follow-up'); const newer = chat.newChat('dddddddd-0000-4000-8000-000000000001'); chat.edit(newer, 'Paper question');
    server.pause = null; gate.resolve(); await sending;
    expect(c.draft).toBe('New follow-up'); expect(chat.current(newer.documentID)).toBe(newer); expect(newer.draft).toBe('Paper question');
    expect(server.requests[0].request.documentID).toBe(null);
  });
  it.each(['stop', 'signout'] as const)('keeps a nonempty interrupted answer on %s with no automatic second request', async reason => {
    const { history, owner } = await setup(); const gate = delay();
    const chat = new ChatSession(account, history, owner.signal, { readConsent: () => true, stream: async function* (_a, _r, signal) {
      yield { type: 'delta', text: 'A partial answer' };
      await new Promise<void>((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
    } });
    const c = chat.current(null); chat.edit(c, 'Question'); const sending = chat.send(c);
    await vi.waitFor(() => expect(c.liveText).toBe('A partial answer'));
    if (reason === 'stop') chat.stop(c); else await chat.settleBeforeSignOut();
    gate.resolve(); await sending;
    expect(chat.branch(c)?.messages.at(-1)?.payload).toMatchObject({ text: 'A partial answer', status: 'interrupted' });
    expect(c.phase).toBe('idle');
  });
  it('EOF preserves partials; refusal discards text; a successful diagram is stored encrypted alongside its answer', async () => {
    const { chat } = await setup([{ type: 'delta', text: 'Partial' }]), c = chat.current(null); chat.edit(c, 'Q'); await chat.send(c);
    expect(chat.branch(c)?.messages.at(-1)?.payload.status).toBe('interrupted'); expect(c.issue).toBe('transport');
    server.rows = [];
    const refused = await setup([{ type: 'delta', text: 'Refusal partial' }, { type: 'error', code: 'refused' }]), r = refused.chat.current(null);
    refused.chat.edit(r, 'Q'); await refused.chat.send(r); expect(refused.chat.branch(r)?.messages).toHaveLength(1); expect(r.liveText).toBe('');
    server.rows = [];
    const diagram = await setup([{ type: 'delta', text: 'See this.' }, { type: 'diagram', title: 'Flow', source: 'graph TD; A-->B' }, done]), d = diagram.chat.current(null);
    diagram.chat.edit(d, 'Diagram please'); await diagram.chat.send(d); expect(diagram.history.state.diagramsByMessage().size).toBe(1);
  });
  it('late stream events after auth retirement cannot append an answer or notify the replacement', async () => {
    const { history, owner } = await setup(), gate = delay();
    const chat = new ChatSession(account, history, owner.signal, { readConsent: () => true, stream: async function* () { await gate.promise; yield { type: 'delta', text: 'Old account secret' }; yield done; } });
    const c = chat.current(null); chat.edit(c, 'Question'); const sending = chat.send(c);
    await vi.waitFor(() => expect(c.phase).toBe('streaming'));
    const listener = vi.fn(); chat.subscribe(listener); owner.abort(); gate.resolve(); await sending;
    expect(listener).not.toHaveBeenCalled(); expect(server.rows).toHaveLength(2); expect(c.liveText).toBe('');
  });
  it('a failed answer save retries encryption only, never a second provider operation', async () => {
    const { history, owner } = await setup(); let calls = 0;
    const chat = new ChatSession(account, history, owner.signal, { readConsent: () => true, stream: async function* () { calls++; yield { type: 'delta', text: 'Save me' }; server.fail = true; yield done; } });
    const c = chat.current(null); chat.edit(c, 'Q'); await chat.send(c); expect(c.issue).toBe('storage'); expect(c.answer).not.toBeNull();
    server.fail = false; await chat.retry(c); expect(calls).toBe(1); expect(server.rows).toHaveLength(3); expect(c.answer).toBeNull();
  });
});

it('an unsaved answer fences branch changes; background acknowledgement releases the same answer without AI', async () => {
  const { history, owner } = await setup(); let calls = 0;
  const chat = new ChatSession(account, history, owner.signal, { readConsent: () => true, stream: async function* () { calls++; yield { type: 'delta', text: 'Original branch answer' }; server.fail = true; yield done; } });
  const c = chat.current(null); chat.edit(c, 'Question'); await chat.send(c);
  const head = c.head, answerID = c.answer![0].id;
  chat.chooseBranch(c, crypto.randomUUID()); expect(c.head).toBe(head); expect(c.question).not.toBeNull();
  server.fail = false; await history.sync();
  expect(c.answer).toBeNull(); expect(c.head).toBe(answerID); expect(c.issue).toBeNull(); expect(calls).toBe(1);
});

it('a completed diagram with no prose still has an encrypted assistant attachment', async () => {
  const { chat, history } = await setup([{ type: 'diagram', title: 'Flow', source: 'graph TD; A-->B' }, done]);
  const c = chat.current(null); chat.edit(c, 'Draw it'); await chat.send(c);
  expect(chat.branch(c)?.messages.at(-1)?.payload.text).toBe('Flow'); expect(history.state.diagramsByMessage().size).toBe(1);
});

it('background sync acknowledges a failed question visibly, but never initiates AI', async () => {
  const { chat, history } = await setup(), c = chat.current(null);
  chat.edit(c, 'Queued question'); server.fail = true; await chat.send(c);
  server.fail = false; await history.sync();
  expect(c.issue).toBe('question_ready'); expect(c.draft).toBe(''); expect(server.requests).toHaveLength(0);
  await chat.retry(c); expect(server.requests).toHaveLength(1);
});
