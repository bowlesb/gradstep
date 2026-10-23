// Browser reader journeys against the local fixture backend, under the production CSP.
import { openAddPaper } from './device-reader-helpers';
import { type Page, expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { durableKeys } from './key-capability';

import { fixtureOrigin as FIXTURE } from './environment';
const shots = '../../.artifacts/web-e2e/';

function watch(page: Page) {
  const problems: string[] = [];
  page.on('console', message => {
    // arXiv is unreachable on purpose (see beforeEach): its blocked requests are expected, not problems.
    if (message.type() === 'error' && !/Failed to load resource: the server responded with a status of (401|403|422)/.test(message.text())
      && !message.location().url.startsWith('https://arxiv.org/')) problems.push(message.text());
  });
  page.on('pageerror', error => problems.push(String(error)));
  return problems;
}
async function signIn(page: Page, email: string, navigate = true) {
  if (navigate) await page.goto('/');
  await page.getByTestId('email').fill(email);
  await page.getByTestId('send-code').click();
  await expect(page.getByText(`We sent a 6-digit code to ${email}.`)).toBeVisible();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
}
const shot = (page: Page, name: string) => page.screenshot({ path: `${shots}${test.info().project.name}-${name}.png`, fullPage: false });

async function holdReadingSave(page: Page) {
  await page.evaluate(() => {
    const hooks = window as unknown as { releaseActivity?: () => void; activityWaiting?: boolean; activityEncryptions: number };
    hooks.activityEncryptions = 0;
    const encrypt = crypto.subtle.encrypt.bind(crypto.subtle);
    crypto.subtle.encrypt = (async (algorithm: AesGcmParams, key: CryptoKey, data: BufferSource) => {
      const value = await encrypt(algorithm, key, data);
      if (algorithm.additionalData && new TextDecoder().decode(algorithm.additionalData).startsWith('gradstep/web-reading/v1/')) {
        hooks.activityEncryptions++;
        if (hooks.activityEncryptions === 1) {
          hooks.activityWaiting = true;
          return new Promise<ArrayBuffer>(resolve => { hooks.releaseActivity = () => resolve(value); });
        }
      }
      return value;
    }) as typeof crypto.subtle.encrypt;
  });
}

test.beforeEach(async ({ request, page }) => {
  await request.post(`${FIXTURE}/__reset`);
  // The fixture papers are legacy arXiv items: the reader tries their official HTML first (2026-10-14) and falls back to
  // the server bundle these journeys read when arXiv is unreachable, which they make it (no test reaches arXiv).
  await page.route('https://arxiv.org/**', route => route.abort());
});

test('returning reader: recovery code, library, retry, add paper, read, sign out and back', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  const problems = watch(page);
  let descriptors = 0;
  page.on('request', request => { if (request.url().includes('/functions/v1/reader-artifact?')) descriptors++; });
  await signIn(page, 'returning@example.test');
  await expect(page.getByRole('heading', { name: 'Restore your private library' })).toBeVisible();
  await expect(page.getByTestId('approval-qr')).toBeVisible(); // the default: approve from a phone
  await page.getByTestId('use-recovery-code').click();
  // Password AutoFill shape: a username for the account and a current-password field.
  await expect(page.locator('input[autocomplete="username"]')).toHaveValue('returning@example.test');
  await expect(page.getByTestId('recovery-code')).toHaveAttribute('autocomplete', 'current-password');
  await page.getByTestId('recovery-code').fill('0'.repeat(64));
  await page.getByTestId('recover').click();
  await expect(page.getByText('That recovery code doesn’t match this account.')).toBeVisible();
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE.toUpperCase());
  await page.getByTestId('recover').click();

  const table = page.getByTestId('library-table');
  await expect(table.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
  await expect(table.getByText('Couldn’t download this paper')).toBeVisible();
  await expect(table.getByText(/Mamba/)).toHaveCount(0); // archived: hidden by default
  await expect(page.getByRole('button', { name: 'Archived' })).toBeVisible();
  await expect(page.getByRole('button', { name: /Failed/ })).toBeVisible();
  await shot(page, 'library');

  await table.getByRole('button', { name: 'Retry' }).click();
  await expect(table.getByRole('link', { name: 'A retried paper' })).toBeVisible({ timeout: 15_000 });

  await openAddPaper(page);
  await page.getByTestId('arxiv-input').fill('not a paper');
  await page.getByTestId('arxiv-add').click();
  await expect(page.getByTestId('add-outcome')).toContainText('Couldn’t find a paper for this.'); // free text goes to add-paper
  await page.getByTestId('arxiv-input').fill('https://arxiv.org/abs/1706.03762');
  await page.getByTestId('arxiv-add').click();
  await expect(page.getByTestId('import-progress').first()).toBeVisible();
  await expect(table.getByText(/Adding…/).first()).toBeVisible({ timeout: 8_000 }); // two words and a percentage, the apps' "Adding…" (2026-10-15)
  await shot(page, 'import-progress');
  await expect(table.getByRole('link', { name: 'Attention Is All You Need' })).toBeVisible({ timeout: 15_000 });

  await table.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page).toHaveURL(/\/paper\/aaaaaaaa-0000-4000-8000-000000000001$/);
  const frame = page.frameLocator('[data-testid=reader-frame]');
  await expect(frame.locator('h1').first()).toContainText('Direct Preference Optimization');
  await expect(frame.locator('.sr-paper-line')).toContainText('2023 · NeurIPS 2023 · arXiv 2305.18290v3');
  await expect(frame.locator('figure img').first()).toBeVisible();
  await expect(page.getByTestId('contents')).toBeEnabled();
  await shot(page, 'reader');

  // Wide windows keep the contents in the side panel; narrow ones open it as a drawer that closes on a jump.
  // Below 1100 px a paper opens with Contents closed (UX audit R26); the button opens it beside the paper or as a drawer.
  const contents = page.getByRole('navigation', { name: 'Contents' });
  if (!await contents.isVisible()) await page.getByTestId('contents').click();
  const drawer = await page.locator('[data-testid=pane-left].overlay').count() > 0;
  const headings = await contents.getByRole('button').allTextContents();
  expect(headings.length).toBeGreaterThan(5);
  await contents.getByRole('button', { name: headings[3], exact: true }).click();
  if (drawer) await expect(contents).toBeHidden();
  else await expect(contents.getByRole('button', { name: headings[3], exact: true })).toHaveAttribute('aria-current', 'location');

  const citation = frame.locator('.sr-cite').first();
  await citation.scrollIntoViewIfNeeded();
  await citation.click();
  await expect(page.getByTestId('citation-back')).toBeVisible();
  await page.getByTestId('citation-back').click();
  await expect(page.getByTestId('citation-back')).toBeHidden();

  await frame.locator('figure img').first().click();
  await expect(page.locator('iframe.figure-frame')).toBeVisible();
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();

  // The paper chat stays beside the reader, with a drawer on narrow windows.
  const chat = page.getByTestId('pane-right');
  if (!await chat.isVisible()) await page.getByTestId('ask').click();
  await expect(chat).toContainText('Ask about this paper');
  if (drawer) { await page.keyboard.press('Escape'); await expect(chat).toHaveCount(0); }

  await frame.locator('body').evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight / 2));
  await page.waitForTimeout(2600);
  await frame.locator('body').evaluate(() => window.scrollBy(0, 40));
  await page.waitForTimeout(600);
  await page.getByTestId('back-to-library').click();
  const row = table.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
  await expect(row.locator('.reading-progress')).toBeVisible();

  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('confirm-sign-out').click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();

  // This browser stays approved: no recovery code the second time.
  await page.getByTestId('email').fill('returning@example.test');
  await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456');
  await page.getByTestId('verify').click();
  await expect(table.getByRole('link', { name: /Direct Preference Optimization/ })).toBeVisible();
  await expect(row.locator('.reading-progress')).toBeVisible(); // reading place kept on this device

  // A new login authorizes the paper again instead of reusing the previous session's verified cache.
  const previousDescriptors = descriptors;
  await table.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(frame.locator('h1').first()).toContainText('Direct Preference Optimization');
  expect(descriptors).toBe(previousDescriptors + 1);
  await page.getByTestId('back-to-library').click();

  // Removing this browser's keys brings the recovery step back.
  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('forget-device').check();
  await page.getByTestId('confirm-sign-out').click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  // No reload or artificial cleanup delay: the UI must retire its in-memory keys as well.
  await signIn(page, 'returning@example.test', false);
  await expect(page.getByRole('heading', { name: 'Restore your private library' })).toBeVisible();
  expect(problems).toEqual([]);
});

