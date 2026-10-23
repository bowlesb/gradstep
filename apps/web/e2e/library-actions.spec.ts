import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';
import { fixtureOrigin as FIXTURE } from './environment';

const ITEM = 'aaaaaaaa-0000-4000-8000-000000000001';
const paper = (page: Page) => page.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
const editor = (page: Page) => page.getByRole('dialog', { name: 'Edit tags', exact: true });
async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
async function tags(page: Page) {
  await paper(page).getByRole('button', { name: /^Actions for/ }).click();
  await page.getByRole('menuitem', { name: 'Edit tags…' }).click();
  await expect(editor(page)).toBeVisible();
}
async function addTag(page: Page, text: string) {
  await editor(page).getByRole('textbox', { name: 'Add a tag' }).fill(text);
  await editor(page).getByRole('button', { name: 'Add', exact: true }).click();
}

test.beforeEach(async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Safari durable-key acceptance is separate.');
  await request.post(`${FIXTURE}/__reset`);
});

test('paper menus support keyboard and pointer; dirty Escape keeps the tag draft and Cancel discards it', async ({ page, request }) => {
  await signIn(page);
  const trigger = paper(page).getByRole('button', { name: /^Actions for/ });
  await trigger.focus(); await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('menu')).toHaveAttribute('data-library-row-owner', `item:${ITEM}`);
  // Find similar papers first, as in the apps' row actions (LibraryRowActions).
  await expect(page.getByRole('menuitem', { name: 'Find similar papers' })).toBeFocused();
  await page.keyboard.press('End'); await expect(page.getByRole('menuitem', { name: 'Remove from library…' })).toBeFocused();
  await page.keyboard.press('ArrowUp'); await expect(page.getByRole('menuitem', { name: 'Archive…', exact: true })).toBeFocused();
  while (!await page.getByRole('menuitem', { name: 'Edit tags…' }).evaluate(e => e === document.activeElement)) await page.keyboard.press('ArrowUp');
  await page.keyboard.press('Enter');
  await expect(editor(page)).toHaveAttribute('data-library-row-owner', `item:${ITEM}`);
  await page.keyboard.press('Escape'); await expect(editor(page)).toHaveCount(0); await expect(trigger).toBeFocused();
  await trigger.click(); await expect(page.getByRole('menu', { name: 'Paper actions' })).toBeVisible();
  await trigger.click(); await expect(page.getByRole('menu', { name: 'Paper actions' })).toHaveCount(0);
  await trigger.focus(); await page.keyboard.press('ArrowUp');
  await expect(page.getByRole('menuitem', { name: 'Remove from library…' })).toBeFocused();
  await page.keyboard.press('Tab'); await expect(paper(page).getByRole('link')).toBeFocused();
  await expect(page.getByRole('menu', { name: 'Paper actions' })).toHaveCount(0);
  await tags(page);
  await editor(page).getByRole('button', { name: 'Remove tag Alignment', exact: true }).click();
  await page.keyboard.press('Escape'); await expect(editor(page)).toBeVisible();
  await expect(editor(page).getByRole('status')).toHaveText('Use Cancel to discard your tag changes.');
  await editor(page).getByRole('textbox', { name: 'Add a tag' }).fill('😀'.repeat(31));
  await expect(editor(page).getByRole('button', { name: 'Add', exact: true })).toBeDisabled();
  await expect(editor(page).getByText('Use 1–40 characters', { exact: false })).toBeVisible();
  await addTag(page, '界'.repeat(40));
  await expect(editor(page).getByRole('button', { name: 'Remove tag ' + '界'.repeat(40), exact: true })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath('tag-editor.png') });
  await editor(page).getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(trigger).toBeFocused();
  await trigger.click(); await page.getByRole('heading', { name: 'Library', exact: true }).click();
  await expect(page.getByRole('menu', { name: 'Paper actions' })).toHaveCount(0);
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.receipts).toHaveLength(0);
  await tags(page); await expect(editor(page).getByRole('button', { name: 'Remove tag Alignment', exact: true })).toBeVisible();
  await expect(editor(page).getByRole('button', { name: 'Save', exact: true })).toBeDisabled();
});

