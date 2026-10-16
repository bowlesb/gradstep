// Paper podcasts in the browser: contract decoding, the single-use verified audio download, device-local listening
// places and transcript helpers. No live backend calls (fetch is stubbed).
import { createHash } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Session } from '../src/lib/backend';

const ACCOUNT = '11111111-2222-4333-8444-555555555555';
const OTHER = '22222222-3333-4444-8555-666666666666';
const RELEASE = 'a0000000-0000-4000-8000-000000000001';
const DOCUMENT = 'd0000000-0000-4000-8000-000000000001';
const AUDIO = new Uint8Array(Array.from({ length: 4096 }, (_, i) => (i * 7) % 251));
const AUDIO_SHA = createHash('sha256').update(AUDIO).digest('hex');
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const episode = (extra: Record<string, unknown> = {}) => ({
  release_id: RELEASE, scope: 'shared', title: 'Synthetic fixture: Direct  Preference\nOptimization', year: 2023, authors: ['Rafael Rafailov', 7, 'Archit Sharma'],
  topic: 'Alignment', duration_ms: 48_000, language: 'en', ai_audio: true, fixture: true, document_id: DOCUMENT, published_at: '2026-10-08T00:00:00Z', state: 'ready',
  source: { arxiv_id: '2305.18290', version: 3, url: 'https://arxiv.org/abs/2305.18290v3', license: 'https://creativecommons.org/licenses/by/4.0/' },
  audio: { bytes: AUDIO.length, sha256: AUDIO_SHA, media_type: 'audio/wav' }, ...extra,
});
const detail = (extra: Record<string, unknown> = {}) => ({ episode: { ...episode(), chapters: [
  { id: 'c1', title: 'The result', start_ms: 0 }, { id: 'c2', title: 'How it works', start_ms: 16_000 }, { id: 'c3', title: 'Limitations', start_ms: 32_000 }],
transcript: { speakers: { explainer: 'Host 1 — explainer', skeptic: 'Host 2 — skeptical reader' }, disclosure: 'AI-generated audio.', timing: 'approximate', segments: [
  { id: 's1', speaker: 'explainer', text: 'DPO drops the separate reward model.', start_ms: 0, end_ms: 8000, chapter: 'c1', claim_type: 'paper_result',
    evidence: [{ id: 'e1', quote: 'can be optimized exactly with a simple binary cross-entropy objective', section: '1' }], math: [] },
  { id: 's2', speaker: 'skeptic', text: 'Does that hold beyond their benchmarks?', start_ms: 8000, end_ms: 16_000, chapter: 'c1', claim_type: 'mystery', evidence: [], math: [{ latex: '\\beta', spoken: 'beta' }] },
  { id: 's3', speaker: 'explainer', text: 'The loss compares log-ratios.', start_ms: 16_000, end_ms: 32_000, chapter: 'c2', claim_type: 'paper_result', evidence: [], math: [] },
  { id: 's4', speaker: 'skeptic', text: 'And the limitations?', start_ms: 32_000, end_ms: 48_000, chapter: 'c3', claim_type: 'author_interpretation', evidence: [], math: [] },
] }, ...extra } });

