import { describe, expect, it } from 'vitest';
import {
  catalogSeeds, decodeEvent, eligibleSeed, errorMessage, footerText, recommendBody, RecommendationRun, recommendKeywords, RecommendStreamParser,
  statusText, type RecommendBody, type RecommendEvent, type RecommendedPaper,
} from '../src/lib/recommend';
import type { ClientEntry, LibraryPaper } from '../src/lib/device-pdf';

const item = (source: string, extra: Record<string, unknown> = {}) => ({ kind: 'item', id: `id-${source}`, document_id: `doc-${source}`, visible: true,
  added_at: 1, source: 'arxiv', source_id: source, scope: 'shared_catalog', membership_revision: 1,
  metadata: { title: `Paper ${source}`, authors: ['A'], categories: ['cs.IR'] }, tags: [], ...extra }) as unknown as LibraryPaper;
const paper = (n: number, status: RecommendedPaper['status'] = 'added'): RecommendedPaper => ({ source_id: `2410.0000${n}`, revision: 1, title: `Rec ${n}`,
  authors: ['E. Five'], year: 2026, reason: `Reason ${n}`, status, import_id: status === 'added' ? `00000000-0000-4000-8000-00000000000${n}` : null });
const frames = (events: unknown[]) => new TextEncoder().encode(': open\n\n' + events.map(e => `data: ${JSON.stringify(e)}\n\n`).join(': ping\n\n'));

describe('recommendation events', () => {
  it('parses data lines across any chunking and ignores comments, other fields and unknown types', () => {
    const bytes = frames([{ type: 'status', phase: 'searching' }, { type: 'unknown' }, { type: 'status', phase: 'choosing', candidates: 34 },
      { type: 'paper', ordinal: 1, paper: paper(1) }, { type: 'done', added: 1, requested: 3, credits: 1, charged: true }]);
    for (const size of [1, 5, 64, bytes.length]) {
      const parser = new RecommendStreamParser(), seen: RecommendEvent[] = [];
      for (let i = 0; i < bytes.length; i += size) seen.push(...parser.consume(bytes.slice(i, i + size)));
      seen.push(...parser.finish());
      expect(seen.map(e => e.type)).toEqual(['status', 'status', 'paper', 'done']);
    }
    // \r\n and an `event:` field are tolerated; a malformed line is skipped.
    const parser = new RecommendStreamParser();
    expect(parser.consume(new TextEncoder().encode('event: x\r\ndata: {bad\r\n\r\ndata: {"type":"error","code":"daily_limit"}\r\n\r\n'))).toEqual([{ type: 'error', code: 'daily_limit' }]);
  });

  it('bounds and checks every field', () => {
    expect(decodeEvent({ type: 'paper', paper: { ...paper(1), source_id: 'https://arxiv.org/abs/1' } })).toBeNull();
    expect(decodeEvent({ type: 'paper', paper: { ...paper(1), title: 'x'.repeat(301) } })).toBeNull();
    expect(decodeEvent({ type: 'paper', paper: { ...paper(1), status: 'maybe' } })).toBeNull();
    const ok = decodeEvent({ type: 'paper', ordinal: 2, paper: { ...paper(2), authors: ['a', 'b', 'c', 'd', 3], year: 12, import_id: 'nope' } });
    expect(ok).toMatchObject({ type: 'paper', ordinal: 2, paper: { authors: ['a', 'b', 'c'], year: null, import_id: null } });
    expect(decodeEvent({ type: 'paper', paper: { ...paper(3, 'present'), import_id: '00000000-0000-4000-8000-000000000003' } })).toMatchObject({ paper: { import_id: null } });
    expect(decodeEvent({ type: 'done', added: 9, requested: 3, credits: 1, charged: true })).toBeNull();
    expect(decodeEvent({ type: 'done', added: 0, requested: 3, credits: 0, charged: false, reason: 'none_related' })).toMatchObject({ reason: 'none_related' });
    expect(decodeEvent({ type: 'error', code: 'Bad Code!', retry_after: 9999 })).toEqual({ type: 'error', code: 'service_unavailable', retry_after: 600 });
  });
});

