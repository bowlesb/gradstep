import { expect, test, type Page } from '@playwright/test';
import { fixtureOrigin as fixture } from './environment';
const release = 'a0000000-0000-4000-8000-000000000001';
const account = '11111111-2222-4333-8444-555555555555', sessionKey = 'gradstep.podcast-fixture.session', path = '/e2e/podcast-harness.html';
const control = (page: Page, data: unknown) => page.request.post(`${fixture}/__control`, { data });
const calls = async (page: Page) => (await (await page.request.get(`${fixture}/__state`)).json()).calls as { action: string; body: Record<string, unknown> }[];
const count = async (page: Page, action: string) => (await calls(page)).filter(c => c.action === action).length;
const status = (page: Page) => page.evaluate(() => (window as any).podcastFixture.player.status);
async function openPlayer(page: Page) { await page.getByTestId('podcast-play').click(); await expect.poll(() => status(page)).toBe('ready'); await page.evaluate(() => (window as any).podcastFixture.player.pause()); }
async function seek(page: Page, position: number) { await page.evaluate(value => (window as any).podcastFixture.player.seek(value), position); }
async function relogin(page: Page) { await page.evaluate(sessionKey => { const prior = JSON.parse(localStorage.getItem(sessionKey)!);
  localStorage.setItem(sessionKey, JSON.stringify({ ...prior, lifetime: 'next-login' })); window.dispatchEvent(new StorageEvent('storage', { key: sessionKey, newValue: localStorage.getItem(sessionKey) })); }, sessionKey); }
async function quote(page: Page) { await page.getByTestId('podcast-paper-listen').click(); await page.getByRole('button', { name: 'Get an estimate' }).click(); await expect(page.getByTestId('podcast-estimate')).toBeVisible(); }
test.beforeEach(async ({ page }) => {
  await page.request.post(`${fixture}/__reset`);
  await page.addInitScript(({ account, sessionKey }) => {
    if (!localStorage.getItem(sessionKey)) localStorage.setItem(sessionKey, JSON.stringify({ accessToken: 'fixture-access', refreshToken: 'fixture-refresh', expiresAt: Date.now() / 1000 + 3600,
      lifetime: 'fixture-login', user: { id: account, email: 'fixture@example.test' } }));
    const handlers: Record<string, any> = {}; (window as any).mediaHandlers = handlers;
    if ('mediaSession' in navigator) { const original = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
      navigator.mediaSession.setActionHandler = (name, handler) => { handlers[name] = handler; return original(name, handler); }; }
    const originalRevoke = URL.revokeObjectURL.bind(URL); (window as any).revocations = [];
    URL.revokeObjectURL = value => { (window as any).revocations.push(value); originalRevoke(value); };
  }, { account, sessionKey });
  await page.route('https://**', route => route.abort()); await page.goto(path); await expect(page.getByTestId('podcast-card')).toHaveCount(1);
});

test('verified playback, idempotent media commands, rate, chapters, transcript, evidence and explicit Add', async ({ page }) => {
  await openPlayer(page);
  await page.evaluate(() => { (window as any).mediaHandlers.pause({}); (window as any).mediaHandlers.pause({}); });
  expect(await page.locator('audio').evaluate((e: HTMLAudioElement) => e.paused)).toBe(true);
  await page.evaluate(() => { (window as any).mediaHandlers.play({}); (window as any).mediaHandlers.play({}); });
  await expect.poll(() => page.locator('audio').evaluate((e: HTMLAudioElement) => e.paused)).toBe(false);
  await page.evaluate(() => (window as any).mediaHandlers.pause({})); await page.getByTestId('podcast-speed').selectOption('1.5');
  expect(await page.locator('audio').evaluate((e: HTMLAudioElement) => e.playbackRate)).toBe(1.5);
  await page.getByTestId('podcast-expand').click(); await page.getByTestId('podcast-chapter').nth(1).click();
  await expect(page.getByTestId('podcast-position')).toHaveValue('16000'); await page.getByTestId('podcast-segment').nth(1).click();
  await expect(page.getByTestId('podcast-position')).toHaveValue('8000'); await page.getByTestId('podcast-evidence').click();
  await expect(page.getByTestId('fixture-passage')).toContainText('binary cross-entropy'); await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'false');
  await page.getByLabel('Paper in library').uncheck(); await page.getByTestId('podcast-expand').click(); await page.getByTestId('podcast-evidence').click();
  await expect(page.getByRole('link', { name: 'Open source' })).toHaveAttribute('href', 'https://arxiv.org/abs/2305.18290v3');
  await expect(page.getByTestId('fixture-added')).toBeEmpty(); await page.getByRole('button', { name: 'Add to library', exact: true }).click();
  await expect(page.getByTestId('fixture-added')).toHaveText('Added by explicit action');
  const dock = await page.getByTestId('podcast-dock').boundingBox(), composer = await page.getByLabel('Paper chat composer').boundingBox(); expect(composer!.y + composer!.height).toBeLessThanOrEqual(dock!.y);
  const actions = (await calls(page)).map(c => c.action); expect(actions.indexOf('states')).toBeLessThan(actions.indexOf('download')); expect(await count(page, 'download')).toBe(1); expect(await count(page, 'start')).toBe(0);
  await page.screenshot({ path: '../../.artifacts/podcast-client/player-desktop.png' });
});

