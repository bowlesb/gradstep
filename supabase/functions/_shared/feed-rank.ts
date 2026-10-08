// For you ranking (docs/architecture/PERSONALIZED_FEED.md, option A: heuristic, no paid API).
// `worker_feed_candidates` (migration 044) returns the reader's server-visible profile, their Feed
// feedback and a bounded, prefiltered candidate set; this module scores, diversifies, explores and
// explains. Ranking lives here, not in SQL, so it can change without a migration. Pure (Deno + Node).
import { TAG_VOCABULARY, tagsFromCategories } from './tag-vocabulary.ts';

export const FEED_RANKING_VERSION = 'feed-heuristic-v1';

export interface FeedCandidate {
  source_id: string; revision: number; title: string; authors: string[]; author_keys: string[]; abstract: string | null;
  categories: string[]; topics: string[]; announced_on: string; first_seen_at: string; matched_tags: string[]; readers: number | null;
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
  profile: ProfilePaper[]; feedback: FeedbackRow[]; candidates: FeedCandidate[];
}

export type ReasonKind = 'author' | 'tag' | 'more_like' | 'added' | 'popular' | 'category' | 'explore';
export interface FeedReason { kind: ReasonKind; label: string; text: string }
export interface ForYouResult {
  source_id: string; revision: number; title: string; authors: string[]; year: number | null; abstract: string | null;
  categories: string[]; reason: FeedReason; first_seen: string; announced: string;
}

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
interface Profile {
  tags: Map<string, Weight>; categories: Map<string, number>; authors: Map<string, { weight: number; library: boolean }>;
  maxTag: number; categoryTotal: number;
  papers: (ProfilePaper & { weight: number })[];
  liked: (FeedbackRow & { weight: number })[]; dismissed: (FeedbackRow & { weight: number })[];
  empty: boolean;
}

