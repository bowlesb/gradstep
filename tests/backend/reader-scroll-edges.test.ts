// Wide tables and equations scroll sideways in flat boxes on every surface (owner, build 58, Table 4 of a wide-table
// paper: "I really dislike this gradient"). The scroll shadows lived in the app-owned reader bridge
// (apps/apple/ScienceReader/Resources/reader-bridge.js), which the iPhone, iPad and Mac readers inject and the browser
// reader's frame runs byte for byte (apps/web/vite.config.ts); the bundle's own stylesheet never had one.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ARXIV_CSS } from '../../supabase/functions/_shared/reader/arxiv-bundle.ts';
import { READER_CSS } from '../../supabase/functions/_shared/reader/profile.ts';

const bridge = readFileSync(new URL('../../apps/apple/ScienceReader/Resources/reader-bridge.js', import.meta.url), 'utf8');

test('no gradient in the reader bridge or the bundle stylesheet; tables and display math still scroll in their own boxes', () => {
  assert.doesNotMatch(bridge, /gradient\(/);
  assert.doesNotMatch(ARXIV_CSS, /gradient\(/);
  assert.match(READER_CSS, /\.reader-table\{overflow-x:auto;/);
  assert.match(READER_CSS, /\.reader-display\{[^}]*overflow-x:auto/);
  // Nothing paints a background on the scrolling boxes: the table sits flat on the page in light and dark.
  // (The sticky equation number keeps the page colour behind it, so the equation scrolls under it.)
  assert.doesNotMatch(bridge, /\.reader-(?:table|display|inline-wide)(?=[,{])[^{']*\{[^}']*background/);
});

test('an edge with more of the box beyond it shows a hairline, defined for light and dark', () => {
  assert.match(bridge, /:root\{[^}]*--sr-edge:rgba\([^)]*\)[^}]*\}@media\(prefers-color-scheme:dark\)\{:root\{[^}]*--sr-edge:rgba\([^)]*\)/);
  assert.match(bridge, /\.sr-more-left\{box-shadow:inset 1px 0 0 var\(--sr-edge\)\}/);
  assert.match(bridge, /\.sr-more-right\{box-shadow:inset -1px 0 0 var\(--sr-edge\)\}/);
  const source = /const scrollEdges = (box => \{[\s\S]*?\n {2}\});/.exec(bridge);
  assert.ok(source, 'the bridge marks scroll edges');
  const scrollEdges = new Function(`return ${source[1]};`)() as (box: unknown) => void;
  const box = (scrollWidth: number, clientWidth: number, scrollLeft: number) => {
    const classes = new Set<string>();
    const element = { scrollWidth, clientWidth, scrollLeft, classList: { toggle: (name: string, on: boolean) => { if (on) classes.add(name); else classes.delete(name); } } };
    scrollEdges(element);
    return [...classes].sort();
  };
  assert.deepEqual(box(400, 400, 0), [], 'a table that fits has no edge');
  assert.deepEqual(box(900, 400, 0), ['sr-more-right'], 'at the start: more to the right');
  assert.deepEqual(box(900, 400, 200), ['sr-more-left', 'sr-more-right']);
  assert.deepEqual(box(900, 400, 500), ['sr-more-left'], 'at the end: more to the left');
});
