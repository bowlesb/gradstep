// Library protocol format 2 (migrations 010/019/020/027/029/030) — a port of the native
// LibraryWire/LibraryReconciler (ScienceReaderCore). A page or response that fails any
// check is rejected whole; nothing partial is published.
import { canonicalJSON, isUUID } from './bytes';
import { BackendError, rpc } from './backend';

export const FORMAT = 2, PAGE_LIMIT = 100, MAX_PAGE_BYTES = 1_048_576, MAX_ENTRIES = 4_000;

export interface Metadata { title: string; authors: string[]; abstract?: string; published_at?: string; updated_at?: string; categories: string[]; venue?: string }
export interface ProgressDetail { step: string; percent: number; eta_seconds?: number; delayed: boolean; pages?: number; pages_done?: number; bytes?: number }

export interface Item {
  kind: 'item'; id: string; document_id: string; created_seq: number; state_seq: number; membership_revision: number; visible: boolean;
  added_at: number; last_remove_seq: number; approval_id?: string; version_id?: string; metadata_id?: string; source?: string; source_id?: string;
  source_revision?: number; metadata?: Metadata; metadata_recorded_at?: number; source_url?: string; scope: 'shared_catalog' | 'owner_private';
  page_count: number; original_object_id?: string; artifact_id?: string; readiness: string; original_availability?: string; render_availability?: string;
  original_availability_revision?: number; render_availability_revision?: number; archived?: boolean; tags?: string[]; user_tags?: string[]; hidden_tags?: string[];
}
export interface Import {
  kind: 'import'; id: string; created_seq: number; state_seq: number; intent_revision: number; visible: boolean; phase: string; source: string;
  source_id: string; requested_revision?: number; source_revision?: number; metadata_id?: string; version_id?: string; metadata?: Metadata;
  metadata_recorded_at?: number; source_url: string; document_id?: string; library_item_id?: string; error_code?: string; retryable: boolean;
  progress?: string; progress_detail?: ProgressDetail;
}
export type Entry = Item | Import;

export class ProtocolError extends Error {}
const fail = (what: string): never => { throw new ProtocolError(what); };

// ---------- Decoding and validation ----------

const scalars = (s: string) => [...s].length;
const bounded = (v: unknown, max: number, min = 0): v is string => typeof v === 'string' && scalars(v) >= min && scalars(v) <= max;
const int = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);
const revision = (v: unknown) => int(v) && v > 0 && v <= 2_147_483_647;
const absent = (v: unknown) => v === undefined || v === null;
const opt = <T>(v: T | null | undefined): T | undefined => (v === null ? undefined : v);

function calendarDate(value: string): boolean {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) return false;
  const [y, m, d] = value.split('-').map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  return y > 0 && date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
}
function timestamp(v: unknown): number {
  if (typeof v !== 'string' || v.length > 64) return fail('entry');
  const ms = Date.parse(v as string);
  return Number.isFinite(ms) && /^\d{4}-\d{2}-\d{2}T/.test(v as string) ? ms : fail('entry');
}
function metadata(v: unknown): Metadata | undefined {
  if (absent(v)) return undefined;
  const m = v as Record<string, unknown>;
  if (typeof m !== 'object' || Array.isArray(m) || !Object.keys(m).every(k => ['title', 'authors', 'abstract', 'published_at', 'updated_at', 'categories', 'venue'].includes(k))
    || !bounded(m.title, 2000, 1) || !Array.isArray(m.authors) || m.authors.length > 512 || !m.authors.every(a => bounded(a, 256))
    || !Array.isArray(m.categories) || m.categories.length > 64 || !m.categories.every(c => bounded(c, 64))
    || !(absent(m.abstract) || bounded(m.abstract, 24_000)) || !(absent(m.venue) || bounded(m.venue, 1024))
    || !(absent(m.published_at) || (typeof m.published_at === 'string' && calendarDate(m.published_at)))
    || !(absent(m.updated_at) || (typeof m.updated_at === 'string' && calendarDate(m.updated_at)))
    || JSON.stringify(m).length > 32_768) return fail('metadata');
  return { title: m.title as string, authors: m.authors as string[], categories: m.categories as string[], abstract: opt(m.abstract as string),
    published_at: opt(m.published_at as string), updated_at: opt(m.updated_at as string), venue: opt(m.venue as string) };
}
function uuid(v: unknown, required = true): string | undefined {
  if (absent(v) && !required) return undefined;
  return isUUID(v) ? v.toLowerCase() : fail('entry');
}
const tagList = (v: unknown, max: number): string[] | undefined => {
  if (absent(v)) return undefined;
  return Array.isArray(v) && v.length > 0 && v.length <= max && v.every(t => bounded(t, 120, 1)) ? v as string[] : fail('entry');
};

