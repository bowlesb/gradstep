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
async function open(page: Page) { await page.getByRole('button', { name: 'Catalogs', exact: true }).click(); await expect(dialog(page)).toBeVisible(); }
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
  await page.getByTestId('add-paper').click();
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
