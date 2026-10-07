// Browser reader journeys against the local fixture backend, under the production CSP.
import { type Page, expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';

const FIXTURE = 'http://127.0.0.1:54329';
const shots = '../../.artifacts/web-e2e/';

function watch(page: Page) {
  const problems: string[] = [];
  page.on('console', message => {
    if (message.type() === 'error' && !/Failed to load resource: the server responded with a status of (401|403|422)/.test(message.text())) problems.push(message.text());
  });
  page.on('pageerror', error => problems.push(String(error)));
  return problems;
}
async function signIn(page: Page, email: string) {
  await page.goto('/');
  await page.getByTestId('email').fill(email);
  await page.getByTestId('send-code').click();
  await expect(page.getByText(`We sent a 6-digit code to ${email}.`)).toBeVisible();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
}
const shot = (page: Page, name: string) => page.screenshot({ path: `${shots}${test.info().project.name}-${name}.png`, fullPage: false });

test.beforeEach(async ({ request }) => { await request.post(`${FIXTURE}/__reset`); });

test('returning reader: recovery code, library, retry, add paper, read, sign out and back', async ({ page }) => {
  const problems = watch(page);
  await signIn(page, 'returning@example.test');
  await expect(page.getByRole('heading', { name: 'Restore your private library' })).toBeVisible();
  // Password AutoFill shape: a username for the account and a current-password field.
  await expect(page.locator('input[autocomplete="username"]')).toHaveValue('returning@example.test');
  await expect(page.getByTestId('recovery-code')).toHaveAttribute('autocomplete', 'current-password');
  await page.getByTestId('recovery-code').fill('0'.repeat(64));
  await page.getByTestId('recover').click();
  await expect(page.getByText('That recovery code doesn’t match this account.')).toBeVisible();
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE.toUpperCase());
  await page.getByTestId('recover').click();

  const table = page.getByTestId('library-table');
  await expect(table.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
  await expect(table.getByText('Couldn’t download this paper')).toBeVisible();
  await expect(table.getByText(/Mamba/)).toHaveCount(0); // archived: hidden by default
  await expect(page.getByRole('button', { name: 'Archived' })).toBeVisible();
  await expect(page.getByRole('button', { name: /Failed/ })).toBeVisible();
  await shot(page, 'library');

  await table.getByRole('button', { name: 'Retry' }).click();
  await expect(table.getByRole('link', { name: 'A retried paper' })).toBeVisible({ timeout: 15_000 });

  await page.getByTestId('add-paper').click();
  await page.getByTestId('arxiv-input').fill('not a paper');
  await page.getByTestId('arxiv-add').click();
  await expect(page.getByText(/Enter an arXiv identifier or link/)).toBeVisible();
  await page.getByTestId('arxiv-input').fill('https://arxiv.org/abs/1706.03762');
  await page.getByTestId('arxiv-add').click();
  await expect(page.getByTestId('import-progress').first()).toBeVisible();
  await expect(table.getByText(/Reading equations and figures \(page 6 of 15\)/)).toBeVisible({ timeout: 8_000 });
  await shot(page, 'import-progress');
  await expect(table.getByRole('link', { name: 'Attention Is All You Need' })).toBeVisible({ timeout: 15_000 });

  await table.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page).toHaveURL(/\/paper\/aaaaaaaa-0000-4000-8000-000000000001$/);
  const frame = page.frameLocator('[data-testid=reader-frame]');
  await expect(frame.locator('h1').first()).toContainText('Direct Preference Optimization');
  await expect(frame.locator('.sr-paper-line')).toContainText('2023 · NeurIPS 2023 · arXiv 2305.18290v3');
  await expect(frame.locator('figure img').first()).toBeVisible();
  await expect(page.getByTestId('contents')).toBeEnabled();
  await shot(page, 'reader');

  await page.getByTestId('contents').click();
  const contents = page.getByRole('navigation', { name: 'Contents' });
  const headings = await contents.getByRole('button').allTextContents();
  expect(headings.length).toBeGreaterThan(5);
  await contents.getByRole('button', { name: headings[3] }).click();
  await expect(contents).toBeHidden();

  const citation = frame.locator('.sr-cite').first();
  await citation.scrollIntoViewIfNeeded();
  await citation.click();
  await expect(page.getByTestId('citation-back')).toBeVisible();
  await page.getByTestId('citation-back').click();
  await expect(page.getByTestId('citation-back')).toBeHidden();

  await frame.locator('figure img').first().click();
  await expect(page.locator('iframe.figure-frame')).toBeVisible();
  await page.getByRole('button', { name: 'Done' }).click();

  await page.getByTestId('ask').click({ force: true }); // aria-disabled: explains instead of acting
  await expect(page.getByText(/Chat is not yet available in the browser/)).toBeVisible();

  await frame.locator('body').evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight / 2));
  await page.waitForTimeout(2600);
  await frame.locator('body').evaluate(() => window.scrollBy(0, 40));
  await page.waitForTimeout(600);
  await page.getByTestId('back-to-library').click();
  const row = table.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
  await expect(row.locator('.reading-progress')).toBeVisible();

  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('confirm-sign-out').click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();

  // This browser stays approved: no recovery code the second time.
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await expect(table.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
  await expect(row.locator('.reading-progress')).toBeVisible(); // reading place kept on this device

  // Removing this browser's keys brings the recovery step back.
  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('forget-device').check();
  await page.getByTestId('confirm-sign-out').click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.waitForTimeout(300); // let the local key removal finish before reloading
  await signIn(page, 'returning@example.test');
  await expect(page.getByRole('heading', { name: 'Restore your private library' })).toBeVisible();
  expect(problems).toEqual([]);
});

