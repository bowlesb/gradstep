// Part framing (figure-framing.ts; FIGURE_VIEW.md "Parts as viewports") against the shared fixture
// tests/fixtures/figure-crops/framing.json, which ScienceReaderCore's FigureFramingTests read too: the same parameters,
// levels, scores, reasons, frames and regions on the same real figures. UPDATE_FRAMING_FIXTURE=1 rewrites the expectations
// from this implementation (review the levels and reasons in the diff: they are the behaviour).
import { readFileSync, writeFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { figureInk, type Rect } from '../src/lib/figure-crops';
import { FRAMING, captionLetters, frameAspect, frameParts, framingLook, keptParts, labelLetter } from '../src/lib/figure-framing';

const dir = new URL('../../../tests/fixtures/figure-crops/', import.meta.url);
type Part = { level: string; score: number; reasons: string[]; extra: boolean; veil: number; outlined: boolean; framePixels: number[]; regionPixels: number[] };
const fixture = JSON.parse(readFileSync(new URL('framing.json', dir), 'utf8')) as {
  parameters: Record<string, number>; tolerancePixels: number; toleranceScore: number;
  cases: { name: string; image: string; width: number; height: number; unchecked: boolean; boxes: Rect[]; labels: string[]; caption: string; detector: (number | null)[] | null;
    expect: { coverage: number | null; parts: Part[] } }[];
  captionLetters: { caption: string; letters: string[] }[]; labelLetters: { label: string; letter: string | null }[];
};

/** A non-interlaced 8-bit RGB or RGBA PNG (the fixtures), as RGB(A) bytes (as figure-crops.test.ts reads them). */
function png(bytes: Buffer): { width: number; height: number; channels: number; pixels: Uint8Array } {
  let at = 8, width = 0, height = 0, channels = 0;
  const data: Buffer[] = [];
  while (at < bytes.length) {
    const length = bytes.readUInt32BE(at), type = bytes.toString('latin1', at + 4, at + 8), body = bytes.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') { width = body.readUInt32BE(0); height = body.readUInt32BE(4); channels = body[9] === 2 ? 3 : 4; }
    else if (type === 'IDAT') data.push(body);
    at += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(data)), stride = width * channels, out = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? out[y * stride + x - channels] : 0, b = y ? out[(y - 1) * stride + x] : 0, c = x >= channels && y ? out[(y - 1) * stride + x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const predicted = filter === 0 ? 0 : filter === 1 ? a : filter === 2 ? b : filter === 3 ? (a + b) >> 1 : pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      out[y * stride + x] = (line[x] + predicted) & 255;
    }
  }
  return { width, height, channels, pixels: out };
}
const inks = new Map<string, ReturnType<typeof figureInk>>();
const inkFor = (name: string) => {
  if (!inks.has(name)) { const image = png(readFileSync(new URL(name, dir))); inks.set(name, figureInk(image.pixels, image.width, image.height, image.channels)); }
  return inks.get(name)!;
};
const framed = (c: (typeof fixture.cases)[number]) => {
  const ink = inkFor(c.image);
  return frameParts(c.unchecked ? null : ink, { width: c.width, height: c.height }, { boxes: c.boxes, labels: c.labels, caption: c.caption, detector: c.detector ?? undefined });
};
const pixels = (f: Rect, W: number, H: number) => [f[0] * W, f[1] * H, f[2] * W, f[3] * H];

