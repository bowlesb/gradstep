// Admin › Spend vs income with synthetic data only (docs/RUNBOOK_SPENDING.md). Start npm run dev:admin -- --port 5188.
// Checks the headline figures, the funding split, a switch's dry-run preview, the two-step confirm and its reversal,
// the pool form's validation, keyboard reach, and desktop/phone light/dark screenshots in .artifacts/spend-income/.
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const base = new URL(process.env.SPEND_INCOME_PREVIEW ?? 'http://127.0.0.1:5188');
if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1') throw Error('Loopback preview required');
const folder = '.artifacts/spend-income';
await mkdir(folder, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  for (const scheme of ['light', 'dark']) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, colorScheme: scheme });
    await context.route('**/*', route => new URL(route.request().url()).origin === base.origin ? route.continue() : route.abort());
    const page = await context.newPage(), errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(new URL('/?fixture=spend-income', base).href);
    await page.getByRole('heading', { name: /AI spend vs App Store income/ }).waitFor();
    const metrics = await page.locator('.metrics').innerText();
    assert.match(metrics, /AI spend this month[\s\S]*\$24\.18/);
    assert.match(metrics, /Estimated proceeds[\s\S]*\$93\.39/);
    assert.match(metrics, /Spend ÷ proceeds[\s\S]*0\.26×/);
    assert.match(await page.getByRole('table', { name: 'By who pays' }).innerText(), /Free AI[\s\S]*\$4\.35/);
    assert.match(await page.getByRole('table', { name: 'Income by product (Production)' }).innerText(), /Plus monthly\s+7\s+\$47\.93\s+1 · \$7\.99/);
    await page.getByText('Not emailed (no address or key)').waitFor();
    if (scheme === 'light') {
      // Preview, then a two-step confirm, then undo.
      const row = page.getByRole('listitem', { name: 'Pause podcast generation' });
      await row.getByRole('button', { name: 'Preview' }).click();
      await row.getByText('Last 7 days: 12 requests from 7 accounts (6 paying), $3.80 (41% of AI spend).').waitFor();
      const go = row.getByRole('button', { name: 'Pause podcasts' });
      assert.equal(await go.isDisabled(), true, 'a reason is required');
      await row.getByLabel('Reason').fill('Podcast spend spiked');
      await go.click();
      await row.getByRole('button', { name: 'Confirm: Pause podcasts' }).click();
      await row.getByText('On', { exact: true }).waitFor();
      await row.getByLabel('Reason').fill('Back to normal');
      await row.getByRole('button', { name: 'Resume podcasts' }).click();
      await row.getByRole('button', { name: 'Confirm: Resume podcasts' }).click();
      await row.getByText('Off', { exact: true }).waitFor();
      // The pool form refuses more than $50.
      const pool = page.getByRole('region', { name: 'Free AI pool' });
      await pool.getByLabel('New pool, US$').fill('60');
      await pool.getByLabel('Reason').fill('Too much');
      assert.equal(await pool.getByRole('button', { name: 'Set pool' }).isDisabled(), true);
      await pool.getByLabel('New pool, US$').fill('20');
      await pool.getByRole('button', { name: 'Set pool' }).click();
      await pool.getByText('$20.00', { exact: true }).waitFor();
      // Keyboard: the first switch's Preview is reachable by Tab.
      await page.getByRole('listitem', { name: 'Pause free AI' }).getByRole('button', { name: 'Preview' }).focus();
      assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Preview');
    }
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: `${folder}/desktop-${scheme}.png`, fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), true, 'no sideways page scroll at phone width');
    await page.screenshot({ path: `${folder}/phone-${scheme}.png`, fullPage: true });
    await page.goto(new URL('/?fixture=spend-income&state=over', base).href);
    await page.getByText('Spend is above 0.6× proceeds', { exact: false }).waitFor();
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.screenshot({ path: `${folder}/over-${scheme}.png`, fullPage: true });
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log('PASS spend vs income: figures, funding split, preview, confirm and undo, pool validation, keyboard, phone width, light/dark');
} finally { await browser.close(); }
