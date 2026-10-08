import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FEED_TOPIC_TAGS, FEED_TOPICS_VERSION, feedTopics } from '../../supabase/functions/_shared/feed-topics.ts';
import { TAG_NAMES } from '../../supabase/functions/_shared/tag-vocabulary.ts';
import { announcementDay, parsePoolRSS, poolAuthors, poolFeedURL, POOL_BATCH, runRefresh, sameSecret, withTopics,
  type PoolItem, type RefreshClaim, type RefreshDeps, type RefreshStatus } from '../../supabase/functions/_shared/feed-pool.ts';
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

// ---- Pool parsing ------------------------------------------------------------------------------

const fixture = new Uint8Array(readFileSync(new URL('../fixtures/arxiv/rss-cs.LG-sample.xml', import.meta.url)));

function rss(items: string[]): Uint8Array {
  return new TextEncoder().encode(`<?xml version='1.0' encoding='UTF-8'?>\n<rss xmlns:arxiv="http://arxiv.org/schemas/atom" ` +
    `xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel><title>x</title>${items.join('')}</channel></rss>`);
}
function item(id: string, type: string, options: { title?: string; categories?: string[]; authors?: string; pubDate?: string; abstract?: string } = {}) {
  return `<item><title>${options.title ?? `Paper ${id}`}</title><link>https://arxiv.org/abs/${id}</link>` +
    `<description>arXiv:${id}v2 Announce Type: ${type} \nAbstract: ${options.abstract ?? 'We study things &amp; stuff.'}</description>` +
    (options.categories ?? ['cs.LG']).map(c => `<category>${c}</category>`).join('') +
    `<pubDate>${options.pubDate ?? 'Thu, 08 Oct 2026 00:00:00 -0400'}</pubDate><arxiv:announce_type>${type}</arxiv:announce_type>` +
    `<dc:creator>${options.authors ?? 'Ada Lovelace, Alan Turing'}</dc:creator></item>`;
}

test('parses the real arXiv RSS sample into pool items', () => {
  const { items, skipped } = parsePoolRSS(fixture, { limit: 3000, today: '2026-10-05' });
  assert.equal(skipped, 0);
  assert.equal(items.length, 3);
  assert.equal(items[0].source_id, '2610.02224');
  assert.equal(items[0].announced_on, '2026-10-05');
  assert.equal(items[0].announce_type, 'new');
  assert.deepEqual(items[0].categories, ['cs.LG', 'cond-mat.mtrl-sci']);
  assert.equal(items[0].authors[0], 'Quach Thi Thai Binh');
  assert.ok(items[0].abstract!.startsWith('Rapid and reliable identification'));
  assert.ok(items[0].abstract!.length <= 2000);
  const tagged = withTopics(items);
  assert.ok(tagged[0].topics.includes('Machine learning') && tagged[0].topics.length <= 10, String(tagged[0].topics));
});

test('keeps new and cross-lists, skips replacements, merges duplicates, bounds every field', () => {
  const longAuthors = Array.from({ length: 30 }, (_, i) => `Author ${i + 1}`).join(', ');
  const { items, skipped } = parsePoolRSS(rss([
    item('2610.00001', 'new', { categories: ['cs.CL'] }),
    item('2610.00002', 'replace'),
    item('2610.00003', 'replace-cross'),
    item('2610.00004', 'cross', { authors: longAuthors, categories: ['cs.CV', 'cs.LG'] }),
    item('2610.00001', 'cross', { categories: ['cs.LG'] }),
    item('not-an-id', 'new'),
    item('2610.00005', 'new', { categories: [] }),
    item('2610.00006', 'new', { pubDate: 'Thu, 08 Oct 2025 00:00:00 -0400' }),
    item('2610.00007', 'new', { title: '' }),
  ]), { limit: 3000, today: '2026-10-08' });
  assert.deepEqual(items.map(i => i.source_id), ['2610.00001', '2610.00004']);
  assert.equal(skipped, 4, 'bad id, no category, a year-old date and an empty title');
  assert.deepEqual(items[0].categories, ['cs.CL', 'cs.LG'], 'a duplicate merges its categories');
  assert.equal(items[0].announce_type, 'new');
  assert.equal(items[0].revision, 2);
  assert.equal(items[0].abstract, 'We study things & stuff.');
  assert.equal(items[1].authors.length, 12);
  assert.equal(items[1].authors[11], 'Author 30', 'the last author is kept');
  assert.equal(items[1].announce_type, 'cross');
});