async function setup() {
  const values = new Map<string, string>();
  const session: Session = { accessToken: 'access', refreshToken: 'refresh', expiresAt: Date.now() / 1000 + 3600, lifetime: 'test', user: { id: ACCOUNT, email: 'reader@example.test' } };
  values.set('gradstep.test.session', JSON.stringify(session));
  vi.stubGlobal('localStorage', { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key), get length() { return values.size; }, key: (index: number) => [...values.keys()][index] ?? null });
  vi.stubGlobal('window', new EventTarget());
  vi.stubGlobal('navigator', { locks: { request: async (_name: string, _options: unknown, body: () => Promise<unknown>) => body() } });
  vi.stubEnv('VITE_SUPABASE_URL', 'https://fixture.invalid');
  vi.stubEnv('VITE_SUPABASE_ANON_KEY', 'fixture-anon');
  vi.stubEnv('VITE_ENVIRONMENT', 'test');
  return { podcast: await import('../src/lib/podcast'), playback: await import('../src/lib/podcast-playback'), values };
}
beforeEach(() => { vi.resetModules(); });
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe('podcast contract decoding', () => {
  it('decodes your own episodes and requests (migration 074) strictly, and says the plain words', async () => {
    const { podcast } = await setup();
    const asked = 'b0000000-0000-4000-8000-000000000001', failed = 'b0000000-0000-4000-8000-000000000002';
    const catalog = podcast.decodeCatalog({ episodes: [], mine: {
      episodes: [episode({ scope: 'private', title: 'Toward Study', request_id: asked }), episode({ release_id: OTHER })],
      requests: [{ request_id: asked, status: 'making', profile: 'podcast-10min-v1', label: '10 min', target_seconds: 600, document_id: DOCUMENT, title: 'Toward\nStudy' },
        { request_id: failed, status: 'failed', failure: 'quality_rejected', profile: 'Bad Profile', target_seconds: 9, document_id: 'x', title: null },
        { request_id: asked, status: 'making' }, { request_id: 'nope', status: 'making' }] } });
    // Only your own ready episodes (a shared one can't pose as yours), with the request that made each.
    expect(catalog.mine!.episodes.map(e => [e.title, e.requestID, e.scope])).toEqual([['Toward Study', asked, 'private']]);
    expect(catalog.mine!.requests).toEqual([
      { requestID: asked, status: 'making', profile: 'podcast-10min-v1', label: '10 min', targetSeconds: 600, documentID: DOCUMENT, title: 'Toward Study' },
      { requestID: failed, status: 'failed', profile: null, label: null, targetSeconds: 300, documentID: null, title: null }]);
    expect(JSON.stringify(catalog.mine)).not.toContain('quality_rejected');
    expect(podcast.decodeCatalog({ episodes: [] }).mine).toBeNull();
    expect(podcast.decodeCatalog({ episodes: [], mine: { episodes: 'x', requests: [] } }).mine).toBeNull();
    expect(podcast.plainProviders(['DeepSeek (script)', 'Google Vertex AI (speech)'])).toBe('DeepSeek and Google');
    expect(podcast.expectedWait(300)).toBe('Usually ready in a few minutes.');
    expect(podcast.expectedWait(600)).toBe('This length can take 10 minutes or more.');
    expect([0, 1, 2, 9].map(podcast.mineCheckDelay)).toEqual([15_000, 30_000, 60_000, 60_000]);
  });

  it('keeps ready, well-formed episodes once and cleans their text', async () => {
    const { podcast } = await setup();
    const catalog = podcast.decodeCatalog({ episodes: [episode(), episode(), episode({ release_id: 'not-a-uuid' }),
      episode({ release_id: 'a0000000-0000-4000-8000-000000000002', state: 'quarantined' }),
      episode({ release_id: 'a0000000-0000-4000-8000-000000000003', audio: { bytes: 10, sha256: 'x', media_type: 'audio/wav' } }),
      episode({ release_id: 'a0000000-0000-4000-8000-000000000004', audio: { bytes: 10, sha256: AUDIO_SHA, media_type: 'text/html' } }),
      episode({ release_id: 'a0000000-0000-4000-8000-000000000005', ai_audio: false }),
    ], next: null, capabilities: { catalog: true, generation: false, delivery: true, max_credits: 150, target_seconds: 300, transfer: { remaining_bytes: 5, limit_bytes: 10 } } });
    expect(catalog.episodes).toHaveLength(1);
    const [e] = catalog.episodes;
    expect(e).toMatchObject({ releaseID: RELEASE, title: 'Synthetic fixture: Direct Preference Optimization', authors: ['Rafael Rafailov', 'Archit Sharma'], fixture: true,
      durationMs: 48_000, topic: 'Alignment', audio: { bytes: 4096, sha256: AUDIO_SHA, mediaType: 'audio/wav' } });
    expect(catalog.capabilities).toEqual({ catalog: true, generation: false, delivery: true, maxCredits: 150, targetSeconds: 300, writers: [], transfer: { remainingBytes: 5, limitBytes: 10 } });
  });

  it('treats absent capabilities as unavailable and refuses malformed pages', async () => {
    const { podcast } = await setup();
    expect(podcast.decodeCatalog({ episodes: [] }).capabilities).toMatchObject({ catalog: false, generation: false, delivery: false, maxCredits: 150, transfer: null });
    expect(() => podcast.decodeCatalog({ episodes: 'x' })).toThrow();
    expect(() => podcast.decodeCatalog({ episodes: Array(51).fill(episode()) })).toThrow();
  });

  it('offers only https source links without credentials', async () => {
    const { podcast } = await setup();
    const source = (url: string) => podcast.decodeCatalog({ episodes: [episode({ source: { url } })] }).episodes[0].source.url;
    expect(source('javascript:alert(1)')).toBeNull();
    expect(source('http://arxiv.org/abs/1')).toBeNull();
    expect(source('https://user:pw@arxiv.org/abs/1')).toBeNull();
    expect(source('https://arxiv.org/abs/1')).toBe('https://arxiv.org/abs/1');
  });

  it('decodes chapters and transcript in order, with bounded evidence and a known claim type', async () => {
    const { podcast } = await setup();
    const d = podcast.decodeEpisodeDetail(detail());
    expect(d.chapters.map(c => c.startMs)).toEqual([0, 16_000, 32_000]);
    expect(d.transcript.segments[0].evidence[0]).toEqual({ id: 'e1', quote: 'can be optimized exactly with a simple binary cross-entropy objective', section: '1' });
    expect(d.transcript.segments[1].claimType).toBe('context');
    expect(d.transcript.speakers.skeptic).toBe('Host 2 — skeptical reader');
    const reordered = detail(); (reordered.episode.chapters as unknown[]).reverse();
    expect(() => podcast.decodeEpisodeDetail(reordered)).toThrow();
    const backwards = detail(); (backwards.episode.transcript.segments[2] as { start_ms: number }).start_ms = 1;
    expect(() => podcast.decodeEpisodeDetail(backwards)).toThrow();
    const speaker = detail(); (speaker.episode.transcript.segments[0] as { speaker: string }).speaker = 'narrator';
    expect(() => podcast.decodeEpisodeDetail(speaker)).toThrow();
  });

  it('accepts only the configured bounded podcast-member URL', async () => {
    const { podcast } = await setup();
    const good = `https://fixture.invalid/functions/v1/podcast-member?grant=${'a'.repeat(64)}&member=${RELEASE}`;
    expect(podcast.memberURL(good)).toBe(true);
    for (const bad of [good.replace('fixture.invalid', 'evil.invalid'), good.replace('podcast-member', 'reader-member'), good + '&range=0-1', good + '#x',
      good.replace('a'.repeat(64), 'a'.repeat(63)), good.replace(RELEASE, 'nope'), `https://fixture.invalid/storage/v1/object/sign/podcast-assets/x?token=1`]) {
      expect(podcast.memberURL(bad), bad).toBe(false);
    }
  });

  it('maps unknown release states to unavailable', async () => {
    const { podcast } = await setup();
    const states = podcast.decodeStates({ states: { [RELEASE]: { state: 'withdrawn', replacement_id: null } } }, [RELEASE, 'a0000000-0000-4000-8000-000000000009']);
    expect(states.get(RELEASE)).toEqual({ state: 'withdrawn', replacementID: null });
    expect(states.get('a0000000-0000-4000-8000-000000000009')).toEqual({ state: 'unavailable', replacementID: null });
  });
});

