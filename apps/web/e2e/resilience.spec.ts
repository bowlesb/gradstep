// docs/architecture/RESILIENCE.md, "journeys that must stay usable": one failing dependency costs its own feature, with
// an honest message, never the page. Faults come from the fixture backend's /__fault switch; arXiv is routed.
import { expect, test, type Page } from '@playwright/test';
import { signInReader } from './device-reader-helpers';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';

const fault = (request: import('@playwright/test').APIRequestContext, path: string, kind: number | string, times?: number) =>
  request.post(`${API}/__fault`, { data: { path, kind, ...(times ? { times } : {}) } });
const shot = (page: Page, name: string) => page.screenshot({ path: `../../.artifacts/resilience/web-${name}-${test.info().project.name}.png` });
// The same state in the dark appearance, then back.
const shots = async (page: Page, name: string) => {
  await shot(page, name);
  await page.emulateMedia({ colorScheme: 'dark' }); await shot(page, `${name}-dark`); await page.emulateMedia({ colorScheme: 'light' });
};

test.beforeEach(async ({ page }) => { await page.route('https://arxiv.org/**', route => route.abort()); });

test('launch: when Gradstep can\'t be reached the page says so, counts down and comes back by itself', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signInReader(page, request);
  // The next two key checks fail as an unreachable server would; the third succeeds.
  await fault(request, 'rest/v1/rpc/v1_key_state', 503, 2);
  await page.reload();
  await expect(page.getByTestId('launch-offline')).toBeVisible();
  await expect(page.getByTestId('launch-offline')).toContainText(/Trying again (in \d+ s)?…/);
  await shots(page, 'launch-offline');
  // No manual step: the library arrives once the server answers again.
  await expect(page.getByTestId('library-table')).toBeVisible({ timeout: 20_000 });
});

test('a region that fails to render shows its own notice; the rest of the page keeps working', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signInReader(page, request);
  // An unexpected exception while the Feed renders its cards (dates formatted as "Oct 2026"), as a malformed value would.
  await page.evaluate(() => {
    const Original = Intl.DateTimeFormat;
    const Patched = function (locale?: string | string[], options?: Intl.DateTimeFormatOptions) {
      const real = new Original(locale, options);
      if (options?.month === 'short' && options?.year === 'numeric' && options?.timeZone === 'UTC' && !options.day)
        return new Proxy(real, { get: (target, key) => key === 'format' ? () => { throw new TypeError('fault injected'); } : Reflect.get(target, key) });
      return real;
    } as unknown as typeof Intl.DateTimeFormat;
    (Intl as unknown as { DateTimeFormat: typeof Intl.DateTimeFormat }).DateTimeFormat = Patched;
  });
  await page.getByRole('link', { name: 'Feed' }).click();
  await expect(page.getByTestId('fault-feed')).toBeVisible();
  await expect(page.getByTestId('fault-feed')).toContainText('The feed hit a problem.');
  await shots(page, 'region-fault');
  // The navigation, the library and the chat panel are untouched.
  await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
  await expect(page.getByTestId('fault-feed')).toHaveCount(0);
});

test('chat down: the answer fails on its own; reading and the library keep working', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signInReader(page, request);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  const frame = page.frameLocator('[data-testid=reader-frame]');
  await expect(frame.locator('h1').first()).toBeVisible();
  await fault(request, 'functions/v1/chat', 503);
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Why is the reference model needed?');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  // The first question asks for the cloud consent, as in chat.spec.
  await expect(page.getByRole('dialog', { name: 'Cloud AI answers' })).toBeVisible();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.locator('.chat-issue[role=alert]')).toBeVisible({ timeout: 15_000 });
  await shots(page, 'chat-down');
  // The paper is still there and readable, and the library opens.
  await expect(frame.locator('h1').first()).toBeVisible();
  await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
});

test('feed down: the last page stays, said as of then; the library keeps working', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signInReader(page, request);
  await page.getByRole('link', { name: 'Feed' }).click();
  await expect(page.getByTestId('feed-grid')).toBeVisible();
  await fault(request, 'functions/v1/discover', 503);
  await page.getByRole('button', { name: /Refresh/ }).first().click();
  await expect(page.getByText('Couldn’t refresh. These are the papers from your last update.')).toBeVisible();
  await expect(page.getByTestId('feed-grid')).toBeVisible();
  await shots(page, 'feed-stale');
  await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
});

test('sign-in email down: the limit is said plainly and Apple and Google stay available', async ({ page, request }) => {
  await request.post(`${API}/__reset`);
  await fault(request, 'auth/v1/otp', 429);
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await expect(page.getByRole('alert')).toContainText(/Too many attempts|Wait/);
  await expect(page.getByTestId('oauth-apple')).toBeEnabled();
  await expect(page.getByTestId('oauth-google')).toBeEnabled();
  await shots(page, 'email-down');
});
