// Library protocol (format 2), arXiv parsing and import progress wording, ported from ScienceReaderCore.
import { describe, expect, it } from 'vitest';
import { parseArxiv } from '../src/lib/arxiv';
import { decodeEntry } from '../src/lib/library';
import { type Mark, importAction, importStatus, importStep, observe, progressView, shownPercent } from '../src/lib/progress';
import { canRead, effectiveTags, rows } from '../src/lib/paper';

const at = '2026-10-07T09:00:00.123+00:00';
const item = (extra: Record<string, unknown> = {}) => ({
  kind: 'item', id: 'AAAAAAAA-0000-4000-8000-000000000001', document_id: 'dddddddd-0000-4000-8000-000000000001', created_seq: 3, state_seq: 5,
  membership_revision: 1, visible: true, added_at: at, last_remove_seq: 0, approval_id: 'eeeeeeee-0000-4000-8000-000000000001',
  version_id: 'eeeeeeee-0000-4000-8000-000000000002', metadata_id: 'eeeeeeee-0000-4000-8000-000000000003', source: 'arxiv', source_id: '2305.18290',
  source_revision: 3, metadata: { title: 'DPO', authors: ['Rafael Rafailov', 'Archit Sharma'], categories: ['cs.LG', 'cs.CL'], published_at: '2023-05-29' },
  metadata_recorded_at: at, source_url: 'https://arxiv.org/abs/2305.18290v3', scope: 'shared_catalog', page_count: 27,
  original_object_id: 'eeeeeeee-0000-4000-8000-000000000004', artifact_id: 'eeeeeeee-0000-4000-8000-000000000005', readiness: 'converted_ready', ...extra,
});
const imported = (extra: Record<string, unknown> = {}) => ({
  kind: 'import', id: 'bbbbbbbb-0000-4000-8000-000000000001', created_seq: 7, state_seq: 9, intent_revision: 1, visible: true, phase: 'acquiring',
  source: 'arxiv', source_id: '1706.03762', requested_revision: null, source_url: 'https://arxiv.org/abs/1706.03762', retryable: false, ...extra,
});

describe('library entries', () => {
  it('decodes items and imports, lowercasing identities and ignoring unknown fields', () => {
    const decoded = decodeEntry({ ...item(), some_future_field: 1 });
    expect(decoded.id).toBe('aaaaaaaa-0000-4000-8000-000000000001');
    expect(decoded.kind === 'item' && canRead(decoded)).toBe(true);
    expect(decodeEntry(imported()).kind).toBe('import');
  });
  it('after the server copies were retired, an arXiv item still reads from arXiv; a web paper has no reading copy', () => {
    // docs/architecture/DATA_HANDLING_AND_COSTS.md "Server paper copies: retired": unavailable at a newer revision, ids kept.
    const retired = { readiness: 'unavailable', render_availability: 'unavailable', original_availability: 'unavailable',
      render_availability_revision: 2, original_availability_revision: 2 };
    const arxiv = decodeEntry(item(retired));
    expect(arxiv.kind === 'item' && canRead(arxiv)).toBe(true);
    const web = decodeEntry(item({ ...retired, source: 'web', source_id: 'openalex:W2741809807', source_revision: 1, source_url: 'https://example.org/paper' }));
    expect(web.kind === 'item' && canRead(web)).toBe(false);
    const [row] = rows([web]);
    expect(row.readable).toBe(false);
    expect(row.status).toEqual({ kind: 'problem', text: 'No reading copy' });
  });
  it('rejects entries the native decoder rejects', () => {
    expect(() => decodeEntry(item({ source_url: 'https://arxiv.org/abs/2305.18290v2' }))).toThrow();
    expect(() => decodeEntry(item({ page_count: 0 }))).toThrow();
    expect(() => decodeEntry(item({ readiness: 'converted_ready', artifact_id: null }))).toThrow();
    expect(() => decodeEntry(item({ state_seq: 2 }))).toThrow();
    expect(() => decodeEntry(item({ metadata: { title: 'x', authors: [], categories: [], published_at: '2023-02-30' } }))).toThrow();
    expect(() => decodeEntry(imported({ retryable: true }))).toThrow(); // retryable only when failed
    expect(() => decodeEntry(imported({ phase: 'ready' }))).toThrow(); // a ready import is hidden and mapped
    expect(() => decodeEntry(imported({ document_id: 'dddddddd-0000-4000-8000-000000000001' }))).toThrow();
    expect(() => decodeEntry({ ...imported(), kind: 'other' })).toThrow();
  });
  it('keeps a malformed progress detail from blocking the library', () => {
    const e = decodeEntry(imported({ progress_detail: { step: 'reading_equations', percent: 400, pages: 12, pages_done: 30, eta_seconds: -1 } }));
    expect(e.kind === 'import' && e.progress_detail).toEqual({ step: 'reading_equations', percent: 0, delayed: false, pages: 12, pages_done: undefined, eta_seconds: undefined, bytes: undefined });
  });
  it('shows effective tags, falls back to arXiv topics, and hides imports resolved into a visible item', () => {
    const tagged = decodeEntry(item({ tags: ['Alignment', 'Large language models'], user_tags: ['Mine'], hidden_tags: ['alignment'] }));
    expect(tagged.kind === 'item' && effectiveTags(tagged)).toEqual(['Large language models', 'Mine']);
    const plain = decodeEntry(item());
    const resolved = decodeEntry(imported({ phase: 'ready', visible: false, document_id: plain.kind === 'item' ? plain.document_id : '', library_item_id: plain.id,
      metadata_id: 'eeeeeeee-0000-4000-8000-000000000003', version_id: 'eeeeeeee-0000-4000-8000-000000000002', source_revision: 1,
      metadata: { title: 'x', authors: [], categories: [] }, metadata_recorded_at: at, source_url: 'https://arxiv.org/abs/1706.03762v1' }));
    const list = rows([plain, resolved]);
    expect(list).toHaveLength(1);
    expect(list[0].tags).toEqual(['DPO']);
    expect(list[0].year).toBe(2023);
  });
});

