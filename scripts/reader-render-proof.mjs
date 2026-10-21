#!/usr/bin/env node
// Renders the cached public DPO artifact saved by reader-cutover-canary (retired 2026-10-21). No
// credentials, live endpoints or downloads; only an ephemeral loopback server.
import { createHash } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MAX_FILE = 1_600_000, MAX_MEMBERS = 1_048_576;
class ProofError extends Error {}
const fail = code => { throw new ProofError(code); };
const sha = value => createHash('sha256').update(value).digest('hex');
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).sort().join(',') === [...keys].sort().join(',');
const base64 = (value, maximum) => {
  if (typeof value !== 'string' || value.length > Math.ceil(maximum / 3) * 4) fail('artifact_base64');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length > maximum || bytes.toString('base64') !== value) fail('artifact_base64');
  return bytes;
};

export function readRenderArtifact(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX_FILE) fail('artifact_size');
  let artifact, manifest;
  try { artifact = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('artifact_json'); }
  if (!exact(artifact, ['format', 'source_id', 'manifest_sha256', 'manifest', 'members'])
    || artifact.format !== 'gradstep-reader-render-proof-v1' || artifact.source_id !== '2305.18290'
    || !/^[0-9a-f]{64}$/.test(artifact.manifest_sha256)) fail('artifact_format');
  const body = base64(artifact.manifest, 65_536);
  if (sha(body) !== artifact.manifest_sha256) fail('manifest_digest');
  try { manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body)); } catch { fail('manifest_json'); }
  if (!Array.isArray(artifact.members) || artifact.members.length < 1 || artifact.members.length > 64
    || !Array.isArray(manifest.members) || manifest.members.length !== artifact.members.length) fail('artifact_members');
  const seen = new Set(); let total = 0;
  for (const member of artifact.members) {
    if (!exact(member, ['path', 'base64']) || typeof member.path !== 'string' || member.path.length > 240
      || member.path.includes('..') || !member.path.split('/').every(part => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(part))
      || seen.has(member.path.toLowerCase())) fail('artifact_member_path');
    seen.add(member.path.toLowerCase());
    const content = base64(member.base64, MAX_MEMBERS), expected = manifest.members.filter(item => item.path === member.path);
    if (expected.length !== 1 || content.length !== expected[0].bytes || sha(content) !== expected[0].sha256) fail('member_integrity');
    total += content.length; if (total > MAX_MEMBERS) fail('artifact_size');
  }
  return artifact;
}

export const loopbackRequestAllowed = (url, origin) => {
  try { const value = new URL(url), expected = new URL(origin);
    return expected.protocol === 'http:' && expected.hostname === '127.0.0.1' && value.origin === expected.origin
      && !value.username && !value.password && !value.search && !value.hash && ['/', '/proof.js'].includes(value.pathname);
  } catch { return false; }
};

