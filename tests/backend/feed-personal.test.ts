// Feed topics and popularity (migration 046; docs/architecture/PERSONALIZED_FEED.md, "Specific topics
// and popularity"): Hugging Face upvotes in the pool refresh, the reader's topic chips, topic serving,
// and the v2 ranking/response fields.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dailyPapersURL, HF_PAGE, HF_SPACING_MS, parseDailyPapers, runSignals, type SignalDeps, type Upvote } from '../../supabase/functions/_shared/feed-signals.ts';
import { runRefresh, type PoolFetch, type PoolSource, type RefreshClaim, type RefreshDeps } from '../../supabase/functions/_shared/feed-pool.ts';
import { displayTopics, feedTopics } from '../../supabase/functions/_shared/feed-topics.ts';
import { COMPOUND_TOPICS, compoundsParameter, interestTopics, isGenericTag, resolveTopic, specificity,
  type TopicStats } from '../../supabase/functions/_shared/feed-interests.ts';
import { FEED_RANKING_VERSION, poolResultV2, rankForYou, trend, withDetails,
  type CandidateSet, type FeedCandidate, type ProfilePaper } from '../../supabase/functions/_shared/feed-rank.ts';
import { TAG_VOCABULARY, vocabularyName } from '../../supabase/functions/_shared/tag-vocabulary.ts';

// ---- Hugging Face daily papers -----------------------------------------------------------------

const sample = new Uint8Array(readFileSync(new URL('../fixtures/huggingface/daily-papers-2026-10-07-sample.json', import.meta.url)));
const encode = (value: unknown) => new TextEncoder().encode(JSON.stringify(value));

test('daily papers: arXiv identifiers and whole upvote counts from the public list', () => {
  const parsed = parseDailyPapers(sample);
  assert.equal(parsed.entries, 4);
  assert.deepEqual(parsed.items[0], { source_id: '2610.08448', upvotes: 162 });
  assert.ok(parsed.items.every(item => /^\d{4}\.\d{4,5}$/.test(item.source_id) && Number.isInteger(item.upvotes)));
  const odd = parseDailyPapers(encode([
    { paper: { id: '2610.00001', upvotes: 3 } }, { paper: { id: '2610.00001', upvotes: 9 } },   // listed twice: the larger count
    { paper: { id: 'not-arxiv', upvotes: 5 } }, { paper: { id: '2610.00002', upvotes: 1.5 } }, { paper: { id: '2610.00003', upvotes: -1 } },
    { paper: { id: '2610.00004', upvotes: '7' } }, { paper: { id: '2610.00005' } }, null, { other: true },
    { paper: { id: '2610.00006v2', upvotes: 2 } }, { paper: { id: '2610.00007', upvotes: 2_000_000 } },
  ]));
  assert.deepEqual(odd.items, [{ source_id: '2610.00001', upvotes: 9 }]);
  assert.equal(odd.skipped, 9);
  assert.throws(() => parseDailyPapers(encode({ papers: [] })), /invalid_signals/);
  assert.throws(() => parseDailyPapers(new TextEncoder().encode('<html>')), /invalid_signals/);
  assert.throws(() => parseDailyPapers(encode(Array.from({ length: 201 }, () => ({})))), /invalid_signals/);
});

test('daily papers URL: one day, one of two pages', () => {
  assert.equal(dailyPapersURL('2026-10-07', 0), 'https://huggingface.co/api/daily_papers?date=2026-10-07&limit=100&p=0');
  assert.throws(() => dailyPapersURL('2026-13-45', 0));
  assert.throws(() => dailyPapersURL('2026-10-07&x=1', 0));
  assert.throws(() => dailyPapersURL('2026-10-07', 2));
});

