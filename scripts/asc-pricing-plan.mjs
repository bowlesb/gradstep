#!/usr/bin/env node
// The App Store Connect changes for the accepted pricing (owner, 2026-10-22; docs/PRICING_HOW_IT_WORKS.md §App Store).
// Server allowances live in migration 0150 (app_private.store_products); keep the two in step.
//
//   node scripts/asc-pricing-plan.mjs                      read-only: what exists now, and each change still to make
//   node scripts/asc-pricing-plan.mjs --apply --owner-approved=YYYY-MM-DD
//                                                          makes the API changes below (only after the owner approves)
//
// Nothing here is run automatically. `--apply` needs the owner's approval date and refuses Production-affecting steps
// that Apple only offers in the web UI (listed as MANUAL). Beta scope: United States prices and availability only.
import assert from 'node:assert/strict';
import { asc } from './asc.mjs';

const APP = '6819313864', TERRITORY = 'USA';
const apply = process.argv.includes('--apply');
const approved = process.argv.find(a => a.startsWith('--owner-approved='))?.split('=')[1];
if (apply && !/^20[2-9]\d-\d\d-\d\d$/.test(approved ?? '')) {
  console.error('--apply needs --owner-approved=YYYY-MM-DD (the date the owner approved this plan).'); process.exit(2);
}
const REVIEW_NOTE = 'Credits pay for AI answers about papers. Purchases require signing in; the account is linked to the purchase on our server.';
// Group levels: Pro (both periods) above Plus (both periods), so Plus → Pro is an upgrade and monthly ↔ yearly a crossgrade.
const SUBSCRIPTIONS = [
  { productId: 'com.sciencereader.ios.pro.monthly', name: 'Pro Monthly', period: 'ONE_MONTH', level: 1, price: '19.99', display: 'Pro', description: '2,000 AI credits each month' },
  { productId: 'com.sciencereader.ios.pro.annual', name: 'Pro Yearly', period: 'ONE_YEAR', level: 1, price: '199.99', display: 'Pro (yearly)', description: '2,000 AI credits each month, billed yearly' },
  { productId: 'com.sciencereader.ios.standard.monthly', name: 'Standard Monthly', period: 'ONE_MONTH', level: 2, price: '7.99', display: 'Plus', description: '600 AI credits each month',
    intro: { mode: 'PAY_UP_FRONT', duration: 'ONE_MONTH', periods: 1, price: '3.99' } },
  { productId: 'com.sciencereader.ios.standard.annual', name: 'Plus Yearly', period: 'ONE_YEAR', level: 2, price: '79.99', display: 'Plus (yearly)', description: '600 AI credits each month, billed yearly' },
];
const PACKS = [
  { productId: 'com.sciencereader.ios.credits.300', name: '300 Credits', price: '4.99', display: '300 Credits', description: '300 AI credits that never expire' },
  { productId: 'com.sciencereader.ios.credits.700', name: '700 Credits', price: '9.99', display: '700 Credits', description: '700 AI credits that never expire' },
];
const RETIRED_PACK = 'com.sciencereader.ios.credits.400';
const MANUAL = [
  `Remove ${RETIRED_PACK} from sale (App Store Connect › Gradstep › In-App Purchases › 400 Credits › Availability: remove all territories). The server keeps recording it, so earlier buyers can restore.`,
  'Enroll in the App Store Small Business Program (developer.apple.com/app-store/small-business-program; 15% commission) before the first Production sale.',
  'Add an App Review screenshot of the Get credits sheet to each new product (node scripts/setup-store-products.mjs --review-screenshot=PNG covers the old ones; upload the same image for the new ones in the web UI).',
  'Submit the new products with the next app version (version page › In-App Purchases and Subscriptions › select all six).',
  'Price decrease for Standard Monthly: Apple applies a lower price to existing subscribers at their next renewal; no consent is needed.',
];

const rel = (type, id) => ({ data: { type, id } });
const steps = [];
const plan = (text, run) => steps.push({ text, run });
async function get(path) { const r = await asc('GET', path); return r.status === 200 ? r.body : null; }
async function all(path) {
  const items = []; let next = path;
  while (next) { const page = await asc('GET', next); assert.equal(page.status, 200, `GET ${next} → ${page.status}`); items.push(...page.body.data);
    next = page.body.links?.next ? page.body.links.next.replace('https://api.appstoreconnect.apple.com', '') : null; }
  return items;
}
async function call(method, path, body) {
  const result = await asc(method, path, body);
  if (result.status >= 300) throw new Error(`${method} ${path} → ${result.status} ${JSON.stringify(result.body?.errors ?? result.body).slice(0, 600)}`);
  return result.body;
}

