// One bounded podcast job (or, for a staged profile, one stage of it) per worker
// request (docs/architecture/PAPER_PODCASTS.md). Every paid POST has its own durable
// grant; an unknown outcome stops the job and keeps the liability; nothing paid is
// retried automatically. Content (paper text, scripts, audio) never enters logs —
// only ids, digests and counts; staged drafts are kept as bounded server checkpoints.
import { applyCorrections, boundReport, checkScript, CHECKER_VERSION, correctionLimit, DISCLOSURE, draftRequest, FIVE_MINUTE_BOUNDS, FIVE_MINUTE_SHAPE,
  fitsInput, fixtureScript, NORMALIZATION_VERSION, normalizeText, parseReview, parseScript, requestBytes, reviewRequest, scriptCost, scriptDocument,
  scriptInstructions, SPEAKERS, type CheckedScript, type CheckerBounds, type CheckReport, type Script, type ScriptCallResult, type ScriptParams,
  type ScriptProvider, type ScriptShape } from './podcast-script.ts';
import { alignSegments, fitSpeech, fixtureAudio, joinChunks, parseWav, speechCost, speechRequest, verifyAudio, wavBytes, type Pcm,
  type SpeechProvider, type SpeechResult, type Timing } from './podcast-speech.ts';

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
  /** Ten and twenty minutes: one paid script pass per request, checkpointed in between. */
  staged?: boolean; shape?: ScriptShape; checker?: CheckerBounds;
  script: { model: string; calls: { route: string; max_input_tokens: number; max_output_tokens: number; window_seconds?: number }[] };
  speech: { model: string; max_input_tokens: number; max_output_tokens: number; max_calls?: number; max_audio_tokens?: number; window_seconds?: number;
    voices: { explainer: string; skeptic: string }; rates_microusd_per_token: { text_input: number; audio_output: number } };
  storage: { audio_bytes: number; transcript_bytes: number; manifest_bytes: number };
}
interface DraftCheckpoint { format: 1; draft: Script; draft_sha256: string; models: Record<string, string | null> }
/** `final` is the draft with the review's corrections applied; `review_sha256` digests that correction set (absent before checker v2). */
interface ScriptCheckpoint { format: 1; final: Script; draft_sha256: string | null; review_sha256?: string | null; models: Record<string, string | null> }
interface Claim {
  claimed: boolean; more?: boolean; job_id: string; claim_id: string; generation: number; origin: 'generated' | 'fixture';
  funding_kind: string; scope: 'shared' | 'private'; owner_id: string | null; episode_id: string; spec: Spec;
  metadata: { title?: string | null; authors?: unknown } | null;
  source: { document_id: string; bucket: string; path: string; sha256: string; bytes: number; normalization_version: string };
  /** A staged job continuing after its checkpoint. */
  resume?: { stage: 'review'; document: DraftCheckpoint } | { stage: 'speech'; document: ScriptCheckpoint } | null;
}
interface Admission { granted: boolean; reason?: string | null; attempt_id: string; account_id: string; operation_id: string; ceiling_microusd: number }

/** A fence or epoch change means another worker or an operator owns the job now: stop without writing. */
class Stop extends Error { constructor(code: string) { super(code); } }
/** Terminal job failure, recorded once. */
class Failure extends Error {
  readonly quality: boolean;
  constructor(code: string, quality: boolean) { super(code); this.quality = quality; }
}
/** Not enough of this request is left for the next paid call: hand the job back at its last safe point. */
class Park extends Error { constructor() { super('request_deadline'); } }
const FENCE = new Set(['stale_podcast_claim', 'podcast_epoch_changed', 'podcast_job_unavailable']);
const code = (error: unknown) => error instanceof Error && /^[a-z][a-z0-9_]{0,63}$/.test(error.message) ? error.message : 'unexpected';

export interface PodcastRunResult { processed: number; recovered: number; state: string | null; failure: string | null }

/** Recover expired leases (bounded), then claim and run at most one job (or one stage) before `deadline`. */
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

