// One bounded podcast job per worker request (docs/architecture/PAPER_PODCASTS.md).
// Every paid POST has its own durable grant; an unknown outcome stops the job and
// keeps the liability; nothing paid is retried automatically. Content (paper text,
// scripts, audio) never enters logs or database rows — only ids, digests and counts.
import { checkScript, CHECKER_VERSION, DISCLOSURE, draftRequest, fitsInput, fixtureScript, NORMALIZATION_VERSION, normalizeText,
  parseScript, requestBytes, reviewRequest, scriptCost, scriptDocument, SPEAKERS, type CheckedScript, type Script,
  type ScriptCallResult, type ScriptParams, type ScriptProvider } from './podcast-script.ts';
import { alignSegments, fixtureAudio, parseWav, speechCost, speechRequest, verifyAudio, type SpeechProvider,
  type SpeechResult, type Timing } from './podcast-speech.ts';

export interface EncodedAudio { bytes: Uint8Array; durationMs: number; mediaType: 'audio/mp4'; encoder: Record<string, string | number> }
export interface AudioEncoder {
  /** Mono AAC-LC ~64 kbit/s in MP4 with chapter markers; verified by probing the output. */
  encode(wav: Uint8Array, chapters: { title: string; start_ms: number; end_ms: number }[], title: string, signal: AbortSignal): Promise<EncodedAudio>;
}
export interface PodcastStorage {
  download(bucket: string, path: string, maximum: number): Promise<Uint8Array>;
  /** Single immutable write (no overwrite). */
  upload(bucket: string, path: string, bytes: Uint8Array, contentType: string): Promise<void>;
}
export interface PodcastDeps {
  rpc<T>(name: string, params: Record<string, unknown>): Promise<T>;
  storage: PodcastStorage;
  script: ScriptProvider | null;
  speech: SpeechProvider | null;
  encoder: AudioEncoder;
  sha256Hex(bytes: Uint8Array): Promise<string>;
  uuid(): string;
  now(): number;
  log(event: string, fields?: Record<string, string | number | boolean | null>): void;
}

interface Spec {
  id: string; version: number; target_seconds: number; min_seconds: number; max_seconds: number; max_source_bytes: number;
  script: { model: string; calls: { route: string; max_input_tokens: number; max_output_tokens: number }[] };
  speech: { model: string; max_input_tokens: number; max_output_tokens: number; voices: { explainer: string; skeptic: string };
    rates_microusd_per_token: { text_input: number; audio_output: number } };
  storage: { audio_bytes: number; transcript_bytes: number; manifest_bytes: number };
}
interface Claim {
  claimed: boolean; more?: boolean; job_id: string; claim_id: string; generation: number; origin: 'generated' | 'fixture';
  funding_kind: string; scope: 'shared' | 'private'; owner_id: string | null; episode_id: string; spec: Spec;
  metadata: { title?: string | null; authors?: unknown } | null;
  source: { document_id: string; bucket: string; path: string; sha256: string; bytes: number; normalization_version: string };
}
interface Admission { granted: boolean; reason?: string | null; attempt_id: string; account_id: string; operation_id: string; ceiling_microusd: number }

/** A fence or epoch change means another worker or an operator owns the job now: stop without writing. */
class Stop extends Error { constructor(code: string) { super(code); } }
/** Terminal job failure, recorded once. */
class Failure extends Error {
  readonly quality: boolean;
  constructor(code: string, quality: boolean) { super(code); this.quality = quality; }
}
const FENCE = new Set(['stale_podcast_claim', 'podcast_epoch_changed', 'podcast_job_unavailable']);
const code = (error: unknown) => error instanceof Error && /^[a-z][a-z0-9_]{0,63}$/.test(error.message) ? error.message : 'unexpected';

export interface PodcastRunResult { processed: number; recovered: number; state: string | null; failure: string | null }

/** Recover expired leases (bounded), then claim and run at most one job before `deadline`. */
export async function runPodcast(deps: PodcastDeps, deadline: number, options: { generated: boolean } = { generated: true }): Promise<PodcastRunResult> {
  let recovered = 0;
  for (let i = 0; i < 3; i++) {
    const r = await deps.rpc<{ recovered: boolean; more?: boolean; state?: string }>('worker_podcast_recover', {});
    if (r?.recovered) { recovered++; deps.log('podcast_recovered', { state: r.state ?? null }); }
    if (!r?.more) break;
  }
  for (let i = 0; i < 3; i++) {
    // Without every provider credential, generated jobs stay queued (never claimed into a failure).
    const claim = await deps.rpc<Claim>('worker_podcast_claim', { p_claim_id: deps.uuid(), p_generated: options.generated });
    if (claim?.claimed) {
      const outcome = await runJob(deps, claim, deadline);
      return { processed: 1, recovered, ...outcome };
    }
    if (!claim?.more) break;
  }
  return { processed: 0, recovered, state: null, failure: null };
}

