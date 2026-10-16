import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin } from './environment';
import { durableKeys } from './key-capability';

async function openPaper(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('[data-sr-reference]').first()).toBeAttached();
}
async function openReference(page: Page) {
  const entry = page.frameLocator('[data-testid=reader-frame]').locator('[data-sr-reference]').first();
  await entry.scrollIntoViewIfNeeded(); await entry.click({ position: { x: 10, y: 10 } });
  await expect(page.getByRole('dialog', { name: 'Reference actions' })).toBeVisible();
}

test('verified bibliography actions use the existing reference endpoint and keep paid chat explicit', async ({ page, request }) => {
  test.skip(process.env.WEB_E2E_DEV === '1', 'Production journey; harness journeys use the dev server.');
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await request.post(`${fixtureOrigin}/__reset`);
  const bodies: Record<string, unknown>[] = []; let chats = 0;
  page.on('request', r => { if (r.method() === 'POST' && r.url().endsWith('/functions/v1/chat')) chats++; });
  await page.route(`${fixtureOrigin}/functions/v1/add-reference`, async route => {
    bodies.push(route.request().postDataJSON());
    if (bodies.length === 2) await route.fulfill({ status: 503, json: { error: 'temporarily_unavailable' } });
    else await route.fulfill({ json: { status: bodies.length === 1 ? 'not_found' : 'added', paper: { title: 'A matched paper' } } });
  });
  await openPaper(page); await openReference(page);
  const menu = page.getByRole('dialog', { name: 'Reference actions' });
  await expect(menu.getByRole('heading')).toHaveCount(0); // entry stays in view; no duplicate title
  await menu.getByRole('button', { name: 'Add to library' }).click();
  await expect(page.getByTestId('reference-notice')).toContainText('Couldn’t identify this reference.');
  await expect(page.getByRole('button', { name: 'Ask in chat' })).toBeVisible();
  expect(chats).toBe(0);
  expect(bodies[0]).toMatchObject({ capabilities: ['web_import'] });
  expect(bodies[0]).not.toHaveProperty('consent_version');
  expect(bodies[0]).not.toHaveProperty('messages');
  expect(typeof bodies[0].operation_id).toBe('string');
  await page.getByRole('button', { name: 'Dismiss reference message' }).click();
  await openReference(page); await menu.getByRole('button', { name: 'Add to library' }).click();
  await expect(page.getByTestId('reference-notice')).toContainText('Couldn’t add it right now.');
  await page.getByRole('button', { name: 'Try again' }).click();
  await expect(page.getByTestId('reference-notice')).toContainText('Added “A matched paper”.');
  expect(bodies[2]).toEqual(bodies[1]); // a retry keeps the operation identity and bytes
  expect(chats).toBe(0);
  await page.screenshot({ path: test.info().outputPath('reference.png') });
});

// A local reviewed bridge may be supplied for forward-contract integration before its shared branch merges.
// The default remains the repository bridge. This replaces only Vite's test module response; no shared file is edited.
const bridgePath = process.env.WEB_E2E_READER_BRIDGE;
async function bridgeForTest(page: Page) {
  const sample = new URL('../../apple/ScienceReader/Resources/ReaderSamples/cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/', import.meta.url);
  const manifest = readFileSync(new URL('manifest.json', sample));
  const members = new Map<string, Buffer>([['manifest.json', manifest]]);
  for (const { path } of JSON.parse(manifest.toString()).members) members.set(path, readFileSync(new URL(path, sample)));
  await page.route('**/__reader_sample/**', route => {
    const bytes = members.get(new URL(route.request().url()).pathname.split('/__reader_sample/')[1]);
    return route.fulfill(bytes ? { body: bytes, contentType: 'application/octet-stream' } : { status: 404 });
  });
  if (!bridgePath) return;
  const script = readFileSync(new URL('../src/reader/frame-shim.js', import.meta.url), 'utf8') + '\n' + readFileSync(bridgePath, 'utf8');
  const hash = 'sha256-' + createHash('sha256').update(script).digest('base64');
  await page.route(url => decodeURIComponent(url.pathname).includes('virtual:reader-frame'), route => route.fulfill({
    contentType: 'application/javascript', body: `export default ${JSON.stringify({ script, hash })};`,
  }));
}

