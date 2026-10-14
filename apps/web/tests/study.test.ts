// Study (lib/study.ts, docs/architecture/CHAT.md "Study", 2026-10-14): the request, the map, its drawing, and the
// session's study state across turns.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fromBytea, sha256, toBytea } from '../src/lib/bytes';
import { makeRequest, requestBody, SSEParser, type StreamEvent } from '../src/lib/chat';
import { EMPTY_STUDY_MAP, stateCounts, studyMap, studyMermaid, studyStart, type StudyMap } from '../src/lib/study';

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

const sample: StudyMap = { concepts: [{ id: 'scaling', label: 'Scaled dot-product attention', state: 'learning', paragraphs: [2], note: 'Mixes up d_k and d_model' },
  { id: 'softmax', label: 'Softmax saturation', state: 'unknown', paragraphs: [2] }, { id: 'end', label: 'End of sequence', state: 'known', paragraphs: [] }],
  links: [{ from: 'softmax', to: 'scaling', kind: 'prerequisite' }, { from: 'scaling', to: 'end', kind: 'deeper' }], focus: 'scaling', journey: ['scaling', 'softmax', 'scaling'], next: 'verify' };

describe('the study request and map', () => {
  it('sends the map with a study turn, no selection needed, and asks for no follow-ups', () => {
    const request = makeRequest('bbbbbbbb-0000-4000-8000-000000000002', null, [{ role: 'user', text: studyStart() }], null, 'study');
    expect(request.action).toBe('study'); expect(request.selection).toBeNull();
    const body = requestBody({ ...request, study: sample });
    expect(body.action).toBe('study'); expect(body.study).toEqual(sample); expect(body.follow_ups).toBeUndefined(); expect(body.topic_title).toBeUndefined();
    expect(requestBody(request).study).toEqual(EMPTY_STUDY_MAP);
    // Other actions still need their quote; a quote may start a study on a passage.
    expect(makeRequest('bbbbbbbb-0000-4000-8000-000000000002', null, [{ role: 'user', text: 'x' }], null, 'relevance').action).toBeNull();
    expect(studyStart('divide by sqrt(d_k)')).toContain('divide by sqrt(d_k)');
  });
  it('keeps whole maps only and cleans what it keeps', () => {
    expect(studyMap(sample)).toEqual(sample);
    expect(studyMap({ ...sample, concepts: [{ id: 'scaling', label: ' Scaled\u0000 attention ', state: 'known', paragraphs: [2, 2, 0, 1e9] }], links: [], focus: 'ghost', journey: [], next: 'sideways' }))
      .toEqual({ concepts: [{ id: 'scaling', label: 'Scaled attention', state: 'known', paragraphs: [2] }], links: [], focus: null, journey: [], next: 'calibrate' });
    for (const broken of [null, [], { concepts: [] }, { ...sample, concepts: [{ ...sample.concepts[0], state: 'mastered' }] },
      { ...sample, links: [{ from: 'scaling', to: 'ghost', kind: 'related' }] }, { ...sample, journey: ['ghost'] }, { ...sample, links: [{ from: 'scaling', to: 'scaling', kind: 'related' }] },
      { ...sample, concepts: [...sample.concepts, { id: 'scaling', label: 'dup', state: 'known', paragraphs: [] }] }]) expect(studyMap(broken)).toBeNull();
    expect(stateCounts(sample)).toEqual({ unknown: 1, learning: 1, known: 1, verified: 0 });
  });
  it('parses the study event and drops an unusable map', () => {
    const frames = (text: string) => { const p = new SSEParser(); return p.consume(new TextEncoder().encode(text)); };
    expect(frames(`event: study\ndata: ${JSON.stringify({ map: sample })}\n\n`)).toEqual([{ type: 'study', map: sample }]);
    expect(frames('event: study\ndata: {"map":{"concepts":[{"id":"x","label":"x","state":"fluent","paragraphs":[]}],"links":[]}}\n\n')).toEqual([]);
    expect(frames('event: study\ndata: {"map":"none"}\n\n')).toEqual([]);
  });
  it('draws the map as a strict Mermaid flowchart with safe ids and quoted, cleaned labels', () => {
    const source = studyMermaid({ ...sample, concepts: [...sample.concepts.slice(0, 2), { id: 'end', label: 'End "of" [seq] {x} <y>', state: 'known', paragraphs: [] }] });
    expect(source.split('\n')[0]).toBe('flowchart TD');
    expect(source).toContain('s_scaling["Scaled dot-product attention"]:::learning');
    expect(source).toContain('s_end["End of seq x y"]:::known');
    expect(source).toContain('s_softmax --> s_scaling'); expect(source).toContain('s_scaling -.-> s_end');
    expect(source).toContain('style s_scaling stroke-width:3px');
    expect(source).not.toMatch(/^\s*end\b/m);
    expect(studyMermaid(EMPTY_STUDY_MAP)).toContain('classDef verified');
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
  it('starts with an empty map, sends the map back each turn, advances it on complete answers only, and ends cleanly', async () => {
    const grown: StudyMap = { ...sample, journey: [...sample.journey, 'end'], focus: 'end' };
    const { chat } = await setup([
      [{ type: 'delta', text: '**What does attention compute?**' }, { type: 'study', map: sample }, done],
      [{ type: 'delta', text: 'Partly.' }, { type: 'study', map: grown }, { type: 'error', code: 'provider_unavailable' }],
      [{ type: 'delta', text: 'Right. **Next?**' }, { type: 'study', map: grown }, done],
    ]);
    expect(chat.canStudy(member)).toBe(true); expect(chat.canStudy(null)).toBe(false); expect(chat.canStudy('dddddddd-0000-4000-8000-000000000001')).toBe(false);
    const c = chat.current(member);
    await chat.startStudy(c);
    expect(server.requests[0].action).toBe('study'); expect(server.requests[0].study).toEqual(EMPTY_STUDY_MAP);
    expect(server.requests[0].localContext?.format).toBe('reader-local-context-v2'); expect(server.requests[0].turns.at(-1)?.text).toBe(studyStart());
    expect(c.study).toEqual(sample); expect(c.followUps).toBeNull();
    expect(chat.branch(c)?.messages.map(e => e.payload.text)).toEqual([studyStart(), '**What does attention compute?**']);
    // The reader's answer is a study turn carrying the current map; a failed answer leaves the map as it was.
    chat.edit(c, 'A weighted sum of values.'); await chat.send(c);
    expect(server.requests[1].action).toBe('study'); expect(server.requests[1].study).toEqual(sample);
    expect(c.issue).toBe('provider_unavailable'); expect(c.study).toEqual(sample);
    await chat.retry(c);
    expect(server.requests[2].action).toBe('study'); expect(c.study).toEqual(grown); expect(c.issue).toBeNull();
    chat.endStudy(c);
    expect(c.study).toBeNull();
    // Nothing of the map reached storage (it is memory only, never written in the clear).
    expect(JSON.stringify(server.rows)).not.toContain('Softmax');
  });
  it('is only offered for papers numbered on this device', async () => {
    const { chat } = await setup([[{ type: 'delta', text: 'x' }, done]]);
    const general = chat.current(null);
    await chat.startStudy(general);
    expect(server.requests).toHaveLength(0); expect(general.study).toBeNull(); expect(general.draft).toBe('');
  });
});
