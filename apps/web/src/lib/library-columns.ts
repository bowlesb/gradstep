// Presentation only. No paper, account or reading data belongs in this preference.
export const LIBRARY_COLUMNS = [
  { key: 'authors', label: 'Authors', width: 168 },
  { key: 'year', label: 'Year', width: 64 },
  { key: 'tags', label: 'Tags', width: 184 },
  { key: 'added', label: 'Added', width: 100 },
  { key: 'opened', label: 'Opened', width: 100 },
  { key: 'progress', label: 'Progress', width: 112 },
] as const;
export type LibraryColumn = typeof LIBRARY_COLUMNS[number]['key'];
export const LIBRARY_COLUMNS_KEY = 'gradstep.library.columns.v1';
const KNOWN = new Set<string>(LIBRARY_COLUMNS.map(c => c.key));

export const defaultLibraryColumns = (compact: boolean): readonly LibraryColumn[] => compact
  ? ['year', 'progress'] : LIBRARY_COLUMNS.map(c => c.key);

/** A tiny, versioned and closed preference. Invalid or oversized data is ignored whole. */
export function parseLibraryColumns(raw: string | null): readonly LibraryColumn[] | null {
  if (raw === null || raw.length > 256) return null;
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 2
      || value.version !== 1 || !Array.isArray(value.columns) || value.columns.length > LIBRARY_COLUMNS.length
      || !value.columns.every((key: unknown) => typeof key === 'string' && KNOWN.has(key))
      || new Set(value.columns).size !== value.columns.length) return null;
    // Display order is fixed and independent of the order in localStorage.
    return LIBRARY_COLUMNS.filter(c => value.columns.includes(c.key)).map(c => c.key);
  } catch { return null; }
}
