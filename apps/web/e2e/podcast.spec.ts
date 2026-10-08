// Paper podcasts in the browser against the fixture backend's labeled synthetic episodes (generated WAV tones; no
// provider, no spend). Production build and CSP (media-src blob: only).
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';

const API = 'http://127.0.0.1:54329';
const SHOTS = '../../.artifacts/podcast-web';

async function login(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
const currentTime = (page: Page) => page.getByTestId('podcast-audio').evaluate(e => (e as HTMLAudioElement).currentTime);
const evidence = async (request: { get: (url: string) => Promise<{ json: () => Promise<unknown> }> }) =>
  (await request.get(`${API}/__podcast-evidence`)).json() as Promise<{ grants: number; redemptions: { range: string | null }[] }>;

async function startPlaying(page: Page) {
  await page.getByTestId('podcast-play').first().click();
  const dock = page.getByTestId('podcast-dock');
  await expect(dock).toBeVisible();
  await expect(page.getByTestId('podcast-audio')).toHaveAttribute('src', /^blob:/);
  // An autoplay refusal leaves "Press play to start"; pressing Play is the listener's own gesture.
  const toggle = page.getByTestId('podcast-toggle');
  await expect(toggle).toBeEnabled();
  if (await toggle.getAttribute('aria-label') === 'Play') await toggle.click();
  await expect(toggle).toHaveAttribute('aria-label', 'Pause');
  return dock;
}

test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

test('Listen filter → verified single-use download → docked player, transcript and chapter seeking, evidence passage', async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit', 'The existing key persistence gate is tested separately.');
  const errors: string[] = [], remote: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('request', r => { if (!/^(http:\/\/127\.0\.0\.1:|data:|blob:)/.test(r.url())) remote.push(r.url()); });
  // Reduced motion: transcript following jumps instead of animating, which also keeps screenshots deterministic.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await login(page);
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('podcast-listen').click();
  await expect(page.getByTestId('podcast-listen')).toHaveAttribute('aria-pressed', 'true');
  const cards = page.getByTestId('podcast-card');
  await expect(cards).toHaveCount(2);
  const first = cards.first();
  for (const text of ['AI audio', 'Synthetic fixture', '48 s', 'Alignment', '2023']) await expect(first).toContainText(text);
  await page.screenshot({ path: `${SHOTS}/listen-light-${info.project.name}.png` });

  const dock = await startPlaying(page);
  let seen = await evidence(request);
  expect(seen.grants).toBe(1);
  expect(seen.redemptions).toEqual([{ range: null, authorized: true }]);
  await expect(first).toHaveClass(/current/);

  await page.getByTestId('podcast-expand').click();
  await expect(page.getByTestId('podcast-transcript')).toBeVisible();
  await page.getByTestId('podcast-segment').nth(4).click();
  await expect.poll(() => currentTime(page)).toBeGreaterThanOrEqual(32);
  expect(await currentTime(page)).toBeLessThan(36);
  await expect(page.getByTestId('podcast-segment').nth(4)).toHaveAttribute('aria-current', 'true');
  await page.getByTestId('podcast-chapter').filter({ hasText: 'How the objective works' }).click();
  await expect.poll(() => currentTime(page)).toBeGreaterThanOrEqual(16);
  expect(await currentTime(page)).toBeLessThan(20);
  await page.getByTestId('podcast-speed').selectOption('1.5');
  expect(await page.getByTestId('podcast-audio').evaluate(e => (e as HTMLAudioElement).playbackRate)).toBe(1.5);
  await page.getByRole('button', { name: 'Back 15 seconds' }).click();
  expect(await currentTime(page)).toBeLessThan(6);
  await page.getByTestId('podcast-toggle').click();
  await expect(page.getByTestId('podcast-toggle')).toHaveAttribute('aria-label', 'Play');
  await page.screenshot({ path: `${SHOTS}/player-light-${info.project.name}.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${SHOTS}/player-dark-${info.project.name}.png` });
  await page.emulateMedia({ colorScheme: 'light' });

  // Evidence for a paper in the library opens its cited passage; the dock stays and never covers the chat composer.
  await page.getByTestId('podcast-evidence').first().click();
  await expect(page).toHaveURL(/\/paper\/aaaaaaaa-0000-4000-8000-000000000001$/);
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  await expect(page.getByTestId('citation-back')).toBeVisible();
  await expect(page.getByText('Couldn’t find the passage')).toHaveCount(0);
  await expect(dock).toBeVisible();
  // The jump folded the dock to its bar so the passage has the room.
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'false');
  if (info.project.name === 'desktop') {
    if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
    const composer = (await page.locator('.chat-composer').boundingBox())!, docked = (await dock.boundingBox())!;
    expect(composer.y + composer.height).toBeLessThanOrEqual(docked.y + 1);
    const reader = (await page.getByTestId('reader-frame').boundingBox())!;
    expect(reader.y + reader.height).toBeLessThanOrEqual(docked.y + 1);
    await page.screenshot({ path: `${SHOTS}/paper-with-dock-light-${info.project.name}.png` });
  }

  // Back in Listen: the second paper isn't in the library, so its evidence offers the source link instead.
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('podcast-listen').click();
  await page.getByTestId('podcast-play').nth(1).click();
  await expect(page.getByTestId('podcast-toggle')).toBeEnabled();
  await page.getByTestId('podcast-expand').click();
  await page.getByTestId('podcast-evidence').first().click();
  await expect(page.getByRole('status').filter({ hasText: 'isn’t in your library' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open it on arXiv' })).toHaveAttribute('href', 'https://arxiv.org/abs/1706.03762v7');
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${SHOTS}/listen-dark-${info.project.name}.png` });
  await page.emulateMedia({ colorScheme: 'light' });

  // Each play is a new single-use grant; the place saved at Stop is resumed, and the dock and its audio go away.
  await page.getByTestId('podcast-play').first().click();
  await expect(page.getByTestId('podcast-toggle')).toBeEnabled();
  await expect.poll(() => currentTime(page)).toBeLessThan(6);
  await page.getByTestId('podcast-position').fill('24000');
  await expect.poll(() => currentTime(page)).toBeGreaterThanOrEqual(24);
  await page.getByTestId('podcast-stop').click();
  await expect(page.getByTestId('podcast-dock')).toHaveCount(0);
  expect(await page.getByTestId('podcast-audio').getAttribute('src')).toBeNull();
  await page.getByTestId('podcast-play').first().click();
  await expect(page.getByTestId('podcast-toggle')).toBeEnabled();
  expect(await currentTime(page)).toBeGreaterThanOrEqual(23);
  seen = await evidence(request);
  expect(seen.grants).toBe(4);
  expect(seen.redemptions.every(r => r.range === null)).toBe(true);
  expect(errors).toEqual([]);
  expect(remote).toEqual([]);
});

test('without the podcast capability, Listen explains and the Feed keeps working', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__podcast-fixture`, { data: { mode: 'disabled' } });
  await login(page);
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('podcast-listen').click();
  await expect(page.getByTestId('podcast-unavailable')).toContainText('Listening isn’t available yet');
  await expect(page.getByTestId('podcast-dock')).toHaveCount(0);
  await page.getByRole('button', { name: 'Machine learning' }).first().click();
  await expect(page.getByTestId('feed-grid')).toBeVisible();
});

test('the docked player is keyboard operable', async ({ page }, info) => {
  test.skip(info.project.name !== 'desktop');
  await login(page);
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('podcast-listen').click();
  await startPlaying(page);
  await page.getByTestId('podcast-toggle').focus();
  await page.keyboard.press('Enter');
  await expect(page.getByTestId('podcast-toggle')).toHaveAttribute('aria-label', 'Play');
  await page.getByTestId('podcast-expand').focus();
  await page.keyboard.press('Space');
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'true');
  await page.getByTestId('podcast-segment').nth(2).focus();
  await page.keyboard.press('Enter');
  await expect.poll(() => currentTime(page)).toBeGreaterThanOrEqual(16);
  await expect(page.getByTestId('podcast-position')).toHaveAttribute('aria-valuetext', /of 0:48$/);
});
