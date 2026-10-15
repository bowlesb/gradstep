import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DATACITE_MAX_BYTES, DATACITE_USER_AGENT, DataCiteError, dataciteBatchURL, dataciteEvidence, dataciteSourceMetadata, fetchDataCiteRecord,
  fetchDataCiteRecords, parseDataCiteRecord } from '../../supabase/functions/_shared/datacite.ts';

// DataCite as the server's (and the browser's) arXiv metadata source (docs/architecture/ARXIV_DEVICE_ONLY.md §5.10).
// Fixtures were recorded once from api.datacite.org on 2026-10-15; no-abstract.json is 2305.18290 with its
// description removed (no live arXiv record without an abstract was found).
const fixture = (name: string) => JSON.parse(readFileSync(new URL(`./fixtures/datacite/${name}.json`, import.meta.url), 'utf8'));

test('a CC BY record: latest version, given-family names, primary category first, licence and version dates', () => {
  const record = parseDataCiteRecord(fixture('2305.18290').data)!;
  assert.equal(record.sourceID, '2305.18290');
  assert.equal(record.version, 3);
  assert.equal(record.title, 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.deepEqual(record.authors.slice(0, 3), ['Rafael Rafailov', 'Archit Sharma', 'Eric Mitchell']);
  assert.deepEqual(record.categories, ['cs.LG', 'cs.AI', 'cs.CL']);
  assert.equal(record.licenseURI, 'https://creativecommons.org/licenses/by/4.0/');
  assert.deepEqual(record.submitted, { 1: '2023-05-29', 2: '2023-12-13', 3: '2024-07-29' });
  assert.match(record.abstract!, /^While large-scale unsupervised language models/);
  const now = new Date('2026-10-15T12:00:00Z');
  const latest = dataciteSourceMetadata(record, 3, now);
  assert.equal(latest.origin, 'datacite'); assert.equal(latest.license_uri, record.licenseURI); assert.equal(latest.version_date, '2024-07-29');
  assert.equal(latest.html_available, false);
  // An older version: DataCite's licence describes the latest, so the older one's is unknown here.
  assert.equal(dataciteSourceMetadata(record, 1, now).license_uri, null);
  assert.throws(() => dataciteSourceMetadata(record, 4, now), DataCiteError);
  assert.deepEqual(dataciteEvidence(record), { origin: 'datacite', doi: '10.48550/arxiv.2305.18290', title: record.title, first_author: 'Rafael Rafailov',
    version: 3, license_uri: 'https://creativecommons.org/licenses/by/4.0/' });
});

test('a default-licence record with 157 authors, an old-style identifier, and a record without an abstract', () => {
  const deepseek = parseDataCiteRecord(fixture('2405.04434').data)!;
  assert.equal(deepseek.licenseURI, 'http://arxiv.org/licenses/nonexclusive-distrib/1.0/'); // egress-ok: namespace
  assert.equal(deepseek.authors.length, 157);
  assert.deepEqual(deepseek.categories, ['cs.CL', 'cs.AI']);
  const maldacena = parseDataCiteRecord(fixture('hep-th-9711200').data)!;
  assert.equal(maldacena.sourceID, 'hep-th/9711200');
  assert.deepEqual(maldacena.categories, ['hep-th']);
  assert.equal(maldacena.licenseURI, 'http://arxiv.org/licenses/assumed-1991-2003/'); // egress-ok: namespace
  const bare = parseDataCiteRecord(fixture('no-abstract').data)!;
  assert.equal(bare.abstract, null);
  assert.equal(dataciteSourceMetadata(bare, 3, new Date('2026-10-15T12:00:00Z')).abstract, null);
  // Not an arXiv DOI, or missing what a library entry needs.
  assert.equal(parseDataCiteRecord({ attributes: { doi: '10.5281/zenodo.1', titles: [{ title: 'x' }], version: '1', creators: [{ name: 'A' }] } }), null);
  assert.equal(parseDataCiteRecord({ attributes: { ...fixture('2305.18290').data.attributes, creators: [] } }), null);
  assert.equal(parseDataCiteRecord({ attributes: { ...fixture('2305.18290').data.attributes, version: 'three' } }), null);
  assert.equal(parseDataCiteRecord('nope'), null);
});

function fakeFetch(script: Array<{ status: number; body?: unknown; headers?: Record<string, string>; raw?: Uint8Array }>) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fetcher = async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    const next = script.shift()!;
    const body = next.raw ?? (next.body === undefined ? null : new TextEncoder().encode(JSON.stringify(next.body)));
    return new Response(body, { status: next.status, headers: next.headers });
  };
  return { calls, fetcher };
}

