import { decodeStoredFigureParts, stripPartMarkers } from './chat-figures';
// Private events (the decrypted payload of wire format 1) and the state they build — a port of
// ScienceReaderCore/PrivateState.swift and ConversationSummary.swift. Payloads are decoded and validated
// as Swift does; unknown keys are ignored, UUIDs are compared lowercase and written uppercase (as Swift's
// JSONEncoder writes them). History persists exact encrypted envelopes through the browser journal.
import { isUUID } from './bytes';

export type EventKind = 'conversation' | 'message' | 'note' | 'position' | 'diagram' | 'tombstone' | 'local_paper';
export type Role = 'user' | 'assistant';
export type TurnStatus = 'complete' | 'interrupted';
export interface TextAnchor { artifactID?: string; manifestSHA256?: string; quote: string; prefix: string; suffix: string; elementID?: string; page?: number }
export interface SourcePaperReference { format: 'source-membership-v1'; membershipID: string; source: 'arxiv'; sourceID: string; revision: number }
export function sourceReference(value: unknown): SourcePaperReference {
  const r = value as SourcePaperReference;
  if (!r || r.format !== 'source-membership-v1' || !isUUID(r.membershipID) || r.source !== 'arxiv' ||
    typeof r.sourceID !== 'string' || !/^(?:\d{4}\.\d{4,5}|[a-z][a-z.-]+(?:\.[A-Z]{2})?\/\d{7})$/.test(r.sourceID) ||
    !Number.isSafeInteger(r.revision) || r.revision < 1 || r.revision > 2147483647) throw new EventError('invalid_event');
  return {format:r.format,membershipID:r.membershipID.toLowerCase(),source:r.source,sourceID:r.sourceID,revision:r.revision};
}
export interface LocalPDFMembership { format: 'device-pdf-membership-v1'; title: string; pageCount: number; createdAt: number; archived: boolean; tags: string[] }
export function localPDFMembership(e: PrivateEvent): LocalPDFMembership {
  if (e.kind !== 'local_paper' || e.documentID || e.paperReference || !e.text) fail();
  let m: LocalPDFMembership;
  try { m = JSON.parse(e.text!); } catch { return fail(); }
  if (!m || m.format !== 'device-pdf-membership-v1' || typeof m.title !== 'string' || utf8Bytes(m.title) < 1 || utf8Bytes(m.title) > 2000 ||
    !Number.isInteger(m.pageCount) || m.pageCount < 1 || m.pageCount > 250 || !Number.isSafeInteger(m.createdAt) || m.createdAt < 0 || m.createdAt >= MAX_CREATED_AT ||
    typeof m.archived !== 'boolean' || !Array.isArray(m.tags) || m.tags.length > 32 || m.tags.some(t => typeof t !== 'string' || utf8Bytes(t) < 1 || utf8Bytes(t) > 120)) fail();
  return m;
}
export interface PrivateEvent {
  kind: EventKind; entityID: string; parents: string[]; conversationID?: string; documentID?: string; text?: string;
  paperReference?: SourcePaperReference;
  role?: Role; status?: TurnStatus; anchor?: TextAnchor; createdAt?: number;
  /** A conversation revision's title origin (2026-10-08): `generated` or `renamed`; any string from a later build is kept. */
  titleSource?: string;
  /** An answer's serving model and chat profile (2026-10-08), shown under it. */
  model?: string; profile?: string;
}
export const GENERATED_TITLE = 'generated', RENAMED_TITLE = 'renamed';
/** Bound on titleSource/model/profile (UTF-8 bytes), on every kind, exactly as Swift checks (PrivateEvent.maximumLabelBytes). */
export const MAX_LABEL_BYTES = 64;
export interface AppliedEvent { id: string; deviceID: string; payload: PrivateEvent }