/** Each paid call needs its full typical duration plus the reserve for later stages; otherwise stop at zero charge. */
export const SCRIPT_CALL_MS = 240_000, SPEECH_CALL_MS = 240_000;
/** Staged requests: time kept after a script pass (checkpoint) and after speech (join, encode, upload, publish). */
export const STAGED_SCRIPT_RESERVE_MS = 45_000, STAGED_SPEECH_RESERVE_MS = 240_000;
/** A review reads the paper plus the draft: the draft's output cap plus this framing must still fit its input cap. */
export const REVIEW_FRAMING_TOKENS = 1_000;

async function runJob(deps: PodcastDeps, claim: Claim, deadline: number): Promise<{ state: string | null; failure: string | null }> {
  const fence = { p_job: claim.job_id, p_claim: claim.claim_id, p_generation: claim.generation };
  const spec = claim.spec, fixture = claim.origin === 'fixture', staged = !fixture && spec.staged === true;
  const resume = fixture ? null : claim.resume ?? null;
  const log = (event: string, fields: Record<string, string | number | boolean | null> = {}) => deps.log(event, { job_id: claim.job_id, ...fields });
  const remaining = () => deadline - deps.now();
  /** Non-staged: the v1 windows. Staged: the profile's window, or hand the job back if the request can't fit it. */
  const windowFor = (reserve: number, wanted: number, profileSeconds?: number) => {
    if (!staged || !profileSeconds) return callWindow(remaining(), reserve, wanted);
    const window = Math.min(profileSeconds * 1000, remaining() - reserve);
    if (window < profileSeconds * 1000) throw new Park();
    return window;
  };
  const advance = async (state: string) => {
    const r = await deps.rpc<{ state: string; canceled: boolean }>('worker_podcast_advance', { ...fence, p_state: state });
    if (r.canceled) throw new Stop('canceled');
  };
  const checkpoint = async (stage: 'draft' | 'script', document: DraftCheckpoint | ScriptCheckpoint) => {
    const r = await deps.rpc<{ state: string; canceled: boolean }>('worker_podcast_checkpoint', { ...fence, p_stage: stage, p_document: document });
    if (r.canceled) throw new Stop('canceled');
    log('podcast_checkpoint', { stage, state: r.state });
    return { state: r.state, failure: null };
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
    const bounds = spec.checker ?? FIVE_MINUTE_BOUNDS;
    // The prompt's spoken-character limit also fits the profile's speech calls (five minutes: one call).
    const instructions = scriptInstructions(spec.shape ?? FIVE_MINUTE_SHAPE, bounds.max_spoken_characters,
      { maxInputTokens: spec.speech.max_input_tokens, maxCalls: spec.speech.max_calls ?? 1 });

    let final: Script, draftDigest: string | null = null, reviewDigest: string | null = null;
    const models: Record<string, string | null> = {};
    if (fixture) {
      final = fixtureScript(paper, title);
      await advance('checking');
    } else if (resume?.stage === 'speech') {
      final = resume.document.final; draftDigest = resume.document.draft_sha256; reviewDigest = resume.document.review_sha256 ?? null;
      Object.assign(models, resume.document.models);
    } else {
      const [first, second] = spec.script.calls;
      let draft: Script;
      if (resume?.stage === 'review') {
        draft = resume.document.draft; draftDigest = resume.document.draft_sha256; Object.assign(models, resume.document.models);
      } else {
        const params = draftRequest(paper, title, first.max_output_tokens, instructions);
        // The review will read this paper plus the draft: refuse now, before any paid call, if that could not fit.
        await reviewMustFit(deps, params, first.max_input_tokens, first.max_output_tokens, second.max_input_tokens);
        const parsed = parseScript(await scriptCall(deps, fence, 'podcast_script', params, first.max_input_tokens,
          () => windowFor(staged ? STAGED_SCRIPT_RESERVE_MS : 180_000, SCRIPT_CALL_MS, first.window_seconds), models));
        if (!parsed) throw new Failure('script_invalid', true);
        draft = parsed;
        draftDigest = await deps.sha256Hex(new TextEncoder().encode(JSON.stringify(draft)));
        if (staged) return await checkpoint('draft', { format: 1, draft, draft_sha256: draftDigest, models });
        await advance('checking');
      }
      // The review returns a bounded correction set (never the whole script), applied here deterministically.
      const review = parseReview(await scriptCall(deps, fence, 'podcast_review', reviewRequest(paper, title, draft, second.max_output_tokens, instructions),
        second.max_input_tokens, () => windowFor(staged ? STAGED_SCRIPT_RESERVE_MS : 180_000, SCRIPT_CALL_MS, second.window_seconds), models));
      if (!review) throw new Failure('script_invalid', true);
      reviewDigest = await deps.sha256Hex(new TextEncoder().encode(JSON.stringify(review)));
      const reviewed = applyCorrections(draft, review, correctionLimit(second.max_output_tokens));
      if (!reviewed.ok) {
        log('podcast_review_invalid', { problems: reviewed.problems.length, first: reviewed.problems[0] ?? null });
        await recordCheck(deps, fence, { checker: CHECKER_VERSION, stage: 'review', outcome: 'rejected', rules: reviewed.problems }, log);
        throw new Failure('script_corrections_invalid', true);
      }
      log('podcast_reviewed', { verdict: review.verdict, corrections: reviewed.corrections, deleted: review.delete.length });
      final = reviewed.script;
    }
    // Checker v3 drops unverifiable evidence and removes unsupported claims within bounded shares; its
    // report (counts, ids and offsets only) is recorded with the job whatever the outcome.
    const checked = checkScript(final, paper, { fixture, bounds });
    const resumedSpeech = resume?.stage === 'speech';
    log('podcast_script_checked', { outcome: checked.report.outcome, kept: checked.report.segments?.kept ?? null, removed: checked.report.segments?.removed ?? null,
      evidence: checked.report.evidence?.checked ?? null, unverified: checked.report.evidence?.unverified ?? null, first: checked.ok ? null : checked.problems[0] ?? null });
    if (!checked.ok) { await recordCheck(deps, fence, checked.report, log); throw new Failure('script_evidence_rejected', true); }
    // The speech plan: chunks within the per-call input limit, at most the profile's calls, its audio budget shared out;
    // delivery directions are shortened if that is what it takes to fit (never a spoken word).
    const perCall = spec.speech.max_output_tokens;
    const fit = fixture ? null : fitSpeech(checked.script.segments, { maxInputTokens: spec.speech.max_input_tokens, maxCalls: spec.speech.max_calls ?? 1,
      perCallOutputTokens: perCall, maxAudioTokens: spec.speech.max_audio_tokens ?? perCall });
    const report: CheckReport = fit ? { ...checked.report, speech: { bytes: fit.bytes, budget: fit.budget, calls: fit.plan?.length ?? 0,
      styles_shortened: fit.stylesShortened } } : checked.report;
    if (fit && !fit.plan) {
      await recordCheck(deps, fence, { ...report, stage: 'speech', outcome: 'rejected', rules: ['speech_too_long'] }, log);
      throw new Failure('script_too_long_for_speech', true);
    }
    if (!resumedSpeech) await recordCheck(deps, fence, report, log);
    const plan = fit?.plan ?? null;
    const script: CheckedScript = fit ? { ...checked.script, segments: fit.segments } : checked.script;
    if (staged && resume?.stage !== 'speech') return await checkpoint('script', { format: 1, final, draft_sha256: draftDigest, review_sha256: reviewDigest, models });
    if (resume?.stage !== 'speech') await advance('synthesizing');

    // Speech: every chunk granted together, sent together, each result recorded before any is judged.
    let takes: Pcm[];
    if (fixture) {
      try { takes = [parseWav(fixtureAudio(script))]; } catch (error) { throw new Failure(code(error), true); }
    } else {
      if (!deps.speech) throw new Failure('speech_unavailable', false);
      const chunks = plan!;
      // A single call keeps the full per-call cap (the five-minute grant is unchanged).
      const requests = chunks.map(c => speechRequest({ segments: script.segments.slice(c.start, c.end) }, spec.speech.voices,
        chunks.length === 1 ? Math.min(perCall, spec.speech.max_audio_tokens ?? perCall) : c.audioTokens));
      if (requests.some(r => r.bytes > spec.speech.max_input_tokens)) throw new Failure('script_too_long_for_speech', true);
      // Never send a paid call that cannot finish inside this request: that would only create an unknown liability.
      const window = windowFor(staged ? STAGED_SPEECH_RESERVE_MS : 120_000, SPEECH_CALL_MS, spec.speech.window_seconds);
      const admissions = await admitSpeech(deps, fence, requests);
      const results: SpeechResult[] = await Promise.all(requests.map(request =>
        deps.speech!.generate(request, AbortSignal.timeout(window)).catch((): SpeechResult => ({ state: 'unknown', requestID: null, model: null,
          finishReason: null, audio: null, mimeType: null, usage: null, failure: 'transport_unknown' }))));
      for (const [i, result] of results.entries()) {
        await finishAttempt(deps, admissions[i], result.state, result.requestID,
          result.state === 'succeeded' ? speechCost(result.usage!, spec.speech.rates_microusd_per_token) : result.state === 'rejected' ? 0 : null,
          result.state === 'succeeded' ? { ...result.usage!, ...(result.audio ? { audio_ms: estimateMs(result.audio) } : {}) } : {}, result.failure);
      }
      if (results.some(r => r.state === 'unknown')) throw new Failure('speech_outcome_unknown', false);
      if (results.some(r => r.state === 'rejected')) throw new Failure('speech_rejected', false);
      if (results.some(r => r.finishReason !== 'STOP' || !r.audio || !/^audio\/(wav|x-wav|l16)/.test(r.mimeType ?? ''))) throw new Failure('speech_incomplete', true);
      models.speech = results[0].model;
      if (results.some(r => r.model !== models.speech)) throw new Failure('speech_model_changed', true);
      try { takes = results.map(r => parseWav(r.audio!)); } catch (error) { throw new Failure(code(error), true); }
      for (const [i, take] of takes.entries()) {
        // Each chunk is a complete, audible take within its own allowance.
        const problem = verifyAudio(take, { minMs: 1_000, maxMs: Math.ceil((requests[i].body.generationConfig as { maxOutputTokens: number }).maxOutputTokens / 25) * 1000 + 1_000 });
        if (problem) throw new Failure(problem, true);
      }
    }
    await advance('verifying');
    const joined = joinChunks(takes);
    const pcm = joined.pcm;
    const problem = verifyAudio(pcm, { minMs: fixture ? 1_000 : spec.min_seconds * 1000, maxMs: spec.max_seconds * 1000 });
    if (problem) throw new Failure(problem, true);
    // Approximate timing inside each chunk, placed at that chunk's exact position in the joined take.
    const timings: Timing[] = [];
    (plan ?? [{ start: 0, end: script.segments.length }]).forEach((c, i) => {
      const offset = joined.spans[i].start_ms;
      for (const t of alignSegments(script.segments.slice(c.start, c.end).map(s => s.text), joined.parts[i])) {
        timings.push({ start_ms: t.start_ms + offset, end_ms: t.end_ms + offset });
      }
    });
    const chapters = chapterTimes(script, timings, pcm.durationMs);
    const wav = wavBytes(pcm.samples, pcm.sampleRate);
    const encoded = await deps.encoder.encode(wav, chapters, script.title, AbortSignal.timeout(Math.max(1_000, Math.min(240_000, remaining() - 60_000))));
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
      speech_calls: takes.length,
      voices: fixture ? { explainer: 'tone-220hz', skeptic: 'tone-330hz' } : spec.speech.voices, encoder: encoded.encoder, checker: CHECKER_VERSION };
    const manifest = new TextEncoder().encode(JSON.stringify({ format: 1, kind: 'gradstep-podcast-release', release_key: releaseKey,
      job_id: claim.job_id, episode_id: claim.episode_id, scope: claim.scope,
      members: [{ role: 'audio', path: 'audio.m4a', sha256: audioDigest, bytes: encoded.bytes.byteLength, media_type: encoded.mediaType },
        { role: 'transcript', path: 'transcript.json', sha256: transcriptDigest, bytes: transcript.byteLength, media_type: 'application/json' }],
      script_sha256: scriptDigest, draft_sha256: draftDigest, review_sha256: reviewDigest, duration_ms: pcm.durationMs, identity,
      source: { document_id: source.document_id, text_sha256: source.sha256, normalization_version: source.normalization_version } }));
    const manifestDigest = await deps.sha256Hex(manifest);
    const prefix = claim.scope === 'shared' ? `shared/${releaseKey}/` : `private/${ownerFromSource(claim)}${releaseKey}/`;
    const objects = [
      { role: 'audio', path: prefix + 'audio.m4a', sha256: audioDigest, bytes: encoded.bytes.byteLength, media_type: 'audio/mp4', body: encoded.bytes },
      { role: 'transcript', path: prefix + 'transcript.json', sha256: transcriptDigest, bytes: transcript.byteLength, media_type: 'application/json', body: transcript },
      { role: 'manifest', path: prefix + 'manifest.json', sha256: manifestDigest, bytes: manifest.byteLength, media_type: 'application/json', body: manifest },
    ];
    const uploadID = deps.uuid();
    const planned = await deps.rpc<{ objects: { role: string; id: string; path: string; verified: boolean }[] }>('worker_podcast_asset_plan',
      { ...fence, p_upload_id: uploadID, p_objects: objects.map(({ body: _body, ...rest }) => rest) });
    for (const entry of planned.objects) {
      if (entry.verified) continue;
      const object = objects.find(o => o.path === entry.path);
      if (!object) throw new Failure('asset_plan_mismatch', false);
      const writeID = deps.uuid();
      const write = await deps.rpc<{ write: boolean; verified: boolean; bucket?: string; path?: string }>('worker_podcast_asset_write',
        { ...fence, p_upload_id: uploadID, p_object_id: entry.id, p_write_id: writeID });
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
      segments: script.segments.length, words: checked.words, speech_calls: takes.length });
    return { state: published.state, failure: null };
  } catch (error) {
    if (error instanceof Stop || FENCE.has(code(error))) { log('podcast_stopped', { code: code(error) }); return { state: null, failure: code(error) }; }
    if (error instanceof Park) {
      // Only where nothing paid would be lost (the database refuses otherwise, and the job then fails below).
      try {
        const parked = await deps.rpc<{ state: string; canceled: boolean }>('worker_podcast_yield', fence);
        log('podcast_parked', { state: parked.state });
        return { state: parked.state, failure: null };
      } catch (inner) {
        if (FENCE.has(code(inner))) return { state: null, failure: code(inner) };
        error = new Failure('deadline_before_paid_call', false);
      }
    }
    const failure = error instanceof Failure ? error : new Failure(code(error), false);
    log('podcast_failed', { code: failure.message, quality: failure.quality });
    try { await deps.rpc('worker_podcast_fail', { ...fence, p_failure: failure.message, p_quality: failure.quality }); }
    catch (inner) { log('podcast_fail_unrecorded', { code: code(inner) }); }
    return { state: 'failed', failure: failure.message };
  }
}

