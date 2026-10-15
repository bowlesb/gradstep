// Retry timing for every browser loop (docs/architecture/RESILIENCE.md; the native RetryBackoff does the same): a
// failing call backs off exponentially with jitter and honours the server's wait; a healthy poll keeps its cadence with
// a little jitter, so browsers that lost the server together don't come back together.
import { BackendError } from './backend';

/** Milliseconds after `failures` consecutive failures (1 = the first): between half and all of
 * `min(cap, base × 2^(failures−1))`, never shorter than the server's wait. */
export function backoffDelay(failures: number, baseMs: number, capMs: number, retryAfterMs?: number, random = Math.random): number {
  const ceiling = Math.min(capMs, baseMs * 2 ** Math.min(Math.max(failures, 1) - 1, 16));
  const jittered = ceiling * (0.5 + 0.5 * Math.min(Math.max(random(), 0), 1));
  return Math.max(jittered, Math.min(retryAfterMs ?? 0, capMs * 4));
}

/** A healthy cadence spread by ±`spread`. */
export function jittered(ms: number, spread = 0.2, random = Math.random): number {
  return ms * (1 - spread + 2 * spread * Math.min(Math.max(random(), 0), 1));
}

/** The connection, a busy server or an unexplained server error: worth retrying later as is. Specific refusals are not. */
export function isTransient(error: unknown): boolean {
  if (!(error instanceof BackendError)) return error instanceof TypeError || (error instanceof DOMException && error.name === 'TimeoutError');
  if (error.code === 'connection' || error.code === 'throttled' || error.status === 429) return true;
  return error.status >= 500 || (error.code === 'request_failed' && error.status === 0);
}

/** The server's requested wait in milliseconds, when it gave one. */
export function retryAfterMs(error: unknown): number | undefined {
  return error instanceof BackendError && error.retryAfter !== undefined ? error.retryAfter * 1000 : undefined;
}

export { parseRetryAfter } from './backend';

/** When last-good data was loaded, in words: "a minute ago", "14:05", "Oct 14". */
export function asOf(at: number, now = Date.now()): string {
  const seconds = Math.max(0, (now - at) / 1000);
  if (seconds < 90) return 'a minute ago';
  if (seconds < 3600) return `${Math.round(seconds / 60)} minutes ago`;
  const date = new Date(at);
  return seconds < 86_400 ? date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : date.toLocaleDateString([], { month: 'short', day: 'numeric' });
}
