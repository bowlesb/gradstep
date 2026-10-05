#!/usr/bin/env node
// Creates (idempotently) the App Store products approved on 2026-10-05 in App
// Store Connect, and points sandbox server notifications at staging:
//   Plans group: Standard $9.99/month (800 credits), Pro $19.99/month (1,800)
//   Consumable: 400 credits, $4.99 (never expire)
// Beta scope: United States pricing and availability. Credits per product live in
// migration 018 (app_private.store_products); keep the two in step.
// Usage: node scripts/setup-store-products.mjs [--dry-run] [--review-screenshot=PNG [--replace-screenshots]]
// (App Review needs a screenshot of the purchase screen; products without one stay
// MISSING_METADATA and are not offered in the sandbox.)
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { asc } from './asc.mjs';

const APP = '6819313864', TERRITORY = 'USA';
const dry = process.argv.includes('--dry-run');
const screenshot = process.argv.find(a => a.startsWith('--review-screenshot='))?.split('=')[1];
const replaceScreenshots = process.argv.includes('--replace-screenshots');
const root = new URL('../', import.meta.url);
const staging = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
const REVIEW_NOTE = 'Credits pay for converting papers and for AI answers about them. Purchases require signing in; '
  + 'the account is linked to the purchase on our server.';
const SUBSCRIPTIONS = [
  { productId: 'com.sciencereader.ios.pro.monthly', name: 'Pro Monthly', level: 1, price: '19.99', display: 'Pro', description: '1,800 AI credits each month' },
  { productId: 'com.sciencereader.ios.standard.monthly', name: 'Standard Monthly', level: 2, price: '9.99', display: 'Standard', description: '800 AI credits each month' },
];
const PACK = { productId: 'com.sciencereader.ios.credits.400', name: '400 Credits', price: '4.99', display: '400 Credits', description: '400 AI credits that never expire' };

async function call(method, path, body) {
  if (dry && method !== 'GET') { console.log('[dry-run]', method, path); return { status: 0, body: { data: { id: 'dry' } } }; }
  const result = await asc(method, path, body);
  if (result.status >= 300) throw new Error(`${method} ${path} → ${result.status} ${JSON.stringify(result.body?.errors ?? result.body).slice(0, 600)}`);
  return result;
}
async function all(path) {
  const items = []; let next = path;
  while (next) {
    const page = await call('GET', next);
    items.push(...page.body.data);
    next = page.body.links?.next ? page.body.links.next.replace('https://api.appstoreconnect.apple.com', '') : null;
  }
  return items;
}
const rel = (type, id) => ({ data: { type, id } });

// The app itself: free, offered in the beta territory (subscriptions need the app's
// pricing and availability before they are complete). Change before public release.
if (!dry && (await asc('GET', `/v1/apps/${APP}/appPriceSchedule`)).status === 404) {
  const points = await all(`/v1/apps/${APP}/appPricePoints?filter[territory]=${TERRITORY}&limit=200`);
  const free = points.find(p => Number(p.attributes.customerPrice) === 0);
  assert.ok(free, 'no free price point');
  await call('POST', '/v1/appPriceSchedules', { data: { type: 'appPriceSchedules', relationships: { app: rel('apps', APP),
    baseTerritory: rel('territories', TERRITORY), manualPrices: { data: [{ type: 'appPrices', id: '${free}' }] } } },
    included: [{ type: 'appPrices', id: '${free}', attributes: { startDate: null }, relationships: { appPricePoint: rel('appPricePoints', free.id) } }] });
  console.log('app price: free');
}
if (!dry && (await asc('GET', `/v1/apps/${APP}/appAvailabilityV2`)).status === 404) {
  // Every territory is listed; only the beta territory is available.
  const territories = await all('/v1/territories?limit=200');
  await call('POST', '/v2/appAvailabilities', { data: { type: 'appAvailabilities', attributes: { availableInNewTerritories: false },
    relationships: { app: rel('apps', APP), territoryAvailabilities: { data: territories.map(t => ({ type: 'territoryAvailabilities', id: `\${${t.id}}` })) } } },
    included: territories.map(t => ({ type: 'territoryAvailabilities', id: `\${${t.id}}`, attributes: { available: t.id === TERRITORY },
      relationships: { territory: rel('territories', t.id) } })) });
  console.log('app availability:', TERRITORY);
}