export class EventError extends Error {}
const fail = (code = 'invalid_event'): never => { throw new EventError(code); };
const KINDS: readonly EventKind[] = ['conversation', 'message', 'note', 'position', 'diagram', 'tombstone', 'local_paper'];
const utf8Bytes = (s: string) => new TextEncoder().encode(s).length;
const absent = (v: unknown) => v === undefined || v === null;
const uuid = (v: unknown): string => (isUUID(v) ? v.toLowerCase() : fail());
const optional = <T>(v: unknown, read: (v: unknown) => T): T | undefined => (absent(v) ? undefined : read(v));
const string = (v: unknown): string => (typeof v === 'string' ? v : fail());
const MAX_CREATED_AT = 253_402_300_800_000; // year 10000

export function validateEvent(e: PrivateEvent): void {
  if (!KINDS.includes(e.kind) || !isUUID(e.entityID) || !Array.isArray(e.parents) || e.parents.some(p => !isUUID(p))
    || (e.conversationID !== undefined && !isUUID(e.conversationID)) || (e.documentID !== undefined && !isUUID(e.documentID))
    || (e.text !== undefined && typeof e.text !== 'string') || (e.role !== undefined && !['user', 'assistant'].includes(e.role))
    || (e.status !== undefined && !['complete', 'interrupted'].includes(e.status))) fail();
  if (e.parents.length > 100 || new Set(e.parents).size !== e.parents.length || utf8Bytes(e.text ?? '') > 200_000) fail();
  if (e.createdAt !== undefined && !(Number.isSafeInteger(e.createdAt) && e.createdAt >= 0 && e.createdAt < MAX_CREATED_AT)) fail();
  for (const label of [e.titleSource, e.model, e.profile]) if (label !== undefined && (typeof label !== 'string' || utf8Bytes(label) > MAX_LABEL_BYTES)) fail();
  if (e.paperReference && sourceReference(e.paperReference).membershipID !== e.documentID) fail();
  if (e.kind === 'local_paper') localPDFMembership(e);
  if (e.kind === 'message' && (!e.conversationID || !e.role || !e.status || e.text === undefined)) fail();
  if ((e.kind === 'note' || e.kind === 'diagram' || e.kind === 'conversation') && e.text === undefined) fail();
  if (e.kind === 'position' && (!e.documentID || !e.anchor)) fail();
  if (e.anchor) {
    const a = e.anchor;
    if ((a.artifactID !== undefined) === (a.manifestSHA256 !== undefined) || (a.artifactID !== undefined && !isUUID(a.artifactID)) || (a.manifestSHA256 !== undefined && !/^[a-f0-9]{64}$/.test(a.manifestSHA256)) || typeof a.quote !== 'string' || typeof a.prefix !== 'string' || typeof a.suffix !== 'string' || (a.elementID !== undefined && typeof a.elementID !== 'string')) fail();
    if (utf8Bytes(a.quote) > 20_000 || utf8Bytes(a.prefix) > 1000 || utf8Bytes(a.suffix) > 1000 || utf8Bytes(a.elementID ?? '') > 200
      || (a.page !== undefined && !(Number.isInteger(a.page) && a.page > 0 && a.page <= 250))) fail();
  }
}

/** A decrypted payload, decoded as Swift's synthesized `Decodable` would (required keys, enum values, integer times). */
export function decodeEvent(value: unknown): PrivateEvent {
  const v = value as Record<string, unknown>;
  if (!v || typeof v !== 'object' || Array.isArray(v) || !KINDS.includes(v.kind as EventKind) || !Array.isArray(v.parents)) fail();
  const anchor = optional(v.anchor, raw => {
    const a = raw as Record<string, unknown>;
    if (!a || typeof a !== 'object' || Array.isArray(a)) fail();
    return { artifactID: optional(a.artifactID, uuid), manifestSHA256: optional(a.manifestSHA256, string), quote: string(a.quote), prefix: string(a.prefix), suffix: string(a.suffix),
      elementID: optional(a.elementID, string), page: optional(a.page, p => (Number.isSafeInteger(p) ? p as number : fail())) };
  });
  const ref = optional(v.paperReference, sourceReference);
  if (ref && !absent(v.documentID)) fail();
  const event: PrivateEvent = {
    kind: v.kind as EventKind, entityID: uuid(v.entityID), parents: (v.parents as unknown[]).map(uuid),
    conversationID: optional(v.conversationID, uuid), documentID: ref?.membershipID ?? optional(v.documentID, uuid), paperReference: ref, text: optional(v.text, string),
    role: optional(v.role, r => (r === 'user' || r === 'assistant' ? r : fail())),
    status: optional(v.status, s => (s === 'complete' || s === 'interrupted' ? s : fail())),
    anchor, createdAt: optional(v.createdAt, t => (Number.isSafeInteger(t) ? t as number : fail())),
    titleSource: optional(v.titleSource, string), model: optional(v.model, string), profile: optional(v.profile, string),
  };
  validateEvent(event);
  return event;
}

