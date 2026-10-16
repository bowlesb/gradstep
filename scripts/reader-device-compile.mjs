#!/usr/bin/env node
// The whole device path for a cached paper, in a headless browser: the shipped compiler (apps/web/public/arxiv-reader.js)
// plans the assets, this script fetches them once (paced, cached under .artifacts/reader-sweep/assets/<id>/), the
// compiler rasterizes/admits them and composes the bundle, and the result says ok (bundle size, members, pixels) or the
// reason code. The sweep (reader-sweep.mjs) converts the HTML only; a paper can pass it and still fail on a device
// over its images (Apertus 1.5 on build 42, 2026-10-15). Since revision 15 one image the device can't prepare is
// that figure's note, not a refusal: the line counts them ("2 not shown"). Sources: .artifacts/reader-sweep/sources/<id>v<rev>.html.
//
//   node scripts/reader-device-compile.mjs --ids=2610.15542v1,2610.17288v1 [--title=...] [--out=<dir>]
// --out writes each bundle as the device installs it (<dir>/<id>/manifest.json and its members) for tests that need a
// real paper's bundle (the Simulator figure tests read one).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const ROOT = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(ROOT + 'apps/web/package.json');
const { chromium } = require('playwright');
const arg = (name, fallback) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const IDS = arg('ids', '').split(',').map(s => s.trim()).filter(Boolean);
if (!IDS.length) { console.error('pass --ids=<id>v<rev>,…'); process.exit(2); }
const compiler = readFileSync(ROOT + 'apps/web/public/arxiv-reader.js', 'utf8');
const browser = await chromium.launch();
const page = await browser.newPage();
await page.setContent(`<!doctype html><meta charset="utf-8"><script>${compiler}</script>`);
let failed = 0;
for (const key of IDS) {
  const m = /^(.+?)v(\d+)$/.exec(key); const id = m[1], revision = Number(m[2]);
  const sourcePath = `${ROOT}.artifacts/reader-sweep/sources/${key}.html`;
  if (!existsSync(sourcePath)) { console.log(`${key}: no cached source (run the sweep with --ids=${key} first)`); failed++; continue; }
  const source64 = readFileSync(sourcePath).toString('base64');
  const options = { authors: [], title: arg('title', 'Untitled') };
  let urls;
  try { urls = await page.evaluate(([s, i, r, o]) => GradstepArxivReader.assets(s, i, r, o), [source64, id, revision, options]); }
  catch (e) { console.log(`FAIL ${key}: ${/ReaderRenderError: ([a-z_]+)/.exec(e.message)?.[1] ?? e.message.slice(0, 80)} (planning)`); failed++; continue; }
  const dir = `${ROOT}.artifacts/reader-sweep/assets/${key}`; mkdirSync(dir, { recursive: true });
  const inputs = [];
  for (const url of urls) {
    const file = `${dir}/${encodeURIComponent(url.split('/').slice(-1)[0])}`;
    if (!existsSync(file)) {
      const r = await fetch(url, { headers: { 'user-agent': 'Gradstep/0.1 reader-device-compile (+https://gradstep.ai; mailto:hello@gradstep.ai)' } });
      if (r.status !== 200) { console.log(`${key}: asset ${url} HTTP ${r.status}`); break; }
      writeFileSync(file, Buffer.from(await r.arrayBuffer())); await new Promise(r => setTimeout(r, 400));
    }
    inputs.push({ url, base64: readFileSync(file).toString('base64') });
  }
  const started = Date.now();
  const result = await page.evaluate(async ([s, i, r, inputs, o]) => {
    try {
      const p = await GradstepArxivReader.prepare(s, i, r, inputs, o);
      const members = p.members ?? []; const bytes = members.reduce((n, m) => n + Math.floor(m.base64.length * 3 / 4), 0);
      const images = members.filter(m => /^assets\//.test(m.path));
      const page = new TextDecoder().decode(Uint8Array.from(atob(members.find(m => m.path === 'index.html')?.base64 ?? ''), c => c.charCodeAt(0)));
      const unshown = (page.match(/couldn’t be shown here; the PDF has it/g) ?? []).length;
      return { ok: true, members: members.length, images: images.length, unshown, bytes, largest: Math.max(0, ...images.map(m => Math.floor(m.base64.length * 3 / 4))),
        written: { manifest: p.manifest ?? null, sha256: p.manifestSHA256 ?? p.manifest_sha256 ?? null, members } };
    } catch (e) { return { ok: false, code: e?.message?.slice(0, 80) ?? String(e) }; }
  }, [source64, id, revision, inputs, options]);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  const out = arg('out', '');
  if (result.ok && out && result.written.manifest) {
    const target = `${out}/${key}`; mkdirSync(target, { recursive: true });
    writeFileSync(`${target}/manifest.json`, Buffer.from(result.written.manifest, 'base64'));
    for (const m of result.written.members) { mkdirSync(`${target}/${m.path}`.replace(/\/[^/]*$/, ''), { recursive: true }); writeFileSync(`${target}/${m.path}`, Buffer.from(m.base64, 'base64')); }
    writeFileSync(`${target}/manifest.sha256`, String(result.written.sha256 ?? ''));
  }
  if (result.ok) console.log(`ok   ${key}: ${urls.length} assets in, ${result.images} images out${result.unshown ? `, ${result.unshown} not shown` : ''}, bundle ${(result.bytes / 1048576).toFixed(1)} MiB (largest image ${(result.largest / 1048576).toFixed(1)} MiB), ${seconds} s`);
  else { console.log(`FAIL ${key}: ${result.code} (${urls.length} assets, ${seconds} s)`); failed++; }
}
await browser.close();
process.exit(failed ? 1 : 0);
