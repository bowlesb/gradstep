// Encrypted history in the browser (docs/architecture/BROWSER_READER.md › Chat): the account's event log is pulled
// with v3_pull_events and decrypted into memory; this browser's events are sealed with the current epoch and sent
// with v1_append_event, keeping their ID and bytes across retries (as DeviceKeys.transfer does natively). Pages are
// checked as EncryptedStore.ingest checks them (contiguous cursors, digests, decryption, valid payloads); a failure
// stops at the last good page.
//
// With the durable journal (lib/journal.ts, BROWSER_OFFLINE_STORAGE.md gate 1) the same envelopes are also kept in this
// browser, sealed under its local key: a local submission commits its exact outbox bytes (with a draft receipt or a
// retired answer turn) before anything is sent, a validated page commits with its cursor and outbox removals, and an
// acknowledgement only edits the outbox. Without the journal (an existing profile not yet activated) nothing is written
// to browser storage — no plaintext, no drafts, no outbox — and reloads lose unsent work, as before.
import { BackendError, rpc } from './backend';
import { type Bytes, equal, fromBytea, isUUID, sha256, toBytea } from './bytes';
import { type AppliedEvent, type PrivateEvent, PrivateState, decodeEvent, encodeEvent } from './events';
import type { Journal, JournalDelta, JournalSnapshot, LoadedEvent, StoredDraft, StoredTurn } from './journal';
import { type EventEnvelope, type KeyRing, WireError, openEvent, sealEvent } from './wire';

const PAGE = 50, PAGE_BYTES = 32 * 1024 * 1024;
export const MAX_HISTORY_EVENTS = 20_000, MAX_HISTORY_BYTES = 64 * 1024 * 1024;
interface Row { id: string; device_id: string; cursor: number; epoch: number; format: number; ciphertext: string; ciphertext_sha256: string }
interface Page { events: Row[]; next_cursor: number; has_more: boolean }
export interface AppendOptions {
  draft?: StoredDraft; finishTurn?: string; recoveryTurn?: StoredTurn;
  /** Planned against the latest journal revision, so a delayed generated title cannot replace a rename. */
  title?: { id: string; conversationID: string; text: string; source: 'generated' | 'renamed' };
  /** Snippet blobs the events need (Notes): committed in the same local transaction; requires the durable journal. */
  blobs?: { blobID: string; stored: Bytes }[];
}
/** Decides, just before an authored event is sent, whether it may go now (a Notes entry waits for its blobs). */
export type SendGate = (event: PrivateEvent) => Promise<boolean>;

export type HistoryStatus = 'loading' | 'ready' | 'error';
const refreshable = (error: unknown) => (error instanceof WireError && error.code === 'missing_key')
  || (error instanceof BackendError && ['stale_key_epoch', 'key_authority_required'].includes(error.code));

/** Sync failures that sending can't get past: the keys, the history's size, an update, a conflict or this browser's own
 * storage. Anything else (no connection, a rate limit, a paused transfer) is temporary: a question is still saved here and
 * synced by the send itself or a later sync (A20, "degrade, don't refuse"). */
const BLOCKING_SYNC = new Set(['stale_key_epoch', 'key_authority_required', 'missing_key', 'history_capacity', 'sync_page_too_large', 'reader_update_required',
  'event_conflict', 'local_storage', 'local_quota', 'local_capacity']);
export function syncBlocksSending(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  if (typeof code !== 'string') return true; // unknown: as before, wait for a completed sync
  return BLOCKING_SYNC.has(code) || code.startsWith('storage_');
}

