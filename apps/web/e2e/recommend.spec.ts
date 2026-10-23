// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md) against the fixture's scripted `recommend` stream: Paper ⋯ ›
// Recommend similar papers › Add N papers, rows as they are added with a reason, Remove one, Undo, Done; the catalog's
// Recommend; keyboard access; the catalog the papers go to; the reader's words for refusals. No provider is contacted.
import { expect, test, type Page } from '@playwright/test';
import { fileURLToPath } from 'node:url';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';
import { fixtureOrigin as FIXTURE } from './environment';

const SHOTS = fileURLToPath(new URL('../../../.artifacts/recommendations/browser/', import.meta.url));
const dpo = (page: Page) => page.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
const dialog = (page: Page) => page.getByTestId('recommend-dialog');
const RECOMMENDED = ['Generative Retrieval with Learned Document Codes', 'Semantic Identifiers for Dense Retrieval at Scale', 'Continual Learning for Generative Retrieval Indexes'];
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
async function fixture(request: import('@playwright/test').APIRequestContext, body: Record<string, unknown>) {
  return (await (await request.post(`${FIXTURE}/__recommend-fixture`, { data: body })).json()) as { requests: { count: number; scope: string; seeds: { source_id: string; keywords: string[] }[]; operation_id: string }[] };
}
async function recommendFromRow(page: Page, count: 1 | 3 | 5) {
  await dpo(page).getByRole('button', { name: /^Actions for/ }).click();
  await page.getByTestId('recommend-menu').click();
  await page.getByTestId(`recommend-add-${count}`).click();
  await expect(dialog(page)).toBeVisible();
}
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}${test.info().project.name}-${name}.png` });

test.beforeEach(async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Safari durable-key acceptance is separate.');
  await request.post(`${FIXTURE}/__reset`);
});

test('Recommend similar papers adds them as they arrive, with why; Remove, Undo and Done', async ({ page, request }) => {
  await fixture(request, { mode: 'normal', delay: 350 });
  await signIn(page);
  // Directly under Find similar papers, with the price before anything is asked.
  await dpo(page).getByRole('button', { name: /^Actions for/ }).click();
  const items = page.getByRole('menu', { name: 'Paper actions' }).getByRole('menuitem');
  await expect(items.nth(0)).toHaveText('Find similar papers');
  await expect(items.nth(1)).toHaveText(/Recommend similar papers/);
  await page.getByTestId('recommend-menu').click();
  await expect(page.getByTestId('recommend-note')).toHaveText('1 credit');
  await shot(page, 'menu');
  await page.getByTestId('recommend-add-3').click();
  await expect(dialog(page)).toBeVisible();
  await expect(page.getByTestId('recommend-status')).toContainText('Direct Preference Optimization');
  // Rows stream in, each with its reason.
  await expect(page.getByTestId('recommend-row-2410.01001')).toContainText('Same task; learns the document codes instead of fixing them');
  await expect(page.locator('.recommend-row')).toHaveCount(3);
  await expect(page.getByTestId('recommend-footer')).toHaveText('Added 3 papers · 1 credit');
  await expect(page.getByTestId('recommend-status')).toHaveCount(0);
  await shot(page, 'added');
  const sent = (await fixture(request, {})).requests;
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ count: 3, scope: 'paper', seeds: [{ source_id: '2305.18290' }] });
  expect(sent[0].seeds[0].keywords).toContain('Alignment');
  expect(sent[0].seeds[0].keywords).not.toContain('Large language models');
  // The papers are in the library.
  await page.getByTestId('recommend-done').click();
  await expect(dialog(page)).toHaveCount(0);
  for (const title of RECOMMENDED) await expect(page.getByTestId('paper-row').filter({ hasText: title })).toHaveCount(1);
  // Reopen from the row menu (a request is not running): a new request is not started by reopening; Undo from a new run.
  await recommendFromRow(page, 1);
  await expect(page.getByTestId('recommend-footer')).toHaveText('Added 1 paper · 1 credit');
  await expect(page.getByTestId('recommend-row-2410.01004')).toBeVisible();
  await page.getByRole('button', { name: 'Remove A Benchmark for Corpus Updates in Retrieval' }).click();
  await expect(page.getByTestId('recommend-row-2410.01004')).toContainText('Removed');
  await expect(page.getByTestId('recommend-undo')).toHaveCount(0);
  await page.getByTestId('recommend-done').click();
  await expect(page.getByTestId('paper-row').filter({ hasText: 'A Benchmark for Corpus Updates' })).toHaveCount(0);
});

test('Undo takes all of them back; the dialog can close while papers are still being added', async ({ page, request }) => {
  await fixture(request, { mode: 'normal', delay: 600 });
  await signIn(page);
  await recommendFromRow(page, 3);
  // Closing early does not stop the request: the papers still arrive in the library.
  await page.getByTestId('recommend-done').click();
  await expect(dialog(page)).toHaveCount(0);
  for (const title of RECOMMENDED) await expect(page.getByTestId('paper-row').filter({ hasText: title })).toHaveCount(1, { timeout: 15_000 });
  // Reopening shows the finished request (the menu's choice reopens the running one, or starts another once done).
  await recommendFromRow(page, 1);
  await expect(page.getByTestId('recommend-footer')).toHaveText(/Added 1 paper/);
  await page.getByTestId('recommend-undo').click();
  await expect(page.getByTestId('recommend-footer')).toHaveText('Removed the 1 paper again · 1 credit');
  await page.getByTestId('recommend-done').click();
  await expect(page.getByTestId('paper-row').filter({ hasText: 'A Benchmark for Corpus Updates' })).toHaveCount(0);
});

test('keyboard: → or Enter opens the choices, Esc returns to the menu; the catalog has its own Recommend', async ({ page, request }) => {
  await fixture(request, { mode: 'normal', delay: 100 });
  await signIn(page);
  const trigger = dpo(page).getByRole('button', { name: /^Actions for/ });
  await trigger.focus(); await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('menuitem', { name: 'Find similar papers' })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(page.getByTestId('recommend-menu')).toBeFocused();
  await expect(page.getByTestId('recommend-menu')).toHaveAttribute('aria-expanded', 'false');
  await page.keyboard.press('ArrowRight');
  await expect(page.getByTestId('recommend-add-1')).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect(page.getByTestId('recommend-add-3')).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('recommend-menu')).toBeFocused();
  await expect(page.getByTestId('recommend-add-1')).toHaveCount(0);
  await expect(page.getByRole('menu', { name: 'Paper actions' })).toBeVisible();
  await page.keyboard.press('Enter'); await expect(page.getByTestId('recommend-add-1')).toBeFocused();
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  await expect(dialog(page)).toBeVisible();
  await expect(page.locator('.recommend-row')).toHaveCount(3);
  await expect(page.getByTestId('recommend-done')).toBeEnabled();
  await page.keyboard.press('Escape');
  await expect(dialog(page)).toHaveCount(0);
  // The catalog's Recommend: its most recent papers as seeds.
  await page.getByTestId('library-options').click(); await page.getByTestId('recommend-catalog').click(); // the Library's "…" › Recommend papers ›
  await expect(page.getByTestId('recommend-note')).toHaveText(/^For Default · 1 credit/);
  await shot(page, 'catalog-menu');
  await page.getByTestId('recommend-add-1').click();
  await expect(page.getByTestId('recommend-footer')).toHaveText('Added 1 paper · 1 credit');
  await expect(dialog(page)).toContainText('For Default');
  const sent = (await fixture(request, {})).requests;
  expect(sent.at(-1)).toMatchObject({ scope: 'catalog', count: 1 });
  expect(sent.at(-1)!.seeds.length).toBeGreaterThanOrEqual(2);
  expect(sent.at(-1)!.seeds.length).toBeLessThanOrEqual(8);
  expect(sent.at(-1)!.seeds.every(seed => seed.keywords.length <= 3)).toBe(true);
});

test('papers go to the catalog being viewed', async ({ page, request }) => {
  await fixture(request, { mode: 'normal', delay: 100 });
  await signIn(page);
  const catalogs = page.getByRole('dialog', { name: 'Catalogs', exact: true });
  await page.getByTestId('library-options').click(); await page.getByTestId('library-catalogs').click();
  await catalogs.getByRole('button', { name: 'Rename Default', exact: true }).click();
  await catalogs.getByLabel('Catalog name', { exact: true }).fill('Reading'); await catalogs.getByRole('button', { name: 'Save', exact: true }).click();
  await catalogs.getByRole('button', { name: 'New catalog', exact: true }).click();
  await catalogs.getByLabel('Catalog name', { exact: true }).fill('Later'); await catalogs.getByRole('button', { name: 'Save', exact: true }).click();
  await catalogs.getByRole('button', { name: 'Close', exact: true }).click();
  await page.getByLabel('Current catalog').selectOption({ label: 'Reading' });
  await dpo(page).getByRole('button', { name: /^Actions for/ }).click();
  await page.getByTestId('recommend-menu').click();
  await expect(page.getByTestId('recommend-note')).toHaveText('1 credit · added to Reading');
  await page.getByTestId('recommend-add-1').click();
  await expect(page.getByTestId('recommend-footer')).toHaveText('Added 1 paper to Reading · 1 credit');
  await page.getByTestId('recommend-done').click();
  const added = page.getByTestId('paper-row').filter({ hasText: RECOMMENDED[0] });
  await expect(added).toHaveCount(1);
  await page.getByLabel('Current catalog').selectOption({ label: 'Later' });
  await expect(added).toHaveCount(0);
  await page.getByLabel('Current catalog').selectOption({ label: 'Reading' });
  await expect(added).toHaveCount(1);
});

test('refusals and nothing related are said plainly and charge nothing; a request already running is waited for', async ({ page, request }) => {
  await signIn(page);
  await fixture(request, { mode: 'daily_limit' });
  await recommendFromRow(page, 3);
  await expect(dialog(page).getByRole('alert')).toHaveText('You’ve asked for recommendations 20 times today. Try again tomorrow.');
  await expect(page.getByTestId('recommend-retry')).toHaveCount(0);
  await shot(page, 'daily-limit');
  await page.getByTestId('recommend-done').click();
  await fixture(request, { mode: 'none_related' });
  await recommendFromRow(page, 5);
  await expect(page.getByTestId('recommend-footer')).toHaveText('No closely related papers found. Nothing was charged.');
  await page.getByTestId('recommend-done').click();
  await fixture(request, { mode: 'in_progress', delay: 50 });
  await recommendFromRow(page, 1);
  await expect(page.getByTestId('recommend-footer')).toHaveText('Added 1 paper · 1 credit');
  const sent = (await fixture(request, {})).requests.slice(-2);
  expect(sent[0].operation_id).toBe(sent[1].operation_id);
  await page.getByTestId('recommend-done').click();
  // A server refusing the request outright (an older server without the function): Try again starts a new request.
  await page.route('**/functions/v1/recommend', route => route.fulfill({ status: 503, json: { code: 'service_unavailable', retry_after: 10 } }));
  await recommendFromRow(page, 1);
  await expect(dialog(page).getByRole('alert')).toHaveText('Recommendations aren’t available right now. Nothing was charged.');
  await page.unroute('**/functions/v1/recommend');
  await fixture(request, { mode: 'normal', delay: 50 });
  await page.getByTestId('recommend-retry').click();
  await expect(page.getByTestId('recommend-footer')).toHaveText(/Added 1 paper/);
});

test('screenshots in both themes', async ({ page, request }) => {
  await fixture(request, { mode: 'normal', delay: 150 });
  for (const scheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme: scheme });
    if (scheme === 'light') await signIn(page); else await page.reload();
    await expect(page.getByTestId('library-table')).toBeVisible();
    await recommendFromRow(page, scheme === 'light' ? 3 : 1);
    await expect(page.getByTestId('recommend-footer')).toBeVisible();
    // No horizontal scroll at this width.
    expect(await dialog(page).evaluate(e => e.scrollWidth <= e.clientWidth + 1)).toBe(true);
    await shot(page, `dialog-${scheme}`);
    await page.getByTestId('recommend-done').click();
  }
});
