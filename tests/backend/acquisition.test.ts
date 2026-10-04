import test from 'node:test';
import assert from 'node:assert/strict';
import { metadataAction, metadataResult, runMetadataAction, type AcquisitionRPC, type AcquisitionRPCRequest, type MetadataDependencies } from '../../supabase/functions/_shared/acquisition.ts';
import { createMetadataSourceTransport, type MetadataSourceResult } from '../../supabase/functions/_shared/source-fetch.ts';

const account = 'aaaaaaaa-0000-4000-8000-000000000001', importedID = 'aaaaaaaa-0000-4000-8000-000000000002';
const jobID = 'aaaaaaaa-0000-4000-8000-000000000003', claimID = 'aaaaaaaa-0000-4000-8000-000000000004';
const token = 'aaaaaaaa-0000-4000-8000-000000000005', metadataID = 'aaaaaaaa-0000-4000-8000-000000000006';
const nextJob = 'aaaaaaaa-0000-4000-8000-000000000007';
const epoch = Date.parse('2026-10-03T20:00:00.000Z'), expiry = new Date(epoch + 120_000).toISOString();
const bytes = (value: string) => new TextEncoder().encode(value);
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });
const atom = bytes(`<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/1706.03762v2</id>
  <title>Bounded paper</title><published>2017-06-12T17:57:34Z</published><updated>2017-06-19T16:49:45Z</updated>
  <author><name>Example</name></author><category term="cs.LG"/></entry></feed>`);
const raw = (license = 'https://creativecommons.org/licenses/by/4.0/') => bytes(`<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
  <GetRecord><record><header><identifier>oai:arXiv.org:1706.03762</identifier></header><metadata>
  <arXivRaw xmlns="http://arxiv.org/OAI/arXivRaw/"><id>1706.03762</id><version version="v2"><date>Mon, 19 Jun 2017 16:49:45 GMT</date></version>
  <license>${license}</license></arXivRaw></metadata></record></GetRecord></OAI-PMH>`);
const catalog = { title: 'Bounded paper', authors: ['Example'], categories: ['cs.LG'], abstract: null, venue: null,
  published_at: '2017-06-12', updated_at: '2017-06-19' };
function job(changes: Record<string, unknown> = {}) {
  return { id: jobID, kind: 'lookup', source_id: '1706.03762', requested_revision: null, source_revision: null,
    metadata_id: null, metadata: null, atom_published_at: null, atom_updated_at: null, stage: 'atom', status: 'leased',
    generation: 1, claim_id: claimID, lease_until: expiry, eligibility: null, retryable: false, ...changes };
}
function licenseJob(changes: Record<string, unknown> = {}) {
  return job({ source_revision: 2, metadata_id: metadataID, metadata: structuredClone(catalog), stage: 'license',
    atom_published_at: '2017-06-12T17:57:34.000Z', atom_updated_at: '2017-06-19T16:49:45.000Z', ...changes });
}
function grant(value = job()) { return { granted: true, action: 'perform_stage', job: value, token, byte_ceiling: 1_048_576, request_deadline: expiry, reservation: null }; }
function importState(changes: Record<string, unknown> = {}, acquisition: Record<string, unknown> | null = null, desired = true) {
  return { entry: { kind: 'import', id: importedID, source: 'arxiv', source_id: '1706.03762', requested_revision: null,
    intent_revision: 1, state_seq: 1, phase: 'accepted', metadata_id: null, ...changes }, desired_present: desired, acquisition };
}
const linked = (changes: Record<string, unknown> = {}) => ({ intent_revision: 1, lookup_job_id: jobID, original_job_id: null, retired: false, ...changes });
const lookupAction = { kind: 'lookup', jobID, claimID };
const linkAction = { kind: 'link', accountID: account, importID: importedID };
type Step = { name: AcquisitionRPC; value?: unknown; run?: (body: Record<string, unknown>, request: AcquisitionRPCRequest) => unknown | Promise<unknown> };
function harness(steps: Step[], body: Uint8Array = atom) {
  let clock = epoch, fetched = 0, closed = 0;
  const calls: AcquisitionRPCRequest[] = [], sourceCalls: { url: string; init: RequestInit }[] = [];
  const deps: MetadataDependencies = {
    projectRef: 'abcdefghijklmnopqrst', environment: 'staging', now: () => clock,
    rpc: async request => {
      assert.ok(Object.isFrozen(request)); calls.push(request);
      const expected = steps.shift(); assert.ok(expected, `Unexpected RPC ${request.name}`); assert.equal(request.name, expected.name);
      const value = expected.run ? await expected.run(JSON.parse(request.body), request) : expected.value;
      return value instanceof Response ? value : json(value);
    },
    source: createMetadataSourceTransport(() => ({
      fetch: async (url, init) => { fetched++; sourceCalls.push({ url, init }); return new Response(new Uint8Array(body).buffer); },
      close: () => { closed++; },
    }), () => clock),
  };
  return { deps, calls, sourceCalls, remaining: () => steps.length, fetched: () => fetched, closed: () => closed, advance: (ms: number) => { clock += ms; } };
}
const sourceClaim = (value: unknown = grant()): Step => ({ name: 'worker_claim_arxiv_stage', value });
const closeStep = (): Step => ({ name: 'worker_finish_arxiv_request', value: { closed: true, replayed: false } });
const atomSaved = () => licenseJob({ status: 'queued', claim_id: null, lease_until: null });

