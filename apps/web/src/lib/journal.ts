// The durable encrypted private journal (docs/architecture/BROWSER_OFFLINE_STORAGE.md, delivery gate 1).
//
// One account-scoped partition in the `gradstep` IndexedDB database (version 2, store `journal`) holds:
// - an authenticated head: scope (backend origin, environment, account, random incarnation, author device), the
//   admitted login lifetime, a revision, the complete pull cursor, the ordered outbox, local rebase mappings, a
//   SHA-256 hash chain over every event record and digest manifests of the draft and active-turn records;
// - immutable event records: each exact wire envelope (server-pulled or authored here), sealed again;
// - draft checkpoints with submission receipts and discard tombstones; active-turn checkpoints (partial answers).
//
// Every record is AES-GCM sealed with this browser's non-extractable local key (the device record's `localKey`) under
// domain-separated authenticated data that binds its kind, account, incarnation and identity. Public IDB keys contain
// only the environment label, the account UUID, the incarnation, ordinals and random composer/turn IDs.
//
// Writers serialize on a per-account Web Lock and never hold it over network requests. Encryption happens outside the
// IndexedDB transaction; the transaction compares the exact stored head bytes it planned from (compare-and-swap) and
// commits records and the replacement head together. Success is published on transaction completion only. A missing,
// substituted, reordered or undecryptable record is a damaged journal: it stops private writes and is never treated as
// an empty account. Formats newer than this release are preserved and refused with an update instruction.
import { type Bytes, concat, equal, fromUtf8, sha256, toHex, utf8 } from './bytes';
import { type JournalAccess, type WriterFence, journalAccess, idb } from './idb';
import { type EventEnvelope, open, seal } from './wire';

export const JOURNAL_FORMAT = 1;
export const JOURNAL_LIMITS = {
  events: 21_000, historyBytes: 96 * 1024 * 1024, outbox: 128, replaced: 1_000,
  draftRecords: 1_024, nonemptyDrafts: 128, draftText: 200_000, draftBytes: 8 * 1024 * 1024, recordBytes: 262_144 + 4_096,
  turns: 3, turnText: 200_000,
};

export type JournalErrorCode = 'journal_inactive' | 'journal_newer' | 'journal_damaged' | 'journal_scope' | 'journal_conflict'
  | 'journal_capacity' | 'journal_quota' | 'journal_retired' | 'journal_unavailable' | 'journal_unsupported' | 'journal_stale' | 'journal_discarded';
export class JournalError extends Error { constructor(readonly code: JournalErrorCode) { super(code); } }

/** A composer checkpoint (the native LocalDraft, simplified to one owning tab per composer). */
export interface StoredDraft {
  id: string; documentID: string | null; conversationID: string | null; head: string | null;
  /** Monotonic per composer. Each edit also gets a fresh `textRevision`, even when the text repeats. */
  revision: number; textRevision: string; text: string; editedAt: number;
  branchRevision: string; acknowledgedSubmissionID: string | null;
  /** The last local submission: its user event is `submissionID`; it consumed text revision `textRevision`. */
  receipt: { submissionID: string; eventIDs: string[]; textRevision: string; revision: number; branchRevision: string } | null;
  discarded: boolean;
}
/** A paid answer in progress. Persisted before the request; retired atomically with its final or interrupted events. */
export interface StoredTurn {
  id: string; entityID: string; composerID: string; conversationID: string; documentID: string | null; questionID: string;
  operationID: string; requestDigest: string; text: string; startedAt: number; updatedAt: number;
}
export interface LoadedEvent { ordinal: number; envelope: EventEnvelope; local: boolean }
export interface JournalSnapshot {
  events: LoadedEvent[]; cursor: number; outbox: string[]; replaced: Map<string, string>;
  drafts: StoredDraft[]; turns: StoredTurn[]; device: string;
}
/** Changes another tab committed since this tab's last view. */
export interface JournalDelta { events: LoadedEvent[]; cursor: number; outbox: string[]; replaced: Map<string, string> }

interface Head {
  format: number; minReader: number;
  origin: string; environment: string; account: string; incarnation: string; device: string;
  lifetime: string | null; generation: number; writer: string; revision: number;
  count: number; chain: string; historyBytes: number; cursor: number;
  outbox: string[]; replaced: [string, string][];
  drafts: Record<string, { digest: string; bytes: number; text: number; live: boolean }>;
  turns: Record<string, { digest: string; bytes: number }>;
}
interface Plan { next: Head; put: [string, Bytes][]; remove: string[]; committed?: () => void }

export interface JournalScope { origin: string; environment: string; account: string; deviceKey: string; deviceID: string; localKey: CryptoKey; lifetime: string;
  fence: WriterFence; current: () => boolean }
