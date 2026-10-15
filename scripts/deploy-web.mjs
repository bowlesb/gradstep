#!/usr/bin/env node
// Dedicated static Cloudflare Pages targets. Provision project/domain separately; this script never edits DNS.
//   node scripts/deploy-web.mjs app    # apps/web → gradstep-app / app.gradstep.ai
//   node scripts/deploy-web.mjs admin  # apps/admin → gradstep-admin / admin.gradstep.ai
//   node scripts/deploy-web.mjs site   # web/site → gradstep-site / gradstep.ai
// Add --build-only to run every local output gate without invoking Wrangler or Cloudflare.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../', import.meta.url));
export const TARGETS = Object.freeze({
  app: { path: 'apps/web', project: 'gradstep-app', host: 'app.gradstep.ai', script: 'build' },
  admin: { path: 'apps/admin', project: 'gradstep-admin', host: 'admin.gradstep.ai', script: 'build:admin' },
  site: { path: 'web/site', project: 'gradstep-site', host: 'gradstep.ai' },
});
class Refusal extends Error {}
const fail = message => { throw new Refusal(message); };
function dotenv(path) {
  return Object.fromEntries(readFileSync(path, 'utf8').split('\n').filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
}
function files(dir) {
  return readdirSync(dir).flatMap(name => {
    const path = join(dir, name), stat = lstatSync(path);
    if (stat.isSymbolicLink()) fail('built assets must not contain symbolic links');
    return stat.isDirectory() ? files(path) : [path];
  });
}
function globalHeaders(text) {
  const rules = new Map(), cacheRules = new Map([
    ['/index.html', 'no-cache'], ['/', 'no-cache'], ['/assets/*', 'public, max-age=31536000, immutable'],
  ]);
  let current;
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    // Pages detach directives remove inherited headers. Never accept one, even outside the global rule.
    if (line.trimStart().startsWith('!')) fail('output header detachment is forbidden');
    if (!/^\s/.test(line)) {
      if ((line !== '/*' && !cacheRules.has(line)) || rules.has(line)) fail('unexpected or duplicate output header route');
      current = new Map(); rules.set(line, current); continue;
    }
    const match = line.trim().match(/^([A-Za-z0-9-]+):\s*(.*)$/);
    if (!current || !match || current.has(match[1].toLowerCase())) fail('ambiguous output headers');
    current.set(match[1].toLowerCase(), match[2]);
  }
  for (const [route, value] of cacheRules) {
    const rule = rules.get(route);
    if (rule?.size !== 1 || rule.get('cache-control') !== value) fail('non-global output headers must be the exact cache-only rules');
  }
  return rules.get('/*') ?? new Map();
}
export function validateClientOutput(root, directory, target, backend, env) {
  const headers = globalHeaders(readFileSync(join(directory, '_headers'), 'utf8'));
  const directives = new Map();
  for (const item of (headers.get('content-security-policy') ?? '').split(';').map(s => s.trim()).filter(Boolean)) {
    const [name, ...values] = item.split(/\s+/);
    if (directives.has(name)) fail('duplicate CSP directive');
    directives.set(name, values.join(' '));
  }
  const auth = env.VITE_AUTH_URL?.replace(/\/$/, '') || backend;
  let expectedConnect;
  // The browser reader reads arXiv's HTML on the device, and searches DataCite from the device (ARXIV_DEVICE_ONLY.md §5.6).
  try { expectedConnect = [...new Set([...(target === 'app' ? ['https://arxiv.org', 'https://api.datacite.org'] : []), new URL(backend).origin, new URL(auth).origin])].join(' '); }
  catch { fail('the configured auth URL is not an absolute URL'); }
  if (directives.get('connect-src') !== expectedConnect || directives.get('default-src') !== "'none'" || directives.get('frame-ancestors') !== "'none'"
    || headers.get('strict-transport-security') !== 'max-age=31536000' || headers.get('x-content-type-options') !== 'nosniff'
    || headers.get('referrer-policy') !== 'no-referrer' || headers.get('x-frame-options') !== 'DENY'
    || !headers.get('cache-control')?.split(/,\s*/).includes('no-transform')) fail('the built _headers lack the strict policy for the staging backend');
  if (target === 'admin' && (directives.get('script-src') !== "'self'" || directives.get('style-src') !== "'self'"
    || directives.get('object-src') !== "'none'" || directives.get('worker-src') !== "'none'"
    || directives.get('frame-src') !== "'none'" || directives.get('base-uri') !== "'none'" || directives.get('form-action') !== "'self'")) fail('admin CSP permits an unexpected execution or embedding source');
  if (existsSync(join(root, 'functions'))) fail('static Pages deployment must not include a root functions directory');
  const secrets = Object.entries(env).filter(([k, v]) => k !== 'SUPABASE_ANON_KEY' && k !== 'VITE_AUTH_URL' && v.length >= 16
    && !/^(SUPABASE_URL|SUPABASE_PROJECT_REF|GCLOUD_PROJECT_ID|GCLOUD_PROJECT_NUMBER|CLOUDFLARE_ACCOUNT_ID)$/.test(k));
  for (const file of files(directory)) {
    const path = relative(directory, file);
    if (/(^|\/)functions(\/|$)|(^|\/)\.env(?:\.|$)|(^|\/)_(?:worker\.js|routes\.json)(?:\/|$)|\.map$/.test(path)) fail('server, environment or source-map files appear in the static output');
    const text = readFileSync(file, 'latin1');
    for (const [name, value] of secrets) if (text.includes(value)) fail(`${name} appears in ${relative(root, file)}`);
    if (target === 'admin' && /__fixture-spending-entry|synthetic-observation|\/@vite\/client|react-refresh|owner@example\.com/.test(text)) fail('a development fixture or development runtime appears in the admin output');
  }
}
export function deployWeb(target, { root = repository, buildOnly = false, publish = true, run = execFileSync, processEnv = process.env, log = console.log } = {}) {
  if (!Object.hasOwn(TARGETS, target)) fail('Usage: node scripts/deploy-web.mjs app|admin|site [--build-only]');
  const selected = TARGETS[target], env = dotenv(join(root, '.env.staging'));
  if (!buildOnly) for (const name of ['CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID']) if (!env[name]) fail(`${name} is missing from .env.staging`);
  let directory = join(root, selected.path);
  if (target !== 'site') {
    const project = JSON.parse(readFileSync(join(root, 'infra/account.json'), 'utf8')).projects.staging.id;
    const backend = `https://${project}.supabase.co`;
    if (!/^[a-z]{20}$/.test(project) || env.SUPABASE_PROJECT_REF !== project || env.SUPABASE_URL?.replace(/\/$/, '') !== backend) fail('.env.staging does not name the staging project');
    const key = env.SUPABASE_ANON_KEY ?? ''; let claims;
    try { claims = JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString('utf8')); } catch { fail('the anon key is not a JWT'); }
    if (key.split('.').length !== 3 || claims?.role !== 'anon' || claims?.ref !== project) fail('the public key is not the staging anon key');
    for (const local of ['.env', '.env.local', '.env.production', '.env.production.local'])
      if (existsSync(join(directory, local))) fail(`remove ${selected.path}/${local}; deploy builds take values only from .env.staging`);
    const buildEnv = { ...Object.fromEntries(Object.entries(processEnv).filter(([k]) => !k.startsWith('VITE_') && !k.startsWith('CLOUDFLARE_') && !Object.hasOwn(env, k))), NODE_ENV: 'production',
      VITE_SUPABASE_URL: backend, VITE_AUTH_URL: env.VITE_AUTH_URL ?? backend, VITE_SUPABASE_ANON_KEY: key, VITE_ENVIRONMENT: 'staging' };
    run('npm', ['run', selected.script], { cwd: target === 'admin' ? root : directory, env: buildEnv, stdio: ['ignore', 'inherit', 'inherit'] });
    directory = join(directory, 'dist');
    validateClientOutput(root, directory, target, backend, env);
  }
  if (buildOnly) { log(`Validated ${target} static output for Pages project ${selected.project}; no deployment performed`); }
  else if (!publish) { log(`Validated ${target} static output; publishing in phases`); }
  else {
    const wrangler = join(root, 'node_modules/.bin/wrangler');
    if (!existsSync(wrangler)) fail('run npm ci at the repository root for the locked Wrangler version');
    // Locked Wrangler otherwise delegates a missing Pages project to Workers in agent environments.
    // Explicit Pages mode plus noninteractive stdin fails when the separately provisioned project is absent.
    run(wrangler, ['pages', 'deploy', directory, '--project-name', selected.project, '--branch', 'main', '--commit-dirty=true', '--force'], {
      cwd: root, stdio: ['ignore', 'inherit', 'inherit'],
      env: { ...processEnv, CLOUDFLARE_API_TOKEN: env.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: env.CLOUDFLARE_ACCOUNT_ID, WRANGLER_SEND_METRICS: 'false' },
    });
    log(`Deployed ${target} to Pages project ${selected.project}`);
  }
  return { target, directory, pagesProject: selected.project, intendedOrigin: `https://${selected.host}`, buildOnly };
}

