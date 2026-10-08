// Feed: the newest arXiv submissions in the library's main categories (functions/v1/discover,
// a port of the native ReaderModel.feedCategories / ArxivTopics and BackendClient.feed).
import { tagsFromCategories } from '../../../../supabase/functions/_shared/tag-vocabulary.ts';
import { BackendError, functionGet, rpc } from './backend';
import { parseArxiv } from './arxiv';
import type { Entry } from './library';

export interface DiscoveryResult {
  source_id: string; revision: number; title: string; authors: string[]; year: number | null;
  abstract: string | null; abstractTruncated: boolean; categories: string[]; topics: string[];
  upvotes: number | null; reason: string | null; announced: string | null; firstSeen: string | null;
}
export type FeedSelection = 'for_you' | `category:${string}` | `topic:${string}`;
export interface FeedTopic { name: string; kind: 'combined' | 'topic' | 'own'; papers: number }
export interface FeedPage {
  results: DiscoveryResult[]; forYou: boolean; topics: FeedTopic[] | null;
  refreshedAt: string | null; coldStart: boolean;
}
export type FeedFeedback = 'not_interested' | 'more_like_this';

const CATEGORY = /^[a-z]{2,8}(-[a-z]{2,6})?(\.[A-Z]{2})?$/;
const FEED_NAMES: Record<string, string> = { 'cs.LG': 'Machine learning', 'cs.CL': 'Language', 'cs.AI': 'AI', 'cs.CV': 'Vision', 'stat.ML': 'Statistical ML',
  'cs.RO': 'Robotics', 'cs.NE': 'Neural computing', 'cs.IR': 'Retrieval', 'math.OC': 'Optimization', 'cs.CR': 'Security', 'cs.DC': 'Distributed' };
const NAMES: Record<string, string> = { ...FEED_NAMES, 'cs.CY': 'Computers and society', 'cs.DS': 'Algorithms', 'cs.GT': 'Game theory',
  'cs.HC': 'Human–computer interaction', 'cs.MA': 'Multi-agent systems', 'cs.SD': 'Sound', 'cs.SE': 'Software engineering', 'cs.SI': 'Social networks',
  'cs.PL': 'Programming languages', 'cs.NI': 'Networking', 'cs.DB': 'Databases', 'cs.GR': 'Graphics', 'cs.IT': 'Information theory', 'cs.LO': 'Logic',
  'cs.CC': 'Complexity', 'cs.CG': 'Computational geometry', 'cs.DM': 'Discrete math', 'cs.SY': 'Systems and control', 'cs.AR': 'Hardware',
  'stat.ME': 'Statistical methods', 'stat.TH': 'Statistics theory', 'stat.AP': 'Applied statistics', 'stat.CO': 'Computational statistics',
  'math.PR': 'Probability', 'math.ST': 'Statistics theory', 'math.NA': 'Numerical analysis', 'math.CO': 'Combinatorics', 'math.IT': 'Information theory',
  'math.DS': 'Dynamical systems', 'math.AP': 'PDEs', 'eess.AS': 'Audio and speech', 'eess.IV': 'Image and video', 'eess.SP': 'Signal processing',
  'eess.SY': 'Systems and control', 'q-bio.NC': 'Neuroscience', 'q-bio.QM': 'Quantitative biology', 'q-bio.GN': 'Genomics', 'econ.EM': 'Econometrics',
  'physics.comp-ph': 'Computational physics', 'quant-ph': 'Quantum physics', 'hep-th': 'High-energy theory', 'hep-ph': 'High-energy phenomenology',
  'gr-qc': 'Relativity and cosmology', 'astro-ph.CO': 'Cosmology', 'cond-mat.stat-mech': 'Statistical mechanics' };
const ARCHIVES: Record<string, string> = { cs: 'Computer science', stat: 'Statistics', math: 'Mathematics', eess: 'Electrical engineering', 'q-bio': 'Quantitative biology',
  'q-fin': 'Quantitative finance', econ: 'Economics', physics: 'Physics', 'cond-mat': 'Condensed matter', 'astro-ph': 'Astrophysics' };
const CORE = new Set(['cs.LG', 'cs.CL', 'cs.AI', 'cs.CV', 'stat.ML', 'cs.NE', 'cs.RO', 'cs.IR']);

