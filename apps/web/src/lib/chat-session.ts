// One login lifetime owns these composers and streams. Private text remains in memory; only sealed History
// envelopes persist remotely. Paid requests require an acknowledged question. Navigation never rebinds a task.
// When a newer tab retires this page's storage, the session stops sending (BROWSER_OFFLINE_STORAGE.md, compatibility
// checkpoint): active answers stop through the existing partial-save path and drafts stay visible, read-only, to copy.
import { BackendError, config, rpc } from './backend';
import { boundedText, CONSENT_VERSION, makeRequest, resolution, streamAnswer, type ChatAction, type Outcome, type Progress, type StreamEvent } from './chat';
import { cancellation } from './cancellation';
import { encodeDiagram, type PrivateEvent, type TextAnchor } from './events';
import { History } from './history';
import { storage as browserStorage, type StorageLifecycle } from './idb';

interface Entry { id: string; event: PrivateEvent }
interface Question { revision: number; id: string; entries: Entry[]; selection: string | null; action: ChatAction | null }
export interface Composer {
  id: string; documentID: string | null; conversationID: string | null; head: string | null; draft: string; revision: number;
  phase: 'idle' | 'saving' | 'consent' | 'streaming' | 'finishing'; issue: string | null;
  question: Question | null; answer: Entry[] | null; liveID: string | null; liveText: string; progress: Progress | null; credits: number | null;
}
interface Dependencies {
  stream: (account: string, request: ReturnType<typeof makeRequest>, signal: AbortSignal) => AsyncIterable<StreamEvent>;
  readConsent: () => boolean; writeConsent: () => void;
  storage: { snapshot: () => StorageLifecycle; subscribe: (listener: () => void) => () => void };
}
const bytes = (s: string) => new TextEncoder().encode(s).length;
const scope = (documentID: string | null) => documentID ?? 'general';
const busy = (c: Composer) => c.phase === 'saving' || c.phase === 'streaming' || c.phase === 'finishing';
export const composerBusy = busy;

export class ChatSession {
  readonly composers = new Map<string, Composer>();
  readonly selected = new Map<string, string>();
  balance: { available: number; reserved: number } | null = null;
  private listeners = new Set<() => void>();
  private version = 0;
  private streams = new Map<string, ReturnType<typeof cancellation>>();
  private tasks = new Set<Promise<void>>();
  private accepting = true;
  private retiredStorage = false;
  private readonly deps: Dependencies;

  constructor(readonly account: string, readonly history: History, readonly signal: AbortSignal, dependencies: Partial<Dependencies> = {}) {
    const consentKey = `gradstep.${config.environment}.${account}.cloud-ai-consent`;
    this.deps = { stream: streamAnswer, readConsent: () => { try { return localStorage.getItem(consentKey) === CONSENT_VERSION; } catch { return false; } },
      writeConsent: () => { localStorage.setItem(consentKey, CONSENT_VERSION); if (localStorage.getItem(consentKey) !== CONSENT_VERSION) throw new Error('consent_unsaved'); },
      storage: browserStorage, ...dependencies };
    const unsubscribe = history.subscribe(() => {
      for (const c of this.composers.values()) if (c.phase === 'idle' && c.issue === 'question_unsaved' && c.question?.entries.length
        && c.question.entries.every(e => history.state.events.has(e.id) && !history.isPending(e.id))) {
        c.head = c.question.id; c.issue = 'question_ready';
        if (c.revision === c.question.revision) { c.draft = ''; c.revision++; }
        this.publish();
      }
      for (const c of this.composers.values()) if (c.answer && c.phase === 'idle' && c.answer.every(e => history.state.events.has(e.id) && !history.isPending(e.id))) {
        c.head = c.answer[0].id; c.answer = null; c.liveText = ''; c.liveID = null;
        if (c.issue === 'storage') c.issue = null;
        this.publish();
      }
    });
    const observeStorage = () => { if (this.deps.storage.snapshot().phase !== 'open') this.retireStorage(); };
    const unsubscribeStorage = this.deps.storage.subscribe(observeStorage);
    signal.addEventListener('abort', () => { unsubscribe(); unsubscribeStorage(); this.accepting = false; for (const c of this.streams.values()) c.abort(); this.listeners.clear(); }, { once: true });
    observeStorage();
  }
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
  get hasVolatileContent() { return this.history.unsaved > 0 || [...this.composers.values()].some(c => !!c.draft || busy(c) || !!c.answer); }

