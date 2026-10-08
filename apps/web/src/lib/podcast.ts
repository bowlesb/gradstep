// Paper podcasts (docs/architecture/PAPER_PODCASTS.md, "V1 implementation contract"): the Edge `podcast`
// calls and the single-use `podcast-member` audio download. Strict decoders: anything outside the
// contract is dropped or refused, never shown. No audio is persisted in the browser in v1.
import { BackendError, config, functionGet, functionPost, podcastMemberBytes } from './backend';
import { isUUID, sha256Hex } from './bytes';

export type Speaker = 'explainer' | 'skeptic';
export type ClaimType = 'paper_result' | 'author_interpretation' | 'explainer_analogy' | 'context';
export type ReleaseState = 'ready' | 'pending_review' | 'superseded' | 'quarantined' | 'withdrawn' | 'unavailable';

export interface EpisodeSource { arxivID: string | null; version: number | null; url: string | null; license: string | null }
export interface Episode {
  releaseID: string; scope: 'shared' | 'private'; title: string; year: number | null; authors: string[]; topic: string | null;
  durationMs: number; language: string; fixture: boolean; documentID: string; publishedAt: string | null; state: ReleaseState;
  source: EpisodeSource; audio: { bytes: number; sha256: string; mediaType: string };
}
export interface Chapter { id: string; title: string; startMs: number }
export interface Evidence { id: string; quote: string; section: string | null }
export interface Segment {
  id: string; speaker: Speaker; text: string; startMs: number; endMs: number; chapter: string | null; claimType: ClaimType;
  evidence: Evidence[]; math: { latex: string; spoken: string }[];
}
export interface Transcript { speakers: Record<Speaker, string>; disclosure: string; segments: Segment[] }
export interface EpisodeDetail extends Episode { chapters: Chapter[]; transcript: Transcript }
export interface Capabilities { catalog: boolean; generation: boolean; delivery: boolean; maxCredits: number; targetSeconds: number;
  transfer: { remainingBytes: number; limitBytes: number } | null }
export interface Catalog { episodes: Episode[]; next: string | null; capabilities: Capabilities }
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

function decodeEpisode(value: unknown): Episode | null {
  const v = value as Record<string, unknown> | null;
  if (!v || typeof v !== 'object') return null;
  const audio = v.audio as Record<string, unknown> | null, source = (v.source ?? {}) as Record<string, unknown>;
  if (!isUUID(v.release_id) || !isUUID(v.document_id) || (v.scope !== 'shared' && v.scope !== 'private') || !text(v.title, 2000)
    || !count(v.duration_ms, 4 * 3600_000) || !audio || !count(audio.bytes, MAX_AUDIO_BYTES) || (audio.bytes as number) < 1
    || typeof audio.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(audio.sha256) || typeof audio.media_type !== 'string'
    || !AUDIO_TYPES.has(audio.media_type.toLowerCase()) || (v.ai_audio !== undefined && v.ai_audio !== true)) return null;
  const state = typeof v.state === 'string' && STATES.has(v.state as ReleaseState) ? v.state as ReleaseState : 'ready';
  const authors = Array.isArray(v.authors) ? v.authors.filter((a): a is string => text(a, 256)).map(clean).slice(0, 64) : [];
  return {
    releaseID: v.release_id.toLowerCase(), scope: v.scope, title: clean(v.title), year: count(v.year, 9999) && (v.year as number) >= 1000 ? v.year as number : null,
    authors, topic: text(v.topic, 120) ? clean(v.topic) : null, durationMs: v.duration_ms as number, language: text(v.language, 16) ? v.language : 'en',
    fixture: v.fixture === true, documentID: v.document_id.toLowerCase(), publishedAt: optionalText(v.published_at, 64), state,
    source: { arxivID: typeof source.arxiv_id === 'string' && /^[0-9a-z.\-/]{4,40}$/i.test(source.arxiv_id) ? source.arxiv_id : null,
      version: count(source.version, 10_000) && (source.version as number) > 0 ? source.version as number : null,
      url: httpsURL(source.url), license: httpsURL(source.license) },
    audio: { bytes: audio.bytes as number, sha256: audio.sha256, mediaType: audio.media_type.toLowerCase() },
  };
}

export function decodeCapabilities(value: unknown): Capabilities {
  const v = (value ?? {}) as Record<string, unknown>, t = v.transfer as Record<string, unknown> | null | undefined;
  return { catalog: v.catalog === true, generation: v.generation === true, delivery: v.delivery === true,
    maxCredits: count(v.max_credits, 100_000) ? v.max_credits as number : 150, targetSeconds: count(v.target_seconds, 7200) ? v.target_seconds as number : 300,
    transfer: t && count(t.remaining_bytes, 2 ** 40) && count(t.limit_bytes, 2 ** 40) ? { remainingBytes: t.remaining_bytes as number, limitBytes: t.limit_bytes as number } : null };
}

export function decodeCatalog(value: unknown): Catalog {
  const v = value as Record<string, unknown> | null;
  if (!v || !Array.isArray(v.episodes) || v.episodes.length > 50) throw new BackendError('invalid_response');
  const seen = new Set<string>();
  const episodes = v.episodes.map(decodeEpisode).filter((e): e is Episode => !!e && e.state === 'ready' && !seen.has(e.releaseID) && !!seen.add(e.releaseID));
  return { episodes, next: typeof v.next === 'string' && /^[A-Za-z0-9._:-]{1,200}$/.test(v.next) ? v.next : null, capabilities: decodeCapabilities(v.capabilities) };
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
  return { ...episode, chapters, transcript: decodeTranscript(raw.transcript, episode.durationMs) };
}

/** Grant members must be the configured project's bounded `podcast-member` path: no other host, path or credential-bearing URL. */
export function decodeGrant(value: unknown, expected: Episode): Member {
  const grant = (value as Record<string, unknown> | null)?.grant as Record<string, unknown> | undefined;
  if (!grant || !Array.isArray(grant.members) || grant.members.length < 1 || grant.members.length > 4) throw new BackendError('invalid_response');
  const audio = grant.members.map(m => m as Record<string, unknown>).filter(m => m?.role === 'audio');
  if (audio.length !== 1) throw new BackendError('invalid_response');
  const m = audio[0];
  if (!count(m.bytes, MAX_AUDIO_BYTES) || m.bytes !== expected.audio.bytes || m.sha256 !== expected.audio.sha256 || typeof m.media_type !== 'string'
    || !AUDIO_TYPES.has(m.media_type.toLowerCase()) || !memberURL(m.url)) throw new BackendError('podcast_integrity_failed');
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
  const detail = decodeEpisodeDetail(await functionGet(`podcast?action=episode&release_id=${releaseID}`, { account, signal, maximum: 4_194_304 }));
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
  const member = decodeGrant(await functionPost('podcast?action=download', { release_id: episode.releaseID }, { account, signal, maximum: 65_536 }), episode);
  const bytes = await podcastMemberBytes(member.url, member.bytes, signal, account);
  if (bytes.length !== member.bytes || await sha256Hex(bytes) !== member.sha256) throw new BackendError('podcast_integrity_failed');
  return new Blob([bytes], { type: member.mediaType });
}
