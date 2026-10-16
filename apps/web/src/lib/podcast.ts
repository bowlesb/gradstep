// Paper podcasts (docs/architecture/PAPER_PODCASTS.md, "V1 implementation contract"): the Edge `podcast`
// calls and the single-use `podcast-member` audio download. Strict decoders: anything outside the
// contract is dropped or refused, never shown. No audio is persisted in the browser in v1.
import { auth, BackendError, config, functionGet, functionPost, podcastMemberBytes } from './backend';
import { cancellation } from './cancellation';
import { isUUID, sha256Hex } from './bytes';

export type Speaker = 'explainer' | 'skeptic';
export type ClaimType = 'paper_result' | 'author_interpretation' | 'explainer_analogy' | 'context';
export type ReleaseState = 'ready' | 'pending_review' | 'superseded' | 'quarantined' | 'withdrawn' | 'unavailable';

export interface EpisodeSource { arxivID: string | null; version: number | null; url: string | null; license: string | null }
export interface Episode {
  releaseID: string; scope: 'shared' | 'private'; title: string; year: number | null; authors: string[]; topic: string | null;
  durationMs: number; language: string; fixture: boolean; documentID: string; publishedAt: string | null; state: ReleaseState;
  source: EpisodeSource; replacementID: string | null; audio: { bytes: number; sha256: string; mediaType: string };
}
export interface Chapter { id: string; title: string; startMs: number }
export interface Evidence { id: string; quote: string; section: string | null }
export interface Segment {
  id: string; speaker: Speaker; text: string; startMs: number; endMs: number; chapter: string | null; claimType: ClaimType;
  evidence: Evidence[]; math: { latex: string; spoken: string }[];
}
export interface Transcript { speakers: Record<Speaker, string>; disclosure: string; segments: Segment[] }
export interface EpisodeDetail extends Episode { chapters: Chapter[]; transcript: Transcript }
/** A writer the server offers for the default length (2026-10-14): `anthropic` (Claude Sonnet 5.5) or `deepseek`, each with its maximum. */
export interface Writer { writer: string; label: string; maxCredits: number }
export interface Capabilities { catalog: boolean; generation: boolean; delivery: boolean; maxCredits: number; targetSeconds: number;
  transfer: { remainingBytes: number; limitBytes: number } | null; writers: Writer[];
  /** Every length the server offers, shortest first, each with its writers (PodcastLength); empty before 2026-10-14. */
  lengths?: Length[] }
/** One episode length ("Short", "5 min", "10 min", "20 min"): its own episode, maximum and writers. */
export interface Length { profile: string; label: string; targetSeconds: number; maxCredits: number; writers: Writer[] }
export const DEFAULT_LENGTH = 'podcast-5min-v1';
/** "Under a minute", "About 2½ minutes", "About 10 minutes" (PodcastGenerateSheet.about). */
export function aboutMinutes(seconds: number): string {
  const minutes = seconds / 60;
  if (minutes < 1) return 'Under a minute';
  const whole = Math.floor(minutes), half = minutes - whole >= 0.5;
  return `About ${whole}${half ? '½' : ''} minute${whole === 1 && !half ? '' : 's'}`;
}
export interface Catalog { episodes: Episode[]; next: string | null; capabilities: Capabilities;
  /** The account's own episodes and requests, on the first page (migration 076); null from older servers and later pages. */
  mine: Mine | null }
/** An episode the account asked for: being made, or couldn't be made (until it asks again for that paper). */
export interface MineRequest { requestID: string; status: 'making' | 'failed'; profile: string | null; label: string | null;
  targetSeconds: number; documentID: string | null; title: string | null }
/** Listen's own section (owner, 2026-10-16: "you ask for, it doesnt matter if you leave the page or app, its there for you"). */
export interface Mine { episodes: (Episode & { requestID: string | null })[]; requests: MineRequest[] }
export interface Member { role: 'audio'; url: string; bytes: number; sha256: string; mediaType: string }

