// One login lifetime owns these composers and streams. Paid requests require an acknowledged question. Navigation never
// rebinds a task. When a newer tab retires this page's storage, the session stops sending (BROWSER_OFFLINE_STORAGE.md,
// compatibility checkpoint): active answers stop through the existing partial-save path and drafts stay visible,
// read-only, to copy.
//
// With the durable journal (gate 1), drafts are checkpointed on this device (sealed, debounced), a submission commits its
// question events, outbox entries and draft receipt together before anything is sent, and an answer's operation and
// identities are persisted before the paid request. Partial answers are checkpointed at most once per second; the
// final or interrupted answer retires its turn atomically. A turn whose owning tab died reopens as interrupted. Nothing
// is ever re-requested automatically. Without the journal, private text stays in memory only.
import { BackendError, config, rpc } from './backend';
import { sha256Hex, utf8 } from './bytes';
import { boundedText, CONSENT_VERSION, makeRequest, requestBody, resolution, streamAnswer, type ChatAction, type Outcome, type Progress, type StreamEvent } from './chat';
import { cancellation } from './cancellation';
import { encodeDiagram, type PrivateEvent, type TextAnchor } from './events';
import { History } from './history';
import { storage as browserStorage, type StorageLifecycle } from './idb';
import type { Journal, StoredDraft, StoredTurn } from './journal';

interface Entry { id: string; event: PrivateEvent }
interface Question { revision: number; id: string; entries: Entry[]; selection: string | null; action: ChatAction | null }
type Receipt = NonNullable<StoredDraft['receipt']>;
export interface Composer {
  id: string; documentID: string | null; conversationID: string | null; head: string | null; draft: string; revision: number;
  phase: 'idle' | 'saving' | 'consent' | 'streaming' | 'finishing'; issue: string | null;
  question: Question | null; answer: Entry[] | null; liveID: string | null; liveText: string; progress: Progress | null; credits: number | null;
  /** Identity of the current text edit (a new one per edit, even when the text repeats). */
  textRevision: string;
  /** The latest revision committed on this device (durable journal only). */
  savedRevision: number;
  receipt: Receipt | null;
}
/** Whether this page's drafts survive a reload, and if not, why. */
export type JournalState = 'active' | 'inactive' | 'unsupported' | 'newer' | 'damaged' | 'unavailable';
interface Locks {
  /** Holds a named Web Lock until released (or the page goes away). */
  hold: (name: string) => Promise<() => void>;
  /** Acquires a named lock only if no live tab holds it. */
  tryHold: (name: string) => Promise<(() => void) | null>;
}
interface Dependencies {
  stream: (account: string, request: ReturnType<typeof makeRequest>, signal: AbortSignal) => AsyncIterable<StreamEvent>;
  readConsent: () => boolean; writeConsent: () => void;
  storage: { snapshot: () => StorageLifecycle; subscribe: (listener: () => void) => () => void };
  journal: Journal | null;
  locks: Locks;
}
const bytes = (s: string) => new TextEncoder().encode(s).length;
const scope = (documentID: string | null) => documentID ?? 'general';
const busy = (c: Composer) => c.phase === 'saving' || c.phase === 'streaming' || c.phase === 'finishing';
export const composerBusy = busy;
const CHECKPOINT_DELAY = 400, CHECKPOINT_MAX = 2_000, TURN_INTERVAL = 1_000;

export const browserLocks: Locks = {
  hold: name => new Promise((resolve, reject) => {
    if (!navigator.locks) { reject(new Error('locks_unavailable')); return; }
    navigator.locks.request(name, () => new Promise<void>(release => resolve(() => release()))).catch(reject);
  }),
  tryHold: name => new Promise((resolve, reject) => {
    if (!navigator.locks) { reject(new Error('locks_unavailable')); return; }
    navigator.locks.request(name, { ifAvailable: true }, lock => lock ? new Promise<void>(release => resolve(() => release())) : (resolve(null), undefined))
      .catch(reject);
  }),
};