test('saving every catalog tag hidden stays empty; suggestions and custom tags use the native normalization', async ({ page, request }) => {
  await signIn(page); await tags(page);
  // "Large language models" is too generic to show (main 9446667, GENERIC_KEYWORDS): Alignment is the catalog tag left.
  await expect(editor(page).getByRole('button', { name: 'Remove tag Large language models', exact: true })).toHaveCount(0);
  await editor(page).getByRole('button', { name: 'Remove tag Alignment', exact: true }).click();
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(editor(page)).toHaveCount(0); await expect(page.getByRole('status')).toContainText('Tags saved.');
  await expect(paper(page).locator('.tag')).toHaveCount(0);
  let evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  // Every catalog tag not kept is recorded hidden, the generic one the editor didn't show included.
  expect(evidence.entries.find((entry: any) => entry.id === ITEM)).toMatchObject({ membership_revision: 2, hidden_tags: ['Large language models', 'Alignment'] });
  await tags(page);
  await expect(editor(page).getByRole('button', { name: 'Add Alignment', exact: true })).toBeVisible();
  await addTag(page, 'machine learning');
  await expect(editor(page).getByText('Choose a specific method, dataset or topic instead of AI or machine learning.')).toBeVisible();
  await editor(page).getByRole('textbox', { name: 'Add a tag' }).fill('');
  await addTag(page, 'natural language processing'); await addTag(page, '  My   reading  ');
  await expect(editor(page).getByRole('button', { name: 'Remove tag Natural language processing', exact: true })).toBeVisible();
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click(); await expect(editor(page)).toHaveCount(0);
  evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.entries.find((entry: any) => entry.id === ITEM)).toMatchObject({ membership_revision: 3, user_tags: ['Natural language processing', 'My reading'], hidden_tags: ['Large language models', 'Alignment'] });
  await page.screenshot({ path: test.info().outputPath('tags-saved.png') });
});

test('a server-committed lost response replays the same operation once', async ({ page, request }) => {
  await signIn(page); await tags(page); await addTag(page, 'Review');
  const bodies: any[] = [], replies: any[] = [];
  await page.route('**/rpc/v2_set_item_tags', async route => {
    bodies.push(route.request().postDataJSON());
    const reply = await route.fetch(); replies.push(await reply.json());
    if (bodies.length === 1) await route.abort('failed');
    else await route.fulfill({ response: reply });
  });
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(editor(page)).toHaveCount(0); await expect(page.getByRole('status')).toContainText('Tags saved.');
  expect(bodies).toHaveLength(2); expect(bodies[0]).toEqual(bodies[1]); expect(bodies[0]).not.toHaveProperty('expectedItemID');
  expect(replies.map(reply => reply.replayed)).toEqual([false, true]);
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.receipts).toHaveLength(1); expect(evidence.entries.find((entry: any) => entry.id === ITEM).membership_revision).toBe(2);
});

for (const failedRefresh of [false, true]) test(`a revision race retains the draft until explicit reload${failedRefresh ? ' after a failed receipt refresh' : ''}`, async ({ page, request }) => {
  await signIn(page); await tags(page); await addTag(page, 'My draft');
  await request.post(`${FIXTURE}/__paper-action`, { data: { action: 'tags', tags: ['Other device'] } });
  let reads = 0; const commands: any[] = [];
  page.on('request', r => { if (r.url().endsWith('/rpc/v2_set_item_tags')) commands.push(r.postDataJSON()); });
  await page.route('**/rpc/v3_library_changes', route => failedRefresh && ++reads === 1
    ? route.fulfill({ status: 503, json: { code: 'fixture_read_unavailable' } }) : route.continue());
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  if (failedRefresh) {
    await expect(editor(page).getByRole('alert')).toContainText('Gradstep received your request');
    await expect(editor(page).getByRole('button', { name: 'Checking…' })).toBeDisabled();
    await editor(page).getByRole('button', { name: 'Refresh library' }).click();
  }
  await expect(editor(page).getByRole('alert')).toContainText('Your draft is still here.');
  await expect(editor(page).getByRole('button', { name: 'Remove tag My draft', exact: true })).toBeVisible();
  await expect(editor(page).getByRole('button', { name: 'Save', exact: true })).toBeDisabled();
  expect(commands).toHaveLength(1); expect(commands[0].p_expected_revision).toBe(1);
  await page.screenshot({ path: test.info().outputPath('revision-conflict.png') });
  await editor(page).getByRole('button', { name: 'Reload current tags' }).click();
  await expect(editor(page).getByRole('button', { name: 'Remove tag My draft', exact: true })).toHaveCount(0);
  await expect(editor(page).getByRole('button', { name: 'Remove tag Other device', exact: true })).toBeVisible();
  await addTag(page, 'My draft'); await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(editor(page)).toHaveCount(0); expect(commands).toHaveLength(2); expect(commands[1].p_expected_revision).toBe(2);
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.entries.find((entry: any) => entry.id === ITEM)).toMatchObject({ membership_revision: 3, user_tags: ['Other device', 'My draft'] });
});