export interface JournalDependencies {
  /** Serializes writers across tabs. Required: there is no unconstrained fallback. */
  lock: <T>(name: string, body: () => Promise<T>) => Promise<T>;
  access: JournalAccess;
  /** Invalidation hints between tabs (no private text). Optional. */
  channel?: (name: string) => { post: (value: unknown) => void; listen: (listener: (value: unknown) => void) => () => void; close: () => void } | null;
}

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const uuid = (v: unknown): v is string => typeof v === 'string' && ID.test(v);
const bytesOf = (s: string) => utf8(s).length;
const pad = (n: number) => n.toString().padStart(10, '0');
export const journalPrefix = (environment: string, account: string, origin: string) => `${environment}:${account}:journal:${encodeURIComponent(origin)}:`;
const keys = (environment: string, account: string, origin: string, incarnation: string) => {
  const prefix = journalPrefix(environment, account, origin);
  return {
    head: prefix + 'head',
    event: (ordinal: number) => `${prefix}${incarnation}:e:${pad(ordinal)}`,
    draft: (id: string) => `${prefix}${incarnation}:d:${id}`,
    turn: (id: string) => `${prefix}${incarnation}:t:${id}`,
    events: [`${prefix}${incarnation}:e:`, `${prefix}${incarnation}:e:\uffff`] as const,
  };
};
const aad = {
  head: (environment: string, account: string, origin: string) => utf8(`gradstep/web-journal/v1/head\n${environment}\n${account}\n${origin}\n`),
  event: (account: string, incarnation: string, ordinal: number) => utf8(`gradstep/web-journal/v1/event\n${account}\n${incarnation}\n${ordinal}\n`),
  draft: (account: string, incarnation: string, id: string) => utf8(`gradstep/web-journal/v1/draft\n${account}\n${incarnation}\n${id}\n`),
  turn: (account: string, incarnation: string, id: string) => utf8(`gradstep/web-journal/v1/turn\n${account}\n${incarnation}\n${id}\n`),
};
const chainStart = async (account: string, incarnation: string) => toHex(await sha256(utf8(`gradstep/web-journal/v1/chain\n${account}\n${incarnation}\n`)));
async function chainNext(previous: string, sealed: Bytes): Promise<string> {
  const prev = new Uint8Array(previous.match(/../g)!.map(h => parseInt(h, 16)));
  return toHex(await sha256(concat(prev, await sha256(sealed))));
}
const digest = async (sealed: Bytes) => toHex(await sha256(sealed));
const damaged = (): never => { throw new JournalError('journal_damaged'); };

// Event record plaintext: u32 header length, header JSON, then the exact wire ciphertext (no base64 wrapping).
function encodeEvent(event: LoadedEvent): Bytes {
  const header = utf8(JSON.stringify({ id: event.envelope.id, device: event.envelope.deviceID, epoch: event.envelope.epoch,
    format: event.envelope.format, local: event.local }));
  const length = new Uint8Array(4); new DataView(length.buffer).setUint32(0, header.length);
  return concat(length, header, event.envelope.ciphertext);
}
function decodeEvent(plain: Bytes, ordinal: number): LoadedEvent {
  if (plain.length < 4) damaged();
  const length = new DataView(plain.buffer, plain.byteOffset).getUint32(0);
  if (length > 1024 || plain.length < 4 + length + 28) damaged();
  let h: Record<string, unknown>;
  try { h = JSON.parse(fromUtf8(plain.subarray(4, 4 + length))) as Record<string, unknown>; } catch { return damaged(); }
  if (!uuid(h.id) || !uuid(h.device) || !Number.isSafeInteger(h.epoch) || (h.epoch as number) <= 0 || h.format !== 1 || typeof h.local !== 'boolean') damaged();
  return { ordinal, local: h.local as boolean, envelope: { id: h.id as string, deviceID: h.device as string, epoch: h.epoch as number, format: 1,
    ciphertext: plain.slice(4 + length) } };
}
function validDraft(d: StoredDraft, id: string): StoredDraft {
  const optionalID = (v: unknown) => v === null || uuid(v);
  if (!d || d.id !== id || !optionalID(d.documentID) || !optionalID(d.conversationID) || !optionalID(d.head) || !Number.isSafeInteger(d.revision)
    || d.revision < 0 || !uuid(d.textRevision) || typeof d.text !== 'string' || bytesOf(d.text) > JOURNAL_LIMITS.draftText
    || !Number.isFinite(d.editedAt) || !uuid(d.branchRevision) || !optionalID(d.acknowledgedSubmissionID)
    || typeof d.discarded !== 'boolean' || (d.discarded && d.text !== '')) damaged();
  if (d.receipt !== null) {
    const r = d.receipt;
    if (!r || !uuid(r.submissionID) || !Array.isArray(r.eventIDs) || r.eventIDs.length < 1 || r.eventIDs.length > 2 || !r.eventIDs.every(uuid)
      || r.eventIDs.at(-1) !== r.submissionID || !uuid(r.textRevision) || !uuid(r.branchRevision) || !Number.isSafeInteger(r.revision) || r.revision < 0 || r.revision > d.revision
      || (d.textRevision === r.textRevision && d.text !== '')) damaged();
  }
  return d;
}
function validTurn(t: StoredTurn, id: string): StoredTurn {
  if (!t || t.id !== id || !uuid(t.entityID) || !uuid(t.composerID) || !uuid(t.conversationID) || !(t.documentID === null || uuid(t.documentID))
    || !uuid(t.questionID) || !uuid(t.operationID) || typeof t.requestDigest !== 'string' || !/^[0-9a-f]{64}$/.test(t.requestDigest)
    || typeof t.text !== 'string' || bytesOf(t.text) > JOURNAL_LIMITS.turnText || !Number.isFinite(t.startedAt) || !Number.isFinite(t.updatedAt)) damaged();
  return t;
}
function validHead(h: Head, scope: JournalScope): Head {
  if (!h || typeof h !== 'object' || !Number.isSafeInteger(h.format) || !Number.isSafeInteger(h.minReader)) damaged();
  if (h.format > JOURNAL_FORMAT || h.minReader > JOURNAL_FORMAT) throw new JournalError('journal_newer');
  if (h.environment !== scope.environment || h.account !== scope.account) damaged();
  if (h.origin !== scope.origin) throw new JournalError('journal_scope');
  if (h.format !== JOURNAL_FORMAT || h.minReader < 1) damaged();
  if (!uuid(h.incarnation) || !uuid(h.device) || !uuid(h.writer) || !Number.isSafeInteger(h.generation) || h.generation < 1
    || !(h.lifetime === null || typeof h.lifetime === 'string') || !Number.isSafeInteger(h.revision) || h.revision < 1
    || !Number.isSafeInteger(h.count) || h.count < 0 || h.count > JOURNAL_LIMITS.events || typeof h.chain !== 'string' || !/^[0-9a-f]{64}$/.test(h.chain)
    || !Number.isSafeInteger(h.historyBytes) || h.historyBytes < 0 || h.historyBytes > JOURNAL_LIMITS.historyBytes || !Number.isSafeInteger(h.cursor) || h.cursor < 0 || !Array.isArray(h.outbox) || !h.outbox.every(uuid)
    || new Set(h.outbox).size !== h.outbox.length || h.outbox.length > JOURNAL_LIMITS.outbox || !Array.isArray(h.replaced)
    || h.replaced.length > JOURNAL_LIMITS.replaced || !h.replaced.every(p => Array.isArray(p) && p.length === 2 && uuid(p[0]) && uuid(p[1])) || new Set(h.replaced.map(p => p[0])).size !== h.replaced.length
    || !h.drafts || typeof h.drafts !== 'object' || !h.turns || typeof h.turns !== 'object') damaged();
  if (Object.keys(h.drafts).length > JOURNAL_LIMITS.draftRecords || Object.keys(h.turns).length > JOURNAL_LIMITS.turns) damaged();
  for (const [id, d] of Object.entries(h.drafts)) if (!uuid(id) || !/^[0-9a-f]{64}$/.test(d?.digest) || !Number.isSafeInteger(d.bytes) || d.bytes < 28 || d.bytes > JOURNAL_LIMITS.recordBytes
    || !Number.isSafeInteger(d.text) || d.text < 0 || d.text > JOURNAL_LIMITS.draftText || typeof d.live !== 'boolean') damaged();
  for (const [id, t] of Object.entries(h.turns)) if (!uuid(id) || !/^[0-9a-f]{64}$/.test(t?.digest) || !Number.isSafeInteger(t.bytes) || t.bytes < 28 || t.bytes > JOURNAL_LIMITS.recordBytes) damaged();
  const drafts = Object.values(h.drafts);
  if (drafts.filter(d => d.live).length > JOURNAL_LIMITS.nonemptyDrafts || drafts.reduce((n, d) => n + d.bytes, 0) > JOURNAL_LIMITS.draftBytes || drafts.reduce((n, d) => n + d.text, 0) > 2 * 1024 * 1024) damaged();
  return h;
}
const clone = (h: Head): Head => ({ ...h, outbox: [...h.outbox], replaced: h.replaced.map(p => [p[0], p[1]] as [string, string]),
  drafts: Object.fromEntries(Object.entries(h.drafts).map(([k, v]) => [k, { ...v }])), turns: Object.fromEntries(Object.entries(h.turns).map(([k, v]) => [k, { ...v }])) });

