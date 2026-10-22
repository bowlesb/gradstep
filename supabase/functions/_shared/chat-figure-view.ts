// The figure view (docs/architecture/FIGURE_VIEW.md): a walkthrough of one figure on request, part by part, with a box
// (a fraction of the image) where a small detail of a large figure needs the reader's eye, and any one part again, more
// simply. Like the equation view, both are chat actions on the reader's own model, tools, shared instructions and paper,
// so they read and write the chat's cached prefix; only these instructions follow the paper.
//
// The walkthrough comes as one figure_walkthrough tool call. Sonnet 5.5 and Opus 5.5 refuse a forced tool_choice (400),
// so the call is asked for by the instructions with the chat's own tool_choice (auto) and adaptive thinking, and the
// server checks its input. The tool is in the tools of every paper chat from a build that has the figure view (the
// `figure_view` capability), so a walkthrough and the chat around it share one cached prefix.
import type { Effort, ToolDefinition } from './model-request.ts';
import { EFFORTS } from './chat-profiles.ts';
import { JsonListStream } from './json-list-stream.ts';

/** `figure_detail` ("Extract the subfigure and more context") is DEPRECATED (2026-10-21, owner: "Let's not do extract the
 * subfigure"). No current client sends it; it is accepted only so already-installed iPhone/iPad/Mac builds 63–79 (and
 * browser pages loaded before the next deploy) keep working. Remove it, with its instructions, event and allowance, once
 * no supported build sends it (migration 083's settlement value stays for old ledger rows). FIGURE_VIEW.md "Extract the
 * subfigure removed". */
export const FIGURE_ACTIONS = ['figure', 'figure_simpler', 'figure_detail'] as const;
export type FigureAction = typeof FIGURE_ACTIONS[number];
export const isFigureAction = (action: string | null | undefined): action is FigureAction =>
  action === 'figure' || action === 'figure_simpler' || action === 'figure_detail';

/** A build with the figure view says so on every paper chat request; only then is figure_walkthrough among the tools. */
export const FIGURE_VIEW_CAPABILITY = 'figure_view';
export const FIGURE_FORMAT = 'figure-walkthrough-v1';
export const FIGURE_LIMITS = Object.freeze({ sections: 12, textChars: 1_500, summaryChars: 800, labelChars: 60, titleChars: 120,
  paragraphs: 8, boxes: 12, minSide: 0.04 });
/** The walkthrough's output allowance: a standard answer's, plus the effort's thinking (the reader's length does not
 * apply: the walkthrough has its own shape). */
export const FIGURE_ANSWER_TOKENS = 6_000;
export function figureMaxTokens(effort: string): number {
  return FIGURE_ANSWER_TOKENS + (EFFORTS.find(entry => entry.id === effort)?.thinkingTokens ?? 4_000);
}
/** One part, extracted (`figure_detail`, deprecated: see FIGURE_ACTIONS): its box and up to ~1,500 characters, plus the
 * effort's thinking. */
export const FIGURE_DETAIL_FORMAT = 'figure-detail-v1';
export const FIGURE_DETAIL_ANSWER_TOKENS = 2_500;
export function figureDetailMaxTokens(effort: string): number {
  return FIGURE_DETAIL_ANSWER_TOKENS + (EFFORTS.find(entry => entry.id === effort)?.thinkingTokens ?? 4_000);
}