const group = (await all(`/v1/apps/${APP}/subscriptionGroups`)).find(g => g.attributes.referenceName === 'Plans');
assert.ok(group, 'subscription group Plans not found (scripts/setup-store-products.mjs creates it)');
const subscriptions = await all(`/v1/subscriptionGroups/${group.id}/subscriptions`);
console.log('Subscription group Plans:', group.id);
for (const plan_ of SUBSCRIPTIONS) {
  const sub = subscriptions.find(s => s.attributes.productId === plan_.productId);
  if (!sub) {
    console.log(`  ${plan_.productId}: missing`);
    plan(`Create ${plan_.productId} (${plan_.period}, level ${plan_.level}, "${plan_.display}", $${plan_.price}, ${TERRITORY})`, async () => {
      const created = (await call('POST', '/v1/subscriptions', { data: { type: 'subscriptions', attributes: { name: plan_.name, productId: plan_.productId,
        familySharable: false, subscriptionPeriod: plan_.period, groupLevel: plan_.level, reviewNote: REVIEW_NOTE },
        relationships: { group: rel('subscriptionGroups', group.id) } } })).data;
      await call('POST', '/v1/subscriptionLocalizations', { data: { type: 'subscriptionLocalizations',
        attributes: { name: plan_.display, locale: 'en-US', description: plan_.description }, relationships: { subscription: rel('subscriptions', created.id) } } });
      await call('POST', '/v1/subscriptionAvailabilities', { data: { type: 'subscriptionAvailabilities', attributes: { availableInNewTerritories: false },
        relationships: { subscription: rel('subscriptions', created.id), availableTerritories: { data: [{ type: 'territories', id: TERRITORY }] } } } });
      await setPrice(created.id, plan_.price);
      if (plan_.intro) await setIntro(created.id, plan_.intro);
    });
    continue;
  }
  const local = (await all(`/v1/subscriptions/${sub.id}/subscriptionLocalizations`)).find(l => l.attributes.locale === 'en-US');
  const priceBody = await get(`/v1/subscriptions/${sub.id}/prices?filter[territory]=${TERRITORY}&include=subscriptionPricePoint`);
  const current = (priceBody?.included ?? []).map(p => p.attributes.customerPrice);
  const intro = await all(`/v1/subscriptions/${sub.id}/introductoryOffers`).catch(() => []);
  console.log(`  ${plan_.productId}: level ${sub.attributes.groupLevel}, "${local?.attributes.name}" — ${local?.attributes.description}; ${TERRITORY} price ${current.join(' → ') || 'none'}; ${intro.length} introductory offer(s); state ${sub.attributes.state}`);
  if (local && (local.attributes.name !== plan_.display || local.attributes.description !== plan_.description)) {
    plan(`Rename ${plan_.productId}: "${local.attributes.name}" → "${plan_.display}", description → "${plan_.description}"`, () =>
      call('PATCH', `/v1/subscriptionLocalizations/${local.id}`, { data: { type: 'subscriptionLocalizations', id: local.id, attributes: { name: plan_.display, description: plan_.description } } }));
  }
  if (!current.includes(plan_.price) || current.at(-1) !== plan_.price) {
    plan(`Price ${plan_.productId}: $${current.at(-1) ?? '—'} → $${plan_.price} (${TERRITORY}, from today; existing subscribers move at renewal)`, () => setPrice(sub.id, plan_.price));
  }
  if (plan_.intro && !intro.length) {
    plan(`Introductory offer on ${plan_.productId}: first month $${plan_.intro.price}, pay up front, new subscribers only`, () => setIntro(sub.id, plan_.intro));
  }
}