export class Journal {
  private retired = false;
  private faultListeners = new Set<(error: unknown) => void>();
  private listeners = new Set<(delta: JournalDelta) => void | Promise<void>>();
  private knownIDs = new Map<string, LoadedEvent>();
  private hint: ReturnType<NonNullable<JournalDependencies['channel']>> | null = null;
  private unlisten: (() => void) | null = null;
  private readonly k: ReturnType<typeof keys>;
  private readonly lockName: string;

  private constructor(private readonly scope: JournalScope, private head: Head, private sealedHead: Bytes, private readonly deps: JournalDependencies) {
    this.k = keys(scope.environment, scope.account, scope.origin, head.incarnation);
    this.lockName = `gradstep.journal.${journalPrefix(scope.environment, scope.account, scope.origin)}`;
  }

  get incarnation() { return this.head.incarnation; }
  get cursor() { return this.head.cursor; }
  get outbox(): readonly string[] { return this.head.outbox; }
  get active() { return !this.retired; }
  subscribeFault(listener: (error: unknown) => void): () => void { this.faultListeners.add(listener); return () => { this.faultListeners.delete(listener); }; }
  private fault(error: unknown) {
    const code = (error as { code?: string })?.code;
    if (code && ['journal_damaged', 'journal_scope', 'journal_newer', 'journal_retired', 'corrupt_data', 'invalid_event', 'event_conflict', 'unsupported_format', 'local_storage'].includes(code)) this.retire();
    for (const listener of this.faultListeners) listener(error);
  }
  get revision() { return this.head.revision; }
  get lockScope() { return this.lockName; }
  /** Only this separate lane is held over sync network requests. Local editor commits remain free to proceed. */
  sync<T>(body: () => Promise<T>): Promise<T> { return this.deps.lock(`${this.lockName}sync`, body); }