describe('recommendation requests', () => {
  it('sends the specific keywords the reader sees, within the server\'s rule', () => {
    const p = item('2401.00001', { tags: ['Large language models', 'Generative retrieval', 'Document identifiers'], user_tags: ['k-NN search (fast)', 'x', 'Machine learning'] });
    expect(recommendKeywords(p, 6)).toEqual(['Generative retrieval', 'Document identifiers', 'k-NN search (fast)']);
    expect(recommendKeywords(p, 1)).toEqual(['Generative retrieval']);
    const body = recommendBody('paper', [p], 3, '00000000-0000-4000-8000-0000000000aa');
    expect(body).toEqual({ operation_id: '00000000-0000-4000-8000-0000000000aa', count: 3, scope: 'paper',
      seeds: [{ source_id: '2401.00001', keywords: ['Generative retrieval', 'Document identifiers', 'k-NN search (fast)'] }] });
    const catalog = recommendBody('catalog', [p, item('2401.00002')], 5);
    expect(catalog.seeds[0].keywords).toHaveLength(3);
    expect(catalog.seeds).toHaveLength(2);
  });

  it('only papers the server has details for seed a request; a catalog uses its eight newest', () => {
    const local = { kind: 'local_pdf', id: 'l', visible: true, metadata: { title: 'Mine' } } as unknown as ClientEntry;
    expect(eligibleSeed(local)).toBe(false);
    expect(eligibleSeed(item('2401.00001'))).toBe(true);
    expect(eligibleSeed(item('openalex:W2963403868'))).toBe(true);
    expect(eligibleSeed(item('2401.00001', { visible: false }))).toBe(false);
    expect(eligibleSeed(item('2401.00001', { metadata: undefined }))).toBe(false);
    expect(eligibleSeed({ kind: 'import', id: 'i', visible: true, source_id: '2401.00009', phase: 'accepted' } as unknown as ClientEntry)).toBe(false);
    const entries = Array.from({ length: 12 }, (_, i) => item(`2401.000${String(i).padStart(2, '0')}`, { added_at: i }));
    const seeds = catalogSeeds([...entries, local, item('2401.00011', { added_at: 99 })], e => e.source_id !== '2401.00010');
    expect(seeds.map(s => s.source_id)).toEqual(['2401.00011', '2401.00009', '2401.00008', '2401.00007', '2401.00006', '2401.00005', '2401.00004', '2401.00003']);
  });
});

function fakeRun(events: RecommendEvent[][], overrides: { assignFails?: boolean; removeFails?: string } = {}) {
  const calls = { bodies: [] as RecommendBody[], assigned: [] as string[], removed: [] as string[], refreshes: 0, sleeps: [] as number[] };
  let attempt = 0;
  const run = new RecommendationRun({
    stream: async function* (body) { calls.bodies.push(body); for (const e of events[attempt++] ?? []) yield e; },
    assign: async source => { if (overrides.assignFails) throw Error('locked'); calls.assigned.push(source); },
    refresh: async () => { calls.refreshes++; },
    remove: async p => { if (p.source_id === overrides.removeFails) throw Error('busy'); calls.removed.push(p.source_id); },
    sleep: async ms => { calls.sleeps.push(ms); },
  }, recommendBody('paper', [item('2401.00001')], 3, '00000000-0000-4000-8000-0000000000bb'), 'Evolving Semantic Indexes', 'Reading');
  return { run, calls };
}

