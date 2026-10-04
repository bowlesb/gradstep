/** Closed, short-lived hosted compatibility probe. No acquisition authority. */
import type { Measurement } from '../runtime.ts';

export const CASES = [
  'pages-1', 'pages-25', 'pages-50', 'pages-51', 'not-pdf',
  'corrupt-flate', 'unsupported-filter', 'stream-budget',
  'object-stream-small', 'object-stream-oom', 'job-json-encrypt-40',
] as const;
export type CaseName = typeof CASES[number];
export type ProbeConfig = {
  project: string; runID: string; userID: string; createdAt: number; expiresAt: number;
  buildSHA256: string; path: string;
};
type Runtime = { deno: string; v8: string; typescript: string };
type MemorySnapshot = { rss: number; heapTotal: number; heapUsed: number; external: number };
export const PROBE_STAGES = ['initialization', 'fixture_decode', 'fixture_hash', 'verification', 'result_check'] as const;
export type ProbeStage = typeof PROBE_STAGES[number];
export const PROBE_CODES = ['invalid_profile', 'verifier_build_mismatch', 'verifier_abi_mismatch',
  'invalid_verifier_memory', 'invalid_verifier_import', 'invalid_verifier_memory_export', 'one_verification_at_a_time',
  'probe_fixture_mismatch', 'probe_result_mismatch', 'unknown'] as const;
export const PROBE_ERROR_CLASSES = ['Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError', 'URIError',
  'EvalError', 'AggregateError', 'DOMException', 'WebAssembly.CompileError', 'WebAssembly.LinkError',
  'WebAssembly.RuntimeError', 'non_error'] as const;
export const PROBE_OUTCOMES = ['verified', 'malformed', 'encrypted', 'unsupported', 'parser_resource_limit',
  'resource_limit', 'internal_error', 'input_limit', 'page_limit', 'binding_mismatch'] as const;
type ProbeDiagnostic = {
  stage: ProbeStage; code: typeof PROBE_CODES[number]; error_class: typeof PROBE_ERROR_CLASSES[number];
  observed_outcome: typeof PROBE_OUTCOMES[number] | null; observed_pages: number | null;
};

function errorClass(error: unknown): ProbeDiagnostic['error_class'] {
  // Never read name, constructor.name, stack, cause or a string conversion.
  if (error instanceof WebAssembly.CompileError) return 'WebAssembly.CompileError';
  if (error instanceof WebAssembly.LinkError) return 'WebAssembly.LinkError';
  if (error instanceof WebAssembly.RuntimeError) return 'WebAssembly.RuntimeError';
  if (error instanceof TypeError) return 'TypeError';
  if (error instanceof RangeError) return 'RangeError';
  if (error instanceof SyntaxError) return 'SyntaxError';
  if (error instanceof ReferenceError) return 'ReferenceError';
  if (error instanceof URIError) return 'URIError';
  if (error instanceof EvalError) return 'EvalError';
  if (error instanceof AggregateError) return 'AggregateError';
  if (error instanceof DOMException) return 'DOMException';
  return error instanceof Error ? 'Error' : 'non_error';
}

function diagnostic(stage: ProbeStage, error: unknown, observed?: unknown): Readonly<ProbeDiagnostic> {
  let code: ProbeDiagnostic['code'] = 'unknown', category: ProbeDiagnostic['error_class'] = 'non_error';
  let outcome: ProbeDiagnostic['observed_outcome'] = null, pages: number | null = null;
  try {
    category = errorClass(error);
    // Only exact known literals survive. Even a familiar prefix plus private
    // content is unknown, and no original Error is retained by the wrapper.
    if (error instanceof Error) {
      const message = error.message;
      if (PROBE_CODES.includes(message as ProbeDiagnostic['code'])) code = message as ProbeDiagnostic['code'];
    }
  } catch { /* Hostile property access stays redacted. */ }
  try {
    if (stage === 'result_check' && observed !== null && typeof observed === 'object') {
      const value = observed as Record<string, unknown>;
      const observedOutcome = value.outcome, observedPages = value.pages;
      if (PROBE_OUTCOMES.includes(observedOutcome as typeof PROBE_OUTCOMES[number])) outcome = observedOutcome as ProbeDiagnostic['observed_outcome'];
      if (Number.isInteger(observedPages) && (observedPages as number) >= 0 && (observedPages as number) <= 2_147_483_647) pages = observedPages as number;
    }
  } catch { /* Unexpected result fields cannot disclose diagnostics. */ }
  return Object.freeze({ stage, code, error_class: category, observed_outcome: outcome, observed_pages: pages });
}

