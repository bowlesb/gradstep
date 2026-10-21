// The account's notes in this browser (NOTES_AND_SNIPPETS.md "Implementation contract"): reduction of the encrypted
// history, writes as ordinary encrypted events, snippet blobs committed with their entry in the account's journal, the
// upload of those blobs before their entry event is sent, and on-demand image fetches shown through in-memory object
// URLs that are revoked when this account's session retires. Nothing about notes is sent except encrypted events and
// opaque blobs; no AI, search index or server-side image work is involved.
import { BackendError, getNoteAsset, putNoteAsset } from './backend';
import { type Bytes, sha256Hex } from './bytes';
import type { PrivateEvent } from './events';
import type { History } from './history';
import { BlobError, type SealedBlob, checkDimensions, descriptor, openBlob, sealBlob } from './note-blob';
import { type PreparedImage, decodedSize } from './note-images';
import { type EntryAnchor, type EntryKind, type EntrySource, type EntryView, type MediaDescriptor, type NoteView, type NotesView, NotesRecordError,
  classifyNoteText, deletion, editedEntry, newEntry, newNote, nextCounter, offsetMinutes, reduceNotes, renamedNote } from './notes';

/** The note-assets function, or a fake in tests. */
export interface BlobTransport {
  put(blobID: string, stored: Bytes, sha256: string, signal: AbortSignal): Promise<void>;
  get(blobID: string, bytes: number, signal: AbortSignal): Promise<Bytes>;
}
export const backendTransport = (account: string): BlobTransport => ({
  put: async (blobID, stored, sha256, signal) => { await putNoteAsset(blobID, stored, sha256, account, signal); },
  get: (blobID, bytes, signal) => getNoteAsset(blobID, bytes, account, signal),
});

/** Why an upload waits. Every case keeps the entry and its image on this device. */
export type UploadIssue = 'offline' | 'quota' | 'busy' | 'session' | 'conflict' | 'missing' | 'failed';
/** The note-assets function's answers (NOTES_AND_SNIPPETS.md "Server status"): 429 `quota` (stored, or the monthly
 * read-back allowance) or `rate_limited`; 503 `not_ready`/`service_unavailable` is repeated with the same PUT. */
export function uploadIssue(error: unknown): UploadIssue {
  if (error instanceof NotesError && error.code === 'blob_missing') return 'missing';
  if (error instanceof BackendError) {
    if (error.code === 'connection') return 'offline';
    if (error.status === 429) return error.code === 'rate_limited' ? 'busy' : 'quota';
    if (error.status === 401 || error.status === 403 || error.code === 'sign_in_required') return 'session';
    if (error.status === 409) return 'conflict';
  }
  return 'failed';
}
export const UPLOAD_ISSUE_TEXT: Record<UploadIssue, string> = {
  offline: 'Saved on this device · Waiting to sync',
  quota: 'Saved on this device · Snippet storage is full, so uploads are paused',
  busy: 'Saved on this device · Uploads are limited for a moment and will resume',
  session: 'Saved on this device · Sign in again to sync',
  conflict: 'Saved on this device · This image couldn’t be uploaded',
  missing: 'This image isn’t stored in this browser any more',
  failed: 'Saved on this device · Upload didn’t finish',
};

export class NotesError extends Error {
  constructor(readonly code: 'note_unavailable' | 'entry_unavailable' | 'needs_storage' | 'blob_missing' | 'closed' | 'invalid') { super(code); }
}

/** Identities fixed when a composer opens, so a repeated Save, a retry or a reload keeps one entry, one note and one blob each. */
export interface EntryOperation {
  entryID: string; entryEventID: string; noteID: string; noteEventID: string; createdAt: number;
  counter?: { noteID: string; value: number };
  sealed?: { image: PreparedImage; full: SealedBlob; thumb: SealedBlob; thumbImage: PreparedImage };
}
export const entryOperation = (now = Date.now()): EntryOperation => ({
  entryID: crypto.randomUUID(), entryEventID: crypto.randomUUID(), noteID: crypto.randomUUID(), noteEventID: crypto.randomUUID(), createdAt: now });