export function isWebSourceID(value: string): boolean { return /^openalex:W[1-9][0-9]{0,14}$/.test(value); }
const arxivURL = (source: string, rev?: number) => 'https://arxiv.org/abs/' + source + (rev ? `v${rev}` : '');
function validHTTPS(value: string): boolean {
  if (!bounded(value, 512, 9) || !/^[\x21-\x7e]+$/.test(value)) return false;
  try { const u = new URL(value); return u.protocol === 'https:' && !!u.hostname && !u.username && !u.password; } catch { return false; }
}

function progressDetail(v: unknown): ProgressDetail | undefined {
  // Presentation only: never a reason to reject an entry (unknown steps kept, out-of-range values dropped).
  if (absent(v) || typeof v !== 'object' || Array.isArray(v)) return absent(v) ? undefined : { step: '', percent: 0, delayed: false };
  const d = v as Record<string, unknown>;
  const n = (x: unknown, lo: number, hi: number) => int(x) && x >= lo && x <= hi ? x : undefined;
  const pages = n(d.pages, 1, 250), done = n(d.pages_done, 0, 250);
  return { step: typeof d.step === 'string' && d.step.length <= 64 ? d.step : '', percent: n(d.percent, 0, 100) ?? 0, eta_seconds: n(d.eta_seconds, 0, 86_400),
    delayed: d.delayed === true, pages, pages_done: done !== undefined && (pages === undefined || done <= pages) ? done : undefined, bytes: n(d.bytes, 1, 67_108_864) };
}

export function decodeEntry(raw: unknown): Entry {
  const e = raw as Record<string, unknown>;
  if (!e || typeof e !== 'object') return fail('entry');
  if (e.kind === 'item') {
    const item: Item = {
      kind: 'item', id: uuid(e.id)!, document_id: uuid(e.document_id)!, created_seq: e.created_seq as number, state_seq: e.state_seq as number,
      membership_revision: e.membership_revision as number, visible: e.visible as boolean, added_at: timestamp(e.added_at), last_remove_seq: e.last_remove_seq as number,
      approval_id: uuid(e.approval_id, false), version_id: uuid(e.version_id, false), metadata_id: uuid(e.metadata_id, false),
      source: opt(e.source as string), source_id: opt(e.source_id as string), source_revision: opt(e.source_revision as number), metadata: metadata(e.metadata),
      metadata_recorded_at: absent(e.metadata_recorded_at) ? undefined : timestamp(e.metadata_recorded_at), source_url: opt(e.source_url as string),
      scope: e.scope as Item['scope'], page_count: e.page_count as number, original_object_id: uuid(e.original_object_id, false), artifact_id: uuid(e.artifact_id, false),
      readiness: e.readiness as string, original_availability: opt(e.original_availability as string), render_availability: opt(e.render_availability as string),
      original_availability_revision: opt(e.original_availability_revision as number), render_availability_revision: opt(e.render_availability_revision as number),
      archived: opt(e.archived as boolean), tags: tagList(e.tags, 16), user_tags: tagList(e.user_tags, 32), hidden_tags: tagList(e.hidden_tags, 16),
    };
    validateItem(item);
    return item;
  }
  if (e.kind === 'import') {
    const entry: Import = {
      kind: 'import', id: uuid(e.id)!, created_seq: e.created_seq as number, state_seq: e.state_seq as number, intent_revision: e.intent_revision as number,
      visible: e.visible as boolean, phase: e.phase as string, source: e.source as string, source_id: e.source_id as string,
      requested_revision: opt(e.requested_revision as number), source_revision: opt(e.source_revision as number), metadata_id: uuid(e.metadata_id, false),
      version_id: uuid(e.version_id, false), metadata: metadata(e.metadata), metadata_recorded_at: absent(e.metadata_recorded_at) ? undefined : timestamp(e.metadata_recorded_at),
      source_url: e.source_url as string, document_id: uuid(e.document_id, false), library_item_id: uuid(e.library_item_id, false),
      error_code: opt(e.error_code as string), retryable: e.retryable as boolean, progress: opt(e.progress as string), progress_detail: progressDetail(e.progress_detail),
    };
    validateImport(entry);
    return entry;
  }
  return fail('entry');
}