test('new account: new keys and recovery code, empty library, reload stays ready', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  const problems = watch(page);
  await page.emulateMedia({ colorScheme: 'dark' });
  await signIn(page, 'new@example.test');
  await expect(page.getByRole('heading', { name: 'Save your recovery code' })).toBeVisible();
  const code = await page.getByTestId('new-recovery-code').textContent();
  expect(code).toMatch(/^[0-9a-f]{8}(-[0-9a-f]{8}){7}$/);
  await expect(page.getByTestId('confirm-code')).toBeDisabled();
  await shot(page, 'new-keys-dark');
  await page.getByTestId('saved-code').check();
  await page.getByTestId('confirm-code').click();
  await expect(page.getByText('Your library is empty.')).toBeVisible();
  await shot(page, 'empty-library-dark');
  await page.reload();
  await expect(page.getByText('Your library is empty.')).toBeVisible();
  expect(problems).toEqual([]);
});

test('live tags preserve the open document, selection, reading place and citation return', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  const problems = watch(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await signIn(page, 'returning@example.test');
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await page.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  const frame = page.frameLocator('[data-testid=reader-frame]'), body = frame.locator('body');
  await expect(page.getByTestId('contents')).toBeEnabled();
  const position = () => body.evaluate(() => (window as unknown as {
    __scienceReaderLocation: () => { block: number; fraction: number; height: number; y: number };
  }).__scienceReaderLocation());
  const samePlace = async (expected: Awaited<ReturnType<typeof position>>) => {
    await expect.poll(async () => {
      const actual = await position();
      return actual.block === expected.block && Math.abs(actual.fraction - expected.fraction) * expected.height < 3;
    }).toBe(true);
  };
  const updateTags = async (tags: string[]) => {
    expect((await request.post(`${FIXTURE}/__paper-tags`, { data: { tags } })).ok()).toBe(true);
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await expect(frame.locator('.sr-tag')).toHaveText(tags);
  };

  // Observe the bridge's position report so a delayed report cannot make the assertion pass by accident.
  await page.evaluate(() => {
    const state = window as unknown as { readerPositionY?: number };
    window.addEventListener('message', event => {
      if (event.data?.gradstep === 'reader' && event.data.value?.type === 'position') state.readerPositionY = event.data.value.y;
    });
  });
  const selection = await body.evaluate(() => {
    document.body.dataset.readerInstance = 'original';
    const paragraph = [...document.querySelectorAll('p[data-reader-block]')].filter(p => p.textContent!.length > 100)[6];
    const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
    let text = walker.nextNode();
    while (text && text.textContent!.length < 40) text = walker.nextNode();
    if (!text) throw new Error('fixture paragraph has no selectable prose');
    const range = document.createRange(); range.setStart(text, 0); range.setEnd(text, 30);
    window.getSelection()!.removeAllRanges(); window.getSelection()!.addRange(range);
    const rect = paragraph.getBoundingClientRect();
    window.scrollTo(0, window.scrollY + rect.top + rect.height / 3);
    return range.toString();
  });
  await page.waitForFunction(() => ((window as unknown as { readerPositionY?: number }).readerPositionY ?? 0) > 100);
  const reading = await position();
  await updateTags(['Preference optimization', 'Reinforcement learning', 'Natural language processing', 'Alignment']);
  await expect(body).toHaveAttribute('data-reader-instance', 'original');
  expect(await body.evaluate(() => window.getSelection()?.toString())).toBe(selection);
  await samePlace(reading);

  const citation = frame.locator('.sr-cite').first();
  await citation.scrollIntoViewIfNeeded();
  const origin = await position();
  await citation.click();
  await expect(page.getByTestId('citation-back')).toBeVisible();
  await updateTags([]);
  await expect(body).toHaveAttribute('data-reader-instance', 'original');
  await expect(page.getByTestId('citation-back')).toBeVisible();
  await page.getByTestId('citation-back').click();
  await samePlace(origin);
  await expect(page.getByTestId('citation-back')).toBeHidden();
  expect(problems).toEqual([]);
});

