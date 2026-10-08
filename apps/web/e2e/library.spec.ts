import { expect, test } from '@playwright/test';
import { writeFile } from 'node:fs/promises';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

const FIXTURE = 'http://127.0.0.1:54329';

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
  await expect(rows).toHaveCount(3999); // 4,000 retained entries include one archived paper.
  const recoveryToLibraryMs = Date.now() - started;
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

  // A changed entry with the same ID must invalidate row facts and search membership while the
  // memoized table remains mounted. The same journal also updates the reader in its own journeys.
  expect((await request.post(`${FIXTURE}/__paper-tags`, { data: { tags: ['Live library marker'] } })).ok()).toBe(true);
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.getByTestId('search').fill('Live library marker');
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Direct Preference Optimization');
  await expect(rows.first().locator('.col-tags')).toHaveText('Live library marker');
  await page.getByTestId('search').fill('');

  const searchStarted = Date.now();
  await page.getByTestId('search').fill('Research paper 3997');
  await expect(rows).toHaveCount(1);
  const searchMs = Date.now() - searchStarted;
  await expect(rows.first()).toContainText('Research paper 3997');
  await expect(page.getByTestId('search')).toBeFocused();
  await page.getByTestId('search').fill('');
  await page.getByRole('combobox', { name: 'Filter by tag' }).selectOption('Self-supervised learning');
  await expect(rows).toHaveCount(1998);
  await page.getByRole('combobox', { name: 'Filter by tag' }).selectOption('');
  await page.getByRole('button', { name: /^Year/ }).click();
  await expect(rows.first().locator('.col-year')).toHaveText('2025');
  await page.getByTestId('search').fill('Research paper 3997');
  const link = rows.getByRole('link');
  await link.focus();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/\/paper\/cccccccc-0000-4000-8000-000000003997$/);
  await expect(page.getByTestId('contents')).toBeEnabled();
  expect(errors).toEqual([]);
  const report = { retainedEntries: 4000, visibleRows: 3999, recoveryToLibraryMs, searchMs,
    observationSeconds: after.Timestamp - before.Timestamp,
    scriptMilliseconds: (after.ScriptDuration - before.ScriptDuration) * 1000,
    taskMilliseconds: (after.TaskDuration - before.TaskDuration) * 1000,
    layoutMilliseconds: (after.LayoutDuration - before.LayoutDuration) * 1000,
    rendererNodes: after.Nodes };
  await info.attach(`library-${label}-${info.project.name}.json`, { body: JSON.stringify(report, null, 2), contentType: 'application/json' });
  await writeFile(`../../.artifacts/web-library/${label}-${info.project.name}-metrics.json`, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ libraryPerformance: label, project: info.project.name, ...report }));
});
