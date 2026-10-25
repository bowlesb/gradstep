// For you ranking (docs/architecture/PERSONALIZED_FEED.md, option A: heuristic, no paid API).
// `worker_feed_candidates` (migration 043) returns the reader's server-visible profile, their Feed
// feedback and a bounded, prefiltered candidate set; this module scores, diversifies, explores and
// explains. Ranking lives here, not in SQL, so it can change without a migration. Pure (Deno + Node).
// v2 (migration 046): Hugging Face upvotes add a small boost and a "Popular on Hugging Face Papers"
// reason; one topic can be ranked for the reader (a topic chip); results carry their topics.
// v3 (migration 0155): similarity to the library. Candidates carry the cosine similarity of their gte-small
// fingerprint to the nearest library paper (interest index); it becomes the main relevance term, "Like “…”" at
// LIKE_SIMILARITY, and popular papers that are also similar rank highest. Author reasons need a credible match
// (two library papers, a rare name, or a similar paper), so namesakes ("Yu Wang") stop explaining picks.
import { discoveryAbstract } from './discover.ts';
import { displayTopics } from './feed-topics.ts';
import { TAG_VOCABULARY, tagsFromCategories } from './tag-vocabulary.ts';

export const FEED_RANKING_VERSION = 'feed-heuristic-v3';

export interface FeedCandidate {
  source_id: string; revision: number; title: string; authors: string[]; author_keys: string[];
  /** 043's candidates carry a 700-character abstract; 046's carry none (worker_feed_details fills it in). */
  abstract?: string | null;
  categories: string[]; topics: string[]; announced_on: string; first_seen_at: string; matched_tags: string[]; readers: number | null;
  /** Hugging Face Papers upvotes (migration 046); null or absent when unknown. */
  upvotes?: number | null;
  /** Cosine similarity to the nearest library paper (migration 0155); null or absent when not served or not embedded. */
  similarity?: number | null;
  /** That library paper (migration 0155). */
  similar_to?: { source_id: string; title: string | null } | null;
}
export interface ProfilePaper {
  source_id: string | null; title: string | null; added_at: string; archived: boolean; pending: boolean;
  categories: string[]; tags: string[]; own_tags: string[]; author_keys: string[];
}
export interface FeedbackRow {
  source_id: string; kind: 'not_interested' | 'more_like_this'; title: string | null;
  categories: string[]; topics: string[]; author_keys: string[]; created_at: string;
}
export interface CandidateSet {
  now: string; today: string; seed: string; window_days: number; pool: number; refreshed_at: string | null;
  /** The pool's categories (feed_policy.categories): the ML categories a reason may name. */
  categories?: string[];
  profile: ProfilePaper[]; feedback: FeedbackRow[]; candidates: FeedCandidate[];
  /** How many window papers carry each of the profile's author keys (migration 0155): a rare key is a person. */
  author_counts?: Record<string, number> | null;
}

export type ReasonKind = 'author' | 'tag' | 'more_like' | 'added' | 'popular' | 'trending' | 'category' | 'explore';
export interface FeedReason { kind: ReasonKind; label: string; text: string }
export interface ForYouResult {
  source_id: string; revision: number; title: string; authors: string[]; year: number | null; abstract: string | null;
  full_abstract?: string | null; abstract_truncated?: boolean;
  categories: string[]; topics: string[]; upvotes: number | null; reason: FeedReason; first_seen: string; announced: string;
}
/** Upvotes from which a paper is called popular on Hugging Face Papers (its "why" line). */
export const TRENDING_UPVOTES = 20;
/** 0…1 from upvotes: log-scaled, 100 upvotes or more count fully. */
export function trend(upvotes: number | null | undefined): number {
  return upvotes && upvotes > 0 ? Math.min(1, Math.log1p(upvotes) / Math.log1p(100)) : 0;
}