test('tags arriving during paper download appear before restoring the saved reading place', async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await signIn(page, 'returning@example.test');
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await page.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  const frame = page.frameLocator('[data-testid=reader-frame]'), body = frame.locator('body');
  await expect(page.getByTestId('contents')).toBeEnabled();
  await page.evaluate(() => {
    const state = window as unknown as { readerPositionY?: number };
    window.addEventListener('message', event => {
      if (event.data?.gradstep === 'reader' && event.data.value?.type === 'position') state.readerPositionY = event.data.value.y;
    });
  });
  await body.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight / 2));
  await page.waitForFunction(() => ((window as unknown as { readerPositionY?: number }).readerPositionY ?? 0) > 100);
  const saved = await body.evaluate(() => (window as unknown as {
    __scienceReaderLocation: () => { block: number; fraction: number; height: number };
  }).__scienceReaderLocation());
  await page.getByTestId('back-to-library').click();
  const row = page.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
  await expect(row.locator('.reading-progress')).toBeVisible();
  await expect.poll(async () => Number(await row.locator('.reading-progress progress').getAttribute('value'))).toBeGreaterThan(0.4);
  // Signing out waits for the encrypted local save and retires the cache, so the next open downloads again.
  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('confirm-sign-out').click();
  await signIn(page, 'returning@example.test', false);
  await expect(row.locator('.reading-progress')).toBeVisible();
  await expect.poll(async () => Number(await row.locator('.reading-progress progress').getAttribute('value'))).toBeGreaterThan(0.4);

  const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  await page.route('**/functions/v1/reader-artifact?*', async route => {
    const response = await route.fetch(); reached.resolve(); await release.promise;
    await route.fulfill({ response });
  });
  try {
    await page.getByRole('link', { name: /Direct Preference Optimization/ }).click();
    await reached.promise;
    const tags = ['Preference optimization', 'Alignment'];
    expect((await request.post(`${FIXTURE}/__paper-tags`, { data: { tags } })).ok()).toBe(true);
    const refreshed = page.waitForResponse(response => response.url().endsWith('/rpc/v3_library_changes'));
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await refreshed;
    release.resolve();
    await expect(frame.locator('.sr-tag')).toHaveText(tags);
    await expect(page.getByTestId('contents')).toBeEnabled();
    const location = () => body.evaluate(() => (window as unknown as {
      __scienceReaderLocation: () => { block: number; fraction: number };
    }).__scienceReaderLocation());
    await expect.poll(async () => (await location()).block).toBe(saved.block);
    await expect.poll(async () => Math.abs((await location()).fraction - saved.fraction) * saved.height).toBeLessThan(3);
  } finally { release.resolve(); }
});

