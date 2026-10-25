// For you ranking v3 (migration 0155; docs/architecture/PERSONALIZED_FEED.md, "Similarity to the library"): similarity
// to the nearest library paper leads relevance and explains picks as "Like “…”"; popular ∩ similar ranks highest; author
// reasons need a credible match; weak picks are left out of a list that has enough good ones.
import test from 'node:test';
import assert from 'node:assert/strict';
import { AUTHOR_SIMILARITY, closeness, COMMON_AUTHOR_PAPERS, FEED_RANKING_VERSION, LIKE_SIMILARITY, MIN_FOR_YOU, rankForYou,
  RARE_AUTHOR_PAPERS, type CandidateSet, type FeedCandidate, type ProfilePaper } from '../../supabase/functions/_shared/feed-rank.ts';

const NOW = '2026-10-24T12:00:00Z';
const LIB_A = { source_id: '2410.00001', title: 'Capable Teacher, Myopic Scorer: Reward-Free Teacher Repair' };
const LIB_B = { source_id: '2410.00002', title: 'Agent World Model in the Wild' };
// The owner's case: library tags are only broad areas, and common names appear on one library paper each.
const paper = (source: { source_id: string; title: string }, authors: string[], extra: Partial<ProfilePaper> = {}): ProfilePaper => ({
  source_id: source.source_id, title: source.title, added_at: '2026-10-20T00:00:00Z', archived: false, pending: false,
  categories: ['cs.CL', 'cs.AI'], tags: ['Natural language processing', 'Artificial intelligence'], own_tags: [], author_keys: authors, ...extra });
let next = 0;
function candidate(options: Partial<FeedCandidate> & { sim?: number | null; near?: { source_id: string; title: string } } = {}): FeedCandidate {
  const authors = options.authors ?? [`Author ${next}`];
  const { sim, near, ...rest } = options;
  return { source_id: `2610.${String(10000 + next++)}`, revision: 1, title: `Paper ${next}`, authors, author_keys: authors.map(a => a.toLowerCase()),
    categories: ['cs.CL'], topics: ['Natural language processing'], announced_on: '2026-10-23', first_seen_at: '2026-10-23T05:00:00Z',
    matched_tags: [], readers: null, upvotes: null,
    similarity: sim === undefined ? 0.85 : sim, similar_to: sim === null ? null : near ?? LIB_A, ...rest };
}
function set(candidates: FeedCandidate[], extra: Partial<CandidateSet> = {}): CandidateSet {
  return { now: NOW, today: '2026-10-24', seed: 'reader:2026-10-24', window_days: 14, pool: 8000, refreshed_at: NOW,
    categories: ['cs.LG', 'cs.CL', 'cs.CV', 'cs.AI', 'stat.ML', 'cs.RO'],
    profile: [paper(LIB_A, ['yu wang', 'mei rare']), paper(LIB_B, ['lei zhang', 'tri twice']), paper({ source_id: '2410.00003', title: 'Third' }, ['tri twice'])],
    feedback: [], candidates, author_counts: { 'yu wang': 18, 'lei zhang': 9, 'mei rare': 1, 'tri twice': 6 }, ...extra };
}
const byID = (results: { source_id: string }[]) => new Map(results.map((r, i) => [r.source_id, i]));

test('v3: thresholds are ordered and closeness is bounded', () => {
  assert.equal(FEED_RANKING_VERSION, 'feed-heuristic-v3');
  assert.ok(AUTHOR_SIMILARITY < LIKE_SIMILARITY && RARE_AUTHOR_PAPERS < COMMON_AUTHOR_PAPERS);
  assert.equal(closeness(null), 0);
  assert.equal(closeness(0.5), 0);
  assert.equal(closeness(0.84), 0);
  assert.equal(closeness(0.99), 1);
  assert.ok(closeness(0.88) > 0.4 && closeness(0.88) < 0.5);
  assert.equal(closeness(Number.NaN), 0);
});

