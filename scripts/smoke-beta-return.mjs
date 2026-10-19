#!/usr/bin/env node
// Staging opt-in: real deletion -> public signup -> code verification, twice.
// Reserved .invalid addresses only. Signup may attempt SMTP to that nonexistent address;
// verification uses an Admin-generated code without delivering mail. No real user, paper, AI or credits.
import assert from 'node:assert/strict';
import {readFileSync, mkdirSync, writeFileSync} from 'node:fs';
import {randomBytes, randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';

const env = Object.fromEntries(readFileSync(new URL('../.env.staging', import.meta.url), 'utf8')
  .split('\n').filter(s => s.includes('=')).map(s => {const i=s.indexOf('='); return [s.slice(0,i),s.slice(i+1)];}));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {auth:{persistSession:false,autoRefreshToken:false}});
const evidence = {at:new Date().toISOString(), checks:[], realUserTouched:false, modelCalls:0};
const email = `beta-return-${randomUUID()}@example.invalid`, password = randomBytes(32).toString('base64url');
let account, session;
async function request(path, body, token) {
  const r = await fetch(env.SUPABASE_URL+'/'+path, {method:'POST', redirect:'error',
    headers:{'content-type':'application/json',apikey:env.SUPABASE_ANON_KEY,...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
  return {status:r.status,body:await r.json()};
}
async function verify() {
  const code=await admin.auth.admin.generateLink({type:'magiclink',email});
  assert.equal(code.error,null); assert.equal(code.data.user.id,account);
  const result=await request('auth/v1/verify',{email,token:code.data.properties.email_otp,type:'email'});
  assert.equal(result.status,200,'code exchange'); assert.equal(result.body.user.id,account);
  session=result.body;
  const keys=await request('rest/v1/rpc/v1_key_state',{p_device_id:randomUUID()},session.access_token);
  assert.equal(keys.status,200,'new account accepts a normal authenticated RPC');
}
try {
  const first=await admin.auth.admin.createUser({email,password,email_confirm:true});
  assert.equal(first.error,null); account=first.data.user.id; await verify();
  for (let cycle=1;cycle<=2;cycle++) {
    const oldID=account, oldSession=session;
    const deletion=await request('functions/v1/account-delete',{confirm:'delete my account'},oldSession.access_token);
    assert.equal(deletion.status,200); assert.equal(deletion.body.complete,true); account=null; session=null;
    assert.ok((await admin.auth.admin.getUserById(oldID)).error,'old login removed');
    const old=await request('rest/v1/rpc/v1_key_state',{p_device_id:randomUUID()},oldSession.access_token);
    assert.equal(old.status,403,'old token remains rejected');
    // This is the public entry point, not Admin createUser re-admitting the user.
    const signup=await request('auth/v1/signup',{email,password});
    evidence.checks.push({cycle,action:'public signup after deletion',status:signup.status,code:signup.body.error_code??signup.body.code??null});
    assert.equal(signup.status,200,`public signup refused: ${signup.body.error_code??signup.body.code??'unknown'}`);
    assert.match(signup.body.user?.id??signup.body.id??'',/^[0-9a-f-]{36}$/);
    account=signup.body.user?.id??signup.body.id; assert.notEqual(account,oldID);
    await verify();
    evidence.checks.push({cycle,action:'fresh UUID, verified login, account RPC, old token rejection',passed:true});
  }
} finally {
  if (account) {
    if (!session) await verify();
    const result=await request('functions/v1/account-delete',{confirm:'delete my account'},session.access_token);
    assert.equal(result.status,200); assert.equal(result.body.complete,true);
    evidence.syntheticLoginDeleted=true;
  }
  const folder='.artifacts/auth-lifecycle';mkdirSync(folder,{recursive:true});
  writeFileSync(`${folder}/${evidence.at.replace(/[:.]/g,'-')}-beta-return.json`,JSON.stringify(evidence,null,2)+'\n',{mode:0o600});
}
console.log(JSON.stringify(evidence));
