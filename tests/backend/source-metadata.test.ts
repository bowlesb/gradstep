import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ARXIV_CATEGORIES, ARXIV_LICENSES, comparableTitle, familyName, licenseFromLabel, licenseFromRights, SourceMetadataError,
  validateSourceMetadata } from '../../supabase/functions/_shared/source-metadata.ts';

// The device metadata contract (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3–5.4), the same rules as the database's
// app_private.valid_source_metadata (tests/database/device_source_metadata.sql).

const now = new Date('2026-10-15T12:00:00Z');
const good = () => ({ format: 'arxiv-source-metadata-v1', source_id: '2305.18290', revision: 3, origin: 'arxiv_html',
  title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', authors: ['Rafael Rafailov', 'Archit Sharma'],
  abstract: 'While large-scale unsupervised language models learn broad world knowledge.', categories: ['cs.LG'],
  license_uri: 'https://creativecommons.org/licenses/by/4.0/', version_date: '2024-07-29', html_available: true, observed_at: '2026-10-15T10:00:00Z' });
const refused = (change: Record<string, unknown>, field: string, expected = {}) =>
  assert.throws(() => validateSourceMetadata({ ...good(), ...change }, expected, now), (e: unknown) => e instanceof SourceMetadataError && e.field === field, JSON.stringify(change).slice(0, 80));

test('a good record is normalized: NFC, whitespace collapsed, observation time canonical', () => {
  const { metadata, flags } = validateSourceMetadata({ ...good(), title: '  Direct  Preference\nOptimization ', authors: ['Rafael   Rafailov'],
    abstract: 'Line one.\n\n\n\nLine  two.', observed_at: '2026-10-15T12:00:00+02:00' }, { sourceID: '2305.18290', revision: 3 }, now);
  assert.equal(metadata.title, 'Direct Preference Optimization');
  assert.deepEqual(metadata.authors, ['Rafael Rafailov']);
  assert.equal(metadata.abstract, 'Line one.\n\nLine two.');
  assert.equal(metadata.observed_at, '2026-10-15T10:00:00.000Z');
  assert.deepEqual(flags, []);
  assert.equal(validateSourceMetadata({ ...good(), title: 'Café' }, {}, now).metadata.title, 'Café', 'NFC');
  // Old-style identifiers and nullable fields.
  assert.equal(validateSourceMetadata({ ...good(), source_id: 'hep-th/9711200', version_date: '1997-11-27', abstract: null, license_uri: null, categories: [] }, {}, now).metadata.source_id, 'hep-th/9711200');
  // A first version from another month than its identifier is flagged, not refused.
  assert.deepEqual(validateSourceMetadata({ ...good(), revision: 1, version_date: '2023-06-02' }, {}, now).flags, ['v1_month_differs']);
});

test('hostile and malformed records are refused, naming the field', () => {
  refused({ extra: 1 }, 'extra');
  refused({ format: 'arxiv-source-metadata-v2' }, 'format');
  refused({ source_id: '2305.18290v3' }, 'source_id');
  refused({ source_id: '../../etc' }, 'source_id');
  refused({}, 'source_id', { sourceID: '2305.18291' });
  refused({ revision: '3' }, 'revision');
  refused({ revision: 0 }, 'revision');
  refused({}, 'revision', { revision: 2 });
  refused({ origin: 'server' }, 'origin');
  refused({ title: '' }, 'title');
  refused({ title: 'x'.repeat(2001) }, 'title');
  refused({ title: 'a‮b' }, 'title');
  refused({ title: 'a\u0000b' }, 'title');
  refused({ title: 42 }, 'title');
  refused({ authors: [] }, 'authors');
  refused({ authors: Array.from({ length: 513 }, (_, i) => `A ${i}`) }, 'authors');
  refused({ authors: ['ok', 7] }, 'authors');
  refused({ authors: ['x'.repeat(257)] }, 'authors');
  refused({ abstract: 'x'.repeat(24_001) }, 'abstract');
  refused({ categories: ['cs.XX'] }, 'categories');
  refused({ categories: ['cs.LG', 'cs.LG'] }, 'categories');
  refused({ categories: 'cs.LG' }, 'categories');
  refused({ license_uri: 'https://example.com/mine' }, 'license_uri');
  refused({ version_date: '2023-04-30' }, 'version_date');
  refused({ version_date: '2024-02-30' }, 'version_date');
  refused({ version_date: '2026-10-20' }, 'version_date');
  refused({ version_date: '1990-01-01', source_id: 'hep-th/9711200' }, 'version_date');
  refused({ html_available: 'yes' }, 'html_available');
  refused({ observed_at: '2026-10-16T12:00:00Z' }, 'observed_at');
  refused({ observed_at: 'yesterday' }, 'observed_at');
  refused({ authors: Array.from({ length: 200 }, (_, i) => `Author Name Number ${i} `.repeat(8).trim().slice(0, 250)) }, 'size');
  assert.throws(() => validateSourceMetadata([good()], {}, now), SourceMetadataError);
  assert.throws(() => validateSourceMetadata(null, {}, now), SourceMetadataError);
});

