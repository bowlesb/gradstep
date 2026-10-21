// Test-only host for the reader frame's snippet capture (notes-capture.spec.ts). Not part of the production build.
// It mounts the real frame document (frameDocument: the bundle's own CSP, sandbox, shim and bridge) for a verified
// bundle the test supplies, asks it to capture regions, and compares two PNGs pixel by pixel.
import { fromBase64, toBase64 } from '../src/lib/bytes';
import { verifyBundle } from '../src/lib/bundle';
import { frameDocument } from '../src/reader/frame';

type Reply = { type: string; nonce: string; ok: boolean; png?: ArrayBuffer | string; width?: number; height?: number; blocks?: string[]; reason?: string };
let frame: HTMLIFrameElement | null = null, ready: (() => void) | null = null;
const replies = new Map<string, (value: Reply) => void>();
addEventListener('message', event => {
  if (!frame || event.source !== frame.contentWindow || event.data?.gradstep !== 'reader') return;
  const value = event.data.value as Reply;
  if (value?.type === 'headings') ready?.();
  if ((value?.type === 'capture' || value?.type === 'captureProbe') && replies.has(value.nonce)) { replies.get(value.nonce)!(value); replies.delete(value.nonce); }
});
const command = (name: string, ...args: unknown[]) => frame!.contentWindow!.postMessage({ gradstep: 'command', name, args }, '*');
async function ask(name: string, ...args: unknown[]): Promise<Reply> {
  const nonce = crypto.randomUUID(), reply = new Promise<Reply>(resolve => replies.set(nonce, resolve));
  command(name, nonce, ...args);
  return reply;
}
async function pixels(base64: string) {
  const bitmap = await createImageBitmap(new Blob([fromBase64(base64)], { type: 'image/png' }));
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height), context = canvas.getContext('2d')!;
  context.drawImage(bitmap, 0, 0);
  return { width: bitmap.width, height: bitmap.height, data: context.getImageData(0, 0, bitmap.width, bitmap.height).data };
}

Object.assign(window, { harness: {
  async load(manifest: string, sha: string, members: [string, string][], theme: 'light' | 'dark', width: number, height: number, lineWidth?: 'comfortable' | 'wide' | 'full') {
    const bundle = await verifyBundle(fromBase64(manifest), sha, new Map(members.map(([path, bytes]) => [path, fromBase64(bytes)])));
    frame?.remove();
    frame = document.createElement('iframe');
    frame.sandbox.add('allow-scripts');
    frame.style.cssText = `display:block;border:0;width:${width}px;height:${height}px`;
    frame.srcdoc = frameDocument(bundle, { parentOrigin: location.origin, theme, fontSize: 18, lineWidth });
    const shown = new Promise<void>(resolve => { ready = resolve; });
    document.body.append(frame);
    await shown;
    return { equations: bundle.index.equations.filter(e => e.display).map(e => e.id), figures: bundle.index.figures.map(f => f.id), tables: (bundle.index.tables ?? []).map(t => t.id) };
  },
  async capture(rect: unknown) {
    const reply = await ask('capture', rect);
    if (reply.png instanceof ArrayBuffer) reply.png = toBase64(new Uint8Array(reply.png));
    return reply;
  },
  probe: () => ask('captureProbe'),
  /** Mean absolute channel difference (0–255) and the share of pixels whose largest channel difference exceeds 64,
   * after scaling `b` to `a`'s size (screenshots and captures are both at the device scale). */
  async compare(a: string, b: string) {
    const x = await pixels(a), y0 = await pixels(b);
    let y = y0;
    if (y0.width !== x.width || y0.height !== x.height) {
      const bitmap = await createImageBitmap(new Blob([fromBase64(b)], { type: 'image/png' }));
      const canvas = new OffscreenCanvas(x.width, x.height), context = canvas.getContext('2d')!;
      context.drawImage(bitmap, 0, 0, x.width, x.height);
      y = { width: x.width, height: x.height, data: context.getImageData(0, 0, x.width, x.height).data };
    }
    // Strict: each pixel against the same pixel. Tolerant: against the closest of its 3×3 neighbours, so a line of text
    // placed one device pixel lower (fractional line heights round differently) is not counted as different.
    const at = (d: Uint8ClampedArray, i: number, j: number) => Math.max(Math.abs(x.data[i] - d[j]), Math.abs(x.data[i + 1] - d[j + 1]), Math.abs(x.data[i + 2] - d[j + 2]));
    let sum = 0, bad = 0, near = 0, nearBad = 0;
    for (let row = 0; row < x.height; row++) for (let col = 0; col < x.width; col++) {
      const i = (row * x.width + col) * 4, d = at(y.data, i, i);
      sum += (Math.abs(x.data[i] - y.data[i]) + Math.abs(x.data[i + 1] - y.data[i + 1]) + Math.abs(x.data[i + 2] - y.data[i + 2])) / 3;
      if (d > 64) bad++;
      let best = d;
      for (let dy = -1; dy <= 1 && best > 0; dy++) for (let dx = -1; dx <= 1; dx++) {
        const r = row + dy, c = col + dx;
        if (r < 0 || c < 0 || r >= x.height || c >= x.width) continue;
        best = Math.min(best, at(y.data, i, (r * x.width + c) * 4));
      }
      near += best; if (best > 64) nearBad++;
    }
    const n = x.data.length / 4;
    return { width: x.width, height: x.height, sourceWidth: y0.width, sourceHeight: y0.height, mean: sum / n, bad: bad / n, nearMean: near / n, nearBad: nearBad / n };
  },
} });