  /** Opens (or creates) this account's journal and admits this login lifetime as its writer. */
  static async open(scope: JournalScope, deps: JournalDependencies): Promise<{ journal: Journal; snapshot: JournalSnapshot }> {
    const lockName = `gradstep.journal.${journalPrefix(scope.environment, scope.account, scope.origin)}`;
    return deps.lock(lockName, async () => {
      if (!scope.current()) throw new JournalError('journal_retired');
      const prefix = journalPrefix(scope.environment, scope.account, scope.origin), headKey = prefix + 'head';
      let stored = await deps.access.get(headKey);
      if (!stored) {
        // A lost head never authorizes initializing over remaining private records.
        if ((await deps.access.range(prefix, `${prefix}\uffff`)).length) damaged();
        const incarnation = scope.fence.incarnation;
        const head: Head = { format: JOURNAL_FORMAT, minReader: JOURNAL_FORMAT, origin: scope.origin, environment: scope.environment, account: scope.account,
          incarnation, device: scope.deviceID, lifetime: scope.lifetime, generation: scope.fence.generation, writer: scope.fence.writer,
          revision: 1, count: 0, chain: await chainStart(scope.account, incarnation),
          historyBytes: 0, cursor: 0, outbox: [], replaced: [], drafts: {}, turns: {} };
        const sealed = await seal(scope.localKey, utf8(JSON.stringify(head)), aad.head(scope.environment, scope.account, scope.origin));
        // Created only beside this exact device record: a forgotten or replaced device cannot be recreated by a late open.
        const result = await deps.access.commit(headKey, null, [[headKey, sealed]], [], { key: scope.deviceKey, deviceID: scope.deviceID, fence: scope.fence, current: scope.current });
        if (result === 'conflict') throw new JournalError('journal_conflict');
        if (result === 'fenced') throw new JournalError('journal_retired');
        stored = sealed;
      }
      let head: Head;
      try { head = JSON.parse(fromUtf8(await open(scope.localKey, stored, aad.head(scope.environment, scope.account, scope.origin)))) as Head; }
      catch { return damaged(); }
      head = validHead(head, scope);
      if (head.incarnation !== scope.fence.incarnation || head.generation > scope.fence.generation) throw new JournalError('journal_retired');
      const journal = new Journal(scope, head, stored, deps);
      const snapshot = await journal.load();
      // Admit this login lifetime. Tabs of the same login stay admitted; an earlier login's writers are fenced.
      // Even a same-login reopen proves that this exact admitted writer still exists in the device transaction.
      await journal.commitUnlocked(async h => ({ next: { ...clone(h), lifetime: scope.lifetime, generation: scope.fence.generation }, put: [], remove: [] }), true);
      journal.listen();
      return { journal, snapshot };
    });
  }

  /** Reads every record named by the head and verifies the chain and manifests. Never initializes over damage. */
  private async load(): Promise<JournalSnapshot> {
    const { head, scope } = this;
    const raw = await this.deps.access.range(this.k.events[0], this.k.events[1]);
    if (raw.length !== head.count) damaged();
    const byKey = new Map(raw);
    const events: LoadedEvent[] = [];
    let chain = await chainStart(scope.account, head.incarnation), bytes = 0;
    for (let ordinal = 0; ordinal < head.count; ordinal++) {
      const sealed = byKey.get(this.k.event(ordinal)) ?? damaged();
      chain = await chainNext(chain, sealed); bytes += sealed.length;
      let plain: Bytes;
      try { plain = await open(scope.localKey, sealed, aad.event(scope.account, head.incarnation, ordinal)); } catch { return damaged(); }
      const event = decodeEvent(plain, ordinal);
      if (this.knownIDs.has(event.envelope.id)) damaged();
      this.knownIDs.set(event.envelope.id, event); events.push(event);
    }
    if (chain !== head.chain || bytes !== head.historyBytes) damaged();
    const replaced = new Map(head.replaced);
    for (const id of head.outbox) { const e = this.knownIDs.get(id); if (!e || !e.local || replaced.has(id)) damaged(); }
    for (const [old, next] of replaced) { const a = this.knownIDs.get(old), b = this.knownIDs.get(next); if (!a?.local || !b?.local || a.ordinal >= b.ordinal) damaged(); }
    const drafts: StoredDraft[] = [], turns: StoredTurn[] = [];
    for (const [id, entry] of Object.entries(head.drafts)) {
      const sealed = await this.deps.access.get(this.k.draft(id)) ?? damaged();
      if (sealed.length !== entry.bytes || await digest(sealed) !== entry.digest) damaged();
      let draft: StoredDraft;
      try { draft = JSON.parse(fromUtf8(await open(scope.localKey, sealed, aad.draft(scope.account, head.incarnation, id)))) as StoredDraft; } catch { return damaged(); }
      drafts.push(validDraft(draft, id));
      if (bytesOf(draft.text) !== entry.text || !!draft.text !== entry.live) damaged();
    }
    for (const [id, entry] of Object.entries(head.turns)) {
      const sealed = await this.deps.access.get(this.k.turn(id)) ?? damaged();
      if (sealed.length !== entry.bytes || await digest(sealed) !== entry.digest) damaged();
      let turn: StoredTurn;
      try { turn = JSON.parse(fromUtf8(await open(scope.localKey, sealed, aad.turn(scope.account, head.incarnation, id)))) as StoredTurn; } catch { return damaged(); }
      turns.push(validTurn(turn, id));
    }
    const prefix = journalPrefix(scope.environment, scope.account, scope.origin);
    if ((await this.deps.access.range(prefix, `${prefix}\uffff`)).length !== 1 + head.count + drafts.length + turns.length) damaged();
    return { events, cursor: head.cursor, outbox: [...head.outbox], replaced, drafts, turns, device: head.device };
  }