/** Before the first paid call: the draft must fit its cap, and the review (paper + the largest draft) must fit too. */
/** Records the checker's bounded report with the job (event 'checked'); a missing or failing recorder never stops the job. */
async function recordCheck(deps: PodcastDeps, fence: Record<string, unknown>, report: CheckReport,
  log: (event: string, fields?: Record<string, string | number | boolean | null>) => void): Promise<void> {
  try { await deps.rpc('worker_podcast_checked', { ...fence, p_report: boundReport(report) }); }
  catch (error) {
    if (FENCE.has(code(error))) throw error;
    log('podcast_check_unrecorded', { code: code(error) });
  }
}

async function reviewMustFit(deps: PodcastDeps, params: ScriptParams, draftCap: number, draftOutput: number, reviewCap: number): Promise<void> {
  const bytes = requestBytes(params);
  if (bytes <= draftCap && bytes + draftOutput + REVIEW_FRAMING_TOKENS <= reviewCap) return;
  if (!deps.script) throw new Failure('script_unavailable', false);
  const counted = await deps.script.countTokens(params, AbortSignal.timeout(30_000));
  if (!fitsInput(bytes, counted, draftCap) || counted === null || Math.ceil(counted * 1.05) + 512 + draftOutput + REVIEW_FRAMING_TOKENS > reviewCap) {
    throw new Failure('source_too_large', false);
  }
}