/** Audio larger than this is refused before any download (the v1 encoder ceiling is 16 MiB). */
export const MAX_AUDIO_BYTES = 16_777_216;
/** Media the browser may be handed. The fixture backend serves WAV; hosted releases are AAC in MP4. */
const AUDIO_TYPES = new Set(['audio/mp4', 'audio/mpeg', 'audio/aac', 'audio/wav', 'audio/x-wav']);
const STATES = new Set<ReleaseState>(['ready', 'pending_review', 'superseded', 'quarantined', 'withdrawn', 'unavailable']);
const CLAIMS = new Set<ClaimType>(['paper_result', 'author_interpretation', 'explainer_analogy', 'context']);

const text = (v: unknown, max: number): v is string => typeof v === 'string' && v.length > 0 && v.length <= max;
const optionalText = (v: unknown, max: number): string | null => (text(v, max) ? v : null);
const count = (v: unknown, max: number): v is number => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= max;
const clean = (s: string) => s.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
const id = (v: unknown): v is string => typeof v === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(v);
/** Only https links on a host, without credentials, are ever offered. */
function httpsURL(v: unknown): string | null {
  if (!text(v, 2048)) return null;
  try { const u = new URL(v); return u.protocol === 'https:' && !u.username && !u.password && u.hostname ? u.toString() : null; } catch { return null; }
}

export function decodeEpisode(value: unknown): Episode | null {
  const v = value as Record<string, unknown> | null;
  if (!v || typeof v !== 'object') return null;
  const audio = v.audio as Record<string, unknown> | null, source = (v.source ?? {}) as Record<string, unknown>;
  if (!isUUID(v.release_id) || !isUUID(v.document_id) || (v.scope !== 'shared' && v.scope !== 'private') || (v.scope === 'shared' ? !text(v.title, 2000) : v.title !== null && !text(v.title, 2000))
    || !count(v.duration_ms, 4 * 3600_000) || !audio || !count(audio.bytes, MAX_AUDIO_BYTES) || (audio.bytes as number) < 1
    || typeof audio.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(audio.sha256) || typeof audio.media_type !== 'string'
    || !AUDIO_TYPES.has(audio.media_type.toLowerCase()) || v.ai_audio !== true || typeof v.fixture !== 'boolean' || v.language !== 'en') return null;
  const state = typeof v.state === 'string' && STATES.has(v.state as ReleaseState) ? v.state as ReleaseState : 'unavailable';
  const authors = Array.isArray(v.authors) ? v.authors.filter((a): a is string => text(a, 256)).map(clean).slice(0, 64) : [];
  return {
    releaseID: v.release_id.toLowerCase(), scope: v.scope, title: text(v.title, 2000) ? clean(v.title) : 'Private paper episode', year: count(v.year, 9999) && (v.year as number) >= 1000 ? v.year as number : null,
    authors, topic: text(v.topic, 120) ? clean(v.topic) : null, durationMs: v.duration_ms as number, language: text(v.language, 16) ? v.language : 'en',
    fixture: v.fixture === true, documentID: v.document_id.toLowerCase(), publishedAt: optionalText(v.published_at, 64), state, replacementID: isUUID(v.replacement_id) ? v.replacement_id.toLowerCase() : null,
    source: { arxivID: typeof source.arxiv_id === 'string' && /^[0-9a-z.\-/]{4,40}$/i.test(source.arxiv_id) ? source.arxiv_id : null,
      version: count(source.version, 10_000) && (source.version as number) > 0 ? source.version as number : null,
      url: httpsURL(source.url), license: httpsURL(source.license) },
    audio: { bytes: audio.bytes as number, sha256: audio.sha256, mediaType: audio.media_type.toLowerCase() },
  };
}