// Subscription group.
let group = (await all(`/v1/apps/${APP}/subscriptionGroups`)).find(g => g.attributes.referenceName === 'Plans');
if (!group) {
  group = (await call('POST', '/v1/subscriptionGroups', { data: { type: 'subscriptionGroups', attributes: { referenceName: 'Plans' },
    relationships: { app: rel('apps', APP) } } })).body.data;
  console.log('created group Plans', group.id);
}
if (!dry && !(await all(`/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations`)).some(l => l.attributes.locale === 'en-US')) {
  await call('POST', '/v1/subscriptionGroupLocalizations', { data: { type: 'subscriptionGroupLocalizations',
    attributes: { name: 'Plans', locale: 'en-US' }, relationships: { subscriptionGroup: rel('subscriptionGroups', group.id) } } });
  console.log('group localization');
}

const existingSubscriptions = dry ? [] : await all(`/v1/subscriptionGroups/${group.id}/subscriptions`);
for (const plan of SUBSCRIPTIONS) {
  let sub = existingSubscriptions.find(s => s.attributes.productId === plan.productId);
  if (!sub) {
    sub = (await call('POST', '/v1/subscriptions', { data: { type: 'subscriptions', attributes: { name: plan.name, productId: plan.productId,
      familySharable: false, subscriptionPeriod: 'ONE_MONTH', groupLevel: plan.level, reviewNote: REVIEW_NOTE,
      marketSettings: ['APP_STORE'], multiSeatStatus: 'DISABLED' },
      relationships: { group: rel('subscriptionGroups', group.id) } } })).body.data;
    console.log('created', plan.productId, sub.id);
  }
  if (dry) continue;
  if (!(await all(`/v1/subscriptions/${sub.id}/subscriptionLocalizations`)).some(l => l.attributes.locale === 'en-US')) {
    await call('POST', '/v1/subscriptionLocalizations', { data: { type: 'subscriptionLocalizations',
      attributes: { name: plan.display, locale: 'en-US', description: plan.description }, relationships: { subscription: rel('subscriptions', sub.id) } } });
    console.log('  localization');
  }
  // Availability first: Apple refuses a price for a territory the product is not offered in.
  const availability = await asc('GET', `/v1/subscriptions/${sub.id}/subscriptionAvailability`);
  if (availability.status !== 200 || !availability.body?.data) {
    await call('POST', '/v1/subscriptionAvailabilities', { data: { type: 'subscriptionAvailabilities', attributes: { availableInNewTerritories: false },
      relationships: { subscription: rel('subscriptions', sub.id), availableTerritories: { data: [{ type: 'territories', id: TERRITORY }] } } } });
    console.log('  availability', TERRITORY);
  }
  const prices = await all(`/v1/subscriptions/${sub.id}/prices?filter[territory]=${TERRITORY}&include=subscriptionPricePoint`);
  if (!prices.length) {
    const points = await all(`/v1/subscriptions/${sub.id}/pricePoints?filter[territory]=${TERRITORY}&limit=200`);
    const point = points.find(p => p.attributes.customerPrice === plan.price);
    assert.ok(point, `no ${plan.price} price point`);
    await call('POST', '/v1/subscriptionPrices', { data: { type: 'subscriptionPrices', attributes: { preserveCurrentPrice: false },
      relationships: { subscription: rel('subscriptions', sub.id), subscriptionPricePoint: rel('subscriptionPricePoints', point.id), territory: rel('territories', TERRITORY) } } });
    console.log('  price', plan.price);
  }
}