export const FIGURE_WALKTHROUGH_TOOL: ToolDefinition = {
  name: 'figure_walkthrough',
  description: 'Gives the figure view its walkthrough of the attached figure (F1): a short summary, then one section per '
    + 'sub-figure, panel or region in reading order; a section may carry a box, a region of the image the reader sees '
    + 'cropped. Call it only when the instructions after the paper say the reader opened the figure view and asked for a '
    + 'walkthrough: once, with no other text. Never call it in an ordinary answer (use show_figure_parts there).',
  input_schema: {
    type: 'object',
    properties: {
      summary: { type: 'string', description: 'What the figure shows and the point it makes, in two or three plain sentences.' },
      sections: { type: 'array', minItems: 1, maxItems: FIGURE_LIMITS.sections, items: { type: 'object', properties: {
        kind: { type: 'string', enum: ['panel', 'concept', 'related_work'], description: 'Panel or grouped panels; a supporting concept; or related work as described by this paper.' },
        label: { type: 'string', description: 'The part as the figure names it: "(a)", "Left", "Top row", "Inset"; empty when it has no name.' },
        title: { type: 'string', description: 'What this part shows, in a few words (under 80 characters).' },
        text: { type: 'string', description: 'The walkthrough of this part in Markdown, with [¶N] citations; at most about 1,200 characters.' },
        paragraphs: { type: 'array', items: { type: 'integer' }, description: 'The N of each [¶N] paragraph that discusses this part.' },
        box: { type: 'object', description: 'A region of the image the reader sees enlarged above this section. Give one when the text points '
          + 'at a panel that needs enlargement. Enclose the complete panel, its axes, tick labels, title and legend; never cut a plot into a thin slice. '
          + 'For a single-panel figure omit the box. x, y: its top-left corner; w, h: its width and height; fractions of the image, each side at least 0.04. At most 12 in a walkthrough. Together, panel boxes must cover the entire figure, including margins and shared legends; overlap or group panels if needed.',
        properties: { x: { type: 'number' }, y: { type: 'number' }, w: { type: 'number' }, h: { type: 'number' } }, required: ['x', 'y', 'w', 'h'] },
      }, required: ['label', 'title', 'text', 'paragraphs'] } },
    },
    required: ['summary', 'sections'],
  },
};

export const FIGURE_INSTRUCTIONS = `The reader opened the figure view on the attached figure (F1; the <selected_passage> block is its caption) and asked for a walkthrough of it. Read the image itself, closely: every panel, axis, tick label, legend entry, colour, marker, line style, arrow and annotation.
Write the whole walkthrough as one JSON object in your reply, with the fields of the figure_walkthrough tool's input after a count: {"parts": 3, "summary": "…", "sections": [{"kind": "panel", "label": "…", "title": "…", "text": "…", "paragraphs": [N, …], "box": {"x": …, "y": …, "w": …, "h": …}}, …]}. First "parts", the number of sections you will write (the reader's progress bar), then the summary, then each section whole before the next: the reader sees each part as soon as it is written. Write it even when part of the image is unclear or cut off (say so in the text). Write nothing else (no code fence, no words before or after it), call no tool and do not search the web. Inside the JSON strings, escape as JSON requires: math is \\\\( … \\\\) and \\\\[ … \\\\] there (it reads as \\( … \\) and \\[ … \\]), never dollar signs; line breaks are \\n.
- summary: two or three plain sentences: what the figure shows and the point it makes in the paper.
- sections: primarily panel cards, one per sub-figure or coherent group of panels, in reading order (the figure's own labels (a), (b)…, else left to right, top to bottom). Leave none out; panels that repeat one pattern may share a section (at most ${FIGURE_LIMITS.sections} sections). A single-panel figure can use one panel card without a crop. Add concept or related-work cards only when they help interpret this figure, not to fill a quota.
- kind: panel, concept, or related_work. A concept card explains an idea needed to understand the result; a related_work card summarizes only what the supplied paper says about another work, names that work in its title and cites the supporting [¶N]. Do not imply you have read another paper. Non-panel cards have no box.
- label: the part as the figure names it ("(a)", "Left", "Top row", "Inset"), empty when it has no name; title: what that part shows, in a few words.
- text: explain every detail a careful reader needs, in plain words: what is plotted against what, units and scales (log axes, normalisation, ranges), what each colour, marker, line style or arrow encodes, the values, trends or exceptions to notice, and how this part supports the paper's claim. Say what the image shows, not only what the caption says. Cite the paragraphs that discuss it by writing their [¶N] markers in the text, right after the statement each supports, as in an answer (only markers that exist in the paper), and list their numbers in paragraphs. Use the room: usually 500 to 1,200 characters, the most for a dense panel.
- A table shown as a figure: a first section on how to read it (what the rows and columns are, the units, what bold, underline or colour marks), then a section for each comparison or result it supports.
- box: for a multi-panel figure, include a crop for every panel card and ALWAYS cover all pixels of the original image across those cards, including margins, labels and legends. Overlap is allowed; group multiple panels in one card when needed. Never leave gaps between crops or omit an inconvenient region. Each crop contains a COMPLETE subfigure or panel, including its axis titles, tick labels, units, panel label, annotations and legend. Enlarge or group panels to include shared legends. If you cannot divide the figure without losing context, use the full-figure explanation without crops and state why. The crop must contain everything the section explains. Never isolate a narrow slice of a plot, a curve crossing or a label when discussing the full result. A single-panel plot usually needs no box: the whole image is already shown and can be opened fullscreen. Coordinates are normalized top-left x,y,width,height, with a little margin and each side at least ${FIGURE_LIMITS.minSide}; at most ${FIGURE_LIMITS.boxes} boxes.
- For comparisons, state the observed relationship (which quantity is larger/lower, the actual numbers only if legible), then what the authors infer from it and why. Separate observation from the authors' interpretation and your inference. For descriptive tables explain the design or categories; never invent a numerical result. A section naming axes or table headers alone is not an explanation of the result.`;

