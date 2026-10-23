// Chat redesign from build 57 feedback (docs/architecture/CHAT.md, 2026-10-16), the browser's journey: the empty chat's
// three starter questions directly above the one-pill composer (a click fills the box and sends nothing), the chat's
// ⋯ menu with Answer options (Model and Length only, DeepSeek where the table lists it) and Study mode, and All chats'
// one-row header (search and ≡; no title, no Done). Local fixtures only; the paper is the authored arXiv HTML fixture,
// compiled on this device, so its starters can name its own figure, table and equation.
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin } from './environment';
import { durableKeys } from './key-capability';
const SHOTS = '../../.artifacts/chat-redesign';
const html = readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html', import.meta.url));
const raster = readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg', import.meta.url));
const member = '58000000-0000-4000-8000-000000000003';
const evidence = async (request: any) => (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();

async function openFixturePaper(page: Page) {
  await page.route('https://arxiv.org/**', async route => {
    const url = route.request().url();
    if (url === 'https://arxiv.org/html/2601.01234v2') await route.fulfill({ status: 200, contentType: 'text/html', headers: { 'access-control-allow-origin': '*' }, body: html });
    else if (url === 'https://arxiv.org/html/2601.01234v2/figure.jpg') await route.fulfill({ status: 200, contentType: 'image/jpeg', headers: { 'access-control-allow-origin': '*' }, body: raster });
    else throw Error('Unexpected source acquisition ' + url);
  });
  await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_page`, async route => {
    const response = await route.fetch(), body = await response.json();
    const row = body.entries.find((e: { kind: string }) => e.kind === 'item');
    body.entries = [{ kind: 'import', id: member, created_seq: row.created_seq, state_seq: row.state_seq, intent_revision: 1, visible: true, phase: 'source_only', source: 'arxiv', source_id: '2601.01234', requested_revision: 2, source_revision: 2,
      metadata_id: row.metadata_id, version_id: row.version_id, metadata_recorded_at: row.metadata_recorded_at, source_url: 'https://arxiv.org/abs/2601.01234v2', retryable: false, metadata: { title: 'Authored HTML fixture', authors: ['Fixture author'], categories: ['cs.LG'] } }];
    body.has_more = false; body.next_cursor = { format: 2, account_id: body.account_id, through: body.baseline_cursor, created_seq: row.created_seq, id: member, kind: 'import' };
    await route.fulfill({ response, json: body });
  });
  await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`, async route => { const response = await route.fetch(), body = await response.json(); body.changes = []; body.has_more = false; body.next_cursor = body.through; await route.fulfill({ response, json: body }); });
  await page.goto('/'); await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: 'Authored HTML fixture', exact: true }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('[data-reader-block]')).not.toHaveCount(0, { timeout: 20_000 });
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
}

