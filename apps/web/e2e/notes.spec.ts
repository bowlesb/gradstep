// Notes and snippets journeys (docs/architecture/NOTES_AND_SNIPPETS.md): real WebCrypto, the production CSP and the
// local fixture backend (its note-assets route follows the deployed contract). Desktop and phone; light and dark
// screenshots go to .artifacts/web-e2e/notes/ for review. No hosted or paid request.
import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';

const SHOTS = '../../.artifacts/web-e2e/notes';
mkdirSync(SHOTS, { recursive: true });
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png` });
const assets = async (request: any) => (await request.get(`${API}/__note-assets`)).json() as Promise<{ blobs: { id: string; bytes: number; head: string }[]; puts: string[]; gets: string[] }>;
const phone = () => test.info().project.name === 'phone';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
async function openPaper(page: Page) {
  await page.getByTestId('back-to-library').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  // The chat drawer covers a phone's paper when it opens with it.
  if (phone() && await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('chat-pane').getByRole('button', { name: /Close|Hide/ }).first().click();
}
async function selectParagraph(page: Page, text: string) {
  await page.frameLocator('[data-testid=reader-frame]').locator('p').filter({ hasText: text }).first().evaluate(node => {
    node.scrollIntoView({ block: 'center' });
    const r = document.createRange(); r.selectNodeContents(node); const s = window.getSelection()!; s.removeAllRanges(); s.addRange(r); document.dispatchEvent(new Event('selectionchange'));
  });
  await expect(page.getByRole('toolbar', { name: 'Selected passage' })).toBeVisible();
}
async function drawBox(page: Page) {
  await page.getByRole('button', { name: /^Actions for Direct Preference Optimization/ }).click();
  await page.getByTestId('draw-snippet').click();
  const stage = page.getByTestId('snippet-stage');
  await expect(stage).toBeVisible();
  const box = (await stage.boundingBox())!;
  await page.mouse.move(box.x + box.width * 0.12, box.y + box.height * 0.3);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.6, box.y + box.height * 0.5, { steps: 6 });
  await page.mouse.move(box.x + box.width * 0.88, box.y + box.height * 0.62, { steps: 6 });
  await page.mouse.up();
  await expect(page.getByTestId('snippet-box')).toBeVisible();
}

test.beforeEach(async ({ request, page }) => {
  await request.post(`${API}/__reset`);
  await page.route('https://arxiv.org/**', route => route.abort());
});

test('notes: create, write, quote, draw a snippet, view, edit, sync to another browser, delete', async ({ page, browser, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  const errors: string[] = [], remote: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('request', r => { const u = r.url(); if (!u.startsWith('http://127.0.0.1:') && !u.startsWith('data:') && !u.startsWith('blob:') && !u.startsWith('https://arxiv.org/')) remote.push(u); });
  await signIn(page);

  // The destination: desktop adds Notes to the existing top navigation; phone widths use the five destinations.
  if (phone()) {
    const tabs = page.getByRole('navigation', { name: 'Main' });
    await expect(tabs.locator('.phone-tab')).toHaveText(['Feed', 'Library', 'Paper', 'Chat', 'Notes']);
    await page.getByTestId('account-menu').click();
    await expect(page.getByRole('menu')).toContainText('Settings'); await page.keyboard.press('Escape');
  } else await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link')).toHaveText(['Library', 'Feed', 'Notes']);
  await page.getByTestId('nav-notes').click();
  await expect(page).toHaveURL(/\/notes$/);
  await expect(page.getByText('A place for your next idea').first()).toBeVisible();
  await shot(page, 'light-empty');

  // New note, then the reader's own writing.
  await page.getByTestId('new-note').first().click();
  await page.getByTestId('note-name').fill('Preference learning'); await page.getByTestId('note-name-save').click();
  await expect(page.getByTestId('note-title')).toHaveText('Preference learning');
  await page.getByTestId('add-text').click();
  await page.getByTestId('composer-comment').fill('Compare the DPO loss with IPO next.');
  await page.getByTestId('composer-save').click();
  await expect(page.getByTestId('note-entry')).toHaveCount(1);
  await expect(page.getByTestId('note-entry').first()).toContainText('Your writing');

  // A quote from the paper (selection › Add to note), saved back to the paper with Open note.
  await openPaper(page);
  await selectParagraph(page, 'preferences');
  await page.getByTestId('selection-add-to-note').click();
  const composer = page.getByRole('dialog', { name: 'Add to note' });
  await expect(composer.getByTestId('composer-quote')).toContainText('preferences');
  await expect(composer.getByTestId('composer-note')).toHaveValue(/.+/);
  await expect(composer.getByTestId('composer-source')).toContainText('Direct Preference Optimization');
  await composer.getByTestId('composer-comment').fill('The key sentence.');
  await composer.getByTestId('composer-save').click();
  await expect(page.getByTestId('notes-saved')).toContainText('Saved to Preference learning');
  await expect(page.getByTestId('reader-frame')).toBeVisible(); // still reading

  // Paper ⋯ › Draw snippet: a box, the actual image previewed, saved locally, then uploaded before its entry.
  await drawBox(page);
  await shot(page, 'light-draw');
  await page.getByTestId('snippet-use').click();
  const draw = page.getByRole('dialog', { name: 'Add to note' });
  await expect(draw.getByTestId('composer-image')).toBeVisible();
  const size = await draw.getByTestId('composer-image').evaluate((img: HTMLImageElement) => ({ w: img.naturalWidth, h: img.naturalHeight }));
  expect(size.w).toBeGreaterThan(100); expect(size.h).toBeGreaterThan(50);
  await draw.getByTestId('composer-comment').fill('The objective in one picture.');
  await shot(page, 'light-composer');
  await draw.getByTestId('composer-save').click();
  await expect(page.getByTestId('notes-saved')).toContainText('Saved to Preference learning');
  await expect.poll(async () => (await assets(request)).puts.length).toBe(2);
  const stored = await assets(request);
  // Opaque ciphertext only: neither blob starts with an image signature.
  for (const blob of stored.blobs) { expect(blob.head.startsWith('89504e47')).toBe(false); expect(blob.head.startsWith('ffd8ff')).toBe(false); }

  await page.getByTestId('open-saved-note').click();
  await expect(page).toHaveURL(/\/notes\/[0-9a-f-]{36}$/);
  const entries = page.getByTestId('note-entry');
  await expect(entries).toHaveCount(3);
  await expect(entries.nth(1)).toContainText('Text snippet'); await expect(entries.nth(1)).toContainText('The key sentence.');
  await expect(entries.nth(2)).toContainText('Region snippet');
  const thumb = entries.nth(2).getByTestId('snippet-image').locator('img');
  await expect(thumb).toBeVisible();
  expect(await thumb.evaluate((img: HTMLImageElement) => img.src.startsWith('blob:') && img.complete && img.naturalWidth > 0)).toBe(true);
  await expect(page.getByTestId('entry-state')).toHaveCount(0); // synced
  await shot(page, 'light-note');

  // Full-size view with zoom.
  await entries.nth(2).getByTestId('snippet-image').click();
  const zoom = page.getByRole('dialog', { name: 'Snippet' });
  await expect(zoom.locator('img')).toBeVisible();
  await zoom.getByTestId('zoom').fill('2');
  await shot(page, 'light-zoom');
  await zoom.getByRole('button', { name: 'Close' }).click();

  // Edit a comment, rename, search.
  await entries.nth(1).getByTestId('entry-menu').click(); await page.getByRole('menuitem', { name: 'Edit comment' }).click();
  await page.getByTestId('comment-text').fill('The key sentence, revised.'); await page.getByTestId('comment-save').click();
  await expect(entries.nth(1)).toContainText('The key sentence, revised.');
  await page.getByTestId('note-menu').click(); await page.getByRole('menuitem', { name: 'Rename note…' }).click();
  await page.getByTestId('note-name').fill('Preference learning (DPO)'); await page.getByTestId('note-name-save').click();
  await expect(page.getByTestId('note-title')).toHaveText('Preference learning (DPO)');

  // Dark appearance of the same screens.
  await page.emulateMedia({ colorScheme: 'dark' });
  await shot(page, 'dark-note');

  // Another browser of the same account: the note syncs and the crop downloads, decrypts and shows.
  const other = await browser.newContext({ viewport: page.viewportSize()!, hasTouch: phone(), colorScheme: 'dark' }), second = await other.newPage();
  await second.route('https://arxiv.org/**', route => route.abort());
  await signIn(second);
  await second.getByTestId('nav-notes').click();
  await second.getByTestId('note-row').filter({ hasText: 'Preference learning (DPO)' }).first().click();
  const remoteEntries = second.getByTestId('note-entry');
  await expect(remoteEntries).toHaveCount(3);
  await expect(remoteEntries.nth(2).getByTestId('snippet-image').locator('img')).toBeVisible();
  await expect.poll(async () => (await assets(request)).gets.length).toBeGreaterThan(0);
  await remoteEntries.nth(2).getByTestId('snippet-image').click();
  await expect(second.getByRole('dialog', { name: 'Snippet' }).locator('img')).toBeVisible();
  await second.screenshot({ path: `${SHOTS}/${info.project.name}-dark-second-browser-zoom.png` });
  await other.close();

  // Open in paper from the quote, then back to the list; search; delete with confirmation.
  await page.emulateMedia({ colorScheme: 'light' });
  await entries.nth(1).getByTestId('entry-menu').click(); await page.getByRole('menuitem', { name: 'Open in paper' }).click();
  await expect(page).toHaveURL(/\/paper\//);
  await page.getByTestId('nav-notes').click();
  if (await page.getByTestId('notes-search').first().isVisible()) {
    await page.getByTestId('notes-search').first().fill('revised');
    await expect(page.getByTestId('note-row')).toHaveCount(1);
    await page.getByTestId('notes-search').first().fill('nothing like this');
    await expect(page.getByTestId('note-row')).toHaveCount(0);
    await page.getByTestId('notes-search').first().fill('');
  }
  await shot(page, 'light-list');
  await page.getByTestId('note-row').first().click();
  await entries.nth(0).getByTestId('entry-menu').click(); await page.getByRole('menuitem', { name: 'Delete snippet' }).click();
  await page.getByTestId('confirm-delete').click();
  await expect(entries).toHaveCount(2);
  await page.getByTestId('note-menu').click(); await page.getByRole('menuitem', { name: 'Delete note…' }).click();
  await expect(page.getByRole('dialog', { name: /Delete “Preference learning \(DPO\)”/ })).toContainText('2 entries');
  await page.getByTestId('confirm-delete').click();
  await expect(page).toHaveURL(/\/notes$/);
  await expect(page.getByText('A place for your next idea').first()).toBeVisible();
  expect(errors).toEqual([]); expect(remote).toEqual([]);
});

test('notes: a full snippet store keeps the crop here, says why, and uploads it on Retry; chats are not blocked', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  await signIn(page);
  await request.post(`${API}/__note-assets`, { data: { quota: true } });
  await openPaper(page);
  await drawBox(page);
  await page.getByTestId('snippet-use').click();
  const draw = page.getByRole('dialog', { name: 'Add to note' });
  await expect(draw.getByTestId('composer-note')).toHaveValue('new');
  await expect(draw.getByTestId('composer-new-name')).toHaveValue('Quick notes');
  await draw.getByTestId('composer-save').click();
  await expect(page.getByTestId('notes-saved')).toContainText('Saved to Quick notes');
  await page.getByTestId('open-saved-note').click();
  await expect(page.getByTestId('notes-issue')).toContainText('Snippet storage is full');
  await expect(page.getByTestId('entry-state')).toContainText('Snippet storage is full');
  // The crop is still shown from this browser's encrypted copy.
  await expect(page.getByTestId('note-entry').first().getByTestId('snippet-image').locator('img')).toBeVisible();
  await shot(page, 'light-quota');
  expect((await assets(request)).puts).toHaveLength(0);
  // A reload keeps the entry and its image (durable local commit).
  await page.reload();
  await expect(page.getByTestId('note-entry')).toHaveCount(1);
  await expect(page.getByTestId('note-entry').first().getByTestId('snippet-image').locator('img')).toBeVisible();
  // Still held after the reload: the sync that follows it meets the same full store.
  await expect(page.getByTestId('notes-issue')).toContainText('Snippet storage is full');
  expect((await assets(request)).puts).toHaveLength(0);
  await request.post(`${API}/__note-assets`, { data: { quota: false } });
  await page.getByTestId('notes-issue').getByRole('button', { name: 'Retry' }).click();
  await expect(page.getByTestId('notes-issue')).toHaveCount(0);
  await expect(page.getByTestId('entry-state')).toHaveCount(0);
  expect((await assets(request)).puts).toHaveLength(2);
});

test('notes: figure and equation pages add their item; Escape cancels drawing and restores reading', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  await signIn(page);
  await openPaper(page);
  // Draw snippet: Escape restores reading with nothing saved.
  await page.getByRole('button', { name: /^Actions for Direct Preference Optimization/ }).click();
  await page.getByTestId('draw-snippet').click();
  await expect(page.getByTestId('snippet-capture')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('snippet-capture')).toHaveCount(0);
  // Keyboard path: Whole view, then Use snippet.
  await page.getByRole('button', { name: /^Actions for Direct Preference Optimization/ }).click();
  await page.getByTestId('draw-snippet').click();
  await page.locator('.snippet-edges summary').click(); await page.getByTestId('snippet-whole').click();
  await page.getByTestId('snippet-use').click();
  await expect(page.getByRole('dialog', { name: 'Add to note' }).getByTestId('composer-image')).toBeVisible();
  await page.getByRole('dialog', { name: 'Add to note' }).getByRole('button', { name: 'Cancel' }).last().click();
  await expect(page.getByRole('dialog', { name: 'Add to note' })).toHaveCount(0);
  // A figure page's Add to note: the figure's own image.
  await page.getByTestId('figures').click();
  await page.getByRole('list', { name: 'Figures' }).getByRole('button').first().click();
  await page.getByTestId('figure-add-to-note').click();
  const composer = page.getByRole('dialog', { name: 'Add to note' });
  await expect(composer.getByTestId('composer-image')).toBeVisible();
  await expect(composer.getByTestId('composer-source')).toContainText('Figure');
  await composer.getByTestId('composer-new-name').fill('Figures');
  await composer.getByTestId('composer-save').click();
  await expect(page.getByTestId('notes-saved')).toContainText('Saved to Figures');
  // An equation (tapped in the paper), rendered here as an image.
  const display = page.frameLocator('[data-testid=reader-frame]').locator('[data-reader-equation]').filter({ has: page.frameLocator('[data-testid=reader-frame]').locator('math[display=block]') }).first();
  await display.scrollIntoViewIfNeeded(); await display.click();
  await expect(page.getByRole('toolbar', { name: 'Selected passage' })).toBeVisible();
  await page.getByTestId('selection-add-to-note').click();
  const eq = page.getByRole('dialog', { name: 'Add to note' });
  await expect(eq.getByTestId('composer-image')).toBeVisible();
  await expect(eq.getByTestId('composer-source')).toContainText('Equation');
  await eq.getByTestId('composer-save').click();
  await expect(page.getByTestId('notes-saved')).toContainText('Saved to Figures');
  await page.getByTestId('open-saved-note').click();
  await expect(page.getByTestId('note-entry')).toHaveCount(2);
  await shot(page, 'light-figures-note');
});

// Owner, 2026-10-21: "In the snippet options when viewing it in a figure, there should be a Chat option to launch and talk
// about the snippet." ⋯ › Chat and the full-size view's Chat: the paper's chat with the crop attached and the comment as the
// draft, nothing sent; the question carries the crop as a figure (F3); Back to note returns.
test('notes: a snippet’s Chat attaches its crop to the paper’s chat and returns to the note', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  await signIn(page);
  await openPaper(page);
  await drawBox(page);
  await page.getByTestId('snippet-use').click();
  const draw = page.getByRole('dialog', { name: 'Add to note' });
  await expect(draw.getByTestId('composer-image')).toBeVisible();
  await draw.getByTestId('composer-comment').fill('Why does it level off?');
  await draw.getByTestId('composer-save').click();
  await page.getByTestId('open-saved-note').click();
  const entry = page.getByTestId('note-entry').first();
  await expect(entry.getByTestId('snippet-image').locator('img')).toBeVisible();
  const before = (await (await request.get(`${API}/__chat-evidence`)).json()).requests.length;

  await entry.getByTestId('entry-menu').click();
  await expect(page.getByTestId('entry-chat')).toBeVisible();
  await shot(page, 'light-snippet-options');
  await page.getByTestId('entry-chat').click();
  const context = page.getByTestId('promoted-context').filter({ visible: true });
  await expect(context.getByTestId('promoted-image')).toBeVisible();
  await expect(context.getByTestId('promoted-image-note')).toHaveText('This picture goes with your questions in this chat.');
  const message = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(message).toHaveValue('Why does it level off?');
  expect((await (await request.get(`${API}/__chat-evidence`)).json()).requests.length).toBe(before); // nothing sent
  await shot(page, 'light-snippet-chat');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect.poll(async () => (await (await request.get(`${API}/__chat-evidence`)).json()).requests.length).toBe(before + 1);
  const asked = (await (await request.get(`${API}/__chat-evidence`)).json()).requests.at(-1);
  expect(asked.mode).toBe('paper');
  expect(asked.figures.map((f: { id: string }) => f.id)).toContain('F3');
  expect(asked.selection.quote).toContain('A snippet the reader drew from');

  await context.getByTestId('back-to-note').click();
  await expect(page).toHaveURL(/\/notes\/[0-9a-f-]{36}$/);
  await expect(page.getByTestId('note-entry').first()).toBeVisible();
  // The full-size view's Chat.
  await page.getByTestId('note-entry').first().getByTestId('snippet-image').click();
  await page.getByRole('dialog', { name: 'Snippet' }).getByTestId('zoom-chat').click();
  await expect(page.getByTestId('promoted-context').filter({ visible: true }).getByTestId('promoted-image')).toBeVisible();
});

// Owner, 2026-10-21: "In the notes list each needs a very pleasant border around it, so it looks like a bunch of cards."
test('notes: the list shows each note as a card, apart from the next, in light and dark', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  await signIn(page);
  await page.getByTestId('nav-notes').click();
  for (const [name, writing] of [['Preference learning', 'Compare the DPO loss with IPO next.'], ['Reading group: alignment', 'Bring the reward-model plot.'],
    ['Open questions', 'Why does beta matter so much?']]) {
    await page.getByTestId('new-note').first().click();
    await page.getByTestId('note-name').fill(name); await page.getByTestId('note-name-save').click();
    await expect(page.getByTestId('note-title')).toHaveText(name);
    await page.getByTestId('add-text').click(); await page.getByTestId('composer-comment').fill(writing); await page.getByTestId('composer-save').click();
    await expect(page.getByTestId('note-entry')).toHaveCount(1);
    if (await page.getByTestId('notes-back').isVisible()) await page.getByTestId('notes-back').click();
  }
  if (phone()) await page.getByTestId('nav-notes').click();
  const rows = page.getByTestId('note-row');
  await expect(rows).toHaveCount(3);
  // A card: rounded, a whole hairline edge (not the old bottom rule), and a gap before the next card.
  const look = await rows.evaluateAll(all => all.map(row => { const s = getComputedStyle(row), r = row.getBoundingClientRect();
    return { radius: parseFloat(s.borderTopLeftRadius), top: parseFloat(s.borderTopWidth), bottom: parseFloat(s.borderBottomWidth), left: parseFloat(s.borderLeftWidth), y: r.top, bottomY: r.bottom }; }));
  for (const card of look) { expect(card.radius).toBeGreaterThanOrEqual(12); expect([card.top, card.bottom, card.left]).toEqual([1, 1, 1]); }
  for (let i = 1; i < look.length; i++) expect(look[i].y - look[i - 1].bottomY).toBeGreaterThanOrEqual(8);
  await expect(rows.first()).toContainText('1 entry');
  await shot(page, 'light-cards');
  await page.emulateMedia({ colorScheme: 'dark' });
  await shot(page, 'dark-cards');
  await page.emulateMedia({ colorScheme: 'light' });
  await rows.filter({ hasText: 'Open questions' }).click();
  await expect(page.getByTestId('note-title')).toHaveText('Open questions');
});
