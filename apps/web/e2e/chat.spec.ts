// Real WebCrypto + production CSP. Local fixtures only, no hosted or paid requests.
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
async function login(page: Page) {
  await page.goto('/');
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
  // The fixture paper is a legacy arXiv item: the reader tries its official HTML first (2026-10-14) and falls back to
  // the server bundle when arXiv is unreachable, which this journey makes it (no third-party request ever completes).
  await page.route('https://arxiv.org/**', route => route.abort());
  page.on('request', r => { if (!r.url().startsWith('http://127.0.0.1:') && !r.url().startsWith('data:') && !r.url().startsWith('https://arxiv.org/')) remote.push(r.url()); });
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
  // Papers in this answer (B2): the arXiv paper it links, already in the library, so Library rather than Add.
  const papers = page.getByTestId('answer-papers');
  await expect(papers).toContainText('Papers in this answer');
  await expect(papers.getByTestId('answer-paper')).toHaveCount(1);
  await expect(papers.getByRole('link', { name: 'arXiv 2305.18290' })).toBeVisible();
  await expect(papers.getByRole('button', { name: 'Open in Library' })).toBeVisible(); await expect(papers.getByTestId('answer-paper-add')).toHaveCount(0);
  await papers.getByRole('link', { name: 'arXiv 2305.18290' }).click();
  await expect(page.getByRole('dialog', { name: 'Open source' })).toContainText('https://arxiv.org/abs/2305.18290'); await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.getByTestId('chat-assistant').first().scrollIntoViewIfNeeded();
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-answer-papers.png` });
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

test('assistant answers and Mermaid diagrams can be copied by an explicit user action', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop');
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'diagram' } });
  await page.addInitScript(() => Object.defineProperty(Navigator.prototype, 'clipboard', { configurable: true,
    get: () => ({ writeText: async (text: string) => { (window as any).__copied = text; } }) }));
  await login(page); await send(page, 'Draw a preference diagram', true);
  await expect(page.getByTestId('chat-assistant')).toBeVisible();
  await page.getByTestId('copy-copy-answer').click();
  await expect(page.getByTestId('copy-copy-answer')).toHaveText('Copied');
  expect(await page.evaluate(() => (window as any).__copied)).toContain('preference');
  await page.getByRole('button', { name: 'Full size' }).click(); // the diagram is drawn in the answer; full size opens it (build 46)
  await page.getByText('Diagram source', { exact: true }).click();
  await page.getByRole('button', { name: 'Copy Mermaid', exact: true }).click();
  await expect(page.getByTestId('copy-copy-mermaid')).toHaveText('Copied');
  expect(await page.evaluate(() => (window as any).__copied)).toContain('graph');
});

test('Stop, navigation while streaming and insufficient credits', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode: 'slow' } });
  await login(page); await send(page, 'A slow answer', true); await expect(page.getByTestId('chat-streaming')).toContainText('objective');
  await page.getByRole('button', { name: 'General', exact: true }).click(); await expect(page.getByTestId('chat-streaming')).toHaveCount(0);
  await page.getByRole('button', { name: 'Paper', exact: true }).click(); await page.getByRole('button', { name: 'Stop', exact: true }).click();
  // The reader's Stop is recorded for the request's operation before the stream closes, and the kept part says what it
  // cost (2026-10-16, CHAT.md "When an answer stops early"); every request says it records a Stop.
  await expect(page.getByTestId('chat-interrupted')).toHaveText('Stopped · charged for the part written');
  const stopped = await evidence(request); expect(stopped.requests).toHaveLength(1);
  expect(stopped.requests[0].capabilities).toContain('stop_signal'); expect(stopped.stops).toEqual([stopped.requests[0].operation_id]);
  // The provider cuts the next answer short: the part written stays, and costs nothing.
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'midstream' } }); await page.getByRole('button', { name: 'New chat', exact: true }).click();
  await send(page, 'An answer the provider cuts short');
  await expect(page.getByTestId('chat-interrupted')).toHaveText('Interrupted · not charged');
  await expect(page.getByRole('alert')).toBeVisible(); expect((await evidence(request)).stops).toHaveLength(1);
  await page.screenshot({ path: '../../.artifacts/web-chat/interrupted-not-charged.png' });
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
  await page.frameLocator('[data-testid=reader-frame]').locator('body').evaluate(() => scrollTo(0, document.documentElement.scrollHeight)); // Back is offered only when there's somewhere to return to
  await page.getByRole('button', { name: 'Go to passage', exact: true }).click(); await expect(page.getByTestId('citation-back')).toBeVisible();
  // The chat's … menu offers it too (B10; UX_PARITY: chat title menu, chat "…", All chats).
  await page.getByTestId('chat-menu').click(); await expect(page.getByTestId('chat-menu-passage')).toBeVisible(); await page.keyboard.press('Escape');
  // A second chat about the same passage: tapping the passage lists both by title, not "Chat 1" / "Chat 2" (B10, PaperPassages).
  await frame.locator('p').filter({ hasText: 'preferences' }).first().evaluate(node => { const r = document.createRange(); r.selectNodeContents(node); const s = window.getSelection()!; s.removeAllRanges(); s.addRange(r); document.dispatchEvent(new Event('selectionchange')); });
  await page.getByRole('toolbar', { name: 'Selected passage' }).getByRole('button', { name: 'Explain', exact: true }).click();
  await expect(page.getByTestId('chat-assistant')).toBeVisible();
  await frame.locator('body').evaluate(() => getSelection()?.removeAllRanges());
  await frame.locator('p').filter({ hasText: 'preferences' }).first().click();
  const chats = page.getByTestId('passage-chats');
  await expect(chats.getByRole('button')).toHaveCount(3); // two chats and Cancel
  await expect(chats).not.toContainText('Chat 1');
  await expect(chats.getByRole('button').first()).toContainText(/Why it matters|Explain/);
  await chats.getByRole('button', { name: 'Cancel', exact: true }).click(); await expect(chats).toHaveCount(0);
  // Underline passages with chats can be turned off (the apps' Settings › Reading): the passage no longer offers its chats.
  await page.getByTestId('account-menu').click(); await page.getByTestId('passage-marks').click();
  await expect(page.getByTestId('passage-marks')).toHaveAttribute('aria-checked', 'false'); await page.keyboard.press('Escape');
  await frame.locator('p').filter({ hasText: 'preferences' }).first().click();
  await page.waitForTimeout(300); await expect(chats).toHaveCount(0);
  await page.getByTestId('account-menu').click(); await page.getByTestId('passage-marks').click(); await page.keyboard.press('Escape');
});

test('selected answer text and formulas: Quote in Chat, Explain, Define, Copy LaTeX and Copy as text (B1)', async ({ page, request, browserName }, info) => {
  test.skip(info.project.name === 'webkit', 'Existing key-persistence gate remains in force.');
  if (browserName === 'chromium') await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await login(page); await send(page, 'Explain the objective', true);
  const answer = page.getByTestId('chat-assistant').first(); await expect(answer.locator('math')).toBeVisible();
  const select = (selector: string) => answer.locator(selector).first().evaluate(node => {
    const r = document.createRange(); r.selectNodeContents(node); const s = getSelection()!; s.removeAllRanges(); s.addRange(r);
  });
  const bar = page.getByTestId('answer-selection'), box = page.getByRole('textbox', { name: 'Message', exact: true });
  // Text: Quote in Chat makes a draft, nothing is sent.
  await select('p'); await expect(bar).toHaveAttribute('aria-label', 'Selected text');
  await expect(bar.getByRole('button')).toHaveText(['Quote in Chat', 'Explain', 'Define']);
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-answer-selection.png` });
  await bar.getByRole('button', { name: 'Quote in Chat' }).click();
  await expect(box).toHaveValue(/^About “The objective compares preferences/); await expect(bar).toHaveCount(0);
  // A formula (clicked): Copy LaTeX and Copy as text too; with a draft, Explain joins it unsent.
  await answer.locator('.answer-math').first().click(); await expect(bar).toHaveAttribute('aria-label', 'Selected formula');
  await expect(bar.getByRole('button')).toHaveText(['Copy LaTeX', 'Copy as text', 'Quote in Chat', 'Explain', 'Define']);
  await bar.getByRole('button', { name: 'Copy LaTeX' }).click(); await expect(bar).toContainText('LaTeX copied');
  if (browserName === 'chromium') expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('L = -\\log \\sigma(\\beta x)');
  await bar.getByRole('button', { name: 'Copy as text' }).click();
  if (browserName === 'chromium') expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('L = -log σ(β x)');
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-answer-formula.png` });
  await bar.getByRole('button', { name: 'Explain' }).click();
  await expect(box).toHaveValue(/^Explain this equation: \\\[L = -\\log \\sigma\(\\beta x\)\\\]/);
  await expect(box).toHaveValue(/\n\nAbout “The objective/);
  expect((await evidence(request)).requests).toHaveLength(1);
  // An empty box: Define asks at once.
  await box.fill(''); await select('p'); await bar.getByRole('button', { name: 'Define' }).click();
  await expect(page.getByTestId('chat-user').last()).toContainText('Define the terms and symbols in: The objective compares preferences');
  await expect.poll(async () => (await evidence(request)).requests.length).toBe(2);
});

test('the chat menu sets the chat text size for this browser; the paper keeps its own (B8)', async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit', 'Existing key-persistence gate remains in force.');
  await login(page); await send(page, 'Explain the objective', true);
  const answer = page.getByTestId('chat-assistant').first(); await expect(answer).toBeVisible();
  const size = async () => parseFloat(await answer.evaluate(e => getComputedStyle(e).fontSize));
  const before = await size(), paper = await page.frameLocator('[data-testid=reader-frame]').locator('html').evaluate(e => getComputedStyle(e).fontSize);
  await page.getByTestId('chat-menu').click();
  await page.getByTestId('chat-text-larger').click(); await page.getByTestId('chat-text-larger').click();
  expect(await size()).toBe(before + 2);
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-chat-text-larger.png` });
  await page.keyboard.press('Escape');
  expect(await page.frameLocator('[data-testid=reader-frame]').locator('html').evaluate(e => getComputedStyle(e).fontSize)).toBe(paper);
  await page.reload();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await expect(page.getByTestId('chat-pane')).toHaveAttribute('style', `--chat-text: ${before + 2}px;`);
  await page.getByTestId('chat-menu').click();
  await page.getByTestId('chat-text-smaller').click(); await page.getByTestId('chat-text-smaller').click();
  await expect(page.getByTestId('chat-pane')).toHaveAttribute('style', `--chat-text: ${before}px;`);
});