export function decodeCapabilities(value: unknown): Capabilities {
  const v = (value ?? {}) as Record<string, unknown>, t = v.transfer as Record<string, unknown> | null | undefined;
  // Every length with its writers (servers from 2026-10-14; none before); `writers` stays the default length's list.
  const raw = Array.isArray(v.lengths) ? (v.lengths as Record<string, unknown>[]).slice(0, 8) : [];
  const writersOf = (l: Record<string, unknown> | undefined) => (Array.isArray(l?.writers) ? l!.writers as Record<string, unknown>[] : []).slice(0, 4)
    .filter(w => typeof w?.writer === 'string' && /^[a-z][a-z0-9_-]{1,31}$/.test(w.writer as string) && typeof w.label === 'string' && PROVIDER_LABEL.test(w.label as string) && count(w.max_credits, MAX_QUOTE_CREDITS))
    .map(w => ({ writer: w.writer as string, label: w.label as string, maxCredits: w.max_credits as number }));
  const lengths: Length[] = raw.filter(l => typeof l?.profile === 'string' && /^[a-z][a-z0-9-]{2,47}$/.test(l.profile) && typeof l.label === 'string' && l.label.trim()
      && new TextEncoder().encode(l.label).length <= 40 && count(l.target_seconds, 3600) && (l.target_seconds as number) >= 30 && count(l.max_credits, MAX_QUOTE_CREDITS))
    .filter((l, i, all) => all.findIndex(x => x.profile === l.profile) === i)
    .map(l => ({ profile: l.profile as string, label: (l.label as string).trim(), targetSeconds: l.target_seconds as number, maxCredits: l.max_credits as number, writers: writersOf(l) }));
  const writers = writersOf(raw.find(l => l?.profile === DEFAULT_LENGTH) ?? raw[0]);
  return { catalog: v.catalog === true, generation: v.generation === true, delivery: v.delivery === true,
    maxCredits: count(v.max_credits, 100_000) ? v.max_credits as number : 150, targetSeconds: count(v.target_seconds, 7200) ? v.target_seconds as number : 300,
    transfer: t && count(t.remaining_bytes, 2 ** 40) && count(t.limit_bytes, 2 ** 40) ? { remainingBytes: t.remaining_bytes as number, limitBytes: t.limit_bytes as number } : null, writers,
    ...(lengths.length ? { lengths } : {}) };
}

export function decodeCatalog(value: unknown): Catalog {
  const v = value as Record<string, unknown> | null;
  if (!v || !Array.isArray(v.episodes) || v.episodes.length > 50) throw new BackendError('invalid_response');
  const seen = new Set<string>();
  const episodes = v.episodes.map(decodeEpisode).filter((e): e is Episode => !!e && e.scope === 'shared' && e.state === 'ready' && !seen.has(e.releaseID) && !!seen.add(e.releaseID));
  return { episodes, next: typeof v.next === 'string' && /^[1-9][0-9]{0,17}$/.test(v.next) ? v.next : null, capabilities: decodeCapabilities(v.capabilities),
    mine: decodeMine(v.mine) };
}

/** Strict like the rest: only the account's own ready episodes, and requests with a known status; titles cleaned. */
export function decodeMine(value: unknown): Mine | null {
  const v = value as Record<string, unknown> | null;
  if (!v || typeof v !== 'object' || !Array.isArray(v.episodes) || !Array.isArray(v.requests) || v.episodes.length > 50 || v.requests.length > 20) return null;
  const seen = new Set<string>();
  const episodes = v.episodes.flatMap(raw => {
    const e = decodeEpisode(raw), requestID = (raw as Record<string, unknown> | null)?.request_id;
    if (!e || e.scope !== 'private' || e.state !== 'ready' || seen.has(e.releaseID)) return [];
    seen.add(e.releaseID);
    return [{ ...e, title: e.title === 'Private paper episode' ? 'Your episode' : e.title, requestID: isUUID(requestID) ? requestID.toLowerCase() : null }];
  });
  const asked = new Set<string>();
  const requests = v.requests.flatMap(raw => {
    const r = raw as Record<string, unknown> | null;
    if (!r || !isUUID(r.request_id) || asked.has(r.request_id.toLowerCase())) return [];
    asked.add(r.request_id.toLowerCase());
    return [{ requestID: r.request_id.toLowerCase(), status: r.status === 'failed' ? 'failed' as const : 'making' as const,
      profile: typeof r.profile === 'string' && /^[a-z][a-z0-9-]{2,47}$/.test(r.profile) ? r.profile : null,
      label: text(r.label, 40) ? clean(r.label) : null,
      targetSeconds: count(r.target_seconds, 3600) && (r.target_seconds as number) >= 30 ? r.target_seconds as number : 300,
      documentID: isUUID(r.document_id) ? r.document_id.toLowerCase() : null, title: text(r.title, 1000) ? clean(r.title) : null }];
  });
  return { episodes, requests };
}

