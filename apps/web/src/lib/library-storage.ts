// Encrypted, complete browser-library checkpoints (docs/architecture/BROWSER_LIBRARY_STORAGE.md).
//
// This module is deliberately independent of the live Reconciler and is not called by the UI yet.  It provides the
// gate-2 primitive that the v5 client will use once the server has an epoch-bound descriptor write contract: a sealed
// head authenticates the complete presentation checkpoint, and each immutable child row is sealed under its own AAD.
// Encryption happens before IndexedDB is opened; the final head compare-and-swap, child replacement and old-child
// cleanup are one transaction.  A missing or malformed child is a damaged checkpoint, never an empty library.
import { type Bytes, canonicalJSON, equal, fromUtf8, isUUID, sha256Hex, utf8, wireUUID } from './bytes';
import { decodeEntry, type Entry } from './library';
import { libraryAccess, StorageError, storage, type LibraryDeviceGuard, type LibraryPut, type LibraryRemove, type LibraryStore, type WriterFence } from './idb';
import { open, seal } from './wire';

export const LIBRARY_STORAGE_FORMAT = 1;
export const LIBRARY_STORAGE_LIMITS = {
  entries: 4_000,
  rowBytes: 64 * 1024,
  ciphertextBytes: 256 * 1024 * 1024,
  headBytes: 2 * 1024 * 1024,
  cursorBytes: 16 * 1024,
} as const;

export type LibraryStorageErrorCode = 'library_inactive' | 'library_newer' | 'library_damaged' | 'library_scope'
  | 'library_conflict' | 'library_fenced' | 'library_capacity' | 'library_quota' | 'library_unavailable' | 'library_unsupported'
  | 'library_invalid';
export class LibraryStorageError extends Error { constructor(readonly code: LibraryStorageErrorCode) { super(code); } }

/** The prepared local key and admission fence from keys.ts.  No key bytes are accepted by this API. */
export interface LibraryStorageScope {
  origin: string;
  environment: string;
  account: string;
  deviceKey: string;
  deviceID: string;
  localKey: CryptoKey;
  fence: WriterFence;
  current: () => boolean;
}

export interface LibraryCheckpoint {
  entries: Entry[];
  cursor: unknown;
  datasetEpoch: string;
  revision: number;
  checkpointID: string;
  /** The exact sealed head, useful to a caller that wants to publish a local revision hint. */
  headCiphertext: Bytes;
}

interface RowRef { kind: Entry['kind']; id: string; key: string; digest: string; bytes: number }
interface Head {
  format: 1; minReader: 1; minWriter: 1;
  origin: string; environment: string; account: string; incarnation: string; device: string; generation: number;
  dataset_epoch: string; cursor: unknown; revision: number; checkpoint: string;
  rows: RowRef[]; count: number; charged_bytes: number;
}

interface Domain { prefix: string; head: string; originDigest: string; account: string }

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const MAX_INT = 2_147_483_647;
const rowKinds: readonly Entry['kind'][] = ['item', 'import'];
const rowKey = (domain: Domain, checkpoint: string, kind: Entry['kind'], id: string) => `${domain.prefix}${checkpoint}:row:${kind}:${id}`;
const range = (domain: Domain) => [domain.prefix, `${domain.prefix}\uffff`] as const;
const keysFor = (domain: Domain, head: Head) => head.rows.map(row => row.key);

