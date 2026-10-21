// Notes and snippets records (docs/architecture/NOTES_AND_SNIPPETS.md, "Implementation contract"). Each record is the
// JSON `text` of an encrypted `note` PrivateEvent whose entityID is the note's or entry's ID. Records are recognised by
// `format == "gradstep-notes-v1"`; every other `note` event (Library catalogs, anything older) is ignored here, and the
// catalog reducer ignores these (tests prove both directions). Field order follows tests/fixtures/notes/notes-v1.json,
// so a decoded fixture encodes back to the same bytes; key order is not otherwise part of the contract.
import { isUUID } from './bytes';
import type { AppliedEvent, PrivateEvent, PrivateState } from './events';

export const NOTES_FORMAT = 'gradstep-notes-v1';
export const NOTES_LIMITS = {
  titleScalars: 80, commentBytes: 16 * 1024, quoteBytes: 20 * 1024, recordBytes: 48 * 1024, blockIDs: 64, rects: 64,
  authors: 64, authorBytes: 512, sourceTitleBytes: 2_000, sectionBytes: 1_000, labelBytes: 200, urlBytes: 2_048,
  // The stored blob is nonce ‖ ciphertext ‖ tag: 28 bytes more than the image (the server's 413 limit is 2 MiB + 28).
  fullBytes: 2 * 1024 * 1024 + 28, thumbBytes: 64 * 1024 + 28, fullEdge: 4_096, fullPixels: 6_000_000, thumbEdge: 480,
  counter: 2_147_483_647, offsetMinutes: 24 * 60, parents: 100,
};
const MAX_TIME = 253_402_300_800_000; // year 10000, as events.ts

export type EntryKind = 'region' | 'quote' | 'text';
export type MediaType = 'image/png' | 'image/jpeg';
export interface NoteRecord { format: typeof NOTES_FORMAT; record: 'note'; noteID: string; title: string; createdAt: number }
export interface EntrySource {
  kind: 'arxiv' | 'local_pdf' | 'document'; title: string; authors: string[]; sourceID: string | null; revision: number | null; url: string | null;
  section: string | null; label: string | null; membershipID?: string; pdfSHA256?: string; page?: number;
}
export interface EntryAnchor {
  manifestSHA256: string | null; rendererRevision: number | null; blockIDs: string[]; rects: [number, number, number, number][];
  viewport: [number, number, number] | null; quote: string | null;
}
export interface MediaDescriptor { blobID: string; key: string; sha256: string; bytes: number; type: MediaType; width: number; height: number }
export interface EntryMedia { full: MediaDescriptor; thumb?: MediaDescriptor }
export interface EntryRecord {
  format: typeof NOTES_FORMAT; record: 'entry'; entryID: string; noteID: string; kind: EntryKind; counter: number;
  capturedAt: number; offsetMinutes: number; comment: string; source: EntrySource | null; anchor: EntryAnchor | null;
  quote: string | null; media: EntryMedia | null;
}
export type NotesRecord = NoteRecord | EntryRecord;

export class NotesRecordError extends Error { constructor(readonly reason: string) { super(reason); } }
const invalid = (reason: string): never => { throw new NotesRecordError(reason); };
const bytes = (s: string) => new TextEncoder().encode(s).length;
const scalars = (s: string) => [...s].length;
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const absent = (v: unknown) => v === undefined || v === null;
const id = (v: unknown, reason: string): string => (isUUID(v) ? v.toLowerCase() : invalid(reason));
const integer = (v: unknown, min: number, max: number, reason: string): number => (Number.isSafeInteger(v) && (v as number) >= min && (v as number) <= max ? v as number : invalid(reason));
const text = (v: unknown, maxBytes: number, reason: string): string => (typeof v === 'string' && bytes(v) <= maxBytes ? v : invalid(reason));
const nullableText = (v: unknown, maxBytes: number, reason: string): string | null => (absent(v) ? null : text(v, maxBytes, reason));
const HEX64 = /^[0-9a-f]{64}$/, BLOCK = /^[0-9A-Za-z_-]{1,200}$/, BASE64_32 = /^[A-Za-z0-9+/]{43}=$/;