/** A category's friendly name: the tag vocabulary's, then the Feed's labels, then its archive. */
export function topicName(category: string): string {
  const tag = tagsFromCategories([category], 1)[0];
  if (tag) return tag;
  if (NAMES[category]) return NAMES[category];
  const archive = category.split('.')[0];
  return (category.includes('.') && ARCHIVES[archive]) || ARCHIVES[category] || category;
}

/** At most six topics from the library's arXiv categories: two papers each unless core ML; the most frequent first; one per name. */
export function feedCategories(entries: Iterable<Entry>): string[] {
  const counts = new Map<string, number>();
  for (const e of entries) if (e.kind === 'item' && e.visible) for (const c of e.metadata?.categories ?? []) if (CATEGORY.test(c)) counts.set(c, (counts.get(c) ?? 0) + 1);
  const names = new Set<string>(), top: string[] = [];
  for (const [category] of [...counts].filter(([c, n]) => n >= 2 || CORE.has(c)).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))) {
    const name = topicName(category);
    if (names.has(name)) continue;
    names.add(name); top.push(category);
    if (top.length === 6) break;
  }
  return top.length ? top : ['cs.LG', 'cs.CL', 'cs.AI', 'cs.CV'];
}

const bounded = (v: unknown, max: number): v is string => typeof v === 'string' && v.length <= max;
const clean = (v: unknown, max: number): string | null => bounded(v, max) && !/[\u0000-\u001f\u007f-\u009f]/.test(v) ? v.trim() || null : null;
const texts = (v: unknown, count: number, length: number): string[] => Array.isArray(v)
  ? [...new Set(v.slice(0, count).flatMap(x => clean(x, length) ?? []))] : [];
const date = (v: unknown): string | null => bounded(v, 40) && /^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2}))?$/.test(v) && Number.isFinite(Date.parse(v)) ? v : null;

/** Additive server fields are optional. Unsafe paper identities never become links or Add commands. */
export function decodeFeed(value: unknown): FeedPage {
  const results = (value as { results?: unknown })?.results;
  if (!Array.isArray(results) || results.length > 200) throw new BackendError('invalid_response');
  const seen = new Set<string>();
  const papers = results.flatMap(r => {
    const v = r as Record<string, unknown>;
    if (!v || !bounded(v.source_id, 64) || !v.source_id || !bounded(v.title, 2000) || !v.title || !Number.isInteger(v.revision) || (v.revision as number) < 1
      || !Array.isArray(v.authors) || !v.authors.every(a => bounded(a, 256)) || !Array.isArray(v.categories) || !v.categories.every(c => bounded(c, 64))) return [];
    const identity = parseArxiv(v.source_id);
    if (!identity || identity.sourceID !== v.source_id || identity.revision !== null || seen.has(identity.sourceID)) return [];
    seen.add(identity.sourceID);
    const abstract = bounded(v.full_abstract, 24_000) ? v.full_abstract : bounded(v.abstract, 2000) ? v.abstract : null;
    const reason = v.reason as { text?: unknown } | undefined;
    return [{ source_id: v.source_id, revision: v.revision as number, title: v.title.replace(/\s+/g, ' ').trim(), authors: (v.authors as string[]).slice(0, 64),
      year: Number.isInteger(v.year) && (v.year as number) >= 1900 && (v.year as number) <= 9999 ? v.year as number : null, abstract: abstract?.replace(/\s+/g, ' ').trim() || null,
      abstractTruncated: v.abstract_truncated === true || (!bounded(v.full_abstract, 24_000) && (abstract?.length ?? 0) >= 700),
      categories: (v.categories as string[]).filter(c => CATEGORY.test(c)).slice(0, 16), topics: texts(v.topics, 4, 80),
      upvotes: Number.isSafeInteger(v.upvotes) && (v.upvotes as number) >= 0 ? v.upvotes as number : null,
      reason: clean(reason?.text, 600), announced: date(v.announced), firstSeen: date(v.first_seen) }];
  });
  const info = (value as { feed?: Record<string, unknown> }).feed;
  const forYou = info?.for_you === true;
  const topicNames = new Set<string>();
  const topics: FeedTopic[] | null = forYou && Array.isArray(info.topics) ? info.topics.slice(0, 8).flatMap(v => {
    const name = clean(v?.name, 40);
    if (!name || topicNames.has(name) || !['combined', 'topic', 'own'].includes(v.kind) || !Number.isSafeInteger(v.papers) || v.papers < 0) return [];
    topicNames.add(name); return [{ name, kind: v.kind as FeedTopic['kind'], papers: v.papers }];
  }) : null;
  return { results: papers, forYou, topics, refreshedAt: date(info?.refreshed_at), coldStart: info?.cold_start === true };
}