export const FIGURE_SIMPLER_INSTRUCTIONS = `The reader is reading a walkthrough of the attached figure (F1) and asked for one part of it, in the <selected_passage> block, to be explained more simply ("back up a bit"). Explain only that part again, for someone meeting it for the first time: where to look in the image and what is there, in plain words; the background it relies on, each idea briefly (what the axes or quantities mean, why this kind of plot or measure is used, any term the passage takes for granted); then what to notice and why it matters to the paper, with a small concrete example when it helps. Do not walk through the rest of the figure and do not repeat the passage. Cite the paper as usual. Do not use any tool and do not search the web.`;

/** Deprecated with `figure_detail` (see FIGURE_ACTIONS; older builds only).
 * "Extract the subfigure and more context" (owner, build 62): one part of the walkthrough, cropped and read again with
 * more of the paper around it. Same tool as the walkthrough (so the cached tools stay the chat's), one section, its box
 * required: the device crops the image it sent to that region and shows the text under it. */
export const FIGURE_DETAIL_INSTRUCTIONS = `The reader is reading a walkthrough of the attached figure (F1) and asked to extract one part of it, in the <selected_passage> block (the part's label, title and text from the walkthrough), and for more context about it. Look closely at that part of the image.
Call figure_walkthrough once with exactly one section, that part, even when it is hard to read (say so in the text). Write no other text, use no other tool and do not search the web.
- box: the region of the image this part occupies, tight around it with a little margin, as fractions of the image: x and y its top-left corner, w and h its width and height, each side at least ${FIGURE_LIMITS.minSide}. Include the complete relevant panel with axes, tick labels, units, title, annotations and legend. Do not isolate a thin slice. If the relevant part is the whole figure, say that the full figure is needed and omit the box rather than cutting away context; the reader can enlarge the full image.
- label and title: the part's, as in the passage.
- text: a closer reading of that region than the walkthrough gave: every detail visible in it (axes and their ranges, tick labels, legend entries, values, colours, markers, line styles, arrows, annotations, small print), then more context from the paper: what the text around the figure says about this part, the method or setting it comes from, how it supports the paper's claims, and any caveat the paper states. Cite paragraphs with their [¶N] markers right after the statements they support, and list their numbers in paragraphs. Do not repeat the passage. Usually 800 to 1,500 characters.
- summary: one plain sentence saying what this part shows.`;

