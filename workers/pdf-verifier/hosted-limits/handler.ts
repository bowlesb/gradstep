import { runBackground, runCPU, runMemory, type Clock, type Start, type Synthetic, type WorkResult } from './workloads.ts';

export const CASES = ['deny_missing_auth', 'deny_wrong_run', 'deny_invalid_case', 'control',
  'cpu-wasm', 'memory-wasm', 'background', 'recovery'] as const;
export type CaseName = typeof CASES[number];
export type WorkCase = Exclude<CaseName, 'deny_missing_auth' | 'deny_wrong_run' | 'deny_invalid_case'>;
export const RUNTIME = 'supabase-edge-runtime-1.77.0 (compatible with Deno v2.1.4)';
export const BUILD = '39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610';
export const SOURCE_HEADER = 'x-probe-source-sha256';
export type Config = {
  project: string; runID: string; userID: string; createdAt: number; expiresAt: number;
  buildSHA256: string; path: string; requests: readonly { case: CaseName; attemptID: string }[];
};
type EventName = 'start' | 'complete' | 'fallback' | 'allocation_refused' | 'heartbeat' | 'beforeunload' | 'failed';
export type Event = {
  probe: 'hosted-limits-v1'; event: EventName; run_id: string; attempt_id: string; case: WorkCase;
  source_sha256: string; deployment_id: string; execution_id: string; isolate_id: string;
  runtime_version: string; sequence: number; elapsed_ms: number | null; pages: number | null;
};
export type Dependencies = {
  authenticate(token: string, signal: AbortSignal): Promise<unknown>;
  synthetic(): Promise<Synthetic>;
  recover(): Promise<{ outcome: string; pages: number | null; sha256: string }>;
  fixtureSHA256: string;
  now(): number; monotonic(): number; sleep(ms: number): Promise<void>;
  waitUntil(promise: Promise<void>): void;
  runtimeVersion: string; deploymentID: string | null; executionID: string | null; isolateID: string;
  log(event: Event): void;
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha = /^[0-9a-f]{64}$/;
const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);
const response = (status: number, value: unknown) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
});

async function body(request: Request): Promise<{ run_id: string; attempt_id: string; case: string }> {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json' ||
      !request.body || request.signal.aborted) throw new Error('invalid_request');
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > 512)) throw new Error('invalid_request');
  const reader = request.body.getReader();
  let stop = () => {}, timer: ReturnType<typeof setTimeout> | undefined, stopped = false;
  const timeout = new Promise<never>((_, reject) => {
    stop = () => { stopped = true; reject(new Error('invalid_request')); void reader.cancel().catch(() => {}); };
    timer = setTimeout(stop, 3000);
  });
  request.signal.addEventListener('abort', stop, { once: true });
  try {
    const bytes = new Uint8Array(512); let length = 0;
    while (true) {
      const { done, value } = await Promise.race([reader.read(), timeout]);
      if (stopped || request.signal.aborted) throw new Error('invalid_request');
      if (done) break;
      if (length + value.byteLength > 512) throw new Error('invalid_request');
      bytes.set(value, length); length += value.byteLength;
    }
    if (declared !== null && Number(declared) !== length) throw new Error('invalid_request');
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length));
    // Flat, unescaped public identifiers only. Duplicate/unknown keys cannot be
    // hidden by JSON.parse's last-key-wins behavior.
    const skeleton = text.replace(/"(?:run_id|attempt_id|case)"\s*:\s*"[A-Za-z0-9_-]{1,64}"/g, 'F');
    if (!/^\s*\{\s*F\s*,\s*F\s*,\s*F\s*\}\s*$/.test(skeleton)) throw new Error('invalid_request');
    const value = JSON.parse(text);
    if (!object(value) || Object.keys(value).sort().join(',') !== 'attempt_id,case,run_id' ||
        typeof value.run_id !== 'string' || !uuid.test(value.run_id) ||
        typeof value.attempt_id !== 'string' || !uuid.test(value.attempt_id) || typeof value.case !== 'string') throw new Error('invalid_request');
    return value as { run_id: string; attempt_id: string; case: string };
  } finally {
    clearTimeout(timer); request.signal.removeEventListener('abort', stop);
    void reader.cancel().catch(() => {}); reader.releaseLock();
  }
}

