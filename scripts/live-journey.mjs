#!/usr/bin/env node
// Full staging journey on the iPhone Simulator: synthetic account → recorded
// operator credit grant → add arXiv paper → paid conversion → download →
// offline reader (→ optional paid question) → relaunch. Costs are capped by
// the database platform budget. The synthetic account is kept for inspection.
// With --delete the run instead deletes the account through Settings and checks
// the server (closed, login removed, no personal rows).
// --store runs Settings › Get credits and requires every product to be listed (no purchase).
// --reference=11:PaLM adds the paper first, follows citation 11 → Add to library and waits for
// the cited paper to become readable (one Add paper answer, about $0.10 on DPO).
// --derived=/private/tmp/... uses that DerivedData folder (default .artifacts/lead-derived).
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
// A git worktree reads the main checkout's secrets.
const secrets = existsSync(new URL('.env.staging', root)) ? root : pathToFileURL(dirname(execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
  { cwd: fileURLToPath(root), encoding: 'utf8' }).trim()) + '/');
const env = Object.fromEntries(readFileSync(new URL('.env.staging', secrets), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
mkdirSync(new URL('.artifacts/', root), { recursive: true });
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const args = Object.fromEntries(process.argv.slice(2).map(a => { const [k, v] = a.replace(/^--/, '').split('='); return [k, v ?? 'true']; }));
const arxiv = args.arxiv ?? '2305.18290', title = args.title ?? 'Direct Preference Optimization';
const device = args.device ?? 'B6CD74CE-CB0C-417E-9E9B-F68175B5094D';
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const email = `science-reader-journey-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
assert.equal(created.error, null, 'Could not create the synthetic account');
const account = created.data.user.id;
const grant = await admin.rpc('worker_grant_credits', { p_account_id: account, p_source: 'adjustment', p_external_key: `operator:journey:${account}`,
  p_credits: Number(args.credits ?? 300), p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Synthetic journey test grant' });
assert.equal(grant.error, null, 'Credit grant failed');
writeFileSync(new URL(`.artifacts/live-journey-${account}.json`, root), JSON.stringify({ account, email, password, arxiv, created_at: new Date().toISOString() }), { mode: 0o600 });
console.log('Synthetic account', account, 'granted', args.credits ?? 300, 'credits');
// --open-timing=2305.18290:Direct Preference|2312.00752:Mamba — add converted papers first, then time opening them.
const timing = args['open-timing'] && args['open-timing'] !== 'true' ? args['open-timing'].split('|').map(x => x.split(':')) : [];
const reference = args.reference && args.reference !== 'true' ? args.reference : null;
const prepared = timing.length ? timing : reference ? [[arxiv, title]] : [];
if (prepared.length) {
  const user = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  assert.equal((await user.auth.signInWithPassword({ email, password })).error, null);
  for (const [source] of prepared) {
    const cursor = (await user.rpc('v2_library_page', { p_cursor: null, p_limit: 1 })).data.baseline_cursor;
    const begun = await user.rpc('v2_begin_import', { p_operation_id: randomUUID(), p_source_id: source, p_observed_cursor: cursor });
    assert.equal(begun.error, null, begun.error?.message);
  }
  for (const started = Date.now(); ;) {
    const ready = (await user.rpc('v2_library_page', { p_cursor: null, p_limit: 50 })).data.entries.filter(e => e.kind === 'item' && e.readiness === 'converted_ready');
    if (ready.length === prepared.length) break;
    assert.ok(Date.now() - started < 300_000, 'papers did not become ready'); await new Promise(r => setTimeout(r, 2000));
  }
  console.log('Papers ready:', prepared.map(t => t[0]).join(', '));
}
if (!args['no-generate']) execFileSync('xcodegen', ['generate'], { cwd: new URL('apps/apple/', root), stdio: 'ignore' });
// Start from a clean install: the Keychain session of an earlier synthetic
// account must not carry into this run.
try { execFileSync('xcrun', ['simctl', 'uninstall', device, 'com.sciencereader.ios'], { stdio: 'ignore' }); } catch { /* not installed */ }
// Keychain items survive app deletion on the Simulator; reset them too.
try { execFileSync('xcrun', ['simctl', 'keychain', device, 'reset'], { stdio: 'ignore' }); } catch { /* older simctl */ }
const result = `../../.artifacts/live-journey-${account}.xcresult`;
const xcode = ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug', '-destination', `platform=iOS Simulator,id=${device}`,
  '-derivedDataPath', args.derived && args.derived !== 'true' ? args.derived : '../../.artifacts/lead-derived', '-resultBundlePath', result,
  `-only-testing:ScienceReaderUITests/LiveJourneyTests/${timing.length ? 'testOpenTimingsOfConvertedPapers' : args.store ? 'testGetCreditsListsEveryProduct'
    : reference ? 'testReferenceAddToLibraryImportsThePaper' : args.delete ? 'testDeleteAccountFromSettings' : 'testAddConvertDownloadReadAskAndRelaunch'}`,
  'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'test'];
const child = spawn('xcodebuild', xcode, { cwd: new URL('apps/apple/', root), stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env,
  TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_EMAIL: email, TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_PASSWORD: password,
  TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_ARXIV: arxiv, TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_TITLE: title,
  ...(args.question ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_QUESTION: args.question } : {}),
  ...(args.search ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_SEARCH: args.search } : {}),
  ...(args.delete ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_DELETE: '1' } : {}),
  ...(args.store ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_STORE: '1' } : {}),
  ...(reference ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_REFERENCE: reference } : {}),
  ...(timing.length ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_OPEN_TIMING: timing.map(t => t[1]).join('|') } : {}) } });
let log = ''; child.stdout.on('data', b => { log += b; }); child.stderr.on('data', b => { log += b; });
// A timing run records a session; copy it out while the test runs (Xcode removes the app when testing ends).
const copied = new Set();
const watcher = timing.length ? setInterval(() => {
  try {
    const container = execFileSync('xcrun', ['simctl', 'get_app_container', device, 'com.sciencereader.ios', 'data'], { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    const dir = join(container, 'Library/Application Support/TestSessions');
    for (const zip of readdirSync(dir).filter(n => n.endsWith('.zip') && !copied.has(n))) {
      execFileSync('ditto', ['-x', '-k', join(dir, zip), fileURLToPath(new URL('.artifacts/sessions/', root))]); copied.add(zip);
      console.log('Session:', zip);
    }
  } catch { /* not installed yet or no sessions */ }
}, 1500) : null;
const status = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
log = log.replaceAll(password, '[redacted]');
if (watcher) clearInterval(watcher);
// Leave the Simulator signed out for other test suites.
try { execFileSync('xcrun', ['simctl', 'uninstall', device, 'com.sciencereader.ios'], { stdio: 'ignore' }); } catch {}
try { execFileSync('xcrun', ['simctl', 'keychain', device, 'reset'], { stdio: 'ignore' }); } catch {}
writeFileSync(new URL(`.artifacts/live-journey-${account}.log`, root), log, { mode: 0o600 });
console.log(log.split('\n').filter(l => /Test Case|error:|failed|passed|TEST (SUCCEEDED|FAILED)|OPEN-TIMING/.test(l)).slice(-25).join('\n'));
console.log('Result bundle:', result.replace('../../', ''));
if (args.delete && status === 0) {
  const server = await admin.rpc('worker_account_deletion_status', { p_account_id: account });
  assert.equal(server.error, null, server.error?.message);
  console.log('Server status', JSON.stringify(server.data));
  assert.ok(server.data.closed && !server.data.login_linked && server.data.personal_rows === 0, 'account not fully deleted');
  assert.ok((await admin.auth.admin.getUserById(account)).error, 'login still exists');
}
process.exit(status === 0 ? 0 : 1);
