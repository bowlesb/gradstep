// UX audit 2026-10-22: the small logic fixes behind the browser's screen findings (S3, S25) and the reader's (R5, R20,
// R22, R24, R26).
import { describe, expect, it } from 'vitest';
import { nextDiscoveryState } from '../src/ui/PaperSearch';
import { loadMessage } from '../src/ui/SupportReports';
import { BackendError } from '../src/lib/backend';
import { catalogCount } from '../src/ui/Catalogs';
import { libraryIsEmpty } from '../src/ui/Library';
import { focusSearch } from '../src/ui/ReadingMode';
import { paperExplainerTap } from '../src/ui/PaperExplainer';
import { composerBalance, creditsUsed, keepStarters, starterSeedFor } from '../src/ui/ChatPane';
import { paneWanted } from '../src/ui/prefs';
import { placeCapsule } from '../src/ui/SelectionActions';
import { readFrameMessage } from '../src/reader/frame';

describe('/ and ⌘K in reading mode (R5)', () => {
  it('leaves reading mode first, committed at once, then focuses the field', () => {
    const calls: string[] = [];
    focusSearch({ on: true, exit: () => calls.push('exit') }, () => calls.push('focus'), run => { calls.push('commit'); run(); });
    expect(calls).toEqual(['commit', 'exit', 'focus']);
  });
  it('focuses at once outside reading mode', () => {
    const calls: string[] = [];
    focusSearch({ on: false, exit: () => calls.push('exit') }, () => calls.push('focus'), () => { throw new Error('no commit needed'); });
    focusSearch(null, () => calls.push('focus'));
    expect(calls).toEqual(['focus', 'focus']);
  });
});

describe('Paper AI Explainer (R20)', () => {
  it('asks which model only on the tap, and only without a default', () => {
    expect(paperExplainerTap(false)).toBe('choose');
    expect(paperExplainerTap(true)).toBe('run');
  });
});

describe('Credits under the message box and on answers (R22)', () => {
  const balance = (available: number, extra: object = {}) => ({ available, reserved: 0, ...extra });
  it('shows the balance only when it may not cover the chosen answer, or an answer was refused', () => {
    expect(composerBalance(balance(1000), 41, false, null)).toBeNull();
    expect(composerBalance(balance(30), 41, false, null)).toBe('30 credits left');
    expect(composerBalance(balance(45), null, false, null)).toBe('45 credits left');
    expect(composerBalance(balance(1000), 41, true, '2:05 PM')).toBe('1,000 credits left · as of 2:05 PM');
    expect(composerBalance(balance(1, { reserved: 4 }), 41, false, null)).toBe('1 credit left · 4 held');
    expect(composerBalance(balance(0, { unlimited_testing: true }), 41, true, null)).toBeNull();
    expect(composerBalance(null, 41, true, null)).toBeNull();
  });
  it('says what an answer used', () => {
    expect(creditsUsed(3)).toBe('3 credits used');
    expect(creditsUsed(1)).toBe('1 credit used');
    expect(creditsUsed(null)).toBeNull();
  });
});

