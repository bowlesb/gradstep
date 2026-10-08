import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';
import { fixtureOrigin as FIXTURE } from './environment';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toHaveAttribute('aria-rowcount', '4000');
  await expect(page.getByTestId('paper-row')).toHaveCount(3999); // complete native Find is the default
}
async function windowed(page: Page, allColumns = false) {
  await page.getByRole('button', { name: 'Columns', exact: true }).click();
  const chooser = page.getByRole('dialog', { name: 'Library columns' });
  if (allColumns) for (const name of ['Authors', 'Year', 'Tags', 'Added', 'Opened', 'Progress']) await chooser.getByRole('checkbox', { name, exact: true }).check();
  await chooser.getByRole('checkbox', { name: 'Show rows as you scroll', exact: true }).check();
  await chooser.getByRole('button', { name: 'Done', exact: true }).click();
  await expect.poll(() => page.getByTestId('paper-row').count()).toBeLessThan(80);
}
const table = (page: Page) => page.getByRole('region', { name: 'Library table' });
const anchor = (page: Page) => table(page).evaluate(element => {
  const edge = element.getBoundingClientRect().top + element.querySelector('thead')!.getBoundingClientRect().height;
  const row = [...element.querySelectorAll<HTMLElement>('[data-row-key]')].find(row => row.getBoundingClientRect().bottom > edge + 1);
  return { key: row?.dataset.rowKey, inset: row ? edge - row.getBoundingClientRect().top : 0, left: element.scrollLeft, top: element.scrollTop };
});
async function sameAnchor(page: Page, saved: Awaited<ReturnType<typeof anchor>>) {
  await expect.poll(async () => (await anchor(page)).key).toBe(saved.key);
  await expect.poll(async () => Math.abs((await anchor(page)).inset - saved.inset)).toBeLessThan(3);
}
async function deep(page: Page) {
  await table(page).evaluate(element => { element.dispatchEvent(new WheelEvent('wheel')); element.scrollTop = 30_017; element.scrollLeft = 90; });
  await expect.poll(async () => (await anchor(page)).top).toBeGreaterThan(29_000);
}
const refresh = (page: Page) => page.evaluate(() => dispatchEvent(new Event('focus')));

test.beforeEach(async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Safari durable-key acceptance is separate.');
  await request.post(`${FIXTURE}/__reset`); await request.post(`${FIXTURE}/__large-library`, { data: { count: 4000 } });
});

test('opt-in keyboard traversal reaches unmounted rows and reader return keeps its anchor and mode', async ({ page }) => {
  const errors: string[] = []; page.on('pageerror', error => errors.push(String(error)));
  await signIn(page); await windowed(page);
  const rows = page.getByTestId('paper-row');
  await rows.getByRole('link').first().focus(); await page.keyboard.press('End');
  await expect(page.locator('[aria-rowindex="4000"] a.title')).toBeFocused();
  await expect(page.locator('[aria-rowindex="4000"] a.title')).toBeInViewport();
  await page.keyboard.press('PageUp'); await expect(page.locator('a.title:focus')).toBeInViewport();
  const selected = await page.locator('a.title:focus').getAttribute('href'), saved = await anchor(page);
  await page.keyboard.press('Enter'); await expect(page).toHaveURL(new RegExp(`${selected}$`));
  await expect(page.getByTestId('contents')).toBeEnabled(); await page.getByTestId('back-to-library').click();
  await sameAnchor(page, saved); await expect(page.locator(`a.title[href="${selected}"]`)).toBeFocused();
  await expect.poll(() => rows.count()).toBeLessThan(80);
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: test.info().outputPath('windowed-dark.png') });
  await page.keyboard.press('Home'); await expect(rows.getByRole('link').first()).toBeFocused(); await expect(rows.getByRole('link').first()).toBeInViewport();
  await page.getByRole('button', { name: 'Columns', exact: true }).click();
  await page.screenshot({ path: test.info().outputPath('windowing-choice-dark.png') });
  await page.keyboard.press('Escape');
  expect(errors).toEqual([]);
});

