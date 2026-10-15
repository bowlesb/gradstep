import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deployWeb, verifyLive } from '../../scripts/deploy-web.mjs';

const project = 'aaaaaaaaaaaaaaaaaaaa', backend = `https://${project}.supabase.co`;
const jwt = (role = 'anon', ref = project) => Buffer.from('{}').toString('base64url') + '.' + Buffer.from(JSON.stringify({ role, ref })).toString('base64url') + '.fixture';
const adminHeaders = readFileSync(new URL('../../apps/admin/public/_headers', import.meta.url), 'utf8').replaceAll('https://coxhjvqpflgxkleydati.supabase.co', backend);
function fixture(t, changes = {}) {
  const root = mkdtempSync(join(tmpdir(), 'gradstep-web-deployment-')); t.after(() => rmSync(root, { recursive: true, force: true }));
  const env = { SUPABASE_PROJECT_REF: project, SUPABASE_URL: backend, SUPABASE_ANON_KEY: jwt(),
    SUPABASE_SERVICE_ROLE_KEY: 'fixture-server-role-secret-never-public', CLOUDFLARE_API_TOKEN: 'fixture-cloudflare-token-never-public', CLOUDFLARE_ACCOUNT_ID: 'b'.repeat(32), ...changes };
  for (const directory of ['infra', 'apps/admin', 'apps/web', 'web/site', 'node_modules/.bin']) mkdirSync(join(root, directory), { recursive: true });
  writeFileSync(join(root, '.env.staging'), Object.entries(env).map(([key, value]) => `${key}=${value}`).join('\n'));
  writeFileSync(join(root, 'infra/account.json'), JSON.stringify({ projects: { staging: { id: project } } }));
  writeFileSync(join(root, 'node_modules/.bin/wrangler'), 'fixture, never executed');
  const calls = [], logs = [];
  let mutate = () => {};
  const options = { root, log: message => logs.push(message), processEnv: { PATH: '/fixture-bin', NODE_ENV: 'development', VITE_EVIL: 'wrong-public-value',
    VITE_SUPABASE_URL: 'https://wrong.invalid', CLOUDFLARE_API_TOKEN: env.CLOUDFLARE_API_TOKEN, SUPABASE_SERVICE_ROLE_KEY: env.SUPABASE_SERVICE_ROLE_KEY },
    run: (command, args, options) => {
      calls.push({ command, args, ...options });
      if (command !== 'npm') return;
      const app = args[1] === 'build:admin' ? 'apps/admin' : 'apps/web';
      const directory = join(root, app, 'dist'); mkdirSync(join(directory, 'assets'), { recursive: true });
      // The browser reader fetches arXiv HTML and searches DataCite directly (devices only), so its connect-src names both first.
      writeFileSync(join(directory, '_headers'), app === 'apps/web' ? adminHeaders.replace(`connect-src ${backend}`, `connect-src https://arxiv.org https://api.datacite.org ${backend}`) : adminHeaders);
      writeFileSync(join(directory, 'index.html'), '<html><body><script src="/assets/client.js"></script></body></html>');
      writeFileSync(join(directory, 'assets/client.js'), `export const endpoint=${JSON.stringify(backend)},key=${JSON.stringify(env.SUPABASE_ANON_KEY)};`);
      mutate(directory);
    } };
  return { root, env, options, calls, logs, afterBuild: next => { mutate = next; } };
}

test('admin target builds from the repository, strips inherited public/server values, validates then deploys only its Pages project', t => {
  const f = fixture(t), result = deployWeb('admin', f.options);
  assert.equal(result.pagesProject, 'gradstep-admin'); assert.equal(result.intendedOrigin, 'https://admin.gradstep.ai');
  assert.equal(f.calls.length, 2);
  assert.deepEqual([f.calls[0].command, f.calls[0].args, f.calls[0].cwd], ['npm', ['run', 'build:admin'], f.root]);
  assert.deepEqual(Object.fromEntries(Object.entries(f.calls[0].env).filter(([key]) => key.startsWith('VITE_'))),
    { VITE_SUPABASE_URL: backend, VITE_AUTH_URL: backend, VITE_SUPABASE_ANON_KEY: jwt(), VITE_ENVIRONMENT: 'staging' });
  assert.equal(f.calls[0].env.NODE_ENV, 'production');
  assert.equal(f.calls[0].env.CLOUDFLARE_API_TOKEN, undefined); assert.equal(f.calls[0].env.SUPABASE_SERVICE_ROLE_KEY, undefined);
  assert.deepEqual(f.calls[1].args, ['pages', 'deploy', join(f.root, 'apps/admin/dist'), '--project-name', 'gradstep-admin', '--branch', 'main', '--commit-dirty=true', '--force']);
  assert.equal(f.calls[1].stdio[0], 'ignore', 'missing Pages project must not enter interactive creation');
  assert.equal(f.calls[1].env.WRANGLER_SEND_METRICS, 'false');
  assert.ok(!f.logs.join().includes(f.env.CLOUDFLARE_API_TOKEN)); assert.ok(!f.logs.join().includes(f.env.SUPABASE_SERVICE_ROLE_KEY));
});