test('v3: a close paper says which library paper it is like (old clients show kind added as "Like: …")', () => {
  const like = candidate({ sim: 0.925 });
  const near = candidate({ sim: 0.895, near: LIB_B });
  const { results } = rankForYou(set([like, near]));
  const reasons = new Map(results.map(r => [r.source_id, r.reason]));
  assert.deepEqual(reasons.get(like.source_id), { kind: 'added', label: LIB_A.title, text: 'Like “Capable Teacher, Myopic Scorer: Reward-Free Teacher Repair”' });
  assert.notEqual(reasons.get(near.source_id)!.kind, 'added', 'below LIKE_SIMILARITY it is not called like');
  assert.equal(results[0].source_id, like.source_id);
});

test('v3: an own tag still comes first; like comes before an author and a category', () => {
  const profile = [paper(LIB_A, ['mei rare'], { tags: ['Tokenization'], own_tags: ['Tokenization'] })];
  const tagged = candidate({ sim: 0.93, topics: ['Tokenization'] });
  const authored = candidate({ sim: 0.93, authors: ['Mei Rare'] });
  const reasons = new Map(rankForYou(set([tagged, authored], { profile })).results.map(r => [r.source_id, r.reason.kind]));
  assert.equal(reasons.get(tagged.source_id), 'tag');
  assert.equal(reasons.get(authored.source_id), 'added');
});

test('v3: similarity leads relevance, and popular ∩ similar ranks highest', () => {
  const both = candidate({ sim: 0.91, upvotes: 80, near: LIB_B });
  const similar = candidate({ sim: 0.91, near: LIB_A });
  const popular = candidate({ sim: 0.80, upvotes: 300 });
  const generic = candidate({ sim: 0.83, topics: ['Natural language processing', 'Artificial intelligence'] });
  const order = byID(rankForYou(set([generic, popular, similar, both])).results);
  assert.equal(order.get(both.source_id), 0, 'popular and similar first');
  assert.ok(order.get(similar.source_id)! < order.get(popular.source_id)!, 'similar beats popular but unrelated');
  assert.ok(order.get(similar.source_id)! < order.get(generic.source_id)!, 'similar beats a generic topic match');
});

test('v3: author reasons are credible — namesakes no longer explain picks', () => {
  // "Yu Wang" is on 18 window papers and one library paper: on an unrelated paper it is a namesake.
  const namesake = candidate({ sim: 0.80, authors: ['Yu Wang'] });
  // Common (≥ COMMON_AUTHOR_PAPERS) even on a fairly similar paper.
  const commonSimilar = candidate({ sim: 0.885, authors: ['Lei Zhang'], near: LIB_B });
  // A rare name: one person.
  const rare = candidate({ sim: 0.80, authors: ['Mei Rare'] });
  // Two library papers with the name.
  const twice = candidate({ sim: 0.80, authors: ['Tri Twice'] });
  // Not rare, not common, one library paper: credible only on a similar paper.
  const middling = candidate({ sim: 0.88, authors: ['Ana Middle'] });
  const middlingFar = candidate({ sim: 0.80, authors: ['Ana Middle'] });
  const profile = [...set([]).profile, paper({ source_id: '2410.00004', title: 'Fourth' }, ['ana middle'])];
  const counts = { ...set([]).author_counts, 'ana middle': 5 };
  const { results } = rankForYou(set([namesake, commonSimilar, rare, twice, middling, middlingFar], { profile, author_counts: counts }));
  const reasons = new Map(results.map(r => [r.source_id, r.reason]));
  assert.notEqual(reasons.get(namesake.source_id)?.kind, 'author');
  assert.notEqual(reasons.get(commonSimilar.source_id)?.kind, 'author');
  assert.deepEqual(reasons.get(rare.source_id), { kind: 'author', label: 'Mei Rare', text: 'By Mei Rare, an author in your library' });
  assert.equal(reasons.get(twice.source_id)?.kind, 'author');
  assert.equal(reasons.get(middling.source_id)?.kind, 'author');
  assert.notEqual(reasons.get(middlingFar.source_id)?.kind, 'author');
  // Without counts (an older database), a single library paper's name needs similarity.
  const unknown = rankForYou(set([candidate({ sim: 0.80, authors: ['Mei Rare'] })], { author_counts: undefined })).results[0];
  assert.notEqual(unknown.reason.kind, 'author');
});