// Swift's CharacterSet.whitespacesAndNewlines, which the catalog names also use (library-catalogs.ts).
const EDGE_SPACE = /^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/gu;
/** A note title as typed: one line, trimmed, 1–80 Unicode scalars; null when nothing usable is left. */
export function cleanNoteTitle(raw: string): string | null {
  const line = raw.replace(/[\p{Cc}\u2028\u2029]/gu, ' ').replace(EDGE_SPACE, '');
  return line && scalars(line) <= NOTES_LIMITS.titleScalars ? line : null;
}
function title(v: unknown): string {
  if (typeof v !== 'string') return invalid('title must be text');
  if (!v.replace(EDGE_SPACE, '')) return invalid('empty title');
  if (v.replace(EDGE_SPACE, '') !== v) return invalid('title not trimmed');
  if (scalars(v) > NOTES_LIMITS.titleScalars) return invalid('title over 80 Unicode scalars');
  return v;
}

function media(v: unknown, thumb: boolean): MediaDescriptor {
  if (!isObject(v)) return invalid('invalid media');
  const type = v.type === 'image/png' || v.type === 'image/jpeg' ? v.type : invalid('unsupported media type');
  const width = integer(v.width, 1, thumb ? NOTES_LIMITS.thumbEdge : NOTES_LIMITS.fullEdge, 'media dimensions out of bounds');
  const height = integer(v.height, 1, thumb ? NOTES_LIMITS.thumbEdge : NOTES_LIMITS.fullEdge, 'media dimensions out of bounds');
  if (!thumb && width * height > NOTES_LIMITS.fullPixels) invalid('media over 6 megapixels');
  if (typeof v.key !== 'string' || !BASE64_32.test(v.key)) invalid('media key must be 32 bytes');
  if (typeof v.sha256 !== 'string' || !HEX64.test(v.sha256)) invalid('media digest must be SHA-256 hex');
  return { blobID: id(v.blobID, 'media blobID must be a UUID'), key: v.key as string, sha256: v.sha256 as string,
    bytes: integer(v.bytes, 29, thumb ? NOTES_LIMITS.thumbBytes : NOTES_LIMITS.fullBytes, 'media bytes out of bounds'), type, width, height };
}
function source(v: unknown): EntrySource | null {
  if (absent(v)) return null;
  if (!isObject(v)) return invalid('invalid source');
  const kind = v.kind === 'arxiv' || v.kind === 'local_pdf' || v.kind === 'document' ? v.kind : invalid('unknown source kind');
  if (!Array.isArray(v.authors) || v.authors.length > NOTES_LIMITS.authors) invalid('invalid source authors');
  const url = nullableText(v.url, NOTES_LIMITS.urlBytes, 'invalid source url');
  if (url !== null && !/^https:\/\/[^\s]+$/.test(url)) invalid('invalid source url');
  const out: EntrySource = { kind, title: text(v.title, NOTES_LIMITS.sourceTitleBytes, 'invalid source title'),
    authors: (v.authors as unknown[]).map(a => text(a, NOTES_LIMITS.authorBytes, 'invalid source authors')),
    sourceID: nullableText(v.sourceID, 200, 'invalid source id'), revision: absent(v.revision) ? null : integer(v.revision, 1, NOTES_LIMITS.counter, 'invalid source revision'),
    url, section: nullableText(v.section, NOTES_LIMITS.sectionBytes, 'invalid source section'), label: nullableText(v.label, NOTES_LIMITS.labelBytes, 'invalid source label') };
  if (!absent(v.membershipID)) out.membershipID = id(v.membershipID, 'invalid source membership');
  if (!absent(v.pdfSHA256)) out.pdfSHA256 = typeof v.pdfSHA256 === 'string' && HEX64.test(v.pdfSHA256) ? v.pdfSHA256 : invalid('invalid source PDF digest');
  if (!absent(v.page)) out.page = integer(v.page, 1, 10_000, 'invalid source page');
  return out;
}
function anchor(v: unknown): EntryAnchor | null {
  if (absent(v)) return null;
  if (!isObject(v)) return invalid('invalid anchor');
  const manifest = absent(v.manifestSHA256) ? null : typeof v.manifestSHA256 === 'string' && HEX64.test(v.manifestSHA256) ? v.manifestSHA256 : invalid('invalid anchor manifest');
  if (!Array.isArray(v.blockIDs) || v.blockIDs.length > NOTES_LIMITS.blockIDs || v.blockIDs.some(b => typeof b !== 'string' || !BLOCK.test(b))) invalid('invalid anchor blocks');
  if (!Array.isArray(v.rects) || v.rects.length > NOTES_LIMITS.rects) invalid('invalid anchor rectangles');
  const rects = (v.rects as unknown[]).map(r => {
    if (!Array.isArray(r) || r.length !== 4 || r.some(n => typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 1)) invalid('invalid anchor rectangles');
    const [x, y, w, h] = r as number[];
    return [x, y, w, h] as [number, number, number, number];
  });
  let viewport: [number, number, number] | null = null;
  if (!absent(v.viewport)) {
    const p = v.viewport;
    if (!Array.isArray(p) || p.length !== 3 || p.some(n => typeof n !== 'number' || !Number.isFinite(n) || n <= 0 || n > 100_000)) invalid('invalid anchor viewport');
    viewport = [(p as number[])[0], (p as number[])[1], (p as number[])[2]];
  }
  return { manifestSHA256: manifest, rendererRevision: absent(v.rendererRevision) ? null : integer(v.rendererRevision, 0, NOTES_LIMITS.counter, 'invalid anchor renderer'),
    blockIDs: [...v.blockIDs as string[]], rects, viewport, quote: nullableText(v.quote, NOTES_LIMITS.quoteBytes, 'quote over 20 KiB') };
}

