// Loopback-only owner form with a synthetic append ledger. No Auth/MFA claim or hosted writes.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const base = new URL(process.env.SPENDING_PREVIEW ?? 'http://127.0.0.1:5198');
if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1') throw Error('Loopback preview required');
const folder = '.artifacts/spending-entry'; await mkdir(folder, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  await context.route('**/*', route => new URL(route.request().url()).origin === base.origin ? route.continue() : route.abort());
  const calls = [], ledger = new Map(); let loseNext = true;
  await context.route('**/__fixture-spending-entry', async route => {
    const body = route.request().postDataJSON(), previous = ledger.get(body.request_id); calls.push(structuredClone(body));
    if (previous && JSON.stringify(previous) !== JSON.stringify(body)) return route.fulfill({ status: 409, json: { code: 'observation_id_conflict' } });
    ledger.set(body.request_id, structuredClone(body));
    if (loseNext) { loseNext = false; return route.abort('failed'); }
    return route.fulfill({ status: 200, json: { id: body.request_id, replayed: !!previous } });
  });
  const page = await context.newPage(), errors = []; page.on('pageerror', error => errors.push(error.message));
  const month = new Date().toISOString().slice(0, 7);
  const visit = async () => { await page.goto(new URL('/?fixture=spending&state=entry', base).href);
    await page.getByRole('heading', { name: 'Spending', exact: true }).waitFor(); await page.getByText('Loading spending…').waitFor({ state: 'hidden' }); };
  const entry = page.getByRole('region', { name: 'Record cost evidence', exact: true });
  const fill = async (measure, amount, evidence) => {
    await entry.getByRole('button', { name: 'Add observation', exact: true }).click();
    assert.equal(await page.evaluate(() => document.activeElement?.tagName), 'SELECT');
    await entry.getByLabel('Reporting month', { exact: true }).fill(month);
    await entry.getByRole('combobox', { name: 'Measure', exact: true }).selectOption(measure);
    await entry.getByLabel('Amount (USD)', { exact: true }).fill(amount);
    await entry.getByLabel('Evidence reference', { exact: true }).fill(evidence);
  };
  await visit(); await fill('invoice', '30', 'dated-source:tavily-paid-2026-10-06');
  await entry.getByRole('button', { name: 'Record observation', exact: true }).click();
  await entry.getByRole('alert').getByText('The observation was not confirmed.', { exact: false }).waitFor();
  assert.equal(calls.length, 1); assert.equal(await entry.getByLabel('Amount (USD)', { exact: true }).isDisabled(), true);
  const retryState = await page.evaluate(() => Object.entries(sessionStorage).filter(([key]) => key.includes('.spending-retry.')));
  assert.equal(retryState.length, 1);
  for (const privateText of ['dated-source', 'tavily-paid', '30000000', 'amount_microusd', 'invoice']) assert.ok(!JSON.stringify(retryState).includes(privateText));
  await entry.getByRole('button', { name: 'Retry same entry', exact: true }).click();
  await entry.getByText('Already recorded; no duplicate was added.', { exact: false }).waitFor();
  assert.deepEqual(calls[0], calls[1]); assert.equal(ledger.size, 1);
  await page.getByText('Recorded plan:', { exact: false }).filter({ hasText: '$35.00' }).waitFor();
  await page.getByText('Recent invoices and infrastructure observations', { exact: true }).click();
  await page.getByText('tavily subscription · invoice', { exact: true }).waitFor();
  await page.getByText('$30.00 ·', { exact: false }).filter({ hasText: 'Partial observation' }).waitFor();

  await entry.getByRole('button', { name: 'Record another observation', exact: true }).click();
  assert.equal(await page.evaluate(() => document.activeElement?.tagName), 'SELECT');
  await entry.getByRole('combobox', { name: 'Measure', exact: true }).selectOption('commitment');
  await entry.getByLabel('Amount (USD)', { exact: true }).fill('30');
  await entry.getByLabel('Complete evidence', { exact: true }).check();
  await entry.getByLabel('Evidence reference', { exact: true }).fill('dated-source:monthly-total-2026-10');
  await entry.getByText('individual line items are not added together.', { exact: false }).waitFor();
  await entry.scrollIntoViewIfNeeded(); await entry.screenshot({ path: `${folder}/desktop-form.png` });
  await entry.getByRole('button', { name: 'Record observation', exact: true }).click();
  await entry.getByText('Observation recorded.', { exact: false }).waitFor();
  await page.getByText('Recorded plan:', { exact: false }).filter({ hasText: '$55.00' }).waitFor();
  assert.equal(ledger.size, 2, 'invoice does not sum into commitment; full provider allocation stays 25 USD');

  await entry.getByRole('button', { name: 'Record another observation', exact: true }).click();
  await entry.getByRole('combobox', { name: 'Measure', exact: true }).selectOption('metric');
  await entry.getByLabel('Evidence reference', { exact: true }).fill('report:allocation-2026-10');
  loseNext = true;
  await entry.getByRole('button', { name: 'Record observation', exact: true }).click();
  await entry.getByRole('alert').getByText('The observation was not confirmed.', { exact: false }).waitFor();
  const unknown = calls.at(-1); assert.equal(unknown.amount_microusd, null); assert.equal(unknown.complete, false);
  await page.reload(); await page.getByRole('heading', { name: 'Spending', exact: true }).waitFor();
  await entry.getByText('Re-enter the same fields to retry an entry after a reload.', { exact: false }).waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  await fill('metric', '', 'report:allocation-2026-10');
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'No page overflow at phone width');
  await entry.screenshot({ path: `${folder}/phone-form.png` });
  await page.emulateMedia({ colorScheme: 'dark' }); await entry.screenshot({ path: `${folder}/phone-dark.png` });
  await entry.getByRole('button', { name: 'Record observation', exact: true }).click();
  await entry.getByText('Already recorded; no duplicate was added.', { exact: false }).waitFor();
  assert.deepEqual(calls.at(-1), unknown, 'reload retries original timestamp and UUID, not a new entry');
  assert.equal(ledger.size, 3);
  await entry.getByRole('button', { name: 'Record another observation', exact: true }).click();
  await entry.getByLabel('Evidence reference', { exact: true }).focus(); await page.keyboard.press('Escape');
  assert.equal(await entry.locator('form').count(), 0);
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Add observation');
  assert.deepEqual(errors, []);
  await writeFile(`${folder}/summary.json`, JSON.stringify({ mode: 'loopback synthetic fixture', requests: calls.length,
    appended: ledger.size, duplicate_rows: 0, scenarios: ['invoice separate from planning total', 'commitment replaces component total',
      'lost ack exact retry', 'reload retains identity without evidence persistence', 'unknown versus zero', 'keyboard close and focus', 'phone light/dark'],
    hosted_mfa_tested: false, hosted_writes: 0, page_errors: errors }, null, 2));
  console.log('PASS spending entry: exact retries and reload, separate invoice/commitment accounting, unknown amount, bounded private-free retry metadata, desktop/phone/dark and keyboard');
} finally { await browser.close(); }
