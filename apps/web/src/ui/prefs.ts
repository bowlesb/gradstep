// Per-browser presentation preferences (theme, pane widths and visibility, text size). Conveniences
// only: storage can be unavailable (private windows, blocked site data) and every read falls back.
import { useCallback, useEffect, useState, useSyncExternalStore } from 'react';
import { defaultLibraryColumns, LIBRARY_COLUMNS_KEY, parseLibraryColumns, type LibraryColumn, LIBRARY_COLUMNS_VERSION } from '../lib/library-columns';

export function readStored<T>(key: string, fallback: T, valid: (value: unknown) => boolean): T {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return fallback;
    const value = JSON.parse(raw) as unknown;
    return valid(value) ? value as T : fallback;
  } catch { return fallback; }
}
export function writeStored(key: string, value: unknown) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* per-viewer convenience only */ }
}

export function useStored<T>(key: string, fallback: T, valid: (value: unknown) => boolean): [T, (next: T | ((previous: T) => T)) => void] {
  const [value, setValue] = useState<T>(() => readStored(key, fallback, valid));
  const update = useCallback((next: T | ((previous: T) => T)) => {
    setValue(previous => {
      const value = typeof next === 'function' ? (next as (previous: T) => T)(previous) : next;
      writeStored(key, value);
      return value;
    });
  }, [key]);
  return [value, update];
}

export function useMedia(query: string): boolean {
  const subscribe = useCallback((notify: () => void) => {
    const list = matchMedia(query);
    list.addEventListener('change', notify);
    return () => list.removeEventListener('change', notify);
  }, [query]);
  return useSyncExternalStore(subscribe, () => matchMedia(query).matches, () => false);
}

// ---------- Library columns ----------

const compactLibrary = () => typeof matchMedia === 'function' && matchMedia('(max-width: 759px)').matches;
export function useLibraryColumns() {
  const [columns, setColumns] = useState<readonly LibraryColumn[]>(() => {
    try { return parseLibraryColumns(localStorage.getItem(LIBRARY_COLUMNS_KEY)) ?? defaultLibraryColumns(compactLibrary()); }
    catch { return defaultLibraryColumns(compactLibrary()); }
  });
  const update = useCallback((next: readonly LibraryColumn[]) => {
    setColumns(next);
    writeStored(LIBRARY_COLUMNS_KEY, { version: LIBRARY_COLUMNS_VERSION, columns: next });
  }, []);
  // Defaults differ at first use or an explicit Reset only. Resizing never hides a chosen column.
  const reset = useCallback(() => update(defaultLibraryColumns(compactLibrary())), [update]);
  return { columns, setColumns: update, reset };
}

// ---------- Theme ----------

export type Theme = 'system' | 'light' | 'dark';
const THEME_KEY = 'gradstep.theme';
const isTheme = (v: unknown) => v === 'system' || v === 'light' || v === 'dark';

/** Applied before the first render (main.tsx) and whenever it changes. */
export function applyTheme(theme: Theme = readStored<Theme>(THEME_KEY, 'system', isTheme)) {
  if (theme === 'system') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
}

export function useTheme(): { theme: Theme; resolved: 'light' | 'dark'; setTheme: (theme: Theme) => void } {
  const [theme, setTheme] = useStored<Theme>(THEME_KEY, 'system', isTheme);
  const systemDark = useMedia('(prefers-color-scheme: dark)');
  useEffect(() => applyTheme(theme), [theme]);
  return { theme, resolved: theme === 'system' ? (systemDark ? 'dark' : 'light') : theme, setTheme };
}

// ---------- Panes ----------

export type Route = 'library' | 'paper' | 'feed' | 'notes';
export interface PaneLayout { left: number; right: number; open: Record<Route, { left: boolean; right: boolean }>;
  /** Which panes the reader has shown or hidden themselves (`paper.left`); a default can follow the window until then. */
  chosen?: string[] }
/** Below this width a paper opens with its contents panel closed unless the reader chose otherwise (UX audit R26: at
 * iPad widths it took a third of the screen; the iPad opens Contents as a sheet). */
export const PAPER_RAIL_DEFAULT_MIN = 1100;
/** Whether a side pane shows: the reader's own choice once made; for a paper's contents panel at narrower windows,
 * closed until then. */
export function paneWanted(layout: PaneLayout, route: Route, side: 'left' | 'right', width: number): boolean {
  const wanted = layout.open[route][side];
  if (route === 'paper' && side === 'left' && width < PAPER_RAIL_DEFAULT_MIN && !layout.chosen?.includes('paper.left')) return false;
  return wanted;
}
export const PANE_LIMITS = { left: { min: 200, max: 460, initial: 272 }, right: { min: 300, max: 640, initial: 392 }, center: 440 };
const LAYOUT_KEY = 'gradstep.layout.v1';
const DEFAULT_LAYOUT: PaneLayout = {
  left: PANE_LIMITS.left.initial, right: PANE_LIMITS.right.initial,
  // The legacy app: the library alone; a paper beside its chat. Each route remembers its own choice.
  open: { library: { left: true, right: false }, paper: { left: true, right: true }, feed: { left: true, right: false }, notes: { left: true, right: false } },
};
const validLayout = (v: unknown) => {
  const l = v as PaneLayout;
  return !!l && typeof l.left === 'number' && typeof l.right === 'number' && !!l.open
    && (['library', 'paper', 'feed'] as const).every(r => typeof l.open[r]?.left === 'boolean' && typeof l.open[r]?.right === 'boolean')
    && (l.open.notes === undefined || (typeof l.open.notes?.left === 'boolean' && typeof l.open.notes?.right === 'boolean'));
};
export const clampWidth = (side: 'left' | 'right', width: number) => Math.round(Math.min(PANE_LIMITS[side].max, Math.max(PANE_LIMITS[side].min, width)));

export function usePaneLayout() {
  const [stored, setLayout] = useStored<PaneLayout>(LAYOUT_KEY, DEFAULT_LAYOUT, validLayout);
  // A layout saved before Notes has no entry for it: Notes starts with the list beside the note.
  const layout: PaneLayout = stored.open.notes ? stored : { ...stored, open: { ...stored.open, notes: DEFAULT_LAYOUT.open.notes } };
  const setWidth = useCallback((side: 'left' | 'right', width: number) => setLayout(l => ({ ...l, [side]: clampWidth(side, width) })), [setLayout]);
  const setOpen = useCallback((route: Route, side: 'left' | 'right', open: boolean) =>
    setLayout(l => ({ ...l, open: { ...l.open, [route]: { ...(l.open[route] ?? DEFAULT_LAYOUT.open[route]), [side]: open } },
      chosen: [...new Set([...(Array.isArray(l.chosen) ? l.chosen.filter(c => typeof c === 'string') : []), `${route}.${side}`])] })), [setLayout]);
  const reset = useCallback((side: 'left' | 'right') => setLayout(l => ({ ...l, [side]: PANE_LIMITS[side].initial })), [setLayout]);
  return { layout, setWidth, setOpen, reset };
}
