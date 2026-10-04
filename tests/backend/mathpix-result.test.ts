import test from 'node:test';
import assert from 'node:assert/strict';
import { zipSync } from 'fflate';
import { sha256 } from '../../supabase/functions/_shared/http.ts';
import { mathpixProfile } from '../../supabase/functions/_shared/mathpix.ts';
import { ARCHIVE_LIMITS } from '../../supabase/functions/_shared/archive.ts';
import {
  captureMathpixResult, openMathpixResult, validateMathpixRenderInput,
  isMathpixArchivePath, MathpixResultError, MATHPIX_OPTIONS_SHA256, MATHPIX_RESULT_LIMITS,
} from '../../supabase/functions/_shared/mathpix-result.ts';
import type {
  CaptureMathpixResultInput, MathpixRawManifest, MathpixRawResult, MathpixRenderInput, MathpixResultErrorCode,
} from '../../supabase/functions/_shared/mathpix-result.ts';

// Synthetic provider outputs only: no claim of actual Mathpix compatibility.
const encode = (value: string) => new TextEncoder().encode(value);
const decode = (value: Uint8Array) => new TextDecoder().decode(value);
const uid = (n: number) => `aaaaaaaa-0000-4000-8000-${String(n).padStart(12, '0')}`;
const archiveMMD = '# Archive paper\n\nEquation \\(x^2 + λ = 1\\).\n\n![Fixture](../images/figure.jpg)\n';
const standaloneMMD = '# Standalone response\n\nDifferent formatting and paths are retained.\n';
function zip(members: Record<string, Uint8Array>): Uint8Array {
  return zipSync(members, { level: 0, mtime: new Date('2020-01-01T00:00:00Z') });
}
function fixture(): CaptureMathpixResultInput {
  return {
    binding: {
      document: { id: uid(1), original_object_id: uid(2), sha256: 'a'.repeat(64), bytes: 100, page_count: 2 },
      attempt: { ocr_run_id: uid(3), id: uid(4), provider_scope_id: 'synthetic_scope', provider_job_id: 'synthetic_job' },
      ocr: { api: 'v3/pdf', profile: 'science-reader-mmd-v1', options_sha256: MATHPIX_OPTIONS_SHA256 },
    },
    status: { providerJobID: 'synthetic_job', state: 'completed', pages: 2, completedPages: 2, pipelineVersion: 'fixture-v1', deleted: false, errorCode: null },
    conversion: { providerJobID: 'synthetic_job', state: 'completed', errorCode: null },
    standaloneMMD: encode(standaloneMMD),
    archive: zip({ 'paper/main.mmd': encode(archiveMMD), 'images/figure.jpg': new Uint8Array([255, 216, 255, 217]), 'unused/data.bin': new Uint8Array([7, 8, 9]) }),
    linesJSON: encode(' {"pages":[{"lines":[{"text":"auxiliary only"}]},{}]}\n'),
  };
}
function reject(code: MathpixResultErrorCode) {
  return (error: unknown) => error instanceof MathpixResultError && error.code === code && error.message === code;
}
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const map = value as Record<string, unknown>;
    return `{${Object.keys(map).sort().map(key => `${JSON.stringify(key)}:${canonical(map[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
const parse = (result: MathpixRawResult) => JSON.parse(decode(result.manifestBytes)) as MathpixRawManifest;
const opening = (result: MathpixRawResult) => ({ manifestBytes: result.manifestBytes, expectedSHA256: result.manifestSHA256, rawMembers: result.rawMembers });
async function changedManifest(result: MathpixRawResult, mutate: (manifest: MathpixRawManifest) => void) {
  const manifest = parse(result); mutate(manifest);
  const manifestBytes = encode(`${canonical(manifest)}\n`);
  return { manifestBytes, expectedSHA256: await sha256(manifestBytes), rawMembers: result.rawMembers };
}

test('capture creates deterministic closed canonical LF manifest with complete exact raw/expanded hashes', async () => {
  const input = fixture(), a = await captureMathpixResult(input), b = await captureMathpixResult(input), manifest = parse(a);
  assert.deepEqual(a.manifestBytes, b.manifestBytes);
  assert.equal(a.manifestSHA256, await sha256(a.manifestBytes));
  assert.equal(decode(a.manifestBytes), `${canonical(manifest)}\n`);
  assert.equal((await mathpixProfile()).sha256, MATHPIX_OPTIONS_SHA256);
  assert.deepEqual(manifest.document, input.binding.document);
  assert.deepEqual(manifest.attempt, input.binding.attempt);
  assert.deepEqual(manifest.completion, { status: input.status, conversion: input.conversion });
  assert.deepEqual(manifest.outputs.map(x => [x.path, x.role]), [
    ['lines.json', 'auxiliary_lines'], ['output.mmd.zip', 'mmd_archive'], ['standalone.mmd', 'standalone_mmd'],
  ]);
  for (const output of manifest.outputs) {
    const raw = a.rawMembers.get(output.path)!;
    assert.equal(output.bytes, raw.length); assert.equal(output.sha256, await sha256(raw));
  }
  const opened = await openMathpixResult(opening(a)), checked = await validateMathpixRenderInput(opened);
  assert.deepEqual(manifest.archive_entries.map(x => x.path), ['images/figure.jpg', 'paper/main.mmd', 'unused/data.bin']);
  for (const entry of manifest.archive_entries) {
    const raw = opened.archiveMembers.get(entry.path)!;
    assert.equal(entry.bytes, raw.length); assert.equal(entry.sha256, await sha256(raw));
  }
  assert.deepEqual(checked.manifest, manifest);
  assert.deepEqual(Object.keys(opened).sort(), ['archiveMembers', 'expectedRawManifestSHA256', 'rawManifestBytes']);
  assert.equal(decode(opened.archiveMembers.get(manifest.render_source.path)!), archiveMMD);
  assert.notEqual(manifest.render_source.sha256, manifest.outputs.find(x => x.path === 'standalone.mmd')!.sha256);
  assert.equal(decode(a.rawMembers.get('standalone.mmd')!), standaloneMMD);
});

test('all supplied buffers and nested binding/status scalars are owned before first capture await', async () => {
  const input = fixture();
  input.archive = Buffer.from(input.archive); input.linesJSON = Buffer.from(input.linesJSON); input.standaloneMMD = Buffer.from(input.standaloneMMD);
  const expected = await captureMathpixResult(input), pending = captureMathpixResult(input);
  input.binding.document.sha256 = 'b'.repeat(64); input.binding.document.page_count = 1;
  input.binding.attempt.provider_job_id = 'changed'; input.binding.ocr.options_sha256 = 'b'.repeat(64);
  input.status.providerJobID = 'changed'; input.status.pages = 1; input.status.pipelineVersion = 'changed'; input.status.deleted = true;
  input.conversion.state = 'error';
  input.archive.fill(0); input.linesJSON.fill(0); input.standaloneMMD.fill(0);
  const actual = await pending;
  assert.deepEqual(actual, expected);
});

test('open owns manifest and all raw Buffer/map members before first await', async () => {
  const raw = await captureMathpixResult(fixture()), expected = await openMathpixResult(opening(raw));
  raw.manifestBytes = Buffer.from(raw.manifestBytes);
  raw.rawMembers = new Map([...raw.rawMembers].map(([name, data]) => [name, Buffer.from(data)]));
  const input = opening(raw), pending = openMathpixResult(input);
  input.expectedSHA256 = 'b'.repeat(64); input.manifestBytes.fill(0);
  for (const data of input.rawMembers.values()) data.fill(0);
  input.rawMembers.clear();
  assert.deepEqual(await pending, expected);
});

test('receiver owns manifest and every expanded member before awaited validation', async () => {
  const opened = await openMathpixResult(opening(await captureMathpixResult(fixture())));
  const expected = await validateMathpixRenderInput(opened), pending = validateMathpixRenderInput(opened);
  opened.expectedRawManifestSHA256 = 'b'.repeat(64); opened.rawManifestBytes.fill(0);
  for (const raw of opened.archiveMembers.values()) raw.fill(0);
  opened.archiveMembers.clear();
  assert.deepEqual(await pending, expected);
});

test('nullable provider page and version fields remain null without inventing usage', async () => {
  const input = fixture(); input.status.pages = null; input.status.completedPages = null; input.status.pipelineVersion = null;
  const result = await captureMathpixResult(input), checked = await validateMathpixRenderInput(await openMathpixResult(opening(result)));
  assert.deepEqual(checked.manifest.completion.status, input.status);
  assert.equal(checked.manifest.document.page_count, 2);
});

test('pending/missing/deleted/error outputs never produce a retained result', async () => {
  const changes: ((input: CaptureMathpixResultInput) => void)[] = [
    x => { x.status.state = 'processing'; }, x => { x.conversion.state = 'missing'; },
    x => { x.status.deleted = true; }, x => { x.status.errorCode = 'provider_error'; }, x => { x.conversion.errorCode = 'conversion_error'; },
  ];
  for (const change of changes) { const input = fixture(); change(input); await assert.rejects(captureMathpixResult(input), reject('output_incomplete')); }
});

test('wrong provider/page/profile/checkpoint values reject before output capture', async () => {
  const changes: ((input: CaptureMathpixResultInput) => void)[] = [
    x => { x.status.providerJobID = 'other_job'; }, x => { x.conversion.providerJobID = 'other_job'; },
    x => { x.status.pages = 1; }, x => { x.status.completedPages = 0; }, x => { x.status.pages = NaN; },
    x => { x.binding.document.bytes = 7; }, x => { x.binding.document.page_count = 251; }, x => { x.binding.document.id = 'not-uuid'; },
    x => { x.binding.attempt.provider_scope_id = 'https://secret.invalid'; }, x => { x.binding.attempt.provider_job_id = 'x'.repeat(161); },
    x => { x.binding.ocr.options_sha256 = 'b'.repeat(64); }, x => { x.status.pipelineVersion = 'x'.repeat(129); },
    x => { x.binding.document.sha256 = 'A'.repeat(64); },
  ];
  for (const change of changes) { const input = fixture(); change(input); await assert.rejects(captureMathpixResult(input), reject('binding_mismatch')); }
});

test('unknown or accessor checkpoint fields are refused without invoking getters', async () => {
  const input = fixture();
  (input.binding.document as unknown as Record<string, unknown>).account = 'must-not-enter-provenance';
  await assert.rejects(captureMathpixResult(input), reject('binding_mismatch'));
  const getter = fixture(); let reads = 0;
  Object.defineProperty(getter.status, 'pages', { enumerable: true, get() { reads++; return 2; } });
  await assert.rejects(captureMathpixResult(getter), reject('binding_mismatch')); assert.equal(reads, 0);
});

test('zero or multiple case-sensitive archive MMD entries refuse standalone fallback', async () => {
  const cases: Record<string, Uint8Array>[] = [
    { 'paper.MMD': encode('uppercase only') }, { 'image.png': encode('opaque') },
    { 'a.mmd': encode('first'), 'b.mmd': encode('second') },
  ];
  for (const files of cases) {
    const input = fixture(); input.archive = zip(files);
    await assert.rejects(captureMathpixResult(input), reject('mmd_ambiguous'));
  }
  const input = fixture(); input.archive = zip({ 'paper.mmd': encode('selected'), 'other.MMD': encode('retained unused') });
  assert.equal(parse(await captureMathpixResult(input)).render_source.path, 'paper.mmd');
});

test('UTF-8 MMD/line envelope admission is independent of future rendering policy', async () => {
  for (const data of [new Uint8Array([0xff]), encode('a\0b')]) {
    const input = fixture(); input.standaloneMMD = data;
    await assert.rejects(captureMathpixResult(input), reject('unsupported_content'));
    const archive = fixture(); archive.archive = zip({ 'paper.mmd': data });
    await assert.rejects(captureMathpixResult(archive), reject('unsupported_content'));
  }
  const empty = fixture(); empty.archive = zip({ 'paper.mmd': new Uint8Array() });
  await assert.rejects(captureMathpixResult(empty), reject('unsupported_content'));
  for (const raw of ['null', '[]', '{}', '{"pages":[{}]}', '{"pages":[{},null]}', '{"pages":[{},[]]}', '{']) {
    const input = fixture(); input.linesJSON = encode(raw);
    await assert.rejects(captureMathpixResult(input), reject('unsupported_content'));
  }
  const invalid = fixture(); invalid.linesJSON = new Uint8Array([0xff]);
  await assert.rejects(captureMathpixResult(invalid), reject('unsupported_content'));
  const auxiliary = fixture(); auxiliary.linesJSON = encode('{"pages":[{"opaque":{"coordinate":"unvalidated"}},{}],"extra":"retained"}');
  auxiliary.archive = zip({ 'paper.mmd': encode('Unsupported renderer markup <script>not executed</script>'), 'unused.svg': encode('<svg/>') });
  const raw = await captureMathpixResult(auxiliary), opened = await openMathpixResult(opening(raw));
  assert.deepEqual(raw.rawMembers.get('lines.json'), auxiliary.linesJSON);
  assert.equal(opened.archiveMembers.has('unused.svg'), true);
  assert.equal('lines' in opened, false);
});

test('fixed raw byte ceilings and empty members fail without hash/extraction', async () => {
  for (const [field, maximum] of [['standaloneMMD', MATHPIX_RESULT_LIMITS.standaloneBytes], ['archive', MATHPIX_RESULT_LIMITS.archiveBytes], ['linesJSON', MATHPIX_RESULT_LIMITS.linesBytes]] as const) {
    const input = fixture(); input[field] = new Uint8Array(maximum + 1);
    await assert.rejects(captureMathpixResult(input), reject('output_limit'));
    input[field] = new Uint8Array();
    await assert.rejects(captureMathpixResult(input), reject('output_incomplete'));
  }
});

test('overridden typed-array byteLength cannot bypass intrinsic empty/size admission', async () => {
  for (const [length, code] of [[0, 'output_incomplete'], [MATHPIX_RESULT_LIMITS.standaloneBytes + 1, 'output_limit']] as const) {
    const input = fixture(), forged = new Uint8Array(length);
    Object.defineProperty(forged, 'byteLength', { value: 1 });
    input.standaloneMMD = forged;
    await assert.rejects(captureMathpixResult(input), reject(code));
  }
  const input = fixture(), buffer = Buffer.from(standaloneMMD);
  Object.defineProperty(buffer, 'byteLength', { value: 1 }); input.standaloneMMD = buffer;
  const raw = await captureMathpixResult(input);
  assert.equal(parse(raw).outputs.find(x => x.path === 'standalone.mmd')!.bytes, encode(standaloneMMD).length);
});

test('ZIP corruption, path collisions, unsafe names, and excessive expansion map to finite errors', async () => {
  const archives = [zip({ '../paper.mmd': encode('bad') }), zip({ 'A.mmd': encode('a'), 'a.mmd': encode('b') }), encode('this is not a complete ZIP container')];
  const badCRC = zip({ 'paper.mmd': encode('fixture') }); badCRC[30 + 'paper.mmd'.length] ^= 1; archives.push(badCRC);
  for (const archive of archives) { const input = fixture(); input.archive = archive; await assert.rejects(captureMathpixResult(input), reject('archive_invalid')); }
  const input = fixture(); input.archive = zipSync({ 'paper.mmd': new Uint8Array(1_048_576) });
  await assert.rejects(captureMathpixResult(input), reject('output_limit'));
});

test('raw reopen rejects missing/extra/substituted members and expected digest mismatch', async () => {
  const raw = await captureMathpixResult(fixture());
  for (const path of raw.rawMembers.keys()) {
    const missing = new Map(raw.rawMembers); missing.delete(path);
    await assert.rejects(openMathpixResult({ ...opening(raw), rawMembers: missing }), reject('output_incomplete'));
    const wrong = new Map(raw.rawMembers), data = new Uint8Array(wrong.get(path)!); data[data.length - 1] ^= 1; wrong.set(path, data);
    await assert.rejects(openMathpixResult({ ...opening(raw), rawMembers: wrong }), reject('binding_mismatch'));
  }
  const extra = new Map(raw.rawMembers); extra.set('extra', encode('opaque'));
  await assert.rejects(openMathpixResult({ ...opening(raw), rawMembers: extra }), reject('output_limit'));
  await assert.rejects(openMathpixResult({ ...opening(raw), expectedSHA256: 'b'.repeat(64) }), reject('binding_mismatch'));
});

test('reopening repeats ZIP validation even with a self-consistent changed raw hash', async () => {
  const raw = await captureMathpixResult(fixture()), archive = new Uint8Array(raw.rawMembers.get('output.mmd.zip')!);
  archive[30 + 'paper/main.mmd'.length] ^= 1;
  raw.rawMembers.set('output.mmd.zip', archive); const digest = await sha256(archive);
  const input = await changedManifest(raw, manifest => { manifest.outputs.find(x => x.path === 'output.mmd.zip')!.sha256 = digest; });
  await assert.rejects(openMathpixResult(input), reject('archive_invalid'));
});

test('every typed manifest object is closed, including completion and file identities', async () => {
  const raw = await captureMathpixResult(fixture());
  const targets: ((m: MathpixRawManifest) => object)[] = [m => m, m => m.document, m => m.attempt, m => m.ocr, m => m.completion,
    m => m.completion.status, m => m.completion.conversion, m => m.outputs[0], m => m.archive_entries[0], m => m.render_source];
  for (const target of targets) {
    const input = await changedManifest(raw, manifest => { (target(manifest) as Record<string, unknown>).unknown = 'not allowed'; });
    await assert.rejects(openMathpixResult(input), reject('binding_mismatch'));
  }
});

test('canonical manifest refuses alternate JSON, duplicate keys, BOM, missing/extra LF and malformed UTF-8', async () => {
  const raw = await captureMathpixResult(fixture()), text = decode(raw.manifestBytes);
  const values = [encode(text.slice(0, -1)), encode(`${text}\n`), encode(` ${text}`), encode(`\ufeff${text}`),
    encode(text.replace('"format":"mathpix-raw-result-v1"', '"format":"mathpix-raw-result-v1","format":"mathpix-raw-result-v1"')),
    encode(text.replace('"bytes":100', '"bytes":1e2')), new Uint8Array([0xff, 0x0a])];
  for (const manifestBytes of values) await assert.rejects(openMathpixResult({ ...opening(raw), manifestBytes, expectedSHA256: await sha256(manifestBytes) }), reject('binding_mismatch'));
});

test('reopen repeats completion/profile/count consistency and exact source/output selection', async () => {
  const raw = await captureMathpixResult(fixture());
  const mutations: ((m: MathpixRawManifest) => void)[] = [
    m => { m.ocr.options_sha256 = 'b'.repeat(64); }, m => { m.completion.status.pages = 1; },
    m => { m.completion.conversion.providerJobID = 'other'; }, m => { m.render_source = { ...m.archive_entries[0] }; },
    m => { m.outputs.reverse(); }, m => { m.archive_entries.reverse(); }, m => { m.render_source.sha256 = 'b'.repeat(64); },
  ];
  for (const mutate of mutations) await assert.rejects(openMathpixResult(await changedManifest(raw, mutate)), reject('binding_mismatch'));
  await assert.rejects(openMathpixResult(await changedManifest(raw, m => { m.completion.status.deleted = true; })), reject('output_incomplete'));
});

test('receiver refuses every missing, extra or changed expanded member including unused assets', async () => {
  const opened = await openMathpixResult(opening(await captureMathpixResult(fixture())));
  for (const path of opened.archiveMembers.keys()) {
    const missing = new Map(opened.archiveMembers); missing.delete(path);
    await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: missing }), reject('binding_mismatch'));
    const wrong = new Map(opened.archiveMembers), data = new Uint8Array(wrong.get(path)!); data[0] ^= 1; wrong.set(path, data);
    await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: wrong }), reject('binding_mismatch'));
  }
  const extra = new Map(opened.archiveMembers); extra.set('unused/new.bin', encode('new'));
  await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: extra }), reject('binding_mismatch'));
});