const upper = (id: string) => id.toUpperCase();
/** The payload JSON, keys in a fixed order (so equal events encode identically). */
export function encodeEvent(e: PrivateEvent): Record<string, unknown> {
  validateEvent(e);
  const out: Record<string, unknown> = { kind: e.kind, entityID: upper(e.entityID), parents: e.parents.map(upper) };
  if (e.conversationID) out.conversationID = upper(e.conversationID);
  if (e.paperReference) out.paperReference = {...e.paperReference, membershipID: upper(e.paperReference.membershipID)};
  else if (e.documentID) out.documentID = upper(e.documentID);
  if (e.text !== undefined) out.text = e.text;
  if (e.role) out.role = e.role;
  if (e.status) out.status = e.status;
  if (e.anchor) {
    const a = e.anchor, anchor: Record<string, unknown> = { quote: a.quote, prefix: a.prefix, suffix: a.suffix };
    if (a.artifactID) anchor.artifactID = upper(a.artifactID);
    if (a.manifestSHA256) anchor.manifestSHA256 = a.manifestSHA256;
    if (a.elementID !== undefined) anchor.elementID = a.elementID;
    if (a.page !== undefined) anchor.page = a.page;
    out.anchor = anchor;
  }
  if (e.createdAt !== undefined) out.createdAt = e.createdAt;
  if (e.titleSource !== undefined) out.titleSource = e.titleSource;
  if (e.model !== undefined) out.model = e.model;
  if (e.profile !== undefined) out.profile = e.profile;
  return out;
}
const same = (a: AppliedEvent, b: AppliedEvent) => a.id === b.id && a.deviceID === b.deviceID && JSON.stringify(encodeEvent(a.payload)) === JSON.stringify(encodeEvent(b.payload));

export interface ConversationBranch { head: string; messages: AppliedEvent[]; complete: boolean }
export interface ConversationSummary {
  id: string; title: string; documentID?: string; messageCount: number; startedAt?: number; lastUsedAt?: number;
  lastArrival: number; startArrival: number; latestAnswer?: string; questions: string; anchor?: TextAnchor;
  /** Where `title` came from: absent for the first question, else `generated` (topic title) or `renamed`. */
  titleSource?: string;
  /** Words in the newest answer (All chats' Answer length). */
  latestAnswerWords: number;
}

/** A topic title as one plain line of at most 80 characters (ChatTopicTitle.clean): control and bidirectional
 * characters become spaces, whitespace collapses; null when nothing is left. */
export const MAX_TITLE_CHARACTERS = 80;
export function cleanTopicTitle(text: string): string | null {
  // Swift's CharacterSet.controlCharacters is Cc and Cf (bidirectional controls included), plus the line separators.
  const line = text.replace(/[\p{Cc}\p{Cf}\u2028\u2029]/gu, ' ').split(/\s+/).filter(Boolean).join(' ');
  if (!line) return null;
  // Swift counts Characters (grapheme clusters); a segmenter matches that where it exists.
  const graphemes = typeof Intl !== 'undefined' && 'Segmenter' in Intl
    ? [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(line)].map(s => s.segment) : [...line];
  return graphemes.length > MAX_TITLE_CHARACTERS ? graphemes.slice(0, MAX_TITLE_CHARACTERS).join('').trim() : line;
}

