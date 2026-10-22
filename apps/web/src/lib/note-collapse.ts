// Collapsed snippets (owner, 2026-10-22: "having the ability to collapse individual snippets would be helpful (so you can
// just see the date/times)"; docs/architecture/NOTES_AND_SNIPPETS.md "Collapsible snippet cards"). A collapsed entry is
// one line: its time, a short form of its paper's title and the first words of the reader's comment. Which entries are
// collapsed is remembered in this browser only (never synced, never sent). The apps apply the same rules
// (ScienceReaderCore NoteCollapse.swift) against the same cases (tests/fixtures/notes/collapsed-lines.json).

export const TITLE_LIMIT = 32;
/** Narrow screens (phones): a shorter title leaves room for the comment's first words. */
export const COMPACT_TITLE_LIMIT = 20;
export const WORD_LIMIT = 8;
export const WORDS_CHARACTER_LIMIT = 60;

const collapse = (text: string) => text.split(/\s+/).filter(Boolean).join(' ');
const chars = (text: string) => Array.from(text);
const trimEnd = (text: string) => text.replace(/[\s:;,.\-–—]+$/u, '');

/** At most `limit` characters: whole words when the cut falls between words, else ending at the last space at or after
 * `minimumWordCut`, else a hard cut. */
function cut(text: string, limit: number, minimumWordCut: number): string {
  const all = chars(text);
  let head = all.slice(0, limit);
  const atBoundary = all.length > limit && all[limit] === ' ';
  const space = head.lastIndexOf(' ');
  if (!atBoundary && space >= minimumWordCut) head = head.slice(0, space);
  return trimEnd(head.join(''));
}

/** The title, or its first words within `limit` characters with "…". */
export function shortTitle(title: string, limit = TITLE_LIMIT): string {
  const text = collapse(title);
  return chars(text).length > limit ? `${cut(text, limit - 1, Math.min(12, Math.floor(limit / 2)))}…` : text;
}

/** The first words of the comment; without one, of the quotation; without either, the item's label ("Figure 2"). */
export function firstWords(comment: string, quote: string | null | undefined, label: string | null | undefined): string {
  const source = [comment, quote ?? '', label ?? ''].map(collapse).find(Boolean) ?? '';
  const words = source ? source.split(' ') : [];
  let text = words.slice(0, WORD_LIMIT).join(' ');
  let shortened = words.length > WORD_LIMIT;
  if (chars(text).length > WORDS_CHARACTER_LIMIT) { text = cut(text, WORDS_CHARACTER_LIMIT - 1, 20); shortened = true; }
  return shortened ? `${trimEnd(text)}…` : text;
}

/** "3:04 PM · Direct Preference Optimization… · The early improvement is the interesting part." */
export function collapsedLine(time: string, title: string, comment: string, quote?: string | null, label?: string | null, titleLimit = TITLE_LIMIT): string {
  return [time, shortTitle(title, titleLimit), firstWords(comment, quote, label)].filter(Boolean).join(' · ');
}

// ---------- This browser's memory ----------

export const COLLAPSE_KEY_PREFIX = 'gradstep.notes.collapsed.';
type Storage = Pick<globalThis.Storage, 'getItem' | 'setItem' | 'removeItem'>;
function storage(): Storage | null {
  try { return globalThis.localStorage ?? null; } catch { return null; }
}

/** Entry IDs collapsed in this collection, in this browser (empty when storage is unavailable). */
export function collapsedEntries(noteID: string, store: Storage | null = storage()): Set<string> {
  try {
    const raw = store?.getItem(COLLAPSE_KEY_PREFIX + noteID);
    const ids: unknown = raw ? JSON.parse(raw) : [];
    return new Set(Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : []);
  } catch { return new Set(); }
}

/** Remembers the set, keeping only entries the collection still has (when `existing` is given); empty removes the key.
 * A storage failure (private windows, blocked site data) leaves the choice for this page only. */
export function rememberCollapsed(noteID: string, ids: Set<string>, existing?: Iterable<string>, store: Storage | null = storage()): void {
  const keep = existing ? new Set(existing) : null;
  const kept = [...ids].filter(id => !keep || keep.has(id)).sort();
  try {
    if (!kept.length) store?.removeItem(COLLAPSE_KEY_PREFIX + noteID);
    else store?.setItem(COLLAPSE_KEY_PREFIX + noteID, JSON.stringify(kept));
  } catch { /* remembered for this page only */ }
}