test('build-only performs output checks but never invokes Cloudflare, and existing app/site destinations stay distinct', t => {
  const admin = fixture(t, { CLOUDFLARE_API_TOKEN: '', CLOUDFLARE_ACCOUNT_ID: '' });
  const result = deployWeb('admin', { ...admin.options, buildOnly: true });
  assert.equal(result.buildOnly, true); assert.equal(admin.calls.length, 1);
  const app = fixture(t); deployWeb('app', app.options);
  assert.deepEqual(app.calls[0].args, ['run', 'build']); assert.equal(app.calls[0].cwd, join(app.root, 'apps/web'));
  assert.equal(app.calls[1].args[4], 'gradstep-app');
  const site = fixture(t); deployWeb('site', site.options);
  assert.equal(site.calls.length, 1); assert.equal(site.calls[0].args[4], 'gradstep-site'); assert.equal(site.calls[0].args[2], join(site.root, 'web/site'));
});

test('wrong backend/privileged key/local dotenv fail before a build or upload', t => {
  for (const changes of [{ SUPABASE_URL: 'https://other.invalid' }, { SUPABASE_PROJECT_REF: 'wrong' }, { SUPABASE_ANON_KEY: jwt('service_role') },
    { SUPABASE_ANON_KEY: jwt('anon', 'wrong') }, { SUPABASE_ANON_KEY: 'not-a-jwt' }]) {
    const f = fixture(t, changes); assert.throws(() => deployWeb('admin', f.options)); assert.equal(f.calls.length, 0);
  }
  for (const name of ['.env', '.env.local', '.env.production', '.env.production.local']) {
    const f = fixture(t); writeFileSync(join(f.root, 'apps/admin', name), 'VITE_SECRET=private');
    assert.throws(() => deployWeb('admin', f.options), /deploy builds take values only/); assert.equal(f.calls.length, 0);
  }
});

test('invalid CSP, missing HSTS/no-transform, and leaked credentials block upload after the build', t => {
  const mutations = [
    headers => headers.replace(`connect-src ${backend}`, 'connect-src https://wrong.invalid'),
    headers => headers.replace("script-src 'self'", "script-src 'self' 'unsafe-inline'"),
    headers => headers.replace("frame-src 'none'", 'frame-src *'),
    headers => headers.replace('  Strict-Transport-Security: max-age=31536000\n', ''),
    headers => headers.replace('  Cache-Control: no-transform\n', ''),
    headers => headers.replace("default-src 'none'", "default-src 'none'; default-src *"),
  ];
  for (const mutation of mutations) { const f = fixture(t);
    f.afterBuild(directory => writeFileSync(join(directory, '_headers'), mutation(adminHeaders)));
    assert.throws(() => deployWeb('admin', f.options)); assert.equal(f.calls.length, 1);
  }
  for (const name of ['SUPABASE_SERVICE_ROLE_KEY', 'CLOUDFLARE_API_TOKEN']) { const f = fixture(t);
    f.afterBuild(directory => writeFileSync(join(directory, 'assets/bad.js'), f.env[name]));
    assert.throws(() => deployWeb('admin', f.options), error => error.message.includes(name) && !error.message.includes(f.env[name])); assert.equal(f.calls.length, 1);
  }
});

