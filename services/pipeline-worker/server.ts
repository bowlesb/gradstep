// The request remains open until the pipeline's worker thread finishes or is stopped.
// Do not detach work from this lifecycle: Cloud Run uses request-based CPU billing.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import type { RunResult } from './run.ts';

/** Leave a full minute for termination, logging and the response before Cloud Run's 900 s limit. */
export const HARD_RUN_LIMIT_MS = 840_000;
const log = (event: string, fields: Record<string, unknown> = {}) => console.log(JSON.stringify({ event, ...fields }));

export function sameSecret(given: string, expected: string): boolean {
  const a = Buffer.from(given), b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export class RunFailure extends Error {
  readonly code: 'run_timeout' | 'worker_failed' | 'worker_stopped' | 'invalid_worker_result';
  constructor(code: RunFailure['code']) { super(code); this.code = code; }
}

/** A real thread boundary enforces the wall-clock bound even if a renderer blocks its JS event loop.
 * Termination does not retry or settle paid work: fenced claims and durable provider grants survive it.
 * The small options surface permits real, provider-free worker fixtures in lifecycle tests. */
export function runInWorker(options: { url?: URL; timeoutMs?: number } = {}): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const url = options.url ?? new URL('./run.ts', import.meta.url);
    const worker = new Worker(url, { workerData: { pipelineRun: 1, entryPoint: url.href } });
    let finishing = false;
    const finish = async (result?: RunResult, error?: RunFailure) => {
      if (finishing) return;
      finishing = true;
      clearTimeout(timer);
      try {
        // Always join, including after success: nothing may continue after the HTTP response.
        await worker.terminate();
        if (error) reject(error); else resolve(result!);
      } catch { reject(new RunFailure('worker_failed')); }
    };
    const timer = setTimeout(() => { void finish(undefined, new RunFailure('run_timeout')); }, options.timeoutMs ?? HARD_RUN_LIMIT_MS);
    worker.once('message', (value: unknown) => {
      const message = value as { ok?: unknown; result?: Partial<RunResult> } | null;
      if (message?.ok === false) return void finish(undefined, new RunFailure('worker_failed'));
      if (message?.ok !== true || !Number.isSafeInteger(message.result?.processed) || message.result!.processed! < 0
        || !Number.isFinite(message.result?.ms) || message.result!.ms! < 0) {
        return void finish(undefined, new RunFailure('invalid_worker_result'));
      }
      void finish(message.result as RunResult);
    });
    worker.once('error', () => { void finish(undefined, new RunFailure('worker_failed')); });
    worker.once('exit', () => { void finish(undefined, new RunFailure('worker_stopped')); });
  });
}

/** One independent handler per server; one in-flight run per instance. */
export function createHandler(run: () => Promise<RunResult> = runInWorker) {
  let running: Promise<RunResult> | null = null;
  return async function handle(request: IncomingMessage, response: ServerResponse, secret = process.env.PIPELINE_SECRET): Promise<void> {
    const send = (status: number, body: unknown) => {
      response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
      response.end(JSON.stringify(body));
    };
    request.resume();
    if (request.method === 'GET' && request.url === '/health') return send(200, { ok: true });
    if (request.method !== 'POST') return send(405, { code: 'method_unavailable' });
    const given = request.headers['x-pipeline-secret'];
    if (!secret || secret.length < 32 || typeof given !== 'string' || !sameSecret(given, secret)) return send(401, { code: 'unauthorized' });
    if (running) return send(202, { accepted: true, busy: true });
    // Promise.resolve also gives a synchronous constructor error the same bounded failure path.
    running = Promise.resolve().then(run);
    try {
      const result = await running;
      log('run_finished', { processed: result.processed, ms: result.ms });
      send(200, { accepted: true, processed: result.processed });
    } catch (error) {
      const code = error instanceof RunFailure ? error.code : 'worker_failed';
      log('run_failed', { code });
      send(code === 'run_timeout' ? 504 : 500, { code: 'run_failed' });
    } finally { running = null; }
  };
}

export const handle = createHandler();
if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 8080);
  createServer((request, response) => { void handle(request, response); }).listen(port, () => log('listening', { port }));
}