  private listen() {
    this.hint = this.deps.channel?.(this.lockName) ?? null;
    this.unlisten = this.hint?.listen(() => { void this.refresh().catch(() => {}); }) ?? null;
  }
  /** Changes committed by other tabs (history records, cursor, outbox). Drafts and turns stay with their owning tab. */
  subscribe(listener: (delta: JournalDelta) => void | Promise<void>): () => void { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  /** Re-read after acquiring an editor/turn owner lock; the initial open snapshot may predate its last commit. */
  draft(id: string): Promise<StoredDraft | null> {
    return this.deps.lock(this.lockName, async () => { await this.catchUp(); return this.readDraft(this.head, id); })
      .catch(error => { this.fault(error); throw error; });
  }
  turn(id: string): Promise<StoredTurn | null> {
    return this.deps.lock(this.lockName, async () => { await this.catchUp(); return this.head.turns[id] ? this.readTurn(this.head, id) : null; })
      .catch(error => { this.fault(error); throw error; });
  }
  /** Loads another tab's commits, if any. */
  refresh(): Promise<void> {
    if (this.retired) return Promise.reject(new JournalError('journal_retired'));
    return this.deps.lock(this.lockName, () => this.catchUp()).catch(error => { this.fault(error); throw error; });
  }

  private async catchUp(): Promise<void> {
    if (this.retired) throw new JournalError('journal_retired');
    const stored = await this.deps.access.get(this.k.head);
    if (!stored) { this.retire(); throw new JournalError('journal_retired'); } // forgotten elsewhere
    if (equal(stored, this.sealedHead)) return;
    let head: Head;
    try { head = validHead(JSON.parse(fromUtf8(await open(this.scope.localKey, stored, aad.head(this.scope.environment, this.scope.account, this.scope.origin)))) as Head, this.scope); }
    catch (error) { if (error instanceof JournalError && error.code !== 'journal_damaged') throw error; return damaged(); }
    if (head.incarnation !== this.head.incarnation || head.count < this.head.count || head.revision <= this.head.revision) { this.retire(); throw new JournalError('journal_retired'); }
    const raw = new Map(await this.deps.access.range(this.k.event(this.head.count), this.k.events[1]));
    const events: LoadedEvent[] = [];
    let chain = this.head.chain, historyBytes = this.head.historyBytes;
    for (let ordinal = this.head.count; ordinal < head.count; ordinal++) {
      const sealed = raw.get(this.k.event(ordinal)) ?? damaged();
      chain = await chainNext(chain, sealed);
      historyBytes += sealed.length;
      const event = decodeEvent(await open(this.scope.localKey, sealed, aad.event(this.scope.account, head.incarnation, ordinal)).catch(damaged), ordinal);
      if (this.knownIDs.has(event.envelope.id)) damaged();
      events.push(event);
    }
    if (chain !== head.chain || historyBytes !== head.historyBytes) damaged();
    const known = new Map([...this.knownIDs, ...events.map(e => [e.envelope.id, e] as const)]), retired = new Map(head.replaced);
    for (const id of head.outbox) if (!known.get(id)?.local || retired.has(id)) damaged();
    for (const [old, next] of head.replaced) { const a = known.get(old), b = known.get(next); if (!a?.local || !b?.local || a.ordinal >= b.ordinal) damaged(); }
    for (const [id, entry] of Object.entries(head.drafts)) if (entry.digest !== this.head.drafts[id]?.digest) await this.readDraft(head, id);
    for (const [id, entry] of Object.entries(head.turns)) if (entry.digest !== this.head.turns[id]?.digest) await this.readTurn(head, id);
    const delta: JournalDelta = { events, cursor: head.cursor, outbox: [...head.outbox], replaced: new Map(head.replaced) };
    for (const listener of [...this.listeners]) {
      try { await listener(delta); }
      catch (error) {
        if (['missing_key', 'history_capacity'].includes((error as { code?: string })?.code ?? '')) throw error;
        throw new JournalError('journal_damaged');
      }
    }
    for (const event of events) this.knownIDs.set(event.envelope.id, event);
    this.head = head; this.sealedHead = stored;
  }

  /** The single write path: plan against the latest head, seal outside the transaction, then compare-and-swap. */
  private commit(plan: (head: Head) => Promise<Plan | null>): Promise<void> {
    if (this.retired) return Promise.reject(new JournalError('journal_retired'));
    return this.deps.lock(this.lockName, () => this.commitUnlocked(plan)).catch(error => { this.fault(error); throw error; });
  }
  private async commitUnlocked(plan: (head: Head) => Promise<Plan | null>, admitting = false): Promise<void> {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (this.retired || !this.scope.current()) throw new JournalError('journal_retired');
      await this.catchUp();
      // A later login (or an explicit sign-out) retired this writer's lifetime: it is fenced for good.
      if (!admitting && (this.head.lifetime !== this.scope.lifetime || this.head.generation !== this.scope.fence.generation)) { this.retire(); throw new JournalError('journal_retired'); }
      const prepared = await plan(this.head);
      if (!prepared) return;
      const next = { ...prepared.next, writer: this.scope.fence.writer, revision: this.head.revision + 1 };
      const sealedNext = await seal(this.scope.localKey, utf8(JSON.stringify(next)), aad.head(this.scope.environment, this.scope.account, this.scope.origin));
      if (this.retired) throw new JournalError('journal_retired');
      let result: 'committed' | 'conflict' | 'fenced';
      try {
        result = await this.deps.access.commit(this.k.head, this.sealedHead, [...prepared.put, [this.k.head, sealedNext]], prepared.remove,
          { key: this.scope.deviceKey, deviceID: this.scope.deviceID, fence: this.scope.fence, current: this.scope.current });
      } catch (error) {
        // An ambiguous completion: inspect what is stored before reporting failure.
        const now = await this.deps.access.get(this.k.head).catch(() => null);
        if (now && equal(now, sealedNext)) result = 'committed';
        else if (error instanceof Error && error.message === 'storage_quota') throw new JournalError('journal_quota');
        else throw error;
      }
      if (result === 'fenced') { this.retire(); throw new JournalError('journal_retired'); } // the device was forgotten or replaced
      if (result === 'committed') {
        this.head = next; this.sealedHead = sealedNext;
        prepared.committed?.();
        try { this.hint?.post({ kind: 'journal-changed' }); } catch { /* closed */ }
        return;
      }
    }
    throw new JournalError('journal_conflict');
  }

