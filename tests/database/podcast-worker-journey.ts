// Zero-spend end-to-end podcast journey against the real migrated database: the actual worker code
// (runPodcast), the actual Edge handlers (handlePodcast, deliverPodcastMember) and the real SQL functions,
// connected through psql with PostgREST-style named arguments. Providers, Storage and the encoder are local
// fakes; nothing leaves the machine. Run by tests/database/podcast_worker_journey.py on a disposable database.
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { runPodcast, type PodcastDeps } from '../../supabase/functions/_shared/podcast-worker.ts';
import { parseWav, wavBytes } from '../../supabase/functions/_shared/podcast-speech.ts';
import { handlePodcast } from '../../supabase/functions/_shared/podcast-api.ts';
import { deliverPodcastMember } from '../../supabase/functions/_shared/podcast-delivery.ts';
import type { Script } from '../../supabase/functions/_shared/podcast-script.ts';

const [psql, db, fixtureJSON] = [process.env.PODCAST_PSQL!, process.env.PODCAST_DB!, process.env.PODCAST_FIXTURE!];
const fixture = JSON.parse(fixtureJSON) as { owner: string; account: string; other: string; approval: string; item: string; paper: string;
  document: string; committed_before: number; episodes_before: number };
const sha = (bytes: Uint8Array | string) => createHash('sha256').update(bytes).digest('hex');

