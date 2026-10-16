// Deleting the account from the browser (owner, 2026-10-16), as the apps do: the account menu's "Delete account…",
// type DELETE, the fixture's account-delete (it mirrors functions/account-delete), then signed out with nothing of the
// account left in this browser and a confirmation. A failed request changes nothing here and offers Try again; the
// failures come from the fixture's /__fault (503, 429) and routed replies (no connection, the function's 409).
import { expect, test, type Page } from '@playwright/test';
import { fixtureOrigin as API } from './environment';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

const ACCOUNT = '11111111-2222-4333-8444-555555555555'; // returning@example.test in the fixture
const shots = '../../.artifacts/browser-delete/';

test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

async function signIn(page: Page) {
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

/** What this browser holds for the account: web-storage keys naming it, every IndexedDB record of it, the session. */
function traces(page: Page) {
  return page.evaluate(async account => {
    const named = (storage: Storage) => Array.from({ length: storage.length }, (_, i) => storage.key(i) ?? '').filter(k => k.toLowerCase().includes(account));
    const db = await new Promise<IDBDatabase>((resolve, reject) => { const r = indexedDB.open('gradstep'); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    const records: string[] = [];
    for (const name of Array.from(db.objectStoreNames)) {
      const keys = await new Promise<IDBValidKey[]>(resolve => { const r = db.transaction(name).objectStore(name).getAllKeys(); r.onsuccess = () => resolve(r.result); });
      records.push(...keys.map(String).filter(k => k.toLowerCase().includes(account)).map(k => `${name}/${k}`));
    }
    db.close();
    return { local: named(localStorage), session: named(sessionStorage), records, signedIn: localStorage.getItem('gradstep.fixture.session') !== null,
      tag: localStorage.getItem('gradstep.library.tag'), theme: localStorage.getItem('gradstep.theme') };
  }, ACCOUNT);
}

/** The account's own keys as the app writes them (chat consent, the Feed's offer, a Library tag filter), plus a
 * per-browser setting that deletion leaves alone. */
async function storeAccountKeys(page: Page) {
  await page.evaluate(account => {
    localStorage.setItem(`gradstep.fixture.${account}.cloud-ai-consent`, JSON.stringify('cloud-ai-v4'));
    localStorage.setItem(`gradstep.fixture.feed-offer.${account}`, '1');
    localStorage.setItem('gradstep.library.tag', JSON.stringify('thesis'));
    localStorage.setItem('gradstep.theme', JSON.stringify('system'));
  }, ACCOUNT);
}

async function openDelete(page: Page) {
  await page.getByTestId('account-menu').click();
  await expect(page.getByRole('menuitem', { name: 'Delete account…' })).toBeVisible();
  await page.getByTestId('delete-account').click();
  const dialog = page.getByRole('dialog', { name: 'Delete account' });
  await expect(dialog).toBeVisible();
  return dialog;
}

test('typing DELETE enables deletion; the account is deleted, this browser keeps nothing of it, and says so', async ({ page }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await signIn(page);
  await storeAccountKeys(page);
  const before = await traces(page);
  expect(before.signedIn).toBe(true);
  expect(before.records.length).toBeGreaterThan(0);
  expect(before.local.length).toBeGreaterThanOrEqual(2);

  await page.getByTestId('account-menu').click();
  await expect(page.getByRole('menuitem', { name: 'Delete account…' })).toBeVisible();
  await page.screenshot({ path: `${shots}${info.project.name}-menu-light.png` });
  await page.keyboard.press('Escape');
  const dialog = await openDelete(page);
  await expect(dialog.getByText('This permanently deletes your account:')).toBeVisible();
  await expect(dialog.getByText('Unused credits are forfeited.', { exact: false })).toBeVisible();
  const field = dialog.getByRole('textbox', { name: 'Type DELETE to confirm' });
  const confirm = dialog.getByTestId('confirm-delete-account');
  await expect(field).toBeFocused();
  await expect(confirm).toBeDisabled();
  await field.fill('delete');
  await expect(confirm).toBeDisabled();
  await field.fill('DELETE');
  await expect(confirm).toBeEnabled();
  await expect(confirm).toHaveText('Delete account');
  // Nothing fits outside the window, at any width.
  expect(await dialog.evaluate(d => { const r = d.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth + 0.5; })).toBe(true);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: `${shots}${info.project.name}-dialog-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${shots}${info.project.name}-dialog-dark.png` });
  await page.emulateMedia({ colorScheme: 'light' });

  await confirm.click();
  const notice = page.getByTestId('account-deleted');
  await expect(notice).toBeVisible();
  await expect(notice).toHaveAttribute('role', 'status');
  await expect(notice).toContainText('Your account and its data were deleted from our servers and this browser.');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.screenshot({ path: `${shots}${info.project.name}-deleted-light.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `${shots}${info.project.name}-deleted-dark.png` });
  await page.emulateMedia({ colorScheme: 'light' });

  const after = await traces(page);
  expect(after).toEqual({ local: [], session: [], records: [], signedIn: false, tag: null, theme: JSON.stringify('system') });

  await notice.getByRole('button', { name: 'OK' }).click();
  await expect(notice).toHaveCount(0);
  // The server deleted the login too: the same address no longer signs in.
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await expect(page.getByRole('alert')).toHaveText('There’s no Gradstep account for this address. Gradstep is invite-only during the beta.');
  // Reloading does not repeat the confirmation.
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await expect(page.getByTestId('account-deleted')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('another tab of the account signs out too and writes nothing of it back', async ({ page, context }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  test.skip(info.project.name !== 'desktop', 'One width is enough for the cross-tab path.');
  await signIn(page);
  const other = await context.newPage();
  await other.goto('/');
  await expect(other.getByRole('link', { name: 'Library' })).toBeVisible();
  const dialog = await openDelete(page);
  await dialog.getByRole('textbox', { name: 'Type DELETE to confirm' }).fill('DELETE');
  await dialog.getByTestId('confirm-delete-account').click();
  await expect(page.getByTestId('account-deleted')).toBeVisible();
  await expect(other.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  // Give the other tab's timers (activity saves, journal flushes) time to try.
  await other.waitForTimeout(2_000);
  const after = await traces(page);
  expect({ local: after.local, session: after.session, records: after.records, signedIn: after.signedIn }).toEqual({ local: [], session: [], records: [], signedIn: false });
  await other.close();
});

test('a failed deletion is one sentence and Try again; nothing in this browser changes until it succeeds', async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  await signIn(page);
  await storeAccountKeys(page);
  const before = await traces(page);
  const posts: unknown[] = [];
  page.on('request', r => { if (r.url().endsWith('/functions/v1/account-delete') && r.method() === 'POST') posts.push(r.postDataJSON()); });

  // The server is down for a moment: the keyboard path, Enter in the field.
  await request.post(`${API}/__fault`, { data: { path: 'functions/v1/account-delete', kind: 503, times: 1 } });
  await page.getByTestId('account-menu').click();
  await page.getByTestId('delete-account').focus();
  await page.keyboard.press('Enter');
  const dialog = page.getByRole('dialog', { name: 'Delete account' });
  const field = dialog.getByRole('textbox', { name: 'Type DELETE to confirm' });
  await expect(field).toBeFocused();
  await page.keyboard.type('DELETE');
  await page.keyboard.press('Enter');
  const alert = dialog.getByRole('alert');
  await expect(alert).toHaveText('The account couldn’t be deleted. Try again.');
  await expect(field).toHaveAttribute('aria-describedby', 'delete-account-error');
  await expect(field).toBeFocused();
  const retry = dialog.getByTestId('confirm-delete-account');
  await expect(retry).toHaveText('Try again');
  await expect(retry).toBeEnabled();
  await page.screenshot({ path: `${shots}${info.project.name}-failure-light.png` });
  expect(await traces(page)).toEqual(before);

  // Too many requests: the wait the server gave.
  await request.post(`${API}/__fault`, { data: { path: 'functions/v1/account-delete', kind: 429, times: 1 } });
  await retry.click();
  await expect(alert).toHaveText('Too many requests right now. Try again in 30 seconds.');
  await expect(field).toBeFocused(); // the button was busy; focus returns to the field
  expect(await traces(page)).toEqual(before);

  // No connection, then the server's refusal while an episode finishes (functions/account-delete's 409).
  await page.route('**/functions/v1/account-delete', route => route.abort('internetdisconnected'), { times: 1 });
  await page.keyboard.press('Enter');
  await expect(alert).toHaveText('Couldn’t reach Gradstep. Check your connection and try again.');
  await page.route('**/functions/v1/account-delete', route => route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ code: 'account_busy' }) }), { times: 1 });
  await retry.click();
  await expect(alert).toHaveText('An episode or another task is still finishing. Try again in a moment.');
  expect(await traces(page)).toEqual(before);

  // Cancel keeps everything; the reader is still signed in.
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
  expect(await traces(page)).toEqual(before);

  // Opening it again starts afresh, and Try again then succeeds.
  const again = await openDelete(page);
  await expect(again.getByRole('alert')).toHaveCount(0);
  await expect(again.getByTestId('confirm-delete-account')).toBeDisabled();
  await again.getByRole('textbox', { name: 'Type DELETE to confirm' }).fill('DELETE');
  await again.getByTestId('confirm-delete-account').click();
  await expect(page.getByTestId('account-deleted')).toBeVisible();
  expect((await traces(page)).records).toEqual([]);
  // Each request carried exactly the function's confirmation.
  expect(posts).toEqual(Array(5).fill({ confirm: 'delete my account' }));
});