test('quote confirmation, lost-start identity, bounded polling, ready charge and private library title', async ({ page }) => {
  await control(page, { loseStart: true }); await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByRole('button', { name: 'Get an estimate' })).toBeVisible();
  expect(await count(page, 'quote')).toBe(0); expect(await count(page, 'start')).toBe(0); await page.getByRole('button', { name: 'Get an estimate' }).click();
  await expect(page.getByTestId('podcast-estimate')).toContainText('maximum 150 credits'); await expect(page.getByRole('dialog')).toContainText('Anthropic (script) and Google Vertex AI (speech)');
  await expect(page.getByRole('dialog')).toContainText('aren’t end-to-end encrypted'); expect(await count(page, 'start')).toBe(0);
  await page.screenshot({ path: '../../.artifacts/podcast-client/private-consent-desktop.png' });
  await page.getByTestId('podcast-confirm').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request'); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-job-state')).toContainText('Waiting to start');
  const starts = (await calls(page)).filter(c => c.action === 'start'); expect(starts).toHaveLength(2); expect(starts[0].body).toEqual(starts[1].body);
  expect(starts[0].body.request_id).toBe((await calls(page)).find(c => c.action === 'quote')!.body.request_id);
  await page.clock.install(); await page.clock.fastForward(5_000); await expect(page.getByTestId('podcast-job-state')).toContainText('Checking it against');
  await page.clock.fastForward(5_000); await expect(page.getByTestId('podcast-job-state')).toContainText('ready'); await expect(page.getByTestId('podcast-charges')).toHaveText('43 credits charged · 107 released.');
  await page.clock.fastForward(60_000); expect(await count(page, 'status')).toBe(2);
  await page.getByRole('button', { name: 'Play episode', exact: true }).click(); await expect.poll(() => status(page)).toBe('ready'); await expect(page.getByTestId('podcast-dock')).toContainText('My library paper title');
});

test('disabled capability blocks generation; cancellation is explicit, closing keeps work running', async ({ page }) => {
  await control(page, { generation: false }); await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-generation-unavailable')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Get an estimate' })).toHaveCount(0); expect(await count(page, 'quote')).toBe(0); expect(await count(page, 'start')).toBe(0);
  await page.getByRole('button', { name: 'Close Listen' }).click(); await control(page, { generation: true, readyAfter: 100 }); await quote(page); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-job-state')).toBeVisible(); await page.getByRole('button', { name: 'Close Listen' }).click(); expect(await count(page, 'cancel')).toBe(0);
  await page.getByTestId('podcast-paper-listen').click(); await page.getByRole('button', { name: 'Cancel generation' }).click();
  await expect(page.getByTestId('podcast-job-state')).toContainText('Generation canceled'); await expect(page.getByTestId('podcast-charges')).toHaveText('0 credits charged · 150 released.');
});

