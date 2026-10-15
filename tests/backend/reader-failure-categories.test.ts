import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Every reason code the device compiler can throw has a category on both surfaces, and the two tables agree
// (audit 2026-10-15: the browser's list was kept by hand and iOS collapsed every refusal to one message).
const root = new URL('../../', import.meta.url);
const read = (path: string) => readFileSync(new URL(path, root), 'utf8');
const converterCodes = new Set<string>();
for (const file of ['arxiv-html.ts', 'arxiv-bundle.ts', 'device-compiler.ts'])
  // The code is the last argument of a refusing helper (`check`, `boundedText`, …) or an Error's message; LaTeXML
  // class names (`ltx_…`) are never codes.
  for (const m of read(`supabase/functions/_shared/reader/${file}`).matchAll(/(?:\b(?:check|boundedText|decodeUTF8|decode64|integer|text)\([^;]*?, |Error\()'((?!ltx_)[a-z][a-z0-9]*_[a-z0-9_]+)'\)/g)) converterCodes.add(m[1]);
const host = read('apps/web/src/reader/arxiv-compiler-host.js');
const browser = new Map<string, string>();
for (const m of host.matchAll(/\[((?:'[a-z0-9_]+',?\s*)+)\]\.includes\(code\)[^;]*?return '([a-z-]+)'/g)) for (const code of m[1].match(/[a-z0-9_]+/g)!) browser.set(code, m[2]);
for (const m of host.matchAll(/code === '([a-z0-9_]+)'\) return '([a-z-]+)'/g)) browser.set(m[1], m[2]);
const swift = read('apps/apple/ScienceReader/Services/ArxivHTMLReader.swift');
const native = new Map<string, string>();
for (const m of swift.matchAll(/\("([a-z-]+)", \[((?:"[a-z0-9_]+",?\s*)+)\]\)/g)) for (const code of m[2].match(/[a-z0-9_]+/g)!) native.set(code, m[1]);

test('every converter reason code has a category in the browser frame and in the app, and the tables agree', () => {
  assert.ok(converterCodes.size >= 40, `found ${converterCodes.size} codes`);
  const missingBrowser = [...converterCodes].filter(c => !browser.has(c)), missingNative = [...converterCodes].filter(c => !native.has(c));
  assert.deepEqual(missingBrowser, [], 'uncategorized in apps/web/src/reader/arxiv-compiler-host.js');
  assert.deepEqual(missingNative, [], 'uncategorized in ArxivCompilerFailure (ArxivHTMLReader.swift)');
  assert.deepEqual([...native].sort(), [...browser].sort(), 'the app and the browser frame categorize the same codes the same way');
});