test('an accepted save with a failed pull stays locked and only refreshes until the receipt is observed', async ({ page }) => {
  await signIn(page); await tags(page); await addTag(page, 'Review');
  let reads = 0, commands = 0;
  page.on('request', r => { if (r.url().endsWith('/rpc/v2_set_item_tags')) commands++; });
  await page.route('**/rpc/v3_library_changes', route => ++reads === 1
    ? route.fulfill({ status: 503, json: { code: 'fixture_read_unavailable' } }) : route.continue());
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(editor(page).getByRole('alert')).toContainText('Gradstep received your request');
  await expect(editor(page).getByRole('button', { name: 'Checking…' })).toBeDisabled();
  await expect(editor(page).getByRole('textbox')).not.toBeEditable();
  await expect(editor(page).getByRole('button', { name: 'Cancel' })).toBeDisabled();
  await expect(page.getByText('Tags saved.', { exact: true })).toHaveCount(0);
  await expect(paper(page).getByRole('button', { name: 'Review', exact: true })).toHaveCount(0);
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(editor(page)).toHaveCount(0); await expect(page.getByRole('status')).toContainText('Tags saved.');
  expect(commands).toBe(1);
});

test('archive and unarchive require confirmation and update the existing library filters', async ({ page, request }) => {
  await signIn(page);
  await paper(page).getByRole('button', { name: /^Actions for/ }).click(); await page.getByRole('menuitem', { name: 'Archive…', exact: true }).click();
  await page.getByRole('dialog', { name: 'Archive paper' }).getByRole('button', { name: 'Cancel' }).click();
  expect((await (await request.get(`${FIXTURE}/__library-action-evidence`)).json()).receipts).toHaveLength(0);
  await paper(page).getByRole('button', { name: /^Actions for/ }).click(); await page.getByRole('menuitem', { name: 'Archive…', exact: true }).click();
  await page.getByRole('dialog', { name: 'Archive paper' }).getByRole('button', { name: 'Archive', exact: true }).click();
  await expect(paper(page)).toHaveCount(0); await expect(page.getByRole('status')).toContainText('Paper archived.');
  await page.getByRole('button', { name: /^Archived/ }).click(); await expect(paper(page)).toBeVisible();
  await paper(page).getByRole('button', { name: /^Actions for/ }).click(); await page.getByRole('menuitem', { name: 'Unarchive…', exact: true }).click();
  await page.getByRole('dialog', { name: 'Unarchive paper' }).getByRole('button', { name: 'Unarchive', exact: true }).click();
  await expect(paper(page)).toHaveCount(0); await expect(page.getByRole('status')).toContainText('Paper unarchived.');
  await page.getByRole('button', { name: 'Clear filters', exact: true }).click(); await expect(paper(page)).toBeVisible();
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json();
  expect(evidence.receipts).toHaveLength(2); expect(evidence.entries.find((entry: any) => entry.id === ITEM).membership_revision).toBe(3);
});

test('removal clears personal tags and reveals a live mapped import without reviving a completed import', async ({ page, request }) => {
  await request.post(`${FIXTURE}/__paper-action`, { data: { action: 'tags', tags: ['Mine'], hidden: ['Alignment'] } });
  await request.post(`${FIXTURE}/__mapped-imports`); await signIn(page);
  await expect(page.getByTestId('paper-row').filter({ hasText: 'arXiv 1706.03762' })).toHaveCount(0);
  const remove = async () => {
    await paper(page).getByRole('button', { name: /^Actions for/ }).click(); await page.getByRole('menuitem', { name: 'Remove from library…' }).click();
  };
  await remove(); await page.getByRole('dialog', { name: 'Remove paper' }).getByRole('button', { name: 'Cancel' }).click();
  await expect(paper(page)).toBeVisible();
  await remove(); await page.getByRole('dialog', { name: 'Remove paper' }).getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(paper(page)).toHaveCount(0); await expect(page.getByRole('status')).toContainText('Paper removed from your library.');
  await expect(page.getByTestId('paper-row').filter({ hasText: 'arXiv 1706.03762' })).toHaveCount(1);
  const evidence = await (await request.get(`${FIXTURE}/__library-action-evidence`)).json(), removed = evidence.entries.find((entry: any) => entry.id === ITEM);
  expect(removed).toMatchObject({ visible: false, membership_revision: 3 });
  expect(removed).not.toHaveProperty('user_tags'); expect(removed).not.toHaveProperty('hidden_tags');
  expect(evidence.entries.find((entry: any) => entry.id.endsWith('0011'))).toMatchObject({ phase: 'ready', visible: false });
});