function validateItem(i: Item): void {
  const ok = int(i.created_seq) && i.created_seq > 0 && int(i.state_seq) && i.state_seq >= i.created_seq && int(i.membership_revision) && i.membership_revision > 0
    && int(i.last_remove_seq) && i.last_remove_seq >= 0 && i.last_remove_seq <= i.state_seq && typeof i.visible === 'boolean'
    && (i.original_availability_revision === undefined || (int(i.original_availability_revision) && i.original_availability_revision >= 0))
    && (i.render_availability_revision === undefined || (int(i.render_availability_revision) && i.render_availability_revision >= 0))
    && int(i.page_count) && i.page_count >= 1 && i.page_count <= 250 && (i.scope === 'shared_catalog' || i.scope === 'owner_private')
    && bounded(i.readiness, 64) && (i.archived === undefined || typeof i.archived === 'boolean')
    && [i.original_availability, i.render_availability].every(a => a === undefined || bounded(a, 64));
  if (!ok) fail('entry');
  if (!i.approval_id) {
    if (i.version_id || i.metadata_id || i.source || i.source_id || i.source_revision !== undefined || i.metadata || i.metadata_recorded_at !== undefined
      || i.source_url || i.original_object_id || i.readiness === 'pdf_ready' || i.readiness === 'converted_ready') fail('entry');
  } else {
    if (!i.version_id || !i.metadata_id || !i.source || !bounded(i.source_id, 128, 1) || !revision(i.source_revision) || !i.metadata
      || i.metadata_recorded_at === undefined || !i.original_object_id) fail('entry');
    const validSource = i.source === 'arxiv' ? i.source_url === arxivURL(i.source_id!, i.source_revision)
      : i.source === 'web' ? isWebSourceID(i.source_id!) && i.source_revision === 1 && !!i.source_url && validHTTPS(i.source_url) : false;
    if (!validSource || (i.readiness === 'converted_ready' && !i.artifact_id) || i.readiness === 'unverified') fail('entry');
  }
}

function validateImport(i: Import): void {
  const phases = ['accepted', 'resolving', 'acquiring', 'failed', 'ready', 'cancelled', 'source_only', 'membership_conflict'];
  const ok = int(i.created_seq) && i.created_seq > 0 && int(i.state_seq) && i.state_seq >= i.created_seq && int(i.intent_revision) && i.intent_revision > 0
    && typeof i.visible === 'boolean' && phases.includes(i.phase) && bounded(i.source_id, 128, 1) && typeof i.retryable === 'boolean'
    && (i.requested_revision === undefined || revision(i.requested_revision)) && (i.source_revision === undefined || revision(i.source_revision))
    && (i.document_id === undefined) === (i.library_item_id === undefined) && (!i.retryable || i.phase === 'failed')
    && (i.error_code === undefined || bounded(i.error_code, 64)) && (i.progress === undefined || bounded(i.progress, 64));
  if (!ok) fail('entry');
  const validSource = i.source === 'arxiv' ? i.source_url === arxivURL(i.source_id, i.source_revision ?? i.requested_revision)
    : i.source === 'web' ? isWebSourceID(i.source_id) && i.requested_revision === undefined && (i.source_revision ?? 1) === 1
      && i.source_url === 'https://openalex.org/works/' + i.source_id.slice('openalex:'.length) : false;
  if (!validSource) fail('entry');
  if (i.phase === 'ready' && (i.visible || !i.library_item_id)) fail('entry');
  if (i.phase === 'cancelled' && i.visible) fail('entry');
  if (!i.metadata_id) {
    if (i.version_id || i.source_revision !== undefined || i.metadata || i.metadata_recorded_at !== undefined) fail('entry');
  } else if (!i.version_id || i.source_revision === undefined || !i.metadata || i.metadata_recorded_at === undefined
    || (i.requested_revision !== undefined && i.requested_revision !== i.source_revision)) fail('entry');
}