function decodeTranscript(value: unknown, durationMs: number): Transcript {
  const v = value as Record<string, unknown> | null;
  if (!v || !Array.isArray(v.segments) || v.segments.length > 2000) throw new BackendError('invalid_response');
  const speakers = (v.speakers ?? {}) as Record<string, unknown>;
  const segments: Segment[] = [];
  let previous = 0;
  for (const raw of v.segments) {
    const s = raw as Record<string, unknown>;
    if (!s || !id(s.id) || (s.speaker !== 'explainer' && s.speaker !== 'skeptic') || !text(s.text, 8000) || !count(s.start_ms, durationMs + 60_000)
      || !count(s.end_ms, durationMs + 60_000) || (s.end_ms as number) < (s.start_ms as number) || (s.start_ms as number) < previous) throw new BackendError('invalid_response');
    previous = s.start_ms as number;
    const evidence = Array.isArray(s.evidence) ? s.evidence.slice(0, 16).flatMap(e => {
      const x = e as Record<string, unknown>;
      return x && id(x.id) && text(x.quote, 2000) ? [{ id: x.id, quote: x.quote.trim(), section: text(x.section, 120) ? clean(x.section) : null }] : [];
    }) : [];
    const math = Array.isArray(s.math) ? s.math.slice(0, 16).flatMap(m => {
      const x = m as Record<string, unknown>;
      return x && text(x.latex, 2000) && text(x.spoken, 2000) ? [{ latex: x.latex, spoken: clean(x.spoken) }] : [];
    }) : [];
    segments.push({ id: s.id, speaker: s.speaker, text: clean(s.text), startMs: s.start_ms as number, endMs: s.end_ms as number,
      chapter: id(s.chapter) ? s.chapter : null, claimType: CLAIMS.has(s.claim_type as ClaimType) ? s.claim_type as ClaimType : 'context', evidence, math });
  }
  return { speakers: { explainer: text(speakers.explainer, 80) ? clean(speakers.explainer) : 'Explainer', skeptic: text(speakers.skeptic, 80) ? clean(speakers.skeptic) : 'Skeptical reader' },
    disclosure: text(v.disclosure, 2000) ? clean(v.disclosure) : 'AI-generated audio from the paper’s text.', segments };
}

export function decodeEpisodeDetail(value: unknown): EpisodeDetail {
  const raw = (value as Record<string, unknown> | null)?.episode as Record<string, unknown> | undefined;
  const episode = decodeEpisode(raw);
  if (!episode || !raw || !Array.isArray(raw.chapters) || raw.chapters.length > 200) throw new BackendError('invalid_response');
  let previous = -1;
  const chapters = raw.chapters.map(c => {
    const x = c as Record<string, unknown>;
    if (!x || !id(x.id) || !text(x.title, 300) || !count(x.start_ms, episode.durationMs + 60_000) || (x.start_ms as number) <= previous) throw new BackendError('invalid_response');
    previous = x.start_ms as number;
    return { id: x.id, title: clean(x.title), startMs: x.start_ms as number };
  });
  const chapterIDs = new Set(chapters.map(c => c.id));
  const transcript = decodeTranscript(raw.transcript, episode.durationMs);
  if (!chapters.length || chapters[0].startMs !== 0 || chapterIDs.size !== chapters.length
    || !transcript.segments.length || new Set(transcript.segments.map(s => s.id)).size !== transcript.segments.length
    || transcript.segments.some(s => !s.chapter || !chapterIDs.has(s.chapter))) throw new BackendError('invalid_response');
  return { ...episode, chapters, transcript };
}