for (const mode of ['diagram', 'unsafe_diagram', 'broken_diagram']) test(`opaque ${mode} under production CSP`, async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode } }); await login(page); await send(page, 'Draw a preference diagram', true);
  await page.getByRole('button', { name: 'Full size' }).click(); // the diagram is drawn in the answer; full size opens it (build 46)
  const frame = page.getByRole('dialog').frameLocator('iframe[title=Diagram]');
  if (mode === 'diagram') {
    await expect(frame.locator('#diagram svg')).toBeVisible();
    expect(await frame.locator('body').evaluate(() => { try { localStorage.getItem('x'); return true; } catch { return false; } })).toBe(false);
    await page.screenshot({ path: '../../.artifacts/web-chat/diagram.png' });
  } else await expect(page.getByRole('dialog').getByRole('alert')).toContainText('Couldn’t draw this diagram');
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click(); await expect(page.getByTestId('chat-assistant')).toBeVisible();
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
  await page.getByRole('button', { name: 'Stop', exact: true }).click(); await expect(page.getByTestId('chat-interrupted')).toHaveText('Stopped · charged for the part written');
  await expect.poll(async () => (await evidence(request)).events.length).toBe(3);
  expect((await evidence(request)).requests).toHaveLength(1);
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
  await expect(page.getByTestId('chat-interrupted')).toHaveText('Stopped · charged for the part written');
});