/** A known record, validated as every client must (unknown keys are ignored, as Swift's Decodable does). */
export function decodeNotesRecord(value: unknown): NotesRecord {
  if (!isObject(value)) return invalid('not an object');
  if (value.format !== NOTES_FORMAT) return invalid('unknown format');
  if (value.record === 'note') {
    return { format: NOTES_FORMAT, record: 'note', noteID: id(value.noteID, 'noteID must be a UUID'), title: title(value.title),
      createdAt: integer(value.createdAt, 0, MAX_TIME - 1, 'invalid createdAt') };
  }
  if (value.record !== 'entry') return invalid('unknown record');
  const kind = value.kind === 'region' || value.kind === 'quote' || value.kind === 'text' ? value.kind : invalid('unknown entry kind');
  const counter = Number.isSafeInteger(value.counter) && (value.counter as number) < 1 ? invalid('counter must be >= 1') : integer(value.counter, 1, NOTES_LIMITS.counter, 'invalid counter');
  if (typeof value.comment !== 'string') invalid('comment must be text');
  if (bytes(value.comment as string) > NOTES_LIMITS.commentBytes) invalid('comment over 16 KiB');
  const record: EntryRecord = {
    format: NOTES_FORMAT, record: 'entry', entryID: id(value.entryID, 'entryID must be a UUID'), noteID: id(value.noteID, 'noteID must be a UUID'), kind, counter,
    capturedAt: integer(value.capturedAt, 0, MAX_TIME - 1, 'invalid capturedAt'),
    offsetMinutes: integer(value.offsetMinutes, -NOTES_LIMITS.offsetMinutes, NOTES_LIMITS.offsetMinutes, 'invalid offsetMinutes'),
    comment: value.comment as string, source: source(value.source), anchor: anchor(value.anchor),
    quote: nullableText(value.quote, NOTES_LIMITS.quoteBytes, 'quote over 20 KiB'), media: null,
  };
  if (!absent(value.media)) {
    if (!isObject(value.media)) invalid('invalid media');
    const m = value.media as Record<string, unknown>;
    record.media = { full: media(m.full, false), ...(absent(m.thumb) ? {} : { thumb: media(m.thumb, true) }) };
    if (record.media.thumb?.blobID === record.media.full.blobID) invalid('thumbnail must be its own blob');
  }
  if (kind === 'region' && !record.media) invalid('a region needs its image');
  if (kind === 'quote' && !record.quote) invalid('a quote needs its text');
  if (kind === 'text' && (record.source || record.anchor || record.quote !== null || record.media)) invalid('text has no source or media');
  return record;
}

