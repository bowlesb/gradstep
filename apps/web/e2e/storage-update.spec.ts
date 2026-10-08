// Compatibility checkpoint (docs/architecture/BROWSER_OFFLINE_STORAGE.md): three real two-tab journeys in one Chromium
// profile against the local fixture backend. The second tab stands in for a newer release: it opens the `gradstep`
// database at version 2 (or proposes doing so) from a same-origin document that does not run the app. No hosted or
// paid requests are made; "requests" below are the fixture's local chat stream.
import { expect, test, type Page } from '@playwright/test';
import { durableKeys } from './key-capability';
import { RECOVERY_CODE } from './fixture-keys.mjs';

import { fixtureOrigin as API, appOrigin } from './environment';
const shots = '../../.artifacts/web-storage/';
const evidence = async (request: any) => (await request.get(`${API}/__chat-evidence`)).json();
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

async function login(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
async function openPaperChat(page: Page) {
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
}
const message = (page: Page) => page.getByRole('textbox', { name: 'Message', exact: true });
/** A same-origin document that does not run Gradstep: the newer release's stand-in. */
async function newerTab(page: Page) {
  const tab = await page.context().newPage();
  await tab.goto('/brand-icon.svg');
  return tab;
}
/** What a newer release does to activate a schema: open version 2. Reports how long the older tabs took to let go. */
const upgrade = (tab: Page) => tab.evaluate(() => new Promise<{ ms: number; blocked: boolean; version: number }>((resolve, reject) => {
  const start = performance.now(); let blocked = false;
  const request = indexedDB.open('gradstep', 2);
  request.onupgradeneeded = () => { request.result.createObjectStore('journal-probe'); };
  request.onblocked = () => { blocked = true; };
  request.onsuccess = () => { const db = request.result; resolve({ ms: performance.now() - start, blocked, version: db.version }); db.close(); };
  request.onerror = () => reject(new Error(String(request.error?.name)));
}));
const records = (tab: Page) => tab.evaluate(() => new Promise<{ version: number; devices: number; activity: number }>((resolve, reject) => {
  const request = indexedDB.open('gradstep');
  request.onsuccess = () => {
    const db = request.result, tx = db.transaction(['devices', 'activity']);
    const devices = tx.objectStore('devices').count(), activity = tx.objectStore('activity').count();
    tx.oncomplete = () => { resolve({ version: db.version, devices: devices.result, activity: activity.result }); db.close(); };
  };
  request.onerror = () => reject(new Error('unavailable'));
}));

test('an update during an answer stops it once, keeps unsent text copyable and lets the newer tab in promptly', async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit' || !await durableKeys(page), 'Requires durable non-extractable keys (WebKit 312279 gate).');
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: appOrigin });
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'slow' } });
  await login(page); await openPaperChat(page);
  await page.getByRole('button', { name: 'General', exact: true }).click();
  await message(page).fill('An unsent general draft to keep');
  await page.getByRole('button', { name: 'Paper', exact: true }).click();
  await message(page).fill('A slow answer'); await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('chat-streaming')).toContainText('objective');
  await message(page).fill('A newer paper draft typed while streaming');

  const newer = await newerTab(page);
  const opened = await upgrade(newer);
  // Bounded closure: this tab let go as soon as its accepted transactions finished, without a blocked newer tab.
  expect(opened.version).toBe(2); expect(opened.blocked).toBe(false); expect(opened.ms).toBeLessThan(3_000);

  const notice = page.getByTestId('storage-notice');
  await expect(notice).toContainText('Gradstep was updated in another tab');
  await expect(notice).toHaveAttribute('role', 'alert');
  await expect(page.getByTestId('chat-assistant').last()).toContainText('Answer interrupted');
  await expect(page.getByTestId('chat-streaming')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Send', exact: true })).toBeDisabled();
  await expect(message(page)).toHaveValue('A newer paper draft typed while streaming');
  await expect(message(page)).toHaveAttribute('readonly', '');
  await expect(page.getByTestId('chat-pane')).toContainText('This tab has stopped sending. Select your text to copy it.');
  // No duplicate or late paid request: one stream, saved question and interrupted answer only.
  await page.waitForTimeout(1_500);
  const e = await evidence(request);
  expect(e.requests).toHaveLength(1); expect(e.events).toHaveLength(3);

  // Volatile text remains readable and copyable with the keyboard.
  await page.getByRole('button', { name: 'General', exact: true }).click();
  await expect(message(page)).toHaveValue('An unsent general draft to keep');
  await message(page).focus();
  await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.press('ControlOrMeta+C');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('An unsent general draft to keep');
  await page.getByRole('button', { name: 'Paper', exact: true }).click();

  // Keyboard: the guidance sits right after the top bar in tab order.
  await page.getByTestId('account-menu').focus(); await page.keyboard.press('Tab');
  await expect(page.getByRole('button', { name: 'Reload this tab' })).toBeFocused();
  await page.screenshot({ path: `${shots}${info.project.name}-update-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${shots}${info.project.name}-update-dark.png` });
  // The existing departure warning still protects unsent text; nothing reloads by itself.
  let warned = false;
  page.on('dialog', dialog => { warned = dialog.type() === 'beforeunload'; void dialog.dismiss(); });
  await page.close({ runBeforeUnload: true });
  await expect.poll(() => warned).toBe(true);
  expect(errors).toEqual([]);
  await newer.close();
});

