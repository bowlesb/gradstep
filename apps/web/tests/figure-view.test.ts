// The figure view (docs/architecture/FIGURE_VIEW.md): the server's `figure` event checked again, the request's shape
// (the chat's own, with exactly this figure), the crop arithmetic, and the session's request and cache.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SSEParser, makeRequest, requestBody, type LocalPaperContext, type StreamEvent } from '../src/lib/chat';
import { cropRect, cropStyle, cropCoverage, cardTypeLabel, displayBox, detailQuote, figureBox, figureKey, figureNoun, figureTurn, parseFigureDetail, parseFigureWalkthrough, sectionHeading } from '../src/lib/figure-view';

const server = vi.hoisted(() => ({ requests: [] as any[] }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string) => name === 'v1_credit_balance' ? { available: 100, reserved: 0 } : name === 'v3_pull_events' ? { events: [], next_cursor: 0, has_more: false } : null };
});
vi.mock('../src/lib/arxiv-reader', () => ({ localChatContext: (reference: { membershipID: string }) => ({ format: 'reader-local-context-v2', membership_id: reference.membershipID,
  source: 'arxiv', source_id: '2601.01234', revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] # Fixture\n\n[¶2] Two pipelines.' }) }));
// The image as chat prepares it needs a canvas; its preparation is chat-figures' own (tested with chat).
vi.mock('../src/lib/chat-figures', async original => {
  const mod = await original<typeof import('../src/lib/chat-figures')>();
  return { ...mod, figureImage: async (_bundle: unknown, figure: { block_id: string; caption: string; asset_paths: string[] }) => figure.asset_paths.length
    ? { id: 'F1', paragraph: 3, caption: figure.caption, mediaType: 'image/jpeg', data: 'AAAA', width: 1000, height: 200, blockID: figure.block_id, assetPath: figure.asset_paths[0], assetPaths: figure.asset_paths } : null };
});

const event = { format: 'figure-walkthrough-v1', summary: 'Two pipelines [¶2].', sections: [
  { label: '(a)', title: 'Three stages', text: 'A reward model first [¶2].', paragraphs: [2] },
  { label: '', title: 'One stage', text: 'Straight from preferences.', paragraphs: [2, 3], box: { x: 0.5, y: 0, w: 0.5, h: 1 } }] };
const local: LocalPaperContext = { format: 'reader-local-context-v2', membership_id: '58000000-0000-4000-8000-000000000003', source: 'arxiv', source_id: '2601.01234',
  revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] Title\n\n[¶2] Two pipelines.' };
const image = { id: 'F1', paragraph: 3, caption: 'Figure 1: Two pipelines.', mediaType: 'image/jpeg' as const, data: 'AAAA', width: 1000, height: 200,
  blockID: 'b-3', assetPath: 'assets/x.jpg', assetPaths: ['assets/x.jpg'] };

describe('the walkthrough event', () => {
  it('keeps a checked walkthrough as it came', () => {
    expect(parseFigureWalkthrough(event)).toEqual(event);
  });
  it('degrades rather than refuses: a part without words goes, a box that doesn’t fit goes (its part stays), at most 12 parts and 12 boxes', () => {
    const parsed = parseFigureWalkthrough({ ...event, sections: [
      { label: 'x', title: '', text: 'no title' }, { label: 'y', title: 'No text', text: '  ' }, 'row', null,
      { label: 'z', title: 'Outside', text: 'Box past the edge.', paragraphs: [0, 4, 4, 1e6, 'x'], box: { x: 0.8, y: 0, w: 0.3, h: 0.5 } },
      { label: 'w', title: 'Whole', text: 'The whole image is no crop.', paragraphs: [], box: { x: 0, y: 0, w: 1, h: 1 } },
      { label: 'v', title: 'Tiny', text: 'Too small to see.', box: { x: 0, y: 0, w: 0.02, h: 0.5 } }] })!;
    expect(parsed.sections.map(s => s.title)).toEqual(['Outside', 'Whole', 'Tiny']);
    expect(parsed.sections.every(s => !s.box)).toBe(true);
    expect(parsed.sections[0].paragraphs).toEqual([4]);
    const many = parseFigureWalkthrough({ ...event, sections: Array.from({ length: 15 }, (_, i) => ({ label: `${i}`, title: `Part ${i}`, text: 'Words.', box: { x: 0, y: 0, w: 0.5, h: 0.5 } })) })!;
    expect(many.sections).toHaveLength(12); expect(many.sections.filter(s => s.box)).toHaveLength(12);
    expect(parseFigureWalkthrough({ ...event, format: 'figure-walkthrough-v2' })).toBeNull();
    expect(parseFigureWalkthrough({ ...event, sections: [] })).toBeNull();
    expect(parseFigureWalkthrough({ ...event, summary: 'a\u0000b ' + 'c'.repeat(900) })!.summary).toHaveLength(800);
    expect(figureBox({ x: 0.1, y: 0.1, w: 0.5, h: 0.5 })).toEqual({ x: 0.1, y: 0.1, w: 0.5, h: 0.5 });
    expect(figureBox({ x: '0', y: 0, w: 0.5, h: 0.5 })).toBeNull();
  });
  it('arrives as a stream event; an unusable one is dropped, never fatal', () => {
    const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));
    expect(frames(`event: figure\ndata: ${JSON.stringify(event)}\n\n`)).toEqual([{ type: 'figure', walkthrough: event }]);
    expect(frames('event: figure\ndata: {"format":"x"}\n\nevent: delta\ndata: {"text":"words"}\n\n')).toEqual([{ type: 'delta', text: 'words' }]);
  });
});

// One part extracted (owner, TestFlight 62: "Extract the subfigure and more context").
const detail = { format: 'figure-detail-v1', label: '(a)', title: 'Three stages', text: 'Up close: three boxes [¶2].', paragraphs: [2], box: { x: 0, y: 0, w: 0.5, h: 1 } };
describe('the detail event', () => {
  it('needs a usable region and words; it arrives as a stream event, an unusable one dropped', () => {
    expect(parseFigureDetail(detail)).toEqual(detail);
    for (const box of [undefined, { x: 0, y: 0, w: 1, h: 1 }, { x: 0.9, y: 0, w: 0.5, h: 0.5 }, { x: 0, y: 0, w: 0.01, h: 0.5 }]) expect(parseFigureDetail({ ...detail, box })).toBeNull();
    expect(parseFigureDetail({ ...detail, text: ' ' })).toBeNull();
    expect(parseFigureDetail({ ...detail, format: 'figure-walkthrough-v1' })).toBeNull();
    expect(parseFigureDetail({ ...detail, title: '', paragraphs: [2, 2, 0, 'x'] })).toMatchObject({ label: '', title: '(a)', paragraphs: [2] });
    const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));
    expect(frames(`event: figure_detail\ndata: ${JSON.stringify(detail)}\n\n`)).toEqual([{ type: 'figure_detail', detail }]);
    expect(frames('event: figure_detail\ndata: {"format":"x"}\n\n')).toEqual([]);
    expect(detailQuote({ label: '(a)', title: 'Three stages', text: 'A reward model first.' })).toBe('(a) Three stages\nA reward model first.');
  });
});

