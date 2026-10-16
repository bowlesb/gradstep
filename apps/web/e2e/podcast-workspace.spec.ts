// The real App/Feed/Reader composition, under the production CSP. Synthetic audio only.
import { createHash, randomUUID } from 'node:crypto';
import { expect, test, type Page } from '@playwright/test';
import { RECOVERY_CODE } from './fixture-keys.mjs';
import { fixtureOrigin as API } from './environment';
import { durableKeys } from './key-capability';

const releaseID = 'a0000000-0000-4000-8000-000000000001', mineID = 'a0000000-0000-4000-8000-000000000009';
const dpoID = 'aaaaaaaa-0000-4000-8000-000000000001';
const quoteText = 'can be optimized exactly with a simple binary cross-entropy objective';
const audio = Buffer.alloc(44 + 48 * 8_000 * 2);
audio.write('RIFF'); audio.writeUInt32LE(audio.length - 8, 4); audio.write('WAVEfmt ', 8); audio.writeUInt32LE(16, 16);
audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22); audio.writeUInt32LE(8_000, 24); audio.writeUInt32LE(16_000, 28);
audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34); audio.write('data', 36); audio.writeUInt32LE(audio.length - 44, 40);
for (let i = 0; i < 48 * 8_000; i++) audio.writeInt16LE(Math.round(Math.sin(i / 8_000 * 2 * Math.PI * 220) * 300), 44 + 2 * i);
const digest = createHash('sha256').update(audio).digest('hex');

// Every length with its writers (podcast_lengths, migration 065), as servers from 2026-10-14 list them.
const writers = (max: number) => [{ writer: 'anthropic', label: 'Anthropic', max_credits: max }, { writer: 'deepseek', label: 'DeepSeek', max_credits: Math.round(max / 3) }];
const LENGTHS = ([['podcast-short-v1', 'Short', 150, 60], ['podcast-5min-v1', '5 min', 300, 150], ['podcast-10min-v1', '10 min', 600, 300], ['podcast-20min-v1', '20 min', 1200, 600]] as const)
  .map(([profile, label, target_seconds, max_credits]) => ({ profile, label, target_seconds, max_credits, writers: writers(max_credits) }));
