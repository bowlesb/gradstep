// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): the background a paper
// assumes, its key ideas and how they fit together, on request from the paper's options. The server streams it
// (`paper_progress`, `paper_summary`, `paper_item`, then the whole `paper_explainer`; supabase/functions/_shared/
// chat-paper-explainer.ts); this module checks those events again (untrusted), draws the diagram's Mermaid source and
// computes the progress bar. The apps' `PaperExplainer` (ScienceReaderCore) reproduces the same Mermaid source and
// progress values: both test against tests/fixtures/paper-explainer.json.

export const PAPER_EXPLAINER_FORMAT = 'paper-explainer-v1';
export type PaperExplainerKind = 'background' | 'idea';
export interface PaperExplainerItem { id: string; name: string; line: string; paragraphs: number[] }
export interface PaperExplainerLink { from: string; to: string; label: string }
export interface PaperExplainer { format: typeof PAPER_EXPLAINER_FORMAT; summary: string; background: PaperExplainerItem[]; ideas: PaperExplainerItem[]; links: PaperExplainerLink[] }

const LIMITS = Object.freeze({ background: 10, ideas: 6, links: 24, summary: 600, name: 60, line: 240, label: 40, paragraphs: 6 });
const ID = /^[a-z0-9][a-z0-9_-]{0,31}$/;
function text(value: unknown, limit: number): string | null {
  if (typeof value !== 'string') return null;
  const t = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim();
  return [...t].length <= limit ? t : null;
}

/** One entry from an event (untrusted): null when it has no usable id or name. Paragraphs outside 1…`paragraphs` are
 * dropped (the device knows its paper's block count; 100,000 when it doesn't). */
export function parsePaperItem(input: unknown, paragraphs = 100_000): PaperExplainerItem | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  const id = typeof v.id === 'string' && ID.test(v.id) ? v.id : null, name = text(v.name, LIMITS.name);
  if (!id || !name) return null;
  const numbers = Array.isArray(v.paragraphs) ? v.paragraphs.filter((n): n is number => Number.isSafeInteger(n) && n >= 1 && n <= paragraphs) : [];
  return { id, name, line: text(v.line, LIMITS.line) ?? '', paragraphs: [...new Set(numbers)].slice(0, LIMITS.paragraphs) };
}

/** The final `paper_explainer` event (untrusted), checked as the server checks it: entries without an id or name and
 * links to unknown ids are dropped; null when no entry is left or the format is unknown. */
export function parsePaperExplainer(input: unknown, paragraphs = 100_000): PaperExplainer | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  if (v.format !== PAPER_EXPLAINER_FORMAT) return null;
  const seen = new Set<string>();
  const items = (raw: unknown, limit: number) => (Array.isArray(raw) ? raw : []).map(i => parsePaperItem(i, paragraphs))
    .filter((i): i is PaperExplainerItem => !!i && !seen.has(i.id) && !!seen.add(i.id)).slice(0, limit);
  const background = items(v.background, LIMITS.background), ideas = items(v.ideas, LIMITS.ideas);
  if (!background.length && !ideas.length) return null;
  const ids = new Set([...background, ...ideas].map(i => i.id)), pairs = new Set<string>();
  const links = (Array.isArray(v.links) ? v.links : []).flatMap(raw => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return [];
    const l = raw as Record<string, unknown>;
    if (typeof l.from !== 'string' || typeof l.to !== 'string' || !ids.has(l.from) || !ids.has(l.to) || l.from === l.to || pairs.has(`${l.from}>${l.to}`)) return [];
    pairs.add(`${l.from}>${l.to}`);
    return [{ from: l.from, to: l.to, label: text(l.label, LIMITS.label) ?? '' }];
  }).slice(0, LIMITS.links);
  return { format: PAPER_EXPLAINER_FORMAT, summary: text(v.summary, LIMITS.summary) ?? '', background, ideas, links };
}

/** The diagram of how the paper's concepts fit together: a top-down Mermaid flowchart drawn by the app's own sandboxed
 * diagram renderer (strict mode, no network). Background concepts and the paper's own ideas are styled apart; labels are
 * quoted and stripped of the characters Mermaid reads as syntax; node ids are prefixed so none is a keyword. Empty when
 * the explainer has no entries. */
export function paperExplainerMermaid(e: Pick<PaperExplainer, 'background' | 'ideas' | 'links'>): string {
  if (!e.background.length && !e.ideas.length) return '';
  const node = (id: string) => `n_${id.replace(/[^a-z0-9_]/g, '_')}`;
  const lines = ['flowchart TD'];
  for (const b of e.background) lines.push(`  ${node(b.id)}["${mermaidLabel(b.name, 48)}"]:::background`);
  for (const i of e.ideas) lines.push(`  ${node(i.id)}["${mermaidLabel(i.name, 48)}"]:::idea`);
  for (const l of e.links) {
    const label = mermaidLabel(l.label, 32, '');
    lines.push(label ? `  ${node(l.from)} -->|"${label}"| ${node(l.to)}` : `  ${node(l.from)} --> ${node(l.to)}`);
  }
  lines.push('  classDef background fill:#eef1f8,stroke:#7a86a8,color:#1b1b1b',
    '  classDef idea fill:#fff1d6,stroke:#c98a12,color:#1b1b1b');
  return lines.join('\n');
}
/** A label Mermaid draws as written: no quotes, brackets, pipes or other syntax characters; at most `max` characters
 * (cut with "…"). */