describe('figure requests', () => {
  it('are the chat request for the paper with the action and exactly this figure: same capabilities, no title or suggestions', () => {
    const chat = makeRequest('op-1', null, [{ role: 'user', text: 'What does Figure 1 show?' }], null, null, { visualAnswers: true }); chat.localContext = local;
    expect(requestBody(chat).capabilities).toEqual(['visual_answers', 'figure_requests', 'figure_view', 'stop_signal']);
    for (const [action, turn, quote] of [['figure', 'Figure 1', 'Figure 1: Two pipelines.'], ['figure_simpler', 'Figure 1 (a)', 'A reward model first [¶2].']] as const) {
      const request = makeRequest('op-2', null, [{ role: 'user', text: turn }], quote, action, { topicTitle: true, visualAnswers: true });
      request.localContext = local; request.figures = [image];
      const body = requestBody(request);
      expect(body).toMatchObject({ mode: 'paper', action, consent_version: 'cloud-ai-v6', selection: { quote }, messages: [{ role: 'user', text: turn }], local_context: local,
        figures: [{ id: 'F1', paragraph: 3, caption: 'Figure 1: Two pipelines.', media_type: 'image/jpeg', data: 'AAAA', width: 1000, height: 200 }] });
      expect(body.capabilities).toEqual(requestBody(chat).capabilities);
      for (const key of ['topic_title', 'follow_ups', 'document_id', 'study']) expect(body).not.toHaveProperty(key);
    }
    // Visual answers off still says figure_view: the walkthrough tool doesn't depend on it.
    const prose = makeRequest('op-3', null, [{ role: 'user', text: 'Figure 1' }], 'c', 'figure', { visualAnswers: false }); prose.localContext = local;
    expect(requestBody(prose).capabilities).toEqual(['figure_view', 'stop_signal']);
    expect(figureTurn('Figure 1')).toBe('Figure 1'); expect(figureTurn('Table 2', ' Proprietary ')).toBe('Table 2 Proprietary');
    expect(figureKey('m', 'b-3', 'figure_simpler', 'p', '0:(a):x')).not.toBe(figureKey('m', 'b-3', 'figure_simpler', 'p', '1::y'));
    expect(sectionHeading({ label: '(a)', title: 'Three stages' })).toBe('(a) · Three stages'); expect(sectionHeading({ label: '', title: 'Legend' })).toBe('Legend');
  });
});