export class ChatSession {
  readonly composers = new Map<string, Composer>();
  readonly selected = new Map<string, string>();
  balance: { available: number; reserved: number } | null = null;
  journalState: JournalState;
  private listeners = new Set<() => void>();
  private version = 0;
  private streams = new Map<string, ReturnType<typeof cancellation>>();
  private tasks = new Set<Promise<void>>();
  private accepting = true;
  private retiredStorage = false;
  private readonly deps: Dependencies;
  private journal: Journal | null;
  /** Editor locks: one live tab owns each composer; another tab can't load or overwrite it. */
  private editors = new Map<string, Promise<() => void>>();
  private checkpoints = new Map<string, { timer: ReturnType<typeof setTimeout>; since: number }>();
  private writes: Promise<void> = Promise.resolve();

  constructor(readonly account: string, readonly history: History, readonly signal: AbortSignal, dependencies: Partial<Dependencies> = {}, journalState?: JournalState) {
    const consentKey = `gradstep.${config.environment}.${account}.cloud-ai-consent`;
    this.deps = { stream: streamAnswer, readConsent: () => { try { return localStorage.getItem(consentKey) === CONSENT_VERSION; } catch { return false; } },
      writeConsent: () => { localStorage.setItem(consentKey, CONSENT_VERSION); if (localStorage.getItem(consentKey) !== CONSENT_VERSION) throw new Error('consent_unsaved'); },
      storage: browserStorage, journal: null, locks: browserLocks, ...dependencies };
    this.journal = this.deps.journal;
    this.journalState = journalState ?? (this.journal ? 'active' : 'inactive');
    const unsubscribe = history.subscribe(() => {
      for (const c of this.composers.values()) if (c.phase === 'idle' && c.issue === 'question_unsaved' && c.question?.entries.length
        && c.question.entries.every(e => history.state.events.has(history.resolve(e.id)) && !history.isPending(e.id))) {
        c.head = history.resolve(c.question.id); c.issue = 'question_ready';
        if (c.revision === c.question.revision) this.consume(c);
        this.publish();
      }
      for (const c of this.composers.values()) if (c.answer && c.phase === 'idle' && c.answer.every(e => history.state.events.has(history.resolve(e.id)) && !history.isPending(e.id))) {
        c.head = history.resolve(c.answer[0].id); c.answer = null; c.liveText = ''; c.liveID = null;
        if (c.issue === 'storage') c.issue = null;
        this.publish();
      }
    });
    const unsubscribeRebase = history.subscribeRebase(mapping => this.remap(mapping));
    const observeStorage = () => { if (this.deps.storage.snapshot().phase !== 'open') this.retireStorage(); };
    const unsubscribeStorage = this.deps.storage.subscribe(observeStorage);
    signal.addEventListener('abort', () => {
      unsubscribe(); unsubscribeRebase(); unsubscribeStorage(); this.accepting = false;
      for (const c of this.streams.values()) c.abort();
      for (const { timer } of this.checkpoints.values()) clearTimeout(timer);
      this.checkpoints.clear(); this.listeners.clear(); this.releaseEditors();
    }, { once: true });
    observeStorage();
  }
  /** Drafts and interrupted answers survive a reload in this browser. */
  get durable() { return !!this.journal?.active && this.history.durable; }
  /** Storage was retired by a newer tab: this page sends nothing new, but its unsent text stays readable. */
  get storageRetired() { return this.retiredStorage; }
  private retireStorage() {
    if (this.retiredStorage || this.signal.aborted) return;
    this.retiredStorage = true;
    // While this account is still valid, stopping goes through the ordinary partial-save path (interrupted answer).
    for (const controller of this.streams.values()) controller.abort(new DOMException('Storage retired', 'AbortError'));
    for (const c of this.composers.values()) if (c.phase === 'consent') { c.phase = 'idle'; c.issue = 'storage_retired'; }
    this.publish();
  }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  getVersion = () => this.version;
  private publish() { if (!this.signal.aborted) { this.version++; for (const listener of this.listeners) listener(); } }
  private allowed() { this.signal.throwIfAborted(); if (!this.accepting) throw new BackendError('cancelled'); }
  /** Work a reload or closing the tab would lose (the before-unload warning and storage-update deferral use this). */
  get hasVolatileContent() {
    if (this.durable) return [...this.composers.values()].some(c => (c.revision > c.savedRevision && (!!c.draft || c.savedRevision > 0)) || busy(c) || !!c.answer);
    return this.history.unsaved > 0 || [...this.composers.values()].some(c => !!c.draft || busy(c) || !!c.answer);
  }

