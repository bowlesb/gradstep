import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { runProcessGroup } from '../process-group.mjs';

test('local worker success and oversize result are bounded', async () => {
  assert.equal((await runProcessGroup(process.execPath, ['-e', 'process.stdout.write("ok")'], { timeoutMS: 3000 })).toString(), 'ok');
  await assert.rejects(runProcessGroup(process.execPath, ['-e', 'process.stdout.write("x".repeat(100000))'], { timeoutMS: 3000, maxOutputBytes: 1024 }), /fixture_build_failed/);
});

test('outer watchdog timeout kills the worker and its live grandchild', async () => {
  const directory = mkdtempSync(new URL('./process-check-', import.meta.url)); const path = join(directory, 'pids.json');
  try {
    const script = 'const {spawn}=require("node:child_process");const {writeFileSync}=require("node:fs");const child=spawn(process.execPath,["-e","setInterval(()=>{},1000)"],{stdio:"ignore"});writeFileSync(process.argv[1],JSON.stringify([process.pid,child.pid]));setInterval(()=>{},1000);';
    await assert.rejects(runProcessGroup(process.execPath, ['-e', script, path], { timeoutMS: 1000 }), /fixture_build_failed/);
    const pids = JSON.parse(readFileSync(path));
    const gone = pid => { try { process.kill(pid, 0); return false; } catch (error) { return error.code === 'ESRCH'; } };
    for (let turn = 0; turn < 40 && !pids.every(gone); turn++) await new Promise(resolve => setTimeout(resolve, 50));
    assert.ok(pids.every(gone), 'all process-group members must be gone');
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
