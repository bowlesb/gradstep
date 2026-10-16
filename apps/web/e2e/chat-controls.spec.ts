// Model and length in the chat, answer labels and topic titles (2026-10-08; redesigned from build 57 feedback,
// 2026-10-16: the chat's ⋯ › Answer options holds Model and Length only, effort is automatic where the server offers
// it, and Settings › AI chat options sets the defaults and lists the usual credits). Local fixtures only: the fixture
// backend serves the server's published profile table (with automatic effort and DeepSeek unless asked for 'v1') and,
// with `labels`, answers like the chat function.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API, appOrigin as APP } from './environment';
const SHOTS = '../../.artifacts/visual/chat-controls-20261016/web';
async function login(page: Page) {
  await page.goto(APP);
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
}
async function send(page: Page, text: string, consent = false) {
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill(text);
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  if (consent) await page.getByRole('button', { name: 'Allow and get answer' }).click();
}
/** ⋯ › Answer options…, after checking the item's "Sonnet · Standard" summary when given. */
async function answerOptions(page: Page, summary?: string) {
  await page.getByTestId('chat-menu').click();
  if (summary) await expect(page.getByTestId('answer-options-summary')).toHaveText(summary);
  await page.getByTestId('answer-options-item').click();
  const dialog = page.getByRole('dialog', { name: 'Answer options' });
  await expect(dialog).toBeVisible();
  return dialog;
}
async function summary(page: Page) {
  await page.getByTestId('chat-menu').click();
  const text = await page.getByTestId('answer-options-summary').textContent();
  await page.keyboard.press('Escape');
  return text;
}
const evidence = async (request: any) => (await request.get(`${API}/__chat-evidence`)).json();
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

