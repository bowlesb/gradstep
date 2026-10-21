// A catalog as a spreadsheet (owner, build 75: "We should have an option to save the entire catalog as csv"). Built and
// saved in this browser; nothing is sent. The native app's ScienceReaderCore LibraryCSV produces the same bytes from the
// same rows: tests/fixtures/library-csv/catalog.json is the shared contract.
import type { ClientEntry } from './device-pdf';
import { rows as buildRows } from './paper';

export interface LibraryCSVRow {
  title: string; authors: string[]; year: number | null; arxivID: string | null; doi: string | null; link: string | null;
  tags: string[];
  /** When the paper joined the library, as an ISO 8601 time; the file keeps its UTC day. */
  added: string | null;
}

export const LIBRARY_CSV_COLUMNS = ['Title', 'Authors', 'Year', 'arXiv ID', 'DOI', 'Link', 'Tags', 'Added'] as const;

/** One RFC 4180 cell. A value a spreadsheet would run as a formula (= + - @, or a leading tab or carriage return)
 * starts with an apostrophe, so opening the file never runs anything. */
function cell(value: string | number | null): string {
  let text = value === null ? '' : String(value);
  if (/^[=+\-@\t\r]/.test(text)) text = "'" + text;
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function day(added: string | null): string {
  if (!added) return '';
  const time = Date.parse(added);
  return Number.isFinite(time) ? new Date(time).toISOString().slice(0, 10) : '';
}

/** UTF-8 text with a byte-order mark (spreadsheets then read accents and other scripts correctly) and CRLF line ends. */
export function libraryCSV(rows: readonly LibraryCSVRow[]): string {
  const lines = [LIBRARY_CSV_COLUMNS.join(','), ...rows.map(r => [r.title, r.authors.join('; '), r.year, r.arxivID, r.doi, r.link, r.tags.join('; '), day(r.added)]
    .map(cell).join(','))];
  return '\uFEFF' + lines.map(line => line + '\r\n').join('');
}

/** "<catalog name>.csv", without characters a file system or a download would refuse. */
export function csvFileName(catalog: string): string {
  const name = catalog.replace(/[\\/:*?"<>|\u0000-\u001f\u007f]+/g, '-').replace(/\s+/g, ' ').replace(/^[\s.-]+|[\s.-]+$/g, '');
  return `${[...name].slice(0, 100).join('') || 'Library'}.csv`;
}

/** The catalog's papers as the library shows them: the effective tags, the exact arXiv version and its page. */
export function catalogCSVRows(entries: readonly ClientEntry[]): LibraryCSVRow[] {
  return buildRows(entries).map(row => {
    const e = row.entry;
    const revision = e.kind === 'local_pdf' ? undefined : e.source_revision ?? (e.kind === 'import' ? e.requested_revision : undefined);
    const arxiv = e.kind !== 'local_pdf' && e.source === 'arxiv' && e.source_id ? e.source_id + (revision ? `v${revision}` : '') : null;
    const link = arxiv ? `https://arxiv.org/abs/${arxiv}` : e.kind !== 'local_pdf' && e.source_url ? e.source_url : null;
    const added = e.kind === 'import' ? e.added_at ?? e.metadata_recorded_at : e.added_at;
    return {
      title: e.metadata?.title ?? row.title, authors: e.metadata?.authors ?? [], year: row.year, arxivID: arxiv, doi: null, link,
      tags: row.tags, added: typeof added === 'number' && added > 0 ? new Date(added).toISOString() : null,
    };
  });
}
