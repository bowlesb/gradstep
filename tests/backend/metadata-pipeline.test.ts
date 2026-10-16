// The metadata stage without arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md, rollout step 5): an arXiv paper's catalog
// record comes from DataCite by its DOI (recorded answers in tests/backend/fixtures/datacite and fixtures/lookup); a
// paper DataCite doesn't list yet waits; nothing is ever requested from arXiv.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseDataCiteRecord } from '../../supabase/functions/_shared/datacite.ts';
import { dataciteCatalog, PENDING_ATTEMPTS, pendingDelaySeconds, runMetadataPipeline, type MetadataDeps } from '../../supabase/functions/_shared/metadata-pipeline.ts';

const recording = (path: string) => readFileSync(new URL(path, import.meta.url), 'utf8');
const DPO = recording('fixtures/datacite/2305.18290.json'), ATTENTION = recording('fixtures/lookup/datacite-id-1706.03762.json');

/** One worker pass over one claimed paper; `answer` stands in for DataCite (any other host fails the test). */
async function pass(paper: { source_id: string; requested_revision: number; failures?: number },
  answer: (url: string) => Response | Promise<Response>) {
  const calls: { name: string; args: Record<string, unknown> }[] = [], urls: string[] = [];
  const deps: MetadataDeps = {
    rpc: async <T>(name: string, args: Record<string, unknown> = {}) => {
      calls.push({ name, args });
      return (name === 'worker_pipeline_policy' ? { enabled: true } : name === 'worker_pipeline_claim'
        ? { id: 'paper', stage: 'metadata', claim_id: 'claim', generation: 1, failures: 0, ...paper } : null) as T;
    },
    fetch: (async (input: RequestInfo | URL) => {
      const url = String(input); urls.push(url);
      assert.equal(new URL(url).hostname, 'api.datacite.org', 'only DataCite is asked');
      return answer(url);
    }) as typeof fetch,
    sleep: async () => {}, now: () => Date.UTC(2026, 9, 16), uuid: () => 'claim', log: () => {},
  };
  assert.deepEqual(await runMetadataPipeline(deps, deps.now() + 60_000), { processed: 1 });
  return { calls, urls, rpc: (name: string) => calls.find(c => c.name === name)?.args };
}
const json = (body: string, status = 200) => new Response(body, { status, headers: { 'content-type': 'application/vnd.api+json' } });

