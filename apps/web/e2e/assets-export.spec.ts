// Your assets › Download your assets (owner, build 82: "Need a download assets button"): a drawn snippet and a collection
// are saved, then the account menu's Download your assets makes the .zip in this browser and saves it. The downloaded
// file is opened here: README first, the collection's Markdown with its comment, and the snippet's image decrypted (a
// real PNG/JPEG, where the server only ever held ciphertext). Real WebCrypto and the local fixture backend; desktop and
// phone; screenshots under .artifacts/web-e2e/assets-export/.
import { mkdirSync, readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';

const SHOTS = '../../.artifacts/web-e2e/assets-export';
mkdirSync(SHOTS, { recursive: true });
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png` });
const phone = () => test.info().project.name === 'phone';

async function signIn(page: Page) {
  await page.goto('/');
  await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}

/** The zip's entries through its central directory (stored entries, as lib/assets-export.ts writes them). */
function entries(bytes: Buffer): Map<string, Buffer> {
  const end = bytes.length - 22, out = new Map<string, Buffer>();
  expect(bytes.readUInt32LE(end)).toBe(0x06054b50);
  let at = bytes.readUInt32LE(end + 16);
  for (let i = 0; i < bytes.readUInt16LE(end + 10); i++) {
    const size = bytes.readUInt32LE(at + 20), nameLength = bytes.readUInt16LE(at + 28), offset = bytes.readUInt32LE(at + 42);
    const name = bytes.subarray(at + 46, at + 46 + nameLength).toString('utf8');
    const data = offset + 30 + bytes.readUInt16LE(offset + 26);
    out.set(name, bytes.subarray(data, data + size));
    at += 46 + nameLength;
  }
  return out;
}

test.beforeEach(async ({ request, page }) => {
  await request.post(`${API}/__reset`);
  await page.route('https://arxiv.org/**', route => route.abort());
});

test('Download your assets: a zip made here with the collection, its comment and the decrypted snippet image', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys (WebKit 312279).');
  const errors: string[] = [], remote: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('request', r => { const u = r.url(); if (!u.startsWith('http://127.0.0.1:') && !u.startsWith('data:') && !u.startsWith('blob:') && !u.startsWith('https://arxiv.org/')) remote.push(u); });
  await signIn(page);

  // A collection and a drawn snippet in it.
  await page.getByTestId('nav-notes').click();
  await page.getByTestId('new-note').first().click();
  await page.getByTestId('note-name').fill('Export check'); await page.getByTestId('note-name-save').click();
  await expect(page.getByTestId('note-title')).toHaveText('Export check');
  await page.getByTestId('back-to-library').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.frameLocator('[data-testid=reader-frame]').locator('h1').first()).toBeVisible();
  if (phone() && await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('chat-pane').getByRole('button', { name: /Close|Hide/ }).first().click();
  await page.getByRole('button', { name: /^Actions for Direct Preference Optimization/ }).click();
  await page.getByTestId('draw-snippet').click();
  const stage = page.getByTestId('snippet-stage'); await expect(stage).toBeVisible();
  const box = (await stage.boundingBox())!;
  await page.mouse.move(box.x + box.width * 0.12, box.y + box.height * 0.3); await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.88, box.y + box.height * 0.62, { steps: 8 }); await page.mouse.up();
  await page.getByTestId('snippet-use').click();
  const composer = page.getByRole('dialog', { name: 'Save snippet' });
  await composer.getByTestId('composer-note').selectOption({ label: 'Export check' }).catch(() => {});
  await composer.getByTestId('composer-comment').fill('The objective in one picture.');
  await composer.getByTestId('composer-save').click();
  await expect(page.getByTestId('notes-saved')).toContainText('Saved to Export check');

  // Your assets › Download your assets.
  await page.getByTestId('account-menu').click(); await page.getByTestId('open-settings').click(); // Settings › Your assets
  await page.getByTestId('assets-download').click();
  const dialog = page.getByRole('dialog', { name: 'Download your assets' });
  await expect(dialog).toContainText('Downloaded papers aren’t included');
  const [download] = await Promise.all([page.waitForEvent('download'), dialog.getByTestId('assets-export-run').click()]);
  await expect(dialog.getByTestId('assets-export-done')).toContainText(/Downloaded Gradstep export \d{4}-\d{2}-\d{2}\.zip/);
  await shot(page, 'done');
  expect(download.suggestedFilename()).toMatch(/^Gradstep export \d{4}-\d{2}-\d{2}\.zip$/);

  const files = entries(readFileSync((await download.path())!));
  const names = [...files.keys()];
  expect(names[0]).toMatch(/^Gradstep export \d{4}-\d{2}-\d{2}\/README\.md$/);
  const root = names[0]!.split('/')[0];
  const collection = files.get(`${root}/snippets/Export check.md`)?.toString('utf8') ?? '';
  expect(collection).toContain('The objective in one picture.');
  const image = names.find(n => n.startsWith(`${root}/snippets/images/`))!;
  expect(collection).toContain(`![Snippet](<images/${image.split('/').pop()}>)`);
  const head = files.get(image)!.subarray(0, 3).toString('hex');
  expect(['89504e', 'ffd8ff']).toContain(head); // decrypted here: a real image
  expect(names.some(n => /\.pdf$/i.test(n))).toBe(false);
  expect(files.get(names[0]!)!.toString('utf8')).toContain('- Snippets: 1 in 1 collection');
  await dialog.getByRole('button', { name: 'Done' }).click();
  expect(errors).toEqual([]);
  expect(remote).toEqual([]);
});
