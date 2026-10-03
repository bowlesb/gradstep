#!/usr/bin/env node
// Synthetic staging integration check. No email, provider calls, or real data.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { chromium } from '@playwright/test';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(line => line.includes('=')).map(line => { const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1)]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const pat = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).trim();
const options = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, options);
const users = []; const attachmentID = randomUUID(); const reportID = randomUUID(); let browser;

async function sql(query) {
  const response = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}/database/query`, { method: 'POST', headers: { Authorization: `Bearer ${pat}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }) });
  assert.ok(response.ok, `fixture management SQL failed (${response.status})`);
  return response.json();
}
async function rpc(client, name, params = {}) { const { data, error } = await client.rpc(name, params); assert.equal(error?.code, undefined, `${name} rejected (${error?.code})`); return data; }
async function fixtureUser() {
  const email = `science-reader-support-${randomUUID()}@example.invalid`; const password = randomBytes(32).toString('base64url');
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.equal(error?.code, undefined, 'fixture user creation failed');
  const id = data.user.id; assert.match(id, /^[0-9a-f-]{36}$/); users.push(id);
  const client = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, options);
  const login = await client.auth.signInWithPassword({ email, password }); assert.equal(login.error, null, 'fixture sign-in failed');
  return { id, client, session: login.data.session };
}
async function asset(token, method = 'GET', body, id = attachmentID, expected = 200) {
  const url = new URL('/functions/v1/support-assets', env.SUPABASE_URL);
  url.searchParams.set('attachment_id', id); if (method === 'POST') url.searchParams.set('report_id', reportID);
  const response = await fetch(url, { method, body, headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY, ...(body ? { 'Content-Type': 'image/png' } : {}) } });
  assert.equal(response.status, expected, `${method} support asset returned ${response.status}, expected ${expected}`);
  return response;
}
function totp(secret) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of secret.toUpperCase().replaceAll('=', '')) { const n = alphabet.indexOf(c); assert.ok(n >= 0); bits += n.toString(2).padStart(5, '0'); }
  const key = Buffer.from(bits.match(/.{8}/g).map(b => parseInt(b, 2)));
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const mac = createHmac('sha1', key).update(counter).digest(); const offset = mac[19] & 15;
  return String((mac.readUInt32BE(offset) & 0x7fffffff) % 1000000).padStart(6, '0');
}