function signalDeps(responses: Record<string, Response | Error>, plan: string[] | null = ['2026-10-08', '2026-10-07']) {
  const fetched: string[] = [], recorded: { day: string; status: string; items: Upvote[] }[] = [], slept: number[] = [];
  const deps: SignalDeps = {
    plan: async () => ({ source: 'huggingface', enabled: plan !== null, days: plan ?? [] }),
    record: async (_claim, day, status, items) => { recorded.push({ day, status, items }); return { matched: items.length }; },
    fetch: (async (url: string | URL | Request) => {
      fetched.push(String(url));
      const response = responses[String(url)] ?? new Response('[]', { status: 200 });
      if (response instanceof Error) throw response;
      return response;
    }) as typeof fetch,
    sleep: async ms => { slept.push(ms); },
  };
  return { deps, fetched, recorded, slept };
}
const page = (day: string, p: number) => dailyPapersURL(day, p);
const papers = (n: number, start = 0) => encode(Array.from({ length: n }, (_, i) => ({ paper: { id: `2610.${String(start + i).padStart(5, '0')}`, upvotes: i } })));

test('a popularity pass: planned days, a second apart, a full page reads the next, upvotes recorded', async () => {
  const { deps, fetched, recorded, slept } = signalDeps({
    [page('2026-10-08', 0)]: new Response(sample),
    [page('2026-10-07', 0)]: new Response(papers(HF_PAGE)),
    [page('2026-10-07', 1)]: new Response(papers(3, 500)),
  });
  const outcome = await runSignals(deps, 'claim');
  assert.deepEqual(fetched, [page('2026-10-08', 0), page('2026-10-07', 0), page('2026-10-07', 1)]);
  assert.deepEqual(slept, [HF_SPACING_MS, HF_SPACING_MS]);
  assert.deepEqual(recorded.map(r => [r.day, r.status, r.items.length]), [['2026-10-08', 'ok', 4], ['2026-10-07', 'ok', HF_PAGE + 3]]);
  assert.deepEqual(outcome, { status: 'ok', days: 2, requests: 3, matched: 4 + HF_PAGE + 3 });
});

test('throttled (429): the day is busy and the pass stops; failures are recorded and two stop it', async () => {
  const busy = signalDeps({ [page('2026-10-08', 0)]: new Response('slow down', { status: 429 }) });
  assert.equal((await runSignals(busy.deps, 'claim')).status, 'busy');
  assert.deepEqual(busy.fetched, [page('2026-10-08', 0)]);
  assert.deepEqual(busy.recorded, [{ day: '2026-10-08', status: 'busy', items: [] }]);

  const failing = signalDeps({ [page('2026-10-08', 0)]: new Response('', { status: 500 }), [page('2026-10-07', 0)]: new Error('network'),
    [page('2026-10-06', 0)]: new Response(sample) }, ['2026-10-08', '2026-10-07', '2026-10-06']);
  const outcome = await runSignals(failing.deps, 'claim');
  assert.equal(outcome.status, 'failed');
  assert.equal(outcome.code, 'source_failed');
  assert.deepEqual(failing.recorded.map(r => r.status), ['failed', 'failed']);
  assert.equal(failing.fetched.length, 2, 'the third day is left for a later refresh');

  const garbled = signalDeps({ [page('2026-10-08', 0)]: new Response('<html>'), [page('2026-10-07', 0)]: new Response(sample) });
  const mixed = await runSignals(garbled.deps, 'claim');
  assert.deepEqual(garbled.recorded.map(r => r.status), ['failed', 'ok']);
  assert.equal(mixed.status, 'failed');
  assert.equal(mixed.days, 1);
});

test('switched off, an unusable plan, or a failed record never throws', async () => {
  const off = signalDeps({}, null);
  assert.deepEqual(await runSignals(off.deps, 'claim'), { status: 'off', days: 0, requests: 0, matched: 0 });
  assert.equal(off.fetched.length, 0);
  const planless = signalDeps({});
  planless.deps.plan = async () => { throw new Error('feed_claim_lost'); };
  assert.equal((await runSignals(planless.deps, 'claim')).code, 'plan_failed');
  const strange = signalDeps({}, ['2026-10-08; drop', '2026-10-08']);
  await runSignals(strange.deps, 'claim');
  assert.deepEqual(strange.fetched, [page('2026-10-08', 0)]);
  const lost = signalDeps({ [page('2026-10-08', 0)]: new Response(sample) });
  lost.deps.record = async () => { throw new Error('feed_claim_lost'); };
  assert.equal((await runSignals(lost.deps, 'claim')).code, 'record_failed');
});