  // ---------- Composers ----------

  current(documentID: string | null): Composer {
    const selected = this.selected.get(scope(documentID));
    return (selected && this.composers.get(selected)) || this.create(documentID);
  }
  private blank(documentID: string | null, id: string = crypto.randomUUID()): Composer {
    return { id, documentID, conversationID: null, head: null, draft: '', revision: 0, phase: 'idle', issue: null, question: null, answer: null,
      liveID: null, liveText: '', progress: null, credits: null, textRevision: crypto.randomUUID(), savedRevision: 0, receipt: null };
  }
  private create(documentID: string | null): Composer {
    // Empty, inactive composers can be retired. Unsent text is never evicted to make room.
    for (const [id, c] of this.composers) if (!c.draft && !c.conversationID && !busy(c) && !c.question && !c.answer && c.savedRevision === 0) { this.composers.delete(id); this.releaseEditor(id); }
    const c = this.blank(documentID);
    this.composers.set(c.id, c); this.selected.set(scope(documentID), c.id);
    this.claimEditor(c.id);
    return c;
  }
  private claimEditor(id: string) {
    if (!this.journal || this.editors.has(id)) return;
    const held = this.deps.locks.hold(`gradstep.composer.${id}`);
    held.catch(() => {});
    this.editors.set(id, held);
  }
  private releaseEditor(id: string) { const held = this.editors.get(id); this.editors.delete(id); void held?.then(release => release(), () => {}); }
  private releaseEditors() { for (const id of [...this.editors.keys()]) this.releaseEditor(id); }

  newChat(documentID: string | null): Composer { this.allowed(); const c = this.create(documentID); this.publish(); return c; }
  open(conversationID: string): Composer | null {
    this.allowed();
    const summary = this.history.state.conversationSummaries().find(c => c.id === conversationID);
    if (!summary) return null;
    let c = [...this.composers.values()].find(c => c.conversationID === conversationID);
    if (!c) { c = this.create(summary.documentID ?? null); c.conversationID = conversationID; }
    this.selected.set(scope(c.documentID), c.id); this.publish(); return c;
  }
  chooseDraft(id: string) { const c = this.composers.get(id); if (c) { this.selected.set(scope(c.documentID), id); this.publish(); } return c; }
  discardDraft(id: string) {
    const c = this.composers.get(id);
    if (!c || busy(c) || c.answer) return;
    if (!this.journal || (c.savedRevision === 0 && !this.checkpoints.has(id))) { c.draft = ''; c.revision++; c.textRevision = crypto.randomUUID(); this.publish(); return; }
    // An encrypted tombstone: no delayed checkpoint can resurrect this composer. Later typing gets a new composer ID.
    this.cancelCheckpoint(c);
    const observed = c.revision, template = { id: c.id, documentID: c.documentID, conversationID: c.conversationID, head: c.head, textRevision: c.textRevision, editedAt: Date.now() };
    const replacement = { ...this.blank(c.documentID), conversationID: c.conversationID, head: c.head };
    this.composers.delete(c.id); this.composers.set(replacement.id, replacement);
    if (this.selected.get(scope(c.documentID)) === c.id) this.selected.set(scope(c.documentID), replacement.id);
    this.claimEditor(replacement.id);
    this.publish();
    this.queue(() => this.journal!.discardDraft(c.id, observed, template)).finally(() => this.releaseEditor(c.id)).catch(() => {});
  }
  edit(c: Composer, text: string): boolean {
    this.allowed();
    if (this.retiredStorage) return false;
    if ((!c.draft && text && [...this.composers.values()].filter(x => !!x.draft).length >= 128) || bytes(text) > 200_000 || [...this.composers.values()].reduce((n, x) => n + (x === c ? 0 : bytes(x.draft)), 0) + bytes(text) > 2 * 1024 * 1024) return false;
    c.draft = text; c.revision++; c.textRevision = crypto.randomUUID(); this.scheduleCheckpoint(c); this.publish(); return true;
  }
  branch(c: Composer) {
    if (!c.conversationID) return null;
    const branches = this.history.state.conversationBranches(c.conversationID);
    const head = c.head && this.history.resolve(c.head);
    // Explicit choices and active tasks stay fixed. A unique synced continuation can advance naturally.
    if (head && (busy(c) || branches.length !== 1)) return this.history.state.conversationBranch(c.conversationID, head);
    return branches.length === 1 ? branches[0] : head ? this.history.state.conversationBranch(c.conversationID, head) : null;
  }
  resumeAfterSignOutFailure() { if (!this.signal.aborted) this.accepting = true; }
  chooseBranch(c: Composer, head: string) { if (busy(c) || c.answer) return; c.head = head; c.question = null; c.issue = null; c.revision++; this.scheduleCheckpoint(c); this.publish(); }