export interface BaselineCursor { format: number; account_id: string; through: number; created_seq: number; id: string; kind: 'item' | 'import' }
interface BaselinePage { format: number; account_id: string; baseline_cursor: number; retained_after: number; entries: Entry[]; next_cursor: BaselineCursor | null; has_more: boolean }
interface ChangesPage { format: number; account_id: string; through: number; retained_after: number; changes: { seq: number; entries: Entry[] }[]; next_cursor: number; has_more: boolean }

const order = (seq: number, id: string, kind: string) => [seq, id, kind] as const;
const before = (a: readonly [number, string, string], b: readonly [number, string, string]) =>
  a[0] !== b[0] ? a[0] < b[0] : a[1] !== b[1] ? a[1] < b[1] : a[2] < b[2];
const entryKey = (e: Entry) => order(e.created_seq, e.id, e.kind);

function decodeBaseline(raw: unknown): BaselinePage {
  const p = raw as Record<string, unknown>;
  if (!p || p.format !== FORMAT) return fail('unsupported_format');
  if (!Array.isArray(p.entries) || p.entries.length > PAGE_LIMIT || !int(p.baseline_cursor) || p.baseline_cursor < 0 || !int(p.retained_after) || p.retained_after < 0) fail('page');
  if ((p.retained_after as number) > (p.baseline_cursor as number)) throw new BackendError('library_resync_required');
  const page: BaselinePage = { format: FORMAT, account_id: uuid(p.account_id)!, baseline_cursor: p.baseline_cursor as number, retained_after: p.retained_after as number,
    entries: (p.entries as unknown[]).map(decodeEntry), next_cursor: absent(p.next_cursor) ? null : p.next_cursor as BaselineCursor, has_more: p.has_more === true };
  if (page.entries.length === 0 !== (page.next_cursor === null) || (page.has_more && page.entries.length === 0)) fail('cursor');
  let previous: readonly [number, string, string] | null = null;
  for (const entry of page.entries) {
    const key = entryKey(entry);
    if (entry.created_seq > page.baseline_cursor || (previous && !before(previous, key))) fail('page');
    previous = key;
  }
  const c = page.next_cursor;
  if (c) {
    if (c.format !== FORMAT || !int(c.through) || !int(c.created_seq) || c.created_seq <= 0 || c.created_seq > c.through || !isUUID(c.id)
      || (c.kind !== 'item' && c.kind !== 'import') || uuid(c.account_id) !== page.account_id || c.through !== page.baseline_cursor) fail('cursor');
    page.next_cursor = { ...c, account_id: c.account_id.toLowerCase(), id: c.id.toLowerCase() };
    const k = order(c.created_seq, page.next_cursor.id, c.kind);
    if (!previous || canonicalJSON(previous) !== canonicalJSON(k)) fail('cursor');
  }
  return page;
}