describe('verified audio download', () => {
  const member = `https://fixture.invalid/functions/v1/podcast-member?grant=${'b'.repeat(64)}&member=${DOCUMENT}`;
  const grant = (extra: Record<string, unknown> = {}) => json({ grant: { expires_at: '2026-10-08T00:15:00Z', members: [{ role: 'audio', url: member, bytes: AUDIO.length, sha256: AUDIO_SHA, media_type: 'audio/wav', ...extra }] } });

  it('redeems the grant once with the account token, no Range, and verifies length and SHA-256', async () => {
    const { podcast } = await setup();
    const requests: { url: string; headers: Record<string, string>; method: string }[] = [];
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit) => {
      requests.push({ url, headers: init.headers as Record<string, string>, method: init.method ?? 'GET' });
      return url.includes('action=download') ? grant() : new Response(AUDIO, { status: 200, headers: { 'Content-Type': 'audio/wav' } });
    }));
    const e = podcast.decodeCatalog({ episodes: [episode()] }).episodes[0];
    const blob = await podcast.downloadEpisodeAudio(ACCOUNT, e);
    expect(blob.size).toBe(AUDIO.length);
    expect(blob.type).toBe('audio/wav');
    expect(requests.map(r => [r.method, new URL(r.url).pathname])).toEqual([['POST', '/functions/v1/podcast'], ['GET', '/functions/v1/podcast-member']]);
    expect(requests[1].headers.Authorization).toBe('Bearer access');
    expect(Object.keys(requests[1].headers).map(k => k.toLowerCase())).not.toContain('range');
  });

  it('refuses tampered bytes, a mismatched grant and a foreign member URL without playing anything', async () => {
    const { podcast } = await setup();
    const e = podcast.decodeCatalog({ episodes: [episode()] }).episodes[0];
    const tampered = AUDIO.slice(); tampered[10] ^= 1;
    vi.stubGlobal('fetch', vi.fn(async (url: string) => url.includes('action=download') ? grant() : new Response(tampered)));
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, e)).rejects.toMatchObject({ code: 'podcast_integrity_failed' });
    vi.stubGlobal('fetch', vi.fn(async (url: string) => url.includes('action=download') ? grant() : new Response(AUDIO.slice(0, 100))));
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, e)).rejects.toMatchObject({ code: 'podcast_integrity_failed' });
    const fetcher = vi.fn(async () => grant({ sha256: 'c'.repeat(64) }));
    vi.stubGlobal('fetch', fetcher);
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, e)).rejects.toMatchObject({ code: 'podcast_integrity_failed' });
    expect(fetcher).toHaveBeenCalledTimes(1);
    vi.stubGlobal('fetch', vi.fn(async () => grant({ url: 'https://evil.invalid/functions/v1/podcast-member?grant=' + 'b'.repeat(64) + '&member=' + DOCUMENT })));
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, e)).rejects.toMatchObject({ code: 'podcast_integrity_failed' });
  });

  it('surfaces finite podcast codes and never free text', async () => {
    const { podcast } = await setup();
    const e = podcast.decodeCatalog({ episodes: [episode()] }).episodes[0];
    vi.stubGlobal('fetch', vi.fn(async () => json({ code: 'podcast_transfer_limit' }, 429)));
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, e)).rejects.toMatchObject({ code: 'podcast_transfer_limit' });
    vi.stubGlobal('fetch', vi.fn(async () => json({ code: 'Error: something <b>bad</b>' }, 500)));
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, e)).rejects.toMatchObject({ code: 'request_failed' });
  });
});

