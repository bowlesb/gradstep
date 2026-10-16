// Screenshot bug-report journey. The fixture routes mirror the deployed support RPCs and asset function;
// the image is public test data and never leaves the local Playwright process.
import { expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');

async function signIn(page: import('@playwright/test').Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click();
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
}

test('a browser report includes a screenshot and can be reopened from My reports', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; support reports require an authenticated browser.');
  let uploaded = 0;
  let reportID = '';
  let attachmentID = '';
  await page.route('**/rest/v1/rpc/v1_create_report', route => { reportID = (route.request().postDataJSON() as { p_id: string }).p_id; return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(reportID) }); });
  await page.route('**/functions/v1/support-assets**', async route => {
    const requestURL = new URL(route.request().url());
    if (route.request().method() === 'POST') { uploaded = route.request().postDataBuffer()?.length ?? 0; attachmentID = requestURL.searchParams.get('attachment_id') ?? ''; return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: attachmentID }) }); }
    return route.fulfill({ status: 200, contentType: 'image/png', body: PNG });
  });
  await page.route('**/rest/v1/rpc/v2_reports', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ id: reportID, title: 'Add paper is disabled', note: 'The button stays disabled after sign-in.', status: 'open', app_version: '0.1.0', build: 'web', os_version: 'MacIntel', screen: 'Browser / · 1280×900', fixed_build: null, created_at: '2026-10-08T00:00:00Z', updated_at: '2026-10-08T00:00:00Z' }]) }));
  await page.route('**/rest/v1/rpc/v1_report_thread', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ report: { id: reportID, title: 'Add paper is disabled', note: 'The button stays disabled after sign-in.', status: 'open', app_version: '0.1.0', build: 'web', os_version: 'MacIntel', screen: 'Browser / · 1280×900', fixed_build: null, created_at: '2026-10-08T00:00:00Z', updated_at: '2026-10-08T00:00:00Z' }, messages: [], attachments: [{ id: attachmentID, object_id: '55555555-5555-4555-8555-555555555555' }] }) }));
  await signIn(page);
  await page.getByTestId('account-menu').click();
  await page.getByTestId('report-issue').click();
  await page.getByTestId('report-title').fill('Add paper is disabled');
  await page.getByTestId('report-note').fill('The button stays disabled after sign-in.');
  await page.getByTestId('report-file').setInputFiles({ name: 'bug.png', mimeType: 'image/png', buffer: PNG });
  await expect(page.getByAltText('Screenshot preview')).toBeVisible();
  await page.getByTestId('report-send').click();
  await expect(page.getByRole('heading', { name: 'My reports' })).toBeVisible();
  expect(uploaded).toBeGreaterThan(0);
  await expect(page.getByRole('button', { name: /Add paper is disabled/ })).toBeVisible();
  await page.getByRole('button', { name: /Add paper is disabled/ }).click();
  await expect(page.getByRole('heading', { name: 'Add paper is disabled' })).toBeVisible();
  await expect(page.getByAltText('Screenshot shared with support')).toBeVisible();
  // It decodes (the page's image policy blocks blob: URLs; a blocked image still shows its alt text).
  await expect.poll(() => page.getByAltText('Screenshot shared with support').evaluate((img: HTMLImageElement) => img.naturalWidth)).toBeGreaterThan(0);
});

test('an operator gets the operations dashboard in the account menu; a reader does not', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  let roles: string[] = [];
  await page.route('**/rest/v1/rpc/v1_account_context', route => route.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify({ account_id: '00000000-0000-4000-8000-000000000001', protocol_version: 1, roles, operator_verified: false }) }));
  await signIn(page);
  await page.getByTestId('account-menu').click();
  await expect(page.getByTestId('my-reports')).toBeVisible();
  await expect(page.getByTestId('operations-dashboard')).toHaveCount(0);
  await expect(page.getByTestId('menu-admin')).toHaveCount(0); // no Admin group for readers
  roles = ['owner'];
  await page.reload();
  await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
  await page.getByTestId('account-menu').click();
  // Operator tools sit in one grey Admin group (owner, build 58).
  const admin = page.getByRole('group', { name: 'Admin' });
  await expect(admin).toBeVisible();
  const link = admin.getByTestId('operations-dashboard');
  await expect(link).toBeVisible();
  await expect(link).toHaveAttribute('href', 'https://admin.gradstep.ai/#health/30');
  await expect(link).toHaveAttribute('target', '_blank');
  await page.screenshot({ path: `../../.artifacts/owner-58/${test.info().project.name}-account-menu-operator.png` });
});