function buildProfile(set: CandidateSet): Profile {
  const now = Date.parse(set.now);
  const age = (iso: string) => Math.max(0, (now - Date.parse(iso)) / DAY);
  const tags = new Map<string, Weight>(), categories = new Map<string, number>();
  const authors = new Map<string, { weight: number; library: boolean }>();
  const addTag = (name: string, weight: number, own: boolean) => {
    const known = tags.get(key(name));
    tags.set(key(name), { name: own || !known ? name : known.name, weight: (known?.weight ?? 0) + weight, own: own || (known?.own ?? false) });
  };
  const addCategories = (list: readonly string[], weight: number) =>
    list.forEach((category, index) => categories.set(category, (categories.get(category) ?? 0) + weight * (index === 0 ? 1 : 0.5)));
  const addAuthors = (keys: readonly string[], weight: number, library: boolean) => {
    for (const author of keys) if (author) {
      const known = authors.get(author);
      authors.set(author, { weight: (known?.weight ?? 0) + weight, library: library || (known?.library ?? false) });
    }
  };
  const papers = set.profile.map(paper => {
    const weight = paper.pending ? 1 : (paper.archived ? 0.5 : 1) * (0.4 + 0.6 * Math.exp(-age(paper.added_at) / 120));
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
  return { tags, categories, authors, maxTag, categoryTotal, papers, liked, dismissed,
    empty: tags.size === 0 && categories.size === 0 && authors.size === 0 };
}

interface Scored {
  candidate: FeedCandidate; score: number; topic: number; author: number; category: number;
  explore: boolean; lead: string; firstAuthor: string; primary: string;
}

function score(candidate: FeedCandidate, profile: Profile, set: CandidateSet): Scored {
  const terms = [...new Set([...candidate.topics, ...candidate.matched_tags].map(key))];
  const topicSum = terms.reduce((sum, term) => sum + (profile.tags.get(term)?.weight ?? 0), 0);
  const topic = profile.maxTag > 0 ? 1 - Math.exp(-topicSum / profile.maxTag) : 0;
  const authorSum = candidate.author_keys.reduce((sum, author) => sum + (author ? profile.authors.get(author)?.weight ?? 0 : 0), 0);
  const author = 1 - Math.exp(-authorSum);
  const categorySum = candidate.categories.reduce((sum, category, index) => sum + (profile.categories.get(category) ?? 0) * (index === 0 ? 1 : 0.5), 0);
  const category = profile.categoryTotal > 0 ? Math.min(1, categorySum / profile.categoryTotal) : 0;
  const popular = (candidate.readers ?? 0) >= 3 ? 1 : 0;
  let overlap = 0;
  for (const row of profile.dismissed) {
    const shared = row.topics.filter(tag => !isArea(tag) && candidate.topics.some(t => key(t) === key(tag))).length * 0.5
      + row.author_keys.filter(author => author && candidate.author_keys.includes(author)).length;
    overlap += row.weight * shared;
  }
  const relevance = profile.empty ? 0.5 : 0.5 * topic + 0.3 * author + 0.2 * category + 0.1 * popular;
  const age = Math.max(0, (Date.parse(`${set.today}T00:00:00Z`) - Date.parse(`${candidate.announced_on}T00:00:00Z`)) / DAY);
  const fresh = 0.5 ** (age / 5);
  const lead = [...terms].filter(term => !isArea(term)).sort((a, b) => (profile.tags.get(b)?.weight ?? 0) - (profile.tags.get(a)?.weight ?? 0))[0]
    ?? candidate.categories[0] ?? '';
  return {
    candidate, topic, author, category, lead, primary: candidate.categories[0] ?? '',
    firstAuthor: candidate.author_keys.find(Boolean) ?? '',
    explore: !profile.empty && topic === 0 && author === 0 && candidate.matched_tags.length === 0,
    score: relevance * (0.4 + 0.6 * fresh) * Math.exp(-0.7 * overlap) + 0.03 * seeded(set.seed, candidate.source_id),
  };
}

function reasonFor(item: Scored, profile: Profile, cold: boolean, exploring: boolean): FeedReason {
  const c = item.candidate;
  if (exploring) {
    const name = categoryName(item.primary);
    return { kind: 'explore', label: item.primary, text: `Something different: ${name}` };
  }
  if (!cold) {
    // An author the reader has (or asked for more of).
    let best = -1, bestWeight = 0, library = false;
    for (let index = 0; index < c.author_keys.length; index++) {
      const known = c.author_keys[index] ? profile.authors.get(c.author_keys[index]) : undefined;
      if (known && known.weight >= 0.2 && known.weight > bestWeight) { best = index; bestWeight = known.weight; library = known.library; }
    }
    if (best >= 0 && c.authors[best]) {
      const name = c.authors[best];
      return { kind: 'author', label: name, text: library ? `By ${name}, an author in your library` : `By ${name}, an author of a paper you liked` };
    }
    // One of the reader's own tags.
    const own = [...c.matched_tags, ...c.topics].map(tag => profile.tags.get(key(tag))).find(tag => tag?.own);
    if (own) return { kind: 'tag', label: own.name, text: `In your tag: ${own.name}` };
    // A paper they marked More like this.
    const topics = new Set(c.topics.filter(tag => !isArea(tag)).map(key));
    const liked = profile.liked.map(row => ({ row, shared: row.topics.filter(tag => topics.has(key(tag))).length
      + row.author_keys.filter(author => author && c.author_keys.includes(author)).length }))
      .filter(entry => entry.shared > 0 && entry.row.title).sort((a, b) => b.shared - a.shared || b.row.weight - a.row.weight)[0];
    if (liked) return { kind: 'more_like', label: liked.row.title!, text: `More like “${short(liked.row.title!)}”` };
    // A library paper sharing its strongest topic.
    const shared = [...topics].sort((a, b) => (profile.tags.get(b)?.weight ?? 0) - (profile.tags.get(a)?.weight ?? 0));
    for (const topic of shared) {
      const paper = profile.papers.filter(p => p.title && !p.pending && p.tags.some(tag => key(tag) === topic))
        .sort((a, b) => Date.parse(b.added_at) - Date.parse(a.added_at))[0];
      if (paper) return { kind: 'added', label: paper.title!, text: `Because you added “${short(paper.title!)}”` };
    }
    if ((c.readers ?? 0) >= 3) return { kind: 'popular', label: String(c.readers), text: 'Added by several readers this week' };
  }
  const category = cold ? item.primary : c.categories.find(cat => profile.categories.has(cat)) ?? item.primary;
  return { kind: 'category', label: category, text: `New in ${categoryName(category)}` };
}

function year(sourceID: string): number | null {
  const modern = /^(\d{2})\d{2}\.\d{4,5}$/.exec(sourceID);
  if (modern) return 2000 + Number(modern[1]);
  const historic = /\/(\d{2})\d{5}$/.exec(sourceID);
  return historic ? (Number(historic[1]) >= 91 ? 1900 : 2000) + Number(historic[1]) : null;
}

/** Ranks For you: relevance × freshness, Not-interested penalty, a little daily variety; greedy
 * diversity by lead topic, first author and primary category; every fifth slot explores. */
export function rankForYou(set: CandidateSet, limit = 50): { results: ForYouResult[]; cold_start: boolean } {
  const profile = buildProfile(set);
  const cold = profile.empty;
  const scored = set.candidates.map(candidate => score(candidate, profile, set)).sort((a, b) => b.score - a.score);
  const main = scored.filter(item => !item.explore), explore = scored.filter(item => item.explore);
  const counts = { lead: new Map<string, number>(), author: new Map<string, number>(), primary: new Map<string, number>() };
  const adjusted = (item: Scored) => item.score * 0.8 ** (counts.lead.get(item.lead) ?? 0)
    * (item.firstAuthor ? 0.7 ** (counts.author.get(item.firstAuthor) ?? 0) : 1)
    * 0.9 ** Math.max(0, (counts.primary.get(item.primary) ?? 0) - 2);
  const take = (list: Scored[]): Scored | null => {
    if (!list.length) return null;
    let best = 0;
    for (let i = 1; i < list.length; i++) if (adjusted(list[i]) > adjusted(list[best])) best = i;
    return list.splice(best, 1)[0];
  };
  const results: ForYouResult[] = [];
  while (results.length < limit) {
    const exploring = !cold && (results.length + 1) % 5 === 0 && explore.length > 0;
    const item = exploring ? take(explore) : take(main) ?? take(explore);
    if (!item) break;
    for (const [map, value] of [[counts.lead, item.lead], [counts.author, item.firstAuthor], [counts.primary, item.primary]] as const) {
      if (value) map.set(value, (map.get(value) ?? 0) + 1);
    }
    const c = item.candidate;
    results.push({ source_id: c.source_id, revision: c.revision, title: c.title, authors: c.authors.slice(0, 12), year: year(c.source_id),
      abstract: c.abstract ? c.abstract.slice(0, 700) : null, categories: c.categories.slice(0, 12),
      reason: reasonFor(item, profile, cold, exploring), first_seen: c.first_seen_at, announced: c.announced_on });
  }
  return { results, cold_start: cold };
}

/** A category chip served from the pool (`worker_feed_category` rows) in the discover result shape. */
export function poolResult(row: { source_id: string; revision: number; title: string; authors: string[]; abstract: string | null;
  categories: string[]; announced_on: string; first_seen_at: string }) {
  return { source_id: row.source_id, revision: row.revision, title: row.title, authors: row.authors.slice(0, 12), year: year(row.source_id),
    abstract: row.abstract ? row.abstract.slice(0, 700) : null, categories: row.categories.slice(0, 12),
    first_seen: row.first_seen_at, announced: row.announced_on };
}
