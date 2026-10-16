import test from 'node:test';
import assert from 'node:assert/strict';
import { FEED_TOPIC_TAGS, FEED_TOPICS_VERSION, feedTopics } from '../../supabase/functions/_shared/feed-topics.ts';
import { TAG_NAMES } from '../../supabase/functions/_shared/tag-vocabulary.ts';
import { poolAuthors, POOL_BATCH, runRefresh, sameSecret, withTopics,
  type PoolFetch, type PoolItem, type PoolSource, type RefreshClaim, type RefreshDeps, type RefreshStatus } from '../../supabase/functions/_shared/feed-pool.ts';
import { categoryName, FEED_RANKING_VERSION, poolResult, rankForYou, seeded,
  type CandidateSet, type FeedCandidate, type ProfilePaper } from '../../supabase/functions/_shared/feed-rank.ts';

// ---- Topic rules -------------------------------------------------------------------------------

test('every topic rule names a vocabulary tag, once', () => {
  for (const tag of FEED_TOPIC_TAGS) assert.ok(TAG_NAMES.includes(tag), tag);
  assert.equal(new Set(FEED_TOPIC_TAGS).size, FEED_TOPIC_TAGS.length);
  assert.ok(FEED_TOPIC_TAGS.length >= 100, `${FEED_TOPIC_TAGS.length} rules`);
  assert.match(FEED_TOPICS_VERSION, /^[a-z0-9-]{1,64}$/);
});

test('keyword topics for well-known abstracts', () => {
  const dpo = feedTopics('Direct Preference Optimization: Your Language Model is Secretly a Reward Model',
    'While large-scale unsupervised language models learn broad world knowledge, achieving precise control is difficult. Existing methods ' +
    'collect human labels and fine-tune with reinforcement learning from human feedback (RLHF). We introduce DPO, which solves the standard ' +
    'RLHF problem with only a simple classification loss on preference pairs.', ['cs.LG', 'cs.AI', 'cs.CL']);
  for (const tag of ['Preference optimization', 'Learning from human feedback', 'Large language models', 'Reward modeling']) assert.ok(dpo.includes(tag), `${tag}: ${dpo}`);
  assert.ok(dpo.includes('Machine learning'), 'category tags are added after the rule matches');
  const mamba = feedTopics('Mamba: Linear-Time Sequence Modeling with Selective State Spaces',
    'Foundation models are almost universally based on the Transformer architecture. We integrate selective state space models (SSMs) into ' +
    'a simplified architecture without attention.', ['cs.LG']);
  assert.ok(mamba.includes('State space models') && mamba.includes('Transformers'), String(mamba));
  const moe = feedTopics('Sparse Mixture-of-Experts at Scale', 'We route tokens to experts with a learned router; our MoE model matches dense quality.', ['cs.CL']);
  assert.ok(moe.includes('Mixture of experts') && moe.includes('Natural language processing'), String(moe));
  const nerf = feedTopics('Instant Gaussian Splatting for Novel View Synthesis', 'We render scenes from 3DGS in real time.', ['cs.CV']);
  assert.ok(nerf.includes('Neural rendering') && nerf.includes('Computer vision'), String(nerf));
});

test('acronyms are case-sensitive and broad tags need the title or two mentions', () => {
  assert.ok(!feedTopics('A storage paper', 'We use ram and a rag to clean the moe.', []).some(t => ['Retrieval-augmented generation', 'Mixture of experts'].includes(t)));
  assert.ok(feedTopics('Scaling RAG systems', 'Retrieval.', []).includes('Retrieval-augmented generation'));
  // "Evaluation" (min 2): one passing mention is not enough; the title is.
  assert.ok(!feedTopics('Graph coloring', 'We report results on a benchmark.', []).includes('Evaluation'));
  assert.ok(feedTopics('A benchmark for graph coloring', 'Results.', []).includes('Evaluation'));
  assert.ok(feedTopics('Graph coloring', 'Our benchmark is new. The benchmark has 3 parts.', []).includes('Evaluation'));
  // Diffusion as physics is not a diffusion model.
  assert.ok(!feedTopics('Heat diffusion in metals', 'We measure diffusion coefficients.', []).includes('Diffusion models'));
  assert.ok(feedTopics('Fast sampling for diffusion models', 'We distill.', []).includes('Diffusion models'));
});

