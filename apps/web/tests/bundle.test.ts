// Reader bundle verification against the app's real Mathpix sample bundle (DPO).
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { type ImageCheck, verifyBundle } from '../src/lib/bundle';
import { sha256Hex, utf8 } from '../src/lib/bytes';

const SHA = 'cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71';
const dir = fileURLToPath(new URL(`../../apple/ScienceReader/Resources/ReaderSamples/${SHA}/`, import.meta.url));
const files = (): Map<string, Uint8Array<ArrayBuffer>> => {
  const out = new Map<string, Uint8Array<ArrayBuffer>>();
  const walk = (rel: string) => { for (const name of readdirSync(join(dir, rel))) { const path = rel ? `${rel}/${name}` : name;
    if (statSync(join(dir, path)).isDirectory()) walk(path); else if (path !== 'manifest.json') out.set(path, new Uint8Array(readFileSync(join(dir, path)))); } };
  walk('');
  return out;
};
const manifest = () => new Uint8Array(readFileSync(join(dir, 'manifest.json')));

// Node has no image decoder: read the frame size from the PNG IHDR / JPEG SOF header.
const headerSize: ImageCheck = async (bytes, type) => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (type === 'image/png') return { width: view.getUint32(16), height: view.getUint32(20) };
  for (let i = 2; i < bytes.length;) {
    const marker = bytes[i + 1], length = view.getUint16(i + 2);
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return { width: view.getUint16(i + 7), height: view.getUint16(i + 5) };
    i += 2 + length;
  }
  throw new Error('no frame');
};

describe('verified reader bundle', () => {
  it('admits the real sample bundle', async () => {
    expect(await sha256Hex(manifest())).toBe(SHA);
    const bundle = await verifyBundle(manifest(), SHA, files(), headerSize);
    expect(bundle.index.title).toContain('Direct Preference Optimization');
    expect(bundle.index.headings.length).toBeGreaterThan(5);
    expect(bundle.manifest.renderer.id).toBe('timestep-mathpix-mathml-v1');
  });
  it('refuses a different trusted digest, a changed byte, a missing or extra member, and wrong image sizes', async () => {
    await expect(verifyBundle(manifest(), '0'.repeat(64), files(), headerSize)).rejects.toThrow('integrity');
    const changed = files(); const html = changed.get('index.html')!.slice(); html[100] ^= 1; changed.set('index.html', html);
    await expect(verifyBundle(manifest(), SHA, changed, headerSize)).rejects.toThrow('integrity');
    const missing = files(); missing.delete('NOTICE.txt');
    await expect(verifyBundle(manifest(), SHA, missing, headerSize)).rejects.toThrow('resource');
    const extra = files(); extra.set('extra.js', utf8('alert(1)'));
    await expect(verifyBundle(manifest(), SHA, extra, headerSize)).rejects.toThrow('resource');
    await expect(verifyBundle(manifest(), SHA, files(), async () => ({ width: 1, height: 1 }))).rejects.toThrow('resource');
  });
});