test('reopening a paper waits for its encrypted reading place before starting the reader', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  const problems = watch(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await signIn(page, 'returning@example.test');
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await page.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  const body = page.frameLocator('[data-testid=reader-frame]').locator('body');
  await expect(page.getByTestId('contents')).toBeEnabled();
  const paperPath = new URL(page.url()).pathname;
  const position = () => body.evaluate(() => (window as unknown as {
    __scienceReaderLocation: () => { block: number; fraction: number; height: number };
  }).__scienceReaderLocation());
  await page.evaluate(() => {
    const state = window as unknown as { readerPositionY?: number };
    window.addEventListener('message', event => {
      if (event.data?.gradstep === 'reader' && event.data.value?.type === 'position') state.readerPositionY = event.data.value.y;
    });
  });
  await body.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight / 2));
  await page.waitForFunction(() => ((window as unknown as { readerPositionY?: number }).readerPositionY ?? 0) > 100);
  const saved = await position();
  await page.getByTestId('back-to-library').click();
  const row = page.getByTestId('paper-row').filter({ hasText: 'Direct Preference Optimization' });
  await expect.poll(async () => Number(await row.locator('.reading-progress progress').getAttribute('value'))).toBeGreaterThan(0.4);
  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('confirm-sign-out').click(); // drains the encrypted save
  await signIn(page, 'returning@example.test', false);
  await expect.poll(async () => Number(await row.locator('.reading-progress progress').getAttribute('value'))).toBeGreaterThan(0.4);

  // On the next document, hold real activity decryption independently of the fast library/bundle responses.
  // Hold every load until released, including React Strict Mode's cancelled first effect.
  await page.addInitScript(() => {
    const hooks = window as unknown as { readingLoadWaiting?: boolean; releaseReadingLoad: () => void };
    const gate = new Promise<void>(resolve => { hooks.releaseReadingLoad = resolve; });
    const decrypt = crypto.subtle.decrypt.bind(crypto.subtle);
    crypto.subtle.decrypt = (async (algorithm: AesGcmParams, key: CryptoKey, data: BufferSource) => {
      const value = await decrypt(algorithm, key, data);
      if (algorithm.additionalData && new TextDecoder().decode(algorithm.additionalData).startsWith('gradstep/web-reading/v1/')) {
        hooks.readingLoadWaiting = true;
        await gate;
      }
      return value;
    }) as typeof crypto.subtle.decrypt;
  });
  await page.goto(paperPath);
  await page.waitForFunction(() => (window as unknown as { readingLoadWaiting?: boolean }).readingLoadWaiting);
  try {
    await expect(page.getByRole('status', { name: 'Opening paper' })).toBeVisible();
    await expect(page.getByTestId('reader-frame')).toHaveCount(0);
  } finally { await page.evaluate(() => (window as unknown as { releaseReadingLoad: () => void }).releaseReadingLoad()); }
  await expect(page.getByTestId('contents')).toBeEnabled();
  await expect.poll(async () => (await position()).block).toBe(saved.block);
  await expect.poll(async () => Math.abs((await position()).fraction - saved.fraction) * saved.height).toBeLessThan(3);
  expect(problems).toEqual([]);
});

