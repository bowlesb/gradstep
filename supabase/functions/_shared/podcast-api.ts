// Edge `podcast` API (docs/architecture/PAPER_PODCASTS.md "Client API"). Short,
// bounded ingress: authenticated customer RPCs for catalog/quote/start/status,
// service RPCs only after the caller's token is verified. Responses carry public
// metadata only; storage paths, funders and work keys never leave the server.
import { PublicError, sha256, uuid } from './http.ts';

export interface PodcastAPIDeps {
  /** Verifies the bearer token and returns an RPC bound to that customer session. */
  user(request: Request): Promise<{ accountID: string; rpc<T>(name: string, params: Record<string, unknown>): Promise<T> }>;
  service<T>(name: string, params: Record<string, unknown>): Promise<T>;
  /** One bounded Storage read of a trusted object. */
  download(bucket: string, path: string, maximum: number): Promise<Uint8Array>;
  /** The Supabase origin used for single-use member URLs. */
  origin: string;
  randomHex(bytes: number): string;
}

/** Finite customer-visible codes; anything else is service_unavailable. */
const STATUS: Record<string, number> = {
  authentication_required: 401, account_unavailable: 403, spending_suspended: 403, request_rate_limit: 429,
  podcast_unavailable: 503, podcast_release_unavailable: 404, podcast_request_unavailable: 404, podcast_request_conflict: 409,
  quote_unavailable: 404, quote_expired: 410, consent_required: 400, source_unavailable: 404, source_too_large: 413, podcast_writer_unavailable: 400,
  active_generation_limit: 429, podcast_busy: 429, podcast_daily_limit: 429, podcast_paused: 503, storage_full: 507,
  podcast_outcome_pending: 409, podcast_profile_unavailable: 400,
  insufficient_credits: 402, platform_budget_exhausted: 503, too_many_active_operations: 429,
  podcast_transfer_limit: 429, podcast_grant_unavailable: 403, podcast_grant_consumed: 409,
  invalid_podcast_request: 400, invalid_podcast_cursor: 400, invalid_podcast_grant: 400, invalid_id: 400,
};
export function podcastError(message: string): PublicError {
  const known = Object.hasOwn(STATUS, message);
  return new PublicError(known ? STATUS[message] : 503, known ? message : 'service_unavailable');
}

async function body(request: Request): Promise<Record<string, unknown>> {
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > 8192)) throw new PublicError(413, 'invalid_podcast_request');
  const text = await request.text();
  if (text.length > 8192) throw new PublicError(413, 'invalid_podcast_request');
  try {
    const value = JSON.parse(text) as unknown;
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new PublicError(400, 'invalid_podcast_request'); }
}

const json = (value: unknown, headers: Record<string, string>) => {
  const text = JSON.stringify(value);
  if (new TextEncoder().encode(text).byteLength > 4_194_304 + 65_536) throw new PublicError(503, 'service_unavailable');
  return new Response(text, { headers: { ...headers, 'Content-Type': 'application/json' } });
};

interface Transcript { format: number; speakers: unknown; disclosure: unknown; timing: unknown; chapters: unknown; segments: unknown[] }

