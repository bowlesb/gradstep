// Approve this browser from a phone (QR) against the local fixture backend, under the production CSP.
// The fixture's "iPhone" (POST /__approve) reads the exact QR text the page renders and approves it as the app does.
import { type Page, expect, test } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

const FIXTURE = 'http://127.0.0.1:54329';
const shots = '../../.artifacts/web-approval/';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
}
const payloadOf = (page: Page) => page.getByTestId('approval-qr').getAttribute('data-payload');

test.beforeEach(async ({ request }) => { await request.post(`${FIXTURE}/__reset`); await mkdir(shots, { recursive: true }); });

test('a phone scans the QR code and approves this browser; the library opens', async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  const problems: string[] = [];
  page.on('pageerror', error => problems.push(String(error)));
  page.on('console', m => { if (m.type() === 'error' && !/status of (401|403|422)/.test(m.text())) problems.push(m.text()); });
  const external: string[] = [];
  page.on('request', r => { const u = new URL(r.url()); if (!['127.0.0.1', 'localhost'].includes(u.hostname) && u.protocol !== 'data:') external.push(r.url()); });
  await signIn(page);
  await expect(page.getByRole('heading', { name: 'Restore your private library' })).toBeVisible();
  const qr = page.getByTestId('approval-qr');
  await expect(qr.locator('svg')).toBeVisible();
  const payload = await payloadOf(page);
  expect(payload).toMatch(/^GSDA1\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\.w$/);
  const shown = (await page.getByTestId('approval-code').textContent())!.replace(/\s/g, '');
  expect(shown).toMatch(/^\d{6}$/);
  await expect(page.getByTestId('approval-status')).toContainText('Waiting for approval');
  await page.screenshot({ path: `${shots}${info.project.name}-qr-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${shots}${info.project.name}-qr-dark.png` });

  // A reload resumes the same pending recipient and request: same QR, same number.
  await page.reload();
  await expect(qr.locator('svg')).toBeVisible();
  expect(await payloadOf(page)).toBe(payload);

  const approval = await request.post(`${FIXTURE}/__approve`, { data: { payload } });
  expect(approval.status()).toBe(200);
  expect((await approval.json()).code).toBe(shown); // the phone computes the same number from the server's request
  await expect(page.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible({ timeout: 20_000 });
  await page.reload();
  await expect(page.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
  expect(external).toEqual([]);
  expect(problems).toEqual([]);
});

test('switching between the phone and the recovery code keeps one pending request', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await signIn(page);
  await expect(page.getByTestId('approval-qr').locator('svg')).toBeVisible();
  const payload = await payloadOf(page);
  await page.getByTestId('use-recovery-code').click();
  await expect(page.getByTestId('recovery-code')).toBeVisible();
  await page.getByTestId('use-phone').click();
  await expect(page.getByTestId('approval-qr').locator('svg')).toBeVisible();
  expect(await payloadOf(page)).toBe(payload);
  await page.getByTestId('use-recovery-code').click();
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
  const requests = await (await request.get(`${FIXTURE}/__pending-requests`)).json();
  expect(requests).toEqual([expect.objectContaining({ approved: true })]); // the QR's request, approved with the code
  // The phone, scanning the old QR afterwards, finds nothing left to approve.
  expect((await request.post(`${FIXTURE}/__approve`, { data: { payload } })).status()).toBe(404);
});