/** Grant members must be the configured project's bounded `podcast-member` path: no other host, path or credential-bearing URL. */
export function decodeGrant(value: unknown, expected: Episode): Member {
  const grant = (value as Record<string, unknown> | null)?.grant as Record<string, unknown> | undefined;
  if (!grant || !Array.isArray(grant.members) || grant.members.length < 1 || grant.members.length > 4) throw new BackendError('invalid_response');
  const audio = grant.members.map(m => m as Record<string, unknown>).filter(m => m?.role === 'audio');
  if (audio.length !== 1) throw new BackendError('invalid_response');
  const m = audio[0];
  if (!count(m.bytes, MAX_AUDIO_BYTES) || m.bytes !== expected.audio.bytes || m.sha256 !== expected.audio.sha256 || typeof m.media_type !== 'string'
    || m.media_type.toLowerCase() !== expected.audio.mediaType || !memberURL(m.url)) throw new BackendError('podcast_integrity_failed');
  return { role: 'audio', url: m.url as string, bytes: m.bytes as number, sha256: m.sha256 as string, mediaType: m.media_type.toLowerCase() };
}

export function memberURL(value: unknown): boolean {
  if (typeof value !== 'string' || value.length > 2048 || !config.url) return false;
  try {
    const u = new URL(value);
    return u.origin === new URL(config.url).origin && u.pathname === '/functions/v1/podcast-member' && !u.username && !u.password && !u.hash
      && u.searchParams.size === 2 && new Set(u.searchParams.keys()).size === 2 && /^[0-9a-f]{64}$/.test(u.searchParams.get('grant') ?? '') && isUUID(u.searchParams.get('member'));
  } catch { return false; }
}

export function decodeStates(value: unknown, ids: readonly string[]): Map<string, { state: ReleaseState; replacementID: string | null }> {
  const states = (value as Record<string, unknown> | null)?.states as Record<string, unknown> | undefined;
  const out = new Map<string, { state: ReleaseState; replacementID: string | null }>();
  if (!states || typeof states !== 'object') throw new BackendError('invalid_response');
  for (const releaseID of ids) {
    const s = states[releaseID] as Record<string, unknown> | undefined;
    out.set(releaseID, { state: s && STATES.has(s.state as ReleaseState) ? s.state as ReleaseState : 'unavailable', replacementID: s && isUUID(s.replacement_id) ? s.replacement_id.toLowerCase() : null });
  }
  return out;
}

// ---------- Calls ----------

export async function podcastCatalog(account: string, after: string | null, signal?: AbortSignal): Promise<Catalog> {
  const query = `podcast?action=catalog&limit=50${after ? `&after=${encodeURIComponent(after)}` : ''}`;
  return decodeCatalog(await functionGet(query, { account, signal, maximum: 1_048_576 }));
}

export async function podcastEpisode(account: string, releaseID: string, signal?: AbortSignal): Promise<EpisodeDetail> {
  if (!isUUID(releaseID)) throw new BackendError('invalid_release');
  const detail = decodeEpisodeDetail(await functionGet(`podcast?action=episode&release_id=${releaseID}`, { account, signal, maximum: 4_259_840 }));
  if (detail.releaseID !== releaseID.toLowerCase()) throw new BackendError('invalid_response');
  return detail;
}

export async function podcastStates(account: string, ids: readonly string[], signal?: AbortSignal) {
  if (!ids.length || ids.length > 100 || !ids.every(isUUID)) throw new BackendError('invalid_release');
  return decodeStates(await functionPost('podcast?action=states', { release_ids: ids }, { account, signal, maximum: 262_144 }), ids);
}

/** Single-use grant → one authorized GET (no Range) → exact length and SHA-256 before the bytes are used. A failed or
 * interrupted transfer needs a new grant: the server already charged its authorized bytes. */