/** Similarity from which a candidate is "Like “<library paper>”". Calibrated on the owner's staging library
 * (2026-10-24, 70 papers, 8,175 window papers): sampled pairs at ≥ 0.90 were all recognizably the same line of work
 * (agent memory ↔ agentic memory, on-policy distillation ↔ teacher repair); at 0.88–0.89 about half were; at 0.87 few. */
export const LIKE_SIMILARITY = 0.90;
/** Similarity from which a shared author is credible without other evidence, and a topic anchor may be named. */
export const AUTHOR_SIMILARITY = 0.87;
/** A name key on at most this many window papers is rare enough to be one person (owner's library: "yu wang" 18,
 * "di wu" 10, "lei zhang" 9). */
export const RARE_AUTHOR_PAPERS = 3;
/** A name key on this many window papers or more is a namesake unless the reader has two papers with it. */
export const COMMON_AUTHOR_PAPERS = 8;
/** Below this similarity a candidate counts as unrelated (exploration); the pool's median is about 0.85. */
export const EXPLORE_SIMILARITY = 0.86;
/** closeness(): 0 at SIM_FLOOR, 1 at SIM_FULL. */
const SIM_FLOOR = 0.84, SIM_FULL = 0.93;

/** 0…1 from a similarity: 0 at or below 0.84 (about the pool's median), 1 at 0.93 or above. */
export function closeness(similarity: number | null | undefined): number {
  return typeof similarity === 'number' && Number.isFinite(similarity)
    ? Math.min(1, Math.max(0, (similarity - SIM_FLOOR) / (SIM_FULL - SIM_FLOOR))) : 0;
}
const similarityOf = (c: FeedCandidate): number | null =>
  typeof c.similarity === 'number' && Number.isFinite(c.similarity) ? c.similarity : null;

const DAY = 86_400_000;
const AREAS = new Set(TAG_VOCABULARY.filter(tag => tag.kind === 'area').map(tag => tag.name.toLowerCase()));
const isArea = (tag: string) => AREAS.has(tag.toLowerCase());
const key = (tag: string) => tag.toLowerCase();

/** A category's reader-facing name (the tag vocabulary's, where it has one), else the code. */
export function categoryName(category: string): string { return tagsFromCategories([category], 1)[0] ?? category; }