try {
  const a = await fixtureUser(); const b = await fixtureUser(); const c = await fixtureUser();
  await sql(`insert into app_private.app_roles(account_id,role) values('${b.id}','owner')`);
  await rpc(a.client, 'v1_create_report', { p_id: reportID, p_title: 'Synthetic screenshot workflow check', p_note: 'Integration fixture only: an equation is clipped in this example.', p_app_version: 'test', p_build: 'test', p_os_version: 'test', p_screen: 'paper' });
  const bytes = readFileSync(new URL('.artifacts/admin-signin.png', root));
  await asset(a.session.access_token, 'POST', bytes);
  await asset(a.session.access_token, 'POST', bytes);
  const returned = Buffer.from(await (await asset(a.session.access_token)).arrayBuffer());
  assert.equal(createHash('sha256').update(returned).digest('hex'), createHash('sha256').update(bytes).digest('hex'));
  const otherPixel = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNITvsIAALqAbsZhJbTAAAAAElFTkSuQmCC', 'base64');
  await asset(a.session.access_token, 'POST', otherPixel, attachmentID, 409);
  await asset(c.session.access_token, 'GET', undefined, attachmentID, 403);
  await asset(b.session.access_token, 'GET', undefined, attachmentID, 403);
  await asset(env.SUPABASE_ANON_KEY, 'GET', undefined, attachmentID, 401);
  const thread = await rpc(a.client, 'v1_report_thread', { p_report_id: reportID });
  assert.equal(thread.attachments.length, 1);
  const direct = await a.client.storage.from('support').download(`${a.id}/${attachmentID}.png`);
  assert.ok(direct.error, 'customer cannot bypass authorized image proxy');
  console.log('PASS hosted verified image upload, exact retry, conflict, private bucket, customer/MFA/anon isolation');

  const enrollment = await b.client.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Synthetic integration check' });
  assert.equal(enrollment.error, null, 'fixture MFA enrollment failed');
  const verified = await b.client.auth.mfa.challengeAndVerify({ factorId: enrollment.data.id, code: totp(enrollment.data.totp.secret) });
  assert.equal(verified.error, null, 'fixture MFA verification failed');
  const session = (await b.client.auth.getSession()).data.session;
  await asset(session.access_token);
  console.log('PASS verified operator can view only explicitly submitted screenshot data');

  browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.addInitScript(({ session }) => localStorage.setItem('science-reader.admin.staging', JSON.stringify(session)), { session });
  const page = await context.newPage();
  await page.goto('http://127.0.0.1:5173/');
  await page.getByRole('heading', { name: 'Overview', exact: true }).waitFor();
  await page.getByText('No provider budget is configured. Paid processing is disabled.').waitFor();
  await page.getByRole('heading', { name: 'Encrypted history storage', exact: true }).waitFor();
  await page.getByRole('heading', { name: 'History downloads this month', exact: true }).waitFor();
  assert.equal(await page.getByRole('progressbar', { name: 'Encrypted history storage used' }).getAttribute('max'), '536870912');
  assert.equal(await page.getByRole('progressbar', { name: 'History download allowance used' }).getAttribute('max'), '10737418240');
  await page.screenshot({ path: new URL('.artifacts/admin-overview.png', root).pathname, fullPage: true });
  await page.getByRole('button', { name: /^Support/ }).click();
  await page.getByRole('button', { name: /Synthetic screenshot workflow check/ }).click();
  const image = page.getByRole('img', { name: 'Screenshot shared by the reporter' });
  await image.waitFor();
  await image.evaluate(el => { if (!el.complete || !el.naturalWidth) return new Promise((resolve, reject) => { el.onload = resolve; el.onerror = reject; }); });
  let intercepted = false; const operationIDs = [];
  await page.route('**/rest/v1/rpc/v1_reply_to_report', async route => {
    operationIDs.push(route.request().postDataJSON().p_id);
    if (!intercepted) { intercepted = true; const response = await route.fetch(); assert.equal(response.status(), 200); await route.abort('failed'); }
    else await route.continue();
  });
  const message = 'Synthetic reply: verified private screenshot receipt and idempotent retry.';
  await page.getByLabel('Reply', { exact: true }).fill(message);
  await page.getByRole('button', { name: 'Send reply' }).click();
  await page.getByRole('alert').filter({ hasText: 'Your changes were not confirmed' }).waitFor();
  await page.getByRole('button', { name: 'Send reply' }).click();
  await page.locator('.messages').getByText(message, { exact: true }).waitFor();
  assert.equal(operationIDs.length, 2); assert.equal(operationIDs[0], operationIDs[1]);
  assert.equal((await rpc(a.client, 'v1_report_thread', { p_report_id: reportID })).messages.length, 1);
  await page.screenshot({ path: new URL('.artifacts/admin-support.png', root).pathname, fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: new URL('.artifacts/admin-support-mobile.png', root).pathname, fullPage: true });
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await page.getByRole('heading', { name: 'Administration', exact: true }).waitFor();
  assert.equal(await page.getByText(message, { exact: true }).count(), 0);
  console.log('PASS browser operator dashboard, private image, lost-response retry, mobile layout, sign-out boundary');
} finally {
  if (browser) await browser.close();
  if (users.length) {
    const removal = await admin.storage.from('support').remove([`${users[0]}/${attachmentID}.png`]);
    assert.equal(removal.error, null, 'fixture object cleanup failed');
    const ids = users.map(id => `'${id}'::uuid`).join(',');
    // No immutable status/audit/credit event is created by this check. Only the
    // exact synthetic accounts, report, object, and reply may be removed.
    await sql(`begin;
delete from app_private.support_attachments where report_id='${reportID}';
delete from app_private.attachment_uploads where report_id='${reportID}';
delete from app_private.stored_objects where id='${attachmentID}' and owner_id in (${ids});
delete from app_private.support_messages where report_id='${reportID}';
delete from app_private.support_reports where id='${reportID}' and account_id in (${ids});
delete from app_private.api_rate_windows where scope_id in (${users.map(id => `'${id}'`).join(',')});
delete from app_private.app_roles where account_id in (${ids});
delete from app_private.accounts where id in (${ids});
commit;`);
    for (const id of users) { const result = await admin.auth.admin.deleteUser(id); assert.equal(result.error, null, 'fixture Auth cleanup failed'); }
    console.log('Removed only this run’s synthetic accounts, report, reply, and image');
  }
}
