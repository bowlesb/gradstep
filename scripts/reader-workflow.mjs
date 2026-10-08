// Reader transport verification for workflow checks. No environment access or side effects on import.
// This checks authenticated delivery, manifest membership and bytes; native/browser renderer admission
// remains separate. Finite errors never contain a bearer URL, token, member path or response body.
import { createHash } from 'node:crypto';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = value => typeof value === 'string' && value.length === 64 && /^[0-9a-f]{64}$/.test(value);
const uuid = value => typeof value === 'string' && value.length === 36 && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const path = value => typeof value === 'string' && value.length <= 240 && !/[\r\n]/.test(value) && !value.includes('..')
  && value.split('/').every(part => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(part));
const mediaTypes = new Set(['text/html', 'text/css', 'text/plain', 'application/json', 'image/png', 'image/jpeg']);
const publicErrors = new Set(['reader_transfer_limit', 'reader_upgrade_required', 'reader_grant_unavailable', 'reader_grant_consumed',
  'reader_unavailable', 'reader_not_ready', 'reader_integrity_failed', 'asset_inventory_incomplete', 'authentication_required',
  'account_unavailable', 'request_rate_limit', 'service_unavailable']);
const fail = code => { throw new Error(code); };
const deadline = (ms, signal) => AbortSignal.any([AbortSignal.timeout(ms), ...(signal ? [signal] : [])]);

async function readBounded(response, maximum, expected) {
  const declared = response.headers.get('content-length');
  if (!response.body || declared !== null && (!/^\d+$/.test(declared) || declared.length > 10
    || Number(declared) > maximum || expected !== undefined && Number(declared) !== expected)) {
    await response.body?.cancel().catch(() => {}); fail('reader_response_size');
  }
  const reader = response.body.getReader(), chunks = []; let count = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      count += value.length;
      if (count > maximum) fail('reader_response_size');
      chunks.push(value);
    }
  } catch {
    await reader.cancel().catch(() => {}); fail('reader_response_read_failed');
  } finally { reader.releaseLock(); }
  if (expected !== undefined && count !== expected || declared !== null && count !== Number(declared)) fail('reader_response_size');
  return Buffer.concat(chunks, count);
}

async function request(fetcher, url, headers, signal, maximum, expected, kind) {
  if (signal.aborted) fail('reader_cancelled');
  let response;
  try { response = await fetcher(url.href, { method: 'GET', headers, redirect: 'error', signal }); }
  catch { fail('reader_transport_failed'); }
  if (response.redirected || response.url !== url.href) { await response.body?.cancel().catch(() => {}); fail('reader_response_origin'); }
  if (response.status !== 200) {
    const bytes = await readBounded(response, 4096);
    let code;
    try { code = JSON.parse(bytes.toString('utf8'))?.code; } catch { /* finite status only */ }
    fail(`${kind}: HTTP ${response.status}${publicErrors.has(code) ? ` ${code}` : ''}`);
  }
  // Ask for identity encoding; refuse compressed/partial replies before treating a declared
  // length as decoded bytes. The authenticated member endpoint explicitly emits these headers.
  const encoding = response.headers.get('content-encoding');
  if (encoding && encoding.toLowerCase() !== 'identity' || response.headers.has('content-range')) {
    await response.body?.cancel().catch(() => {}); fail('reader_response_encoding');
  }
  return { response, bytes: await readBounded(response, maximum, expected) };
}

function memberURL(value, origin, memberPath, transport) {
  if (typeof value !== 'string' || value.length > 8192) fail('reader_member_url');
  let url;
  try { url = new URL(value); } catch { fail('reader_member_url'); }
  if (url.origin !== origin || url.protocol !== 'https:' || url.username || url.password || value.includes('#') || url.href !== value) fail('reader_member_url');
  if (transport === 'bounded-v1') {
    if (url.pathname !== '/functions/v1/reader-member' || url.searchParams.size !== 2
      || !digest(url.searchParams.get('grant')) || !uuid(url.searchParams.get('member'))) fail('reader_member_url');
  } else if (!url.pathname.startsWith('/storage/v1/object/sign/paper-assets/reader/') || !url.pathname.endsWith('/' + memberPath)
    || url.searchParams.size !== 1 || !url.searchParams.get('token')) fail('reader_member_url');
  return url;
}

