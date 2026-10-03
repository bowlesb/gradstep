#!/usr/bin/env node
// Real staging Auth/RPC with two independently keyed native client contexts.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const root=new URL('../',import.meta.url);
const env=Object.fromEntries(readFileSync(new URL('.env.staging',root),'utf8').split('\n').filter(line=>line.includes('=')).map(line=>{const i=line.indexOf('=');return [line.slice(0,i),line.slice(i+1)];}));
assert.equal(env.SUPABASE_PROJECT_REF,'coxhjvqpflgxkleydati');
const pat=execFileSync('security',['find-generic-password','-s','Supabase CLI','-w'],{encoding:'utf8'}).trim();
const admin=createClient(env.SUPABASE_URL,env.SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
async function sql(query){const response=await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${pat}`,'Content-Type':'application/json'},body:JSON.stringify({query})});assert.ok(response.ok,'Sync fixture SQL failed');return response.json();}
const email=`science-reader-native-sync-${randomUUID()}@example.invalid`,password=randomBytes(36).toString('base64url');
let account;
try {
  const created=await admin.auth.admin.createUser({email,password,email_confirm:true});assert.equal(created.error,null);account=created.data.user.id;assert.match(account,/^[0-9a-f-]{36}$/);
  execFileSync('xcodegen',['generate'],{cwd:new URL('apps/apple/',root),stdio:'ignore'});
  const args=['-project','ScienceReader.xcodeproj','-scheme','ScienceReader','-configuration','Debug','-destination','platform=iOS Simulator,id=B6CD74CE-CB0C-417E-9E9B-F68175B5094D','-derivedDataPath','../../.artifacts/DerivedData','-resultBundlePath',`../../.artifacts/native-sync-${randomUUID()}.xcresult`,'-only-testing:ScienceReaderTests/LiveSyncTests','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','test'];
  const child=spawn('xcodebuild',args,{cwd:new URL('apps/apple/',root),env:{...process.env,TEST_RUNNER_SCIENCE_READER_LIVE_EMAIL:email,TEST_RUNNER_SCIENCE_READER_LIVE_PASSWORD:password,TEST_RUNNER_SCIENCE_READER_LIVE_ACCOUNT:account},stdio:['ignore','pipe','pipe']});
  let log='';child.stdout.on('data',bytes=>{log+=bytes;});child.stderr.on('data',bytes=>{log+=bytes;});
  const status=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});
  log=log.replaceAll(password,'[redacted]').replaceAll(email,'native-sync-fixture@example.invalid');
  writeFileSync(new URL('.artifacts/native-sync-live.log',root),log,{mode:0o600});
  assert.equal(status,0,'Native sync check failed; inspect local log');
  assert.match(log,/testTwoDeviceRecoveryOfflineEditsAndLostAcknowledgment.*passed/,'Native sync check did not run');
  const rows=await sql(`select count(*)::int as devices,min(acknowledged_cursor)::int as acknowledged from app_private.devices where account_id='${account}'`);
  assert.equal(rows[0].devices,2);assert.equal(rows[0].acknowledged,7);
  console.log('PASS hosted native two-device key recovery, concurrent offline edits, exact ciphertext replay, missed acknowledgment recovery, byte-bounded pagination, and durable device cursors');
} finally {
  if(account){
    // This check creates no immutable rotation/billing/audit events. Such future
    // checks require an isolated fixture lifecycle, not disabling audit triggers.
    const transitions=await sql(`select count(*)::int as count from app_private.key_transitions where account_id='${account}'`);
    assert.equal(transitions[0].count,0,'Unexpected immutable event; automatic fixture purge refused');
    await sql(`begin;
delete from app_private.sync_events where account_id='${account}';
delete from app_private.enrollment_requests where account_id='${account}';
delete from app_private.device_envelopes where account_id='${account}';
delete from app_private.devices where account_id='${account}';
delete from app_private.keyrings where account_id='${account}';
delete from app_private.accounts where id='${account}';
commit;`);
    const removed=await admin.auth.admin.deleteUser(account);assert.equal(removed.error,null);
    const counters=await sql('select ciphertext_bytes=(select coalesce(sum(octet_length(ciphertext)),0) from app_private.sync_events) and event_count=(select count(*) from app_private.sync_events) as reconciled from app_private.sync_environment_storage');
    assert.equal(counters[0].reconciled,true,'Storage counters must reconcile after fixture cleanup');
    console.log('Removed the synthetic sync account, device envelopes, enrollment, and encrypted events');
  }
}