/** After a deploy: wait until the domain serves the new index, then fetch each script and stylesheet the way a
 * browser does (with an Origin header, which Cloudflare caches separately). On 2026-10-15 the admin's new script was
 * requested during propagation, answered by the old deployment's HTML fallback, and that HTML was cached under the
 * year-long `/assets/*` rule, so the live admin was blank. A wrong type here fails the deploy loudly. */
export async function verifyLive(directory, host, { fetchImpl = fetch, wait = ms => new Promise(r => setTimeout(r, ms)), timeoutMs = 180_000, log = console.log } = {}) {
  const index = readFileSync(join(directory, 'index.html'), 'utf8');
  const assets = [...new Set([...index.matchAll(/(?:src|href)="\/?(assets\/[^"]+\.(?:js|css))"/g)].map(m => m[1]))];
  const origin = `https://${host}`, started = Date.now();
  for (;;) {
    const live = await fetchImpl(`${origin}/?deploy-check=${Date.now()}`, { cache: 'no-store' }).then(r => r.text()).catch(() => '');
    if (assets.every(a => live.includes(a))) break;
    if (Date.now() - started > timeoutMs) fail(`${host} still serves the previous index after ${Math.round(timeoutMs / 1000)}s`);
    await wait(5_000);
  }
  await wait(20_000); // other edges switch a little later than the one answering us
  for (const asset of assets) {
    const response = await fetchImpl(`${origin}/${asset}`, { headers: { Origin: origin } });
    const type = response.headers.get('content-type') ?? '';
    const expected = asset.endsWith('.js') ? /javascript/ : /text\/css/;
    if (!response.ok || !expected.test(type)) fail(`${origin}/${asset} answers ${response.status} ${type}: an edge cached the HTML fallback. Change any source file and deploy again (new asset names)`);
  }
  log(`Verified ${origin}: ${assets.length} scripts and stylesheets served with their own types`);
}

/** One Pages deployment of `directory` to the target's project (the same Wrangler call deployWeb makes). */
function pagesDeploy(root, target, directory, run, env, processEnv) {
  const wrangler = join(root, 'node_modules/.bin/wrangler');
  if (!existsSync(wrangler)) fail('run npm ci at the repository root for the locked Wrangler version');
  run(wrangler, ['pages', 'deploy', directory, '--project-name', TARGETS[target].project, '--branch', 'main', '--commit-dirty=true', '--force'], {
    cwd: root, stdio: ['ignore', 'inherit', 'inherit'],
    env: { ...processEnv, CLOUDFLARE_API_TOKEN: env.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: env.CLOUDFLARE_ACCOUNT_ID, WRANGLER_SEND_METRICS: 'false' },
  });
}

/** The two staged directories of a phased release. Phase 1 is the live release, whole (its index, headers and files),
 * plus the new release's assets; phase 2 is the new release plus the previous release's assets (a tab still on the
 * old index can load its own chunks). Each carries a marker named for its phase, so the domain can be asked which one
 * it serves without requesting a new asset from an edge that may still be on the old deployment. */
export function stagePhases(dist, previous, stageRoot, id) {
  const phase1 = join(stageRoot, 'phase1'), phase2 = join(stageRoot, 'phase2');
  for (const dir of [phase1, phase2]) rmSync(dir, { recursive: true, force: true });
  cpSync(previous, phase1, { recursive: true });
  cpSync(join(dist, 'assets'), join(phase1, 'assets'), { recursive: true, force: false, errorOnExist: false });
  cpSync(dist, phase2, { recursive: true });
  if (existsSync(join(previous, 'assets'))) cpSync(join(previous, 'assets'), join(phase2, 'assets'), { recursive: true, force: false, errorOnExist: false });
  writeFileSync(join(phase1, `__deploy-${id}-1.txt`), id);
  writeFileSync(join(phase2, `__deploy-${id}-2.txt`), id);
  return { phase1, phase2 };
}

/** Waits until the domain serves the deployment carrying `marker` (its text is the deploy id). */
export async function waitForMarker(host, marker, id, { fetchImpl = fetch, wait = ms => new Promise(r => setTimeout(r, ms)), timeoutMs = 180_000 } = {}) {
  const started = Date.now();
  for (;;) {
    const text = await fetchImpl(`https://${host}/${marker}?check=${Date.now()}`, { cache: 'no-store' }).then(r => r.ok ? r.text() : '').catch(() => '');
    if (text.trim() === id) return;
    if (Date.now() - started > timeoutMs) fail(`${host} does not serve ${marker} after ${Math.round(timeoutMs / 1000)}s`);
    await wait(5_000);
  }
}

/** Publishes a validated build in two phases (2026-10-15: twice a new script was requested from an edge still on the
 * previous deployment, answered with the single-page fallback and cached for a year, blanking the site). Phase 1 puts
 * the new assets everywhere while the old index is still served; only then does phase 2 switch the index. Without a
 * snapshot of the live release (the first phased deploy) it publishes once, as before, and keeps the snapshot. */
export async function publishInPhases(target, dist, { root = repository, run = execFileSync, processEnv = process.env, log = console.log,
  fetchImpl = fetch, wait = ms => new Promise(r => setTimeout(r, ms)), id = Date.now().toString(36) } = {}) {
  const env = dotenv(join(root, '.env.staging')), host = TARGETS[target].host;
  const snapshot = join(root, '.artifacts/web-deployed', target), stageRoot = join(root, '.artifacts/web-deploy-stage', target);
  mkdirSync(stageRoot, { recursive: true });
  let final = dist;
  if (existsSync(join(snapshot, 'index.html'))) {
    const { phase1, phase2 } = stagePhases(dist, snapshot, stageRoot, id);
    pagesDeploy(root, target, phase1, run, env, processEnv);
    await waitForMarker(host, `__deploy-${id}-1.txt`, id, { fetchImpl, wait });
    await wait(30_000); // other edges switch a little later than the one answering us
    log(`Phase 1 live on ${host}: the new assets are served beside the current release`);
    pagesDeploy(root, target, phase2, run, env, processEnv);
    final = phase2;
  } else {
    log(`No snapshot of the live ${target} release yet: publishing in one phase`);
    pagesDeploy(root, target, dist, run, env, processEnv);
  }
  log(`Deployed ${target} to Pages project ${TARGETS[target].project}`);
  await verifyLive(final, host, { fetchImpl, wait, log });
  rmSync(snapshot, { recursive: true, force: true });
  cpSync(dist, snapshot, { recursive: true });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [target, flag, ...extra] = process.argv.slice(2);
    if (extra.length || (flag && flag !== '--build-only')) fail('Usage: node scripts/deploy-web.mjs app|admin|site [--build-only]');
    const buildOnly = flag === '--build-only', phased = !buildOnly && target !== 'site';
    const result = deployWeb(target, { buildOnly, publish: !phased });
    if (phased) await publishInPhases(target, result.directory);
  } catch (error) {
    console.error(error instanceof Refusal ? 'Refusing to deploy: ' + error.message : 'Build/deployment failed. No credentials are included in this diagnostic.');
    process.exitCode = 1;
  }
}