describe('device-local listening places', () => {
  const at = (positionMs: number, session: string, sessionStartedAt: number, sequence: number, extra = {}) =>
    ({ positionMs, durationMs: 48_000, completed: false, session, sessionStartedAt, sequence, savedAt: sessionStartedAt + sequence, ...extra });
  const S1 = 'f0000000-0000-4000-8000-000000000001', S2 = 'f0000000-0000-4000-8000-000000000002';

  it('respects a backwards seek within a session (not the largest position)', async () => {
    const { playback } = await setup();
    expect(playback.savePosition(ACCOUNT, RELEASE, at(30_000, S1, 1000, 1))).toBe(true);
    expect(playback.savePosition(ACCOUNT, RELEASE, at(5_000, S1, 1000, 2))).toBe(true);
    expect(playback.loadPosition(ACCOUNT, RELEASE)?.positionMs).toBe(5_000);
    expect(playback.savePosition(ACCOUNT, RELEASE, at(40_000, S1, 1000, 2))).toBe(false); // duplicate sequence keeps the stored one
  });

  it('a later play session wins over a stale tab or offline device, whatever the positions', async () => {
    const { playback } = await setup();
    playback.savePosition(ACCOUNT, RELEASE, at(10_000, S2, 2000, 1));
    expect(playback.savePosition(ACCOUNT, RELEASE, at(45_000, S1, 1000, 9))).toBe(false);
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toMatchObject({ positionMs: 10_000, session: S2 });
    // Equal starts: the session ID breaks the tie deterministically.
    expect(playback.newer(at(1, S2, 3000, 1), at(1, S1, 3000, 1))).toBe(true);
    expect(playback.newer(at(1, S1, 3000, 1), at(1, S2, 3000, 1))).toBe(false);
  });

  it('is per account, bounded, cleared at sign-out and tolerant of unavailable storage', async () => {
    const { playback, values } = await setup();
    playback.savePosition(ACCOUNT, RELEASE, at(1000, S1, 1, 1));
    expect(playback.loadPosition(OTHER, RELEASE)).toBeNull();
    for (let i = 0; i < playback.MAX_POSITIONS + 5; i++) {
      playback.savePosition(ACCOUNT, `b0000000-0000-4000-8000-${String(i).padStart(12, '0')}`, at(1000, S1, 10 + i, 1));
    }
    const keys = [...values.keys()].filter(k => k.startsWith(playback.positionsKey(ACCOUNT)));
    expect(keys).toHaveLength(playback.MAX_POSITIONS);
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toBeNull(); // the least recently saved went first
    playback.clearPositions(ACCOUNT);
    expect([...values.keys()].some(k => k.startsWith(playback.positionsKey(ACCOUNT)))).toBe(false);
    vi.stubGlobal('localStorage', { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); }, removeItem: () => { throw new Error('blocked'); } });
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toBeNull();
    expect(playback.savePosition(ACCOUNT, RELEASE, at(1000, S1, 1, 1))).toBe(false);
    expect(() => playback.clearPositions(ACCOUNT)).not.toThrow();
    values.set(playback.positionsKey(OTHER), '{"version":1,"positions":{"x":1}}');
  });

  it('restarts completed or nearly finished episodes', async () => {
    const { playback } = await setup();
    expect(playback.resumeAt(null, 48_000)).toBe(0);
    expect(playback.resumeAt(at(20_000, S1, 1, 1), 48_000)).toBe(20_000);
    expect(playback.resumeAt(at(44_000, S1, 1, 1), 48_000)).toBe(0);
    expect(playback.resumeAt(at(20_000, S1, 1, 1, { completed: true }), 48_000)).toBe(0);
  });
});