export class History {
  readonly state = new PrivateState();
  status: HistoryStatus = 'loading';
  issue: string | null = null;
  /** Whether the current issue stops new questions (see syncBlocksSending); a temporary one doesn't. */
  issueBlocks = false;
  /** New questions wait for the first completed sync and for a sync failure that sending can't get past. */
  get blocksSending(): boolean { return this.status !== 'ready' || (!!this.issue && this.issueBlocks); }
  private cursor = 0;
  private acknowledged = 0;
  private version = 0;
  private listeners = new Set<() => void>();
  private rebaseListeners = new Set<(mapping: Map<string, string>) => void>();
  /** Sealed here and applied locally; not yet acknowledged by the server (in order). */
  private pending: EventEnvelope[] = [];
  private sealed = new Map<string, Bytes>();
  private running: Promise<void> | null = null;
  private again = false;
  private writes: Promise<void> = Promise.resolve();
  private sizes = new Map<string, number>();
  private retainedBytes = 0;

  constructor(private readonly account: string, private readonly deviceID: string, private ring: KeyRing,
    private readonly signal: AbortSignal, private readonly refreshRing: () => Promise<KeyRing>, private readonly journal: Journal | null = null) {
    journal?.subscribe(delta => this.applyDelta(delta));
  }

  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  /** Fresh-ID rebases (key rotation or author change): retired pending event → its replacement. */
  subscribeRebase = (listener: (mapping: Map<string, string>) => void) => { this.rebaseListeners.add(listener); return () => { this.rebaseListeners.delete(listener); }; };
  getVersion = () => this.version;
  /** Unsent work survives a reload in this browser (the encrypted journal is active). */
  get durable() { return !!this.journal; }
  /** The encrypted local journal (snippet blobs live beside its events), when active. */
  get localJournal(): Journal | null { return this.journal; }
  private gate: SendGate | null = null;
  /** Held events stay in the outbox, in order; later unrelated events are still sent (a failed upload never blocks chats). */
  setSendGate(gate: SendGate | null) { this.gate = gate; }
  /** Pending events the gate held back in the last send. */
  readonly held = new Set<string>();
  get unsaved(): number { return this.pending.length; }
  isPending(id: string): boolean { const resolved = this.state.resolve(id); return this.pending.some(p => p.id === resolved); }
  /** An event ID after any local rebase. */
  resolve(id: string): string { return this.state.resolve(id); }
  private publish() { if (!this.signal.aborted) { this.version++; for (const listener of this.listeners) listener(); } }

  private admit(events: { id: string; bytes: number }[]) {
    const fresh = new Map(events.filter(e => !this.sizes.has(e.id)).map(e => [e.id, e.bytes]));
    if (this.sizes.size + fresh.size > MAX_HISTORY_EVENTS || this.retainedBytes + [...fresh.values()].reduce((a, b) => a + b, 0) > MAX_HISTORY_BYTES)
      throw new BackendError('history_capacity');
    return fresh;
  }
  private record(sizes: Map<string, number>) { for (const [id, size] of sizes) { this.sizes.set(id, size); this.retainedBytes += size; } }

  private async decrypt(events: LoadedEvent[]): Promise<AppliedEvent[]> {
    const out: AppliedEvent[] = [];
    for (const { envelope } of events) out.push({ id: envelope.id, deviceID: envelope.deviceID, payload: decodeEvent(await openEvent(envelope, this.ring)) });
    return out;
  }

