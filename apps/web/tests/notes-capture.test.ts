// Snippet capture plumbing: the frame's capture replies are bounded and bound to the open paper; a snippet records
// only verified blocks, a clamped viewport rectangle and the paper's own identity (no guesses).
import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import type { VerifiedBundle } from '../src/lib/bundle';
import type { Item } from '../src/lib/library';
import { decodeNotesRecord, NOTES_FORMAT } from '../src/lib/notes';
import { clip, paperSource, sectionOf, snippetAnchor } from '../src/lib/snippet-source';
import { readFrameMessage } from '../src/reader/frame';

const manifest = 'a'.repeat(64);
const bundle = { manifestSHA256: manifest, manifest: { source: { kind: 'mathpix-mmd' }, renderer: { id: 'timestep-mathpix-mathml-v1', build_sha256: 'b'.repeat(64) } },
  index: { headings: [{ id: 'h-1', level: 1, title: '1 Introduction' }, { id: 'h-2', level: 1, title: '2 Method' }],
    blocks: [{ id: 'h-1', kind: 'heading', text: '' }, { id: 'p-1', kind: 'paragraph', text: '' }, { id: 'h-2', kind: 'heading', text: '' }, { id: 'p-2', kind: 'paragraph', text: '' }] } } as unknown as VerifiedBundle;
const nonce = '0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a';
const reply = { type: 'capture', nonce, ok: true, png: new ArrayBuffer(64), width: 400, height: 200, blocks: ['p-1'], box: [10, 20, 400, 200], viewport: [800, 600, 2], manifest_sha256: manifest };

it('admits a bounded capture reply for the open paper only', () => {
  expect(readFrameMessage(reply, bundle)).toMatchObject({ type: 'capture', nonce, ok: true, width: 400, height: 200, blocks: ['p-1'], box: [10, 20, 400, 200], viewport: [800, 600, 2] });
  for (const change of [{ manifest_sha256: 'c'.repeat(64) }, { png: 'not bytes' }, { png: new ArrayBuffer(4) }, { width: 5000 }, { width: 3000, height: 3000 },
    { blocks: ['<script>'] }, { blocks: Array(65).fill('p-1') }, { box: [0, 0, Infinity, 1] }, { viewport: [800, 0, 1] }]) {
    expect(readFrameMessage({ ...reply, ...change }, bundle)).toEqual({ type: 'capture', nonce, ok: false, reason: 'invalid' });
  }
  expect(readFrameMessage({ ...reply, nonce: 'not-a-nonce' }, bundle)).toBeNull();
  expect(readFrameMessage({ type: 'capture', nonce, ok: false, reason: 'tainted' })).toEqual({ type: 'capture', nonce, ok: false, reason: 'tainted' });
  expect(readFrameMessage({ type: 'capture', nonce, ok: false, reason: 'Some <b>text</b>' })).toEqual({ type: 'capture', nonce, ok: false, reason: 'failed' });
  expect(readFrameMessage({ type: 'captureProbe', nonce, ok: true })).toEqual({ type: 'captureProbe', nonce, ok: true });
  expect(readFrameMessage({ type: 'captureProbe', nonce, ok: 'yes' })).toBeNull();
});

it('records verified blocks, a clamped rectangle with its viewport, and the paper as the library knows it', () => {
  const anchor = snippetAnchor(bundle, ['p-1', 'unknown', 'p-1', 'h-2'], { rect: [-0.1, 0.25, 0.5, 1.4], viewport: [800, 600, 2] });
  expect(anchor).toEqual({ manifestSHA256: manifest, rendererRevision: null, blockIDs: ['p-1', 'h-2'], rects: [[0, 0.25, 0.5, 1]], viewport: [800, 600, 2], quote: null });
  expect(snippetAnchor(bundle, ['p-2'], { viewport: [800, 600, 2], quote: 'A passage' })).toMatchObject({ rects: [], viewport: null, quote: 'A passage' });
  expect(sectionOf(bundle.index, 'p-2')).toBe('2 Method'); expect(sectionOf(bundle.index, 'missing')).toBeNull();
  const item = { kind: 'item', id: 'AAAAAAAA-0000-4000-8000-000000000001', source: 'arxiv', source_id: '2305.18290', source_revision: 3,
    metadata: { title: 'Direct Preference Optimization', authors: ['Rafael Rafailov', 'x'.repeat(600)] } } as unknown as Item;
  const source = paperSource(item, bundle.index, 'p-1', 'Figure 1');
  expect(source).toMatchObject({ kind: 'arxiv', title: 'Direct Preference Optimization', sourceID: '2305.18290', revision: 3, url: 'https://arxiv.org/abs/2305.18290v3',
    section: '1 Introduction', label: 'Figure 1', membershipID: 'aaaaaaaa-0000-4000-8000-000000000001' });
  expect(new TextEncoder().encode(source.authors[1]).length).toBeLessThanOrEqual(512);
  // The record the composer builds from them is a valid Notes entry.
  expect(() => decodeNotesRecord({ format: NOTES_FORMAT, record: 'entry', entryID: nonce, noteID: nonce.replace('0f', '1f'), kind: 'quote', counter: 1, capturedAt: 1, offsetMinutes: 0,
    comment: '', source, anchor: snippetAnchor(bundle, ['p-1'], { quote: 'q' }), quote: 'q', media: null })).not.toThrow();
  expect(clip('é'.repeat(10), 9)).toBe('ééé…'); // 6 bytes and the 3-byte ellipsis
});

it('keeps the reader frame policy and capture code free of network and new script sources', () => {
  const shim = readFileSync(new URL('../src/reader/frame-shim.js', import.meta.url), 'utf8');
  const frame = readFileSync(new URL('../src/reader/frame.ts', import.meta.url), 'utf8');
  expect(frame).toContain("default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src '${frame.hash}'; base-uri 'none'; form-action 'none'; connect-src 'none'; frame-src 'none'; font-src 'none'");
  for (const forbidden of ['fetch(', 'XMLHttpRequest', 'createObjectURL', 'WebSocket', 'importScripts', 'getDisplayMedia', 'eval(', 'new Function']) expect(shim).not.toContain(forbidden);
  expect(shim).toContain("image.src = 'data:image/svg+xml;base64,'");
});