  private async eventRecords(head: Head, events: LoadedEvent[]): Promise<{ put: [string, Bytes][]; next: Head }> {
    const next = clone(head), put: [string, Bytes][] = [];
    for (const event of events) {
      const ordinal = next.count++;
      if (next.count > JOURNAL_LIMITS.events) throw new JournalError('journal_capacity');
      const sealed = await seal(this.scope.localKey, encodeEvent({ ...event, ordinal }), aad.event(this.scope.account, next.incarnation, ordinal));
      if (sealed.length > JOURNAL_LIMITS.recordBytes) throw new JournalError('journal_capacity');
      next.chain = await chainNext(next.chain, sealed); next.historyBytes += sealed.length;
      if (next.historyBytes > JOURNAL_LIMITS.historyBytes) throw new JournalError('journal_capacity');
      put.push([this.k.event(ordinal), sealed]); event.ordinal = ordinal;
    }
    return { put, next };
  }
  private async draftRecord(next: Head, draft: StoredDraft): Promise<[string, Bytes]> {
    validDraft(draft, draft.id);
    const sealed = await seal(this.scope.localKey, utf8(JSON.stringify(draft)), aad.draft(this.scope.account, next.incarnation, draft.id));
    if (sealed.length > JOURNAL_LIMITS.recordBytes) throw new JournalError('journal_capacity');
    next.drafts[draft.id] = { digest: await digest(sealed), bytes: sealed.length, text: bytesOf(draft.text), live: !!draft.text };
    const entries = Object.values(next.drafts);
    if (entries.length > JOURNAL_LIMITS.draftRecords || entries.filter(d => d.live).length > JOURNAL_LIMITS.nonemptyDrafts
      || entries.reduce((n, d) => n + d.bytes, 0) > JOURNAL_LIMITS.draftBytes || entries.reduce((n, d) => n + d.text, 0) > 2 * 1024 * 1024) throw new JournalError('journal_capacity');
    return [this.k.draft(draft.id), sealed];
  }
  /** Always read the canonical record named by the latest authenticated head, while holding the writer lock. */
  private async readDraft(head: Head, id: string): Promise<StoredDraft | null> {
    const entry = head.drafts[id];
    if (!entry) return null;
    const sealed = await this.deps.access.get(this.k.draft(id)) ?? damaged();
    if (sealed.length !== entry.bytes || await digest(sealed) !== entry.digest) damaged();
    let value: StoredDraft;
    try { value = JSON.parse(fromUtf8(await open(this.scope.localKey, sealed, aad.draft(this.scope.account, head.incarnation, id)))); }
    catch { return damaged(); }
    validDraft(value, id);
    if (bytesOf(value.text) !== entry.text || !!value.text !== entry.live) damaged();
    return value;
  }
  /** A submission consumes its captured edit only. Later text and a later explicit branch choice survive. */
  private async reconcileDraft(head: Head, incoming: StoredDraft, submitting = false): Promise<StoredDraft | null> {
    const stored = await this.readDraft(head, incoming.id);
    if (stored?.discarded) throw new JournalError('journal_discarded');
    if (stored && stored.documentID !== incoming.documentID) throw new JournalError('journal_conflict');
    if (submitting) {
      const receipt = incoming.receipt;
      if (!receipt || receipt.submissionID !== incoming.head) throw new JournalError('journal_conflict');
      if (stored?.receipt?.submissionID === receipt.submissionID) {
        if (JSON.stringify(stored.receipt) !== JSON.stringify(receipt)) throw new JournalError('journal_conflict');
        return null; // exact submission replay; never replace later typing
      }
      if (stored?.receipt && (stored.receipt.textRevision === receipt.textRevision || stored.receipt.revision >= receipt.revision)) throw new JournalError('journal_stale');
      if (stored?.conversationID && stored.conversationID !== incoming.conversationID) throw new JournalError('journal_conflict');
      const latest = stored && stored.revision > incoming.revision ? stored : incoming;
      return { ...latest, conversationID: incoming.conversationID,
        head: latest.branchRevision === receipt.branchRevision ? receipt.submissionID : latest.head,
        text: latest.textRevision === receipt.textRevision ? '' : latest.text, receipt };
    }
    if (stored && incoming.revision < stored.revision) return null;
    const receipt = stored?.receipt ?? null;
    const next = { ...incoming, conversationID: stored?.conversationID ?? incoming.conversationID, receipt,
      text: receipt?.textRevision === incoming.textRevision ? '' : incoming.text,
      head: receipt && incoming.acknowledgedSubmissionID !== receipt.submissionID && incoming.branchRevision === receipt.branchRevision ? stored!.head : incoming.head };
    if (stored && incoming.revision === stored.revision) {
      // Canonical receipt/head promotion is permitted; a different same-revision edit is never silently accepted.
      if (next.textRevision !== stored.textRevision || next.text !== stored.text || next.branchRevision !== stored.branchRevision) throw new JournalError('journal_conflict');
      return null;
    }
    return next;
  }

  /** Events authored here: records and outbox entries, with an optional draft receipt and turn retirement, atomically. */
  appendLocal(envelopes: EventEnvelope[], options: { draft?: StoredDraft; finishTurn?: string; recoveryTurn?: StoredTurn; expectedRevision?: number } = {}): Promise<void> {
    return this.commit(async head => {
      if (options.expectedRevision !== undefined && head.revision !== options.expectedRevision) throw new JournalError('journal_conflict');
      // Recovery retires only the exact checkpoint it read after acquiring ownership. Rebase or a late writer
      // forces a fresh read; it must never delete newer text while committing an older interrupted answer.
      if (options.recoveryTurn) {
        if (options.finishTurn !== options.recoveryTurn.id) throw new JournalError('journal_conflict');
        await this.checkTurn(head, options.recoveryTurn);
      }
      const fresh: LoadedEvent[] = [];
      for (const envelope of envelopes) {
        const known = this.knownIDs.get(envelope.id);
        if (known) { if (!equal(known.envelope.ciphertext, envelope.ciphertext)) throw new JournalError('journal_conflict'); continue; }
        fresh.push({ ordinal: -1, envelope, local: true });
      }
      const draft = options.draft ? await this.reconcileDraft(head, options.draft, true) : null;
      if (!fresh.length && !draft && !(options.finishTurn && head.turns[options.finishTurn])) return null;
      const { put, next } = await this.eventRecords(head, fresh);
      next.outbox.push(...fresh.map(e => e.envelope.id));
      if (next.outbox.length > JOURNAL_LIMITS.outbox) throw new JournalError('journal_capacity');
      const byID = new Map([...this.knownIDs, ...fresh.map(e => [e.envelope.id, e] as const)]);
      if (next.outbox.reduce((n, id) => n + (byID.get(id)?.envelope.ciphertext.length ?? JOURNAL_LIMITS.historyBytes), 0) > 8 * 1024 * 1024) throw new JournalError('journal_capacity');
      if (draft) put.push(await this.draftRecord(next, draft));
      const remove: string[] = [];
      if (options.finishTurn && next.turns[options.finishTurn]) { delete next.turns[options.finishTurn]; remove.push(this.k.turn(options.finishTurn)); }
      return { next, put, remove, committed: () => { for (const e of fresh) this.knownIDs.set(e.envelope.id, e); } };
    });
  }

