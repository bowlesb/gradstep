// "Go deeper" on one Key concept of the paper's AI Explainer (2026-10-25; docs/JUDGMENT_LOG.md 27, docs/architecture/CHAT.md
// "Go deeper on a key concept"). Owner, TestFlight 93: "an option for users to request more elaboration on each concept,
// and then another screen in front". One concept, explained in this paper's context: what it is, why the paper needs it,
// an intuition or small worked example, how the paper uses it, and where it appears (paragraph by paragraph). Like the
// paper's explainer it is a chat action on the reader's own model, tools, shared instructions and paper, so it reads the
// chat's cached prefix and only these instructions and the concept follow the paper. The model writes one JSON object in
// its reply, read incrementally (json-list-stream.ts) and relayed section by section, each checked exactly as the final
// concept is: a [¶N] the paper doesn't have is removed, a place outside the paper is dropped. Deno and Node compatible.
import { EFFORTS } from './chat-profiles.ts';
import { JsonListStream } from './json-list-stream.ts';

export const PAPER_CONCEPT_FORMAT = 'paper-concept-v1';
export const PAPER_CONCEPT_LIMITS = Object.freeze({ sections: 6, textChars: 1_500, titleChars: 60, places: 6, noteChars: 160, paragraphs: 8 });
/** The concept's output allowance: about 1,000–1,300 tokens written (four sections and the places), room to spare, plus
 * the effort's thinking. */
export const PAPER_CONCEPT_ANSWER_TOKENS = 3_000;
export function paperConceptMaxTokens(effort: string): number {
  return PAPER_CONCEPT_ANSWER_TOKENS + (EFFORTS.find(entry => entry.id === effort)?.thinkingTokens ?? 4_000);
}

export const PAPER_CONCEPT_KINDS = ['what', 'why', 'example', 'paper', 'where'] as const;
export type PaperConceptKind = typeof PAPER_CONCEPT_KINDS[number];
/** A section's title when the model gives none. */
export const PAPER_CONCEPT_TITLES: Readonly<Record<PaperConceptKind, string>> = Object.freeze({
  what: 'What it is', why: 'Why this paper needs it', example: 'An intuition', paper: 'How the paper uses it', where: 'Where it appears' });

export const PAPER_CONCEPT_INSTRUCTIONS = `The reader is reading this paper's AI Explainer and asked to go deeper on one of its key concepts. The <selected_passage> block names it: its name, whether it is background the paper assumes or one of the paper's own ideas, the explainer's one line about it, and the paragraphs the explainer linked to it. Explain that concept in the context of this paper, for a reader meeting it for the first time. Write it as one JSON object in your reply and nothing else (no code fence, no words before or after it); call no tool and do not search the web:
{"parts": 5, "sections": [{"kind": "what", "title": "What it is", "text": "…"}, {"kind": "why", "title": "Why this paper needs it", "text": "…"}, {"kind": "example", "title": "A small example", "text": "…"}, {"kind": "paper", "title": "How the paper uses it", "text": "…"}, {"kind": "where", "title": "Where it appears", "places": [{"paragraph": N, "note": "…"}, …]}]}
First "parts", the number of sections you will write (the reader's progress bar), then each section whole before the next, in that order: the reader sees each one as soon as it is written.
- what: what the concept is, plainly, in two to four sentences, defining any term it relies on. For one of the paper's own ideas: what the paper proposes, in its own terms.
- why: why this paper needs it: the problem it addresses here, or the step of the paper that depends on it.
- example: one intuition or one small worked example (a toy case with a few concrete numbers, or an accurate everyday analogy) that makes it click; title it "A small example" or "An intuition", as it is.
- paper: how it relates to what the paper does: where it enters the method, what the paper changes, adds to or measures about it, and any result that depends on it (with the paper's own numbers when it gives them).
- where: 2 to 6 places in the paper where it appears, first use first. paragraph: the N of a [¶N] marker that exists in the paper. note: under 90 characters saying what happens there ("defines the loss", "compared in Table 2"); plain text, no markers.
- text: 200 to 700 characters of plain prose (Markdown emphasis only where it helps). Cite the paragraphs a statement relies on by writing their [¶N] markers right after it, as in an answer (only markers that exist in the paper). Math as \\\\( … \\\\) inline or \\\\[ … \\\\] on its own line (escaped as JSON requires), never dollar signs.
Do not repeat the explainer's line. General background (in what and example) needs no citation: say "in general" or "for example" where it is not the paper's own, without remarks about what you can or cannot verify. Never attribute to the paper what it does not say, and never invent its results or numbers.`;

