// Study mode (lib/study.ts, LEARNING_GUIDE.md, reworked 2026-10-22): the request, the tutor's hidden notes, the visual
// suggestion pattern, and the session's study state across turns.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fromBytea, sha256, toBytea } from '../src/lib/bytes';
import { makeRequest, requestBody, SSEParser, type StreamEvent } from '../src/lib/chat';
import { isVisualFollowUp, STUDY_ENTRY, STUDY_HINT, STUDY_NOTES_LIMITS, STUDY_OPENING, studyNotes, type StudyNotes } from '../src/lib/study';

const server = vi.hoisted(() => ({ rows: [] as any[], requests: [] as any[] }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string, p: any) => {
    if (name === 'v1_append_event') {
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
// The paper numbered on this device (the HTML reader's bundle), as the chat attaches it.
vi.mock('../src/lib/arxiv-reader', () => ({ localChatContext: () => ({ format: 'reader-local-context-v2', membership_id: member, source: 'arxiv', source_id: '2601.01234',
  revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] # Fixture\n\n[¶2] Scaled attention.' }) }));
const { ChatSession } = await import('../src/lib/chat-session');
const { History } = await import('../src/lib/history');
const { keyRing, generateBundle } = await import('../src/lib/wire');
const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001', member = '58000000-0000-4000-8000-000000000003';
const reference = { format: 'source-membership-v1' as const, membershipID: member, source: 'arxiv' as const, sourceID: '2601.01234', revision: 2 };

const notes: StudyNotes = { turn: 1, level: 'core', concepts: [{ name: 'Scaled dot-product attention', status: 'new', asked: [1], paras: [2] }], next: 'check scaling' };
const later: StudyNotes = { turn: 2, level: 'intro', concepts: [{ name: 'Scaled dot-product attention', status: 'shaky', asked: [1, 2], paras: [2] },
  { name: 'Softmax saturation', status: 'new', asked: [2], paras: [2] }], next: 'explain softmax; look back at scaling at turn 4' };
const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));

describe('the study request and notes', () => {
  it('sends the tutor’s notes back with a study turn (none on the first), never the old map, and asks for no follow-ups', () => {
    const first = makeRequest('bbbbbbbb-0000-4000-8000-000000000002', null, [{ role: 'user', text: STUDY_OPENING }], null, 'study');
    expect(first.action).toBe('study'); expect(first.selection).toBeNull();
    const body = requestBody(first);
    expect(body.action).toBe('study'); expect(body).not.toHaveProperty('study'); expect(body).not.toHaveProperty('study_state'); expect(body).not.toHaveProperty('follow_ups');
    expect(requestBody({ ...first, studyState: notes }).study_state).toEqual(notes);
    // Notes never travel with anything else.
    const plain = makeRequest('bbbbbbbb-0000-4000-8000-000000000002', null, [{ role: 'user', text: 'q' }], null);
    expect(requestBody({ ...plain, studyState: notes })).not.toHaveProperty('study_state');
    // A passage may start the study (it goes as the selection).
    expect(makeRequest('bbbbbbbb-0000-4000-8000-000000000002', null, [{ role: 'user', text: STUDY_OPENING }], 'divide by √d_k', 'study').selection).toBe('divide by √d_k');
  });
  it('reads the study_state event leniently and ignores the retired study map event', () => {
    expect(frames(`event: study_state\ndata: ${JSON.stringify({ state: later })}\n\n`)).toEqual([{ type: 'study_state', state: later }]);
    expect(frames('event: study_state\ndata: {"state": "turn 2"}\n\n')).toEqual([]);
    expect(frames(`event: study\ndata: ${JSON.stringify({ map: { concepts: [], links: [] } })}\n\n`)).toEqual([]);
  });
  it('repairs notes as the server does: unknown values fall back, names cleaned, duplicates keep the newest, bounded', () => {
    const checked = studyNotes({ turn: 0, level: 'expert', next: ' revisit\u0000 <softmax> ', concepts: [
      { name: ' Softmax ', status: 'mastered', asked: [3, 1, 1, 0], paras: [2, 2] }, { name: '' }, 'junk', { name: 'softmax', status: 'ok', asked: [2], paras: [4] }] })!;
    expect(checked).toEqual({ turn: 1, level: 'core', next: 'revisit softmax', concepts: [{ name: 'softmax', status: 'ok', asked: [2], paras: [4] }] });
    expect(studyNotes({ concepts: Array.from({ length: 20 }, (_, i) => ({ name: `C${i}`, status: 'ok' })) })!.concepts).toHaveLength(STUDY_NOTES_LIMITS.concepts);
    expect(studyNotes(null)).toBeNull(); expect(studyNotes([notes])).toBeNull();
    expect(studyNotes({ ...notes, next: 'n'.repeat(5_000) })!.next.length).toBe(STUDY_NOTES_LIMITS.next);
  });
  it('tells a picture suggestion from a question, as the server does', () => {
    for (const q of ['Create a diagram explaining the background of RLHF', 'Draw how attention flows step by step', 'Show the DPO pipeline as a visual', 'Make a flowchart of the training loop'])
      expect(isVisualFollowUp(q)).toBe(true);
    for (const q of ['Show how DPO compares to PPO', 'What does Figure 2 show?', 'Show me Figure 3', 'How is the reward model trained?']) expect(isVisualFollowUp(q)).toBe(false);
    expect(STUDY_ENTRY).toBe('Enter Study Mode – Quiz me and help me learn');
  });
});

describe('a study in the chat session', () => {
  const done: StreamEvent = { type: 'done', stopReason: 'end_turn', credits: 3 };
  async function setup(answers: StreamEvent[][]) {
    const owner = new AbortController(), ring = await keyRing(generateBundle(account));
    const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
    let turn = 0;
    const chat = new ChatSession(account, history, owner.signal, {
      readConsent: () => true, writeConsent: () => {},
      stream: async function* (_account, request) { server.requests.push(request); for (const event of answers[Math.min(turn++, answers.length - 1)]) yield event; },
    });
    chat.setSourcePapers(new Map([[member, { reference, load: async () => ({}) as any }]]));
    return { chat, history };
  }
  beforeEach(() => { server.rows = []; server.requests = []; });
  it('enters with the opening turn, sends the notes back each turn, advances them on complete answers only, and stops without a request', async () => {
    const { chat } = await setup([
      [{ type: 'delta', text: '**What does attention compute?**' }, { type: 'study_state', state: notes }, done],
      [{ type: 'delta', text: 'Partly.' }, { type: 'study_state', state: later }, { type: 'error', code: 'provider_unavailable' }],
      [{ type: 'delta', text: 'Right. **Next?**' }, { type: 'study_state', state: later }, done],
      [{ type: 'delta', text: 'A hint: think of the scale. **Again?**' }, done],
    ]);
    expect(chat.canStudy(member)).toBe(true); expect(chat.canStudy(null)).toBe(false); expect(chat.canStudy('dddddddd-0000-4000-8000-000000000001')).toBe(false);
    const c = chat.current(member);
    await chat.startStudy(c);
    expect(server.requests[0].action).toBe('study'); expect(server.requests[0].studyState).toBeUndefined();
    expect(server.requests[0].localContext?.format).toBe('reader-local-context-v2'); expect(server.requests[0].turns.at(-1)?.text).toBe(STUDY_OPENING);
    expect(c.study).toEqual({ notes }); expect(c.followUps).toBeNull();
    expect(chat.branch(c)?.messages.map(e => e.payload.text)).toEqual([STUDY_OPENING, '**What does attention compute?**']);
    // The reader's answer is a study turn carrying the notes; a failed answer leaves them as they were.
    chat.edit(c, 'A weighted sum of values.'); await chat.send(c);
    expect(server.requests[1].action).toBe('study'); expect(server.requests[1].studyState).toEqual(notes);
    expect(c.issue).toBe('provider_unavailable'); expect(c.study).toEqual({ notes });
    await chat.retry(c);
    expect(server.requests[2].action).toBe('study'); expect(c.study).toEqual({ notes: later }); expect(c.issue).toBeNull();
    // Hint sends its turn at once, with the latest notes.
    await chat.studyReply(c, STUDY_HINT);
    expect(server.requests[3].turns.at(-1)?.text).toBe(STUDY_HINT); expect(server.requests[3].studyState).toEqual(later); expect(c.study).toEqual({ notes: later });
    chat.endStudy(c);
    expect(c.study).toBeNull(); expect(server.requests).toHaveLength(4);
    // A reply after Stop is an ordinary question.
    await chat.studyReply(c, STUDY_HINT); expect(server.requests).toHaveLength(4);
    // Nothing of the notes reached storage (memory only, never written in the clear).
    expect(JSON.stringify(server.rows)).not.toContain('Softmax');
  });
  it('is only offered for papers numbered on this device', async () => {
    const { chat } = await setup([[{ type: 'delta', text: 'x' }, done]]);
    const general = chat.current(null);
    await chat.startStudy(general);
    expect(server.requests).toHaveLength(0); expect(general.study).toBeNull(); expect(general.draft).toBe('');
  });
});