  /**
   * History and outbox kept in this browser: shown at once, before any network request. Sending still waits for a
   * completed online sync (`status === 'ready'`). A record that doesn't decrypt or validate stops here; it never
   * becomes an empty history.
   */
  async restore(snapshot: JournalSnapshot): Promise<void> {
    const retired = snapshot.replaced;
    const kept = snapshot.events.filter(e => !retired.has(e.envelope.id));
    let all: AppliedEvent[];
    try { all = await this.decrypt(snapshot.events); }
    catch (error) {
      // A peer can commit a rotated epoch after key preparation but before this snapshot opens.
      // Refresh current authority once before classifying the complete checkpoint as unreadable.
      if (!(error instanceof WireError) || error.code !== 'missing_key') throw error;
      this.ring = await this.refreshRing(); this.signal.throwIfAborted();
      all = await this.decrypt(snapshot.events);
    }
    const byID = new Map(all.map(e => [e.id, e]));
    const resolve = (id: string) => { const seen = new Set<string>(); while (retired.has(id)) { if (seen.has(id)) throw new BackendError('local_storage'); seen.add(id); id = retired.get(id)!; } return id; };
    if (new Set(retired.values()).size !== retired.size) throw new BackendError('local_storage');
    for (const [old, next] of retired) {
      const before = byID.get(old), after = byID.get(next);
      if (!before || !after || JSON.stringify(encodeEvent({ ...before.payload, parents: before.payload.parents.map(resolve) })) !== JSON.stringify(encodeEvent({ ...after.payload, parents: after.payload.parents.map(resolve) }))) throw new BackendError('local_storage');
    }
    const staged = all.filter(e => !retired.has(e.id));
    if (staged.some(e => e.payload.parents.some(p => retired.has(p)))) throw new BackendError('local_storage');
    this.signal.throwIfAborted();
    const sizes = this.admit(kept.map(e => ({ id: e.envelope.id, bytes: e.envelope.ciphertext.length })));
    this.state.restoreReplacements(retired);
    this.state.applyBatch(staged);
    this.record(sizes);
    this.cursor = snapshot.cursor;
    const envelopes = new Map(kept.map(e => [e.envelope.id, e.envelope]));
    this.pending = snapshot.outbox.map(id => envelopes.get(id)!);
    for (const envelope of this.pending) this.sealed.set(envelope.id, envelope.ciphertext);
    this.publish();
  }

  /** Another tab committed history records, a cursor or outbox changes. */
  private async applyDelta(delta: JournalDelta): Promise<void> {
    const kept = delta.events.filter(e => !delta.replaced.has(e.envelope.id));
    const all = await this.decrypt(delta.events), staged = all.filter(e => !delta.replaced.has(e.id));
    if (this.signal.aborted) return;
    const resolve = (id: string): string => { const seen = new Set<string>(); while (delta.replaced.has(id)) { if (seen.has(id)) throw new BackendError('local_storage'); seen.add(id); id = delta.replaced.get(id)!; } return id; };
    const byID = new Map([...this.state.events.values(), ...all].map(e => [e.id, e]));
    for (const [old, next] of delta.replaced) {
      const a = byID.get(old), b = byID.get(next);
      if (a && (!b || JSON.stringify(encodeEvent({ ...a.payload, parents: a.payload.parents.map(resolve) })) !== JSON.stringify(encodeEvent({ ...b.payload, parents: b.payload.parents.map(resolve) })))) throw new BackendError('local_storage');
    }
    const fresh: [string, string][] = [...delta.replaced].filter(([old]) => this.state.events.has(old)).map(([old, next]) => [old, resolve(next)]);
    this.state.check(staged);
    if (fresh.length) this.state.checkLocalReplacements(staged, new Map(fresh));
    const sizes = this.admit(kept.map(e => ({ id: e.envelope.id, bytes: e.envelope.ciphertext.length })));
    this.state.applyBatch(staged);
    this.record(sizes);
    if (fresh.length) this.state.applyLocalReplacements(new Map(fresh));
    this.state.restoreReplacements(delta.replaced);
    this.cursor = Math.max(this.cursor, delta.cursor);
    this.syncPending(delta.outbox, kept.map(e => e.envelope));
    if (fresh.length) for (const listener of this.rebaseListeners) listener(new Map(fresh));
    this.publish();
  }
  /** The journal's outbox is authoritative for durable pending events. */
  private syncPending(outbox: readonly string[], extra: EventEnvelope[] = []) {
    const known = new Map([...this.pending, ...extra].map(e => [e.id, e]));
    this.pending = outbox.map(id => known.get(id)).filter((e): e is EventEnvelope => !!e);
    for (const envelope of this.pending) this.sealed.set(envelope.id, envelope.ciphertext);
  }

