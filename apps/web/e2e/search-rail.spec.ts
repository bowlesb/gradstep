// Search beside the reading view (owner, 2026-10-22: "the search bar should probably be on the left … in the same area as
// the list of articles would be", like Mail): off the Library route, search is a mode of the left panel. A result opens in
// the middle and the list stays; Esc twice puts the panel back exactly as it was (reader audit R1/R2). Also the Library
// and Feed "…" (S10/S16), Settings (S9) and the account menu, captured light and dark.
import { readFileSync } from 'node:fs';
import { type Page, expect, test } from '@playwright/test';
import { openSettings, signInReader } from './device-reader-helpers';
import { durableKeys } from './key-capability';

const SHOTS = process.env.APPROVED_SHOTS ?? '../../.artifacts/ux-audit-20261022/approved';
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png` });
const html = readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html', import.meta.url));
const raster = readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg', import.meta.url));

test.beforeEach(async ({ page }) => {
  // The added paper reads from the fixture's arXiv HTML; legacy fixture papers read their bundle (nothing reaches arXiv).
  await page.route('https://arxiv.org/**', async route => {
    const url = route.request().url();
    if (/\/html\/2604\.01001v7$/.test(url)) await route.fulfill({ status: 200, contentType: 'text/html', headers: { 'access-control-allow-origin': '*' }, body: html });
    else if (/\/html\/2604\.01001v7\/figure\.jpg$/.test(url)) await route.fulfill({ status: 200, contentType: 'image/jpeg', headers: { 'access-control-allow-origin': '*' }, body: raster });
    else await route.abort();
  });
});

const openDPO = async (page: Page) => {
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toContainText('Direct Preference Optimization');
};

test('paper open → / → type → the list in the left panel → a result opens in the middle, the list stays → Esc twice → Contents back', async ({ page, request }, info) => {
  test.skip(!['desktop', 'phone', 'tablet', 'tablet-large'].includes(info.project.name), 'Chromium widths.');
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  const errors: string[] = []; page.on('pageerror', e => errors.push(String(e)));
  await signInReader(page, request);
  await openDPO(page);
  const dpoURL = page.url();
  const sideTabs = page.getByRole('tablist', { name: 'Side panel' });
  const before = { open: await page.getByTestId('pane-left').count(), contents: await sideTabs.getByRole('tab', { name: 'Contents' }).getAttribute('aria-selected').catch(() => null) };

  // / opens search in the left panel (a drawer on a phone), focused in its own field.
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press('/');
  const rail = page.getByTestId('search-rail'), field = page.getByTestId('rail-search');
  await expect(rail).toBeVisible();
  await expect(field).toBeFocused();
  const inline = (await page.locator('[data-testid=pane-left].overlay').count()) === 0; // beside the paper, or a drawer over it
  await expect(rail.getByTestId('search-scope-library')).toHaveAttribute('aria-pressed', 'true');
  await page.keyboard.type('preference');
  const results = rail.getByTestId('search-result');
  await expect(results.first()).toContainText('Direct Preference Optimization');
  await expect(results.first()).toHaveAttribute('aria-current', 'page'); // the paper open in the middle
  await expect(page).toHaveURL(dpoURL);

  // ML papers in the same list: Add, then the row opens its paper.
  await rail.getByTestId('search-scope-arxiv').click();
  await field.fill('sparse attention'); await field.press('Enter');
  const ml = rail.getByTestId('search-ml-result');
  await expect(ml).toHaveCount(2);
  const sparse = ml.filter({ hasText: 'Scaling sparse attention' });
  await sparse.getByRole('button', { name: '+ Add' }).click();
  await expect(sparse.getByTestId('feed-open')).toHaveText('✓ In library', { timeout: 15_000 });

  // Back to the library list: the new paper is a result; it opens in the middle and (beside the paper) the list stays.
  await rail.getByTestId('search-scope-library').click();
  await field.fill('2604.01001');
  await expect(results).toHaveCount(1);
  await results.first().click();
  await expect(page).toHaveURL(/\/paper\/[0-9a-f-]{36}$/);
  expect(page.url()).not.toBe(dpoURL);
  if (inline) {
    await expect(rail).toBeVisible();
    await expect(results.first()).toHaveAttribute('aria-current', 'page');
    await shot(page, 'search-list-beside-paper');
    // Esc clears the words, a second Esc ends search: the panel is back as it was.
    await field.press('Escape');
    await expect(field).toHaveValue('');
    await field.press('Escape');
  } else {
    // A drawer closes on opening, and search ends with it.
    await expect(rail).toHaveCount(0);
  }
  await expect(rail).toHaveCount(0);
  expect(await page.getByTestId('pane-left').count()).toBe(before.open);
  if (before.open) await expect(sideTabs.getByRole('tab', { name: 'Contents' })).toHaveAttribute('aria-selected', 'true');
  expect(errors).toEqual([]);
});

test('the top-bar field opens the list; ✕ closes it; the panel closed before stays closed', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop', 'One width is enough.');
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signInReader(page, request);
  await openDPO(page);
  await page.getByRole('button', { name: 'Hide side panel' }).click();
  await expect(page.getByTestId('pane-left')).toHaveCount(0);
  await page.getByTestId('search').click();
  await expect(page.getByTestId('rail-search')).toBeFocused();
  await expect(page.getByTestId('pane-left')).toHaveCount(1);
  await page.keyboard.type('zzz');
  await expect(page.getByTestId('rail-search-empty')).toContainText('No papers in your library match “zzz”.');
  await page.getByTestId('rail-search-close').click();
  await expect(page.getByTestId('pane-left')).toHaveCount(0);
  // From the Feed, a result opens its paper beside the list.
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('search').click();
  await page.getByTestId('rail-search').fill('direct');
  await page.getByTestId('search-result').first().click();
  await expect(page).toHaveURL(/\/paper\//);
  await expect(page.getByTestId('search-rail')).toBeVisible();
});

test('reading mode: / leaves it and opens search (R5)', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop', 'One width is enough.');
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signInReader(page, request);
  await openDPO(page);
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press('f');
  await expect(page.locator('.app.reading')).toHaveCount(1);
  await page.keyboard.press('/');
  await expect(page.locator('.app.reading')).toHaveCount(0);
  await expect(page.getByTestId('rail-search')).toBeFocused();
});

test('screens: the search list, the Library and Feed "…", Settings and the account menu (light and dark)', async ({ page, request }, info) => {
  test.skip(!['desktop', 'phone'].includes(info.project.name), 'Desktop and phone captures.');
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  const errors: string[] = []; page.on('pageerror', e => errors.push(String(e)));
  await signInReader(page, request);
  const field = page.getByTestId('search'), railField = page.getByTestId('rail-search');
  for (const scheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
    await page.getByTestId('back-to-library').click();
    // Library: its own search filters the table; the switch sits in its title row.
    await field.fill('optim');
    await expect(page.getByTestId('search-scope')).toBeVisible();
    await shot(page, `${scheme}-library-search`);
    await field.press('Escape');
    // The Library's "…" and its Sort by submenu.
    await page.getByTestId('library-options').click();
    const menu = page.getByRole('menu', { name: 'Library options' });
    await expect(menu.getByRole('menuitem').first()).toHaveText(/Add paper…/);
    await shot(page, `${scheme}-library-options`);
    await menu.getByTestId('library-sort').click();
    await expect(menu.getByRole('menuitemradio', { name: /Added/ })).toHaveAttribute('aria-checked', 'true');
    await shot(page, `${scheme}-library-options-sort`);
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
    // Paper: the search list beside it, library then ML papers.
    await openDPO(page);
    await field.click();
    await railField.fill('preference');
    await expect(page.getByTestId('search-result').first()).toBeVisible();
    await shot(page, `${scheme}-search-paper`);
    await page.getByTestId('search-scope-arxiv').click();
    await railField.fill('sparse attention'); await railField.press('Enter');
    await expect(page.getByTestId('search-ml-result')).toHaveCount(2);
    await shot(page, `${scheme}-search-paper-ml`);
    await page.getByTestId('rail-search-close').click();
    // Feed: the search list and the Feed's "…".
    await page.getByRole('link', { name: 'Feed' }).first().click();
    await expect(page.getByTestId('feed-grid')).toBeVisible();
    await field.click(); await railField.fill('direct');
    await expect(page.getByTestId('search-result').first()).toBeVisible();
    await shot(page, `${scheme}-search-feed`);
    await page.getByTestId('rail-search-close').click();
    await page.getByTestId('feed-options').click();
    await expect(page.getByRole('menu', { name: 'Feed options' })).toBeVisible();
    await shot(page, `${scheme}-feed-options`);
    await page.keyboard.press('Escape');
    // Snippets keeps its own field in its panel; the top field searches papers.
    await page.getByTestId('nav-notes').first().click();
    await field.click(); await railField.fill('direct');
    await expect(page.getByTestId('search-result').first()).toBeVisible();
    await shot(page, `${scheme}-search-snippets`);
    await page.getByTestId('rail-search-close').click();
    // The account menu and Settings.
    await page.getByTestId('account-menu').click();
    await expect(page.getByRole('menu', { name: 'Account' }).getByRole('menuitem')).toHaveText([/Settings…/, /Keyboard shortcuts/, /Report this screen…/, /Sign out…/]);
    await shot(page, `${scheme}-account-menu`);
    await page.keyboard.press('Escape');
    const settings = await openSettings(page);
    await expect(settings.getByRole('heading', { level: 3 })).toHaveText(['Account', 'AI credits', 'AI options', 'Library', 'Reading', 'Your assets', 'Help and about']);
    await shot(page, `${scheme}-settings`);
    await settings.getByTestId('settings-account').evaluate(e => e.closest('dialog')!.scrollTo(0, 10_000));
    await shot(page, `${scheme}-settings-bottom`);
    await settings.getByTestId('settings-shortcuts-row').click();
    await expect(settings.getByTestId('settings-shortcuts')).toBeVisible();
    await settings.getByTestId('settings-back').click();
    await settings.getByTestId('settings-close').click();
    await expect(settings).toBeHidden();
  }
  expect(errors).toEqual([]);
});
