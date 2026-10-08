import { expect, test } from '@playwright/test';
import { writeFile } from 'node:fs/promises';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

import { fixtureOrigin as FIXTURE } from './environment';

test('a full library stays searchable while an import progresses', async ({ page, request, context, browserName }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  expect((await request.post(`${FIXTURE}/__large-library`, { data: { count: 4000 } })).ok()).toBe(true);
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(String(error)));
  const client = browserName === 'chromium' ? await context.newCDPSession(page) : null;
  await client?.send('Performance.enable');
  const metrics = async () => Object.fromEntries((await client?.send('Performance.getMetrics'))?.metrics.map(m => [m.name, m.value]) ?? []);
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  const started = Date.now();
  await page.getByTestId('recover').click();
  const rows = page.getByTestId('paper-row');
  await expect(page.getByTestId('library-table')).toHaveAttribute('aria-rowcount', '4000'); // includes the heading, excludes one archived paper
  await expect(rows).toHaveCount(3999); // full rendering remains the default
  const recoveryToLibraryMs = Date.now() - started;
  // Exercise the heaviest chosen-column view on both sizes; compact defaults are deliberately smaller.
  await page.getByRole('button', { name: 'Columns', exact: true }).click();
  const columns = page.getByRole('dialog', { name: 'Library columns' });
  await columns.getByRole('checkbox', { name: 'Show rows as you scroll', exact: true }).check();
  for (const name of ['Authors', 'Year', 'Tags', 'Added', 'Opened', 'Progress']) await columns.getByRole('checkbox', { name, exact: true }).check();
  await columns.getByRole('button', { name: 'Done' }).click();
  const progress = page.getByTestId('import-progress').locator('progress');
  const initialProgress = Number(await progress.getAttribute('value'));
  await page.getByTestId('search').focus();
  const before = await metrics();
  await page.waitForTimeout(3200); // fixed observation window for real import clocks and unchanged catch-up pages
  const after = await metrics();
  expect(Number(await progress.getAttribute('value'))).toBeGreaterThan(initialProgress);
  await expect(page.getByTestId('search')).toBeFocused();
  const label = (process.env.WEB_LIBRARY_LABEL ?? 'current').replace(/[^a-z0-9-]/gi, '');
  await page.screenshot({ path: `../../.artifacts/web-library/${label}-${info.project.name}-large-library.png` });
  const scroller = page.getByRole('region', { name: 'Library table' });
  await scroller.evaluate(element => { element.scrollTop = 1000; });
  await expect.poll(() => scroller.evaluate(element => element.scrollTop)).toBeGreaterThan(900);
  expect((await page.getByRole('columnheader', { name: 'Title' }).boundingBox())!.y).toBeCloseTo((await scroller.boundingBox())!.y, 0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(page.viewportSize()!.width);

  // A changed entry with the same ID must invalidate row facts and search membership while the
  // memoized table remains mounted. The same journal also updates the reader in its own journeys.
  expect((await request.post(`${FIXTURE}/__paper-tags`, { data: { tags: ['Live library marker'] } })).ok()).toBe(true);
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.getByTestId('search').fill('Live library marker');
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Direct Preference Optimization');
  await expect(rows.first().locator('.col-tags')).toHaveText('Live library marker');
  await page.getByTestId('search').fill('');

  const renderedRows = await rows.count();
  const searchStarted = Date.now();
  await page.getByTestId('search').fill('Research paper 3997');
  await expect(rows).toHaveCount(1);
  const searchMs = Date.now() - searchStarted;
  await expect(rows.first()).toContainText('Research paper 3997');
  await expect(page.getByTestId('search')).toBeFocused();
  await page.getByTestId('search').fill('');
  // Wide windows filter from the side panel's tag list; narrow ones from the chips' tag menu.
  const rail = page.getByRole('navigation', { name: 'Library filters' });
  const tag = async (name: string) => (await rail.isVisible())
    ? rail.getByRole('button', { name: new RegExp(name || 'Self-supervised learning') }).click()
    : page.getByRole('combobox', { name: 'Filter by tag' }).selectOption(name);
  await tag('Self-supervised learning');
  await expect(page.getByTestId('library-table')).toHaveAttribute('aria-rowcount', '1999');
  await expect.poll(() => rows.count()).toBeLessThan(80);
  await tag(''); // a second press clears the rail's tag
  await page.getByRole('button', { name: /^Year/ }).click();
  await expect(rows.first().locator('.col-year')).toHaveText('2025');
  await page.getByTestId('search').fill('Research paper 3997');
  const link = rows.getByRole('link');
  await link.focus();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/\/paper\/cccccccc-0000-4000-8000-000000003997$/);
  await expect(page.getByTestId('contents')).toBeEnabled();
  expect(errors).toEqual([]);
  const report = { retainedEntries: 4000, matchingRows: 3999, renderedRows, recoveryToLibraryMs, searchMs,
    observationSeconds: after.Timestamp - before.Timestamp,
    scriptMilliseconds: (after.ScriptDuration - before.ScriptDuration) * 1000,
    taskMilliseconds: (after.TaskDuration - before.TaskDuration) * 1000,
    layoutMilliseconds: (after.LayoutDuration - before.LayoutDuration) * 1000,
    rendererNodes: after.Nodes };
  await info.attach(`library-${label}-${info.project.name}.json`, { body: JSON.stringify(report, null, 2), contentType: 'application/json' });
  await writeFile(`../../.artifacts/web-library/${label}-${info.project.name}-metrics.json`, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ libraryPerformance: label, project: info.project.name, ...report }));
});