test('the pool refresh runs the popularity pass once, under its claim, before releasing it', async () => {
  const claim: RefreshClaim = { claim_id: 'c1', source: 'datacite-ml', kind: 'datacite', categories: ['cs.LG'], etag: null, last_modified: null, max_items: 3000 };
  const order: string[] = [];
  const deps: RefreshDeps = {
    fetch: (async () => { throw new Error('the source brings its own transport'); }) as unknown as typeof fetch,
    upsert: async () => ({ inserted: 0, updated: 0 }),
    finish: async (_claim, status) => { order.push(`finish:${status}`); return { pruned: 0, pool: 0 }; },
    sleep: async () => {}, today: () => '2026-10-08',
    signals: async id => { order.push(`signals:${id}`); return { status: 'ok', days: 1, requests: 1, matched: 3 }; },
  };
  const answer = (fetched: PoolFetch): PoolSource => async () => fetched;
  assert.equal((await runRefresh(deps, claim, answer({ status: 'not_modified' }))).status, 'not_modified');
  assert.deepEqual(order, ['signals:c1', 'finish:not_modified']);
  order.length = 0;
  deps.signals = async () => { order.push('signals'); throw new Error('boom'); };
  assert.equal((await runRefresh(deps, claim, answer({ status: 'busy' }))).status, 'busy');
  assert.deepEqual(order, ['signals', 'finish:busy'], 'a failing pass never blocks the release');
  order.length = 0;
  assert.equal((await runRefresh(deps, { ...claim, categories: ['bad category'] }, answer({ status: 'failed', code: 'invalid_categories' }))).code, 'invalid_categories');
  assert.deepEqual(order, ['finish:failed']);
});

// ---- Topics shown per paper --------------------------------------------------------------------

test('a paper\'s topics: specific first, broad category areas only when nothing else applies', () => {
  assert.deepEqual(displayTopics(['Large language models', 'Reasoning', 'Natural language processing', 'Machine learning', 'Reinforcement learning']),
    ['Large language models', 'Reasoning', 'Reinforcement learning']);
  assert.deepEqual(displayTopics(['Natural language processing', 'Machine learning']), ['Natural language processing', 'Machine learning']);
  assert.deepEqual(displayTopics(['Tokenization', 'Tokenization', 'Efficient inference', 'Quantization', 'Pre-training', 'Scaling laws']).length, 4);
  const mamba = displayTopics(feedTopics('Mamba-3: State Space Models with Tokenizer-Free Inputs',
    'We train selective state space models (SSMs) directly on bytes, removing the tokenizer.', ['cs.LG', 'cs.CL']));
  assert.ok(mamba.includes('State space models') && mamba.includes('Tokenization'), String(mamba));
  assert.ok(!mamba.includes('Machine learning'));
});

// ---- Topic chips -------------------------------------------------------------------------------

const NOW = '2026-10-08T12:00:00Z';
const paper = (title: string, tags: string[], options: Partial<ProfilePaper> = {}): ProfilePaper => ({
  source_id: options.source_id ?? null, title, added_at: options.added_at ?? '2026-10-01T00:00:00Z', archived: options.archived ?? false,
  pending: options.pending ?? false, categories: options.categories ?? ['cs.LG'], tags, own_tags: options.own_tags ?? [], author_keys: [] });