describe('Starter questions across the chat pane closing and opening (R24)', () => {
  it('keeps the seed for a chat, and for the empty chat that silently replaces it; New chat gets a fresh one', () => {
    const seeds = new Map<string, { composerID: string; seed: number }>(), alive = new Set(['a']);
    let next = 10;
    const fresh = () => next++, has = (id: string) => alive.has(id);
    expect(starterSeedFor('paper', 'a', has, seeds, fresh)).toBe(10);
    expect(starterSeedFor('paper', 'a', has, seeds, fresh)).toBe(10); // the pane closed and opened again
    alive.delete('a'); alive.add('b');
    expect(starterSeedFor('paper', 'b', has, seeds, fresh)).toBe(10); // the empty chat was retired and replaced
    alive.add('c');
    expect(starterSeedFor('paper', 'c', has, seeds, fresh)).toBe(11); // New chat beside the last one
    expect(starterSeedFor('general', 'g', has, seeds, fresh)).toBe(12);
  });
  it('keeps the first full set shown, even if the paper’s structure later picks others', () => {
    const seeds = new Map<string, { composerID: string; seed: number; starters?: { category: string; icon: string; text: string }[] }>();
    starterSeedFor('paper', 'a', () => true, seeds, () => 1);
    const first = [{ category: 'x', icon: 'list', text: 'One' }], later = [{ category: 'y', icon: 'list', text: 'Two' }];
    expect(keepStarters('paper', 'a', [], seeds)).toEqual([]);
    expect(keepStarters('paper', 'a', first, seeds)).toBe(first);
    expect(keepStarters('paper', 'a', later, seeds)).toBe(first);
  });
});

describe('A paper’s contents panel at tablet widths (R26)', () => {
  const layout = (chosen?: string[]) => ({ left: 272, right: 392, chosen,
    open: { library: { left: true, right: false }, paper: { left: true, right: true }, feed: { left: true, right: false }, notes: { left: true, right: false } } });
  it('starts closed below 1100 px until the reader chooses', () => {
    expect(paneWanted(layout(), 'paper', 'left', 834)).toBe(false);
    expect(paneWanted(layout(), 'paper', 'left', 1024)).toBe(false);
    expect(paneWanted(layout(['paper.left']), 'paper', 'left', 834)).toBe(true);
    expect(paneWanted(layout(), 'paper', 'left', 1280)).toBe(true);
    expect(paneWanted(layout(), 'paper', 'right', 834)).toBe(true);
    expect(paneWanted(layout(), 'library', 'left', 834)).toBe(true);
  });
});

describe('Selection actions beside the selection (R15, owner 2026-10-22)', () => {
  const stage = { w: 800, h: 600 }, size = { w: 220, h: 40 }, column: [number, number] = [100, 700];
  it('sits just above the selection, centred on it', () => {
    expect(placeCapsule({ x: 300, y: 300, w: 200, h: 40 }, column, stage, size)).toEqual({ left: 290, top: 252 });
  });
  it('goes below the selection near the top of the view', () => {
    expect(placeCapsule({ x: 300, y: 20, w: 200, h: 40 }, column, stage, size)).toEqual({ left: 290, top: 68 });
  });
  it('stays inside the paper column', () => {
    expect(placeCapsule({ x: 90, y: 300, w: 20, h: 20 }, column, stage, size)!.left).toBe(100);
    expect(placeCapsule({ x: 690, y: 300, w: 20, h: 20 }, column, stage, size)!.left).toBe(480);
  });
  it('hides while the selection is scrolled out of view', () => {
    expect(placeCapsule({ x: 300, y: -80, w: 200, h: 40 }, column, stage, size)).toBeNull();
    expect(placeCapsule({ x: 300, y: 640, w: 200, h: 40 }, column, stage, size)).toBeNull();
  });
  it('reads the frame’s selection geometry and right-clicks, bounded', () => {
    expect(readFrameMessage({ type: 'selectionRect', rect: [1, 2, 3, 4], column: [0, 700] })).toEqual({ type: 'selectionRect', rect: [1, 2, 3, 4], column: [0, 700] });
    expect(readFrameMessage({ type: 'selectionRect', rect: null, column: [0, 700] })).toEqual({ type: 'selectionRect', rect: null, column: [0, 700] });
    expect(readFrameMessage({ type: 'selectionRect', rect: [1, 2, 'x', 4], column: [0, 700] })).toBeNull();
    expect(readFrameMessage({ type: 'selectionMenu', x: 10, y: 20 })).toEqual({ type: 'selectionMenu', x: 10, y: 20 });
    expect(readFrameMessage({ type: 'selectionMenu', x: Infinity, y: 20 })).toBeNull();
  });
});

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