test('limits, unsafe XML and the announcement day', () => {
  assert.equal(parsePoolRSS(rss([item('2610.00001', 'new'), item('2610.00004', 'new')]), { limit: 1, today: '2026-10-08' }).items.length, 1);
  assert.throws(() => parsePoolRSS(new TextEncoder().encode('<!DOCTYPE x><rss></rss>'), { limit: 10, today: '2026-10-08' }), /invalid_feed/);
  assert.throws(() => parsePoolRSS(new TextEncoder().encode('<html/>'), { limit: 10, today: '2026-10-08' }), /invalid_feed/);
  assert.equal(announcementDay('Thu, 8 Oct 2026 00:00:00 -0400'), '2026-10-08');
  assert.equal(announcementDay('garbage'), null);
  assert.deepEqual(poolAuthors(['  Ada   Lovelace ', '', 'x'.repeat(300)]), ['Ada Lovelace']);
  assert.equal(poolFeedURL(['cs.LG', 'stat.ML', 'eess.AS']), 'https://rss.arxiv.org/rss/cs.LG+stat.ML+eess.AS');
  assert.throws(() => poolFeedURL(['cs.LG', 'cs.LG/../x']), /invalid_categories/);
  assert.throws(() => poolFeedURL([]), /invalid_categories/);
});

test('items match the database rules (migration 043 feed_valid_item)', () => {
  const tagged = withTopics(parsePoolRSS(rss([item('2610.00004', 'cross', { title: 'Mixture of experts for RAG' })]), { limit: 10, today: '2026-10-08' }).items);
  const keys = Object.keys(tagged[0]).sort();
  assert.deepEqual(keys, ['abstract', 'announce_type', 'announced_on', 'authors', 'categories', 'revision', 'source_id', 'title', 'topics']);
  for (const topic of tagged[0].topics) assert.ok(topic.length <= 40 && topic === topic.trim(), topic);
  assert.equal(new Set(tagged[0].topics.map(t => t.toLowerCase())).size, tagged[0].topics.length);
});

// ---- Refresh loop ------------------------------------------------------------------------------

const claim: RefreshClaim = { claim_id: '0a2b5c7e-0000-4000-8000-000000000001', source: 'arxiv-ml', categories: ['cs.LG', 'cs.CL'],
  etag: '"previous"', last_modified: 'Wed, 07 Oct 2026 04:31:42 GMT', max_items: 3000 };

function refreshDeps(response: () => Response, options: { reserved?: boolean; wait?: number; failFinish?: boolean } = {}) {
  const calls = { fetches: [] as { url: string; headers: Record<string, string> }[], upserts: [] as PoolItem[][], sleeps: [] as number[],
    finishes: [] as { status: RefreshStatus; etag: string | null; lastModified: string | null; items: number | null }[] };
  const deps: RefreshDeps = {
    slot: async () => ({ reserved: options.reserved ?? true, wait_ms: options.wait ?? 0 }),
    fetch: (async (url: string, init?: RequestInit) => { calls.fetches.push({ url, headers: init?.headers as Record<string, string> }); return response(); }) as typeof fetch,
    upsert: async (claimID, items, version) => {
      assert.equal(claimID, claim.claim_id); assert.equal(version, FEED_TOPICS_VERSION); calls.upserts.push(items);
      return { inserted: items.length, updated: 0 };
    },
    finish: async (claimID, status, etag, lastModified, items) => {
      assert.equal(claimID, claim.claim_id); calls.finishes.push({ status, etag, lastModified, items });
      if (options.failFinish) throw new Error('database_unavailable');
      return { pruned: 0, pool: 42 };
    },
    sleep: async ms => { calls.sleeps.push(ms); },
    today: () => '2026-10-08',
  };
  return { deps, calls };
}

