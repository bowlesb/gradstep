// Browser OAuth is exercised through the local Supabase-style PKCE fixture. No provider or hosted account is used.
import { expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as FIXTURE } from './environment';
import { durableKeys } from './key-capability';

test.beforeEach(async ({ request }) => { await request.post(`${FIXTURE}/__reset`); });

test('Google OAuth returns through the PKCE callback and then restores the encrypted browser', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  const authorize: string[] = [];
  page.on('request', request => { if (request.url().includes('/auth/v1/authorize')) authorize.push(request.url()); });
  await page.goto('/');
  await expect(page.getByTestId('oauth-google')).toBeVisible();
  await page.getByTestId('oauth-google').click();
  await expect(page.getByTestId('use-recovery-code')).toBeVisible({ timeout: 20_000 });
  expect(authorize).toHaveLength(1);
  const started = new URL(authorize[0]);
  // The auth service may live on a branded hostname separate from the data API.
  expect(started.hostname).toBe('localhost');
  expect(started.searchParams.get('provider')).toBe('google');
  expect(started.searchParams.get('code_challenge_method')).toBe('s256');
  expect(started.searchParams.get('state')).toBeNull();
  expect(started.searchParams.get('code_challenge')).toMatch(/^[A-Za-z0-9_-]{43}$/);
  const redirect = new URL(started.searchParams.get('redirect_to')!);
  expect(redirect.pathname).toBe('/auth/callback');
  expect(redirect.searchParams.get('client_state')).toMatch(/^[A-Za-z0-9_-]{32,128}$/);
  await page.getByTestId('use-recovery-code').click();
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible({ timeout: 20_000 });
});

test('Apple OAuth uses the same callback contract', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  const authorize: string[] = [];
  page.on('request', request => { if (request.url().includes('/auth/v1/authorize')) authorize.push(request.url()); });
  await page.goto('/');
  await page.getByTestId('oauth-apple').click();
  await expect(page.getByTestId('use-recovery-code')).toBeVisible({ timeout: 20_000 });
  // Apple is probed once before navigation so a missing web secret becomes a
  // local configuration message instead of a raw JSON page.
  expect(authorize).toHaveLength(2);
  const started = new URL(authorize.at(-1)!);
  expect(started.searchParams.get('provider')).toBe('apple');
  expect(started.searchParams.get('state')).toBeNull();
  expect(new URL(started.searchParams.get('redirect_to')!).searchParams.get('client_state')).toMatch(/^[A-Za-z0-9_-]{32,128}$/);
});

test('an OAuth callback without the matching browser state is rejected before any session is created', async ({ page }) => {
  await page.goto('/auth/callback?code=not-a-real-code&client_state=wrong-state');
  await expect(page.getByTestId('oauth-google')).toBeVisible();
  await expect(page.getByRole('alert')).toHaveText('That sign-in link has expired or was already used. Start again.');
  expect(new URL(page.url()).pathname).toBe('/');
});

test('a beta admission refusal is explained instead of treated as a silent cancellation', async ({ page }) => {
  await page.goto('/auth/callback#error=access_denied&error_code=signup_disabled');
  await expect(page.getByTestId('oauth-google')).toBeVisible();
  await expect(page.getByRole('alert')).toContainText('isn’t invited to the beta');
  expect(new URL(page.url()).hash).toBe('');
  await page.goto('/auth/callback#error=access_denied&error_description=beta_invitation_required');
  await expect(page.getByRole('alert')).toContainText('isn’t invited to the beta');
});