test('Atom action requires one atomic permit, closes before checkpoint, and preserves full timestamps', async () => {
  const h = harness([sourceClaim(), { name: 'worker_finish_arxiv_request', run: body => {
    assert.equal(h.closed(), 1); assert.equal(body.p_token, token); assert.equal(body.p_actual_bytes, atom.length);
    return { closed: true, replayed: false };
  } }, { name: 'worker_finish_lookup', run: body => {
    assert.deepEqual(body.p_result, { revision: 2, metadata: catalog,
      atom_published_at: '2017-06-12T17:57:34.000Z', atom_updated_at: '2017-06-19T16:49:45.000Z' });
    return atomSaved();
  } }]);
  const result = await runMetadataAction(lookupAction, h.deps);
  assert.equal(result.state, 'progress'); assert.equal(result.outcome, 'metadata_pinned');
  assert.equal(h.fetched(), 1); assert.equal(h.remaining(), 0);
  assert.equal(h.sourceCalls[0].init.redirect, 'error');
  assert.equal(new URL(h.sourceCalls[0].url).searchParams.get('id_list'), '1706.03762');
  assert.equal(JSON.parse(h.calls[0].body).p_environment, 'staging');
});

test('License action reconstructs pinned full instants and yields eligible or source-only without original work', async () => {
  for (const eligible of [true, false]) {
    const h = harness([sourceClaim(grant(licenseJob())), closeStep(), { name: 'worker_finish_lookup', run: body => {
      const result = body.p_result as Record<string, unknown>;
      assert.equal(result.eligible, eligible);
      if (eligible) {
        assert.equal(result.license_uri, 'https://creativecommons.org/licenses/by/4.0/');
        assert.equal((result.evidence as Record<string, unknown>).latest_version_at, '2017-06-19T16:49:45.000Z');
      } else assert.equal(result.reason, 'license_not_supported');
      return licenseJob({ stage: 'complete', status: 'complete', eligibility: eligible ? 'eligible' : 'source_only', claim_id: null, lease_until: null });
    } }], raw(eligible ? undefined : 'https://arxiv.org/licenses/nonexclusive-distrib/1.0/'));
    const result = await runMetadataAction(lookupAction, h.deps);
    assert.equal(result.state, 'terminal'); assert.equal(result.outcome, eligible ? 'eligible' : 'source_only');
    assert.equal(h.fetched(), 1); assert.equal(h.calls.length, 3); assert.equal(h.remaining(), 0);
    assert.equal(new URL(h.sourceCalls[0].url).hostname, 'oaipmh.arxiv.org');
  }
});

test('Wait, disabled, terminal and replayed grants produce no fetch, failure mutation, or invented attempt', async () => {
  for (const action of ['wait', 'disabled', 'terminal', 'no_interest', 'reconcile']) {
    const h = harness([{ name: 'worker_claim_arxiv_stage', value: { granted: false, action, job: job(),
      next_allowed_at: expiry, token, closed: false } }]);
    const result = await runMetadataAction(lookupAction, h.deps);
    assert.equal(result.state, action === 'reconcile' ? 'reconcile_required' : action === 'no_interest' ? 'terminal' : action);
    assert.equal(h.fetched(), 0); assert.equal(h.calls.length, 1);
  }
});

