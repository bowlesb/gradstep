import { openAddPaper } from './device-reader-helpers';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';
import { fixtureOrigin as FIXTURE } from './environment';

const dialog = (page: Page) => page.getByRole('dialog', { name: 'Catalogs', exact: true });
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
// Catalogs… is a row of the Library's "…" (owner-approved 2026-10-22, audit S10).
async function open(page: Page) { await page.getByTestId('library-options').click(); await page.getByTestId('library-catalogs').click(); await expect(dialog(page)).toBeVisible(); }
test.beforeEach(async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Safari durable-key acceptance is separate.'); await request.post(`${FIXTURE}/__reset`);
});

test('rename, create, default, restart and both move destinations preserve the library', async ({ page }) => {
  await signIn(page); const initial = await page.getByTestId('paper-row').count(); await open(page);
  await dialog(page).getByRole('button', { name: 'Rename Default', exact: true }).click();
  await dialog(page).getByLabel('Catalog name', { exact: true }).fill('Reading'); await dialog(page).getByRole('button', { name: 'Save', exact: true }).click();
  await dialog(page).getByRole('button', { name: 'New catalog', exact: true }).click();
  await dialog(page).getByLabel('Catalog name', { exact: true }).fill('Research'); await dialog(page).getByRole('button', { name: 'Save', exact: true }).click();
  await dialog(page).getByRole('button', { name: 'Make Research default' }).click();
  await dialog(page).getByRole('button', { name: 'Close', exact: true }).click();
  await expect(page.getByTestId('paper-row')).toHaveCount(0);
  await page.reload(); await expect(page.getByLabel('Current catalog')).toHaveValue(/.+/); await expect(page.getByTestId('paper-row')).toHaveCount(0);
  await open(page); await dialog(page).getByRole('button', { name: 'Delete Reading', exact: true }).click();
  await dialog(page).getByRole('button', { name: 'Move papers and delete catalog' }).click();
  await dialog(page).getByRole('button', { name: 'Close', exact: true }).click(); await expect(page.getByTestId('paper-row')).toHaveCount(initial);
  await open(page); await dialog(page).getByRole('button', { name: 'Delete Research', exact: true }).click();
  await dialog(page).getByLabel('What happens to its papers?').selectOption('new');
  await dialog(page).getByLabel('New catalog name').fill('Scientific papers');
  await dialog(page).getByRole('button', { name: 'Move papers and delete catalog' }).click();
  await expect(dialog(page).getByRole('button', { name: 'Rename Scientific papers', exact: true })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath('catalogs.png') });
  await dialog(page).getByRole('button', { name: 'Close', exact: true }).click(); await expect(page.getByTestId('paper-row')).toHaveCount(initial);
  await page.reload(); await expect(page.getByTestId('paper-row')).toHaveCount(initial); await expect(page.getByLabel('Current catalog')).toContainText('Scientific papers');
});

test('a refused paper deletion keeps the catalog; a confirmed retry removes actual entries', async ({ page, request }) => {
  await signIn(page); await open(page);
  await page.route('**/rpc/v2_set_library_item', route => route.fulfill({ status: 403, json: { code: 'forbidden' } }));
  await dialog(page).getByRole('button', { name: 'Delete Default', exact: true }).click();
  await dialog(page).getByLabel('What happens to its papers?').selectOption('delete');
  await dialog(page).getByRole('button', { name: 'Continue', exact: true }).click();
  await dialog(page).getByRole('button', { name: 'Delete catalog and papers', exact: true }).click();
  await expect(dialog(page).getByRole('alert')).toBeVisible();
  await expect(dialog(page)).toContainText('Default contains');
  await page.unroute('**/rpc/v2_set_library_item');
  await dialog(page).getByRole('button', { name: 'Delete catalog and papers', exact: true }).click();
  await expect(dialog(page).getByRole('button', { name: 'New catalog', exact: true })).toBeVisible();
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.entries.filter((e: { visible: boolean }) => e.visible)).toHaveLength(0);
  await dialog(page).getByRole('button', { name: 'Close', exact: true }).click(); await expect(page.getByTestId('paper-row')).toHaveCount(0);
});