  /** Pull to the end, send what's pending, pull again; one run at a time (a call during a run schedules one more). */
  sync(): Promise<void> {
    if (this.signal.aborted) return Promise.reject(new BackendError('cancelled'));
    if (this.running) { this.again = true; return this.running; }
    const run = (async () => {
      try {
        do {
          this.again = false;
          if (this.journal) await this.journal.sync(() => this.transfer());
          else await this.transfer();
        } while (this.again && !this.signal.aborted);
        if (this.status !== 'ready' || this.issue) { this.status = 'ready'; this.issue = null; this.issueBlocks = false; this.publish(); }
      } catch (error) {
        if (this.signal.aborted) return;
        this.status = this.status === 'loading' ? 'error' : this.status;
        this.issue = syncIssueText(error); this.issueBlocks = syncBlocksSending(error);
        this.publish();
        throw error;
      } finally { this.running = null; }
    })();
    this.running = run;
    return run;
  }

  /**
   * Seals and applies events here at once (they show immediately). With the journal, the exact envelopes, their outbox
   * entries and the optional draft receipt / turn retirement commit in one local transaction first; a failed local
   * commit changes nothing. Nothing is sent.
   */
  async commit(entries: { id: string; event: PrivateEvent }[], options: AppendOptions = {}): Promise<void> {
    const write = this.writes.then(async () => {
      for (let attempt = 0; ; attempt++) {
      this.signal.throwIfAborted();
      await this.journal?.refresh();
      const expectedRevision = this.journal?.revision;
      const memoryTitles = options.title && this.state.revisions(options.title.conversationID).map(e => e.id).join(':');
      const planned = [...entries];
      if (options.title) {
        const { id, conversationID, text, source } = options.title;
        const saved = this.state.events.get(this.resolve(id));
        if (saved) {
          if (saved.payload.kind !== 'conversation' || saved.payload.entityID !== conversationID || saved.payload.text !== text || saved.payload.titleSource !== source) throw new BackendError('event_conflict');
          planned.push({ id, event: saved.payload });
        } else if (source === 'renamed' || !this.state.revisions(conversationID).some(e => e.payload.titleSource !== undefined)) {
          const event = this.state.titledConversation(conversationID, text, source);
          if (event) planned.push({ id, event });
        }
      }
      if (options.blobs?.length && !this.journal) throw new BackendError('local_storage');
      if (!planned.length || planned.length > 4 || planned.some(e => !isUUID(e.id) || e.id !== e.id.toLowerCase()) || new Set(planned.map(e => e.id)).size !== planned.length) throw new BackendError('invalid_request');
      const normalized = planned.map(({ id, event }) => ({ id, event: { ...event, parents: event.parents.map(p => this.resolve(p)) } }));
      const fresh = normalized.filter(({ id, event }) => {
        const old = this.state.events.get(this.state.resolve(id));
        if (!old) return true;
        if ((old.deviceID !== this.deviceID && this.resolve(id) === id) || JSON.stringify(encodeEvent(old.payload)) !== JSON.stringify(encodeEvent(event))) throw new BackendError('event_conflict');
        return false;
      });
      if (this.pending.length + fresh.length > 128) throw new BackendError('history_capacity');
      const applied = fresh.map(({ id, event }) => ({ id, deviceID: this.deviceID, payload: event }));
      this.state.check(applied);
      const envelopes = await Promise.all(fresh.map(({ id, event }) => sealEvent(encodeEvent(event), id, this.deviceID, this.ring)));
      this.signal.throwIfAborted();
      // A deliberately deferred version-1 tab has no journal CAS. A pull can still publish a rename while sealing.
      if (!this.journal && options.title && memoryTitles !== this.state.revisions(options.title.conversationID).map(e => e.id).join(':')) {
        if (attempt < 2) continue;
        throw new BackendError('history_unsaved');
      }
      if ([...this.pending, ...envelopes].reduce((n, e) => n + e.ciphertext.length, 0) > 8 * 1024 * 1024) throw new BackendError('history_capacity');
      const sizes = this.admit(envelopes.map(e => ({ id: e.id, bytes: e.ciphertext.length })));
      if (this.journal) {
        const draft = options.draft && { ...options.draft, head: options.draft.head && this.resolve(options.draft.head),
          requestedAnswer: options.draft.requestedAnswer && { ...options.draft.requestedAnswer, questionID: this.resolve(options.draft.requestedAnswer.questionID) },
          acknowledgedSubmissionID: options.draft.acknowledgedSubmissionID && this.resolve(options.draft.acknowledgedSubmissionID),
          receipt: options.draft.receipt && { ...options.draft.receipt, submissionID: this.resolve(options.draft.receipt.submissionID), eventIDs: options.draft.receipt.eventIDs.map(id => this.resolve(id)) } };
        try { await this.journal.appendLocal(envelopes, { ...options, draft, expectedRevision }); }
        catch (error) {
          if ((error as { code?: string }).code === 'journal_conflict' && attempt < 2) continue;
          if (options.recoveryTurn && (error as { code?: string }).code === 'journal_stale') throw error;
          throw new BackendError(journalCode(error));
        }
        this.signal.throwIfAborted();
      }
      this.state.applyBatch(applied);
      this.record(sizes);
      for (const envelope of envelopes) { this.sealed.set(envelope.id, envelope.ciphertext); if (!this.pending.some(p => p.id === envelope.id)) this.pending.push(envelope); }
      if (this.journal) this.syncPending(this.journal.outbox, envelopes);
      this.publish();
      return;
      }
    });
    this.writes = write.catch(() => {});
    await write;
  }

