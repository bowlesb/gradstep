// Development-only owner dashboard journey. Start `npm run dev:admin -- --port 5186` first.
// Uses synthetic fixtures, and refuses hosted URLs. Never contacts Apple or Supabase.
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const base = new URL(process.env.PURCHASE_DIAGNOSTIC_PREVIEW ?? 'http://127.0.0.1:5186');
if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1') throw Error('A loopback fixture preview is required');
await mkdir('.artifacts', { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.route('**/*', route => new URL(route.request().url()).origin === base.origin ? route.continue() : route.abort());
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const visit = async state => {
    await page.goto(new URL('/?fixture=purchases' + (state ? '&state=' + state : ''), base).href);
    await page.getByRole('heading', { name: 'Purchase verification', exact: true }).waitFor();
    await page.getByText('Loading purchase diagnostics…').waitFor({ state: 'hidden' });
  };
  await visit();
  assert.equal(await page.getByRole('cell', { name: 'Credits pending', exact: true }).count(), 1);
  assert.equal(await page.getByRole('cell', { name: 'Interrupted · unconfirmed', exact: true }).count(), 1);
  await page.getByRole('button', { name: 'View attempts ' + '38'.repeat(8) }).click();
  await page.getByRole('region', { name: 'Verification attempts' }).getByRole('table').waitFor();
  assert.equal(await page.getByRole('region', { name: 'Verification attempts' }).locator('tbody tr').count(), 3);
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Attempts', 'opening details announces and focuses them');
  await page.screenshot({ path: '.artifacts/purchase-admin-desktop.png', fullPage: true });
  await page.getByRole('button', { name: 'Close details' }).click();
  assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('aria-label')), 'View attempts ' + '38'.repeat(8));
  await page.getByLabel('Support code', { exact: true }).fill('40'.repeat(8));
  await page.getByRole('button', { name: 'Find', exact: true }).click();
  await page.getByRole('cell', { name: 'Not accepted', exact: true }).waitFor();
  assert.equal(await page.getByLabel('Purchase status').inputValue(), 'all', 'support lookup searches all outcomes');
  assert.equal(await page.locator('tbody tr').count(), 1);
  await page.getByRole('button', { name: 'Clear', exact: true }).click();
  await page.getByLabel('Purchase status').selectOption('refused');
  await page.getByRole('cell', { name: 'Not accepted', exact: true }).waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'narrow screen has no page overflow');
  await page.screenshot({ path: '.artifacts/purchase-admin-narrow.png', fullPage: true });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: '.artifacts/purchase-admin-dark.png', fullPage: true });
  await visit('empty');
  await page.getByText('No matching purchase submissions.', { exact: true }).waitFor();
  await visit('error');
  await page.getByRole('alert').getByText('Purchase diagnostics could not load. Try Refresh.').waitFor();
  await visit('cleanup');
  await page.getByRole('alert').getByText('Observation cleanup is not ready.', { exact: false }).waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS purchase admin: pending/interrupted, attempt history, support lookup across statuses, filter, narrow layout, empty/error and cleanup readiness');
} finally { await browser.close(); }