/** Immutable revisions plus tombstones. Arrival order never chooses the winner of concurrent edits. */
export class PrivateState {
  readonly events = new Map<string, AppliedEvent>();
  private arrival = new Map<string, number>();
  private nextArrival = 0;
  /** Changes with every applied, rolled-back or replaced event. Derived views (summaries, branches, revisions, diagrams)
   * are computed once per change and shared until the next (C2/C3): a render or a streamed token no longer rescans all
   * events. Cached arrays are frozen; callers copy before sorting. */
  private mutation = 0;
  private derived: Derived = emptyDerived(-1);
  get version(): number { return this.mutation; }
  private cache(): Derived {
    if (this.derived.mutation !== this.mutation) this.derived = emptyDerived(this.mutation);
    return this.derived;
  }
  private index(): Required<Pick<Derived, 'byEntity' | 'messages' | 'deleted' | 'kinds' | 'references'>> {
    const cache = this.cache();
    if (!cache.byEntity) {
      const byEntity = new Map<string, AppliedEvent[]>(), messages = new Map<string, AppliedEvent[]>(), deleted = new Set<string>(), kinds = new Map<EventKind, Set<string>>();
      const references = new Map<string, SourcePaperReference>();
      for (const e of this.events.values()) {
        const list = byEntity.get(e.payload.entityID); if (list) list.push(e); else byEntity.set(e.payload.entityID, [e]);
        if (e.payload.kind === 'tombstone') deleted.add(e.payload.entityID);
        if (e.payload.kind === 'message' && e.payload.conversationID) { const m = messages.get(e.payload.conversationID); if (m) m.push(e); else messages.set(e.payload.conversationID, [e]); }
        const ids = kinds.get(e.payload.kind); if (ids) ids.add(e.payload.entityID); else kinds.set(e.payload.kind, new Set([e.payload.entityID]));
        const reference = e.payload.paperReference; if (reference && !references.has(reference.membershipID)) references.set(reference.membershipID, reference);
      }
      Object.assign(cache, { byEntity, messages, deleted, kinds, references });
    }
    return cache as Required<Pick<Derived, 'byEntity' | 'messages' | 'deleted' | 'kinds' | 'references'>>;
  }
  /** Every event of an entity (tombstones included), in arrival order. */
  private entityEvents(entityID: string): readonly AppliedEvent[] { return this.index().byEntity.get(entityID) ?? []; }
  /** Every record of an entity (all revisions and tombstones), as a copy. */
  entityRecords(entityID: string): AppliedEvent[] { return [...this.entityEvents(entityID)]; }
  /** The entities that have at least one event of this kind (arrival order). */
  entitiesOfKind(kind: EventKind): string[] { return [...this.index().kinds.get(kind) ?? []]; }
  /** The first paper reference saved for a source membership (a chat started on it). */
  paperReference(membershipID: string): SourcePaperReference | undefined { return this.index().references.get(membershipID); }

  arrivalIndex(id: string): number | undefined { return this.arrival.get(id); }

  /** A pulled page or locally sealed batch is all-or-nothing, including a late conflict/cycle. */
  applyBatch(events: AppliedEvent[]): void {
    const added: string[] = [], before = this.nextArrival;
    try {
      for (const event of events) {
        const exists = this.events.has(event.id);
        this.apply(event);
        if (!exists) added.push(event.id);
      }
    } catch (error) {
      for (const id of added) { this.events.delete(id); this.arrival.delete(id); }
      this.nextArrival = before; this.mutation++;
      throw error;
    }
  }

  /** Whether a batch would apply (conflicts, cycles, invalid payloads), without changing this state. */
  check(events: AppliedEvent[]): void {
    const added: string[] = [], before = this.nextArrival;
    try {
      for (const event of events) { const exists = this.events.has(event.id); this.apply(event); if (!exists) added.push(event.id); }
    } finally {
      for (const id of added) { this.events.delete(id); this.arrival.delete(id); }
      this.nextArrival = before; if (added.length) this.mutation++;
    }
  }