function fail(code: LibraryStorageErrorCode): never { throw new LibraryStorageError(code); }
function exactFields(value: unknown, required: readonly string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return fail('library_damaged');
  const fields = Object.keys(value);
  if (fields.length !== required.length || required.some(field => !fields.includes(field))) return fail('library_damaged');
  return value as Record<string, unknown>;
}
function canonicalBytes(value: unknown, code: LibraryStorageErrorCode): Bytes {
  try {
    const text = canonicalJSON(value);
    if (typeof text !== 'string') return fail(code);
    return utf8(text);
  } catch { return fail(code); }
}
function parseCanonical(bytes: Bytes, code: LibraryStorageErrorCode): unknown {
  let text: string, value: unknown;
  try { text = fromUtf8(bytes); value = JSON.parse(text); } catch { return fail(code); }
  if (canonicalJSON(value) !== text) return fail(code);
  return value;
}
function uuid(value: unknown, code: LibraryStorageErrorCode): string {
  if (typeof value !== 'string' || !ID.test(value)) return fail(code);
  return value.toLowerCase();
}
function positiveInt(value: unknown, code: LibraryStorageErrorCode, zero = false): number {
  if (!Number.isSafeInteger(value) || (zero ? (value as number) < 0 : (value as number) < 1) || (value as number) > MAX_INT) return fail(code);
  return value as number;
}
function validKey(key: CryptoKey): boolean {
  return key.type === 'secret' && key.extractable === false && key.algorithm.name === 'AES-GCM'
    && key.usages.includes('encrypt') && key.usages.includes('decrypt');
}
function checkScope(scope: LibraryStorageScope): string {
  if (!scope || typeof scope.origin !== 'string' || scope.origin.length < 1 || scope.origin.length > 2_048
    || typeof scope.environment !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(scope.environment)
    || typeof scope.deviceKey !== 'string' || scope.deviceKey.length < 1 || scope.deviceKey.length > 256
    || typeof scope.deviceID !== 'string' || !ID.test(scope.deviceID) || !validKey(scope.localKey)
    || typeof scope.current !== 'function' || !scope.fence || scope.fence.key !== scope.deviceKey
    || scope.fence.origin !== scope.origin || !ID.test(scope.fence.incarnation) || !ID.test(scope.fence.writer)
    || !Number.isSafeInteger(scope.fence.generation) || scope.fence.generation < 1) return fail('library_scope');
  let account: string;
  try { account = wireUUID(scope.account); } catch { return fail('library_scope'); }
  if (!scope.origin.startsWith('https://') && !scope.origin.startsWith('http://')) return fail('library_scope');
  return account;
}

async function domain(scope: LibraryStorageScope): Promise<Domain> {
  const account = checkScope(scope);
  // The exact backend URL is never exposed as a public IndexedDB key.  It is still included in AAD below.
  const originDigest = await sha256Hex(utf8(scope.origin));
  const prefix = `${scope.environment}:${account}:library:${originDigest}:`;
  return { prefix, head: `${prefix}head`, originDigest, account };
}

const headAAD = (scope: LibraryStorageScope, d: Domain) => utf8(
  `science-reader/browser-library/v1/head\n${scope.origin}\n${scope.environment}\n${d.account}\n${d.originDigest}\n${scope.fence.incarnation}\n${scope.deviceID}\n1\n`);
const rowAAD = (scope: LibraryStorageScope, d: Domain, checkpoint: string, kind: Entry['kind'], id: string) => utf8(
  `science-reader/browser-library/v1/row\n${scope.origin}\n${scope.environment}\n${d.account}\n${d.originDigest}\n${scope.fence.incarnation}\n${scope.deviceID}\n${checkpoint}\n${kind}\n${id}\n1\n`);

function mapStorageError(error: unknown): never {
  if (error instanceof LibraryStorageError) throw error;
  if (error instanceof StorageError) {
    if (error.code === 'storage_quota') return fail('library_quota');
    if (error.code === 'storage_upgraded') return fail('library_newer');
    return fail('library_unavailable');
  }
  return fail('library_unavailable');
}

async function ensureReady(): Promise<void> {
  try { if (!await storage.libraryReady()) fail('library_inactive'); }
  catch (error) { mapStorageError(error); }
}

function validateRowRef(value: unknown, domain: Domain, checkpoint: string): RowRef {
  const row = exactFields(value, ['kind', 'id', 'key', 'digest', 'bytes']);
  const kind = row.kind;
  if (!rowKinds.includes(kind as Entry['kind'])) return fail('library_damaged');
  const id = uuid(row.id, 'library_damaged');
  const key = row.key;
  if (typeof key !== 'string' || key !== rowKey(domain, checkpoint, kind as Entry['kind'], id)) return fail('library_damaged');
  if (typeof row.digest !== 'string' || !HEX64.test(row.digest)) return fail('library_damaged');
  const bytes = positiveInt(row.bytes, 'library_damaged');
  if (bytes < 28 || bytes > 16 * 1024 * 1024) return fail('library_damaged');
  return { kind: kind as Entry['kind'], id, key, digest: row.digest, bytes };
}