/** The record's JSON in the fixture's field order. Throws when it is out of bounds (the caller keeps the draft). */
export function encodeNotesRecord(record: NotesRecord): string {
  const r = decodeNotesRecord(record); // validates and normalizes
  let json: string;
  if (r.record === 'note') json = JSON.stringify({ format: r.format, record: r.record, noteID: r.noteID, title: r.title, createdAt: r.createdAt });
  else {
    const s = r.source && { kind: r.source.kind, title: r.source.title, authors: r.source.authors, sourceID: r.source.sourceID, revision: r.source.revision, url: r.source.url,
      section: r.source.section, label: r.source.label, ...(r.source.membershipID ? { membershipID: r.source.membershipID } : {}),
      ...(r.source.pdfSHA256 ? { pdfSHA256: r.source.pdfSHA256 } : {}), ...(r.source.page !== undefined ? { page: r.source.page } : {}) };
    const a = r.anchor && { manifestSHA256: r.anchor.manifestSHA256, rendererRevision: r.anchor.rendererRevision, blockIDs: r.anchor.blockIDs, rects: r.anchor.rects,
      viewport: r.anchor.viewport, quote: r.anchor.quote };
    const m = (d: MediaDescriptor) => ({ blobID: d.blobID, key: d.key, sha256: d.sha256, bytes: d.bytes, type: d.type, width: d.width, height: d.height });
    json = JSON.stringify({ format: r.format, record: r.record, entryID: r.entryID, noteID: r.noteID, kind: r.kind, counter: r.counter, capturedAt: r.capturedAt,
      offsetMinutes: r.offsetMinutes, comment: r.comment, source: s, anchor: a, quote: r.quote, media: r.media && { full: m(r.media.full), ...(r.media.thumb ? { thumb: m(r.media.thumb) } : {}) } });
  }
  if (bytes(json) > NOTES_LIMITS.recordBytes) invalid('record over 48 KiB');
  return json;
}

export type Classified =
  | { kind: 'record'; record: NotesRecord }
  | { kind: 'future'; format: string; noteID: string | null }
  | { kind: 'malformed'; reason: string; noteID: string | null }
  | { kind: 'other' };
const FUTURE = /^gradstep-notes-v([0-9]{1,6})$/;
/** Which family a `note` event's text belongs to. Anything not a Notes payload is `other` (catalogs, older notes). */
export function classifyNoteText(textValue: string | undefined): Classified {
  if (!textValue || !textValue.includes('gradstep-notes-')) return { kind: 'other' };
  let value: unknown;
  try { value = JSON.parse(textValue); } catch { return { kind: 'other' }; }
  if (!isObject(value) || typeof value.format !== 'string') return { kind: 'other' };
  const noteID = isUUID(value.noteID) ? value.noteID.toLowerCase() : null;
  if (value.format !== NOTES_FORMAT) {
    const version = FUTURE.exec(value.format);
    return version && Number(version[1]) > 1 ? { kind: 'future', format: value.format, noteID } : { kind: 'other' };
  }
  if (bytes(textValue) > NOTES_LIMITS.recordBytes) return { kind: 'malformed', reason: 'record over 48 KiB', noteID };
  try { return { kind: 'record', record: decodeNotesRecord(value) }; }
  catch (error) { return { kind: 'malformed', reason: error instanceof NotesRecordError ? error.reason : 'invalid record', noteID }; }
}

/** A revision may change only the title (note) or comment (entry); everything else repeats the entity's first record. */
export function sameIdentity(a: NotesRecord, b: NotesRecord): boolean {
  if (a.record !== b.record) return false;
  if (a.record === 'note') return a.noteID === (b as NoteRecord).noteID && a.createdAt === (b as NoteRecord).createdAt;
  const strip = (r: EntryRecord) => encodeNotesRecord({ ...r, comment: '' });
  return strip(a) === strip(b as EntryRecord);
}

