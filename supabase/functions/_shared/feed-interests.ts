// The Feed's topic chips (docs/architecture/PERSONALIZED_FEED.md, "Specific topics"; owner feedback on
// build 21: "Machine learning and artificial intelligence are too generic, it needs to be specific to the
// individual tastes and their nuances"). Chips are the reader's own interests, read from what the server
// already holds for their library — catalog tags, their own tags, More like this — and ordered by how much
// those papers weigh, discounted when a topic covers a large share of the pool. Broad category areas
// ("Machine learning") are never chips; they stay under "More topics". A few curated combinations of
// vocabulary tags ("RL for reasoning") give names more specific than any single tag. No model is called.
// Pure (Deno + Node); `worker_feed_candidates_v2` (migration 048) supplies the pool counts.
import { isArea, isBroadArea } from './feed-topics.ts';
import { paperWeight, type CandidateSet } from './feed-rank.ts';
import { vocabularyName } from './tag-vocabulary.ts';

/** A named combination of vocabulary tags: every tag in `all`, and (when given) at least one in `any`. */
export interface CompoundTopic { name: string; all: string[]; any: string[] }

/** Curated combinations, named the way researchers say them. Each is checked against the vocabulary
 * (a backend test), and a name never repeats a vocabulary tag. Adding one is free: chips use it once a
 * reader has at least two papers with it. */
export const COMPOUND_TOPICS: readonly CompoundTopic[] = Object.freeze([
  { name: 'RL for reasoning', all: ['Reasoning'], any: ['Reinforcement learning', 'Policy optimization', 'Reward modeling'] },
  { name: 'Multimodal reasoning', all: ['Reasoning'], any: ['Vision-language models', 'Multimodal learning'] },
  { name: 'Diffusion language models', all: ['Diffusion models'], any: ['Large language models', 'Natural language processing'] },
  { name: 'Diffusion policies', all: ['Diffusion models'], any: ['Robotics', 'Imitation learning', 'Embodied AI'] },
  { name: 'Robot foundation models', all: ['Robotics'], any: ['Vision-language models', 'Large language models'] },
  { name: 'Coding agents', all: ['Code generation', 'AI agents'], any: [] },
  { name: 'Agent safety', all: ['AI agents'], any: ['AI safety', 'Red teaming', 'Security', 'Alignment'] },
  { name: 'Agentic RAG', all: ['Retrieval-augmented generation', 'AI agents'], any: [] },
  { name: 'LLM multi-agent systems', all: ['Multi-agent systems', 'Large language models'], any: [] },
  { name: 'Efficient long context', all: ['Long context'], any: ['Efficient inference', 'State space models'] },
  { name: 'Speech language models', all: ['Speech and audio', 'Large language models'], any: [] },
  { name: 'Medical imaging', all: ['Healthcare and medicine'], any: ['Computer vision', 'Segmentation', 'Object detection'] },
  { name: 'Graph transformers', all: ['Transformers'], any: ['Graph neural networks', 'Graph learning'] },
  { name: 'Video world models', all: ['World models'], any: ['Video generation', 'Video understanding'] },
  { name: '3D generation', all: ['3D vision'], any: ['Diffusion models', 'Image generation', 'Neural rendering'] },
] satisfies CompoundTopic[]);

// A library paper's catalog tags come from a model that may name only the narrower tag; for matching
// combinations, a narrower tag implies its broader one (both sides of the pool rules do this already).
const IMPLIES: Record<string, string[]> = {
  'Mathematical reasoning': ['Reasoning'],
  'Policy optimization': ['Reinforcement learning'],
  'Offline reinforcement learning': ['Reinforcement learning'],
  'Model-based reinforcement learning': ['Reinforcement learning'],
  'Mechanistic interpretability': ['Interpretability'],
  'Vision-language models': ['Multimodal learning'],
  'Graph neural networks': ['Graph learning'],
};

/** Pool counts for one For you request (`worker_feed_candidates_v2` → `topics`). */
export interface TopicStats { tags: Record<string, number>; own: Record<string, number>; compounds: Record<string, number> }
export type InterestKind = 'topic' | 'own' | 'combined';
export interface InterestTopic { name: string; kind: InterestKind; papers: number }

export const MAX_CHIPS = 8;
/** A topic on more than this share of the window's papers is too general to be a chip. */
export const MAX_SHARE = 0.2;
/** A chip needs this many papers to show. */
export const MIN_PAPERS = 2;

const key = (tag: string) => tag.toLowerCase();
const generic = new Set(['to read', 'read later', 'read', 'reading', 'important', 'favorite', 'favorites', 'todo', 'to do', 'later', 'reviewed',
  'review', 'starred', 'misc', 'other', 'paper', 'papers', 'work', 'thesis']);
/** Personal tags that organize rather than describe ("to read"); the database ignores the same list. */
export function isGenericTag(tag: string): boolean { return !/\p{L}/u.test(tag) || generic.has(key(tag.trim())); }

/** How specific a topic is from its share of the pool: 1 at 1 % or less, 0.35 at 20 %. */
export function specificity(share: number): number {
  if (!(share > 0)) return 1;
  return Math.min(1, Math.max(0.35, Math.log(1 / share) / Math.log(100)));
}

function expanded(tags: readonly string[]): Set<string> {
  const result = new Set(tags.map(key));
  for (const tag of tags) for (const implied of IMPLIES[vocabularyName(tag) ?? ''] ?? []) result.add(key(implied));
  return result;
}

function satisfies(tags: Set<string>, compound: CompoundTopic): boolean {
  return compound.all.every(tag => tags.has(key(tag))) && (!compound.any.length || compound.any.some(tag => tags.has(key(tag))));
}

