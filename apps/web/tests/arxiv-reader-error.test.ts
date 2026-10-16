import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { expect, it } from 'vitest';
import { arxivPreparationMessage } from '../src/lib/arxiv-reader-error';

const host = readFileSync(new URL('../src/reader/arxiv-compiler-host.js', import.meta.url), 'utf8');
async function failure(error: Error) {
 let listener!: (event: unknown) => Promise<void>;
 let reply: unknown, closed = false;
 const parent = {};
 runInNewContext(host, {parent, addEventListener: (_: string, fn: typeof listener) => {listener = fn;},
  GradstepArxivReader: {assets: () => {throw error;}}});
 await listener({source:parent, data:{method:'assets'}, ports:[{postMessage: (value: unknown) => {reply=value;}, close: () => {closed=true;}}]});
 expect(closed).toBe(true);
 return reply;
}

it('distinguishes source, adapter, figure and limit failures without forwarding exception text', async () => {
 for (const [code, category, phrase] of [
  ['arxiv_conversion_error', 'source-incomplete', 'arXiv’s HTML'],
  ['arxiv_nested_content', 'formatting', 'formatting'],
  ['arxiv_math_attribute', 'math', 'equation'],
  ['svg_element', 'figure', 'figure'],
  ['arxiv_unresolved_fragment', 'reference', 'internal references'],
  ['image_total_limit', 'limit', 'limits'],
 ]) {
  // The listed code crosses too, for the reader's ⓘ (READER_VERSIONS.md); never the exception's own text.
  expect(await failure(new Error(code))).toEqual({ok:false, failure:category, code});
  expect(arxivPreparationMessage(category)).toContain(phrase);
 }
 expect(await failure(new Error('private source text https://example.test/secret'))).toEqual({ok:false,failure:'unknown',code:null});
 expect(await failure(new Error('arxiv_conversion_error https://example.test/secret'))).toEqual({ok:false,failure:'unknown',code:null});
 expect(arxivPreparationMessage('private source text')).not.toContain('private');
 expect(arxivPreparationMessage('__proto__')).toContain('could not be prepared');
 expect(arxivPreparationMessage(null)).toContain('could not be prepared');
});