test('a conditional request that is not modified records success without parsing', async () => {
  const { deps, calls } = refreshDeps(() => new Response(null, { status: 304 }), { wait: 1500 });
  const outcome = await runRefresh(deps, claim);
  assert.equal(outcome.status, 'not_modified');
  assert.deepEqual(calls.sleeps, [1500], 'waits for the shared arXiv slot');
  assert.equal(calls.fetches[0].url, 'https://rss.arxiv.org/rss/cs.LG+cs.CL');
  assert.equal(calls.fetches[0].headers['if-none-match'], '"previous"');
  assert.equal(calls.fetches[0].headers['if-modified-since'], 'Wed, 07 Oct 2026 04:31:42 GMT');
  assert.equal(calls.upserts.length, 0);
  assert.deepEqual(calls.finishes, [{ status: 'not_modified', etag: null, lastModified: null, items: null }]);
});

test('a new listing is tagged, written in batches and recorded with its validators', async () => {
  const many = Array.from({ length: POOL_BATCH + 25 }, (_, i) => item(`2610.${String(10000 + i)}`, 'new', { title: `Diffusion models ${i}` }));
  const { deps, calls } = refreshDeps(() => new Response(rss(many), { status: 200, headers: { etag: '"next"', 'last-modified': 'Thu, 08 Oct 2026 04:31:42 GMT' } }));
  const outcome = await runRefresh(deps, claim);
  assert.deepEqual({ status: outcome.status, items: outcome.items, inserted: outcome.inserted, pool: outcome.pool },
    { status: 'updated', items: POOL_BATCH + 25, inserted: POOL_BATCH + 25, pool: 42 });
  assert.deepEqual(calls.upserts.map(batch => batch.length), [POOL_BATCH, 25]);
  assert.ok(calls.upserts[0][0].topics.includes('Diffusion models'));
  assert.deepEqual(calls.finishes, [{ status: 'updated', etag: '"next"', lastModified: 'Thu, 08 Oct 2026 04:31:42 GMT', items: POOL_BATCH + 25 }]);
});

test('throttling, a busy slot, oversize and a lost database are recorded, never thrown', async () => {
  let run = refreshDeps(() => new Response('slow down', { status: 429 }));
  assert.deepEqual([(await runRefresh(run.deps, claim)).code, run.calls.finishes[0].status], ['arxiv_429', 'failed']);
  run = refreshDeps(() => { throw new Error('unused'); }, { reserved: false });
  assert.equal((await runRefresh(run.deps, claim)).status, 'busy');
  assert.equal(run.calls.fetches.length, 0, 'no request without the pacing slot');
  run = refreshDeps(() => new Response('x', { status: 200, headers: { 'content-length': String(64 * 1024 * 1024) } }));
  assert.equal((await runRefresh(run.deps, claim)).code, 'feed_too_large');
  run = refreshDeps(() => new Response('<html/>', { status: 200 }));
  assert.equal((await runRefresh(run.deps, claim)).code, 'invalid_feed');
  run = refreshDeps(() => new Response(null, { status: 304 }), { failFinish: true });
  const lost = await runRefresh(run.deps, claim);
  assert.equal(lost.code, 'finish_failed', 'the lease expires and the next kick retries');
  const bad = refreshDeps(() => new Response(null, { status: 304 }));
  assert.equal((await runRefresh(bad.deps, { ...claim, categories: ['../x'] })).code, 'invalid_categories');
  assert.equal(bad.calls.fetches.length, 0);
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