function validateHead(value: unknown, scope: LibraryStorageScope, d: Domain): Head {
  const h = exactFields(value, ['format', 'minReader', 'minWriter', 'origin', 'environment', 'account', 'incarnation', 'device', 'generation',
    'dataset_epoch', 'cursor', 'revision', 'checkpoint', 'rows', 'count', 'charged_bytes']);
  if (h.format !== LIBRARY_STORAGE_FORMAT || h.minReader !== 1 || h.minWriter !== 1) {
    if (typeof h.format === 'number' && h.format > LIBRARY_STORAGE_FORMAT) return fail('library_newer');
    return fail('library_damaged');
  }
  if (h.origin !== scope.origin || h.environment !== scope.environment || h.account !== d.account || h.incarnation !== scope.fence.incarnation
    || h.device !== scope.deviceID) return fail('library_scope');
  const generation = positiveInt(h.generation, 'library_scope');
  if (generation > scope.fence.generation) return fail('library_scope');
  const datasetEpoch = uuid(h.dataset_epoch, 'library_damaged');
  const checkpoint = uuid(h.checkpoint, 'library_damaged');
  const revision = positiveInt(h.revision, 'library_damaged');
  const cursorBytes = canonicalBytes(h.cursor, 'library_damaged');
  if (cursorBytes.length > LIBRARY_STORAGE_LIMITS.cursorBytes) return fail('library_damaged');
  if (!Array.isArray(h.rows) || h.rows.length > LIBRARY_STORAGE_LIMITS.entries || h.count !== h.rows.length) return fail('library_damaged');
  const rows = h.rows.map(row => validateRowRef(row, d, checkpoint));
  if (new Set(rows.map(row => `${row.kind}:${row.id}`)).size !== rows.length || new Set(rows.map(row => row.key)).size !== rows.length)
    return fail('library_damaged');
  const charged = rows.reduce((sum, row) => sum + row.bytes, 0);
  if (h.charged_bytes !== charged || !Number.isSafeInteger(charged) || charged > LIBRARY_STORAGE_LIMITS.ciphertextBytes) return fail('library_damaged');
  return { format: 1, minReader: 1, minWriter: 1, origin: scope.origin, environment: scope.environment, account: d.account,
    incarnation: scope.fence.incarnation, device: scope.deviceID, generation, dataset_epoch: datasetEpoch, cursor: h.cursor,
    revision, checkpoint, rows, count: rows.length, charged_bytes: charged };
}

async function openHead(sealed: Bytes, scope: LibraryStorageScope, d: Domain): Promise<Head> {
  if (sealed.length < 28 || sealed.length > LIBRARY_STORAGE_LIMITS.headBytes) return fail('library_damaged');
  let plain: Bytes;
  try { plain = await open(scope.localKey, sealed, headAAD(scope, d)); } catch { return fail('library_damaged'); }
  return validateHead(parseCanonical(plain, 'library_damaged'), scope, d);
}

async function readHead(scope: LibraryStorageScope, d: Domain): Promise<{ sealed: Bytes; head: Head } | null> {
  let values: (Bytes | undefined)[];
  try { values = await libraryAccess.read([{ store: 'library', key: d.head }]); } catch (error) { mapStorageError(error); }
  const sealed = values![0];
  if (!sealed) return null;
  return { sealed, head: await openHead(sealed, scope, d) };
}

async function noOrphans(d: Domain): Promise<void> {
  let found: string[];
  try { found = await libraryAccess.keys('library', ...range(d), LIBRARY_STORAGE_LIMITS.entries); } catch (error) { mapStorageError(error); }
  if (found!.length > 0) fail('library_damaged');
}

function guard(scope: LibraryStorageScope): LibraryDeviceGuard {
  return { key: scope.deviceKey, deviceID: scope.deviceID, fence: scope.fence, current: scope.current };
}

function normalizeEntries(entries: readonly Entry[]): Entry[] {
  if (!Array.isArray(entries) || entries.length > LIBRARY_STORAGE_LIMITS.entries) return fail('library_capacity');
  const out: Entry[] = [];
  const seen = new Set<string>();
  for (const value of entries) {
    let normalized: Entry;
    try { normalized = decodeEntry(JSON.parse(canonicalJSON(value))); } catch { return fail('library_invalid'); }
    const identity = `${normalized.kind}:${normalized.id}`;
    if (seen.has(identity)) return fail('library_invalid');
    seen.add(identity); out.push(normalized);
  }
  return out;
}

