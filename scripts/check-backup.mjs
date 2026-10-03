#!/usr/bin/env node
// A synthetic hosted checkpoint -> encrypted archive -> quarantined local restore.
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { hex, sha256, encode, seal, eventAAD, recoveryKey, recoveryAAD, publicBytes, wrapDevice } from '../tests/backend/wire-crypto.mjs';

const root=new URL('../',import.meta.url);
const env=Object.fromEntries(readFileSync(new URL('.env.staging',root),'utf8').split('\n').filter(line=>line.includes('=')).map(line=>{const i=line.indexOf('=');return [line.slice(0,i),line.slice(i+1)];}));
assert.equal(env.SUPABASE_PROJECT_REF,'coxhjvqpflgxkleydati');
const pat=execFileSync('security',['find-generic-password','-s','Supabase CLI','-w'],{encoding:'utf8'}).trim();
const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}};
const admin=createClient(env.SUPABASE_URL,env.SUPABASE_SERVICE_ROLE_KEY,options);
const client=createClient(env.SUPABASE_URL,env.SUPABASE_ANON_KEY,options);
let account, checkpoint;
const report=randomUUID(), attachment=randomUUID(), device=randomUUID(), event=randomUUID();
const note='Synthetic restore drill: verify the screenshot, note, account mapping, and opaque encrypted event.';
const image=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNITvsIAALqAbsZhJbTAAAAAElFTkSuQmCC','base64');
async function sql(query){const response=await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${pat}`,'Content-Type':'application/json'},body:JSON.stringify({query})});assert.ok(response.ok,`fixture SQL failed (${response.status})`);return response.json();}
async function rpc(name,params){const {data,error}=await client.rpc(name,params);assert.equal(error?.code,undefined,`${name} failed (${error?.code})`);return data;}
try {
  const email=`science-reader-backup-${randomUUID()}@example.invalid`,password=randomBytes(32).toString('base64url');
  const user=await admin.auth.admin.createUser({email,password,email_confirm:true});assert.equal(user.error,null);account=user.data.user.id;
  assert.match(account,/^[0-9a-f-]{36}$/);
  const login=await client.auth.signInWithPassword({email,password});assert.equal(login.error,null);
  const management=randomBytes(32), content=randomBytes(32), rawPrivate=randomBytes(32), challenge=randomBytes(32), code=randomBytes(32).toString('hex');
  const bundle={accountID:account.toUpperCase(),epoch:1,contentKeys:{'1':content.toString('base64')},managementToken:management.toString('base64')};
  await rpc('v1_bootstrap_keys',{p_device_id:device,p_public_key:hex(publicBytes(rawPrivate)),p_recovery_package:hex(seal(recoveryKey(code,account),encode(bundle),recoveryAAD(account))),p_management_token:hex(management),p_device_envelope:hex(wrapDevice(bundle,device,publicBytes(rawPrivate),challenge)),p_challenge:hex(challenge)});
  const payload={kind:'message',entityID:randomUUID().toUpperCase(),parents:[],conversationID:randomUUID().toUpperCase(),text:'Synthetic encrypted research question — ∑ attention.',role:'user',status:'complete'};
  const ciphertext=seal(content,encode(payload),eventAAD(account,event,device));
  await rpc('v1_append_event',{p_device_id:device,p_id:event,p_epoch:1,p_format:1,p_ciphertext:hex(ciphertext),p_management_token:hex(management)});
  await rpc('v1_create_report',{p_id:report,p_title:'Synthetic backup check',p_note:note,p_app_version:'test',p_build:'test',p_os_version:'test',p_screen:'paper'});
  const url=new URL('/functions/v1/support-assets',env.SUPABASE_URL);url.searchParams.set('report_id',report);url.searchParams.set('attachment_id',attachment);
  const upload=await fetch(url,{method:'POST',headers:{Authorization:`Bearer ${login.data.session.access_token}`,apikey:env.SUPABASE_ANON_KEY,'Content-Type':'image/png'},body:image});assert.equal(upload.status,200);
  const exported=JSON.parse(execFileSync('python3',['scripts/backup.py','staging'],{cwd:root,encoding:'utf8',timeout:180000}));
  checkpoint=exported.checkpoint;assert.equal(exported.objects>=1,true);
  const fixture={account,report,attachment,event,note,ciphertext:ciphertext.toString('hex'),image_sha256:sha256(image).toString('hex')};
  const restored=JSON.parse(execFileSync('python3',['scripts/restore-local.py',checkpoint,'--fixture-stdin'],{cwd:root,input:JSON.stringify(fixture),encoding:'utf8',timeout:180000}));
  assert.equal(restored.restored,true);console.log('PASS signed encrypted database + object checkpoint, local restore, row counts, ciphertext, screenshot, RLS, worker quarantine');
  // Corrupt only a copy of this synthetic checkpoint; the valid backup survives.
  const bad=mkdtempSync(new URL('.artifacts/backup-corrupt-',root).pathname);
  try {
    cpSync(new URL(checkpoint+'/',root).pathname,bad,{recursive:true});
    const manifest=new URL('manifest.json.age',new URL('file://'+bad+'/'));
    const bytes=readFileSync(manifest);bytes[bytes.length-1]^=1;writeFileSync(manifest,bytes);
    const rejected=spawnSync('python3',['scripts/restore-local.py',bad],{cwd:root,encoding:'utf8'});
    assert.notEqual(rejected.status,0);assert.match(rejected.stderr,/InvalidSignature/);
    console.log('PASS changed backup manifest rejected before decryption or SQL execution');
  } finally {rmSync(bad,{recursive:true,force:true});}
  console.log(JSON.stringify({checkpoint,restore_seconds:restored.seconds,objects:restored.objects}));
} finally {
  if(account){
    const removal=await admin.storage.from('support').remove([`${account}/${attachment}.png`]);assert.equal(removal.error,null);
    await sql(`begin;
delete from app_private.support_attachments where report_id='${report}' and account_id='${account}';
delete from app_private.attachment_uploads where report_id='${report}' and account_id='${account}';
delete from app_private.stored_objects where id='${attachment}' and owner_id='${account}';
delete from app_private.support_reports where id='${report}' and account_id='${account}';
delete from app_private.api_rate_windows where scope_id='${account}';
delete from app_private.sync_events where account_id='${account}';
delete from app_private.device_envelopes where account_id='${account}';
delete from app_private.devices where account_id='${account}';
delete from app_private.keyrings where account_id='${account}';
delete from app_private.accounts where id='${account}';
commit;`);
    const result=await admin.auth.admin.deleteUser(account);assert.equal(result.error,null);
    console.log('Removed this run’s synthetic hosted account, history, report, and image');
  }
}
