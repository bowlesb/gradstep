// Owner reports from TestFlight builds 57–58 (2026-10-16), brought to the browser as the apps have them: the account
// menu (About with Report and My reports for everyone; operator tools in a grey Admin group, see support-reports.spec),
// Privacy & data with Papers and arXiv and Reports, ⓘ explanations in AI chat options, and a library row that keeps its
// height while a paper is being added. The Feed's Add spinner is in parity.spec and paper-search.spec. Local fixtures only.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin } from './environment';
import { durableKeys } from './key-capability';
const SHOTS = '../../.artifacts/owner-58';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByRole('link', { name: 'Library' })).toBeVisible();
}
test.beforeEach(async ({ request }) => { await request.post(`${fixtureOrigin}/__reset`); });

for (const scheme of ['light', 'dark'] as const) test(`account menu, Privacy & data and the ⓘ in AI chat options (${scheme})`, async ({ page }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys; the account menu requires an authenticated browser.');
  await page.emulateMedia({ colorScheme: scheme });
  await signIn(page);
  await page.getByTestId('account-menu').click();
  const menu = page.getByRole('menu');
  // Who and the sync state only; About with Report and My reports beside it; no Admin group for a reader.
  await expect(menu).not.toContainText('Signed in with');
  await expect(menu.getByRole('menuitem')).toHaveText(['AI chat options…', 'Keyboard shortcuts', 'How Gradstep works', 'Privacy & data', 'Report this screen…',
    'My reports', 'Sign out…', 'Delete account…'].map(t => new RegExp(`^\\s*${t.replace(/[.…&]/g, c => `\\${c}`)}$`)));
  await expect(menu.getByRole('group', { name: 'Admin' })).toHaveCount(0);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-account-menu.png` });

  await menu.getByRole('menuitem', { name: 'Privacy & data' }).click();
  const privacy = page.getByRole('dialog', { name: 'Privacy & data' });
  await expect(privacy.getByRole('heading', { level: 3 })).toHaveText(['Your notes and conversations', 'AI answers', 'Papers and arXiv', 'Reports']);
  const arxiv = privacy.getByTestId('privacy-arxiv');
  await expect(arxiv).toContainText('Papers open from the official web version or PDF that arXiv publishes. Your device downloads them directly from arXiv when you open a paper, and prepares them for reading on the device, for you alone. A PDF you open comes straight from arXiv in a new tab.');
  await expect(arxiv).toContainText('Your device also asks arXiv when you search for papers. Gradstep’s servers never contact arXiv; the Feed’s list of new papers comes from DataCite, which publishes arXiv’s records.');
  await expect(arxiv).toContainText('Requests to arXiv are spaced out, name Gradstep, and stop for a day if arXiv asks this device to slow down, as arXiv’s API Terms of Use require. Each paper stays under its authors’ license, with a link back to arXiv.');
  await expect(arxiv.getByRole('link', { name: 'arXiv API Terms of Use' })).toHaveAttribute('href', 'https://info.arxiv.org/help/api/tou.html');
  await expect(arxiv).toContainText('Thank you to arXiv for use of its open access interoperability.');
  await expect(privacy).toContainText('to Anthropic, or to DeepSeek when you choose it in Answer options.');
  await expect(privacy).toContainText('A report you send, with its screenshot and notes, goes to Gradstep’s support so we can fix the problem, and is kept until you delete your account.');
  await expect(privacy).not.toContainText('fetched by our server');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-privacy.png` });
  await privacy.getByRole('button', { name: 'Done' }).click();

  // AI chat options: the explanations sit behind ⓘ beside the words; Enter shows one, Esc hides it.
  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'AI chat options…' }).click();
  const options = page.getByRole('dialog', { name: 'AI chat options' });
  const tip = options.getByTestId('visual-answers-info');
  await expect(tip).toHaveAccessibleDescription('Lets the assistant draw diagrams and explanations beside its answers; off, it answers in prose.');
  await expect(options.getByText('Lets the assistant draw diagrams')).toBeHidden();
  await tip.focus(); await page.keyboard.press('Enter');
  await expect(options.getByText('Lets the assistant draw diagrams')).toBeVisible();
  await expect(tip).toHaveAttribute('aria-expanded', 'true');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-${scheme}-ai-chat-options-info.png` });
  await page.keyboard.press('Escape');
  await expect(options.getByText('Lets the assistant draw diagrams')).toBeHidden();
  await expect(options).toBeVisible(); // Esc on the ⓘ hides only its text
  await expect(page.getByTestId('visual-answers')).toBeChecked(); // the ⓘ never toggles the setting it explains
});

test('a paper being added keeps its row height when its title and authors arrive', async ({ page }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await signIn(page);
  await page.getByTestId('add-paper').click();
  await page.getByTestId('arxiv-input').fill('2605.01234');
  await page.getByTestId('arxiv-add').click();
  // The row before the paper's details arrive (the fixture adds them 0.8 s after the import starts).
  const before = await (await page.waitForFunction(() => {
    const row = document.querySelector<HTMLElement>('tr.adding[data-testid=paper-row]');
    return row ? { key: row.dataset.rowKey!, height: row.getBoundingClientRect().height } : null;
  }, undefined, { polling: 'raf', timeout: 8_000 })).jsonValue();
  const row = page.locator(`tr[data-row-key="${before!.key}"]`);
  await expect(row).toContainText('Paper 2605.01234', { timeout: 8_000 });
  await expect(row).not.toHaveClass(/\badding\b/);
  const after = (await row.boundingBox())!.height;
  // Never taller once the details arrive (a short title may leave the reserved second line empty).
  expect(after).toBeLessThanOrEqual(before!.height + 1);
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-library-adding-row.png` });
});
