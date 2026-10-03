#!/usr/bin/env node
// Signed simulator + real staging. Credentials exist only for this disposable
// unprivileged account and are passed through the test runner's environment.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(line => line.includes('=')).map(line => { const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1)]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const pat = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).trim();
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
async function sql(query) {
  const response = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}/database/query`, { method: 'POST', headers: { Authorization: `Bearer ${pat}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }) });
  assert.ok(response.ok, 'fixture management SQL failed'); return response.json();
}
const email = `science-reader-native-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
let id;
try {
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.equal(created.error, null, 'native fixture account creation failed'); id = created.data.user.id; assert.match(id, /^[0-9a-f-]{36}$/);
  execFileSync('xcodegen', ['generate'], { cwd: new URL('apps/apple/', root), stdio: 'ignore' });
  const args = ['-project','ScienceReader.xcodeproj','-scheme','ScienceReader','-configuration','Debug','-destination','platform=iOS Simulator,id=B6CD74CE-CB0C-417E-9E9B-F68175B5094D','-derivedDataPath','../../.artifacts/DerivedData','-resultBundlePath',`../../.artifacts/native-support-${randomUUID()}.xcresult`,'-only-testing:ScienceReaderTests/LiveSupportTests','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','test'];
  const child = spawn('xcodebuild', args, { cwd: new URL('apps/apple/', root), env: { ...process.env,
    TEST_RUNNER_SCIENCE_READER_LIVE_EMAIL: email, TEST_RUNNER_SCIENCE_READER_LIVE_PASSWORD: password, TEST_RUNNER_SCIENCE_READER_LIVE_ACCOUNT: id,
  }, stdio: ['ignore','pipe','pipe'] });
  let log = ''; child.stdout.on('data', bytes => { log += bytes; }); child.stderr.on('data', bytes => { log += bytes; });
  const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
  // Strip fixture credentials even from the ignored local test log.
  log = log.replaceAll(password, '[redacted]').replaceAll(email, 'native-fixture@example.invalid');
  writeFileSync(new URL('.artifacts/native-support-live.log', root), log, { mode: 0o600 });
  assert.equal(code, 0, 'Native support check failed; inspect the local test log');
  assert.match(log, /testPrivateReportRoundTripAgainstStaging.*passed/, 'Native check was skipped or did not run');
  console.log('PASS signed native Auth, encrypted report outbox, private screenshot upload/download, exact retries and reply round trip');
} finally {
  if (id) {
    const objects = await sql(`select path from app_private.stored_objects where owner_id='${id}' and bucket='support'`);
    if (objects.length) { const result = await admin.storage.from('support').remove(objects.map(item => item.path)); assert.equal(result.error, null, 'native fixture object cleanup failed'); }
    await sql(`begin;
delete from app_private.support_attachments where account_id='${id}';
delete from app_private.attachment_uploads where account_id='${id}';
delete from app_private.stored_objects where owner_id='${id}' and bucket='support';
delete from app_private.support_messages where report_id in (select id from app_private.support_reports where account_id='${id}');
delete from app_private.support_reports where account_id='${id}';
delete from app_private.api_rate_windows where scope_id='${id}';
delete from app_private.accounts where id='${id}';
commit;`);
    const deleted = await admin.auth.admin.deleteUser(id); assert.equal(deleted.error, null, 'native fixture Auth cleanup failed');
    console.log('Removed the native fixture account, report, image, and reply');
  }
}