function candidateSet(profile: ProfilePaper[], extra: Partial<CandidateSet> = {}): CandidateSet {
  return { now: NOW, today: '2026-10-08', seed: 'r:2026-10-08', window_days: 14, pool: 8000, refreshed_at: NOW,
    categories: ['cs.LG', 'cs.CL'], profile, feedback: [], candidates: [], ...extra };
}
// A researcher of RL for reasoning, interpretability and tokenizers, in a pool of 8,000 papers.
const researcher = [
  paper('GRPO for math', ['Large language models', 'Reasoning', 'Policy optimization', 'Reinforcement learning', 'Natural language processing']),
  paper('RL scaling for reasoning', ['Large language models', 'Mathematical reasoning', 'Reinforcement learning']),
  paper('Process rewards', ['Reasoning', 'Reward modeling', 'Large language models']),
  paper('Verifier RL', ['Reasoning', 'Policy optimization', 'Large language models']),
  paper('Sparse autoencoders at scale', ['Mechanistic interpretability', 'Large language models']),
  paper('Circuit tracing', ['Mechanistic interpretability', 'Interpretability']),
  paper('Byte latent transformer', ['Tokenization', 'Transformers', 'byte-level LMs'], { own_tags: ['byte-level LMs'] }),
  paper('Tokenizer transfer', ['Tokenization', 'Large language models', 'to read'], { own_tags: ['to read'] }),
  paper('Old vision paper', ['Computer vision', 'Object detection'], { added_at: '2025-01-01T00:00:00Z', archived: true }),
];
const stats: TopicStats = {
  tags: { 'Large language models': 2600, Reasoning: 900, 'Policy optimization': 160, 'Reinforcement learning': 400, 'Mechanistic interpretability': 45,
    Interpretability: 120, Tokenization: 30, Transformers: 700, 'Natural language processing': 3000, 'Reward modeling': 60, 'Mathematical reasoning': 150,
    'Computer vision': 2500, 'Object detection': 90 },
  own: { 'byte-level LMs': 4, 'to read': 3000 },
  compounds: { 'RL for reasoning': 120, 'Multimodal reasoning': 80 },
};

test('chips: the reader\'s specific interests, most weighted first, never broad areas or generic tags', () => {
  const chips = interestTopics(candidateSet(researcher), stats);
  const names = chips.map(chip => chip.name);
  assert.equal(names[0], 'RL for reasoning', String(names));
  assert.deepEqual(chips[0], { name: 'RL for reasoning', kind: 'combined', papers: 120 });
  for (const expected of ['Mechanistic interpretability', 'Tokenization']) assert.ok(names.includes(expected), `${expected}: ${names}`);
  for (const broad of ['Machine learning', 'Natural language processing', 'Computer vision']) assert.ok(!names.includes(broad), String(names));
  assert.ok(!names.includes('Large language models'), 'on a third of the pool: too general');
  assert.ok(!names.includes('to read'), 'organizational tags are not topics');
  assert.ok(!names.includes('Object detection'), 'one old archived paper is not an interest');
  assert.ok(!names.includes('Reasoning') && !names.includes('Policy optimization'), 'parts the combination explains are not repeated');
  assert.ok(names.includes('byte-level LMs'), 'a tag the reader gave counts from one paper');
  assert.equal(chips.find(chip => chip.name === 'byte-level LMs')!.kind, 'own');
  assert.ok(chips.length <= 8);
  // Each chip has papers to show and is a small share of the pool.
  assert.ok(chips.every(chip => chip.papers >= 2 && chip.papers / 8000 <= 0.2));
});

test('chips: no stats or an empty library give none; More like this is evidence on its own', () => {
  assert.deepEqual(interestTopics(candidateSet(researcher), null), []);
  assert.deepEqual(interestTopics(candidateSet([]), stats), []);
  const liked = interestTopics(candidateSet([], { feedback: [{ source_id: '2610.00001', kind: 'more_like_this', title: 'Interp',
    categories: ['cs.LG'], topics: ['Mechanistic interpretability'], author_keys: [], created_at: NOW }] }), stats);
  assert.deepEqual(liked.map(chip => chip.name), ['Mechanistic interpretability']);
  const dismissedOnly = interestTopics(candidateSet([], { feedback: [{ source_id: '2610.00001', kind: 'not_interested', title: 'Interp',
    categories: ['cs.LG'], topics: ['Mechanistic interpretability'], author_keys: [], created_at: NOW }] }), stats);
  assert.deepEqual(dismissedOnly, []);
  // A topic with fewer than two papers in the pool has nothing to show.
  assert.ok(!interestTopics(candidateSet(researcher), { ...stats, tags: { ...stats.tags, Tokenization: 1 } }).some(chip => chip.name === 'Tokenization'));
});