test('choosing another email cancels a verification that already reached the server', async ({ page }) => {
  const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  await page.route('**/auth/v1/verify', async route => {
    if (route.request().postDataJSON().email !== 'returning@example.test') return route.continue();
    const response = await route.fetch(); reached.resolve(); await release.promise;
    await route.fulfill({ response }).catch(() => {}); // aborting the browser request may already have closed it
  });
  try {
    await signIn(page, 'returning@example.test');
    await reached.promise;
    await page.getByRole('button', { name: 'Use another email' }).click();
    await page.getByTestId('email').fill('new@example.test');
    await page.getByTestId('send-code').click();
    release.resolve();
    await expect(page.getByText('We sent a 6-digit code to new@example.test.')).toBeVisible();
    await expect(page.getByTestId('code')).toBeVisible();
    await page.getByTestId('code').fill('123456');
    await page.getByTestId('verify').click();
    await expect(page.getByRole('heading', { name: /Save your recovery code|Couldn’t prepare this browser/ })).toBeVisible();
  } finally { release.resolve(); }
});

test('a late encrypted reading-place save cannot recreate a forgotten device or its data', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await signIn(page, 'returning@example.test');
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
  await holdReadingSave(page);
  await page.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toContainText('Direct Preference Optimization');
  await page.waitForFunction(() => (window as unknown as { activityWaiting?: boolean }).activityWaiting);
  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('forget-device').check();
  await page.getByTestId('confirm-sign-out').click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.evaluate(() => (window as unknown as { releaseActivity: () => void }).releaseActivity());
  // Acquiring the same activity lane waits for the released save to settle before inspecting real IndexedDB.
  const retained = await page.evaluate(() => navigator.locks.request('gradstep.activity.fixture:11111111-2222-4333-8444-555555555555', () => new Promise<{ devices: number; activity: number; journal: number; retired: boolean }>((resolve, reject) => {
    const opening = indexedDB.open('gradstep');
    opening.onerror = () => reject(new Error('IndexedDB unavailable'));
    opening.onsuccess = () => {
      const db = opening.result, tx = db.transaction(['devices', 'activity', 'journal']);
      const devices = tx.objectStore('devices').getAll(), activity = tx.objectStore('activity').count(), journal = tx.objectStore('journal').count();
      tx.oncomplete = () => { db.close(); resolve({ devices: devices.result.filter(d => d.deviceID || d.privateKey || d.localKey).length,
        activity: activity.result, journal: journal.result,
        retired: devices.result.length === 1 && devices.result[0].lifetime === null && devices.result[0].writers.length === 0 }); };
    };
  })));
  expect(retained).toEqual({ devices: 0, activity: 0, journal: 0, retired: true });
});