  /** Local rebase mappings (retired pending event → its fresh-ID replacement), as PrivateState.applyLocalReplacements. */
  private replacements = new Map<string, string>();
  resolve(id: string): string { let next = id; for (let i = 0; i < 64 && this.replacements.has(next); i++) next = this.replacements.get(next)!; return next; }
  /** Restores mappings committed earlier (the retired events themselves are not loaded). */
  restoreReplacements(mapping: Map<string, string>) { for (const [old, next] of mapping) this.replacements.set(old, next); if (mapping.size) this.mutation++; }
  /** Prove a local rebase is valid before its transaction commits. */
  checkLocalReplacements(events: AppliedEvent[], mapping: Map<string, string>): void {
    const staged = new PrivateState();
    staged.applyBatch([...this.events.values(), ...events]);
    staged.applyLocalReplacements(mapping);
  }
  /**
   * Replaces retired local events by already applied replacements: content must match with parents remapped, and no
   * retained event may still refer to a retired one. A replacement keeps its original's place in the arrival order.
   */
  applyLocalReplacements(mapping: Map<string, string>): void {
    if (!mapping.size || new Set(mapping.values()).size !== mapping.size || [...mapping.keys()].some(k => [...mapping.values()].includes(k))) fail('corrupt_data');
    for (const [oldID, newID] of mapping) {
      const old = this.events.get(oldID), next = this.events.get(newID);
      if (!old || !next || this.replacements.has(oldID)) fail('corrupt_data');
      const expected = { ...old!.payload, parents: old!.payload.parents.map(p => mapping.get(p) ?? p) };
      if (JSON.stringify(encodeEvent(expected)) !== JSON.stringify(encodeEvent(next!.payload))) fail('corrupt_data');
    }
    const retired = new Set(mapping.keys());
    for (const e of this.events.values()) if (!retired.has(e.id) && e.payload.parents.some(p => retired.has(p))) fail('corrupt_data');
    for (const [oldID, newID] of mapping) {
      this.events.delete(oldID); this.replacements.set(oldID, newID);
      const original = this.arrival.get(oldID);
      this.arrival.delete(oldID);
      if (original !== undefined) this.arrival.set(newID, Math.min(original, this.arrival.get(newID) ?? original));
    }
    this.mutation++;
  }

  apply(event: AppliedEvent): void {
    if (this.replacements.has(event.id)) fail('event_conflict');
    validateEvent(event.payload);
    const existing = this.events.get(event.id);
    if (existing) { if (!same(existing, event)) fail('event_conflict'); return; }
    if (event.payload.parents.includes(event.id)) fail();
    this.events.set(event.id, event); this.mutation++;
    if (this.containsCycle(event.id)) { this.events.delete(event.id); fail(); }
    this.arrival.set(event.id, this.nextArrival++);
  }

  private containsCycle(id: string): boolean {
    const stack: [string, boolean][] = [[id, false]], active = new Set<string>(), finished = new Set<string>();
    while (stack.length) {
      const [current, leaving] = stack.pop()!;
      if (leaving) { active.delete(current); finished.add(current); continue; }
      if (finished.has(current)) continue;
      if (active.has(current)) return true;
      active.add(current);
      stack.push([current, true]);
      for (const parent of this.events.get(current)?.payload.parents ?? []) stack.push([parent, false]);
    }
    return false;
  }

  private deleted(): ReadonlySet<string> { return this.index().deleted; }
  isDeleted(entityID: string): boolean { return this.deleted().has(entityID); }

  /** Each continuation follows its causal predecessor; concurrent children are separate branches (ID order for stability). */
  conversationBranches(conversationID: string): readonly ConversationBranch[] {
    const cache = this.cache(), cached = cache.branches.get(conversationID);
    if (cached) return cached;
    const branches = freezeBranches(this.computeBranches(conversationID));
    cache.branches.set(conversationID, branches);
    return branches;
  }
  private computeBranches(conversationID: string): ConversationBranch[] {
    const deleted = this.deleted();
    if (deleted.has(conversationID)) return [];
    const messages = (this.index().messages.get(conversationID) ?? []).filter(e => !deleted.has(e.payload.entityID));
    const parents = new Set<string>();
    for (const message of messages) {
      const candidates = [...message.payload.parents], visited = new Set<string>();
      while (candidates.length) {
        const id = candidates.pop()!;
        if (visited.has(id)) continue;
        visited.add(id);
        const parent = this.events.get(id);
        if (!parent || parent.payload.kind !== 'message' || parent.payload.conversationID !== conversationID) continue;
        if (deleted.has(parent.payload.entityID)) candidates.push(...parent.payload.parents); else parents.add(id);
      }
    }
    return messages.filter(m => !parents.has(m.id)).sort((a, b) => (a.id < b.id ? -1 : 1))
      .map(head => this.branchThrough(conversationID, head.id, deleted)).filter((b): b is ConversationBranch => !!b);
  }