function ownerFromSource(claim: Claim): string {
  // The database plan check binds private paths to the private episode's owner.
  if (!claim.owner_id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(claim.owner_id)) throw new Failure('owner_unavailable', false);
  return `${claim.owner_id}/`;
}

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

/** Every chunk of the speech plan, granted together (or none); returns the grants in chunk order. */
async function admitSpeech(deps: PodcastDeps, fence: Record<string, unknown>, requests: { body: Record<string, unknown> }[]): Promise<Admission[]> {
  const chunks = [];
  for (const [i, request] of requests.entries()) {
    const digest = await deps.sha256Hex(new TextEncoder().encode(JSON.stringify(['gradstep/podcast-request/v1', fence.p_job, 'podcast_speech', i, request.body])));
    chunks.push({ attempt_id: deps.uuid(), request_sha256: digest,
      audio_tokens: (request.body.generationConfig as { maxOutputTokens: number }).maxOutputTokens });
  }
  let result: { granted: boolean; reason?: string | null; attempts?: Admission[] };
  try { result = await deps.rpc('worker_podcast_speech_begin', { ...fence, p_chunks: chunks }); }
  catch (error) {
    if (FENCE.has(code(error))) throw error;
    // The grants may have committed: never retry into another send permission.
    throw new Failure('provider_admission_unavailable', false);
  }
  if (!result?.granted || result.attempts?.length !== requests.length) throw new Stop(result?.reason === 'canceled' ? 'canceled' : 'provider_admission_refused');
  return result.attempts;
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

/** One granted script pass; returns the complete model text (the caller parses it). */
async function scriptCall(deps: PodcastDeps, fence: Record<string, unknown>, route: 'podcast_script' | 'podcast_review', params: ScriptParams,
  inputCap: number, windowFor: () => number, models: Record<string, string | null>): Promise<string | null> {
  if (!deps.script) throw new Failure('script_unavailable', false);
  const bytes = requestBytes(params);
  const counted = bytes <= inputCap ? null : await deps.script.countTokens(params, AbortSignal.timeout(30_000));
  // Refuse before any paid call; never truncate the paper silently.
  if (!fitsInput(bytes, counted, inputCap)) throw new Failure('source_too_large', false);
  const window = windowFor();
  const admission = await admit(deps, fence, route, params);
  const result: ScriptCallResult = await deps.script.generate(params, AbortSignal.timeout(window));
  models[route] = result.model;
  const cost = result.state === 'succeeded' ? scriptCost(result) : null;
  await finishAttempt(deps, admission, result.state, result.requestID, result.state === 'rejected' ? 0 : cost?.microusd ?? null, cost?.units ?? {}, result.failure);
  if (result.state === 'unknown') throw new Failure('script_outcome_unknown', false);
  if (result.state === 'rejected') throw new Failure('script_rejected', false);
  if (result.model?.replace(/-\d{8}$/, '') !== params.model) throw new Failure('script_model_changed', true);
  if (result.stopReason !== 'end_turn') throw new Failure(result.stopReason === 'refusal' ? 'script_refused' : 'script_incomplete', true);
  return result.text;
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