class ProbeFailure extends Error {
  readonly diagnostic: Readonly<ProbeDiagnostic>;
  constructor(stage: ProbeStage, error: unknown, observed?: unknown) {
    super('probe_failed');
    this.diagnostic = diagnostic(stage, error, observed);
  }
}

/** Retains only the fixed diagnostic DTO, never the original Error or result. */
export async function withProbeStage<T>(stage: ProbeStage, work: () => T | Promise<T>, observed?: unknown): Promise<T> {
  try { return await work(); }
  catch (error) { throw new ProbeFailure(stage, error, observed); }
}
type Executor = {
  coldLoadMS: number;
  verify(name: CaseName): Promise<Measurement>;
};
export type ProbeDependencies = {
  authenticate(token: string, signal: AbortSignal): Promise<unknown>;
  initialize(): Promise<Executor>;
  now(): number;
  runtime: Runtime;
  deploymentID: string | null;
  executionID: string | null;
  isolateID: string;
  memory(): MemorySnapshot | null;
  log(event: Record<string, unknown>): void;
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const hash = /^[0-9a-f]{64}$/;
const json = (status: number, value: unknown) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
});
const object = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

async function limitedBody(request: Request): Promise<unknown> {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('invalid_request');
  const length = request.headers.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > 512)) throw new Error('invalid_request');
  if (!request.body || request.signal.aborted) throw new Error('invalid_request');
  const reader = request.body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let stopped = false;
  let stop: () => void = () => {};
  const timeout = new Promise<never>((_, reject) => {
    stop = () => {
      stopped = true;
      reject(new Error('invalid_request'));
      // Cancellation may fulfill a pending read with done:true. The explicit
      // stopped fence prevents a valid prefix becoming a complete body.
      void reader.cancel().catch(() => {});
    };
    timer = setTimeout(stop, 3000);
  });
  request.signal.addEventListener('abort', stop, { once: true });
  try {
    const parts: Uint8Array[] = []; let size = 0;
    while (true) {
      const { done, value } = await Promise.race([reader.read(), timeout]);
      if (stopped || request.signal.aborted) throw new Error('invalid_request');
      if (done) break;
      size += value.byteLength;
      if (size > 512) throw new Error('invalid_request');
      parts.push(new Uint8Array(value));
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.length; }
    if (stopped || request.signal.aborted || (length !== null && size !== Number(length))) throw new Error('invalid_request');
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } finally {
    clearTimeout(timer);
    request.signal.removeEventListener('abort', stop);
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export function createProbeHandler(input: ProbeConfig, dependencies: ProbeDependencies) {
  const config = Object.freeze({ ...input });
  const deps = { ...dependencies, runtime: { ...dependencies.runtime } };
  if (config.project !== 'coxhjvqpflgxkleydati' || !uuid.test(config.runID) || !uuid.test(config.userID) ||
      !hash.test(config.buildSHA256) || !Number.isSafeInteger(config.createdAt) || !Number.isSafeInteger(config.expiresAt) ||
      config.expiresAt <= config.createdAt || config.expiresAt - config.createdAt > 1_200_000 ||
      config.path !== `/pdf-verifier-probe-${config.runID.slice(0, 8)}` || !uuid.test(deps.isolateID)) throw new Error('invalid_probe_config');
  let executor: Promise<Executor> | undefined;
  let busy = false, ordinal = 0;
  const active = () => deps.now() >= config.createdAt && deps.now() < config.expiresAt;
  return async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    // Supabase routes the function under /functions/v1/<slug>; local tests may
    // use /<slug>. No query, suffix, alternate function, or CORS entry point.
    if (request.method !== 'POST' || ![config.path, '/functions/v1' + config.path].includes(url.pathname) || url.search) return json(404, { error: 'unavailable' });
    if (!active()) return json(410, { error: 'probe_expired' });
    const authorization = request.headers.get('authorization');
    if (!authorization || !/^Bearer [A-Za-z0-9_.-]{20,4096}$/.test(authorization)) return json(401, { error: 'unauthorized' });
    let body: unknown;
    try { body = await limitedBody(request); } catch { return json(400, { error: 'invalid_request' }); }
    if (!object(body) || Object.keys(body).sort().join(',') !== 'fixture,run_id' || body.run_id !== config.runID ||
        typeof body.fixture !== 'string' || !CASES.includes(body.fixture as CaseName)) return json(400, { error: 'invalid_request' });
    const name = body.fixture as CaseName;
    const controller = new AbortController();
    let authTimer: ReturnType<typeof setTimeout> | undefined;
    let authTimedOut = false;
    const abortAuth = () => controller.abort();
    request.signal.addEventListener('abort', abortAuth, { once: true });
    let user: unknown;
    try {
      user = await Promise.race([deps.authenticate(authorization.slice(7), controller.signal), new Promise<never>((_, reject) => {
        authTimer = setTimeout(() => { authTimedOut = true; reject(new Error('auth_unavailable')); controller.abort(); }, 5000);
      })]);
      if (authTimedOut || request.signal.aborted) throw new Error('auth_unavailable');
    } catch { return json(401, { error: 'unauthorized' }); }
    finally { clearTimeout(authTimer); request.signal.removeEventListener('abort', abortAuth); controller.abort(); }
    if (!object(user) || user.id !== config.userID || !object(user.app_metadata) ||
        user.app_metadata.science_reader_check !== 'pdf-verifier-probe' || user.app_metadata.check_run_id !== config.runID) return json(403, { error: 'forbidden' });
    if (!active()) return json(410, { error: 'probe_expired' });
    if (busy || ordinal >= 40) return json(429, { error: 'probe_capacity' });
    busy = true; ordinal += 1;
    const execution = {
      run_id: config.runID, fixture: name, isolate_id: deps.isolateID,
      deployment_id: deps.deploymentID, execution_id: deps.executionID, ordinal, build_sha256: config.buildSHA256,
    };
    const cold = executor === undefined;
    let stage: ProbeStage = 'initialization';
    let initializationWallMS: number | null = null;
    try {
      deps.log({ event: 'pdf_probe_start', ...execution });
      if (request.signal.aborted) return json(408, { error: 'request_cancelled' });
      executor ??= deps.initialize(); // No compilation before authorization.
      const loaded = await executor;
      initializationWallMS = cold ? loaded.coldLoadMS : 0;
      if (request.signal.aborted) return json(408, { error: 'request_cancelled' });
      if (!active()) return json(410, { error: 'probe_expired' });
      stage = 'verification';
      const result = await loaded.verify(name);
      let memory: MemorySnapshot | null = null;
      try { memory = deps.memory(); } catch { /* unsupported measurement remains absent */ }
      const response = {
        ...execution, runtime: deps.runtime, cold,
        initialization_wall_ms: initializationWallMS,
        result, memory_snapshot: memory, cpu_ms: null, peak_memory_bytes: null,
        hosted_admitted: false,
      };
      deps.log({ event: 'pdf_probe_complete', ...execution, outcome: result.outcome, elapsed_ms: result.elapsedMS });
      return json(200, response);
    } catch (error) {
      const failure = error instanceof ProbeFailure ? error.diagnostic : diagnostic(stage, error);
      deps.log({ event: 'pdf_probe_failed', ...execution, diagnostic: failure });
      return json(500, { error: 'probe_failed', ...execution, runtime: deps.runtime, cold,
        initialization_wall_ms: initializationWallMS, diagnostic: failure,
        cpu_ms: null, peak_memory_bytes: null, hosted_admitted: false });
    } finally { busy = false; }
  };
}