// The live library decoder exposes timestamps as epoch milliseconds, while the server wire page carries ISO text.
// Persist the canonical wire spelling so a reload can run the same strict decoder and produce the same Entry value.
function wireEntry(entry: Entry): Record<string, unknown> {
  const value = { ...entry } as Record<string, unknown>;
  const date = (milliseconds: unknown): string => {
    if (typeof milliseconds !== 'number' || !Number.isFinite(milliseconds)) throw new Error('timestamp');
    const text = new Date(milliseconds).toISOString();
    if (!/^\d{4}-\d{2}-\d{2}T/.test(text)) throw new Error('timestamp');
    return text;
  };
  if (Object.hasOwn(value, 'added_at')) value.added_at = date(value.added_at);
  if (Object.hasOwn(value, 'metadata_recorded_at') && value.metadata_recorded_at !== undefined) value.metadata_recorded_at = date(value.metadata_recorded_at);
  return value;
}
function rowPayload(entry: Entry) { return { format: 1, kind: entry.kind, id: entry.id, entry: wireEntry(entry) }; }

async function sealRows(entries: Entry[], scope: LibraryStorageScope, d: Domain, checkpoint: string): Promise<{ refs: RowRef[]; put: LibraryPut[] }> {
  const refs: RowRef[] = [], put: LibraryPut[] = [];
  let charged = 0;
  for (const entry of entries) {
    let plain: Bytes;
    try { plain = canonicalBytes(rowPayload(entry), 'library_invalid'); } catch (error) {
      if (error instanceof LibraryStorageError) throw error;
      return fail('library_invalid');
    }
    if (plain.length > LIBRARY_STORAGE_LIMITS.rowBytes) return fail('library_capacity');
    let sealed: Bytes;
    try { sealed = await seal(scope.localKey, plain, rowAAD(scope, d, checkpoint, entry.kind, entry.id)); } catch { return fail('library_unavailable'); }
    if (sealed.length > 16 * 1024 * 1024) return fail('library_capacity');
    charged += sealed.length;
    if (charged > LIBRARY_STORAGE_LIMITS.ciphertextBytes) return fail('library_capacity');
    const key = rowKey(d, checkpoint, entry.kind, entry.id);
    refs.push({ kind: entry.kind, id: entry.id, key, digest: await sha256Hex(sealed), bytes: sealed.length });
    put.push({ store: 'library', key, value: sealed });
  }
  return { refs, put };
}

async function openRow(sealed: Bytes, ref: RowRef, scope: LibraryStorageScope, d: Domain, checkpoint: string): Promise<Entry> {
  if (sealed.length !== ref.bytes || sealed.length < 28 || sealed.length > 16 * 1024 * 1024) return fail('library_damaged');
  try { if (await sha256Hex(sealed) !== ref.digest) return fail('library_damaged'); } catch { return fail('library_damaged'); }
  let plain: Bytes;
  try { plain = await open(scope.localKey, sealed, rowAAD(scope, d, checkpoint, ref.kind, ref.id)); } catch { return fail('library_damaged'); }
  const value = parseCanonical(plain, 'library_damaged');
  const row = exactFields(value, ['format', 'kind', 'id', 'entry']);
  if (row.format !== 1 || row.kind !== ref.kind || row.id !== ref.id) return fail('library_damaged');
  let entry: Entry;
  try { entry = decodeEntry(row.entry); } catch { return fail('library_damaged'); }
  if (entry.kind !== ref.kind || entry.id !== ref.id || canonicalJSON(row.entry) !== canonicalJSON(wireEntry(entry))) return fail('library_damaged');
  return entry;
}