test('opaque diagram blocks embedded media, source navigation and remote CSS', async ({ page, request }, info) => {
  test.skip(info.project.name !== 'desktop'); await request.post(`${API}/__chat-fixture`, { data: { mode: 'external_diagram' } });
  const network: string[] = [], popups: string[] = [];
  await page.route('https://attacker.invalid/**', route => { network.push(route.request().url()); return route.abort(); });
  page.on('popup', popup => popups.push(popup.url()));
  await login(page); await send(page, 'A diagram with untrusted links', true);
  await page.getByRole('button', { name: 'Full size' }).click(); // the diagram is drawn in the answer; full size opens it (build 46)
  const frame = page.getByRole('dialog').frameLocator('iframe[title=Diagram]'); await expect(frame.locator('#diagram svg')).toBeVisible();
  await expect(frame.locator('#diagram image, #diagram foreignObject, #diagram script, #diagram [href], #diagram [*|href]')).toHaveCount(0);
  // A click lands on the gesture layer above the opaque frame (build 62); the frame's own guard still stops one sent to it.
  await page.getByTestId('diagram-gesture').click(); await frame.locator('#diagram svg').dispatchEvent('click');
  // Exercise the frame's network policy directly, even if a future Mermaid release emits remote CSS.
  await frame.locator('body').evaluate(node => {
    (window as any).blockedDiagramResource = false;
    document.addEventListener('securitypolicyviolation', e => { if (e.blockedURI.startsWith('https://attacker.invalid/')) (window as any).blockedDiagramResource = true; });
    const style = document.createElement('style'); style.textContent = '#diagram { background-image:url(https://attacker.invalid/style.svg) }'; node.appendChild(style);
  });
  await expect.poll(() => frame.locator('body').evaluate(() => (window as any).blockedDiagramResource)).toBe(true);
  expect(popups).toEqual([]); expect(network).toEqual([]);
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
});