export function mermaidLabel(value: string, max: number, fallback = 'concept'): string {
  const t = value.replace(/["\\[\]{}()<>|#;`]/g, ' ').replace(/\s+/g, ' ').trim();
  const scalars = [...t];
  return (scalars.length > max ? `${scalars.slice(0, max - 1).join('').trimEnd()}…` : t) || fallback;
}

/** The explainer as plain text: what "Open in Chat" carries into the conversation and what a copy holds. */
export function paperExplainerText(e: Pick<PaperExplainer, 'summary' | 'background' | 'ideas'>): string {
  const list = (items: PaperExplainerItem[]) => items.map(i => `- ${i.name}${i.line ? `: ${i.line}` : ''}`).join('\n');
  return [e.summary, e.background.length ? `Background:\n${list(e.background)}` : '', e.ideas.length ? `Key ideas:\n${list(e.ideas)}` : '']
    .filter(Boolean).join('\n\n');
}

// The progress bar (the figure explainer's rules, FIGURE_VIEW.md "Speed"): a stage label always; a determinate value only
// while the number of entries the model announced (`items`) is known and not yet reached; never backwards; past the
// estimate (the links, or more entries than announced) it turns indeterminate until the explainer is done.

export type PaperProgressStage = 'preparing' | 'reading' | 'writing' | 'done';
export interface PaperProgressInput {
  stage: PaperProgressStage;
  /** The summary has arrived. */
  summary: boolean;
  /** Entries (background and ideas) that have arrived. */
  items: number;
  /** Of those, ideas (the paper writes its background first). */
  ideas: number;
  /** The explainer's characters written so far (the latest `paper_progress`), 0 before any. */
  characters: number;
  /** `characters` when the summary or the latest entry arrived. */
  charactersAtLast: number;
  /** How many entries the model announced, when it has; null when not. */
  expected: number | null;
  /** The value last shown; null when it was indeterminate or nothing was shown. */
  previous: number | null;
}
export interface PaperProgressState { label: string; value: number | null }
/** Measured on the evaluation papers (Gemini 3.8 Flash at low and Sonnet 5.5, 2026-10-22): the summary's JSON about 500
 * characters, an entry's about 280. */
export const PAPER_PROGRESS = Object.freeze({ summaryChars: 500, itemChars: 280, summaryShare: 0.1, itemsShare: 0.85, itemCap: 0.9 });

export function paperExplainerProgress(input: PaperProgressInput): PaperProgressState {
  const p = PAPER_PROGRESS;
  switch (input.stage) {
    case 'preparing': return { label: 'Preparing the paper…', value: null };
    case 'reading': return { label: 'Reading the paper…', value: null };
    case 'done': return { label: 'Done', value: 1 };
    default: break;
  }
  const n = input.expected;
  const inSummary = !input.summary && input.items === 0;
  const known = n != null && n >= 1 && input.items < n;
  const where = input.ideas > 0 ? 'the key ideas' : 'the background';
  const label = inSummary ? 'Writing the summary…'
    : n != null && input.items >= n ? 'Drawing how it fits together…'
    : known ? `Writing ${where}, ${input.items + 1} of ${n}…` : `Writing ${where}…`;
  if (!known) return { label, value: null };
  const current = Math.max(0, input.characters - input.charactersAtLast);
  const value = inSummary ? p.summaryShare * Math.min(p.itemCap, current / p.summaryChars)
    : p.summaryShare + p.itemsShare * (input.items + Math.min(p.itemCap, current / p.itemChars)) / n!;
  return { label, value: round(Math.min(1, Math.max(input.previous ?? 0, value))) };
}
const round = (v: number) => Math.round(v * 10_000) / 10_000;

// ---------- A request and its result (ChatSession.paperExplainer) ----------

/** The explainer's one user turn. */
export const PAPER_EXPLAINER_TURN = 'Explain this paper';
/** Where a streamed explainer is, for the progress bar (only while loading, never kept). */
export interface PaperStreamProgress { stage: PaperProgressStage; summary: boolean; items: number; ideas: number; characters: number; charactersAtLast: number; announced: number | null }
/** One explainer request: what streamed so far (the summary and entries as they arrive, links once whole), or the model's
 * words when it wrote no usable explainer; kept per paper revision and model once done. */
export interface PaperExplainerResult {
  phase: 'loading' | 'done' | 'failed'; explainer: PaperExplainer | null; text: string; issue: string | null; credits: number | null;
  model?: string; charged?: boolean; reason?: string; progress?: PaperStreamProgress;
}
/** The kept result's key: the paper's bundle and the model/effort/length it was asked with. */
export const paperExplainerKey = (manifest: string, profile: string) => `${manifest}|paper_explainer|${profile}`;
