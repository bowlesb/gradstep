// Isolated podcast contract fixture. Synthetic tones only; no providers or hosted services.
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
const PORT = Number(process.env.FIXTURE_PORT || 54369);
const release = 'a0000000-0000-4000-8000-000000000001', replacement = 'a0000000-0000-4000-8000-000000000002', mineRelease = 'a0000000-0000-4000-8000-000000000003';
const document = 'd0000000-0000-4000-8000-000000000001';
const audio = Buffer.alloc(44 + 48 * 8000 * 2);
audio.write('RIFF'); audio.writeUInt32LE(audio.length - 8, 4); audio.write('WAVEfmt ', 8); audio.writeUInt32LE(16, 16);
audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22); audio.writeUInt32LE(8000, 24); audio.writeUInt32LE(16000, 28);
audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34); audio.write('data', 36); audio.writeUInt32LE(audio.length - 44, 40);
for (let i = 0; i < 48 * 8000; i++) audio.writeInt16LE(Math.round(Math.sin(i / 8000 * 2 * Math.PI * (i < 16 * 8000 ? 220 : 330)) * 300), 44 + 2 * i);
const hash = createHash('sha256').update(audio).digest('hex');
// Every length the server offers, each with its writers (podcast_lengths, migration 065), shortest first.
const writers = max => [{ writer: 'anthropic', label: 'Anthropic', max_credits: max, consent_version: 'podcast-private-v1' }, { writer: 'deepseek', label: 'DeepSeek', max_credits: Math.round(max / 3), consent_version: 'podcast-private-v1' }];
const LENGTHS = [['podcast-short-v1', 'Short', 150, 60], ['podcast-5min-v1', '5 min', 300, 150], ['podcast-10min-v1', '10 min', 600, 300], ['podcast-20min-v1', '20 min', 1200, 600]]
  .map(([profile, label, target_seconds, max_credits]) => ({ profile, label, target_seconds, max_credits, estimate: `Up to ${max_credits} credits`, writers: writers(max_credits) }));
const capabilities = () => ({ catalog: state.catalog, delivery: state.delivery, generation: state.generation, max_credits: 150, target_seconds: 300, transfer: { remaining_bytes: 100_000_000, limit_bytes: 100_000_000 },
  ...(state.lengths ? { lengths: LENGTHS } : {}) });
const episode = (id = release, scope = 'shared') => ({ release_id: id, document_id: document, scope, title: scope === 'private' ? null : 'Synthetic fixture: Direct Preference Optimization',
  state: id === release ? state.releaseState : 'ready', replacement_id: state.releaseState === 'superseded' ? replacement : null,
  fixture: true, ai_audio: true, language: 'en', authors: scope === 'private' ? [] : ['R. Rafailov', 'A. Sharma'], year: scope === 'private' ? null : 2023,
  topic: 'Alignment', duration_ms: 48_000, published_at: '2026-10-08T00:00:00Z', source: scope === 'private' ? null : {
    arxiv_id: '2305.18290', version: 3, url: 'https://arxiv.org/abs/2305.18290v3', license: 'https://creativecommons.org/licenses/by/4.0/' },
  audio: { bytes: audio.length, sha256: hash, media_type: 'audio/wav' } });
const chapters = [{ id: 'c1', title: 'The result', start_ms: 0 }, { id: 'c2', title: 'How it works', start_ms: 16_000 }, { id: 'c3', title: 'Limitations', start_ms: 32_000 }];
const transcript = { speakers: { explainer: 'Explainer', skeptic: 'Skeptical reader' }, disclosure: 'Synthetic fixture tones. No real speech or generation.', timing: 'approximate', segments: [
  { id: 's1', speaker: 'explainer', text: 'DPO avoids a separate reward model.', start_ms: 0, end_ms: 8000, chapter: 'c1', claim_type: 'paper_result', evidence: [{ id: 'e1', section: '1', quote: 'can be optimized exactly with a simple binary cross-entropy objective' }], math: [] },
  { id: 's2', speaker: 'skeptic', text: 'Does this generalize beyond the benchmarks?', start_ms: 8000, end_ms: 16_000, chapter: 'c1', claim_type: 'context', evidence: [], math: [] },
  { id: 's3', speaker: 'explainer', text: 'Compare the log-ratios.', start_ms: 16_000, end_ms: 32_000, chapter: 'c2', claim_type: 'paper_result', evidence: [], math: [{ latex: '\\beta', spoken: 'beta' }] },
  { id: 's4', speaker: 'skeptic', text: 'The paper also reports limitations.', start_ms: 32_000, end_ms: 48_000, chapter: 'c3', claim_type: 'author_interpretation', evidence: [], math: [] },
] };
let state, calls, grants, job, quoteIDs, reused;
function reset() { state = { catalog: true, delivery: true, generation: true, releaseState: 'ready', paperReady: false, corrupt: false, memberDelay: 0, episodeDelay: 0,
  loseStart: false, readyAfter: 2, statusReads: 0, quoteOutcome: 'quote', quoteError: null }; calls = []; grants = new Set(); job = null; quoteIDs = new Map(); reused = new Set(); }
