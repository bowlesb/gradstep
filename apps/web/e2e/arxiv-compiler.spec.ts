import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { expect, test } from '@playwright/test';

const script = readFileSync(new URL('../src/reader/arxiv-reader.js', import.meta.url), 'utf8') + '\n'
 + readFileSync(new URL('../src/reader/arxiv-compiler-host.js', import.meta.url), 'utf8');
const hash = 'sha256-' + createHash('sha256').update(script).digest('base64');
const source = readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html', import.meta.url), 'utf8');
const image = readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)).toString('base64');
const figures = readFileSync(new URL('../../../tests/fixtures/reader-arxiv/figures.html', import.meta.url), 'utf8');
// Revision 15: one figure the device can't prepare is that figure's loss, never the paper's (2610.19820, 2610.16784).
const pictured = source.replace('<ol>', '<figure id="S1.F2"><img src="2601.01234v2/picture.svg"><figcaption>Figure 2: A picture.</figcaption></figure><ol>');
const layers = '<g id="layer_1"><rect width="40" height="10" fill="#16697A"></rect></g><g id="layer_1"><rect y="10" width="40" height="10"></rect></g>';
const svg = (size: string, body: string) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" ${size}>${body}</svg>`).toString('base64');
const pictures = [svg('width="40" height="20"', layers), svg('width="9000pt" height="6000pt" viewBox="0 0 9000 6000"', layers),
 svg('width="40" height="20"', layers + '<use href="#layer_1"></use>')];

test('isolated HTML compiler preserves content and reports finite failure reasons under production CSP', async ({page}) => {
 await page.goto('/');
 const results = await page.evaluate(async ({script,hash,source,image,figures,pictured,pictures}) => {
  const frame=document.createElement('iframe'); frame.sandbox.add('allow-scripts');
  frame.srcdoc=`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${hash}'; img-src data:; connect-src 'none'; style-src 'none'; base-uri 'none'"><script>${script}</script>`;
  const loaded=new Promise<void>(resolve=>{frame.onload=()=>resolve();}); document.body.append(frame); await loaded;
  const call = (text: string, method='prepare', picture?: string) => new Promise<Record<string, unknown>>(resolve=>{
   const channel=new MessageChannel(); channel.port1.onmessage=e=>{channel.port1.close();resolve(e.data);};
   frame.contentWindow!.postMessage({method,source:btoa(text),sourceID:'2601.01234',revision:2,
    inputs:[{url:'https://arxiv.org/html/2601.01234v2/figure.jpg',base64:image},
     ...picture ? [{url:'https://arxiv.org/html/2601.01234v2/picture.svg',base64:picture}] : []]},'*',[channel.port2]);
  });
  // A LaTeXML error marker is tolerated with a closing note since 2026-10-14; a page without the article is not a paper.
  try {return [await call(source), await call(source.replace('class="ltx_document"','class="ltx_page"'),'assets'),
   await call(source.replace('<msup>','<maction>').replace('</msup>','</maction>')), await call(figures),
   await call(figures.replace('href="#glyph"','href="https://example.test/remote.svg#glyph"')),
   await call(figures.replace('<defs>','<foreignObject><p>unsafe</p></foreignObject><defs>')),
   ...await Promise.all(pictures.map(picture => call(pictured, 'prepare', picture)))];}
  finally {frame.remove();}
 }, {script,hash,source,image,figures,pictured,pictures});
 expect(results[0].ok).toBe(true);
 expect(results[0].result).toHaveProperty('manifestSHA256');
 expect(results[1]).toEqual({ok:false,failure:'source-unavailable',code:'arxiv_article'});
 // Revision 29: a formula outside the reader's MathML shows its TeX and the paper opens (it refused as 'math' before).
 expect(results[2].ok).toBe(true);
 const fallback=results[2].result as {members:{path:string;base64:string}[]};
 expect(Buffer.from(fallback.members.find(m=>m.path==='index.html')!.base64,'base64').toString()).toContain('reader-math-fallback');
 expect(results[3].ok).toBe(true);
 const bundle=results[3].result as {members:{path:string;base64:string}[]};
 const index=JSON.parse(Buffer.from(bundle.members.find(m=>m.path==='reader.json')!.base64,'base64').toString());
 expect(index.figures).toHaveLength(4); expect(index.equations).toHaveLength(2);
 expect(index.blocks.at(-1).text).toContain('Retained legend text');
 // A legend picture with a remote reference is not drawn: a note takes its place and the paper opens (revision 15;
 // it refused the paper as 'figure' before).
 expect(results[4].ok).toBe(true);
 const noted=results[4].result as {members:{path:string;base64:string}[]};
 const notedHTML=Buffer.from(noted.members.find(m=>m.path==='index.html')!.base64,'base64').toString();
 expect(notedHTML).toContain('<p><em>Part of this figure couldn’t be shown here; the PDF has it.</em></p>');
 expect(JSON.parse(Buffer.from(noted.members.find(m=>m.path==='reader.json')!.base64,'base64').toString()).figures).toHaveLength(4);
 // A picture whose foreignObject holds text is read as paragraphs since 2026-10-14; the SVG itself is never emitted.
 expect(results[5].ok).toBe(true);
 const tolerated=results[5].result as {members:{path:string;base64:string}[]};
 const html=Buffer.from(tolerated.members.find(m=>m.path==='index.html')!.base64,'base64').toString();
 expect(html).not.toContain('foreignObject');
 // Pictures in WebKit's and Chromium's own XML parser: two layers named alike are drawn (2610.19820's teaser); a
 // picture too large to draw at twice its size is drawn smaller (2610.16784); a reference to the repeated name is not
 // drawn, and that figure reads as its caption under a note.
 const bundleOf = (result: Record<string, unknown>) => {
  const members=(result.result as {members:{path:string;base64:string}[]}).members;
  const text=(path: string) => Buffer.from(members.find(m=>m.path===path)!.base64,'base64').toString();
  return {html:text('index.html'),index:JSON.parse(text('reader.json')),manifest:JSON.parse(Buffer.from((result.result as {manifest:string}).manifest,'base64').toString())};
 };
 for (const result of results.slice(6)) expect(result.ok).toBe(true);
 const [drawn,large,unshown]=results.slice(6).map(bundleOf);
 expect(drawn.index.figures.map((f: {caption: string}) => f.caption)).toEqual(['Figure 1: A test figure.','Figure 2: A picture.']);
 expect(drawn.html).not.toContain('couldn’t be shown');
 expect(large.index.figures).toHaveLength(2);
 const sizes=large.manifest.members.filter((m: {role: string}) => m.role==='image').map((m: {width: number; height: number}) => m.width*m.height);
 expect(Math.max(...sizes)).toBeLessThanOrEqual(3_000_000);
 expect(unshown.index.figures).toHaveLength(1);
 expect(unshown.html).toMatch(/<p class="reader-caption"[^>]*><em>This figure couldn’t be shown here; the PDF has it\.<\/em> Figure 2: A picture\.<\/p>/);
});