async function runJob(deps: PodcastDeps, claim: Claim, deadline: number): Promise<{ state: string | null; failure: string | null }> {
  const fence = { p_job: claim.job_id, p_claim: claim.claim_id, p_generation: claim.generation };
  const spec = claim.spec, fixture = claim.origin === 'fixture';
  const log = (event: string, fields: Record<string, string | number | boolean | null> = {}) => deps.log(event, { job_id: claim.job_id, ...fields });
  const remaining = () => deadline - deps.now();
  const advance = async (state: string) => {
    const r = await deps.rpc<{ state: string; canceled: boolean }>('worker_podcast_advance', { ...fence, p_state: state });
    if (r.canceled) throw new Stop('canceled');
  };
  try {
    // The exact pinned text: verified length and digest before any paid call.
    const source = claim.source;
    if (source.normalization_version !== NORMALIZATION_VERSION || source.bytes > spec.max_source_bytes) throw new Failure('source_too_large', false);
    const raw = await deps.storage.download(source.bucket, source.path, source.bytes);
    if (raw.byteLength !== source.bytes || await deps.sha256Hex(raw) !== source.sha256) throw new Failure('source_integrity_failed', false);
    let paper: string;
    try { paper = new TextDecoder('utf-8', { fatal: true }).decode(raw); } catch { throw new Failure('source_integrity_failed', false); }
    const title = typeof claim.metadata?.title === 'string' ? claim.metadata.title : null;

    let draft: Script, final: Script, draftDigest: string | null = null;
    const models: Record<string, string | null> = {};
    if (fixture) {
      draft = final = fixtureScript(paper, title);
      await advance('checking');
    } else {
      const [first, second] = spec.script.calls;
      draft = await scriptCall(deps, fence, 'podcast_script', draftRequest(paper, title, first.max_output_tokens), first.max_input_tokens, false, remaining, models);
      draftDigest = await deps.sha256Hex(new TextEncoder().encode(JSON.stringify(draft)));
      await advance('checking');
      final = await scriptCall(deps, fence, 'podcast_review', reviewRequest(paper, title, draft, second.max_output_tokens), second.max_input_tokens, true, remaining, models);
    }
    const checked = checkScript(final, paper, { fixture });
    if (!checked.ok) { log('podcast_script_rejected', { problems: checked.problems.length, first: checked.problems[0] ?? null }); throw new Failure('script_evidence_rejected', true); }
    const script = checked.script;
    await advance('synthesizing');

    // Speech: one granted call with the profile's full serving limit.
    let wav: Uint8Array;
    if (fixture) wav = fixtureAudio(script);
    else {
      const request = speechRequest(script, spec.speech.voices, spec.speech.max_output_tokens);
      if (request.bytes > spec.speech.max_input_tokens) throw new Failure('script_too_long_for_speech', true);
      if (!deps.speech) throw new Failure('speech_unavailable', false);
      // Never send a paid call that cannot finish inside this request: that would only create an unknown liability.
      const window = callWindow(remaining(), 120_000, SPEECH_CALL_MS);
      const admission = await admit(deps, fence, 'podcast_speech', request.body);
      const result: SpeechResult = await deps.speech.generate(request, AbortSignal.timeout(window));
      models.speech = result.model;
      await finishAttempt(deps, admission, result.state, result.requestID,
        result.state === 'succeeded' ? speechCost(result.usage!, spec.speech.rates_microusd_per_token) : result.state === 'rejected' ? 0 : null,
        result.state === 'succeeded' ? { ...result.usage!, ...(result.audio ? { audio_ms: estimateMs(result.audio) } : {}) } : {}, result.failure);
      if (result.state === 'unknown') throw new Failure('speech_outcome_unknown', false);
      if (result.state === 'rejected') throw new Failure('speech_rejected', false);
      if (result.finishReason !== 'STOP' || !result.audio || !/^audio\/(wav|x-wav|l16)/.test(result.mimeType ?? '')) throw new Failure('speech_incomplete', true);
      wav = result.audio;
    }
    await advance('verifying');
    let pcm;
    try { pcm = parseWav(wav); } catch (error) { throw new Failure(code(error), true); }
    const problem = verifyAudio(pcm, { minMs: fixture ? 1_000 : spec.min_seconds * 1000, maxMs: spec.max_seconds * 1000 });
    if (problem) throw new Failure(problem, true);
    const timings = alignSegments(script.segments.map(s => s.text), pcm);
    const chapters = chapterTimes(script, timings, pcm.durationMs);
    const encoded = await deps.encoder.encode(wav, chapters, script.title, AbortSignal.timeout(Math.max(1_000, Math.min(120_000, remaining() - 60_000))));
    if (Math.abs(encoded.durationMs - pcm.durationMs) > 1_500 || encoded.bytes.byteLength > spec.storage.audio_bytes) throw new Failure('encoding_invalid', true);
    await advance('publishing');

    // Release identity: script hash, model/voice/encoder identity and member hashes.
    const document = scriptDocument(script), scriptDigest = await deps.sha256Hex(new TextEncoder().encode(document));
    const transcript = new TextEncoder().encode(JSON.stringify(transcriptDocument(claim, script, timings, chapters, fixture)));
    if (transcript.byteLength > spec.storage.transcript_bytes) throw new Failure('transcript_too_large', true);
    const audioDigest = await deps.sha256Hex(encoded.bytes), transcriptDigest = await deps.sha256Hex(transcript);
    // Bound to the job: identical bytes from two jobs (deterministic fixtures, a re-run) remain distinct releases.
    const releaseKey = await deps.sha256Hex(new TextEncoder().encode(`gradstep/podcast-release/v1:${claim.job_id}:${audioDigest}:${transcriptDigest}`));
    const identity = { profile: `${spec.id}:${spec.version}`, origin: claim.origin, script_model: fixture ? 'fixture' : models.podcast_script ?? null,
      review_model: fixture ? 'fixture' : models.podcast_review ?? null, speech_model: fixture ? 'fixture-tones-v1' : models.speech ?? null,
      voices: fixture ? { explainer: 'tone-220hz', skeptic: 'tone-330hz' } : spec.speech.voices, encoder: encoded.encoder, checker: CHECKER_VERSION };
    const manifest = new TextEncoder().encode(JSON.stringify({ format: 1, kind: 'gradstep-podcast-release', release_key: releaseKey,
      job_id: claim.job_id, episode_id: claim.episode_id, scope: claim.scope,
      members: [{ role: 'audio', path: 'audio.m4a', sha256: audioDigest, bytes: encoded.bytes.byteLength, media_type: encoded.mediaType },
        { role: 'transcript', path: 'transcript.json', sha256: transcriptDigest, bytes: transcript.byteLength, media_type: 'application/json' }],
      script_sha256: scriptDigest, draft_sha256: draftDigest, duration_ms: pcm.durationMs, identity,
      source: { document_id: source.document_id, text_sha256: source.sha256, normalization_version: source.normalization_version } }));
    const manifestDigest = await deps.sha256Hex(manifest);
    const prefix = claim.scope === 'shared' ? `shared/${releaseKey}/` : `private/${ownerFromSource(claim)}${releaseKey}/`;
    const objects = [
      { role: 'audio', path: prefix + 'audio.m4a', sha256: audioDigest, bytes: encoded.bytes.byteLength, media_type: 'audio/mp4', body: encoded.bytes },
      { role: 'transcript', path: prefix + 'transcript.json', sha256: transcriptDigest, bytes: transcript.byteLength, media_type: 'application/json', body: transcript },
      { role: 'manifest', path: prefix + 'manifest.json', sha256: manifestDigest, bytes: manifest.byteLength, media_type: 'application/json', body: manifest },
    ];
    const uploadID = deps.uuid();
    const plan = await deps.rpc<{ objects: { role: string; id: string; path: string; verified: boolean }[] }>('worker_podcast_asset_plan',
      { ...fence, p_upload_id: uploadID, p_objects: objects.map(({ body: _body, ...rest }) => rest) });
    for (const planned of plan.objects) {
      if (planned.verified) continue;
      const object = objects.find(o => o.path === planned.path);
      if (!object) throw new Failure('asset_plan_mismatch', false);
      const writeID = deps.uuid();
      const write = await deps.rpc<{ write: boolean; verified: boolean; bucket?: string; path?: string }>('worker_podcast_asset_write',
        { ...fence, p_upload_id: uploadID, p_object_id: planned.id, p_write_id: writeID });
      if (write.verified) continue;
      if (!write.write || write.bucket !== 'podcast-assets' || write.path !== object.path) throw new Failure('asset_write_uncertain', false);
      try { await deps.storage.upload('podcast-assets', object.path, object.body, object.media_type); }
      catch {
        // A lost reply may still have written: prove the exact bytes before recording.
        if (!await sameObject(deps, object)) { log('podcast_upload_uncertain', { role: object.role }); throw new Failure('upload_failed', false); }
      }
      await recordWritten(deps, writeID);
    }
    const published = await deps.rpc<{ state: string; canceled: boolean; release?: { release_id: string; state: string } }>('worker_podcast_publish', {
      ...fence, p_upload_id: uploadID, p_release: { script_sha256: scriptDigest, ...(draftDigest ? { draft_sha256: draftDigest } : {}),
        checker_version: CHECKER_VERSION, segments: script.segments.length, chapters: script.chapters.length, duration_ms: pcm.durationMs,
        manifest_sha256: manifestDigest, identity } });
    log('podcast_published', { state: published.release?.state ?? published.state, duration_ms: pcm.durationMs, bytes: encoded.bytes.byteLength,
      segments: script.segments.length, words: checked.words });
    return { state: published.state, failure: null };
  } catch (error) {
    if (error instanceof Stop || FENCE.has(code(error))) { log('podcast_stopped', { code: code(error) }); return { state: null, failure: code(error) }; }
    const failure = error instanceof Failure ? error : new Failure(code(error), false);
    log('podcast_failed', { code: failure.message, quality: failure.quality });
    try { await deps.rpc('worker_podcast_fail', { ...fence, p_failure: failure.message, p_quality: failure.quality }); }
    catch (inner) { log('podcast_fail_unrecorded', { code: code(inner) }); }
    return { state: 'failed', failure: failure.message };
  }
}

