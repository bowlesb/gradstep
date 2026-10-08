#!/usr/bin/env node
// Local, fail-closed stand-in for the Supabase routes the browser reader uses, for Playwright.
// It follows the real contracts (migrations 002/006/010/019/029, reader-artifact) closely enough to
// exercise the client, with public test data only. Unknown routes answer 404; nothing proxies out.
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { wrapDevice } from '../../../tests/backend/wire-crypto.mjs';
import { RECOVERY_CODE, returningKeyring } from './fixture-keys.mjs';

const PORT = Number(process.env.FIXTURE_PORT ?? 54329);
const SAMPLE = fileURLToPath(new URL('../../apple/ScienceReader/Resources/ReaderSamples/cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/', import.meta.url));
const SAMPLE_SHA = 'cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71';
const CODE = '123456';
// The chat function's published profile table (GET functions/v1/chat), exactly as the server sends it (checked against
// publishedProfiles() by tests/backend/chat-profiles-fixture.test.ts).
const CHAT_PROFILES = JSON.parse(readFileSync(new URL('../../apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/chat-profiles-v1.json', import.meta.url), 'utf8'));
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
  if (!state.has(id)) state.set(id, { keyring: null, devices: new Map(), envelopes: new Map(), requests: new Map(), seq: 0, entries: new Map(), log: [], receipts: new Map(), timers: [], privateEvents: [], chatRequests: [], chatMode: "answer", failAppend: false, importItems: new Set(), chatLabels: false, chatProfiles: true });
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
  a.phone = { bundle: keys.keys, managementToken: keys.managementToken }; // what the "iPhone" holds, for /__approve
  // The "iPhone" that created the keyring.
  a.devices.set(keys.deviceID, { id: keys.deviceID, public_key: keys.publicKey, challenge: keys.challenge, revoked_at: null });
  a.envelopes.set(`${keys.deviceID}:1`, keys.envelope);
  emit(a, [item('aaaaaaaa-0000-4000-8000-000000000001', '2305.18290', 3, DPO, { tags: ['Large language models', 'Alignment'] })]);
  emit(a, [item('aaaaaaaa-0000-4000-8000-000000000002', '2312.00752', 2, MAMBA, { archived: true })]);
  emit(a, [{ kind: 'import', id: 'bbbbbbbb-0000-4000-8000-000000000001', intent_revision: 1, visible: true, phase: 'failed', source: 'arxiv', source_id: '2401.00001',
    requested_revision: null, source_url: 'https://arxiv.org/abs/2401.00001', error_code: 'download_failed', retryable: true }]);
}

// Capacity fixture uses the production page/change shapes, including one active import.
// The total includes the archived item and import; it never raises the 4,000-entry client limit.
function seedLargeLibrary(count) {
  const a = account(ACCOUNTS['returning@example.test']);
  if (a.entries.size !== 3) return false;
  for (let i = 1; i <= count - 3; i++) {
    const number = String(i).padStart(4, '0');
    emit(a, [item(`cccccccc-0000-4000-8000-${String(i).padStart(12, '0')}`, `2501.${String(i).padStart(5, '0')}`, 1, {
      title: `Research paper ${number}: ${i % 3 === 0 ? 'Understanding efficient learning and reliable evaluation across long sequences' : 'Learning with structured representations'}`,
      authors: [`Researcher ${i % 30}`, 'Coauthor Example'], published_at: `${2020 + i % 6}-01-01`,
      categories: i % 2 === 0 ? ['cs.LG'] : ['cs.CL'],
    }, { added_at: `2026-09-${String(1 + i % 28).padStart(2, '0')}T12:00:00Z`,
      tags: i % 2 === 0 ? ['Representation learning', 'Self-supervised learning'] : ['Language modeling', 'Transformers'] })]);
  }
  const imp = a.entries.get('import:bbbbbbbb-0000-4000-8000-000000000001');
  emit(a, [{ ...imp, phase: 'acquiring', error_code: null, retryable: false, progress: 'converting',
    progress_detail: { step: 'reading_equations', percent: 40, eta_seconds: 60, pages: 15, pages_done: 6 } }]);
  return true;
}

