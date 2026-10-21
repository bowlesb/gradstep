import { openAddPaper } from './device-reader-helpers';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

import { fixtureOrigin as FIXTURE } from './environment';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  // The library is ready (Add paper now lives in the far-right menu, build 75; opening it here would add a request).
  await expect(page.getByTestId('library-table')).toBeVisible();
}

for (const failRefresh of [false, true]) test(`removing an import needs a complete post-receipt observation${failRefresh ? ' when catch-up fails' : ''}`, async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  await request.post(`${FIXTURE}/__removable-import`);
  await signIn(page);
  const stopped = page.getByTestId('paper-row').filter({ hasText: 'arXiv 2401.00001' });
  await expect(stopped.getByRole('button', { name: 'Remove' })).toBeVisible();

  const oldReached = Promise.withResolvers<void>(), oldRelease = Promise.withResolvers<void>();
  const freshRelease = Promise.withResolvers<void>();
  let changes = 0, freshReached = false, commands = 0;
  page.on('request', req => { if (req.url().endsWith('/rpc/v2_cancel_import')) commands++; });
  await page.route('**/rpc/v3_library_changes', async route => {
    const number = ++changes;
    if (number === 1) {
      const response = await route.fetch(); // fixed boundary before either later server change
      oldReached.resolve(); await oldRelease.promise;
      await route.fulfill({ response }).catch(() => {});
    } else if (number === 2) {
      freshReached = true; await freshRelease.promise;
      if (failRefresh) await route.fulfill({ status: 503, json: { code: 'fixture_read_unavailable' } });
      else await route.continue();
    } else await route.continue();
  });
  try {
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await oldReached.promise;
    await request.post(`${FIXTURE}/__another-paper`); // unrelated change must not be skipped by the receipt
    const receipt = page.waitForResponse(r => r.url().endsWith('/rpc/v2_cancel_import'));
    await stopped.getByRole('button', { name: 'Remove' }).click();
    await (await receipt).finished();
    await expect(stopped.getByText('Updating…')).toBeVisible();
    oldRelease.resolve();
    await expect.poll(() => freshReached).toBe(true);
    await expect(stopped.getByText('Updating…')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Added on another device' })).toHaveCount(0);
    freshRelease.resolve();
    if (failRefresh) {
      await expect(page.getByRole('alert')).toContainText('Refresh the page');
      await expect(stopped).toBeVisible(); // no partial receipt was published, no silent success
      await expect(stopped.getByText('Updating…')).toBeVisible();
      await expect(stopped.getByRole('button', { name: 'Remove' })).toHaveCount(0);
      await expect(page.getByRole('link', { name: 'Added on another device' })).toHaveCount(0);
      await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    }
    await expect(stopped).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Added on another device' })).toBeVisible();
    await expect(page.getByRole('alert')).toHaveCount(0);
    expect(commands).toBe(1); // retrying the read does not submit a new mutation
  } finally { oldRelease.resolve(); freshRelease.resolve(); }
});

test('Add captures the published cursor while a background change page is incomplete', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  await signIn(page);
  await request.post(`${FIXTURE}/__paper-tags`, { data: { tags: ['Unpublished change'] } });
  await request.post(`${FIXTURE}/__another-paper`);
  const held = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  let publishedCursor = -1, partialCursor = -1, pages = 0;
  await page.route('**/rpc/v3_library_changes', async route => {
    if (++pages === 1) {
      publishedCursor = route.request().postDataJSON().p_after;
      const response = await route.fetch(), body = await response.json();
      expect(body.changes.length).toBe(2);
      partialCursor = body.changes[0].seq;
      await route.fulfill({ response, json: { ...body, changes: body.changes.slice(0, 1), next_cursor: partialCursor, has_more: true } });
    } else if (pages === 2) {
      // Getting this continuation proves the reconciler advanced its working cursor.
      expect(route.request().postDataJSON().p_after).toBe(partialCursor);
      held.resolve(); await release.promise;
      await route.continue();
    } else await route.continue();
  });
  try {
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await held.promise;
    await expect(page.getByText('Unpublished change', { exact: true })).toHaveCount(0);
    await openAddPaper(page);
    await page.getByTestId('arxiv-input').fill('1706.03762');
    const sent = page.waitForRequest(r => r.url().endsWith('/rpc/v2_begin_import'));
    const accepted = page.waitForResponse(r => r.url().endsWith('/rpc/v2_begin_import'));
    await page.getByTestId('arxiv-add').click();
    expect((await sent).postDataJSON().p_observed_cursor).toBe(publishedCursor);
    expect(partialCursor).toBeGreaterThan(publishedCursor);
    await (await accepted).finished();
    await expect(page.getByTestId('arxiv-add')).toHaveText('Adding…');
    await expect(page.getByTestId('arxiv-input')).not.toBeEditable();
    release.resolve();
    await expect(page.getByRole('dialog')).not.toBeVisible();
    await expect(page.getByRole('link', { name: 'Added on another device' })).toBeVisible();
    await expect(page.getByTestId('paper-row').filter({ hasText: '1706.03762' })).toBeVisible();
  } finally { release.resolve(); }
});