test('a reading save resumed after the update is refused; reopening shows the update barrier and leaves storage intact', async ({ page }, info) => {
  test.skip(info.project.name === 'webkit' || !await durableKeys(page), 'Requires durable non-extractable keys (WebKit 312279 gate).');
  await login(page);
  const newer = await newerTab(page);
  const before = await records(newer);
  expect(before).toMatchObject({ version: 1, devices: 1 });
  // Hold this tab's next reading-place encryption, so its write starts only after the update.
  await page.evaluate(() => {
    const hooks = window as unknown as { releaseActivity?: () => void; activityWaiting?: boolean };
    const encrypt = crypto.subtle.encrypt.bind(crypto.subtle);
    crypto.subtle.encrypt = (async (algorithm: AesGcmParams, key: CryptoKey, data: BufferSource) => {
      const value = await encrypt(algorithm, key, data);
      if (!hooks.activityWaiting && algorithm.additionalData && new TextDecoder().decode(algorithm.additionalData as ArrayBuffer).startsWith('gradstep/web-reading/v1/')) {
        hooks.activityWaiting = true;
        return new Promise<ArrayBuffer>(resolve => { hooks.releaseActivity = () => resolve(value); });
      }
      return value;
    }) as typeof crypto.subtle.encrypt;
  });
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await page.waitForFunction(() => (window as unknown as { activityWaiting?: boolean }).activityWaiting);
  const opened = await upgrade(newer);
  expect(opened).toMatchObject({ version: 2, blocked: false });
  await expect(page.getByTestId('storage-notice')).toContainText('Gradstep was updated in another tab');
  await page.evaluate(() => (window as unknown as { releaseActivity: () => void }).releaseActivity());
  await page.waitForTimeout(1_000);
  // The resumed callback could not write into the newer database.
  expect(await records(newer)).toEqual({ version: 2, devices: 1, activity: before.activity });

  // Reopening this release over the newer database: an explanation and a reload button, not "browser unsupported",
  // and no automatic reload, downgrade or deletion.
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Gradstep was updated in another tab' })).toBeVisible();
  await expect(page.getByRole('alert')).toContainText('This tab can’t use this browser’s Gradstep storage any more');
  await expect(page.getByText('This browser isn’t allowing Gradstep to store its keys')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Reload this page' })).toBeVisible();
  await page.keyboard.press('Tab');
  for (let i = 0; i < 4 && !await page.getByRole('button', { name: 'Reload this page' }).evaluate(b => b === document.activeElement); i++) await page.keyboard.press('Tab');
  await expect(page.getByRole('button', { name: 'Reload this page' })).toBeFocused();
  await page.screenshot({ path: `${shots}${info.project.name}-reopen-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${shots}${info.project.name}-reopen-dark.png` });
  expect(await records(newer)).toEqual({ version: 2, devices: 1, activity: before.activity });
  await newer.close();
});

test('a tab with unsent work asks a proposed update to wait, then releases it; nothing upgrades by itself', async ({ page }, info) => {
  test.skip(info.project.name === 'webkit' || !await durableKeys(page), 'Requires durable non-extractable keys (WebKit 312279 gate).');
  await login(page); await openPaperChat(page);
  await message(page).fill('Work that is not sent yet');
  const newer = await newerTab(page);
  const propose = () => newer.evaluate(() => new Promise<unknown[]>(resolve => {
    const channel = new BroadcastChannel('gradstep.storage'), replies: unknown[] = [], proposal = crypto.randomUUID();
    channel.onmessage = event => replies.push(event.data);
    channel.postMessage({ kind: 'upgrade-proposal', proposal, version: 2 });
    (window as unknown as { channel: BroadcastChannel }).channel = channel;
    setTimeout(() => resolve(replies.map(r => ({ ...(r as object), proposal: (r as { proposal: string }).proposal === proposal }))), 800);
  }));
  expect(await propose()).toEqual([{ kind: 'upgrade-reply', proposal: true, ready: false }]);
  const notice = page.getByTestId('storage-notice');
  await expect(notice).toContainText('Another Gradstep tab is ready to update');
  await expect(notice).toContainText('Send or copy it, then close this tab.');
  await expect(notice).toHaveAttribute('role', 'status');
  // Deferring is not retirement: this tab can still send, and the database stays at version 1.
  await expect(page.getByRole('button', { name: 'Send', exact: true })).toBeEnabled();
  await expect(message(page)).not.toHaveAttribute('readonly', '');
  expect((await records(newer)).version).toBe(1);
  await page.screenshot({ path: `${shots}${info.project.name}-waiting-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${shots}${info.project.name}-waiting-dark.png` });
  await page.emulateMedia({ colorScheme: 'light' });
  // Once the work is gone the tab tells the waiting tab, and the notice clears.
  const released = newer.evaluate(() => new Promise<unknown>(resolve => {
    (window as unknown as { channel: BroadcastChannel }).channel.onmessage = event => resolve(event.data);
  }));
  await message(page).fill('');
  expect(await released).toMatchObject({ kind: 'upgrade-reply', ready: true });
  await expect(notice).toHaveCount(0);
  expect((await records(newer)).version).toBe(1);
  await newer.close();
});
