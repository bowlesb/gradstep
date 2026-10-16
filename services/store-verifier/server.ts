import { installEgressGuard } from '../../supabase/functions/_shared/egress.ts';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { pathToFileURL } from 'node:url';
import { storeCryptoCapabilities } from '../../supabase/functions/_shared/app-store.ts';
import { MAX_BODY_BYTES, parseRequest, POLICY_ID, replyFor, unavailable, type VerificationRequest } from './protocol.ts';
import { Capacity, runVerification } from './thread-runner.ts';
import { sdkPatchProof } from './sdk-patch.ts';
// No request from this server may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('store-verifier');

export const BODY_TIMEOUT_MS = 3_000;
export const HEADER_TIMEOUT_MS = 3_000;
export function health(env: NodeJS.ProcessEnv) {
  const capabilities = storeCryptoCapabilities();
  const ocspFreshness = sdkPatchProof();
  const policyValid = env.STORE_VERIFIER_POLICY_ID === POLICY_ID;
  const maintenance = env.STORE_VERIFIER_MAINTENANCE !== 'false';
  const revision = typeof env.K_REVISION === 'string' && /^gradstep-store-verifier-[a-z0-9-]{1,39}$/.test(env.K_REVISION)
    && env.K_REVISION.length <= 63 && !/[^\x21-\x7e]/.test(env.K_REVISION) ? env.K_REVISION : null;
  const node = /^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(process.versions.node) ? process.versions.node : 'unknown';
  return { version: 1, ok: true, policy_id: POLICY_ID, policy_valid: policyValid, maintenance,
    ready: policyValid && !maintenance && Object.values(capabilities).every(Boolean) && ocspFreshness.applied, revision,
    runtime: { node, apple_library: '3.1.0', capabilities, ocsp_freshness: ocspFreshness } };
}
class InputError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}
async function readBody(request: IncomingMessage, signal: AbortSignal, timeout: number): Promise<unknown> {
  if (request.headers['content-type']?.split(';')[0]?.trim().toLowerCase() !== 'application/json'
    || (request.headers['content-encoding'] !== undefined && request.headers['content-encoding'] !== 'identity')) throw new InputError(400, 'invalid_request');
  const length = request.headers['content-length'];
  if (length !== undefined && (!/^[0-9]+$/.test(length) || Number(length) > MAX_BODY_BYTES)) throw new InputError(413, 'payload_too_large');
  return await new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    let finished = false;
    const done = (error?: Error, value?: unknown) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      request.off('data', data); request.off('end', end); request.off('error', errorEvent);
      signal.removeEventListener('abort', abort);
      if (error) { request.pause(); reject(error); } else resolve(value);
    };
    const data = (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) return done(new InputError(413, 'payload_too_large'));
      chunks.push(chunk);
    };
    const end = () => {
      try { done(undefined, JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size)))); }
      catch { done(new InputError(400, 'invalid_request')); }
    };
    const abort = () => done(new InputError(400, 'invalid_request'));
    const errorEvent = () => done(new InputError(400, 'invalid_request'));
    const timer = setTimeout(() => done(new InputError(408, 'request_timeout')), timeout);
    request.on('data', data); request.once('end', end); request.once('error', errorEvent);
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
  });
}
function send(response: ServerResponse, status: number, body: string) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body), connection: 'close' });
  response.end(body);
}
/** Dependency injection is local-test-only. The executable uses these fixed
 * production defaults; environment and HTTP input never choose an executor. */
export function createVerifierServer(options: { env?: NodeJS.ProcessEnv;
  execute?: (request: VerificationRequest, signal: AbortSignal) => Promise<unknown>; bodyTimeoutMS?: number } = {}) {
  const state = health(options.env ?? process.env);
  const capacity = new Capacity();
  const active = new Set<AbortController>();
  const tasks = new Set<Promise<void>>();
  let stopping = false;
  const handle = async (request: IncomingMessage, response: ServerResponse) => {
    const small = (status: number, code: string) => send(response, status, JSON.stringify({ error: code }));
    if (request.method === 'GET' && request.url === '/health') {
      send(response, 200, JSON.stringify({ ...state, ready: state.ready && !stopping })); return;
    }
    if (request.url !== '/verify') { small(404, 'not_found'); return; }
    if (request.method !== 'POST') { small(405, 'method_not_allowed'); return; }
    if (stopping || !state.ready) { small(503, 'maintenance'); return; }
    const release = capacity.acquire();
    if (!release) { small(503, 'busy'); return; }
    const controller = new AbortController(); active.add(controller);
    request.on('error', () => controller.abort()); // Do not expose late socket errors after cancellation.
    const disconnect = () => { if (!response.writableFinished) controller.abort(); };
    response.once('close', disconnect);
    let parsed: VerificationRequest | null = null;
    try {
      parsed = parseRequest(await readBody(request, controller.signal, options.bodyTimeoutMS ?? BODY_TIMEOUT_MS));
      if (!parsed) { small(400, 'invalid_request'); return; }
      const result = await (options.execute ?? runVerification)(parsed, controller.signal);
      const reply = replyFor(parsed, result);
      send(response, reply.status, reply.body);
    } catch (error) {
      if (error instanceof InputError) small(error.status, error.code);
      else if (parsed) { const reply = replyFor(parsed, unavailable()); send(response, reply.status, reply.body); }
      else small(400, 'invalid_request');
    } finally {
      response.off('close', disconnect);
      active.delete(controller); release();
    }
  };
  const server = createServer({ maxHeaderSize: 8 * 1024, headersTimeout: HEADER_TIMEOUT_MS,
    requestTimeout: 6_000, connectionsCheckingInterval: 500, keepAliveTimeout: 1_000 }, (request, response) => {
    const task = handle(request, response);
    tasks.add(task); void task.then(() => tasks.delete(task), () => { tasks.delete(task); response.destroy(); });
  });
  server.maxHeadersCount = 32;
  // Headers occupy no worker slot; Node's header deadline bounds slow clients.
  server.maxConnections = 8;
  return { server, capacity, state, async shutdown() {
    stopping = true;
    for (const controller of active) controller.abort();
    const closed = new Promise<void>(resolve => server.close(() => resolve()));
    server.closeAllConnections();
    await Promise.allSettled([...tasks]);
    await closed;
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const instance = createVerifierServer();
  const port = /^[0-9]{1,5}$/.test(process.env.PORT ?? '') ? Number(process.env.PORT) : 8080;
  if (port < 1 || port > 65535) throw new Error('invalid_port');
  instance.server.listen(port, '0.0.0.0');
  let stopping = false;
  const stop = () => { if (!stopping) { stopping = true; void instance.shutdown().then(() => process.exit(0)); } };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
}