async function fixture(page: Page, options: { lengths?: boolean; sourceUnavailable?: boolean } = {}) {
  const state = { documentID: '', inLibrary: true, deployed: true, calls: [] as { action: string; body: Record<string, unknown> }[],
    /** What the account's own section says about the started request (migration 076). */ mine: 'making' as 'making' | 'ready' | 'failed' };
  await page.route('**/rest/v1/rpc/v3_library_page', async route => {
    const response = await route.fetch(), data = await response.json();
    state.documentID = data.entries.find((e: { id: string }) => e.id === dpoID)?.document_id ?? state.documentID;
    await route.fulfill({ response });
  });
  const episode = () => ({ release_id: releaseID, document_id: state.inLibrary ? state.documentID : 'dddddddd-1111-4111-8111-111111111111',
    scope: 'shared', title: 'Synthetic fixture: Direct Preference Optimization', state: 'ready', replacement_id: null,
    fixture: true, ai_audio: true, language: 'en', authors: ['Rafael Rafailov'], year: 2023, topic: 'Alignment', duration_ms: 48_000,
    published_at: '2026-10-08T00:00:00Z', source: { arxiv_id: '1706.03762', version: 3,
      url: 'https://arxiv.org/abs/1706.03762v3', license: 'https://creativecommons.org/licenses/by/4.0/' },
    audio: { bytes: audio.length, sha256: digest, media_type: 'audio/wav' } });
  const capabilities = { catalog: true, delivery: true, generation: true, max_credits: 150, target_seconds: 300, ...(options.lengths ? { lengths: LENGTHS } : {}) };
  let quoteID = '', requestID = '', started = false;
  const grants = new Set<string>();
  const job = () => ({ request_id: requestID, state: 'queued', stage_entered_at: new Date().toISOString(), release_id: null,
    held_credits: 150, charged_credits: null, released_credits: null, failure: null });
  await page.route('**/functions/v1/podcast**', async route => {
    const url = new URL(route.request().url()), action = url.pathname.endsWith('podcast-member') ? 'member' : url.searchParams.get('action')!;
    const body = route.request().method() === 'POST' ? route.request().postDataJSON() : {};
    state.calls.push({ action, body });
    if (!state.deployed) return route.fulfill({ status: 404, json: { code: 'NOT_FOUND' } });
    if (action === 'member') {
      expect(grants.delete(url.searchParams.get('grant')!)).toBe(true);
      expect(route.request().headers().range).toBeUndefined();
      return route.fulfill({ body: audio, contentType: 'audio/wav' });
    }
    if (action === 'catalog') return route.fulfill({ json: { episodes: [episode()], next: null, capabilities, mine: !started ? { episodes: [], requests: [] }
      : state.mine === 'ready' ? { episodes: [{ ...episode(), release_id: mineID, scope: 'private', title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model',
        document_id: dpoID, authors: [], topic: null, request_id: requestID }], requests: [] }
      : { episodes: [], requests: [{ request_id: requestID, status: state.mine, failure: state.mine === 'failed' ? 'quality_rejected' : null, profile: 'podcast-5min-v1', label: '5 min',
        target_seconds: 300, document_id: dpoID, title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model' }] } } });
    if (action === 'states') return route.fulfill({ json: { states: Object.fromEntries((body.release_ids as string[]).map(id => [id, { state: 'ready', replacement_id: null }])) } });
    if (action === 'episode') return route.fulfill({ json: { episode: { ...episode(), ...(url.searchParams.get('release_id') === mineID ? { release_id: mineID, scope: 'private', title: null, document_id: dpoID } : {}), chapters: [{ id: 'result', title: 'The result', start_ms: 0 }],
      transcript: { speakers: { explainer: 'Explainer', skeptic: 'Skeptical reader' }, disclosure: 'Synthetic fixture tone. No generated speech.',
        segments: [{ id: 'one', speaker: 'explainer', text: 'DPO uses a binary cross-entropy objective.', start_ms: 0, end_ms: 48_000,
          chapter: 'result', claim_type: 'paper_result', evidence: [{ id: 'passage', section: '1', quote: quoteText }], math: [] }] } } } });
    if (action === 'download') {
      const grant = createHash('sha256').update(randomUUID()).digest('hex'); grants.add(grant);
      return route.fulfill({ json: { grant: { expires_at: new Date(Date.now() + 60_000).toISOString(), members: [{ role: 'audio',
        url: `${API}/functions/v1/podcast-member?grant=${grant}&member=${body.release_id}`, bytes: audio.length, sha256: digest, media_type: 'audio/wav' }] } } });
    }
    if (action === 'paper') return route.fulfill({ json: { episode: null, job: started && state.mine === 'making' ? job() : null, capabilities } });
    if (action === 'quote' && options.sourceUnavailable) return route.fulfill({ status: 409, json: { code: 'source_unavailable' } });
    if (action === 'quote' && options.lengths) {
      requestID = body.request_id; quoteID = randomUUID();
      const length = LENGTHS.find(l => l.profile === body.profile)!, max = length.writers.find(w => w.writer === body.writer)!.max_credits;
      return route.fulfill({ json: { quote: { id: quoteID, expires_at: new Date(Date.now() + 60_000).toISOString(), max_credits: max, target_seconds: length.target_seconds,
        label: length.label, estimate: `Estimate: up to ${max} credits`, providers: [body.writer === 'deepseek' ? 'DeepSeek (script)' : 'Anthropic (script)', 'Google Vertex AI (speech)'],
        consent_version: 'podcast-private-v1' } } });
    }
    if (action === 'quote') {
      requestID = body.request_id; quoteID = randomUUID();
      return route.fulfill({ json: { quote: { id: quoteID, expires_at: new Date(Date.now() + 60_000).toISOString(), max_credits: 150,
        target_seconds: 300, estimate: 'Estimate: up to 150 credits', providers: ['Anthropic (script)', 'Google Vertex AI (speech)'], consent_version: 'podcast-private-v1' } } });
    }
    if (action === 'start') {
      expect(body).toEqual({ request_id: requestID, quote_id: quoteID, consent_version: 'podcast-private-v1' }); started = true;
      return route.fulfill({ json: { job: job() } });
    }
    if (action === 'status') return route.fulfill({ json: { job: job() } });
    throw new Error(`Unexpected podcast action: ${action}`);
  });
  return state;
}

async function signIn(page: Page) {
  await page.goto('/'); await page.getByTestId('email').fill('returning@example.test'); await page.getByTestId('send-code').click();
  await page.getByTestId('code').fill('123456'); await page.getByTestId('verify').click();
  await page.getByTestId('use-recovery-code').click(); await page.getByTestId('recovery-code').fill(RECOVERY_CODE); await page.getByTestId('recover').click();
  await expect(page.getByTestId('library-table')).toBeVisible();
}
async function showChat(page: Page) {
  await expect(page.getByTestId('reader-frame')).toBeVisible();
  if (!await page.getByTestId('chat-pane').isVisible()) await page.getByTestId('ask').click();
  await expect(message(page)).toBeVisible();
}
async function closeDrawer(page: Page) { if (await page.locator('.pane-right.overlay').count()) await page.keyboard.press('Escape'); }
const message = (page: Page) => page.getByRole('textbox', { name: 'Message', exact: true });
async function listen(page: Page) {
  await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('podcast-listen').filter({ visible: true }).click();
  await expect(page.getByTestId('podcast-card')).toBeVisible(); await page.getByTestId('podcast-play').click();
  await expect(page.getByTestId('podcast-audio')).toHaveAttribute('src', /^blob:/);
  await expect(page.getByTestId('podcast-position')).toBeEnabled();
  await page.getByTestId('podcast-audio').evaluate((e: HTMLAudioElement) => e.pause());
}

test.beforeEach(async ({ page, request }) => {
  test.skip(!await durableKeys(page), 'Safari secure-key storage remains its own acceptance gate.');
  await request.post(`${API}/__reset`);
});

test('Listen preserves the draft, opens the exact evidence paper and leaves room for chat', async ({ page, request }, info) => {
  const f = await fixture(page), errors: string[] = []; page.on('pageerror', e => errors.push(String(e)));
  await page.addInitScript(() => { (window as any).passages = []; window.addEventListener('message', e => {
    if (e.data?.gradstep === 'reader' && e.data.value?.type === 'passage') (window as any).passages.push(e.data.value.found);
  }); });
  await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await showChat(page);
  await message(page).fill('Keep my paper question while I listen'); await closeDrawer(page);
  await listen(page); await page.getByTestId('podcast-expand').click(); await page.getByTestId('podcast-evidence').click();
  await expect(page).toHaveURL(new RegExp(`/paper/${dpoID}$`));
  await expect.poll(() => page.evaluate(() => (window as any).passages)).toContain(true);
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'false');
  await showChat(page); await expect(message(page)).toHaveValue('Keep my paper question while I listen');
  const composer = await message(page).boundingBox(), dock = await page.getByTestId('podcast-dock').boundingBox();
  expect(composer!.y + composer!.height).toBeLessThanOrEqual(dock!.y);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: `../../.artifacts/web-podcast-workspace/${info.project.name}-paper-chat.png` });
  expect(f.calls.filter(c => c.action === 'start' || c.action === 'quote')).toHaveLength(0);
  expect((await (await request.get(`${API}/__chat-evidence`)).json()).requests).toHaveLength(0);
  await page.getByTestId('podcast-stop').click(); await page.reload(); await showChat(page);
  await expect(message(page)).toHaveValue('Keep my paper question while I listen'); expect(errors).toEqual([]);
});

test('a missing evidence paper requires explicit Add with separate source revision', async ({ page }) => {
  const f = await fixture(page); f.inLibrary = false; const adds: Record<string, unknown>[] = [];
  page.on('request', request => { if (request.url().endsWith('/rpc/v2_begin_import')) adds.push(request.postDataJSON()); });
  await signIn(page); await listen(page); await page.getByTestId('podcast-expand').click(); await page.getByTestId('podcast-evidence').click();
  await expect(page).toHaveURL(/\/feed$/); await expect(page.getByRole('link', { name: 'Open source' })).toHaveAttribute('href', 'https://arxiv.org/abs/1706.03762v3');
  expect(adds).toHaveLength(0); await page.getByRole('button', { name: 'Add to library', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('Added.'); expect(adds).toHaveLength(1);
  expect(adds[0]).toMatchObject({ p_source_id: '1706.03762', p_requested_revision: 3 });
  expect(f.calls.filter(c => c.action === 'start')).toHaveLength(0);
});

test('superseded evidence navigation preserves the transcript and cannot leave a later passage jump', async ({ page }) => {
  await fixture(page);
  await page.addInitScript(() => { (window as any).passages = []; window.addEventListener('message', e => {
    if (e.data?.gradstep === 'reader' && e.data.value?.type === 'passage') (window as any).passages.push(e.data.value.found);
  }); });
  await signIn(page); await listen(page);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('button').click();
  await page.getByTestId('history-menu').click(); await page.getByRole('menuitem', { name: 'New general chat', exact: true }).click(); // All chats › ≡ (build 57)
  await expect(message(page)).toBeFocused();
  await page.evaluate(() => {
    const timer = window.setTimeout.bind(window);
    window.setTimeout = ((handler: TimerHandler, delay?: number, ...args: unknown[]) => timer(handler, delay === 400 ? 30_000 : delay, ...args)) as typeof window.setTimeout;
    const encrypt = crypto.subtle.encrypt.bind(crypto.subtle);
    const gate = new Promise<void>(resolve => { (window as any).releaseCheckpoint = resolve; });
    (window as any).checkpointWaiting = false;
    crypto.subtle.encrypt = async (...args: Parameters<SubtleCrypto['encrypt']>) => {
      (window as any).checkpointWaiting = true;
      await gate;
      return encrypt(...args);
    };
  });
  await message(page).fill('Hold this draft while I change my navigation choice'); await closeDrawer(page);
  await page.getByTestId('podcast-expand').click(); await page.getByTestId('podcast-evidence').click();
  await expect.poll(() => page.evaluate(() => (window as any).checkpointWaiting)).toBe(true);
  await page.getByTestId('back-to-library').click();
  await page.evaluate(() => (window as any).releaseCheckpoint());
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByTestId('podcast-expand')).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByRole('button', { name: 'Add to library', exact: true })).toHaveCount(0);
  await page.getByTestId('podcast-expand').click();
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click();
  await expect(page.getByTestId('reader-frame')).toBeVisible();
  expect(await page.evaluate(() => (window as any).passages)).toEqual([]);
});

test('paper generation is one explicit action; undeployed podcasts never offer a paid action', async ({ page }) => {
  const f = await fixture(page); await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await closeDrawer(page);
  expect(f.calls.filter(c => c.action === 'quote')).toHaveLength(0);
  await page.getByTestId('podcast-paper-listen').click();
  const dialog = page.getByRole('dialog', { name: 'Listen to this paper' });
  await expect(page.getByTestId('podcast-confirm')).toBeEnabled();
  await expect(dialog.getByTestId('podcast-privacy')).toContainText('sent to Anthropic and Google and deleted once the episode is made'); await expect(dialog).toContainText('not end-to-end encrypted');
  expect(f.calls.filter(c => c.action === 'start')).toHaveLength(0); await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-making')).toContainText('Making your episode');
  await page.getByRole('button', { name: 'Close Listen' }).click(); expect(f.calls.filter(c => c.action === 'cancel')).toHaveLength(0);
  f.deployed = false; await page.getByRole('link', { name: 'Feed', exact: true }).click();
  await page.getByTestId('podcast-listen').filter({ visible: true }).click(); await expect(page.getByTestId('podcast-unavailable')).toBeVisible();
  await page.getByTestId('back-to-library').click(); await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await closeDrawer(page);
  await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-generation-unavailable')).toBeVisible();
  await expect(page.getByTestId('podcast-confirm')).toHaveCount(0);
});

test('Listen offers every length and both writers compactly, prices the chosen one, and says where the text goes', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  const f = await fixture(page, { lengths: true }); await signIn(page);
  await page.getByRole('link', { name: 'Feed', exact: true }).click(); await page.getByTestId('podcast-listen').filter({ visible: true }).click();
  await expect(page.getByRole('button', { name: 'Check for new episodes' })).toBeVisible();
  await page.getByTestId('back-to-library').click(); await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await closeDrawer(page);
  await page.getByTestId('podcast-paper-listen').click();
  const dialog = page.getByRole('dialog', { name: 'Listen to this paper' });
  // All four lengths (PodcastGenerateSheet's chips), the default 5 min and the default writer chosen, priced at once.
  const lengths = dialog.getByTestId('podcast-lengths');
  await expect(lengths.getByRole('radio')).toHaveCount(4);
  await expect(lengths.getByRole('radio', { name: '5 min' })).toBeChecked();
  await expect(dialog.getByTestId('podcast-writers').getByRole('radio', { name: 'Anthropic' })).toBeChecked();
  await expect(dialog.getByTestId('podcast-price')).toHaveText('Up to 150 credits. You’re charged only for what’s used, and nothing if it can’t be made.');
  await dialog.getByRole('radio', { name: 'DeepSeek' }).check();
  await expect(dialog.getByTestId('podcast-price')).toContainText('Up to 50 credits.');
  await lengths.getByRole('radio', { name: '10 min' }).check();
  await expect(dialog.getByTestId('podcast-length-line')).toHaveText('About 10 minutes');
  await expect(dialog.getByTestId('podcast-price')).toContainText('Up to 100 credits.');
  await expect(page.getByTestId('podcast-confirm')).toBeEnabled();
  await page.screenshot({ path: `../../.artifacts/parity-web-listen-lengths-${test.info().project.name}.png` });
  expect(f.calls.filter(c => c.action === 'quote').at(-1)!.body).toMatchObject({ profile: 'podcast-10min-v1', writer: 'deepseek' });
  await expect(dialog.getByTestId('podcast-privacy')).toContainText('To make it, the paper’s text is sent to DeepSeek and Google and deleted once the episode is made.');
  for (const jargon of ['converted', 'source', '(script)', 'Vertex', 'estimate']) await expect(dialog).not.toContainText(jargon);
  await expect(page.getByTestId('podcast-confirm')).toHaveText('Make an episode');
});

test('a paper whose text isn’t on this device yet says to open it first', async ({ page }) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  await fixture(page, { sourceUnavailable: true }); await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await closeDrawer(page);
  await page.getByTestId('podcast-paper-listen').click();
  await expect(page.getByRole('alert')).toHaveText('Open this paper first so it’s ready on this device, then try again.');
});

// Owner, 2026-10-16: "you ask for, it doesnt matter if you leave the page or app, its there for you".
test('ask, leave for Listen, come back to the tab: the episode is waiting, marked New', async ({ page }, info) => {
  test.skip(!await durableKeys(page), 'Engine cannot persist X25519 keys.');
  const f = await fixture(page, { lengths: true }); await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await closeDrawer(page);
  await page.getByTestId('podcast-paper-listen').click();
  await expect(page.getByTestId('podcast-confirm')).toBeEnabled();
  await page.screenshot({ path: `../../.artifacts/podcast-simple/after/web-${info.project.name}-ask.png` });
  await page.getByTestId('podcast-confirm').click();
  await expect(page.getByTestId('podcast-leave')).toHaveText('You can leave this page. It’ll be in Listen when it’s ready.');
  await page.screenshot({ path: `../../.artifacts/podcast-simple/after/web-${info.project.name}-making.png` });
  await page.getByTestId('podcast-done').click();
  await page.getByRole('link', { name: 'Feed', exact: true }).click(); await page.getByTestId('podcast-listen').filter({ visible: true }).click();
  const own = page.getByTestId('podcast-own');
  await expect(own.getByTestId('podcast-request')).toHaveAttribute('data-status', 'making');
  await expect(own).toContainText('Direct Preference Optimization'); await expect(own).toContainText('Making your episode');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: `../../.artifacts/podcast-simple/after/web-${info.project.name}-listen-making.png` });
  // Made while the reader was elsewhere; coming back to the tab checks at once.
  f.mine = 'ready';
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await expect(own.getByTestId('podcast-request')).toHaveCount(0);
  await expect(own.getByTestId('podcast-new')).toBeVisible(); await expect(own.getByTestId('podcast-card')).toContainText('Direct Preference Optimization');
  await page.screenshot({ path: `../../.artifacts/podcast-simple/after/web-${info.project.name}-listen-ready.png` });
  await own.getByTestId('podcast-play').click();
  await expect(page.getByTestId('podcast-audio')).toHaveAttribute('src', /^blob:/);
  await page.getByTestId('podcast-audio').evaluate((e: HTMLAudioElement) => e.pause());
  await expect(page.getByTestId('podcast-dock')).toContainText('Direct Preference Optimization');
  await expect(own.getByTestId('podcast-new')).toHaveCount(0);
  expect(f.calls.filter(c => c.action === 'start')).toHaveLength(1);
});