test('an overlong paper gets an actionable explanation instead of a retry dead end', async ({ page }) => {
  await control(page, { quoteError: 'source_too_large' });
  await page.getByTestId('podcast-paper-listen').click();
  await page.getByRole('button', { name: 'Get an estimate' }).click();
  await expect(page.getByTestId('podcast-source-too-large')).toBeVisible();
  await expect(page.getByTestId('podcast-source-too-large')).toContainText('too long for a full-paper episode at any available length');
  await expect(page.getByTestId('podcast-source-too-large')).toContainText('Nothing was charged');
  await expect(page.getByTestId('podcast-confirm')).toHaveCount(0);
  await page.getByRole('button', { name: 'Back to paper' }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('tampering prevents playback and canceling delivery prevents late Blob installation', async ({ page }) => {
  await control(page, { corrupt: true }); await page.getByTestId('podcast-play').click(); await expect(page.getByRole('alert')).toContainText('checksum'); expect(await page.locator('audio').getAttribute('src')).toBeNull();
  await page.getByTestId('podcast-stop').click(); await control(page, { corrupt: false, memberDelay: 600 }); await page.getByTestId('podcast-play').click(); await expect.poll(() => count(page, 'member')).toBe(2);
  await page.getByTestId('podcast-stop').click(); await page.waitForTimeout(800); await expect(page.getByTestId('podcast-dock')).toHaveCount(0); expect(await page.locator('audio').getAttribute('src')).toBeNull();
});

test('external auth retirement clears positions; ordinary unmount retains resume and pauses detached audio', async ({ page }) => {
  await openPlayer(page); await seek(page, 12_000); expect(await page.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.positionMs, release)).toBe(12_000);
  await page.evaluate(() => { (window as any).oldAudio = document.querySelector('audio'); }); await relogin(page); await expect(page.getByTestId('podcast-dock')).toHaveCount(0);
  expect(await page.evaluate(() => Object.keys(localStorage).filter(k => k.includes('podcast-positions.')))).toEqual([]); expect(await page.evaluate(() => (window as any).oldAudio.paused)).toBe(true);
  await openPlayer(page); await seek(page, 9000); await page.evaluate(() => { (window as any).oldAudio = document.querySelector('audio'); }); await page.getByTestId('fixture-unmount').click();
  expect(await page.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.positionMs, release)).toBe(9000); expect(await page.evaluate(() => (window as any).oldAudio.paused)).toBe(true);
  expect(await page.evaluate(() => (window as any).oldAudio.getAttribute('src'))).toBeNull(); expect(await page.evaluate(() => (window as any).revocations.length)).toBeGreaterThanOrEqual(2);
});

test('auth retirement during delayed delivery cannot install an old episode', async ({ page }) => {
  await control(page, { memberDelay: 600 }); await page.getByTestId('podcast-play').click(); await expect.poll(() => count(page, 'member')).toBe(1); await relogin(page);
  await page.waitForTimeout(800); await expect(page.getByTestId('podcast-dock')).toHaveCount(0); expect(await page.locator('audio').getAttribute('src')).toBeNull();
});

test('bounded revocation checks remove audio and positions and offer replacement', async ({ page }) => {
  await openPlayer(page); await seek(page, 12_000); await page.clock.install();
  for (let i = 0; i < 3; i++) await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect.poll(() => count(page, 'states')).toBe(2); await control(page, { releaseState: 'superseded' }); await page.clock.fastForward(60_000);
  await expect(page.getByRole('alert')).toContainText('no longer available'); expect(await page.evaluate(id => (window as any).podcastFixture.loadPosition(id), release)).toBeNull();
  expect(await page.locator('audio').getAttribute('src')).toBeNull(); expect(await count(page, 'states')).toBe(3);
  await page.getByRole('button', { name: 'Open replacement' }).click(); await expect.poll(() => status(page)).toBe('ready');
});

test('two actual tabs retain independent playback and merge the newer session for next resume', async ({ page, context }) => {
  await openPlayer(page); await seek(page, 30_000); const second = await context.newPage(); await second.goto(path); await openPlayer(second); await seek(second, 5_000); await seek(page, 40_000);
  expect(await page.evaluate(() => (window as any).podcastFixture.player.positionMs)).toBe(40_000); expect(await second.evaluate(() => (window as any).podcastFixture.player.positionMs)).toBe(5_000);
  expect(await page.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.positionMs, release)).toBe(5_000);
});

test('phone layout keeps the dock in its own row and confirmation readable', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await openPlayer(page); await page.getByTestId('podcast-expand').click();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390); const dock = await page.getByTestId('podcast-dock').boundingBox(); expect(dock!.x).toBeGreaterThanOrEqual(0); expect(dock!.x + dock!.width).toBeLessThanOrEqual(390);
  await page.screenshot({ path: '../../.artifacts/podcast-client/player-phone.png' }); await quote(page); await expect(page.getByTestId('podcast-confirm')).toBeVisible(); await page.screenshot({ path: '../../.artifacts/podcast-client/private-consent-phone.png' });
});

