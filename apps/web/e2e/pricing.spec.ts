// Free AI and the accepted plans in the browser (migration 0150; docs/PRICING_HOW_IT_WORKS.md): the account menu's Plan
// (Free / Plus / Pro, yearly), its ⓘ explaining every plan, the Free AI row, and the free-AI words when a chat answer is
// refused because this month's free AI is used up. The browser sells nothing. Local fixtures only.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';
const SHOTS = '../../.artifacts/pricing-browser';
const NOV = '2026-11-01T00:00:00+00:00';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
}
async function row(page: Page, testID: string, label: string, value: string | RegExp) {
  const r = page.getByTestId(testID);
  await expect(r.locator('.settings-label')).toContainText(label);
  await expect(r.locator('.settings-value')).toHaveText(value);
}
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

for (const scheme of ['light', 'dark'] as const) test(`a free reader's plan, its ⓘ and free AI this month (${scheme})`, async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  test.skip(!['desktop', 'phone'].includes(info.project.name));
  await page.emulateMedia({ colorScheme: scheme });
  await request.post(`${API}/__store`, { data: { available: 32, reserved: 0, plan: null,
    free: { monthly: 50, available: 32, usable: true, reason: null, resumes_at: NOV, daily: 20 } } });
  await signIn(page);
  await page.getByTestId('account-menu').click(); await page.getByTestId('open-settings').click();
  const menu = page.getByRole('dialog', { name: 'Settings' }); // a Settings window since 2026-10-22 (audit S9)
  await row(page, 'account-credits', 'Available', '32');
  await row(page, 'account-plan', 'Plan', 'Free');
  await row(page, 'account-free-ai', 'Free AI this month', '32 of 50 left');
  await expect(menu).not.toContainText(/Get credits|Buy|Upgrade/);
  await expect(menu.getByTestId('plan-info')).toHaveAccessibleDescription(/^Reading papers is always free\. AI uses credits\. Free: 50 credits a month/);
  await expect(menu.getByTestId('free-ai-info')).toHaveAccessibleDescription(/^Free accounts get 50 credits a month for the fast models/);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-menu.png` });
  await menu.getByTestId('plan-info').click();
  await expect(menu.getByText('Plus: 600 credits a month (about 200 answers), every model.', { exact: false })).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-plan-info.png`, animations: 'disabled' });
  await page.keyboard.press('Escape');
});

test('used up this month; a yearly Plus subscriber has no free AI row', async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  test.skip(!['desktop', 'phone'].includes(info.project.name));
  await request.post(`${API}/__store`, { data: { available: 0, reserved: 0, plan: null,
    free: { monthly: 50, available: 12, usable: false, reason: 'pool', resumes_at: NOV, daily: 20 } } });
  await signIn(page);
  await page.getByTestId('account-menu').click(); await page.getByTestId('open-settings').click();
  await row(page, 'account-free-ai', 'Free AI this month', 'Used up · back November 1');
  await page.getByTestId('settings-close').click();
  await request.post(`${API}/__store`, { data: { available: 600, reserved: 0, plan: 'standard', period_months: 12, free: null } });
  await page.getByTestId('account-menu').click(); await page.getByTestId('open-settings').click();
  await row(page, 'account-plan', 'Plan', 'Plus (yearly)');
  await expect(page.getByTestId('account-free-ai')).toHaveCount(0);
});

for (const scheme of ['light', 'dark'] as const) test(`a chat answer refused while this month's free AI is used up says so (${scheme})`, async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  test.skip(!['desktop', 'phone'].includes(info.project.name));
  await page.emulateMedia({ colorScheme: scheme });
  await request.post(`${API}/__store`, { data: { available: 0, reserved: 0, plan: null,
    free: { monthly: 50, available: 12, usable: false, reason: 'pool', resumes_at: NOV, daily: 20 } } });
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'insufficient_credits' } });
  await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('What does β control?');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  const issue = page.getByTestId('chat-pane').locator('.chat-issue');
  await expect(issue).toHaveText(/This month’s free AI has all been used\. It comes back on November 1\. Reading is unaffected\. Credits can’t be bought on the web yet\. If you have an iPhone, iPad or Mac, credits added in the Gradstep app work here right away\./);
  await expect(page.getByTestId('chat-user')).toContainText('What does β control?');
  await issue.scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-chat-free-used.png` });
  // Not on the free tier: the usual words.
  await request.post(`${API}/__store`, { data: { available: 0, reserved: 0, free: null } });
  await page.getByRole('button', { name: 'New chat', exact: true }).click();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Another question');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.getByTestId('chat-pane').locator('.chat-issue')).toContainText('Not enough credits for this answer.');
});