function ownerFromSource(claim: Claim): string {
  // The database plan check binds private paths to the private episode's owner.
  if (!claim.owner_id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(claim.owner_id)) throw new Failure('owner_unavailable', false);
  return `${claim.owner_id}/`;
}

/** Each paid call needs its full typical duration plus the reserve for later stages; otherwise stop at zero charge. */
export const SCRIPT_CALL_MS = 240_000, SPEECH_CALL_MS = 240_000;
function callWindow(remaining: number, reserve: number, wanted: number): number {
  const window = Math.min(300_000, remaining - reserve);
  if (window < wanted) throw new Failure('deadline_before_paid_call', false);
  return window;
}

/** The confirmation is replay-safe; a lost reply must not leave a write unresolved. */
async function recordWritten(deps: PodcastDeps, writeID: string): Promise<void> {
  for (let n = 0; n < 3; n++) {
    try { await deps.rpc('worker_podcast_asset_written', { p_write_id: writeID, p_verified: true }); return; }
    catch (error) { if (FENCE.has(code(error))) throw error; }
  }
  throw new Failure('write_unrecorded', false);
}

async function sameObject(deps: PodcastDeps, object: { path: string; sha256: string; bytes: number }): Promise<boolean> {
  try {
    const existing = await deps.storage.download('podcast-assets', object.path, object.bytes);
    return existing.byteLength === object.bytes && await deps.sha256Hex(existing) === object.sha256;
  } catch { return false; }
}

