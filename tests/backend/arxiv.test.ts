import test from 'node:test';
import assert from 'node:assert/strict';
import { arxivAtomRecord, arxivCatalogArguments, arxivReference, arxivReuseEvidence, arxivURLs } from '../../supabase/functions/_shared/arxiv.ts';
import { sourceXML } from '../../supabase/functions/_shared/source-xml.ts';

const bytes = (value: string) => new TextEncoder().encode(value);
const observed = '2026-10-03T20:00:00.000Z';
const atom = (entry = '', namespace = 'http://www.w3.org/2005/Atom') => bytes(`<feed xmlns="${namespace}" xmlns:arxiv="http://arxiv.org/schemas/atom">${entry}</feed>`);
function entry(id = '1706.03762v2', extra = '', title = 'A synthetic &amp; bounded paper') {
  return `<entry><id>http://arxiv.org/abs/${id}</id><title>${title}</title>
    <published>2017-06-12T17:57:34Z</published><updated>2017-06-19T16:49:45Z</updated>
    <author><name>Ada Example</name><arxiv:affiliation>Example lab</arxiv:affiliation></author>
    <summary>A synthetic abstract with $x^2$.</summary><category term="cs.LG"/>
    <category term="stat.ML"/><category term="cs.LG"/>${extra}</entry>`;
}
const pinned = () => arxivAtomRecord(atom(entry()), arxivReference('1706.03762'));
function raw(license = 'http://creativecommons.org/licenses/by/4.0/', versions = ['v1', 'v2'], id = '1706.03762', extra = '') {
  return bytes(`<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
    <GetRecord><record><header><identifier>oai:arXiv.org:${id}</identifier></header>
    <metadata><arXivRaw xmlns="http://arxiv.org/OAI/arXivRaw/"><id>${id}</id>
    ${versions.map(version => `<version version="${version}"><date>Mon, 19 Jun 2017 16:49:45 GMT</date></version>`).join('')}
    ${license ? `<license>${license}</license>` : ''}${extra}</arXivRaw></metadata></record></GetRecord></OAI-PMH>`);
}

test('arXiv references pin requested versions and normalize supported link and historical aliases', () => {
  for (const input of ['1706.03762v2', ' arXiv:1706.03762v2 ', 'https://arxiv.org/abs/1706.03762v2', 'https://arxiv.org:443/abs/1706.03762v2', 'http://export.arxiv.org/pdf/1706.03762v2.pdf?download=1#page=3']) {
    assert.deepEqual(arxivReference(input), { sourceID: '1706.03762', revision: 2 });
  }
  assert.deepEqual(arxivReference('arXiv:math.CA/0611800v2'), { sourceID: 'math/0611800', revision: 2 });
  assert.deepEqual(arxivReference('hep-th/9901001'), { sourceID: 'hep-th/9901001', revision: null });
  assert.deepEqual(arxivReference('0704.0001'), { sourceID: '0704.0001', revision: null });
  assert.deepEqual(arxivReference('1501.00001'), { sourceID: '1501.00001', revision: null });
});

test('arXiv normalization rejects malformed identifiers, other origins, credentials, ports and path encodings', () => {
  for (const value of ['1700.03762', '1713.03762', '1706.3762', '0703.0001', '1412.00001', '1501.0001', '1706.00000',
    'hep-th/0712001', 'hep-th/9101001', 'hep-th/8801001', 'hep-th/9901000', 'math.evil/0301001',
    '1706.03762v0', '1706.03762v01', '1706.03762v2147483648', '1706.03762vv2', '1706.03762\nmalicious',
    'https://arxiv.org.evil.test/abs/1706.03762', 'https://evil.test/arxiv.org/abs/1706.03762',
    'https://arxiv.org@evil.test/abs/1706.03762', 'https://name:secret@arxiv.org/abs/1706.03762',
    'https://arxiv.org:8080/abs/1706.03762', 'file:///abs/1706.03762',
    'https://arxiv.org/abs/1706%2e03762', 'https://arxiv.org/search/1706.03762',
    'https://arxiv.org/abs/%2e%2e/abs/1706.03762', 'https://arxiv.org/abs/../abs/1706.03762',
    'https://arxiv.org/abs/1706.03762/extra', 'https://arxiv.org\\@evil.test/abs/1706.03762']) {
    assert.throws(() => arxivReference(value), /invalid_arxiv_id/, value);
  }
});

test('outbound addresses are derived, pinned PDF only; query and fragment input cannot propagate', () => {
  const addresses = arxivURLs(arxivReference('https://arxiv.org/pdf/1706.03762v2.pdf?token=discard#page=3'));
  assert.equal(addresses.abstract, 'https://arxiv.org/abs/1706.03762v2');
  assert.equal(addresses.pdf, 'https://arxiv.org/pdf/1706.03762v2');
  assert.equal(new URL(addresses.atom).searchParams.get('id_list'), '1706.03762v2');
  assert.equal(new URL(addresses.raw).searchParams.get('identifier'), 'oai:arXiv.org:1706.03762');
  assert.equal(arxivURLs(arxivReference('1706.03762')).pdf, null);
  assert.throws(() => arxivURLs({ sourceID: '//evil.test/path', revision: 1 }), /invalid_arxiv_id/);
});