  /** Commits locally, then resolves when the server has every entry (after any rebase). */
  async append(entries: { id: string; event: PrivateEvent }[], options: AppendOptions = {}): Promise<void> {
    await this.commit(entries, options);
    await this.flush([...entries.map(e => e.id), ...(options.title ? [options.title.id] : [])]);
  }
  /** Syncs and checks that these events (by their current IDs) were acknowledged. */
  async flush(ids: string[]): Promise<void> {
    try { await this.sync(); } catch (error) {
      if (ids.some(id => this.isPending(id))) throw new BackendError('history_unsaved');
      throw error;
    }
    this.signal.throwIfAborted();
    if (ids.some(id => this.isPending(id))) throw new BackendError('history_unsaved');
  }

  private async transfer(): Promise<void> {
    // Online authority is refreshed before catch-up/rebase. It never comes from a durable local cursor.
    if (this.journal) { this.ring = await this.refreshRing(); await this.journal.refresh(); }
    for (let attempt = 0; ; attempt++) {
      try {
        await this.pull();
        // Restored pending events by an earlier author device or epoch are replaced before anything is sent.
        await this.rebase();
        await this.push();
        await this.pull();
        if (this.cursor > this.acknowledged) {
          await rpc('v1_acknowledge_cursor', { p_device_id: this.deviceID, p_cursor: this.cursor, p_management_token: toBytea(this.ring.managementToken) },
            { account: this.account, signal: this.signal }).then(() => { this.acknowledged = this.cursor; }, () => {});
        }
        return;
      } catch (error) {
        if (attempt > 0 || !refreshable(error)) throw error;
        // A newer epoch: refresh this browser's keys and catch up completely (a visible newer epoch fences old-epoch
        // commits), then rebase what the server still doesn't have under fresh IDs.
        this.ring = await this.refreshRing();
        await this.pull();
        await this.rebase();
      }
    }
  }