test('receiver refuses case/path conflicts and enforces file/count/aggregate payload bounds', async () => {
  const opened = await openMathpixResult(opening(await captureMathpixResult(fixture())));
  for (const path of ['../escape', 'paper/MAIN.MMD', 'paper', 'CON.txt']) {
    const members = new Map(opened.archiveMembers); members.set(path, encode('x'));
    await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: members }), reject('binding_mismatch'));
  }
  const count = new Map(Array.from({ length: ARCHIVE_LIMITS.entries + 1 }, (_, n) => [`file${n}`, new Uint8Array()]));
  await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: count }), reject('output_limit'));
  const large = new Map([['a', new Uint8Array(ARCHIVE_LIMITS.fileBytes + 1)]]);
  await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: large }), reject('output_limit'));
  const full = new Uint8Array(ARCHIVE_LIMITS.fileBytes);
  const total = new Map([['a', full], ['b', full], ['c', new Uint8Array(1)]]);
  await assert.rejects(validateMathpixRenderInput({ ...opened, archiveMembers: total }), reject('output_limit'));
});

test('archive path export matches canonical ASCII/depth/reserved-name policy', () => {
  for (const path of ['a.mmd', '_dir/a-1.JPG', 'a/b/c/d/e/f/g/h', 'a'.repeat(240)]) assert.equal(isMathpixArchivePath(path), true, path);
  for (const path of ['', '/a', 'a/', 'a//b', 'a/../b', 'a\\b', '.hidden', 'a.', 'aux.txt', 'a/LPT1.png', 'λ.mmd', '%61.mmd', 'a'.repeat(241), 'a/b/c/d/e/f/g/h/i', 5, null]) assert.equal(isMathpixArchivePath(path), false, String(path));
});