test('at most eight rule tags plus two category tags, strongest first', () => {
  const busy = feedTopics('Transformers, LLMs, RAG, MoE, LoRA, DPO, RLHF, CoT, KV cache, quantization and tokenizers',
    'Transformers LLMs RAG MoE LoRA DPO RLHF CoT KV cache quantization tokenizer.', ['cs.CL', 'cs.LG', 'cs.CV']);
  assert.ok(busy.length <= 10, String(busy));
  assert.deepEqual(busy.slice(-2), ['Natural language processing', 'Machine learning']);
});

// ---- Pool items and the refresh loop (the source is DataCite: feed-datacite.test.ts; arXiv's RSS is retired) -------------

const poolItem = (i: number, title = `Diffusion models ${i}`): PoolItem => ({ source_id: `2610.${String(10000 + i)}`, revision: 1, title,
  authors: ['Ada Lovelace'], abstract: 'We study things & stuff.', categories: ['cs.LG'], topics: [], announced_on: '2026-10-08', announce_type: 'new' });

test('pool authors and topics match the database rules (migration 043 feed_valid_item)', () => {
  assert.deepEqual(poolAuthors(['  Ada   Lovelace ', '', 'x'.repeat(300)]), ['Ada Lovelace']);
  const long = Array.from({ length: 30 }, (_, i) => `Author ${i + 1}`);
  assert.deepEqual([poolAuthors(long).length, poolAuthors(long)[11]], [12, 'Author 30'], 'the last author is kept');
  const tagged = withTopics([poolItem(4, 'Mixture of experts for RAG')]);
  assert.deepEqual(Object.keys(tagged[0]).sort(), ['abstract', 'announce_type', 'announced_on', 'authors', 'categories', 'revision', 'source_id', 'title', 'topics']);
  for (const topic of tagged[0].topics) assert.ok(topic.length <= 40 && topic === topic.trim(), topic);
  assert.equal(new Set(tagged[0].topics.map(t => t.toLowerCase())).size, tagged[0].topics.length);
});

const claim: RefreshClaim = { claim_id: '0a2b5c7e-0000-4000-8000-000000000001', source: 'datacite-ml', kind: 'datacite', categories: ['cs.LG', 'cs.CL'],
  etag: null, last_modified: '2026-10-07T04:31:42Z', max_items: 3000 };
const source = (fetched: PoolFetch | (() => never)): PoolSource => async () => typeof fetched === 'function' ? fetched() : fetched;

function refreshDeps(options: { failFinish?: boolean } = {}) {
  const calls = { upserts: [] as PoolItem[][], finishes: [] as { status: RefreshStatus; etag: string | null; lastModified: string | null; items: number | null }[] };
  const deps: RefreshDeps = {
    fetch: (async () => { throw new Error('the source brings its own transport'); }) as typeof fetch,
    upsert: async (claimID, items, version) => {
      assert.equal(claimID, claim.claim_id); assert.equal(version, FEED_TOPICS_VERSION); calls.upserts.push(items);
      return { inserted: items.length, updated: 0 };
    },
    finish: async (claimID, status, etag, lastModified, items) => {
      assert.equal(claimID, claim.claim_id); calls.finishes.push({ status, etag, lastModified, items });
      if (options.failFinish) throw new Error('database_unavailable');
      return { pruned: 0, pool: 42 };
    },
    sleep: async () => {},
    today: () => '2026-10-08',
  };
  return { deps, calls };
}

test('nothing new is recorded as success without writing', async () => {
  const { deps, calls } = refreshDeps();
  assert.equal((await runRefresh(deps, claim, source({ status: 'not_modified' }))).status, 'not_modified');
  assert.equal(calls.upserts.length, 0);
  assert.deepEqual(calls.finishes, [{ status: 'not_modified', etag: null, lastModified: null, items: null }]);
});