  // ---------- Device checkpoints (durable journal) ----------

  private queue(write: () => Promise<void>): Promise<void> {
    const next = this.writes.then(write);
    this.writes = next.catch(() => {});
    return next;
  }
  private record(c: Composer): StoredDraft {
    return { id: c.id, documentID: c.documentID, conversationID: c.conversationID, head: c.head, revision: c.revision, textRevision: c.textRevision,
      text: c.draft, editedAt: Date.now(), receipt: c.receipt, discarded: false };
  }
  private scheduleCheckpoint(c: Composer) {
    if (!this.journal) return;
    const pending = this.checkpoints.get(c.id), now = Date.now();
    if (pending) clearTimeout(pending.timer);
    const since = pending?.since ?? now;
    // A short debounce while typing, bounded so continuous typing still commits about every two seconds.
    const timer = setTimeout(() => void this.checkpoint(c), now - since >= CHECKPOINT_MAX ? 0 : CHECKPOINT_DELAY);
    this.checkpoints.set(c.id, { timer, since });
  }
  private cancelCheckpoint(c: Composer) { const pending = this.checkpoints.get(c.id); if (pending) { clearTimeout(pending.timer); this.checkpoints.delete(c.id); } }
  private checkpoint(c: Composer): Promise<void> {
    this.cancelCheckpoint(c);
    if (!this.journal || this.signal.aborted || !this.composers.has(c.id)) return Promise.resolve();
    const record = this.record(c);
    return this.queue(async () => {
      try {
        await this.journal!.checkpointDraft(record);
        if (record.revision > c.savedRevision) c.savedRevision = record.revision;
        if (c.issue === 'local_save') c.issue = null;
      } catch (error) {
        // Capacity, quota or I/O: the previous checkpoint stays; the text stays here. Nothing is evicted.
        if ((error as { code?: string }).code !== 'journal_discarded' && !this.signal.aborted && this.composers.has(c.id)) c.issue = 'local_save';
      }
      this.publish();
    });
  }
  /** Commits every scheduled draft checkpoint and waits for accepted device writes (before sign-out or navigation). */
  async flushCheckpoints(): Promise<void> {
    const due = [...this.checkpoints.keys()].map(id => this.composers.get(id)).filter((c): c is Composer => !!c);
    await Promise.allSettled(due.map(c => this.checkpoint(c)));
    await this.writes;
    await this.journal?.drain();
  }
  private consume(c: Composer) { c.draft = ''; c.revision++; c.textRevision = crypto.randomUUID(); }
  private remap(mapping: Map<string, string>) {
    const map = (id: string) => mapping.get(id) ?? id;
    const entries = (list: Entry[]) => list.map(e => ({ id: map(e.id), event: { ...e.event, parents: e.event.parents.map(map) } }));
    for (const c of this.composers.values()) {
      if (c.head) c.head = map(c.head);
      if (c.question) c.question = { ...c.question, id: map(c.question.id), entries: entries(c.question.entries) };
      if (c.answer) c.answer = entries(c.answer);
      if (c.receipt) c.receipt = { ...c.receipt, submissionID: map(c.receipt.submissionID), eventIDs: c.receipt.eventIDs.map(map) };
    }
    this.publish();
  }

