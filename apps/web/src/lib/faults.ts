// What went wrong where, for support reports (docs/architecture/RESILIENCE.md fix 2): a region and an error's kind,
// never its message or any content. Memory only, the last few.
export interface Fault { region: string; kind: string; at: number }

const faults: Fault[] = [];
const MAX = 8;

/** The error's class name and, for our own errors, its code — e.g. "TypeError", "BackendError:connection". */
export function faultKind(error: unknown): string {
  if (error && typeof error === 'object') {
    const name = (error as { name?: unknown }).name, code = (error as { code?: unknown }).code;
    const base = typeof name === 'string' && /^[A-Za-z]{1,40}$/.test(name) ? name : 'Error';
    return typeof code === 'string' && /^[a-z0-9_]{1,40}$/.test(code) ? `${base}:${code}` : base;
  }
  return typeof error === 'string' ? 'String' : 'Unknown';
}

export function recordFault(region: string, error: unknown, now = Date.now()): Fault {
  const fault = { region: region.replace(/[^a-z-]/g, '').slice(0, 24) || 'app', kind: faultKind(error), at: now };
  faults.push(fault);
  if (faults.length > MAX) faults.splice(0, faults.length - MAX);
  return fault;
}

export function recentFaults(): readonly Fault[] { return faults; }
export function clearFaults() { faults.length = 0; }

/** "chat:TypeError, app:BackendError:connection" for a report's screen line (bounded). */
export function faultSummary(limit = 3): string {
  return faults.slice(-limit).map(f => `${f.region}:${f.kind}`).join(', ');
}

/** Errors nobody caught: recorded, and the page keeps running. */
export function installGlobalFaultHandlers(target: Pick<Window, 'addEventListener'> = window) {
  target.addEventListener('error', (event: Event) => { recordFault('app', (event as ErrorEvent).error ?? 'error'); });
  target.addEventListener('unhandledrejection', (event: Event) => { recordFault('async', (event as PromiseRejectionEvent).reason); });
}
