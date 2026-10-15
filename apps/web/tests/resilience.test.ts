import { describe, expect, it } from 'vitest';
import { BackendError, parseRetryAfter } from '../src/lib/backend';
import { clearFaults, faultKind, faultSummary, recentFaults, recordFault } from '../src/lib/faults';
import { asOf, backoffDelay, isTransient, jittered, retryAfterMs } from '../src/lib/retry';

// docs/architecture/RESILIENCE.md: back-off with jitter, the server's wait, transient vs specific failures, and fault
// codes for reports that never carry content.
describe('back-off', () => {
  it('doubles from the base, stays within half to all of the ceiling, and caps', () => {
    expect(backoffDelay(1, 1_000, 60_000, undefined, () => 0)).toBe(500);
    expect(backoffDelay(1, 1_000, 60_000, undefined, () => 1)).toBe(1_000);
    expect(backoffDelay(3, 1_000, 60_000, undefined, () => 1)).toBe(4_000);
    expect(backoffDelay(30, 1_000, 60_000, undefined, () => 1)).toBe(60_000);
    expect(backoffDelay(30, 1_000, 60_000, undefined, () => 0)).toBe(30_000);
  });
  it('never comes back sooner than the server asked, within reason', () => {
    expect(backoffDelay(1, 1_000, 60_000, 30_000, () => 0)).toBe(30_000);
    expect(backoffDelay(1, 1_000, 10_000, 9_999_999, () => 0)).toBe(40_000);
  });
  it('spreads a healthy cadence by about a fifth', () => {
    expect(jittered(60_000, 0.2, () => 0)).toBeCloseTo(48_000);
    expect(jittered(60_000, 0.2, () => 1)).toBeCloseTo(72_000);
  });
});

describe('what is worth retrying', () => {
  it('retries the connection, a busy server and server errors; not specific refusals', () => {
    expect(isTransient(new BackendError('connection'))).toBe(true);
    expect(isTransient(new BackendError('throttled', 429, 30))).toBe(true);
    expect(isTransient(new BackendError('request_failed', 503))).toBe(true);
    expect(isTransient(new BackendError('insufficient_credits', 400))).toBe(false);
    expect(isTransient(new BackendError('sign_in_required', 401))).toBe(false);
    expect(isTransient(new BackendError('request_failed', 404))).toBe(false);
  });
  it('reads the server\'s wait from a header or a body', () => {
    expect(parseRetryAfter('30')).toBe(30);
    expect(parseRetryAfter(null, 12)).toBe(12);
    expect(parseRetryAfter(new Date(Date.UTC(2027, 0, 15, 8, 0, 20)).toUTCString(), undefined, Date.UTC(2027, 0, 15, 8, 0, 0))).toBe(20);
    expect(parseRetryAfter('soon')).toBeUndefined();
    expect(parseRetryAfter('99999')).toBe(3600);
    expect(retryAfterMs(new BackendError('throttled', 429, 30))).toBe(30_000);
    expect(retryAfterMs(new Error('x'))).toBeUndefined();
  });
  it('says when last-good data is from', () => {
    const now = Date.UTC(2027, 0, 15, 12, 0, 0);
    expect(asOf(now - 30_000, now)).toBe('a minute ago');
    expect(asOf(now - 12 * 60_000, now)).toBe('12 minutes ago');
  });
});

describe('fault codes for reports', () => {
  it('keep a region and a kind, never the message', () => {
    clearFaults();
    recordFault('chat', new TypeError('Cannot read properties of undefined (reading "title") — secret paper text'));
    recordFault('feed', new BackendError('connection'));
    expect(recentFaults().map(f => `${f.region}:${f.kind}`)).toEqual(['chat:TypeError', 'feed:Error:connection']);
    expect(faultSummary()).not.toContain('secret');
    expect(faultKind('a string')).toBe('String');
    for (let i = 0; i < 20; i++) recordFault('app', new Error('x'));
    expect(recentFaults().length).toBe(8);
  });
});