  /**
   * The native pull-first, fresh-ID rebase (EncryptedStore.rebasePendingAfterCatchUp). Only called after a complete pull
   * under current authority, so absence proves these events were never committed. Every pending descendant is included;
   * content and logical IDs are preserved, parents remapped. Committed history is never rewritten.
   */
  private async rebase(attempt = 0): Promise<void> {
    await this.journal?.refresh();
    const expectedRevision = this.journal?.revision;
    const pending = [...this.pending];
    const affected = new Set(pending.filter(e => e.epoch < this.ring.epoch || e.deviceID !== this.deviceID).map(e => e.id));
    if (!affected.size) return;
    for (let grew = true; grew;) {
      grew = false;
      for (const e of pending) if (!affected.has(e.id) && this.state.events.get(e.id)?.payload.parents.some(p => affected.has(p))) { affected.add(e.id); grew = true; }
    }
    const mapping = new Map([...affected].map(id => [id, crypto.randomUUID()]));
    const replacements: { old: string; envelope: EventEnvelope; payload: PrivateEvent }[] = [];
    for (const original of pending) {
      if (!affected.has(original.id)) continue;
      const event = this.state.events.get(original.id);
      if (!event) throw new BackendError('history_unsaved');
      const payload = { ...event.payload, parents: event.payload.parents.map(p => mapping.get(p) ?? p) };
      replacements.push({ old: original.id, payload, envelope: await sealEvent(encodeEvent(payload), mapping.get(original.id)!, this.deviceID, this.ring) });
    }
    this.signal.throwIfAborted();
    const applied = replacements.map(r => ({ id: r.envelope.id, deviceID: this.deviceID, payload: r.payload }));
    this.state.checkLocalReplacements(applied, mapping);
    const sizes = this.admit(replacements.map(r => ({ id: r.envelope.id, bytes: r.envelope.ciphertext.length })));
    if (this.journal) {
      try { await this.journal.rebase(replacements.map(r => ({ old: r.old, envelope: r.envelope })), this.deviceID, expectedRevision!); }
      catch (error) {
        if ((error as { code?: string }).code === 'journal_conflict' && attempt < 2) return this.rebase(attempt + 1);
        throw new BackendError(journalCode(error));
      }
    }
    this.state.applyBatch(applied);
    this.state.applyLocalReplacements(mapping);
    this.record(sizes);
    const replaced = new Map(replacements.map(r => [r.old, r.envelope]));
    this.pending = this.pending.map(e => replaced.get(e.id) ?? e);
    for (const r of replacements) { this.sealed.delete(r.old); this.sealed.set(r.envelope.id, r.envelope.ciphertext); }
    for (const listener of [...this.rebaseListeners]) listener(mapping);
    this.publish();
  }

  private async push(): Promise<void> {
    const held = new Set<string>();
    for (const envelope of [...this.pending]) {
      if (!this.pending.includes(envelope)) continue; // a pull already reconciled it
      // An event waits for its blobs (the gate), and anything after it that depends on it waits too.
      const event = this.state.events.get(envelope.id)?.payload;
      if (event && (event.parents.some(p => held.has(p)) || (this.gate && !await this.gate(event)))) { held.add(envelope.id); continue; }
      this.signal.throwIfAborted();
      // Each event is sent by the author device its authenticated data names.
      const cursor = await rpc<number>('v1_append_event', { p_device_id: envelope.deviceID, p_id: envelope.id, p_epoch: envelope.epoch, p_format: envelope.format,
        p_ciphertext: toBytea(envelope.ciphertext), p_management_token: toBytea(this.ring.managementToken) }, { account: this.account, signal: this.signal });
      this.signal.throwIfAborted();
      if (!Number.isSafeInteger(cursor) || cursor <= 0) throw new BackendError('invalid_response');
      // Losing this local acknowledgement is harmless: the next pull reconciles the same ID and bytes.
      if (this.journal) await this.journal.acknowledge([envelope.id]);
      this.pending = this.pending.filter(p => p.id !== envelope.id);
      this.publish();
    }
    this.held.clear(); for (const id of held) this.held.add(id);
  }