function decodeChanges(raw: unknown): ChangesPage {
  const p = raw as Record<string, unknown>;
  if (!p || p.format !== FORMAT) return fail('unsupported_format');
  const through = p.through as number, retained = p.retained_after as number, next = p.next_cursor as number;
  if (!int(through) || through < 0 || !int(retained) || retained < 0 || retained > through || !int(next) || next < 0 || next > through
    || !Array.isArray(p.changes) || p.changes.length > PAGE_LIMIT) fail('page');
  let previous = 0;
  const changes = (p.changes as { seq: unknown; entries: unknown }[]).map(batch => {
    const seq = batch.seq as number;
    if (!int(seq) || seq <= previous || seq > through || !Array.isArray(batch.entries) || batch.entries.length < 1 || batch.entries.length > 4) fail('page');
    const entries = (batch.entries as unknown[]).map(decodeEntry);
    if (new Set(entries.map(e => e.kind + e.id)).size !== entries.length || entries.some(e => e.state_seq > seq)) fail('page');
    previous = seq;
    return { seq, entries };
  });
  const page: ChangesPage = { format: FORMAT, account_id: uuid(p.account_id)!, through, retained_after: retained, changes, next_cursor: next, has_more: p.has_more === true };
  if (page.has_more ? !(changes.length && next === changes[changes.length - 1].seq && next < through) : next !== through) fail('cursor');
  if (changes.length && changes[changes.length - 1].seq > next) fail('cursor');
  return page;
}

export interface CommandResponse { result: { status: 'applied' | 'revision_conflict'; kind: 'item' | 'import'; id?: string; seq?: number; revision: number }; replayed: boolean; entry?: Entry }
/** An accepted receipt still awaiting a complete read, not a reason to submit another mutation. */
export class CommandRefreshError extends BackendError {
  constructor(readonly response: CommandResponse) { super('library_refresh_pending'); }
}
export const receiptFloor = (response: CommandResponse) => Math.max(response.result.seq ?? 0, response.entry?.state_seq ?? 0);
function decodeCommand(raw: unknown): CommandResponse {
  const v = raw as Record<string, unknown>;
  const r = v?.result as Record<string, unknown>;
  if (!r || (r.status !== 'applied' && r.status !== 'revision_conflict') || (r.kind !== 'item' && r.kind !== 'import') || !int(r.revision) || r.revision < 0
    || !(absent(r.seq) || (int(r.seq) && r.seq > 0)) || JSON.stringify(r).length > 2048) fail('command');
  const result = { status: r.status as 'applied', kind: r.kind as 'item', id: uuid(r.id, false), seq: opt(r.seq as number), revision: r.revision as number };
  if (result.status === 'applied' && (!result.id || result.seq === undefined || result.revision <= 0)) fail('command');
  const entry = absent(v.entry) ? undefined : decodeEntry(v.entry);
  if (entry ? !(result.id && entry.kind === result.kind && entry.id === result.id && (result.seq === undefined || result.seq <= entry.state_seq)) : result.id) fail('command');
  return { result, replayed: v.replayed === true, entry };
}

// ---------- Reconciler ----------

function same(a: Entry, b: Entry): boolean { return canonicalJSON(a) === canonicalJSON(b); }
const preserves = <T>(old: T | undefined, next: T | undefined) => old === undefined || canonicalJSON(old) === canonicalJSON(next);
const advances = (old?: number, next?: number) => old === undefined || (next !== undefined && next >= old);

function validateIdentity(old: Entry, next: Entry): void {
  if (old.created_seq !== next.created_seq || old.kind !== next.kind) fail('identity');
  if (old.kind === 'item' && next.kind === 'item') {
    if (old.document_id !== next.document_id || old.scope !== next.scope || old.page_count !== next.page_count || old.added_at !== next.added_at) fail('identity');
    if (next.state_seq > old.state_seq && !(next.membership_revision >= old.membership_revision && next.last_remove_seq >= old.last_remove_seq
      && preserves(old.approval_id, next.approval_id) && preserves(old.version_id, next.version_id) && preserves(old.metadata_id, next.metadata_id)
      && preserves(old.source, next.source) && preserves(old.source_id, next.source_id) && preserves(old.source_revision, next.source_revision)
      && preserves(old.metadata, next.metadata) && preserves(old.metadata_recorded_at, next.metadata_recorded_at) && preserves(old.source_url, next.source_url)
      && preserves(old.original_object_id, next.original_object_id) && preserves(old.artifact_id, next.artifact_id)
      && advances(old.original_availability_revision, next.original_availability_revision) && advances(old.render_availability_revision, next.render_availability_revision))) fail('identity');
  } else if (old.kind === 'import' && next.kind === 'import') {
    if (old.source !== next.source || old.source_id !== next.source_id || old.requested_revision !== next.requested_revision
      || (old.library_item_id && next.library_item_id && old.library_item_id !== next.library_item_id)
      || (old.document_id && next.document_id && old.document_id !== next.document_id)) fail('identity');
    if (next.state_seq > old.state_seq && !(next.intent_revision >= old.intent_revision && preserves(old.metadata_id, next.metadata_id)
      && preserves(old.version_id, next.version_id) && preserves(old.source_revision, next.source_revision) && preserves(old.metadata, next.metadata)
      && preserves(old.metadata_recorded_at, next.metadata_recorded_at) && preserves(old.library_item_id, next.library_item_id)
      && preserves(old.document_id, next.document_id))) fail('identity');
  }
}