test('the compact library shares the same tag editor without navigating the paper', async ({ page }) => {
  await signIn(page); await paper(page).getByRole('link').click();
  await expect(page.getByTestId('contents')).toBeEnabled();
  // The side panel's Library tab (the top-bar search no longer takes it over, reader audit R2); a drawer on a phone.
  const sideTabs = page.getByRole('tablist', { name: 'Side panel' });
  if (!await sideTabs.isVisible()) await page.getByTestId('contents').click();
  await sideTabs.getByRole('tab', { name: 'Library', exact: true }).click();
  await expect(sideTabs.getByRole('tab', { name: 'Library', exact: true })).toHaveAttribute('aria-selected', 'true');
  const before = page.url();
  await page.locator('.compact-library').getByRole('button', { name: /^Actions for/ }).click();
  await page.getByRole('menuitem', { name: 'Edit tags…' }).click(); await addTag(page, 'Beside paper');
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(editor(page)).toHaveCount(0); await expect(page.locator('.compact-library').getByRole('status')).toContainText('Tags saved.');
  expect(page.url()).toBe(before);
});

test('the reader toolbar exposes the same paper actions and tag editor', async ({ page }) => {
  await signIn(page); await paper(page).getByRole('link').click();
  await expect(page.getByTestId('contents')).toBeEnabled();
  const trigger = page.getByRole('button', { name: /^Actions for Direct Preference Optimization/ });
  await expect(trigger).toBeVisible();
  await trigger.click();
  await expect(page.getByRole('menu', { name: 'Paper actions' })).toBeVisible();
  await page.getByRole('menuitem', { name: 'Edit tags…' }).click();
  await expect(editor(page)).toBeVisible();
  await addTag(page, 'From reader');
  await editor(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(editor(page)).toHaveCount(0);
  await expect(page.getByRole('status')).toContainText('Tags saved.');
  await expect(trigger).toHaveAttribute('aria-expanded', 'false');
});

test('a real tag dialog keeps its row alive while optional windowing scrolls away', async ({ page, request }) => {
  await request.post(`${FIXTURE}/__large-library`, { data: { count: 400 } }); await signIn(page);
  await expect(page.getByTestId('paper-row')).toHaveCount(399);
  await page.getByTestId('library-options').click(); await page.getByTestId('library-columns').click();
  await page.getByRole('checkbox', { name: 'Show rows as you scroll', exact: true }).check();
  await page.getByRole('dialog', { name: 'Library columns' }).getByRole('button', { name: 'Close', exact: true }).click();
  await expect.poll(() => page.getByTestId('paper-row').count()).toBeLessThan(80);
  const trigger = page.getByTestId('paper-row').getByRole('button', { name: /^Actions for/ }).first();
  const key = await trigger.evaluate(button => button.closest('tr')!.dataset.rowKey);
  await trigger.click(); await page.getByRole('menuitem', { name: 'Edit tags…' }).click();
  await editor(page).getByRole('textbox').fill('Retained draft');
  await page.getByRole('region', { name: 'Library table' }).evaluate(region => { region.dispatchEvent(new WheelEvent('wheel')); region.scrollTop = region.scrollHeight; });
  await expect(editor(page)).toBeVisible(); await expect(editor(page).getByRole('textbox')).toBeFocused();
  await expect(page.locator(`[data-row-key="${key}"]`)).toHaveCount(1);
  await expect.poll(() => page.getByTestId('paper-row').count()).toBeLessThan(80);
  await editor(page).getByRole('button', { name: 'Cancel', exact: true }).click(); await expect(trigger).toBeFocused();
  const owner = page.locator(`[data-row-key="${key}"]`);
  await owner.getByRole('button', { name: /^Actions for/ }).click();
  await page.keyboard.press('Tab'); // the event originates in a portal, outside the scroller
  await expect(page.getByTestId('paper-row')).toHaveCount(399);
  await expect(owner.getByRole('link')).toBeFocused(); // exact next native control, no skipped rows
});

test('external auth retirement closes an editor and ignores a delayed accepted response', async ({ page }) => {
  await signIn(page); await tags(page); await addTag(page, 'Old session');
  const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  await page.route('**/rpc/v2_set_item_tags', async route => {
    const response = await route.fetch(); reached.resolve(); await release.promise;
    await route.fulfill({ response }).catch(() => {});
  });
  try {
    await editor(page).getByRole('button', { name: 'Save', exact: true }).click(); await reached.promise;
    await page.evaluate(() => {
      const key = 'gradstep.fixture.session', oldValue = localStorage.getItem(key);
      localStorage.removeItem(key); window.dispatchEvent(new StorageEvent('storage', { key, oldValue, newValue: null }));
    });
    await expect(page.getByTestId('email')).toBeVisible(); release.resolve();
    await expect(editor(page)).toHaveCount(0); await expect(page.getByText('Tags saved.', { exact: true })).toHaveCount(0);
  } finally { release.resolve(); }
});