export async function handlePodcast(request: Request, deps: PodcastAPIDeps, headers: Record<string, string>): Promise<Response> {
  const url = new URL(request.url), action = url.searchParams.get('action') ?? '';
  const reads = new Set(['catalog', 'episode', 'paper', 'status']), writes = new Set(['quote', 'start', 'cancel', 'download', 'states']);
  if (!(reads.has(action) && request.method === 'GET') && !(writes.has(action) && request.method === 'POST')) throw new PublicError(405, 'method_unavailable');
  const session = await deps.user(request);
  switch (action) {
    case 'catalog': {
      const after = url.searchParams.get('after'), limit = Number(url.searchParams.get('limit') ?? '20');
      if ((after !== null && !/^[1-9][0-9]{0,17}$/.test(after)) || !Number.isInteger(limit) || limit < 1 || limit > 50) throw new PublicError(400, 'invalid_podcast_cursor');
      return json(await session.rpc('v1_podcast_catalog', { p_after: after, p_limit: limit }), headers);
    }
    case 'paper':
      return json(await session.rpc('v1_podcast_paper', { p_item_id: uuid(url.searchParams.get('item_id')) }), headers);
    case 'status':
      return json(await session.rpc('v1_podcast_status', { p_request_id: uuid(url.searchParams.get('request_id')) }), headers);
    case 'quote': {
      const b = await body(request);
      // A length (podcast-short-v1, podcast-5min-v1, podcast-10min-v1, podcast-20min-v1); omitted means five minutes.
      if (b.profile !== undefined && b.profile !== null && (typeof b.profile !== 'string' || !/^[a-z][a-z0-9-]{2,47}$/.test(b.profile))) {
        throw new PublicError(400, 'podcast_profile_unavailable');
      }
      // The writer (owner request 2026-10-14): `anthropic` (Claude Sonnet 5.5) or `deepseek`; omitted means the policy's default.
      if (b.writer !== undefined && b.writer !== null && (typeof b.writer !== 'string' || !/^[a-z][a-z0-9_-]{1,31}$/.test(b.writer))) {
        throw new PublicError(400, 'podcast_writer_unavailable');
      }
      return json(await session.rpc('v1_podcast_quote', { p_item_id: uuid(String(b.item_id ?? '')), p_request_id: uuid(String(b.request_id ?? '')),
        ...(typeof b.profile === 'string' ? { p_profile: b.profile } : {}), ...(typeof b.writer === 'string' ? { p_writer: b.writer } : {}) }), headers);
    }
    case 'start': {
      const b = await body(request);
      if (typeof b.consent_version !== 'string' || b.consent_version.length > 40) throw new PublicError(400, 'consent_required');
      return json(await session.rpc('v1_podcast_start', { p_quote_id: uuid(String(b.quote_id ?? '')), p_request_id: uuid(String(b.request_id ?? '')),
        p_consent_version: b.consent_version }), headers);
    }
    case 'cancel': {
      const b = await body(request);
      return json(await session.rpc('v1_podcast_cancel', { p_request_id: uuid(String(b.request_id ?? '')) }), headers);
    }
    case 'states': {
      const b = await body(request);
      if (!Array.isArray(b.release_ids) || b.release_ids.length < 1 || b.release_ids.length > 100) throw new PublicError(400, 'invalid_podcast_request');
      const ids = [...new Set(b.release_ids.map(id => uuid(String(id))))];
      return json(await session.rpc('v1_podcast_states', { p_release_ids: ids }), headers);
    }
    case 'episode': {
      const releaseID = uuid(url.searchParams.get('release_id'));
      const detail = await deps.service<{ episode: Record<string, unknown>; transcript: { bucket: string; path: string; sha256: string; bytes: number } }>(
        'worker_podcast_release', { p_account_id: session.accountID, p_release_id: releaseID });
      const t = detail?.transcript;
      if (!t || t.bucket !== 'podcast-assets' || !/^(shared|private\/[0-9a-f-]{36})\/[0-9a-f]{64}\/transcript\.json$/.test(t.path)
        || !Number.isSafeInteger(t.bytes) || t.bytes < 1 || t.bytes > 4_194_304 || !/^[0-9a-f]{64}$/.test(t.sha256)) throw new PublicError(503, 'podcast_integrity_failed');
      // The transcript bytes were charged by worker_podcast_release before this read.
      const bytes = await deps.download(t.bucket, t.path, t.bytes);
      if (bytes.byteLength !== t.bytes || await sha256(bytes) !== t.sha256) throw new PublicError(503, 'podcast_integrity_failed');
      let transcript: Transcript;
      try { transcript = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as Transcript; }
      catch { throw new PublicError(503, 'podcast_integrity_failed'); }
      if (transcript?.format !== 1 || !Array.isArray(transcript.segments) || !Array.isArray(transcript.chapters)) throw new PublicError(503, 'podcast_integrity_failed');
      return json({ episode: { ...detail.episode, chapters: transcript.chapters,
        transcript: { speakers: transcript.speakers, disclosure: transcript.disclosure, timing: transcript.timing, segments: transcript.segments } } }, headers);
    }
    case 'download': {
      const b = await body(request);
      const releaseID = uuid(String(b.release_id ?? ''));
      const token = deps.randomHex(32);
      const grant = await deps.service<{ grant_id: string; expires_at: string; members: { role: string; id: string; bytes: number; sha256: string; media_type: string }[] }>(
        'worker_podcast_delivery_create', { p_account_id: session.accountID, p_release_id: releaseID,
          p_token_sha256: '\\x' + await sha256(new TextEncoder().encode(token)) });
      if (!grant || !Array.isArray(grant.members) || grant.members.length !== 1) throw new PublicError(503, 'podcast_integrity_failed');
      const origin = deps.origin.replace(/\/$/, '');
      return json({ grant: { expires_at: grant.expires_at, members: grant.members.map(m => ({ role: m.role, bytes: m.bytes, sha256: m.sha256,
        media_type: m.media_type, url: `${origin}/functions/v1/podcast-member?grant=${token}&member=${m.id}` })) } }, headers);
    }
  }
  throw new PublicError(405, 'method_unavailable');
}