test('Tab expands actual rows without replacing a distant focused node or skipping adjacent controls', async ({ page }) => {
  await signIn(page); await windowed(page, true);
  const title = page.getByTestId('paper-row').getByRole('link').first(), href = await title.getAttribute('href');
  await title.focus(); await title.evaluate(node => { (window as any).__focusedLibraryLink = node; }); await deep(page);
  await expect(page.locator(`a.title[href="${href}"]`)).toBeFocused();
  await expect.poll(() => page.getByTestId('paper-row').count()).toBeLessThan(80);
  await page.keyboard.press('Tab'); await expect(page.getByTestId('paper-row')).toHaveCount(3999);
  expect(await page.evaluate(() => document.activeElement?.closest('tr') === (window as any).__focusedLibraryLink.closest('tr'))).toBe(true);
  await page.keyboard.press('Shift+Tab'); await expect(page.locator(`a.title[href="${href}"]`)).toBeFocused();
  expect(await page.evaluate(() => document.activeElement === (window as any).__focusedLibraryLink)).toBe(true);
  await page.keyboard.press('Enter'); await expect(page.getByTestId('contents')).toBeEnabled(); await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('paper-row')).toHaveCount(3999);
});

test('native text selection and keyboard Find expand real rows while preserving selection nodes', async ({ page }) => {
  await signIn(page); await windowed(page); await deep(page);
  const saved = await anchor(page);
  await page.locator(`[data-row-key="${saved.key}"] a.title`).evaluate(link => {
    const text = link.firstChild!; (window as any).__selectionText = text;
    const range = document.createRange(); range.setStart(text, 0); range.setEnd(text, 12);
    const selection = getSelection()!; selection.removeAllRanges(); selection.addRange(range);
  });
  await expect(page.getByTestId('paper-row')).toHaveCount(3999);
  expect(await page.evaluate(() => ({ same: getSelection()?.anchorNode === (window as any).__selectionText, text: getSelection()?.toString() })))
    .toEqual({ same: true, text: 'Research pap' });
  await sameAnchor(page, saved); await page.evaluate(() => getSelection()?.removeAllRanges()); await windowed(page);
  await page.getByTestId('search').focus(); await page.keyboard.press('ControlOrMeta+f');
  await expect(page.getByTestId('paper-row')).toHaveCount(3999); await page.keyboard.press('Escape');
});

test('stable key and inset survive width, columns, large text and reader-return layout changes', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await signIn(page); await windowed(page, true); await deep(page);
  let saved = await anchor(page); const original = page.viewportSize()!;
  await page.setViewportSize({ width: original.width < 700 ? 850 : 390, height: original.height }); await sameAnchor(page, saved);
  await page.getByRole('button', { name: 'Columns', exact: true }).click();
  const chooser = page.getByRole('dialog', { name: 'Library columns' });
  await chooser.getByRole('checkbox', { name: 'Authors', exact: true }).uncheck(); await chooser.getByRole('checkbox', { name: 'Tags', exact: true }).uncheck();
  await chooser.getByRole('button', { name: 'Done', exact: true }).click(); await sameAnchor(page, saved);
  await page.addStyleTag({ content: '.papers td, .papers .title, .papers th .sort { font-size: 20px !important; }' }); await sameAnchor(page, saved);
  saved = await anchor(page); const title = page.locator(`[data-row-key="${saved.key}"] a.title`), href = await title.getAttribute('href');
  // Focus without Playwright's click auto-scroll: the partially visible anchor is deliberately kept.
  await title.evaluate(element => element.focus({ preventScroll: true }));
  saved = await anchor(page); await page.keyboard.press('Enter');
  await expect(page.getByTestId('contents')).toBeEnabled(); await page.setViewportSize(original);
  await page.getByTestId('back-to-library').click(); await sameAnchor(page, saved); await expect(page.locator(`a.title[href="${href}"]`)).toBeInViewport();
});

