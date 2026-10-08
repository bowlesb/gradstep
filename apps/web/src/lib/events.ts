// Private events (the decrypted payload of wire format 1) and the state they build — a port of
// ScienceReaderCore/PrivateState.swift and ConversationSummary.swift. Payloads are decoded and validated
// as Swift does; unknown keys are ignored, UUIDs are compared lowercase and written uppercase (as Swift's
// JSONEncoder writes them). Nothing here is persisted: the browser keeps history in memory only.
import { isUUID } from './bytes';

export type EventKind = 'conversation' | 'message' | 'note' | 'position' | 'diagram' | 'tombstone';
export type Role = 'user' | 'assistant';
export type TurnStatus = 'complete' | 'interrupted';
export interface TextAnchor { artifactID: string; quote: string; prefix: string; suffix: string; elementID?: string; page?: number }
export interface PrivateEvent {
  kind: EventKind; entityID: string; parents: string[]; conversationID?: string; documentID?: string; text?: string;
  role?: Role; status?: TurnStatus; anchor?: TextAnchor; createdAt?: number;
}
export interface AppliedEvent { id: string; deviceID: string; payload: PrivateEvent }

export class EventError extends Error {}
const fail = (code = 'invalid_event'): never => { throw new EventError(code); };
const KINDS: readonly EventKind[] = ['conversation', 'message', 'note', 'position', 'diagram', 'tombstone'];
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
  if (e.kind === 'message' && (!e.conversationID || !e.role || !e.status || e.text === undefined)) fail();
  if ((e.kind === 'note' || e.kind === 'diagram' || e.kind === 'conversation') && e.text === undefined) fail();
  if (e.kind === 'position' && (!e.documentID || !e.anchor)) fail();
  if (e.anchor) {
    const a = e.anchor;
    if (!isUUID(a.artifactID) || typeof a.quote !== 'string' || typeof a.prefix !== 'string' || typeof a.suffix !== 'string' || (a.elementID !== undefined && typeof a.elementID !== 'string')) fail();
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
    return { artifactID: uuid(a.artifactID), quote: string(a.quote), prefix: string(a.prefix), suffix: string(a.suffix),
      elementID: optional(a.elementID, string), page: optional(a.page, p => (Number.isSafeInteger(p) ? p as number : fail())) };
  });
  const event: PrivateEvent = {
    kind: v.kind as EventKind, entityID: uuid(v.entityID), parents: (v.parents as unknown[]).map(uuid),
    conversationID: optional(v.conversationID, uuid), documentID: optional(v.documentID, uuid), text: optional(v.text, string),
    role: optional(v.role, r => (r === 'user' || r === 'assistant' ? r : fail())),
    status: optional(v.status, s => (s === 'complete' || s === 'interrupted' ? s : fail())),
    anchor, createdAt: optional(v.createdAt, t => (Number.isSafeInteger(t) ? t as number : fail())),
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
  if (e.documentID) out.documentID = upper(e.documentID);
  if (e.text !== undefined) out.text = e.text;
  if (e.role) out.role = e.role;
  if (e.status) out.status = e.status;
  if (e.anchor) {
    const a = e.anchor, anchor: Record<string, unknown> = { artifactID: upper(a.artifactID), quote: a.quote, prefix: a.prefix, suffix: a.suffix };
    if (a.elementID !== undefined) anchor.elementID = a.elementID;
    if (a.page !== undefined) anchor.page = a.page;
    out.anchor = anchor;
  }
  if (e.createdAt !== undefined) out.createdAt = e.createdAt;
  return out;
}
const same = (a: AppliedEvent, b: AppliedEvent) => a.id === b.id && a.deviceID === b.deviceID && JSON.stringify(encodeEvent(a.payload)) === JSON.stringify(encodeEvent(b.payload));

export interface ConversationBranch { head: string; messages: AppliedEvent[]; complete: boolean }
export interface ConversationSummary {
  id: string; title: string; documentID?: string; messageCount: number; startedAt?: number; lastUsedAt?: number;
  lastArrival: number; startArrival: number; latestAnswer?: string; questions: string; anchor?: TextAnchor;
}

