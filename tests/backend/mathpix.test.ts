// The historical Mathpix OCR identity and provider record parsing remain so that retained
// mathpix-mmd reader bundles stay verifiable. There is no provider client to test: the server
// submits nothing to Mathpix (docs/architecture/HTML_FIRST_READER.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mathpixProfile, mathpixStatus, mathpixConversion } from '../../supabase/functions/_shared/mathpix.ts';

const id = '2026_10_03_synthetic123';
const ready = () => mathpixStatus({ pdf_id: id, status: 'completed', num_pages: 2, num_pages_completed: 2, version: 'fixture-v1' }, id);

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

test('OCR percentage and converter outer status never read as completed output', () => {
  const busy = mathpixStatus({ pdf_id: id, status: 'split', percent_done: 100, num_pages: 2, num_pages_completed: 2 }, id);
  assert.equal(busy.state, 'split');
  assert.equal(mathpixConversion({ status: 'completed', conversion_status: { 'mmd.zip': { status: 'processing' } } }, id).state, 'processing');
  assert.equal(mathpixConversion({ status: 'completed' }, id).state, 'missing');
  assert.equal(mathpixConversion({ status: 'completed', conversion_status: { 'mmd.zip': { status: 'completed' } } }, id).state, 'completed');
  assert.equal(ready().state, 'completed');
});
