#!/usr/bin/env node
// Local, fail-closed stand-in for the Supabase routes the browser reader uses, for Playwright.
// It follows the real contracts (migrations 002/006/010/019/029, reader-artifact) closely enough to
// exercise the client, with public test data only. Unknown routes answer 404; nothing proxies out.
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { RECOVERY_CODE, returningKeyring } from './fixture-keys.mjs';

const PORT = Number(process.env.FIXTURE_PORT ?? 54329);
const SAMPLE = fileURLToPath(new URL('../../apple/ScienceReader/Resources/ReaderSamples/cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/', import.meta.url));
const SAMPLE_SHA = 'cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71';
const CODE = '123456';
export const ACCOUNTS = { 'returning@example.test': '11111111-2222-4333-8444-555555555555', 'new@example.test': '22222222-3333-4444-8555-666666666666' };

const sha = bytes => createHash('sha256').update(bytes).digest();
const unhex = v => { if (typeof v !== 'string' || !/^\\x([0-9a-f]{2})*$/.test(v)) throw pg('invalid_bytea'); return Buffer.from(v.slice(2), 'hex'); };
const hex = b => '\\x' + Buffer.from(b).toString('hex');
const pg = message => Object.assign(new Error(message), { pg: true });
const verifier = (account, token) => sha(Buffer.concat([Buffer.from(`science-reader/management/v1/${account}/`), token])).toString('hex');

// ---------- State ----------
const sessions = new Map(); // token -> account
const state = new Map();
function account(id) {
  if (!state.has(id)) state.set(id, { keyring: null, devices: new Map(), envelopes: new Map(), requests: new Map(), seq: 0, entries: new Map(), log: [], receipts: new Map(), timers: [] });
  return state.get(id);
}
const now = () => new Date().toISOString();
const DPO = { title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', authors: ['Rafael Rafailov', 'Archit Sharma', 'Eric Mitchell', 'Stefano Ermon', 'Christopher D. Manning', 'Chelsea Finn'],
  abstract: 'While large-scale unsupervised language models learn broad world knowledge…', published_at: '2023-05-29', categories: ['cs.LG', 'cs.AI', 'cs.CL'], venue: 'NeurIPS 2023' };
const ATTENTION = { title: 'Attention Is All You Need', authors: ['Ashish Vaswani', 'Noam Shazeer', 'Niki Parmar'], published_at: '2017-06-12', categories: ['cs.CL', 'cs.LG'] };
const MAMBA = { title: 'Mamba: Linear-Time Sequence Modeling with Selective State Spaces', authors: ['Albert Gu', 'Tri Dao'], published_at: '2023-12-01', categories: ['cs.LG'] };

function emit(a, entries) {
  a.seq++;
  for (const e of entries) { e.state_seq = a.seq; if (!e.created_seq) e.created_seq = a.seq; a.entries.set(e.kind + ':' + e.id, structuredClone(e)); }
  a.log.push({ seq: a.seq, entries: entries.map(e => structuredClone(e)) });
  return a.seq;
}
function item(id, source, revision, metadata, extra = {}) {
  return { kind: 'item', id, document_id: randomUUID(), membership_revision: 1, visible: true, added_at: now(), last_remove_seq: 0,
    approval_id: randomUUID(), version_id: randomUUID(), metadata_id: randomUUID(), source: 'arxiv', source_id: source, source_revision: revision,
    metadata, metadata_recorded_at: now(), source_url: `https://arxiv.org/abs/${source}v${revision}`, scope: 'shared_catalog', page_count: 27,
    original_object_id: randomUUID(), artifact_id: randomUUID(), readiness: 'converted_ready', original_availability: 'available', render_availability: 'available',
    original_availability_revision: 1, render_availability_revision: 1, ...extra };
}
function seedReturning() {
  const a = account(ACCOUNTS['returning@example.test']);
  if (a.seq) return;
  const keys = returningKeyring();
  a.keyring = { epoch: 1, recovery_package: keys.recoveryPackage, verifier: verifier(ACCOUNTS['returning@example.test'], keys.managementToken) };
  // The "iPhone" that created the keyring.
  a.devices.set(keys.deviceID, { id: keys.deviceID, public_key: keys.publicKey, challenge: keys.challenge, revoked_at: null });
  a.envelopes.set(`${keys.deviceID}:1`, keys.envelope);
  emit(a, [item('aaaaaaaa-0000-4000-8000-000000000001', '2305.18290', 3, DPO, { tags: ['Large language models', 'Alignment'] })]);
  emit(a, [item('aaaaaaaa-0000-4000-8000-000000000002', '2312.00752', 2, MAMBA, { archived: true })]);
  emit(a, [{ kind: 'import', id: 'bbbbbbbb-0000-4000-8000-000000000001', intent_revision: 1, visible: true, phase: 'failed', source: 'arxiv', source_id: '2401.00001',
    requested_revision: null, source_url: 'https://arxiv.org/abs/2401.00001', error_code: 'download_failed', retryable: true }]);
}