export const selectionName = (selection: FeedSelection) => selection === 'for_you' ? 'For you'
  : selection.startsWith('category:') ? topicName(selection.slice(9)) : selection.slice(6);
export const personalFeed = (selection: FeedSelection) => !selection.startsWith('category:');
export const resultTopics = (paper: DiscoveryResult) => paper.topics.length ? paper.topics : [...new Set(paper.categories.map(topicName))].slice(0, 2);

export async function feedPage(account: string, selection: FeedSelection, signal?: AbortSignal): Promise<FeedPage> {
  const query = new URLSearchParams({ abstract: 'full' });
  if (selection === 'for_you') query.set('feed', 'for_you');
  else if (selection.startsWith('category:') && CATEGORY.test(selection.slice(9))) query.set('category', selection.slice(9));
  else if (selection.startsWith('topic:') && clean(selection.slice(6), 40)) {
    query.set('feed', 'topic'); query.set('topic', selection.slice(6));
  } else throw new BackendError('invalid_category');
  return decodeFeed(await functionGet(`discover?${query}`, { account, signal, maximum: 4_194_304 }));
}

export async function feed(account: string, category: string, signal?: AbortSignal): Promise<DiscoveryResult[]> {
  return (await feedPage(account, `category:${category}`, signal)).results;
}

export async function recordFeedFeedback(account: string, source: string, kind: FeedFeedback | null, signal?: AbortSignal) {
  if (parseArxiv(source)?.sourceID !== source) throw new BackendError('invalid_feed_feedback');
  const response = await rpc<{ source_id: string; kind: FeedFeedback | null }>('v1_feed_feedback', { p_source_id: source, p_kind: kind }, { account, signal });
  if (response?.source_id !== source || response.kind !== kind) throw new BackendError('invalid_response');
}

/** Native FeedFormat parity: submission month/serial, never an invented publication day. */
export function arxivMonth(source: string): { year: number; month: number; serial: number } | null {
  const id = parseArxiv(source)?.sourceID;
  if (!id) return null;
  const digits = id.includes('/') ? id.split('/')[1] : id.replace('.', '');
  const yy = Number(digits.slice(0, 2));
  return { year: yy >= 91 ? 1900 + yy : 2000 + yy, month: Number(digits.slice(2, 4)), serial: Number(digits.slice(4)) };
}
export function published(paper: DiscoveryResult): string {
  const value = arxivMonth(paper.source_id);
  return value ? new Intl.DateTimeFormat(undefined, { month: 'short', year: 'numeric', timeZone: 'UTC' }).format(Date.UTC(value.year, value.month - 1, 15)) : String(paper.year ?? '—');
}
export type FeedSort = 'suggested' | 'newest' | 'popularity' | 'title' | 'authors' | 'topic';
export function orderFeed(results: DiscoveryResult[], sort: FeedSort, ascending = false): DiscoveryResult[] {
  if (sort === 'suggested') return results;
  const value = (p: DiscoveryResult): number | string | null => {
    if (sort === 'popularity') return p.upvotes;
    if (sort === 'title') return p.title;
    if (sort === 'authors') return p.authors[0]?.trim().split(/\s+/).pop() ?? null;
    if (sort === 'topic') return resultTopics(p)[0] ?? null;
    const month = arxivMonth(p.source_id);
    return month ? (month.year * 100 + month.month) * 100_000 + month.serial : p.year === null ? null : p.year * 10_000_000;
  };
  return results.map((paper, index) => ({ paper, index, value: value(paper) })).sort((a, b) => {
    if (a.value === null || b.value === null) return a.value === b.value ? a.index - b.index : a.value === null ? 1 : -1;
    const difference = typeof a.value === 'number' && typeof b.value === 'number' ? a.value - b.value : String(a.value).localeCompare(String(b.value));
    return (ascending ? difference : -difference) || a.index - b.index;
  }).map(r => r.paper);
}