/** Reads the current complete checkpoint. It retries once if a writer replaces the head between the two read transactions. */
export async function loadLibraryCheckpoint(scope: LibraryStorageScope): Promise<LibraryCheckpoint | null> {
  await ensureReady();
  if (!scope.current()) fail('library_fenced');
  const d = await domain(scope);
  for (let attempt = 0; attempt < 2; attempt++) {
    const current = await readHead(scope, d);
    if (!current) { await noOrphans(d); if (!scope.current()) fail('library_fenced'); return null; }
    const requests = [{ store: 'library' as LibraryStore, key: d.head }, ...keysFor(d, current.head).map(key => ({ store: 'library' as LibraryStore, key }))];
    let values: (Bytes | undefined)[];
    try { values = await libraryAccess.read(requests); } catch (error) { mapStorageError(error); }
    if (!values![0] || !equal(values![0]!, current.sealed)) continue;
    const children = values!.slice(1), entries: Entry[] = [];
    // Open sequentially. A full checkpoint is allowed to be large, but one malformed child must not make the
    // browser hold every plaintext row in a second Promise.all allocation while it is being verified.
    for (let i = 0; i < current.head.rows.length; i++) {
      const child = children[i];
      if (!child) fail('library_damaged');
      entries.push(await openRow(child, current.head.rows[i], scope, d, current.head.checkpoint));
    }
    if (!scope.current()) fail('library_fenced');
    if (!scope.current()) fail('library_fenced');
    const total = current.head.rows.reduce((sum, row) => sum + row.bytes, 0);
    if (total !== current.head.charged_bytes || entries.length !== current.head.count) fail('library_damaged');
    return { entries, cursor: current.head.cursor, datasetEpoch: current.head.dataset_epoch, revision: current.head.revision,
      checkpointID: current.head.checkpoint, headCiphertext: current.sealed.slice() as Bytes };
  }
  fail('library_conflict');
}

/** Stores a complete v5 presentation checkpoint. The UI must remain on the legacy Reconciler until this is wired to a server epoch. */
export async function saveLibraryCheckpoint(scope: LibraryStorageScope, entries: readonly Entry[], cursor: unknown, datasetEpoch: string): Promise<LibraryCheckpoint> {
  await ensureReady();
  if (!scope.current()) fail('library_fenced');
  const d = await domain(scope);
  const normalized = normalizeEntries(entries);
  const epoch = (() => { try { return wireUUID(datasetEpoch); } catch { return fail('library_invalid'); } })();
  const cursorBytes = canonicalBytes(cursor, 'library_invalid');
  if (cursorBytes.length > LIBRARY_STORAGE_LIMITS.cursorBytes) return fail('library_capacity');
  const previous = await readHead(scope, d);
  if (!previous) await noOrphans(d);
  const checkpoint = crypto.randomUUID().toLowerCase();
  const rows = await sealRows(normalized, scope, d, checkpoint);
  const head: Head = {
    format: 1, minReader: 1, minWriter: 1, origin: scope.origin, environment: scope.environment, account: d.account,
    incarnation: scope.fence.incarnation, device: scope.deviceID, generation: scope.fence.generation, dataset_epoch: epoch,
    cursor, revision: (previous?.head.revision ?? 0) + 1, checkpoint, rows: rows.refs, count: rows.refs.length,
    charged_bytes: rows.refs.reduce((sum, row) => sum + row.bytes, 0),
  };
  const headPlain = canonicalBytes(head, 'library_invalid');
  let sealedHead: Bytes;
  try { sealedHead = await seal(scope.localKey, headPlain, headAAD(scope, d)); } catch { return fail('library_unavailable'); }
  if (sealedHead.length > LIBRARY_STORAGE_LIMITS.headBytes || sealedHead.length + head.charged_bytes > LIBRARY_STORAGE_LIMITS.ciphertextBytes)
    return fail('library_capacity');
  const remove: LibraryRemove[] = (previous?.head.rows ?? []).map(row => ({ store: 'library', key: row.key }));
  const put: LibraryPut[] = [...rows.put, { store: 'library', key: d.head, value: sealedHead }];
  let result: 'committed' | 'conflict' | 'fenced';
  try {
    result = await libraryAccess.commit([{ store: 'library', key: d.head, expected: previous?.sealed ?? null }], put, remove, guard(scope));
  } catch (error) { mapStorageError(error); }
  if (result! === 'conflict') return fail('library_conflict');
  if (result! === 'fenced') return fail('library_fenced');
  return { entries: normalized, cursor, datasetEpoch: epoch, revision: head.revision, checkpointID: checkpoint, headCiphertext: sealedHead };
}