// ---------- Reduction ----------

export interface Version<T> { eventID: string; record: T; createdAt: number | null }
export interface EntryView {
  id: string; noteID: string; record: EntryRecord; eventID: string;
  /** Every current head, winner (greatest event ID) first. More than one is "2 versions". */
  versions: Version<EntryRecord>[]; editedAt: number;
}
export interface NoteView {
  id: string; record: NoteRecord | null; title: string | null; eventID: string | null; versions: Version<NoteRecord>[];
  entries: EntryView[]; lastEdited: number;
  /** Records from a newer release for this note ("Update Gradstep to see this note"). */
  future: number;
  /** Entries arrived before the note itself (loading/incomplete; never assigned elsewhere). */
  incomplete: boolean;
}
export interface NotesView {
  notes: NoteView[]; malformed: number; future: number;
  /** The greatest counter ever used per note, removed entries included (the next append is one more). */
  counters: Map<string, number>;
}

interface Collected<T extends NotesRecord> { event: AppliedEvent; record: T }
const byID = (a: { eventID: string }, b: { eventID: string }) => (a.eventID < b.eventID ? 1 : a.eventID > b.eventID ? -1 : 0);

function heads<T extends NotesRecord>(revisions: Collected<T>[], onInvalid: () => void): Version<T>[] {
  // The entity's first record: a revision without parents (the smallest event ID if there were several).
  const roots = revisions.filter(r => !r.event.payload.parents.length).sort((a, b) => (a.event.id < b.event.id ? -1 : 1));
  const base = roots[0] ?? [...revisions].sort((a, b) => (a.event.id < b.event.id ? -1 : 1))[0];
  const valid = revisions.filter(r => { const ok = sameIdentity(base.record, r.record); if (!ok) onInvalid(); return ok; });
  const superseded = new Set(valid.flatMap(r => r.event.payload.parents));
  return valid.filter(r => !superseded.has(r.event.id)).map(r => ({ eventID: r.event.id, record: r.record, createdAt: r.event.payload.createdAt ?? null })).sort(byID);
}

