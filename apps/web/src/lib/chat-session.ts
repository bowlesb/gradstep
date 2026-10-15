import { localChatContext } from './arxiv-reader';
import { chatFigureImages, composeFigure, figureLabel, storedFigurePartsText, type FigureParts } from './chat-figures';
import type { VerifiedBundle } from './bundle';
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
import { isProfileChoice, isStandard, offers, parseProfileID, ProfileTableLoader, STANDARD_PROFILE, type ProfileChoice, type ProfileTable } from './chat-profiles';
import { cancellation } from './cancellation';
import { cleanTopicTitle, encodeDiagram, makeDiagram, GENERATED_TITLE, RENAMED_TITLE, validateEvent, type PrivateEvent, type TextAnchor, type SourcePaperReference, type DiagramFormat } from './events';
import { History, type AppendOptions } from './history';
import { storage as browserStorage, type StorageLifecycle } from './idb';
import type { Journal, StoredDraft, StoredTurn } from './journal';
import { EMPTY_STUDY_MAP, studyStart, type StudyMap } from './study';
import { equationKey, equationTurn, type EquationAction, type EquationResult } from './equation';

interface Entry { id: string; event: PrivateEvent }
interface Question { revision: number; id: string; entries: Entry[]; selection: string | null; action: ChatAction | null; profile?: ProfileChoice }
type Receipt = NonNullable<StoredDraft['receipt']>;
export interface Composer {
  id: string; documentID: string | null; conversationID: string | null; head: string | null; draft: string; revision: number;
  phase: 'idle' | 'saving' | 'consent' | 'streaming' | 'finishing'; issue: string | null;
  question: Question | null; answer: Entry[] | null; liveID: string | null; liveText: string; progress: Progress | null; credits: number | null;
  /** The newest complete answer's suggested follow-up questions (memory only; cleared by the next question). */
  followUps: string[] | null;
  /** Study (lib/study.ts): the knowledge map while this chat is a study; null otherwise. Memory only. */
  study: StudyMap | null;
  /** A model/effort/length the reader chose here (memory only); null follows the conversation, then the default. */
  profile: ProfileChoice | null;
  /** Identity of the current text edit (a new one per edit, even when the text repeats). */
  textRevision: string;
  /** The latest revision committed on this device (durable journal only). */
  savedRevision: number;
  receipt: Receipt | null;
  branchRevision: string;
  acknowledgedSubmissionID: string | null;
  anchor?: TextAnchor;
  requestedAnswer?: StoredDraft['requestedAnswer'];
  answerTitle?: AppendOptions['title'];
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
  /** The published profile table (GET functions/v1/chat); undefined uses the backend. */
  fetchProfiles?: (account: string, signal: AbortSignal) => Promise<unknown>;
  /** This browser's default for new chats (a per-browser presentation preference). */
  readDefault: () => ProfileChoice | null; writeDefault: (choice: ProfileChoice) => void;
}
const DEFAULT_KEY = 'gradstep.chat-defaults.v1';
/** The "Visual answers" setting (chat defaults): per browser, on unless turned off. */
export const VISUAL_ANSWERS_KEY = 'gradstep.chat-visual-answers.v1';
export function readVisualAnswers(): boolean { try { return localStorage.getItem(VISUAL_ANSWERS_KEY) !== 'false'; } catch { return true; } }
export function writeVisualAnswers(on: boolean) { try { localStorage.setItem(VISUAL_ANSWERS_KEY, on ? 'true' : 'false'); } catch { /* per-browser convenience */ } }
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
  private sourcePapers = new Map<string,{reference:SourcePaperReference;load:()=>Promise<VerifiedBundle>}>();
  setSourcePapers(rows:Map<string,{reference:SourcePaperReference;load:()=>Promise<VerifiedBundle>}>) { this.sourcePapers=rows; }
  private reference(documentID:string|null):SourcePaperReference|undefined {
    if(!documentID)return undefined;
    return this.sourcePapers.get(documentID)?.reference ?? [...this.history.state.events.values()].find(e=>e.payload.paperReference?.membershipID===documentID)?.payload.paperReference;
  }
  readonly composers = new Map<string, Composer>();
  readonly selected = new Map<string, string>();
  balance: { available: number; reserved: number } | null = null;
  journalState: JournalState;
  private listeners = new Set<() => void>();
  private version = 0;
  private streams = new Map<string, ReturnType<typeof cancellation>>();
  private starting = new Set<string>();
  private tasks = new Set<Promise<void>>();
  private accepting = true;
  private retiredStorage = false;
  private readonly deps: Dependencies;
  private journal: Journal | null;
  /** Editor locks: one live tab owns each composer; another tab can't load or overwrite it. */
  private editors = new Map<string, Promise<() => void>>();
  private checkpoints = new Map<string, { timer: ReturnType<typeof setTimeout>; since: number }>();
  private writes: Promise<void> = Promise.resolve();
  private discarding = new Set<string>();
  private turnOwners = new Map<string, { id: string; release: () => void; refused: boolean }>();
  private discussions = new Map<string, { quote: string; composerID: string; textRevision: string; anchor?: TextAnchor }>();
  readonly profiles: ProfileTableLoader;
  private browserDefault: ProfileChoice | null;
  private renames = new Map<string, { id: string; text: string }>();

  constructor(readonly account: string, readonly history: History, readonly signal: AbortSignal, dependencies: Partial<Dependencies> = {}, journalState?: JournalState) {
    const consentKey = `gradstep.${config.environment}.${account}.cloud-ai-consent`;
    this.deps = { stream: streamAnswer, readConsent: () => { try { return localStorage.getItem(consentKey) === CONSENT_VERSION; } catch { return false; } },
      writeConsent: () => { localStorage.setItem(consentKey, CONSENT_VERSION); if (localStorage.getItem(consentKey) !== CONSENT_VERSION) throw new Error('consent_unsaved'); },
      readDefault: () => { try { const v = JSON.parse(localStorage.getItem(DEFAULT_KEY) ?? 'null') as unknown; return isProfileChoice(v) ? { model: v.model, effort: v.effort, length: v.length } : null; } catch { return null; } },
      writeDefault: choice => { try { localStorage.setItem(DEFAULT_KEY, JSON.stringify(choice)); } catch { /* per-browser convenience only */ } },
      storage: browserStorage, journal: null, locks: browserLocks, ...dependencies };
    this.profiles = new ProfileTableLoader(account, signal, this.deps.fetchProfiles);
    this.browserDefault = this.deps.readDefault();
    // Fetched ahead of the first answer; until it arrives (or if this server predates profiles) requests stay default.
    void this.profiles.load().then(table => { if (table) this.publish(); });
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
        c.head = history.resolve(c.answer[0].id); c.answer = null; c.answerTitle = undefined; c.liveText = ''; c.liveID = null;
        this.turnOwners.get(c.id)?.release(); this.turnOwners.delete(c.id);
        if (c.issue === 'storage') c.issue = null;
        this.publish();
      }
    });
    const unsubscribeRebase = history.subscribeRebase(mapping => this.remap(mapping));
    const observeStorage = () => { if (this.deps.storage.snapshot().phase !== 'open') this.retireStorage(); };
    const unsubscribeStorage = this.deps.storage.subscribe(observeStorage);
    const unsubscribeFault = this.journal?.subscribeFault(error => {
      if (!this.journal?.active) { this.journalState = 'damaged'; this.retireStorage(); }
      else if ((error as { code?: string }).code === 'missing_key') void this.history.sync().catch(() => {});
    });
    signal.addEventListener('abort', () => {
      unsubscribe(); unsubscribeRebase(); unsubscribeStorage(); unsubscribeFault?.(); this.accepting = false;
      for (const c of this.streams.values()) c.abort();
      for (const { timer } of this.checkpoints.values()) clearTimeout(timer);
      this.checkpoints.clear(); this.listeners.clear();
      // A replacement editor cannot acquire the lock while accepted writes or a discard still settle.
      void Promise.allSettled([...this.tasks, this.writes]).then(() => {
        this.journal?.retire(); this.releaseEditors();
        for (const turn of this.turnOwners.values()) turn.release(); this.turnOwners.clear();
      });
    }, { once: true });
    observeStorage();
  }
  /** Drafts and interrupted answers survive a reload in this browser. */
  get durable() { return !!this.journal && this.history.durable; }
  /** Storage was retired by a newer tab: this page sends nothing new, but its unsent text stays readable. */
  get storageRetired() { return this.retiredStorage; }
  hasUnresolvedTurn(c: Composer) { return this.turnOwners.has(c.id); }
  lockJournal(state: JournalState) { this.journalState = state; this.retireStorage(); }
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
      liveID: null, liveText: '', progress: null, credits: null, followUps: null, study: null, profile: null, textRevision: crypto.randomUUID(), savedRevision: 0, receipt: null,
      branchRevision: crypto.randomUUID(), acknowledgedSubmissionID: null };
  }
  private create(documentID: string | null): Composer {
    // Empty, inactive composers can be retired. Unsent text is never evicted to make room.
    for (const [id, c] of this.composers) if (!c.draft && !c.conversationID && !busy(c) && !c.question && !c.answer && c.revision === 0 && c.savedRevision === 0) { this.composers.delete(id); this.releaseEditor(id); }
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

  /** `profile`: a selection action carries the choice shown in the chat pane into its new conversation. */
  newChat(documentID: string | null, profile: ProfileChoice | null = null): Composer {
    this.allowed(); const c = this.create(documentID); c.profile = profile ? { ...profile } : null; this.publish(); return c;
  }

  // ---------- Model, effort and length ----------

  get profileTable(): ProfileTable | null { return this.profiles.table; }
  async reloadProfiles() { await this.profiles.load(); this.publish(); }
  /** New chats start here: this browser's choice, else the server's default (Sonnet · Low · Standard). */
  get defaultProfile(): ProfileChoice {
    const table = this.profiles.table, saved = this.browserDefault;
    if (!table) return STANDARD_PROFILE;
    if (saved && offers(table, saved)) return saved;
    return table?.defaultChoice ?? STANDARD_PROFILE;
  }
  setDefaultProfile(choice: ProfileChoice) { this.browserDefault = { ...choice }; this.deps.writeDefault(this.browserDefault); this.publish(); }
  /** The chat's current choice: one made here, else the profile its newest answer used, else the default. */
  profileFor(c: Composer): ProfileChoice {
    const table = this.profiles.table;
    if (!table) return STANDARD_PROFILE;
    const usable = (choice: ProfileChoice | null) => !!choice && (!table || offers(table, choice));
    if (c.profile && usable(c.profile)) return c.profile;
    const answers = this.branch(c)?.messages.filter(m => m.payload.role === 'assistant') ?? [];
    for (const answer of [...answers].reverse()) { const used = parseProfileID(answer.payload.profile); if (used && usable(used)) return used; }
    return this.defaultProfile;
  }
  setProfile(c: Composer, choice: ProfileChoice) { c.profile = { ...choice }; this.publish(); }

  /** A locally submitted question keeps its exact captured choice. Other-device/legacy questions use the visible choice at Get answer. */
  retryProfile(c: Composer): ProfileChoice {
    if (c.question?.profile) return c.question.profile;
    const last = this.branch(c)?.messages.at(-1), questionID = c.question?.id ?? (last?.payload.role === 'user' ? last.id : null);
    const binding = c.requestedAnswer;
    return binding && questionID && this.history.resolve(binding.questionID) === this.history.resolve(questionID) ? binding.choice : this.profileFor(c);
  }

  /** Whether the conversation has a topic title (generated or the reader's own). */
  hasTopicTitle(conversationID: string | null): boolean {
    return !!conversationID && this.history.state.revisions(conversationID).some(e => e.payload.kind === 'conversation' && e.payload.titleSource !== undefined);
  }
  /** Rename: a conversation revision with the reader's title (≤ 80 characters), which a generated title never replaces. */
  async rename(conversationID: string, title: string): Promise<boolean> {
    this.allowed();
    if (this.retiredStorage) return false;
    const text = cleanTopicTitle(title);
    if (!text || !this.history.state.titledConversation(conversationID, text, RENAMED_TITLE)) return false;
    const pending = this.renames.get(conversationID);
    const revision = pending?.text === text ? pending : { id: crypto.randomUUID(), text };
    this.renames.set(conversationID, revision);
    const options: AppendOptions = { title: { ...revision, conversationID, source: RENAMED_TITLE } };
    if (this.durable) { await this.history.commit([], options); void this.history.flush([revision.id]).catch(() => {}); }
    else await this.history.append([], options);
    this.renames.delete(conversationID);
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
  async discardDraft(id: string) {
    const c = this.composers.get(id);
    if (!c || busy(c) || c.answer || this.turnOwners.has(id) || this.discarding.has(id) || this.retiredStorage) return;
    if (!this.journal) { c.draft = ''; c.revision++; c.textRevision = crypto.randomUUID(); this.publish(); return; }
    // An encrypted tombstone: no delayed checkpoint can resurrect this composer. Later typing gets a new composer ID.
    this.cancelCheckpoint(c);
    const observed = c.revision, template = { ...this.record(c) };
    const replacement = { ...this.blank(c.documentID), conversationID: c.conversationID, head: c.head,
      requestedAnswer: c.requestedAnswer, revision: c.requestedAnswer ? 1 : 0 };
    if (replacement.requestedAnswer) this.claimEditor(replacement.id);
    this.discarding.add(id);
    try {
      await this.queue(async () => {
        await this.editors.get(id); await this.editors.get(replacement.id);
        await this.journal!.discardDraft(c.id, observed, template, replacement.requestedAnswer ? this.record(replacement) : undefined);
      });
      this.signal.throwIfAborted();
      // Keep the original text reachable until the tombstone commits. Any edit during deletion has a new identity.
      replacement.savedRevision = replacement.revision;
      if (c.revision > observed) Object.assign(replacement, { draft: c.draft, revision: replacement.revision + 1, textRevision: c.textRevision, anchor: c.anchor });
      this.composers.delete(c.id); this.composers.set(replacement.id, replacement);
      if (this.selected.get(scope(c.documentID)) === c.id) this.selected.set(scope(c.documentID), replacement.id);
      this.claimEditor(replacement.id); this.releaseEditor(id);
      if (replacement.draft) this.scheduleCheckpoint(replacement);
    } catch { this.releaseEditor(replacement.id); c.issue = 'local_save'; }
    finally { this.discarding.delete(id); this.publish(); }
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
  chooseBranch(c: Composer, head: string) { if (busy(c) || c.answer) return; c.head = head; c.branchRevision = crypto.randomUUID(); c.question = null; c.issue = null; c.revision++; this.scheduleCheckpoint(c); this.publish(); }

  /** Discuss prepares a device draft only; the caller reveals/focuses this composer. */
  async discuss(documentID: string, quote: string, anchor?: TextAnchor): Promise<Composer | null> {
    this.allowed();
    if (this.retiredStorage) return null;
    if (anchor !== undefined) {
      try { validateEvent({ kind: 'position', entityID: documentID, documentID, parents: [], anchor }); }
      catch { return null; }
    }
    quote = boundedText(quote, 12_000);
    const pending = this.discussions.get(documentID), sameAnchor = JSON.stringify(pending?.anchor) === JSON.stringify(anchor);
    const retry = pending && pending.quote === quote && sameAnchor && this.composers.get(pending.composerID);
    let c = retry && retry.textRevision === pending!.textRevision ? retry : this.current(documentID);
    if (c.conversationID || busy(c) || c.answer) c = this.newChat(documentID);
    if (!(pending?.composerID === c.id && pending.textRevision === c.textRevision && pending.quote === quote && sameAnchor)) {
      if (!this.edit(c, `About “${quote}”: ${c.draft}`)) return null;
      c.anchor = anchor && { ...anchor };
      this.discussions.set(documentID, { quote, composerID: c.id, textRevision: c.textRevision, anchor: c.anchor });
    }
    await this.checkpoint(c);
    if (c.issue === 'local_save') return null;
    this.discussions.delete(documentID);
    return c;
  }
  /** Retries device persistence only. This action never requests an answer. */
  async retryDeviceSave(c: Composer): Promise<void> {
    const terminal = this.turnOwners.get(c.id);
    if (terminal?.refused) {
      try { await this.journal!.dropTurn(terminal.id); terminal.release(); this.turnOwners.delete(c.id); c.issue = 'refused'; }
      catch { c.issue = 'local_save'; }
      this.publish(); return;
    }
    await this.checkpoint(c);
  }

  // ---------- Device checkpoints (durable journal) ----------

  private queue(write: () => Promise<void>): Promise<void> {
    const next = this.writes.then(write);
    this.writes = next.catch(() => {});
    return next;
  }
  private record(c: Composer): StoredDraft {
    return { id: c.id, documentID: c.documentID, conversationID: c.conversationID, head: c.head, revision: c.revision, textRevision: c.textRevision,
      text: c.draft, editedAt: Date.now(), receipt: c.receipt, discarded: false,
      branchRevision: c.branchRevision, acknowledgedSubmissionID: c.acknowledgedSubmissionID,
      anchor: c.anchor, requestedAnswer: c.requestedAnswer };
  }
  private scheduleCheckpoint(c: Composer) {
    if (!this.journal || this.discarding.has(c.id)) return;
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
        await this.editors.get(c.id);
        await this.journal!.checkpointDraft(record);
        if (record.revision > c.savedRevision) c.savedRevision = record.revision;
        if (c.issue === 'local_save' && !this.turnOwners.has(c.id)) c.issue = null;
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
    if ([...this.composers.values()].some(c => c.issue === 'local_save' && c.revision > c.savedRevision)) throw new BackendError('local_storage');
  }
  private consume(c: Composer) { c.draft = ''; c.revision++; c.textRevision = crypto.randomUUID(); }
  private remap(mapping: Map<string, string>) {
    const map = (id: string) => mapping.get(id) ?? id;
    const entries = (list: Entry[]) => list.map(e => ({ id: map(e.id), event: { ...e.event, parents: e.event.parents.map(map) } }));
    for (const c of this.composers.values()) {
      if (c.head) c.head = map(c.head);
      if (c.question) c.question = { ...c.question, id: map(c.question.id), entries: entries(c.question.entries) };
      if (c.answer) c.answer = entries(c.answer);
      if (c.answerTitle) c.answerTitle = { ...c.answerTitle, id: map(c.answerTitle.id) };
      if (c.receipt) c.receipt = { ...c.receipt, submissionID: map(c.receipt.submissionID), eventIDs: c.receipt.eventIDs.map(map) };
      if (c.acknowledgedSubmissionID) c.acknowledgedSubmissionID = map(c.acknowledgedSubmissionID);
      if (c.requestedAnswer) c.requestedAnswer = { ...c.requestedAnswer, questionID: map(c.requestedAnswer.questionID) };
    }
    this.publish();
  }

  /**
   * Restores this account's drafts and recovers abandoned answers after a reload. A composer still open in another live
   * tab stays there. A turn is recovered only after acquiring its owner lock (elapsed time proves nothing): its saved
   * partial text becomes an interrupted answer; an empty one is removed. No request is ever retried here.
   */
  restore(drafts: StoredDraft[], turns: StoredTurn[]): Promise<void> {
    return this.track(this.restoreOwned(drafts, turns));
  }
  private async restoreOwned(drafts: StoredDraft[], turns: StoredTurn[]): Promise<void> {
    if (!this.journal) return;
    const reclaim: string[] = [], releaseReclaimed: (() => void)[] = [];
    const restored: { composer: Composer; editedAt: number }[] = [];
    this.signal.throwIfAborted();
    try {
      for (const captured of drafts) {
        const release = await this.deps.locks.tryHold(`gradstep.composer.${captured.id}`).catch(() => null);
        if (!release) continue; // a live tab owns it
        let d: StoredDraft | null;
        try { this.signal.throwIfAborted(); d = await this.journal.draft(captured.id); this.signal.throwIfAborted(); }
        catch (error) { release(); throw error; }
        if (!d) { release(); continue; }
        const pendingSubmission = !!d.receipt && this.history.isPending(d.receipt.submissionID);
        if (d.discarded || (!d.text && !(d.conversationID && (d.receipt || d.requestedAnswer)))) { reclaim.push(d.id); releaseReclaimed.push(release); continue; }
        const c: Composer = { ...this.blank(d.documentID, d.id), conversationID: d.conversationID, head: d.head && this.history.resolve(d.head), draft: d.text,
          revision: d.revision, savedRevision: d.revision, textRevision: d.textRevision, branchRevision: d.branchRevision, anchor: d.anchor,
          requestedAnswer: d.requestedAnswer && { ...d.requestedAnswer, questionID: this.history.resolve(d.requestedAnswer.questionID) },
          acknowledgedSubmissionID: d.receipt && this.history.resolve(d.receipt.submissionID), receipt: d.receipt && { ...d.receipt,
            submissionID: this.history.resolve(d.receipt.submissionID), eventIDs: d.receipt.eventIDs.map(id => this.history.resolve(id)) } };
        if (pendingSubmission) c.question = { revision: -1, id: c.receipt!.submissionID, entries: [], selection: null, action: null };
        this.composers.set(c.id, c); this.editors.set(c.id, Promise.resolve(release));
        restored.push({ composer: c, editedAt: d.editedAt });
      }
      for (const { composer: c } of restored.sort((a, b) => a.editedAt - b.editedAt)) this.selected.set(scope(c.documentID), c.id);
      if (reclaim.length) { this.signal.throwIfAborted(); await this.journal.collectDrafts(reclaim); }
    } finally { for (const release of releaseReclaimed) release(); }
    for (const captured of turns) {
      const release = await this.deps.locks.tryHold(`gradstep.turn.${captured.id}`).catch(() => null);
      if (!release) continue; // its stream is still running in another tab
      try { await this.recoverTurn(captured.id); } finally { release(); }
    }
    this.publish();
  }
  private async recoverTurn(id: string): Promise<void> {
    for (let attempt = 0; ; attempt++) {
      try {
        this.signal.throwIfAborted();
        const turn = await this.journal!.turn(id);
        this.signal.throwIfAborted();
        if (!turn) return;
        if (!turn.text.trim()) { await this.journal!.dropTurn(turn.id, turn); return; }
        await this.history.commit([{ id: turn.id, event: { kind: 'message', entityID: turn.entityID, parents: [this.history.resolve(turn.questionID)],
          conversationID: turn.conversationID, documentID: turn.documentID ?? undefined, paperReference:this.history.state.events.get(this.history.resolve(turn.questionID))?.payload.paperReference, text: turn.text, role: 'assistant', status: 'interrupted', createdAt: turn.updatedAt } }],
          { finishTurn: turn.id, recoveryTurn: turn });
        return;
      } catch (error) {
        if ((error as { code?: string }).code === 'journal_stale' && attempt < 2) continue;
        throw error; // preserve the checkpoint and surface failure; never silently open over damaged private data
      }
    }
  }

  async refreshBalance() {
    try {
      const balance = await rpc<{ available: number; reserved: number }>('v1_credit_balance', {}, { account: this.account, signal: this.signal });
      if (this.signal.aborted) return;
      if (Number.isSafeInteger(balance?.available) && balance.available >= 0 && Number.isSafeInteger(balance.reserved) && balance.reserved >= 0) { this.balance = balance; this.publish(); }
    } catch { /* A failed balance read never becomes a fabricated zero or client spending authority. */ }
  }
  // ---------- The equation view (EQUATION_VIEW.md) ----------

  /** Whether this browser accepted cloud AI answers: the chat's own consent, which the equation view shares. */
  get cloudConsent(): boolean { return this.deps.readConsent(); }
  acceptCloudConsent(): boolean { try { this.deps.writeConsent(); return true; } catch { return false; } }
  private equations = new Map<string, EquationResult>();
  private equationProfile(): ProfileChoice { return this.profiles.table ? this.defaultProfile : STANDARD_PROFILE; }
  /** A finished result for this equation with the current default model (memory only, this login lifetime). */
  savedEquation(manifest: string, equationID: string, action: EquationAction): EquationResult | null {
    const p = this.equationProfile();
    return this.equations.get(equationKey(manifest, equationID, action, `${p.model}-${p.effort}-${p.length}`)) ?? null;
  }
  /** One equation-view request, sent exactly as this browser's chat sends a question about the paper (its default
   * profile, capabilities, consent and the numbered paper on this device), so the server reads the same cached prefix.
   * No conversation or history is made; the finished result is kept in memory for this session. */
  async equation(documentID: string, input: { equationID: string; latex: string; number: string | null }, action: EquationAction,
    update: (result: EquationResult) => void, signal: AbortSignal): Promise<EquationResult> {
    this.allowed();
    let result: EquationResult = { phase: 'loading', symbols: null, text: '', credits: null, issue: null };
    const finish = (issue: string | null) => { result = { ...result, phase: issue ? 'failed' : 'done', issue }; update(result); return result; };
    if (this.retiredStorage) return finish('storage_retired');
    if (!this.deps.readConsent()) return finish('consent_required');
    const reference = this.reference(documentID), local = reference && this.sourcePapers.get(reference.membershipID);
    if (!reference || !local) return finish('local_reader_unavailable');
    update(result);
    const table = await this.profiles.load();
    const profile = table ? this.defaultProfile : STANDARD_PROFILE;
    let bundle: VerifiedBundle;
    try { bundle = await local.load(); } catch { return finish('local_reader_unavailable'); }
    if (signal.aborted || this.signal.aborted) return finish('cancelled');
    const key = equationKey(bundle.manifestSHA256, input.equationID, action, `${profile.model}-${profile.effort}-${profile.length}`);
    const saved = this.equations.get(key);
    if (saved) { update(saved); return saved; }
    const request = makeRequest(crypto.randomUUID(), null, [{ role: 'user', text: equationTurn(input.number) }], input.latex, action,
      { ...(table ? { profile } : {}), visualAnswers: readVisualAnswers() });
    try { request.localContext = localChatContext(reference, bundle); } catch { return finish('local_reader_unavailable'); }
    const controller = cancellation([this.signal, signal]), deadline = setTimeout(() => controller.abort(new DOMException('Deadline', 'TimeoutError')), 210_000);
    try {
      for await (const event of this.deps.stream(this.account, request, controller.signal)) {
        if (event.type === 'delta') { result = { ...result, text: boundedText(result.text + event.text) }; update(result); }
        else if (event.type === 'equation') { result = { ...result, symbols: event.symbols }; update(result); }
        else if (event.type === 'error') { result = { ...result, credits: event.credits ?? null }; finish(event.code); break; }
        else if (event.type === 'done') { result = { ...result, credits: event.credits }; finish(result.symbols || result.text.trim() ? null : 'provider_unavailable'); break; }
      }
      if (result.phase === 'loading') finish('transport');
    } catch (error) {
      finish(controller.signal.aborted && controller.signal.reason?.name !== 'TimeoutError' ? 'cancelled'
        : error instanceof BackendError && error.code !== 'connection' ? error.code : 'transport');
    } finally { clearTimeout(deadline); controller.dispose(); }
    if (result.phase === 'done') this.equations.set(key, result);
    void this.refreshBalance();
    return result;
  }
  private track(task: Promise<void>): Promise<void> { this.tasks.add(task); void task.finally(() => this.tasks.delete(task)).catch(() => {}); return task; }

  // ---------- Sending ----------

  /** Study needs the paper numbered on this device (the HTML reader's bundle), as the server's tutor cites [¶N]. */
  canStudy(documentID: string | null): boolean { return !!documentID && this.sourcePapers.has(documentID); }
  /** A figure's image from this chat's paper on this device, when its bundle is the one the parts were cut from;
   * several panels composed exactly as they were sent. */
  async figureImage(documentID: string | null, manifestSHA256: string, paths: string[]): Promise<Blob | null> {
    const local = documentID ? this.sourcePapers.get(documentID) : undefined;
    if (!local) return null;
    try {
      const bundle = await local.load();
      if (bundle.manifestSHA256 !== manifestSHA256) return null;
      const panels = paths.map(path => ({ bytes: bundle.contents.get(path), mediaType: bundle.manifest.members.find(m => m.path === path)?.media_type ?? '' }));
      if (panels.some(p => !p.bytes || !p.mediaType)) return null;
      if (panels.length === 1) return new Blob([panels[0].bytes as BlobPart], { type: panels[0].mediaType });
      const composed = await composeFigure(panels as { bytes: Uint8Array; mediaType: string }[]);
      return composed && 'convertToBlob' in composed ? await composed.convertToBlob({ type: 'image/png' }) : null;
    } catch { return null; }
  }
  /** Starts (or restarts) a study in this chat: an empty map and the opening turn, sent as the reader's message. */
  startStudy(c: Composer, selection: string | null = null, anchor?: TextAnchor): Promise<void> {
    this.allowed();
    if (busy(c) || c.answer || !this.canStudy(c.documentID)) return Promise.resolve();
    c.study = { ...EMPTY_STUDY_MAP };
    if (!this.edit(c, studyStart(selection))) { c.study = null; return Promise.resolve(); }
    return this.send(c, selection, 'study', anchor);
  }
  /** Ends the study: the chat goes on as an ordinary paper chat; the map is dropped (it was never stored). */
  endStudy(c: Composer) { this.allowed(); c.study = null; this.publish(); }

  send(c: Composer, selection: string | null = null, action: ChatAction | null = null, anchor?: TextAnchor): Promise<void> {
    this.allowed();
    // While a chat is a study, every message is the reader's answer to the tutor.
    if (!action && c.study) action = 'study';
    if (this.retiredStorage) return Promise.resolve(); // refused: nothing is saved or requested from this page
    if (busy(c) || c.answer || this.turnOwners.has(c.id) || !c.draft.trim()) return Promise.resolve();
    if (this.history.status !== 'ready' || this.history.issue) { c.issue = 'question_unsaved'; this.publish(); return Promise.resolve(); }
    if (c.conversationID && this.history.state.isDeleted(c.conversationID)) { c.issue = 'conversation_deleted'; this.publish(); return Promise.resolve(); }
    const branch = this.branch(c);
    if (c.conversationID && (!branch || !branch.complete)) { c.issue = 'branch_required'; this.publish(); return Promise.resolve(); }
    const text = c.draft.trim(), revision = c.revision, textRevision = c.textRevision, at = Date.now(), entries: Entry[] = [];
    const previous = { conversationID: c.conversationID, head: c.head, receipt: c.receipt };
    if (!c.conversationID) {
      c.conversationID = crypto.randomUUID();
      const root = crypto.randomUUID();
      entries.push({ id: root, event: { kind: 'conversation', entityID: c.conversationID, parents: [], documentID: c.documentID ?? undefined, paperReference:this.reference(c.documentID),
        text: [...text].slice(0, 100).join(''), anchor: anchor ?? c.anchor, createdAt: at } });
      c.head = root;
    } else c.head = branch!.head;
    const id = crypto.randomUUID();
    entries.push({ id, event: { kind: 'message', entityID: crypto.randomUUID(), parents: [c.head!], conversationID: c.conversationID,
      documentID: c.documentID ?? undefined, paperReference:this.reference(c.documentID), text, role: 'user', status: 'complete', createdAt: at } });
    const requestedAnswer = { questionID: id, choice: { ...this.profileFor(c) } };
    c.question = { revision, id, entries, selection, action, profile: requestedAnswer.choice }; c.phase = 'saving'; c.issue = null; c.credits = null; c.followUps = null;
    this.publish();
    return this.track((async () => {
      try {
        if (this.durable) {
          // One local transaction: root/question events, their exact outbox bytes and the receipt that consumes only the
          // captured text revision. Newer typing survives; a failure leaves the previous checkpoint and this text.
          const receipt: Receipt = { submissionID: id, eventIDs: entries.map(e => e.id), textRevision, revision, branchRevision: c.branchRevision };
          this.cancelCheckpoint(c);
          try { await this.editors.get(c.id); await this.history.commit(entries, { draft: { ...this.record(c), head: id, receipt, requestedAnswer } }); }
          catch (error) { Object.assign(c, previous); c.question = null; throw Object.assign(error as object, { local: true }); }
          this.signal.throwIfAborted();
          c.receipt = receipt; c.acknowledgedSubmissionID = id; c.head = id;
          c.requestedAnswer = { ...requestedAnswer, questionID: this.history.resolve(id) };
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
    if (this.turnOwners.get(c.id)?.refused) return this.retryDeviceSave(c);
    if (busy(c) || this.retiredStorage) return Promise.resolve();
    // Freeze before any history await; editing controls or a late capability response cannot change this request.
    const capturedProfile = { ...this.retryProfile(c) };
    if (!c.answer) {
      if (!c.question) {
        const branch = this.branch(c), last = branch?.messages.at(-1);
        if (!branch?.complete || last?.payload.role !== 'user') { c.issue = 'branch_required'; this.publish(); return Promise.resolve(); }
        c.question = { revision: -1, id: last.id, entries: [], selection: null, action: c.study ? 'study' : null };
      }
      c.question.profile ??= capturedProfile;
      const questionID = this.history.resolve(c.question.id);
      if (c.requestedAnswer?.questionID !== questionID) {
        c.requestedAnswer = { questionID, choice: { ...c.question.profile } };
        if (this.durable) { c.revision++; this.scheduleCheckpoint(c); }
      }
    }
    c.phase = 'saving'; c.issue = null; this.publish();
    return this.track((async () => {
      try {
        if (c.answer) {
          await this.history.append(c.answer, { ...(this.durable ? { finishTurn: c.answer[0].id } : {}), title: c.answerTitle });
          this.turnOwners.get(c.id)?.release(); this.turnOwners.delete(c.id);
          c.head = this.history.resolve(c.answer[0].id); c.answer = null; c.answerTitle = undefined; c.liveText = ''; c.liveID = null; c.phase = 'idle'; this.publish(); return;
        }
        if (!c.question) throw new BackendError('invalid_request');
        if (this.durable) { await this.checkpoint(c); if (c.issue === 'local_save') throw new BackendError('local_storage'); }
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
    await this.flushCheckpoints();
    if (this.turnOwners.size) throw new BackendError('local_storage');
  }
  /** After explicit sign-out (and any local removal): retire this login lifetime's journal writer. */
  async retireJournal() { await this.journal?.signOut(); }

  private async answerQuestion(c: Composer): Promise<void> {
    if (this.starting.has(c.id) || this.streams.has(c.id)) return;
    if (this.streams.size + this.starting.size >= 3) { c.phase = 'idle'; c.issue = 'rate_limited'; this.publish(); return; }
    this.starting.add(c.id);
    try { await this.runAnswer(c); } finally { this.starting.delete(c.id); }
  }
  private async runAnswer(c: Composer): Promise<void> {
    this.signal.throwIfAborted();
    if (!this.accepting) { c.phase = 'idle'; this.publish(); return; }
    // A question saved while storage retired stays saved; no paid request starts from this page.
    if (this.retiredStorage) { c.phase = 'idle'; c.issue = 'storage_retired'; this.publish(); return; }
    const questionID = c.question ? this.history.resolve(c.question.id) : null;
    if (this.history.status !== 'ready' || this.history.issue || !c.question || !questionID || this.history.isPending(questionID) || this.history.state.isDeleted(c.conversationID!)) { c.phase = 'idle'; c.issue = 'question_unsaved'; this.publish(); return; }
    if (!this.deps.readConsent()) { c.phase = 'consent'; this.publish(); return; }
    const branch = this.history.state.conversationBranch(c.conversationID!, questionID);
    if (!branch?.complete) { c.phase = 'idle'; c.issue = 'branch_required'; this.publish(); return; }
    const question = c.question;
    const capturedProfile = question.profile;
    if (!capturedProfile) { c.phase = 'idle'; c.issue = 'question_unsaved'; this.publish(); return; }
    c.phase = 'saving'; this.publish();
    // Choices and titles go only to a server that published its profile table (one that accepts them).
    const table = await this.profiles.load();
    if (this.signal.aborted) return;
    if (this.retiredStorage || !this.accepting) { c.phase = 'idle'; this.publish(); return; }
    if (table ? !offers(table, capturedProfile) : !isStandard(capturedProfile)) { c.phase = 'idle'; c.issue = 'profile_unavailable'; this.publish(); return; }
    const request = makeRequest(crypto.randomUUID(), c.documentID, branch.messages.map(e => ({ role: e.payload.role!, text: e.payload.text! })), question.selection, question.action,
      { ...(table ? { profile: capturedProfile, topicTitle: !this.hasTopicTitle(c.conversationID) } : {}), visualAnswers: readVisualAnswers() });
    if (question.action === 'study') request.study = c.study ?? { ...EMPTY_STUDY_MAP };
    const reference=this.reference(c.documentID);
    let figureManifest:string|null=null, figureBundle:VerifiedBundle|null=null;
    if(reference){
      try {
        const local=this.sourcePapers.get(reference.membershipID);
        if(!local)throw new Error('local_reader_unavailable');
        const bundle=await local.load(); figureBundle=bundle;
        request.localContext=localChatContext(reference,bundle);
        request.documentID=null;
        // The figures the question names, from this paper's own images (consent v3 names them; CHAT.md).
        if(question.action!=='ingest'&&question.action!=='diagram_fix'){
          const asked=branch.messages.at(-1)?.payload.text??'';
          const figures=await chatFigureImages(asked,question.selection,bundle);
          if(figures.length){request.figures=figures;figureManifest=bundle.manifestSHA256;}
        }
      }catch{if(!this.signal.aborted){c.phase='idle';c.issue='local_reader_unavailable';this.publish();}return;}
      if(this.signal.aborted || this.retiredStorage || !this.accepting)return;
    }
    const answerID = crypto.randomUUID(), entityID = crypto.randomUUID(), conversationID = c.conversationID!;
    let turn: StoredTurn | null = null, releaseTurn: (() => void) | null = null;
    if (this.durable) {
      // The operation, request digest, answer identities and owner are durable before the paid request starts.
      c.phase = 'saving'; this.publish();
      try {
        releaseTurn = await this.deps.locks.hold(`gradstep.turn.${answerID}`);
        const now = Date.now();
        turn = { id: answerID, entityID, composerID: c.id, conversationID, documentID: c.documentID, questionID, operationID: request.operationID,
          requestDigest: await sha256Hex(utf8(JSON.stringify(requestBody(request)))), requestedProfile: { ...request.profile }, text: '', startedAt: now, updatedAt: now };
        await this.journal!.beginTurn(turn);
      } catch {
        releaseTurn?.();
        if (!this.signal.aborted) { c.phase = 'idle'; c.issue = 'local_save'; this.publish(); }
        return;
      }
      if (this.signal.aborted || this.retiredStorage || !this.accepting) { await this.journal!.dropTurn(answerID).catch(() => {}); releaseTurn(); if (!this.signal.aborted) { c.phase = 'idle'; this.publish(); } return; }
    }
    let controller = cancellation([this.signal]), deadline = setTimeout(() => controller.abort(new DOMException('Deadline', 'TimeoutError')), 210_000);
    this.streams.set(c.id, controller);
    this.starting.delete(c.id);
    c.liveID = entityID; c.liveText = ''; c.phase = 'streaming'; c.issue = null; c.progress = null;
    // A question sent with a figure says so until the answer starts (owner, 2026-10-15: "Not able to do this").
    const named = request.figures?.[0] ? figureLabel(request.figures[0].caption) : null;
    if (named) c.progress = { kind: 'looking_at_figure', query: named };
    this.publish();
    let outcome: Outcome = { kind: 'failed', code: 'transport' }, diagram: { title: string; source: string; format?: DiagramFormat } | null = null;
    let lastCheckpoint = performance.now(), lastCheckpointDate = turn?.updatedAt ?? Date.now(), checkpointing: Promise<void> = Promise.resolve(), checkpointTimer: ReturnType<typeof setTimeout> | undefined;
    const checkpointTurn = (force = false) => {
      if (!turn) return;
      if (!force && performance.now() - lastCheckpoint < TURN_INTERVAL) {
        checkpointTimer ??= setTimeout(() => { checkpointTimer = undefined; checkpointTurn(); }, TURN_INTERVAL - (performance.now() - lastCheckpoint));
        return;
      }
      clearTimeout(checkpointTimer); checkpointTimer = undefined;
      lastCheckpoint = performance.now(); lastCheckpointDate = Math.max(lastCheckpointDate + 1, Date.now());
      const snapshot = { ...turn, text: c.liveText, updatedAt: lastCheckpointDate };
      checkpointing = checkpointing.then(() => this.journal!.checkpointTurn(snapshot)).catch(() => { if (!this.signal.aborted) { c.issue = 'local_save'; this.publish(); } });
    };
    let topicTitle: string | null = null, followUps: string[] | null = null, nextMap: StudyMap | null = null, answeredBy: { model?: string; profile?: string } = {};
    let figureParts: FigureParts | null = null, asked: string | null = null, sent = request;
    for (let pass = 0; pass < 2; pass++) {
    try {
      for await (const event of this.deps.stream(this.account, sent, controller.signal)) {
        controller.signal.throwIfAborted();
        if (event.type === 'delta') {
          const next = c.liveText + event.text;
          if (bytes(next) > 200_000) { c.liveText = boundedText(next); outcome = { kind: 'failed', code: 'answer_too_large' }; break; }
          c.liveText = next; c.progress = null; checkpointTurn();
        } else if (event.type === 'status') c.progress = event.progress;
        else if (event.type === 'diagram') diagram = { title: event.title, source: event.source };
        else if (event.type === 'visual') diagram = { title: event.title, source: event.html, format: 'html-v1' };
        else if (event.type === 'title') { if (request.topicTitle) topicTitle = event.text; }
        else if (event.type === 'followups') followUps = event.questions;
        else if (event.type === 'study') nextMap = event.map;
        else if (event.type === 'figure_parts') figureParts = event.parts;
        else if (event.type === 'figure_request') asked = event.figure;
        else if (event.type === 'equation') { /* the equation view's own event; a chat never asks for it */ }
        else if (event.type === 'error') { outcome = { kind: 'failed', code: event.code }; if (event.credits !== undefined) c.credits = event.credits; break; }
        else { outcome = { kind: 'completed', stopReason: event.stopReason }; c.credits = event.credits; answeredBy = { model: event.model, profile: event.profile }; break; }
        this.publish();
      }
    } catch (error) {
      outcome = controller.signal.aborted && controller.signal.reason?.name !== 'TimeoutError' ? { kind: 'cancelled' }
        : { kind: 'failed', code: error instanceof BackendError && error.code !== 'connection' ? error.code : 'transport' };
    } finally { clearTimeout(deadline); clearTimeout(checkpointTimer); controller.dispose(); this.streams.delete(c.id); }
    // The model asked for a figure the question is about (none was attached): the same question again, once, with that
    // figure from this paper; the first answer was only the request and is not kept.
    if (pass === 0 && asked && !sent.figures?.length && outcome.kind === 'completed' && figureBundle && !this.signal.aborted) {
      const figures = await chatFigureImages(asked, null, figureBundle);
      if (figures.length && !this.signal.aborted) {
        sent = { ...sent, operationID: crypto.randomUUID(), figures }; figureManifest = figureBundle.manifestSHA256;
        c.liveText = ''; diagram = null; figureParts = null; followUps = null; nextMap = null; asked = null;
        outcome = { kind: 'failed', code: 'transport' };
        c.progress = { kind: 'looking_at_figure', query: figures[0] ? figureLabel(figures[0].caption) ?? undefined : undefined }; this.publish();
        controller = cancellation([this.signal]); deadline = setTimeout(() => controller.abort(new DOMException('Deadline', 'TimeoutError')), 210_000);
        this.streams.set(c.id, controller);
        continue;
      }
    }
    break;
    }
    await checkpointing;
    // An externally retired login cannot write or expose text in its replacement. Its turn checkpoint stays on this
    // device and reopens as interrupted on the next sign-in; it is never re-requested.
    if (this.signal.aborted) { releaseTurn?.(); return; }
    // The answer's figure parts are its drawing (the server sends at most one kind): the parts and where their image
    // is in this paper's bundle, never the image (StoredFigureParts, as the apps keep it).
    if (figureParts && figureManifest) {
      const parts: FigureParts = figureParts, image = sent.figures?.find(f => f.id === parts.figure);
      const made = image ? makeDiagram(parts.title, storedFigurePartsText({ manifestSHA256: figureManifest, blockID: image.blockID,
        assetPath: image.assetPath, assetPaths: image.assetPaths, paragraph: parts.paragraph, title: parts.title, parts: parts.parts }), undefined, 'figure-parts-v1') : null;
      if (made) diagram = { title: made.title, source: made.source, format: 'figure-parts-v1' };
    }
    // A valid diagram-only completion still needs an assistant event to attach the encrypted diagram to.
    if (!c.liveText.trim() && diagram && outcome.kind === 'completed' && ['end_turn', 'stop_sequence'].includes(outcome.stopReason)) c.liveText = diagram.title;
    const result = resolution(outcome, c.liveText);
    c.progress = null; c.issue = result.issue; c.phase = 'finishing';
    // Suggestions belong to a complete answer only; an interrupted or failed one offers none.
    c.followUps = result.status === 'complete' ? followUps : null;
    // The map advances only with a complete tutored answer; a failed or interrupted one keeps the previous map.
    if (result.status === 'complete' && nextMap && c.study && request.action === 'study') c.study = nextMap;
    if (result.status) {
      const answer: PrivateEvent = { kind: 'message', entityID, parents: [this.history.resolve(question.id)], conversationID,
        documentID: c.documentID ?? undefined, paperReference:this.reference(c.documentID), text: c.liveText, role: 'assistant', status: result.status, createdAt: Date.now() };
      // Which model and profile answered, encrypted with the answer and shown under it.
      if (answeredBy.model) answer.model = answeredBy.model;
      if (answeredBy.profile) answer.profile = answeredBy.profile;
      const entries: Entry[] = [{ id: answerID, event: answer }];
      if (diagram && result.status === 'complete') entries.push({ id: crypto.randomUUID(), event: { kind: 'diagram', entityID: crypto.randomUUID(), parents: [],
        conversationID, text: encodeDiagram({ ...diagram, messageID: entityID }), createdAt: Date.now() } });
      // A topic title is kept with a complete answer, in the same batch, unless the chat got one meanwhile (a rename wins).
      c.answerTitle = topicTitle && result.status === 'complete' ? { id: crypto.randomUUID(), conversationID, text: cleanTopicTitle(topicTitle) ?? '', source: GENERATED_TITLE } : undefined;
      c.answer = entries; this.publish();
      if (this.durable) {
        // The final or interrupted answer enters the outbox in the same transaction that retires its turn.
        try { await this.history.commit(entries, { finishTurn: answerID, title: c.answerTitle }); c.answer = null; c.head = this.history.resolve(answerID); }
        catch { c.issue = 'storage'; }
        if (!c.answer) void this.history.flush(entries.map(e => e.id)).catch(() => {});
      } else {
        try { await this.history.append(entries, { title: c.answerTitle }); c.answer = null; c.head = answerID; } catch { c.issue = 'storage'; }
      }
    } else if (turn) {
      try { await this.journal!.dropTurn(answerID); }
      catch {
        // Keep ownership while cleanup is retryable; a live peer must not recover a refused checkpoint.
        c.issue = 'local_save';
        if (releaseTurn) { this.turnOwners.set(c.id, { id: answerID, release: releaseTurn, refused: true }); releaseTurn = null; }
      }
    }
    if (c.answer && releaseTurn) { this.turnOwners.set(c.id, { id: answerID, release: releaseTurn, refused: false }); releaseTurn = null; }
    releaseTurn?.();
    if (!c.answer) { c.liveText = ''; c.liveID = null; c.answerTitle = undefined; }
    c.phase = 'idle'; this.publish(); void this.refreshBalance();
  }
}
