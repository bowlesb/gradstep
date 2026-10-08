// Real WebCrypto + production CSP. Local fixtures only, no hosted or paid requests.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
const API = 'http://127.0.0.1:54329';
async function login(page: Page) {
  await page.goto('http://127.0.0.1:4317/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
}
async function send(page: Page, text: string, consent = false) {
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill(text);
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  if (consent) await page.getByRole('button', { name: 'Allow and get answer' }).click();
}
const evidence = async (request: any) => (await request.get(`${API}/__chat-evidence`)).json();
test.beforeEach(async ({ request }) => { await request.post(`${API}/__reset`); });

test('paper/general, consent, math, safe sources, encrypted reload and cross-browser sync', async ({ page, browser, request }, info) => {
  test.skip(info.project.name === 'webkit', 'Existing key-persistence gate remains in force.');
  const errors: string[] = [], remote: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('request', r => { if (!r.url().startsWith('http://127.0.0.1:') && !r.url().startsWith('data:')) remote.push(r.url()); });
  await login(page); await send(page, 'Explain the private β objective');
  await expect(page.getByRole('dialog', { name: 'Cloud AI answers' })).toBeVisible(); expect((await evidence(request)).requests).toHaveLength(0);
  await page.getByRole('button', { name: 'Not now', exact: true }).click();
  await page.getByRole('button', { name: 'Get answer', exact: true }).click(); await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('chat-assistant').locator('math')).toBeVisible();
  await expect(page.getByTestId('chat-assistant').locator('table')).toBeVisible();
  await expect(page.getByTestId('chat-pane')).toContainText('3 credits used');
  await expect(page.getByTestId('chat-pane')).toContainText('1000 credits');
  expect(await page.evaluate(() => (window as any).injected)).toBeUndefined();
  await page.getByRole('link', { name: 'Original paper' }).click(); await expect(page.getByRole('dialog', { name: 'Open source' })).toContainText('https://arxiv.org/abs/2305.18290');
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  const e = await evidence(request); expect(e.requests[0].eventsBeforeRequest).toBe(2); expect(e.requests[0].mode).toBe('paper'); expect(JSON.stringify(e.events)).not.toContain('private');
  const persisted = await page.evaluate(async () => {
    const db = await new Promise<IDBDatabase>(resolve => { const r = indexedDB.open('gradstep'); r.onsuccess = () => resolve(r.result); });
    const values = await Promise.all([...db.objectStoreNames].map(n => new Promise(resolve => { const r = db.transaction(n).objectStore(n).getAll(); r.onsuccess = () => resolve(r.result); })));
    return JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage }, values });
  });
  expect(persisted).not.toContain('private β'); expect(persisted).not.toContain('objective');
  await page.getByRole('button', { name: 'General', exact: true }).click(); await send(page, 'Explain a general idea');
  await expect(page.getByTestId('chat-assistant')).toBeVisible(); expect((await evidence(request)).requests[1].mode).toBe('general');
  await page.getByRole('button', { name: 'Paper', exact: true }).click(); await expect(page.getByTestId('chat-user')).toContainText('private β');
  await page.reload(); await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await page.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click(); await page.getByRole('button', { name: 'Explain the private β objective', exact: true }).click();
  await expect(page.getByTestId('chat-assistant').locator('math')).toBeVisible();
  const other = await browser.newContext({ viewport: { width: 1440, height: 900 } }), second = await other.newPage();
  await login(second); await second.getByTestId('chat-pane').getByRole('button', { name: 'All chats' }).click(); await second.getByRole('button', { name: 'Explain the private β objective', exact: true }).click();
  await expect(second.getByTestId('chat-assistant').locator('math')).toBeVisible(); await other.close();
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-paper.png` }); expect(errors).toEqual([]); expect(remote).toEqual([]);
});

test('Stop, navigation while streaming and insufficient credits', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode: 'slow' } });
  await login(page); await send(page, 'A slow answer', true); await expect(page.getByTestId('chat-streaming')).toContainText('objective');
  await page.getByRole('button', { name: 'General', exact: true }).click(); await expect(page.getByTestId('chat-streaming')).toHaveCount(0);
  await page.getByRole('button', { name: 'Paper', exact: true }).click(); await page.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(page.getByTestId('chat-assistant')).toContainText('Answer interrupted'); expect((await evidence(request)).requests).toHaveLength(1);
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'insufficient_credits' } }); await page.getByRole('button', { name: 'New chat', exact: true }).click(); await send(page, 'Need credits');
  await expect(page.getByRole('alert')).toContainText('Not enough credits'); await expect(page.getByTestId('chat-user')).toContainText('Need credits');
  await page.screenshot({ path: '../../.artifacts/web-chat/credit-error.png' });
});

test('selection tools and passage return keep the verified paper context', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await login(page);
  const frame = page.frameLocator('[data-testid=reader-frame]');
  await frame.locator('p').filter({ hasText: 'preferences' }).first().evaluate(node => { const r = document.createRange(); r.selectNodeContents(node); const s = window.getSelection()!; s.removeAllRanges(); s.addRange(r); document.dispatchEvent(new Event('selectionchange')); });
  await expect(page.getByRole('toolbar', { name: 'Selected passage' })).toBeVisible(); await page.getByRole('button', { name: 'Why it matters', exact: true }).click();
  await page.getByRole('button', { name: 'Allow and get answer' }).click(); await expect(page.getByTestId('chat-assistant')).toBeVisible();
  const e = await evidence(request); expect(e.requests[0].action).toBe('relevance'); expect(e.requests[0].selection.quote.length).toBeGreaterThan(10);
  await page.getByRole('button', { name: 'Go to passage', exact: true }).click(); await expect(page.getByTestId('citation-back')).toBeVisible();
});

for (const mode of ['diagram', 'unsafe_diagram', 'broken_diagram']) test(`opaque ${mode} under production CSP`, async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode } }); await login(page); await send(page, 'Draw a preference diagram', true);
  await page.getByRole('button', { name: /View diagram/ }).click();
  const frame = page.frameLocator('iframe[title=Diagram]');
  if (mode === 'diagram') {
    await expect(frame.locator('#diagram svg')).toBeVisible();
    expect(await frame.locator('body').evaluate(() => { try { localStorage.getItem('x'); return true; } catch { return false; } })).toBe(false);
    await page.screenshot({ path: '../../.artifacts/web-chat/diagram.png' });
  } else await expect(page.getByRole('alert')).toContainText('Couldn’t draw this diagram');
  await page.getByRole('button', { name: 'Done', exact: true }).click(); await expect(page.getByTestId('chat-assistant')).toBeVisible();
});

test('dark streaming updates at a steady cadence, retry never duplicates a failed question', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await page.emulateMedia({ colorScheme: 'dark' });
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'slow', failAppend: true } });
  await login(page); await send(page, 'A recoverable private question');
  await expect(page.getByRole('alert')).toContainText('question couldn’t be saved'); expect((await evidence(request)).requests).toHaveLength(0);
  await page.getByRole('button', { name: 'Get answer', exact: true }).click(); await page.getByRole('button', { name: 'Allow and get answer' }).click();
  await expect(page.getByTestId('chat-streaming')).toContainText('objective');
  const first = await page.getByTestId('chat-streaming').textContent();
  await expect(page.getByTestId('chat-streaming')).not.toHaveText(first!);
  await page.getByRole('button', { name: 'Stop', exact: true }).click(); await expect(page.getByTestId('chat-assistant')).toContainText('Answer interrupted');
  const e = await evidence(request); expect(e.events).toHaveLength(3); expect(e.requests).toHaveLength(1);
  await page.screenshot({ path: '../../.artifacts/web-chat/dark-partial.png' });
  // An explicitly confirmed sign-out retires the stream and the page, without saving draft plaintext.
  await page.getByTestId('account-menu').click(); await page.getByRole('menuitem', { name: 'Sign out' }).click();
  await page.getByTestId('confirm-sign-out').click(); await expect(page.getByTestId('email')).toBeVisible();
});


test('continuous short chunks render before the stream ends', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode: 'steady' } });
  await login(page); await send(page, 'Stream continuously', true);
  await expect(page.getByTestId('chat-streaming')).toContainText('The');
  const first = await page.getByTestId('chat-streaming').textContent();
  await expect(page.getByTestId('chat-streaming')).not.toHaveText(first!);
  // With a resetting debounce, none of these short deltas would render before done.
  await expect(page.getByRole('button', { name: 'Stop', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(page.getByTestId('chat-assistant')).toContainText('Answer interrupted');
});

test('opaque diagram blocks embedded media, source navigation and remote CSS', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode: 'external_diagram' } });
  const network: string[] = [], popups: string[] = [];
  await page.route('https://attacker.invalid/**', route => { network.push(route.request().url()); return route.abort(); });
  page.on('popup', popup => popups.push(popup.url()));
  await login(page); await send(page, 'A diagram with untrusted links', true);
  await page.getByRole('button', { name: /View diagram/ }).click();
  const frame = page.frameLocator('iframe[title=Diagram]'); await expect(frame.locator('#diagram svg')).toBeVisible();
  await expect(frame.locator('#diagram image, #diagram foreignObject, #diagram script, #diagram [href], #diagram [*|href]')).toHaveCount(0);
  await frame.locator('#diagram svg').click();
  // Exercise the frame's network policy directly, even if a future Mermaid release emits remote CSS.
  await frame.locator('body').evaluate(node => {
    (window as any).blockedDiagramResource = false;
    document.addEventListener('securitypolicyviolation', e => { if (e.blockedURI.startsWith('https://attacker.invalid/')) (window as any).blockedDiagramResource = true; });
    const style = document.createElement('style'); style.textContent = '#diagram { background-image:url(https://attacker.invalid/style.svg) }'; node.appendChild(style);
  });
  await expect.poll(() => frame.locator('body').evaluate(() => (window as any).blockedDiagramResource)).toBe(true);
  expect(popups).toEqual([]); expect(network).toEqual([]);
  await page.getByRole('button', { name: 'Done', exact: true }).click();
});
