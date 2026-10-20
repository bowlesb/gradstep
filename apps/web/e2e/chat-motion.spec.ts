import { expect, test } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';

for (const surface of ['paper', 'figure'] as const) test(`${surface} chat: touch and wheel own the transcript while answers arrive; completed text stays still`, async ({ page, request, browserName }, info) => {
  test.skip(browserName !== 'chromium', 'Real touch injection uses Chromium CDP; other engines retain their separate capability gates.');
  await request.post(`${API}/__reset`);
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'scrolling' } });
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  let host = page.getByTestId('chat-pane');
  if (surface === 'figure') {
    if (await page.locator('.pane-right.overlay').count()) await page.keyboard.press('Escape');
    await page.getByTestId('figures').click();
    await page.getByRole('list', { name: 'Figures' }).getByRole('button').first().click();
    const dialog = page.getByRole('dialog', { name: 'Figures', exact: true });
    const figureImage = dialog.frameLocator('iframe.figure-frame').locator('img').first();
    await expect(figureImage).toBeVisible();
    await expect.poll(() => figureImage.evaluate((image: HTMLImageElement) => image.naturalWidth)).toBeGreaterThan(0);
    await expect(figureImage).toBeInViewport();
    host = dialog.getByTestId('contextual-chat');
  }
  await host.getByRole('textbox', { name: 'Message', exact: true }).fill('Explain this carefully');
  await host.getByRole('button', { name: 'Send', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click();
  const viewport = host.getByRole('region', { name: 'Conversation', exact: true });
  await expect.poll(() => viewport.evaluate(e => e.scrollHeight - e.clientHeight)).toBeGreaterThan(300);
  await viewport.scrollIntoViewIfNeeded();
  const cdp = await page.context().newCDPSession(page);
  const box = (await viewport.boundingBox())!;
  await viewport.evaluate(el => {
    el.setAttribute('data-touch-cancels', '0');
    el.addEventListener('pointercancel', () => el.setAttribute('data-touch-cancels', String(Number(el.getAttribute('data-touch-cancels')) + 1)));
  });
  // Real touch scrolling transfers control to the browser, cancelling the pointer while touch remains held.
  // The end-of-transcript boundary does not give automatic following ownership of that still-held finger.
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: box.x + box.width / 2, y: box.y + box.height / 2 }] });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: box.x + box.width / 2, y: box.y + box.height / 2 - 40 }] });
  await expect(viewport).toHaveAttribute('data-touch-cancels', '1');
  const held = await viewport.evaluate(async el => {
    const startHeight = el.scrollHeight, start = el.scrollTop, samples: number[] = [];
    for (let i = 0; i < 28; i++) { await new Promise(requestAnimationFrame); samples.push(el.scrollTop); }
    return { start, samples, growth: el.scrollHeight - startHeight };
  });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  expect(held.growth).toBeGreaterThan(20);
  expect(Math.max(...held.samples.map(top => Math.abs(top - held.start)))).toBeLessThanOrEqual(1);
  await expect(host.getByRole('button', { name: 'Latest message' })).toBeVisible();

  // Wheel/trackpad scrollback must not be overwritten by the next token or a delayed programmatic scroll event.
  await viewport.hover(); await page.mouse.wheel(0, -20_000);
  await expect.poll(() => viewport.evaluate(e => e.scrollTop)).toBeLessThan(2);
  const before = await host.getByTestId('chat-streaming').textContent();
  await expect(host.getByTestId('chat-streaming')).not.toHaveText(before!);
  expect(await viewport.evaluate(e => e.scrollTop)).toBeLessThan(2);
  await host.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(host.getByTestId('chat-assistant')).toBeVisible();
  const still = await viewport.evaluate(async el => {
    const samples: number[] = [];
    for (let i = 0; i < 24; i++) { await new Promise(requestAnimationFrame); samples.push(el.scrollTop); }
    return samples;
  });
  expect(Math.max(...still) - Math.min(...still)).toBeLessThanOrEqual(1);
  await host.getByRole('button', { name: 'Latest message' }).click();
  await expect.poll(() => viewport.evaluate(e => e.scrollHeight - e.scrollTop - e.clientHeight)).toBeLessThanOrEqual(2);
  await page.screenshot({ path: `../../.artifacts/parity-20261020/${info.project.name}-${surface}-chat-motion.png` });
  await cdp.detach();
});