test('quote reuse/join never starts new generation, expired estimates require a fresh explicit quote', async ({ page }) => {
  await control(page, { quoteOutcome: 'reuse' }); await page.getByTestId('podcast-paper-listen').click(); await page.getByRole('button', { name: 'Get an estimate' }).click();
  await expect(page.getByRole('button', { name: 'Play episode', exact: true })).toBeVisible(); expect(await count(page, 'start')).toBe(0);
  await page.getByRole('button', { name: 'Close Listen' }).click(); await control(page, { quoteOutcome: 'join', readyAfter: 100 });
  await page.getByTestId('podcast-paper-listen').click(); await page.getByRole('button', { name: 'Get an estimate' }).click();
  await expect(page.getByTestId('podcast-job-state')).toContainText('Checking'); expect(await count(page, 'start')).toBe(0);
  await page.getByRole('button', { name: 'Close Listen' }).click(); await page.request.post(`${fixture}/__reset`);
  await quote(page); await page.clock.install(); await page.clock.fastForward(61_000); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByRole('alert')).toContainText('expired'); expect(await count(page, 'start')).toBe(0); await expect(page.getByRole('button', { name: 'Get an estimate' })).toBeVisible();
});

test('transient revocation errors preserve verified audio; no bytes enter persistent browser storage', async ({ page }) => {
  await openPlayer(page); await seek(page, 10_000); await control(page, { stateError: true });
  await page.evaluate(() => window.dispatchEvent(new Event('online'))); await expect.poll(() => count(page, 'states')).toBe(2);
  expect(await status(page)).toBe('ready'); expect(await page.locator('audio').getAttribute('src')).toMatch(/^blob:/);
  expect(await page.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.positionMs, release)).toBe(10_000);
  expect(await page.evaluate(() => Object.values(localStorage).some(value => value.includes('data:audio') || value.includes('blob:')))).toBe(false);
  expect(await page.evaluate(() => caches.keys())).toEqual([]); expect(await page.evaluate(() => indexedDB.databases())).toEqual([]);
  const headers = (await page.request.get(path)).headers(); expect(headers['content-security-policy']).toContain('media-src blob:');
});

test('retired account cannot consume late private-start UI response', async ({ page }) => {
  await control(page, { startDelay: 600 }); await quote(page); await page.getByTestId('podcast-confirm').click(); await expect.poll(() => count(page, 'start')).toBe(1);
  await relogin(page); await page.waitForTimeout(800); await expect(page.getByRole('dialog')).not.toBeVisible(); await expect(page.getByTestId('podcast-job-state')).toHaveCount(0);
  expect(await count(page, 'status')).toBe(0); expect(await count(page, 'start')).toBe(1);
});

test('another tab mount, ordinary unmount and remount preserve a saved resume point', async ({ page, context }) => {
  await openPlayer(page); await seek(page, 30_000);
  const second = await context.newPage(); await second.goto(path); await expect(second.getByTestId('podcast-card')).toHaveCount(1);
  expect(await second.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.positionMs, release)).toBe(30_000);
  await second.getByTestId('fixture-unmount').click(); await second.getByTestId('fixture-unmount').click();
  await expect(second.getByTestId('podcast-card')).toHaveCount(1);
  expect(await second.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.positionMs, release)).toBe(30_000);
  await openPlayer(second); const resumed = await second.locator('audio').evaluate((e: HTMLAudioElement) => e.currentTime);
  expect(resumed).toBeGreaterThanOrEqual(30); expect(resumed).toBeLessThan(32);
});

test('completion survives Stop and late media events cannot restore its media-session state', async ({ page }) => {
  await openPlayer(page); await seek(page, 47_900); await page.evaluate(() => (window as any).podcastFixture.player.play());
  await expect.poll(() => page.locator('audio').evaluate((e: HTMLAudioElement) => e.ended)).toBe(true);
  await page.getByTestId('podcast-stop').click();
  expect(await page.evaluate(id => (window as any).podcastFixture.loadPosition(id)?.completed, release)).toBe(true);
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => navigator.mediaSession.playbackState)).toBe('none');
});