export interface EntryInput {
  /** An existing note, or a new one created with the entry in the same local transaction. */
  destination: { noteID: string } | { newTitle: string };
  kind: EntryKind; comment: string; capturedAt: number; source: EntrySource | null; anchor: EntryAnchor | null; quote: string | null;
  image?: { full: PreparedImage; thumb: PreparedImage };
}
export interface EntryState { pending: boolean; uploading: boolean }

export class NotesStore {
  private cached: { version: number; view: NotesView } | null = null;
  private listeners = new Set<() => void>();
  private version = 0;
  private urls = new Map<string, Promise<string>>();
  private retired = false;
  issue: UploadIssue | null = null;
  /** The note last saved to on this device in this session (the composer preselects it). */
  lastDestination: string | null = null;
  private readonly unsubscribe: () => void;

  constructor(readonly account: string, readonly history: History, readonly signal: AbortSignal, private readonly transport: BlobTransport) {
    history.setSendGate(this.gate);
    this.unsubscribe = history.subscribe(() => this.publish());
    signal.addEventListener('abort', () => this.retire(), { once: true });
  }

  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  getVersion = () => this.version;
  private publish() { if (!this.retired) { this.version++; for (const l of this.listeners) l(); } }

  view(): NotesView {
    const v = this.history.getVersion();
    if (this.cached?.version !== v) this.cached = { version: v, view: reduceNotes(this.history.state) };
    return this.cached.view;
  }
  note(noteID: string): NoteView | null { return this.view().notes.find(n => n.id === noteID) ?? null; }
  /** Writes are allowed with the durable journal (offline too) or after a completed sync. */
  get writable(): boolean { return !this.retired && !this.signal.aborted && (this.history.durable || this.history.status === 'ready'); }
  /** Images need the encrypted journal: an image is never held only in memory. */
  get canSaveImages(): boolean { return this.writable && !!this.history.localJournal; }

  entryState(entry: EntryView): EntryState {
    const blobs = this.history.localJournal?.noteBlobs ?? {};
    const media = entry.record.media ? [entry.record.media.full, entry.record.media.thumb].filter((m): m is MediaDescriptor => !!m) : [];
    return { pending: entry.versions.some(v => this.history.isPending(v.eventID)), uploading: media.some(m => blobs[m.blobID]?.state === 'local') };
  }
  /** Edits (titles, comments, deletions) and entries of this note not yet confirmed by the server. */
  pendingIn(note: NoteView): number {
    return note.versions.filter(v => this.history.isPending(v.eventID)).length + note.entries.filter(e => this.entryState(e).pending).length;
  }
  get pendingCount(): number { return this.view().notes.reduce((n, note) => n + this.pendingIn(note), 0); }

  private writableOrThrow() { if (!this.writable) throw new NotesError('closed'); }
  private async write(entries: { id: string; event: PrivateEvent }[], blobs?: { blobID: string; stored: Bytes }[]) {
    this.writableOrThrow();
    await this.history.commit(entries, blobs?.length ? { blobs } : {});
    void this.history.sync().catch(() => {});
  }