  conversationBranch(conversationID: string, head: string): ConversationBranch | null {
    // A head that is one of the conversation's branch tips is that cached branch.
    const tip = this.conversationBranches(conversationID).find(b => b.head === head);
    if (tip) return tip;
    const branch = this.branchThrough(conversationID, head, this.deleted());
    return branch && freezeBranches([branch])[0];
  }

  private branchThrough(conversationID: string, head: string, deleted: ReadonlySet<string>): ConversationBranch | null {
    const first = this.events.get(head);
    if (deleted.has(conversationID) || !first || first.payload.kind !== 'message' || first.payload.conversationID !== conversationID) return null;
    const path: AppliedEvent[] = [], visited = new Set<string>();
    let next: string | undefined = head, complete = true;
    while (next) {
      const event = this.events.get(next);
      if (visited.has(next) || !event) { complete = false; break; }
      visited.add(next);
      if (event.payload.kind !== 'message' || event.payload.conversationID !== conversationID) { complete = false; break; }
      if (!deleted.has(event.payload.entityID)) path.push(event);
      const predecessors: string[] = [];
      for (const parentID of event.payload.parents) {
        const parent = this.events.get(parentID);
        if (!parent) { complete = false; continue; }
        if (parent.payload.kind === 'message' && parent.payload.conversationID === conversationID) predecessors.push(parentID);
        else if (parent.payload.kind !== 'conversation' || parent.payload.entityID !== conversationID) complete = false;
      }
      if (predecessors.length > 1) { complete = false; break; }
      next = predecessors[0];
    }
    return { head, messages: path.reverse(), complete };
  }

  revisions(entityID: string): AppliedEvent[] {
    if (this.isDeleted(entityID)) return [];
    const revisions = this.entityEvents(entityID).filter(e => e.payload.kind !== 'tombstone');
    const superseded = new Set(revisions.flatMap(e => e.payload.parents));
    return revisions.filter(e => !superseded.has(e.id)).sort((a, b) => (a.id < b.id ? -1 : 1));
  }

  /** A conversation revision giving it a topic title (PrivateState.titledConversation): the current revision's paper,
   * passage and start time are kept; its parents are every current revision, so concurrent titles resolve to this one. */
  titledConversation(conversationID: string, title: string, source: string): PrivateEvent | null {
    const current = this.revisions(conversationID).filter(e => e.payload.kind === 'conversation');
    const base = current[0], text = cleanTopicTitle(title);
    if (!base || !text) return null;
    const event: PrivateEvent = { kind: 'conversation', entityID: conversationID, parents: current.map(e => e.id), text, titleSource: source };
    if (base.payload.paperReference) event.paperReference = base.payload.paperReference;
    if (base.payload.documentID) event.documentID = base.payload.documentID;
    if (base.payload.anchor) event.anchor = base.payload.anchor;
    if (base.payload.createdAt !== undefined) event.createdAt = base.payload.createdAt;
    return event;
  }

