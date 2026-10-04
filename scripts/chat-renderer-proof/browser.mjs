import { chromium } from '../../node_modules/playwright/index.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const mode = process.argv[2] ?? 'typesetter';
if (!['typesetter', 'source'].includes(mode)) throw new Error('unknown_component');
const proofGlobal = mode === 'source' ? 'ChatSourceProof' : 'ChatTypesetterProof';
const directory = new URL(`../../.artifacts/chat-${mode}-component/`, import.meta.url);
const bundle = readFileSync(new URL(mode === 'source' ? 'tokenizer.js' : 'typesetter.js', directory), 'utf8');
const fixtureData = readFileSync(new URL('fixtures.json', directory));
const fixtures = JSON.parse(fixtureData);
const browser = await chromium.launch({ headless: true, args: [
  '--disable-background-networking', '--disable-component-update', '--disable-sync',
  '--disable-extensions', '--no-first-run', '--host-resolver-rules=MAP * ~NOTFOUND',
  '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>' ] });
const rows = [];
try {
  for (const fixture of fixtures) {
    const context = await browser.newContext({ serviceWorkers: 'block' });
    let requests = 0, consoleCalls = 0, pageErrors = 0;
    await context.route('**/*', route => { requests++; return route.abort(); });
    const page = await context.newPage();
    page.on('console', () => consoleCalls++); page.on('pageerror', () => pageErrors++);
    try {
      await page.setContent('<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src \'none\'">');
      await page.evaluate(bundle);
      const start = performance.now();
      const result = await page.evaluate(({ input, name }) => globalThis[name].run(input), { input: fixture, name: proofGlobal });
      const durationMs = Math.round(performance.now() - start);
      const reuse = await page.evaluate(name => globalThis[name].run({ source: 'x' }), proofGlobal);
      const pass = result.code === fixture.expected && (!fixture.expectedStage || result.stage === fixture.expectedStage)
        && (!fixture.labeled || result.textNodes > 0) && reuse.code === 'realm_consumed'
        && requests === 0 && consoleCalls === 0 && pageErrors === 0;
      rows.push({ id: fixture.id, expected: fixture.expected, ...result, durationMs, requests, consoleCalls, pageErrors, pass });
    } finally { await context.close(); }
  }
  const report = { format: 1, browser: await browser.version(), component: mode,
    scope: 'isolated component only; no sanitization, native layout, shipping renderer or hard CPU/RSS bound',
    bundleSHA256: createHash('sha256').update(bundle).digest('hex'),
    fixturesSHA256: createHash('sha256').update(fixtureData).digest('hex'), rows, passed: rows.every(row => row.pass) };
  writeFileSync(new URL('browser-results.json', directory), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ cases: rows.length, passed: report.passed, rows }));
  if (!report.passed) process.exitCode = 1;
} finally { await browser.close(); }
