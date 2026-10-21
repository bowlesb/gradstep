// Opt-in: `npx playwright test -c notes-capture.playwright.config.ts`. See docs/architecture/NOTES_AND_SNIPPETS.md.
// The real reader frame (bundle CSP, sandbox, shim, bridge) on real bundles: the DPO Mathpix sample (text, MathML,
// JPEG figures) and, when its pinned source is on this machine, the official arXiv HTML of 2305.18290v3 compiled by
// the shipped device compiler. Each capture is compared with the browser's own screenshot of the same pixels.
// Results and both images per case are written to .artifacts/notes-capture/ for review.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { expect, test, type Frame, type Page } from '@playwright/test';

const root = new URL('../../../', import.meta.url);
const out = new URL('.artifacts/notes-capture/', root);
mkdirSync(out, { recursive: true });
type Bundle = { name: string; manifest: string; sha: string; members: [string, string][] };

function sample(): Bundle {
  const dir = new URL('apps/apple/ScienceReader/Resources/ReaderSamples/cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/', root);
  const manifest = readFileSync(new URL('manifest.json', dir));
  const members: [string, string][] = JSON.parse(manifest.toString()).members.map((m: { path: string }) => [m.path, readFileSync(new URL(m.path, dir)).toString('base64')]);
  return { name: 'dpo-mathpix', manifest: manifest.toString('base64'), sha: createHash('sha256').update(manifest).digest('hex'), members };
}
// The pinned corpus sources live outside git (npm run test:slow:fetch); READER_CORPUS_DIR may point at another checkout's copy.
const corpus = process.env.READER_CORPUS_DIR ? new URL(process.env.READER_CORPUS_DIR.replace(/\/?$/, '/'), 'file://') : new URL('.artifacts/reader-corpus/', root);
async function compiled(page: Page, key: string): Promise<Bundle | null> {
  const lock = JSON.parse(readFileSync(new URL('tests/corpus/reader-lock.json', root), 'utf8')).papers.find((p: { key: string }) => p.key === key);
  if (!lock || !existsSync(new URL(`${key}/source.html`, corpus))) return null;
  const input = (name: string) => readFileSync(new URL(`${key}/${name}`, corpus)).toString('base64');
  const script = readFileSync(new URL('apps/web/public/arxiv-reader.js', root), 'utf8') + '\n' + readFileSync(new URL('apps/web/src/reader/arxiv-compiler-host.js', root), 'utf8');
  const hash = 'sha256-' + createHash('sha256').update(script).digest('base64');
  const [id, revision] = key.split('v');
  const inputs = lock.assets.map((a: { url: string }) => ({ url: a.url, base64: input(createHash('sha256').update(a.url).digest('hex')) }));
  const result = await page.evaluate(async ({ script, hash, source, inputs, id, revision }) => {
    const frame = document.createElement('iframe'); frame.sandbox.add('allow-scripts');
    frame.srcdoc = `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${hash}'; img-src data:; connect-src 'none'; style-src 'none'; base-uri 'none'"><script>${script}</script>`;
    const loaded = new Promise<void>(resolve => { frame.onload = () => resolve(); }); document.body.append(frame); await loaded;
    try {
      return await new Promise<any>((resolve, reject) => {
        const c = new MessageChannel(), timer = setTimeout(() => reject(Error('compiler timeout')), 90000);
        c.port1.onmessage = e => { clearTimeout(timer); resolve(e.data); };
        frame.contentWindow!.postMessage({ method: 'prepare', source, sourceID: id, revision: Number(revision), inputs }, '*', [c.port2]);
      });
    } finally { frame.remove(); }
  }, { script, hash, source: input('source.html'), inputs, id, revision });
  expect(result.ok, JSON.stringify(result.failure)).toBe(true);
  const bundle = result.result;
  return { name: `arxiv-${key}`, manifest: bundle.manifest, sha: bundle.manifestSHA256, members: bundle.members.map((m: { path: string; base64: string }) => [m.path, m.base64]) };
}

