// Study mode (reworked 2026-10-22; docs/proposals/LEARNING_GUIDE.md, docs/architecture/CHAT.md "Study mode"). A paper
// conversation with `action: "study"` is a tutor: one focused question at a time, grounded in the numbered paper,
// feedback on each answer, and a step back to a short explanation with a quick check when the reader is shaky or an idea
// needs groundwork first. The tutor keeps its own light notes on the reader (concepts covered, how sure the reader is,
// its plan) in the same reply, inside <study_state>…</study_state> after its question. The server removes that block from
// the stream (`StudyStateFilter`), checks it (`studyState`) and relays it once as an SSE `study_state` event; the device
// keeps it with the open chat and sends it back with the next turn. Nothing of it is stored or logged by the server.
//
// The 2026-10-14 slice (a knowledge map rebuilt after each answer by a second, forced Haiku request, drawn as a map,
// journey and concept list) is retired: builds that predate this still send `study: {map}`, which is accepted and
// ignored (`legacyStudyMap`), and no longer receive `study` events.

/** The hidden notes' bounds: the tutor writes them every turn, so they must stay small (they are output tokens). */
export const STUDY_STATE_LIMITS = Object.freeze({ concepts: 12, name: 60, asked: 8, paras: 6, next: 200, bytes: 4_096, turn: 500 });
export const STUDY_LEVELS = ['intro', 'core', 'deep'] as const;
export const STUDY_STATUSES = ['new', 'shaky', 'ok', 'solid'] as const;
export type StudyLevel = typeof STUDY_LEVELS[number];
export type StudyStatus = typeof STUDY_STATUSES[number];
export interface StudyConceptNote { name: string; status: StudyStatus; asked: number[]; paras: number[] }
export interface StudyState { turn: number; level: StudyLevel; concepts: StudyConceptNote[]; next: string }

export const STUDY_OPEN = '<study_state>';
export const STUDY_CLOSE = '</study_state>';

/** One line, control characters out, cut to the limit (a model writes long names; a cut name beats lost notes). */
function line(value: unknown, limit: number): string | null {
  if (typeof value !== 'string') return null;
  const text = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/[<>]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!text) return null;
  const scalars = [...text];
  return scalars.length <= limit ? text : scalars.slice(0, limit - 1).join('').trimEnd() + '…';
}
const numbers = (value: unknown, max: number, limit: number) => [...new Set((Array.isArray(value) ? value : [])
  .filter(n => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= max) as number[])].sort((a, b) => a - b).slice(-limit);

/** The tutor's notes from the model or the device (untrusted), repaired rather than refused: an unknown level becomes
 * `core`, an unknown status `new`, a concept without a name is dropped, duplicates keep the newest, lists are bounded.
 * Null only when the shape is unusable (not an object) or the result is over 4 KB. `paragraphs` bounds `paras` (the
 * paper's block count; the device's copy is checked against 100,000). */
export function studyState(input: unknown, paragraphs = 100_000): StudyState | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  const turn = Number.isSafeInteger(v.turn) && (v.turn as number) >= 1 ? Math.min(v.turn as number, STUDY_STATE_LIMITS.turn) : 1;
  const level = STUDY_LEVELS.includes(v.level as StudyLevel) ? v.level as StudyLevel : 'core';
  const byName = new Map<string, StudyConceptNote>();
  for (const raw of Array.isArray(v.concepts) ? v.concepts.slice(0, 64) : []) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const c = raw as Record<string, unknown>;
    const name = line(c.name, STUDY_STATE_LIMITS.name);
    if (!name) continue;
    const status = STUDY_STATUSES.includes(c.status as StudyStatus) ? c.status as StudyStatus : 'new';
    byName.delete(name.toLowerCase());
    byName.set(name.toLowerCase(), { name, status, asked: numbers(c.asked, STUDY_STATE_LIMITS.turn, STUDY_STATE_LIMITS.asked),
      paras: numbers(c.paras, paragraphs, STUDY_STATE_LIMITS.paras) });
  }
  const concepts = [...byName.values()].slice(-STUDY_STATE_LIMITS.concepts);
  const state: StudyState = { turn, level, concepts, next: line(v.next, STUDY_STATE_LIMITS.next) ?? '' };
  return new TextEncoder().encode(JSON.stringify(state)).length <= STUDY_STATE_LIMITS.bytes ? state : null;
}

/** A 2026-10-14 build's knowledge map (`study: {concepts, links, …}`): accepted when it is an object of at most 16 KB,
 * and otherwise ignored (the tutor no longer reads it; those builds keep working without map updates). */