test('new account: new keys and recovery code, empty library, reload stays ready', async ({ page }) => {
  const problems = watch(page);
  await page.emulateMedia({ colorScheme: 'dark' });
  await signIn(page, 'new@example.test');
  await expect(page.getByRole('heading', { name: 'Save your recovery code' })).toBeVisible();
  const code = await page.getByTestId('new-recovery-code').textContent();
  expect(code).toMatch(/^[0-9a-f]{8}(-[0-9a-f]{8}){7}$/);
  await expect(page.getByTestId('confirm-code')).toBeDisabled();
  await shot(page, 'new-keys-dark');
  await page.getByTestId('saved-code').check();
  await page.getByTestId('confirm-code').click();
  await expect(page.getByText('Your library is empty.')).toBeVisible();
  await shot(page, 'empty-library-dark');
  await page.reload();
  await expect(page.getByText('Your library is empty.')).toBeVisible();
  expect(problems).toEqual([]);
});

test('an address without an account is told sign-up is invite-only', async ({ page }) => {
  await page.goto('/');
  await shot(page, 'sign-in');
  await page.getByTestId('email').fill('stranger@example.test');
  await page.getByTestId('send-code').click();
  await expect(page.getByText(/invite-only during the beta/)).toBeVisible();
});

test('security headers and a refused foreign script', async ({ page, request }) => {
  const response = await request.get('/');
  const csp = response.headers()['content-security-policy'];
  expect(csp).toContain("default-src 'none'");
  expect(csp).toContain(`connect-src ${FIXTURE}`);
  expect(csp).toContain("frame-ancestors 'none'");
  expect(response.headers()['x-content-type-options']).toBe('nosniff');
  await page.goto('/');
  // An injected inline script is refused by the policy.
  const ran = await page.evaluate(async () => {
    const s = document.createElement('script'); s.textContent = 'window.__injected = true'; document.head.append(s);
    await new Promise(r => setTimeout(r, 50));
    return (window as unknown as { __injected?: boolean }).__injected === true;
  });
  expect(ran).toBe(false);
});