describe('crops', () => {
  it('keeps nearby axis text in the FDE-Gym panels without changing stored geometry or leaving the image', () => {
    const original = { x: 0, y: 0, w: 0.49, h: 0.98 }, size = { width: 1000, height: 400 };
    const left = cropRect(displayBox(original), size);
    expect(left.x).toBe(0); expect(left.y).toBe(0);
    expect(left.x + left.width).toBeGreaterThanOrEqual(510); expect(left.height).toBe(400);
    expect(original.w).toBe(0.49);
    const right = cropRect(displayBox({ x: 0.5, y: 0.01, w: 0.49, h: 0.98 }), size);
    expect(right.x).toBeLessThanOrEqual(480); expect(right.x + right.width).toBe(1000); expect(right.height).toBe(400);
  });
  it('fill their frame with the box: the right half of a wide figure, and a centred quarter', () => {
    expect(cropStyle({ x: 0.5, y: 0, w: 0.5, h: 1 }, { width: 1000, height: 200 })).toEqual({ aspect: 2.5, size: '200% 100%', position: '100% 0%' });
    expect(cropStyle({ x: 0.25, y: 0.25, w: 0.5, h: 0.5 }, { width: 800, height: 800 })).toEqual({ aspect: 1, size: '200% 200%', position: '50% 50%' });
    expect(cropStyle({ x: 0.1, y: 0.6, w: 0.2, h: 0.4 }, { width: 1000, height: 500 })).toEqual({ aspect: 1, size: '500% 250%', position: '12.5% 100%' });
    expect(cropRect({ x: 0.5, y: 0, w: 0.5, h: 1 }, { width: 1001, height: 200 })).toEqual({ x: 500, y: 0, width: 501, height: 200 });
    expect(cropRect({ x: 0.9999, y: 0.9999, w: 0.04, h: 0.04 }, { width: 100, height: 100 })).toEqual({ x: 99, y: 99, width: 1, height: 1 });
  });
});

