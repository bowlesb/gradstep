// Notes v1 records, reduction and snippet blob cryptography against the shared fixture
// (tests/fixtures/notes/notes-v1.json; NOTES_AND_SNIPPETS.md "Implementation contract").
import { readFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { fromHex, toHex, utf8 } from '../src/lib/bytes';
import { PrivateState, decodeEvent, encodeEvent, type AppliedEvent, type PrivateEvent } from '../src/lib/events';
import { CATALOG_ENTITY, INITIAL_CATALOG, LibraryCatalogs, catalogEvent } from '../src/lib/library-catalogs';
import { BlobError, blobAAD, checkDimensions, descriptor, headerSize, openBlob, sealBlob } from '../src/lib/note-blob';
import { type EntryRecord, type NoteRecord, NOTES_FORMAT, NotesRecordError, classifyNoteText, cleanNoteTitle, decodeNotesRecord, deletion, editedEntry,
  encodeNotesRecord, newNote, nextCounter, reduceNotes, renamedNote } from '../src/lib/notes';

const fixture = JSON.parse(readFileSync(new URL('../../../tests/fixtures/notes/notes-v1.json', import.meta.url), 'utf8'));
const R = fixture.records;
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const device = id(999);
function event(n: number, record: object, parents: string[] = [], createdAt = 1792900000000 + n, extra: Partial<PrivateEvent> = {}): AppliedEvent {
  const r = record as NoteRecord | EntryRecord;
  return { id: id(n), deviceID: device, payload: { kind: 'note', entityID: r.record === 'note' ? r.noteID : r.entryID, parents, text: JSON.stringify(record), createdAt, ...extra } };
}
const tombstone = (n: number, entityID: string, parents: string[] = []): AppliedEvent => ({ id: id(n), deviceID: device, payload: { kind: 'tombstone', entityID, parents, createdAt: 1792900000000 + n } });
function state(...events: AppliedEvent[]) { const s = new PrivateState(); s.applyBatch(events); return s; }

describe('gradstep-notes-v1 records', () => {
  it('decodes every fixture record and encodes it back byte for byte', () => {
    for (const name of ['note', 'entry', 'quoteEntry', 'textEntry', 'noteRenamed', 'entryCommentEdited']) {
      const record = decodeNotesRecord(R[name]);
      expect(encodeNotesRecord(record), name).toBe(JSON.stringify(R[name]));
      expect(classifyNoteText(JSON.stringify(R[name]))).toEqual({ kind: 'record', record });
    }
  });
  it('refuses each invalid fixture record for its stated reason', () => {
    expect(R.invalid).toHaveLength(R.invalidReasons.length);
    R.invalid.forEach((record: object, i: number) => {
      expect(() => decodeNotesRecord(record)).toThrow(new NotesRecordError(R.invalidReasons[i]));
      expect(classifyNoteText(JSON.stringify(record))).toMatchObject({ kind: 'malformed', reason: R.invalidReasons[i] });
    });
  });
  it('keeps a future format as unknown, and leaves every other note payload alone', () => {
    expect(classifyNoteText(JSON.stringify(R.future[0]))).toEqual({ kind: 'future', format: 'gradstep-notes-v2', noteID: R.entry.noteID });
    const catalog = catalogEvent(new PrivateState(), [{ action: 'rename', catalogID: INITIAL_CATALOG, name: 'Reading' }]);
    expect(classifyNoteText(catalog.text)).toEqual({ kind: 'other' });
    expect(classifyNoteText('{"format":"library-catalog-v2"}')).toEqual({ kind: 'other' });
    expect(classifyNoteText('older plain note text')).toEqual({ kind: 'other' });
  });
  it('accepts Swift-style uppercase IDs and omitted null keys, and normalizes them', () => {
    const upper = { ...R.textEntry, entryID: R.textEntry.entryID.toUpperCase(), noteID: R.textEntry.noteID.toUpperCase() };
    delete (upper as Record<string, unknown>).source; delete (upper as Record<string, unknown>).media;
    expect(encodeNotesRecord(decodeNotesRecord(upper))).toBe(JSON.stringify(R.textEntry));
  });
  it('enforces kind, media and size invariants', () => {
    expect(() => decodeNotesRecord({ ...R.entry, media: null })).toThrow('a region needs its image');
    expect(() => decodeNotesRecord({ ...R.quoteEntry, quote: null })).toThrow('a quote needs its text');
    expect(() => decodeNotesRecord({ ...R.textEntry, quote: 'x' })).toThrow('text has no source or media');
    expect(() => decodeNotesRecord({ ...R.entry, media: { full: { ...R.entry.media.full, width: 4097 } } })).toThrow('media dimensions out of bounds');
    expect(() => decodeNotesRecord({ ...R.entry, media: { full: { ...R.entry.media.full, width: 3000, height: 3000 } } })).toThrow('media over 6 megapixels');
    expect(() => decodeNotesRecord({ ...R.entry, media: { full: { ...R.entry.media.full, bytes: 2 * 1024 * 1024 + 29 } } })).toThrow('media bytes out of bounds');
    expect(() => decodeNotesRecord({ ...R.entry, media: { full: R.entry.media.full, thumb: { ...R.entry.media.full, type: 'image/jpeg' } } })).toThrow('thumbnail must be its own blob');
    expect(() => decodeNotesRecord({ ...R.entry, anchor: { ...R.entry.anchor, rects: [[0, 0, 1.2, 1]] } })).toThrow('invalid anchor rectangles');
    expect(() => decodeNotesRecord({ ...R.entry, anchor: { ...R.entry.anchor, blockIDs: Array(65).fill('b-1') } })).toThrow('invalid anchor blocks');
    expect(() => decodeNotesRecord({ ...R.entry, source: { ...R.entry.source, url: 'javascript:alert(1)' } })).toThrow('invalid source url');
    expect(() => decodeNotesRecord({ ...R.note, title: ' padded ' })).toThrow('title not trimmed');
    expect(() => encodeNotesRecord({ ...R.quoteEntry, quote: 'q', comment: 'c'.repeat(16_000), anchor: { ...R.quoteEntry.anchor, quote: 'x'.repeat(20_000) }, source: { ...R.quoteEntry.source, title: 't'.repeat(2000) } }))
      .not.toThrow();
    expect(() => encodeNotesRecord({ ...R.quoteEntry, quote: 'q'.repeat(20_000), comment: 'c'.repeat(16_000), anchor: { ...R.quoteEntry.anchor, quote: 'x'.repeat(20_000) } }))
      .toThrow('record over 48 KiB');
    expect(cleanNoteTitle('  Reading\nlist  ')).toBe('Reading list');
    expect(cleanNoteTitle('   ')).toBeNull();
    expect(cleanNoteTitle('é'.repeat(80))).toBe('é'.repeat(80));
    expect(cleanNoteTitle('x'.repeat(81))).toBeNull();
  });
  it('is an ordinary note event to older readers', () => {
    const { event: e } = newNote('Preference learning', 1792900000000, R.note.noteID);
    const decoded = decodeEvent(encodeEvent(e));
    expect(decoded).toMatchObject({ kind: 'note', entityID: R.note.noteID, parents: [], createdAt: 1792900000000 });
    expect(decoded.text).toBe(JSON.stringify(R.note));
  });
});

describe('reducing notes from private events', () => {
  const note = event(1, R.note), entry = event(2, R.entry), quote = event(3, R.quoteEntry), text = event(4, R.textEntry);
  it('orders entries by counter, then entry ID, whatever the arrival order', () => {
    const tie = { ...R.textEntry, entryID: '0b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e', counter: 3, comment: 'Same counter' };
    for (const events of [[note, entry, quote, text, event(5, tie)], [event(5, tie), text, quote, entry, note]]) {
      const view = reduceNotes(state(...events));
      expect(view.notes).toHaveLength(1);
      expect(view.notes[0].title).toBe('Preference learning');
      expect(view.notes[0].entries.map(e => e.id)).toEqual([R.entry.entryID, R.quoteEntry.entryID, tie.entryID, R.textEntry.entryID]);
      expect(nextCounter(view, R.note.noteID)).toBe(4);
    }
  });
  it('applies renames and comment edits as causal revisions', () => {
    const view = reduceNotes(state(note, entry, event(5, R.noteRenamed, [note.id]), event(6, R.entryCommentEdited, [entry.id], 1792900200000)));
    expect(view.notes[0].title).toBe('Preference learning (DPO, IPO)');
    expect(view.notes[0].versions).toHaveLength(1);
    expect(view.notes[0].entries[0].record.comment).toBe('Edited: the margin is scaled by beta.');
    expect(view.notes[0].lastEdited).toBe(1792900200000);
  });
  it('keeps concurrent comments as two versions until one is chosen, then writes after every head', () => {
    const a = event(7, { ...R.entry, comment: 'From the iPhone' }, [entry.id]), b = event(9, { ...R.entry, comment: 'From the browser' }, [entry.id]);
    const s = state(note, entry, a, b);
    const current = reduceNotes(s).notes[0].entries[0];
    expect(current.versions.map(v => v.record.comment)).toEqual(['From the browser', 'From the iPhone']);
    expect(current.record.comment).toBe('From the browser'); // greatest event ID wins until resolved
    const choice = editedEntry(current, 'From the iPhone', 1792900000100);
    expect(choice.parents).toEqual([b.id, a.id]);
    s.apply({ id: id(10), deviceID: device, payload: choice });
    const resolved = reduceNotes(s).notes[0].entries[0];
    expect(resolved.versions).toHaveLength(1); expect(resolved.record.comment).toBe('From the iPhone');
    // Rename conflicts work the same way.
    const r1 = event(11, { ...R.note, title: 'One' }, [note.id]), r2 = event(12, { ...R.note, title: 'Two' }, [note.id]);
    s.applyBatch([r1, r2]);
    const titled = reduceNotes(s).notes[0];
    expect(titled.versions.map(v => v.record.title)).toEqual(['Two', 'One']);
    expect(renamedNote(titled, 'Chosen').parents).toEqual([r2.id, r1.id]);
  });
  it('hides deleted entries and notes; a stale edit never resurrects them; counters still advance', () => {
    const removed = tombstone(5, R.entry.entryID, [entry.id]);
    const stale = event(6, R.entryCommentEdited, [entry.id]);
    let view = reduceNotes(state(note, entry, quote, removed, stale));
    expect(view.notes[0].entries.map(e => e.id)).toEqual([R.quoteEntry.entryID]);
    expect(nextCounter(view, R.note.noteID)).toBe(3);
    view = reduceNotes(state(note, entry, quote, tombstone(7, R.note.noteID, [note.id])));
    expect(view.notes).toEqual([]);
    expect(deletion(R.note.noteID, [note.id])).toMatchObject({ kind: 'tombstone', entityID: R.note.noteID, parents: [note.id] });
  });
  it('shows entries that arrive before their note as an incomplete note, never somewhere else', () => {
    const view = reduceNotes(state(entry, text));
    expect(view.notes).toHaveLength(1);
    expect(view.notes[0]).toMatchObject({ id: R.note.noteID, incomplete: true, title: null });
    expect(view.notes[0].entries).toHaveLength(2);
  });
  it('counts malformed and future records visibly, and keeps the rest readable', () => {
    const bad = R.invalid.map((r: object, i: number) => event(20 + i, { ...r, entryID: id(500 + i), noteID: R.note.noteID }));
    const wrongEntity: AppliedEvent = { ...event(30, R.textEntry), payload: { ...event(30, R.textEntry).payload, entityID: id(31) } };
    const bound: AppliedEvent = event(32, { ...R.textEntry, entryID: id(33) }, [], 1, { documentID: id(34) });
    const changedIdentity = event(35, { ...R.entry, counter: 9 }, [entry.id]);
    const view = reduceNotes(state(note, entry, ...bad, wrongEntity, bound, changedIdentity, event(36, R.future[0])));
    expect(view.malformed).toBe(R.invalid.length + 3);
    expect(view.future).toBe(1);
    expect(view.notes[0].future).toBe(1);
    expect(view.notes[0].entries.map(e => [e.id, e.record.counter])).toEqual([[R.entry.entryID, 1]]);
  });
  it('ignores Library catalog events, and the catalog reducer ignores Notes records', () => {
    const catalog: AppliedEvent = { id: id(40), deviceID: device, payload: catalogEvent(new PrivateState(), [{ action: 'rename', catalogID: INITIAL_CATALOG, name: 'Research' }]) };
    const disguised = event(41, { ...R.note, noteID: CATALOG_ENTITY, title: 'Not a catalog' }); // even on the catalog entity
    const withNotes = state(catalog, note, entry, quote, text, disguised), catalogsOnly = state(catalog);
    expect(new LibraryCatalogs(withNotes)).toEqual(new LibraryCatalogs(catalogsOnly));
    expect(new LibraryCatalogs(withNotes).catalogs).toEqual([{ id: INITIAL_CATALOG, name: 'Research' }]);
    const view = reduceNotes(withNotes);
    expect(view.notes.map(n => n.title).sort()).toEqual(['Not a catalog', 'Preference learning']);
    expect(view.malformed).toBe(0);
    // Chats, diagrams and catalogs see nothing new.
    expect(withNotes.conversationSummaries()).toEqual([]); expect(withNotes.savedDiagrams()).toEqual([]);
  });
});

// A 1×1 PNG with a real IHDR, made here so the dimension check sees the image's own header.
function png(width: number, height: number): Uint8Array {
  const crc = (b: Uint8Array) => { let c = ~0; for (const x of b) { c ^= x; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); } return ~c >>> 0; };
  const chunk = (type: string, data: Uint8Array) => {
    const out = new Uint8Array(12 + data.length), v = new DataView(out.buffer);
    v.setUint32(0, data.length); out.set(utf8(type), 4); out.set(data, 8); v.setUint32(8 + data.length, crc(out.subarray(4, 8 + data.length))); return out;
  };
  const ihdr = new Uint8Array(13), v = new DataView(ihdr.buffer); v.setUint32(0, width); v.setUint32(4, height); ihdr.set([8, 2, 0, 0, 0], 8);
  const raw = new Uint8Array((width * 3 + 1) * height);
  return Uint8Array.from([...fromHex('89504e470d0a1a0a')!, ...chunk('IHDR', ihdr), ...chunk('IDAT', deflateSync(raw)), ...chunk('IEND', new Uint8Array())]);
}