describe('figure part framing (shared fixtures)', () => {
  it('uses the parameters the fixture states', () => {
    expect({ ...FRAMING }).toEqual(fixture.parameters);
  });

  for (const c of fixture.cases) {
    it(c.name, () => {
      const result = framed(c);
      if (c.expect.coverage === null) expect(result.coverage).toBeNull();
      else expect(result.coverage).toBeCloseTo(c.expect.coverage, 4);
      expect(result.parts.length).toBe(c.expect.parts.length);
      result.parts.forEach((part, k) => {
        const want = c.expect.parts[k];
        expect([part.level, part.reasons, part.extra, part.veil, part.outlined]).toEqual([want.level, want.reasons, want.extra, want.veil, want.outlined]);
        expect(Math.abs(part.score - want.score)).toBeLessThanOrEqual(fixture.toleranceScore);
        pixels(part.frame, c.width, c.height).forEach((v, j) => expect(Math.abs(v - want.framePixels[j])).toBeLessThanOrEqual(fixture.tolerancePixels));
        pixels(part.region, c.width, c.height).forEach((v, j) => expect(Math.abs(v - want.regionPixels[j])).toBeLessThanOrEqual(fixture.tolerancePixels));
      });
    });
  }

  it('reads panel letters from captions and labels', () => {
    for (const { caption, letters } of fixture.captionLetters) expect(captionLetters(caption)).toEqual(letters);
    for (const { label, letter } of fixture.labelLetters) expect(labelLetter(label)).toBe(letter);
  });

  it('keeps only the caption\'s panels, lettered ones first', () => {
    expect(keptParts(['(a)', '(b)', 'Legend'], ['a', 'b'])).toEqual([true, true, false]);
    expect(keptParts(['Legend', '(b)', '(a)'], ['a', 'b'])).toEqual([false, true, true]);
    expect(keptParts(['Left', 'Middle', 'Right'], ['a', 'b'])).toEqual([true, true, false]);
    expect(keptParts(['(a)', '(a)', 'Right'], ['a', 'b'])).toEqual([true, false, true]);
    // Without letters (or with fewer parts than letters) every part is kept.
    expect(keptParts(['x', 'y', 'z'], [])).toEqual([true, true, true]);
    expect(keptParts(['(a)'], ['a', 'b', 'c'])).toEqual([true]);
  });

  it('frames tight parts as their crop with its margin, loose ones wider, low ones whole', () => {
    const c = fixture.cases.find(x => x.name === 'imprecise-box-reaches-neighbour')!, { parts } = framed(c);
    const [tight, loose] = parts;
    // Tight: the completed crop plus the background margin (10 px on this 1360 × 501 image), as the crops looked.
    expect(pixels(tight.frame, c.width, c.height).map(Math.round)).toEqual([-2, -2, 682, 502]);
    expect(frameAspect(tight, c)).toBeCloseTo(684 / 504, 3);
    // Loose: wider than its region on every side the canvas allows; the whole figure's frame is the canvas.
    expect(loose.frame[0]).toBeLessThan(loose.region[0]);
    expect(loose.frame[1]).toBeLessThanOrEqual(loose.region[1]);
    const cut = framed(fixture.cases.find(x => x.name === 'detail-slice')!).parts[0];
    expect(cut.frame).toEqual([-cut.padX, -cut.padY, 1 + cut.padX, 1 + cut.padY].map(v => Math.round(v * 1e6) / 1e6));
    expect(frameParts(null, { width: 0, height: 0 }, { boxes: [[0, 0, 0.5, 1]] }).parts).toEqual([]);
  });

  it('reveals context once the reader zooms or pans: a tight frame\'s veil turns soft and its outline shows', () => {
    expect(framingLook({ veil: 1, outlined: false }, false)).toEqual({ veil: 1, outlined: false });
    expect(framingLook({ veil: 1, outlined: false }, true)).toEqual({ veil: FRAMING.veilRevealed, outlined: true });
    expect(framingLook({ veil: 0, outlined: true }, true)).toEqual({ veil: 0, outlined: true });
  });
});

if (process.env.UPDATE_FRAMING_FIXTURE) {
  it('rewrites the expectations', () => {
    const file = JSON.parse(readFileSync(new URL('framing.json', dir), 'utf8'));
    file.parameters = { ...FRAMING };
    for (const c of file.cases) {
      const r = framed(c), round = (v: number) => Math.round(v * 100) / 100;
      c.expect = { coverage: r.coverage === null ? null : Math.round(r.coverage * 1e6) / 1e6, parts: r.parts.map(p => ({ level: p.level, score: p.score, reasons: p.reasons,
        extra: p.extra, veil: p.veil, outlined: p.outlined, framePixels: pixels(p.frame, c.width, c.height).map(round), regionPixels: pixels(p.region, c.width, c.height).map(round) })) };
    }
    file.captionLetters = file.captionLetters.map((x: { caption: string }) => ({ caption: x.caption, letters: captionLetters(x.caption) }));
    file.labelLetters = file.labelLetters.map((x: { label: string }) => ({ label: x.label, letter: labelLetter(x.label) }));
    writeFileSync(new URL('framing.json', dir), JSON.stringify(file, null, 1) + '\n');
  });
}