type Rect = { x: number; y: number; width: number; height: number };
const frameOf = (page: Page): Frame => page.frames().find(f => f !== page.mainFrame())!;
async function region(frame: Frame, kind: string, ids: { equations: string[]; figures: string[] }): Promise<Rect | null> {
  return frame.evaluate(({ kind, ids }) => {
    const pad = (r: DOMRect, p = 8) => { const x = Math.floor(Math.max(0, r.left - p)), y = Math.floor(Math.max(0, r.top - p));
      return { x, y, width: Math.ceil(Math.min(innerWidth - 20, r.right + p)) - x, height: Math.ceil(r.bottom + p) - y }; };
    const show = (element: Element | null) => { if (!element) return null; element.scrollIntoView({ block: 'center' }); return element.getBoundingClientRect(); };
    if (kind === 'text') { const p = [...document.querySelectorAll('p[data-reader-block]')].find(p => p.getBoundingClientRect().height > 80 && !p.querySelector('math, img')); const r = show(p ?? null); return r && pad(r); }
    if (kind === 'math') { for (const id of ids.equations) { const e = document.getElementById(id); const box = e?.closest('.reader-display, .ltx_equation, .ltx_equationgroup, table') ?? e; const r = show(box ?? null); if (r && r.height > 20) return pad(r); } return null; }
    if (kind === 'figure') { for (const id of ids.figures) { const r = show(document.getElementById(id)); if (r && r.height > 60 && r.height < innerHeight - 40) return pad(r); } return null; }
    if (kind === 'mixed') { const h = [...document.querySelectorAll('h2, h3')][2] ?? document.querySelector('h2'); h?.scrollIntoView({ block: 'start' }); return { x: 0, y: 0, width: innerWidth - 20, height: Math.min(560, innerHeight) }; }
    return null;
  }, { kind, ids });
}

for (const bundleName of ['dpo-mathpix', 'arxiv-2305.18290v3']) {
  for (const theme of ['light', 'dark'] as const) {
    test(`${bundleName} ${theme}: local capture matches the screen`, async ({ page }, info) => {
      const network: string[] = [];
      await page.route(url => !url.href.startsWith(`http://127.0.0.1:`), route => { network.push(route.request().url()); return route.abort(); });
      await page.goto('/e2e/capture-harness.html');
      await page.waitForFunction(() => 'harness' in window);
      const bundle = bundleName === 'dpo-mathpix' ? sample() : await compiled(page, '2305.18290v3');
      test.skip(!bundle, 'The pinned arXiv source is not on this machine (npm run test:slow:fetch).');
      const ids = await page.evaluate(({ b, theme }) => (window as any).harness.load(b.manifest, b.sha, b.members, theme, 880, 900), { b: bundle!, theme });
      const probe = await page.evaluate(() => (window as any).harness.probe());
      const results: Record<string, unknown> = { engine: info.project.name, bundle: bundleName, theme, probe: probe.ok };
      expect(probe.ok, 'canvas readable after drawing a foreignObject image').toBe(true);
      const frame = frameOf(page);
      for (const kind of ['text', 'math', 'figure', 'mixed', 'element']) {
        let rect: Rect | null, capture: any;
        if (kind === 'element') {
          // A whole equation captured while it is off screen (Add to note from the equation view), then shown to compare.
          const id = ids.equations[Math.min(3, ids.equations.length - 1)];
          await frame.evaluate(() => scrollTo(0, 0));
          capture = await page.evaluate(id => (window as any).harness.capture({ element: id }), id);
          rect = await frame.evaluate(id => { const e = document.getElementById(id)!; e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect();
            const x = Math.floor(Math.max(0, r.left - 8)), y = Math.floor(r.top - 8); return { x, y, width: Math.ceil(Math.min(innerWidth, r.right + 8)) - x, height: Math.ceil(r.bottom + 8) - y }; }, id);
        } else {
          rect = await region(frame, kind, ids);
          if (!rect) { results[kind] = 'none in this bundle'; continue; }
          await page.waitForTimeout(150);
          capture = await page.evaluate(r => (window as any).harness.capture(r), rect);
        }
        expect(capture.ok, `${kind}: ${capture.reason}`).toBe(true);
        await page.waitForTimeout(100);
        const screen = (await page.screenshot({ clip: rect! })).toString('base64');
        const metric = await page.evaluate(([a, b]) => (window as any).harness.compare(a, b), [screen, capture.png]);
        const prefix = `${info.project.name}-${bundleName}-${theme}-${kind}`;
        writeFileSync(new URL(`${prefix}-screen.png`, out), Buffer.from(screen, 'base64'));
        writeFileSync(new URL(`${prefix}-capture.png`, out), Buffer.from(capture.png, 'base64'));
        results[kind] = { ...metric, blocks: capture.blocks?.length ?? 0 };
      }
      writeFileSync(new URL(`${info.project.name}-${bundleName}-${theme}.json`, out), JSON.stringify(results, null, 2));
      await info.attach('fidelity', { body: JSON.stringify(results, null, 2), contentType: 'application/json' });
      expect(network).toEqual([]);
      // Faithful: practically no pixel without a close match within one device pixel (antialiasing, image resampling
      // and fractional line positions differ slightly between a screenshot and a canvas), and a small mean difference.
      for (const [kind, value] of Object.entries(results)) if (value && typeof value === 'object') {
        const m = value as { nearMean: number; nearBad: number; mean: number; bad: number };
        expect.soft(m.nearBad, `${kind} pixels with no close match`).toBeLessThan(0.005);
        expect.soft(m.nearMean, `${kind} mean difference within a pixel`).toBeLessThan(2.5);
      }
    });
  }
}