describe('transcript helpers', () => {
  it('finds the playing segment and chapter, formats times and builds a text-only passage anchor', async () => {
    const { podcast, playback } = await setup();
    const d = podcast.decodeEpisodeDetail(detail());
    expect(playback.segmentAt(d.transcript.segments, 0)?.id).toBe('s1');
    expect(playback.segmentAt(d.transcript.segments, 15_999)?.id).toBe('s2');
    expect(playback.segmentAt(d.transcript.segments, 99_000)?.id).toBe('s4');
    expect(playback.segmentAt([], 10)).toBeNull();
    expect(playback.chapterAt(d.chapters, 31_000)?.title).toBe('How it works');
    expect(playback.clock(0)).toBe('0:00');
    expect(playback.clock(301_400)).toBe('5:01');
    expect(playback.clock(3_725_000)).toBe('1:02:05');
    expect(playback.durationLabel(48_000)).toBe('48 s');
    expect(playback.durationLabel(301_000)).toBe('5 min');
    expect(playback.positionText(61_000, 300_000)).toBe('1:01 of 5:00');
    expect(playback.evidenceAnchor(d.transcript.segments[0].evidence[0])).toEqual({ artifactID: '', quote: 'can be optimized exactly with a simple binary cross-entropy objective', prefix: '', suffix: '' });
  });
});

