import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tagWindows } from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { det, extent, host, input, line, page, TAGGER } from './device-pdf/synthetic.ts';
import type { TagLine } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';

const contextual = { ...TAGGER, context: 24 };
const characters = (n: number) => line('a'.repeat(n), 40, 200, 1).map((g, i) => ({ ...g, text: String.fromCharCode(0x100 + i) }));
const charVocab = Object.fromEntries(Array.from({ length: 900 }, (_, i) => [String(0x100 + i), i + 1]));

test('bounded tagger windows cover long-line tails exactly once, including the one-glyph v4 tail', () => {
  for (const context of [0, 24]) for (const count of [352, 353, 400, 401, 704, 705, 800, 801]) {
    const glyphs = characters(count), vocab = { ...TAGGER, context, char_vocab: charVocab };
    const windows = tagWindows(glyphs, vocab, characters(24), characters(24));
    const covered: number[] = [];
    for (const w of windows) {
      assert.ok(w.input.font.length >= 2 && w.input.font.length <= 400);
      assert.equal(w.input.x.length, w.input.font.length * (context ? 12 : 10));
      covered.push(...w.input.char.slice(...w.own));
      assert.equal(w.to - w.from, w.own[1] - w.own[0]);
    }
    assert.deepEqual(covered, Array.from({ length: count }, (_, i) => i + 1));
  }
});

test('context retains its original line geometry and is marked separately from emitted glyphs', () => {
  const before = line('ab', 40, 100, 20), own = line('$xy$', 40, 130, 10), after = line('cd', 40, 160, 5);
  const [{ input: t, own: range }] = tagWindows(own, contextual, before, after);
  assert.deepEqual(range, [2, 4]);
  assert.deepEqual(t.font, [2, 2, 7, 7, 2, 2]);
  assert.deepEqual(Array.from({ length: 6 }, (_, i) => t.x.slice(i * 12 + 10, i * 12 + 12)), [[1, 0], [1, 0], [0, 0], [0, 0], [0, 1], [0, 1]]);
  // Each line's size and baseline are normalized independently, not against the three-line window.
  assert.deepEqual(Array.from({ length: 6 }, (_, i) => t.x.slice(i * 12, i * 12 + 2)), Array(6).fill([1, 0]));
  assert.deepEqual(t.x.slice(2 * 12 + 6, 2 * 12 + 10), [0.9, 0.01, 0.9, 0]);
});

test('an equation crossing a window boundary stays whole and a tail equation reaches the reader', () => {
  for (const context of [0, 24]) {
    const boundary = context ? 352 : 400;
    const glyphs = line('a'.repeat(boundary - 2) + '$xyzw$' + 'b'.repeat(80) + '$uv$', 40, 200, 1);
    const pages = [page(glyphs, [det('paragraph', extent(glyphs))])];
    const vocab = { ...TAGGER, context }, h = host(pages, { vocab });
    const bundle = composeDevicePDFReader(input(1, { tagger: vocab, trace: true }), h);
    assert.equal(h.log.taggedLines, 2);
    assert.equal(h.log.crops.length, 2, 'one whole crossing equation and one tail equation');
    const index = bundle.trace as { equations: { pdf_text: string }[] };
    assert.equal(index.equations.length, 2);
    const first = h.log.crops[0].rect, second = h.log.crops[1].rect;
    assert.ok(first[2] - first[0] > second[2] - second[0], 'the crossing formula retains all four glyphs');
  }
});

test('region context never leaks into another region or a table cell, nor becomes reader content', () => {
  const a = [...line('aa', 40, 200), ...line('$xx$', 40, 220)];
  const b = line('bb', 40, 300);
  const cells = [...line('cc', 40, 400), ...line('dd', 140, 400), ...line('ee', 40, 420), ...line('ff', 140, 420)];
  const pages = [page([...a, ...b, ...cells], [det('paragraph', extent(a)), det('paragraph', extent(b)), det('table', extent(cells))])];
  const captured: TagLine[] = [], h = host(pages, { vocab: contextual });
  const originalTag = h.tag;
  h.tag = ls => { captured.push(...ls); return originalTag(ls); };
  const bundle = composeDevicePDFReader(input(1, { tagger: contextual, trace: true }), h);
  assert.deepEqual(captured.map(t => t.font.length).sort((a, b) => a - b), [2, 2, 2, 2, 2, 4, 4]);
  assert.equal((bundle.trace as { equations: unknown[] }).equations.length, 1, 'context math is not a second formula');
  assert.equal(h.log.crops.length, 1);
});

test('invalid context contracts and incomplete model answers fail explicitly', () => {
  for (const bad of [{ context: -1 }, { context: 200 }, { context: 1.5 }, { max_len: 1 }, { max_len: 401 }]) {
    assert.throws(() => tagWindows(line('ab', 40, 200), { ...contextual, ...bad }), /device_pdf_tagger/);
  }
  const glyphs = line('abc', 40, 200), pages = [page(glyphs, [det('paragraph', extent(glyphs))])];
  for (const answer of [[], [[-5]], [[-5, Number.NaN, -5]]]) {
    const h = host(pages); h.tag = () => answer;
    assert.throws(() => composeDevicePDFReader(input(1), h), /device_pdf_tagger/);
  }
});
