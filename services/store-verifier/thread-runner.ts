import { Worker } from 'node:worker_threads';
import { unavailable, type VerificationDecision, type VerificationRequest } from './protocol.ts';

export const TRANSACTION_TIMEOUT_MS = 40_000;
export const NOTIFICATION_TIMEOUT_MS = 70_000;
export const MAX_CONCURRENCY = 2;

/** Capacity includes body receipt and final thread exit, not just HTTP responses. */
export class Capacity {
  #active = 0;
  get active(): number { return this.#active; }
  acquire(): (() => void) | null {
    if (this.#active >= MAX_CONCURRENCY) return null;
    this.#active++;
    let released = false;
    return () => { if (!released) { released = true; this.#active--; } };
  }
}

/** The entry point cannot be chosen by a caller or an environment variable. No
 * inherited application secrets, preloads or worker stdout enter this service. */
export function productionWorker(): Worker {
  return new Worker(new URL('./worker.ts', import.meta.url), {
    env: {}, execArgv: [], stdin: false, stdout: true, stderr: true,
    resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 16, stackSizeMb: 4 },
  });
}

/** Returns only after the thread has exited, including after an early success
 * or SDK Promise.all rejection with another OCSP request still outstanding.
 * A factory/deadline may be injected by local tests; the HTTP entry point uses
 * the fixed production defaults and exposes no request/config injection. */
export async function runVerification(request: VerificationRequest, signal: AbortSignal,
  options: { factory?: () => Worker; timeoutMS?: number } = {}): Promise<unknown | VerificationDecision> {
  if (signal.aborted) return unavailable('other');
  let worker: Worker;
  try { worker = (options.factory ?? productionWorker)(); }
  catch { return unavailable(); }
  worker.stdout?.on('data', () => { /* Never forward SDK/customer output. */ });
  worker.stderr?.on('data', () => { /* Never forward SDK/customer output. */ });
  let settle!: (value: unknown) => void;
  const result = new Promise<unknown>(resolve => { settle = resolve; });
  let completed = false;
  const complete = (value: unknown) => { if (!completed) { completed = true; settle(value); } };
  const exited = new Promise<void>(resolve => {
    worker.once('exit', () => { complete(unavailable()); resolve(); });
  });
  worker.once('message', message => complete(message));
  worker.on('error', () => complete(unavailable()));
  const abort = () => complete(unavailable('other'));
  signal.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => complete(unavailable('timeout')), options.timeoutMS ??
    (request.kind === 'transaction' ? TRANSACTION_TIMEOUT_MS : NOTIFICATION_TIMEOUT_MS));
  try {
    if (signal.aborted) abort();
    else worker.postMessage(request);
    return await result;
  } catch { return unavailable(); }
  finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', abort);
    // terminate() resolves after the exit event. Keep the exit listener as an
    // independent join: a response can never release a still-running worker.
    try { await worker.terminate(); } catch { /* Wait for actual exit below. */ }
    await exited;
  }
}