test('specificity: 1 for a niche topic, 0.35 at a fifth of the pool', () => {
  assert.equal(specificity(0.005), 1);
  assert.equal(specificity(0.01), 1);
  assert.ok(Math.abs(specificity(0.1) - 0.5) < 1e-9);
  assert.equal(specificity(0.2), 0.35);
  assert.equal(specificity(0), 1);
});

test('combinations are well formed for the database and never repeat a vocabulary name', () => {
  const names = new Set<string>();
  for (const compound of COMPOUND_TOPICS) {
    assert.ok(!vocabularyName(compound.name), compound.name);
    assert.ok(!names.has(compound.name.toLowerCase()), compound.name);
    names.add(compound.name.toLowerCase());
    assert.ok(compound.name.length <= 40 && compound.name === compound.name.trim());
    assert.ok(compound.all.length >= 1 && compound.all.length <= 4 && compound.any.length <= 6, compound.name);
    for (const tag of [...compound.all, ...compound.any]) assert.equal(vocabularyName(tag), tag, `${compound.name}: ${tag}`);
  }
  assert.ok(COMPOUND_TOPICS.length <= 32);
  assert.deepEqual(compoundsParameter()[0], { name: 'RL for reasoning', all: ['Reasoning'], any: ['Reinforcement learning', 'Policy optimization', 'Reward modeling'] });
});

test('a topic chip resolves to a combination, a vocabulary tag, or the reader\'s own tag', () => {
  assert.deepEqual(resolveTopic('rl FOR reasoning'), { kind: 'combined', name: 'RL for reasoning', all: ['Reasoning'],
    any: ['Reinforcement learning', 'Policy optimization', 'Reward modeling'] });
  assert.deepEqual(resolveTopic(' tokenization '), { kind: 'topic', name: 'Tokenization', all: ['Tokenization'], any: [] });
  assert.deepEqual(resolveTopic('byte-level   LMs'), { kind: 'own', name: 'byte-level LMs', phrase: 'byte-level LMs' });
  assert.equal(resolveTopic('to read'), null);
  assert.equal(resolveTopic('   '), null);
  assert.equal(resolveTopic('x'.repeat(41)), null);
  assert.equal(resolveTopic('tab\u0007bell'), null);
  assert.equal(resolveTopic('1234'), null);
  assert.ok(isGenericTag('Favorites') && !isGenericTag('RLHF'));
});

// ---- Ranking v2 --------------------------------------------------------------------------------

function candidate(id: string, options: Partial<FeedCandidate> = {}): FeedCandidate {
  return { source_id: id, revision: 1, title: options.title ?? `Paper ${id}`, authors: options.authors ?? ['Pat Example'],
    author_keys: (options.authors ?? ['Pat Example']).map(a => a.toLowerCase()), categories: options.categories ?? ['cs.CL'],
    topics: options.topics ?? [], announced_on: options.announced_on ?? '2026-10-08', first_seen_at: '2026-10-08T05:00:00Z',
    matched_tags: options.matched_tags ?? [], readers: options.readers ?? null, upvotes: options.upvotes ?? null };
}
const rankingSet = (candidates: FeedCandidate[], profile: ProfilePaper[] = [paper('Tokenizer transfer', ['Tokenization'],
  { own_tags: ['Tokenization'] })]) => candidateSet(profile, { candidates, pool: candidates.length });

test('v2: upvotes lift a paper a little and explain it when nothing personal does', () => {
  assert.equal(FEED_RANKING_VERSION, 'feed-heuristic-v2');
  assert.equal(trend(null), 0);
  assert.ok(trend(10) > 0 && trend(10) < trend(100));
  assert.equal(trend(5000), 1);
  const { results } = rankForYou(rankingSet([candidate('2610.00001', { upvotes: null }), candidate('2610.00002', { upvotes: 162 })]));
  assert.equal(results[0].source_id, '2610.00002');
  assert.deepEqual(results[0].reason, { kind: 'trending', label: '162', text: 'Popular on Hugging Face Papers' });
  assert.equal(results[0].upvotes, 162);
  assert.equal(results[1].upvotes, null, 'unknown stays unknown');
  assert.equal(results[1].reason.kind, 'category');
  const personal = rankForYou(rankingSet([candidate('2610.00003', { topics: ['Tokenization'], upvotes: 500 })])).results[0];
  assert.equal(personal.reason.kind, 'tag', 'a personal reason comes first');
});

