// Serve the actual production admin bundle under its static CSP on loopback.
// All off-origin requests are blocked. No sign-in, fake MFA, provider call or hosted mutation.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

const root = fileURLToPath(new URL('../', import.meta.url)), directory = join(root, 'apps/admin/dist');
const artifacts = join(root, '.artifacts/admin-hosting'); await mkdir(artifacts, { recursive: true });
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
const assets = new Map();
async function collect(dir, prefix = '') {
  for (const name of await readdir(dir)) { const path = join(dir, name), entry = await stat(path);
    if (entry.isDirectory()) await collect(path, prefix + '/' + name);
    else if (!name.startsWith('_')) assets.set(prefix + '/' + name, { data: await readFile(path), type: mime[extname(name)] ?? 'application/octet-stream' });
  }
}
await collect(directory);
const headers = {}; let global = false;
for (const line of (await readFile(join(directory, '_headers'), 'utf8')).split(/\r?\n/)) {
  if (!line.trim()) continue;
  if (!/^\s/.test(line)) { global = line === '/*'; continue; }
  if (global) { const colon = line.indexOf(':'); headers[line.slice(0, colon).trim()] = line.slice(colon + 1).trim(); }
}
assert.match(headers['Content-Security-Policy'], /default-src 'none'/);
const server = createServer((request, response) => {
  const path = new URL(request.url, 'http://127.0.0.1').pathname;
  const asset = assets.get(path === '/' ? '/index.html' : path);
  if (!asset) { response.writeHead(404, headers); response.end(); return; }
  response.writeHead(200, { ...headers, 'Content-Type': asset.type, 'Cache-Control': 'no-store, no-transform' }); response.end(asset.data);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const external = [], errors = [];
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin === origin) return route.continue();
    external.push('blocked'); return route.abort();
  });
  await context.addInitScript(() => {
    window.__adminCSPViolations = [];
    window.addEventListener('securitypolicyviolation', event => window.__adminCSPViolations.push(event.violatedDirective));
  });
  const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message));
  for (const query of ['', '?fixture=spending', '?fixture=accounts', '?fixture=purchases', '?fixture=reliability', '?fixture=costs']) {
    const response = await page.goto(origin + '/' + query);
    assert.equal(response.status(), 200); assert.equal(response.headers()['content-security-policy'], headers['Content-Security-Policy']);
    await page.getByRole('heading', { name: 'Administration', exact: true }).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Sign in', exact: true }).isEnabled(), true, 'production public backend is configured');
    assert.equal(await page.getByRole('heading', { name: 'Spending', exact: true }).count(), 0);
    assert.equal(await page.getByRole('button', { name: 'Record observation', exact: true }).count(), 0);
    assert.deepEqual(await page.evaluate(() => window.__adminCSPViolations), []);
  }
  await page.screenshot({ path: join(artifacts, 'production-sign-in.png') });
  await page.setViewportSize({ width: 390, height: 844 }); await page.emulateMedia({ colorScheme: 'dark' });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
  await page.screenshot({ path: join(artifacts, 'production-sign-in-phone-dark.png') });
  assert.deepEqual(external, []); assert.deepEqual(errors, []);
  await writeFile(join(artifacts, 'production-build-check.json'), JSON.stringify({ mode: 'loopback production bundle with actual static CSP',
    fixture_queries_checked: 5, public_backend_configured: true, sign_in_attempts: 0, external_requests: external.length,
    hosted_mfa_verified: false, hosted_writes: 0, page_errors: errors }, null, 2) + '\n');
  console.log('PASS production admin: strict CSP, configured sign-in, fixture exclusion, desktop/phone dark, no off-origin requests or writes');
} finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