for (const scheme of ['light', 'dark'] as const) test(`choose model and length; effort is automatic; the answer is labelled and the chat titled (${scheme})`, async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit', 'Existing key-persistence gate remains in force.');
  await page.emulateMedia({ colorScheme: scheme });
  await request.post(`${API}/__chat-fixture`, { data: { labels: true } });
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await login(page);
  const dialog = await answerOptions(page, 'Sonnet · Standard');
  // Model and Length, nothing else (owner, build 57: "literally nothing else is needed on this UI").
  await expect(dialog.getByRole('radiogroup')).toHaveCount(2);
  await expect(dialog.getByRole('radio')).toHaveText(['Haiku', 'Sonnet', 'Opus', 'DeepSeek', 'Brief', 'Standard', 'Detailed']);
  await expect(dialog).not.toContainText('credits'); await expect(dialog).not.toContainText('Effort'); await expect(dialog).not.toContainText('Reset');
  await expect(dialog.getByRole('radio', { name: 'Sonnet', exact: true })).toBeFocused();
  await expect(dialog.getByTestId('default-note')).toHaveText('New chats start with these.');
  await dialog.getByRole('radio', { name: 'Opus', exact: true }).click();
  await expect(dialog).toContainText('Most capable; costs the most');
  await expect(dialog.getByTestId('use-for-new-chats')).toBeVisible(); // differs from the default now
  // Arrow keys move within a group.
  await dialog.getByRole('radio', { name: 'Standard', exact: true }).focus(); await page.keyboard.press('ArrowRight');
  await expect(dialog.getByRole('radio', { name: 'Detailed', exact: true })).toHaveAttribute('aria-checked', 'true');
  await expect(dialog.getByRole('radio', { name: 'Detailed', exact: true })).toBeFocused();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-answer-options.png` });
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden(); await expect(page.getByTestId('chat-menu')).toBeFocused();
  expect(await summary(page)).toBe('Opus · Detailed');

  await send(page, 'Explain the preference objective', true);
  await expect(page.getByTestId('answer-by')).toHaveText('Opus · Detailed');
  await expect(page.getByTestId('chat-title')).toHaveText('Preference objective explained');
  const e = await evidence(request);
  // The server picks the effort (it offers automatic effort for Opus · Detailed).
  expect(e.requests[0].profile).toEqual({ model: 'opus', effort: 'auto', length: 'detailed' }); expect(e.requests[0].topic_title).toBe(true);
  await expect.poll(async () => (await evidence(request)).events.length).toBe(4); // root, question, answer, title revision — all encrypted
  expect(JSON.stringify(e.events)).not.toContain('Preference objective');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-answer-title.png` });

  // A follow-up keeps the chat's choice and no longer asks for a title.
  await send(page, 'And the reference model?');
  await expect(page.getByTestId('answer-by')).toHaveCount(2);
  const second = (await evidence(request)).requests[1];
  expect(second.profile).toEqual({ model: 'opus', effort: 'auto', length: 'detailed' }); expect(second.topic_title).toBeUndefined();

  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
  const chats = page.getByRole('dialog', { name: 'All chats' });
  await expect(chats.getByRole('button', { name: 'Preference objective explained', exact: true })).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-all-chats.png` });
  // Rename from the list.
  await chats.getByRole('button', { name: 'Rename Preference objective explained' }).click();
  await chats.getByTestId('rename-input').fill('My DPO notes'); await chats.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(chats.getByRole('button', { name: 'My DPO notes', exact: true })).toBeVisible();
  await chats.getByTestId('history-menu').click(); await chats.getByRole('menuitem', { name: 'Close' }).click();
  await expect(chats).toBeHidden();
  await expect(page.getByTestId('chat-title')).toHaveText('My DPO notes');
  expect(errors).toEqual([]);
});

test('rename in the chat header; AI chat options sets new chats; Use for new chats; a selection action keeps the visible choice', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__chat-fixture`, { data: { labels: true } });
  await login(page);
  await send(page, 'What does beta do?', true);
  await expect(page.getByTestId('chat-title')).toHaveText('Preference objective explained');
  await page.getByRole('button', { name: 'Rename “Preference objective explained”' }).click();
  await page.getByTestId('rename-input').fill('Beta, explained'); await page.keyboard.press('Enter');
  await expect(page.getByTestId('chat-title')).toHaveText('Beta, explained');
  // Escape leaves the title unchanged.
  await page.getByRole('button', { name: 'Rename “Beta, explained”' }).click(); await page.getByTestId('rename-input').fill('Discarded');
  await page.keyboard.press('Escape'); await expect(page.getByTestId('chat-title')).toHaveText('Beta, explained');

  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'AI chat options…' }).click();
  const settings = page.getByRole('dialog', { name: 'AI chat options' });
  // Owner, build 59: "Default options for new chats" holds Model, Length and Visual answers; the rest is behind its ⓘ.
  await expect(settings.getByRole('heading', { name: 'Default options for new chats' })).toBeVisible();
  await expect(settings.getByTestId('visual-answers')).toBeVisible(); await expect(settings.getByTestId('chat-credits')).toHaveCount(0);
  await settings.getByRole('radio', { name: 'Haiku', exact: true }).click();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-default-options.png` });
  await settings.getByRole('button', { name: 'About AI chat options' }).click();
  await expect(settings.getByRole('heading', { name: 'About AI chat options' })).toBeVisible();
  // Per-model detail with who processes it, the usual credits from the published table, and automatic effort.
  await expect(settings.getByTestId('chat-options-models')).toContainText('Processed by Anthropic');
  await expect(settings.getByTestId('chat-options-models')).toContainText('Processed by DeepSeek');
  await expect(settings.getByTestId('chat-credits').getByRole('row', { name: /Sonnet/ })).toContainText('4–24up to 41');
  await expect(settings.getByTestId('effort-note')).toContainText('Effort is chosen automatically for each question');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-ai-chat-options.png` });
  await settings.getByTestId('chat-options-back').click();
  await expect(settings.getByRole('radio', { name: 'Haiku', exact: true })).toHaveAttribute('aria-checked', 'true');
  await settings.getByRole('button', { name: 'Done', exact: true }).click();
  // The open chat keeps its own choice; a new one starts from the default.
  expect(await summary(page)).toBe('Sonnet · Standard');
  await page.getByRole('button', { name: 'New chat', exact: true }).click();
  expect(await summary(page)).toBe('Haiku · Standard');
  // Change it here and make it the default for new chats.
  let options = await answerOptions(page);
  await options.getByRole('radio', { name: 'Brief', exact: true }).click();
  await options.getByTestId('use-for-new-chats').click();
  await expect(options.getByTestId('default-note')).toHaveText('New chats start with these.');
  // The link opens About AI chat options; back from it, the defaults show the same choice.
  await options.getByTestId('about-chat-options').click();
  await expect(options).toBeHidden();
  await expect(settings.getByRole('heading', { name: 'About AI chat options' })).toBeVisible();
  await settings.getByTestId('chat-options-back').click();
  await expect(settings.getByRole('radio', { name: 'Brief', exact: true })).toHaveAttribute('aria-checked', 'true');
  await settings.getByRole('button', { name: 'Done', exact: true }).click();
  // A selection action answers with what the pane showed.
  const frame = page.frameLocator('[data-testid=reader-frame]');
  await frame.locator('p').filter({ hasText: 'preferences' }).first().evaluate(node => { const r = document.createRange(); r.selectNodeContents(node); const s = window.getSelection()!; s.removeAllRanges(); s.addRange(r); document.dispatchEvent(new Event('selectionchange')); });
  await page.getByRole('button', { name: 'Why it matters', exact: true }).click();
  await expect(page.getByTestId('answer-by')).toHaveText('Haiku · Brief');
  const requests = (await evidence(request)).requests;
  expect(requests.at(-1).profile).toEqual({ model: 'haiku', effort: 'auto', length: 'brief' }); expect(requests.at(-1).action).toBe('relevance');
  // Reloading keeps the chat's choice from its answer.
  await page.reload(); await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
  await page.getByRole('dialog', { name: 'All chats' }).getByRole('button', { name: 'Preference objective explained', exact: true }).click();
  expect(await summary(page)).toBe('Haiku · Brief');
  options = await answerOptions(page); await expect(options.getByTestId('default-note')).toBeVisible(); await page.keyboard.press('Escape');
});

