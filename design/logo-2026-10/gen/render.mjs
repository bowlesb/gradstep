// Renders SVGs with Chromium (Playwright): single PNGs at exact sizes, and contact sheets.
//   node gen/render.mjs png <in.svg> <out.png> <size>
//   node gen/render.mjs sheet <dir> <out.png> [--sizes=256,64,32,16] [--filter=prefix]
//   node gen/render.mjs page <in.html> <out.png> <width> [height]
import { chromium } from 'playwright';
import { readFileSync, readdirSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';

const [mode, ...args] = process.argv.slice(2);
const browser = await chromium.launch();
const dataURL = file => 'data:image/svg+xml;base64,' + readFileSync(file).toString('base64');

if (mode === 'png') {
  const [input, out, size] = args; const n = Number(size);
  const page = await browser.newPage({ viewport: { width: n, height: n }, deviceScaleFactor: 1 });
  await page.setContent(`<html><body style="margin:0;background:transparent"><img src="${dataURL(input)}" width="${n}" height="${n}" style="display:block"></body></html>`);
  await page.waitForTimeout(100);
  await page.screenshot({ path: out, omitBackground: true });
} else if (mode === 'sheet') {
  const [dir, out, ...rest] = args;
  const sizes = (rest.find(a => a.startsWith('--sizes='))?.slice(8) ?? '256,64,32,16').split(',').map(Number);
  const filter = rest.find(a => a.startsWith('--filter='))?.slice(9) ?? '';
  const files = readdirSync(dir).filter(f => f.endsWith('.svg') && f.startsWith(filter)).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const cell = f => `<figure><div class="row">${sizes.map(s => `<img src="${dataURL(join(dir, f))}" width="${s}" height="${s}" style="border-radius:${s * 0.2237}px">`).join('')}</div><figcaption>${basename(f, '.svg')}</figcaption></figure>`;
  const html = `<html><head><style>body{margin:0;padding:28px;background:#ECEAE4;font:13px -apple-system,sans-serif;color:#2a2a33}
    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:26px 22px}figure{margin:0}.row{display:flex;align-items:flex-end;gap:12px}
    img{display:block;box-shadow:0 1px 2px rgba(0,0,0,.12)}figcaption{margin-top:8px;font-weight:600}</style></head>
    <body><div class="grid">${files.map(cell).join('')}</div></body></html>`;
  const page = await browser.newPage({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1 });
  await page.setContent(html); await page.waitForTimeout(300);
  await page.screenshot({ path: out, fullPage: true });
} else if (mode === 'page') {
  const [input, out, width, height] = args;
  const page = await browser.newPage({ viewport: { width: Number(width), height: Number(height ?? 900) }, deviceScaleFactor: 2 });
  await page.goto('file://' + resolve(input)); await page.waitForTimeout(400);
  await page.screenshot({ path: out, fullPage: !height });
}
await browser.close();