export async function downloadEpisodeAudio(account: string, episode: Episode, signal?: AbortSignal): Promise<Blob> {
  if (episode.audio.bytes > MAX_AUDIO_BYTES) throw new BackendError('podcast_too_large');
  const before = auth.snapshot();
  const controller = cancellation([signal, before.signal]);
  try {
  controller.signal.throwIfAborted();
  const member = decodeGrant(await functionPost('podcast?action=download', { release_id: episode.releaseID }, { account, signal: controller.signal, maximum: 65_536 }), episode);
  const bytes = await podcastMemberBytes(member.url, member.bytes, controller.signal, account);
  if (bytes.length !== member.bytes || await sha256Hex(bytes) !== member.sha256) throw new BackendError('podcast_integrity_failed');
  controller.signal.throwIfAborted();
  if (auth.snapshot().generation !== before.generation) throw new BackendError('cancelled');
  return new Blob([bytes], { type: member.mediaType });
  } finally { controller.dispose(); }
}


// ---------- Explicitly quoted private generation ----------
export const CONSENT_VERSION = 'podcast-private-v1';
/** Consent versions the quote may name: v1 (Anthropic writes the script) and v2 (DeepSeek writes it, 2026-10-14). The
 * reader confirms the providers the quote lists, and the start call sends back the version the quote carried. */
export const CONSENT_VERSIONS = ['podcast-private-v1', 'podcast-private-v2'] as const;
export const PROVIDER_LABEL = /^[A-Za-z0-9 .()\-]{3,40}$/;
export const MAX_QUOTE_CREDITS = 2_000;
export const JOB_STATES = ['queued', 'scripting', 'checking', 'synthesizing', 'verifying', 'publishing', 'ready',
  'canceled', 'failed', 'capacity_wait', 'unknown_provider', 'quarantined'] as const;
export type JobState = typeof JOB_STATES[number];
export interface Job { requestID: string; state: JobState; stageEnteredAt: string; releaseID: string | null;
  heldCredits: number; chargedCredits: number | null; releasedCredits: number | null; failure: string | null;
  /** The length it is being made at, and whether a cancel was asked for (both absent from older servers). */
  profile?: string | null; cancelRequested?: boolean }
export interface Quote { id: string; expiresAt: number; maxCredits: number; estimate: string; providers: string[];
  consentVersion: typeof CONSENT_VERSIONS[number]; targetSeconds: number; /** The length's label ("10 min"), from servers that name it. */ label?: string }
export type QuoteResult = { kind: 'quote'; quote: Quote } | { kind: 'reuse'; releaseID: string } | { kind: 'join'; requestID: string };
export interface PaperPodcast { episode: Episode | null; job: Job | null; capabilities: Capabilities }
const timestamp = (v: unknown): v is string => text(v, 64) && Number.isFinite(Date.parse(v));