  /**
   * A complete, validated server page: new records, the advanced pull cursor and the outbox entries it acknowledges,
   * in one transaction. Rows another tab already committed are skipped. An append receipt never advances this cursor.
   */
  commitPull(rows: { cursor: number; envelope: EventEnvelope }[], cursor: number): Promise<void> {
    return this.commit(async head => {
      if (cursor <= head.cursor) return null;
      const first = rows[0]?.cursor ?? cursor;
      if (head.cursor < first - 1) throw new JournalError('journal_conflict');
      const page = rows.filter(r => r.cursor > head.cursor);
      const fresh: LoadedEvent[] = [];
      for (const row of page) {
        const known = this.knownIDs.get(row.envelope.id);
        if (known) { if (!equal(known.envelope.ciphertext, row.envelope.ciphertext) || !known.local) throw new JournalError('journal_conflict'); continue; }
        fresh.push({ ordinal: -1, envelope: row.envelope, local: false });
      }
      const { put, next } = await this.eventRecords(head, fresh);
      const seen = new Set(page.map(r => r.envelope.id));
      next.outbox = next.outbox.filter(id => !seen.has(id));
      next.cursor = cursor;
      return { next, put, remove: [], committed: () => { for (const e of fresh) this.knownIDs.set(e.envelope.id, e); } };
    });
  }

  /** The server accepted these events. Only outbox metadata changes; the pull cursor does not. */
  acknowledge(ids: string[]): Promise<void> {
    return this.commit(async head => {
      if (!ids.some(id => head.outbox.includes(id))) return null;
      const next = clone(head); next.outbox = next.outbox.filter(id => !ids.includes(id));
      return { next, put: [], remove: [] };
    });
  }

  /**
   * Native fresh-ID rebase, after a complete pull under the current authority: absent pending events (and their pending
   * descendants) are replaced by new IDs sealed for the current epoch/device. Committed history is never rewritten.
   */
  rebase(replacements: { old: string; envelope: EventEnvelope }[], device: string, expectedRevision: number): Promise<void> {
    return this.commit(async head => {
      // The plan includes every pending descendant. Any intervening local commit forces a fresh plan.
      if (head.revision !== expectedRevision) throw new JournalError('journal_conflict');
      for (const { old } of replacements) if (!head.outbox.includes(old)) throw new JournalError('journal_conflict');
      const fresh = replacements.map(r => ({ ordinal: -1, envelope: r.envelope, local: true }));
      const { put, next } = await this.eventRecords(head, fresh);
      const mapping = new Map(replacements.map(r => [r.old, r.envelope.id]));
      next.outbox = next.outbox.map(id => mapping.get(id) ?? id);
      next.replaced.push(...replacements.map(r => [r.old, r.envelope.id] as [string, string]));
      if (next.replaced.length > JOURNAL_LIMITS.replaced) throw new JournalError('journal_capacity');
      next.device = device;
      const resolve = (id: string) => mapping.get(id) ?? id;
      for (const id of Object.keys(head.drafts)) {
        const draft = (await this.readDraft(head, id))!;
        const updated = { ...draft, head: draft.head && resolve(draft.head), acknowledgedSubmissionID: draft.acknowledgedSubmissionID && resolve(draft.acknowledgedSubmissionID),
          receipt: draft.receipt && { ...draft.receipt, submissionID: resolve(draft.receipt.submissionID), eventIDs: draft.receipt.eventIDs.map(resolve) } };
        if (JSON.stringify(draft) !== JSON.stringify(updated)) put.push(await this.draftRecord(next, updated));
      }
      for (const id of Object.keys(head.turns)) {
        const turn = await this.readTurn(head, id);
        if (mapping.has(turn.questionID)) put.push(await this.turnRecord(next, { ...turn, questionID: resolve(turn.questionID) }));
      }
      return { next, put, remove: [], committed: () => { for (const e of fresh) this.knownIDs.set(e.envelope.id, e); } };
    });
  }