describe('snippet blob encryption', () => {
  const B = fixture.blob;
  const media = R.entry.media.full;
  it('matches the fixture vector byte for byte', async () => {
    expect(new TextDecoder().decode(blobAAD(B.accountID.toUpperCase(), B.blobID.toUpperCase()))).toBe(B.aad);
    const sealed = await sealBlob(fromHex(B.plaintextHex)!, B.accountID, B.blobID, { key: fromHex(B.keyHex)!, nonce: fromHex(B.nonceHex)! });
    expect(toHex(sealed.stored)).toBe(B.blobHex);
    expect(sealed.sha256).toBe(B.blobSHA256);
    expect(descriptor(sealed, 'image/png', 1, 1)).toEqual(media);
    expect(toHex(await openBlob(fromHex(B.blobHex)!, media, B.accountID))).toBe(B.plaintextHex);
  });
  it('refuses a changed length, digest, tag, account, blob identity or media type', async () => {
    const stored = fromHex(B.blobHex)!;
    const code = (p: Promise<unknown>) => p.then(() => 'opened', (e: BlobError) => e.code);
    expect(await code(openBlob(stored.slice(0, 35), media, B.accountID))).toBe('blob_length');
    const flipped = stored.slice(); flipped[20] ^= 1;
    expect(await code(openBlob(flipped, media, B.accountID))).toBe('blob_digest');
    const { sha256Hex } = await import('../src/lib/bytes');
    expect(await code(openBlob(flipped, { ...media, sha256: await sha256Hex(flipped) }, B.accountID))).toBe('blob_tag');
    expect(await code(openBlob(stored, media, id(1)))).toBe('blob_tag');
    expect(await code(openBlob(stored, { ...media, blobID: id(2) }, B.accountID))).toBe('blob_tag');
    expect(await code(openBlob(stored, { ...media, type: 'image/jpeg' }, B.accountID))).toBe('blob_type');
  });
  it('checks the image header’s dimensions against the record before display', async () => {
    expect(() => checkDimensions(fromHex(B.plaintextHex)!, media)).toThrow(new BlobError('blob_dimensions')); // a signature alone
    const image = png(3, 2);
    expect(headerSize(image)).toEqual({ width: 3, height: 2 });
    const sealed = await sealBlob(image, B.accountID, id(3));
    const d = descriptor(sealed, 'image/png', 3, 2);
    expect(Array.from(await openBlob(sealed.stored, d, B.accountID))).toEqual(Array.from(image));
    expect(() => checkDimensions(image, d)).not.toThrow();
    expect(() => checkDimensions(image, { ...d, width: 4 })).toThrow(new BlobError('blob_dimensions'));
    // JPEG: SOF0 after an APP0 segment.
    const jpeg = fromHex('ffd8ffe000104a46494600010100000100010000ffc0001108000a001403012200021101031101ffd9')!;
    expect(headerSize(jpeg)).toEqual({ width: 20, height: 10 });
    expect(NOTES_FORMAT).toBe(R.note.format);
  });
});
