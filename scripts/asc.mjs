#!/usr/bin/env node
// Minimal App Store Connect API client for Science Reader (dedicated key in
// .env.appstore; the .p8 never leaves secrets/). Usage: node scripts/asc.mjs GET /v1/apps?filter[bundleId]=...
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.appstore', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
const key = createPrivateKey(readFileSync(new URL(env.ASC_KEY_PATH, root)));
const b64 = value => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');
export function token() {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64({ alg: 'ES256', kid: env.ASC_KEY_ID, typ: 'JWT' })}.${b64({ iss: env.ASC_ISSUER_ID, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })}`;
  const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${signature.toString('base64url')}`;
}
export async function asc(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, { method, redirect: 'error',
    headers: { Authorization: `Bearer ${token()}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}
if (import.meta.url === `file://${process.argv[1]}`) {
  const [method, path] = process.argv.slice(2);
  const result = await asc(method, path);
  console.log(result.status, JSON.stringify(result.body, null, 1).slice(0, 4000));
}