  current(documentID: string | null): Composer {
    const selected = this.selected.get(scope(documentID));
    return (selected && this.composers.get(selected)) || this.create(documentID);
  }
  private create(documentID: string | null): Composer {
    // Empty, inactive composers can be retired. Unsent text is never evicted to make room.
    for (const [id, c] of this.composers) if (!c.draft && !c.conversationID && !busy(c) && !c.question && !c.answer) this.composers.delete(id);

    const c: Composer = { id: crypto.randomUUID(), documentID, conversationID: null, head: null, draft: '', revision: 0,
      phase: 'idle', issue: null, question: null, answer: null, liveID: null, liveText: '', progress: null, credits: null };
    this.composers.set(c.id, c); this.selected.set(scope(documentID), c.id);
    return c;
  }
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
  discardDraft(id: string) { const c = this.composers.get(id); if (!c || busy(c) || c.answer) return; c.draft = ''; c.revision++; this.publish(); }
  edit(c: Composer, text: string): boolean {
    this.allowed();
    if (this.retiredStorage) return false;
    if ((!c.draft && text && [...this.composers.values()].filter(x => !!x.draft).length >= 128) || bytes(text) > 200_000 || [...this.composers.values()].reduce((n, x) => n + (x === c ? 0 : bytes(x.draft)), 0) + bytes(text) > 2 * 1024 * 1024) return false;
    c.draft = text; c.revision++; this.publish(); return true;
  }
  branch(c: Composer) {
    if (!c.conversationID) return null;
    const branches = this.history.state.conversationBranches(c.conversationID);
    // Explicit choices and active tasks stay fixed. A unique synced continuation can advance naturally.
    if (c.head && (busy(c) || branches.length !== 1)) return this.history.state.conversationBranch(c.conversationID, c.head);
    return branches.length === 1 ? branches[0] : c.head ? this.history.state.conversationBranch(c.conversationID, c.head) : null;
  }
  resumeAfterSignOutFailure() { if (!this.signal.aborted) this.accepting = true; }
  chooseBranch(c: Composer, head: string) { if (busy(c) || c.answer) return; c.head = head; c.question = null; c.issue = null; this.publish(); }
  async refreshBalance() {
    try {
      const balance = await rpc<{ available: number; reserved: number }>('v1_credit_balance', {}, { account: this.account, signal: this.signal });
      if (this.signal.aborted) return;
      if (Number.isSafeInteger(balance?.available) && balance.available >= 0 && Number.isSafeInteger(balance.reserved) && balance.reserved >= 0) { this.balance = balance; this.publish(); }
    } catch { /* A failed balance read never becomes a fabricated zero or client spending authority. */ }
  }
  private track(task: Promise<void>): Promise<void> { this.tasks.add(task); void task.finally(() => this.tasks.delete(task)).catch(() => {}); return task; }