test('new items are tagged, written in batches and recorded with the source\'s mark', async () => {
  const many = Array.from({ length: POOL_BATCH + 25 }, (_, i) => poolItem(i));
  const { deps, calls } = refreshDeps();
  const outcome = await runRefresh(deps, claim, source({ status: 'updated', items: many, lastModified: '2026-10-08T04:31:42Z' }));
  assert.deepEqual({ status: outcome.status, items: outcome.items, inserted: outcome.inserted, pool: outcome.pool },
    { status: 'updated', items: POOL_BATCH + 25, inserted: POOL_BATCH + 25, pool: 42 });
  assert.deepEqual(calls.upserts.map(batch => batch.length), [POOL_BATCH, 25]);
  assert.ok(calls.upserts[0][0].topics.includes('Diffusion models'));
  assert.deepEqual(calls.finishes, [{ status: 'updated', etag: null, lastModified: '2026-10-08T04:31:42Z', items: POOL_BATCH + 25 }]);
});

test('a busy or failing source, a thrown error and a lost database are recorded, never thrown', async () => {
  let run = refreshDeps();
  assert.equal((await runRefresh(run.deps, claim, source({ status: 'busy' }))).status, 'busy');
  run = refreshDeps();
  assert.deepEqual([(await runRefresh(run.deps, claim, source({ status: 'failed', code: 'datacite_unavailable' }))).code, run.calls.finishes[0].status],
    ['datacite_unavailable', 'failed']);
  run = refreshDeps();
  assert.equal((await runRefresh(run.deps, claim, source(() => { throw new Error('invalid_feed'); }))).code, 'invalid_feed');
  run = refreshDeps({ failFinish: true });
  assert.equal((await runRefresh(run.deps, claim, source({ status: 'not_modified' }))).code, 'finish_failed', 'the lease expires and the next kick retries');
});

test('the cron secret comparison', () => {
  const secret = 'x'.repeat(48);
  assert.ok(sameSecret(secret, secret));
  assert.ok(!sameSecret('', secret));
  assert.ok(!sameSecret(secret.slice(1) + 'y', secret));
});

// ---- Ranking -----------------------------------------------------------------------------------

const NOW = '2026-10-08T12:00:00Z';
function candidate(id: string, options: Partial<FeedCandidate> & { days?: number } = {}): FeedCandidate {
  const authors = options.authors ?? ['Pat Example'];
  return { source_id: id, revision: 1, title: options.title ?? `Paper ${id}`, authors,
    author_keys: options.author_keys ?? authors.map(a => a.toLowerCase()), abstract: options.abstract ?? 'An abstract.',
    categories: options.categories ?? ['cs.LG'], topics: options.topics ?? [], announced_on: `2026-10-${String(8 - (options.days ?? 0)).padStart(2, '0')}`,
    first_seen_at: '2026-10-08T05:00:00Z', matched_tags: options.matched_tags ?? [], readers: options.readers ?? null };
}
const library: ProfilePaper = { source_id: '2401.00001', title: 'Our own paper about denoising', added_at: '2026-10-01T00:00:00Z', archived: false,
  pending: false, categories: ['cs.LG', 'cs.CL'], tags: ['Diffusion models', 'RLHF', 'Machine learning'], own_tags: ['RLHF'],
  author_keys: ['ada lovelace', 'alan turing'] };
function set(candidates: FeedCandidate[], extra: Partial<CandidateSet> = {}): CandidateSet {
  return { now: NOW, today: '2026-10-08', seed: 'reader-a:2026-10-08', window_days: 14, pool: candidates.length, refreshed_at: NOW,
    categories: ['cs.LG', 'cs.CL', 'cs.CV', 'cs.AI', 'stat.ML', 'cs.RO'],
    profile: [library], feedback: [], candidates, ...extra };
}

