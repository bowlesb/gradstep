import test from 'node:test';
import assert from 'node:assert/strict';
import { uploadInventoried } from '../../supabase/functions/_shared/asset-upload.ts';
import { boundedStorageDownload, deliverReaderMember, type ReaderDeliveryDeps } from '../../supabase/functions/_shared/reader-delivery.ts';
import { sha256 } from '../../supabase/functions/_shared/http.ts';
import type { PipelineDeps } from '../../supabase/functions/_shared/pipeline.ts';

const claim = { p_paper_id: crypto.randomUUID(), p_claim_id: crypto.randomUUID(), p_generation: 1 };
const bytes = new TextEncoder().encode('a safe member');

test('physical writes require inventory then a single grant; lost acknowledgement never repeats the upload', async () => {
  const events: string[] = []; let confirmations = 0;
  const deps = { uuid: () => crypto.randomUUID(), sleep: async () => {},
    rpc: async (name: string, args: Record<string, unknown>) => {
      events.push(name);
      if (name === 'worker_pipeline_asset_plan') return { upload_id: args.p_upload_id, objects: [{ id: crypto.randomUUID(), path: 'reader/hash/a.txt', verified: false }] };
      if (name === 'worker_pipeline_asset_write') return { write: true, verified: false };
      if (++confirmations < 3) throw new Error('lost acknowledgement');
    }, storage: { upload: async () => { events.push('upload'); } },
  } as unknown as PipelineDeps;
  await uploadInventoried(deps, claim, 'reader', [{ path: 'reader/hash/a.txt', bytes, mediaType: 'text/plain' }]);
  assert.deepEqual(events, ['worker_pipeline_asset_plan', 'worker_pipeline_asset_write', 'upload',
    'worker_pipeline_asset_written', 'worker_pipeline_asset_written', 'worker_pipeline_asset_written']);
});

test('unresolved grant and failed upload preserve uncertainty instead of confirming absence', async () => {
  for (const write of [false, true]) {
    const events: string[] = [];
    const deps = { uuid: () => crypto.randomUUID(), sleep: async () => {},
      rpc: async (name: string, args: Record<string, unknown>) => {
        events.push(name);
        if (name === 'worker_pipeline_asset_plan') return { upload_id: args.p_upload_id, objects: [{ id: crypto.randomUUID(), path: 'reader/hash/a.txt', verified: false }] };
        if (name === 'worker_pipeline_asset_write') return { write, verified: false };
      }, storage: { upload: async () => { events.push('upload'); throw new Error('lost response'); } },
    } as unknown as PipelineDeps;
    await assert.rejects(uploadInventoried(deps, claim, 'reader', [{ path: 'reader/hash/a.txt', bytes, mediaType: 'text/plain' }]));
    assert.equal(events.filter(e => e === 'upload').length, write ? 1 : 0);
    assert.ok(!events.includes('worker_pipeline_asset_written'));
  }
});

test('member redemption consumes authority before the one upstream GET; replay fetches nothing', async () => {
  const object = crypto.randomUUID(), token = 'a'.repeat(64), digest = await sha256(bytes);
  const request = () => new Request(`https://fixture.invalid/functions/v1/reader-member?grant=${token}&member=${object}`);
  const events: string[] = []; let consumed = false;
  const deps: ReaderDeliveryDeps = {
    account: async () => 'account',
    rpc: async <T>(name: string) => {
      events.push(name);
      if (name === 'worker_reader_delivery_redeem') {
        if (consumed) throw new Error('reader_grant_consumed'); consumed = true;
        return { grant_id: crypto.randomUUID(), bucket: 'paper-assets', path: 'reader/hash/a.txt', bytes: bytes.length, sha256: digest, media_type: 'text/plain' } as T;
      }
      return null as T;
    }, download: async () => { events.push('download'); return bytes; },
  };
  const results = await Promise.allSettled([deliverReaderMember(request(), deps, {}), deliverReaderMember(request(), deps, {})]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(events.filter(e => e === 'download').length, 1);
  assert.ok(events.indexOf('worker_reader_delivery_redeem') < events.indexOf('download'));
  const result = results.find(r => r.status === 'fulfilled') as PromiseFulfilledResult<Response>;
  assert.equal(await result.value.text(), new TextDecoder().decode(bytes));
  assert.equal(result.value.headers.get('cache-control'), 'private, no-store');
});

test('ranges, duplicate query keys and denied authorization never reach Storage', async () => {
  let read = 0, authorize = 0;
  const deps: ReaderDeliveryDeps = { account: async () => 'account',
    rpc: async () => { authorize++; throw new Error('reader_grant_unavailable'); }, download: async () => { read++; return bytes; } };
  const target = `https://fixture.invalid/functions/v1/reader-member?grant=${'a'.repeat(64)}&member=${crypto.randomUUID()}`;
  await assert.rejects(deliverReaderMember(new Request(target, { headers: { range: 'bytes=0-1' } }), deps, {}));
  await assert.rejects(deliverReaderMember(new Request(target + '&grant=extra'), deps, {}));
  assert.equal(authorize, 0);
  await assert.rejects(deliverReaderMember(new Request(target), deps, {}));
  assert.equal(authorize, 1); assert.equal(read, 0);
});

test('Storage response bounds cancel before unlimited buffering and never retry', async () => {
  let gets = 0, cancelled = 0;
  const fetcher = async () => {
    gets++;
    return new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(10)); }, cancel() { cancelled++; } }),
      { headers: { 'content-length': '10' } });
  };
  await assert.rejects(boundedStorageDownload('https://fixture.invalid', 'fake-service-key', 'paper-assets', 'reader/hash/a', 5, fetcher as typeof fetch), /too_large/);
  assert.equal(gets, 1); assert.equal(cancelled, 1);
});

test('a failed partial read preserves admitted liability and records received bytes separately', async () => {
  const receipt = crypto.randomUUID(), object = crypto.randomUUID();
  const observations: Record<string, unknown>[] = [];
  const deps: ReaderDeliveryDeps = {
    account: async () => 'account',
    rpc: async <T>(name: string, params: Record<string, unknown>) => {
      if (name === 'worker_reader_delivery_redeem') return { grant_id: receipt, bucket: 'paper-assets', path: 'reader/hash/a.txt',
        bytes: 100, sha256: 'a'.repeat(64), media_type: 'text/plain' } as T;
      observations.push(params); return null as T;
    },
    download: async (_bucket, _path, _maximum, observed) => { observed?.(37); throw new Error('connection_reset'); },
  };
  await assert.rejects(deliverReaderMember(new Request(`https://fixture.invalid/functions/v1/reader-member?grant=${'a'.repeat(64)}&member=${object}`), deps, {}));
  assert.deepEqual(observations, [{ p_grant_id: receipt, p_object_id: object, p_upstream_bytes: 37, p_response_bytes: 0, p_observation: 'upstream_failed' }]);
});
