// Your AI usage (owner, 2026-10-22): account menu › AI credits › Your AI usage. One row per request, newest first, with
// the activity (chat named from what this browser knew, the paper's title from its library), model, tokens and credits;
// stopped and failed rows labeled; parts on opening a row; activity chips with totals; more rows on scrolling; the period.
// Local fixtures only (fixture-backend.mjs serves tests/fixtures/ai-usage.json), no hosted or paid requests.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';
const SHOTS = '../../.artifacts/ai-usage-20261022';

async function signInToPaper(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
}
async function openUsage(page: Page) {
  await page.getByTestId('account-menu').click();
  await page.getByRole('menu').getByTestId('ai-usage').click();
  const dialog = page.getByRole('dialog', { name: 'Your AI usage' });
  await expect(dialog).toBeVisible();
  return dialog;
}
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

for (const scheme of ['light', 'dark'] as const) test(`Your AI usage: rows, labels, parts, filters, pages and period (${scheme})`, async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  await page.route('https://arxiv.org/**', route => route.abort());
  await page.emulateMedia({ colorScheme: scheme });
  await signInToPaper(page);
  // One paper question from this browser: its row is "Paper chat" with the paper's title from the library here.
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('What does β control?');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('chat-assistant').first()).toBeVisible();
  const asked = (await (await request.get(`${API}/__chat-evidence`)).json()).requests[0];
  // The browser remembers only the kind and the library's ids, never the title.
  const stored = await page.evaluate(() => Object.entries(localStorage).filter(([k]) => k.includes('usage-provenance')).map(([, v]) => v).join());
  expect(stored).toContain(asked.operation_id); expect(stored).not.toContain('Direct Preference');

  const usage = await openUsage(page);
  await expect(usage.getByTestId('usage-totals')).toContainText('Last 30 days: ');
  await expect(usage.getByTestId('usage-totals')).toContainText('credits · 40 requests');
  const first = usage.getByTestId(`usage-row-${asked.operation_id}`);
  await expect(first).toContainText('Paper chat'); await expect(first).toContainText('Direct Preference Optimization'); await expect(first).toContainText('3 credits');
  await expect(first).toContainText('Claude Sonnet 5.5');
  // The shared fixture's rows, as the apps word them.
  const row = (id: string) => usage.getByTestId(`usage-row-14400000-0000-4000-8001-${id}`);
  await expect(row('00000000000b')).toContainText('Chat');
  await expect(row('000000000003')).toContainText('Stopped'); await expect(row('000000000003')).toContainText('1 credit');
  await expect(row('000000000003')).toContainText('≈ 5k in · 300 out');
  await expect(row('000000000004')).toContainText('Equation explainer'); await expect(row('000000000004')).toContainText('Didn’t finish · not charged');
  await expect(row('000000000005')).toContainText('In progress'); await expect(row('000000000005')).toContainText('Up to 30');
  await expect(row('000000000007')).toContainText('Tags'); await expect(row('000000000007')).toContainText('Free');
  await expect(row('000000000006')).toContainText('Podcast'); await expect(row('000000000006')).toContainText('55 credits');
  await page.screenshot({ path: `${SHOTS}/browser-${info.project.name}-${scheme}-list.png` });

  // A row's parts: the answer, its suggestions and title, the search.
  await row('000000000001').click();
  await expect(row('000000000001')).toHaveAttribute('aria-expanded', 'true');
  const parts = usage.getByTestId('usage-parts-14400000-0000-4000-8001-000000000001');
  await expect(parts.locator('li').first()).toContainText('Answer');
  await expect(parts).toContainText('Suggested questions'); await expect(parts).toContainText('Chat title'); await expect(parts).toContainText('1 search');
  await expect(parts).toContainText('1,000 in · 20,000 cached · 700 out');
  await parts.scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${SHOTS}/browser-${info.project.name}-${scheme}-parts.png` });

  // More rows as the list scrolls: 40 in the window, 25 a page.
  await expect(usage.locator('.usage-list > li')).toHaveCount(25);
  await usage.getByTestId('usage-more').scrollIntoViewIfNeeded();
  await expect(usage.locator('.usage-list > li')).toHaveCount(40);
  await expect(usage.getByTestId('usage-more')).toHaveCount(0);
  const ids = await usage.locator('.usage-list > li > button').evaluateAll(b => b.map(x => x.getAttribute('data-testid')));
  expect(new Set(ids).size).toBe(40);

  // The activity chips (only activities in the window) and their totals.
  await usage.getByTestId('usage-chip-podcast').click();
  await expect(usage.getByTestId('usage-chip-podcast')).toHaveAttribute('aria-pressed', 'true');
  await expect(usage.locator('.usage-list > li')).toHaveCount(1);
  await expect(usage.getByTestId('usage-totals')).toHaveText(/Last 30 days · Podcast: 55 credits · 1 request · 108k tokens$/);
  await expect(usage.getByTestId('usage-chip-web_search')).toHaveCount(0);
  await usage.getByTestId('usage-chip-all').click();
  await expect(usage.locator('.usage-list > li')).toHaveCount(25);

  // What affects cost, behind ⓘ.
  await expect(usage.getByTestId('usage-info')).toHaveAccessibleDescription(/cached copy/);
  // The period, remembered in this browser.
  await usage.getByTestId('usage-period').selectOption('7');
  await expect(usage.getByTestId('usage-totals')).toContainText('Last 7 days');
  const queries = (await (await request.get(`${API}/__usage-evidence`)).json()).queries;
  expect(queries.at(-1)).toMatchObject({ p_days: 7, p_activity: null, p_before_id: null, p_limit: 25 });
  expect(JSON.stringify(queries)).not.toMatch(/Direct Preference|title/);
  await usage.getByTestId('usage-close').click();
  await expect(usage).toBeHidden();
  const again = await openUsage(page);
  await expect(again.getByTestId('usage-period')).toHaveValue('7');
});

test('Your AI usage: empty, then a failure with Try again', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  await page.route('https://arxiv.org/**', route => route.abort());
  await request.post(`${API}/__usage`, { data: { empty: true } });
  await signInToPaper(page);
  let usage = await openUsage(page);
  await expect(usage.getByTestId('usage-empty')).toContainText('No AI usage in the last 30 days');
  await expect(usage.locator('.usage-chips')).toHaveCount(0);
  await usage.getByTestId('usage-close').click();
  await request.post(`${API}/__usage`, { data: { fail: true } });
  usage = await openUsage(page);
  await expect(usage.getByTestId('usage-error')).toContainText('Couldn’t load your AI usage.');
  await request.post(`${API}/__usage`, { data: {} });
  await usage.getByRole('button', { name: 'Try again' }).click();
  await expect(usage.locator('.usage-list > li')).toHaveCount(25);
});