export async function renderProof(file, { output = join(dirname(file), 'render-proof') } = {}) {
  if (!lstatSync(file).isFile() || lstatSync(file).size > MAX_FILE) fail('artifact_size');
  const artifact = readRenderArtifact(readFileSync(file));
  mkdirSync(output, { mode: 0o700 }); // create-only; never overwrite earlier evidence
  const require = createRequire(join(ROOT, 'apps/web/package.json'));
  const { build } = await import(pathToFileURL(require.resolve('vite')).href);
  const { chromium } = require('@playwright/test');
  // The normal Vite plugin supplies the exact app-owned frame script/CSP hash.
  // Override all public backend values so even the local JS contains no endpoint.
  const built = await build({ root: join(ROOT, 'apps/web'), configFile: join(ROOT, 'apps/web/vite.config.ts'), logLevel: 'silent',
    define: { 'import.meta.env.VITE_SUPABASE_URL': '""', 'import.meta.env.VITE_SUPABASE_ANON_KEY': '""', 'import.meta.env.VITE_ENVIRONMENT': '"local-proof"' },
    build: { write: false, minify: false, lib: { entry: join(ROOT, 'scripts/reader-render-proof-client.ts'), formats: ['es'], fileName: () => 'proof.js' } } });
  const assets = (Array.isArray(built) ? built : [built]).flatMap(result => result.output);
  const script = assets.find(asset => asset.fileName === 'proof.js' && asset.type === 'chunk')?.code;
  const headerText = assets.find(asset => asset.fileName === '_headers')?.source;
  if (!script || assets.some(asset => asset.type === 'chunk' && asset.fileName !== 'proof.js') || typeof headerText !== 'string') fail('local_build');
  const csp = headerText.match(/^\s+Content-Security-Policy: (.+)$/m)?.[1]?.replace(/connect-src [^;]+/, "connect-src 'none'");
  if (!csp || !csp.includes("connect-src 'none'")) fail('local_csp');
  const html = '<!doctype html><meta charset="utf-8"><title>Verified reader proof</title><link rel="icon" href="data:,"><style>html,body{margin:0;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}</style><script type="module" src="/proof.js"></script>';
  let origin, browser, deadline, rejected = 0, pageErrors = 0, consoleErrors = 0;
  const server = createServer((request, response) => {
    if (request.method !== 'GET' || request.headers.host !== new URL(origin).host || !loopbackRequestAllowed(new URL(request.url, origin), origin)) {
      response.writeHead(404); response.end(); return;
    }
    response.writeHead(200, { 'Content-Type': request.url === '/proof.js' ? 'text/javascript' : 'text/html',
      'Content-Security-Policy': csp, 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store' });
    response.end(request.url === '/proof.js' ? script : html);
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    origin = `http://127.0.0.1:${server.address().port}`;
    browser = await chromium.launch({ headless: true });
    deadline = setTimeout(() => { void browser.close().catch(() => {}); }, 60_000);
    // A fresh context plus worker-src 'none' forbids service workers. Playwright's
    // serviceWorkers:block injects code that itself throws in an opaque srcdoc.
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, reducedMotion: 'reduce' });
    await context.route('**/*', route => {
      if (loopbackRequestAllowed(route.request().url(), origin)) return route.continue();
      rejected++; return route.abort('blockedbyclient');
    });
    const page = await context.newPage();
    page.on('pageerror', () => pageErrors++); page.on('console', message => { if (message.type() === 'error') consoleErrors++; });
    page.setDefaultTimeout(15_000);
    await page.goto(origin, { waitUntil: 'load' });
    await page.waitForFunction(() => typeof window.loadReaderProof === 'function');
    const themes = [];
    for (const theme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: theme });
      const expected = await page.evaluate(({ artifact, theme }) => window.loadReaderProof(artifact, theme), { artifact, theme });
      await page.waitForFunction(() => window.readerProofState.headings > 0 || window.readerProofState.invalid);
      const frame = page.frameLocator('iframe'), body = frame.locator('body');
      const measured = await body.evaluate(async (_, expected) => {
        await document.fonts.ready;
        const images = [...document.querySelectorAll('img')];
        await Promise.all(images.map(image => image.decode()));
        const shown = element => !!element && element.getBoundingClientRect().width > 0 && element.getBoundingClientRect().height > 0;
        return { headings: expected.headings.filter(id => shown(document.getElementById(id))).length,
          equations: expected.equations.filter(id => { const element = document.getElementById(id); return shown(element) && !!element.querySelector('math'); }).length,
          mathml: [...document.querySelectorAll('math')].filter(shown).length,
          figures: expected.figures.filter(id => shown(document.getElementById(id))).length,
          images: images.length, decoded_images: images.filter(image => image.src.startsWith('data:') && image.naturalWidth > 0 && image.naturalHeight > 0).length,
          horizontal_overflow: document.documentElement.scrollWidth > innerWidth + 2 };
      }, expected);
      if (!expected.equations.length || !expected.figures.length || !expected.imageMembers
        || measured.headings !== expected.headings.length || measured.equations !== expected.equations.length
        || measured.figures !== expected.figures.length || measured.mathml < expected.equations.length
        || measured.images < expected.imageMembers || measured.decoded_images !== measured.images || measured.horizontal_overflow) fail('reader_render');
      const save = async name => { const path = join(output, `${theme}-${name}.png`); await page.screenshot({ path }); chmodSync(path, 0o600); };
      await save('top');
      const displayMath = frame.locator('math[display="block"]').first();
      await displayMath.scrollIntoViewIfNeeded(); await save('math');
      await frame.locator('figure').first().scrollIntoViewIfNeeded(); await save('figure');
      await body.evaluate(() => {
        const paragraph = [...document.querySelectorAll('p[data-reader-block]')].find(item => item.textContent.length > 100);
        if (!paragraph) throw new Error('prose_missing');
        const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT); let text = walker.nextNode();
        while (text && text.textContent.length < 40) text = walker.nextNode();
        if (!text) throw new Error('text_missing');
        const range = document.createRange(); range.setStart(text, 0); range.setEnd(text, 30);
        getSelection().removeAllRanges(); getSelection().addRange(range);
        document.dispatchEvent(new Event('selectionchange'));
      });
      await page.waitForFunction(() => window.readerProofState.selection);
      const bridge = await page.evaluate(() => window.readerProofState);
      if (bridge.invalid) fail('reader_bridge');
      themes.push({ theme, ...measured, bridge_headings: bridge.headings, selection: bridge.selection });
    }
    if (rejected || pageErrors || consoleErrors) fail(`reader_browser_errors_requests_${rejected}_page_${pageErrors}_console_${consoleErrors}`);
    const report = { format: 'reader-local-render-proof-v1', manifest_sha256: artifact.manifest_sha256,
      browser: browser.version(), network: 'loopback-only', rejected_requests: rejected, page_errors: pageErrors, console_errors: consoleErrors, themes,
      limitation: 'Verified cached bundle rendering only; authentication and successful paid answers are not exercised.' };
    writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
    return report;
  } finally {
    clearTimeout(deadline);
    await browser?.close(); await new Promise(resolve => server.close(resolve));
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3 || process.argv[2].startsWith('-')) fail('usage_node_reader_render_proof_local_artifact');
    const report = await renderProof(resolve(process.argv[2])); console.log(JSON.stringify(report));
  } catch (error) {
    console.error(error instanceof ProofError ? error.message : 'local_render_proof_failed'); process.exitCode = 1;
  }
}