test('Lost, malformed and oversized grant responses only inspect state even if a committed token exists', async () => {
  const faults = [() => { throw new Error('private transport detail'); }, () => new Response('{'),
    () => new Response(' '.repeat(65_537), { headers: { 'content-length': '1' } })];
  for (const fault of faults) {
    const h = harness([{ name: 'worker_claim_arxiv_stage', run: fault },
      { name: 'worker_acquisition_state', value: { job: job(), step: { network_token: token } } }]);
    const result = await runMetadataAction(lookupAction, h.deps);
    assert.equal(result.state, 'reconcile_required'); assert.equal(result.reconciliation, 'claim');
    assert.equal(h.fetched(), 0); assert.equal(h.remaining(), 0);
    assert.doesNotMatch(JSON.stringify(result), /private|transport detail/);
  }
});

test('A grant for another identity, generation, stage or unsafe numeric bound never reaches source transport', async () => {
  const bad = [grant(job({ id: nextJob })), grant(job({ claim_id: nextJob })), grant(job({ kind: 'original' })),
    grant(job({ generation: Number.MAX_SAFE_INTEGER + 1 })), { ...grant(), byte_ceiling: 1_048_577 },
    { ...grant(), request_deadline: '2026-10-03T19:00:00Z' }, grant(licenseJob({ metadata_id: null })),
    { ...grant(), action: 'reconcile' }, { ...grant(), reservation: {} }, grant(job({ metadata_id: metadataID }))];
  for (const value of bad) {
    const h = harness([sourceClaim(value)]);
    assert.equal((await runMetadataAction(lookupAction, h.deps)).state, 'reconcile_required');
    assert.equal(h.fetched(), 0); assert.equal(h.calls.length, 1);
  }
});

test('Prepare replay freezes deterministic operation/body and owned action before async work', async () => {
  let preparedBody: string | undefined;
  for (const lost of [false, true]) {
    const prep: Step = { name: 'worker_prepare_acquisition', run: (body, request) => {
      if (preparedBody) assert.equal(request.body, preparedBody); else preparedBody = request.body;
      assert.equal(body.p_source_id, '1706.03762'); return { job: job({ status: 'queued', claim_id: null, lease_until: null }), replayed: lost };
    } };
    const h = harness([{ name: 'worker_import_state', value: importState() },
      ...(lost ? [{ name: 'worker_prepare_acquisition' as const, run: (_: unknown, request: AcquisitionRPCRequest) => {
        assert.equal(request.body, preparedBody); throw new Error('lost acknowledgment');
      } }] : []), prep,
      { name: 'worker_link_import_acquisition', run: body => {
        assert.equal(body.p_import_id, importedID); assert.equal(body.p_expected_intent_revision, 1);
        assert.equal(body.p_expected_state_seq, 1); return importState({}, linked());
      } }, { name: 'worker_project_import_acquisition', value: importState({ phase: 'resolving', state_seq: 2 }, linked()) }]);
    const action = { ...linkAction };
    const promise = runMetadataAction(action, h.deps); action.importID = nextJob;
    assert.equal((await promise).state, 'progress'); assert.equal(h.fetched(), 0); assert.equal(h.remaining(), 0);
  }
});

test('Only HTTP 400 with the expected structured business error stops exact RPC replay', async () => {
  for (const error of [
    { status: 400, code: 'P0001', message: 'acquisition_control_capacity', definitive: true },
    { status: 500, code: 'P0001', message: 'acquisition_control_capacity', definitive: false },
    { status: 502, code: 'P0001', message: 'acquisition_control_capacity', definitive: false },
    { status: 400, code: 'OTHER', message: 'acquisition_control_capacity', definitive: false },
    { status: 400, code: 'P0001', message: 'unknown_private_detail', definitive: false },
  ]) {
    const h = harness([
      { name: 'worker_import_state', value: importState() },
      { name: 'worker_prepare_acquisition', value: json({ code: error.code, message: error.message }, error.status) },
      ...(!error.definitive ? [
        { name: 'worker_prepare_acquisition' as const, value: { job: job(), replayed: true } },
        { name: 'worker_link_import_acquisition' as const, value: importState({}, linked()) },
        { name: 'worker_project_import_acquisition' as const, value: importState({ phase: 'resolving' }, linked()) },
      ] : []),
    ]);
    const result = await runMetadataAction(linkAction, h.deps);
    assert.equal(result.state, error.definitive ? 'reconcile_required' : 'progress');
    assert.equal(h.calls.length, error.definitive ? 2 : 5);
    assert.equal(h.remaining(), 0); assert.equal(h.fetched(), 0);
    assert.doesNotMatch(JSON.stringify(result), /unknown_private_detail/);
    if (!error.definitive) assert.deepEqual(h.calls[2], h.calls[1]);
  }
});