describe('the figure view in the chat session', () => {
  const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001', member = '58000000-0000-4000-8000-000000000003';
  const reference = { format: 'source-membership-v1' as const, membershipID: member, source: 'arxiv' as const, sourceID: '2601.01234', revision: 2 };
  const bundle = { manifestSHA256: 'c'.repeat(64), index: { figures: [{ id: 'b-3', block_id: 'b-3', caption: 'Figure 1: Two pipelines.', alt: 'Two pipelines', asset_paths: ['assets/x.jpg'] }], blocks: [] } };
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
      stream: async function* (_account, request) { server.requests.push(request); for (const e of answers[Math.min(turn++, answers.length - 1)]) yield e; },
    });
    chat.setSourcePapers(new Map([[member, { reference, load: async () => bundle as any }]]));
    return chat;
  }
  it('sends the walkthrough with the figure, keeps it for the session, and asks a part again more simply', async () => {
    const chat = await setup([[{ type: 'figure', walkthrough: event as any }, { type: 'done', stopReason: 'end_turn', credits: 5, charged: true }],
      [{ type: 'delta', text: 'Start with ' }, { type: 'delta', text: 'the left half.' }, { type: 'done', stopReason: 'end_turn', credits: 3, charged: true }]]);
    const seen: string[] = [];
    const walk = await chat.figure(member, { figureID: 'b-3' }, 'figure', r => seen.push(r.phase), new AbortController().signal);
    expect(walk).toMatchObject({ phase: 'done', walkthrough: event, image: { data: 'AAAA', width: 1000, height: 200 }, issue: null, charged: true });
    const sent = server.requests[0];
    expect(sent).toMatchObject({ action: 'figure', selection: 'Figure 1: Two pipelines.', turns: [{ role: 'user', text: 'Figure 1' }], documentID: null });
    expect(sent.figures).toHaveLength(1); expect(sent.localContext.format).toBe('reader-local-context-v2');
    expect(requestBody(sent).capabilities).toContain('figure_view');
    // Reopened: the same walkthrough without a new request.
    expect(chat.savedFigure(bundle.manifestSHA256, 'b-3', 'figure')).toEqual(walk);
    await chat.figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal);
    expect(server.requests).toHaveLength(1);
    const part = { key: '0:(a):Three stages', label: '(a)', title: 'Three stages', text: 'A reward model first [¶2].' };
    const simpler = await chat.figure(member, { figureID: 'b-3', part }, 'figure_simpler', () => {}, new AbortController().signal);
    expect(simpler).toMatchObject({ phase: 'done', text: 'Start with the left half.', walkthrough: null });
    expect(server.requests[1]).toMatchObject({ action: 'figure_simpler', selection: part.text, turns: [{ role: 'user', text: 'Figure 1 (a)' }] });
    expect(chat.savedFigure(bundle.manifestSHA256, 'b-3', 'figure_simpler', part.key)).toEqual(simpler);
    expect(chat.savedFigure(bundle.manifestSHA256, 'b-3', 'figure_simpler', '1::One stage')).toBeNull();
  });
  it('extracts a part: its label, title and text as the passage, the region kept with the result; words alone without a region', async () => {
    const chat = await setup([[{ type: 'figure_detail', detail: detail as any }, { type: 'done', stopReason: 'end_turn', credits: 3, charged: true }],
      [{ type: 'delta', text: 'The legend, read closely.' }, { type: 'done', stopReason: 'end_turn', credits: 2, charged: true }]]);
    const part = { key: '0:(a):Three stages', label: '(a)', title: 'Three stages', text: 'A reward model first [¶2].' };
    const closer = await chat.figure(member, { figureID: 'b-3', part }, 'figure_detail', () => {}, new AbortController().signal);
    expect(closer).toMatchObject({ phase: 'done', detail, image: { data: 'AAAA' }, charged: true });
    expect(server.requests[0]).toMatchObject({ action: 'figure_detail', selection: '(a) Three stages\nA reward model first [¶2].', turns: [{ role: 'user', text: 'Figure 1 (a)' }] });
    expect(requestBody(server.requests[0])).toMatchObject({ action: 'figure_detail' });
    expect(requestBody(server.requests[0]).follow_ups).toBeUndefined();
    expect(chat.savedFigure(bundle.manifestSHA256, 'b-3', 'figure_detail', part.key)).toEqual(closer);
    const legend = { key: '2::Legend', label: '', title: 'Legend', text: 'Arrows show data flow.' };
    const words = await chat.figure(member, { figureID: 'b-3', part: legend }, 'figure_detail', () => {}, new AbortController().signal);
    expect(words).toMatchObject({ phase: 'done', text: 'The legend, read closely.' }); expect(words.detail).toBeUndefined();
    expect((await chat.figure(member, { figureID: 'b-3' }, 'figure_detail', () => {}, new AbortController().signal)).issue).toBe('invalid_request');
  });
  it('shows the words when no walkthrough came, fails plainly with nothing, and sends nothing without consent or the paper', async () => {
    const words = await (await setup([[{ type: 'delta', text: 'The figure shows two pipelines.' }, { type: 'done', stopReason: 'max_tokens', credits: 0, charged: false, reason: 'limit' }]]))
      .figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal);
    expect(words).toMatchObject({ phase: 'done', walkthrough: null, text: 'The figure shows two pipelines.', charged: false, reason: 'limit' });
    const nothing = await (await setup([[{ type: 'done', stopReason: 'end_turn', credits: 0, charged: false, reason: 'provider' }]]))
      .figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal);
    expect(nothing).toMatchObject({ phase: 'failed', issue: 'provider_unavailable' });
    server.requests = [];
    const chat = await setup([[{ type: 'done', stopReason: 'end_turn', credits: 1 }]], false);
    expect((await chat.figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal)).issue).toBe('consent_required');
    const other = await setup([[{ type: 'done', stopReason: 'end_turn', credits: 1 }]]);
    expect((await other.figure('dddddddd-0000-4000-8000-000000000001', { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal)).issue).toBe('local_reader_unavailable');
    expect((await other.figure(member, { figureID: 'missing' }, 'figure', () => {}, new AbortController().signal)).issue).toBe('figure_unavailable');
    expect((await other.figure(member, { figureID: 'b-3' }, 'figure_simpler', () => {}, new AbortController().signal)).issue).toBe('invalid_request');
    expect(server.requests).toHaveLength(0);
  });
  it('keeps a bounded number of finished results, the oldest out first (C8, B4)', async () => {
    const chat = await setup([[{ type: 'delta', text: 'It squares x.' }, { type: 'done', stopReason: 'end_turn', credits: 1, charged: true }]]);
    for (let i = 0; i < 401; i++) await chat.equation(member, { equationID: `e${i}`, latex: 'x^2', number: null }, 'equation', () => {}, new AbortController().signal);
    expect(chat.savedEquation(bundle.manifestSHA256, 'e0', 'equation')).toBeNull();
    expect(chat.savedEquation(bundle.manifestSHA256, 'e1', 'equation')).not.toBeNull();
    expect(chat.keptEntries().filter(e => e.kind === 'equation')).toHaveLength(400);
  });
  it('keeps finished explanations for a later session: they reopen without a request and stay listed (B4)', async () => {
    const chat = await setup([[{ type: 'figure', walkthrough: event as any }, { type: 'done', stopReason: 'end_turn', credits: 5, charged: true, model: 'gemini-3.8-flash' }],
      [{ type: 'delta', text: 'It squares x.' }, { type: 'done', stopReason: 'end_turn', credits: 2, charged: true }]]);
    let saved = 0; chat.onKept(() => saved++);
    await chat.figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal);
    await chat.equation(member, { equationID: 'e1', latex: 'x^2', number: '(1)' }, 'equation', () => {}, new AbortController().signal);
    expect(saved).toBe(2);
    const kept = chat.keptEntries();
    expect(kept.map(e => e.kind).sort()).toEqual(['equation', 'figure']);
    expect((kept.find(e => e.kind === 'figure')!.result as any).image).toBeNull(); // the image is prepared again, never kept
    expect((kept.find(e => e.kind === 'figure')!.result as any).model).toBe('gemini-3.8-flash');
    server.requests = [];
    const later = await setup([[{ type: 'done', stopReason: 'end_turn', credits: 0 }]]);
    expect(later.explanations('equation')).toEqual([]);
    later.restoreKept(JSON.parse(JSON.stringify(kept)));
    expect(later.explanations('equation').map(e => e.label)).toEqual(['Equation (1)']);
    expect(later.explanations('figure').map(e => e.targetID)).toEqual(['b-3']);
    expect(later.savedEquation(bundle.manifestSHA256, 'e1', 'equation')).toMatchObject({ phase: 'done', text: 'It squares x.' });
    const reopened = await later.figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal);
    expect(reopened).toMatchObject({ phase: 'done', walkthrough: event });
    expect(server.requests).toHaveLength(0);
    expect(await later.keptFigureImage(member, 'b-3')).toMatchObject({ data: 'AAAA', width: 1000, height: 200 });
  });
  it('lets go of a figure or equation composer that was only shown, keeping one with text (C8)', async () => {
    const chat = await setup([[{ type: 'done', stopReason: 'end_turn', credits: 0 }]]);
    const anchor = { manifestSHA256: bundle.manifestSHA256, elementID: 'b-3', quote: 'Figure 1', prefix: '', suffix: '' };
    const shown = chat.contextualComposer(member, anchor);
    expect(chat.composers.has(shown.id)).toBe(true);
    chat.releaseContextual(shown);
    expect(chat.composers.has(shown.id)).toBe(false);
    chat.retainContextual(shown, 'figures'); // shown again (a remount)
    expect(chat.contextualComposer(member, anchor)).toBe(shown);
    chat.edit(shown, 'What is on the left?');
    chat.releaseContextual(shown);
    expect(chat.composers.has(shown.id)).toBe(true);
  });
  it('lists what this tab explained for Your assets: each figure or equation once, newest first; a failure is not listed', async () => {
    const chat = await setup([[{ type: 'figure', walkthrough: event as any }, { type: 'done', stopReason: 'end_turn', credits: 5, charged: true }],
      [{ type: 'delta', text: 'Simpler.' }, { type: 'done', stopReason: 'end_turn', credits: 1, charged: true }],
      [{ type: 'delta', text: 'It squares x.' }, { type: 'done', stopReason: 'end_turn', credits: 2, charged: true }],
      [{ type: 'done', stopReason: 'end_turn', credits: 0, charged: false, reason: 'provider' }]]);
    expect(chat.explanations('figure')).toEqual([]); expect(chat.explanations('equation')).toEqual([]);
    await chat.figure(member, { figureID: 'b-3' }, 'figure', () => {}, new AbortController().signal);
    // A part asked again doesn't list the figure twice.
    await chat.figure(member, { figureID: 'b-3', part: { key: '0:(a):Three stages', label: '(a)', title: 'Three stages', text: 'A reward model first.' } }, 'figure_simpler', () => {}, new AbortController().signal);
    expect(chat.explanations('figure')).toEqual([{ kind: 'figure', documentID: member, manifest: bundle.manifestSHA256, targetID: 'b-3', label: 'Figure 1', at: expect.any(Number) }]);
    await chat.equation(member, { equationID: 'e1', latex: 'x^2', number: '(1)' }, 'equation', () => {}, new AbortController().signal);
    expect(chat.explanations('equation')).toEqual([{ kind: 'equation', documentID: member, manifest: bundle.manifestSHA256, targetID: 'e1', label: 'Equation (1)', at: expect.any(Number) }]);
    const failed = await chat.equation(member, { equationID: 'e2', latex: 'y', number: null }, 'equation', () => {}, new AbortController().signal);
    expect(failed.phase).toBe('failed');
    expect(chat.explanations('equation').map(e => e.targetID)).toEqual(['e1']);
    expect(chat.explanations('figure').map(e => e.targetID)).toEqual(['b-3']);
  });
});


