// Study mode (reworked 2026-10-22; docs/proposals/LEARNING_GUIDE.md): the chat becomes a tutor that asks one question at
// a time and backs off to a short explanation when the reader is shaky. The tutor keeps its own light notes on the reader
// (concepts covered, how sure the reader is, its plan) hidden in its reply; the server removes them and relays them as a
// `study_state` event, and this browser sends them back with the next turn. They live with the open chat in memory only:
// never shown, never written to this browser or to history. This module mirrors supabase/functions/_shared/chat-study.ts.

/** The entry offered after the starter questions and as the last suggested question in a paper chat. */
export const STUDY_ENTRY = 'Enter Study Mode – Quiz me and help me learn';
/** The reader's opening turn (a selected passage goes with it as the passage). */
export const STUDY_OPENING = 'Quiz me and help me learn this paper.';
/** What Hint and Explain instead send, as the reader's turn. */
export const STUDY_HINT = 'Give me a hint.';
export const STUDY_EXPLAIN = 'Explain it to me instead.';

export const STUDY_NOTES_LIMITS = Object.freeze({ concepts: 12, name: 60, asked: 8, paras: 6, next: 200, bytes: 4_096, turn: 500 });
export const STUDY_LEVELS = ['intro', 'core', 'deep'] as const;
export const STUDY_STATUSES = ['new', 'shaky', 'ok', 'solid'] as const;
export interface StudyConceptNote { name: string; status: typeof STUDY_STATUSES[number]; asked: number[]; paras: number[] }
export interface StudyNotes { turn: number; level: typeof STUDY_LEVELS[number]; concepts: StudyConceptNote[]; next: string }

function line(value: unknown, limit: number): string | null {
  if (typeof value !== 'string') return null;
  const text = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/[<>]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!text) return null;
  const scalars = [...text];
  return scalars.length <= limit ? text : scalars.slice(0, limit - 1).join('').trimEnd() + '…';
}
const numbers = (value: unknown, max: number, limit: number) => [...new Set((Array.isArray(value) ? value : [])
  .filter(n => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= max) as number[])].sort((a, b) => a - b).slice(-limit);

/** The tutor's notes from the server (untrusted), repaired as the server repairs them; null when unusable or over 4 KB. */
export function studyNotes(input: unknown): StudyNotes | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  const turn = Number.isSafeInteger(v.turn) && (v.turn as number) >= 1 ? Math.min(v.turn as number, STUDY_NOTES_LIMITS.turn) : 1;
  const level = (STUDY_LEVELS as readonly unknown[]).includes(v.level) ? v.level as StudyNotes['level'] : 'core';
  const byName = new Map<string, StudyConceptNote>();
  for (const raw of Array.isArray(v.concepts) ? v.concepts.slice(0, 64) : []) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const c = raw as Record<string, unknown>;
    const name = line(c.name, STUDY_NOTES_LIMITS.name);
    if (!name) continue;
    const status = (STUDY_STATUSES as readonly unknown[]).includes(c.status) ? c.status as StudyConceptNote['status'] : 'new';
    byName.delete(name.toLowerCase());
    byName.set(name.toLowerCase(), { name, status, asked: numbers(c.asked, STUDY_NOTES_LIMITS.turn, STUDY_NOTES_LIMITS.asked), paras: numbers(c.paras, 100_000, STUDY_NOTES_LIMITS.paras) });
  }
  const notes: StudyNotes = { turn, level, concepts: [...byName.values()].slice(-STUDY_NOTES_LIMITS.concepts), next: line(v.next, STUDY_NOTES_LIMITS.next) ?? '' };
  return new TextEncoder().encode(JSON.stringify(notes)).length <= STUDY_NOTES_LIMITS.bytes ? notes : null;
}

/** A suggestion that asks for a picture (a diagram or a visual explanation): the server's `isVisualFollowUp`
 * (chat-follow-ups.ts). When the model offered one, the generic Draw a diagram / Create a visual explanation rows give way. */
export const VISUAL_FOLLOW_UP_PATTERN = /^(?:please\s+)?(?:(?:draw|sketch|diagram|visuali[sz]e|illustrate)\b|(?:create|make|show|give me|build)\b.*\b(?:diagram|visual|flow ?chart|chart|mind ?map|concept map|picture|illustration)s?\b)/i;
export const isVisualFollowUp = (question: string) => VISUAL_FOLLOW_UP_PATTERN.test(question.trim());
