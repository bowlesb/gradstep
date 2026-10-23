import { type Page, expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin } from './environment';

const full = 'We compare reasoning policies against a fixed set of carefully checked baselines. '.repeat(24) + 'Every remaining limitation is included in this final sentence.';
const results = [
  { source_id: '2610.00101', revision: 1, title: 'Reasoning without shortcuts', authors: ['Ada Example'], year: 2026, abstract: 'Preview', full_abstract: full, abstract_truncated: false,
    categories: ['cs.LG'], topics: ['RL for reasoning', 'Policy optimization'], upvotes: null, reason: { kind: 'added', text: 'Because you added “Direct Preference Optimization”' } },
  { source_id: '2610.00102', revision: 1, title: 'Efficient policy search', authors: ['Grace Example'], year: 2026, abstract: 'Search improves the policy.', categories: ['cs.AI'], topics: ['RL for reasoning'], upvotes: 87,
    reason: { kind: 'trending', text: 'Popular on Hugging Face Papers' } },
  { source_id: '2305.18290', revision: 3, title: 'Direct Preference Optimization', authors: ['Rafael Rafailov'], year: 2023, abstract: 'A paper already in your library.', categories: ['cs.LG'], topics: ['Preference learning'], upvotes: 0 },
];
const personal = () => ({ results, feed: { for_you: true, ranking: 'feed-heuristic-v2', refreshed_at: new Date().toISOString(), cold_start: false,
  topics: [{ name: 'RL for reasoning', kind: 'combined', papers: 16 }, { name: 'Efficient long context', kind: 'combined', papers: 9 }] } });
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
}
const topicButton = (page: Page, name: string) => page.getByRole('button', { name, exact: true }).filter({ visible: true });
// The Feed's options are one "…" at the right of its title row (owner-approved 2026-10-22, audit S16).
async function feedMenu(page: Page, item?: string) {
  await page.getByTestId('feed-options').click();
  const menu = page.getByRole('menu', { name: 'Feed options' });
  await expect(menu).toBeVisible();
  if (item) await menu.getByTestId(item).click();
  return menu;
}
async function expectSort(page: Page, label: string) {
  const menu = await feedMenu(page);
  await expect(menu.getByTestId('feed-sort')).toContainText(label);
  await page.keyboard.press('Escape');
}
async function choose(page: Page, submenu: string, label: string) {
  const menu = await feedMenu(page, submenu);
  await menu.getByRole('menuitemradio', { name: label, exact: true }).click();
}
async function refreshEnabled(page: Page) {
  const menu = await feedMenu(page);
  await expect(menu.getByTestId('feed-refresh')).toBeEnabled();
  await page.keyboard.press('Escape');
}

test.beforeEach(async ({ request }, info) => {
  test.skip(info.project.name === 'webkit', 'Safari key persistence remains its own explicit gate.');
  await request.post(`${fixtureOrigin}/__reset`);
});