test('a server without automatic effort: no DeepSeek, and requests keep the stored effort', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__chat-fixture`, { data: { labels: true, profiles: 'v1' } });
  await login(page);
  const options = await answerOptions(page, 'Sonnet · Standard');
  await expect(options.getByRole('radio')).toHaveText(['Haiku', 'Sonnet', 'Opus', 'Brief', 'Standard', 'Detailed']);
  await page.keyboard.press('Escape');
  await send(page, 'An ordinary question', true);
  await expect(page.getByTestId('answer-by')).toHaveText('Sonnet · Standard');
  expect((await evidence(request)).requests[0].profile).toBeUndefined(); // Sonnet · Low · Standard: exactly today's request
  await (await answerOptions(page)).getByRole('radio', { name: 'Opus', exact: true }).click(); await page.keyboard.press('Escape');
  await send(page, 'A harder question');
  await expect(page.getByTestId('answer-by')).toHaveCount(2);
  expect((await evidence(request)).requests[1].profile).toEqual({ model: 'opus', effort: 'low', length: 'standard' });
  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'AI chat options…' }).click();
  const settings = page.getByRole('dialog', { name: 'AI chat options' });
  await settings.getByRole('button', { name: 'About AI chat options' }).click();
  await expect(settings.getByTestId('effort-note')).toHaveText('Answers use low effort.');
  await expect(settings.getByTestId('chat-credits').getByRole('row', { name: /Sonnet/ })).toContainText('4–24up to 37');
  await expect(settings.getByTestId('chat-options-models')).not.toContainText('DeepSeek');
});

test('a server without the profile table: the default stays visible, options can be retried, and requests stay as before', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__chat-fixture`, { data: { profiles: false } });
  await login(page);
  const options = await answerOptions(page, 'Sonnet · Standard');
  await expect(options).toContainText('Answers use Sonnet · Standard.');
  await expect(options.getByRole('radio', { name: 'Opus', exact: true })).toBeDisabled();
  await options.getByRole('button', { name: 'Retry loading options' }).click();
  await expect(options.getByRole('button', { name: 'Retry loading options' })).toBeEnabled();
  await page.keyboard.press('Escape');
  await send(page, 'An ordinary question', true);
  await expect(page.getByTestId('chat-assistant')).toBeVisible();
  await expect(page.getByTestId('answer-by')).toHaveCount(0);
  const body = (await evidence(request)).requests[0];
  expect(body.profile).toBeUndefined(); expect(body.topic_title).toBeUndefined();
});

test('a saved question retains its settings through lost acknowledgement and reload; Get answer is explicit', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__chat-fixture`, { data: { labels: true, loseAppendAck: true } });
  await login(page);
  let options = await answerOptions(page);
  await options.getByRole('radio', { name: 'Opus', exact: true }).click();
  await options.getByRole('radio', { name: 'Detailed', exact: true }).click(); await page.keyboard.press('Escape');
  await send(page, 'Question with an exact saved answer choice');
  await expect(page.getByRole('alert')).toContainText('question couldn’t be saved');
  expect((await evidence(request)).requests).toHaveLength(0);
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('A later draft must survive');
  await expect(page.getByTestId('draft-status')).toContainText(/Saved (on this device|in this browser)\./);
  await page.reload(); await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await expect(page.getByTestId('chat-user')).toHaveText(/Question with an exact saved answer choice/);
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('A later draft must survive');
  await expect(page.getByTestId('retry-profile')).toHaveText('This question: Opus · Detailed');
  expect((await evidence(request)).requests).toHaveLength(0);
  // The next-question control does not change the saved question's requested settings.
  options = await answerOptions(page);
  await options.getByRole('radio', { name: 'Haiku', exact: true }).click(); await page.keyboard.press('Escape');
  await page.getByRole('button', { name: 'Get answer', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Cloud AI answers' })).toContainText('This question: Opus · Detailed');
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('answer-by')).toHaveText('Opus · Detailed');
  const actual = await evidence(request); expect(actual.requests).toHaveLength(1);
  expect(actual.requests[0].profile).toEqual({ model: 'opus', effort: 'auto', length: 'detailed' });
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('A later draft must survive');
});