  async createNote(title: string, op = entryOperation()): Promise<string> {
    const { event } = newNote(title, op.createdAt, op.noteID);
    await this.write([{ id: op.noteEventID, event }]);
    return op.noteID;
  }
  async renameNote(noteID: string, title: string): Promise<void> {
    const note = this.note(noteID);
    if (!note?.record) throw new NotesError('note_unavailable');
    await this.write([{ id: crypto.randomUUID(), event: renamedNote(note, title) }]);
  }
  /** Keeps one of the concurrent titles: a revision after every head. */
  async chooseTitle(noteID: string, eventID: string): Promise<void> {
    const note = this.note(noteID), chosen = note?.versions.find(v => v.eventID === eventID);
    if (!note || !chosen) throw new NotesError('note_unavailable');
    await this.write([{ id: crypto.randomUUID(), event: renamedNote(note, chosen.record.title) }]);
  }
  async deleteNote(noteID: string): Promise<void> {
    const note = this.note(noteID);
    if (!note) throw new NotesError('note_unavailable');
    await this.write([{ id: crypto.randomUUID(), event: deletion(noteID, note.versions.map(v => v.eventID)) }]);
  }
  private entry(entryID: string): EntryView {
    for (const note of this.view().notes) { const e = note.entries.find(x => x.id === entryID); if (e) return e; }
    throw new NotesError('entry_unavailable');
  }
  async editComment(entryID: string, comment: string): Promise<void> {
    await this.write([{ id: crypto.randomUUID(), event: editedEntry(this.entry(entryID), comment) }]);
  }
  async chooseComment(entryID: string, eventID: string): Promise<void> {
    const entry = this.entry(entryID), chosen = entry.versions.find(v => v.eventID === eventID);
    if (!chosen) throw new NotesError('entry_unavailable');
    await this.write([{ id: crypto.randomUUID(), event: editedEntry(entry, chosen.record.comment) }]);
  }
  async deleteEntry(entryID: string): Promise<void> {
    const entry = this.entry(entryID);
    await this.write([{ id: crypto.randomUUID(), event: deletion(entryID, entry.versions.map(v => v.eventID)) }]);
  }

  /** Commits the entry (and a new note, and its sealed images) together on this device; upload follows separately. */
  async saveEntry(input: EntryInput, op: EntryOperation): Promise<{ noteID: string; entryID: string }> {
    this.writableOrThrow();
    if (input.image && !this.canSaveImages) throw new NotesError('needs_storage');
    const view = this.view(), entries: { id: string; event: PrivateEvent }[] = [];
    let noteID: string;
    if ('newTitle' in input.destination) {
      noteID = op.noteID;
      entries.push({ id: op.noteEventID, event: newNote(input.destination.newTitle, op.createdAt, op.noteID).event });
    } else {
      noteID = input.destination.noteID;
      const note = view.notes.find(n => n.id === noteID);
      if (!note || note.incomplete || !note.record) throw new NotesError('note_unavailable');
    }
    if (op.counter?.noteID !== noteID) op.counter = { noteID, value: 'newTitle' in input.destination ? 1 : nextCounter(view, noteID) };
    let blobs: { blobID: string; stored: Bytes }[] = [], media = null;
    if (input.image) {
      if (op.sealed?.image !== input.image.full) {
        const [full, thumb] = await Promise.all([sealBlob(input.image.full.bytes, this.account, crypto.randomUUID()), sealBlob(input.image.thumb.bytes, this.account, crypto.randomUUID())]);
        op.sealed = { image: input.image.full, full, thumb, thumbImage: input.image.thumb };
      }
      const { full, thumb, image, thumbImage } = op.sealed;
      media = { full: descriptor(full, image.type, image.width, image.height), thumb: descriptor(thumb, thumbImage.type, thumbImage.width, thumbImage.height) };
      blobs = [{ blobID: full.blobID, stored: full.stored }, { blobID: thumb.blobID, stored: thumb.stored }];
    }
    const { event } = newEntry({ entryID: op.entryID, noteID, kind: input.kind, counter: op.counter.value, capturedAt: input.capturedAt,
      offsetMinutes: offsetMinutes(input.capturedAt), comment: input.comment, source: input.source, anchor: input.anchor, quote: input.quote, media }, op.createdAt);
    entries.push({ id: op.entryEventID, event });
    await this.write(entries, blobs);
    this.lastDestination = noteID; this.publish();
    return { noteID, entryID: op.entryID };
  }