  private async pull(): Promise<void> {
    for (;;) {
      this.signal.throwIfAborted();
      const before = this.cursor;
      const page = await rpc<Page>('v3_pull_events', { p_after: before, p_limit: PAGE }, { account: this.account, signal: this.signal, maximum: PAGE_BYTES });
      if (!page || !Array.isArray(page.events) || page.events.length > PAGE || typeof page.has_more !== 'boolean'
        || page.next_cursor !== (page.events.at(-1)?.cursor ?? before) || (page.has_more && !page.events.length)) throw new BackendError('invalid_response');
      const staged: AppliedEvent[] = [], seen = new Set<string>(), rows: { cursor: number; envelope: EventEnvelope }[] = [];
      let expected = before;
      for (const row of page.events) {
        if (!row || row.cursor !== expected + 1 || !isUUID(row.id) || !isUUID(row.device_id) || !Number.isSafeInteger(row.epoch) || !Number.isSafeInteger(row.format)) throw new BackendError('invalid_response');
        const id = row.id.toLowerCase();
        const envelope: EventEnvelope = { id, deviceID: row.device_id.toLowerCase(), epoch: row.epoch, format: row.format, ciphertext: fromBytea(row.ciphertext) };
        if (seen.has(id) || !equal(await sha256(envelope.ciphertext), fromBytea(row.ciphertext_sha256))) throw new BackendError('invalid_response');
        const mine = this.sealed.get(id);
        if (mine && !equal(mine, envelope.ciphertext)) throw new BackendError('event_conflict');
        seen.add(id);
        staged.push({ id, deviceID: envelope.deviceID, payload: decodeEvent(await openEvent(envelope, this.ring)) });
        rows.push({ cursor: row.cursor, envelope });
        expected = row.cursor;
      }
      this.signal.throwIfAborted();
      // The whole page is validated before anything (cursor included) is committed.
      this.state.check(staged);
      const sizes = this.admit(page.events.map(row => ({ id: row.id.toLowerCase(), bytes: fromBytea(row.ciphertext).length })));
      if (this.journal && expected > before) {
        try { await this.journal.commitPull(rows, expected); } catch (error) { throw new BackendError(journalCode(error)); }
        this.signal.throwIfAborted();
      }
      this.state.applyBatch(staged);
      this.record(sizes);
      this.pending = this.pending.filter(p => !seen.has(p.id));
      for (const id of seen) this.sealed.delete(id);
      this.cursor = Math.max(this.cursor, expected, this.journal?.cursor ?? 0);
      if (this.journal) this.syncPending(this.journal.outbox);
      if (staged.length || this.status === 'loading') { if (!page.has_more) this.status = 'ready'; this.publish(); }
      if (!page.has_more) return;
    }
  }
}

/** Journal failures surface as finite history codes (no private detail). */
export function journalCode(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  if (code === 'journal_quota' || code === 'storage_quota') return 'local_quota';
  if (code === 'journal_capacity') return 'local_capacity';
  if (typeof code === 'string' && code.startsWith('storage_')) return code;
  return 'local_storage';
}


/** Sync failures by server code (docs/architecture/PRIVACY_AND_SYNC.md), never server prose: what stopped and that this
 * device's copy still works. Unknown failures keep the generic line. */
export function syncIssueText(error: unknown): string {
  const code = error instanceof BackendError ? error.code : null;
  switch (code) {
    case 'history_capacity': return 'This history is larger than this browser currently supports. Use Gradstep on iPhone, iPad or Mac.';
    case 'connection': return 'Couldn’t reach Gradstep to sync your chats.';
    case 'sync_page_too_large': case 'reader_update_required': return 'Reload to get the latest Gradstep and keep syncing this history. Everything saved here stays available.';
    case 'sync_account_storage_limit': case 'sync_environment_storage_limit': return 'Cloud history uploads are paused because storage is full. New changes stay on this device.';
    case 'sync_account_transfer_limit': case 'sync_environment_transfer_limit': return 'Cloud history downloads are paused for now. Your saved work stays on this device.';
    case 'request_rate_limit': case 'rate_limited': return 'Sync is limited for a moment and will try again.';
    case 'stale_key_epoch': case 'key_authority_required': return 'This browser needs updated encryption keys from an approved device or a recovery code.';
    default: return 'Your chat history couldn’t be synced. Reload the page to try again.';
  }
}