test('live tag reorder keeps the same row and a removed focused row gets a keyboard landing place', async ({ page, request }) => {
  await signIn(page);
  await page.getByRole('button', { name: 'Columns', exact: true }).click();
  await page.getByRole('dialog', { name: 'Library columns' }).getByRole('checkbox', { name: 'Tags', exact: true }).check();
  await page.getByRole('dialog', { name: 'Library columns' }).getByRole('button', { name: 'Done', exact: true }).click();
  await page.getByRole('button', { name: 'Tags', exact: true }).click();
  const key = 'item:aaaaaaaa-0000-4000-8000-000000000001', row = page.locator(`[data-row-key="${key}"]`);
  await row.locator('a.title').focus();
  await windowed(page, true);
  await row.locator('a.title').focus();
  await table(page).evaluate((element, key) => {
    const row = element.querySelector<HTMLElement>(`[data-row-key="${key}"]`)!;
    element.dispatchEvent(new WheelEvent('wheel'));
    element.scrollTop += row.getBoundingClientRect().top - element.getBoundingClientRect().top - element.querySelector('thead')!.getBoundingClientRect().height + 7;
  }, key);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const saved = await anchor(page); expect(saved.key).toBe(key);
  await request.post(`${FIXTURE}/__paper-tags`, { data: { tags: ['Representation learning', 'Live reorder'] } }); await refresh(page);
  await expect(row).toContainText('Live reorder'); await sameAnchor(page, saved); await expect(row.locator('a.title')).toBeFocused();
  // A valid removal delivered through the existing v3 response shape, without another fixture API.
  await page.route('**/rpc/v3_library_changes', async route => {
    const response = await route.fetch(), payload = await response.json();
    for (const change of payload.changes ?? []) for (const entry of change.entries ?? []) if (`${entry.kind}:${entry.id}` === key) {
      entry.visible = false; entry.membership_revision++; entry.last_remove_seq = change.seq;
    }
    await route.fulfill({ response, json: payload });
  });
  await request.post(`${FIXTURE}/__paper-tags`, { data: { tags: ['Removal delivery'] } }); await refresh(page);
  await expect(row).toHaveCount(0); await expect(table(page)).toBeFocused();
  await expect(page.getByTestId('library-table')).toHaveAttribute('aria-rowcount', '3999');
  await expect.poll(() => page.getByTestId('paper-row').count()).toBeLessThan(80);
});

test('print expansion and cancellation restore deep anchor, horizontal position and focus', async ({ page }) => {
  await signIn(page); await windowed(page, true); await deep(page);
  const saved = await anchor(page), title = page.locator(`[data-row-key="${saved.key}"] a.title`);
  await title.focus(); const focused = await title.getAttribute('href'), beforePrint = await anchor(page);
  await page.evaluate(() => dispatchEvent(new Event('beforeprint'))); await page.emulateMedia({ media: 'print' });
  await expect(page.getByTestId('paper-row')).toHaveCount(3999);
  expect(await table(page).evaluate(element => getComputedStyle(element).overflow)).toBe('visible');
  expect(await table(page).evaluate(element => element.clientHeight)).toBeGreaterThan(100_000);
  await page.emulateMedia({ media: 'screen' }); await page.evaluate(() => dispatchEvent(new Event('afterprint')));
  await expect.poll(() => page.getByTestId('paper-row').count()).toBeLessThan(80); await sameAnchor(page, beforePrint);
  expect(Math.abs((await anchor(page)).left - beforePrint.left)).toBeLessThan(2); await expect(page.locator(`a.title[href="${focused}"]`)).toBeFocused();
});

test('a portaled row menu retains its owner only while focus belongs to that menu', async ({ page }) => {
  await signIn(page); await windowed(page);
  const title = page.getByTestId('paper-row').getByRole('link').first(), key = await title.locator('..').locator('..').getAttribute('data-row-key');
  await title.focus();
  await page.evaluate(key => {
    const portal = document.createElement('div'); portal.dataset.libraryRowOwner = key!; portal.id = 'test-row-portal';
    portal.style.cssText = 'position:fixed;top:0;right:0;z-index:99';
    const button = document.createElement('button'); button.textContent = 'Test row menu'; portal.append(button); document.body.append(portal); button.focus();
  }, key);
  await deep(page);
  await expect(page.getByRole('button', { name: 'Test row menu', exact: true })).toBeFocused();
  await expect(page.locator(`[data-row-key="${key}"]`)).toHaveCount(1);
  await page.getByTestId('search').focus();
  await page.evaluate(() => document.getElementById('test-row-portal')?.remove());
  await expect(page.locator(`[data-row-key="${key}"]`)).toHaveCount(0);
});
