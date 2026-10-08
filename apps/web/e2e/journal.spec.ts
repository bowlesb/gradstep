// Gate 1, real Chromium storage and non-extractable keys. Fixture requests are local and unbilled.
import { expect, test, type Page } from '@playwright/test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API, appOrigin as APP } from './environment';

const message = (page: Page) => page.getByRole('textbox', { name: 'Message', exact: true });
async function signIn(page: Page) {
  await page.goto(APP);
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
}
async function login(page: Page) {
  await signIn(page);
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
}
async function openChat(page: Page) {
  await expect(page.getByTestId('library-table')).toBeVisible();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
}
const saved = (page: Page) => expect(page.getByTestId('draft-status')).toContainText('Saved on this device.');
const evidence = async (request: any) => (await request.get(`${API}/__chat-evidence`)).json();
async function records(page: Page) {
  return page.evaluate(async () => {
    const db = await new Promise<IDBDatabase>((resolve, reject) => { const r = indexedDB.open('gradstep'); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    const tx = db.transaction(['journal', 'devices']), a = tx.objectStore('journal').getAll(), keys = tx.objectStore('journal').getAllKeys(), d = tx.objectStore('devices').getAll();
    return new Promise<{ version: number; keys: string[]; raw: string; extractable: boolean[] }>((resolve, reject) => {
      tx.oncomplete = () => { const answer = { version: db.version, keys: keys.result as string[], raw: JSON.stringify(a.result), extractable: d.result.filter(v => v.localKey).flatMap(v => [v.localKey.extractable, v.privateKey.extractable]) }; db.close(); resolve(answer); };
      tx.onabort = () => { db.close(); reject(tx.error); };
    });
  });
}

test.beforeEach(async ({ request }, info) => {
  test.skip(info.project.name !== 'desktop', 'Persistent Chromium gate; Safari key persistence remains a separate gate.');
  await request.post(`${API}/__reset`);
});

test('persistent profile: type, restart, lose append acknowledgement, restart, explicit answer, close, recover partial and newer draft', async ({ playwright, request }) => {
  const profile = await mkdtemp(join(tmpdir(), 'gradstep-journal-'));
  const errors: string[] = [];
  const launch = async () => {
    const context = await playwright.chromium.launchPersistentContext(profile, { viewport: { width: 1280, height: 860 }, baseURL: APP });
    const observe = (page: Page) => page.on('pageerror', e => errors.push(e.message));
    for (const page of context.pages()) observe(page);
    context.on('page', observe); return context;
  };
  let context = await launch();
  try {
    let page = context.pages()[0];
    await login(page); await openChat(page);
    await message(page).fill('Persistent private question β'); await saved(page);
    const before = await records(page); expect(before.version).toBe(2); expect(before.extractable).toEqual([false, false]); expect(before.raw).not.toContain('Persistent private');
    await context.close(); context = await launch(); page = context.pages()[0]; await page.goto(APP); await openChat(page);
    await expect(message(page)).toHaveValue('Persistent private question β');
    await request.post(`${API}/__chat-fixture`, { data: { loseAppendAck: true, mode: 'slow' } });
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(page.getByRole('alert')).toContainText('question couldn’t be saved');
    const lost = await evidence(request); expect(lost.events).toHaveLength(1); expect(lost.requests).toHaveLength(0);
    const exactRoot = { id: lost.events[0].id, ciphertext: lost.events[0].ciphertext };
    await context.close(); context = await launch(); page = context.pages()[0]; await page.goto(APP); await openChat(page);
    await expect(page.getByTestId('chat-user')).toContainText('Persistent private question β');
    await expect.poll(async () => (await evidence(request)).events.length).toBe(2);
    const reconciled = await evidence(request); expect(reconciled.events[0]).toMatchObject(exactRoot); expect(reconciled.requests).toHaveLength(0);
    await page.getByRole('button', { name: 'Get answer', exact: true }).click();
    await page.getByRole('button', { name: 'Allow and get answer' }).click();
    await expect(page.getByTestId('chat-streaming')).toContainText('objective');
    await message(page).fill('Newer private edit while the answer runs'); await saved(page);
    await page.waitForTimeout(1_300); // one bounded partial checkpoint has time to commit
    expect((await records(page)).keys.some(key => key.includes(':t:'))).toBe(true);
    await context.close(); context = await launch(); page = context.pages()[0]; await page.goto(APP); await openChat(page);
    await expect(message(page)).toHaveValue('Newer private edit while the answer runs');
    await expect(page.getByTestId('chat-assistant')).toContainText('Answer interrupted');
    await expect(page.getByTestId('chat-assistant')).toContainText('objective');
    await expect.poll(async () => (await evidence(request)).events.length).toBe(3);
    expect((await evidence(request)).requests).toHaveLength(1);
    expect((await records(page)).keys.some(key => key.includes(':t:'))).toBe(false);
    expect((await records(page)).raw).not.toContain('private');
    await page.screenshot({ path: '../../.artifacts/web-journal/persistent-recovery.png' });
    expect(errors).toEqual([]);
  } finally { await context.close(); await rm(profile, { recursive: true, force: true }); }
});

test('live tabs keep separate editor locks; sign-out clears both presentations and fresh login restores retained drafts', async ({ page, request }) => {
  await login(page); await openChat(page); await message(page).fill('First live tab draft'); await saved(page);
  const second = await page.context().newPage(); await second.goto(APP); await openChat(second);
  await expect(message(second)).toHaveValue(''); await message(second).fill('Second live tab draft'); await saved(second);
  await expect(message(page)).toHaveValue('First live tab draft');
  await second.getByTestId('account-menu').click();
  await second.getByTestId('sign-out').click(); await second.getByTestId('confirm-sign-out').click();
  await expect(page.getByTestId('email')).toBeVisible(); await expect(second.getByTestId('email')).toBeVisible();
  expect((await evidence(request)).requests).toHaveLength(0);
  await second.close(); await signIn(page); await openChat(page);
  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
  await expect(page.locator('.history-draft')).toHaveCount(2);
  await page.locator('.history-draft').first().getByRole('button', { name: /Draft/ }).click();
  expect(['First live tab draft', 'Second live tab draft']).toContain(await message(page).inputValue());
});

test('quota abort keeps the earlier draft; missing authenticated head preserves children and locks private writes', async ({ page }) => {
  await login(page); await openChat(page); await message(page).fill('Previous committed draft'); await saved(page);
  await page.evaluate(() => {
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (...args: Parameters<IDBObjectStore['put']>) {
      if (this.name === 'journal') throw new DOMException('Fixture quota abort', 'QuotaExceededError');
      return put.apply(this, args);
    };
  });
  await message(page).fill('Newer unsaved text after quota');
  await expect(page.getByTestId('draft-status')).toContainText('Couldn’t save this edit');
  page.once('dialog', dialog => dialog.accept()); await page.reload();
  await expect(message(page)).toHaveValue('Previous committed draft');
  const before = await records(page);
  await page.evaluate(() => new Promise<void>((resolve, reject) => {
    const r = indexedDB.open('gradstep'); r.onsuccess = () => {
      const db = r.result, tx = db.transaction('journal', 'readwrite'), store = tx.objectStore('journal'), keys = store.getAllKeys();
      keys.onsuccess = () => { for (const key of keys.result) if (String(key).endsWith(':head')) store.delete(key); };
      tx.oncomplete = () => { db.close(); resolve(); }; tx.onabort = () => { db.close(); reject(tx.error); };
    };
  }));
  await page.reload(); await expect(message(page)).toHaveAttribute('readonly', '');
  await expect(page.getByTestId('chat-pane')).toContainText('stored data has been kept');
  expect((await records(page)).keys).toHaveLength(before.keys.length - 1);
});

test('version-1 activation waits for an explicit acknowledgement; deferring leaves the old schema intact', async ({ page }) => {
  await page.goto(`${APP}/brand-icon.svg`);
  await page.evaluate(() => new Promise<void>((resolve, reject) => {
    const r = indexedDB.open('gradstep', 1); r.onupgradeneeded = () => { r.result.createObjectStore('devices'); r.result.createObjectStore('activity'); };
    r.onsuccess = () => { r.result.close(); resolve(); }; r.onerror = () => reject(r.error);
  }));
  await login(page);
  await expect(page.getByRole('heading', { name: 'Keep drafts in this browser' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Enable device drafts' })).toBeDisabled();
  expect(await page.evaluate(async () => (await indexedDB.databases()).find(d => d.name === 'gradstep')?.version)).toBe(1);
  await page.getByRole('button', { name: 'Continue without device drafts' }).click(); await openChat(page);
  await expect(page.getByTestId('draft-status')).toContainText('aren’t kept after a reload');
  await page.reload();
  await page.getByRole('checkbox', { name: 'I finished or copied' }).check(); await page.getByRole('button', { name: 'Enable device drafts' }).click();
  await expect(page.getByTestId('reader-frame')).toBeVisible();
  expect(await page.evaluate(async () => (await indexedDB.databases()).find(d => d.name === 'gradstep')?.version)).toBe(2);
  await expect(page.getByTestId('draft-status')).toContainText('Saved on this device.');
});