test('Explicit retry follows the failed pinned lookup rather than refreshing latest metadata', async () => {
  const h = harness([{ name: 'worker_import_state', value: importState({ intent_revision: 2, state_seq: 7, metadata_id: metadataID }, linked()) },
    { name: 'worker_acquisition_state', value: { job: licenseJob({ status: 'failed', retryable: true, claim_id: null, lease_until: null }) } },
    { name: 'worker_retry_lookup', run: body => { assert.equal(body.p_previous_job_id, jobID); return { job: licenseJob({ id: nextJob, status: 'queued', claim_id: null, lease_until: null }), replayed: false }; } },
    { name: 'worker_link_import_acquisition', run: body => {
      assert.equal(body.p_expected_intent_revision, 2); assert.equal(body.p_expected_state_seq, 7); assert.equal(body.p_lookup_job_id, nextJob);
      return importState({ intent_revision: 2, state_seq: 7, metadata_id: metadataID }, linked({ intent_revision: 2, lookup_job_id: nextJob }));
    } }, { name: 'worker_project_import_acquisition', value: importState({ intent_revision: 2, state_seq: 8, metadata_id: metadataID, phase: 'resolving' }, linked({ intent_revision: 2, lookup_job_id: nextJob })) }]);
  assert.equal((await runMetadataAction(linkAction, h.deps)).state, 'progress');
  assert.equal(h.remaining(), 0); assert.equal(h.fetched(), 0);
});

test('Existing interest only projects, while a Cancel racing new link is never silently rebased', async () => {
  const existing = harness([{ name: 'worker_import_state', value: importState({}, linked()) },
    { name: 'worker_project_import_acquisition', value: importState({ phase: 'resolving' }, linked()) }]);
  assert.equal((await runMetadataAction(linkAction, existing.deps)).state, 'progress'); assert.equal(existing.calls.length, 2);
  const changed = harness([{ name: 'worker_import_state', value: importState() },
    { name: 'worker_prepare_acquisition', value: { job: job(), replayed: false } },
    { name: 'worker_link_import_acquisition', value: json({ code: 'P0001', message: 'stale_import_checkpoint' }, 400) },
    { name: 'worker_import_state', value: importState({ phase: 'cancelled', intent_revision: 2, state_seq: 2 }, null, false) }]);
  assert.equal((await runMetadataAction(linkAction, changed.deps)).reconciliation, 'link');
  assert.equal(changed.remaining(), 0); assert.equal(changed.fetched(), 0);
});

test('Lost closure acknowledgment retries exact facts and requires matching status before publication', async () => {
  const h = harness([sourceClaim(), { name: 'worker_finish_arxiv_request', run: () => { throw new Error('lost'); } },
    { name: 'worker_finish_arxiv_request', run: (_, request) => { assert.equal(request.body, h.calls[1].body); throw new Error('lost'); } },
    { name: 'worker_arxiv_request_state', value: { token, closed: true, actual_bytes: atom.length } },
    { name: 'worker_finish_lookup', value: atomSaved() }]);
  assert.equal((await runMetadataAction(lookupAction, h.deps)).outcome, 'metadata_pinned'); assert.equal(h.fetched(), 1);
  const uncertain = harness([sourceClaim(), { name: 'worker_finish_arxiv_request', run: () => { throw new Error('lost'); } },
    { name: 'worker_finish_arxiv_request', run: () => { throw new Error('lost'); } },
    { name: 'worker_arxiv_request_state', value: { token, closed: false, actual_bytes: null } }]);
  assert.equal((await runMetadataAction(lookupAction, uncertain.deps)).reconciliation, 'close'); assert.equal(uncertain.remaining(), 0);
});

test('Final result replay retains exact evidence timestamp and never overwrites uncertain success with failure', async () => {
  const complete = licenseJob({ stage: 'complete', status: 'complete', eligibility: 'eligible', claim_id: null, lease_until: null });
  const h = harness([sourceClaim(grant(licenseJob())), closeStep(),
    { name: 'worker_finish_lookup', run: () => { h.advance(1000); throw new Error('lost'); } },
    { name: 'worker_finish_lookup', run: (_, request) => { assert.equal(request.body, h.calls[2].body); return complete; } }], raw());
  assert.equal((await runMetadataAction(lookupAction, h.deps)).outcome, 'eligible'); assert.equal(h.fetched(), 1);
  const lost = harness([sourceClaim(), closeStep(),
    { name: 'worker_finish_lookup', run: () => { throw new Error('lost'); } },
    { name: 'worker_finish_lookup', run: () => { throw new Error('lost'); } },
    { name: 'worker_acquisition_state', value: { job: atomSaved(), step: { outcome: 'complete' } } }]);
  assert.equal((await runMetadataAction(lookupAction, lost.deps)).reconciliation, 'result');
  assert.equal(lost.remaining(), 0); assert.ok(lost.calls.every(call => call.name !== 'worker_fail_acquisition'));
});