const iaps = await all(`/v1/apps/${APP}/inAppPurchasesV2`);
for (const pack of PACKS) {
  const found = iaps.find(p => p.attributes.productId === pack.productId);
  console.log(`  ${pack.productId}: ${found ? `exists (${found.attributes.state})` : 'missing'}`);
  if (found) continue;
  plan(`Create consumable ${pack.productId} ("${pack.display}", $${pack.price}, ${TERRITORY})`, async () => {
    const created = (await call('POST', '/v2/inAppPurchases', { data: { type: 'inAppPurchases', attributes: { name: pack.name, productId: pack.productId,
      inAppPurchaseType: 'CONSUMABLE', reviewNote: REVIEW_NOTE, familySharable: false }, relationships: { app: rel('apps', APP) } } })).data;
    await call('POST', '/v1/inAppPurchaseLocalizations', { data: { type: 'inAppPurchaseLocalizations',
      attributes: { name: pack.display, locale: 'en-US', description: pack.description }, relationships: { inAppPurchaseV2: rel('inAppPurchases', created.id) } } });
    await call('POST', '/v1/inAppPurchaseAvailabilities', { data: { type: 'inAppPurchaseAvailabilities', attributes: { availableInNewTerritories: false },
      relationships: { inAppPurchase: rel('inAppPurchases', created.id), availableTerritories: { data: [{ type: 'territories', id: TERRITORY }] } } } });
    const point = (await all(`/v2/inAppPurchases/${created.id}/pricePoints?filter[territory]=${TERRITORY}&limit=200`)).find(p => p.attributes.customerPrice === pack.price);
    assert.ok(point, `no ${pack.price} price point`);
    await call('POST', '/v1/inAppPurchasePriceSchedules', { data: { type: 'inAppPurchasePriceSchedules', relationships: {
      inAppPurchase: rel('inAppPurchases', created.id), baseTerritory: rel('territories', TERRITORY),
      manualPrices: { data: [{ type: 'inAppPurchasePrices', id: '${price}' }] } } },
      included: [{ type: 'inAppPurchasePrices', id: '${price}', attributes: { startDate: null },
        relationships: { inAppPurchasePricePoint: rel('inAppPurchasePricePoints', point.id) } }] });
  });
}
const retired = iaps.find(p => p.attributes.productId === RETIRED_PACK);
console.log(`  ${RETIRED_PACK}: ${retired ? `exists (${retired.attributes.state}) — to be removed from sale (MANUAL)` : 'missing'}`);

async function setPrice(subscription, price) {
  const point = (await all(`/v1/subscriptions/${subscription}/pricePoints?filter[territory]=${TERRITORY}&limit=200`)).find(p => p.attributes.customerPrice === price);
  assert.ok(point, `no ${price} price point`);
  await call('POST', '/v1/subscriptionPrices', { data: { type: 'subscriptionPrices', attributes: { preserveCurrentPrice: false },
    relationships: { subscription: rel('subscriptions', subscription), subscriptionPricePoint: rel('subscriptionPricePoints', point.id), territory: rel('territories', TERRITORY) } } });
}
async function setIntro(subscription, intro) {
  const point = (await all(`/v1/subscriptions/${subscription}/pricePoints?filter[territory]=${TERRITORY}&limit=200`)).find(p => p.attributes.customerPrice === intro.price);
  assert.ok(point, `no ${intro.price} price point`);
  await call('POST', '/v1/subscriptionIntroductoryOffers', { data: { type: 'subscriptionIntroductoryOffers',
    attributes: { duration: intro.duration, offerMode: intro.mode, numberOfPeriods: intro.periods },
    relationships: { subscription: rel('subscriptions', subscription), territory: rel('territories', TERRITORY), subscriptionPricePoint: rel('subscriptionPricePoints', point.id) } } });
}

console.log('\nAPI changes still to make:');
steps.forEach((s, i) => console.log(`  ${i + 1}. ${s.text}`));
if (!steps.length) console.log('  none');
console.log('\nMANUAL (App Store Connect web UI or the developer account):');
MANUAL.forEach((m, i) => console.log(`  ${String.fromCharCode(97 + i)}. ${m}`));
if (!apply) { console.log('\nRead only: nothing was changed. Run with --apply --owner-approved=YYYY-MM-DD after the owner approves.'); process.exit(0); }
console.log(`\nApplying with owner approval of ${approved}…`);
for (const [i, s] of steps.entries()) { console.log(`  ${i + 1}. ${s.text}`); await s.run(); }
console.log('Done. Re-run without --apply to read the result back.');
