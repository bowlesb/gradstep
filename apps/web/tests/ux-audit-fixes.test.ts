// UX audit 2026-10-22: the small logic fixes behind the browser's screen findings (S3, S25) and the reader's (R5, R20,
// R22, R24, R26).
import { describe, expect, it } from 'vitest';
import { nextDiscoveryState } from '../src/ui/PaperSearch';
import { loadMessage } from '../src/ui/SupportReports';
import { BackendError } from '../src/lib/backend';
import { catalogCount } from '../src/ui/Catalogs';
import { libraryIsEmpty } from '../src/ui/Library';

describe('Catalogs counts (S13)', () => {
  it('counts the papers the Library shows, then the archived ones', () => {
    expect(catalogCount([{}, { archived: false }, { archived: true }])).toBe('2 papers · 1 archived');
    expect(catalogCount([{}])).toBe('1 paper');
    expect(catalogCount([])).toBe('0 papers');
  });
});

describe('An empty library hides its tools and rail (S11)', () => {
  const model = (all: number, catalogs: number, state = 'ready') => ({ all: Array(all), library: { state, catalogs: { state: { catalogs: Array(catalogs) } } } }) as unknown as Parameters<typeof libraryIsEmpty>[0];
  it('only when nothing is in it and there is no other catalog', () => {
    expect(libraryIsEmpty(model(0, 1))).toBe(true);
    expect(libraryIsEmpty(model(0, 2))).toBe(false);
    expect(libraryIsEmpty(model(1, 1))).toBe(false);
    expect(libraryIsEmpty(model(0, 1, 'loading'))).toBe(false);
  });
});

describe('My reports read failures (S25)', () => {
  it('say the reports could not load, never that a report could not be saved', () => {
    for (const error of [new BackendError('connection'), new Error('x'), new BackendError('report_rate_limit')]) {
      expect(loadMessage(error, 'list')).toBe('Couldn’t load your reports.');
      expect(loadMessage(error, 'thread')).toBe('Couldn’t load this report.');
    }
    expect(loadMessage(new BackendError('sign_in_required'), 'list')).toBe('Sign in again to see your reports.');
  });
});

describe('ML paper search state (S3)', () => {
  it('is idle whenever the query is emptied, whatever the last search left', () => {
    expect(nextDiscoveryState({ kind: 'failed', message: 'x' }, '')).toEqual({ kind: 'idle' });
    expect(nextDiscoveryState({ kind: 'results', results: [] }, '   ')).toEqual({ kind: 'idle' });
    expect(nextDiscoveryState({ kind: 'searching' }, '')).toEqual({ kind: 'idle' });
  });
  it('keeps the last outcome while there is text', () => {
    const failed = { kind: 'failed', message: 'x' } as const;
    expect(nextDiscoveryState(failed, 'sparse')).toBe(failed);
  });
});
