// Local fixture only, served under production CSP. No provider, key or backend contract changes.
import { type Page, expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

import { fixtureOrigin as FIXTURE } from './environment';
// The apps' columns (B9): Venue, Source, Pages and Chats besides these; Chats is on by default, the other three chosen.
const COLUMNS = ['Device', 'Authors', 'Year', 'Venue', 'Tags', 'Source', 'Pages', 'Added', 'Opened', 'Chats', 'Progress'];
const PHONE_DEFAULTS = ['Device', 'Authors', 'Year', 'Added', 'Opened', 'Chats', 'Progress'], WIDE_DEFAULTS = [...PHONE_DEFAULTS, 'Tags'];
const KEY = 'gradstep.library.columns.v1';
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click();
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
const shot = (page: Page, name: string) => page.screenshot({ path: `../../.artifacts/web-columns/${test.info().project.name}-${name}.png` });
// Read both sides of the overflow invariant in the same frame; the workspace may collapse its rail
// between two awaited reads immediately after crossing the compact breakpoint.
const hasNoPageOverflow = async (page: Page) => expect.poll(() => page.evaluate(() => {
  const center = document.querySelector('.pane-center')!;
  return { page: document.documentElement.scrollWidth, viewport: innerWidth, centerFits: center.scrollWidth <= center.clientWidth };
})).toMatchObject({ page: page.viewportSize()!.width, viewport: page.viewportSize()!.width, centerFits: true });

test.beforeEach(async ({ request }) => { await request.post(`${FIXTURE}/__reset`); });

test('chosen columns persist, scroll within the center and keep titles and keyboard targets visible', async ({ page }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; its refusal is verified separately.');
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(String(error)));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await signIn(page);
  const phone = info.project.name === 'phone';
  const originalViewport = page.viewportSize()!;
  const table = page.getByTestId('library-table'), scroll = page.getByRole('region', { name: 'Library table' });
  const picker = page.getByRole('button', { name: 'Columns', exact: true });
  const dialog = page.getByRole('dialog', { name: 'Library columns' });
  await expect(table.getByRole('columnheader')).toHaveCount(phone ? 8 : 9);
  await hasNoPageOverflow(page);
  await shot(page, 'defaults-light');

  await picker.focus();
  await page.keyboard.press('Enter');
  await expect(dialog.getByRole('checkbox', { name: /Title/ })).toBeDisabled();
  await expect(dialog.getByRole('checkbox', { name: /Title/ })).toBeChecked();
  for (const name of COLUMNS) await dialog.getByRole('checkbox', { name, exact: true }).check();
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
  await expect(picker).toBeFocused();
  await expect(table.getByRole('columnheader')).toHaveCount(12);
  // Chats shows 0 for a paper without chats; Source names arXiv's ID (LibraryMetadata).
  const dpo = table.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
  await expect(dpo.locator('td.col-chats')).toHaveText('0'); await expect(dpo.locator('td.col-source')).toHaveText('2305.18290');
  const pinned = table.locator('tbody .col-title').first();
  const origin = (await pinned.boundingBox())!;
  await expect(page.getByRole('button', { name: 'Scroll columns right' })).toBeEnabled();
  await page.getByRole('button', { name: 'Scroll columns right' }).click();
  expect(await scroll.evaluate(e => e.scrollLeft)).toBeGreaterThan(0);
  await page.getByRole('button', { name: 'Scroll columns left' }).click();
  await expect.poll(() => scroll.evaluate(e => e.scrollLeft)).toBe(0);
  await scroll.focus();
  // To the end with the keyboard (more columns since B9: a phone needs more steps than six).
  for (let i = 0; i < 40 && await scroll.evaluate(e => e.scrollLeft + e.clientWidth < e.scrollWidth - 1); i++) await page.keyboard.press('ArrowRight');
  expect(await scroll.evaluate(e => e.scrollLeft)).toBeGreaterThan(0);
  expect((await pinned.boundingBox())!.x).toBeCloseTo(origin.x, 0);
  const scrollerBox = (await scroll.boundingBox())!;
  const progressBox = (await table.getByRole('columnheader', { name: 'Progress' }).boundingBox())!;
  expect(progressBox.x).toBeGreaterThanOrEqual(origin.x + origin.width - 1);
  expect(progressBox.x + progressBox.width).toBeLessThanOrEqual(scrollerBox.x + scrollerBox.width + 1);
  await hasNoPageOverflow(page);
  await shot(page, 'all-columns-scrolled-light');
  await page.emulateMedia({ colorScheme: 'dark' });
  await shot(page, 'all-columns-scrolled-dark');
  await page.emulateMedia({ colorScheme: 'light' });

  // Tab to a previously obscured header: the pinned title must not cover the focused button.
  await table.getByRole('button', { name: 'Title', exact: true }).focus();
  await page.keyboard.press('Tab');
  const authors = table.getByRole('button', { name: 'Authors', exact: true });
  await expect(authors).toBeFocused();
  expect((await authors.boundingBox())!.x).toBeGreaterThanOrEqual((await pinned.boundingBox())!.x + origin.width - 1);
  await page.keyboard.press('Tab');
  await page.keyboard.press('Enter');
  await expect(table.locator('th.col-year')).toHaveAttribute('aria-sort', 'descending');
  await expect(table.getByTestId('paper-row').first()).toContainText('Direct Preference Optimization');
  await page.keyboard.press('Enter');
  await expect(table.locator('th.col-year')).toHaveAttribute('aria-sort', 'ascending');
  await expect(table.getByTestId('paper-row').first()).toContainText('2401.00001');

  // Width changes never replace explicit choices, including crossing the compact/default boundary.
  await page.setViewportSize({ width: phone ? 850 : 390, height: originalViewport.height });
  await expect(table.getByRole('columnheader')).toHaveCount(12);
  await hasNoPageOverflow(page);
  await page.setViewportSize(originalViewport);
  await picker.click();
  await dialog.getByRole('checkbox', { name: 'Authors', exact: true }).uncheck();
  await dialog.getByRole('checkbox', { name: 'Tags', exact: true }).uncheck();
  for (const name of ['Venue', 'Source', 'Pages']) await dialog.getByRole('checkbox', { name, exact: true }).uncheck();
  await dialog.getByRole('button', { name: 'Done' }).click();
  await page.reload();
  await expect(table.getByRole('columnheader')).toHaveCount(7);
  await expect(table.locator('.col-authors, .col-tags')).toHaveCount(0);
  await expect(table.getByRole('link', { name: /Direct Preference Optimization/ }).locator('..').locator('.author')).toHaveCount(0);
  expect(await page.evaluate(key => JSON.parse(localStorage.getItem(key)!), KEY)).toEqual({ version: 3, columns: ['device', 'year', 'added', 'opened', 'chats', 'progress'] });
  await picker.click();
  for (const name of COLUMNS) await dialog.getByRole('checkbox', { name, exact: true }).uncheck();
  await page.keyboard.press('Escape');
  await expect(table.getByRole('columnheader')).toHaveCount(1);
  // Hiding the progress column cannot hide failure/retry states.
  await expect(table.getByText('Couldn’t download this paper')).toBeVisible();
  await table.getByRole('button', { name: 'Retry', exact: true }).click();
  await expect(table.getByText(/Adding…/).first()).toBeVisible({ timeout: 8_000 }); // two words and a percentage, the apps' "Adding…" (2026-10-15)
  await expect(table.getByRole('link', { name: 'A retried paper' })).toBeVisible({ timeout: 15_000 });
  await picker.click();
  await dialog.getByRole('button', { name: 'Reset', exact: true }).click();
  for (const name of COLUMNS) await expect(dialog.getByRole('checkbox', { name, exact: true })).toBeChecked({ checked: (phone ? PHONE_DEFAULTS : WIDE_DEFAULTS).includes(name) });
  await page.keyboard.press('Escape');
  await expect(picker).toBeFocused();
  await expect(table.getByRole('columnheader')).toHaveCount(phone ? 8 : 9);
  await page.emulateMedia({ colorScheme: 'dark' });
  await shot(page, 'defaults-dark');
  await picker.click();
  await shot(page, 'picker-dark');
  await page.keyboard.press('Escape');
  await page.getByTestId('search').fill('Direct Preference');
  await page.getByTestId('search').press('ArrowDown');
  await expect(table.getByRole('link').first()).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.getByTestId('reader-frame')).toBeVisible();
  await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('search')).toHaveValue('Direct Preference');
  await expect(table.getByRole('columnheader')).toHaveCount(phone ? 8 : 9);
  expect(errors).toEqual([]);
});

test('unavailable preference storage keeps column choices usable for this view', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; its refusal is verified separately.');
  await page.addInitScript(key => {
    const get = Storage.prototype.getItem, set = Storage.prototype.setItem;
    Storage.prototype.getItem = function (name) { if (name === key) throw new DOMException('Unavailable', 'SecurityError'); return get.call(this, name); };
    Storage.prototype.setItem = function (name, value) { if (name === key) throw new DOMException('Full', 'QuotaExceededError'); set.call(this, name, value); };
  }, KEY);
  await signIn(page);
  await page.getByRole('button', { name: 'Columns', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Library columns' });
  for (const name of COLUMNS) await dialog.getByRole('checkbox', { name, exact: true }).check();
  await dialog.getByRole('button', { name: 'Done' }).click();
  await expect(page.getByTestId('library-table').getByRole('columnheader')).toHaveCount(12);
  await hasNoPageOverflow(page);
});
