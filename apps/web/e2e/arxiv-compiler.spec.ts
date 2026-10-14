import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { expect, test } from '@playwright/test';

const script = readFileSync(new URL('../public/arxiv-reader.js', import.meta.url), 'utf8') + '\n'
 + readFileSync(new URL('../src/reader/arxiv-compiler-host.js', import.meta.url), 'utf8');
const hash = 'sha256-' + createHash('sha256').update(script).digest('base64');
const source = readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html', import.meta.url), 'utf8');
const image = readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)).toString('base64');
const figures = readFileSync(new URL('../../../tests/fixtures/reader-arxiv/figures.html', import.meta.url), 'utf8');

test('isolated HTML compiler preserves content and reports finite failure reasons under production CSP', async ({page}) => {
 await page.goto('/');
 const results = await page.evaluate(async ({script,hash,source,image,figures}) => {
  const frame=document.createElement('iframe'); frame.sandbox.add('allow-scripts');
  frame.srcdoc=`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${hash}'; img-src data:; connect-src 'none'; style-src 'none'; base-uri 'none'"><script>${script}</script>`;
  const loaded=new Promise<void>(resolve=>{frame.onload=()=>resolve();}); document.body.append(frame); await loaded;
  const call = (text: string, method='prepare') => new Promise<Record<string, unknown>>(resolve=>{
   const channel=new MessageChannel(); channel.port1.onmessage=e=>{channel.port1.close();resolve(e.data);};
   frame.contentWindow!.postMessage({method,source:btoa(text),sourceID:'2601.01234',revision:2,
    inputs:[{url:'https://arxiv.org/html/2601.01234v2/figure.jpg',base64:image}]},'*',[channel.port2]);
  });
  // A LaTeXML error marker is tolerated with a closing note since 2026-10-14; a page without the article is not a paper.
  try {return [await call(source), await call(source.replace('class="ltx_document"','class="ltx_page"'),'assets'),
   await call(source.replace('<msup>','<maction>').replace('</msup>','</maction>')), await call(figures),
   await call(figures.replace('href="#glyph"','href="https://example.test/remote.svg#glyph"')),
   await call(figures.replace('<defs>','<foreignObject><p>unsafe</p></foreignObject><defs>'))];}
  finally {frame.remove();}
 }, {script,hash,source,image,figures});
 expect(results[0].ok).toBe(true);
 expect(results[0].result).toHaveProperty('manifestSHA256');
 expect(results[1]).toEqual({ok:false,failure:'source-unavailable'});
 expect(results[2]).toEqual({ok:false,failure:'math'});
 expect(results[3].ok).toBe(true);
 const bundle=results[3].result as {members:{path:string;base64:string}[]};
 const index=JSON.parse(Buffer.from(bundle.members.find(m=>m.path==='reader.json')!.base64,'base64').toString());
 expect(index.figures).toHaveLength(4); expect(index.equations).toHaveLength(2);
 expect(index.blocks.at(-1).text).toContain('Retained legend text');
 expect(results[4]).toEqual({ok:false,failure:'figure'});
 // A picture whose foreignObject holds text is read as paragraphs since 2026-10-14; the SVG itself is never emitted.
 expect(results[5].ok).toBe(true);
 const tolerated=results[5].result as {members:{path:string;base64:string}[]};
 const html=Buffer.from(tolerated.members.find(m=>m.path==='index.html')!.base64,'base64').toString();
 expect(html).not.toContain('foreignObject');
});