export interface FigureBox { x: number; y: number; w: number; h: number }
export type FigureCardKind = 'panel' | 'concept' | 'related_work';
export interface FigureSection { kind?: FigureCardKind; label: string; title: string; text: string; paragraphs: number[]; box?: FigureBox }
export interface FigureWalkthrough { format: typeof FIGURE_FORMAT; summary: string; sections: FigureSection[] }

const scalars = (text: string) => [...text].length;
/** One line: control characters and runs of white space become one space. */
function line(value: unknown, limit: number): string {
  if (typeof value !== 'string') return '';
  const text = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return scalars(text) <= limit ? text : `${[...text].slice(0, limit - 1).join('').trimEnd()}…`;
}
/** Markdown prose: line breaks kept (at most one blank line), other control characters dropped, a [¶N] outside the paper
 * dropped, and a text over the limit cut at its last sentence or line end before it. */
function prose(value: unknown, limit: number, paragraphs: number): string {
  if (typeof value !== 'string') return '';
  let text = value.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, ' ')
    .replace(/\[¶(\d{1,6})\]/g, (marker, n) => Number(n) >= 1 && Number(n) <= paragraphs ? marker : '')
    .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  if (scalars(text) > limit) {
    const head = [...text].slice(0, limit).join('');
    const end = Math.max(head.lastIndexOf('. '), head.lastIndexOf('! '), head.lastIndexOf('? '), head.lastIndexOf('\n'));
    text = end > limit / 2 ? head.slice(0, end + 1).trimEnd() : `${[...head].slice(0, limit - 1).join('').trimEnd()}…`;
  }
  return text;
}
const cited = (text: string) => [...text.matchAll(/\[¶(\d{1,6})\]/g)].map(m => Number(m[1]));

/** A box within the image, each side at least 4 %, not the whole figure (a tiny overshoot is clamped); null otherwise. */
export function figureBox(value: unknown): FigureBox | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  const n = [v.x, v.y, v.w, v.h];
  if (n.some(x => typeof x !== 'number' || !Number.isFinite(x))) return null;
  let [x, y, w, h] = n as number[];
  if (x < -0.02 || y < -0.02 || x >= 1 || y >= 1 || w <= 0 || h <= 0 || x + w > 1.02 || y + h > 1.02) return null;
  if (x < 0) { w += x; x = 0; }
  if (y < 0) { h += y; y = 0; }
  w = Math.min(w, 1 - x); h = Math.min(h, 1 - y);
  if (w < FIGURE_LIMITS.minSide || h < FIGURE_LIMITS.minSide || (w >= 0.95 && h >= 0.95)) return null;
  const round = (k: number) => Math.round(k * 10_000) / 10_000;
  return { x: round(x), y: round(y), w: round(w), h: round(h) };
}

/** One section of the model's figure_walkthrough input, checked and bounded (untrusted), or null when it has no title or
 * text. `boxed` is how many kept sections before it carry a box (at most FIGURE_LIMITS.boxes are kept). The walkthrough
 * and its streamed sections (`FigureWalkthroughStream`) use this one check, so the sections a device sees as they arrive
 * are exactly the final walkthrough's. */
export function figureSection(raw: unknown, paragraphs: number, boxed = 0): FigureSection | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const s = raw as Record<string, unknown>;
  let label = line(s.label, FIGURE_LIMITS.labelChars), title = line(s.title, FIGURE_LIMITS.titleChars);
  const text = prose(s.text, FIGURE_LIMITS.textChars, paragraphs);
  if (!title) { title = label; label = ''; }
  if (!text || !title) return null;
  const given = Array.isArray(s.paragraphs) ? (s.paragraphs as unknown[]).filter((n): n is number => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= paragraphs) : [];
  const numbers = [...new Set([...given, ...cited(text)])].slice(0, FIGURE_LIMITS.paragraphs);
  const kind = s.kind === 'concept' || s.kind === 'related_work' || s.kind === 'panel' ? s.kind : undefined;
  const box = (!kind || kind === 'panel') && boxed < FIGURE_LIMITS.boxes ? figureBox(s.box) : null;
  return { ...(kind ? { kind } : {}), label, title, text, paragraphs: numbers, ...(box ? { box } : {}) };
}
/** The walkthrough's summary, checked (may be empty). */
export const figureSummary = (value: unknown, paragraphs: number): string => prose(value, FIGURE_LIMITS.summaryChars, paragraphs);

