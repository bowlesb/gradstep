import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';

const message = (page: Page) => page.getByRole('textbox', { name: 'Message', exact: true });
async function openChat(page: Page) {
  await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await expect(message(page)).toBeVisible();
}
async function paper(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await openChat(page);
}
const saved = (page: Page) => expect(page.getByTestId('draft-status')).toContainText(/Saved (on this device|in this browser)\./);
test.beforeEach(async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Safari secure-key storage is a separate acceptance gate.');
  await request.post(`${API}/__reset`);
});

test('Discuss a figure keeps text and passage through reload, and waits for explicit Send', async ({ page, request }) => {
  const errors: string[] = []; page.on('pageerror', error => errors.push(String(error)));
  await paper(page);
  await message(page).fill('My own unsent question'); await saved(page);
  // Close a narrow chat drawer so the underlying paper toolbar is reachable.
  if (await page.locator('.pane-right.overlay').count()) await page.keyboard.press('Escape');
  await page.getByTestId('figures').click();
  await page.getByRole('list', { name: 'Figures' }).getByRole('button').first().click();
  // The figure page's Explain in Chat (its top row since build 62, FIGURE_VIEW.md).
  await page.getByRole('button', { name: 'Explain in Chat', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(message(page)).toBeFocused();
  await expect(message(page)).toHaveValue(/^About “.+”: My own unsent question$/s);
  await saved(page); const draft = await message(page).inputValue();
  expect((await (await request.get(`${API}/__chat-evidence`)).json()).requests).toHaveLength(0);
  await page.reload(); await openChat(page);
  await expect(message(page)).toHaveValue(draft);
  expect((await (await request.get(`${API}/__chat-evidence`)).json()).requests).toHaveLength(0);
  // The figure passage is part of the restored draft, not only its visible quote.
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('chat-assistant')).toBeVisible();
  await page.frameLocator('[data-testid=reader-frame]').locator('body').evaluate(() => scrollTo(0, document.documentElement.scrollHeight)); // Back is offered only when there's somewhere to return to
  await page.getByRole('button', { name: 'Go to passage', exact: true }).click();
  if (await page.locator('.pane-right.overlay').count()) await page.keyboard.press('Escape');
  await expect(page.getByTestId('citation-back')).toBeVisible();
  expect((await (await request.get(`${API}/__chat-evidence`)).json()).requests).toHaveLength(1);
  expect(errors).toEqual([]);
});

test('navigation drains a deferred checkpoint and failed storage keeps its copyable draft reachable', async ({ page, request }) => {
  await paper(page);
  await page.evaluate(() => {
    const original = window.setTimeout.bind(window);
    window.setTimeout = ((handler: TimerHandler, timeout?: number, ...args: unknown[]) => original(handler, timeout === 400 ? 30_000 : timeout, ...args)) as typeof window.setTimeout;
  });
  await message(page).fill('Saved by navigation before the typing timer');
  if (await page.locator('.pane-right.overlay').count()) await page.keyboard.press('Escape');
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await expect(page).toHaveURL(/\/feed$/);
  await page.reload();
  await page.getByTestId('back-to-library').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await openChat(page);
  await expect(message(page)).toHaveValue('Saved by navigation before the typing timer');
  await page.evaluate(() => {
    const original = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (...args: Parameters<IDBObjectStore['put']>) {
      if (this.name === 'journal') throw new DOMException('Fixture quota abort', 'QuotaExceededError');
      return original.apply(this, args);
    };
  });
  await message(page).fill('Uncommitted text I must still be able to copy');
  if (await page.locator('.pane-right.overlay').count()) await page.keyboard.press('Escape');
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await expect(page).toHaveURL(/\/feed$/);
  await expect(page.getByTestId('navigation-save-issue')).toContainText('Keep this tab open');
  await page.getByRole('button', { name: 'Review drafts' }).click();
  await page.locator('.history-draft').getByRole('button', { name: /Draft/ }).click();
  await openChat(page);
  await expect(message(page)).toHaveValue('Uncommitted text I must still be able to copy');
  await expect(message(page)).not.toHaveAttribute('readonly', '');
  expect((await (await request.get(`${API}/__chat-evidence`)).json()).requests).toHaveLength(0);
});
