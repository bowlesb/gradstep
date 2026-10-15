#!/usr/bin/env node
// Paid, explicit live check of a private episode made from the paper's own text on the device (migration 066,
// docs/architecture/PAPER_PODCASTS.md "Episodes from the paper on this device"): one disposable account with synthetic
// credits, the DPO v3 text as a device would send it (the browser's own context builder), the `source` upload, a quote
// naming it by digest, a Start, status polling until the episode is ready, the paper lookup by membership id and the
// transcript's evidence. Prints states, credits and counts; never a token, key or password. Deletes the account at the
// end through account-delete, as a reader would. About $0.20 of provider spend per run (the Short length, DeepSeek).
//
//   node scripts/podcast-device-smoke.mjs [--profile=podcast-short-v1] [--writer=deepseek] [--index=<reader.json>]
import { existsSync, readFileSync } from 'node:fs';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'coxhjvqpflgxkleydati';
const arg = (name, fallback) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const PROFILE = arg('profile', 'podcast-short-v1'), WRITER = arg('writer', 'deepseek');
const INDEX = arg('index', `${ROOT}/.artifacts/bundles/ecbc0a04588f/reader.json`);
const dotenv = path => Object.fromEntries(readFileSync(path, 'utf8').split('\n').filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const env = dotenv(`${ROOT}/.env.staging`);
if (!env.SUPABASE_URL?.startsWith(`https://${PROJECT_REF}.`) || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) { console.error('staging env missing'); process.exit(2); }
const secrets = new Set(Object.values(env).filter(v => typeof v === 'string' && v.length >= 8));
const redact = s => { let o = String(s); for (const x of secrets) o = o.split(x).join('[redacted]'); return o.replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[jwt]'); };
const log = (...p) => console.log(redact(`${new Date().toISOString().slice(11, 19)} ${p.join(' ')}`));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const service = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
async function http(url, { method = 'GET', headers = {}, body, timeoutMs = 60_000 } = {}) {
  const r = await fetch(url, { method, headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
  const text = await r.text(); let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: r.status, json, text };
}
async function rpc(name, params, token) {
  const r = await http(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, { method: 'POST', body: params ?? {},
    headers: token === 'service' ? service : { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } });
  if (r.status >= 300) throw new Error(`${name}: HTTP ${r.status} ${r.json?.message ?? r.json?.code ?? ''}`.trim());
  return r.json;
}
const podcast = (token, action, body, method = body === undefined ? 'GET' : 'POST') => http(`${env.SUPABASE_URL}/functions/v1/podcast?${action}`,
  { method, body, headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } });

// 1. The paper's own text, as a device sends it.
const { buildPaperContext } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
if (!existsSync(INDEX)) { console.error(`no reader index at ${INDEX}`); process.exit(2); }
const index = JSON.parse(readFileSync(INDEX, 'utf8'));
const text = buildPaperContext(index);
const manifest_sha256 = createHash('sha256').update(readFileSync(INDEX)).digest('hex');
const membership = randomUUID();
log(`device text: ${index.blocks.length} blocks, ${Buffer.byteLength(text)} bytes; membership ${membership}`);

// 2. Disposable account with synthetic credits.
const email = `gradstep-smoke-podcast-device-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
secrets.add(password);
const created = await http(`${env.SUPABASE_URL}/auth/v1/admin/users`, { method: 'POST', headers: service, body: { email, password, email_confirm: true } });
if (created.status >= 300 || !created.json?.id) throw new Error(`create account: HTTP ${created.status}`);
const accountID = created.json.id;
log(`account ${accountID} created`);
let token = null, exitCode = 1;
try {
  await rpc('worker_grant_credits', { p_account_id: accountID, p_source: 'adjustment', p_external_key: `operator:podcast-device-smoke:${accountID}`,
    p_credits: 600, p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Device-source podcast live smoke synthetic grant' }, 'service');
  const signin = await http(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: { email, password } });
  if (signin.status !== 200 || !signin.json?.access_token) throw new Error(`sign-in: HTTP ${signin.status}`);
  token = signin.json.access_token; secrets.add(token);

  // 3. Store the text, quote by digest, start.
  const stored = await podcast(token, 'action=source', { format: 'paper-context-v2', text });
  if (stored.status !== 200) throw new Error(`source: HTTP ${stored.status} ${stored.json?.code ?? ''}`);
  log(`source stored: ${stored.json.source.bytes} bytes, digest ${stored.json.source.text_sha256.slice(0, 12)}…`);
  const again = await podcast(token, 'action=source', { format: 'paper-context-v2', text });
  if (again.json?.source?.text_sha256 !== stored.json.source.text_sha256) throw new Error('a second upload of the same text must be the same digest');
  const device_source = { source: 'arxiv', source_id: '2305.18290', revision: 3, manifest_sha256, text_sha256: stored.json.source.text_sha256,
    title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', authors: ['Rafael Rafailov', 'Archit Sharma', 'Eric Mitchell', 'Stefano Ermon', 'Christopher D. Manning', 'Chelsea Finn'] };
  const before = await podcast(token, `action=paper&item_id=${membership}`);
  log(`paper lookup before: HTTP ${before.status}, episodes ${before.json?.episodes?.length ?? '?'}, job ${before.json?.job ? before.json.job.state : 'none'}, generation ${before.json?.capabilities?.generation}`);
  const requestID = randomUUID();
  const quoted = await podcast(token, 'action=quote', { item_id: membership, request_id: requestID, profile: PROFILE, writer: WRITER, device_source });
  if (quoted.status !== 200 || !quoted.json?.quote) throw new Error(`quote: HTTP ${quoted.status} ${quoted.json?.code ?? JSON.stringify(quoted.json).slice(0, 200)}`);
  const quote = quoted.json.quote;
  log(`quote ${quote.id.slice(0, 8)}: ${quote.label}, max ${quote.max_credits} credits, writer ${quote.writer_label}, providers ${JSON.stringify(quote.providers)}, consent ${quote.consent_version}`);
  const started = await podcast(token, 'action=start', { quote_id: quote.id, request_id: requestID, consent_version: quote.consent_version });
  if (started.status !== 200 || !started.json?.job) throw new Error(`start: HTTP ${started.status} ${started.json?.code ?? JSON.stringify(started.json).slice(0, 200)}`);
  let job = started.json.job;
  log(`job started: ${job.state}, held ${job.held_credits} credits`);

  // 4. Poll until the episode is ready (or the job ends).
  const startedAt = Date.now(); let last = job.state;
  while (!['ready', 'canceled', 'failed', 'unknown_provider', 'quarantined'].includes(job.state)) {
    if (Date.now() - startedAt > 20 * 60_000) throw new Error('timeout waiting for the episode');
    await sleep(10_000);
    const status = await podcast(token, `action=status&request_id=${requestID}`);
    if (status.status !== 200) { log(`status: HTTP ${status.status} ${status.json?.code ?? ''}`); continue; }
    if (status.json.reuse) { log(`reuse ${status.json.reuse.release_id}`); job = { state: 'ready', release_id: status.json.reuse.release_id }; break; }
    job = status.json.job;
    if (job.state !== last) { log(`job ${job.state}${job.failure ? ` (${job.failure})` : ''}, ${Math.round((Date.now() - startedAt) / 1000)} s`); last = job.state; }
  }
  if (job.state !== 'ready') throw new Error(`job ended ${job.state}: ${job.failure ?? ''}`);
  log(`ready after ${Math.round((Date.now() - startedAt) / 1000)} s; charged ${job.charged_credits} credits, released ${job.released_credits}`);

  // 5. The paper lookup by membership id and the transcript.
  const after = await podcast(token, `action=paper&item_id=${membership}`);
  const episode = after.json?.episode;
  if (!episode || episode.document_id !== membership) throw new Error(`paper lookup after: ${JSON.stringify(after.json).slice(0, 300)}`);
  log(`paper lookup after: episode ${episode.release_id.slice(0, 8)} ${episode.state}, ${Math.round(episode.duration_ms / 1000)} s, document_id = membership, source ${JSON.stringify(episode.source)}`);
  const full = await podcast(token, `action=episode&release_id=${episode.release_id}`);
  const transcript = full.json?.episode?.transcript;
  if (!transcript) throw new Error(`episode: HTTP ${full.status}`);
  const segments = transcript.segments ?? [], evidence = segments.flatMap(s => s.evidence ?? []);
  const markers = evidence.filter(e => /^\s*¶/.test(e.quote ?? ''));
  log(`transcript: ${transcript.chapters?.length ?? 0} chapters, ${segments.length} segments, ${evidence.length} evidence quotes, ${markers.length} starting with a paragraph marker`);
  log(`opening: ${JSON.stringify(segments[0]?.text?.slice(0, 160) ?? '')}`);
  if (markers.length) throw new Error('an evidence quote carries a paragraph marker');
  exitCode = 0;
} catch (error) {
  log(`FAILED: ${error.message}`);
} finally {
  // 6. Cleanup through account-delete, then confirm the auth user is gone.
  let deleted = null;
  if (token) deleted = await http(`${env.SUPABASE_URL}/functions/v1/account-delete`, { method: 'POST', body: { confirm: 'delete my account' },
    headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } }).catch(() => null);
  if (!deleted || deleted.status !== 200) {
    log(`account-delete ${deleted?.status ?? 'skipped'}; removing the auth user with the service role`);
    await http(`${env.SUPABASE_URL}/auth/v1/admin/users/${accountID}`, { method: 'DELETE', headers: service }).catch(() => null);
  }
  const gone = await http(`${env.SUPABASE_URL}/auth/v1/admin/users/${accountID}`, { headers: service }).catch(() => null);
  log(`account ${accountID} ${gone?.status === 404 ? 'deleted' : `still present (HTTP ${gone?.status})`}`);
}
process.exit(exitCode);