// Imports advance on a clock, as the worker would.
function scheduleImport(a, imp, metadata) {
  const revision = imp.intent_revision;
  const currentAttempt = () => {
    const current = a.entries.get('import:' + imp.id);
    return current?.intent_revision === revision && ['accepted', 'resolving', 'acquiring'].includes(current.phase);
  };
  const stages = [
    [800, { phase: 'acquiring', progress: 'downloading', metadata_id: randomUUID(), version_id: randomUUID(), source_revision: 7, metadata, metadata_recorded_at: now(),
      source_url: `https://arxiv.org/abs/${imp.source_id}v7`, progress_detail: { step: 'downloading', percent: 18, eta_seconds: 40, bytes: 2_215_000 } }],
    [2200, { progress: 'converting', progress_detail: { step: 'reading_equations', percent: 46, eta_seconds: 25, pages: 15, pages_done: 6 } }],
    [3800, { progress: 'rendering', progress_detail: { step: 'preparing', percent: 88, eta_seconds: 4, pages: 15 } }],
  ];
  for (const [delay, change] of stages) a.timers.push(setTimeout(() => { if (!currentAttempt()) return; Object.assign(imp, change); emit(a, [imp]); }, delay));
  a.timers.push(setTimeout(() => {
    if (!currentAttempt()) return;
    const it = item(randomUUID(), imp.source_id, 7, metadata);
    a.importItems.add(it.id);
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
  // Like production v3: the creation boundary is fixed, but returned rows are current and may
  // have state_seq above it. Only grouped catch-up makes the resulting observation complete.
  return { format: 2, account_id: id, baseline_cursor: through, retained_after: 0, entries: page, has_more: list.length > page.length,
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
  v1_credit_balance: () => ({ available: 1000, reserved: 0 }),
  v2_pull_events: (id, a, p) => {
    const events = a.privateEvents.filter(e => e.cursor > p.p_after).slice(0, p.p_limit);
    return { events, next_cursor: events.at(-1)?.cursor ?? p.p_after, has_more: a.privateEvents.length > (events.at(-1)?.cursor ?? p.p_after) };
  },
  v1_append_event: (id, a, p) => {
    if (!a.keyring || verifier(id, unhex(p.p_management_token)) !== a.keyring.verifier || !a.devices.has(p.p_device_id)) throw pg('key_authority_required');
    if (a.failAppend) { a.failAppend = false; throw pg('request_failed'); }
    const previous = a.privateEvents.find(e => e.id === p.p_id);
    if (previous) { if (previous.ciphertext !== p.p_ciphertext) throw pg('event_conflict'); return previous.cursor; }
    const row = { id: p.p_id, device_id: p.p_device_id, epoch: p.p_epoch, format: p.p_format, ciphertext: p.p_ciphertext,
      ciphertext_sha256: hex(sha(unhex(p.p_ciphertext))), cursor: a.privateEvents.length + 1 };
    a.privateEvents.push(row); return row.cursor;
  },
  v1_acknowledge_cursor: () => null,
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
    if (imp.intent_revision !== p.p_expected_revision) return receipt(a, p.p_operation_id, digest, { status: 'revision_conflict', kind: 'import', id: imp.id, revision: imp.intent_revision });
    Object.assign(imp, { phase: 'cancelled', visible: false, intent_revision: imp.intent_revision + 1, retryable: false, error_code: null });
    const changed = [imp], linked = a.entries.get('item:' + imp.library_item_id);
    if (linked?.visible && a.importItems.has(linked.id)
      && ![...a.entries.values()].some(e => e.kind === 'import' && e.id !== imp.id && e.library_item_id === linked.id && e.phase === 'ready')) {
      changed.push({ ...linked, visible: false, membership_revision: linked.membership_revision + 1 });
    }
    const seq = emit(a, changed);
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
  if (url.pathname === '/__chat-fixture' && request.method === 'POST') {
    const p = await read(request), a = account(ACCOUNTS['returning@example.test']);
    if (['answer', 'slow', 'steady', 'external_diagram', 'insufficient_credits', 'refusal', 'eof', 'diagram', 'tall_diagram', 'unsafe_diagram', 'broken_diagram'].includes(p?.mode)) a.chatMode = p.mode;
    if (typeof p?.failAppend === 'boolean') a.failAppend = p.failAppend;
    // labels: answers name their model and profile, and a requested topic title is sent (servers from 2026-10-08).
    if (typeof p?.labels === 'boolean') a.chatLabels = p.labels;
    // profiles: false answers GET functions/v1/chat with 404, as a server before profiles does.
    if (typeof p?.profiles === 'boolean') a.chatProfiles = p.profiles;
    return send(response, 200, { ok: true });
  }
  if (url.pathname === '/__chat-evidence') { const a = account(ACCOUNTS['returning@example.test']); return send(response, 200, { events: a.privateEvents, requests: a.chatRequests }); }
  if (url.pathname === '/__large-library' && request.method === 'POST') {
    const body = await read(request);
    if (!Number.isInteger(body?.count) || body.count < 3 || body.count > 4000 || !seedLargeLibrary(body.count)) return send(response, 400, {});
    return send(response, 200, { ok: true, entries: body.count });
  }
  if (url.pathname === '/__removable-import' && request.method === 'POST') {
    const a = account(ACCOUNTS['returning@example.test']), imp = a.entries.get('import:bbbbbbbb-0000-4000-8000-000000000001');
    emit(a, [{ ...imp, retryable: false, error_code: 'pdf_invalid' }]);
    return send(response, 200, { ok: true });
  }
  if (url.pathname === '/__cancel-stopped-import' && request.method === 'POST') {
    const id = ACCOUNTS['returning@example.test'], a = account(id), imp = a.entries.get('import:bbbbbbbb-0000-4000-8000-000000000001');
    rpcs.v2_cancel_import(id, a, { p_operation_id: randomUUID(), p_import_id: imp.id, p_expected_revision: imp.intent_revision });
    return send(response, 200, { ok: true });
  }
  // The returning account's "iPhone" scans the browser's QR text and approves it as the app does (DeviceApproval.swift),
  // independently in Node: same account, the named (or renewed) request must hash to the scanned fingerprint.
  if (url.pathname === '/__approve' && request.method === 'POST') {
    const body = await read(request), id = ACCOUNTS['returning@example.test'], a = account(id);
    const parts = typeof body?.payload === 'string' ? body.payload.split('.') : [];
    if (parts.length !== 5 || parts[0] !== 'GSDA1' || parts[4] !== 'w') return send(response, 400, { error: 'unrecognized' });
    const requestID = Buffer.from(parts[1], 'base64url').toString('hex').replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
    if (sha(Buffer.from(`science-reader/device-approval/v1/account/${id}`)).subarray(0, 16).toString('base64url') !== parts[2]) return send(response, 409, { error: 'different_account' });
    const print = r => sha(Buffer.concat([Buffer.from(`science-reader/enrollment/v1/${id}/${r.device_id}/`), unhex(r.public_key), unhex(r.challenge)])).toString('base64url');
    const pending = [...a.requests.values()].filter(r => !r.approved_at);
    const r = pending.find(r => r.id === requestID) ?? pending.find(r => print(r) === parts[3]);
    if (!r) return send(response, 404, { error: 'expired_or_used' });
    if (print(r) !== parts[3]) return send(response, 409, { error: 'key_mismatch' });
    const code = String(sha(Buffer.concat([Buffer.from('science-reader/device-approval/v1/code/'), Buffer.from(parts[3], 'base64url')])).readUInt32BE(0) % 1e6).padStart(6, '0');
    const envelope = wrapDevice(a.phone.bundle, r.device_id, unhex(r.public_key), unhex(r.challenge));
    rpcs.v1_approve_enrollment(id, a, { p_request_id: r.id, p_epoch: 1, p_management_token: hex(a.phone.managementToken),
      p_expected_public_key: r.public_key, p_expected_challenge: r.challenge, p_envelope: hex(envelope) });
    return send(response, 200, { ok: true, code });
  }
  if (url.pathname === '/__pending-requests' && request.method === 'GET') {
    const a = account(ACCOUNTS['returning@example.test']);
    return send(response, 200, [...a.requests.values()].map(r => ({ id: r.id, approved: Boolean(r.approved_at) })));
  }
  if (url.pathname === '/__another-paper' && request.method === 'POST') {
    const a = account(ACCOUNTS['returning@example.test']);
    emit(a, [item('aaaaaaaa-0000-4000-8000-000000000003', '2501.01234', 1, { ...ATTENTION, title: 'Added on another device' })]);
    return send(response, 200, { ok: true });
  }
  // A tag projection arriving from the worker or another device, through the real library journal shape.
  if (url.pathname === '/__paper-tags' && request.method === 'POST') {
    const body = await read(request), a = account(ACCOUNTS['returning@example.test']);
    const paper = a.entries.get('item:aaaaaaaa-0000-4000-8000-000000000001');
    if (!paper || !Array.isArray(body?.tags) || body.tags.length > 16 || body.tags.some(tag => typeof tag !== 'string' || tag.length > 40)) return send(response, 400, {});
    const updated = { ...paper };
    if (body.tags.length) updated.tags = body.tags; else delete updated.tags; // the wire omits empty lists
    emit(a, [updated]);
    return send(response, 200, { ok: true });
  }
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
  if (url.pathname === '/functions/v1/chat' && request.method === 'GET') {
    return a.chatProfiles ? send(response, 200, CHAT_PROFILES) : send(response, 404, { code: 'method_unavailable' });
  }
  if (url.pathname === '/functions/v1/chat' && request.method === 'POST') {
    const body = await read(request);
    if (!body?.operation_id || body.consent_version !== 'cloud-ai-v2' || !body.messages?.length) return send(response, 400, { code: 'invalid_request' });
    // As chat.ts validates: a profile is exactly {model, effort, length} with known values; topic_title is a boolean.
    const p = body.profile;
    if (p !== undefined && (!p || typeof p !== 'object' || Object.keys(p).length !== 3 || !['haiku', 'sonnet', 'opus'].includes(p.model)
      || !['low', 'medium', 'high'].includes(p.effort) || !['brief', 'standard', 'detailed'].includes(p.length))) return send(response, 400, { code: 'invalid_request' });
    if (body.topic_title !== undefined && typeof body.topic_title !== 'boolean') return send(response, 400, { code: 'invalid_request' });
    a.chatRequests.push({ ...body, eventsBeforeRequest: a.privateEvents.length });
    response.writeHead(200, { ...cors, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' });
    const event = (kind, data) => { if (!response.destroyed) response.write(`event: ${kind}\ndata: ${JSON.stringify(data)}\n\n`); };
    const mode = a.chatMode;
    if (mode === 'insufficient_credits') { event('error', { code: 'insufficient_credits' }); return response.end(); }
    if (mode === 'refusal') { event('delta', { text: 'Discard this refused partial' }); event('error', { code: 'refused' }); return response.end(); }
    event('status', { kind: body.action === 'related' ? 'searching' : 'reading', query: body.action === 'related' ? 'DPO related work' : undefined });
    const text = 'The **objective** compares preferences.\\n\\n\\[L = -\\log \\sigma(\\beta x)\\]\\n\\n| Term | Meaning |\\n|---|---|\\n| β | Temperature |\\n\\n[Original paper](https://arxiv.org/abs/2305.18290)\\n\\n<script>window.injected = true</script>'.replaceAll('\\n', '\n');
    const chunks = text.match(mode === 'steady' ? /[\s\S]/g : /[\s\S]{1,24}/g);
    let index = 0;
    const tick = () => {
      if (response.destroyed) return;
      if (index < chunks.length) { event('delta', { text: chunks[index++] }); if (mode === 'eof' && index === 2) return response.end(); return setTimeout(tick, mode === 'slow' ? 500 : 15); }
      if (mode.includes('diagram')) event('diagram', { title: 'Preference flow', source: mode === 'unsafe_diagram' ? '%%{init: {"securityLevel":"loose"}}%%\ngraph TD; A-->B' : mode === 'broken_diagram' ? 'graph TD; A-->' : mode === 'external_diagram' ? `flowchart TD
A["<img src='https://attacker.invalid/tracker.png'>"] --> B[Answer]
click B "https://attacker.invalid/open"` : mode === 'tall_diagram' ? 'flowchart TD; A[Start] --> B[Compute loss]; B --> C[Compute gradient]; C --> D[Update weights]; D --> E[Validate]; E --> F{Repeat}; F -->|Yes| B; F -->|No| G[Finish]' : 'graph TD; A[Policy] --> B[Preferences]; B --> C[Loss]' });
      if (a.chatLabels && body.topic_title === true) event('title', { text: 'Preference objective explained' });
      const profile = body.profile ? `${body.profile.model}-${body.profile.effort}-${body.profile.length}` : 'sonnet-low-standard';
      const model = { haiku: 'claude-haiku-5-5', sonnet: 'claude-sonnet-5-5', opus: 'claude-opus-5-5' }[body.profile?.model ?? 'sonnet'];
      event('done', { stop_reason: 'end_turn', credits: 3, ...(a.chatLabels ? { model, profile } : {}) }); response.end();
    };
    setTimeout(tick, 200); return;
  }
  if (url.pathname === '/functions/v1/reader-artifact'  && request.method === 'GET') {
    const itemID = url.searchParams.get('item_id'), entry = a.entries.get('item:' + itemID);
    if (!entry || entry.readiness !== 'converted_ready') return send(response, 404, { code: 'item_unavailable' });
    const manifest = readFileSync(join(SAMPLE, 'manifest.json'));
    const members = JSON.parse(manifest).members.map(m => ({ path: m.path, sha256: m.sha256, bytes: m.bytes,
      url: `http://127.0.0.1:${PORT}/storage/v1/object/sign/paper-assets/reader/${SAMPLE_SHA}/${m.path}?token=signed` }));
    return send(response, 200, { item_id: itemID, document_id: entry.document_id, artifact_id: entry.artifact_id, renderer_version: 'timestep-mathpix-mathml-v1',
      manifest_sha256: sha(manifest).toString('hex'), manifest: manifest.toString('base64'), members });
  }
  // Feed (discover?category=…): public sample metadata only.
  if (url.pathname === '/functions/v1/discover' && request.method === 'GET') {
    const category = url.searchParams.get('category') ?? '';
    if (!/^[a-z]{2,8}(-[a-z]{2,6})?(\.[A-Z]{2})?$/.test(category)) return send(response, 400, { code: 'invalid_category' });
    return send(response, 200, { results: [
      { source_id: '2305.18290', revision: 3, title: DPO.title, authors: DPO.authors, year: 2023, abstract: DPO.abstract, categories: DPO.categories },
      { source_id: '2604.01001', revision: 1, title: `New in ${category}: scaling sparse attention`, authors: ['Ada Example', 'Grace Sample'], year: 2026,
        abstract: 'We study how sparse attention patterns scale with context length and compute budget, and find a simple recipe that matches dense attention.', categories: [category] },
      { source_id: '2604.01002', revision: 1, title: `New in ${category}: evaluation under distribution shift`, authors: ['Alan Fixture'], year: 2026, abstract: null, categories: [category] },
    ] });
  }
  // Add by DOI or link (add-paper): a DOI is identified and queued as an arXiv import; a publisher link is blocked.
  if (url.pathname === '/functions/v1/add-paper' && request.method === 'POST') {
    const body = await read(request), query = typeof body?.query === 'string' ? body.query.trim() : '';
    if (!/^[0-9a-f-]{36}$/.test(body?.operation_id ?? '') || !query) return send(response, 400, { code: 'invalid_request' });
    const base = { link: null, reason: null, title: null };
    if (/^(doi:|https:\/\/doi\.org\/)?10\.48550\/arxiv\.1706\.03762$/i.test(query)) {
      if (![...a.entries.values()].some(e => e.source_id === '1706.03762' && e.visible)) {
        const imp = { kind: 'import', id: randomUUID(), intent_revision: 1, visible: true, phase: 'accepted', source: 'arxiv', source_id: '1706.03762', requested_revision: null,
          source_url: 'https://arxiv.org/abs/1706.03762', retryable: false, progress: 'finding', progress_detail: { step: 'finding', percent: 2, eta_seconds: 50 } };
        emit(a, [imp]); scheduleImport(a, a.entries.get('import:' + imp.id), ATTENTION);
      }
      return send(response, 200, { status: 'added', route: 'doi', paper: { title: ATTENTION.title, year: 2017, source_id: '1706.03762', kind: 'arxiv', host: null, link: null }, ...base });
    }
    if (/^https:\/\/publisher\.example\//.test(query)) return send(response, 200, { status: 'blocked', route: 'link', paper: null, link: query, reason: 'pdf_restricted', title: null });
    return send(response, 200, { status: 'not_found', route: 'reference', paper: null, ...base });
  }
  send(response, 404, { message: 'unknown fixture route' });
}).listen(PORT, '127.0.0.1', () => { seedReturning(); console.log(`fixture backend on ${PORT}; recovery code for returning@example.test: ${RECOVERY_CODE}`); });