test('v2: a topic chip ranks without exploring and never names the topic itself as the reason', () => {
  const profile = [paper('Tokenizer transfer', ['Tokenization', 'Large language models'], { own_tags: ['Tokenization'], categories: ['cs.CL'] })];
  const candidates = Array.from({ length: 12 }, (_, i) => candidate(`2610.${String(100 + i).padStart(5, '0')}`,
    { topics: ['Tokenization', i % 2 ? 'Large language models' : 'Machine learning'], categories: i < 6 ? ['cs.CL'] : ['cs.RO'], authors: [`A ${i}`] }));
  const { results } = rankForYou(rankingSet(candidates, profile), { topic: 'Tokenization', limit: 10 });
  assert.equal(results.length, 10);
  assert.ok(results.every(result => result.reason.kind !== 'explore'), 'no exploration slots');
  assert.ok(results.every(result => !(result.reason.kind === 'tag' && result.reason.label === 'Tokenization')));
  assert.ok(results.every(result => result.topics[0] === 'Tokenization'));
  assert.ok(results.every(result => !result.topics.includes('Machine learning')), 'broad areas left out when specific topics exist');
});

test('v2: details fill complete abstracts and current upvotes; pool chips carry topics', () => {
  const ranked = rankForYou(rankingSet([candidate('2610.00001'), candidate('2610.00002'), candidate('2610.00003')])).results;
  const filled = withDetails(ranked, [
    { source_id: '2610.00001', abstract: 'Short and complete.', abstract_complete: true, upvotes: 12 },
    { source_id: '2610.00002', abstract: 'y'.repeat(2000), abstract_complete: false, upvotes: null },
  ]);
  const byID = Object.fromEntries(filled.map(result => [result.source_id, result]));
  assert.deepEqual([byID['2610.00001'].abstract, byID['2610.00001'].full_abstract, byID['2610.00001'].abstract_truncated, byID['2610.00001'].upvotes],
    ['Short and complete.', 'Short and complete.', false, 12]);
  assert.equal(byID['2610.00002'].abstract!.length, 700);
  assert.equal(byID['2610.00002'].full_abstract!.length, 2000);
  assert.equal(byID['2610.00002'].abstract_truncated, true, 'a bounded abstract links to arXiv for the rest');
  assert.equal(byID['2610.00003'].abstract, null, 'no details: nothing invented');
  assert.deepEqual(withDetails(ranked, null), ranked);
  const row = { source_id: '2610.00009', revision: 1, title: 'T', authors: ['A'], abstract: 'An abstract.', abstract_complete: true,
    categories: ['cs.CL'], topics: ['Natural language processing', 'Tokenization'], upvotes: 4, announced_on: '2026-10-08', first_seen_at: NOW };
  assert.deepEqual(poolResultV2(row, true), { source_id: '2610.00009', revision: 1, title: 'T', authors: ['A'], year: 2026,
    abstract: 'An abstract.', categories: ['cs.CL'], first_seen: NOW, announced: '2026-10-08', full_abstract: 'An abstract.', abstract_truncated: false,
    topics: ['Tokenization'], upvotes: 4 });
  assert.deepEqual(Object.keys(poolResultV2({ ...row, upvotes: null }, false)).sort(),
    ['abstract', 'announced', 'authors', 'categories', 'first_seen', 'revision', 'source_id', 'title', 'topics', 'upvotes', 'year']);
  assert.equal(poolResultV2({ ...row, upvotes: -3 }, false).upvotes, null);
});

test('the vocabulary still has the broad areas the chips leave out', () => {
  // Guards the list "More topics" depends on: if an area loses its category, it may become a chip.
  const broad = TAG_VOCABULARY.filter(tag => tag.kind === 'area' && tag.categories?.length).map(tag => tag.name);
  for (const name of ['Machine learning', 'Natural language processing', 'Computer vision', 'Artificial intelligence']) assert.ok(broad.includes(name), name);
});