test('one paper, identified; 429 and 503 back off as asked; 404 is not found; oversized and invalid bodies are refused', async () => {
  const slept: number[] = [];
  const sleep = async (ms: number) => { slept.push(ms); };
  const ok = fakeFetch([{ status: 429, headers: { 'retry-after': '7' } }, { status: 503 }, { status: 200, body: fixture('2305.18290') }]);
  const record = await fetchDataCiteRecord('2305.18290', { fetch: ok.fetcher, sleep, attempts: 3 });
  assert.equal(record.version, 3);
  assert.deepEqual(slept, [7000, 4000], 'Retry-After, then exponential');
  assert.equal(ok.calls[0].url, 'https://api.datacite.org/dois/10.48550/arXiv.2305.18290');
  assert.equal((ok.calls[0].init?.headers as Record<string, string>)['user-agent'], DATACITE_USER_AGENT);
  assert.equal(ok.calls[0].init?.redirect, 'error');
  await assert.rejects(fetchDataCiteRecord('2305.18290', { fetch: fakeFetch([{ status: 404 }]).fetcher, sleep }), (e: DataCiteError) => e.code === 'datacite_not_found');
  await assert.rejects(fetchDataCiteRecord('2305.18290', { fetch: fakeFetch([{ status: 429 }, { status: 429 }]).fetcher, sleep, attempts: 2 }), (e: DataCiteError) => e.code === 'datacite_unavailable');
  await assert.rejects(fetchDataCiteRecord('2305.18290', { fetch: fakeFetch([{ status: 200, raw: new Uint8Array(DATACITE_MAX_BYTES + 1) }]).fetcher, sleep }), (e: DataCiteError) => e.code === 'datacite_too_large');
  await assert.rejects(fetchDataCiteRecord('2305.18290', { fetch: fakeFetch([{ status: 200, raw: new TextEncoder().encode('{nope') }]).fetcher, sleep }), (e: DataCiteError) => e.code === 'datacite_invalid');
  // A record for another paper is refused.
  await assert.rejects(fetchDataCiteRecord('2305.18291', { fetch: fakeFetch([{ status: 200, body: fixture('2305.18290') }]).fetcher, sleep }), (e: DataCiteError) => e.code === 'datacite_invalid');
  await assert.rejects(fetchDataCiteRecord('../../x', { fetch: fakeFetch([]).fetcher, sleep }), DataCiteError);
});

test('the browser identifies with mailto (it cannot set User-Agent) and sends no credentials; batches cap at 25', async () => {
  const browser = fakeFetch([{ status: 200, body: { data: [fixture('2305.18290').data, fixture('2405.04434').data] } }]);
  const records = await fetchDataCiteRecords(['2305.18290', '2405.04434', '2610.99999'], { fetch: browser.fetcher, browser: true });
  assert.deepEqual([...records.keys()], ['2305.18290', '2405.04434']);
  const url = new URL(browser.calls[0].url);
  assert.equal(url.searchParams.get('mailto'), 'hello@gradstep.ai');
  assert.equal(url.searchParams.get('ids'), '10.48550/arXiv.2305.18290,10.48550/arXiv.2405.04434,10.48550/arXiv.2610.99999');
  assert.equal((browser.calls[0].init?.headers as Record<string, string>)['user-agent'], undefined);
  assert.equal(browser.calls[0].init?.credentials, 'omit');
  assert.throws(() => dataciteBatchURL(Array.from({ length: 26 }, (_, i) => `2401.${String(10000 + i)}`)), DataCiteError);
});