describe('current server contract and private generation', () => {
  const requestID = 'c0000000-0000-4000-8000-000000000001';
  const quote = () => ({ id: 'c0000000-0000-4000-8000-000000000002', expires_at: new Date(Date.now() + 60_000).toISOString(),
    max_credits: 150, estimate: 'Estimate — actual usage, maximum 150 credits', providers: ['Anthropic (script)', 'Google Vertex AI (speech)'],
    consent_version: 'podcast-private-v1', target_seconds: 300 });
  const job = (extra = {}) => ({ request_id: requestID, state: 'queued', stage_entered_at: new Date().toISOString(), release_id: null,
    held_credits: 150, charged_credits: null, released_credits: null, failure: null, ...extra });

  it('accepts private metadata with no server title and fails closed on future release states', async () => {
    const { podcast } = await setup();
    expect(podcast.decodePaper({ episode: episode({ scope: 'private', title: null, source: null, authors: [], year: null }), job: null,
      capabilities: {} }).episode).toMatchObject({ title: 'Private paper episode', scope: 'private', source: { url: null } });
    expect(podcast.decodeCatalog({ episodes: [episode({ state: 'new_future_state' }), episode({ state: undefined })] }).episodes).toEqual([]);
    expect(podcast.decodeCatalog({ episodes: [episode({ scope: 'private', title: null })] }).episodes).toEqual([]);
  });
  it('requires chapter zero, unique chapter/segment IDs and valid segment chapter references', async () => {
    const { podcast } = await setup();
    const noZero = detail(); noZero.episode.chapters[0].start_ms = 1;
    const duplicate = detail(); duplicate.episode.chapters[1].id = 'c1';
    const missing = detail(); missing.episode.transcript.segments[0].chapter = 'missing';
    const duplicateSegment = detail(); duplicateSegment.episode.transcript.segments[1].id = 's1';
    for (const value of [noZero, duplicate, missing, duplicateSegment]) expect(() => podcast.decodeEpisodeDetail(value)).toThrow();
  });
  it('requires the displayed v1 credit cap, provider identities and consent, and one quote outcome', async () => {
    const { podcast } = await setup();
    expect(podcast.decodeQuote({ quote: quote() })).toMatchObject({ kind: 'quote', quote: { maxCredits: 150, consentVersion: 'podcast-private-v1' } });
    // A version-2 quote (DeepSeek writes the script, 2026-10-14) names its provider and consent version; the reader confirms those.
    expect(podcast.decodeQuote({ quote: { ...quote(), max_credits: 200, providers: ['DeepSeek (script)', 'Google Vertex AI (speech)'], consent_version: 'podcast-private-v2' } }))
      .toMatchObject({ kind: 'quote', quote: { maxCredits: 200, providers: ['DeepSeek (script)', 'Google Vertex AI (speech)'], consentVersion: 'podcast-private-v2' } });
    for (const bad of [{ consent_version: 'podcast-private-v9' }, { providers: [] }, { providers: ['<script>'] }, { max_credits: 0 }, { max_credits: 2001 }]) {
      expect(() => podcast.decodeQuote({ quote: { ...quote(), ...bad } })).toThrow();
    }
    expect(podcast.decodeQuote({ reuse: { release_id: RELEASE } })).toEqual({ kind: 'reuse', releaseID: RELEASE });
    expect(podcast.decodeQuote({ join: { request_id: requestID } })).toEqual({ kind: 'join', requestID });
    // Other maxima and lengths are the server's to set (profiles change); unknown consent, a bad date or a malformed label still refuse.
    for (const patch of [{ max_credits: 'many' }, { consent_version: 'v2' }, { expires_at: 'later' }, { providers: 'other' }, { target_seconds: -1 }]) {
      expect(() => podcast.decodeQuote({ quote: { ...quote(), ...patch } })).toThrow();
    }
    expect(() => podcast.decodeQuote({ quote: quote(), reuse: { release_id: RELEASE } })).toThrow();
  });
  it('preserves the quote request ID through start retries and checks every returned job owner', async () => {
    const { podcast } = await setup();
    const calls: { action: string | null; body: unknown }[] = [];
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit) => {
      const action = new URL(url).searchParams.get('action'); calls.push({ action, body: init.body ? JSON.parse(String(init.body)) : null });
      return json(action === 'quote' ? { quote: quote() } : { job: job() });
    }));
    const result = await podcast.podcastQuote(ACCOUNT, DOCUMENT, requestID);
    expect(result.kind).toBe('quote'); if (result.kind !== 'quote') return;
    await podcast.podcastStart(ACCOUNT, result.quote, requestID);
    await podcast.podcastStart(ACCOUNT, result.quote, requestID);
    expect(calls).toHaveLength(3);
    expect(calls[0].body).toEqual({ item_id: DOCUMENT, request_id: requestID });
    expect(calls[1].body).toEqual({ quote_id: result.quote.id, request_id: requestID, consent_version: 'podcast-private-v1' });
    expect(calls[2]).toEqual(calls[1]);
    vi.stubGlobal('fetch', vi.fn(async () => json({ job: job({ request_id: DOCUMENT }) })));
    await expect(podcast.podcastStatus(ACCOUNT, requestID)).rejects.toMatchObject({ code: 'invalid_response' });
  });
  it('accepts late start/status reuse while refusing ambiguous, malformed or wrong-request outcomes', async () => {
    const { podcast } = await setup();
    const result = podcast.decodeQuote({ quote: quote() }); if (result.kind !== 'quote') throw new Error('fixture');
    const fetcher = vi.fn(async () => json({ reuse: { release_id: RELEASE } })); vi.stubGlobal('fetch', fetcher);
    expect(await podcast.podcastStart(ACCOUNT, result.quote, requestID)).toEqual({ kind: 'reuse', releaseID: RELEASE });
    expect(await podcast.podcastStatus(ACCOUNT, requestID)).toEqual({ kind: 'reuse', releaseID: RELEASE });
    expect(fetcher).toHaveBeenCalledTimes(2); // no hidden paid retry, lookup or download
    for (const value of [{ job: job(), reuse: { release_id: RELEASE } }, { reuse: { release_id: 'bad' } }, {}, { job: job({ request_id: DOCUMENT }) }]) {
      expect(() => podcast.decodeRequestResult(value, requestID)).toThrow();
    }
    // Cancel is a job-only operation in the actual server contract.
    await expect(podcast.podcastCancel(ACCOUNT, requestID)).rejects.toMatchObject({ code: 'invalid_response' });
  });
  it('does not infer completion, uses bounded status cadence and treats unknown-provider outcome as terminal', async () => {
    const { podcast } = await setup();
    expect(podcast.statusPollDelay(59_999)).toBe(5_000); expect(podcast.statusPollDelay(60_000)).toBe(15_000);
    expect(podcast.revocationPollDelay(false)).toBe(60_000); expect(podcast.revocationPollDelay(true)).toBe(300_000);
    expect(podcast.jobTerminal(podcast.decodeJob(job({ state: 'capacity_wait' })))).toBe(false);
    expect(podcast.jobTerminal(podcast.decodeJob(job({ state: 'unknown_provider', charged_credits: 0, released_credits: 150 })))).toBe(true);
    expect(() => podcast.decodeJob(job({ state: 'ready' }))).toThrow();
    expect(() => podcast.decodeJob(job({ state: 'magic' }))).toThrow();
    expect(() => podcast.decodeJob(job({ charged_credits: 2001 }))).toThrow();
  });
  it('keeps error text finite for quote limits and credit failures', async () => {
    const { podcast } = await setup();
    for (const code of ['quote_expired', 'insufficient_credits', 'active_generation_limit', 'podcast_paused']) {
      vi.stubGlobal('fetch', vi.fn(async () => json({ code }, 429)));
      await expect(podcast.podcastQuote(ACCOUNT, DOCUMENT, requestID)).rejects.toMatchObject({ code });
    }
    vi.stubGlobal('fetch', vi.fn(async () => json({ code: 'podcast_arbitrary_provider_secret' }, 500)));
    await expect(podcast.podcastQuote(ACCOUNT, DOCUMENT, requestID)).rejects.toMatchObject({ code: 'request_failed' });
  });
});

