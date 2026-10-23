// The large-screen workspace (legacy three-pane layout) and its narrow fallback, under the production CSP.
import { openAddPaper, openSettings } from './device-reader-helpers';
import { type Page, expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

import { fixtureOrigin as FIXTURE } from './environment';
const shots = '../../.artifacts/web-layout/';
const shot = (page: Page, name: string) => page.screenshot({ path: `${shots}${name}.png` });

function watch(page: Page) {
  const problems: string[] = [];
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource: the server responded with a status of (401|403|422)/.test(m.text())
    && !(m.text().includes('404') && m.location().url.includes('/functions/v1/discover?'))
    && !m.location().url.startsWith('https://arxiv.org/')) problems.push(m.text()); }); // arXiv is blocked on purpose
  page.on('pageerror', e => problems.push(String(e)));
  return problems;
}
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
}
const box = async (page: Page, selector: string) => (await page.locator(selector).boundingBox())!;

test.beforeEach(async ({ request, page }) => {
  await request.post(`${FIXTURE}/__reset`);
  // Legacy fixture papers try their official arXiv HTML first; these journeys read the fixture bundle (no test reaches arXiv).
  await page.route('https://arxiv.org/**', route => route.abort());
});

for (const [width, height] of [[1440, 900], [1920, 1080]] as const) {
  for (const scheme of ['light', 'dark'] as const) {
    test(`workspace at ${width}×${height} (${scheme})`, async ({ page }, info) => {
      test.skip(info.project.name !== 'desktop', 'Large-screen layout runs in the desktop project.');
      test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
      const problems = watch(page);
      await page.setViewportSize({ width, height });
      await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
      await signIn(page);
      const name = `${width}-${scheme}`;

      // Library: the filters rail, a full-width table with the Authors column, no chat pane by default.
      const rail = page.getByRole('navigation', { name: 'Library filters' });
      await expect(rail).toBeVisible();
      await expect(page.getByRole('columnheader', { name: 'Authors' })).toBeVisible();
      await expect(page.getByTestId('pane-right')).toHaveCount(0);
      await expect(page.getByRole('toolbar', { name: 'Filter library' })).toHaveCount(0); // the rail replaces the chips
      await shot(page, `library-${name}`);
      await rail.getByRole('button', { name: /^Alignment/ }).click();
      await expect(page.getByTestId('paper-row')).toHaveCount(1);
      await rail.getByRole('button', { name: /^Alignment/ }).click();

      // Paper: contents rail, the paper, and the chat pane beside it.
      await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
      const frame = page.frameLocator('[data-testid=reader-frame]');
      await expect(frame.locator('h1').first()).toContainText('Direct Preference Optimization');
      const contents = page.getByRole('navigation', { name: 'Contents' });
      await expect(contents.getByRole('button').first()).toBeVisible();
      await expect(page.getByTestId('pane-right')).toContainText('Ask about this paper');
      const paper = await box(page, '.pane-center'), left = await box(page, '[data-testid=pane-left]'), right = await box(page, '[data-testid=pane-right]');
      expect(left.x).toBe(0);
      expect(paper.x).toBeGreaterThan(left.width);
      expect(right.x).toBeGreaterThan(paper.x + paper.width - 1);
      expect(paper.width).toBeGreaterThan(width / 2 - 100);
      const section = contents.getByRole('button', { name: /Theoretical Analysis/ });
      await section.click();
      await expect(section).toHaveAttribute('aria-current', 'location');
      await page.waitForTimeout(400);
      await shot(page, `reader-${name}`);
      // The appearance toggle reaches the sandboxed paper too (the frame rewrites its own color-scheme conditions).
      const frameDark = () => frame.locator('body').evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--sr-bg').trim() === '#0f0f0f');
      expect(await frameDark()).toBe(scheme === 'dark');
      await page.getByTestId('theme').click();
      await expect.poll(frameDark).toBe(scheme !== 'dark');
      await page.getByTestId('theme').click();
      await expect.poll(frameDark).toBe(scheme === 'dark');

      // Find in the paper (⌘F / Ctrl+F), next match with Enter, Escape closes.
      await frame.locator('body').click({ position: { x: 5, y: 5 } });
      await page.keyboard.press('ControlOrMeta+f');
      await expect(page.getByTestId('find-input')).toBeFocused();
      await page.getByTestId('find-input').fill('preference');
      await expect(page.getByTestId('find-count')).toHaveText(/^\d+ of \d+$/);
      const first = await page.getByTestId('find-count').textContent();
      await page.getByTestId('find-input').press('Enter');
      await expect(page.getByTestId('find-count')).not.toHaveText(first!);
      if (width === 1440 && scheme === 'light') await shot(page, 'find-1440-light');
      await page.getByTestId('find-input').press('Escape');
      await expect(page.getByTestId('find-input')).toHaveCount(0);

      // Figures: the gallery, one figure, arrows, back to the gallery, Show in paper (with Back).
      await page.getByTestId('figures').click();
      const grid = page.getByRole('list', { name: 'Figures' });
      await expect(grid.getByRole('button')).toHaveCount(4);
      await expect(grid.locator('img').first()).toBeVisible();
      if (width === 1440) await shot(page, `figures-${name}`);
      await grid.getByRole('button').first().click();
      await expect(page.getByTestId('figure-count')).toHaveText('1 of 4');
      await page.keyboard.press('ArrowRight');
      await expect(page.getByTestId('figure-count')).toHaveText('2 of 4');
      await page.keyboard.press('Escape');
      await expect(grid).toBeVisible();
      await grid.getByRole('button').nth(2).click();
      await page.getByTestId('show-in-paper').click();
      await expect(page.getByTestId('citation-back')).toBeVisible();
      await page.getByTestId('citation-back').click();

      // Panes: drag the rail wider (remembered), [ and ] toggle, the legacy edge handle restores.
      const before = (await box(page, '[data-testid=pane-left]')).width;
      const splitter = await box(page, '.splitter-left');
      await page.mouse.move(splitter.x + 2, splitter.y + 200);
      await page.mouse.down();
      await page.mouse.move(splitter.x + 60, splitter.y + 200, { steps: 4 });
      await page.mouse.move(splitter.x + 82, splitter.y + 200, { steps: 2 });
      await page.mouse.up();
      await expect.poll(async () => Math.round((await box(page, '[data-testid=pane-left]')).width)).toBe(Math.round(before + 80));
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.keyboard.press(']');
      await expect(page.getByTestId('pane-right')).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Show chat' })).toBeVisible();
      await page.keyboard.press('[');
      await expect(page.getByTestId('pane-left')).toHaveCount(0);
      await page.getByRole('button', { name: 'Show side panel' }).click();
      await page.getByRole('button', { name: 'Show chat' }).click();
      await page.reload();
      await expect(page.getByRole('navigation', { name: 'Contents' }).getByRole('button').first()).toBeVisible();
      expect(Math.round((await box(page, '[data-testid=pane-left]')).width)).toBe(Math.round(before + 80));

      // Search beside the paper (owner, 2026-10-22): the left panel's list; the paper keeps its place; Esc twice puts
      // Contents back (reader audit R1–R3).
      const centre = await box(page, '.pane-center');
      await page.getByTestId('search').click();
      await expect(page.getByTestId('rail-search')).toBeFocused();
      await page.getByTestId('rail-search').fill('direct');
      await expect(page.getByTestId('search-result').first()).toContainText('Direct Preference Optimization');
      expect(await box(page, '.pane-center')).toEqual(centre);
      if (width === 1440) await shot(page, `search-list-${name}`);
      await page.getByTestId('rail-search').press('Escape'); await page.getByTestId('rail-search').press('Escape');
      await expect(page.getByTestId('search-rail')).toHaveCount(0);
      await expect(page.getByRole('tablist', { name: 'Side panel' }).getByRole('tab', { name: 'Contents' })).toHaveAttribute('aria-selected', 'true');

      // Feed: topics in the rail, cards, add in place.
      await page.getByRole('link', { name: 'Feed' }).click();
      await expect(page.getByRole('navigation', { name: 'Feed topics' })).toBeVisible();
      const cards = page.getByTestId('feed-grid').locator('li');
      await expect(cards).toHaveCount(3);
      await expect(cards.filter({ hasText: 'Direct Preference Optimization' }).getByRole('button', { name: 'In library' })).toBeEnabled(); // it opens the paper
      if (width === 1440) await shot(page, `feed-${name}`);
      await cards.nth(1).getByRole('button', { name: '+ Add to library' }).click();
      await expect(cards.nth(1).getByRole('button', { name: 'In library' })).toBeVisible({ timeout: 10_000 });

      // Add by DOI (add-paper) and a link our servers can't fetch.
      await openAddPaper(page);
      await page.getByTestId('arxiv-input').fill('https://publisher.example/paper.pdf');
      await page.getByTestId('arxiv-add').click();
      await expect(page.getByTestId('add-outcome')).toContainText('needs a sign-in or subscription');
      if (width === 1440 && scheme === 'light') await shot(page, 'add-blocked-1440-light');
      await page.getByTestId('arxiv-input').fill('doi:10.48550/arXiv.1706.03762');
      await page.getByTestId('arxiv-add').click();
      await expect(page.getByTestId('add-outcome')).toContainText('Added “Attention Is All You Need”');
      await page.getByRole('button', { name: 'Done' }).click();
      await page.getByTestId('back-to-library').click();
      await expect(page.getByTestId('library-table').getByText('Attention Is All You Need')).toBeVisible();

      // Keyboard: / focuses search, ↓ moves into the rows, ? lists the shortcuts.
      await expect(page.getByTestId('import-progress')).toHaveCount(0, { timeout: 15_000 }); // rows settle (an import becoming a paper replaces its row)
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.keyboard.press('/');
      await expect(page.getByTestId('search')).toBeFocused();
      await page.keyboard.press('ArrowDown');
      await expect(page.getByTestId('library-table').getByRole('link').first()).toBeFocused();
      await page.keyboard.press('ArrowDown');
      await expect(page.getByTestId('library-table').getByRole('link').nth(1)).toBeFocused();
      await page.keyboard.press('?');
      await expect(page.getByRole('heading', { name: 'Keyboard shortcuts' })).toBeVisible();
      await page.keyboard.press('Escape');
      await openSettings(page);
      await page.getByTestId('how-gradstep-works').click();
      await expect(page.getByTestId('how-gradstep-works-dialog')).toBeVisible();
      await expect(page.getByText('A credit is a Gradstep usage unit, not cash.')).toBeVisible();
      // The apps' About: this version, and the work it is built on (B10).
      await expect(page.getByTestId('about-version')).toContainText(/Version \d+\.\d+\.\d+ \(web /);
      await expect(page.getByTestId('acknowledgements').locator('li strong')).toHaveText(['Mermaid', 'htmlparser2, Temml', 'markdown-it', 'arXiv', 'DataCite']);
      await page.getByRole('dialog', { name: 'How Gradstep works' }).getByRole('button', { name: 'Close', exact: true }).click();
      expect(problems).toEqual([]);
    });
  }
}

test('narrow window: drawers for contents and chat, chips for filters', async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Narrow layout runs in the phone project.');
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  const problems = watch(page);
  await signIn(page);
  await expect(page.getByTestId('pane-left')).toHaveCount(0);
  await expect(page.getByRole('toolbar', { name: 'Filter library' })).toBeVisible();
  await expect(page.locator('html')).toHaveJSProperty('scrollWidth', 390);
  await shot(page, 'library-390-light');
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.getByTestId('contents')).toBeEnabled();
  await expect(page.getByTestId('pane-right')).toHaveCount(0);
  await shot(page, 'reader-390-light');
  await page.getByTestId('contents').click();
  const contents = page.getByRole('navigation', { name: 'Contents' });
  await expect(contents).toBeVisible();
  await shot(page, 'contents-390-light');
  await contents.getByRole('button').nth(3).click();
  await expect(contents).toBeHidden();
  await page.getByTestId('ask').click();
  await expect(page.getByTestId('pane-right')).toContainText('Ask about this paper');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('pane-right')).toHaveCount(0);
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.getByTestId('back-to-library').click();
  await shot(page, 'library-390-dark');
  expect(problems).toEqual([]);
});
