// The completeness step against the shared golden fixtures exported from scripts/subfigure-detector/app_crops.py
// (tests/fixtures/figure-crops/cases.json); the apps' FigureCropCompletionTests read the same file.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { completeCrops, cropPadding, figureInk, presented, boxFractions, type Rect } from '../src/lib/figure-crops';

const dir = new URL('../../../tests/fixtures/figure-crops/', import.meta.url);
const fixtures = JSON.parse(readFileSync(new URL('cases.json', dir), 'utf8')) as {
  tolerancePixels: number;
  cases: { name: string; image: string; width: number; height: number; boxes: Rect[];
    expect: { components: number; inkPixels: number; componentDigest: string; tiled: boolean; crops: (Rect | null)[]; inkCoverage: number; padding: number } }[];
};

/** A non-interlaced 8-bit RGB or RGBA PNG (the fixtures), as RGB(A) bytes. */
function png(bytes: Buffer): { width: number; height: number; channels: number; pixels: Uint8Array } {
  let at = 8, width = 0, height = 0, channels = 0;
  const data: Buffer[] = [];
  while (at < bytes.length) {
    const length = bytes.readUInt32BE(at), type = bytes.toString('latin1', at + 4, at + 8), body = bytes.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') {
      width = body.readUInt32BE(0); height = body.readUInt32BE(4);
      if (body[8] !== 8 || body[12] !== 0 || (body[9] !== 2 && body[9] !== 6)) throw new Error('unsupported PNG');
      channels = body[9] === 2 ? 3 : 4;
    } else if (type === 'IDAT') data.push(body);
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

const images = new Map<string, ReturnType<typeof figureInk>>();
const inkFor = (name: string) => {
  if (!images.has(name)) { const image = png(readFileSync(new URL(name, dir))); images.set(name, figureInk(image.pixels, image.width, image.height, image.channels)); }
  return images.get(name)!;
};

describe('figure crop completeness (shared fixtures)', () => {
  for (const c of fixtures.cases) {
    it(c.name, () => {
      const ink = inkFor(c.image);
      expect([ink.width, ink.height]).toEqual([c.width, c.height]);
      expect(ink.inkPixels).toBe(c.expect.inkPixels);
      expect(ink.components.length).toBe(c.expect.components);
      const digest = createHash('sha256').update(ink.components.map(k => `${k.box.join(',')},${k.pixels}`).join(';')).digest('hex');
      expect(digest).toBe(c.expect.componentDigest);
      const result = completeCrops(ink, c.boxes);
      expect(result.tiled).toBe(c.expect.tiled);
      expect(result.crops.length).toBe(c.expect.crops.length);
      result.crops.forEach((crop, i) => {
        const want = c.expect.crops[i];
        if (want === null) { expect(crop).toBeNull(); return; }
        expect(crop).not.toBeNull();
        crop!.forEach((v, j) => expect(Math.abs(v - want[j])).toBeLessThanOrEqual(fixtures.tolerancePixels));
      });
      expect(result.coverage).toBeCloseTo(c.expect.inkCoverage, 4);
      expect(cropPadding(c.width, c.height)).toBe(c.expect.padding);
    });
  }

  it('presents a crop with background padding and a whole-figure card for a crop that could not be completed', () => {
    const shown = presented({ width: 1000, height: 400 }, [100, 40, 500, 360]);
    expect(shown).toEqual({ region: [0.1, 0.1, 0.5, 0.9], whole: false, padX: 8 / 1000, padY: 8 / 400 });
    expect(presented({ width: 1000, height: 400 }, null).whole).toBe(true);
    expect(cropPadding(2000, 1200)).toBe(24);
    expect(boxFractions({ x: 0.25, y: 0.5, w: 0.5, h: 0.25 })).toEqual([0.25, 0.5, 0.75, 0.75]);
  });

  it('runs in tens of milliseconds on a sent-size figure', () => {
    const ink = inkFor('dpo-figure-2.png'), start = performance.now();
    completeCrops(ink, fixtures.cases[0].boxes);
    expect(performance.now() - start).toBeLessThan(500);
  });
});