test('pre-cancelled capture/open/receiver return finite cancellation without partial outputs', async () => {
  const raw = await captureMathpixResult(fixture()), opened = await openMathpixResult(opening(raw)), abort = new AbortController(); abort.abort(new Error('private cancellation reason'));
  await assert.rejects(captureMathpixResult(fixture(), abort.signal), reject('cancelled'));
  await assert.rejects(openMathpixResult(opening(raw), abort.signal), reject('cancelled'));
  await assert.rejects(validateMathpixRenderInput(opened, abort.signal), reject('cancelled'));
});

test('cancellation after invocation and during ZIP yielding never produces partial capture', async () => {
  const first = new AbortController(), pending = captureMathpixResult(fixture(), first.signal); first.abort();
  await assert.rejects(pending, reject('cancelled'));
  const input = fixture(); input.archive = zip(Object.fromEntries([
    ['paper.mmd', encode('fixture')], ...Array.from({ length: 30 }, (_, n) => [`file${n}.bin`, encode('opaque')] as const),
  ]));
  const second = new AbortController(), later = captureMathpixResult(input, second.signal), timer = setTimeout(() => second.abort(), 8);
  try { await assert.rejects(later, reject('cancelled')); } finally { clearTimeout(timer); }
});

test('opaque unsupported renderer image bytes survive raw retention without fetch authority', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('network must not be used'); };
  try {
    const input = fixture(), raw = await captureMathpixResult(input), opened = await openMathpixResult(opening(raw));
    const checked = await validateMathpixRenderInput(opened);
    assert.deepEqual(checked.archiveMembers.get('images/figure.jpg'), new Uint8Array([255, 216, 255, 217]));
  } finally { globalThis.fetch = originalFetch; }
});

test('manifest and receiving DTO reject over-limit/unknown shapes with finite non-content errors', async () => {
  const raw = await captureMathpixResult(fixture()), input = opening(raw);
  await assert.rejects(openMathpixResult({ ...input, manifestBytes: new Uint8Array(MATHPIX_RESULT_LIMITS.manifestBytes + 1) }), reject('output_limit'));
  const opened = await openMathpixResult(input);
  await assert.rejects(validateMathpixRenderInput({ ...opened, privateProviderURL: 'https://private.invalid' } as MathpixRenderInput), reject('binding_mismatch'));
  const malformed = fixture(); malformed.status.errorCode = 'private provider body with spaces';
  await assert.rejects(captureMathpixResult(malformed), error => error instanceof MathpixResultError && !error.message.includes('private'));
});