test('a diagram at full size starts across the width, then pinches, wheels, drags and double-clicks back, on desktop and phone', async ({ page, request }, info) => {
  test.skip(info.project.name === 'webkit', 'Existing key-persistence gate remains in force.');
  await request.post(`${API}/__chat-fixture`, { data: { mode: 'tall_diagram' } });
  await login(page); await send(page, 'Draw the complete gradient descent loop', true);
  await page.getByRole('button', { name: 'Full size' }).click(); // the diagram is drawn in the answer; full size opens it (build 46)
  const frame = page.getByRole('dialog').frameLocator('iframe[title=Diagram]');
  await expect(frame.locator('#diagram svg')).toBeVisible();
  // Every node is drawn inside the frame.
  const geometry = await frame.locator('body').evaluate(() => ({
    width: innerWidth, height: innerHeight,
    nodes: [...document.querySelectorAll('#diagram svg .node')].map(node => {
      const box = node.getBoundingClientRect(); return { left: box.left, top: box.top, right: box.right, bottom: box.bottom };
    }),
  }));
  expect(geometry.nodes).toHaveLength(7);
  for (const box of geometry.nodes) {
    expect(box.left).toBeGreaterThanOrEqual(0); expect(box.top).toBeGreaterThanOrEqual(0);
    expect(box.right).toBeLessThanOrEqual(geometry.width); expect(box.bottom).toBeLessThanOrEqual(geometry.height);
  }
  await expect(frame.locator('#diagram')).toContainText('Finish');
  // Across the width at first (owner, build 62), never larger than it is drawn: within the viewport's width, a tall one
  // scrolling down.
  const viewport = page.getByRole('region', { name: 'Diagram viewport', exact: true });
  const room = await viewport.evaluate(node => ({ width: node.clientWidth, height: node.clientHeight, scroll: node.scrollHeight }));
  const frameBox = () => page.getByRole('dialog').locator('iframe[title=Diagram]').boundingBox().then(b => b!);
  expect((await frameBox()).width).toBeLessThanOrEqual(room.width + 1);
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-tall-diagram.png` });
  const firstNode = frame.locator('#diagram svg .node').first();
  const beforeZoom = (await firstNode.boundingBox())!;
  await page.getByRole('button', { name: 'Zoom in diagram', exact: true }).click();
  await page.getByRole('button', { name: 'Zoom in diagram', exact: true }).click();
  expect((await firstNode.boundingBox())!.height).toBeGreaterThan(beforeZoom.height * 1.8);
  const scroll = await viewport.evaluate(node => ({ top: node.scrollTop, extra: node.scrollHeight - node.clientHeight, wide: node.scrollWidth > node.clientWidth, left: node.scrollLeft }));
  expect(scroll.top).toBeGreaterThan(0); expect(scroll.extra).toBeGreaterThan(0);
  if (scroll.wide) expect(scroll.left).toBeGreaterThan(0);
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-tall-diagram-zoomed.png` });
  await page.getByRole('button', { name: 'Fit diagram', exact: true }).click();
  expect(await viewport.evaluate(node => node.scrollTop + node.scrollLeft)).toBe(0);
  expect((await firstNode.boundingBox())!.height).toBeCloseTo(beforeZoom.height, 0);

  // Over the diagram (a layer above its opaque frame): ctrl + wheel (a trackpad pinch) zooms about the pointer.
  const layer = page.getByTestId('diagram-gesture');
  const at = (await layer.boundingBox())!, centre = { x: at.x + Math.min(at.width, room.width) / 2, y: at.y + Math.min(at.height, room.height) / 2 };
  await page.mouse.move(centre.x, centre.y);
  await page.keyboard.down('Control'); await page.mouse.wheel(0, -120); await page.keyboard.up('Control');
  await expect.poll(async () => (await firstNode.boundingBox())!.height).toBeGreaterThan(beforeZoom.height * 1.5);
  // A drag pans.
  const before = await viewport.evaluate(node => node.scrollTop);
  await page.mouse.move(centre.x, centre.y); await page.mouse.down(); await page.mouse.move(centre.x, centre.y - 120, { steps: 6 }); await page.mouse.up();
  expect(await viewport.evaluate(node => node.scrollTop)).toBeGreaterThan(before + 60);
  // A double-click goes back to the start.
  await layer.dblclick({ position: { x: 20, y: 20 } });
  await expect.poll(async () => (await firstNode.boundingBox())!.height).toBeCloseTo(beforeZoom.height, 0);
  expect(await viewport.evaluate(node => node.scrollTop + node.scrollLeft)).toBe(0);
  // Two fingers apart zoom in (pointer events as a touch screen sends them).
  const touch = async (type: string, id: number, x: number, y: number) => layer.dispatchEvent(type, { pointerId: id, pointerType: 'touch', isPrimary: id === 1, clientX: x, clientY: y, bubbles: true });
  await touch('pointerdown', 1, centre.x - 20, centre.y); await touch('pointerdown', 2, centre.x + 20, centre.y);
  for (const spread of [40, 70, 100]) await touch('pointermove', 2, centre.x + spread, centre.y);
  await touch('pointerup', 2, centre.x + 100, centre.y); await touch('pointerup', 1, centre.x - 20, centre.y);
  await expect.poll(async () => (await firstNode.boundingBox())!.height).toBeGreaterThan(beforeZoom.height * 2);
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-tall-diagram-pinched.png` });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.screenshot({ path: `../../.artifacts/web-chat/${info.project.name}-tall-diagram-pinched-dark.png` });
  await page.emulateMedia({ colorScheme: 'light' });
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
  await expect(page.getByTestId('chat-assistant')).toBeVisible();
});
