// Interest index delivery (Edge function interest-index) and the worker job's guards (docs/architecture/INTEREST_INDEX.md).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { handleInterestIndex } from '../../supabase/functions/_shared/interest-index.ts';
import { PublicError } from '../../supabase/functions/_shared/http.ts';
import { MODEL_VERSION, interestText, runInterest } from '../../supabase/functions/_shared/interest/job.ts';

const ID = '1b2c3d4e-0000-4000-8000-000000000001';
const content = new TextEncoder().encode('artifact bytes');
const sha = createHash('sha256').update(content).digest('hex');

function deps(fail?: string) {
  const calls: [string, Record<string, unknown>][] = [];
  return { calls, deps: {
    account: async (r: Request) => { if (!r.headers.get('authorization')) throw new PublicError(401, 'authentication_required'); return 'acct'; },
    rpc: async <T,>(name: string, parameters: Record<string, unknown>): Promise<T> => {
      calls.push([name, parameters]);
      if (fail) throw new Error(fail);
      if (name === 'worker_interest_manifest') return { format: 1, shards: [] } as T;
      return { sha256: sha, bytes: content.length, content: Buffer.from(content).toString('base64') } as T;
    } } };
}
const get = (query = '', headers: Record<string, string> = { authorization: 'Bearer t' }) =>
  new Request('https://x.test/functions/v1/interest-index' + query, { headers });

test('the manifest is served to a signed-in reader, cached privately for 10 minutes', async () => {
  const { calls, deps: d } = deps();
  const response = await handleInterestIndex(get(), d, {});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { format: 1, shards: [] });
  assert.equal(response.headers.get('cache-control'), 'private, max-age=600');
  assert.deepEqual(calls, [['worker_interest_manifest', { p_account_id: 'acct' }]]);
});

test('an artifact is immutable bytes with its SHA-256 as ETag, and If-None-Match answers 304', async () => {
  const { deps: d } = deps();
  const response = await handleInterestIndex(get(`?artifact=${ID}`), d, {});
  assert.equal(response.status, 200);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), content);
  assert.equal(response.headers.get('etag'), `"${sha}"`);
  assert.match(response.headers.get('cache-control')!, /immutable/);
  const again = await handleInterestIndex(get(`?artifact=${ID}`, { authorization: 'Bearer t', 'if-none-match': `"${sha}"` }), d, {});
  assert.equal(again.status, 304);
});

test('refusals map to HTTP: not served 404, rate 429, bad id 400, no session 401, method 405, unknown 503', async () => {
  const status = async (p: Promise<Response>) => { try { return (await p).status; } catch (e) { return (e as PublicError).status; } };
  assert.equal(await status(handleInterestIndex(get(), deps('interest_unavailable').deps, {})), 404);
  assert.equal(await status(handleInterestIndex(get(), deps('request_rate_limit').deps, {})), 429);
  assert.equal(await status(handleInterestIndex(get(`?artifact=${ID}`), deps('interest_artifact_unavailable').deps, {})), 404);
  assert.equal(await status(handleInterestIndex(get('?artifact=nope'), deps().deps, {})), 400);
  assert.equal(await status(handleInterestIndex(get('', {}), deps().deps, {})), 401);
  assert.equal(await status(handleInterestIndex(new Request('https://x.test/', { method: 'POST', headers: { authorization: 'Bearer t' } }), deps().deps, {})), 405);
  assert.equal(await status(handleInterestIndex(get(), deps('something_else').deps, {})), 503);
});

test('a corrupted artifact is refused, not served', async () => {
  const d = { account: async () => 'acct', rpc: async <T,>() => ({ sha256: sha, bytes: 3, content: btoa('xyz') }) as T };
  await assert.rejects(handleInterestIndex(get(`?artifact=${ID}`), d, {}), (e: PublicError) => e.code === 'interest_integrity_failed');
});

test('the embedded text matches app_private.interest_text: whitespace runs collapsed, ends trimmed', () => {
  assert.equal(interestText('  Sparse   attention\tfor\nlong contexts ', ' A  b. '), 'Sparse attention for long contexts. A b.');
  assert.equal(interestText('Title', null), 'Title. ');
});

test('the job refuses a policy for another model and releases its claim without embedding', async () => {
  const calls: string[] = [];
  const result = await runInterest({
    rpc: async <T,>(name: string) => {
      calls.push(name);
      if (name === 'worker_interest_claim') return { claimed: true, policy: { model_version: 'other' }, map_version: null, rebuild_due: false } as T;
      return null as T;
    },
    embed: async () => { throw new Error('must not embed'); },
    modelVersion: MODEL_VERSION, now: () => 0, uuid: () => ID, log: () => {},
  }, 1000);
  assert.deepEqual(calls, ['worker_interest_claim', 'worker_interest_release']);
  assert.equal(result.counts.error, 'interest_model_mismatch');
});

test('a disabled or busy index does nothing', async () => {
  const calls: string[] = [];
  const result = await runInterest({ rpc: async <T,>(name: string) => { calls.push(name); return { claimed: false, reason: 'busy' } as T; },
    embed: async () => [], modelVersion: MODEL_VERSION, now: () => 0, uuid: () => ID, log: () => {} }, 1000);
  assert.deepEqual(calls, ['worker_interest_claim']);
  assert.deepEqual(result, { processed: 0, counts: { skipped: 'busy' } });
});
