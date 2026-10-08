// Tests the exact install/patch shape without modifying any workspace dependency
// directory. Only the named public source files and synthetic tests are copied.
import { copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = fileURLToPath(new URL('../../../', import.meta.url));
const artifacts = join(root, '.artifacts', 'store-verifier'); mkdirSync(artifacts, { recursive: true });
const context = mkdtempSync(join(artifacts, 'isolated-'));
const files = ['server.ts', 'protocol.ts', 'thread-runner.ts', 'worker.ts', 'sdk-patch.ts', 'package.json', 'package-lock.json'];
for (const name of [...files.map(n => 'services/store-verifier/' + n),
  ...['app-store.ts', 'store-purchases.ts', 'store-verifier-protocol.ts'].map(n => 'supabase/functions/_shared/' + n)]) {
  mkdirSync(dirname(join(context, name)), { recursive: true }); copyFileSync(join(root, name), join(context, name));
}
for (const name of ['package.json', 'package-lock.json']) copyFileSync(join(root, 'services/store-verifier', name), join(context, name));
cpSync(join(root, 'services/store-verifier/tests'), join(context, 'services/store-verifier/tests'), { recursive: true });
const run = (command: string, args: string[], extraEnv: Record<string, string> = {}) => {
  const result = spawnSync(command, args, { cwd: context, env: { ...process.env, ...extraEnv }, encoding: 'utf8', timeout: 120_000 });
  const output = (result.stdout ?? '') + (result.stderr ?? ''); process.stdout.write(output);
  if (result.status !== 0) throw new Error('isolated_test_failed');
  return output;
};
run('npm', ['ci', '--ignore-scripts']);
run(process.execPath, ['--input-type=module', '-e', `
import assert from 'node:assert/strict';
import {health} from './services/store-verifier/server.ts';
import {runVerification} from './services/store-verifier/thread-runner.ts';
import {createHash} from 'node:crypto';
const probe=health({STORE_VERIFIER_POLICY_ID:'app-store-sandbox-v1',STORE_VERIFIER_MAINTENANCE:'false'});
assert.equal(probe.ready,false); assert.equal(probe.runtime.ocsp_freshness.applied,false);
const signed_payload='a'.repeat(20)+'.bb.cc';
const result=await runVerification({version:1,attempt_id:'01000000-0000-0000-0000-000000000001',kind:'transaction',policy_id:'app-store-sandbox-v1',signed_payload,signed_sha256:createHash('sha256').update(signed_payload).digest('hex')},new AbortController().signal);
assert.equal(result.code,'verification_unavailable');
console.log(JSON.stringify({unpatched_ready:probe.ready,unpatched_worker_outcome:result.code}));
`]);
const sdk = join(context, 'node_modules/@apple/app-store-server-library/dist/jws_verification.js');
mkdirSync(join(context, '.artifacts'), { recursive: true });
writeFileSync(join(context, '.artifacts/sdk-stock.js'), readFileSync(sdk));
run(process.execPath, ['services/store-verifier/sdk-patch.ts', '--apply']);
run(process.execPath, ['services/store-verifier/sdk-patch.ts', '--apply']); // Known exact output is idempotent.
const suite = ['--test', 'services/store-verifier/tests/*.test.ts'];
const utc = run(process.execPath, suite, { TZ: 'UTC' });
const other = run(process.execPath, ['--test', 'services/store-verifier/tests/sdk-patch.test.ts', 'services/store-verifier/tests/crypto.test.ts'], { TZ: 'Asia/Kolkata' });
writeFileSync(join(context, '.artifacts/utc-tests.log'), utc); writeFileSync(join(context, '.artifacts/non-utc-tests.log'), other);
writeFileSync(join(artifacts, 'latest-isolated-context.txt'), context + '\n');
console.log(JSON.stringify({ status: 'passed', context, timezones: ['UTC', 'Asia/Kolkata'] }));
