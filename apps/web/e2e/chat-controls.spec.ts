// Model, effort and length in the chat, answer labels and topic titles (2026-10-08). Local fixtures only: the fixture
// backend serves the server's published profile table and, with `labels`, answers like the 2026-10-08 chat function.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API, appOrigin as APP } from './environment';
const SHOTS = '../../.artifacts/visual/chat-controls-20261008/web';
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
const evidence = async (request: any) => (await request.get(`${API}/__chat-evidence`)).json();
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

for (const scheme of ['light', 'dark'] as const) test(`choose model, effort and length; the answer is labelled and the chat titled (${scheme})`, async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit', 'Existing key-persistence gate remains in force.');
  await page.emulateMedia({ colorScheme: scheme });
  await request.post(`${API}/__chat-fixture`, { data: { labels: true } });
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await login(page);
  const control = page.getByTestId('profile-button');
  await expect(control).toHaveText('Sonnet · Low · Standard');
  await control.click();
  const panel = page.getByRole('dialog', { name: 'Answers in this chat' });
  await expect(panel).toBeVisible();
  await expect(page.getByTestId('profile-estimate')).toContainText('Usually 4–24 credits · up to 37');
  await expect(panel.getByRole('radio', { name: 'Sonnet', exact: true })).toBeFocused();
  await panel.getByRole('radio', { name: 'Opus', exact: true }).click();
  await expect(page.getByTestId('profile-estimate')).toContainText('Usually 8–47 credits · up to 74');
  await expect(panel).toContainText('Most capable; costs the most');
  // Arrow keys move within a group.
  await panel.getByRole('radio', { name: 'Low', exact: true }).focus(); await page.keyboard.press('ArrowRight'); await page.keyboard.press('ArrowRight');
  await expect(panel.getByRole('radio', { name: 'High', exact: true })).toHaveAttribute('aria-checked', 'true');
  await expect(panel.getByRole('radio', { name: 'High', exact: true })).toBeFocused();
  await panel.getByRole('radio', { name: 'Detailed', exact: true }).click();
  await expect(page.getByTestId('profile-estimate')).toContainText('Usually 24–63 credits · up to 114');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-controls.png` });
  await page.keyboard.press('Escape');
  await expect(panel).toHaveCount(0); await expect(control).toBeFocused();
  await expect(control).toHaveText('Opus · High · Detailed');

  await send(page, 'Explain the preference objective', true);
  await expect(page.getByTestId('answer-by')).toHaveText('Opus · High · Detailed');
  await expect(page.getByTestId('chat-title')).toHaveText('Preference objective explained');
  const e = await evidence(request);
  expect(e.requests[0].profile).toEqual({ model: 'opus', effort: 'high', length: 'detailed' }); expect(e.requests[0].topic_title).toBe(true);
  await expect.poll(async () => (await evidence(request)).events.length).toBe(4); // root, question, answer, title revision — all encrypted
  expect(JSON.stringify(e.events)).not.toContain('Preference objective');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-answer-title.png` });

  // A follow-up keeps the chat's choice and no longer asks for a title.
  await send(page, 'And the reference model?');
  await expect(page.getByTestId('answer-by')).toHaveCount(2);
  const second = (await evidence(request)).requests[1];
  expect(second.profile).toEqual({ model: 'opus', effort: 'high', length: 'detailed' }); expect(second.topic_title).toBeUndefined();

  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
  const chats = page.getByRole('dialog', { name: 'All chats' });
  await expect(chats.getByRole('button', { name: 'Preference objective explained', exact: true })).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-all-chats.png` });
  // Rename from the list.
  await chats.getByRole('button', { name: 'Rename Preference objective explained' }).click();
  await chats.getByTestId('rename-input').fill('My DPO notes'); await chats.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(chats.getByRole('button', { name: 'My DPO notes', exact: true })).toBeVisible();
  await chats.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(page.getByTestId('chat-title')).toHaveText('My DPO notes');
  expect(errors).toEqual([]);
});

test('rename in the chat header; a new chat starts from Chat defaults; a selection action keeps the visible choice', async ({ page, request }, info) => {
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

  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'Chat defaults…' }).click();
  const defaults = page.getByRole('dialog', { name: 'Chat defaults' });
  await defaults.getByRole('radio', { name: 'Haiku', exact: true }).click();
  await expect(defaults.getByTestId('profile-estimate')).toContainText('Usually 1–2 credits · up to 2');
  await defaults.getByRole('button', { name: 'Done', exact: true }).click();
  // The open chat keeps its own choice; a new one starts from the default.
  await expect(page.getByTestId('profile-button')).toHaveText('Sonnet · Low · Standard');
  await page.getByRole('button', { name: 'New chat', exact: true }).click();
  await expect(page.getByTestId('profile-button')).toHaveText('Haiku · Low · Standard');
  // Change it here, then use a selection action: the new conversation answers with what the pane showed.
  await page.getByTestId('profile-button').click();
  await page.getByRole('dialog', { name: 'Answers in this chat' }).getByRole('radio', { name: 'Brief', exact: true }).click();
  await page.keyboard.press('Escape');
  const frame = page.frameLocator('[data-testid=reader-frame]');
  await frame.locator('p').filter({ hasText: 'preferences' }).first().evaluate(node => { const r = document.createRange(); r.selectNodeContents(node); const s = window.getSelection()!; s.removeAllRanges(); s.addRange(r); document.dispatchEvent(new Event('selectionchange')); });
  await page.getByRole('button', { name: 'Why it matters', exact: true }).click();
  await expect(page.getByTestId('answer-by')).toHaveText('Haiku · Low · Brief');
  const requests = (await evidence(request)).requests;
  expect(requests.at(-1).profile).toEqual({ model: 'haiku', effort: 'low', length: 'brief' }); expect(requests.at(-1).action).toBe('relevance');
  // Reloading keeps the chat's choice from its answer.
  await page.reload(); await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
  await page.getByRole('dialog', { name: 'All chats' }).getByRole('button', { name: 'Preference objective explained', exact: true }).click();
  await expect(page.getByTestId('profile-button')).toHaveText('Haiku · Low · Brief');
});

test('a server without the profile table: the default stays visible, options can be retried, and requests stay as before', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__chat-fixture`, { data: { profiles: false } });
  await login(page);
  await expect(page.getByTestId('profile-button')).toHaveText('Sonnet · Low · Standard');
  await page.getByTestId('profile-button').click();
  const panel = page.getByRole('dialog', { name: 'Answers in this chat' });
  await expect(panel).toContainText('Answers use Sonnet · Low · Standard.');
  await expect(panel.getByRole('radio', { name: 'Opus', exact: true })).toBeDisabled();
  await panel.getByRole('button', { name: 'Retry loading options' }).click();
  await expect(panel.getByRole('button', { name: 'Retry loading options' })).toBeEnabled();
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
  await page.getByTestId('profile-button').click();
  const panel = page.getByRole('dialog', { name: 'Answers in this chat' });
  await panel.getByRole('radio', { name: 'Opus', exact: true }).click();
  await panel.getByRole('radio', { name: 'High', exact: true }).click();
  await panel.getByRole('radio', { name: 'Detailed', exact: true }).click(); await page.keyboard.press('Escape');
  await send(page, 'Question with an exact saved answer choice');
  await expect(page.getByRole('alert')).toContainText('question couldn’t be saved');
  expect((await evidence(request)).requests).toHaveLength(0);
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('A later draft must survive');
  await expect(page.getByTestId('draft-status')).toContainText('Saved on this device.');
  await page.reload(); await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await expect(page.getByTestId('chat-user')).toHaveText(/Question with an exact saved answer choice/);
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('A later draft must survive');
  await expect(page.getByTestId('retry-profile')).toHaveText('This question: Opus · High · Detailed');
  expect((await evidence(request)).requests).toHaveLength(0);
  // The next-question control does not change the saved question's requested settings.
  await page.getByTestId('profile-button').click();
  await panel.getByRole('radio', { name: 'Haiku', exact: true }).click(); await page.keyboard.press('Escape');
  await page.getByRole('button', { name: 'Get answer', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Cloud AI answers' })).toContainText('This question: Opus · High · Detailed');
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('answer-by')).toHaveText('Opus · High · Detailed');
  const actual = await evidence(request); expect(actual.requests).toHaveLength(1);
  expect(actual.requests[0].profile).toEqual({ model: 'opus', effort: 'high', length: 'detailed' });
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('A later draft must survive');
});