for (const scheme of ['light', 'dark'] as const) test(`an empty chat shows three starters above the pill; a click fills the box and sends nothing (${scheme})`, async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await request.post(`${fixtureOrigin}/__reset`);
  await page.emulateMedia({ colorScheme: scheme });
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await openFixturePaper(page);
  const pane = page.getByTestId('chat-pane'), starters = pane.getByTestId('chat-starter'), box = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(starters).toHaveCount(3);
  // Three different categories, one about the paper's own structure (it has a figure, a table and an equation).
  const categories = await starters.evaluateAll(rows => rows.map(row => row.getAttribute('data-category')!));
  expect(new Set(categories).size).toBe(3);
  expect(categories.some(c => ['method', 'figure', 'equation', 'table'].includes(c))).toBe(true);
  await expect(starters.locator('svg')).toHaveCount(3);
  await expect(pane.getByTestId('study-start')).toHaveCount(0); // ⋯ › Study mode stays in the menu
  // After the starters, the fixed Enter Study Mode row (2026-10-22, LEARNING_GUIDE.md), its own row not a starter.
  const rows = pane.getByTestId('chat-starters').locator('button');
  await expect(rows.last()).toHaveAttribute('data-testid', 'study-entry');
  await expect(rows.last()).toHaveText('Enter Study Mode – Quiz me and help me learn');
  await expect(box).toHaveAttribute('placeholder', 'Ask anything about the paper');
  // One full-width pill with Send inside it on the right, and the starters directly above it.
  const [pill, composer, sendButton, last] = await Promise.all([pane.locator('.composer-pill').boundingBox(), pane.locator('.chat-composer').boundingBox(),
    pane.getByRole('button', { name: 'Send', exact: true }).boundingBox(), rows.last().boundingBox()]);
  expect(pill!.width).toBeGreaterThan(composer!.width - 32);
  expect(sendButton!.x).toBeGreaterThan(pill!.x + pill!.width / 2); expect(sendButton!.x + sendButton!.width).toBeLessThanOrEqual(pill!.x + pill!.width);
  expect(sendButton!.y).toBeGreaterThanOrEqual(pill!.y); expect(sendButton!.y + sendButton!.height).toBeLessThanOrEqual(pill!.y + pill!.height);
  expect(pill!.y - (last!.y + last!.height)).toBeGreaterThanOrEqual(0); expect(pill!.y - (last!.y + last!.height)).toBeLessThan(48);
  await page.mouse.move(0, 0); await page.waitForTimeout(300);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-empty-paper-chat.png` });

  // A click fills the message box and focuses it; nothing is sent until the reader sends.
  const text = (await starters.nth(1).textContent())!;
  await starters.nth(1).click();
  await expect(box).toHaveValue(text); await expect(box).toBeFocused();
  await page.waitForTimeout(500);
  expect((await evidence(request)).requests).toHaveLength(0);
  await expect(page.getByRole('dialog', { name: 'Cloud AI answers' })).toHaveCount(0);
  await expect(starters).toHaveCount(3); // the set stays while this empty chat is on screen
  // Another empty chat draws its own set from the general pool in a general chat.
  await box.fill('');
  await pane.getByRole('button', { name: 'General', exact: true }).click();
  await expect(box).toHaveAttribute('placeholder', 'Ask anything');
  await expect(pane.getByTestId('chat-starter')).toHaveCount(3);
  await expect(pane.getByTestId('chat-starter').first()).toHaveAttribute('data-category', 'general');
  await page.mouse.move(0, 0); await page.waitForTimeout(300);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-empty-general-chat.png` });
  expect(errors).toEqual([]);
});

