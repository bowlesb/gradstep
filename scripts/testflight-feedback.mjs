#!/usr/bin/env node
// TestFlight screenshot feedback for Science Reader through the App Store Connect API (scripts/asc.mjs).
// Usage: node scripts/testflight-feedback.mjs <out-dir> [--since=2026-10-25T00:00Z]
// Writes <out-dir>/feedback.json and saves each screenshot as <out-dir>/<created>-<n>.<ext> (Apple's URLs expire).
// In-app Report submissions are the other channel: staging app_private.support_reports.
import { asc } from './asc.mjs';
import { mkdirSync, writeFileSync } from 'node:fs';

const appId = '6819313864';
const out = process.argv[2];
if (!out) { console.error('usage: node scripts/testflight-feedback.mjs <out-dir> [--since=ISO]'); process.exit(2); }
const since = process.argv.find(arg => arg.startsWith('--since='))?.slice(8);
mkdirSync(out, { recursive: true });

let path = `/v1/apps/${appId}/betaFeedbackScreenshotSubmissions?limit=200&sort=-createdDate&include=build&fields[builds]=version`;
const all = [], builds = {};
while (path) {
  const response = await asc('GET', path);
  if (response.status !== 200) { console.error('status', response.status, JSON.stringify(response.body).slice(0, 300)); process.exit(1); }
  for (const included of response.body.included ?? []) builds[included.id] = included.attributes?.version;
  all.push(...response.body.data);
  const oldest = response.body.data.at(-1)?.attributes.createdDate;
  path = since && oldest && oldest < since ? null
    : response.body.links?.next?.replace('https://api.appstoreconnect.apple.com', '') ?? null;
}

const rows = all.filter(d => !since || d.attributes.createdDate >= since).map(d => ({
  id: d.id, created: d.attributes.createdDate, build: builds[d.relationships?.build?.data?.id] ?? null,
  device: d.attributes.deviceModel, os: d.attributes.osVersion, comment: d.attributes.comment ?? '',
  screenshots: (d.attributes.screenshots ?? []).map(s => s.url), files: [],
}));
for (const row of rows) {
  for (const [index, url] of row.screenshots.entries()) {
    const response = await fetch(url, { redirect: 'follow' });
    if (!response.ok) continue;
    const ext = (response.headers.get('content-type') ?? '').includes('png') ? 'png' : 'jpg';
    const file = `${row.created.replace(/[:.]/g, '-').slice(0, 19)}-${index}.${ext}`;
    writeFileSync(`${out}/${file}`, Buffer.from(await response.arrayBuffer()));
    row.files.push(file);
  }
}
writeFileSync(`${out}/feedback.json`, JSON.stringify(rows, null, 1));
for (const row of rows) {
  console.log(row.created.slice(0, 16), `b${row.build}`, row.device, '|', row.comment.replace(/\s+/g, ' '), '|', row.files.join(' '));
}
console.log('total', rows.length);