test('a pinned version DataCite lists: one DataCite request, the catalog record and CC BY evidence, then membership sync', async () => {
  const run = await pass({ source_id: '2305.18290', requested_revision: 3 }, () => json(DPO));
  assert.deepEqual(run.urls, ['https://api.datacite.org/dois/10.48550/arXiv.2305.18290']);
  const args = run.rpc('worker_pipeline_datacite_metadata')!;
  assert.equal(args.p_revision, 3);
  const metadata = args.p_metadata as Record<string, unknown>;
  assert.equal(metadata.title, 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.deepEqual([metadata.published_at, metadata.updated_at, metadata.venue], ['2023-05-29', '2024-07-29', null]);
  assert.equal((metadata.authors as string[])[0], 'Rafael Rafailov');
  assert.deepEqual(Object.keys(metadata).sort(), ['abstract', 'authors', 'categories', 'published_at', 'title', 'updated_at', 'venue'],
    'exactly the catalog keys worker_record_arxiv_metadata accepts');
  const evidence = args.p_evidence as Record<string, unknown>;
  assert.equal(evidence.origin, 'datacite'); assert.equal(evidence.doi, '10.48550/arxiv.2305.18290');
  assert.equal(evidence.version, 3); assert.equal(evidence.source_revision, 3);
  assert.equal(evidence.license_uri, 'https://creativecommons.org/licenses/by/4.0/');
  assert.equal(evidence.source_url, 'https://arxiv.org/abs/2305.18290v3');
  assert.match(String(evidence.evidence_sha256), /^[0-9a-f]{64}$/);
  assert.deepEqual(run.calls.map(c => c.name), ['worker_pipeline_policy', 'worker_expire_stale_chat_operations', 'worker_pipeline_claim',
    'worker_pipeline_datacite_metadata', 'worker_pipeline_sync_imports', 'worker_pipeline_release']);
});

test('an older version: the latest record with that version\'s date; its licence is unknown, so never shared', async () => {
  const record = parseDataCiteRecord(JSON.parse(ATTENTION).data)!;
  const v2 = (await dataciteCatalog(record, 2, '2026-10-16T00:00:00.000Z'))!;
  assert.equal(v2.revision, 2);
  assert.equal(v2.metadata.updated_at, record.submitted[2]);
  assert.equal(v2.metadata.published_at, record.submitted[1]);
  assert.equal(v2.evidence.license_uri, null); assert.equal(v2.eligible, false); assert.equal(v2.evidence.version, 7);
  const latest = (await dataciteCatalog(record, null, '2026-10-16T00:00:00.000Z'))!;
  assert.equal(latest.revision, 7, 'an unpinned import takes the latest version');
  assert.equal(await dataciteCatalog(record, 8, '2026-10-16T00:00:00.000Z'), null, 'a version DataCite does not know yet');
});

test('an oversized record keeps the catalog bound: the abstract goes first, then the end of the author list', async () => {
  const record = parseDataCiteRecord(JSON.parse(DPO).data)!;
  const huge = { ...record, abstract: 'x'.repeat(23_000), authors: Array.from({ length: 400 }, (_, i) => `Author Number ${i} ${'y'.repeat(60)}`) };
  const out = (await dataciteCatalog(huge, 3, '2026-10-16T00:00:00.000Z'))!;
  assert.equal(out.metadata.abstract, null);
  assert.ok(new TextEncoder().encode(JSON.stringify(out.metadata)).length <= 30_000);
  assert.equal(out.metadata.authors[0], 'Author Number 0 ' + 'y'.repeat(60));
});

test('a paper DataCite does not list yet (or a version it lags on) waits, about 10 to 60 minutes apart, then fails retryably', async () => {
  for (const [paper, answer] of [[{ source_id: '2610.99999', requested_revision: 0 }, () => json('{}', 404)],
    [{ source_id: '2305.18290', requested_revision: 4 }, () => json(DPO)]] as const) {
    const run = await pass(paper, answer);
    const defer = run.rpc('worker_pipeline_defer')!;
    assert.deepEqual([defer.p_seconds, defer.p_error_code, defer.p_fail], [600, 'metadata_pending', false]);
    assert.ok(!run.rpc('worker_pipeline_datacite_metadata'));
  }
  assert.deepEqual([1, 2, 6, 11].map(pendingDelaySeconds), [600, 1200, 3600, 3600]);
  const last = await pass({ source_id: '2610.99999', requested_revision: 0, failures: PENDING_ATTEMPTS - 1 }, () => json('{}', 404));
  assert.deepEqual([last.rpc('worker_pipeline_defer')!.p_fail, last.rpc('worker_pipeline_defer')!.p_error_code], [true, 'metadata_unavailable']);
});

test('DataCite busy or unreachable is transient; a record it cannot describe fails at once', async () => {
  const busy = await pass({ source_id: '2305.18290', requested_revision: 3 }, () => new Response('', { status: 503, headers: { 'retry-after': '1' } }));
  assert.equal(busy.urls.length, 2, 'one retry after a 503, honouring Retry-After');
  assert.deepEqual([busy.rpc('worker_pipeline_defer')!.p_fail, busy.rpc('worker_pipeline_defer')!.p_error_code], [false, 'rate_limited']);
  const down = await pass({ source_id: '2305.18290', requested_revision: 3 }, () => { throw new TypeError('network'); });
  assert.equal(down.rpc('worker_pipeline_defer')!.p_fail, false);
  const bare = JSON.parse(DPO); delete bare.data.attributes.version;
  const invalid = await pass({ source_id: '2305.18290', requested_revision: 3 }, () => json(JSON.stringify(bare)));
  assert.deepEqual([invalid.rpc('worker_pipeline_defer')!.p_fail, invalid.rpc('worker_pipeline_defer')!.p_resume_stage], [true, 'metadata']);
});

test('retained PDF and provider stages are never fetched, processed, collected or funded', async () => {
 for (const stage of ['download','private_split','ocr_fund','ocr_submit','ocr_wait','ocr_uncertain','render','source_only','done']) {
  const calls: string[] = [];
  const deps: MetadataDeps = {
   rpc: async <T>(name: string) => { calls.push(name); return (name === 'worker_pipeline_policy' ? { enabled:true } : name === 'worker_pipeline_claim'
    ? {id:'retained-paper',stage,claim_id:'claim',generation:2} : null) as T; },
   fetch: async () => {throw Error('no network allowed');}, sleep: async () => {}, now: () => 0, uuid: () => 'claim', log: () => {},
  };
  assert.deepEqual(await runMetadataPipeline(deps, 60_000), {processed:1});
  assert.deepEqual(calls,['worker_pipeline_policy','worker_expire_stale_chat_operations','worker_pipeline_claim','worker_pipeline_sync_imports','worker_pipeline_release']);
 }
});
