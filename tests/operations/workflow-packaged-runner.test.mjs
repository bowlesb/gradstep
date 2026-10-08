import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import test from 'node:test';

test('the actual allowlisted runner gracefully warns without Management credentials and cleans its synthetic account', async () => {
  const directory = execFileSync('python3', ['-c',
    'import importlib.util,sys; s=importlib.util.spec_from_file_location("scheduler",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.context())',
    resolve('scripts/schedule-workflow-checks.py')], { encoding: 'utf8' }).trim();
  try {
    const empty = resolve(directory, 'empty-secrets'), reports = resolve(directory, 'reports');
    await mkdir(empty);
    const preload = resolve(directory, 'fixture-preload.mjs');
    await writeFile(preload, `
import child from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { writeFileSync } from 'node:fs';
// No Keychain, git fallback, credentials or subprocess can escape this fixture.
child.execFileSync = () => { throw new Error('fixture_subprocess_refused'); };
syncBuiltinESMExports();
const calls = [], id = '11111111-1111-4111-8111-111111111111';
globalThis.fetch = async (url, options = {}) => {
  const target = new URL(url), method = options.method ?? 'GET';
  if (target.origin !== 'https://coxhjvqpflgxkleydati.supabase.co') throw new Error('fixture_off_origin_refused');
  calls.push({ method, path: target.pathname });
  const json = (value, status = 200) => Response.json(value, { status });
  if (target.pathname === '/auth/v1/admin/users') return method === 'POST' ? json({ id }) : json({ users: [] });
  if (target.pathname === '/auth/v1/token') return json({ access_token: 'fixture-account-bearer' });
  if (target.pathname === '/rest/v1/rpc/v1_credit_balance') return json({ available: 0, held: 0 });
  if (target.pathname === '/functions/v1/admin-spending') {
    const header = new Headers(options.headers).get('authorization');
    if (header && header !== 'Bearer fixture-account-bearer') throw new Error('fixture_unexpected_actor');
    return json({ code: header ? 'owner_mfa_required' : 'authentication_required' }, header ? 403 : 401);
  }
  if (target.pathname === '/rest/v1/rpc/v3_library_page') return json({ entries: [], has_more: false, next_cursor: null, baseline_cursor: 0 });
  if (target.pathname === '/functions/v1/account-delete') return json({ ok: true });
  throw new Error('fixture_unexpected_route');
};
process.on('exit', () => writeFileSync(new URL('./fixture-calls.json', import.meta.url), JSON.stringify(calls)));
`);
    const output = execFileSync(process.execPath, ['--import', preload, resolve(directory, 'scripts/workflow-checks.mjs'),
      '--suite=deploy', '--only=admin.spending-gate'], { cwd: directory, encoding: 'utf8', timeout: 15_000,
      env: { PATH: process.env.PATH, WORKFLOW_SECRETS_DIR: empty, WORKFLOW_REPORT_DIR: reports,
        SUPABASE_PROJECT_REF: 'coxhjvqpflgxkleydati', SUPABASE_URL: 'https://coxhjvqpflgxkleydati.supabase.co',
        SUPABASE_ANON_KEY: 'fixture-anon-value', SUPABASE_SERVICE_ROLE_KEY: 'fixture-service-value' } });
    const files = await readdir(reports); assert.equal(files.length, 1);
    const report = JSON.parse(await readFile(resolve(reports, files[0]), 'utf8'));
    const gate = report.results.find(row => row.id === 'admin.spending-gate');
    assert.equal(gate.status, 'warn'); assert.match(gate.reason, /anonymous\/customer refused and credits unchanged/);
    assert.match(gate.reason, /management evidence.*unavailable/);
    assert.equal(report.counts.fail, 0); assert.equal(report.counts.warn, 1);
    assert.equal(report.cost.credits, 0); assert.equal(report.cost.estimated_usd, 0); assert.equal(report.cost.measured, null);
    assert.equal(report.results.find(row => row.id === 'cleanup.accounts').status, 'pass');
    const calls = JSON.parse(await readFile(resolve(directory, 'fixture-calls.json'), 'utf8'));
    assert.equal(calls.filter(row => row.path === '/functions/v1/admin-spending').length, 2);
    assert.equal(calls.filter(row => row.path === '/functions/v1/account-delete').length, 1);
    assert.ok(!calls.some(row => /worker_record_spending|worker_grant|chat|reader-artifact/.test(row.path)));
    assert.doesNotMatch(output, /fixture-account-bearer|fixture-service-value|@example\.invalid/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