test('a delayed sign-out cannot end a newer login from another tab', async ({ page, context, request }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279); refusal is verified separately.');
  await signIn(page, 'returning@example.test');
  await page.getByTestId('use-recovery-code').click(); // approval from a phone is the default
  await page.getByTestId('recovery-code').fill(RECOVERY_CODE);
  await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
  await holdReadingSave(page);
  await page.getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await page.waitForFunction(() => (window as unknown as { activityWaiting?: boolean }).activityWaiting);
  await page.getByTestId('account-menu').click();
  await page.getByTestId('sign-out').click();
  await page.getByTestId('confirm-sign-out').click();
  await expect(page.getByTestId('confirm-sign-out')).toBeDisabled();
  const other = await context.newPage();
  await other.goto('/');
  const response = await request.post(`${FIXTURE}/auth/v1/verify`, { headers: { apikey: 'fixture-anon' }, data: { type: 'email', email: 'new@example.test', token: '123456' } });
  const next = await response.json();
  await other.evaluate(session => localStorage.setItem('gradstep.fixture.session', JSON.stringify({
    accessToken: session.access_token, refreshToken: session.refresh_token, expiresAt: session.expires_at,
    lifetime: crypto.randomUUID(), user: session.user,
  })), next);
  await expect(page.getByRole('heading', { name: 'Save your recovery code' })).toBeVisible();
  await page.evaluate(() => (window as unknown as { releaseActivity: () => void }).releaseActivity());
  await page.waitForFunction(() => (window as unknown as { activityEncryptions: number }).activityEncryptions >= 2);
  await page.evaluate(() => navigator.locks.request('gradstep.activity.fixture:11111111-2222-4333-8444-555555555555', () => {}));
  await page.evaluate(() => new Promise(requestAnimationFrame));
  await expect(page.getByRole('heading', { name: 'Save your recovery code' })).toBeVisible();
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('gradstep.fixture.session')!).user.email)).toBe('new@example.test');
});

test('key enrollment requires a usable persisted key, with clear guidance on unsupported engines', async ({ page }) => {
  const supported = await durableKeys(page);
  let enrollments = 0;
  page.on('request', request => { if (/\/v1_(bootstrap_keys|request_enrollment|approve_enrollment)$/.test(request.url())) enrollments++; });
  await signIn(page, 'new@example.test');
  if (supported) await expect(page.getByRole('heading', { name: 'Save your recovery code' })).toBeVisible();
  else {
    await expect(page.getByText('This browser can’t save the keys needed for your private library.', { exact: false })).toBeVisible();
    await expect(page.getByTestId('confirm-code')).toHaveCount(0);
  }
  expect(enrollments).toBe(0);
});

test('an address without an account is told sign-up is invite-only', async ({ page }) => {
  await page.goto('/');
  await shot(page, 'sign-in');
  await page.getByTestId('email').fill('stranger@example.test');
  await page.getByTestId('send-code').click();
  await expect(page.getByText('This sign-in address isn’t invited to the beta. Use the address on your invitation; Apple’s Hide My Email address may be different.')).toBeVisible();
});

test('security headers and a refused foreign script', async ({ page, request }) => {
  const response = await request.get('/');
  const csp = response.headers()['content-security-policy'];
  expect(csp).toContain("default-src 'none'");
  // The device fetches the official arXiv HTML itself (HTML-first reader) and searches DataCite itself (ARXIV_DEVICE_ONLY.md
  // §5.6), and nothing else beyond the backend.
  expect(csp).toContain(`connect-src https://arxiv.org https://api.datacite.org ${FIXTURE}`);
  expect(csp).toContain("frame-ancestors 'none'");
  expect(response.headers()['x-content-type-options']).toBe('nosniff');
  await page.goto('/');
  // An injected inline script is refused by the policy.
  const ran = await page.evaluate(async () => {
    const s = document.createElement('script'); s.textContent = 'window.__injected = true'; document.head.append(s);
    await new Promise(r => setTimeout(r, 50));
    return (window as unknown as { __injected?: boolean }).__injected === true;
  });
  expect(ran).toBe(false);
});