test('Atom parsing uses namespace identity and bounded plain fields with source categories', () => {
  const record = pinned();
  assert.equal(record.revision, 2);
  assert.equal(record.metadata.title, 'A synthetic & bounded paper');
  assert.deepEqual(record.metadata.authors, ['Ada Example']);
  assert.deepEqual(record.metadata.categories, ['cs.LG', 'stat.ML']);
  assert.equal(record.metadata.venue, null);
  assert.equal(record.metadata.updated_at, '2017-06-19T16:49:45.000Z');
  const prefixed = bytes(new TextDecoder().decode(atom(entry())).replace('<feed xmlns=', '<a:feed xmlns:a=').replace('</feed>', '</a:feed>').replace('<entry>', '<entry xmlns="http://www.w3.org/2005/Atom">'));
  assert.deepEqual(arxivAtomRecord(prefixed, arxivReference('1706.03762')), record);
  assert.throws(() => arxivAtomRecord(atom(entry(), 'https://evil.test/Atom'), arxivReference('1706.03762')), /invalid_source_metadata/);
});

test('catalog persistence uses calendar dates without altering exact license-correlation timestamps', async () => {
  const record = pinned(), original = structuredClone(record);
  const catalog = arxivCatalogArguments(record);
  assert.equal(catalog.p_source_id, '1706.03762');
  assert.equal(catalog.p_revision, 2);
  assert.equal(catalog.p_metadata.published_at, '2017-06-12');
  assert.equal(catalog.p_metadata.updated_at, '2017-06-19');
  catalog.p_metadata.authors.push('Catalog-only mutation');
  catalog.p_metadata.categories.length = 0;
  assert.deepEqual(record, original);
  assert.equal((await arxivReuseEvidence(raw(), record, observed)).eligible, true);
  const sparse = arxivAtomRecord(atom('<entry><id>http://arxiv.org/abs/1706.03762v1</id><title>Sparse</title></entry>'), arxivReference('1706.03762'));
  assert.equal(arxivCatalogArguments(sparse).p_metadata.updated_at, null);
  record.metadata.updated_at = '2017-06-19';
  assert.throws(() => arxivCatalogArguments(record), /invalid_source_metadata/);
});

test('Atom resolution cannot substitute a different paper/version or mistake a source error for a result', () => {
  assert.throws(() => arxivAtomRecord(atom(entry('1706.03763v2')), arxivReference('1706.03762')), /source_identity_mismatch/);
  assert.throws(() => arxivAtomRecord(atom(entry()), arxivReference('1706.03762v1')), /source_identity_mismatch/);
  assert.throws(() => arxivAtomRecord(atom(entry('1706.03762')), arxivReference('1706.03762')), /source_identity_mismatch/);
  assert.throws(() => arxivAtomRecord(atom(entry() + entry()), arxivReference('1706.03762')), /source_identity_mismatch/);
  assert.throws(() => arxivAtomRecord(atom(), arxivReference('1706.03762')), /source_not_found/);
  assert.throws(() => arxivAtomRecord(atom('<entry><id>http://arxiv.org/api/errors</id><title>Error</title></entry>'), arxivReference('1706.03762')), /invalid_source_metadata/);
});

test('optional metadata remains absent and duplicate or unsafe field structure is rejected', () => {
  const minimal = atom('<entry><id>http://arxiv.org/abs/1706.03762v1</id><title>Minimal</title></entry>');
  assert.deepEqual(arxivAtomRecord(minimal, arxivReference('1706.03762')).metadata, {
    title: 'Minimal', authors: [], abstract: null, published_at: null, updated_at: null, categories: [], venue: null,
  });
  for (const body of [entry(undefined, '<title>Duplicate</title>'), entry(undefined, '', '<b>HTML</b>'),
    entry(undefined, '', 'x'.repeat(2001)), entry(undefined, '<category term="&lt;script&gt;"/>'),
    entry().replace('2017-06-19T16:49:45Z', '2017-02-30T16:49:45Z')]) {
    assert.throws(() => arxivAtomRecord(atom(body), arxivReference('1706.03762')), /invalid_source_metadata/);
  }
});

