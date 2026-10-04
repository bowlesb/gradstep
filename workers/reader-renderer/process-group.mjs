import { spawn } from 'node:child_process';

// POSIX local-builder watchdog. A process group includes a worker's descendants,
// unlike child.kill(), so the outer deadline still owns a nested render process.
export function runProcessGroup(executable, args, { timeoutMS = 60000, maxOutputBytes = 65536 } = {}) {
  if (!Number.isSafeInteger(timeoutMS) || timeoutMS <= 0 || !Number.isSafeInteger(maxOutputBytes) || maxOutputBytes <= 0) throw new Error('process_limits');
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { detached: true, stdio: ['ignore', 'pipe', 'ignore'], env: { PATH: process.env.PATH } });
    const chunks = []; let count = 0, failed = false;
    const killGroup = () => { if (child.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') failed = true; } } };
    const abort = () => { failed = true; killGroup(); };
    const timer = setTimeout(abort, timeoutMS);
    process.once('SIGINT', abort); process.once('SIGTERM', abort); process.once('exit', killGroup);
    child.stdout.on('data', bytes => { count += bytes.length; if (count > maxOutputBytes) abort(); else chunks.push(bytes); });
    child.on('error', abort);
    child.on('close', code => {
      clearTimeout(timer); process.removeListener('SIGINT', abort); process.removeListener('SIGTERM', abort); process.removeListener('exit', killGroup); killGroup();
      if (failed || code !== 0) reject(new Error('fixture_build_failed')); else resolve(Buffer.concat(chunks, count));
    });
  });
}