describe('complete-figure presentation', () => {
  const section = (box: {x:number;y:number;w:number;h:number}) => ({label:'',title:'Panel',text:'Text',paragraphs:[],box});
  const size = {width:1001,height:503};
  it('counts every pixel once for grids, overlap, insets and grouped panels', () => {
    const grid = [0, 0.5].flatMap(y => [0, 1/3, 2/3].map(x => section({x,y,w:1/3,h:0.5})));
    expect(cropCoverage(grid,size)).toBe(1);
    expect(cropCoverage([...grid,section({x:0.2,y:0.2,w:0.1,h:0.1})],size)).toBe(1);
    const grouped = [section({x:0,y:0,w:0.7,h:1}),section({x:0.6,y:0,w:0.4,h:1})];
    expect(cropCoverage(grouped,size)).toBe(1);
  });
  it('detects holes and missing legends despite summed overlapping areas greater than a whole image', () => {
    const partial = [section({x:0,y:0,w:0.7,h:0.8}),section({x:0.3,y:0,w:0.7,h:0.8})];
    expect(cropCoverage(partial,size)).toBeLessThan(0.83);
    const hole = [section({x:0,y:0,w:0.4,h:1}),section({x:0.6,y:0,w:0.4,h:1}),section({x:0,y:0,w:1,h:0.4}),section({x:0,y:0.6,w:1,h:0.4})];
    expect(cropCoverage(hole,size)).toBeLessThan(1);
    expect(cropCoverage([],size)).toBeNull();
    expect(cropCoverage([section({x:0,y:0,w:1,h:1})],size)).toBeNull(); // A whole image is no successful extraction.
    expect(cropCoverage(partial,{width:0,height:10})).toBeNull();
  });
  it('keeps old cards readable, labels new kinds, and never crops a concept or related-work card', () => {
    const box = {x:0,y:0,w:0.5,h:1};
    const parsed = parseFigureWalkthrough({...event,sections:['concept','related_work','future',undefined].map(kind => ({...section(box),kind}))})!;
    expect(parsed.sections.map(cardTypeLabel)).toEqual(['Concept','Related work','Panel','Panel']);
    expect(parsed.sections.map(s => !!s.box)).toEqual([false,false,true,true]);
    expect(cropCoverage(parsed.sections,size)).toBeLessThan(1);
  });
});

describe('the figure page names its item (build 76: a table sheet said "Chat about Figure")', () => {
  it('says Table for tables and Figure otherwise', () => {
    for (const label of ['Table 3', 'Table', 'TABLE IV', 'Tab. 2', 'Tables 2']) expect(figureNoun(label)).toBe('Table');
    for (const label of ['Figure 2', 'Fig. 1', 'Algorithm 1', 'Tabular data overview', '']) expect(figureNoun(label)).toBe('Figure');
  });
});
