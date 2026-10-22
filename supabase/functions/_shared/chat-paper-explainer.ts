// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer", docs/architecture/CHAT.md):
// on request from the paper's options, a page that prepares the reader for the whole paper: a short summary, the
// background it assumes (each concept one line, with the paragraphs that rely on it), the paper's own key ideas, and
// links between them that the device draws as one diagram of how the concepts fit together. Like the figure view it is
// a chat action on the reader's own model, tools, shared instructions and paper (so it reads the chat's cached prefix);
// the model writes one JSON object in its reply, read incrementally and relayed item by item, each checked exactly as
// the final explainer is. Deno and Node compatible.
import { EFFORTS } from './chat-profiles.ts';

export const PAPER_EXPLAINER_FORMAT = 'paper-explainer-v1';
export const PAPER_EXPLAINER_LIMITS = Object.freeze({ background: 10, ideas: 6, links: 24, summaryChars: 600, nameChars: 60, lineChars: 240,
  labelChars: 40, paragraphs: 6, items: 16 });
/** The explainer's output allowance: ~1,500 tokens written (measured), room to spare, plus the effort's thinking. */
export const PAPER_EXPLAINER_ANSWER_TOKENS = 3_500;
export function paperExplainerMaxTokens(effort: string): number {
  return PAPER_EXPLAINER_ANSWER_TOKENS + (EFFORTS.find(entry => entry.id === effort)?.thinkingTokens ?? 4_000);
}

export const PAPER_EXPLAINER_INSTRUCTIONS = `The reader opened the AI Explainer for this whole paper: a page that prepares them to read it, with the background it assumes and a diagram of how its ideas fit together. Write it as one JSON object in your reply and nothing else (no code fence, no words before or after it); call no tool and do not search the web:
{"items": 9, "summary": "…", "background": [{"id": "b1", "name": "…", "line": "…", "paragraphs": [N, …]}, …], "ideas": [{"id": "i1", "name": "…", "line": "…", "paragraphs": [N, …]}, …], "links": [{"from": "b1", "to": "i1", "label": "…"}, …]}
Write the fields in that order, each entry whole before the next: the reader sees each one as soon as it is written.
- items: how many background and idea entries you will write in all (the reader's progress bar).
- summary: two or three plain sentences: the problem, what the paper does about it, and its main result.
- background: the 4 to 8 prerequisite concepts a reader needs and the paper assumes or only briefly recalls (not the paper's own contributions), most fundamental first. name: the concept as it is commonly known, under 60 characters. line: one sentence, under 200 characters: what it is, then what this paper uses it for. Names are short (a concept, not a phrase joining two). paragraphs: the numbers N of the 1 to 4 [¶N] paragraphs where the paper relies on it, first use first.
- ideas: the paper's own 2 to 5 key ideas, with the same fields: its method or its parts in the order the paper builds them, and last its main result (what it showed, with the paper's headline number when it gives one).
- links: how they fit together, 4 to 14 arrows, each from a concept to what builds on it (background to idea, idea to idea, idea to result). label: 1 to 4 plain words saying how ("defines", "is replaced by", "optimises", "evaluated by"). Every id appears in at least one link.
Plain text in every string: no Markdown and no [¶N] markers (the paragraphs field carries them); math, if any, as \\\\( … \\\\) (escaped as JSON requires). Only what the paper supports; never invent results or numbers.`;

export type PaperExplainerKind = 'background' | 'idea';
export interface PaperExplainerItem { id: string; name: string; line: string; paragraphs: number[] }
export interface PaperExplainerLink { from: string; to: string; label: string }
export interface PaperExplainer { format: typeof PAPER_EXPLAINER_FORMAT; summary: string; background: PaperExplainerItem[]; ideas: PaperExplainerItem[]; links: PaperExplainerLink[] }