  /**
   * Restores this account's drafts and recovers abandoned answers after a reload. A composer still open in another live
   * tab stays there. A turn is recovered only after acquiring its owner lock (elapsed time proves nothing): its saved
   * partial text becomes an interrupted answer; an empty one is removed. No request is ever retried here.
   */
  async restore(drafts: StoredDraft[], turns: StoredTurn[]): Promise<void> {
    if (!this.journal) return;
    const reclaim: string[] = [];
    const restored: Composer[] = [];
    for (const d of drafts) {
      const release = await this.deps.locks.tryHold(`gradstep.composer.${d.id}`).catch(() => null);
      if (!release) continue; // a live tab owns it
      const pendingSubmission = !!d.receipt && this.history.isPending(d.receipt.submissionID);
      if (d.discarded || (!d.text && !(d.conversationID && d.receipt))) { reclaim.push(d.id); release(); continue; }
      const c: Composer = { ...this.blank(d.documentID, d.id), conversationID: d.conversationID, head: d.head && this.history.resolve(d.head), draft: d.text,
        revision: d.revision, savedRevision: d.revision, textRevision: d.textRevision, receipt: d.receipt && { ...d.receipt,
          submissionID: this.history.resolve(d.receipt.submissionID), eventIDs: d.receipt.eventIDs.map(id => this.history.resolve(id)) } };
      if (pendingSubmission) c.question = { revision: -1, id: c.receipt!.submissionID, entries: [], selection: null, action: null };
      this.composers.set(c.id, c); this.editors.set(c.id, Promise.resolve(release));
      restored.push(c);
      (d as StoredDraft & { at?: number }).at = d.editedAt;
    }
    for (const c of restored.sort((a, b) => (drafts.find(d => d.id === a.id)!.editedAt - drafts.find(d => d.id === b.id)!.editedAt))) this.selected.set(scope(c.documentID), c.id);
    if (reclaim.length) await this.journal.collectDrafts(reclaim).catch(() => {});
    for (const turn of turns) {
      const release = await this.deps.locks.tryHold(`gradstep.turn.${turn.id}`).catch(() => null);
      if (!release) continue; // its stream is still running in another tab
      try {
        if (!turn.text.trim()) { await this.journal.dropTurn(turn.id); continue; }
        await this.history.commit([{ id: turn.id, event: { kind: 'message', entityID: turn.entityID, parents: [this.history.resolve(turn.questionID)],
          conversationID: turn.conversationID, documentID: turn.documentID ?? undefined, text: turn.text, role: 'assistant', status: 'interrupted', createdAt: turn.updatedAt } }],
          { finishTurn: turn.id });
      } catch { /* kept for the next open; never re-requested */ } finally { release(); }
    }
    this.publish();
  }

  async refreshBalance() {
    try {
      const balance = await rpc<{ available: number; reserved: number }>('v1_credit_balance', {}, { account: this.account, signal: this.signal });
      if (this.signal.aborted) return;
      if (Number.isSafeInteger(balance?.available) && balance.available >= 0 && Number.isSafeInteger(balance.reserved) && balance.reserved >= 0) { this.balance = balance; this.publish(); }
    } catch { /* A failed balance read never becomes a fabricated zero or client spending authority. */ }
  }
  private track(task: Promise<void>): Promise<void> { this.tasks.add(task); void task.finally(() => this.tasks.delete(task)).catch(() => {}); return task; }

  // ---------- Sending ----------