test('Discuss waits for the host draft and leaves the reference recoverable on failure', async ({ page }) => {
  test.skip(process.env.WEB_E2E_DEV !== '1', 'Isolated callback harness uses Vite dev, never the production build.');
  await bridgeForTest(page);
  await page.goto('/e2e/reader-harness.html');
  await page.getByTestId('fail-draft').check();
  await openReference(page);
  let menu = page.getByRole('dialog', { name: 'Reference actions' });
  await page.screenshot({ path: test.info().outputPath('reference-actions.png') });
  await menu.getByRole('button', { name: 'Discuss in chat' }).click();
  await expect(menu.getByRole('alert')).toContainText('Couldn’t save the chat draft');
  await expect(page.getByRole('textbox', { name: 'Test composer' })).toHaveValue('Existing unsent draft');
  await menu.getByRole('button', { name: 'Cancel' }).click();
  await page.getByTestId('fail-draft').uncheck(); await openReference(page);
  menu = page.getByRole('dialog', { name: 'Reference actions' });
  await menu.getByRole('button', { name: 'Discuss in chat' }).click();
  await expect(menu).toHaveCount(0);
  await expect(page.getByRole('textbox', { name: 'Test composer' })).toHaveValue(/^About “.+”: Existing unsent draft$/);
  // Gallery Discussion uses the same callback, with the verified caption, and never calls selection/Send.
  await page.getByTestId('figures').click();
  await page.getByRole('list', { name: 'Figures' }).getByRole('button').first().click();
  await page.getByRole('button', { name: 'Explain in Chat', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('textbox', { name: 'Test composer' })).toHaveValue(/^About “.+”: About “.+”: Existing unsent draft$/);
});

test('new bridge figure reference details keep the reading return point through Go and modest scrolling', async ({ page }) => {
  test.skip(process.env.WEB_E2E_DEV !== '1', 'Forward-contract harness uses Vite dev.');
  const bridge = readFileSync(bridgePath ?? new URL('../../apple/ScienceReader/Resources/reader-bridge.js', import.meta.url), 'utf8');
  test.skip(!bridge.includes('FIGURE REFERENCES'), 'Shared figure-reference bridge not present yet.');
  await page.emulateMedia({ reducedMotion: 'reduce' }); await bridgeForTest(page);
  await page.goto('/e2e/reader-harness.html?dark');
  const frame = page.frameLocator('[data-testid=reader-frame]');
  for (const kind of ['Table', 'Figure']) {
    const link = frame.locator('.sr-cite[data-sr-figure]').filter({ hasText: new RegExp(`^${kind}\\b`) }).first();
    await expect(link).toBeAttached(); await link.scrollIntoViewIfNeeded();
    const origin = await frame.locator('body').evaluate(() => scrollY);
    await link.click();
    const detail = page.getByRole('dialog');
    await expect(detail).toBeVisible();
    await expect(detail.locator('iframe')).toBeVisible();
    await expect(detail.frameLocator('iframe').locator(kind === 'Figure' ? 'img' : 'table').first()).toBeVisible();
    await page.screenshot({ path: test.info().outputPath(`${kind.toLowerCase()}-reference-dark.png`) });
    await page.getByTestId('figure-reference-go').click();
    await expect(detail).toHaveCount(0);
    await expect(page.getByTestId('citation-back')).toBeVisible();
    await frame.locator('body').evaluate(() => scrollBy(0, 150));
    await expect(page.getByTestId('citation-back')).toBeVisible();
    await page.getByTestId('citation-back').click();
    await expect.poll(() => frame.locator('body').evaluate(() => scrollY)).toBeCloseTo(origin, 0);
  }
});