test('relevance orders the feed and every paper says why', () => {
  const { results, cold_start } = rankForYou(set([
    candidate('2610.00005', { categories: ['cs.CL'] }),
    candidate('2610.00002', { authors: ['Bea Kim', 'Alan Turing'], categories: ['cs.AI'] }),
    candidate('2610.00003', { matched_tags: ['RLHF'], categories: ['cs.CL'] }),
    candidate('2610.00001', { topics: ['Diffusion models', 'Computer vision'], categories: ['cs.CV'] }),
    candidate('2610.00009', { categories: ['cs.SE'] }),
  ]));
  assert.equal(cold_start, false);
  const reasons = Object.fromEntries(results.map(r => [r.source_id, r.reason]));
  assert.deepEqual(reasons['2610.00002'], { kind: 'author', label: 'Alan Turing', text: 'By Alan Turing, an author in your library' });
  assert.deepEqual(reasons['2610.00003'], { kind: 'tag', label: 'RLHF', text: 'In your tag: RLHF' });
  assert.deepEqual(reasons['2610.00001'], { kind: 'added', label: 'Our own paper about denoising', text: 'Because you added “Our own paper about denoising”' });
  assert.equal(reasons['2610.00005'].kind, 'category');
  assert.equal(reasons['2610.00005'].text, 'New in Natural language processing');
  const order = results.map(r => r.source_id);
  assert.ok(order.indexOf('2610.00001') < order.indexOf('2610.00005') && order.indexOf('2610.00002') < order.indexOf('2610.00005'), String(order));
  assert.equal(order.at(-1), '2610.00009', 'no shared feature: last');
});

test('fresher papers rank higher at equal relevance; Not interested pushes similar papers down', () => {
  const fresh = rankForYou(set([candidate('2610.00011', { topics: ['Diffusion models'], days: 6 }), candidate('2610.00012', { topics: ['Diffusion models'] })]));
  assert.equal(fresh.results[0].source_id, '2610.00012');
  const dismissed = rankForYou(set([
    candidate('2610.00021', { topics: ['Diffusion models'], authors: ['Zed Spam'] }),
    candidate('2610.00022', { topics: ['Diffusion models'], authors: ['Quiet Person'] }),
  ], { feedback: [{ source_id: '2610.00020', kind: 'not_interested', title: 'Spam', categories: ['cs.LG'], topics: ['Diffusion models'],
    author_keys: ['zed spam'], created_at: NOW }] }));
  assert.equal(dismissed.results[0].source_id, '2610.00022');
});

test('More like this adds weight and its own reason', () => {
  const { results } = rankForYou(set([
    candidate('2610.00031', { topics: ['Mixture of experts'], categories: ['cs.DC'] }),
    candidate('2610.00032', { categories: ['cs.DC'] }),
  ], { feedback: [{ source_id: '2610.00030', kind: 'more_like_this', title: 'Routing experts without load balancing', categories: ['cs.LG'],
    topics: ['Mixture of experts'], author_keys: ['grace hopper'], created_at: NOW }] }));
  assert.equal(results[0].source_id, '2610.00031');
  assert.deepEqual(results[0].reason, { kind: 'more_like', label: 'Routing experts without load balancing', text: 'More like “Routing experts without load balancing”' });
});

test('popular papers say so only from the aggregate', () => {
  const { results } = rankForYou(set([candidate('2610.00041', { readers: 3, categories: ['cs.CL'] }), candidate('2610.00042', { readers: null, categories: ['cs.CL'] })]));
  assert.equal(results[0].source_id, '2610.00041');
  assert.equal(results[0].reason.kind, 'popular');
  assert.equal(results[1].reason.kind, 'category');
});

test('diversity spreads authors and topics; every fifth slot explores', () => {
  const crowd = Array.from({ length: 8 }, (_, i) => candidate(`2610.${String(100 + i).padStart(5, '0')}`,
    { topics: ['Diffusion models'], authors: ['Mei Lin'], days: 0 }));
  const others = Array.from({ length: 6 }, (_, i) => candidate(`2610.${String(200 + i).padStart(5, '0')}`,
    { matched_tags: ['RLHF'], authors: [`Author ${i}`], days: 1 }));
  const explore = Array.from({ length: 3 }, (_, i) => candidate(`2610.${String(300 + i).padStart(5, '0')}`, { categories: ['cs.RO'], authors: [`Other ${i}`] }));
  const { results } = rankForYou(set([...crowd, ...others, ...explore]), 10);
  assert.equal(results.length, 10);
  const top5 = results.slice(0, 5).map(r => r.authors[0]);
  assert.ok(top5.filter(a => a === 'Mei Lin').length <= 3, String(top5));
  assert.equal(results[4].reason.kind, 'explore');
  assert.equal(results[4].reason.text, 'Something different: Robotics');
  assert.equal(results[9].reason.kind, 'explore');
  assert.ok(results.slice(0, 4).every(r => r.reason.kind !== 'explore'));
});