test('route rules cannot detach or override inherited security headers', t => {
  for (const header of ['Content-Security-Policy', 'Strict-Transport-Security', 'X-Content-Type-Options', 'Cache-Control']) {
    for (const route of ['/index.html', '/assets/*']) {
      const f = fixture(t);
      f.afterBuild(directory => writeFileSync(join(directory, '_headers'), adminHeaders.replace(`${route}\n`, `${route}\n  ! ${header}\n`)));
      assert.throws(() => deployWeb('admin', f.options), /detachment/); assert.equal(f.calls.length, 1);
    }
  }
  for (const mutation of [
    headers => headers.replace('/index.html\n', '/index.html\n  Content-Security-Policy: default-src *\n'),
    headers => headers.replace('/index.html\n', '/index.html\n  X-Content-Type-Options: invalid\n'),
    headers => headers.replace('/assets/*\n', '/assets/*\n  Cache-Control: public\n'),
    headers => headers.replace('/*\n', "/*\n  Content-Security-Policy : default-src *\n"),
    headers => headers + '\n/other\n  Cache-Control: no-cache\n',
    headers => headers + '\n/index.html\n  Cache-Control: no-cache\n',
    headers => headers.replace('  Cache-Control: no-cache', '  Cache-Control: public'),
  ]) {
    const f = fixture(t); f.afterBuild(directory => writeFileSync(join(directory, '_headers'), mutation(adminHeaders)));
    assert.throws(() => deployWeb('admin', f.options)); assert.equal(f.calls.length, 1);
  }
});

test('fixtures, source maps, environment files, symlinks and Pages Functions cannot ship as the static admin', t => {
  for (const content of ['__fixture-spending-entry', 'synthetic-observation', '/@vite/client', 'react-refresh', 'owner@example.com']) {
    const f = fixture(t); f.afterBuild(directory => writeFileSync(join(directory, 'assets/test.js'), content));
    assert.throws(() => deployWeb('admin', f.options), /development/); assert.equal(f.calls.length, 1);
  }
  for (const name of ['client.js.map', '_worker.js', '_routes.json', '.env.production', 'functions/hello.js']) {
    const f = fixture(t); f.afterBuild(directory => { if (name.includes('/')) mkdirSync(join(directory, 'functions')); writeFileSync(join(directory, name), 'fixture'); });
    assert.throws(() => deployWeb('admin', f.options), /server, environment or source-map/); assert.equal(f.calls.length, 1);
  }
  const link = fixture(t); link.afterBuild(directory => symlinkSync(join(link.root, '.env.staging'), join(directory, 'config')));
  assert.throws(() => deployWeb('admin', link.options), /symbolic links/); assert.equal(link.calls.length, 1);
  const functions = fixture(t); mkdirSync(join(functions.root, 'functions'));
  assert.throws(() => deployWeb('admin', functions.options), /root functions/); assert.equal(functions.calls.length, 1);
});

test('a deploy is verified live: an HTML fallback cached for a new script fails it', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'gradstep-live-')); t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(join(directory, 'index.html'), '<script type="module" src="/assets/index-new.js"></script><link rel="stylesheet" href="/assets/index-new.css">');
  const page = (body, type, status = 200) => ({ ok: status < 400, status, text: async () => body, headers: new Map([['content-type', type]]) });
  let indexCalls = 0; const seen = [];
  const serve = poisoned => async (url, init) => {
    seen.push([url, init?.headers?.Origin ?? null]);
    if (new URL(url).pathname === '/') return page(++indexCalls < 3 ? '<script src="/assets/index-old.js">' : '<script src="/assets/index-new.js"><link href="/assets/index-new.css">', 'text/html');
    if (poisoned) return page('<!doctype html>', 'text/html; charset=utf-8');
    return page('', url.endsWith('.js') ? 'application/javascript' : 'text/css; charset=utf-8');
  };
  const options = { wait: async () => {}, log: () => {} };
  await verifyLive(directory, 'admin.example', { ...options, fetchImpl: serve(false) });
  assert.equal(indexCalls, 3, 'waits for the domain to serve the new index');
  assert.deepEqual(seen.filter(([u]) => u.includes('/assets/')).map(([, origin]) => origin), ['https://admin.example', 'https://admin.example']);
  indexCalls = 0;
  await assert.rejects(verifyLive(directory, 'admin.example', { ...options, fetchImpl: serve(true) }), /HTML fallback/);
  indexCalls = -1e9;
  await assert.rejects(verifyLive(directory, 'admin.example', { ...options, fetchImpl: serve(false), timeoutMs: -1 }), /previous index/);
});