/** Baseline pages, then fixed-boundary catch-up; publishes only complete observations. Memory only. */
export class Reconciler {
  entries = new Map<string, Entry>();
  phase: 'baseline' | 'catching_up' | 'ready' = 'baseline';
  committed: number | null = null;
  private boundary: number | null = null;
  private continuation: BaselineCursor | null = null;
  private catchUpBoundary: number | null = null;

  constructor(readonly accountID: string) {}

  private merge(target: Map<string, Entry>, observations: Entry[]): void {
    for (const entry of observations) {
      const key = entry.kind + ':' + entry.id, old = target.get(key);
      if (old) {
        validateIdentity(old, entry);
        if (entry.state_seq < old.state_seq) continue;
        if (entry.state_seq === old.state_seq) { if (!same(entry, old)) fail('conflicting_revision'); continue; }
      }
      target.set(key, entry);
    }
    if (target.size > MAX_ENTRIES) fail('capacity');
    const documents = new Map<string, string>();
    for (const e of target.values()) if (e.kind === 'item') {
      const previous = documents.get(e.document_id);
      if (previous && previous !== e.id) fail('identity');
      documents.set(e.document_id, e.id);
    }
    for (const e of target.values()) if (e.kind === 'import' && e.library_item_id) {
      const item = target.get('item:' + e.library_item_id);
      if (item && item.kind === 'item' && item.document_id !== e.document_id) fail('identity');
    }
  }

  /** Pulls until a complete observation (bounded). Throws BackendError('library_resync_required') for the caller to reset. */
  async pull(signal?: AbortSignal, minimumCursor = 0, requireFreshBoundary = false): Promise<void> {
    let readFreshBoundary = false;
    this.prepareCatchUp();
    for (let pages = 0; pages < 256; pages++) {
      if (this.phase === 'baseline') {
        const raw = await rpc<unknown>('v3_library_page', { p_cursor: this.continuation, p_limit: PAGE_LIMIT }, { maximum: MAX_PAGE_BYTES, account: this.accountID, signal });
        signal?.throwIfAborted();
        const page = decodeBaseline(raw);
        if (page.account_id !== this.accountID) fail('account');
        if (this.boundary !== null && page.baseline_cursor !== this.boundary) fail('cursor');
        if (this.continuation && page.entries[0] && !before(order(this.continuation.created_seq, this.continuation.id, this.continuation.kind), entryKey(page.entries[0]))) fail('cursor');
        const next = new Map(this.entries);
        this.merge(next, page.entries);
        this.entries = next; this.boundary = page.baseline_cursor; this.continuation = page.next_cursor;
        if (!page.has_more) { this.committed = page.baseline_cursor; this.phase = 'catching_up'; this.catchUpBoundary = null; }
        continue;
      }
      const after = this.committed!;
      const raw = await rpc<unknown>('v3_library_changes', { p_after: after, p_through: this.catchUpBoundary, p_limit: PAGE_LIMIT }, { maximum: MAX_PAGE_BYTES, account: this.accountID, signal });
      signal?.throwIfAborted();
      const page = decodeChanges(raw);
      if (page.account_id !== this.accountID) fail('account');
      if (page.retained_after > after) throw new BackendError('library_resync_required');
      if (page.through < after || (this.catchUpBoundary !== null && page.through !== this.catchUpBoundary)
        || (page.changes[0] && page.changes[0].seq <= after) || page.next_cursor < after || (page.has_more && page.next_cursor <= after)) fail('cursor');
      const next = new Map(this.entries);
      for (const batch of page.changes) this.merge(next, batch.entries);
      if (this.catchUpBoundary === null) readFreshBoundary = true;
      this.entries = next; this.committed = page.next_cursor;
      this.catchUpBoundary = page.has_more ? page.through : null;
      this.phase = 'catching_up';
      if (!page.has_more) {
        // A resumed fixed boundary can predate a receipt. Finish it, then ask for one fresh
        // boundary; a server still behind an acknowledged sequence must fail, never spin or jump.
        if (!readFreshBoundary && (requireFreshBoundary || this.committed < minimumCursor)) continue;
        if (this.committed < minimumCursor) fail('receipt_not_observed');
        // Baselines fix creation order, but return current rows. Some can be ahead of the
        // baseline cursor or refer to an item on a later page. Only catch-up establishes completeness.
        for (const entry of this.entries.values()) {
          if (entry.state_seq > this.committed) fail('incomplete_observation');
          if (entry.kind === 'import' && entry.library_item_id) {
            const item = this.entries.get('item:' + entry.library_item_id);
            if (!item || item.kind !== 'item' || item.document_id !== entry.document_id) fail('incomplete_observation');
          }
        }
        this.phase = 'ready'; return;
      }
    }
    fail('page_budget');
  }

