// Presentation only. No paper, account or reading data belongs in this preference.
// The apps' columns in their order (LibraryTableView): Venue, Source, Pages and Chats since B9.
export const LIBRARY_COLUMNS = [
  { key: 'device', label: 'Device', width: 64 },
  { key: 'authors', label: 'Authors', width: 168 },
  { key: 'year', label: 'Year', width: 64 },
  { key: 'venue', label: 'Venue', width: 160 },
  { key: 'tags', label: 'Tags', width: 184 },
  { key: 'source', label: 'Source', width: 120 },
  { key: 'pages', label: 'Pages', width: 64 },
  { key: 'added', label: 'Added', width: 100 },
  { key: 'opened', label: 'Opened', width: 100 },
  { key: 'chats', label: 'Chats', width: 64 },
  { key: 'progress', label: 'Progress', width: 112 },
] as const;
export type LibraryColumn = typeof LIBRARY_COLUMNS[number]['key'];
export const LIBRARY_COLUMNS_KEY = 'gradstep.library.columns.v1';
const KNOWN = new Set<string>(LIBRARY_COLUMNS.map(c => c.key));

/** The apps' defaults (LibraryMetadata): a phone shows Device, Authors, Year, Added, Opened, Chats and Progress; a wider
 * window Tags too. Venue, Source and Pages are chosen in Columns. */
export const defaultLibraryColumns = (compact: boolean): readonly LibraryColumn[] => compact
  ? ['device', 'authors', 'year', 'added', 'opened', 'chats', 'progress'] : ['device', 'authors', 'year', 'tags', 'added', 'opened', 'chats', 'progress'];
export const LIBRARY_COLUMNS_VERSION = 3;

/** A tiny, versioned and closed preference. Invalid or oversized data is ignored whole. */
export function parseLibraryColumns(raw: string | null): readonly LibraryColumn[] | null {
  if (raw === null || raw.length > 256) return null;
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 2
      || ![1, 2, 3].includes(value.version) || !Array.isArray(value.columns) || value.columns.length > LIBRARY_COLUMNS.length
      || !value.columns.every((key: unknown) => typeof key === 'string' && KNOWN.has(key))
      || new Set(value.columns).size !== value.columns.length) return null;
    // Display order is fixed and independent of the order in localStorage. Older choices gain what was added since,
    // once: Device and Authors (version 2), Chats, which the owner asked to show (version 3).
    return LIBRARY_COLUMNS.filter(c => value.columns.includes(c.key) || value.version === 1 && ['device', 'authors'].includes(c.key)
      || value.version < 3 && c.key === 'chats').map(c => c.key);
  } catch { return null; }
}