export function legacyStudyMap(input: unknown): Record<string, unknown> | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  return new TextEncoder().encode(JSON.stringify(input)).length <= 16_384 ? input as Record<string, unknown> : null;
}

/** Removes the tutor's hidden notes from the streamed reply. `push` returns the text that may be shown now: a possible
 * start of the opening tag at the end of a piece is held back until the next piece decides it, and everything between
 * the tags (wherever the model puts them, an unterminated block to the end) is kept aside. `finish` returns what was
 * held back (never part of a tag) and the notes' raw text, if any. */
export class StudyStateFilter {
  private pending = '';
  private inside = false;
  private captured = '';
  private found = false;
  private shown = '';

  /** The visible reply so far (what the device was sent). */
  get visible(): string { return this.shown; }
  /** Whether an opening tag was seen. */
  get sawState(): boolean { return this.found; }

  push(piece: string): string {
    let text = this.pending + piece, out = '';
    this.pending = '';
    while (text) {
      if (this.inside) {
        const end = text.indexOf(STUDY_CLOSE);
        if (end < 0) {
          // Keep a possible start of the closing tag apart so the captured text never carries half of it.
          const keep = partialSuffix(text, STUDY_CLOSE);
          this.captured += text.slice(0, text.length - keep); this.pending = text.slice(text.length - keep);
          text = '';
        } else {
          this.captured += text.slice(0, end); this.inside = false; text = text.slice(end + STUDY_CLOSE.length);
        }
        continue;
      }
      const start = text.indexOf(STUDY_OPEN);
      if (start >= 0) {
        out += text.slice(0, start); this.inside = true; this.found = true; text = text.slice(start + STUDY_OPEN.length);
        continue;
      }
      const keep = partialSuffix(text, STUDY_OPEN);
      out += text.slice(0, text.length - keep); this.pending = text.slice(text.length - keep);
      text = '';
    }
    this.shown += out;
    return out;
  }

  /** The end of the reply: the held-back text that turned out not to be a tag, and the notes' raw text. */
  finish(): { text: string; raw: string | null } {
    const text = this.inside ? '' : this.pending;
    if (this.inside) this.captured += this.pending;
    this.pending = ''; this.shown += text;
    return { text, raw: this.found ? this.captured : null };
  }
}
/** How many characters at the end of `text` could begin `tag`. */
function partialSuffix(text: string, tag: string): number {
  for (let n = Math.min(tag.length - 1, text.length); n > 0; n--) if (tag.startsWith(text.slice(text.length - n))) return n;
  return 0;
}

/** The notes' raw text (between the tags) as checked notes, or null. A code fence or words around the object are ignored. */
export function studyStateFromText(raw: string | null, paragraphs: number): StudyState | null {
  if (!raw) return null;
  const start = raw.indexOf('{'), end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try { return studyState(JSON.parse(raw.slice(start, end + 1)), paragraphs); } catch { return null; }
}

/** The tutor's protocol (after the paper, with the previous notes after it). Evaluated on simulated learners before it
 * shipped: docs/proposals/LEARNING_GUIDE.md "Evaluation of the tutor prompt". */