test('For you, precise topics, popularity and optional table columns follow the native Feed', async ({ page }, info) => {
  const errors: string[] = []; page.on('pageerror', e => errors.push(String(e)));
  const queries: URLSearchParams[] = [];
  await page.route('**/functions/v1/discover?**', async route => {
    queries.push(new URL(route.request().url()).searchParams);
    await route.fulfill({ json: personal() });
  });
  await signIn(page);
  await expect(topicButton(page, 'For you')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.feed-card').first()).toContainText('Reasoning without shortcuts');
  await expect(page.locator('.feed-card').first()).toContainText('Because you added');
  await expectSort(page, 'Suggested');
  const topic = page.getByRole('button', { name: /^RL for reasoning(?: 16)?$/ }).filter({ visible: true });
  await topic.click();
  await expect.poll(() => queries.some(q => q.get('feed') === 'topic' && q.get('topic') === 'RL for reasoning')).toBe(true);
  await choose(page, 'feed-view-as', 'Table');
  const table = page.getByTestId('feed-table'), rows = page.getByTestId('feed-row');
  await expect(table).toBeVisible();
  await choose(page, 'feed-sort', 'Popularity');
  await expect(rows.first()).toContainText('Efficient policy search');
  await expect(rows.last()).toContainText('Reasoning without shortcuts');
  await table.getByRole('button', { name: /^Popularity/ }).click();
  await expect(rows.first()).toContainText('Direct Preference Optimization');
  await expect(rows.last()).toContainText('Reasoning without shortcuts'); // unknown remains last when ascending
  await feedMenu(page, 'feed-columns');
  const choices = page.getByRole('dialog', { name: 'Feed columns' });
  await choices.getByRole('checkbox', { name: /^Abstract/ }).check();
  await choices.getByRole('checkbox', { name: /^arXiv ID/ }).check();
  await choices.getByRole('checkbox', { name: /^Authors/ }).uncheck();
  await choices.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(table.getByRole('columnheader', { name: 'Abstract', exact: true })).toBeVisible();
  const row = rows.filter({ hasText: 'Reasoning without shortcuts' });
  await row.getByRole('button', { name: 'Reasoning without shortcuts', exact: true }).click();
  const detail = page.locator('.feed-details').filter({ hasText: 'Reasoning without shortcuts' });
  await expect(detail).toContainText(full);
  expect(await detail.locator('.feed-abstract').evaluate(el => el.clientHeight >= el.scrollHeight - 1)).toBe(true);
  const region = page.getByRole('region', { name: 'Feed table', exact: true });
  const titleCell = table.locator('th.col-title');
  const left = (await titleCell.boundingBox())!.x;
  await region.focus(); await page.keyboard.press('ArrowRight');
  await expect.poll(() => region.evaluate(e => e.scrollLeft)).toBeGreaterThan(0);
  expect(Math.abs((await titleCell.boundingBox())!.x - left)).toBeLessThan(2);
  await region.evaluate(e => { e.scrollLeft = 0; });
  await page.screenshot({ path: `../../.artifacts/web-feed/columns-${info.project.name}-light.png` });
  // Settings › Reading › Appearance (audit S9).
  await page.getByTestId('account-menu').click(); await page.getByTestId('open-settings').click();
  await page.getByTestId('appearance-dark').click(); await page.getByTestId('settings-close').click();
  await page.screenshot({ path: `../../.artifacts/web-feed/columns-${info.project.name}-dark.png` });
  await page.reload();
  await expect(table).toBeVisible();
  await expect(table.getByRole('columnheader', { name: 'Abstract', exact: true })).toBeVisible();
  await expect(table.getByRole('columnheader', { name: 'Authors', exact: true })).toHaveCount(0);
  await (await feedMenu(page)).getByRole('menuitemcheckbox', { name: 'Hide papers in my library' }).click(); await page.keyboard.press('Escape');
  await expect(rows).toHaveCount(2);
  await expect(table.getByRole('button', { name: 'Direct Preference Optimization', exact: true })).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('leaving a cached feed during refresh keeps Refresh usable on return', async ({ page }) => {
  let requests = 0, release: (() => void) | undefined;
  const held = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/functions/v1/discover?**', async route => {
    if (++requests === 2) await held;
    await route.fulfill({ json: personal() }).catch(() => {}); // navigation can abort the held response
  });
  await signIn(page);
  await expect(page.locator('.feed-card').first()).toContainText('Reasoning without shortcuts');
  await feedMenu(page, 'feed-refresh');
  await expect.poll(() => requests).toBe(2);
  await expect(page.getByTestId('feed-status')).toContainText('Refreshing…');
  await feedMenu(page); await expect(page.getByTestId('feed-refresh')).toBeDisabled(); await page.keyboard.press('Escape');
  await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
  release!();
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await expect(page.locator('.feed-card').first()).toContainText('Reasoning without shortcuts');
  await refreshEnabled(page);
  await feedMenu(page, 'feed-refresh');
  await expect.poll(() => requests).toBe(3);
  await refreshEnabled(page);
});

test('feed feedback waits for server acceptance, supports Undo and never sends chat', async ({ page }) => {
  const hidden = new Set<string>();
  await page.route('**/functions/v1/discover?**', route => route.fulfill({ json: { ...personal(), results: results.filter(p => !hidden.has(p.source_id)) } }));
  let writes = 0, chatCalls = 0;
  const received: { p_source_id: string; p_kind: string | null }[] = [];
  page.on('request', r => { if (new URL(r.url()).pathname === '/functions/v1/chat' && r.method() === 'POST') chatCalls++; });
  await page.route('**/rest/v1/rpc/v1_feed_feedback', async route => {
    const body = route.request().postDataJSON(); writes++; received.push(body);
    if (writes === 1) await route.fulfill({ status: 503, json: { code: 'service_unavailable' } });
    else {
      if (body.p_kind === 'not_interested') hidden.add(body.p_source_id); else hidden.delete(body.p_source_id);
      await route.fulfill({ json: { source_id: body.p_source_id, kind: body.p_kind } });
    }
  });
  await signIn(page);
  const card = page.locator('.feed-card').filter({ hasText: 'Reasoning without shortcuts' });
  await card.getByLabel('Feed choices for Reasoning without shortcuts').click();
  await page.getByRole('menuitem', { name: 'Not interested', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Couldn’t save your feed choice');
  await expect(card).toBeVisible();
  await card.getByLabel('Feed choices for Reasoning without shortcuts').click();
  await page.getByRole('menuitem', { name: 'Not interested', exact: true }).click();
  await expect(card).toHaveCount(0);
  await feedMenu(page, 'feed-refresh');
  await refreshEnabled(page);
  await page.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(card).toBeVisible();
  await card.getByLabel('Feed choices for Reasoning without shortcuts').click();
  await page.getByRole('menuitem', { name: 'More like this', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('suggest more papers like this');
  const another = page.locator('.feed-card').filter({ hasText: 'Efficient policy search' });
  await another.getByLabel('Feed choices for Efficient policy search').click();
  await page.getByRole('menuitem', { name: 'More like this', exact: true }).click();
  await card.getByLabel('Feed choices for Reasoning without shortcuts').click();
  await page.getByRole('menuitem', { name: 'Undo more like this', exact: true }).click();
  await expect.poll(() => received.at(-1)?.p_kind).toBeNull();
  expect(received.at(-1)?.p_source_id).toBe('2610.00101');
  expect(writes).toBe(6); expect(chatCalls).toBe(0);
});

test('unavailable For you falls back once, and an old category response never triggers a retry loop', async ({ page }) => {
  let probes = 0;
  await page.route('**/functions/v1/discover?**', async route => {
    const params = new URL(route.request().url()).searchParams;
    if (params.has('feed')) { probes++; await route.fulfill({ status: 404, json: { code: 'feed_unavailable' } }); }
    else await route.fulfill({ json: { results } });
  });
  await signIn(page);
  await expect(page.getByTestId('feed-grid').locator('li')).toHaveCount(3);
  await expect(topicButton(page, 'For you')).toHaveCount(0);
  await expectSort(page, 'Newest');
  await feedMenu(page, 'feed-refresh');
  await refreshEnabled(page);
  await page.reload();
  await expect(page.getByTestId('feed-grid').locator('li')).toHaveCount(3);
  expect(probes).toBe(1);
});

test('an expired topic returns to For you; a late topic reply cannot replace a newer choice', async ({ page }) => {
  let delayed: (() => Promise<void>) | null = null;
  await page.route('**/functions/v1/discover?**', async route => {
    const params = new URL(route.request().url()).searchParams;
    if (params.get('topic') === 'RL for reasoning') {
      await route.fulfill({ status: 400, json: { code: 'invalid_feed_topic' } });
    } else if (params.get('topic') === 'Efficient long context') {
      await new Promise<void>(resolve => { delayed = async () => { await route.fulfill({ json: { ...personal(), results: [{ ...results[0], title: 'Late old topic reply' }] } }).catch(() => {}); resolve(); }; });
    } else await route.fulfill({ json: personal() });
  });
  await signIn(page);
  await page.getByRole('button', { name: /^RL for reasoning(?: 16)?$/ }).filter({ visible: true }).click();
  await expect(topicButton(page, 'For you')).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('button', { name: /^Efficient long context(?: 9)?$/ }).filter({ visible: true }).click();
  await expect.poll(() => delayed !== null).toBe(true);
  await topicButton(page, 'For you').click();
  await delayed!();
  await expect(page.locator('.feed-card').first()).toContainText('Reasoning without shortcuts');
  await expect(page.getByText('Late old topic reply', { exact: true })).toHaveCount(0);
});