export function decodeJob(value: unknown): Job {
  const v = value as Record<string, unknown> | null;
  if (!v || !isUUID(v.request_id) || !JOB_STATES.includes(v.state as JobState) || !timestamp(v.stage_entered_at)
    || (v.release_id !== null && !isUUID(v.release_id)) || !count(v.held_credits, MAX_QUOTE_CREDITS)
    || (v.charged_credits !== null && !count(v.charged_credits, MAX_QUOTE_CREDITS)) || (v.released_credits !== null && !count(v.released_credits, MAX_QUOTE_CREDITS))
    || (v.state === 'ready' && !isUUID(v.release_id))) throw new BackendError('invalid_response');
  return { requestID: (v.request_id as string).toLowerCase(), state: v.state as JobState, stageEnteredAt: v.stage_entered_at,
    releaseID: isUUID(v.release_id) ? v.release_id.toLowerCase() : null, heldCredits: v.held_credits as number,
    chargedCredits: v.charged_credits as number | null, releasedCredits: v.released_credits as number | null,
    failure: typeof v.failure === 'string' && /^[a-z_]{1,64}$/.test(v.failure) ? v.failure : null,
    profile: typeof v.profile === 'string' && /^[a-z][a-z0-9-]{2,47}$/.test(v.profile) ? v.profile : null, cancelRequested: v.cancel_requested === true };
}
export function decodeQuote(value: unknown): QuoteResult {
  const v = value as { quote?: Record<string, unknown>; reuse?: { release_id?: unknown }; join?: { request_id?: unknown } } | null;
  if (!v || Number(!!v.quote) + Number(!!v.reuse) + Number(!!v.join) !== 1) throw new BackendError('invalid_response');
  if (isUUID(v.reuse?.release_id)) return { kind: 'reuse', releaseID: v.reuse.release_id.toLowerCase() };
  if (isUUID(v.join?.request_id)) return { kind: 'join', requestID: v.join.request_id.toLowerCase() };
  const q = v.quote;
  // The quote's own maximum, length and consent version (profiles change; the reader confirms what the quote says).
  if (!q || !isUUID(q.id) || !timestamp(q.expires_at) || !count(q.max_credits, MAX_QUOTE_CREDITS) || (q.max_credits as number) < 1 || !count(q.target_seconds, 7_200) || (q.target_seconds as number) < 1
    || !CONSENT_VERSIONS.includes(q.consent_version as typeof CONSENT_VERSIONS[number]) || !text(q.estimate, 2000)
    || !Array.isArray(q.providers) || q.providers.length < 1 || q.providers.length > 3
    || !q.providers.every(label => typeof label === 'string' && PROVIDER_LABEL.test(label))) throw new BackendError('invalid_response');
  return { kind: 'quote', quote: { id: q.id.toLowerCase(), expiresAt: Date.parse(q.expires_at), maxCredits: q.max_credits as number,
    estimate: clean(q.estimate), providers: q.providers as string[], consentVersion: q.consent_version as typeof CONSENT_VERSIONS[number], targetSeconds: q.target_seconds as number,
    ...(text(q.label, 40) && clean(q.label) ? { label: clean(q.label) } : {}) } };
}
export function decodePaper(value: unknown): PaperPodcast {
  const v = value as Record<string, unknown> | null;
  if (!v || !('episode' in v) || !('job' in v)) throw new BackendError('invalid_response');
  const episode = v.episode === null ? null : decodeEpisode(v.episode);
  if (v.episode !== null && !episode) throw new BackendError('invalid_response');
  return { episode, job: v.job === null ? null : decodeJob(v.job), capabilities: decodeCapabilities(v.capabilities) };
}
export async function podcastPaper(account: string, itemID: string, signal?: AbortSignal): Promise<PaperPodcast> {
  if (!isUUID(itemID)) throw new BackendError('invalid_request');
  return decodePaper(await functionGet(`podcast?action=paper&item_id=${itemID}`, { account, signal, maximum: 65_536 }));
}
/** A paper's own text on this device, for a private episode (migration 066): stored once per account and digest. */
export interface DeviceSourceText { format: 'paper-context-v2'; text: string }
/** What the quote names: the paper's identity and the stored text's digest, never the text. */
export interface DeviceSourceDescriptor { source: 'arxiv'; source_id: string; revision: number; manifest_sha256: string; text_sha256: string; title?: string; authors?: string[] }
export async function podcastUploadSource(account: string, source: DeviceSourceText, signal?: AbortSignal): Promise<{ textSHA256: string; bytes: number }> {
  if (source.format !== 'paper-context-v2' || !source.text.trim() || new TextEncoder().encode(source.text).byteLength > 409_600) throw new BackendError('source_too_large');
  const v = await functionPost<{ source?: { text_sha256?: unknown; bytes?: unknown } }>('podcast?action=source', source, { account, signal, maximum: 16_384 });
  if (!v?.source || typeof v.source.text_sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(v.source.text_sha256) || typeof v.source.bytes !== 'number') throw new BackendError('invalid_response');
  return { textSHA256: v.source.text_sha256, bytes: v.source.bytes };
}
export async function podcastQuote(account: string, itemID: string, requestID: string, signal?: AbortSignal, writer?: string, device?: DeviceSourceDescriptor, profile?: string): Promise<QuoteResult> {
  if (!isUUID(itemID) || !isUUID(requestID)) throw new BackendError('invalid_request');
  if (writer !== undefined && !/^[a-z][a-z0-9_-]{1,31}$/.test(writer)) throw new BackendError('invalid_request');
  if (profile !== undefined && !/^[a-z][a-z0-9-]{2,47}$/.test(profile)) throw new BackendError('invalid_request');
  return decodeQuote(await functionPost('podcast?action=quote', { item_id: itemID, request_id: requestID, ...(profile ? { profile } : {}), ...(writer ? { writer } : {}),
    ...(device ? { device_source: device } : {}) }, { account, signal, maximum: 16_384 }));
}
/** Start and status can reuse an episode that became ready after quoting (046), with no job or new hold. */
export type RequestResult = { kind: 'job'; job: Job } | { kind: 'reuse'; releaseID: string };
export function decodeRequestResult(value: unknown, requestID: string): RequestResult {
  const v = value as { job?: unknown; reuse?: { release_id?: unknown } } | null;
  if (!v || Number(!!v.job) + Number(!!v.reuse) !== 1) throw new BackendError('invalid_response');
  if (v.reuse) {
    if (!isUUID(v.reuse.release_id)) throw new BackendError('invalid_response');
    return { kind: 'reuse', releaseID: v.reuse.release_id.toLowerCase() };
  }
  const job = decodeJob(v.job);
  if (job.requestID !== requestID.toLowerCase()) throw new BackendError('invalid_response');
  return { kind: 'job', job };
}
/** The caller must show the quote and receive explicit confirmation. Retry with this same identity after a lost reply. */
export async function podcastStart(account: string, quote: Quote, requestID: string, signal?: AbortSignal): Promise<RequestResult> {
  if (!isUUID(requestID)) throw new BackendError('invalid_request');
  return decodeRequestResult(await functionPost('podcast?action=start',
    { quote_id: quote.id, request_id: requestID, consent_version: quote.consentVersion }, { account, signal, maximum: 16_384 }), requestID);
}
export async function podcastStatus(account: string, requestID: string, signal?: AbortSignal): Promise<RequestResult> {
  if (!isUUID(requestID)) throw new BackendError('invalid_request');
  return decodeRequestResult(await functionGet(`podcast?action=status&request_id=${requestID}`, { account, signal, maximum: 16_384 }), requestID);
}
export async function podcastCancel(account: string, requestID: string, signal?: AbortSignal): Promise<Job> {
  if (!isUUID(requestID)) throw new BackendError('invalid_request');
  const value = await functionPost<{ job: unknown }>('podcast?action=cancel', { request_id: requestID }, { account, signal, maximum: 16_384 });
  const job = decodeJob(value.job);
  if (job.requestID !== requestID.toLowerCase()) throw new BackendError('invalid_response');
  return job;
}
export const jobTerminal = (job: Job) => ['ready', 'canceled', 'failed', 'unknown_provider', 'quarantined'].includes(job.state);
export const statusPollDelay = (elapsedMs: number) => elapsedMs < 60_000 ? 5_000 : 15_000;
export const revocationPollDelay = (hidden: boolean) => hidden ? 300_000 : 60_000;
/** Listen checks for episodes being made after 15 s, 30 s, then every minute (visible only), for at most 45 minutes. */
export const mineCheckDelay = (checks: number) => [15_000, 30_000, 60_000][Math.min(checks, 2)];
export const MINE_CHECK_LIMIT_MS = 45 * 60_000;
/** "Usually ready in a few minutes." / "This length can take 10 minutes or more." (PodcastGeneration.expectedWait). */
export const expectedWait = (targetSeconds: number) => targetSeconds > 300 ? 'This length can take 10 minutes or more.' : 'Usually ready in a few minutes.';
/** The providers a quote names, as plain names: "DeepSeek and Google" (PodcastGeneration.plainProviders). */
export function plainProviders(labels: string[]): string {
  const names = labels.map(l => l.replace(/\s*\(.*\)$/, '')).map(n => n.startsWith('Google') ? 'Google' : n);
  return names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : names[0] ?? 'our providers';
}