/** The model's figure_walkthrough input, checked and bounded (untrusted: the paper and the image can steer it). Degrades
 * rather than refuses: a section without text is left out, a box that does not fit is dropped (the section stays), the
 * first 12 sections and 12 boxes are kept, a [¶N] outside the paper is removed. Null when no section is left.
 * `paragraphs` is the paper's block count. */
export function figureWalkthrough(input: unknown, paragraphs: number): FigureWalkthrough | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  if (!Array.isArray(v.sections)) return null;
  const sections: FigureSection[] = [];
  for (const raw of v.sections as unknown[]) {
    if (sections.length >= FIGURE_LIMITS.sections) break;
    const section = figureSection(raw, paragraphs, sections.filter(s => s.box).length);
    if (section) sections.push(section);
  }
  if (!sections.length) return null;
  return { format: FIGURE_FORMAT, summary: figureSummary(v.summary, paragraphs), sections };
}

/** What a walkthrough's streamed arguments yield as they arrive (FIGURE_VIEW.md "Streamed walkthrough"): the summary
 * once its string is complete, and each section once its object is complete and passes `figureSection` (in order;
 * `index` is its place in the final walkthrough). */
export type FigureStreamItem = { kind: 'summary'; summary: string } | { kind: 'section'; index: number; section: FigureSection }
  /** The number of parts the model says it will write (`"parts"`, its first field): a progress bar's denominator, not a
   * promise (the parts that arrive are what the walkthrough is). */
  | { kind: 'parts'; parts: number };

/** Reads the walkthrough's JSON incrementally (`{"parts": N, "summary": "…", "sections": [{…}, …]}`, keys in any order),
 * from the reply or figure_walkthrough's arguments (json-list-stream.ts): each section checked by `figureSection`, so
 * malformed or cut-off input yields nothing for that value (the final check still decides what the walkthrough is). */
export class FigureWalkthroughStream extends JsonListStream<FigureSection> {
  constructor(paragraphs: number) {
    super({ countKey: 'parts', summaryKey: 'summary', listKey: 'sections', maxCount: FIGURE_LIMITS.sections, maxItems: FIGURE_LIMITS.sections,
      summary: value => figureSummary(value, paragraphs),
      item: (raw, kept) => figureSection(raw, paragraphs, kept.filter(s => s.box).length) });
  }
  /** The sections streamed so far (checked, in order). */
  get sections(): readonly FigureSection[] { return this.items; }
  /** The number of parts the model announced, when it did (1–12). */
  get parts(): number | null { return this.count; }
  /** The walkthrough streamed so far (a cut-off one keeps the sections that were complete); null before any section. */
  walkthrough(): FigureWalkthrough | null {
    return this.kept.length ? { format: FIGURE_FORMAT, summary: this.summaryText, sections: [...this.kept] } : null;
  }
  push(chunk: string): FigureStreamItem[] {
    return this.read(chunk).map((item): FigureStreamItem => item.kind === 'count' ? { kind: 'parts', parts: item.count }
      : item.kind === 'summary' ? item : { kind: 'section', index: item.index, section: item.item });
  }
}