  /** A composer checkpoint. Older revisions are ignored; a discarded composer is never resurrected. */
  async checkpointDraft(draft: StoredDraft): Promise<void> {
    await this.commit(async head => {
      const reconciled = await this.reconcileDraft(head, draft);
      if (!reconciled) return null;
      const next = clone(head);
      const put = [await this.draftRecord(next, reconciled)];
      return { next, put, remove: [] };
    });
  }
  /** Discard leaves an encrypted tombstone. A newer durable revision than the one observed refuses the discard. */
  discardDraft(id: string, observedRevision: number, template: Omit<StoredDraft, 'text' | 'discarded' | 'revision' | 'receipt'>): Promise<void> {
    return this.commit(async head => {
      const stored = await this.readDraft(head, id);
      if (stored?.discarded) return null;
      if (stored && stored.revision > observedRevision) throw new JournalError('journal_stale');
      const tombstone: StoredDraft = { ...template, id, text: '', discarded: true, revision: Math.max(observedRevision, stored?.revision ?? 0) + 1,
        receipt: stored?.receipt ?? null };
      const next = clone(head);
      const put = [await this.draftRecord(next, tombstone)];
      return { next, put, remove: [] };
    });
  }
  /**
   * Reclaims coordination records no live tab owns: empty or consumed drafts and tombstones. Called when a fresh writer
   * opens, after integrity verification; the owning tab's editor lock keeps a live composer's records out of `ids`.
   */
  collectDrafts(ids: string[]): Promise<void> {
    return this.commit(async head => {
      const present = ids.filter(id => head.drafts[id] && !head.drafts[id].live);
      if (!present.length) return null;
      const next = clone(head);
      for (const id of present) delete next.drafts[id];
      return { next, put: [], remove: present.map(id => this.k.draft(id)) };
    });
  }

  /** Persisted before a paid request starts: operation ID, request digest, the answer's identities and its owner. */
  beginTurn(turn: StoredTurn): Promise<void> { return this.writeTurn(turn, true); }
  /** A coalesced partial-answer checkpoint (callers write at most once per second). */
  checkpointTurn(turn: StoredTurn): Promise<void> { return this.writeTurn(turn, false); }
  private async readTurn(head: Head, id: string): Promise<StoredTurn> {
    const entry = head.turns[id] ?? damaged(), sealed = await this.deps.access.get(this.k.turn(id)) ?? damaged();
    if (sealed.length !== entry.bytes || await digest(sealed) !== entry.digest) damaged();
    try { return validTurn(JSON.parse(fromUtf8(await open(this.scope.localKey, sealed, aad.turn(this.scope.account, head.incarnation, id)))) as StoredTurn, id); }
    catch { return damaged(); }
  }
  private async checkTurn(head: Head, expected: StoredTurn): Promise<void> {
    if (!head.turns[expected.id] || JSON.stringify(await this.readTurn(head, expected.id)) !== JSON.stringify(expected)) throw new JournalError('journal_stale');
  }
  private async turnRecord(next: Head, turn: StoredTurn): Promise<[string, Bytes]> {
    validTurn(turn, turn.id);
    const sealed = await seal(this.scope.localKey, utf8(JSON.stringify(turn)), aad.turn(this.scope.account, next.incarnation, turn.id));
    if (sealed.length > JOURNAL_LIMITS.recordBytes) throw new JournalError('journal_capacity');
    next.turns[turn.id] = { digest: await digest(sealed), bytes: sealed.length };
    if (Object.keys(next.turns).length > JOURNAL_LIMITS.turns) throw new JournalError('journal_capacity');
    return [this.k.turn(turn.id), sealed];
  }
  private writeTurn(turn: StoredTurn, creating: boolean): Promise<void> {
    return this.commit(async head => {
      validTurn(turn, turn.id);
      if (creating ? !!head.turns[turn.id] : !head.turns[turn.id]) { if (creating) throw new JournalError('journal_conflict'); return null; }
      const next = clone(head);
      if (!creating) {
        const stored = await this.readTurn(head, turn.id);
        if (turn.updatedAt < stored.updatedAt) return null;
        if (stored.operationID !== turn.operationID || stored.requestDigest !== turn.requestDigest) throw new JournalError('journal_conflict');
        // Rotation may have remapped the parent while this partial checkpoint was being coalesced.
        turn = { ...turn, questionID: stored.questionID };
      }
      return { next, put: [await this.turnRecord(next, turn)], remove: [] };
    });
  }
  /** A refused or empty answer leaves nothing: its partial checkpoint is removed. */
  dropTurn(id: string, expected?: StoredTurn): Promise<void> {
    return this.commit(async head => {
      if (expected) { if (expected.id !== id) throw new JournalError('journal_conflict'); await this.checkTurn(head, expected); }
      if (!head.turns[id]) return null;
      const next = clone(head); delete next.turns[id];
      return { next, put: [], remove: [this.k.turn(id)] };
    });
  }

  /** Waits for every write this tab accepted so far (Web Lock requests are granted in order). */
  drain(): Promise<void> { return this.retired ? Promise.resolve() : this.deps.lock(this.lockName, async () => {}); }
  /** Explicit sign-out: drain accepted writes, then retire this login lifetime. The encrypted partition stays. */
  async signOut(): Promise<void> {
    if (this.retired) return;
    await this.commit(async head => head.lifetime === this.scope.lifetime ? { next: { ...clone(head), lifetime: null }, put: [], remove: [] } : null);
    await idb.retireWriter(this.scope.fence, true);
    this.retire();
  }
  /** Refuse every later write from this instance (account retired, storage retired or journal replaced). */
  retire() {
    if (this.retired) return;
    this.retired = true; this.listeners.clear(); this.unlisten?.(); this.hint?.close();
  }
}

/** Production dependencies: Web Locks (required), IndexedDB, and a BroadcastChannel for change hints. */
export function browserJournalDependencies(): JournalDependencies | null {
  if (typeof navigator === 'undefined' || !navigator.locks) return null;
  return {
    lock: (name, body) => navigator.locks.request(name, body),
    access: journalAccess,
    channel: name => {
      if (typeof BroadcastChannel === 'undefined') return null;
      const channel = new BroadcastChannel(name);
      const listeners = new Set<(value: unknown) => void>();
      channel.onmessage = event => { for (const l of listeners) l(event.data); };
      return { post: value => channel.postMessage(value), listen: l => { listeners.add(l); return () => { listeners.delete(l); }; }, close: () => channel.close() };
    },
  };
}

export const isJournalID = uuid;
