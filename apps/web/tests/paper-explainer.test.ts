// The paper's AI Explainer (lib/paper-explainer.ts, docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): the shared
// fixture both clients reproduce (the diagram's Mermaid source and the progress bar), the events checked again, the
// request (the chat's own, with the action and one turn), and the session's streamed result and kept answer.
import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SSEParser, makeRequest, requestBody, type StreamEvent } from '../src/lib/chat';
import { PAPER_EXPLAINER_TURN, paperExplainerMermaid, paperExplainerProgress, paperExplainerText, PAPER_PROGRESS, parsePaperExplainer, parsePaperItem,
  type PaperExplainer } from '../src/lib/paper-explainer';

const server = vi.hoisted(() => ({ requests: [] as any[] }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string) => name === 'v1_credit_balance' ? { available: 100, reserved: 0 } : name === 'v3_pull_events' ? { events: [], next_cursor: 0, has_more: false } : null };
});
vi.mock('../src/lib/arxiv-reader', () => ({ localChatContext: (reference: { membershipID: string }) => ({ format: 'reader-local-context-v2', membership_id: reference.membershipID,
  source: 'arxiv', source_id: '2601.01234', revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] # Fixture\n\n[¶2] Attention.' }) }));

const fixture = JSON.parse(readFileSync(new URL('../../../tests/fixtures/paper-explainer.json', import.meta.url), 'utf8')) as {
  parameters: typeof PAPER_PROGRESS; explainers: { name: string; explainer: PaperExplainer; mermaid: string; text: string }[];
  progress: { name: string; input: Parameters<typeof paperExplainerProgress>[0]; expected: ReturnType<typeof paperExplainerProgress> }[] };
const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));
const sample = fixture.explainers[0].explainer;

describe('the shared fixture (the apps reproduce it too)', () => {
  it('uses the same parameters', () => { expect(PAPER_PROGRESS).toEqual(fixture.parameters); });
  for (const e of fixture.explainers) it(`draws ${e.name}`, () => {
    expect(paperExplainerMermaid(e.explainer)).toBe(e.mermaid);
    expect(paperExplainerText(e.explainer)).toBe(e.text);
  });
  for (const c of fixture.progress) it(`progress: ${c.name}`, () => { expect(paperExplainerProgress(c.input)).toEqual(c.expected); });
  it('the diagram is a top-down flowchart with background and ideas styled apart, and nothing to draw without entries', () => {
    const source = paperExplainerMermaid(sample);
    expect(source.split('\n')[0]).toBe('flowchart TD');
    expect(source).toContain(':::background'); expect(source).toContain(':::idea'); expect(source).toContain('-->|"');
    expect(paperExplainerMermaid({ background: [], ideas: [], links: [] })).toBe('');
  });
});

describe('the explainer events', () => {
  it('keeps a checked explainer as it came, and drops entries and links that are not usable', () => {
    expect(parsePaperExplainer(sample)).toEqual(sample);
    const repaired = parsePaperExplainer({ ...sample, background: [...sample.background, { id: 'Bad Id', name: 'x' }, { id: 'b1', name: 'dup' }, { id: 'bx', name: '' }],
      links: [...sample.links, { from: 'b1', to: 'ghost', label: 'x' }, { from: 'b1', to: 'b1', label: 'self' }] })!;
    expect(repaired.background).toEqual(sample.background); expect(repaired.links).toEqual(sample.links);
    expect(parsePaperExplainer({ ...sample, format: 'paper-explainer-v2' })).toBeNull();
    expect(parsePaperExplainer({ ...sample, background: [], ideas: [] })).toBeNull();
    expect(parsePaperItem({ id: 'b1', name: 'Softmax', line: 'x', paragraphs: [0, 2, 2, 999] }, 30)).toEqual({ id: 'b1', name: 'Softmax', line: 'x', paragraphs: [2] });
  });
  it('arrives as stream events; an unusable one is dropped, never fatal', () => {
    expect(frames('event: paper_progress\ndata: {"stage":"reading"}\n\n')).toEqual([{ type: 'paper_progress', stage: 'reading' }]);
    expect(frames('event: paper_progress\ndata: {"stage":"writing","characters":120,"items":9}\n\n')).toEqual([{ type: 'paper_progress', stage: 'writing', characters: 120, items: 9 }]);
    expect(frames('event: paper_progress\ndata: {"stage":"writing","characters":-1}\n\n')).toEqual([]);
    expect(frames('event: paper_summary\ndata: {"summary":"In short."}\n\n')).toEqual([{ type: 'paper_summary', summary: 'In short.' }]);
    expect(frames(`event: paper_item\ndata: ${JSON.stringify({ kind: 'idea', index: 1, item: sample.ideas[1] })}\n\n`)).toEqual([{ type: 'paper_item', kind: 'idea', index: 1, item: sample.ideas[1] }]);
    expect(frames(`event: paper_item\ndata: ${JSON.stringify({ kind: 'result', index: 0, item: sample.ideas[0] })}\n\n`)).toEqual([]);
    expect(frames(`event: paper_explainer\ndata: ${JSON.stringify(sample)}\n\n`)).toEqual([{ type: 'paper_explainer', explainer: sample }]);
  });
  it('is the chat’s own paper request with the action and one turn: no passage, figure, title or suggestions', () => {
    const request = makeRequest('bbbbbbbb-0000-4000-8000-000000000002', null, [{ role: 'user', text: PAPER_EXPLAINER_TURN }], 'ignored', 'paper_explainer', { topicTitle: true });
    request.localContext = { format: 'reader-local-context-v2', membership_id: '58000000-0000-4000-8000-000000000003', source: 'arxiv', source_id: '2601.01234',
      revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] x' };
    const body = requestBody(request);
    expect(body).toMatchObject({ action: 'paper_explainer', mode: 'paper', messages: [{ role: 'user', text: 'Explain this paper' }] });
    expect(body.capabilities).toEqual(['visual_answers', 'figure_requests', 'figure_view', 'stop_signal']);
    for (const key of ['selection', 'topic_title', 'follow_ups', 'figures', 'document_id', 'study', 'study_state']) expect(body).not.toHaveProperty(key);
  });
});

describe('the explainer in the chat session', () => {
  const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001', member = '58000000-0000-4000-8000-000000000003';
  const reference = { format: 'source-membership-v1' as const, membershipID: member, source: 'arxiv' as const, sourceID: '2601.01234', revision: 2 };
  const bundle = { manifestSHA256: 'c'.repeat(64), index: { figures: [], blocks: [] } };
  beforeEach(() => { server.requests = []; });
  async function setup(answers: StreamEvent[][], consent = true) {
    const { ChatSession } = await import('../src/lib/chat-session');
    const { History } = await import('../src/lib/history');
    const { keyRing, generateBundle } = await import('../src/lib/wire');
    const owner = new AbortController(), ring = await keyRing(generateBundle(account));
    const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
    let turn = 0;
    const chat = new ChatSession(account, history, owner.signal, {
      readConsent: () => consent, writeConsent: () => {},
      stream: async function* (_account, request, _signal, opened) { server.requests.push(request); opened?.(); for (const e of answers[Math.min(turn++, answers.length - 1)]) yield e; },
    });
    chat.setSourcePapers(new Map([[member, { reference, load: async () => bundle as any }]]));
    return chat;
  }
  it('streams the summary and entries in order, then keeps the whole explainer for this paper revision', async () => {
    const [b1, b2] = sample.background, [i1] = sample.ideas;
    const chat = await setup([[{ type: 'paper_progress', stage: 'reading' }, { type: 'paper_progress', stage: 'writing', characters: 200, items: 3 },
      { type: 'paper_summary', summary: 'In short.' }, { type: 'paper_item', kind: 'background', index: 1, item: b2 }, { type: 'paper_item', kind: 'background', index: 0, item: b1 },
      { type: 'paper_item', kind: 'idea', index: 0, item: i1 }, { type: 'paper_explainer', explainer: sample }, { type: 'done', stopReason: 'end_turn', credits: 4, charged: true }]]);
    const seen: { names: string[]; summary: string; progress?: unknown }[] = [];
    const result = await chat.paperExplainer(member, r => seen.push({ names: [...(r.explainer?.background ?? []), ...(r.explainer?.ideas ?? [])].map(i => i.name), summary: r.explainer?.summary ?? '', progress: r.progress }), new AbortController().signal);
    expect(result).toMatchObject({ phase: 'done', explainer: sample, issue: null, charged: true, credits: 4 });
    expect(result.progress).toBeUndefined();
    // An entry shows only once those before it in its kind have (the second background entry waited for the first).
    expect(seen.map(s => s.names.length)).toEqual([0, 0, 0, 0, 0, 0, 2, 3, sample.background.length + sample.ideas.length, sample.background.length + sample.ideas.length]);
    expect(seen.find(s => s.summary)?.summary).toBe('In short.');
    expect(server.requests[0]).toMatchObject({ action: 'paper_explainer', selection: null, turns: [{ role: 'user', text: 'Explain this paper' }], documentID: null });
    // Kept: the same model asks nothing again, and Your assets lists it once.
    expect(chat.savedPaperExplainer('c'.repeat(64))).toMatchObject({ explainer: sample });
    await chat.paperExplainer(member, () => {}, new AbortController().signal);
    expect(server.requests).toHaveLength(1);
    expect(chat.explanations('paper')).toMatchObject([{ kind: 'paper', documentID: member, targetID: 'paper', label: 'AI Explainer' }]);
    expect(chat.keptEntries().filter(e => e.kind === 'paper')).toHaveLength(1);
  });
  it('shows the model’s words when there is no explainer, drops streamed entries on a failure, and asks nothing without consent', async () => {
    const words = await (await setup([[{ type: 'delta', text: 'About attention [¶2].' }, { type: 'done', stopReason: 'end_turn', credits: 2 }]]))
      .paperExplainer(member, () => {}, new AbortController().signal);
    expect(words).toMatchObject({ phase: 'done', explainer: null, text: 'About attention [¶2].' });
    const failed = await (await setup([[{ type: 'paper_summary', summary: 'In short.' }, { type: 'paper_item', kind: 'background', index: 0, item: sample.background[0] },
      { type: 'error', code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider' }]])).paperExplainer(member, () => {}, new AbortController().signal);
    expect(failed).toMatchObject({ phase: 'failed', explainer: null, issue: 'provider_unavailable' });
    const chat = await setup([[{ type: 'done', stopReason: 'end_turn', credits: 0 }]], false);
    expect(await chat.paperExplainer(member, () => {}, new AbortController().signal)).toMatchObject({ phase: 'failed', issue: 'consent_required' });
    expect(server.requests).toHaveLength(2);
  });
});
