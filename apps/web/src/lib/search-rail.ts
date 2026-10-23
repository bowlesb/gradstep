// Searching papers beside the reading view (owner, 2026-10-22: "the search bar should probably be on the left … in the
// same area as the list of articles would be", like Mail). Off the Library route, search is a mode of the left panel: its
// own field, the Library | ML papers switch and a list of papers; a result opens in the middle and, beside the paper,
// the list stays. On the Library route the table itself is the list. Pure logic here; the panel is ui/SearchRail.tsx.

export const RAIL_MATCHES = 50;

/** What the list can match a library paper by. */
export interface MatchFields {
  title: string; authors: readonly string[]; tags: readonly string[]; source: string; venue?: string | null;
  added: number | null; archived: boolean;
}

/** How well a paper matches, lower is better; null when it doesn't. Title beats authors beats tags and the rest. */
export function matchRank(fields: MatchFields, needle: string): number | null {
  const title = fields.title.toLowerCase();
  if (title.startsWith(needle)) return 0;
  if (title.split(/[^\p{L}\p{N}]+/u).some(word => word.startsWith(needle))) return 1;
  if (title.includes(needle)) return 2;
  if (fields.authors.some(a => a.toLowerCase().includes(needle))) return 3;
  if ([...fields.tags, fields.source, fields.venue ?? ''].some(s => s.toLowerCase().includes(needle))) return 4;
  return null;
}

/** The library papers a query matches, best first (then the newest added, then by title); archived papers aren't
 * offered. `total` counts every match, `shown` at most `limit` of them. */
export function libraryMatches<T extends MatchFields>(rows: readonly T[], query: string, limit = RAIL_MATCHES): { shown: T[]; total: number } {
  const needle = query.trim().toLowerCase();
  if (!needle) return { shown: [], total: 0 };
  const ranked: { row: T; rank: number }[] = [];
  for (const row of rows) {
    if (row.archived) continue;
    const rank = matchRank(row, needle);
    if (rank !== null) ranked.push({ row, rank });
  }
  ranked.sort((a, b) => a.rank - b.rank || (b.row.added ?? 0) - (a.row.added ?? 0) || a.row.title.localeCompare(b.row.title));
  return { shown: ranked.slice(0, limit).map(r => r.row), total: ranked.length };
}

/** Enter in the panel's field: ML papers searches again; the library opens its best match, or, when the library has
 * none, asks ML paper search for the same words. Nothing for an empty field. */
export function enterAction({ ml, query, matches }: { ml: boolean; query: string; matches: number }): 'run-ml' | 'open-first' | 'search-ml' | null {
  if (!query.trim()) return null;
  if (ml) return 'run-ml';
  return matches > 0 ? 'open-first' : 'search-ml';
}

/** Esc in the field: clear what's typed, then leave search. */
export function escapeStep(text: string): 'clear' | 'close' {
  return text ? 'clear' : 'close';
}

/** Switching between the library and ML papers carries the typed words over when the side switched to has none
 * (audit S4); otherwise that side keeps its own words. */
export function carriedQuery(from: string, to: string): string {
  return to.trim() ? to : from;
}

export type SearchRoute = 'library' | 'paper' | 'feed' | 'notes';
/** The left panel's search mode: whether it shows, whether it lists ML papers, and how the left panel was before it
 * (put back exactly on leaving: Contents or closed, reader audit R2). */
export interface RailSearch { open: boolean; ml: boolean; restore: { route: SearchRoute; leftOpen: boolean } | null }
export const RAIL_CLOSED: RailSearch = { open: false, ml: false, restore: null };
export type RailEvent =
  | { type: 'open'; route: SearchRoute; leftOpen: boolean; ml?: boolean }
  | { type: 'ml' } | { type: 'library' }
  /** A result opened its paper: beside it (an inline panel) the list stays; over it (a drawer) search ends. */
  | { type: 'opened'; inline: boolean }
  /** The route changed: the Library has its own search (its table), so search mode ends there. */
  | { type: 'route'; route: SearchRoute }
  | { type: 'close' };

export function railReducer(state: RailSearch, event: RailEvent): RailSearch {
  switch (event.type) {
    case 'open':
      if (event.route === 'library') return state;
      return { open: true, ml: event.ml ?? state.ml, restore: state.open && state.restore ? state.restore : { route: event.route, leftOpen: event.leftOpen } };
    case 'ml': return state.open ? { ...state, ml: true } : state;
    case 'library': return state.open ? { ...state, ml: false } : state;
    case 'opened': return event.inline ? state : RAIL_CLOSED;
    case 'route': return event.route === 'library' && state.open ? RAIL_CLOSED : state;
    case 'close': return state.open ? RAIL_CLOSED : state;
  }
}

/** How the left panel goes back when search ends: open or closed as it was, when still on the route it was opened from;
 * a drawer otherwise just closes. */
export function restoreLeft(state: RailSearch, route: SearchRoute, inline: boolean): boolean | null {
  if (state.restore && state.restore.route === route) return state.restore.leftOpen;
  return inline ? null : false;
}