function estimateMs(wav: Uint8Array): number {
  try { return parseWav(wav).durationMs; } catch { return 0; }
}

async function admit(deps: PodcastDeps, fence: Record<string, unknown>, route: string, request: unknown): Promise<Admission> {
  const attempt = deps.uuid();
  const digest = await deps.sha256Hex(new TextEncoder().encode(JSON.stringify(['gradstep/podcast-request/v1', fence.p_job, route, request])));
  let admission: Admission;
  try {
    admission = await deps.rpc<Admission>('worker_podcast_attempt_begin', { ...fence, p_attempt_id: attempt, p_route: route, p_request_sha256: `\\x${digest}` });
  } catch (error) {
    if (FENCE.has(code(error))) throw error;
    // The grant may have committed: never retry into another send permission.
    throw new Failure('provider_admission_unavailable', false);
  }
  if (!admission?.granted) throw new Stop(admission?.reason === 'canceled' ? 'canceled' : 'provider_admission_refused');
  return admission;
}

async function finishAttempt(deps: PodcastDeps, admission: Admission, state: 'succeeded' | 'rejected' | 'unknown', requestID: string | null,
  microusd: number | null, units: Record<string, number>, failure: string | null): Promise<void> {
  const params = { p_account_id: admission.account_id, p_operation_id: admission.operation_id, p_attempt_id: admission.attempt_id,
    p_state: state, p_provider_request_id: requestID && /^[a-zA-Z0-9._:/-]{1,256}$/.test(requestID) ? requestID : null,
    p_actual_microusd: state === 'unknown' ? null : microusd, p_actual_units: units,
    p_failure_code: failure && /^[a-z][a-z0-9_]{0,63}$/.test(failure) ? failure : null };
  for (let n = 0; n < 3; n++) {
    try { await deps.rpc('worker_provider_attempt_finish', params); return; } catch { /* finish is replay-safe; never resend the provider call */ }
  }
  // Without a recorded result no further paid call may be admitted under this job.
  throw new Failure('provider_result_unrecorded', false);
}