  send(c: Composer, selection: string | null = null, action: ChatAction | null = null, anchor?: TextAnchor): Promise<void> {
    this.allowed();
    if (this.retiredStorage) return Promise.resolve(); // refused: nothing is saved or requested from this page
    if (busy(c) || c.answer || !c.draft.trim()) return Promise.resolve();
    if (this.history.status !== 'ready' || this.history.issue) { c.issue = 'question_unsaved'; this.publish(); return Promise.resolve(); }
    if (c.conversationID && this.history.state.isDeleted(c.conversationID)) { c.issue = 'conversation_deleted'; this.publish(); return Promise.resolve(); }
    const branch = this.branch(c);
    if (c.conversationID && (!branch || !branch.complete)) { c.issue = 'branch_required'; this.publish(); return Promise.resolve(); }
    const text = c.draft.trim(), revision = c.revision, textRevision = c.textRevision, at = Date.now(), entries: Entry[] = [];
    const previous = { conversationID: c.conversationID, head: c.head, receipt: c.receipt };
    if (!c.conversationID) {
      c.conversationID = crypto.randomUUID();
      const root = crypto.randomUUID();
      entries.push({ id: root, event: { kind: 'conversation', entityID: c.conversationID, parents: [], documentID: c.documentID ?? undefined,
        text: [...text].slice(0, 100).join(''), anchor, createdAt: at } });
      c.head = root;
    } else c.head = branch!.head;
    const id = crypto.randomUUID();
    entries.push({ id, event: { kind: 'message', entityID: crypto.randomUUID(), parents: [c.head!], conversationID: c.conversationID,
      documentID: c.documentID ?? undefined, text, role: 'user', status: 'complete', createdAt: at } });
    c.question = { revision, id, entries, selection, action }; c.phase = 'saving'; c.issue = null; c.credits = null;
    this.publish();
    return this.track((async () => {
      try {
        if (this.durable) {
          // One local transaction: root/question events, their exact outbox bytes and the receipt that consumes only the
          // captured text revision. Newer typing survives; a failure leaves the previous checkpoint and this text.
          const receipt: Receipt = { submissionID: id, eventIDs: entries.map(e => e.id), textRevision, revision };
          this.cancelCheckpoint(c);
          try { await this.history.commit(entries, { draft: { ...this.record(c), head: id, receipt } }); }
          catch (error) { Object.assign(c, previous); c.question = null; throw Object.assign(error as object, { local: true }); }
          this.signal.throwIfAborted();
          c.receipt = receipt; c.head = id;
          if (c.textRevision === textRevision) this.consume(c);
          c.savedRevision = Math.max(c.savedRevision, revision);
          this.publish();
          if (c.revision > c.savedRevision) this.scheduleCheckpoint(c);
          await this.history.flush(entries.map(e => e.id));
        } else {
          await this.history.append(entries);
          this.signal.throwIfAborted();
          if (c.revision === revision) this.consume(c);
          c.head = id;
        }
        await this.answerQuestion(c);
      } catch (error) {
        if (!this.signal.aborted) { c.issue = (error as { local?: boolean }).local ? 'local_save' : 'question_unsaved'; c.phase = 'idle'; this.publish(); }
      }
    })());
  }