function literal(value: unknown): string {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return String(value);
  if (typeof value === 'string') return `'${value.replace(/'/g, "''")}'`;
  if (Array.isArray(value) && value.every(v => typeof v === 'string')) return `'{${value.join(',')}}'`;
  return `'${JSON.stringify(value).replace(/'/g, "''")}'`;
}
/** PostgREST-style call: named arguments, the database's RAISE text as the error message. */
function call<T>(name: string, params: Record<string, unknown>, actor?: string): T {
  const args = Object.entries(params).map(([k, v]) => `${k} => ${literal(v)}`).join(', ');
  const prefix = actor ? `set role authenticated; select set_config('request.jwt.claim.sub','${actor}',false) \\g /dev/null\n` : '';
  const result = spawnSync(psql, ['-h', '127.0.0.1', '-p', '55431', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
    { input: `${prefix}select public.${name}(${args});\n`, encoding: 'utf8', env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG'))) });
  if (result.status !== 0) {
    const message = /ERROR:\s+([^\n]+)/.exec(result.stderr)?.[1]?.trim() ?? 'database_error';
    throw new Error(/^[a-z_]{1,64}$/.test(message) ? message : `database_error: ${message}`);
  }
  const out = result.stdout.trim();
  return (out === '' ? null : JSON.parse(out)) as T;
}
const rpc = async <T>(name: string, params: Record<string, unknown>) => call<T>(name, params);

const storage = new Map<string, Uint8Array>();
storage.set('paper-assets/' + fixture.paper.split('|')[0], new TextEncoder().encode(fixture.paper.split('|')[1]));
const PAPER = fixture.paper.split('|')[1];

function tone(seconds: number): Uint8Array {
  const rate = 24_000, samples = new Int16Array(Math.round(seconds * rate));
  for (let i = 0; i < samples.length; i++) samples[i] = (i / rate) % 10 < 9.6 ? Math.round(Math.sin(2 * Math.PI * 200 * i / rate) * 5000) : 0;
  return wavBytes(samples);
}
function script(review: boolean): Script {
  // Whole sentences from body paragraphs (never headings), as a faithful script would quote them.
  const quotes = PAPER.split('\n').filter(line => line && !line.startsWith('#')).flatMap(line => line.split(/(?<=\.)\s+/)).filter(s => s.length > 30);
  const filler = ' The hosts take a moment to explain what this means for a reader who wants the details.';
  const segments = Array.from({ length: 14 }, (_, i) => ({ id: `s${i + 1}`, chapter: i < 5 ? 'c1' : i < 10 ? 'c2' : 'c3',
    speaker: (i % 2 ? 'skeptic' : 'explainer') as 'explainer' | 'skeptic', style: 'measured',
    text: (i % 2 === 0 ? 'The paper states its main finding in a single sentence.' : 'That is worth slowing down for, carefully.') + filler + filler,
    claim_type: (i % 2 === 0 ? 'paper_result' : 'context') as Script['segments'][number]['claim_type'],
    evidence: i % 2 === 0 ? [{ quote: quotes[(i / 2) % quotes.length], section: '' }] : [], math: [] }));
  return { title: 'Journey episode', chapters: [{ id: 'c1', title: 'Question' }, { id: 'c2', title: 'Evidence' }, { id: 'c3', title: 'Caveats' }],
    segments, limitations: ['Synthetic journey'], ...(review ? { review: { verdict: 'accept' as const, issues: [] } } : {}) };
}
let scriptCalls = 0, speechCalls = 0;
const deps = (): PodcastDeps => ({
  rpc: async <T>(name: string, params: Record<string, unknown>) => { try { return await rpc<T>(name, params); } catch (e) { if (process.env.PODCAST_DEBUG) console.error(name, String(e)); throw e; } },
  sha256Hex: async b => sha(b), uuid: () => randomUUID(), now: () => Date.now(), log: (event, fields) => { if (process.env.PODCAST_DEBUG) console.error(event, JSON.stringify(fields)); },
  storage: {
    download: async (bucket, path, maximum) => { const v = storage.get(`${bucket}/${path}`); if (!v || v.byteLength > maximum) throw new Error('missing'); return v; },
    upload: async (bucket, path, bytes) => { if (storage.has(`${bucket}/${path}`)) throw new Error('exists'); storage.set(`${bucket}/${path}`, bytes); },
  },
  script: { countTokens: async () => null, generate: async () => ({ state: 'succeeded', requestID: `msg_${++scriptCalls}`, model: 'claude-sonnet-5-5',
    stopReason: 'end_turn', text: JSON.stringify(script(scriptCalls % 2 === 0)), failure: null,
    usage: { input: 18_000, output: 2_500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 } }) },
  speech: { generate: async () => { speechCalls++; return { state: 'succeeded', requestID: `resp_${speechCalls}`, model: 'gemini-3.8-flash-tts',
    finishReason: 'STOP', audio: tone(140), mimeType: 'audio/wav', usage: { text_input_tokens: 1_400, audio_output_tokens: 3_500 }, failure: null }; } },
  encoder: { encode: async wav => { const pcm = parseWav(wav); const bytes = new TextEncoder().encode(`m4a-fixture-${sha(wav)}`);
    return { bytes, durationMs: pcm.durationMs, mediaType: 'audio/mp4', encoder: { codec: 'aac', fixture: 1 } }; } },
});

// 1. Operator: policy, seed allowance, a labeled fixture and a generated seed (fake providers, zero spend).
call('worker_podcast_policy_set', { p_actor: fixture.owner, p_request_id: randomUUID(), p_reason: 'Journey activation',
  p_changes: { catalog_enabled: true, delivery_enabled: true, generation_enabled: true, seed_enabled: true, fixtures_enabled: true } });
const month = new Date().toISOString().slice(0, 7) + '-01';
call('worker_podcast_seed_period', { p_actor: fixture.owner, p_request_id: randomUUID(), p_period: month, p_limit_microusd: 2_000_000,
  p_enabled: true, p_evidence: 'journey-fixture', p_max_episodes: 2 });
const fixtureJob = call<{ id: string }>('worker_podcast_seed_admit', { p_actor: fixture.owner, p_request_id: randomUUID(), p_approval_id: fixture.approval,
  p_reason: 'Labeled synthetic fixture', p_fixture: true });
let run = await runPodcast(deps(), Date.now() + 780_000, { generated: false });
assert.equal(run.state, 'ready', `fixture job: ${run.failure}`);
const seed = call<{ id: string }>('worker_podcast_seed_admit', { p_actor: fixture.owner, p_request_id: randomUUID(), p_approval_id: fixture.approval,
  p_reason: 'Generated seed with fake providers' });
run = await runPodcast(deps(), Date.now() + 780_000, { generated: true });
assert.equal(run.state, 'ready', `seed job: ${run.failure}`);
assert.equal(scriptCalls, 2); assert.equal(speechCalls, 1);
const status = call<{ recent_jobs: { id: string; attempts: { route: string; state: string; actual_microusd: number }[]; release_id: string }[]; seed_periods: { period: string; committed_microusd: number; episodes: number }[] }>('worker_podcast_status', {});
const seedJob = status.recent_jobs.find(j => j.id === seed.id)!;
assert.deepEqual(seedJob.attempts.map(a => [a.route, a.state]), [['podcast_script', 'succeeded'], ['podcast_review', 'succeeded'], ['podcast_speech', 'succeeded']]);
assert.deepEqual(seedJob.attempts.map(a => a.actual_microusd), [61_000, 61_000, 64_400]);
const period = status.seed_periods.find((p: { period?: string }) => p.period === month)!;
assert.equal(period.committed_microusd - fixture.committed_before, 186_400);
assert.equal(period.episodes - fixture.episodes_before, 1, 'fixtures never count against the seed episode cap');
for (const job of [fixtureJob.id, seed.id]) {
  const release = status.recent_jobs.find(j => j.id === job)!.release_id;
  call('worker_podcast_review', { p_actor: fixture.owner, p_request_id: randomUUID(), p_release_id: release, p_decision: 'publish', p_reason: 'Journey review' });
}

// 2. Listener (another account): the Edge API over the real functions, then single-use delivery.
const edge = (account: string) => ({ user: async () => ({ accountID: account, rpc: async <T>(name: string, params: Record<string, unknown>) => call<T>(name, params, account) }),
  service: rpc, download: async (bucket: string, path: string, maximum: number) => { const v = storage.get(`${bucket}/${path}`)!; assert.ok(v.byteLength <= maximum); return v; },
  origin: 'https://project.supabase.co', randomHex: () => createHash('sha256').update(randomUUID()).digest('hex') });
const headers = { 'Cache-Control': 'no-store' };
const observed: Record<string, unknown> = {};
const get = async (account: string, query: string, init?: RequestInit) => {
  const value = await (await handlePodcast(new Request(`https://edge.test/functions/v1/podcast?${query}`, init), edge(account), headers)).json();
  const action = /action=([a-z]+)/.exec(query)![1];
  observed[observed[action] ? `${action}_${Object.keys(observed).filter(k => k.startsWith(action)).length + 1}` : action] = value;
  return value;
};
const catalog = await get(fixture.other, 'action=catalog&limit=10');
// Other suites may have committed their own releases into this database: look only at this document's.
const ours = catalog.episodes.filter((e: { document_id: string }) => e.document_id === fixture.document);
assert.equal(ours.length, 2);
assert.equal(ours[1].fixture, true, 'fixture labeled');
const generated = ours[0];
assert.equal(generated.fixture, false); assert.equal(generated.title, 'Journey fixture paper'); assert.equal(generated.audio.media_type, 'audio/mp4');
const episode = await get(fixture.other, `action=episode&release_id=${generated.release_id}`);
assert.equal(episode.episode.chapters.length, 3);
assert.equal(episode.episode.transcript.timing, 'approximate');
assert.ok(episode.episode.transcript.segments.every((s: { start_ms: number; end_ms: number }) => s.end_ms >= s.start_ms));
assert.ok(PAPER.replace(/\s+/g, ' ').includes(episode.episode.transcript.segments[0].evidence[0].quote), 'evidence is verbatim pinned text');
const grant = await get(fixture.other, 'action=download', { method: 'POST', body: JSON.stringify({ release_id: generated.release_id }) });
const member = grant.grant.members[0];
const memberDeps = { account: async () => fixture.other, rpc,
  download: async (bucket: string, path: string) => storage.get(`${bucket}/${path}`)! };
const audio = new Uint8Array(await (await deliverPodcastMember(new Request(member.url.replace('https://project.supabase.co', 'https://edge.test')), memberDeps, headers)).arrayBuffer());
assert.equal(audio.byteLength, member.bytes); assert.equal(sha(audio), member.sha256);
await assert.rejects(deliverPodcastMember(new Request(member.url.replace('https://project.supabase.co', 'https://edge.test')), memberDeps, headers), /podcast_grant_consumed/);

// 3. Private generation as the library owner: quote, consent, start, worker, charge within the maximum.
const paperDetail = await get(fixture.account, `action=paper&item_id=${fixture.item}`);
assert.equal(paperDetail.episode.release_id, generated.release_id, 'shared episode offered on paper detail');
const requestID = randomUUID();
const quote = await get(fixture.account, 'action=quote', { method: 'POST', body: JSON.stringify({ item_id: fixture.item, request_id: requestID }) });
assert.equal(quote.quote.max_credits, 150);
const started = await get(fixture.account, 'action=start', { method: 'POST', body: JSON.stringify({ quote_id: quote.quote.id, request_id: requestID,
  consent_version: 'podcast-private-v1' }) });
assert.equal(started.job.state, 'queued'); assert.equal(started.job.held_credits, 150);
run = await runPodcast(deps(), Date.now() + 780_000, { generated: true });
assert.equal(run.state, 'ready', `private job: ${run.failure}`);
const done = await get(fixture.account, `action=status&request_id=${requestID}`);
assert.equal(done.job.state, 'ready');
assert.equal(done.job.charged_credits, 38, '186,400 micro-USD actual usage → 38 credits');
assert.equal(done.job.released_credits, 112);
const mine = await get(fixture.account, `action=paper&item_id=${fixture.item}`);
assert.equal(mine.episode.release_id, done.job.release_id); assert.equal(mine.episode.scope, 'private'); assert.equal(mine.episode.title, null);
const states = await get(fixture.other, 'action=states', { method: 'POST', body: JSON.stringify({ release_ids: [done.job.release_id, generated.release_id] }) });
assert.equal(states.states[done.job.release_id].state, 'unavailable', 'no cross-account oracle');
assert.equal(states.states[generated.release_id].state, 'ready');
// Real server responses (ids randomized per run) for client contract tests: tests/fixtures/podcast/.
if (process.env.PODCAST_FIXTURE_OUT) {
  const { writeFileSync, mkdirSync } = await import('node:fs');
  mkdirSync(process.env.PODCAST_FIXTURE_OUT, { recursive: true });
  for (const [name, value] of Object.entries(observed)) writeFileSync(`${process.env.PODCAST_FIXTURE_OUT}/${name}.json`, JSON.stringify(value, null, 1) + '\n');
}
console.log(JSON.stringify({ ok: true, script_calls: scriptCalls, speech_calls: speechCalls, objects: storage.size }));
