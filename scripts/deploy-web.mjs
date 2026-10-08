#!/usr/bin/env node
// Build and deploy the browser reader or the info site to Cloudflare Pages (docs/architecture/BROWSER_READER.md).
//   node scripts/deploy-web.mjs app    # apps/web → Pages project gradstep-app (https://app.gradstep.ai), staging backend
//   node scripts/deploy-web.mjs site   # web/site → Pages project gradstep-site (https://gradstep.ai)
// Uses the dedicated Cloudflare credential in .env.staging and the repository's locked Wrangler 4.
// Deployment gates for the app: the backend URL must be the staging project, the embedded key must be that
// project's anon key, the built output must not contain any server credential from .env.staging, and the
// generated _headers must carry the strict CSP for exactly that backend. Never prints credentials.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const target = process.argv[2];
if (!['app', 'site'].includes(target)) { console.error('Usage: node scripts/deploy-web.mjs app|site'); process.exit(64); }

function dotenv(path) {
  return Object.fromEntries(readFileSync(path, 'utf8').split('\n').filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
}
const env = dotenv(join(root, '.env.staging'));
const project = JSON.parse(readFileSync(join(root, 'infra/account.json'), 'utf8')).projects.staging.id;
const fail = message => { console.error('Refusing to deploy: ' + message); process.exit(1); };
for (const name of ['CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID']) if (!env[name]) fail(`${name} is missing from .env.staging`);

function files(dir) {
  return readdirSync(dir).flatMap(name => { const path = join(dir, name); return statSync(path).isDirectory() ? files(path) : [path]; });
}

let directory, pagesProject;
if (target === 'app') {
  const backend = `https://${project}.supabase.co`;
  if (env.SUPABASE_PROJECT_REF !== project || env.SUPABASE_URL?.replace(/\/$/, '') !== backend) fail('.env.staging does not name the staging project');
  const key = env.SUPABASE_ANON_KEY ?? '';
  let claims;
  try { claims = JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString('utf8')); } catch { fail('the anon key is not a JWT'); }
  if (key.split('.').length !== 3 || claims.role !== 'anon' || claims.ref !== project) fail('the public key is not the staging anon key');
  const app = join(root, 'apps/web');
  for (const local of ['.env', '.env.local', '.env.production', '.env.production.local'])
    if (existsSync(join(app, local))) fail(`remove apps/web/${local}; deploy builds take values only from .env.staging`);
  const buildEnv = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('VITE_'))),
    VITE_SUPABASE_URL: backend, VITE_SUPABASE_ANON_KEY: key, VITE_ENVIRONMENT: 'staging' };
  execFileSync('npm', ['run', 'build'], { cwd: app, env: buildEnv, stdio: ['ignore', 'inherit', 'inherit'] });
  directory = join(app, 'dist');
  const headers = readFileSync(join(directory, '_headers'), 'utf8');
  if (!headers.includes(`connect-src ${backend};`) || !headers.includes(`default-src 'none'`) || !headers.includes(`frame-ancestors 'none'`) ||
      !headers.includes('Strict-Transport-Security: max-age=31536000')) fail('the generated _headers lack the strict policy for the staging backend');
  const secrets = Object.entries(env).filter(([k, v]) => k !== 'SUPABASE_ANON_KEY' && v.length >= 16 && !/^(SUPABASE_URL|SUPABASE_PROJECT_REF|GCLOUD_PROJECT_ID|GCLOUD_PROJECT_NUMBER|CLOUDFLARE_ACCOUNT_ID)$/.test(k));
  for (const file of files(directory)) {
    const text = readFileSync(file, 'latin1');
    for (const [name, value] of secrets) if (text.includes(value)) fail(`${name} appears in ${file.slice(root.length)}`);
  }
  pagesProject = 'gradstep-app';
} else {
  directory = join(root, 'web/site');
  pagesProject = 'gradstep-site';
}

const wrangler = join(root, 'node_modules/.bin/wrangler');
if (!existsSync(wrangler)) fail('run npm ci at the repository root for the locked Wrangler version');
execFileSync(wrangler, ['pages', 'deploy', directory, '--project-name', pagesProject, '--branch', 'main', '--commit-dirty=true'], {
  cwd: root, stdio: ['ignore', 'inherit', 'inherit'],
  env: { ...process.env, CLOUDFLARE_API_TOKEN: env.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: env.CLOUDFLARE_ACCOUNT_ID, WRANGLER_SEND_METRICS: 'false' },
});
console.log(`Deployed ${target} to Pages project ${pagesProject}`);