function short(title: string, limit = 60): string {
  const clean = title.replace(/\s+/g, ' ').trim();
  if (clean.length <= limit) return clean;
  const cut = clean.slice(0, limit - 1);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(' '), limit - 12)).trimEnd()}…`;
}

/** A deterministic number in [0, 1) for this reader, day and paper (FNV-1a). */
export function seeded(seed: string, id: string): number {
  let hash = 0x811c9dc5;
  for (const char of `${seed}|${id}`) { hash ^= char.codePointAt(0)!; hash = Math.imul(hash, 0x01000193) >>> 0; }
  return hash / 2 ** 32;
}

interface Weight { name: string; weight: number; own: boolean }
interface Author { weight: number; library: boolean; /** Library or More-like-this papers with this key. */ papers: number }
interface Profile {
  tags: Map<string, Weight>; categories: Map<string, number>; authors: Map<string, Author>;
  /** Window papers per author key (migration 0155), when known. */
  authorCounts: Map<string, number> | null;
  /** Candidates carry similarity to the library (migration 0155, interest index serving this reader). */
  similarity: boolean;
  /** How many library papers carry each tag: rarer shared tags make better "Because you added" anchors. */
  frequency: Map<string, number>;
  maxTag: number; categoryTotal: number;
  papers: (ProfilePaper & { weight: number })[];
  liked: (FeedbackRow & { weight: number })[]; dismissed: (FeedbackRow & { weight: number })[];
  empty: boolean;
}

/** A library paper's weight in the reader's profile: imports in flight count fully; others fade from 1
 * toward 0.4 over months, archived papers half. */
export function paperWeight(paper: Pick<ProfilePaper, 'pending' | 'archived' | 'added_at'>, now: string): number {
  const age = Math.max(0, (Date.parse(now) - Date.parse(paper.added_at)) / DAY);
  return paper.pending ? 1 : (paper.archived ? 0.5 : 1) * (0.4 + 0.6 * Math.exp(-age / 120));
}

function buildProfile(set: CandidateSet): Profile {
  const now = Date.parse(set.now);
  const age = (iso: string) => Math.max(0, (now - Date.parse(iso)) / DAY);
  const tags = new Map<string, Weight>(), categories = new Map<string, number>();
  const authors = new Map<string, Author>();
  const addTag = (name: string, weight: number, own: boolean) => {
    const known = tags.get(key(name));
    tags.set(key(name), { name: own || !known ? name : known.name, weight: (known?.weight ?? 0) + weight, own: own || (known?.own ?? false) });
  };
  const addCategories = (list: readonly string[], weight: number) =>
    list.forEach((category, index) => categories.set(category, (categories.get(category) ?? 0) + weight * (index === 0 ? 1 : 0.5)));
  const addAuthors = (keys: readonly string[], weight: number, library: boolean) => {
    for (const author of new Set(keys)) if (author) {
      const known = authors.get(author);
      authors.set(author, { weight: (known?.weight ?? 0) + weight, library: library || (known?.library ?? false), papers: (known?.papers ?? 0) + 1 });
    }
  };
  const papers = set.profile.map(paper => {
    const weight = paperWeight(paper, set.now);
    const own = new Set(paper.own_tags.map(key));
    for (const tag of paper.tags) addTag(tag, weight * (own.has(key(tag)) ? 1.5 : 1) * (isArea(tag) ? 0.35 : 1), own.has(key(tag)));
    addCategories(paper.categories, weight);
    addAuthors(paper.author_keys, weight, true);
    return { ...paper, weight };
  });
  const liked: Profile['liked'] = [], dismissed: Profile['dismissed'] = [];
  for (const row of set.feedback) {
    const decay = Math.exp(-age(row.created_at) / 90);
    if (row.kind === 'more_like_this') {
      const weight = 1.5 * decay;
      for (const tag of row.topics) addTag(tag, weight * (isArea(tag) ? 0.35 : 1), false);
      addCategories(row.categories, weight);
      addAuthors(row.author_keys, weight, false);
      liked.push({ ...row, weight });
    } else dismissed.push({ ...row, weight: decay });
  }
  const maxTag = Math.max(0, ...[...tags.values()].map(tag => tag.weight));
  const categoryTotal = [...categories.values()].reduce((sum, weight) => sum + weight, 0);
  const frequency = new Map<string, number>();
  for (const paper of papers) for (const tag of new Set(paper.tags.map(key))) frequency.set(tag, (frequency.get(tag) ?? 0) + 1);
  const counts = set.author_counts && typeof set.author_counts === 'object'
    ? new Map(Object.entries(set.author_counts).filter(([, n]) => typeof n === 'number' && Number.isFinite(n))) : null;
  return { tags, categories, authors, frequency, maxTag, categoryTotal, papers, liked, dismissed,
    authorCounts: counts, similarity: set.candidates.some(c => similarityOf(c) !== null),
    empty: tags.size === 0 && categories.size === 0 && authors.size === 0 };
}

interface Scored {
  candidate: FeedCandidate; score: number; topic: number; author: number; category: number;
  explore: boolean; lead: string; firstAuthor: string; primary: string; similarity: number | null;
}

/** An author key of a candidate the reader has, when the match is believable: the reader has two or more papers with
 * it, or it is rare in the window (one person) — `strong` — or the candidate is also similar to their library. A
 * single common name ("Yu Wang") on an unrelated paper is a namesake, not an author they read. */
function credibleAuthor(author: string, profile: Profile, similarity: number | null): { known: Author; strong: boolean } | null {
  const known = author ? profile.authors.get(author) : undefined;
  if (!known) return null;
  const count = profile.authorCounts?.get(author);
  const strong = known.papers >= 2 || (count !== undefined && count <= RARE_AUTHOR_PAPERS);
  // Similarity vouches for a name only while it is not one of the window's most common.
  return strong || ((similarity ?? 0) >= AUTHOR_SIMILARITY && (count ?? 0) < COMMON_AUTHOR_PAPERS) ? { known, strong } : null;
}

/** The candidate's author the reader has with the most weight, among strong matches or (strong = false) any credible one. */
function authorReason(item: Scored, profile: Profile, strongOnly: boolean): FeedReason | null {
  const c = item.candidate;
  let best = -1, bestWeight = 0, library = false;
  for (let index = 0; index < c.author_keys.length; index++) {
    const match = credibleAuthor(c.author_keys[index], profile, item.similarity);
    if (match && (match.strong || !strongOnly) && match.known.weight >= 0.2 && match.known.weight > bestWeight) {
      best = index; bestWeight = match.known.weight; library = match.known.library;
    }
  }
  if (best < 0 || !c.authors[best]) return null;
  const name = c.authors[best];
  return { kind: 'author', label: name, text: library ? `By ${name}, an author in your library` : `By ${name}, an author of a paper you liked` };
}

function score(candidate: FeedCandidate, profile: Profile, set: CandidateSet): Scored {
  const terms = [...new Set([...candidate.topics, ...candidate.matched_tags].map(key))];
  const topicSum = terms.reduce((sum, term) => sum + (profile.tags.get(term)?.weight ?? 0), 0);
  const topic = profile.maxTag > 0 ? 1 - Math.exp(-topicSum / profile.maxTag) : 0;
  const similarity = similarityOf(candidate);
  const close = closeness(similarity);
  const authorSum = candidate.author_keys.reduce((sum, author) => sum + (credibleAuthor(author, profile, similarity)?.known.weight ?? 0), 0);
  const author = 1 - Math.exp(-authorSum);
  const categorySum = candidate.categories.reduce((sum, category, index) => sum + (profile.categories.get(category) ?? 0) * (index === 0 ? 1 : 0.5), 0);
  const category = profile.categoryTotal > 0 ? Math.min(1, categorySum / profile.categoryTotal) : 0;
  const popular = (candidate.readers ?? 0) >= 3 ? 1 : 0;
  const trending = trend(candidate.upvotes);
  let overlap = 0;
  for (const row of profile.dismissed) {
    const shared = row.topics.filter(tag => !isArea(tag) && candidate.topics.some(t => key(t) === key(tag))).length * 0.5
      + row.author_keys.filter(author => author && candidate.author_keys.includes(author)).length;
    overlap += row.weight * shared;
  }
  // With similarity, it leads; popular papers that are also similar to the library rank highest (owner, 2026-10-24:
  // "both popular and overlaps with things I've shown to be interested in").
  const relevance = profile.empty ? 0.5 + 0.1 * trending
    : profile.similarity ? 0.55 * close + 0.35 * close * trending + 0.15 * topic + 0.15 * author + 0.05 * category + 0.1 * popular + 0.1 * trending
    : 0.5 * topic + 0.3 * author + 0.2 * category + 0.1 * popular + 0.1 * trending;
  const age = Math.max(0, (Date.parse(`${set.today}T00:00:00Z`) - Date.parse(`${candidate.announced_on}T00:00:00Z`)) / DAY);
  const fresh = 0.5 ** (age / 5);
  const specific = [...terms].filter(term => !isArea(term)).sort((a, b) => (profile.tags.get(b)?.weight ?? 0) - (profile.tags.get(a)?.weight ?? 0));
  // Papers near the same library paper share a lead, so one interest does not fill the list.
  const near = profile.similarity && (similarity ?? 0) >= AUTHOR_SIMILARITY && candidate.similar_to?.source_id;
  const lead = near ? `like:${near}` : specific[0] ?? candidate.categories[0] ?? '';
  const unrelated = profile.similarity
    ? (similarity ?? 0) < EXPLORE_SIMILARITY && !specific.some(term => profile.tags.has(term))
    : topic === 0;
  return {
    candidate, topic, author, category, lead, primary: candidate.categories[0] ?? '', similarity,
    firstAuthor: candidate.author_keys.find(Boolean) ?? '',
    explore: !profile.empty && unrelated && author === 0 && candidate.matched_tags.length === 0,
    // With similarity, age weighs less: upvotes take days to gather, and a close, popular paper from last week is still news.
    score: relevance * (profile.similarity ? 0.6 + 0.4 * fresh : 0.4 + 0.6 * fresh) * Math.exp(-0.7 * overlap)
      + 0.03 * seeded(set.seed, candidate.source_id),
  };
}

/** The category a reason names: the first of the paper's categories the reader has (else one of the
 * pool's ML categories, else its first). */
function namedCategory(c: FeedCandidate, preferred: (category: string) => boolean, pool: ReadonlySet<string>): string {
  return c.categories.find(preferred) ?? c.categories.find(category => pool.has(category)) ?? c.categories[0] ?? '';
}

function reasonFor(item: Scored, profile: Profile, cold: boolean, exploring: boolean, pool: ReadonlySet<string>,
  anchors: Map<string, number>, topic: string | null): FeedReason {
  const c = item.candidate;
  if (exploring) {
    // Exploration is "something different" only outside the reader's own categories.
    const outside = namedCategory(c, category => pool.has(category) && !profile.categories.has(category), pool);
    if (!profile.categories.has(outside)) return { kind: 'explore', label: outside, text: `Something different: ${categoryName(outside)}` };
  }
  if (!cold) {
    // One of the reader's own tags (not the topic being shown: every paper there has it).
    const own = [...c.matched_tags, ...c.topics].filter(tag => !topic || key(tag) !== key(topic))
      .map(tag => profile.tags.get(key(tag))).find(tag => tag?.own);
    if (own) return { kind: 'tag', label: own.name, text: `In your tag: ${own.name}` };
    // Close to one of their papers (interest index). Clients show kind `added` as "Like: <title>".
    const like = c.similar_to?.title?.trim();
    if (like && (item.similarity ?? 0) >= LIKE_SIMILARITY) return { kind: 'added', label: like, text: `Like “${short(like)}”` };
    // An author the reader has (or asked for more of): two of their papers, or a rare name.
    const author = authorReason(item, profile, true);
    if (author) return author;
    // A paper they marked More like this.
    const topics = new Set(c.topics.filter(tag => !isArea(tag)).map(key));
    const liked = profile.liked.map(row => ({ row, shared: row.topics.filter(tag => topics.has(key(tag))).length
      + row.author_keys.filter(author => author && c.author_keys.includes(author)).length }))
      .filter(entry => entry.shared > 0 && entry.row.title).sort((a, b) => b.shared - a.shared || b.row.weight - a.row.weight)[0];
    if (liked) return { kind: 'more_like', label: liked.row.title!, text: `More like “${short(liked.row.title!)}”` };
    // The library paper sharing the most specific topics (a topic few of their papers carry says more
    // than "Large language models"), passing over papers already named often in this list. With similarity
    // known, only for a paper that is somewhat similar: a shared tag alone does not make it "because you added".
    let anchor: { paper: Profile['papers'][number]; score: number } | null = null;
    for (const paper of profile.similarity && (item.similarity ?? 0) < AUTHOR_SIMILARITY ? [] : profile.papers) {
      if (!paper.title || paper.pending) continue;
      const shared = [...new Set(paper.tags.map(key))].filter(tag => topics.has(tag));
      if (!shared.length) continue;
      const specificity = shared.reduce((sum, tag) => sum + 1 / (profile.frequency.get(tag) ?? 1), 0);
      const score = specificity / (1 + 0.75 * (anchors.get(paper.title) ?? 0)) + Date.parse(paper.added_at) / 1e15;
      if (!anchor || score > anchor.score) anchor = { paper, score };
    }
    if (anchor) {
      anchors.set(anchor.paper.title!, (anchors.get(anchor.paper.title!) ?? 0) + 1);
      return { kind: 'added', label: anchor.paper.title!, text: `Because you added “${short(anchor.paper.title!)}”` };
    }
    if ((c.readers ?? 0) >= 3) return { kind: 'popular', label: String(c.readers), text: 'Added by several readers this week' };
  }
  if ((c.upvotes ?? 0) >= TRENDING_UPVOTES) return { kind: 'trending', label: String(c.upvotes), text: 'Popular on Hugging Face Papers' };
  // A common name on a similar paper: probably them, but popularity above is a fact.
  const named = cold ? null : authorReason(item, profile, false);
  if (named) return named;
  const category = namedCategory(c, cat => !cold && profile.categories.has(cat), pool);
  return { kind: 'category', label: category, text: `New in ${categoryName(category)}` };
}

function year(sourceID: string): number | null {
  const modern = /^(\d{2})\d{2}\.\d{4,5}$/.exec(sourceID);
  if (modern) return 2000 + Number(modern[1]);
  const historic = /\/(\d{2})\d{5}$/.exec(sourceID);
  return historic ? (Number(historic[1]) >= 91 ? 1900 : 2000) + Number(historic[1]) : null;
}

/** With similarity, For you shows at least this many papers before leaving out weak picks. */
export const MIN_FOR_YOU = 20;
/** Similarity from which a paper with no other reason is still shown ("New in …"); below it, it is left out. */
export const CATEGORY_SIMILARITY = 0.88;

/** A pick For you leaves out when similarity is known: only a category says why and it is not close to the library,
 * or it is popular but unrelated to the library (popular ∩ the reader's interests is what For you is for). */
function weakPick(reason: FeedReason, similarity: number | null): boolean {
  return (reason.kind === 'category' && (similarity ?? 0) < CATEGORY_SIMILARITY)
    || (reason.kind === 'trending' && (similarity ?? 0) < EXPLORE_SIMILARITY);
}

export interface RankOptions {
  limit?: number;
  /** A topic chip: the candidates all have this topic, so it is never the reason and nothing explores. */
  topic?: string | null;
}

/** Ranks For you: relevance × freshness, Not-interested penalty, a little daily variety; greedy
 * diversity by lead topic (with similarity: the nearest library paper), first author and primary category; every fifth
 * slot explores (every tenth with similarity; never in a topic). */
export function rankForYou(set: CandidateSet, options: number | RankOptions = 50): { results: ForYouResult[]; cold_start: boolean } {
  const { limit = 50, topic = null } = typeof options === 'number' ? { limit: options } : options;
  const profile = buildProfile(set);
  const cold = profile.empty;
  const pool = new Set(set.categories ?? []);
  const anchors = new Map<string, number>();
  const scored = set.candidates.map(candidate => score(candidate, profile, set)).sort((a, b) => b.score - a.score);
  const main = scored.filter(item => !item.explore), explore = scored.filter(item => item.explore);
  const counts = { lead: new Map<string, number>(), author: new Map<string, number>(), primary: new Map<string, number>() };
  const adjusted = (item: Scored) => item.score * 0.8 ** (counts.lead.get(item.lead) ?? 0)
    * (item.firstAuthor ? 0.7 ** (counts.author.get(item.firstAuthor) ?? 0) : 1)
    * 0.9 ** Math.max(0, (counts.primary.get(item.primary) ?? 0) - 2);
  /** The best remaining item of `list` after diversity, removed from `owner` (the list it lives in). */
  const take = (list: Scored[], owner: Scored[] = list): Scored | null => {
    if (!list.length) return null;
    let best = 0;
    for (let i = 1; i < list.length; i++) if (adjusted(list[i]) > adjusted(list[best])) best = i;
    const item = list[best];
    owner.splice(owner.indexOf(item), 1);
    return item;
  };
  const results: ForYouResult[] = [], setAside: ForYouResult[] = [];
  // With similarity, For you leaves out picks whose only reason is weak (owner, 2026-10-24: "start with a smaller list
  // that's better chosen"); a topic chip lists its topic's papers as before.
  const floor = profile.similarity && !cold && !topic;
  while (results.length < limit) {
    // Every fifth slot explores; with similarity (a better-chosen list), every tenth.
    // An exploration slot prefers a paper from outside the reader's categories (with similarity, takes only such a paper:
    // one inside them could only say "New in …").
    const outside = explore.filter(entry => !entry.candidate.categories.some(category => profile.categories.has(category)));
    const exploring = !cold && !topic && (results.length + 1) % (profile.similarity ? 10 : 5) === 0
      && (floor ? outside.length : explore.length) > 0;
    const item = exploring ? (outside.length ? take(outside, explore) : take(explore)) : take(main) ?? take(explore);
    if (!item) break;
    const c = item.candidate;
    const reason = reasonFor(item, profile, cold, exploring, pool, anchors, topic);
    const result: ForYouResult = { source_id: c.source_id, revision: c.revision, title: c.title, authors: c.authors.slice(0, 12), year: year(c.source_id),
      abstract: c.abstract ? c.abstract.slice(0, 700) : null, categories: c.categories.slice(0, 12),
      topics: displayTopics(c.topics), upvotes: validUpvotes(c.upvotes), reason, first_seen: c.first_seen_at, announced: c.announced_on };
    if (floor && !exploring && weakPick(reason, item.similarity)) { setAside.push(result); continue; }
    for (const [map, value] of [[counts.lead, item.lead], [counts.author, item.firstAuthor], [counts.primary, item.primary]] as const) {
      if (value) map.set(value, (map.get(value) ?? 0) + 1);
    }
    results.push(result);
  }
  // A short list is better than a padded one, down to MIN_FOR_YOU.
  const least = Math.min(limit, MIN_FOR_YOU);
  if (results.length < least) results.push(...setAside.slice(0, least - results.length));
  return { results, cold_start: cold };
}

/** A category chip served from the pool (`worker_feed_category` rows) in the discover result shape. */
export function poolResult(row: { source_id: string; revision: number; title: string; authors: string[]; abstract: string | null;
  categories: string[]; announced_on: string; first_seen_at: string }) {
  return { source_id: row.source_id, revision: row.revision, title: row.title, authors: row.authors.slice(0, 12), year: year(row.source_id),
    abstract: row.abstract ? row.abstract.slice(0, 700) : null, categories: row.categories.slice(0, 12),
    first_seen: row.first_seen_at, announced: row.announced_on };
}

const validUpvotes = (value: unknown): number | null =>
  typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 1_000_000 ? value : null;

/** What `worker_feed_details` returns for a paper about to be shown (migration 046). */
export interface PoolDetail { source_id: string; abstract: string | null; abstract_complete: boolean; topics?: string[]; upvotes: number | null }

/** Fills ranked results with the pool's stored abstracts (complete only below the pool's bound) and
 * current upvotes. Results without details keep what they had. */
export function withDetails(results: ForYouResult[], details: readonly PoolDetail[] | null): ForYouResult[] {
  const byID = new Map((details ?? []).map(detail => [detail.source_id, detail]));
  return results.map(result => {
    const detail = byID.get(result.source_id);
    if (!detail) return result;
    return { ...result, ...discoveryAbstract(detail.abstract, true, !detail.abstract_complete), upvotes: validUpvotes(detail.upvotes) ?? result.upvotes };
  });
}

/** A category chip served from the pool (`worker_feed_category_v2` rows): topics, upvotes, and the
 * stored abstract (full when asked for, marked incomplete when the pool bounded it). */
export function poolResultV2(row: { source_id: string; revision: number; title: string; authors: string[]; abstract: string | null;
  abstract_complete?: boolean; categories: string[]; topics?: string[]; upvotes?: number | null; announced_on: string; first_seen_at: string },
  full: boolean) {
  return { ...poolResult(row), ...discoveryAbstract(row.abstract, full, row.abstract_complete === false),
    topics: displayTopics(row.topics ?? []), upvotes: validUpvotes(row.upvotes) };
}
