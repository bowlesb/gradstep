import { expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin } from './environment';

test('expanded feed preserves the complete title and abstract through its final sentence', async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit', 'The existing key persistence gate is tested separately.');
  await request.post(`${fixtureOrigin}/__reset`);
  const full = 'We evaluate an explicitly bounded scientific reading workflow. '.repeat(30) + 'The final limitation remains visible.';
  const title = 'A detailed study of reliable paper discovery, complete scientific abstracts, and mathematical Unicode on every screen size';
  await page.route('**/functions/v1/discover?**', async route => {
    expect(new URL(route.request().url()).searchParams.get('abstract')).toBe('full');
    const response = await route.fetch();
    if (!response.ok()) { await route.fulfill({ response }); return; }
    const value = await response.json();
    value.results[0] = { ...value.results[0], title, abstract: full.slice(0, 700), full_abstract: full, abstract_truncated: false };
    await route.fulfill({ response, json: value });
  });
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  const card = page.locator('.feed-card').filter({ has: page.getByRole('link', { name: title, exact: true }) }), abstract = card.locator('.feed-abstract');
  await expect(abstract).toHaveText(full);
  const before = (await abstract.boundingBox())!.height;
  await card.getByRole('button', { name: 'Full abstract', exact: true }).click();
  await expect(card.getByRole('button', { name: 'Less', exact: true })).toHaveAttribute('aria-expanded', 'true');
  expect((await abstract.boundingBox())!.height).toBeGreaterThan(before * 2);
  expect(await abstract.evaluate(e => e.clientHeight)).toBeGreaterThanOrEqual(await abstract.evaluate(e => e.scrollHeight) - 1);
  const heading = card.locator('.feed-title');
  expect(await heading.evaluate(e => e.clientHeight)).toBeGreaterThanOrEqual(await heading.evaluate(e => e.scrollHeight) - 1);
  await page.screenshot({ path: `../../.artifacts/takeover-20261008/web-full-abstract-${info.project.name}.png` });
  await card.getByRole('button', { name: 'Less', exact: true }).click();
  await expect(card.getByRole('button', { name: 'Full abstract', exact: true })).toHaveAttribute('aria-expanded', 'false');
});