/** Immutable revisions plus tombstones. Arrival order never chooses the winner of concurrent edits. */
export class PrivateState {
  readonly events = new Map<string, AppliedEvent>();
  private arrival = new Map<string, number>();
  private nextArrival = 0;

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
      this.nextArrival = before;
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
      this.nextArrival = before;
    }
  }

  /** Local rebase mappings (retired pending event → its fresh-ID replacement), as PrivateState.applyLocalReplacements. */
  private replacements = new Map<string, string>();
  resolve(id: string): string { let next = id; for (let i = 0; i < 64 && this.replacements.has(next); i++) next = this.replacements.get(next)!; return next; }
  /** Restores mappings committed earlier (the retired events themselves are not loaded). */
  restoreReplacements(mapping: Map<string, string>) { for (const [old, next] of mapping) this.replacements.set(old, next); }
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
  }

  apply(event: AppliedEvent): void {
    if (this.replacements.has(event.id)) fail('event_conflict');
    validateEvent(event.payload);
    const existing = this.events.get(event.id);
    if (existing) { if (!same(existing, event)) fail('event_conflict'); return; }
    if (event.payload.parents.includes(event.id)) fail();
    this.events.set(event.id, event);
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

  private deleted(): Set<string> {
    const out = new Set<string>();
    for (const e of this.events.values()) if (e.payload.kind === 'tombstone') out.add(e.payload.entityID);
    return out;
  }
  isDeleted(entityID: string): boolean {
    for (const e of this.events.values()) if (e.payload.entityID === entityID && e.payload.kind === 'tombstone') return true;
    return false;
  }

  /** Each continuation follows its causal predecessor; concurrent children are separate branches (ID order for stability). */
  conversationBranches(conversationID: string): ConversationBranch[] {
    const deleted = this.deleted();
    if (deleted.has(conversationID)) return [];
    const messages = [...this.events.values()].filter(e => e.payload.kind === 'message' && e.payload.conversationID === conversationID && !deleted.has(e.payload.entityID));
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
    return this.branchThrough(conversationID, head, this.deleted());
  }

  private branchThrough(conversationID: string, head: string, deleted: Set<string>): ConversationBranch | null {
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
    const revisions = [...this.events.values()].filter(e => e.payload.entityID === entityID && e.payload.kind !== 'tombstone');
    const superseded = new Set(revisions.flatMap(e => e.payload.parents));
    return revisions.filter(e => !superseded.has(e.id)).sort((a, b) => (a.id < b.id ? -1 : 1));
  }

  /** Every saved, undeleted conversation (one pass over the events), as All chats lists them. */
  conversationSummaries(): ConversationSummary[] {
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
      out.push({ id, title: root.payload.text ?? '', documentID: root.payload.documentID, messageCount: new Set(surviving.map(e => e.payload.entityID)).size,
        startedAt: rootTime ?? (times.length ? Math.min(...times) : undefined), lastUsedAt: all.length ? Math.max(...all) : undefined,
        lastArrival: Math.max(-1, ...[...revisions, ...surviving].map(e => arrival(e.id))), startArrival: Math.min(...revisions.map(e => arrival(e.id))),
        latestAnswer: answer?.slice(0, 1000), questions, anchor: root.payload.anchor });
    }
    return out.sort((a, b) => (a.id < b.id ? -1 : 1));
  }

  /** Saved diagrams (mermaid-v1 JSON in `text`) by the assistant message that drew them. */
  diagramsByMessage(): Map<string, { id: string; title: string; source: string }> {
    const out = new Map<string, { id: string; title: string; source: string }>();
    const ids = new Set([...this.events.values()].filter(e => e.payload.kind === 'diagram').map(e => e.payload.entityID));
    for (const id of [...ids].sort()) {
      const event = this.revisions(id)[0];
      if (!event || (event.payload.conversationID && this.isDeleted(event.payload.conversationID))) continue;
      const diagram = decodeDiagram(event.payload.text);
      if (diagram?.messageID && !out.has(diagram.messageID)) out.set(diagram.messageID, { id, title: diagram.title, source: diagram.source });
    }
    return out;
  }
}

// ---------- Diagrams (ChatDiagram.swift) ----------

export interface ChatDiagram { title: string; source: string; messageID?: string }
export function makeDiagram(title: string, source: string, messageID?: string): ChatDiagram | null {
  const t = title.trim();
  if (!t || [...t].length > 200 || !source.trim() || utf8Bytes(source) > 16_000) return null;
  return { title: t, source, messageID };
}
/** Sorted keys, as Swift encodes it. */
export function encodeDiagram(d: ChatDiagram): string {
  return JSON.stringify(d.messageID ? { format: 'mermaid-v1', messageID: upper(d.messageID), source: d.source, title: d.title }
    : { format: 'mermaid-v1', source: d.source, title: d.title });
}
export function decodeDiagram(text: string | undefined): ChatDiagram | null {
  if (!text || utf8Bytes(text) > 32_000) return null;
  try {
    const v = JSON.parse(text) as Record<string, unknown>;
    if (v.format !== 'mermaid-v1' || typeof v.title !== 'string' || typeof v.source !== 'string') return null;
    if (!absent(v.messageID) && !isUUID(v.messageID)) return null;
    return makeDiagram(v.title, v.source, isUUID(v.messageID) ? v.messageID.toLowerCase() : undefined);
  } catch { return null; }
}