/** Every visible note, newest activity first, from the private event history. Never throws on a bad record. */
export function reduceNotes(state: PrivateState): NotesView {
  const notes = new Map<string, Collected<NoteRecord>[]>(), entries = new Map<string, Collected<EntryRecord>[]>();
  const deleted = new Set<string>(), futureByNote = new Map<string, number>(), counters = new Map<string, number>();
  let malformed = 0, future = 0;
  for (const event of state.events.values()) {
    const p = event.payload;
    if (p.kind === 'tombstone') { deleted.add(p.entityID); continue; }
    if (p.kind !== 'note') continue;
    const c = classifyNoteText(p.text);
    if (c.kind === 'other') continue;
    if (c.kind === 'future') { future++; if (c.noteID) futureByNote.set(c.noteID, (futureByNote.get(c.noteID) ?? 0) + 1); continue; }
    if (c.kind === 'malformed') { malformed++; continue; }
    const r = c.record;
    // The outer event names the entity and carries no paper or chat binding (sources live inside the payload).
    if (p.entityID !== (r.record === 'note' ? r.noteID : r.entryID) || p.documentID || p.paperReference || p.conversationID) { malformed++; continue; }
    if (r.record === 'note') notes.set(r.noteID, [...(notes.get(r.noteID) ?? []), { event, record: r }]);
    else {
      entries.set(r.entryID, [...(entries.get(r.entryID) ?? []), { event, record: r }]);
      counters.set(r.noteID, Math.max(counters.get(r.noteID) ?? 0, r.counter));
    }
  }
  const out = new Map<string, NoteView>();
  const view = (noteID: string): NoteView => {
    let v = out.get(noteID);
    if (!v) { v = { id: noteID, record: null, title: null, eventID: null, versions: [], entries: [], lastEdited: 0, future: futureByNote.get(noteID) ?? 0, incomplete: true }; out.set(noteID, v); }
    return v;
  };
  const touch = (v: NoteView, ...times: (number | null | undefined)[]) => { for (const t of times) if (typeof t === 'number' && t > v.lastEdited) v.lastEdited = t; };
  for (const [noteID, revisions] of notes) {
    if (deleted.has(noteID)) continue;
    const versions = heads(revisions, () => malformed++);
    if (!versions.length) continue;
    const v = view(noteID);
    Object.assign(v, { record: versions[0].record, title: versions[0].record.title, eventID: versions[0].eventID, versions, incomplete: false });
    touch(v, versions[0].record.createdAt, ...revisions.map(r => r.event.payload.createdAt));
  }
  for (const [entryID, revisions] of entries) {
    if (deleted.has(entryID)) continue;
    const versions = heads(revisions, () => malformed++);
    if (!versions.length) continue;
    const noteID = versions[0].record.noteID;
    if (deleted.has(noteID)) continue;
    const v = view(noteID), editedAt = Math.max(versions[0].record.capturedAt, ...revisions.map(r => r.event.payload.createdAt ?? 0));
    v.entries.push({ id: entryID, noteID, record: versions[0].record, eventID: versions[0].eventID, versions, editedAt });
    touch(v, editedAt);
  }
  // A note seen only through future records is listed, so it can say an update is needed.
  for (const noteID of futureByNote.keys()) if (!deleted.has(noteID)) view(noteID);
  for (const v of out.values()) v.entries.sort((a, b) => a.record.counter - b.record.counter || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const list = [...out.values()].sort((a, b) => b.lastEdited - a.lastEdited || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { notes: list, malformed, future, counters };
}

// ---------- Events this device writes ----------

const noteEventOf = (record: NotesRecord, parents: string[], createdAt: number): PrivateEvent => {
  if (parents.length > NOTES_LIMITS.parents) throw new NotesRecordError('too many versions; sync before editing');
  return { kind: 'note', entityID: record.record === 'note' ? record.noteID : record.entryID, parents, text: encodeNotesRecord(record), createdAt };
};
export function newNote(titleText: string, now = Date.now(), noteID: string = crypto.randomUUID()): { record: NoteRecord; event: PrivateEvent } {
  const t = cleanNoteTitle(titleText);
  if (!t) throw new NotesRecordError('empty title');
  const record: NoteRecord = { format: NOTES_FORMAT, record: 'note', noteID, title: t, createdAt: now };
  return { record, event: noteEventOf(record, [], now) };
}
/** A rename or a chosen title: parents are every current head of the note. */
export function renamedNote(note: NoteView, titleText: string, now = Date.now()): PrivateEvent {
  const t = cleanNoteTitle(titleText);
  if (!t || !note.record) throw new NotesRecordError(t ? 'note not loaded' : 'empty title');
  return noteEventOf({ ...note.record, title: t }, note.versions.map(v => v.eventID), now);
}
export function newEntry(record: Omit<EntryRecord, 'format' | 'record'>, now = Date.now()): { record: EntryRecord; event: PrivateEvent } {
  const full: EntryRecord = { format: NOTES_FORMAT, record: 'entry', ...record };
  return { record: full, event: noteEventOf(full, [], now) };
}
/** A comment edit or a chosen version: only the comment differs; parents are every current head of the entry. */
export function editedEntry(entry: EntryView, comment: string, now = Date.now()): PrivateEvent {
  return noteEventOf({ ...entry.record, comment }, entry.versions.map(v => v.eventID), now);
}
/** Deletion is the existing tombstone for the entity, after every head this device knows. */
export function deletion(entityID: string, parents: string[], now = Date.now()): PrivateEvent {
  return { kind: 'tombstone', entityID, parents: parents.slice(0, NOTES_LIMITS.parents), createdAt: now };
}
/** One greater than the greatest counter ever used in this note (removed entries included). */
export function nextCounter(view: NotesView, noteID: string): number {
  const next = (view.counters.get(noteID) ?? 0) + 1;
  if (next > NOTES_LIMITS.counter) throw new NotesRecordError('this note has too many entries');
  return next;
}
/** The local offset as the record stores it (minutes east of UTC; JavaScript reports minutes west). */
export const offsetMinutes = (at: number) => -new Date(at).getTimezoneOffset();