export interface PaperConceptPlace { paragraph: number; note: string }
export interface PaperConceptSection { kind?: PaperConceptKind; title: string; text: string; paragraphs: number[]; places?: PaperConceptPlace[] }
export interface PaperConcept { format: typeof PAPER_CONCEPT_FORMAT; sections: PaperConceptSection[] }

const scalars = (text: string) => [...text].length;
/** One line: control characters, Markdown emphasis and [¶N] markers out, white space collapsed, cut at a word with "…". */
function oneLine(value: unknown, limit: number): string {
  if (typeof value !== 'string') return '';
  const text = value.replace(/\[¶\d{1,6}\]/g, ' ').replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\*\*|__|`/g, '')
    .replace(/\s+/g, ' ').trim().replace(/\s+([.,;:])/g, '$1');
  if (scalars(text) <= limit) return text;
  const head = [...text].slice(0, limit - 1).join('');
  const space = head.lastIndexOf(' ');
  return `${(space > limit / 2 ? head.slice(0, space) : head).replace(/[\s,;:–—-]+$/, '')}…`;
}
/** Markdown prose: line breaks kept (at most one blank line), other control characters out, a [¶N] outside the paper
 * removed, and a text over the limit cut at its last sentence or line end before it (as a figure section's text). */
function prose(value: unknown, limit: number, paragraphs: number): string {
  if (typeof value !== 'string') return '';
  let text = value.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, ' ')
    .replace(/\[¶(\d{1,6})\]/g, (marker, n) => Number(n) >= 1 && Number(n) <= paragraphs ? marker : '')
    .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').replace(/[ \t]{2,}/g, ' ').trim();
  if (scalars(text) > limit) {
    const head = [...text].slice(0, limit).join('');
    const end = Math.max(head.lastIndexOf('. '), head.lastIndexOf('! '), head.lastIndexOf('? '), head.lastIndexOf('\n'));
    text = end > limit / 2 ? head.slice(0, end + 1).trimEnd() : `${[...head].slice(0, limit - 1).join('').trimEnd()}…`;
  }
  return text;
}
const cited = (text: string) => [...text.matchAll(/\[¶(\d{1,6})\]/g)].map(m => Number(m[1]));
const inPaper = (n: unknown, paragraphs: number): n is number => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= paragraphs;

/** The places a section names (untrusted): each a paragraph of the paper (the first mention kept) with a short note. */
function places(raw: unknown, paragraphs: number): PaperConceptPlace[] {
  const out: PaperConceptPlace[] = [], seen = new Set<number>();
  for (const entry of Array.isArray(raw) ? raw.slice(0, 24) : []) {
    if (out.length >= PAPER_CONCEPT_LIMITS.places) break;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) continue;
    const p = entry as Record<string, unknown>, n = p.paragraph;
    if (!inPaper(n, paragraphs) || seen.has(n)) continue;
    seen.add(n);
    out.push({ paragraph: n, note: oneLine(p.note, PAPER_CONCEPT_LIMITS.noteChars) });
  }
  return out;
}

/** One section of the model's output (untrusted), checked and bounded, or null when it has neither text nor places. The
 * final concept and the stream use this one check, so what a device sees as sections arrive is exactly the final concept. */
export function paperConceptSection(raw: unknown, paragraphs: number): PaperConceptSection | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const s = raw as Record<string, unknown>;
  const kind = (PAPER_CONCEPT_KINDS as readonly string[]).includes(s.kind as string) ? s.kind as PaperConceptKind : undefined;
  const title = oneLine(s.title, PAPER_CONCEPT_LIMITS.titleChars) || (kind ? PAPER_CONCEPT_TITLES[kind] : '');
  const text = prose(s.text, PAPER_CONCEPT_LIMITS.textChars, paragraphs);
  const listed = places(s.places, paragraphs);
  if (!title || (!text && !listed.length)) return null;
  const given = Array.isArray(s.paragraphs) ? (s.paragraphs as unknown[]).filter(n => inPaper(n, paragraphs)) as number[] : [];
  const numbers = [...new Set([...cited(text), ...listed.map(p => p.paragraph), ...given])].slice(0, PAPER_CONCEPT_LIMITS.paragraphs);
  return { ...(kind ? { kind } : {}), title, text, paragraphs: numbers, ...(listed.length ? { places: listed } : {}) };
}

/** The model's concept (untrusted: the paper can steer it), checked and bounded. Degrades rather than refuses: a section
 * without text or places is left out, a [¶N] or place outside the paper is removed, the first six sections are kept.
 * Null when no section is left. `paragraphs` is the paper's block count. */
export function paperConcept(input: unknown, paragraphs: number): PaperConcept | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  const sections: PaperConceptSection[] = [];
  for (const raw of Array.isArray(v.sections) ? (v.sections as unknown[]).slice(0, 24) : []) {
    if (sections.length >= PAPER_CONCEPT_LIMITS.sections) break;
    const section = paperConceptSection(raw, paragraphs);
    if (section) sections.push(section);
  }
  return sections.length ? { format: PAPER_CONCEPT_FORMAT, sections } : null;
}

/** The concept as Markdown: what a reader still gets when it can't be shown as sections. Empty without any words. */
export function paperConceptText(input: unknown, paragraphs: number): string {
  const checked = paperConcept(input, paragraphs);
  if (!checked) return '';
  return checked.sections.map(s => {
    const list = (s.places ?? []).map(p => `- [¶${p.paragraph}]${p.note ? ` ${p.note}` : ''}`).join('\n');
    return [`**${s.title}**`, s.text, list].filter(Boolean).join('\n\n');
  }).join('\n\n');
}

/** What the concept's JSON yields as it arrives: the announced number of sections, then each section once its object is
 * complete and passes `paperConceptSection` (`index` is its place in the final concept). */
export type PaperConceptStreamItem = { kind: 'parts'; parts: number } | { kind: 'section'; index: number; section: PaperConceptSection };

/** Reads the concept's JSON incrementally (`{"parts": N, "sections": [{…}, …]}`, keys in any order; json-list-stream.ts). */
export class PaperConceptStream extends JsonListStream<PaperConceptSection> {
  constructor(paragraphs: number) {
    super({ countKey: 'parts', summaryKey: 'summary', listKey: 'sections', maxCount: PAPER_CONCEPT_LIMITS.sections,
      maxItems: PAPER_CONCEPT_LIMITS.sections, summary: () => '', item: raw => paperConceptSection(raw, paragraphs) });
  }
  /** The number of sections the model announced, when it did (1–6). */
  get parts(): number | null { return this.count; }
  /** The concept streamed so far (a cut-off one keeps its complete sections); null before any section. */
  concept(): PaperConcept | null { return this.kept.length ? { format: PAPER_CONCEPT_FORMAT, sections: [...this.kept] } : null; }
  push(chunk: string): PaperConceptStreamItem[] {
    return this.read(chunk).flatMap((item): PaperConceptStreamItem[] => item.kind === 'count' ? [{ kind: 'parts', parts: item.count }]
      : item.kind === 'item' ? [{ kind: 'section', index: item.index, section: item.item }] : []);
  }
}

/** The JSON object in a reply (the first `{` to the last `}`), or undefined when none parses. */
export function paperConceptJSON(text: string): unknown {
  const start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return undefined;
  try { return JSON.parse(text.slice(start, end + 1)) as unknown; } catch { return undefined; }
}