test('v3: a popular paper whose author match rests on similarity alone is called popular', () => {
  const pick = candidate({ sim: 0.88, authors: ['Ana Middle'], upvotes: 120 });
  const profile = [...set([]).profile, paper({ source_id: '2410.00004', title: 'Fourth' }, ['ana middle'])];
  const [result] = rankForYou(set([pick], { profile, author_counts: { 'ana middle': 5 } })).results;
  assert.deepEqual(result.reason, { kind: 'trending', label: '120', text: 'Popular on Hugging Face Papers' });
});

test('v3: a list with enough good picks leaves out weak ones; a short one keeps them', () => {
  const good = Array.from({ length: 30 }, (_, i) => candidate({ sim: 0.90 + (i % 5) / 100, near: i % 2 ? LIB_A : LIB_B, categories: ['cs.CL'] }));
  const weakCategory = Array.from({ length: 5 }, () => candidate({ sim: 0.86 }));
  const unrelatedPopular = Array.from({ length: 3 }, () => candidate({ sim: 0.80, upvotes: 400 }));
  const closeCategory = candidate({ sim: 0.885 });
  const { results } = rankForYou(set([...good, ...weakCategory, ...unrelatedPopular, closeCategory]), 50);
  const shown = new Set(results.map(r => r.source_id));
  assert.ok(weakCategory.every(c => !shown.has(c.source_id)), 'category-only below 0.88: left out');
  assert.ok(unrelatedPopular.every(c => !shown.has(c.source_id)), 'popular but unrelated: left out');
  assert.ok(shown.has(closeCategory.source_id), 'close enough to keep with a category reason');
  assert.equal(results.length, 31);
  // Few good picks: weak ones fill up to MIN_FOR_YOU.
  const few = rankForYou(set([...good.slice(0, 5), ...Array.from({ length: 30 }, () => candidate({ sim: 0.85 }))]), 50).results;
  assert.equal(few.length, MIN_FOR_YOU);
  assert.deepEqual(few.slice(0, 5).map(r => r.reason.kind), ['added', 'added', 'added', 'added', 'added']);
  // A topic chip lists its topic's papers as before.
  const topic = rankForYou(set([...good.slice(0, 5), ...weakCategory]), { topic: 'Natural language processing' }).results;
  assert.equal(topic.length, 10);
});

test('v3: papers near the same library paper are spread out, and exploration is every tenth slot', () => {
  const nearA = Array.from({ length: 6 }, () => candidate({ sim: 0.95, near: LIB_A }));
  const nearB = Array.from({ length: 6 }, () => candidate({ sim: 0.92, near: LIB_B }));
  const others = Array.from({ length: 30 }, (_, i) => candidate({ sim: 0.90 + (i % 3) / 100, near: { source_id: `2410.1${i}`, title: `Library ${i}` } }));
  const outside = Array.from({ length: 3 }, () => candidate({ sim: 0.70, categories: ['q-bio.NC'], topics: [] }));
  const { results } = rankForYou(set([...nearA, ...nearB, ...others, ...outside]), 30);
  const top6 = results.slice(0, 6).map(r => r.reason.label);
  assert.ok(top6.filter(label => label === LIB_A.title).length <= 3, String(top6));
  assert.equal(results[9].reason.kind, 'explore');
  assert.equal(results[19].reason.kind, 'explore');
  assert.ok(results.filter(r => r.reason.kind === 'explore').length === 3);
  assert.ok(results.slice(0, 9).every(r => r.reason.kind !== 'explore'));
});

test('v3: without similarity (not served, or an older database) ranking is the v2 heuristic', () => {
  const plain = Array.from({ length: 10 }, (_, i) => candidate({ sim: null, authors: [`Other ${i}`], categories: i < 5 ? ['cs.CL'] : ['q-bio.NC'], topics: [] }));
  const { results } = rankForYou(set(plain), 10);
  assert.equal(results.length, 10, 'nothing is left out');
  assert.equal(results[4].reason.kind, 'explore', 'every fifth slot explores');
  assert.ok(results.every(r => r.reason.kind !== 'added'));
});