  retry(c: Composer): Promise<void> {
    this.allowed();
    if (busy(c) || this.retiredStorage) return Promise.resolve();
    c.phase = 'saving'; c.issue = null; this.publish();
    return this.track((async () => {
      try {
        if (c.answer) {
          await this.history.append(c.answer, this.durable ? { finishTurn: c.answer[0].id } : {});
          c.head = this.history.resolve(c.answer[0].id); c.answer = null; c.liveText = ''; c.liveID = null; c.phase = 'idle'; this.publish(); return;
        }
        if (!c.question) {
          const branch = this.branch(c), last = branch?.messages.at(-1);
          if (!branch?.complete || last?.payload.role !== 'user') throw new BackendError('invalid_request');
          c.question = { revision: -1, id: last.id, entries: [], selection: null, action: null };
        }
        if (c.question.entries.length) {
          const receipt = c.receipt?.submissionID === c.question.id ? c.receipt : null;
          await this.history.append(c.question.entries, this.durable && receipt ? { draft: { ...this.record(c), receipt } } : {});
        } else await this.history.flush([c.question.id]);
        this.signal.throwIfAborted();
        c.head = this.history.resolve(c.question.id);
        // A failed send keeps the draft. Consume it only if it still equals that submitted text.
        const sent = c.question.entries.at(-1)?.event.text;
        if (sent !== undefined && c.revision === c.question.revision) this.consume(c);
        await this.answerQuestion(c);
      } catch { if (!this.signal.aborted) { c.issue = c.answer ? 'storage' : 'question_unsaved'; c.phase = 'idle'; this.publish(); } }
    })());
  }
  consent(c: Composer, accepted: boolean): Promise<void> {
    this.allowed();
    if (c.phase !== 'consent') return Promise.resolve();
    if (this.retiredStorage) { c.phase = 'idle'; c.issue = 'storage_retired'; this.publish(); return Promise.resolve(); }
    if (!accepted) { c.phase = 'idle'; c.issue = 'consent_declined'; this.publish(); return Promise.resolve(); }
    try { this.deps.writeConsent(); } catch { c.phase = 'idle'; c.issue = 'consent_unsaved'; this.publish(); return Promise.resolve(); }
    return this.track(this.answerQuestion(c));
  }
  stop(c: Composer) { this.streams.get(c.id)?.abort(); }
  /** Explicit sign-out drains nonempty partials and device writes while credentials/keys still belong to this account. */
  async settleBeforeSignOut() {
    this.accepting = false;
    for (const controller of this.streams.values()) controller.abort();
    await Promise.allSettled([...this.tasks]);
    await this.flushCheckpoints().catch(() => {});
  }
  /** After explicit sign-out (and any local removal): retire this login lifetime's journal writer. */
  async retireJournal() { await this.journal?.signOut().catch(() => {}); }