test('Malformed final acknowledgment and a newer projection intent remain reconciliation work', async () => {
  const h = harness([sourceClaim(), closeStep(),
    { name: 'worker_finish_lookup', value: licenseJob({ source_revision: 3, status: 'queued', claim_id: null, lease_until: null }) },
    { name: 'worker_acquisition_state', value: { job: atomSaved() } },
  ]);
  assert.equal((await runMetadataAction(lookupAction, h.deps)).reconciliation, 'result');
  assert.equal(h.remaining(), 0); assert.ok(h.calls.every(call => call.name !== 'worker_fail_acquisition'));
  const newer = harness([{ name: 'worker_project_import_acquisition', value: importState({ intent_revision: 2 }, linked({ intent_revision: 2 })) }]);
  assert.equal((await runMetadataAction({ kind: 'project', accountID: account, importID: importedID, intentRevision: 1 }, newer.deps)).reconciliation, 'projection');
  assert.equal(newer.calls.length, 1); assert.equal(newer.remaining(), 0);
});

test('Uncertain transfer preserves the gate and reports failure only through the captured fenced claim', async () => {
  const h = harness([sourceClaim(), { name: 'worker_fail_acquisition', run: body => {
    assert.equal(body.p_claim_id, claimID); assert.equal(body.p_generation, 1); assert.equal(body.p_error_code, 'metadata_unavailable');
    return job({ status: 'retry_wait', claim_id: null, lease_until: null, retryable: true });
  } }]);
  const result = await runMetadataAction(lookupAction, { ...h.deps, source: async () => ({ kind: 'uncertain', reason: 'size' }) });
  assert.equal(result.outcome, 'failed'); assert.ok(h.calls.every(call => call.name !== 'worker_finish_arxiv_request'));
});

test('Source status and parser failures release only proven closure and never checkpoint invented metadata', async () => {
  for (const status of [302, 404, 429, 503, 200]) {
    const h = harness([sourceClaim(), closeStep(), { name: 'worker_fail_acquisition', run: body => {
      assert.equal(body.p_error_code, status === 200 ? 'invalid_source_metadata' : status === 404 ? 'source_not_found' : status === 429 ? 'rate_limited' : 'metadata_unavailable');
      assert.equal(body.p_retryable, status === 429 || status === 503);
      return job({ status: 'failed', claim_id: null, lease_until: null });
    } }]);
    const source = createMetadataSourceTransport(() => ({ fetch: async (_url, init) => {
      assert.equal(init.redirect, 'error'); return new Response('<not-metadata/>', { status });
    }, close: () => {} }), () => epoch);
    assert.equal((await runMetadataAction(lookupAction, { ...h.deps, source })).outcome, 'failed'); assert.equal(h.remaining(), 0);
  }
});

test('Public actions/results and deployment configuration fail closed before RPC', async () => {
  for (const value of [{ ...linkAction, url: 'https://evil.test/' }, { ...lookupAction, claimID: 'bad' },
    { kind: 'project', accountID: account, importID: importedID, intentRevision: 0 },
    { kind: 'project', accountID: account, importID: importedID, intentRevision: Number.MAX_SAFE_INTEGER + 1 }]) assert.throws(() => metadataAction(value));
  const h = harness([]);
  await assert.rejects(runMetadataAction(lookupAction, { ...h.deps, environment: 'production' as 'staging' }));
  assert.equal(h.calls.length, 0);
  const valid = { state: 'wait', jobID, importID: null, nextAttemptAt: expiry, outcome: null, reconciliation: null };
  assert.equal(metadataResult(valid).jobID, jobID);
  assert.throws(() => metadataResult({ ...valid, privateMessage: 'not public' }));
  assert.throws(() => metadataResult({ ...valid, state: 'reconcile_required' }));
  assert.throws(() => metadataResult({ ...valid, nextAttemptAt: '2026-02-30T00:00:00Z' }));
});