reset();
// Listen's own section (migration 074): the request being made, or that couldn't be, or its ready episode.
function mine() {
  if (!job) return { episodes: [], requests: [] };
  const done = state.mineState ?? job.state, asked = { request_id: job.request_id, profile: 'podcast-5min-v1', label: '5 min', target_seconds: 300, document_id: document, title: 'My library paper title' };
  if (done === 'ready') return { episodes: [{ ...episode(mineRelease, 'private'), title: 'My library paper title', request_id: job.request_id }], requests: [] };
  if (done === 'canceled') return { episodes: [], requests: [] };
  return { episodes: [], requests: [{ ...asked, status: done === 'failed' ? 'failed' : 'making', failure: done === 'failed' ? 'quality_rejected' : null }] };
}
function jobShape(requestID, status = 'queued') { return { request_id: requestID, state: status, stage_entered_at: new Date().toISOString(), release_id: status === 'ready' ? release : null,
  held_credits: 150, charged_credits: status === 'ready' ? 43 : status === 'canceled' ? 0 : null, released_credits: status === 'ready' ? 107 : status === 'canceled' ? 150 : null, failure: null }; }
const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', 'authorization,apikey,content-type'); res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Cache-Control', 'no-store'); if (req.method === 'OPTIONS') { res.writeHead(204).end(); return; }
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const json = (value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(value)); };
  let body = ''; for await (const chunk of req) body += chunk;
  let value = {}; try { value = body ? JSON.parse(body) : {}; } catch { json({ code: 'invalid_request' }, 400); return; }
  if (url.pathname === '/health') { json({ ready: true }); return; }
  if (url.pathname === '/__reset') { reset(); json({ ok: true }); return; }
  if (url.pathname === '/__control') { Object.assign(state, value); json({ ok: true }); return; }
  if (url.pathname === '/__state') { json({ calls, state, job }); return; }
  if (req.headers.authorization !== 'Bearer fixture-access' || req.headers.apikey !== 'fixture-anon') { json({ code: 'auth_required' }, 401); return; }
  if (url.pathname === '/functions/v1/podcast-member') {
    const token = url.searchParams.get('grant'); if (!grants.delete(token)) { json({ code: 'podcast_grant_consumed' }, 409); return; }
    calls.push({ action: 'member', range: req.headers.range ?? null });
    if (state.memberDelay) await new Promise(r => setTimeout(r, state.memberDelay));
    const bytes = Buffer.from(audio); if (state.corrupt) bytes[100] ^= 1;
    res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': bytes.length, 'Accept-Ranges': 'none' }).end(bytes); return;
  }
  const action = url.searchParams.get('action'); calls.push({ action, body: value, requestID: url.searchParams.get('request_id') });
  if (action === 'catalog') { json({ episodes: state.catalog ? [episode()] : [], next: null, capabilities: capabilities(), mine: url.searchParams.get('after') ? null : mine() }); return; }
  if (action === 'paper') { json({ episode: state.paperReady ? episode(release, 'private') : null, job: state.hidePaperJob ? null : job, capabilities: capabilities() }); return; }
  if (action === 'states' && state.stateError) { json({ code: 'service_unavailable' }, 503); return; }
  if (action === 'states') { json({ states: Object.fromEntries(value.release_ids.map(id => [id, { state: id === release ? state.releaseState : 'ready', replacement_id: state.releaseState === 'superseded' ? replacement : null }])) }); return; }
  if (action === 'episode') {
    if (state.episodeError) { json({ code: 'service_unavailable' }, 503); return; }
    if (state.episodeDelay) await new Promise(r => setTimeout(r, state.episodeDelay));
    json({ episode: { ...episode(url.searchParams.get('release_id'), state.paperReady || reused.size || job?.state === 'ready' ? 'private' : 'shared'), chapters, transcript } }); return;
  }
  if (action === 'download') {
    if (!state.delivery) { json({ code: 'podcast_unavailable' }, 503); return; }
    const grant = createHash('sha256').update(randomUUID()).digest('hex'); grants.add(grant);
    json({ grant: { expires_at: new Date(Date.now() + 15 * 60_000).toISOString(), members: [{ role: 'audio', url: `http://127.0.0.1:${PORT}/functions/v1/podcast-member?grant=${grant}&member=${release}`, bytes: audio.length, sha256: hash, media_type: 'audio/wav' }] } }); return;
  }
  if (action === 'quote') {
    if (state.quoteError) { json({ code: state.quoteError }, state.quoteError === 'source_too_large' ? 413 : 409); return; }
    if (state.quoteOutcome === 'reuse') { json({ reuse: { release_id: release } }); return; }
    if (state.quoteOutcome === 'join') { job ??= jobShape(randomUUID()); json({ join: { request_id: job.request_id } }); return; }
    const id = quoteIDs.get(value.request_id) ?? randomUUID(); quoteIDs.set(value.request_id, id);
    const length = LENGTHS.find(l => l.profile === value.profile);
    if (length) { json({ quote: { id, expires_at: new Date(Date.now() + 60_000).toISOString(), max_credits: length.writers.find(w => w.writer === value.writer)?.max_credits ?? length.max_credits,
      target_seconds: length.target_seconds, label: length.label, estimate: `Estimate — you’re charged actual usage, maximum ${length.max_credits} credits`,
      providers: [value.writer === 'deepseek' ? 'DeepSeek (script)' : 'Anthropic (script)', 'Google Vertex AI (speech)'], consent_version: 'podcast-private-v1' } }); return; }
    json({ quote: { id, expires_at: new Date(Date.now() + 60_000).toISOString(), max_credits: 150, target_seconds: 300,
      estimate: 'Estimate — you’re charged actual usage, maximum 150 credits', providers: ['Anthropic (script)', 'Google Vertex AI (speech)'], consent_version: 'podcast-private-v1' } }); return;
  }
  if (action === 'start') {
    if (quoteIDs.get(value.request_id) !== value.quote_id || value.consent_version !== 'podcast-private-v1') { json({ code: 'podcast_request_conflict' }, 409); return; }
    if (state.startAdmissionDelay) await new Promise(r => setTimeout(r, state.startAdmissionDelay));
    if (state.startError) { json({ code: state.startError }, 409); return; }
    if (!state.dropStartBeforeAdmission) {
      if (state.startOutcome === 'reuse') reused.add(value.request_id);
      else job ??= jobShape(value.request_id);
    }
    if (state.startDelay) await new Promise(r => setTimeout(r, state.startDelay));
    if (state.loseStart || state.dropStartBeforeAdmission) { state.loseStart = false; json({ code: 'service_unavailable' }, 503); return; }
    json(reused.has(value.request_id) ? { reuse: { release_id: release } } : { job }); return;
  }
  if (action === 'status') {
    const id = url.searchParams.get('request_id');
    if (state.statusUnavailable) { json({ code: 'podcast_request_unavailable' }, 404); return; }
    if (reused.has(id)) { json({ reuse: { release_id: release } }); return; }
    if (!job || job.request_id !== id) { json({ code: 'podcast_request_unavailable' }, 404); return; }
    state.statusReads++; if (job.state !== 'canceled') job = jobShape(job.request_id, state.terminalState ?? (state.statusReads >= state.readyAfter ? 'ready' : 'checking'));
    json({ job }); return;
  }
  if (action === 'cancel') { job = jobShape(value.request_id, 'canceled'); json({ job }); return; }
  json({ code: 'invalid_request' }, 400);
});
server.listen(PORT, '127.0.0.1');