  prepareCatchUp(): void { if (this.phase === 'ready') this.phase = 'catching_up'; }

  /** Confirm the target as well as the account cursor; this never merges response entries. */
  requireReceipt(response: CommandResponse): void {
    if (this.phase !== 'ready' || this.committed === null || this.committed < receiptFloor(response)) return fail('receipt_not_observed');
    const target = response.entry, observed = target && this.entries.get(target.kind + ':' + target.id);
    if (!target || !observed || observed.state_seq < target.state_seq) return fail('receipt_not_observed');
    const revision = observed.kind === 'import' ? observed.intent_revision : observed.membership_revision;
    if (revision < response.result.revision) return fail('receipt_not_observed');
    validateIdentity(target, observed);
    if (observed.state_seq === target.state_seq && !same(target, observed)) fail('conflicting_revision');
  }
}

// ---------- Commands (operation-ID replay makes a resend exactly-once) ----------

export type Command =
  | { endpoint: 'v2_begin_import'; p_source_id: string; p_requested_revision: number | null; p_observed_cursor: number }
  | { endpoint: 'v2_retry_import' | 'v2_cancel_import'; p_import_id: string; p_expected_revision: number };

export async function sendCommand(account: string, command: Command, operationID = crypto.randomUUID(), signal?: AbortSignal): Promise<CommandResponse> {
  const { endpoint, ...params } = command;
  let lastError: unknown;
  // One automatic resend of the identical request after a lost reply; the server replays its receipt.
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = decodeCommand(await rpc<unknown>(endpoint, { p_operation_id: operationID, ...params }, { maximum: MAX_PAGE_BYTES, account, signal }));
      const id = command.endpoint === 'v2_begin_import' ? operationID : command.p_import_id;
      const revision = command.endpoint === 'v2_begin_import' ? 1 : command.p_expected_revision + 1;
      const entry = response.entry;
      if (!entry || entry.kind !== 'import') return fail('command_binding');
      if (response.result.kind !== 'import' || response.result.id !== id
        || (response.result.status === 'applied' ? response.result.revision !== revision
          : command.endpoint === 'v2_begin_import' || response.result.seq !== undefined || response.result.revision <= 0 || response.result.revision === command.p_expected_revision)
        || entry.intent_revision < response.result.revision) fail('command_binding');
      if (command.endpoint === 'v2_begin_import' && (entry.source !== 'arxiv' || entry.source_id !== command.p_source_id
        || (entry.requested_revision ?? null) !== command.p_requested_revision)) fail('command_binding');
      return response;
    } catch (error) {
      lastError = error;
      if (!(error instanceof BackendError) || error.code !== 'connection') throw error;
    }
  }
  throw lastError;
}
