import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { expect, it } from 'vitest';

it('forwards figure-reference return ownership while preserving old bridge calls and origin checks', async () => {
  const listeners = new Map<string, (event: unknown) => void>(), calls: unknown[][] = [];
  const parent = { postMessage() {} }, target = 'https://reader.example.test';
  const scope: Record<string, unknown> = {
    document: { querySelector: () => ({ textContent: JSON.stringify({ parent_origin: target }), remove() {} }), documentElement: { style: {} }, styleSheets: [] },
    MutationObserver: class { observe() {} }, addEventListener: (name: string, fn: (event: unknown) => void) => listeners.set(name, fn),
    parent, __scienceReaderShowFigure: (...args: unknown[]) => calls.push(args),
  };
  scope.window = scope;
  runInNewContext(readFileSync(new URL('../src/reader/frame-shim.js', import.meta.url), 'utf8'), scope);
  const send = (origin: string, args: unknown[]) => listeners.get('message')!({ source: parent, origin, data: { gradstep: 'command', name: 'showFigure', args } });
  send('https://other.example.test', ['forged', true, true]);
  send(target, ['figure-1']);
  send(target, ['table-2', true, true]);
  await Promise.resolve(); await Promise.resolve();
  expect(calls).toEqual([['figure-1', false, false], ['table-2', true, true]]);
});

it('forwards Contents › Equations to the bridge, and does nothing on a bridge without it', async () => {
  const listeners = new Map<string, (event: unknown) => void>(), calls: unknown[][] = [];
  const parent = { postMessage() {} }, target = 'https://reader.example.test';
  const run = (bridge: Record<string, unknown>) => {
    const scope: Record<string, unknown> = {
      document: { querySelector: () => ({ textContent: JSON.stringify({ parent_origin: target }), remove() {} }), documentElement: { style: {} }, styleSheets: [] },
      MutationObserver: class { observe() {} }, addEventListener: (name: string, fn: (event: unknown) => void) => listeners.set(name, fn), parent, ...bridge,
    };
    scope.window = scope;
    runInNewContext(readFileSync(new URL('../src/reader/frame-shim.js', import.meta.url), 'utf8'), scope);
    return (origin: string, args: unknown[]) => listeners.get('message')!({ source: parent, origin, data: { gradstep: 'command', name: 'showEquation', args } });
  };
  const send = run({ __scienceReaderShowEquation: (...args: unknown[]) => calls.push(args) });
  send('https://other.example.test', ['forged', true]);
  send(target, ['S2.E1', 1]);
  await Promise.resolve(); await Promise.resolve();
  expect(calls).toEqual([['S2.E1', true]]);
  const older = run({});
  expect(() => older(target, ['S2.E1', false])).not.toThrow();
  await Promise.resolve(); await Promise.resolve();
});

it('keeps the paper in its frame: a link out is posted to the app, never followed (A18)', () => {
  const listeners = new Map<string, (event: unknown) => void>(), posted: unknown[] = [];
  const parent = { postMessage: (message: unknown) => posted.push(message) }, target = 'https://reader.example.test';
  class Element { constructor(readonly href: string | null) {} closest() { return this.href === null ? null : { getAttribute: () => this.href }; } }
  let collapsed = true;
  const scope: Record<string, unknown> = {
    document: { querySelector: () => ({ textContent: JSON.stringify({ parent_origin: target }), remove() {} }), documentElement: { style: {} }, styleSheets: [] },
    MutationObserver: class { observe() {} }, addEventListener: (name: string, fn: (event: unknown) => void) => listeners.set(name, fn), parent, Element, URL,
    getSelection: () => ({ isCollapsed: collapsed }),
  };
  scope.window = scope;
  runInNewContext(readFileSync(new URL('../src/reader/frame-shim.js', import.meta.url), 'utf8'), scope);
  const click = (href: string | null, defaultPrevented = false) => {
    const event = { target: new Element(href), defaultPrevented, prevented: false, preventDefault() { this.prevented = true; } };
    listeners.get('click')!(event); return event.prevented;
  };
  expect(click('https://example.org/data')).toBe(true);
  expect(click('http://example.org/code')).toBe(true);
  expect(click('#b-1')).toBe(false); // the bridge's in-page jump
  expect(click('https://example.org/handled', true)).toBe(false); // a bridge handler already took it
  expect(click(null)).toBe(false);
  expect(click('javascript:alert(1)')).toBe(true); // never followed, never posted
  collapsed = false;
  expect(click('https://example.org/selected')).toBe(true); // a selection drag over a link: not followed, not opened
  expect(posted).toEqual([
    { gradstep: 'reader', value: { type: 'link', url: 'https://example.org/data' } },
    { gradstep: 'reader', value: { type: 'link', url: 'http://example.org/code' } },
  ]);
});
