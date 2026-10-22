// Browser parity with the apps' Settings (owner, builds 57–59): the account menu shows AI credits and the Subscription
// plan as the server reports them (explained behind ⓘ; bought in the apps, never here), and Your assets with Chats and
// Diagrams. Local fixtures only.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';
const SHOTS = '../../.artifacts/account-assets';

/** A row's words and its value (the ⓘ's own text stays out of it). */
async function row(page: Page, testID: string, label: string, value: string | RegExp) {
  const r = page.getByTestId(testID);
  await expect(r.locator('span').first()).toContainText(label);
  await expect(r.locator('.menu-fact-value')).toHaveText(value);
}
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
}
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

for (const scheme of ['light', 'dark'] as const) test(`AI credits, Subscription plan and Your assets in the account menu (${scheme})`, async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  await page.emulateMedia({ colorScheme: scheme });
  await request.post(`${API}/__store`, { data: { available: 1240, reserved: 30, plan: 'pro' } });
  await signIn(page);
  await page.getByTestId('account-menu').click();
  const menu = page.getByRole('menu');
  await row(page, 'account-credits', 'AI credits', '1,240');
  await row(page, 'account-held', 'Held for answers in progress', '30');
  await row(page, 'account-plan', 'Subscription plan', 'Pro');
  // Nothing to buy here: credits and plans are bought in the apps.
  await expect(menu).not.toContainText(/Get credits|Buy|Upgrade/);
  await expect(menu.getByRole('group', { name: 'Your assets' }).getByRole('menuitem')).toHaveText([/Chats$/, /Diagrams$/, /Snippets$/, /Equation explanations$/, /Figure explanations$/]);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-menu.png` });

  // The explanations sit behind ⓘ beside the words; the rest of the page darkens; Esc hides only the bubble.
  const tip = menu.getByTestId('credits-info');
  await expect(tip).toHaveAccessibleDescription(/Credits are bought in the Gradstep app on iPhone, iPad or Mac\.$/);
  await tip.focus(); await page.keyboard.press('Enter');
  const bubble = menu.getByText('Credits pay for AI answers');
  await expect(bubble).toBeVisible(); await expect(page.getByTestId('info-scrim')).toBeVisible();
  const at = (await bubble.boundingBox())!;
  expect(at.x).toBeGreaterThanOrEqual(0); expect(at.x + at.width).toBeLessThanOrEqual(page.viewportSize()!.width);
  expect(await page.evaluate(([x, y]) => !!document.elementFromPoint(x, y)?.closest('.info-tip-text'), [at.x + at.width / 2, at.y + at.height / 2])).toBe(true);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-credits-info.png`, animations: 'disabled' });
  await page.keyboard.press('Escape');
  await expect(bubble).toBeHidden(); await expect(page.getByTestId('info-scrim')).toHaveCount(0); await expect(menu).toBeVisible();
  // A press on the dimmed page hides the bubble and keeps the menu.
  await menu.getByTestId('plan-info').click(); await expect(menu.getByText('Reading papers is always free.', { exact: false })).toBeVisible();
  await page.mouse.click(5, page.viewportSize()!.height - 5);
  await expect(menu.getByText('Reading papers is always free.', { exact: false })).toBeHidden(); await expect(menu).toBeVisible();

  // Diagrams: none yet.
  await menu.getByRole('menuitem', { name: 'Diagrams' }).click();
  const diagrams = page.getByRole('dialog', { name: 'All diagrams' });
  await expect(diagrams.getByTestId('diagrams-empty')).toHaveText('No diagrams yet');
  await diagrams.getByRole('button', { name: 'Done' }).click(); await expect(diagrams).toBeHidden();
  // Equation and Figure explanations (owner, build 62): none yet, in the apps' words (KeptExplanationsView); since B4 they
  // are kept in this browser, and the ⓘ says so.
  for (const [item, title] of [['assets-equations', 'Equation explanations'], ['assets-figures', 'Figure explanations']] as const) {
    await page.getByTestId('account-menu').click(); await page.getByTestId(item).click();
    const kept = page.getByRole('dialog', { name: title });
    await expect(kept.getByRole('heading', { name: title })).toBeVisible();
    const noun = item === 'assets-equations' ? 'equation' : 'figure';
    await expect(kept.getByTestId('explanations-empty')).toHaveText(`No ${noun} explanations${noun === 'equation' ? 'Equations' : 'Figures'} you ask the AI Explainer about are kept in this browser.`);
    await expect(kept.getByTestId('explanations-info')).toHaveAccessibleDescription('Kept in this browser, encrypted with its key, as the apps keep them on your iPhone, iPad or Mac. Opening one shows it again without a new request.');
    if (item === 'assets-equations') await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-equation-explanations.png` });
    await kept.getByTestId('explanations-close').click(); await expect(kept).toBeHidden();
  }
  // Chats opens All chats, as the top bar's Chats does.
  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'Chats' }).click();
  await expect(page.getByRole('dialog', { name: 'All chats' })).toBeVisible();
});

test('a reader without a plan sees Free; a failed read is a dash, never a broken menu', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signIn(page);
  await page.getByTestId('account-menu').click();
  await row(page, 'account-credits', 'AI credits', '1,000');
  await expect(page.getByTestId('account-held')).toHaveCount(0);
  await row(page, 'account-plan', 'Subscription plan', 'Free');
  await page.getByTestId('account-menu').click(); await expect(page.getByRole('menu')).toHaveCount(0);
  // The plan's read fails: its row says nothing new, the balance is still read, the menu works.
  await request.post(`${API}/__store`, { data: { available: 990, reserved: 0 } });
  await request.post(`${API}/__fault`, { data: { path: 'rest/v1/rpc/v1_store_summary', kind: 500 } });
  await page.reload(); await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
  await page.getByTestId('account-menu').click();
  await row(page, 'account-credits', 'AI credits', '990');
  await row(page, 'account-plan', 'Subscription plan', '—');
  await expect(page.getByRole('menuitem', { name: 'Privacy & data' })).toBeVisible();
});

test('Diagrams lists what the chats drew, newest first, and opens one as in its answer', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop', 'Drawn through the paper chat beside the reader.');
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'diagram' } });
  await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Draw a preference diagram');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('chat-assistant')).toBeVisible();
  await expect(page.getByTestId('chat-pane').getByRole('button', { name: 'Full size' })).toBeVisible();

  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'Diagrams' }).click();
  const diagrams = page.getByRole('dialog', { name: 'All diagrams' });
  const rows = diagrams.getByTestId('diagram-list').getByRole('button');
  await expect(rows).toHaveCount(1);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-diagrams-list.png` });
  await rows.first().click();
  const detail = diagrams.getByTestId('diagram-detail');
  await expect(detail.locator('iframe')).toBeVisible();
  await expect(detail.getByRole('button', { name: 'Full size' })).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-diagram-detail.png` });
  await diagrams.getByTestId('diagrams-back').click(); await expect(rows).toHaveCount(1);
  await diagrams.getByRole('button', { name: 'Done' }).click(); await expect(diagrams).toBeHidden();
});
