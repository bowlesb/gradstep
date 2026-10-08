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
  const open = async reference => page.getByRole('button', { name: 'View attempts ' + reference.repeat(8) }).click();
  const ledger = page.getByRole('region', { name: 'Account transaction ledger' });
  const transaction = (environment, id) => ledger.getByRole('article', { name: `Transaction ${environment} ${id}`, exact: true });
  const firstPage = async () => transaction('Sandbox', '91006').waitFor();
  const balances = async (environment, id, expected) => assert.deepEqual(
    await transaction(environment, id).locator('.purchase-balances dd').allTextContents(), expected);
  // Fixture requests last at most 750 ms. Let older promises actually complete
  // before asserting that their stale data cannot replace the current view.
  const completeDelayed = () => page.waitForTimeout(900);
  await visit();
  assert.equal(await page.getByRole('cell', { name: 'Credits pending', exact: true }).count(), 1);
  assert.equal(await page.getByRole('cell', { name: 'Interrupted · unconfirmed', exact: true }).count(), 1);
  await open('38');
  await page.getByRole('region', { name: 'Verification attempts' }).getByRole('table').waitFor();
  assert.equal(await page.getByRole('region', { name: 'Verification attempts' }).locator('tbody tr').count(), 3);
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Attempts', 'opening details announces and focuses them');
  await firstPage();
  assert.equal(await ledger.getByRole('article').count(), 3);
  await balances('Sandbox', '91006', ['0', '0', '0']);
  await balances('Sandbox', '91005', ['200', '140', '20']);
  await balances('Production', '91004', ['400', '0', '40']);
  await transaction('Sandbox', '91006').getByText('Account and Apple identity allowances exhausted').waitFor();
  await transaction('Sandbox', '91005').getByText('Requested 400 · Granted 200', { exact: false }).waitFor();
  await transaction('Production', '91004').getByText('Reserved credits remain held for work already in progress.').waitFor();
  await page.screenshot({ path: '.artifacts/purchase-admin-desktop.png', fullPage: true });
  await ledger.screenshot({ path: '.artifacts/purchase-ledger-desktop.png' });
  await ledger.getByRole('button', { name: 'Older transactions' }).click();
  await transaction('Production', '91003').waitFor();
  assert.equal(await ledger.getByRole('article').count(), 3, 'only one bounded page is retained');
  await balances('Production', '91003', ['800', '0', '20']);
  await transaction('Production', '91003').getByText('Credits expired', { exact: true }).waitFor();
  await transaction('Production', '91002').getByText('Fully spent', { exact: true }).waitFor();
  await transaction('Sandbox', '91001').getByText('No recorded Sandbox allowance decision.').waitFor();
  assert.equal(await transaction('Sandbox', '91001').getByText('exhausted', { exact: false }).count(), 0, 'missing decision never implies allowance exhaustion');
  await ledger.getByRole('button', { name: 'Newest transactions' }).click();
  await firstPage();
  await page.getByRole('button', { name: 'Close details' }).click();
  assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('aria-label')), 'View attempts ' + '38'.repeat(8));
  await page.getByLabel('Support code', { exact: true }).fill('40'.repeat(8));
  await page.getByRole('button', { name: 'Find', exact: true }).click();
  await page.getByRole('cell', { name: 'Not accepted', exact: true }).waitFor();
  assert.equal(await page.getByLabel('Purchase status').inputValue(), 'all', 'support lookup searches all outcomes');
  assert.equal(await page.locator('tbody tr').count(), 1);
  await page.getByRole('button', { name: 'Clear', exact: true }).click();
  await page.getByLabel('Purchase status').selectOption('confirmed');
  assert.equal(await page.getByRole('cell', { name: 'Receipt recorded', exact: true }).count(), 2);
  assert.equal(await page.getByText('Confirmed', { exact: true }).count(), 0);
  await page.getByText('These counts are not sales or credit grants', { exact: false }).waitFor();
  await open('41');
  await firstPage();
  await ledger.getByText('Account-wide records, not a match to this submission.', { exact: false }).waitFor();
  await transaction('Sandbox', '91006').getByText('Transaction details', { exact: true }).click();
  await transaction('Sandbox', '91006').getByText('Transaction ID', { exact: true }).waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'narrow screen has no page overflow');
  await page.screenshot({ path: '.artifacts/purchase-admin-narrow.png', fullPage: true });
  await ledger.screenshot({ path: '.artifacts/purchase-ledger-narrow.png' });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: '.artifacts/purchase-admin-dark.png', fullPage: true });
  await ledger.screenshot({ path: '.artifacts/purchase-ledger-dark.png' });
  await page.setViewportSize({ width: 1280, height: 900 });
  for (const state of ['ledger_empty', 'ledger_error', 'ledger_wrong_account', 'ledger_retry']) {
    await visit(state); await open('38');
    if (state === 'ledger_empty') {
      await ledger.getByText('No recorded transactions for this account.').waitFor();
      assert.equal(await ledger.getByRole('button', { name: 'Older transactions' }).count(), 0);
    } else {
      await ledger.getByRole('alert').getByText('Account transactions could not load. Try again.').waitFor();
      assert.equal(await ledger.getByRole('article').count(), 0, 'failure never displays another account or stale grants');
      if (state === 'ledger_retry') { await ledger.getByRole('button', { name: 'Retry transactions' }).click(); await firstPage(); }
    }
    assert.equal(await page.getByRole('region', { name: 'Verification attempts' }).locator('tbody tr').count(), 3, 'ledger failure is independent of attempt history');
  }
  await visit('ledger_race');
  await page.getByLabel('Purchase status').selectOption('all');
  await open('38');
  await ledger.getByText('Loading account transactions…').waitFor();
  await open('42');
  await transaction('Production', '92001').waitFor();
  await completeDelayed();
  assert.equal(await ledger.getByRole('article').count(), 1);
  assert.equal(await transaction('Sandbox', '91006').count(), 0, 'old account completion cannot replace the selected account');
  await visit('older_race');
  await open('38'); await firstPage();
  await ledger.getByRole('button', { name: 'Older transactions' }).click();
  await ledger.getByText('Loading account transactions…').waitFor();
  await open('39');
  await firstPage();
  await completeDelayed();
  assert.equal(await transaction('Production', '91003').count(), 0, 'a new submission resets pagination and fences the previous read even for the same account');
  await visit('ledger_race');
  await open('38');
  await ledger.getByText('Loading account transactions…').waitFor();
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await ledger.waitFor({ state: 'hidden' });
  await completeDelayed();
  assert.equal(await ledger.count(), 0, 'Refresh clears selected detail and ignores an earlier read');
  await visit('older_race');
  await open('38'); await firstPage();
  await ledger.getByRole('button', { name: 'Older transactions' }).click();
  await ledger.getByText('Loading account transactions…').waitFor();
  await ledger.getByRole('button', { name: 'Newest transactions' }).click();
  await firstPage(); await completeDelayed();
  assert.equal(await transaction('Production', '91003').count(), 0, 'an older page completion cannot replace the newest page');
  await visit('empty');
  await page.getByText('No matching purchase submissions.', { exact: true }).waitFor();
  await visit('error');
  await page.getByRole('alert').getByText('Purchase diagnostics could not load. Try Refresh.').waitFor();
  await visit('cleanup');
  await page.getByRole('alert').getByText('Observation cleanup is not ready.', { exact: false }).waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS purchase admin: receipt semantics, account ledger grant/reserved/spendable states, partial/zero Sandbox grants, older pages, empty/error/retry, account/submission/Refresh/page races, attempt history, support lookup, narrow/dark and cleanup readiness');
} finally { await browser.close(); }
