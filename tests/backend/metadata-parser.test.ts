import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { parseMetadata, MAX_PARSER_INPUT } from '../../workers/source-gateway/parse-metadata.ts';

const observed = '2026-10-04T05:00:00.000Z';
const text = new TextEncoder();
const hash = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
let bundleRoot: string;
function buildBundle(destination: string) {
  const result = spawnSync('python3', [resolve('scripts/build-metadata-parser.py'), destination], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 8192, env: { PATH: process.env.PATH ?? '/usr/bin:/bin' },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(readFileSync(resolve(destination, 'manifest.json'), 'utf8'));
}
before(() => {
  bundleRoot = mkdtempSync(resolve(tmpdir(), 'science-reader-parser-test-'));
  buildBundle(resolve(bundleRoot, 'first'));
});
after(() => { if (bundleRoot) rmSync(bundleRoot, { recursive: true, force: true }); });
const entry = `<entry><id>https://arxiv.org/abs/1706.03762v2</id><title>A fixture paper</title>
  <author><name>Ada Example</name></author><summary>A bounded abstract.</summary>
  <published>2017-06-12T17:57:34Z</published><updated>2017-06-19T16:49:45Z</updated>
  <category term="cs.LG"/></entry>`;
const atomText = `<feed xmlns="http://www.w3.org/2005/Atom">${entry}</feed>`;
const rawText = `<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><GetRecord><record>
  <header><identifier>oai:arXiv.org:1706.03762</identifier></header><metadata>
  <arXivRaw xmlns="http://arxiv.org/OAI/arXivRaw/"><id>1706.03762</id>
  <version version="v2"><date>Mon, 19 Jun 2017 16:49:45 GMT</date></version>
  <license>http://creativecommons.org/licenses/by/4.0/</license>
  </arXivRaw></metadata></record></GetRecord></OAI-PMH>`;
const pinned = () => ({ sourceID: '1706.03762', revision: 2, metadata: {
  title: 'A fixture paper', authors: ['Ada Example'], abstract: 'A bounded abstract.',
  published_at: '2017-06-12T17:57:34.000Z', updated_at: '2017-06-19T16:49:45.000Z',
  categories: ['cs.LG'], venue: null,
} });
function input(stage: 'atom' | 'license' = 'atom', body = stage === 'atom' ? atomText : rawText) {
  const bytes = text.encode(body);
  return { schema_version: 1, request: { source_id: '1706.03762', revision: 2 as number | null, stage, byte_ceiling: 1_048_576 },
    pinned_record: stage === 'license' ? pinned() : null,
    body_base64: Buffer.from(bytes).toString('base64'), body_sha256: hash(bytes), observed_at: observed };
}
function cli(bytes: Uint8Array | string) {
  const result = spawnSync(resolve('node_modules/.bin/deno'), ['run', '--cached-only',
    '--no-config', '--no-lock', '--no-npm', '--no-remote', '--node-modules-dir=none',
    '--no-prompt', '--deny-net', '--deny-env', '--deny-read', '--deny-write', '--deny-run', '--deny-ffi', '--deny-sys',
    resolve(bundleRoot, 'first/parser.mjs')], {
    input: bytes, encoding: 'utf8', timeout: 5000, maxBuffer: 65_536,
    // No inherited credentials, DENO_AUTH_TOKENS, NODE_OPTIONS or proxy variables.
    env: { PATH: process.env.PATH ?? '/usr/bin:/bin' },
  });
  assert.equal(result.error, undefined, 'the bounded parser process must finish');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  return JSON.parse(result.stdout);
}

test('metadata parser emits the exact 012 Atom shape and preserves full source instants', async () => {
  const value = input(); value.request.revision = null;
  const result = await parseMetadata(value);
  assert.equal(result.kind, 'result');
  if (result.kind !== 'result') return;
  assert.equal(result.body_sha256, value.body_sha256);
  assert.equal(result.result.revision, 2);
  assert.equal(result.result.atom_updated_at, '2017-06-19T16:49:45.000Z');
  assert.equal((result.result.metadata as Record<string, unknown>).updated_at, '2017-06-19');
  assert.deepEqual(Object.keys(result.result).sort(), ['atom_published_at', 'atom_updated_at', 'metadata', 'revision']);
});

test('independent captured builds yield identical self-contained code and provenance', () => {
  const first = JSON.parse(readFileSync(resolve(bundleRoot, 'first/manifest.json'), 'utf8'));
  const second = buildBundle(resolve(bundleRoot, 'second'));
  assert.deepEqual(first, second);
  const output = readFileSync(resolve(bundleRoot, 'first/parser.mjs'));
  assert.equal(hash(output), first.output.sha256);
  assert.equal(output.length, first.output.bytes);
  assert.deepEqual(output, readFileSync(resolve(bundleRoot, 'second/parser.mjs')));
  assert.equal(first.hosted_admitted, false);
  assert.equal(first.source_network_enabled, false);
  assert.ok(first.sources['node_modules/saxes/saxes.js']);
  assert.ok(first.sources['node_modules/xmlchars/xml/1.0/ed5.js']);
});

test('license result binds evidence to the same body and the captured observation time', async () => {
  const value = input('license');
  const result = await parseMetadata(value);
  assert.equal(result.kind, 'result');
  if (result.kind !== 'result') return;
  assert.equal(result.result.eligible, true);
  assert.equal(result.result.license_uri, 'https://creativecommons.org/licenses/by/4.0/');
  const evidence = result.result.evidence as Record<string, unknown>;
  assert.equal(evidence.evidence_sha256, value.body_sha256);
  assert.equal(evidence.observed_at, observed);
  assert.equal(evidence.source_revision, 2);
});

test('parser owns nested pins, source, body and timestamp before asynchronous hashing', async () => {
  const value = input('license');
  const expected = structuredClone(value);
  const pending = parseMetadata(value);
  value.request.source_id = '1706.03763';
  value.body_base64 = ''; value.body_sha256 = 'a'.repeat(64);
  value.observed_at = '2000-01-01T00:00:00.000Z';
  value.pinned_record!.metadata.updated_at = null as unknown as string;
  value.pinned_record!.metadata.authors.length = 0;
  assert.deepEqual(await pending, await parseMetadata(expected));
});

test('wrong digest, noncanonical body encodings and unbound pins never yield result arguments', async () => {
  const changes = [
    (v: ReturnType<typeof input>) => { v.body_sha256 = 'a'.repeat(64); },
    (v: ReturnType<typeof input>) => { v.body_base64 += '\n'; },
    (v: ReturnType<typeof input>) => { v.request.byte_ceiling = 1; },
    (v: ReturnType<typeof input>) => { v.pinned_record!.sourceID = '1706.03763'; },
    (v: ReturnType<typeof input>) => { v.request.revision = null; },
    (v: ReturnType<typeof input>) => { v.pinned_record!.metadata.updated_at = '2017-06-19'; },
    (v: ReturnType<typeof input>) => { v.observed_at = '2026-10-04'; },
    (v: ReturnType<typeof input>) => { v.observed_at = '0000-01-01T00:00:00.000Z'; },
  ];
  for (const change of changes) {
    const value = input('license'); change(value);
    assert.deepEqual(await parseMetadata(value), { schema_version: 1, kind: 'rejected', reason: 'invalid_parser_input' });
  }
  const noncanonical = input('atom', 'a');
  noncanonical.body_base64 = 'YR=='; // Same decoded byte with nonzero unused pad bits.
  assert.equal((await parseMetadata(noncanonical)).kind, 'rejected');
});

test('wrong paper, malformed XML and missing source map to finite nonretryable failures', async () => {
  assert.deepEqual(await parseMetadata(input('atom', atomText.replace('1706.03762v2', '1706.03763v2'))),
    { schema_version: 1, kind: 'failure', error_code: 'invalid_source_metadata', retryable: false });
  const sentinel = 'NEVER_REFLECT_SOURCE_PAYLOAD';
  const malformed = await parseMetadata(input('atom', `<!DOCTYPE feed SYSTEM "https://example.invalid/${sentinel}"><feed/>`));
  assert.deepEqual(malformed, { schema_version: 1, kind: 'failure', error_code: 'invalid_source_metadata', retryable: false });
  assert.ok(!JSON.stringify(malformed).includes(sentinel));
  assert.deepEqual(await parseMetadata(input('atom', '<feed xmlns="http://www.w3.org/2005/Atom"/>')),
    { schema_version: 1, kind: 'failure', error_code: 'source_not_found', retryable: false });
});

test('latest-version and license decisions remain source-only when reuse is unproved', async () => {
  for (const [body, reason] of [
    [rawText.replace('version="v2"', 'version="v3"'), 'revision_unverified'],
    [rawText.replace('http://creativecommons.org/licenses/by/4.0/', 'http://arxiv.org/licenses/nonexclusive-distrib/1.0/'), 'license_not_supported'],
  ]) {
    const result = await parseMetadata(input('license', body));
    assert.equal(result.kind, 'result');
    if (result.kind === 'result') assert.deepEqual(result.result, { eligible: false, reason });
  }
});

test('dates that cannot reach the catalog become metadata failures before a result write', async () => {
  const value = input('atom', atomText.replace('2017-06-19T16:49:45Z', '0001-01-01T00:00:00+01:00'));
  const expected = { schema_version: 1, kind: 'failure', error_code: 'invalid_source_metadata', retryable: false };
  assert.deepEqual(await parseMetadata(value), expected);
  assert.deepEqual(cli(JSON.stringify(value)), expected);
});

test('a recognized missing OAI record reports source not found without reflecting source text', async () => {
  const body = '<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><error code="idDoesNotExist">PRIVATE_DIAGNOSTIC</error></OAI-PMH>';
  const value = input('license', body);
  const result = { schema_version: 1, kind: 'failure', error_code: 'source_not_found', retryable: false };
  assert.deepEqual(await parseMetadata(value), result);
  assert.deepEqual(cli(JSON.stringify(value)), result);
});

test('a full one-MiB framed body stays within the bridge envelope and parser limits', async () => {
  const padding = '<!--' + 'x'.repeat(1_048_576 - text.encode(atomText).length - 7) + '-->';
  const value = input('atom', atomText.replace('</feed>', padding + '</feed>'));
  assert.equal(Buffer.from(value.body_base64, 'base64').length, 1_048_576);
  assert.ok(text.encode(JSON.stringify(value)).length < MAX_PARSER_INPUT);
  assert.equal((await parseMetadata(value)).kind, 'result');
});

test('real network-disabled Deno CLI emits the same bounded success result', async () => {
  const value = input('license');
  assert.deepEqual(cli(JSON.stringify(value)), await parseMetadata(value));
});

test('real Deno CLI refuses malformed UTF-8 and oversized input without reflecting it', () => {
  for (const value of [Uint8Array.of(0xff, 0xfe), new Uint8Array(MAX_PARSER_INPUT + 1).fill(32)]) {
    assert.deepEqual(cli(value), { schema_version: 1, kind: 'rejected', reason: 'invalid_parser_input' });
  }
});