test('⋯ › Answer options holds Model and Length only (DeepSeek when listed); All chats has search and ≡, no title or Done', async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await request.post(`${fixtureOrigin}/__reset`);
  await request.post(`${fixtureOrigin}/__chat-fixture`, { data: { labels: true } });
  await openFixturePaper(page);
  // The ⋯ menu: Answer options… with the current choice, and Study mode; arrow keys move, Esc closes and returns focus.
  await page.getByTestId('chat-menu').click();
  const menu = page.getByRole('menu', { name: 'Chat menu' });
  // Smaller / Larger text last (B8; the apps keep them in this menu too).
  await expect(menu.getByRole('menuitem')).toHaveText([/^Answer options…\s*Sonnet · Standard$/, 'Study mode', /Smaller text$/, /Larger text$/]);
  await expect(menu.getByTestId('answer-options-item')).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect(menu.getByRole('menuitem', { name: 'Study mode' })).toBeFocused();
  await page.keyboard.press('Escape'); await expect(menu).toHaveCount(0); await expect(page.getByTestId('chat-menu')).toBeFocused();
  await page.getByTestId('chat-menu').click(); await page.getByTestId('answer-options-item').click();
  const options = page.getByRole('dialog', { name: 'Answer options' });
  // Models in two groups since the providers changed (Anthropic models, Other providers), then Length.
  await expect(options.getByRole('radiogroup')).toHaveCount(3);
  await expect(options.getByRole('radiogroup', { name: 'Anthropic models' }).getByRole('radio')).toHaveText(['Haiku', 'Sonnet', 'Opus']);
  await expect(options.getByRole('radiogroup', { name: 'Other providers' }).getByRole('radio')).toHaveText(['DeepSeek']);
  await expect(options.getByRole('radiogroup', { name: 'Length' }).getByRole('radio')).toHaveText(['Brief', 'Standard', 'Detailed']);
  await expect(options.getByRole('button', { name: 'About AI chat options' })).toBeVisible();
  await expect(options).not.toContainText(/credit|Effort|Reset/);
  await options.getByRole('radio', { name: 'DeepSeek', exact: true }).click();
  await expect(options.getByRole('button', { name: /^Use for new (paper|general) chat$/ })).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-answer-options.png` });
  await page.keyboard.press('Escape'); await expect(options).toBeHidden();

  // The question goes with DeepSeek and automatic effort; the answer is labelled model · length.
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('What problem does this paper solve?');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('answer-by')).toHaveText('DeepSeek · Standard');
  expect((await evidence(request)).requests[0].profile).toEqual({ model: 'deepseek', effort: 'auto', length: 'standard' });
  await expect(page.getByTestId('chat-starter')).toHaveCount(0);

  // All chats: one row (search and ≡), All first and chosen, Last read, and the paper only in its column.
  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
  const chats = page.getByRole('dialog', { name: 'All chats' });
  await expect(chats.getByRole('searchbox', { name: 'Search chats' })).toBeFocused();
  // UX audit S23: a title and a round X in the sheet's top row (the only close used to be inside ≡).
  if (info.project.name !== 'phone') await expect(chats.getByRole('heading', { name: 'All chats' })).toBeVisible();
  await expect(chats.getByTestId('history-close')).toBeVisible();
  await expect(chats.getByRole('button', { name: 'Done', exact: true })).toHaveCount(0);
  const [search, lines] = await Promise.all([chats.getByRole('searchbox', { name: 'Search chats' }).boundingBox(), chats.getByTestId('history-menu').boundingBox()]);
  expect(Math.abs((search!.y + search!.height / 2) - (lines!.y + lines!.height / 2))).toBeLessThan(4);
  expect(lines!.x).toBeGreaterThan(search!.x + search!.width - 1);
  await expect(chats.locator('.history-filters button')).toHaveText(['All', 'This paper', 'Paper chats', 'General']);
  await expect(chats.getByRole('button', { name: 'All', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(chats.getByRole('columnheader', { name: 'Last read' })).toBeVisible();
  const secondLine = chats.getByTestId('history-second-line').first();
  if (info.project.name === 'phone') {
    await expect(chats.getByRole('columnheader', { name: 'Paper' })).toHaveCount(0);
    await expect(secondLine).toHaveText('Authored HTML fixture');
  } else {
    await expect(chats.getByRole('columnheader', { name: 'Paper' })).toBeVisible();
    await expect(secondLine).toContainText('The objective compares preferences');
    await expect(secondLine).not.toContainText('Authored HTML fixture');
  }
  // ≡ holds Sort by and Columns; Esc closes the menu, not the sheet.
  await chats.getByTestId('history-menu').click();
  const options2 = page.getByRole('menu', { name: 'All chats options' });
  await expect(options2.getByRole('group', { name: 'Sort by' }).getByRole('menuitemradio')).toHaveText([/Last read/, /Started/, /Title/]);
  await expect(options2.getByRole('menuitemradio', { name: /Last read/ })).toHaveAttribute('aria-checked', 'true');
  // The apps' All chats columns (B9): Kind, Topics and Answer length besides these.
  await expect(options2.getByRole('group', { name: 'Columns' }).getByRole('menuitemcheckbox')).toHaveText([/Paper/, /Kind/, /Topics/, /Messages/, /Started/, /Answer length/]);
  await expect(options2.getByRole('menuitem', { name: 'Close' })).toHaveCount(0);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-all-chats-menu.png` });
  await page.keyboard.press('Escape');
  await expect(options2).toHaveCount(0); await expect(chats).toBeVisible();
  if (info.project.name !== 'phone') {
    await chats.getByTestId('history-menu').click();
    await page.getByRole('menuitemcheckbox', { name: /Messages/ }).click();
    await expect(chats.getByRole('columnheader', { name: 'Messages' })).toBeVisible();
    for (const name of [/Kind/, /Topics/, /Answer length/]) await page.getByRole('menuitemcheckbox', { name }).click();
    await expect(chats.getByRole('columnheader')).toContainText(['Conversation', 'Paper', 'Kind', 'Topics', 'Messages', 'Answer length', 'Last read']);
    const row = chats.getByTestId('history-table').locator('tbody tr').first();
    await expect(row.locator('.history-kind')).toHaveText(/^(Paper|General)$/);
    await expect(row.locator('.history-length')).toHaveText(/^(—|1 word|\d+ words|\d+(\.\d)?k words)$/);
    await page.keyboard.press('Escape');
  }
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-all-chats.png` });
  await page.keyboard.press('Escape');
  await expect(chats).toBeHidden();
});
