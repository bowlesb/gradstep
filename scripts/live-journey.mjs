#!/usr/bin/env node
// Full staging journey on the iPhone Simulator: synthetic account → recorded
// operator credit grant → add arXiv paper → paid conversion → download →
// offline reader (→ optional paid question) → relaunch. Costs are capped by
// the database platform budget. The synthetic account is kept for inspection.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const args = Object.fromEntries(process.argv.slice(2).map(a => a.replace(/^--/, '').split('=')));
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
execFileSync('xcodegen', ['generate'], { cwd: new URL('apps/apple/', root), stdio: 'ignore' });
// Start from a clean install: the Keychain session of an earlier synthetic
// account must not carry into this run.
try { execFileSync('xcrun', ['simctl', 'uninstall', device, 'com.sciencereader.ios'], { stdio: 'ignore' }); } catch { /* not installed */ }
// Keychain items survive app deletion on the Simulator; reset them too.
try { execFileSync('xcrun', ['simctl', 'keychain', device, 'reset'], { stdio: 'ignore' }); } catch { /* older simctl */ }
const result = `../../.artifacts/live-journey-${account}.xcresult`;
const xcode = ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug', '-destination', `platform=iOS Simulator,id=${device}`,
  '-derivedDataPath', '../../.artifacts/lead-derived', '-resultBundlePath', result, '-only-testing:ScienceReaderUITests/LiveJourneyTests',
  'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'test'];
const child = spawn('xcodebuild', xcode, { cwd: new URL('apps/apple/', root), stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env,
  TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_EMAIL: email, TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_PASSWORD: password,
  TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_ARXIV: arxiv, TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_TITLE: title,
  ...(args.question ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_QUESTION: args.question } : {}),
  ...(args.search ? { TEST_RUNNER_SCIENCE_READER_LIVE_JOURNEY_SEARCH: args.search } : {}) } });
let log = ''; child.stdout.on('data', b => { log += b; }); child.stderr.on('data', b => { log += b; });
const status = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
log = log.replaceAll(password, '[redacted]');
// Leave the Simulator signed out for other test suites.
try { execFileSync('xcrun', ['simctl', 'uninstall', device, 'com.sciencereader.ios'], { stdio: 'ignore' }); } catch {}
try { execFileSync('xcrun', ['simctl', 'keychain', device, 'reset'], { stdio: 'ignore' }); } catch {}
writeFileSync(new URL(`.artifacts/live-journey-${account}.log`, root), log, { mode: 0o600 });
console.log(log.split('\n').filter(l => /Test Case|error:|failed|passed|TEST (SUCCEEDED|FAILED)/.test(l)).slice(-25).join('\n'));
console.log('Result bundle:', result.replace('../../', ''));
process.exit(status === 0 ? 0 : 1);