export function validateReaderDescriptor(value, expected, origin) {
  if (!value || value.item_id !== expected.id || value.document_id !== expected.document_id || value.artifact_id !== expected.artifact_id
    || !digest(value.manifest_sha256) || typeof value.renderer_version !== 'string' || !value.renderer_version.length
    || value.renderer_version.length > 64 || typeof value.manifest !== 'string' || value.manifest.length > 349_528
    || !Array.isArray(value.members) || value.members.length < 1 || value.members.length > 512) fail('reader_descriptor_invalid');
  const manifestBytes = Buffer.from(value.manifest, 'base64');
  if (manifestBytes.length > 262_144 || manifestBytes.toString('base64') !== value.manifest
    || hash(manifestBytes) !== value.manifest_sha256) fail('reader_manifest_integrity');
  let manifest;
  try { manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(manifestBytes)); }
  catch { fail('reader_manifest_invalid'); }
  if (manifest?.format !== 'reader-bundle-v1' || !Array.isArray(manifest.members) || manifest.members.length !== value.members.length) fail('reader_manifest_invalid');
  const inventory = new Map(), names = new Set(); let total = 0;
  for (const member of manifest.members) {
    if (!member || !path(member.path) || names.has(member.path.toLowerCase()) || !digest(member.sha256)
      || !Number.isSafeInteger(member.bytes) || member.bytes < 1 || member.bytes > 16_777_216 || !mediaTypes.has(member.media_type)) fail('reader_manifest_invalid');
    total += member.bytes; names.add(member.path.toLowerCase()); inventory.set(member.path, member);
  }
  if (total > 33_554_432) fail('reader_manifest_invalid');
  // Descriptors before 035 omit transport and contain only legacy Storage URLs.
  const transport = value.transport ?? 'legacy';
  if (transport !== 'legacy' && transport !== 'bounded-v1') fail('reader_descriptor_transport');
  const seen = new Set(), objectIDs = new Set(), grants = new Set();
  const members = value.members.map(member => {
    const entry = member && inventory.get(member.path);
    if (!entry || seen.has(member.path) || member.sha256 !== entry.sha256 || member.bytes !== entry.bytes) fail('reader_manifest_membership');
    seen.add(member.path);
    const url = memberURL(member.url, origin, member.path, transport);
    if (transport === 'bounded-v1') {
      const objectID = url.searchParams.get('member').toLowerCase();
      if (objectIDs.has(objectID)) fail('reader_manifest_membership');
      objectIDs.add(objectID); grants.add(url.searchParams.get('grant'));
    }
    return { ...entry, url };
  });
  if (grants.size > 1) fail('reader_manifest_membership');
  return { transport, members };
}

/** Prefer the actual bounded protocol while keeping explicitly observed legacy compatibility.
 * `token` supplies this synthetic account's current bearer, never a service-role credential.
 * Every URL is checked before the first member is sent; there are no retries of one-use grants. */
export async function verifyReaderDelivery({ backendURL, anonKey, token, item, signal, fetcher = fetch }) {
  let backend;
  try { backend = new URL(backendURL); } catch { fail('reader_configuration'); }
  if (backend.protocol !== 'https:' || backend.username || backend.password || backend.search || backend.hash || backend.pathname !== '/') fail('reader_configuration');
  if (!item || ![item.id, item.document_id, item.artifact_id].every(uuid)) fail('reader_expected_identity');
  const headers = async () => {
    let bearer;
    try { bearer = await token(); } catch { fail('reader_authentication_failed'); }
    return { apikey: anonKey, Authorization: `Bearer ${bearer}`, 'Accept-Encoding': 'identity' };
  };
  const url = new URL('/functions/v1/reader-artifact', backend);
  url.searchParams.set('item_id', item.id); url.searchParams.set('transport', 'bounded-v1');
  const received = await request(fetcher, url, await headers(), deadline(30_000, signal), 1_048_576, undefined, 'reader-artifact');
  if (received.response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') fail('reader_descriptor_type');
  let value;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(received.bytes)); } catch { fail('reader_descriptor_invalid'); }
  const verified = validateReaderDescriptor(value, item, backend.origin);
  let bytes = 0;
  for (const member of verified.members) {
    const auth = verified.transport === 'bounded-v1' ? await headers() : { 'Accept-Encoding': 'identity' };
    const result = await request(fetcher, member.url, auth, deadline(60_000, signal), member.bytes, member.bytes, 'reader-member');
    const servedType = result.response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
    // The standard hosted Edge gateway rewrites GET text/html to text/plain:
    // https://supabase.com/docs/guides/functions/http-methods
    // This one downgrade is transport-only. The trusted manifest remains HTML;
    // exact identity, hashes, bytes, no-store and nosniff still apply below.
    const hostedHTML = verified.transport === 'bounded-v1' && /^[a-z]{20}\.supabase\.co$/.test(backend.hostname)
      && !backend.port && member.media_type === 'text/html' && servedType === 'text/plain';
    if (servedType !== member.media_type && !hostedHTML) fail('reader_member_type');
    const cache = result.response.headers.get('cache-control')?.toLowerCase().split(',').map(value => value.trim()) ?? [];
    // Hosted gateways may omit Content-Length on streamed responses. readBounded
    // still requires the exact manifest length and validates any declared length;
    // the hash below verifies every byte. Missing framing metadata is not bad data.
    if (verified.transport === 'bounded-v1' && (cache.length !== 2 || !cache.includes('private') || !cache.includes('no-store')
      || result.response.headers.get('x-content-type-options')?.toLowerCase() !== 'nosniff'
      || result.response.headers.get('referrer-policy')?.toLowerCase() !== 'no-referrer')) fail('reader_member_response_contract');
    if (hash(result.bytes) !== member.sha256) fail('reader_member_integrity');
    bytes += result.bytes.length;
  }
  return { members: verified.members.length, bytes, transport: verified.transport };
}