test('concurrent commands each wait for a boundary begun after their own receipt', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  await request.post(`${FIXTURE}/__removable-import`);
  await signIn(page);
  const first = Promise.withResolvers<void>(), firstRelease = Promise.withResolvers<void>();
  const second = Promise.withResolvers<void>(), secondRelease = Promise.withResolvers<void>();
  let reads = 0, commands = 0;
  page.on('request', r => { if (/\/rpc\/v2_(begin|cancel)_import$/.test(r.url())) commands++; });
  await page.route('**/rpc/v3_library_changes', async route => {
    const number = ++reads;
    if (number <= 2) {
      const response = await route.fetch();
      (number === 1 ? first : second).resolve();
      await (number === 1 ? firstRelease : secondRelease).promise;
      await route.fulfill({ response }).catch(() => {});
    } else await route.continue();
  });
  try {
    const stopped = page.getByTestId('paper-row').filter({ hasText: 'arXiv 2401.00001' });
    await stopped.getByRole('button', { name: 'Remove' }).click();
    await first.promise; // Remove's fresh read was started before Add existed.
    await openAddPaper(page);
    await page.getByTestId('arxiv-input').fill('1706.03762');
    const accepted = page.waitForResponse(r => r.url().endsWith('/rpc/v2_begin_import'));
    await page.getByTestId('arxiv-add').click();
    await (await accepted).finished();
    firstRelease.resolve();
    await second.promise;
    await expect(stopped).toHaveCount(0);
    await expect(page.getByTestId('arxiv-add')).toHaveText('Adding…');
    await expect(page.getByTestId('paper-row').filter({ hasText: '1706.03762' })).toHaveCount(0);
    secondRelease.resolve();
    await expect(page.getByRole('dialog')).not.toBeVisible();
    await expect(page.getByTestId('paper-row').filter({ hasText: '1706.03762' })).toBeVisible();
    expect(commands).toBe(2);
  } finally { firstRelease.resolve(); secondRelease.resolve(); }
});

test('an accepted Add finishes its waiting form after a failed refresh recovers', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  await signIn(page);
  let reads = 0, submissions = 0;
  page.on('request', r => { if (r.url().endsWith('/rpc/v2_begin_import')) submissions++; });
  await page.route('**/rpc/v3_library_changes', route => ++reads === 1
    ? route.fulfill({ status: 503, json: { code: 'fixture_read_unavailable' } }) : route.continue());
  await openAddPaper(page);
  await page.getByTestId('arxiv-input').fill('1706.03762');
  await page.getByTestId('arxiv-add').click();
  await expect(page.getByRole('alert')).toContainText('Refresh the page');
  await expect(page.getByTestId('arxiv-add')).toBeDisabled();
  await expect(page.getByTestId('arxiv-input')).not.toBeEditable();
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(page.getByRole('dialog')).not.toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
  await expect(page.getByTestId('paper-row').filter({ hasText: '1706.03762' })).toBeVisible();
  await openAddPaper(page);
  await expect(page.getByTestId('arxiv-input')).toHaveValue('');
  await expect(page.getByRole('alert')).toHaveCount(0);
  expect(submissions).toBe(1);
});

for (const failRefresh of [false, true]) test(`a stale Remove reports a revision conflict${failRefresh ? ' after recovering a failed refresh' : ''}`, async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  await request.post(`${FIXTURE}/__removable-import`);
  await signIn(page);
  await request.post(`${FIXTURE}/__cancel-stopped-import`); // another device changes its intent revision
  let reads = 0, submissions = 0;
  page.on('request', r => { if (r.url().endsWith('/rpc/v2_cancel_import')) submissions++; });
  await page.route('**/rpc/v3_library_changes', route => failRefresh && ++reads === 1
    ? route.fulfill({ status: 503, json: { code: 'fixture_read_unavailable' } }) : route.continue());
  const stopped = page.getByTestId('paper-row').filter({ hasText: 'arXiv 2401.00001' });
  await stopped.getByRole('button', { name: 'Remove' }).click();
  if (failRefresh) {
    await expect(page.getByRole('alert')).toContainText('Refresh the page');
    await expect(stopped.getByText('Updating…')).toBeVisible();
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  }
  await expect(stopped).toHaveCount(0);
  await expect(page.getByRole('alert')).toHaveText('This paper changed since you last saw it. Check its status and try again.');
  expect(submissions).toBe(1);
});

// Build 75: two "TreeCut" rows from adding the same paper twice. Any version of an arXiv paper already in the library is
// that paper: Add says so and opens it, and no second import starts (the server's idempotency is separate).
test('adding an arXiv paper that is already in the library opens it instead of importing it again', async ({ page, request }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await request.post(`${FIXTURE}/__reset`);
  await signIn(page);
  let submissions = 0; page.on('request', r => { if (r.url().endsWith('/rpc/v2_begin_import')) submissions++; });
  const rows = await page.getByTestId('paper-row').count();
  await openAddPaper(page);
  await page.getByTestId('arxiv-input').fill('https://arxiv.org/abs/2305.18290v1');
  await page.getByTestId('arxiv-add').click();
  await expect(page.getByTestId('add-outcome')).toHaveText(/“Direct Preference Optimization: Your Language Model is Secretly a Reward Model” is already in your library\./);
  await page.screenshot({ path: `../../.artifacts/feedback-20261021/browser/b9-already-${info.project.name}-light.png` });
  await page.getByTestId('add-open-existing').click();
  await expect(page).toHaveURL(/\/paper\//);
  expect(submissions).toBe(0);
  await page.getByTestId('back-to-library').click();
  await expect(page.getByTestId('paper-row')).toHaveCount(rows);
});