  /** Before an authored entry event is sent: its blobs are uploaded and confirmed (same IDs and bytes on every retry). */
  private gate = async (event: PrivateEvent): Promise<boolean> => {
    if (event.kind !== 'note') return true;
    const c = classifyNoteText(event.text);
    if (c.kind !== 'record' || c.record.record !== 'entry' || !c.record.media) return true;
    try {
      for (const media of [c.record.media.full, c.record.media.thumb]) if (media) await this.upload(media);
      if (this.issue) { this.issue = null; this.publish(); }
      return true;
    } catch (error) {
      if (this.signal.aborted) throw error;
      const issue = uploadIssue(error);
      if (issue !== this.issue) { this.issue = issue; this.publish(); }
      return false;
    }
  };
  private async upload(media: MediaDescriptor) {
    const journal = this.history.localJournal;
    if (!journal || journal.noteBlobs[media.blobID]?.state === 'ready') return;
    const stored = await journal.readBlob(media.blobID);
    if (!stored || stored.length !== media.bytes || await sha256Hex(stored) !== media.sha256) throw new NotesError('blob_missing');
    await this.transport.put(media.blobID, stored, media.sha256, this.signal);
    await journal.markBlobsReady([media.blobID]);
    this.publish();
  }
  /** Retry after an upload issue (or reconnecting): the same IDs and bytes are sent again. */
  retry(): Promise<void> { this.issue = null; this.publish(); return this.history.sync(); }

  /** An object URL for a snippet image, decrypted and checked; kept in memory only and revoked when retired. */
  image(media: MediaDescriptor): Promise<string> {
    if (this.retired) return Promise.reject(new NotesError('closed'));
    let url = this.urls.get(media.blobID);
    if (url) { this.urls.delete(media.blobID); this.urls.set(media.blobID, url); return url; }
    url = this.load(media);
    this.urls.set(media.blobID, url);
    url.catch(() => { if (this.urls.get(media.blobID) === url) this.urls.delete(media.blobID); });
    while (this.urls.size > 96) { const [oldest, value] = this.urls.entries().next().value!; this.urls.delete(oldest); void value.then(URL.revokeObjectURL, () => {}); }
    return url;
  }
  private async load(media: MediaDescriptor): Promise<string> {
    const journal = this.history.localJournal;
    let stored = journal ? await journal.readBlob(media.blobID).catch(() => null) : null, downloaded = false;
    if (!stored || stored.length !== media.bytes) { stored = await this.transport.get(media.blobID, media.bytes, this.signal); downloaded = true; }
    const plain = await openBlob(stored, media, this.account);
    checkDimensions(plain, media);
    if (typeof createImageBitmap === 'function') {
      const size = await decodedSize(plain, media.type);
      if (size.width !== media.width || size.height !== media.height) throw new BlobError('blob_dimensions');
    }
    if (downloaded && journal) void journal.cacheBlob(media.blobID, stored).catch(() => {});
    const url = URL.createObjectURL(new Blob([plain], { type: media.type }));
    if (this.retired) { URL.revokeObjectURL(url); throw new NotesError('closed'); }
    return url;
  }

  retire() {
    if (this.retired) return;
    this.retired = true; this.unsubscribe(); this.listeners.clear();
    this.history.setSendGate(null);
    for (const url of this.urls.values()) void url.then(URL.revokeObjectURL, () => {});
    this.urls.clear();
  }
}

/** Why a snippet image isn't shown (never another image in its place). */
export function imageIssue(error: unknown): string {
  if (error instanceof BlobError) return 'This image didn’t pass its checks, so it isn’t shown';
  if (error instanceof BackendError) {
    if (error.code === 'connection') return 'Image not downloaded · You’re offline';
    if (error.status === 404) return 'Image not available yet';
    if (error.status === 429) return error.code !== 'rate_limited' && (error.retryAfter ?? 0) > 3600 ? 'Image downloads are paused until next month' : 'Image downloads are limited for a moment';
  }
  return 'Image not downloaded';
}

/** Finite, reader-facing text for a failed note write (no private detail). */
export function noteWriteFailure(error: unknown): string {
  const code = (error as { code?: string } | null)?.code;
  if (error instanceof NotesRecordError) return error.reason === 'empty title' ? 'Give the note a name.' : 'This is longer than a note can hold. Shorten it and try again.';
  if (code === 'note_unavailable') return 'That note isn’t available on this device. Choose another note.';
  if (code === 'needs_storage') return 'Snippets with images need this browser’s encrypted storage, which isn’t active in this tab.';
  if (code === 'local_quota' || code === 'local_capacity') return 'Couldn’t save on this device: this browser’s storage for Gradstep is full.';
  if (code === 'closed') return 'Your notes are still opening. Try again in a moment.';
  return 'Couldn’t save on this device. Your text is still here; try again.';
}