  /** Every saved, undeleted conversation (one pass over the events, once per change), as All chats lists them. */
  conversationSummaries(): readonly ConversationSummary[] {
    const cache = this.cache();
    return cache.summaries ??= Object.freeze(this.computeSummaries());
  }
  private computeSummaries(): ConversationSummary[] {
    const deleted = new Set<string>(), roots = new Map<string, AppliedEvent[]>(), messages = new Map<string, AppliedEvent[]>();
    for (const e of this.events.values()) {
      if (e.payload.kind === 'tombstone') deleted.add(e.payload.entityID);
      else if (e.payload.kind === 'conversation') roots.set(e.payload.entityID, [...(roots.get(e.payload.entityID) ?? []), e]);
      else if (e.payload.kind === 'message' && e.payload.conversationID) messages.set(e.payload.conversationID, [...(messages.get(e.payload.conversationID) ?? []), e]);
    }
    const out: ConversationSummary[] = [];
    const arrival = (id: string) => this.arrival.get(id) ?? -1;
    for (const [id, revisions] of roots) {
      if (deleted.has(id)) continue;
      const superseded = new Set(revisions.flatMap(e => e.payload.parents));
      const root = revisions.filter(e => !superseded.has(e.id)).sort((a, b) => (a.id < b.id ? -1 : 1))[0];
      if (!root) continue;
      const surviving = (messages.get(id) ?? []).filter(e => !deleted.has(e.payload.entityID)).sort((a, b) => arrival(a.id) - arrival(b.id));
      const times = surviving.map(e => e.payload.createdAt).filter((t): t is number => t !== undefined);
      const rootTime = root.payload.createdAt;
      const all = rootTime !== undefined ? [...times, rootTime] : times;
      const answer = [...surviving].reverse().find(e => e.payload.role === 'assistant')?.payload.text;
      let questions = '';
      for (const m of [...surviving].reverse()) {
        if (m.payload.role !== 'user' || questions.length >= 4000 || !m.payload.text) continue;
        questions += (questions ? '\n' : '') + m.payload.text.slice(0, 4000 - questions.length);
      }
      out.push({ id, title: root.payload.text ?? '', titleSource: root.payload.titleSource, documentID: root.payload.documentID, messageCount: new Set(surviving.map(e => e.payload.entityID)).size,
        startedAt: rootTime ?? (times.length ? Math.min(...times) : undefined), lastUsedAt: all.length ? Math.max(...all) : undefined,
        lastArrival: Math.max(-1, ...[...revisions, ...surviving].map(e => arrival(e.id))), startArrival: Math.min(...revisions.map(e => arrival(e.id))),
        latestAnswer: answer ? stripPartMarkers(answer).slice(0, 1000) : undefined, questions, anchor: root.payload.anchor,
        latestAnswerWords: answer ? stripPartMarkers(answer).split(/\s+/).filter(Boolean).length : 0 });
    }
    return out.sort((a, b) => (a.id < b.id ? -1 : 1));
  }

  /** Every saved diagram outside deleted chats (ChatDiagram.swift `diagrams()`, Settings › Your assets › Diagrams),
   * newest first, with the paper of the chat that drew it (a figure's parts load their figure from it). */
  savedDiagrams(): readonly SavedDiagram[] {
    const cache = this.cache();
    return cache.savedDiagrams ??= Object.freeze(this.computeSavedDiagrams());
  }
  private computeSavedDiagrams(): SavedDiagram[] {
    const ids = this.index().kinds.get('diagram') ?? new Set<string>();
    const out: SavedDiagram[] = [];
    for (const id of ids) {
      const event = this.revisions(id)[0], conversationID = event?.payload.conversationID;
      if (!event || (conversationID && this.isDeleted(conversationID))) continue;
      const diagram = decodeDiagram(event.payload.text);
      if (!diagram) continue;
      const documentID = conversationID ? this.revisions(conversationID).find(e => e.payload.kind === 'conversation')?.payload.documentID : undefined;
      out.push({ id, title: diagram.title, source: diagram.source, format: diagram.format ?? 'mermaid-v1', conversationID, documentID, createdAt: event.payload.createdAt });
    }
    return out.sort((a, b) => (b.createdAt ?? -1) - (a.createdAt ?? -1) || (a.id < b.id ? -1 : 1));
  }