describe('position ownership under concurrent tabs', () => {
  const S1 = 'f0000000-0000-4000-8000-000000000001', S2 = 'f0000000-0000-4000-8000-000000000002';
  const position = (session: string, start: number, sequence: number, positionMs = 1000) =>
    ({ session, sessionStartedAt: start, sequence, positionMs, durationMs: 48_000, completed: false, savedAt: start + sequence });
  it('interleaved saves for distinct episodes cannot discard one another', async () => {
    const { playback, values } = await setup();
    const second = 'a0000000-0000-4000-8000-000000000002'; let nested = false;
    vi.spyOn(localStorage, 'setItem').mockImplementation((key, value) => {
      if (!nested) { nested = true; playback.savePosition(ACCOUNT, second, position(S2, 2000, 1)); }
      values.set(key, value);
    });
    playback.savePosition(ACCOUNT, RELEASE, position(S1, 1000, 1));
    expect(playback.loadPosition(ACCOUNT, RELEASE)?.session).toBe(S1);
    expect(playback.loadPosition(ACCOUNT, second)?.session).toBe(S2);
  });
  it('a newer same-episode session wins even when the old tab finishes its write last', async () => {
    const { playback, values } = await setup(); let nested = false;
    vi.spyOn(localStorage, 'setItem').mockImplementation((key, value) => {
      if (!nested) { nested = true; playback.savePosition(ACCOUNT, RELEASE, position(S2, 2000, 1, 5000)); }
      values.set(key, value);
    });
    expect(playback.savePosition(ACCOUNT, RELEASE, position(S1, 1000, 9, 40_000))).toBe(false);
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toMatchObject({ session: S2, positionMs: 5000 });
  });
  it('revocation tombstones reject stale tab saves and exact duplicate tombstones win', async () => {
    const { playback } = await setup();
    playback.savePosition(ACCOUNT, RELEASE, position(S1, 1000, 1)); playback.removePosition(ACCOUNT, RELEASE);
    expect(playback.savePosition(ACCOUNT, RELEASE, position(S1, 1000, 2))).toBe(false);
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toBeNull();
    expect(playback.newer({ ...position(S1, 1000, 1), removed: true }, position(S1, 1000, 1))).toBe(true);
  });
  it('old login cleanup never deletes a newer same-account lifetime', async () => {
    const { playback } = await setup();
    playback.savePosition(ACCOUNT, RELEASE, position(S1, 1000, 1), 'old-login');
    playback.savePosition(ACCOUNT, RELEASE, position(S2, 2000, 1), 'new-login');
    playback.clearPositions(ACCOUNT, 'old-login');
    expect(playback.loadPosition(ACCOUNT, RELEASE, 'old-login')).toBeNull();
    expect(playback.loadPosition(ACCOUNT, RELEASE, 'new-login')?.session).toBe(S2);
  });
});

describe('audio cancellation and account fences', () => {
  const grant = () => json({ grant: { expires_at: new Date(Date.now() + 60_000).toISOString(), members: [{ role: 'audio',
    url: `https://fixture.invalid/functions/v1/podcast-member?grant=${'b'.repeat(64)}&member=${DOCUMENT}`, bytes: AUDIO.length, sha256: AUDIO_SHA, media_type: 'audio/wav' }] } });
  it('cancellation during the member prevents a Blob, and retry asks for a new single-use grant', async () => {
    const { podcast } = await setup(); const c = new AbortController(); let grants = 0, members = 0;
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      if (url.includes('action=download')) { grants++; return grant(); }
      members++; if (members === 1) c.abort(); return new Response(AUDIO);
    }));
    const episode = podcast.decodeCatalog({ episodes: [globalEpisode()] }).episodes[0];
    await expect(podcast.downloadEpisodeAudio(ACCOUNT, episode, c.signal)).rejects.toThrow();
    expect((await podcast.downloadEpisodeAudio(ACCOUNT, episode)).size).toBe(AUDIO.length);
    expect([grants, members]).toEqual([2, 2]);
  });
  it('same-account logout/login during hashing rejects audio from the old lifetime', async () => {
    const { podcast, values } = await setup(); const backend = await import('../src/lib/backend');
    let releaseHash!: () => void; const hashing = new Promise<void>(resolve => { releaseHash = resolve; });
    const realDigest = crypto.subtle.digest.bind(crypto.subtle);
    vi.spyOn(crypto.subtle, 'digest').mockImplementation(async (...args) => { await hashing; return realDigest(...args); });
    vi.stubGlobal('fetch', vi.fn(async (url: string) => url.includes('action=download') ? grant() : new Response(AUDIO)));
    const episode = podcast.decodeCatalog({ episodes: [globalEpisode()] }).episodes[0];
    const result = podcast.downloadEpisodeAudio(ACCOUNT, episode);
    await vi.waitFor(() => expect(crypto.subtle.digest).toHaveBeenCalled());
    const next = { ...backend.auth.session()!, lifetime: 'new-login' };
    values.set('gradstep.test.session', JSON.stringify(next));
    const event = new Event('storage'); Object.assign(event, { key: 'gradstep.test.session', newValue: JSON.stringify(next) }); window.dispatchEvent(event);
    releaseHash(); await expect(result).rejects.toThrow();
  });
  it('requires an audio grant with the same MIME identity, no duplicate or hidden query parameters', async () => {
    const { podcast } = await setup(); const e = podcast.decodeCatalog({ episodes: [globalEpisode()] }).episodes[0];
    const raw = await grant().json(); raw.grant.members[0].media_type = 'audio/mp4';
    expect(() => podcast.decodeGrant(raw, e)).toThrow();
    expect(podcast.memberURL(`https://fixture.invalid/functions/v1/podcast-member?grant=${'b'.repeat(64)}&grant=${'b'.repeat(64)}`)).toBe(false);
  });
});
const globalEpisode = episode;

