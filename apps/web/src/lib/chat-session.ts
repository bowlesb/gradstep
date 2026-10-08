// One login lifetime owns these composers and streams. Private text remains in memory; only sealed History
// envelopes persist remotely. Paid requests require an acknowledged question. Navigation never rebinds a task.
import { BackendError, config, rpc } from './backend';
import { boundedText, CONSENT_VERSION, makeRequest, resolution, streamAnswer, type ChatAction, type Outcome, type Progress, type StreamEvent } from './chat';
import { isProfileChoice, offers, parseProfileID, ProfileTableLoader, STANDARD_PROFILE, type ProfileChoice, type ProfileTable } from './chat-profiles';
import { cancellation } from './cancellation';
import { encodeDiagram, GENERATED_TITLE, RENAMED_TITLE, type PrivateEvent, type TextAnchor } from './events';
import { History } from './history';

interface Entry { id: string; event: PrivateEvent }
interface Question { revision: number; id: string; entries: Entry[]; selection: string | null; action: ChatAction | null }
export interface Composer {
  id: string; documentID: string | null; conversationID: string | null; head: string | null; draft: string; revision: number;
  phase: 'idle' | 'saving' | 'consent' | 'streaming' | 'finishing'; issue: string | null;
  question: Question | null; answer: Entry[] | null; liveID: string | null; liveText: string; progress: Progress | null; credits: number | null;
  /** A model/effort/length the reader chose here (memory only); null follows the conversation, then the default. */
  profile: ProfileChoice | null;
}
interface Dependencies {
  stream: (account: string, request: ReturnType<typeof makeRequest>, signal: AbortSignal) => AsyncIterable<StreamEvent>;
  readConsent: () => boolean; writeConsent: () => void;
  /** The published profile table (GET functions/v1/chat); undefined uses the backend. */
  fetchProfiles?: (account: string, signal: AbortSignal) => Promise<unknown>;
  /** This browser's default for new chats (a per-browser presentation preference). */
  readDefault: () => ProfileChoice | null; writeDefault: (choice: ProfileChoice) => void;
}
const DEFAULT_KEY = 'gradstep.chat-defaults.v1';
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
  private readonly deps: Dependencies;
  readonly profiles: ProfileTableLoader;
  private browserDefault: ProfileChoice | null;

  constructor(readonly account: string, readonly history: History, readonly signal: AbortSignal, dependencies: Partial<Dependencies> = {}) {
    const consentKey = `gradstep.${config.environment}.${account}.cloud-ai-consent`;
    this.deps = { stream: streamAnswer, readConsent: () => { try { return localStorage.getItem(consentKey) === CONSENT_VERSION; } catch { return false; } },
      writeConsent: () => { localStorage.setItem(consentKey, CONSENT_VERSION); if (localStorage.getItem(consentKey) !== CONSENT_VERSION) throw new Error('consent_unsaved'); },
      readDefault: () => { try { const v = JSON.parse(localStorage.getItem(DEFAULT_KEY) ?? 'null') as unknown; return isProfileChoice(v) ? { model: v.model, effort: v.effort, length: v.length } : null; } catch { return null; } },
      writeDefault: choice => { try { localStorage.setItem(DEFAULT_KEY, JSON.stringify(choice)); } catch { /* per-browser convenience only */ } },
      ...dependencies };
    this.profiles = new ProfileTableLoader(account, signal, this.deps.fetchProfiles);
    this.browserDefault = this.deps.readDefault();
    // Fetched ahead of the first answer; until it arrives (or if this server predates profiles) requests stay default.
    void this.profiles.load().then(table => { if (table) this.publish(); });
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
    signal.addEventListener('abort', () => { unsubscribe(); this.accepting = false; for (const c of this.streams.values()) c.abort(); this.listeners.clear(); }, { once: true });
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
      phase: 'idle', issue: null, question: null, answer: null, liveID: null, liveText: '', progress: null, credits: null, profile: null };
    this.composers.set(c.id, c); this.selected.set(scope(documentID), c.id);
    return c;
  }
  /** `profile`: a selection action carries the choice shown in the chat pane into its new conversation. */
  newChat(documentID: string | null, profile: ProfileChoice | null = null): Composer {
    this.allowed(); const c = this.create(documentID); c.profile = profile ? { ...profile } : null; this.publish(); return c;
  }

  // ---------- Model, effort and length ----------

  get profileTable(): ProfileTable | null { return this.profiles.table; }
  /** New chats start here: this browser's choice, else the server's default (Sonnet · Low · Standard). */
  get defaultProfile(): ProfileChoice {
    const table = this.profiles.table, saved = this.browserDefault;
    if (saved && (!table || offers(table, saved))) return saved;
    return table?.defaultChoice ?? STANDARD_PROFILE;
  }
  setDefaultProfile(choice: ProfileChoice) { this.browserDefault = { ...choice }; this.deps.writeDefault(this.browserDefault); this.publish(); }
  /** The chat's current choice: one made here, else the profile its newest answer used, else the default. */
  profileFor(c: Composer): ProfileChoice {
    const table = this.profiles.table;
    const usable = (choice: ProfileChoice | null) => !!choice && (!table || offers(table, choice));
    if (c.profile && usable(c.profile)) return c.profile;
    const answers = this.branch(c)?.messages.filter(m => m.payload.role === 'assistant') ?? [];
    for (const answer of [...answers].reverse()) { const used = parseProfileID(answer.payload.profile); if (used && usable(used)) return used; }
    return this.defaultProfile;
  }
  setProfile(c: Composer, choice: ProfileChoice) { c.profile = { ...choice }; this.publish(); }

  /** Whether the conversation has a topic title (generated or the reader's own). */
  hasTopicTitle(conversationID: string | null): boolean {
    return !!conversationID && !!this.history.state.conversationSummaries().find(s => s.id === conversationID)?.titleSource;
  }
  /** Rename: a conversation revision with the reader's title (≤ 80 characters), which a generated title never replaces. */
  async rename(conversationID: string, title: string): Promise<boolean> {
    this.allowed();
    const event = this.history.state.titledConversation(conversationID, title, RENAMED_TITLE);
    if (!event) return false;
    await this.history.append([{ id: crypto.randomUUID(), event }]);
    return true;
  }
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
    if (busy(c)) return Promise.resolve();
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
    if (this.history.status !== 'ready' || this.history.issue || !c.question || this.history.isPending(c.question.id) || this.history.state.isDeleted(c.conversationID!)) { c.phase = 'idle'; c.issue = 'question_unsaved'; this.publish(); return; }
    if (!this.deps.readConsent()) { c.phase = 'consent'; this.publish(); return; }
    const branch = this.history.state.conversationBranch(c.conversationID!, c.question.id);
    if (!branch?.complete) { c.phase = 'idle'; c.issue = 'branch_required'; this.publish(); return; }
    if (this.streams.size >= 3) { c.phase = 'idle'; c.issue = 'rate_limited'; this.publish(); return; }
    const question = c.question;
    // Choices and titles go only to a server that published its profile table (one that accepts them).
    const table = await this.profiles.load();
    if (this.signal.aborted) return;
    const request = makeRequest(crypto.randomUUID(), c.documentID, branch.messages.map(e => ({ role: e.payload.role!, text: e.payload.text! })), question.selection, question.action,
      table ? { profile: this.profileFor(c), topicTitle: !this.hasTopicTitle(c.conversationID) } : {});
    const controller = cancellation([this.signal]), deadline = setTimeout(() => controller.abort(new DOMException('Deadline', 'TimeoutError')), 210_000);
    this.streams.set(c.id, controller);
    const answerID = crypto.randomUUID(), entityID = crypto.randomUUID();
    c.liveID = entityID; c.liveText = ''; c.phase = 'streaming'; c.issue = null; c.progress = null; this.publish();
    let outcome: Outcome = { kind: 'failed', code: 'transport' }, diagram: { title: string; source: string } | null = null;
    let topicTitle: string | null = null, answeredBy: { model?: string; profile?: string } = {};
    try {
      for await (const event of this.deps.stream(this.account, request, controller.signal)) {
        controller.signal.throwIfAborted();
        if (event.type === 'delta') {
          const next = c.liveText + event.text;
          if (bytes(next) > 200_000) { c.liveText = boundedText(next); outcome = { kind: 'failed', code: 'answer_too_large' }; break; }
          c.liveText = next; c.progress = null;
        } else if (event.type === 'status') c.progress = event.progress;
        else if (event.type === 'diagram') diagram = event;
        else if (event.type === 'title') { if (request.topicTitle) topicTitle = event.text; }
        else if (event.type === 'error') { outcome = { kind: 'failed', code: event.code }; break; }
        else { outcome = { kind: 'completed', stopReason: event.stopReason }; c.credits = event.credits; answeredBy = { model: event.model, profile: event.profile }; break; }
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
      const answer: PrivateEvent = { kind: 'message', entityID, parents: [question.id], conversationID: c.conversationID!,
        documentID: c.documentID ?? undefined, text: c.liveText, role: 'assistant', status: result.status, createdAt: Date.now() };
      // Which model and profile answered, encrypted with the answer and shown under it.
      if (answeredBy.model) answer.model = answeredBy.model;
      if (answeredBy.profile) answer.profile = answeredBy.profile;
      const entries: Entry[] = [{ id: answerID, event: answer }];
      if (diagram && result.status === 'complete') entries.push({ id: crypto.randomUUID(), event: { kind: 'diagram', entityID: crypto.randomUUID(), parents: [],
        conversationID: c.conversationID!, text: encodeDiagram({ ...diagram, messageID: entityID }), createdAt: Date.now() } });
      // A topic title is kept with a complete answer, in the same batch, unless the chat got one meanwhile (a rename wins).
      if (topicTitle && result.status === 'complete' && !this.hasTopicTitle(c.conversationID)) {
        const titled = this.history.state.titledConversation(c.conversationID!, topicTitle, GENERATED_TITLE);
        if (titled) entries.push({ id: crypto.randomUUID(), event: titled });
      }
      c.answer = entries; this.publish();
      try { await this.history.append(entries); c.answer = null; c.head = answerID; } catch { c.issue = 'storage'; }
    }
    if (!c.answer) { c.liveText = ''; c.liveID = null; }
    c.phase = 'idle'; this.publish(); void this.refreshBalance();
  }
}