export function createHandler(input: Config, dependencies: Dependencies) {
  const config = Object.freeze({ ...input, requests: Object.freeze(input.requests.map(item => Object.freeze({ ...item }))) });
  const deps = { ...dependencies };
  if (config.project !== 'coxhjvqpflgxkleydati' || !uuid.test(config.runID) || !uuid.test(config.userID) ||
      config.buildSHA256 !== BUILD || !Number.isSafeInteger(config.createdAt) || !Number.isSafeInteger(config.expiresAt) ||
      config.expiresAt - config.createdAt !== 1_200_000 || config.createdAt <= 0 ||
      config.path !== `/pdf-verifier-probe-${config.runID.slice(0, 8)}` || !uuid.test(deps.isolateID) || !sha.test(deps.fixtureSHA256) ||
      config.requests.length !== 8 || config.requests.some((item, index) => item.case !== CASES[index] || !uuid.test(item.attemptID)) ||
      new Set(config.requests.map(item => item.attemptID)).size !== 8) throw new Error('invalid_probe_config');
  const deploymentValid = typeof deps.deploymentID === 'string' && new RegExp(`^${config.project}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_1$`).test(deps.deploymentID);
  let busy = false;
  const consumed = new Set<string>();
  let advisory: (() => void) | null = null;
  const active = (remaining: number) => Number.isFinite(deps.now()) && deps.now() >= config.createdAt && deps.now() + remaining < config.expiresAt;
  return {
    beforeUnload() { advisory?.(); },
    async fetch(request: Request): Promise<Response> {
      const url = new URL(request.url);
      if (request.method !== 'POST' || ![config.path, '/functions/v1' + config.path].includes(url.pathname) || url.search) return response(404, { error: 'unavailable' });
      if (!active(180_000)) return response(410, { error: 'probe_expired' });
      if (deps.runtimeVersion !== RUNTIME || !deploymentValid || !deps.executionID || !uuid.test(deps.executionID)) return response(503, { error: 'invalid_probe_environment' });
      const authorization = request.headers.get('authorization');
      if (!authorization || !/^Bearer [A-Za-z0-9_.-]{20,4096}$/.test(authorization)) return response(401, { error: 'unauthorized' });
      let value: Awaited<ReturnType<typeof body>>;
      try { value = await body(request); } catch { return response(400, { error: 'invalid_request' }); }
      if (value.run_id !== config.runID) return response(403, { error: 'forbidden' });
      if (!(CASES.slice(3) as readonly string[]).includes(value.case)) return response(400, { error: 'invalid_request' });
      const name = value.case as WorkCase;
      if (config.requests.find(item => item.case === name)?.attemptID !== value.attempt_id) return response(403, { error: 'forbidden' });
      const source = request.headers.get(SOURCE_HEADER);
      if (!source || !sha.test(source)) return response(403, { error: 'forbidden' });
      const controller = new AbortController();
      let authTimer: ReturnType<typeof setTimeout> | undefined, authStopped = false;
      const abort = () => controller.abort();
      request.signal.addEventListener('abort', abort, { once: true });
      let user: unknown;
      try {
        user = await Promise.race([deps.authenticate(authorization.slice(7), controller.signal), new Promise<never>((_, reject) => {
          authTimer = setTimeout(() => { authStopped = true; controller.abort(); reject(new Error('auth_unavailable')); }, 5000);
        })]);
        if (authStopped || request.signal.aborted) throw new Error('auth_unavailable');
      } catch { return response(401, { error: 'unauthorized' }); }
      finally { clearTimeout(authTimer); request.signal.removeEventListener('abort', abort); controller.abort(); }
      if (!object(user) || user.id !== config.userID || !object(user.app_metadata) ||
          user.app_metadata.science_reader_check !== 'pdf-verifier-probe' || user.app_metadata.probe_kind !== 'hosted-limits-v1' ||
          user.app_metadata.check_run_id !== config.runID || user.app_metadata.source_manifest_sha256 !== source ||
          user.app_metadata.deployment_id !== deps.deploymentID) return response(403, { error: 'forbidden' });
      if (!active(name === 'background' ? 600_000 : 180_000)) return response(410, { error: 'probe_expired' });
      if (consumed.has(value.attempt_id)) return response(409, { error: 'attempt_consumed' });
      if (busy) return response(429, { error: 'probe_busy' });
      const start: Start = { wall: deps.now(), monotonic: deps.monotonic() };
      if (!Number.isFinite(start.monotonic)) return response(503, { error: 'invalid_probe_clock' });
      consumed.add(value.attempt_id); busy = true;
      const base = { probe: 'hosted-limits-v1' as const, run_id: config.runID, attempt_id: value.attempt_id, case: name,
        source_sha256: source, deployment_id: deps.deploymentID!, execution_id: deps.executionID,
        isolate_id: deps.isolateID, runtime_version: deps.runtimeVersion };
      let sequence = 0, terminal = false, advised = false;
      const elapsed = () => {
        const value = deps.monotonic() - start.monotonic;
        return Number.isFinite(value) && value >= 0 && value <= 500_000 ? value : null;
      };
      const emit = (event: EventName, pages: number | null = null) => {
        if (terminal) return;
        const ms = event === 'start' ? 0 : elapsed();
        if (ms === null && event !== 'failed') throw new Error('workload_clock_invalid');
        if (sequence > 63) throw new Error('probe_event_limit');
        if (['complete', 'fallback', 'allocation_refused', 'failed'].includes(event)) terminal = true;
        deps.log({ ...base, event, sequence: sequence++, elapsed_ms: ms, pages });
      };
      const finish = () => { busy = false; advisory = null; };
      const failed = () => { try { emit('failed'); } catch { /* Never retain raw errors. */ } };
      const result = (state: string, pages: number | null = null, work: WorkResult | null = null) => ({
        schema_version: 1, ...base, result: state, pages, work, elapsed_ms: elapsed(),
        cpu_ms: null, peak_memory_bytes: null, hosted_admitted: false,
      });
      advisory = () => { if (!advised && !terminal) { advised = true; try { emit('beforeunload'); } catch { /* advisory only */ } } };
      const clock: Clock = { now: deps.now, monotonic: deps.monotonic, sleep: deps.sleep,
        cancelled: () => name !== 'background' && request.signal.aborted };
      try {
        emit('start');
        if (name === 'background') {
          let release!: () => void, cancelled = false;
          const gate = new Promise<void>(resolve => { release = resolve; });
          const task = gate.then(async () => {
            if (cancelled) return;
            try { await runBackground(clock, start, () => emit('heartbeat')); emit('fallback'); }
            catch { failed(); }
            finally { finish(); }
          });
          try { deps.waitUntil(task); }
          catch { cancelled = true; release(); throw new Error('wait_until_unavailable'); }
          release();
          return response(202, result('accepted'));
        }
        if (request.signal.aborted) throw new Error('request_cancelled');
        if (name === 'control') { emit('complete'); return response(200, result('complete')); }
        if (name === 'recovery') {
          const recovered = await deps.recover();
          if (recovered.outcome !== 'verified' || recovered.pages !== 1 || recovered.sha256 !== deps.fixtureSHA256) throw new Error('recovery_failed');
          emit('complete', 1); return response(200, result('complete', 1));
        }
        const module = await deps.synthetic();
        const work = name === 'cpu-wasm' ? runCPU(module, clock, start) : await runMemory(module, clock, start);
        emit(work.event); return response(200, result(work.event, null, work));
      } catch { failed(); return response(500, { error: 'workload_failed', ...result('failed') }); }
      finally { if (name !== 'background' || terminal) finish(); }
    },
  };
}