// Imports advance on a clock, as the worker would.
function scheduleImport(a, imp, metadata) {
  const stages = [
    [800, { phase: 'acquiring', progress: 'downloading', metadata_id: randomUUID(), version_id: randomUUID(), source_revision: 7, metadata, metadata_recorded_at: now(),
      source_url: `https://arxiv.org/abs/${imp.source_id}v7`, progress_detail: { step: 'downloading', percent: 18, eta_seconds: 40, bytes: 2_215_000 } }],
    [2200, { progress: 'converting', progress_detail: { step: 'reading_equations', percent: 46, eta_seconds: 25, pages: 15, pages_done: 6 } }],
    [3800, { progress: 'rendering', progress_detail: { step: 'preparing', percent: 88, eta_seconds: 4, pages: 15 } }],
  ];
  for (const [delay, change] of stages) a.timers.push(setTimeout(() => { Object.assign(imp, change); emit(a, [imp]); }, delay));
  a.timers.push(setTimeout(() => {
    const it = item(randomUUID(), imp.source_id, 7, metadata);
    Object.assign(imp, { phase: 'ready', visible: false, document_id: it.document_id, library_item_id: it.id, progress: null, progress_detail: null });
    emit(a, [it, imp]);
  }, 5200));
}

// ---------- Library pages (format 2) ----------
const ordered = a => [...a.entries.values()].sort((x, y) => x.created_seq - y.created_seq || (x.id < y.id ? -1 : x.id > y.id ? 1 : x.kind < y.kind ? -1 : 1));
function libraryPage(id, a, { p_cursor, p_limit = 100 }) {
  const through = p_cursor?.through ?? a.seq;
  let list = ordered(a).filter(e => e.created_seq <= through);
  if (p_cursor) list = list.filter(e => e.created_seq > p_cursor.created_seq || (e.created_seq === p_cursor.created_seq && (e.id > p_cursor.id || (e.id === p_cursor.id && e.kind > p_cursor.kind))));
  const page = list.slice(0, p_limit), last = page[page.length - 1];
  // A baseline row is the entity's state at or before the boundary (latest log entry ≤ through).
  const asOf = e => { for (let i = a.log.length - 1; i >= 0; i--) { if (a.log[i].seq > through) continue; const hit = a.log[i].entries.find(x => x.kind === e.kind && x.id === e.id); if (hit) return hit; } return e; };
  return { format: 2, account_id: id, baseline_cursor: through, retained_after: 0, entries: page.map(asOf), has_more: list.length > page.length,
    next_cursor: last ? { format: 2, account_id: id, through, created_seq: last.created_seq, id: last.id, kind: last.kind } : null };
}
function libraryChanges(id, a, { p_after, p_through, p_limit = 100 }) {
  const through = p_through ?? a.seq;
  const changes = a.log.filter(c => c.seq > p_after && c.seq <= through).slice(0, p_limit);
  const more = a.log.filter(c => c.seq > p_after && c.seq <= through).length > changes.length;
  return { format: 2, account_id: id, through, retained_after: 0, changes, next_cursor: more ? changes[changes.length - 1].seq : through, has_more: more };
}
function receipt(a, operation, digest, result) {
  const old = a.receipts.get(operation);
  if (old) { if (old.digest !== digest) throw pg('operation_id_conflict'); return { ...old.response, replayed: true, entry: a.entries.get(old.response.result.kind + ':' + old.response.result.id) }; }
  const response = { result, replayed: false };
  a.receipts.set(operation, { digest, response });
  return { ...response, entry: a.entries.get(result.kind + ':' + result.id) };
}

