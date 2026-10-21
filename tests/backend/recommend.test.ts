// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md): request validation, search terms, candidate merge and
// exclusion, the bounded prompt, streamed pick parsing, the whole run with fakes (events, idempotent adds, settlement,
// replay, failures uncharged) and the real OpenRouter adapter's attribution. No network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  cleanReason, importIDFor, mergeCandidates, parseRecommendRequest, PickScanner, recommendFrame, recommendParams, RecommendRpcFailure,
  runRecommend, searchTerms, titlePhrase, RECOMMEND_MODEL, type Candidate, type RecommendDeps, type RecommendEvent, type SeedPaper,
} from '../../supabase/functions/_shared/recommend.ts';
import { holdForParams, type ProviderOutcome } from '../../supabase/functions/_shared/inference.ts';
import { admittedModelCalls } from '../../supabase/functions/_shared/provider-spending.ts';
import { openRouterChat } from '../../supabase/functions/_shared/openrouter-chat.ts';
import type { SearchResult } from '../../supabase/functions/_shared/paper-search.ts';

const OP = 'bbbbbbbb-0000-4000-8000-000000000143';
const ACCOUNT = 'aaaaaaaa-0000-4000-8000-000000000143';
const sha256Hex = async (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const seed: SeedPaper = { source_id: '2401.00001', title: 'Evolving Semantic Indexes for Generative Retrieval', abstract: 'We study generative retrieval.',
  authors: ['Ada One', 'Bo Two'], categories: ['cs.IR', 'cs.CL'], tags: ['Machine learning', 'Semantic indexes'] };
const candidate = (n: number, extra: Partial<Candidate> = {}): Candidate => ({ source_id: `2410.${String(n).padStart(5, '0')}`, revision: 1,
  title: `Candidate paper ${n}`, authors: ['E. Five'], year: 2026, abstract: `Abstract ${n}.`, categories: ['cs.IR'], ...extra });
const result = (n: number): SearchResult => ({ source_id: `2410.${String(n).padStart(5, '0')}`, revision: 2, title: `Search paper ${n}`, authors: ['A', 'B', 'C', 'D'],
  year: 2025, abstract: 'short', full_abstract: `Full abstract ${n}.`, abstract_truncated: false, categories: ['cs.IR'], topics: [] });

test('the request: strict shape, 1/3/5, one seed for a paper and up to 8 for a catalog, clean keywords', () => {
  const ok = parseRecommendRequest({ operation_id: OP.toUpperCase(), count: 3, scope: 'paper',
    seeds: [{ source_id: '2401.00001', keywords: [' Generative  retrieval ', 'generative retrieval', 'Mixture-of-Experts (MoE)'] }] });
  assert.deepEqual(ok, { operationID: OP, count: 3, scope: 'paper', seeds: [{ source_id: '2401.00001', keywords: ['Generative retrieval', 'Mixture-of-Experts (MoE)'] }] });
  assert.equal(parseRecommendRequest({ operation_id: OP, count: 5, seeds: [{ source_id: 'openalex:W2963403868' }] })?.scope, 'paper', 'scope defaults to a paper');
  const bad = [
    { operation_id: OP, count: 2, seeds: [{ source_id: '2401.00001' }] },
    { operation_id: 'nope', count: 3, seeds: [{ source_id: '2401.00001' }] },
    { operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001' }], prompt: 'x' },
    { operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001' }, { source_id: '2401.00002' }] },
    { operation_id: OP, count: 3, scope: 'catalog', seeds: Array.from({ length: 9 }, (_, i) => ({ source_id: `2401.0000${i}` })) },
    { operation_id: OP, count: 3, scope: 'catalog', seeds: [{ source_id: '2401.00001' }, { source_id: '2401.00001' }] },
    { operation_id: OP, count: 3, seeds: [{ source_id: 'https://arxiv.org/abs/2401.00001' }] },
    { operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001', keywords: ['x'] }] },
    { operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001', keywords: ['a'.repeat(61)] }] },
    { operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001', keywords: ['ok', 'two', 'three', 'four', 'five', 'six', 'seven'] }] },
    { operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001', keywords: ['title:"x" OR *'] }] },
    { operation_id: OP, count: 3, scope: 'shelf', seeds: [{ source_id: '2401.00001' }] },
    null, [], 'x',
  ];
  for (const body of bad) assert.equal(parseRecommendRequest(body), null, JSON.stringify(body));
});

test('search terms: the keywords the reader sees, never broad ones, then the title; a catalog uses shared keywords', () => {
  assert.equal(titlePhrase('Evolving Semantic Indexes for Generative Retrieval'), 'semantic indexes generative retrieval');
  assert.equal(titlePhrase('Attention Is All You Need'), null, 'too few distinctive words');
  assert.equal(titlePhrase('DPO: Direct Preference Optimization'), null, 'the main title alone is one word');
  const paper = parseRecommendRequest({ operation_id: OP, count: 3, seeds: [{ source_id: seed.source_id, keywords: ['LLMs', 'Generative retrieval', 'Document identifiers', 'Machine learning'] }] })!;
  const terms = searchTerms(paper, [seed]);
  assert.deepEqual(terms.datacite, ['Generative retrieval', 'Document identifiers', 'semantic indexes generative retrieval']);
  assert.deepEqual(terms.pool, ['Generative retrieval', 'Document identifiers', 'semantic indexes generative retrieval']);
  // No keywords from the device: the server's specific tags (broad areas left out).
  assert.deepEqual(searchTerms({ ...paper, seeds: [{ source_id: seed.source_id, keywords: [] }] }, [seed]).datacite, ['Semantic indexes', 'semantic indexes generative retrieval']);
  // Nothing distinctive at all: the main title as written.
  assert.deepEqual(searchTerms({ ...paper, seeds: [{ source_id: 'x', keywords: [] }] }, [{ ...seed, source_id: 'x', title: 'Attention Is All You Need', tags: [] }]).datacite,
    ['Attention Is All You Need']);
  const catalog = parseRecommendRequest({ operation_id: OP, count: 5, scope: 'catalog', seeds: [
    { source_id: '2401.00001', keywords: ['Generative retrieval', 'Dense retrieval'] },
    { source_id: '2401.00002', keywords: ['Dense retrieval'] },
    { source_id: '2401.00003', keywords: ['Reranking', 'Dense retrieval', 'Generative retrieval'] }] })!;
  const seeds = catalog.seeds.map(s => ({ ...seed, source_id: s.source_id }));
  assert.deepEqual(searchTerms(catalog, seeds).datacite, ['Dense retrieval', 'Generative retrieval', 'Reranking'], 'most shared first');
});

test('candidates: interleaved by rank, the reader\'s papers and repeats excluded, arXiv only, capped', () => {
  const a = [candidate(1), candidate(2), candidate(3)], b = [candidate(2), candidate(4), candidate(5, { source_id: 'openalex:W1' })], pool = [candidate(6), candidate(1)];
  assert.deepEqual(mergeCandidates([a, b, pool], new Set(['2410.00003'])).map(c => c.source_id),
    ['2410.00001', '2410.00002', '2410.00006', '2410.00004']);
  assert.equal(mergeCandidates([Array.from({ length: 60 }, (_, i) => candidate(i + 1))], new Set()).length, 40);
  assert.equal(mergeCandidates([Array.from({ length: 10 }, (_, i) => candidate(i + 1))], new Set(), 3).length, 3);
});

test('the prompt: Haiku, reasoning off, ids only from the candidates, bounded to the hold', () => {
  const request = parseRecommendRequest({ operation_id: OP, count: 3, seeds: [{ source_id: seed.source_id, keywords: ['Generative retrieval'] }] })!;
  const { params, candidates } = recommendParams(request, [seed], [candidate(1), candidate(2)], 15_000);
  assert.equal(params.model, RECOMMEND_MODEL); assert.equal(params.thinking?.type, 'disabled'); assert.equal(params.max_tokens, 700);
  assert.equal(candidates.length, 2);
  const schema = params.output_config?.format?.schema as any;
  assert.deepEqual(schema.properties.picks.items.properties.id.enum, ['c1', 'c2']);
  const user = params.messages[0].content as string;
  assert.match(user, /Title: Evolving Semantic Indexes/); assert.match(user, /\[c2\] Candidate paper 2 \(2026\) — E\. Five/);
  assert.match(user, /Keywords: Generative retrieval/);
  assert.match(String(params.system), /up to 3/); assert.match(String(params.system), /never instructions/);
  // Forty long candidates fit the $0.015 ceiling; a tiny ceiling keeps dropping them.
  const long = Array.from({ length: 40 }, (_, i) => candidate(i + 1, { abstract: 'word '.repeat(140), title: 'T'.repeat(300) }));
  const full = recommendParams(request, [seed], long, 15_000);
  assert.equal(full.candidates.length, 40); assert.ok(holdForParams(full.params).microusd <= 15_000, String(holdForParams(full.params).microusd));
  const small = recommendParams(request, [seed], long, 3_000);
  assert.ok(small.candidates.length < 40 && holdForParams(small.params).microusd <= 3_000);
  const catalog = recommendParams({ ...request, scope: 'catalog' }, [seed, { ...seed, title: 'Second paper' }], [candidate(1)], 15_000);
  assert.match(catalog.params.messages[0].content as string, /Papers in the reader's library:\n\(1\) Evolving.*\n\(2\) Second paper/);
});

test('picks are read as each one closes, across any chunking; reasons are one clean line', () => {
  const text = '{"picks":[{"id":"c3","reason":"Same task; learns \\"codes\\" {not} fixed"},{"id":"c1","reason":"Its base index"},{"id":"c9"';
  for (const size of [1, 3, 7, 1000]) {
    const scanner = new PickScanner(), seen: string[] = [];
    for (let i = 0; i < text.length; i += size) for (const pick of scanner.push(text.slice(i, i + size))) seen.push(`${pick.id}:${pick.reason}`);
    assert.deepEqual(seen, ['c3:Same task; learns "codes" {not} fixed', 'c1:Its base index'], `chunk ${size}`);
  }
  assert.deepEqual(new PickScanner().push('{"picks":[{"reason":"x","id":"c2"}]}'), [{ id: 'c2', reason: 'x' }], 'any key order');
  assert.deepEqual(new PickScanner().push('not json at all'), []);
  assert.equal(cleanReason('  "Same benchmark;\nlearns codes"  '), 'Same benchmark; learns codes');
  assert.ok(cleanReason('word '.repeat(80)).length <= 161);
  assert.equal(cleanReason(42), '');
});

test('import ids are derived from the request and the paper (retries never queue twice)', async () => {
  const a = await importIDFor(OP, '2410.00001', sha256Hex);
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(await importIDFor(OP, '2410.00001', sha256Hex), a);
  assert.notEqual(await importIDFor(OP, '2410.00002', sha256Hex), a);
});

/** A fake world: the database answers, DataCite and the pool answer, the model streams `answer` in pieces. */
function world(options: { begin?: unknown; beginError?: string; consumeError?: string; answer?: string; outcome?: Partial<ProviderOutcome>;
  pool?: unknown[]; searchFails?: boolean; add?: (id: string, src: string) => { status: 'added' | 'present' | 'failed'; id: string | null }; generate?: null } = {}) {
  const calls: { name: string; p: Record<string, any> }[] = [], adds: { id: string; src: string }[] = [], events: RecommendEvent[] = [], searches: string[] = [];
  const begin = options.begin ?? { replayed: false, state: 'running', requested: 3, seeds: [seed], hold_microusd: 15_000,
    exclude: ['2401.00001', '2410.00003'], credits: 1 };
  const deps: RecommendDeps = {
    accountID: ACCOUNT, sha256Hex, log: () => {},
    rpc: async (name, p) => {
      calls.push({ name, p });
      if (name === 'worker_consume_request' && options.consumeError) throw new RecommendRpcFailure(options.consumeError);
      if (name === 'worker_recommend_begin') { if (options.beginError) throw new RecommendRpcFailure(options.beginError); return begin; }
      if (name === 'worker_recommend_pool') return options.pool ?? [{ source_id: '2410.00007', revision: 1, title: 'Pool paper', authors: ['P'], year: 2026, abstract: 'Pool.', categories: ['cs.IR'] }];
      if (name === 'worker_recommend_finish') {
        const added = (p.p_picks as any[]).filter(x => x.status === 'added').length;
        return { state: added || !p.p_failure ? 'finished' : 'failed', added, credits: added ? 1 : 0, charged: added > 0 };
      }
      return null;
    },
    search: async term => { searches.push(term); if (options.searchFails) throw new Error('datacite down'); return [result(1), result(2), result(3), result(4)]; },
    addPaper: async (id, src) => { adds.push({ id, src }); return options.add ? options.add(id, src) : { status: 'added', id }; },
    generate: options.generate === null ? null : async (params, stream) => {
      const answer = options.answer ?? '{"picks":[{"id":"c1","reason":"Same task"},{"id":"c2","reason":"Its base"},{"id":"c3","reason":"An alternative"},{"id":"c4","reason":"Extra"}]}';
      for (let i = 0; i < answer.length; i += 9) stream.onText(answer.slice(i, i + 9));
      return { status: 'complete', failure: null, messageID: 'gen-1', model: params.model, stopReason: 'end_turn', refusalCategory: null,
        attempts: [{ model: params.model, estimated: false, billedMicrousd: 1650.2, usage: { input: 14000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 200 } }],
        exact: true, ...options.outcome } as ProviderOutcome;
    },
  };
  return { deps, calls, adds, events, searches, emit: (e: RecommendEvent) => events.push(e) };
}
const request = parseRecommendRequest({ operation_id: OP, count: 3, seeds: [{ source_id: '2401.00001', keywords: ['Generative retrieval'] }] })!;

test('a request: searching, choosing, each paper as it is added, done with 1 credit', async () => {
  const w = world();
  await runRecommend(w.deps, request, w.emit);
  assert.deepEqual(w.events.map(e => e.type === 'status' ? `status:${e.phase}` : e.type), ['status:searching', 'status:choosing', 'paper', 'paper', 'paper', 'done']);
  assert.deepEqual(w.calls.map(c => c.name), ['worker_consume_request', 'worker_recommend_begin', 'worker_recommend_pool', 'worker_recommend_finish']);
  const begin = w.calls[1].p;
  assert.equal(begin.p_scope, 'paper'); assert.deepEqual(begin.p_seeds, ['2401.00001']); assert.equal(begin.p_count, 3);
  assert.match(begin.p_request_sha256, /^\\x[0-9a-f]{64}$/);
  assert.equal(w.calls[0].p.p_route, 'recommend');
  assert.deepEqual(w.calls[2].p.p_terms, ['Generative retrieval', 'semantic indexes generative retrieval']);
  assert.deepEqual(w.calls[2].p.p_categories, ['cs.IR', 'cs.CL']);
  assert.deepEqual(w.searches, ['Generative retrieval', 'semantic indexes generative retrieval']);
  // At most the count asked for, never an excluded paper (2410.00003 was excluded, so c3 is the pool's or the next).
  assert.equal(w.adds.length, 3); assert.ok(!w.adds.some(a => a.src === '2410.00003' || a.src === '2401.00001'));
  for (const add of w.adds) assert.equal(add.id, await importIDFor(OP, add.src, sha256Hex));
  const papers = w.events.filter(e => e.type === 'paper') as Extract<RecommendEvent, { type: 'paper' }>[];
  assert.deepEqual(papers.map(p => p.ordinal), [1, 2, 3]);
  assert.equal(papers[0].paper.reason, 'Same task'); assert.equal(papers[0].paper.status, 'added');
  assert.equal(papers[0].paper.import_id, w.adds[0].id); assert.equal(papers[0].paper.authors.length, 3, 'authors bounded');
  const finish = w.calls[3].p;
  assert.equal(finish.p_failure, null); assert.equal(finish.p_actual_microusd, 1651); assert.equal(finish.p_picks.length, 3);
  assert.deepEqual(w.events.at(-1), { type: 'done', added: 3, requested: 3, credits: 1, charged: true });
  assert.match(recommendFrame(w.events.at(-1)!), /^data: \{"type":"done".*\}\n\n$/);
});

test('papers already there are reported, not charged; nothing related ends free', async () => {
  const present = world({ add: () => ({ status: 'present', id: null }), answer: '{"picks":[{"id":"c1","reason":"x"}]}' });
  await runRecommend(present.deps, request, present.emit);
  assert.deepEqual(present.events.at(-1), { type: 'done', added: 0, requested: 3, credits: 0, charged: false, reason: 'not_added' });
  const none = world({ answer: '{"picks":[]}' });
  await runRecommend(none.deps, request, none.emit);
  assert.deepEqual(none.events.at(-1), { type: 'done', added: 0, requested: 3, credits: 0, charged: false, reason: 'none_related' });
  assert.equal(none.adds.length, 0);
  // No candidates survive: no model call, free.
  let called = false;
  const empty = world({ pool: [], begin: { replayed: false, state: 'running', requested: 3, seeds: [seed], hold_microusd: 15_000, credits: 1,
    exclude: ['2410.00001', '2410.00002', '2410.00003', '2410.00004'] } });
  const generate = empty.deps.generate!;
  empty.deps.generate = async (p, o) => { called = true; return generate(p, o); };
  await runRecommend(empty.deps, request, empty.emit);
  assert.equal(called, false); assert.equal(empty.events.at(-1)?.type, 'done');
  assert.deepEqual(empty.calls.find(c => c.name === 'worker_recommend_finish')!.p.p_picks, []);
});

test('failures are uncharged and say why; the hold is always finished', async () => {
  const model = world({ outcome: { status: 'failed', failure: 'provider_rejected', attempts: [] }, answer: '' });
  await runRecommend(model.deps, request, model.emit);
  assert.deepEqual(model.events.at(-1), { type: 'error', code: 'model_unavailable', charged: false, retry_after: 10 });
  assert.equal(model.calls.find(c => c.name === 'worker_recommend_finish')!.p.p_failure, 'model_unavailable');
  const nokey = world({ generate: null });
  await runRecommend(nokey.deps, request, nokey.emit);
  assert.equal((nokey.events.at(-1) as any).code, 'model_unavailable');
  const search = world({ searchFails: true, pool: [] });
  search.deps.rpc = (orig => async (name: string, p: Record<string, unknown>) => {
    if (name === 'worker_recommend_pool') throw new Error('transport'); return orig(name, p);
  })(search.deps.rpc);
  await runRecommend(search.deps, request, search.emit);
  assert.equal((search.events.at(-1) as any).code, 'search_unavailable');
  assert.equal(search.calls.find(c => c.name === 'worker_recommend_finish')!.p.p_failure, 'search_unavailable');
  // A stream cut after two papers: they stay added and are charged; the run records the interruption.
  const cut = world({ answer: '{"picks":[{"id":"c1","reason":"a"},{"id":"c2","reason":"b"},{"id":"c', outcome: { status: 'failed', failure: 'provider_error' } });
  await runRecommend(cut.deps, request, cut.emit);
  assert.equal(cut.adds.length, 2); assert.equal(cut.calls.find(c => c.name === 'worker_recommend_finish')!.p.p_failure, 'interrupted');
  assert.equal((cut.events.at(-1) as any).charged, true);
});

test('refusals before the hold map to the reader\'s words; replays never call the model', async () => {
  for (const [reason, code] of [['recommend_daily_limit', 'daily_limit'], ['insufficient_credits', 'insufficient_credits'], ['testing_cap_reached', 'insufficient_credits'],
    ['recommend_seed_unavailable', 'seed_unavailable'], ['too_many_active_operations', 'rate_limited'], ['platform_budget_exhausted', 'platform_budget_exhausted'],
    ['recommend_unavailable', 'unavailable'], ['something_else', 'service_unavailable']] as const) {
    const w = world({ beginError: reason });
    await runRecommend(w.deps, request, w.emit);
    assert.equal(w.events.length, 1); assert.equal((w.events[0] as any).code, code, reason); assert.equal((w.events[0] as any).charged, false);
    assert.ok(!w.calls.some(c => c.name === 'worker_recommend_finish'));
  }
  const limited = world({ consumeError: 'request_rate_limit' });
  await runRecommend(limited.deps, request, limited.emit);
  assert.deepEqual(limited.events, [{ type: 'error', code: 'rate_limited', charged: false, retry_after: 60 }]);
  const picks = [{ source_id: '2410.00001', revision: 1, title: 'T', authors: [], year: 2026, reason: 'R', status: 'added', import_id: 'x' }];
  const finished = world({ begin: { replayed: true, state: 'finished', requested: 3, picks, added: 1, credits: 1 } });
  let called = false; finished.deps.generate = async () => { called = true; throw new Error('no'); };
  await runRecommend(finished.deps, request, finished.emit);
  assert.equal(called, false);
  assert.deepEqual(finished.events, [{ type: 'paper', ordinal: 1, paper: picks[0] }, { type: 'done', added: 1, requested: 3, credits: 1, charged: true }]);
  const running = world({ begin: { replayed: true, state: 'running', requested: 3 } });
  await runRecommend(running.deps, request, running.emit);
  assert.deepEqual(running.events, [{ type: 'error', code: 'in_progress', charged: false, retry_after: 5 }]);
  const failed = world({ begin: { replayed: true, state: 'failed', requested: 3, picks: [], added: 0, credits: 0, failure: 'model_unavailable' } });
  await runRecommend(failed.deps, request, failed.emit);
  assert.deepEqual(failed.events, [{ type: 'error', code: 'model_unavailable', charged: false }]);
});

test('through the real OpenRouter adapter: admitted as route chat, feature recommend, Haiku on Vertex, the account as user', async () => {
  const calls: { name: string; p: Record<string, any> }[] = [];
  let sent: any = null;
  const rpc = async (name: string, p: Record<string, any>) => {
    calls.push({ name, p });
    return name === 'worker_openrouter_admit' ? { granted: true, dispatched: true } : name === 'worker_openrouter_receipt' ? true : null;
  };
  const answer = '{"picks":[{"id":"c2","reason":"Learns the codes"}]}';
  const frames = [{ id: 'gen-rec', model: RECOMMEND_MODEL, provider: 'Google', choices: [{ delta: { content: answer.slice(0, 20) }, finish_reason: null }] },
    { id: 'gen-rec', model: RECOMMEND_MODEL, choices: [{ delta: { content: answer.slice(20) }, finish_reason: null }] },
    { id: 'gen-rec', model: RECOMMEND_MODEL, choices: [{ delta: {}, finish_reason: 'stop' }],
      usage: { prompt_tokens: 14000, completion_tokens: 40, prompt_tokens_details: { cached_tokens: 0 }, cost: 0.00156 } }];
  const fetcher = async (_url: unknown, init: RequestInit) => {
    sent = JSON.parse(String(init.body));
    const bytes = new TextEncoder().encode(frames.map(f => `data: ${JSON.stringify(f)}\n\n`).join('') + 'data: [DONE]\n\n');
    return new Response(new ReadableStream({ start(c) { for (let i = 0; i < bytes.length; i += 23) c.enqueue(bytes.slice(i, i + 23)); c.close(); } }),
      { headers: { 'x-generation-id': 'gen-rec' } });
  };
  const generate = admittedModelCalls({ accountID: ACCOUNT, operationID: OP, feature: 'recommend', rpc, sha256Hex },
    openRouterChat({ apiKey: 'fixture', fetch: fetcher as typeof fetch }));
  const w = world();
  w.deps.generate = generate;
  await runRecommend(w.deps, { ...request, count: 1 }, w.emit);
  const admit = calls.find(c => c.name === 'worker_openrouter_admit')!.p;
  assert.equal(admit.p_route, 'chat'); assert.equal(admit.p_model, RECOMMEND_MODEL); assert.equal(admit.p_account_id, ACCOUNT);
  assert.deepEqual(admit.p_metadata, { transport_model: RECOMMEND_MODEL, endpoint: 'google-vertex/us', feature: 'recommend', caller: 'chat' });
  assert.ok(admit.p_ceiling_microusd <= 15_000);
  assert.equal(sent.user, ACCOUNT); assert.equal(sent.session_id, OP); assert.equal(sent.trace.feature, 'recommend');
  assert.deepEqual(sent.provider.only, ['google-vertex/us']); assert.deepEqual(sent.reasoning, { enabled: false });
  assert.equal(sent.response_format.type, 'json_schema'); assert.ok(sent.response_format.json_schema.schema.properties.picks.items.properties.id.enum.includes('c2'));
  assert.equal(calls.find(c => c.name === 'worker_provider_attempt_finish')!.p.p_actual_microusd, 1560);
  assert.equal(w.adds.length, 1);
  assert.deepEqual(w.events.at(-1), { type: 'done', added: 1, requested: 1, credits: 1, charged: true });
});