// Consumable pack.
let pack = dry ? null : (await all(`/v1/apps/${APP}/inAppPurchasesV2`)).find(p => p.attributes.productId === PACK.productId);
if (!pack) {
  pack = (await call('POST', '/v2/inAppPurchases', { data: { type: 'inAppPurchases', attributes: { name: PACK.name, productId: PACK.productId,
    inAppPurchaseType: 'CONSUMABLE', reviewNote: REVIEW_NOTE, familySharable: false }, relationships: { app: rel('apps', APP) } } })).body.data;
  console.log('created', PACK.productId, pack.id);
}
if (!dry) {
  if (!(await all(`/v2/inAppPurchases/${pack.id}/inAppPurchaseLocalizations`)).some(l => l.attributes.locale === 'en-US')) {
    await call('POST', '/v1/inAppPurchaseLocalizations', { data: { type: 'inAppPurchaseLocalizations',
      attributes: { name: PACK.display, locale: 'en-US', description: PACK.description }, relationships: { inAppPurchaseV2: rel('inAppPurchases', pack.id) } } });
    console.log('  localization');
  }
  const availability = await asc('GET', `/v2/inAppPurchases/${pack.id}/inAppPurchaseAvailability`);
  if (availability.status !== 200 || !availability.body?.data) {
    await call('POST', '/v1/inAppPurchaseAvailabilities', { data: { type: 'inAppPurchaseAvailabilities', attributes: { availableInNewTerritories: false },
      relationships: { inAppPurchase: rel('inAppPurchases', pack.id), availableTerritories: { data: [{ type: 'territories', id: TERRITORY }] } } } });
    console.log('  availability', TERRITORY);
  }
  const schedule = await asc('GET', `/v2/inAppPurchases/${pack.id}/iapPriceSchedule?include=manualPrices`);
  if (schedule.status !== 200 || !(schedule.body?.included ?? []).length) {
    const points = await all(`/v2/inAppPurchases/${pack.id}/pricePoints?filter[territory]=${TERRITORY}&limit=200`);
    const point = points.find(p => p.attributes.customerPrice === PACK.price);
    assert.ok(point, `no ${PACK.price} price point`);
    await call('POST', '/v1/inAppPurchasePriceSchedules', { data: { type: 'inAppPurchasePriceSchedules', relationships: {
      inAppPurchase: rel('inAppPurchases', pack.id), baseTerritory: rel('territories', TERRITORY),
      manualPrices: { data: [{ type: 'inAppPurchasePrices', id: '${price}' }] } } },
      included: [{ type: 'inAppPurchasePrices', id: '${price}', attributes: { startDate: null },
        relationships: { inAppPurchasePricePoint: rel('inAppPurchasePricePoints', point.id) } }] });
    console.log('  price', PACK.price);
  }
}

// App Review screenshots (reserve, upload the parts, commit with the checksum).
async function reviewScreenshot(kind, owner, ownerType, relationship, existingPath) {
  if (!screenshot || dry) return;
  const existing = await asc('GET', existingPath);
  if (existing.status === 200 && existing.body?.data) {
    if (!replaceScreenshots) return;
    await call('DELETE', `/v1/${kind}/${existing.body.data.id}`);
  }
  const bytes = readFileSync(screenshot);
  const reserved = (await call('POST', `/v1/${kind}`, { data: { type: kind, attributes: { fileName: basename(screenshot), fileSize: bytes.length },
    relationships: { [relationship]: rel(ownerType, owner) } } })).body.data;
  for (const part of reserved.attributes.uploadOperations) {
    const response = await fetch(part.url, { method: part.method, headers: Object.fromEntries(part.requestHeaders.map(h => [h.name, h.value])),
      body: bytes.subarray(part.offset, part.offset + part.length) });
    assert.ok(response.ok, `upload part ${response.status}`);
  }
  await call('PATCH', `/v1/${kind}/${reserved.id}`, { data: { type: kind, id: reserved.id,
    attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(bytes).digest('hex') } } });
  console.log('review screenshot', ownerType, owner);
}
if (!dry) {
  for (const sub of await all(`/v1/subscriptionGroups/${group.id}/subscriptions`)) {
    await reviewScreenshot('subscriptionAppStoreReviewScreenshots', sub.id, 'subscriptions', 'subscription', `/v1/subscriptions/${sub.id}/appStoreReviewScreenshot`);
  }
  await reviewScreenshot('inAppPurchaseAppStoreReviewScreenshots', pack.id, 'inAppPurchases', 'inAppPurchaseV2', `/v2/inAppPurchases/${pack.id}/appStoreReviewScreenshot`);
}

// Sandbox server notifications → staging (V2). Production stays unset until a production backend exists.
const url = `${staging.SUPABASE_URL}/functions/v1/app-store-notifications`;
const app = (await call('GET', `/v1/apps/${APP}?fields[apps]=subscriptionStatusUrlForSandbox,subscriptionStatusUrlVersionForSandbox`)).body.data;
if (app.attributes.subscriptionStatusUrlForSandbox !== url || app.attributes.subscriptionStatusUrlVersionForSandbox !== 'V2') {
  await call('PATCH', `/v1/apps/${APP}`, { data: { type: 'apps', id: APP, attributes: { subscriptionStatusUrlForSandbox: url, subscriptionStatusUrlVersionForSandbox: 'V2' } } });
  console.log('sandbox notifications →', url);
}
console.log('done');