test('Cancellation and expired invocation stop dispatch even when dependencies deliver late', async () => {
  const h = harness([sourceClaim()]), controller = new AbortController();
  let release!: (value: MetadataSourceResult) => void, started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const promise = runMetadataAction(lookupAction, { ...h.deps, source: async () => { started(); return new Promise(resolve => { release = resolve; }); } }, controller.signal);
  await began; controller.abort();
  assert.equal((await promise).state, 'reconcile_required');
  release({ kind: 'complete', status: 200, bytes: atom, retryAfterSeconds: 0 });
  await Promise.resolve(); assert.equal(h.calls.length, 1);
  const clock = harness([{ name: 'worker_claim_arxiv_stage', run: () => { clock.advance(90_001); return grant(); } }]);
  assert.equal((await runMetadataAction(lookupAction, clock.deps)).reconciliation, 'deadline'); assert.equal(clock.fetched(), 0);
});

test('Complete source bytes are captured before closure/result RPC awaits', async () => {
  const shared = new Uint8Array(atom);
  const h = harness([sourceClaim(), { name: 'worker_finish_arxiv_request', run: () => { shared.fill(0); return { closed: true, replayed: false }; } },
    { name: 'worker_finish_lookup', value: atomSaved() }]);
  assert.equal((await runMetadataAction(lookupAction, { ...h.deps, source: async () => ({ kind: 'complete', status: 200, bytes: shared, retryAfterSeconds: 0 }) })).outcome, 'metadata_pinned');
});

test('Source adapter needs full bounded EOF and connection closure; overflow, truncation and encoding remain uncertain', async () => {
  const request = { reference: { sourceID: '1706.03762', revision: null }, stage: 'atom' as const, byteCeiling: 16, deadline: epoch + 30_000 };
  const responses = [new Response('123', { headers: { 'content-length': '2' } }),
    new Response('x'.repeat(17), { headers: { 'content-length': '1' } }),
    new Response('123', { headers: { 'content-encoding': 'gzip' } }),
    new Response(new ReadableStream({ start(controller) { controller.enqueue(bytes('partial')); controller.error(new Error('private input')); } }))];
  for (const response of responses) {
    let fetches = 0, closes = 0;
    const source = createMetadataSourceTransport(() => ({ fetch: async () => { fetches++; return response; }, close: () => { closes++; } }), () => epoch);
    assert.equal((await source(request, new AbortController().signal)).kind, 'uncertain');
    assert.equal(fetches, 1); assert.equal(closes, 1);
  }
  const brokenClose = createMetadataSourceTransport(() => ({ fetch: async () => new Response('complete'), close: () => { throw new Error('close unavailable'); } }), () => epoch);
  assert.equal((await brokenClose(request, new AbortController().signal)).kind, 'uncertain');
  let closed = false;
  const good = createMetadataSourceTransport(() => ({ fetch: async () => new Response('complete'), close: async () => { closed = true; } }), () => epoch);
  const complete = await good(request, new AbortController().signal);
  assert.equal(complete.kind, 'complete'); assert.equal(closed, true);
  let now = epoch;
  const expiredClose = createMetadataSourceTransport(() => ({ fetch: async () => new Response('complete'), close: () => { now += 30_001; } }), () => now);
  assert.deepEqual(await expiredClose(request, new AbortController().signal), { kind: 'uncertain', reason: 'deadline' });
});

test('Source adapter aborts a stalled body and never follows a redirected response', async () => {
  const request = { reference: { sourceID: '1706.03762', revision: null }, stage: 'atom' as const, byteCeiling: 16, deadline: epoch + 30_000 };
  const controller = new AbortController(); let opened!: () => void, closed = 0;
  const started = new Promise<void>(resolve => { opened = resolve; });
  const source = createMetadataSourceTransport(() => ({ fetch: async () => { opened(); return new Response(new ReadableStream()); }, close: () => { closed++; } }), () => epoch);
  const promise = source(request, controller.signal); await started; controller.abort();
  assert.equal((await promise).kind, 'uncertain'); assert.equal(closed, 1);
  let fetches = 0;
  const redirected = new Response('redirected'); Object.defineProperty(redirected, 'redirected', { value: true });
  const noRedirect = createMetadataSourceTransport(() => ({ fetch: async (_url, init) => { fetches++; assert.equal(init.redirect, 'error'); return redirected; }, close: () => {} }), () => epoch);
  assert.deepEqual(await noRedirect(request, new AbortController().signal), { kind: 'uncertain', reason: 'redirect' }); assert.equal(fetches, 1);
});