// ---------- RPCs ----------
const rpcs = {
  v1_key_state: (id, a, p) => a.keyring && {
    epoch: a.keyring.epoch, recovery_package: a.keyring.recovery_package,
    device_envelope: a.devices.get(p.p_device_id)?.revoked_at === null ? a.envelopes.get(`${p.p_device_id}:${a.keyring.epoch}`) ?? null : null,
  },
  v1_bootstrap_keys: (id, a, p) => {
    if (unhex(p.p_management_token).length !== 32) throw pg('invalid_management_token');
    if (a.keyring) return false;
    a.keyring = { epoch: 1, recovery_package: p.p_recovery_package, verifier: verifier(id, unhex(p.p_management_token)) };
    a.devices.set(p.p_device_id, { id: p.p_device_id, public_key: p.p_public_key, challenge: p.p_challenge, revoked_at: null });
    a.envelopes.set(`${p.p_device_id}:1`, p.p_device_envelope);
    return true;
  },
  v1_request_enrollment: (id, a, p) => {
    const old = a.requests.get(p.p_request_id);
    if (old) { if (old.device_id !== p.p_device_id || old.public_key !== p.p_public_key || old.challenge !== p.p_challenge) throw pg('enrollment_id_conflict'); return p.p_request_id; }
    a.requests.set(p.p_request_id, { id: p.p_request_id, device_id: p.p_device_id, public_key: p.p_public_key, challenge: p.p_challenge, approved_at: null });
    return p.p_request_id;
  },
  v1_enrollment_requests: (id, a) => [...a.requests.values()].filter(r => !r.approved_at),
  v1_approve_enrollment: (id, a, p) => {
    if (!a.keyring || verifier(id, unhex(p.p_management_token)) !== a.keyring.verifier || p.p_epoch !== a.keyring.epoch) throw pg('key_authority_required');
    const r = a.requests.get(p.p_request_id);
    if (!r || r.public_key !== p.p_expected_public_key || r.challenge !== p.p_expected_challenge) throw pg('enrollment_mismatch');
    if (r.approved_at) return null;
    a.devices.set(r.device_id, { id: r.device_id, public_key: r.public_key, challenge: r.challenge, revoked_at: null });
    a.envelopes.set(`${r.device_id}:${p.p_epoch}`, p.p_envelope);
    r.approved_at = now();
    return null;
  },
  v1_devices: (id, a) => [...a.devices.values()],
  v3_library_page: libraryPage,
  v3_library_changes: libraryChanges,
  v2_begin_import: (id, a, p) => {
    if (!/^\d{4}\.\d{4,5}$/.test(p.p_source_id)) throw pg('invalid_arxiv_id');
    const digest = JSON.stringify(['arxiv-import-v1', p.p_source_id, p.p_requested_revision, p.p_observed_cursor]);
    if (a.receipts.has(p.p_operation_id)) return receipt(a, p.p_operation_id, digest);
    const imp = { kind: 'import', id: p.p_operation_id, intent_revision: 1, visible: true, phase: 'accepted', source: 'arxiv', source_id: p.p_source_id,
      requested_revision: p.p_requested_revision ?? null, source_url: `https://arxiv.org/abs/${p.p_source_id}${p.p_requested_revision ? 'v' + p.p_requested_revision : ''}`,
      retryable: false, progress: 'finding', progress_detail: { step: 'finding', percent: 3, eta_seconds: 50 } };
    const seq = emit(a, [imp]);
    scheduleImport(a, a.entries.get('import:' + imp.id), p.p_source_id === '1706.03762' ? ATTENTION : { ...ATTENTION, title: `Paper ${p.p_source_id}` });
    return receipt(a, p.p_operation_id, digest, { status: 'applied', kind: 'import', id: imp.id, seq, revision: 1 });
  },
  v2_retry_import: (id, a, p) => {
    const imp = a.entries.get('import:' + p.p_import_id);
    if (!imp) throw pg('import_unavailable');
    const digest = JSON.stringify(['retry', p.p_import_id, p.p_expected_revision]);
    if (a.receipts.has(p.p_operation_id)) return receipt(a, p.p_operation_id, digest);
    if (imp.intent_revision !== p.p_expected_revision) return receipt(a, p.p_operation_id, digest, { status: 'revision_conflict', kind: 'import', id: imp.id, revision: imp.intent_revision });
    if (imp.phase !== 'failed' || !imp.retryable) throw pg('import_not_retryable');
    Object.assign(imp, { phase: 'accepted', intent_revision: imp.intent_revision + 1, error_code: null, retryable: false, progress: 'finding', progress_detail: { step: 'finding', percent: 2, eta_seconds: 50 } });
    const seq = emit(a, [imp]);
    scheduleImport(a, a.entries.get('import:' + imp.id), { ...ATTENTION, title: 'A retried paper' });
    return receipt(a, p.p_operation_id, digest, { status: 'applied', kind: 'import', id: imp.id, seq, revision: imp.intent_revision });
  },
  v2_cancel_import: (id, a, p) => {
    const imp = a.entries.get('import:' + p.p_import_id);
    if (!imp) throw pg('import_unavailable');
    const digest = JSON.stringify(['cancel', p.p_import_id, p.p_expected_revision]);
    if (a.receipts.has(p.p_operation_id)) return receipt(a, p.p_operation_id, digest);
    Object.assign(imp, { phase: 'cancelled', visible: false, intent_revision: imp.intent_revision + 1, retryable: false, error_code: null });
    const seq = emit(a, [imp]);
    return receipt(a, p.p_operation_id, digest, { status: 'applied', kind: 'import', id: imp.id, seq, revision: imp.intent_revision });
  },
};