test('a request that couldn’t be made says so plainly in Listen, and Try again opens the paper’s Listen', async ({ page }) => {
  const f = await fixture(page); await signIn(page);
  await page.getByTestId('library-table').getByRole('link', { name: /Direct Preference Optimization/ }).click(); await closeDrawer(page);
  await page.getByTestId('podcast-paper-listen').click(); await expect(page.getByTestId('podcast-confirm')).toBeEnabled();
  await page.getByTestId('podcast-confirm').click(); await page.getByTestId('podcast-done').click();
  f.mine = 'failed';
  await page.getByRole('link', { name: 'Feed', exact: true }).click(); await page.getByTestId('podcast-listen').filter({ visible: true }).click();
  const own = page.getByTestId('podcast-own');
  await expect(own.getByTestId('podcast-request')).toHaveAttribute('data-status', 'failed');
  await expect(own).toContainText('Couldn’t make this episode.'); await expect(own).not.toContainText('quality_rejected');
  await own.getByTestId('podcast-request-retry').click();
  await expect(page).toHaveURL(new RegExp(`/paper/${dpoID}$`));
  await expect(page.getByRole('dialog', { name: 'Listen to this paper' })).toBeVisible();
  await expect(page.getByTestId('podcast-confirm')).toBeEnabled();
  expect(f.calls.filter(c => c.action === 'start')).toHaveLength(1);
});