test('new additions stay in the chosen catalog and an individual paper can move without removal', async ({ page, request }) => {
  await signIn(page); await open(page);
  await dialog(page).getByRole('button', { name: 'New catalog', exact: true }).click();
  await dialog(page).getByLabel('Catalog name', { exact: true }).fill('Research'); await dialog(page).getByRole('button', { name: 'Save', exact: true }).click();
  await dialog(page).getByRole('button', { name: 'Close', exact: true }).click();
  await openAddPaper(page);
  await page.getByTestId('arxiv-input').fill('1901.00001');
  await page.getByRole('dialog', { name: 'Add paper', exact: true }).getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page.getByTestId('paper-row')).toHaveCount(1);
  await page.getByLabel('Current catalog').selectOption({ label: 'Default' });
  const paper = page.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
  await paper.getByRole('button', { name: /^Actions for/ }).click();
  await page.getByRole('menuitem', { name: 'Move to catalog…' }).click();
  const moving = page.getByRole('dialog', { name: 'Move to catalog', exact: true });
  await moving.getByRole('combobox', { name: 'Catalog', exact: true }).selectOption({ label: 'Research' });
  await moving.getByRole('button', { name: 'Move', exact: true }).click();
  await expect(moving).toHaveCount(0); await expect(paper).toHaveCount(0);
  await page.getByLabel('Current catalog').selectOption({ label: 'Research' });
  await expect(paper).toHaveCount(1); await expect(page.getByTestId('paper-row')).toHaveCount(2);
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.entries.find((e: { metadata?: { title?: string } }) => e.metadata?.title?.includes('Direct Preference Optimization'))?.visible).toBe(true);
});

// Build 75 (ACLs): "an option to save the entire catalog as csv". Saved by this browser, nothing sent.
test('a catalog exports every paper as a CSV file named after it', async ({ page }, info) => {
  await signIn(page); const titles = await page.getByTestId('paper-row').locator('.title').allTextContents(); await open(page);
  const sent: string[] = []; page.on('request', r => { if (r.method() !== 'GET') sent.push(r.url()); });
  await page.screenshot({ path: `../../.artifacts/feedback-20261021/browser/b6-catalogs-${info.project.name}-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `../../.artifacts/feedback-20261021/browser/b6-catalogs-${info.project.name}-dark.png` });
  await page.emulateMedia({ colorScheme: 'light' });
  const [download] = await Promise.all([page.waitForEvent('download'), dialog(page).getByRole('button', { name: 'Export Default as CSV', exact: true }).click()]);
  expect(download.suggestedFilename()).toBe('Default.csv');
  const bytes = await (await download.createReadStream()).toArray().then(chunks => Buffer.concat(chunks));
  expect([...bytes.subarray(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
  const text = bytes.toString('utf8').slice(1), lines = text.split('\r\n');
  expect(lines[0]).toBe('Title,Authors,Year,arXiv ID,DOI,Link,Tags,Added');
  // The entire catalog: every paper the table shows, and the archived one it hides by default.
  for (const title of titles) expect(lines.some(line => line.startsWith(title.trim()))).toBe(true);
  expect(lines.some(line => line.startsWith('Mamba: Linear-Time Sequence Modeling'))).toBe(true);
  expect(lines.filter(Boolean)).toHaveLength(titles.length + 2);
  expect(text).toContain(',2305.18290v3,,https://arxiv.org/abs/2305.18290v3,Alignment,');
  expect(sent).toEqual([]);
  await expect(dialog(page)).toBeVisible();
});

// Build 75 (AHI8): "Move the catalog to the left of the search bar and move the + option as a new row inside the dialogue
// on the far right" — the Library's own "…" since 2026-10-22 (audit S10).
test('the catalog sits left of the search; Add paper is the first row of the Library\u2019s "…"', async ({ page }, info) => {
  await signIn(page);
  const select = page.getByLabel('Current catalog'), field = page.getByTestId('search');
  await expect(select).toHaveCount(0); // only Default: nothing to choose
  await open(page);
  await dialog(page).getByRole('button', { name: 'New catalog', exact: true }).click();
  await dialog(page).getByLabel('Catalog name', { exact: true }).fill('Research papers for the thesis'); await dialog(page).getByRole('button', { name: 'Save', exact: true }).click();
  await dialog(page).getByRole('button', { name: 'Close', exact: true }).click();
  await expect(select).toBeVisible();
  const [s, f] = [(await select.boundingBox())!, (await field.boundingBox())!];
  expect(s.x + s.width).toBeLessThanOrEqual(f.x);
  expect(Math.abs(s.y + s.height / 2 - (f.y + f.height / 2))).toBeLessThan(4);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(page.viewportSize()!.width);
  await expect(page.getByRole('banner').getByRole('button', { name: 'Add paper' })).toHaveCount(0);
  await page.getByTestId('library-options').click();
  await expect(page.getByRole('menu').getByRole('menuitem').first()).toHaveText('Add paper…');
  for (const scheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.screenshot({ path: `../../.artifacts/feedback-20261021/browser/b7-header-${info.project.name}-${scheme}.png` });
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.getByTestId('add-paper').click();
  await expect(page.getByRole('dialog', { name: 'Add paper', exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  // Hidden while searching, back after Esc (the search panel's Cancel).
  await field.fill('zzz'); await expect(select).toHaveCount(0);
  await field.press('Escape'); await expect(select).toBeVisible();
});
