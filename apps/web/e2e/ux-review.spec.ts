// Pre-build UX review (docs/UX_REVIEW.md): deterministic screenshots of the browser's main screens and chat states
// over the local fixture backend, in light and dark, desktop and phone. No hosted or paid request is made. Run with
// `node scripts/ux-review.mjs`; the contact sheet lands in .artifacts/ux/web/index.html.
import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';

const OUT = new URL('../../../.artifacts/ux/web/', import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const shot = (page: Page, name: string, info: { project: { name: string } }) =>
  page.screenshot({ path: `${OUT}${info.project.name}-${name}.png`, fullPage: false, animations: 'disabled' });

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
async function openPaper(page: Page) {
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
}
const message = (page: Page) => page.getByRole('textbox', { name: 'Message', exact: true });

for (const scheme of ['light', 'dark'] as const) {
  test(`${scheme}: sign-in, library, reader and the chat states`, async ({ page, request }, info) => {
    test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the review needs a signed-in browser (as the other key-dependent journeys).');
    // Legacy fixture papers try their official arXiv HTML first; the review reads the fixture bundle (no test reaches arXiv).
    await page.route('https://arxiv.org/**', route => route.abort());
    await request.post(`${API}/__reset`);
    await page.emulateMedia({ colorScheme: scheme });
    const name = (screen: string) => `${scheme}-${screen}`;
    await page.goto('/');
    await shot(page, name('signin'), info);
    await signIn(page);
    await shot(page, name('library'), info);
    await openPaper(page);
    await shot(page, name('reader-chat-empty'), info);
    // The consent sheet, then a slow answer: the waiting state, streaming text, and the finished answer with
    // citations and follow-up suggestions.
    await request.post(`${API}/__chat-fixture`, { data: { mode: 'slow', labels: true } });
    await message(page).fill('Why does the objective need a reference model?');
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Allow and get answer' })).toBeVisible();
    await shot(page, name('chat-consent'), info);
    await page.getByRole('button', { name: 'Allow and get answer' }).click();
    await expect(page.getByTestId('chat-streaming')).toBeVisible();
    await shot(page, name('chat-waiting'), info);
    await expect(page.getByTestId('chat-streaming')).toContainText('objective');
    await shot(page, name('chat-streaming'), info);
    await expect(page.getByTestId('chat-assistant')).toBeVisible({ timeout: 60_000 });
    await page.getByTestId('follow-ups-toggle').click(); // suggested questions open on request (build 46)
    await expect(page.getByTestId('follow-up').first()).toBeVisible();
    await shot(page, name('chat-answer'), info);
    await page.frameLocator('[data-testid=reader-frame]').locator('body').evaluate(() => scrollTo(0, document.documentElement.scrollHeight)); // Back is offered only when there's somewhere to return to
    const drawer = await page.getByTestId('pane-right').evaluate(e => e.classList.contains('overlay'));
    await page.getByTestId('chat-assistant').locator('.cite').first().click();
    await expect(page.getByTestId('citation-back')).toBeVisible();
    await shot(page, name('chat-citation-jump'), info);
    if (drawer) {
      await page.getByTestId('chat-back').click(); // a phone's drawer closed for the passage; Back to chat reopens it
      await page.getByTestId('follow-ups-toggle').click(); // reopened, its suggestions start folded as ever
    }
    await page.getByTestId('follow-up').first().click();
    await shot(page, name('chat-follow-up-filled'), info);
    await page.getByTestId('profile-button').click();
    await expect(page.getByTestId('profile-panel')).toBeVisible();
    await shot(page, name('chat-answer-settings'), info);
    await page.keyboard.press('Escape');
    // Failure wording: no credits.
    await request.post(`${API}/__chat-fixture`, { data: { mode: 'insufficient_credits' } });
    await message(page).fill('A question without credits');
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(page.getByRole('alert')).toContainText('Not enough credits');
    await shot(page, name('chat-no-credits'), info);
    await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click();
    await expect(page.getByRole('heading', { name: 'All chats' })).toBeVisible();
    await shot(page, name('all-chats'), info);
  });
}
