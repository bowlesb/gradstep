import test from 'node:test';
import assert from 'node:assert/strict';
import { MathpixClient, mathpixProfile, mathpixStatus, mathpixConversion } from '../../supabase/functions/_shared/mathpix.ts';
import { sha256 } from '../../supabase/functions/_shared/http.ts';

const credential = { appID: 'synthetic-app', appKey: 'synthetic-key' };
const pdf = new TextEncoder().encode('%PDF-1.7\nSynthetic transport fixture, not a verified document.');
const id = '2026_10_03_synthetic123';
const attemptID = 'aaaaaaaa-0000-4000-8000-000000000001';
const json = (value: unknown, status = 200, headers: Record<string, string> = {}) => new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json', ...headers } });
async function checkpoint() { return { attemptID, documentSHA256: await sha256(pdf), optionsSHA256: (await mathpixProfile()).sha256 }; }
const ready = () => mathpixStatus({ pdf_id: id, status: 'completed', num_pages: 2, num_pages_completed: 2, version: 'fixture-v1' }, id);
const converted = () => mathpixConversion({ status: 'completed', conversion_status: { 'mmd.zip': { status: 'completed' } } }, id);

test('Mathpix profile preserves scientific structure and freezes OCR identity independently of rendering', async () => {
  const profile = await mathpixProfile(), options = JSON.parse(profile.optionsJSON);
  assert.deepEqual(await mathpixProfile(), profile);
  assert.match(profile.sha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(options.conversion_formats, { 'mmd.zip': true });
  assert.equal(options.metadata.improve_mathpix, false);
  assert.equal(options.include_equation_tags, true);
  assert.equal(options.preserve_section_numbering, true);
  assert.equal(options.rm_fonts, false);
  assert.equal(options.rm_spaces, false);
  assert.deepEqual(options.math_inline_delimiters, ['\\(', '\\)']);
  assert.equal(options.enable_tables_fallback, undefined);
  assert.equal(options.renderer_version, undefined);
});

test('submit uses exact verified bytes/options and an opaque attempt filename in one multipart POST', async () => {
  let calls = 0;
  const client = new MathpixClient(credential, async (url, init) => {
    calls++;
    assert.equal(String(url), 'https://api.mathpix.com/v3/pdf');
    assert.equal(init?.method, 'POST'); assert.equal(init?.redirect, 'error');
    assert.equal(new Headers(init.headers).get('app_key'), credential.appKey);
    assert.ok(init.body instanceof FormData);
    const file = init.body.get('file'); assert.ok(file instanceof File);
    assert.equal(file.name, `${attemptID}.pdf`);
    assert.deepEqual(new Uint8Array(await file.arrayBuffer()), pdf);
    assert.equal(init.body.get('options_json'), (await mathpixProfile()).optionsJSON);
    return json({ pdf_id: id });
  });
  assert.deepEqual(await client.submitOnce(pdf, await checkpoint()), { state: 'accepted', providerJobID: id });
  assert.equal(calls, 1);
});

test('every ambiguous POST response remains uncertain and is never automatically resubmitted', async () => {
  const failures = [
    async () => { throw new Error('This transport diagnostic must never be exposed'); },
    async () => json({ error: 'private provider details' }, 500),
    async () => json({ error: 'rate limit' }, 429),
    async () => json({ error: 'bad input' }, 400),
    async () => new Response('{broken'),
    async () => json({ pdf_id: '../other-account' }),
    async () => json({ pdf_id: id, error_info: { id: 'partial', error: 'private detail' } }),
    async () => new Response('x', { headers: { 'content-length': '65537' } }),
  ];
  for (const failure of failures) {
    let calls = 0;
    const client = new MathpixClient(credential, async () => { calls++; return failure(); });
    const result = await client.submitOnce(pdf, await checkpoint());
    assert.equal(result.state, 'submission_uncertain'); assert.equal(calls, 1);
    assert.doesNotMatch(JSON.stringify(result), /private|diagnostic/);
  }
});

test('changed bytes/options and malformed attempts fail before any provider call', async () => {
  let calls = 0;
  const client = new MathpixClient(credential, async () => { calls++; return json({ pdf_id: id }); });
  const claim = await checkpoint();
  for (const invalid of [{ ...claim, attemptID: 'title with user information' }, { ...claim, optionsSHA256: '0'.repeat(64) }, { ...claim, documentSHA256: '1'.repeat(64) }]) {
    await assert.rejects(client.submitOnce(pdf, invalid), /submission_checkpoint_mismatch/);
  }
  await assert.rejects(client.submitOnce(new TextEncoder().encode('<html>Not a PDF</html>'), claim), /submission_checkpoint_mismatch/);
  assert.equal(calls, 0);
});

test('submission captures Buffer bytes and attempt identity before asynchronous hashing', async () => {
  const mutablePDF = Buffer.from(pdf), mutableCheckpoint = await checkpoint();
  const client = new MathpixClient(credential, async (_, init) => {
    const file = (init?.body as FormData).get('file') as File;
    assert.deepEqual(new Uint8Array(await file.arrayBuffer()), pdf);
    assert.equal(file.name, `${attemptID}.pdf`);
    return json({ pdf_id: id });
  });
  const submitted = client.submitOnce(mutablePDF, mutableCheckpoint);
  mutablePDF.fill(0); mutableCheckpoint.attemptID = 'changed'; mutableCheckpoint.documentSHA256 = 'changed';
  assert.deepEqual(await submitted, { state: 'accepted', providerJobID: id });
});

test('OCR percentage and converter outer status cannot authorize output collection', async () => {
  const busy = mathpixStatus({ pdf_id: id, status: 'split', percent_done: 100, num_pages: 2, num_pages_completed: 2 }, id);
  const pending = mathpixConversion({ status: 'completed', conversion_status: { 'mmd.zip': { status: 'processing' } } }, id);
  const missing = mathpixConversion({ status: 'completed' }, id);
  let calls = 0;
  const client = new MathpixClient(credential, async () => { calls++; return new Response(); });
  await assert.rejects(client.output(busy, 'mmd'), /provider_output_pending/);
  await assert.rejects(client.output(ready(), 'mmd.zip', pending), /provider_output_pending/);
  await assert.rejects(client.output(ready(), 'mmd.zip', missing), /provider_output_pending/);
  await assert.rejects(client.output({ ...ready(), deleted: true }, 'mmd'), /provider_output_pending/);
  assert.equal(calls, 0);
});

test('provider status binds identity, bounds page counts, preserves pipeline version and omits message bodies', () => {
  assert.equal(ready().pipelineVersion, 'fixture-v1');
  assert.throws(() => mathpixStatus({ pdf_id: 'another', status: 'completed' }, id), /provider_response_invalid/);
  assert.throws(() => mathpixStatus({ pdf_id: id, status: 'completed', num_pages: 251 }, id), /provider_page_count_invalid/);
  assert.throws(() => mathpixStatus({ pdf_id: id, status: 'split', num_pages: 2, num_pages_completed: 3 }, id), /provider_page_count_invalid/);
  assert.throws(() => mathpixConversion({ conversion_status: { 'mmd.zip': 'completed' } }, id), /provider_response_invalid/);
  assert.throws(() => mathpixStatus({ pdf_id: id, status: ['completed'] }, id), /provider_response_invalid/);
  assert.throws(() => mathpixConversion({ conversion_status: { 'mmd.zip': { status: ['completed'] } } }, id), /provider_response_invalid/);
  const failure = mathpixStatus({ pdf_id: id, status: 'error', error_info: { id: 'pdf_read', error: 'private filename' } }, id);
  assert.equal(failure.errorCode, 'pdf_read'); assert.doesNotMatch(JSON.stringify(failure), /private filename/);
});

test('early output responses and malformed ZIPs remain GET failures with no resubmission', async () => {
  for (const response of [json({ status: 'processing' }, 202, { 'retry-after': '5' }), json({ status: 'split' }, 404), json({ status: 'completed' }), new Response('<html>error</html>')]) {
    const methods: string[] = [];
    const client = new MathpixClient(credential, async (_, init) => { methods.push(init?.method ?? ''); return response; });
    await assert.rejects(client.output(ready(), 'mmd.zip', converted()), error => {
      if (response.status === 202) assert.equal((error as { retryAfterSeconds: number }).retryAfterSeconds, 5);
      return /provider_output_pending|provider_http_failure|provider_output_invalid/.test(String(error));
    });
    assert.deepEqual(methods, ['GET']);
  }
});

test('streamed output bounds and aborts discard partial results', async () => {
  const overflow = new MathpixClient(credential, async () => new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(8_388_609)); controller.close(); } })));
  await assert.rejects(overflow.output(ready(), 'mmd'), /provider_body_limit/);
  const abort = new AbortController();
  const stalled = new MathpixClient(credential, async () => new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('partial')); queueMicrotask(() => abort.abort()); } })));
  await assert.rejects(stalled.output(ready(), 'mmd', undefined, abort.signal), /provider_transport_failed/);
  const truncated = new MathpixClient(credential, async () => new Response('partial', { headers: { 'content-length': '100' } }));
  await assert.rejects(truncated.output(ready(), 'mmd'), /provider_response_incomplete/);
  const decoded = new MathpixClient(credential, async () => new Response('already decoded', { headers: { 'content-length': '100', 'content-encoding': 'gzip' } }));
  assert.equal(new TextDecoder().decode(await decoded.output(ready(), 'mmd')), 'already decoded');
});

test('completed output is still untrusted bytes for the bounded bundle collector', async () => {
  const client = new MathpixClient(credential, async url => String(url).endsWith('.mmd.zip') ? new Response(Uint8Array.from([0x50, 0x4b, 3, 4])) : json({ pages: [{ page: 1, lines: [] }] }));
  assert.deepEqual(await client.output(ready(), 'mmd.zip', converted()), Uint8Array.from([0x50, 0x4b, 3, 4]));
  assert.match(new TextDecoder().decode(await client.output(ready(), 'lines.json')), /pages/);
});

test('unconfigured credentials and provider error documents cannot become valid inputs or outputs', async () => {
  assert.throws(() => new MathpixClient({ appID: undefined, appKey: undefined } as unknown as typeof credential), /provider_credentials_unavailable/);
  for (const [format, response] of [
    ['mmd', new Response('<!doctype html><html>Error</html>')],
    ['mmd', new Response('<p>Error</p>', { headers: { 'content-type': 'text/html' } })],
    ['lines.json', json({ status: 'processing' })], ['lines.json', json({ pages: [] })],
  ] as const) {
    const client = new MathpixClient(credential, async () => response);
    await assert.rejects(client.output(ready(), format), /provider_output_invalid/);
  }
});