test('XML rejects external/internal entities, malformed structure, invalid UTF-8 and bounded resource excess', () => {
  for (const value of ['<!DOCTYPE feed SYSTEM "https://evil.test/entity"><feed/>',
    '<!DOCTYPE feed [<!ENTITY x "expanded">]><feed>&x;</feed>', '<feed>&unknown;</feed>',
    '<feed><entry></feed>', '<feed/><feed/>', '<feed xmlns="a" xmlns="b"/>']) {
    assert.throws(() => sourceXML(bytes(value)), /invalid_source_xml/);
  }
  assert.throws(() => sourceXML(Uint8Array.from([0xff, 0xfe])), /invalid_source_xml/);
  assert.throws(() => sourceXML(bytes('<a>'.repeat(33) + '</a>'.repeat(33))), /metadata_size_limit/);
  assert.throws(() => sourceXML(new Uint8Array(1_048_577)), /metadata_size_limit/);
});

test('latest-version license evidence normalizes the exact CC-BY and CC0 policies', async () => {
  for (const license of ['http://creativecommons.org/licenses/by/4.0/', 'https://creativecommons.org/publicdomain/zero/1.0/']) {
    const result = await arxivReuseEvidence(raw(license), pinned(), observed);
    assert.equal(result.eligible, true);
    if (!result.eligible) return;
    assert.equal(result.licenseURI, license.replace('http:', 'https:'));
    assert.equal(result.evidence.source_revision, 2);
    assert.match(result.evidence.evidence_sha256, /^[0-9a-f]{64}$/);
    assert.equal(result.evidence.source_url, 'https://arxiv.org/abs/1706.03762v2');
    assert.equal(result.evidence.observed_at, observed);
  }
});

test('OAI latest-license evidence never authorizes an older or unseen version', async () => {
  assert.deepEqual(await arxivReuseEvidence(raw(undefined, ['v1', 'v2', 'v3']), pinned(), observed), { eligible: false, reason: 'revision_unverified' });
  assert.deepEqual(await arxivReuseEvidence(raw(undefined, ['v1']), pinned(), observed), { eligible: false, reason: 'revision_unverified' });
});

test('license evidence requires valid Raw dates matching the pinned Atom update instant', async () => {
  for (const change of [
    (xml: string) => xml.replaceAll(/<date>[^<]*<\/date>/g, ''),
    (xml: string) => xml.replaceAll('Mon, 19 Jun 2017 16:49:45 GMT', 'not-a-date'),
    (xml: string) => xml.replaceAll('Mon, 19 Jun 2017 16:49:45 GMT', 'Mon, 19 Jun 2017 16:49:44 GMT'),
    (xml: string) => xml.replaceAll('Mon, 19 Jun 2017 16:49:45 GMT', 'Tue, 19 Jun 2017 16:49:45 GMT'),
  ]) {
    assert.deepEqual(await arxivReuseEvidence(bytes(change(new TextDecoder().decode(raw()))), pinned(), observed), { eligible: false, reason: 'revision_unverified' });
  }
  const undated = pinned(); undated.metadata.updated_at = null;
  assert.deepEqual(await arxivReuseEvidence(raw(), undated, observed), { eligible: false, reason: 'revision_unverified' });
});

test('unsupported, absent and lookalike licenses fail closed without blocking metadata', async () => {
  assert.deepEqual(await arxivReuseEvidence(raw(''), pinned(), observed), { eligible: false, reason: 'license_unverified' });
  for (const license of ['http://arxiv.org/licenses/nonexclusive-distrib/1.0/', 'https://creativecommons.org/licenses/by-nc/4.0/',
    'https://creativecommons.org/licenses/by-sa/4.0/', 'https://creativecommons.org/licenses/by/3.0/',
    'https://creativecommons.org.evil.test/licenses/by/4.0/', 'https://creativecommons.org/licenses/by/4.0/?different',
    'https://creativecommons.org/licenses/by/4.0/#changed']) {
    assert.deepEqual(await arxivReuseEvidence(raw(license), pinned(), observed), { eligible: false, reason: 'license_not_supported' });
  }
});

test('OAI identity, duplicates, deleted records and malformed version history cannot yield an approval', async () => {
  await assert.rejects(arxivReuseEvidence(raw(undefined, undefined, '1706.03763'), pinned(), observed), /source_identity_mismatch/);
  await assert.rejects(arxivReuseEvidence(raw(undefined, ['v1', 'v2', 'v2']), pinned(), observed), /invalid_source_metadata/);
  await assert.rejects(arxivReuseEvidence(raw(undefined, ['v0']), pinned(), observed), /invalid_source_metadata/);
  await assert.rejects(arxivReuseEvidence(raw(undefined, undefined, undefined, '<license>duplicate</license>'), pinned(), observed), /invalid_source_metadata/);
  const deleted = bytes(new TextDecoder().decode(raw()).replace('<header>', '<header status="deleted">'));
  await assert.rejects(arxivReuseEvidence(deleted, pinned(), observed), /source_not_found/);
  const spoofed = bytes(new TextDecoder().decode(raw()).replace('http://arxiv.org/OAI/arXivRaw/', 'https://evil.test/Raw'));
  await assert.rejects(arxivReuseEvidence(spoofed, pinned(), observed), /invalid_source_metadata/);
});