const scalars = (text: string) => [...text].length;
/** One line: control characters, Markdown emphasis and [¶N] markers out, white space collapsed, cut at the limit. */
function oneLine(value: unknown, limit: number): string {
  if (typeof value !== 'string') return '';
  const text = value.replace(/\[¶\d{1,6}\]/g, ' ').replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\*\*|__|`/g, '')
    .replace(/\s+/g, ' ').trim().replace(/\s+([.,;:])/g, '$1');
  return scalars(text) <= limit ? text : `${[...text].slice(0, limit - 1).join('').trimEnd()}…`;
}
const ID = /^[a-z0-9][a-z0-9_-]{0,31}$/;
function slug(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  if (ID.test(value)) return value;
  const made = value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32);
  return ID.test(made) ? made : null;
}

/** One entry of the model's input (untrusted), checked and bounded, or null when it has no name. `taken` holds the ids
 * already kept (a missing or repeated id gets the next free `b<n>`/`i<n>`); `renamed` records a model id that was
 * changed, so links naming it still resolve. The final explainer and the stream use this one check in order, so what a
 * device sees as items arrive is exactly the final explainer's entries. */
export function paperExplainerItem(raw: unknown, kind: PaperExplainerKind, paragraphs: number, taken: Set<string>,
  renamed: Map<string, string> = new Map()): PaperExplainerItem | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const v = raw as Record<string, unknown>;
  const name = oneLine(v.name, PAPER_EXPLAINER_LIMITS.nameChars);
  if (!name) return null;
  let id = slug(v.id);
  if (!id || taken.has(id)) {
    const prefix = kind === 'background' ? 'b' : 'i';
    let n = 1; while (taken.has(`${prefix}${n}`)) n++;
    id = `${prefix}${n}`;
  }
  if (typeof v.id === 'string' && v.id !== id && !renamed.has(v.id)) renamed.set(v.id, id);
  taken.add(id);
  const given = Array.isArray(v.paragraphs) ? (v.paragraphs as unknown[]).filter((n): n is number => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= paragraphs) : [];
  return { id, name, line: oneLine(v.line, PAPER_EXPLAINER_LIMITS.lineChars), paragraphs: [...new Set(given)].slice(0, PAPER_EXPLAINER_LIMITS.paragraphs) };
}
export const paperExplainerSummary = (value: unknown): string => oneLine(value, PAPER_EXPLAINER_LIMITS.summaryChars);

function links(raw: unknown, ids: Set<string>, renamed: Map<string, string>): PaperExplainerLink[] {
  const out: PaperExplainerLink[] = [], seen = new Set<string>();
  const ref = (value: unknown) => {
    if (typeof value !== 'string') return null;
    const id = renamed.get(value) ?? slug(value);
    return id && ids.has(id) ? id : null;
  };
  for (const entry of Array.isArray(raw) ? raw.slice(0, 64) : []) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) continue;
    const l = entry as Record<string, unknown>;
    const from = ref(l.from), to = ref(l.to);
    if (!from || !to || from === to || seen.has(`${from}>${to}`)) continue;
    seen.add(`${from}>${to}`);
    out.push({ from, to, label: oneLine(l.label, PAPER_EXPLAINER_LIMITS.labelChars) });
    if (out.length >= PAPER_EXPLAINER_LIMITS.links) break;
  }
  return out;
}

/** The model's explainer (untrusted: the paper can steer it), checked and bounded. Degrades rather than refuses: an
 * entry without a name is left out, a paragraph outside the paper is dropped, a link to an unknown id is dropped; the
 * first 10 background entries and 6 ideas are kept. Null when no entry is left. `paragraphs` is the paper's block count. */
export function paperExplainer(input: unknown, paragraphs: number): PaperExplainer | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  const taken = new Set<string>(), renamed = new Map<string, string>();
  const take = (raw: unknown, kind: PaperExplainerKind, limit: number) => {
    const out: PaperExplainerItem[] = [];
    for (const entry of Array.isArray(raw) ? raw.slice(0, 32) : []) {
      if (out.length >= limit) break;
      const item = paperExplainerItem(entry, kind, paragraphs, taken, renamed);
      if (item) out.push(item);
    }
    return out;
  };
  const background = take(v.background, 'background', PAPER_EXPLAINER_LIMITS.background);
  const ideas = take(v.ideas, 'idea', PAPER_EXPLAINER_LIMITS.ideas);
  if (!background.length && !ideas.length) return null;
  return { format: PAPER_EXPLAINER_FORMAT, summary: paperExplainerSummary(v.summary), background, ideas,
    links: links(v.links, new Set([...background, ...ideas].map(i => i.id)), renamed) };
}

/** The explainer as Markdown: what a reader still gets when it can't be shown as one (no usable entry, or only words). */
export function paperExplainerText(input: unknown, paragraphs: number): string {
  const checked = paperExplainer(input, paragraphs);
  if (!checked) return input && typeof input === 'object' && !Array.isArray(input) ? paperExplainerSummary((input as Record<string, unknown>).summary) : '';
  const list = (items: PaperExplainerItem[]) => items.map(i => `- **${i.name}**${i.line ? ` — ${i.line}` : ''}${i.paragraphs.length ? ` ${i.paragraphs.map(n => `[¶${n}]`).join(' ')}` : ''}`).join('\n');
  return [checked.summary, checked.background.length ? `**Background**\n\n${list(checked.background)}` : '',
    checked.ideas.length ? `**Key ideas**\n\n${list(checked.ideas)}` : ''].filter(Boolean).join('\n\n');
}

/** What the explainer's JSON yields as it arrives: the announced count, the summary once its string is complete, and each
 * entry once its object is complete and passes `paperExplainerItem` (`index` is its place among its kind's entries). */
export type PaperExplainerStreamItem = { kind: 'items'; items: number } | { kind: 'summary'; summary: string }
  | { kind: 'item'; section: PaperExplainerKind; index: number; item: PaperExplainerItem };

/** Reads the explainer's JSON incrementally (`{"items": N, "summary": "…", "background": [{…}], "ideas": [{…}], "links":
 * […]}`, keys in any order): a character scanner keeps the open containers, each object's current key and where the
 * values of interest started; a completed value is parsed from its own slice, so a malformed or cut-off entry yields
 * nothing (the final check still decides what the explainer is). As FigureWalkthroughStream (chat-figure-view.ts). */
export class PaperExplainerStream {
  private text = '';
  private at = 0;
  private inString = false;
  private escaped = false;
  private stringStart = -1;
  private stringIsKey = false;
  private readonly stack: { kind: '{' | '['; key: string | null; expectKey: boolean; start: number; role: PaperExplainerKind | 'list' | null; list?: PaperExplainerKind }[] = [];
  private closed = false;
  private objectStart = -1;
  private objectEnd = -1;
  private digits = '';
  private announced: number | null = null;
  private summarySent = false;
  private summaryText = '';
  private readonly taken = new Set<string>();
  private readonly renamed = new Map<string, string>();
  readonly background: PaperExplainerItem[] = [];
  readonly ideas: PaperExplainerItem[] = [];
  private readonly paragraphs: number;
  constructor(paragraphs: number) { this.paragraphs = paragraphs; }

  /** Characters of the object written so far (0 until it starts). */
  get length(): number { return this.objectStart < 0 ? 0 : (this.closed ? this.objectEnd : this.text.length) - this.objectStart; }
  /** The number of entries the model announced, when it did (1–16). */
  get items(): number | null { return this.announced || null; }
  get complete(): boolean { return this.closed; }
  /** Entries streamed so far (both kinds). */
  get count(): number { return this.background.length + this.ideas.length; }
  /** The explainer streamed so far, without links (a cut-off one keeps its complete entries); null before any entry. */
  explainer(): PaperExplainer | null {
    return this.count ? { format: PAPER_EXPLAINER_FORMAT, summary: this.summaryText, background: [...this.background], ideas: [...this.ideas], links: [] } : null;
  }

  push(chunk: string): PaperExplainerStreamItem[] {
    const out: PaperExplainerStreamItem[] = [];
    this.text += chunk;
    for (; this.at < this.text.length; this.at++) {
      const c = this.text[this.at];
      if (!this.stack.length && !this.inString) {
        if (c === '{' && !this.closed) { this.stack.push({ kind: '{', key: null, expectKey: true, start: this.at, role: null }); this.objectStart = this.at; }
        continue;
      }
      if (this.inString) {
        if (this.escaped) this.escaped = false;
        else if (c === '\\') this.escaped = true;
        else if (c === '"') { this.inString = false; this.endString(out); }
        continue;
      }
      const top = this.stack.at(-1);
      if (this.stack.length === 1 && top?.key === 'items' && !top.expectKey && this.announced === null) {
        if (c >= '0' && c <= '9' && this.digits.length < 3) { this.digits += c; continue; }
        if (this.digits) {
          const n = Number(this.digits);
          this.announced = n >= 1 && n <= PAPER_EXPLAINER_LIMITS.items ? n : 0;
          if (this.announced) out.push({ kind: 'items', items: n });
        }
      }
      if (c === '"') {
        this.inString = true; this.stringStart = this.at;
        this.stringIsKey = !!top && top.kind === '{' && top.expectKey;
      } else if (c === '{' || c === '[') {
        const list = c === '[' && this.stack.length === 1 && (top?.key === 'background' || top?.key === 'ideas')
          ? (top.key === 'background' ? 'background' : 'idea') as PaperExplainerKind : undefined;
        const role = list ? 'list' : c === '{' && top?.role === 'list' ? top.list! : null;
        this.stack.push({ kind: c, key: null, expectKey: c === '{', start: this.at, role, ...(list ? { list } : {}) });
      } else if (c === '}' || c === ']') {
        const kind = c === '}' ? '{' : '[';
        let closed = this.stack.pop();
        while (closed && closed.kind !== kind && this.stack.length) {
          if (closed.role === 'background' || closed.role === 'idea') this.endItem(closed.role, closed.start, out);
          closed = this.stack.pop();
        }
        if (closed?.role === 'background' || closed?.role === 'idea') this.endItem(closed.role, closed.start, out);
        if (!this.stack.length) { this.closed = true; this.objectEnd = this.at + 1; }
      } else if (c === ',' && top?.kind === '{') top.expectKey = true;
    }
    return out;
  }

  private endString(out: PaperExplainerStreamItem[]) {
    const top = this.stack.at(-1);
    if (!top || top.kind !== '{') return;
    let value: unknown;
    try { value = JSON.parse(this.text.slice(this.stringStart, this.at + 1)); } catch { return; }
    if (this.stringIsKey) { top.key = typeof value === 'string' ? value : null; top.expectKey = false; return; }
    if (this.stack.length === 1 && top.key === 'summary' && !this.summarySent) {
      this.summarySent = true;
      this.summaryText = paperExplainerSummary(value);
      if (this.summaryText) out.push({ kind: 'summary', summary: this.summaryText });
    }
  }

  private endItem(kind: PaperExplainerKind, start: number, out: PaperExplainerStreamItem[]) {
    const list = kind === 'background' ? this.background : this.ideas;
    if (list.length >= (kind === 'background' ? PAPER_EXPLAINER_LIMITS.background : PAPER_EXPLAINER_LIMITS.ideas)) return;
    let raw: unknown;
    try { raw = JSON.parse(this.text.slice(start, this.at + 1)); } catch { return; }
    const item = paperExplainerItem(raw, kind, this.paragraphs, this.taken, this.renamed);
    if (!item) return;
    list.push(item);
    out.push({ kind: 'item', section: kind, index: list.length - 1, item });
  }
}

/** The JSON object in a reply (the first `{` to the last `}`), or undefined when none parses. */
export function paperExplainerJSON(text: string): unknown {
  const start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return undefined;
  try { return JSON.parse(text.slice(start, end + 1)) as unknown; } catch { return undefined; }
}