  send(c: Composer, selection: string | null = null, action: ChatAction | null = null, anchor?: TextAnchor): Promise<void> {
    this.allowed();
    if (this.retiredStorage) return Promise.resolve(); // refused: nothing is saved or requested from this page
    if (busy(c) || c.answer || !c.draft.trim()) return Promise.resolve();
    if (this.history.status !== 'ready' || this.history.issue) { c.issue = 'question_unsaved'; this.publish(); return Promise.resolve(); }
    if (c.conversationID && this.history.state.isDeleted(c.conversationID)) { c.issue = 'conversation_deleted'; this.publish(); return Promise.resolve(); }
    const branch = this.branch(c);
    if (c.conversationID && (!branch || !branch.complete)) { c.issue = 'branch_required'; this.publish(); return Promise.resolve(); }
    const text = c.draft.trim(), revision = c.revision, at = Date.now(), entries: Entry[] = [];
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
        await this.history.append(entries);
        this.signal.throwIfAborted();
        if (c.revision === revision) { c.draft = ''; c.revision++; }
        c.head = id;
        await this.answerQuestion(c);
      } catch { if (!this.signal.aborted) { c.issue = 'question_unsaved'; c.phase = 'idle'; this.publish(); } }
    })());
  }

  retry(c: Composer): Promise<void> {
    this.allowed();
    if (busy(c) || this.retiredStorage) return Promise.resolve();
    c.phase = 'saving'; c.issue = null; this.publish();
    return this.track((async () => {
      try {
        if (c.answer) { await this.history.append(c.answer); c.head = c.answer[0].id; c.answer = null; c.liveText = ''; c.liveID = null; c.phase = 'idle'; this.publish(); return; }
        if (!c.question) {
          const branch = this.branch(c), last = branch?.messages.at(-1);
          if (!branch?.complete || last?.payload.role !== 'user') throw new BackendError('invalid_request');
          c.question = { revision: -1, id: last.id, entries: [], selection: null, action: null };
        }
        if (c.question.entries.length) await this.history.append(c.question.entries); else await this.history.sync();
        this.signal.throwIfAborted();
        c.head = c.question.id;
        // A failed send keeps the draft. Consume it only if it still equals that submitted text.
        const sent = c.question.entries.at(-1)?.event.text;
        if (sent !== undefined && c.revision === c.question.revision) { c.draft = ''; c.revision++; }
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
  /** Explicit sign-out drains nonempty partials while credentials/keys still belong to this account. */
  async settleBeforeSignOut() { this.accepting = false; for (const controller of this.streams.values()) controller.abort(); await Promise.allSettled([...this.tasks]); }

  private async answerQuestion(c: Composer): Promise<void> {
    this.signal.throwIfAborted();
    if (!this.accepting) { c.phase = 'idle'; this.publish(); return; }
    // A question saved while storage retired stays saved; no paid request starts from this page.
    if (this.retiredStorage) { c.phase = 'idle'; c.issue = 'storage_retired'; this.publish(); return; }
    if (this.history.status !== 'ready' || this.history.issue || !c.question || this.history.isPending(c.question.id) || this.history.state.isDeleted(c.conversationID!)) { c.phase = 'idle'; c.issue = 'question_unsaved'; this.publish(); return; }
    if (!this.deps.readConsent()) { c.phase = 'consent'; this.publish(); return; }
    const branch = this.history.state.conversationBranch(c.conversationID!, c.question.id);
    if (!branch?.complete) { c.phase = 'idle'; c.issue = 'branch_required'; this.publish(); return; }
    if (this.streams.size >= 3) { c.phase = 'idle'; c.issue = 'rate_limited'; this.publish(); return; }
    const question = c.question;
    const request = makeRequest(crypto.randomUUID(), c.documentID, branch.messages.map(e => ({ role: e.payload.role!, text: e.payload.text! })), question.selection, question.action);
    const controller = cancellation([this.signal]), deadline = setTimeout(() => controller.abort(new DOMException('Deadline', 'TimeoutError')), 210_000);
    this.streams.set(c.id, controller);
    const answerID = crypto.randomUUID(), entityID = crypto.randomUUID();
    c.liveID = entityID; c.liveText = ''; c.phase = 'streaming'; c.issue = null; c.progress = null; this.publish();
    let outcome: Outcome = { kind: 'failed', code: 'transport' }, diagram: { title: string; source: string } | null = null;
    try {
      for await (const event of this.deps.stream(this.account, request, controller.signal)) {
        controller.signal.throwIfAborted();
        if (event.type === 'delta') {
          const next = c.liveText + event.text;
          if (bytes(next) > 200_000) { c.liveText = boundedText(next); outcome = { kind: 'failed', code: 'answer_too_large' }; break; }
          c.liveText = next; c.progress = null;
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
    if (this.signal.aborted) return; // an externally retired login cannot write or expose text in its replacement
    // A valid diagram-only completion still needs an assistant event to attach the encrypted diagram to.
    if (!c.liveText.trim() && diagram && outcome.kind === 'completed' && ['end_turn', 'stop_sequence'].includes(outcome.stopReason)) c.liveText = diagram.title;
    const result = resolution(outcome, c.liveText);
    c.progress = null; c.issue = result.issue; c.phase = 'finishing';
    if (result.status) {
      const entries: Entry[] = [{ id: answerID, event: { kind: 'message', entityID, parents: [question.id], conversationID: c.conversationID!,
        documentID: c.documentID ?? undefined, text: c.liveText, role: 'assistant', status: result.status, createdAt: Date.now() } }];
      if (diagram && result.status === 'complete') entries.push({ id: crypto.randomUUID(), event: { kind: 'diagram', entityID: crypto.randomUUID(), parents: [],
        conversationID: c.conversationID!, text: encodeDiagram({ ...diagram, messageID: entityID }), createdAt: Date.now() } });
      c.answer = entries; this.publish();
      try { await this.history.append(entries); c.answer = null; c.head = answerID; } catch { c.issue = 'storage'; }
    }
    if (!c.answer) { c.liveText = ''; c.liveID = null; }
    c.phase = 'idle'; this.publish(); void this.refreshBalance();
  }
}