/** The combinations as `worker_feed_candidates_v2` takes them. */
export function compoundsParameter(): { name: string; all: string[]; any: string[] }[] {
  return COMPOUND_TOPICS.map(({ name, all, any }) => ({ name, all: [...all], any: [...any] }));
}

/** The reader's topic chips, most interesting first: at most `limit`, each with at least two eligible
 * pool papers and two library papers (or a tag the reader gave, or More like this). */
export function interestTopics(set: CandidateSet, stats: TopicStats | null | undefined, limit = MAX_CHIPS): InterestTopic[] {
  if (!stats) return [];
  const pool = Math.max(1, set.pool);
  const now = Date.parse(set.now);
  interface Interest { name: string; weight: number; papers: number; own: boolean; liked: boolean }
  const tags = new Map<string, Interest>(), compounds = new Map<string, Interest>();
  const note = (map: Map<string, Interest>, name: string, weight: number, flags: { own?: boolean; liked?: boolean } = {}) => {
    const known = map.get(key(name));
    map.set(key(name), { name: flags.own || !known ? name : known.name, weight: (known?.weight ?? 0) + weight, papers: (known?.papers ?? 0) + 1,
      own: (known?.own ?? false) || !!flags.own, liked: (known?.liked ?? false) || !!flags.liked });
  };
  for (const paper of set.profile) {
    const weight = paperWeight(paper, set.now);
    const own = new Set(paper.own_tags.map(key));
    for (const tag of new Set(paper.tags)) note(tags, vocabularyName(tag) ?? tag, weight * (own.has(key(tag)) ? 1.5 : 1), { own: own.has(key(tag)) });
    const all = expanded(paper.tags);
    for (const compound of COMPOUND_TOPICS) if (satisfies(all, compound)) note(compounds, compound.name, weight);
  }
  for (const row of set.feedback) {
    if (row.kind !== 'more_like_this') continue;
    const weight = 1.5 * Math.exp(-Math.max(0, (now - Date.parse(row.created_at)) / 86_400_000) / 90);
    for (const tag of new Set(row.topics)) note(tags, vocabularyName(tag) ?? tag, weight, { liked: true });
    const all = expanded(row.topics);
    for (const compound of COMPOUND_TOPICS) if (satisfies(all, compound)) note(compounds, compound.name, weight, { liked: true });
  }
  const counts = (record: Record<string, number> | undefined) => new Map(Object.entries(record ?? {}).map(([name, n]) => [key(name), Number(n) || 0]));
  const tagCounts = counts(stats.tags), ownCounts = counts(stats.own), compoundCounts = counts(stats.compounds);
  interface Chip extends InterestTopic { score: number; weight: number }
  const chips: Chip[] = [];
  const evidence = (interest: Interest) => interest.papers >= MIN_PAPERS || interest.own || interest.liked;
  for (const interest of tags.values()) {
    const vocabulary = vocabularyName(interest.name);
    if (vocabulary ? isBroadArea(vocabulary) : isGenericTag(interest.name)) continue;
    if (!evidence(interest)) continue;
    const papers = (vocabulary ? tagCounts : ownCounts).get(key(interest.name)) ?? 0;
    if (papers < MIN_PAPERS || papers / pool > MAX_SHARE) continue;
    chips.push({ name: vocabulary ?? interest.name, kind: vocabulary ? 'topic' : 'own', papers, weight: interest.weight,
      score: interest.weight * specificity(papers / pool) * (vocabulary && isArea(vocabulary) ? 0.5 : 1) });
  }
  for (const interest of compounds.values()) {
    const papers = compoundCounts.get(key(interest.name)) ?? 0;
    if (!evidence(interest) || papers < MIN_PAPERS || papers / pool > MAX_SHARE) continue;
    chips.push({ name: interest.name, kind: 'combined', papers, weight: interest.weight, score: interest.weight * specificity(papers / pool) });
  }
  chips.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  // A combination usually explains its parts: a part whose papers are mostly the combination's goes.
  const combined = chips.filter(chip => chip.kind === 'combined');
  const kept = chips.filter(chip => chip.kind !== 'topic' || !combined.some(c => {
    const compound = COMPOUND_TOPICS.find(entry => entry.name === c.name)!;
    return [...compound.all, ...compound.any].some(part => key(part) === key(chip.name)) && chip.weight <= 1.25 * c.weight;
  }));
  return kept.slice(0, limit).map(({ name, kind, papers }) => ({ name, kind, papers }));
}

/** What a topic chip asks the database for: a combination or a vocabulary tag by name, else one of the
 * reader's own tags as a phrase (the database checks it is theirs). Null for text that cannot be a tag. */
export type TopicQuery = { kind: 'combined' | 'topic'; name: string; all: string[]; any: string[] } | { kind: 'own'; name: string; phrase: string };
export function resolveTopic(raw: string): TopicQuery | null {
  const name = raw.normalize('NFC').replace(/\s+/g, ' ').trim();
  if (!name || [...name].length > 40 || new TextEncoder().encode(name).length > 120 || /\p{Cc}/u.test(name)) return null;
  const compound = COMPOUND_TOPICS.find(entry => key(entry.name) === key(name));
  if (compound) return { kind: 'combined', name: compound.name, all: [...compound.all], any: [...compound.any] };
  const vocabulary = vocabularyName(name);
  if (vocabulary) return { kind: 'topic', name: vocabulary, all: [vocabulary], any: [] };
  if (isGenericTag(name)) return null;
  return { kind: 'own', name, phrase: name };
}
