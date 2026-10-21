// Catalog CSV export (owner, build 75): the shared fixture both the browser and ScienceReaderCore LibraryCSV must match
// byte for byte, the catalog's rows as the library shows them, and a safe file name.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Item } from '../src/lib/library';
import { catalogCSVRows, csvFileName, libraryCSV, type LibraryCSVRow } from '../src/lib/library-csv';

const fixture = JSON.parse(readFileSync(new URL('../../../tests/fixtures/library-csv/catalog.json', import.meta.url), 'utf8')) as { columns: string[]; rows: LibraryCSVRow[]; csv: string };

describe('catalog CSV', () => {
  it('produces the shared fixture exactly', () => {
    expect(libraryCSV(fixture.rows)).toBe(fixture.csv);
    expect(fixture.csv.startsWith('\uFEFF' + fixture.columns.join(',') + '\r\n')).toBe(true);
  });
  it('never lets a spreadsheet run a cell as a formula', () => {
    const csv = libraryCSV([{ title: '=1+1', authors: ['-2'], year: null, arxivID: null, doi: null, link: '@x', tags: ['+3'], added: null }]);
    expect(csv.split('\r\n')[1]).toBe("'=1+1,'-2,,,,'@x,'+3,");
  });
  it('maps a catalog paper: exact arXiv version, its page, effective tags, the added day', () => {
    const item: Item = { kind: 'item', id: 'aaaaaaaa-0000-4000-8000-000000000001', document_id: 'dddddddd-0000-4000-8000-000000000001',
      created_seq: 1, state_seq: 1, membership_revision: 1, visible: true, added_at: Date.parse('2026-10-19T17:17:42.512Z'), last_remove_seq: 0, scope: 'shared_catalog',
      page_count: 12, readiness: 'converted_ready', render_availability: 'available', source: 'arxiv', source_id: '2305.18290', source_revision: 3,
      source_url: 'https://arxiv.org/abs/2305.18290v3', metadata: { title: 'Direct Preference Optimization', authors: ['Rafael Rafailov', 'Archit Sharma'], categories: ['cs.LG'], published_at: '2023-05-29' },
      tags: ['Preference optimization', 'Large language models'], user_tags: [], hidden_tags: [] } as Item;
    expect(catalogCSVRows([item])).toEqual([{ title: 'Direct Preference Optimization', authors: ['Rafael Rafailov', 'Archit Sharma'], year: 2023,
      arxivID: '2305.18290v3', doi: null, link: 'https://arxiv.org/abs/2305.18290v3', tags: ['Preference optimization'], added: '2026-10-19T17:17:42.512Z' }]);
  });
  it('names the file after the catalog without characters a file system refuses', () => {
    expect(csvFileName('Reading list')).toBe('Reading list.csv');
    expect(csvFileName('a/b: c?')).toBe('a-b- c.csv');
    expect(csvFileName('  ..  ')).toBe('Library.csv');
  });
});