describe('deployment-scoped positions', () => {
  it('identical account, lifetime and environment labels on different backends never share or clear positions', async () => {
    const { playback } = await setup(); const { config } = await import('../src/lib/backend');
    const saved = { positionMs: 1000, durationMs: 48_000, completed: false, session: 'f0000000-0000-4000-8000-000000000001', sessionStartedAt: 1000, sequence: 1, savedAt: 1001 };
    playback.savePosition(ACCOUNT, RELEASE, saved); const firstKey = playback.positionsKey(ACCOUNT);
    config.url = 'https://different-deployment.invalid';
    expect(playback.positionsKey(ACCOUNT)).not.toBe(firstKey); expect(playback.loadPosition(ACCOUNT, RELEASE)).toBeNull();
    playback.clearPositions(ACCOUNT); config.url = 'https://fixture.invalid';
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toEqual(saved);
  });
  it('documents the bounded tombstone limit: eviction can forget a place, never authorize playback', async () => {
    const { playback } = await setup(); playback.removePosition(ACCOUNT, RELEASE);
    for (let i = 0; i < playback.MAX_POSITIONS; i++) playback.savePosition(ACCOUNT, `b0000000-0000-4000-8000-${String(i).padStart(12, '0')}`, {
      positionMs: 1000, durationMs: 48_000, completed: false, session: 'f0000000-0000-4000-8000-000000000001', sessionStartedAt: Date.now() + 100 + i, sequence: 1, savedAt: Date.now() + 100 + i,
    });
    // This disposable local ledger can forget a revoked episode under its explicit 200-entry bound.
    expect(playback.loadPosition(ACCOUNT, RELEASE)).toBeNull();
    expect(playback.savePosition(ACCOUNT, RELEASE, { positionMs: 1000, durationMs: 48_000, completed: false,
      session: 'f0000000-0000-4000-8000-000000000001', sessionStartedAt: 1000, sequence: 2, savedAt: Date.now() + 1000 })).toBe(true);
  });
});

describe('podcast lengths', () => {
  it('decodes every offered length with its writers, shortest first as listed; bad rows are dropped', async () => {
    const { decodeCapabilities, aboutMinutes } = await import('../src/lib/podcast');
    const writer = (writer: string, max: number) => ({ writer, label: writer === 'deepseek' ? 'DeepSeek' : 'Anthropic', max_credits: max });
    const capabilities = decodeCapabilities({ catalog: true, generation: true, delivery: true, max_credits: 150, target_seconds: 300, lengths: [
      { profile: 'podcast-short-v1', label: 'Short', target_seconds: 150, max_credits: 60, writers: [writer('anthropic', 60), writer('deepseek', 20)] },
      { profile: 'podcast-5min-v1', label: '5 min', target_seconds: 300, max_credits: 150, writers: [writer('anthropic', 150), writer('deepseek', 50)] },
      { profile: 'podcast-5min-v1', label: 'duplicate', target_seconds: 300, max_credits: 150 },
      { profile: 'Bad Profile', label: 'x', target_seconds: 300, max_credits: 1 }, { profile: 'podcast-10s-v1', label: '10 s', target_seconds: 10, max_credits: 1 },
      { profile: 'podcast-20min-v1', label: '20 min', target_seconds: 1200, max_credits: 600 },
    ] });
    expect(capabilities.lengths!.map(l => l.label)).toEqual(['Short', '5 min', '20 min']);
    expect(capabilities.lengths![1].writers).toEqual([{ writer: 'anthropic', label: 'Anthropic', maxCredits: 150 }, { writer: 'deepseek', label: 'DeepSeek', maxCredits: 50 }]);
    expect(capabilities.writers).toEqual(capabilities.lengths![1].writers); // the default length's list, as before
    expect(capabilities.lengths![2].writers).toEqual([]);
    expect(aboutMinutes(150)).toBe('About 2½ minutes'); expect(aboutMinutes(60)).toBe('About 1 minute'); expect(aboutMinutes(600)).toBe('About 10 minutes'); expect(aboutMinutes(30)).toBe('Under a minute');
  });
});