// ---------- HTTP ----------
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'apikey, authorization, content-type, x-client-info', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' };
function send(response, status, body, type = 'application/json') {
  const data = body === undefined ? '' : Buffer.isBuffer(body) ? body : JSON.stringify(body);
  response.writeHead(status, { ...cors, 'Content-Type': type, 'Cache-Control': 'no-store' });
  response.end(data);
}
const read = request => new Promise(resolve => { let b = ''; request.on('data', c => { b += c; }); request.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch { resolve(null); } }); });
function sessionFor(email) {
  const token = 'fixture-' + randomUUID(), id = ACCOUNTS[email];
  sessions.set(token, id);
  return { access_token: token, refresh_token: 'refresh-' + randomUUID(), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, user: { id, email } };
}
const memberFiles = () => {
  const files = [];
  const walk = dir => { for (const name of readdirSync(join(SAMPLE, dir))) { const rel = dir ? `${dir}/${name}` : name; statSync(join(SAMPLE, rel)).isDirectory() ? walk(rel) : files.push(rel); } };
  walk(''); return files;
};

createServer(async (request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${PORT}`);
  if (request.method === 'OPTIONS') return send(response, 204);
  if (url.pathname === '/health') return send(response, 200, { ok: true });
  if (url.pathname === '/__reset' && request.method === 'POST') { for (const a of state.values()) a.timers.forEach(clearTimeout); state.clear(); sessions.clear(); seedReturning(); return send(response, 200, { ok: true }); }
  // Signed Storage URLs carry no API key or account credential.
  if (url.pathname.startsWith('/storage/v1/object/sign/paper-assets/reader/')) {
    const path = decodeURIComponent(url.pathname.slice(`/storage/v1/object/sign/paper-assets/reader/${SAMPLE_SHA}/`.length));
    if (url.searchParams.get('token') !== 'signed' || !memberFiles().includes(path)) return send(response, 400, { error: 'InvalidSignature' });
    return send(response, 200, readFileSync(join(SAMPLE, path)), 'application/octet-stream');
  }
  if (request.headers.apikey !== 'fixture-anon') return send(response, 401, { message: 'No API key' });
  if (url.pathname === '/auth/v1/otp' && request.method === 'POST') {
    const body = await read(request);
    if (!ACCOUNTS[body?.email]) return send(response, 422, { code: 422, error_code: 'otp_disabled', msg: 'Signups not allowed for otp' });
    return send(response, 200, {});
  }
  if (url.pathname === '/auth/v1/verify' && request.method === 'POST') {
    const body = await read(request);
    if (body?.type !== 'email' || !ACCOUNTS[body.email] || body.token !== CODE) return send(response, 403, { code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' });
    return send(response, 200, sessionFor(body.email));
  }
  if (url.pathname === '/auth/v1/logout') return send(response, 204);
  const id = sessions.get((request.headers.authorization ?? '').replace(/^Bearer /, ''));
  if (!id) return send(response, 401, { code: 'PGRST301', message: 'JWT expired' });
  const a = account(id);
  if (url.pathname.startsWith('/rest/v1/rpc/') && request.method === 'POST') {
    const name = url.pathname.slice('/rest/v1/rpc/'.length), body = await read(request);
    if (!rpcs[name] || body === null) return send(response, 404, { code: 'PGRST202', message: 'not found' });
    try {
      const result = rpcs[name](id, a, body);
      return result === null && ['v1_approve_enrollment'].includes(name) ? send(response, 204) : send(response, 200, result ?? null);
    } catch (error) {
      if (error.pg) return send(response, 400, { code: 'P0001', message: error.message });
      throw error;
    }
  }
  if (url.pathname === '/functions/v1/reader-artifact' && request.method === 'GET') {
    const itemID = url.searchParams.get('item_id'), entry = a.entries.get('item:' + itemID);
    if (!entry || entry.readiness !== 'converted_ready') return send(response, 404, { code: 'item_unavailable' });
    const manifest = readFileSync(join(SAMPLE, 'manifest.json'));
    const members = JSON.parse(manifest).members.map(m => ({ path: m.path, sha256: m.sha256, bytes: m.bytes,
      url: `http://127.0.0.1:${PORT}/storage/v1/object/sign/paper-assets/reader/${SAMPLE_SHA}/${m.path}?token=signed` }));
    return send(response, 200, { item_id: itemID, document_id: entry.document_id, artifact_id: entry.artifact_id, renderer_version: 'timestep-mathpix-mathml-v1',
      manifest_sha256: sha(manifest).toString('hex'), manifest: manifest.toString('base64'), members });
  }
  send(response, 404, { message: 'unknown fixture route' });
}).listen(PORT, '127.0.0.1', () => { seedReturning(); console.log(`fixture backend on ${PORT}; recovery code for returning@example.test: ${RECOVERY_CODE}`); });