async function scriptCall(deps: PodcastDeps, fence: Record<string, unknown>, route: 'podcast_script' | 'podcast_review', params: ScriptParams,
  inputCap: number, review: boolean, remaining: () => number, models: Record<string, string | null>): Promise<Script> {
  if (!deps.script) throw new Failure('script_unavailable', false);
  const bytes = requestBytes(params);
  const counted = bytes <= inputCap ? null : await deps.script.countTokens(params, AbortSignal.timeout(30_000));
  // Refuse before any paid call; never truncate the paper silently.
  if (!fitsInput(bytes, counted, inputCap)) throw new Failure('source_too_large', false);
  const window = callWindow(remaining(), 180_000, SCRIPT_CALL_MS);
  const admission = await admit(deps, fence, route, params);
  const result: ScriptCallResult = await deps.script.generate(params, AbortSignal.timeout(window));
  models[route] = result.model;
  const cost = result.state === 'succeeded' ? scriptCost(result) : null;
  await finishAttempt(deps, admission, result.state, result.requestID, result.state === 'rejected' ? 0 : cost?.microusd ?? null, cost?.units ?? {}, result.failure);
  if (result.state === 'unknown') throw new Failure('script_outcome_unknown', false);
  if (result.state === 'rejected') throw new Failure('script_rejected', false);
  if (result.model?.replace(/-\d{8}$/, '') !== params.model) throw new Failure('script_model_changed', true);
  if (result.stopReason !== 'end_turn') throw new Failure(result.stopReason === 'refusal' ? 'script_refused' : 'script_incomplete', true);
  const parsed = parseScript(result.text, review);
  if (!parsed) throw new Failure('script_invalid', true);
  return parsed;
}

function chapterTimes(script: CheckedScript, timings: Timing[], durationMs: number) {
  return script.chapters.map((c, i) => {
    const first = script.segments.findIndex(s => s.chapter === c.id);
    const next = script.chapters[i + 1] ? script.segments.findIndex(s => s.chapter === script.chapters[i + 1].id) : -1;
    return { id: c.id, title: c.title, start_ms: first >= 0 ? timings[first].start_ms : 0, end_ms: next >= 0 ? timings[next].start_ms : durationMs };
  });
}

/** The delivered transcript: the contract's Transcript plus chapters and attribution. */
export function transcriptDocument(claim: Claim, script: CheckedScript, timings: Timing[], chapters: { id: string; title: string; start_ms: number }[], fixture: boolean) {
  return { format: 1, title: script.title, language: 'en', speakers: SPEAKERS, timing: 'approximate',
    disclosure: fixture ? `Synthetic fixture for testing playback; not a real episode. ${DISCLOSURE}` : DISCLOSURE,
    chapters: chapters.map(c => ({ id: c.id, title: c.title, start_ms: c.start_ms })),
    segments: script.segments.map((s, i) => ({ id: s.id, speaker: s.speaker, text: s.text, start_ms: timings[i].start_ms, end_ms: timings[i].end_ms,
      chapter: s.chapter, claim_type: s.claim_type, evidence: s.evidence.map(e => ({ id: e.id, quote: e.quote, section: e.section })), math: s.math })),
    limitations: script.limitations,
    source: { document_id: claim.source.document_id, text_sha256: claim.source.sha256, normalization_version: claim.source.normalization_version },
    origin: claim.origin };
}

export { normalizeText };