describe('import progress (IMPORT_PROGRESS.md wording)', () => {
  it('names steps in the reader’s words and offers one action for stopped imports', () => {
    const reading = decodeEntry(imported({ progress: 'converting', progress_detail: { step: 'reading_equations', percent: 46, eta_seconds: 25, pages: 15, pages_done: 6 } }));
    if (reading.kind !== 'import') throw new Error();
    expect(importStep(reading)).toBe('converting');
    const view = progressView(reading, { stateSeq: 9, intent: 1, detail: reading.progress_detail, receivedAt: 0, floor: 0 }, 5_000);
    expect(view).toMatchObject({ title: 'Adding…', detail: null, time: null }); // the apps' word (ImportProgress.label)
    expect(view!.percent).toBeGreaterThanOrEqual(46);
    const failed = decodeEntry(imported({ phase: 'failed', error_code: 'download_failed', retryable: true }));
    if (failed.kind !== 'import') throw new Error();
    expect(importStatus(failed)).toBe('Couldn’t download this paper');
    expect(importStatus(failed, true)).toBe('Download failed');
    expect(importAction(failed)).toBe('retry');
    const credits = decodeEntry(imported({ phase: 'failed', error_code: 'insufficient_credits' }));
    expect(credits.kind === 'import' && importAction(credits)).toBe('credits');
    const retrying = decodeEntry(imported({ phase: 'failed', error_code: 'download_retrying' }));
    expect(retrying.kind === 'import' && importAction(retrying)).toBe(null);
  });
  it('never moves the bar backwards within an attempt', () => {
    const first = decodeEntry(imported({ state_seq: 9, progress_detail: { step: 'downloading', percent: 40, eta_seconds: 10 } }));
    const next = decodeEntry(imported({ state_seq: 10, progress_detail: { step: 'reading_equations', percent: 30, eta_seconds: 20, pages: 10 } }));
    if (first.kind !== 'import' || next.kind !== 'import') throw new Error();
    let marks = observe(new Map(), [first], 0);
    marks = observe(marks, [next], 10_000);
    const mark = marks.get(next.id) as Mark;
    expect(mark.floor).toBe(99);
    expect(shownPercent(mark, 10_000)).toBe(99);
  });
});

describe('arXiv references', () => {
  it.each([
    ['2305.18290', '2305.18290', null], ['arXiv:2305.18290v3', '2305.18290', 3], ['https://arxiv.org/abs/2305.18290v2', '2305.18290', 2],
    ['https://arxiv.org/pdf/1706.03762v7.pdf', '1706.03762', 7], ['  0704.0001 ', '0704.0001', null], ['hep-th/9901001', 'hep-th/9901001', null],
    ['math.AG/0601001', 'math/0601001', null],
  ])('%s', (input, id, revision) => expect(parseArxiv(input)).toEqual({ sourceID: id, revision }));
  it.each(['', '2305.1829', '1501.0001', '2313.00001', 'https://example.com/abs/2305.18290', 'https://arxiv.org/abs/2305.18290%20', '2305.18290v0',
    'hep-th/9901001\u0085', 'https://user@arxiv.org/abs/2305.18290'])('rejects %j', input => expect(parseArxiv(input)).toBeNull());
});