test('licences map from page labels and DataCite rights; anything unknown is null', () => {
  assert.equal(licenseFromLabel('License: CC BY 4.0'), 'https://creativecommons.org/licenses/by/4.0/');
  assert.equal(licenseFromLabel('\n    License: arXiv.org perpetual non-exclusive license\n  '), 'http://arxiv.org/licenses/nonexclusive-distrib/1.0/'); // egress-ok: namespace
  assert.equal(licenseFromLabel('License: CC BY-NC-SA 4.0'), 'https://creativecommons.org/licenses/by-nc-sa/4.0/');
  assert.equal(licenseFromLabel('License: Something else'), null);
  assert.equal(licenseFromRights({ rightsUri: 'https://creativecommons.org/licenses/by/4.0/legalcode', rightsIdentifier: 'cc-by-4.0' }), 'https://creativecommons.org/licenses/by/4.0/');
  assert.equal(licenseFromRights({ rightsUri: 'http://arxiv.org/licenses/nonexclusive-distrib/1.0/' }), 'http://arxiv.org/licenses/nonexclusive-distrib/1.0/'); // egress-ok: namespace
  assert.equal(licenseFromRights({ rightsUri: 'http://creativecommons.org/publicdomain/zero/1.0/' }), 'https://creativecommons.org/publicdomain/zero/1.0/');
  assert.equal(licenseFromRights({ rightsUri: 'https://example.com/' }), null);
});

test('the TypeScript tables and the migration seed are the same', () => {
  const sql = readFileSync(new URL('../../supabase/migrations/202610150071_device_source_metadata.sql', import.meta.url), 'utf8');
  const categories = /insert into app_private\.arxiv_categories\(code\) values\s*([\s\S]*?);/.exec(sql)![1];
  assert.deepEqual([...categories.matchAll(/\('([^']+)'\)/g)].map(m => m[1]), [...ARXIV_CATEGORIES]);
  const licenses = /insert into app_private\.arxiv_licenses\(uri,label\) values\s*([\s\S]*?);/.exec(sql)![1];
  assert.deepEqual([...licenses.matchAll(/\('([^']+)','((?:[^']|'')+)'\)/g)].map(m => [m[1], m[2]]), ARXIV_LICENSES.map(l => [l.uri, l.labels[0]]));
  assert.equal(new Set(ARXIV_CATEGORIES).size, ARXIV_CATEGORIES.length);
});

test('verification compares what matters: titles without case or punctuation, family names either way round', () => {
  assert.equal(comparableTitle('Direct Preference Optimization: Your Language Model is Secretly a Reward Model'),
    comparableTitle('Direct Preference Optimization — Your Language Model Is Secretly a Reward Model'));
  assert.equal(comparableTitle('Scaling $x^2$ laws'), comparableTitle('Scaling laws'));
  assert.notEqual(comparableTitle('Direct Preference Optimization'), comparableTitle('Indirect Preference Optimization'));
  assert.equal(familyName('Rafailov, Rafael'), 'rafailov');
  assert.equal(familyName('Rafael Rafailov'), 'rafailov');
  assert.equal(familyName('Jean-Luc  Picard'), 'picard');
});