const unresolved = (page: Page) => page.evaluate(() => Object.entries(sessionStorage).filter(([key]) => key.includes('.podcast-requests.'))
  .flatMap(([, value]) => JSON.parse(value).records as { itemID: string; requestID: string; quoteID: string; expiresAt: number }[]));

test('lost Start survives sheet close, component navigation and reload with no automatic paid replay', async ({ page }) => {
  await control(page, { loseStart: true, hidePaperJob: true, statusUnavailable: true, readyAfter: 100 });
  await quote(page); await page.getByTestId('podcast-confirm').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  const [original] = await unresolved(page); expect(original).toBeTruthy();
  await page.getByRole('button', { name: 'Close Listen' }).click();
  await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  await expect(page.getByRole('alert')).toBeVisible(); expect(await unresolved(page)).toEqual([original]);
  await page.getByRole('button', { name: 'Close Listen' }).click();
  await page.getByTestId('fixture-unmount').click(); await page.getByTestId('fixture-unmount').click();
  await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  await page.reload(); await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  expect(await unresolved(page)).toEqual([original]); expect(await count(page, 'start')).toBe(1); expect(await count(page, 'quote')).toBe(1);
  // Wait for the intentionally missing read receipt before changing the fixture; a successful
  // in-flight status read would correctly reconcile and remove Retry without another Start.
  await expect(page.getByTestId('podcast-confirm')).toBeEnabled();
  await control(page, { statusUnavailable: false }); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-job-state')).toBeVisible();
  const starts = (await calls(page)).filter(c => c.action === 'start'); expect(starts).toHaveLength(2); expect(starts[1].body).toEqual(starts[0].body);
  expect(await unresolved(page)).toEqual([]);
});

test('closing before admission preserves the Start identity while a missing status is still inconclusive', async ({ page }) => {
  await control(page, { startAdmissionDelay: 900, hidePaperJob: true, readyAfter: 100 });
  await quote(page); await page.getByTestId('podcast-confirm').click(); await expect.poll(() => count(page, 'start')).toBe(1);
  const [original] = await unresolved(page); await page.getByRole('button', { name: 'Close Listen' }).click();
  await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  expect(await unresolved(page)).toEqual([original]); expect(await count(page, 'quote')).toBe(1);
  await page.waitForTimeout(1000); await page.getByRole('button', { name: 'Check request status' }).click();
  await expect(page.getByTestId('podcast-job-state')).toContainText('Checking'); expect(await count(page, 'start')).toBe(1); expect(await unresolved(page)).toEqual([]);
});

test('late Start reuse and lost reuse receipt are read back before explicit Play, without another paid call', async ({ page }) => {
  await control(page, { startOutcome: 'reuse', loseStart: true, hidePaperJob: true, episodeError: true });
  await quote(page); await page.getByTestId('podcast-confirm').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  const original = await unresolved(page); await page.getByRole('button', { name: 'Close Listen' }).click();
  await page.reload(); await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByRole('alert')).toBeVisible();
  expect(await unresolved(page)).toEqual(original); expect(await count(page, 'start')).toBe(1);
  await control(page, { episodeError: false }); await page.getByRole('button', { name: 'Check request status' }).click();
  await expect(page.getByRole('button', { name: 'Play episode', exact: true })).toBeVisible();
  expect(await unresolved(page)).toEqual([]); expect(await count(page, 'download')).toBe(0); expect(await count(page, 'cancel')).toBe(0);
  await page.getByRole('button', { name: 'Play episode', exact: true }).click(); await expect.poll(() => status(page)).toBe('ready');
  expect(await count(page, 'start')).toBe(1); await expect(page.getByTestId('podcast-dock')).toContainText('My library paper title');
});

test('a ready release returned by Start is offered as Play immediately', async ({ page }) => {
  await control(page, { startOutcome: 'reuse' }); await quote(page); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByRole('button', { name: 'Play episode', exact: true })).toBeVisible();
  expect(await count(page, 'start')).toBe(1); expect(await count(page, 'download')).toBe(0); expect(await unresolved(page)).toEqual([]);
});

