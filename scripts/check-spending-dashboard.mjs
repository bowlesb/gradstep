// Owner spending investigation with synthetic data only. Start npm run dev:admin -- --port 5187.
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const base = new URL(process.env.SPENDING_PREVIEW ?? 'http://127.0.0.1:5187');
if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1') throw Error('Loopback preview required');
const folder = '.artifacts/spending-dashboard';
await mkdir(folder, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.route('**/*', route => new URL(route.request().url()).origin === base.origin ? route.continue() : route.abort());
  const page = await context.newPage(), errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const visit = async state => {
    await page.goto(new URL('/?fixture=spending' + (state ? '&state=' + state : ''), base).href);
    await page.getByRole('heading', { name: 'Spending', exact: true }).waitFor();
    await page.getByText('Loading spending…').waitFor({ state: 'hidden' });
  };
  await visit();
  await page.getByRole('heading', { name: 'Provider attempts', exact: true }).waitFor();
  assert.match(await page.locator('.metrics').innerText(), /Reported provider cost[\s\S]*\$0.139/);
  assert.match(await page.locator('.metrics').innerText(), /Unresolved liability[\s\S]*\$0.25/);
  await page.getByText('Forecast incomplete:', { exact: false }).waitFor();
  await page.getByRole('button', { name: 'Load more operations', exact: true }).click();
  await page.getByRole('button', { name: 'metadata · 34000003', exact: true }).waitFor();
  await page.getByRole('button', { name: 'chat · 34000001', exact: true }).click();
  const detail = page.getByRole('region', { name: 'Operation details', exact: true });
  await detail.getByText('Customer debit: 0 credits.', { exact: false }).waitFor();
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Operation details');
  await detail.locator('.attempt-detail > summary').click();
  await detail.getByText('Recorded pricing', { exact: true }).click();
  await detail.getByRole('button', { name: 'Load older records', exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll('.financial-record').length === 2);
  await detail.getByRole('button', { name: 'Customer credits (2)', exact: true }).click();
  await detail.locator('.financial-record > summary').click();
  await detail.getByText('"credits": 50', { exact: false }).waitFor();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: `${folder}/desktop.png`, fullPage: true });
  await detail.getByRole('button', { name: 'Close details', exact: true }).click();
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'chat · 34000001');

  await page.getByLabel('Unresolved only, all dates', { exact: true }).check();
  await page.getByRole('button', { name: 'metadata · 34000004', exact: true }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'ocr · 34000002', exact: true }).count(), 0);
  await page.getByLabel('Account ID', { exact: true }).fill('not-an-id');
  await page.getByRole('button', { name: 'Apply filter', exact: true }).click();
  await page.getByRole('alert').getByText('Enter a complete account ID.', { exact: false }).waitFor();
  // The first account is deliberately slower: its delayed summary must not replace the second account.
  await page.getByLabel('Account ID', { exact: true }).fill('11000000-0000-4000-8000-000000000001');
  await page.getByRole('button', { name: 'Apply filter', exact: true }).click();
  await page.getByLabel('Account ID', { exact: true }).fill('22000000-0000-4000-8000-000000000002');
  await page.getByRole('button', { name: 'Apply filter', exact: true }).click();
  await page.getByRole('button', { name: 'ocr · 34000002', exact: true }).waitFor();
  await page.waitForTimeout(600);
  assert.equal(await page.locator('.metric').filter({ has: page.getByText('Customer credits used', { exact: true }) }).locator('strong').innerText(), '22');
  assert.equal(await page.getByRole('button', { name: 'chat · 34000001', exact: true }).count(), 0);
  assert.equal(await page.getByRole('alert').count(), 0);
  await page.getByRole('button', { name: 'Clear account', exact: true }).click();
  await page.getByRole('button', { name: 'chat · 34000001', exact: true }).waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => window.scrollTo(0, 0));
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'No page overflow at phone width');
  await page.screenshot({ path: `${folder}/narrow.png`, fullPage: true });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.screenshot({ path: `${folder}/dark.png`, fullPage: true });
  await visit('empty');
  await page.getByText('No matching operations.', { exact: true }).waitFor();
  await page.getByText('No tracked provider attempts in this period.', { exact: true }).waitFor();
  await visit('error');
  await page.getByRole('alert').getByText('Spending records could not be loaded.', { exact: false }).waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS spending dashboard: separate costs/holds/refunds, operation and history paging, old unresolved units, keyboard focus, account race, narrow/dark and empty/error states');
} finally { await browser.close(); }