/** The walkthrough written as JSON in the model's reply (FIGURE_INSTRUCTIONS), checked; null when it holds none. */
export function figureWalkthroughFromText(text: string, paragraphs: number): FigureWalkthrough | null {
  const input = walkthroughJSON(text);
  return input === undefined ? null : figureWalkthrough(input, paragraphs);
}
/** The JSON object in a reply (the first `{` to the last `}`), or undefined when there is none that parses. */
export function walkthroughJSON(text: string): unknown {
  const start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return undefined;
  try { return JSON.parse(text.slice(start, end + 1)) as unknown; } catch { return undefined; }
}

/** The figure view's effort (FIGURE_VIEW.md "Speed", 2026-10-22): `low` for the walkthrough and Explain more simply
 * when the reader left the effort to the server (`auto`) or chose Gemini Flash, whose profiles carry no effort choice.
 * Measured on four real figures: Gemini Flash at medium thought for up to 3,800 tokens (24–45 s before a walkthrough);
 * at low it read the same panels, numbers and boxes in 8–11 s. An effort the reader chose for a Claude model stays. */
export function figureViewEffort(requested: { model: string; effort: string } | null, resolved: Effort): Effort {
  if (!requested) return resolved;
  return requested.model === 'gemini' || requested.effort === 'auto' ? 'low' : resolved;
}

export interface FigureDetail { format: typeof FIGURE_DETAIL_FORMAT; label: string; title: string; text: string; paragraphs: number[]; box: FigureBox }
/** Deprecated with `figure_detail` (older builds only). The model's figure_walkthrough input for one part, checked: its
 * first usable section with a usable box. Null when there is none (the words still reach the reader, without a crop: `figureWalkthroughText`). */
export function figureDetail(input: unknown, paragraphs: number): FigureDetail | null {
  if (!input || typeof input !== 'object' || Array.isArray(input) || !Array.isArray((input as Record<string, unknown>).sections)) return null;
  const first = ((input as Record<string, unknown>).sections as unknown[]).find(s => !!s && typeof s === 'object' && !Array.isArray(s));
  const checked = first ? figureWalkthrough({ summary: '', sections: [first] }, paragraphs) : null;
  const section = checked?.sections[0];
  if (!section?.box) return null;
  return { format: FIGURE_DETAIL_FORMAT, label: section.label, title: section.title, text: section.text, paragraphs: section.paragraphs, box: section.box };
}

/** How many sections of the model's input carried a box at all (a count for the log: boxes offered but dropped show a
 * model writing them in a form the check refuses). */
export function offeredBoxes(input: unknown): number {
  const sections = input && typeof input === 'object' && !Array.isArray(input) ? (input as Record<string, unknown>).sections : null;
  return Array.isArray(sections) ? sections.filter(s => !!s && typeof s === 'object' && (s as Record<string, unknown>).box != null).length : 0;
}

/** The walkthrough as Markdown: the words a reader still gets when the walkthrough can't be shown as one (an ordinary
 * answer that called the tool anyway, or an input with no usable section). Empty when the input has no words at all. */
export function figureWalkthroughText(input: unknown, paragraphs: number): string {
  const checked = figureWalkthrough(input, paragraphs);
  if (checked) {
    return [checked.summary, ...checked.sections.map(s => `**${[s.label, s.title].filter(Boolean).join(' ')}**\n\n${s.text}`)]
      .filter(Boolean).join('\n\n');
  }
  if (!input || typeof input !== 'object' || Array.isArray(input)) return '';
  const v = input as Record<string, unknown>;
  const words = [prose(v.summary, FIGURE_LIMITS.summaryChars, paragraphs)];
  if (Array.isArray(v.sections)) {
    for (const raw of (v.sections as unknown[]).slice(0, FIGURE_LIMITS.sections)) {
      if (raw && typeof raw === 'object' && !Array.isArray(raw)) words.push(prose((raw as Record<string, unknown>).text, FIGURE_LIMITS.textChars, paragraphs));
    }
  }
  return words.filter(Boolean).join('\n\n');
}
