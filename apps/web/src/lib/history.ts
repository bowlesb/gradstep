// Encrypted history in the browser (docs/architecture/BROWSER_READER.md › Chat): the account's event log is pulled
// with v2_pull_events and decrypted into memory; this browser's events are sealed with the current epoch and sent
// with v1_append_event, keeping their ID and bytes across retries (as DeviceKeys.transfer does natively). Pages are
// checked as EncryptedStore.ingest checks them (contiguous cursors, digests, decryption, valid payloads); a failure
// stops at the last good page. Nothing is written to browser storage — no plaintext, no drafts, no outbox.
import { BackendError, rpc } from './backend';
import { type Bytes, equal, fromBytea, isUUID, sha256, toBytea } from './bytes';
import { type AppliedEvent, type PrivateEvent, PrivateState, decodeEvent, encodeEvent } from './events';
import { type EventEnvelope, type KeyRing, WireError, openEvent, sealEvent } from './wire';

const PAGE = 50, PAGE_BYTES = 32 * 1024 * 1024;
interface Row { id: string; device_id: string; cursor: number; epoch: number; format: number; ciphertext: string; ciphertext_sha256: string }
interface Page { events: Row[]; next_cursor: number; has_more: boolean }

export type HistoryStatus = 'loading' | 'ready' | 'error';
const refreshable = (error: unknown) => (error instanceof WireError && error.code === 'missing_key')
  || (error instanceof BackendError && ['stale_key_epoch', 'key_authority_required'].includes(error.code));

export class History {
  readonly state = new PrivateState();
  status: HistoryStatus = 'loading';
  issue: string | null = null;
  private cursor = 0;
  private acknowledged = 0;
  private version = 0;
  private listeners = new Set<() => void>();
  /** Sealed here and applied locally; not yet acknowledged by the server (in order). */
  private pending: EventEnvelope[] = [];
  private sealed = new Map<string, Bytes>();
  private running: Promise<void> | null = null;
  private again = false;

  constructor(private readonly account: string, private readonly deviceID: string, private ring: KeyRing,
    private readonly signal: AbortSignal, private readonly refreshRing: () => Promise<KeyRing>) {}

  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  getVersion = () => this.version;
  get unsaved(): number { return this.pending.length; }
  private publish() { this.version++; for (const listener of this.listeners) listener(); }

  /** Pull to the end, send what's pending, pull again; one run at a time (a call during a run schedules one more). */
  sync(): Promise<void> {
    if (this.running) { this.again = true; return this.running; }
    const run = (async () => {
      try {
        do { this.again = false; await this.transfer(); } while (this.again && !this.signal.aborted);
        if (this.status !== 'ready' || this.issue) { this.status = 'ready'; this.issue = null; this.publish(); }
      } catch (error) {
        if (this.signal.aborted) return;
        this.status = this.status === 'loading' ? 'error' : this.status;
        this.issue = error instanceof BackendError && error.code === 'connection' ? 'Couldn’t reach Gradstep to sync your chats.'
          : 'Your chat history couldn’t be synced. Reload the page to try again.';
        this.publish();
        throw error;
      } finally { this.running = null; }
    })();
    this.running = run;
    return run;
  }

  /** Seals and applies events here at once (they show immediately), then resolves when the server has them all. */
  async append(entries: { id: string; event: PrivateEvent }[]): Promise<void> {
    for (const { id, event } of entries) {
      const envelope = await sealEvent(encodeEvent(event), id, this.deviceID, this.ring);
      this.state.apply({ id, deviceID: this.deviceID, payload: event });
      this.sealed.set(id, envelope.ciphertext);
      this.pending.push(envelope);
    }
    this.publish();
    await this.sync().catch(() => {});
    if (entries.some(({ id }) => this.pending.some(p => p.id === id))) throw new BackendError('history_unsaved');
  }

  private async transfer(): Promise<void> {
    for (let attempt = 0; ; attempt++) {
      try {
        await this.pull();
        await this.push();
        await this.pull();
        if (this.cursor > this.acknowledged) {
          await rpc('v1_acknowledge_cursor', { p_device_id: this.deviceID, p_cursor: this.cursor, p_management_token: toBytea(this.ring.managementToken) },
            { account: this.account, signal: this.signal }).then(() => { this.acknowledged = this.cursor; }, () => {});
        }
        return;
      } catch (error) {
        if (attempt > 0 || !refreshable(error)) throw error;
        // A newer epoch: refresh this browser's keys, catch up (fencing old-epoch commits), then re-seal what the
        // server still doesn't have under the new epoch with the same IDs.
        this.ring = await this.refreshRing();
        await this.pull();
        this.pending = await Promise.all(this.pending.map(async envelope => {
          if (envelope.epoch === this.ring.epoch) return envelope;
          const event = this.state.events.get(envelope.id);
          if (!event) throw new BackendError('history_unsaved');
          const resealed = await sealEvent(encodeEvent(event.payload), envelope.id, this.deviceID, this.ring);
          this.sealed.set(envelope.id, resealed.ciphertext);
          return resealed;
        }));
      }
    }
  }

  private async push(): Promise<void> {
    while (this.pending.length) {
      const envelope = this.pending[0];
      const cursor = await rpc<number>('v1_append_event', { p_device_id: this.deviceID, p_id: envelope.id, p_epoch: envelope.epoch, p_format: envelope.format,
        p_ciphertext: toBytea(envelope.ciphertext), p_management_token: toBytea(this.ring.managementToken) }, { account: this.account, signal: this.signal });
      if (!Number.isSafeInteger(cursor) || cursor <= 0) throw new BackendError('invalid_response');
      if (this.pending[0] === envelope) this.pending.shift();
      this.publish();
    }
  }

  private async pull(): Promise<void> {
    for (;;) {
      this.signal.throwIfAborted();
      const before = this.cursor;
      const page = await rpc<Page>('v2_pull_events', { p_after: before, p_limit: PAGE }, { account: this.account, signal: this.signal, maximum: PAGE_BYTES });
      if (!page || !Array.isArray(page.events) || page.events.length > PAGE || typeof page.has_more !== 'boolean'
        || page.next_cursor !== (page.events.at(-1)?.cursor ?? before) || (page.has_more && !page.events.length)) throw new BackendError('invalid_response');
      const staged: AppliedEvent[] = [], seen = new Set<string>();
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
        expected = row.cursor;
      }
      for (const event of staged) this.state.apply(event);
      this.pending = this.pending.filter(p => !seen.has(p.id));
      this.cursor = expected;
      if (staged.length || this.status === 'loading') { if (!page.has_more) this.status = 'ready'; this.publish(); }
      if (!page.has_more) return;
    }
  }
}