export const STUDY_INSTRUCTIONS = `The reader turned on Study mode: you are now their tutor for this paper. Help them understand and remember its key ideas through a calibrated conversation: one focused question at a time, honest feedback on each answer, and a short explanation first whenever they are shaky or an idea needs groundwork.

Each turn has at most three short parts: feedback, then either a step forward or an explanation, then one question.
1. Feedback (when the reader just answered), one or two sentences: say plainly whether it is right, partly right or not right yet, then add something useful: the missing piece, the precise reason, or the paper's own detail, cited. Accept answers in their own words. No stock praise ("Spot on", "Exactly right", "nailed it", "Great") and no exclamation marks; a plain "Right" or "Yes" is enough.
2. The next move:
- Right: go one step further on the same idea (why it works, what would change if…, apply it), or, once it is solid (two good answers, or one good answer to a hard question), move to the next idea that builds on it.
- Partly right: fill the gap in a sentence or two, then ask about the same idea from a different angle.
- Wrong, "I don't know", a guess, or a second shaky answer: back off. Explain that idea from the ground up in at most five plain sentences with one concrete or tiny worked example (illustrative numbers are fine when you say they are an example), citing the paper, then ask an easier check on the same idea: a choice between two or three options you give, one step of the reasoning, or the idea in their own words.
- A misconception (a confident answer built on a wrong belief): name the belief, say why the paper's account differs, and ask a check that tells the two apart. Stay on that idea until the reader answers a check correctly and no longer holds the belief; do not move on while it is shaky, and make it your next look back.
- An idea the reader has not yet shown they know: teach it first in two or three sentences (a tiny worked example when it involves math), then ask about it. Never quiz on something neither taught nor shown: at intro or core level the question must be answerable from what you just said plus general background (to ask why the authors did something, first give the reason or enough of it to reason from); only at deep level may you ask the reader to infer what you have not shown.
- "Hint" (or "give me a hint"): one hint that narrows the answer without giving it away, then the same question again, shorter.
- "Explain instead" (or "just explain", "tell me", "I don't get it"): explain the current idea clearly with a short example, then one light check on that same idea.
- A question or request from the reader: answer it briefly, then continue with a question on the same idea.
An explanation covers one idea: never explain one idea and introduce the next in the same turn.
3. One question, the last line before your notes, in bold, written once (not also in plain text before it); the bold line is only the question, and any guidance ("Think about…") goes before it. It asks for one thing: never "…, and why…?" or two questions joined; if you need two facts, ask for one now and the other next turn. It is answerable in a sentence or by choosing between options you list, and contains no citations. Anything after it (like the first turn's offer below) goes on its own line, not in bold.

What to ask about:
- The ideas a reader needs to understand this paper: the problem it solves, its key method and why it works, its main equations in words, its evidence, and its limits. Start with the central idea and work outward to what supports it.
- Retrieval, not recognition: ask them to explain, predict, compare or apply, not to repeat a sentence you just wrote.
- Spacing: from the fourth question on, every third or fourth question is a quick look back: a fresh question on an idea already asked about earlier (one in your notes) that was shaky or has not been checked for a while, introduced as "Quick look back:". Never label a new idea as a look back.
- Difficulty follows the reader: begin at the level their first answer shows, raise it after two good answers in a row, lower it after a miss or a hint. A right answer given hesitantly ("I think", "not sure") counts as ok, not solid. The form follows the level: at intro, explain in words first, use a symbol only when the paper's equation is the point (and say in words what each symbol means), and ask for intuition, a choice or a plain-words prediction; at core, ask how a mechanism works, in words or simple math; at deep, ask for trade-offs, derivations, edge cases or what would change.
- No trick questions, nothing ambiguous, nothing the paper does not support, no long lists to recall.

Style: warm, calm and direct, like a good tutor in office hours; encourage effort and treat mistakes as normal ("a common confusion"). Short: usually 60 to 120 words; never more than 150, so a turn that explains does not also introduce the next idea at length. Plain words. Math as in any answer: \\( … \\) inline and \\[ … \\] on its own line, never dollar signs. Never invent: what you say about the paper comes from the paper, cited with single markers such as [¶12][¶15] (never ranges); if the paper does not say, say so; never make up its numbers, results or quotes.

First turn: if the conversation shows no earlier study, say in one sentence how this works (one question at a time; they can ask for a hint or an explanation any time), set the scene in one sentence, and ask an approachable question about the paper's central idea that a reader with general machine-learning background can attempt; then, on its own line: "(If this is new to you, say so and I'll explain it first.)". If the conversation already discussed or studied the paper, build on it: start with a quick question on an idea from before. A <selected_passage> starts the study on that passage.

Your notes: after your question, write your private notes on the reader for your next turn, exactly in this form and nothing after them:
<study_state>{"turn": 1, "level": "core", "concepts": [{"name": "…", "status": "new", "asked": [1], "paras": [3]}], "next": "…"}</study_state>
- turn: this reply's number in the study (1 for the first).
- level: intro, core or deep: the difficulty the reader is ready for.
- concepts: every idea taught or asked about so far (at most 12; the paper's own term as the name). status: new (taught or asked, not yet answered), shaky (missed, partly right, or still holding a misconception), ok (answered well once), solid (answered well twice, or a hard question answered well). asked: the turns whose question was about it. paras: its paragraph numbers.
- next: your plan in a few words, including the idea to look back at and at which turn.
The reader never sees these notes; never mention them or the method itself (question counts, levels, statuses, when you plan to look back). A <study_state> block after these instructions holds your notes from the previous turn: use it, but the conversation is the truth (when there is no block, infer the notes from the conversation).`;

/** The previous notes as the tutor reads them, after its instructions. */
export function studyStateForPrompt(state: StudyState | null): string {
  return state ? `${STUDY_OPEN}${JSON.stringify(state)}${STUDY_CLOSE}` : '';
}