describe('a recommendation run', () => {
  const done: RecommendEvent = { type: 'done', added: 2, requested: 3, credits: 1, charged: true };
  it('follows the stream, puts each added paper in the catalog, then says what it cost', async () => {
    const { run, calls } = fakeRun([[{ type: 'status', phase: 'searching' }, { type: 'status', phase: 'choosing', candidates: 34 },
      { type: 'paper', ordinal: 1, paper: paper(1) }, { type: 'paper', ordinal: 2, paper: paper(2) }, { type: 'paper', ordinal: 3, paper: paper(3, 'present') }, done]]);
    const phases: string[] = [];
    run.subscribe(() => phases.push(`${run.state.phase}:${run.state.rows.length}`));
    expect(statusText(run.state)).toBe('Finding papers like “Evolving Semantic Indexes”…');
    await run.start();
    expect(phases).toContain('choosing:0');
    expect(calls.assigned).toEqual(['2410.00001', '2410.00002']);
    expect(calls.refreshes).toBe(2);
    expect(run.state.phase).toBe('done');
    expect(footerText(run.state)).toBe('Added 2 papers to Reading · 1 credit');
    expect(run.addedCount).toBe(2);
  });

  it('Remove takes one back; Undo removes the rest; failures are shown per paper', async () => {
    const { run, calls } = fakeRun([[{ type: 'paper', ordinal: 1, paper: paper(1) }, { type: 'paper', ordinal: 2, paper: paper(2) }, { type: 'paper', ordinal: 3, paper: paper(3) }, { ...done, added: 3 }]],
      { removeFails: '2410.00003' });
    await run.start();
    await run.remove('2410.00002');
    expect(run.state.rows.find(r => r.paper.source_id === '2410.00002')?.removal).toBe('removed');
    await run.undo();
    expect(calls.removed).toEqual(['2410.00002', '2410.00001']);
    expect(run.state.rows.find(r => r.paper.source_id === '2410.00003')?.removal).toBe('failed');
    expect(run.state.undone).toBe(false);
    await run.remove('2410.00002'); // already removed: nothing more
    expect(calls.removed).toHaveLength(2);
  });

  it('a full Undo says so; nothing related and refusals are free and plain', async () => {
    const { run } = fakeRun([[{ type: 'paper', ordinal: 1, paper: paper(1) }, { ...done, added: 1 }]]);
    await run.start(); await run.undo();
    expect(run.state.undone).toBe(true);
    expect(footerText(run.state)).toBe('Removed the 1 paper again · 1 credit');
    const none = fakeRun([[{ type: 'done', added: 0, requested: 3, credits: 0, charged: false, reason: 'none_related' }]]);
    await none.run.start();
    expect(footerText(none.run.state)).toBe('No closely related papers found. Nothing was charged.');
    const limit = fakeRun([[{ type: 'error', code: 'daily_limit' }]]);
    await limit.run.start();
    expect(limit.run.state.error).toEqual({ code: 'daily_limit', message: errorMessage('daily_limit'), retryable: false });
    expect(errorMessage('insufficient_credits')).toContain('out of AI credits');
  });

  it('in progress: waits and asks again once with the same request; Try again is a new request', async () => {
    const { run, calls } = fakeRun([[{ type: 'error', code: 'in_progress', retry_after: 5 }], [{ type: 'paper', ordinal: 1, paper: paper(1) }, { ...done, added: 1 }],
      [{ type: 'error', code: 'service_unavailable' }], [{ ...done, added: 0, reason: 'none_related' }]]);
    await run.start();
    expect(calls.sleeps).toEqual([5000]);
    expect(calls.bodies[0].operation_id).toBe(calls.bodies[1].operation_id);
    expect(run.state.phase).toBe('done');
    // A later failure and Try again: a new operation id.
    await run.retry(); // the third script: fails
    expect(run.state.error?.retryable).toBe(true);
    await run.retry();
    expect(new Set(calls.bodies.map(b => b.operation_id)).size).toBe(3);
  });

  it('a stream that ends early keeps what was added and says why; a catalog it could not write is noted', async () => {
    const { run } = fakeRun([[{ type: 'paper', ordinal: 1, paper: paper(1) }]], { assignFails: true });
    await run.start();
    expect(run.state.phase).toBe('failed');
    expect(run.state.rows).toHaveLength(1);
    expect(run.state.catalogIssue).toBe(true);
    expect(run.state.error?.message).toContain('If papers were added, they’re in your library');
  });
});