  /** Saved diagrams (mermaid-v1 JSON in `text`) by the assistant message that drew them. */
  diagramsByMessage(): ReadonlyMap<string, { id: string; title: string; source: string; format: DiagramFormat }> {
    const cache = this.cache();
    return cache.diagrams ??= this.computeDiagramsByMessage();
  }
  private computeDiagramsByMessage(): Map<string, { id: string; title: string; source: string; format: DiagramFormat }> {
    const out = new Map<string, { id: string; title: string; source: string; format: DiagramFormat }>();
    const ids = this.index().kinds.get('diagram') ?? new Set<string>();
    for (const id of [...ids].sort()) {
      const event = this.revisions(id)[0];
      if (!event || (event.payload.conversationID && this.isDeleted(event.payload.conversationID))) continue;
      const diagram = decodeDiagram(event.payload.text);
      if (diagram?.messageID && !out.has(diagram.messageID)) out.set(diagram.messageID, { id, title: diagram.title, source: diagram.source, format: diagram.format ?? 'mermaid-v1' });
    }
    return out;
  }
}

interface Derived {
  mutation: number; branches: Map<string, readonly ConversationBranch[]>;
  byEntity?: Map<string, AppliedEvent[]>; messages?: Map<string, AppliedEvent[]>; deleted?: Set<string>; kinds?: Map<EventKind, Set<string>>;
  references?: Map<string, SourcePaperReference>; summaries?: readonly ConversationSummary[]; savedDiagrams?: readonly SavedDiagram[];
  diagrams?: Map<string, { id: string; title: string; source: string; format: DiagramFormat }>;
}
const emptyDerived = (mutation: number): Derived => ({ mutation, branches: new Map() });
/** Shared branches can't be changed by a caller (copy before sorting). */
function freezeBranches(branches: ConversationBranch[]): readonly ConversationBranch[] {
  for (const b of branches) { Object.freeze(b.messages); Object.freeze(b); }
  return Object.freeze(branches);
}

// ---------- Diagrams (ChatDiagram.swift) ----------

/** `html-v1` (2026-10-15): a visual answer, the server-sanitized HTML fragment the chat frame shows with no scripts. */
/** `figure-parts-v1` (2026-10-15): an answer's figure parts (chat-figures.ts `StoredFigureParts`), never the image. */
export type DiagramFormat = 'mermaid-v1' | 'html-v1' | 'figure-parts-v1';
export interface ChatDiagram { title: string; source: string; messageID?: string; format?: DiagramFormat }
export interface SavedDiagram { id: string; title: string; source: string; format: DiagramFormat; conversationID?: string; documentID?: string; createdAt?: number }
const DIAGRAM_BYTES: Record<DiagramFormat, number> = { 'mermaid-v1': 16_000, 'html-v1': 24_000, 'figure-parts-v1': 16_000 };
export function makeDiagram(title: string, source: string, messageID?: string, format: DiagramFormat = 'mermaid-v1'): ChatDiagram | null {
  const t = title.trim();
  if (!t || [...t].length > 200 || !source.trim() || utf8Bytes(source) > DIAGRAM_BYTES[format]) return null;
  if (format === 'figure-parts-v1' && !decodeStoredFigureParts(source)) return null;
  return format === 'mermaid-v1' ? { title: t, source, messageID } : { title: t, source, messageID, format };
}
/** Sorted keys, as Swift encodes it. */
export function encodeDiagram(d: ChatDiagram): string {
  const format = d.format ?? 'mermaid-v1';
  return JSON.stringify(d.messageID ? { format, messageID: upper(d.messageID), source: d.source, title: d.title } : { format, source: d.source, title: d.title });
}
export function decodeDiagram(text: string | undefined): ChatDiagram | null {
  if (!text || utf8Bytes(text) > 48_000) return null;
  try {
    const v = JSON.parse(text) as Record<string, unknown>;
    if ((v.format !== 'mermaid-v1' && v.format !== 'html-v1' && v.format !== 'figure-parts-v1') || typeof v.title !== 'string' || typeof v.source !== 'string') return null;
    if (!absent(v.messageID) && !isUUID(v.messageID)) return null;
    return makeDiagram(v.title, v.source, isUUID(v.messageID) ? v.messageID.toLowerCase() : undefined, v.format as DiagramFormat);
  } catch { return null; }
}