  private async answerQuestion(c: Composer): Promise<void> {
    this.signal.throwIfAborted();
    if (!this.accepting) { c.phase = 'idle'; this.publish(); return; }
    // A question saved while storage retired stays saved; no paid request starts from this page.
    if (this.retiredStorage) { c.phase = 'idle'; c.issue = 'storage_retired'; this.publish(); return; }
    const questionID = c.question ? this.history.resolve(c.question.id) : null;
    if (this.history.status !== 'ready' || this.history.issue || !c.question || !questionID || this.history.isPending(questionID) || this.history.state.isDeleted(c.conversationID!)) { c.phase = 'idle'; c.issue = 'question_unsaved'; this.publish(); return; }
    if (!this.deps.readConsent()) { c.phase = 'consent'; this.publish(); return; }
    const branch = this.history.state.conversationBranch(c.conversationID!, questionID);
    if (!branch?.complete) { c.phase = 'idle'; c.issue = 'branch_required'; this.publish(); return; }
    if (this.streams.size >= 3) { c.phase = 'idle'; c.issue = 'rate_limited'; this.publish(); return; }
    const question = c.question;
    const request = makeRequest(crypto.randomUUID(), c.documentID, branch.messages.map(e => ({ role: e.payload.role!, text: e.payload.text! })), question.selection, question.action);
    const answerID = crypto.randomUUID(), entityID = crypto.randomUUID(), conversationID = c.conversationID!;
    let turn: StoredTurn | null = null, releaseTurn: (() => void) | null = null;
    if (this.durable) {
      // The operation, request digest, answer identities and owner are durable before the paid request starts.
      c.phase = 'saving'; this.publish();
      try {
        releaseTurn = await this.deps.locks.hold(`gradstep.turn.${answerID}`);
        const now = Date.now();
        turn = { id: answerID, entityID, composerID: c.id, conversationID, documentID: c.documentID, questionID, operationID: request.operationID,
          requestDigest: await sha256Hex(utf8(JSON.stringify(requestBody(request)))), text: '', startedAt: now, updatedAt: now };
        await this.journal!.beginTurn(turn);
      } catch {
        releaseTurn?.();
        if (!this.signal.aborted) { c.phase = 'idle'; c.issue = 'local_save'; this.publish(); }
        return;
      }
      if (this.signal.aborted || this.retiredStorage || !this.accepting) { await this.journal!.dropTurn(answerID).catch(() => {}); releaseTurn(); if (!this.signal.aborted) { c.phase = 'idle'; this.publish(); } return; }
    }
    const controller = cancellation([this.signal]), deadline = setTimeout(() => controller.abort(new DOMException('Deadline', 'TimeoutError')), 210_000);
    this.streams.set(c.id, controller);
    c.liveID = entityID; c.liveText = ''; c.phase = 'streaming'; c.issue = null; c.progress = null; this.publish();
    let outcome: Outcome = { kind: 'failed', code: 'transport' }, diagram: { title: string; source: string } | null = null;
    let lastCheckpoint = Date.now(), checkpointing: Promise<void> = Promise.resolve();
    const checkpointTurn = (force = false) => {
      if (!turn || (!force && Date.now() - lastCheckpoint < TURN_INTERVAL)) return;
      lastCheckpoint = Date.now();
      const snapshot = { ...turn, text: c.liveText, updatedAt: lastCheckpoint };
      checkpointing = checkpointing.then(() => this.journal!.checkpointTurn(snapshot)).catch(() => {});
    };
    try {
      for await (const event of this.deps.stream(this.account, request, controller.signal)) {
        controller.signal.throwIfAborted();
        if (event.type === 'delta') {
          const next = c.liveText + event.text;
          if (bytes(next) > 200_000) { c.liveText = boundedText(next); outcome = { kind: 'failed', code: 'answer_too_large' }; break; }
          c.liveText = next; c.progress = null; checkpointTurn();
        } else if (event.type === 'status') c.progress = event.progress;
        else if (event.type === 'diagram') diagram = event;
        else if (event.type === 'error') { outcome = { kind: 'failed', code: event.code }; break; }
        else { outcome = { kind: 'completed', stopReason: event.stopReason }; c.credits = event.credits; break; }
        this.publish();
      }
    } catch (error) {
      outcome = controller.signal.aborted && controller.signal.reason?.name !== 'TimeoutError' ? { kind: 'cancelled' }
        : { kind: 'failed', code: error instanceof BackendError && error.code !== 'connection' ? error.code : 'transport' };
    } finally { clearTimeout(deadline); controller.dispose(); this.streams.delete(c.id); }
    await checkpointing;
    // An externally retired login cannot write or expose text in its replacement. Its turn checkpoint stays on this
    // device and reopens as interrupted on the next sign-in; it is never re-requested.
    if (this.signal.aborted) { releaseTurn?.(); return; }
    // A valid diagram-only completion still needs an assistant event to attach the encrypted diagram to.
    if (!c.liveText.trim() && diagram && outcome.kind === 'completed' && ['end_turn', 'stop_sequence'].includes(outcome.stopReason)) c.liveText = diagram.title;
    const result = resolution(outcome, c.liveText);
    c.progress = null; c.issue = result.issue; c.phase = 'finishing';
    if (result.status) {
      const entries: Entry[] = [{ id: answerID, event: { kind: 'message', entityID, parents: [question.id], conversationID,
        documentID: c.documentID ?? undefined, text: c.liveText, role: 'assistant', status: result.status, createdAt: Date.now() } }];
      if (diagram && result.status === 'complete') entries.push({ id: crypto.randomUUID(), event: { kind: 'diagram', entityID: crypto.randomUUID(), parents: [],
        conversationID, text: encodeDiagram({ ...diagram, messageID: entityID }), createdAt: Date.now() } });
      c.answer = entries; this.publish();
      if (this.durable) {
        // The final or interrupted answer enters the outbox in the same transaction that retires its turn.
        try { await this.history.commit(entries, { finishTurn: answerID }); c.answer = null; c.head = this.history.resolve(answerID); }
        catch { c.issue = 'storage'; }
        if (!c.answer) void this.history.flush(entries.map(e => e.id)).catch(() => {});
      } else {
        try { await this.history.append(entries); c.answer = null; c.head = answerID; } catch { c.issue = 'storage'; }
      }
    } else if (turn) await this.journal!.dropTurn(answerID).catch(() => {}); // a refusal or empty answer leaves no partial
    releaseTurn?.();
    if (!c.answer) { c.liveText = ''; c.liveID = null; }
    c.phase = 'idle'; this.publish(); void this.refreshBalance();
  }
}
