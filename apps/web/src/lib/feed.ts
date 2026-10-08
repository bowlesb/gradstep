// Feed: the newest arXiv submissions in the library's main categories (functions/v1/discover,
// a port of the native ReaderModel.feedCategories / ArxivTopics and BackendClient.feed).
import { tagsFromCategories } from '../../../../supabase/functions/_shared/tag-vocabulary.ts';
import { BackendError, functionGet } from './backend';
import type { Entry } from './library';

export interface DiscoveryResult { source_id: string; revision: number; title: string; authors: string[]; year: number | null; abstract: string | null; categories: string[] }

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
function decode(value: unknown): DiscoveryResult[] {
  const results = (value as { results?: unknown })?.results;
  if (!Array.isArray(results) || results.length > 200) throw new BackendError('invalid_response');
  return results.flatMap(r => {
    const v = r as Record<string, unknown>;
    if (!v || !bounded(v.source_id, 64) || !v.source_id || !bounded(v.title, 2000) || !v.title || !Number.isInteger(v.revision) || (v.revision as number) < 1
      || !Array.isArray(v.authors) || !v.authors.every(a => bounded(a, 256)) || !Array.isArray(v.categories) || !v.categories.every(c => bounded(c, 64))) return [];
    return [{ source_id: v.source_id, revision: v.revision as number, title: v.title.replace(/\s+/g, ' ').trim(), authors: (v.authors as string[]).slice(0, 64),
      year: Number.isInteger(v.year) ? v.year as number : null, abstract: bounded(v.abstract, 24_000) && v.abstract ? v.abstract.replace(/\s+/g, ' ').trim() : null,
      categories: (v.categories as string[]).slice(0, 16) }];
  });
}

export async function feed(account: string, category: string, signal?: AbortSignal): Promise<DiscoveryResult[]> {
  if (!CATEGORY.test(category)) throw new BackendError('invalid_category');
  return decode(await functionGet(`discover?category=${encodeURIComponent(category)}`, { account, signal, maximum: 524_288 }));
}