test('a category already in the library is not misleadingly called something different', () => {
  const candidates = Array.from({ length: 12 }, (_, i) => candidate(`2610.${String(700 + i).padStart(5, '0')}`,
    { categories: ['cs.CL'], authors: [`Unfamiliar author ${i}`] }));
  const { results } = rankForYou(set(candidates), 10);
  assert.equal(results.length, 10);
  assert.ok(results.every(r => r.reason.kind === 'category' && r.reason.text === 'New in Natural language processing'));
});

test('a cross-list reason names the relevant ML category instead of an unrelated primary category', () => {
  const candidates = [candidate('2610.00720', { categories: ['math.PR', 'cs.LG'] })];
  const cold = rankForYou(set(candidates, { profile: [] })).results[0];
  const familiar = rankForYou(set(candidates)).results[0];
  assert.equal(cold.reason.label, 'cs.LG');
  assert.equal(familiar.reason.label, 'cs.LG');
});

test('stable within a day for a reader, different across readers or days', () => {
  const many = Array.from({ length: 30 }, (_, i) => candidate(`2610.${String(400 + i).padStart(5, '0')}`, { categories: ['cs.CL'], authors: [`A ${i}`] }));
  const first = rankForYou(set(many)).results.map(r => r.source_id);
  assert.deepEqual(rankForYou(set(many)).results.map(r => r.source_id), first);
  assert.notDeepEqual(rankForYou(set(many, { seed: 'reader-b:2026-10-08' })).results.map(r => r.source_id), first);
  assert.notDeepEqual(rankForYou(set(many, { seed: 'reader-a:2026-10-09' })).results.map(r => r.source_id), first);
  assert.ok(seeded('a', 'b') >= 0 && seeded('a', 'b') < 1 && seeded('a', 'b') === seeded('a', 'b'));
});

test('cold start: newest across categories, no exploration slots, flagged', () => {
  const papers = ['cs.CV', 'cs.CV', 'cs.CV', 'cs.CV', 'cs.CL', 'cs.RO'].map((category, i) =>
    candidate(`2610.${String(500 + i).padStart(5, '0')}`, { categories: [category], authors: [`B ${i}`], days: i === 5 ? 3 : 0 }));
  const { results, cold_start } = rankForYou(set(papers, { profile: [] }));
  assert.equal(cold_start, true);
  assert.ok(results.every(r => r.reason.kind === 'category'));
  assert.equal(results[0].reason.text.startsWith('New in '), true);
  assert.ok(results.slice(0, 4).some(r => r.categories[0] !== 'cs.CV'), 'categories are mixed near the top');
});

test('results fit the app: bounded fields, year from the identifier, first seen and announcement day', () => {
  const long = candidate('2610.00601', { authors: Array.from({ length: 12 }, (_, i) => `Name ${i}`), abstract: 'x'.repeat(2000), topics: ['Diffusion models'] });
  const [result] = rankForYou(set([long])).results;
  assert.equal(result.year, 2026);
  assert.equal(result.authors.length, 12);
  assert.equal(result.abstract!.length, 700);
  assert.equal(result.first_seen, '2026-10-08T05:00:00Z');
  assert.equal(result.announced, '2026-10-08');
  assert.equal(FEED_RANKING_VERSION, 'feed-heuristic-v2');
  assert.equal(categoryName('cs.CL'), 'Natural language processing');
  assert.equal(categoryName('cs.SE'), 'cs.SE');
  assert.deepEqual(poolResult({ source_id: 'hep-th/9901001', revision: 2, title: 'Old', authors: ['A'], abstract: null, categories: ['hep-th'],
    announced_on: '2026-10-01', first_seen_at: NOW }), { source_id: 'hep-th/9901001', revision: 2, title: 'Old', authors: ['A'], year: 1999,
    abstract: null, categories: ['hep-th'], first_seen: NOW, announced: '2026-10-01' });
});

test('an empty candidate set ranks to nothing', () => {
  assert.deepEqual(rankForYou(set([])).results, []);
});