test('storage refusal prevents Start, and retiring auth clears unresolved hints after navigation', async ({ page }) => {
  await quote(page);
  await page.evaluate(() => { const original = Storage.prototype.setItem; (window as any).restoreRequestStorage = () => { Storage.prototype.setItem = original; };
    Storage.prototype.setItem = function (key, value) { if (this === sessionStorage && key.includes('.podcast-requests.')) throw new DOMException('full', 'QuotaExceededError'); return original.call(this, key, value); }; });
  await page.getByTestId('podcast-confirm').click(); await expect(page.getByRole('alert')).toContainText('No new episode request was sent'); expect(await count(page, 'start')).toBe(0);
  await page.evaluate(() => (window as any).restoreRequestStorage()); await page.getByRole('button', { name: 'Close Listen' }).click();
  await control(page, { loseStart: true, hidePaperJob: true, statusUnavailable: true }); await quote(page); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request'); expect(await unresolved(page)).toHaveLength(1);
  await page.getByRole('button', { name: 'Close Listen' }).click(); await page.getByTestId('fixture-unmount').click(); await relogin(page);
  expect(await unresolved(page)).toEqual([]); await page.getByTestId('fixture-unmount').click();
  await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByRole('button', { name: 'Get an estimate' })).toBeVisible();
  expect(await count(page, 'start')).toBe(1);
});

test('an expired quote after an ambiguous attempt cannot discard or replace its old request', async ({ page }) => {
  await control(page, { dropStartBeforeAdmission: true, hidePaperJob: true }); await quote(page); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request'); const original = await unresolved(page);
  await control(page, { dropStartBeforeAdmission: false, startError: 'quote_expired' }); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByRole('alert')).toContainText('earlier request may have started'); expect(await unresolved(page)).toEqual(original);
  await expect(page.getByRole('button', { name: 'Get an estimate' })).toHaveCount(0);
  const starts = (await calls(page)).filter(c => c.action === 'start'); expect(starts[1].body).toEqual(starts[0].body); expect(await count(page, 'quote')).toBe(1);
});


test('evidence waits for winning navigation and ignores superseded or retired callbacks', async ({ page }) => {
  await openPlayer(page); await page.getByTestId('podcast-expand').click();
  await page.evaluate(() => (window as any).podcastFixture.holdEvidence()); await page.getByTestId('podcast-evidence').click();
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'true');
  await page.evaluate(() => (window as any).podcastFixture.finishEvidence(null));
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'true'); await expect(page.getByRole('button', { name: 'Add to library', exact: true })).toHaveCount(0);
  await page.getByTestId('podcast-evidence').click(); await page.evaluate(() => (window as any).podcastFixture.finishEvidence(true));
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'false');
  await page.getByTestId('podcast-expand').click(); await page.getByTestId('podcast-evidence').click(); await relogin(page);
  await openPlayer(page); await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'true');
  await page.evaluate(() => (window as any).podcastFixture.finishEvidence(true));
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'true');
});


test('a first explicit expiry rejection requires a fresh quote, but malformed retained tracking never permits Start', async ({ page }) => {
  await control(page, { startError: 'quote_expired' }); await quote(page); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByRole('button', { name: 'Get an estimate' })).toBeVisible(); expect(await unresolved(page)).toEqual([]);
  await control(page, { startError: null, loseStart: true }); await page.getByRole('button', { name: 'Get an estimate' }).click();
  await page.getByTestId('podcast-confirm').click(); await expect(page.getByTestId('podcast-confirm')).toHaveText('Retry same request');
  const key = await page.evaluate(() => Object.keys(sessionStorage).find(key => key.includes('.podcast-requests.'))!);
  await page.evaluate(key => sessionStorage.setItem(key, '{"version":2,"records":[]}'), key);
  await page.reload(); await page.getByTestId('podcast-paper-listen').click();
  await expect(page.getByRole('alert')).toContainText('couldn’t retain');
  await expect(page.getByTestId('podcast-confirm')).toHaveCount(0); expect(await count(page, 'start')).toBe(2);
  expect(await page.evaluate(key => sessionStorage.getItem(key), key)).toBe('{"version":2,"records":[]}');
});


test('two Start events before React commits still dispatch one paid request', async ({ page }) => {
  await control(page, { startDelay: 500 }); await quote(page);
  await page.getByTestId('podcast-confirm').evaluate(button => { button.dispatchEvent(new MouseEvent('click', { bubbles: true })); button.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
  await expect(page.getByTestId('podcast-job-state')).toBeVisible(); expect(await count(page, 'start')).toBe(1);
});
