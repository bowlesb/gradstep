// DOM integration against the real bundled reader and bridge. Use a locally installed Playwright/Chromium.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs CHROMIUM_PATH=/path/to/chrome node tests/reader/pdf-position-bridge.mjs
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root=new URL('../../apps/apple/ScienceReader/Resources/ReaderSamples/',import.meta.url);
const sampleName = readdirSync(root, {withFileTypes: true}).filter(entry => entry.isDirectory())
 .map(entry => entry.name).find(name => JSON.parse(readFileSync(new URL(name + '/manifest.json', root))).source.kind === 'authored-mmd');
assert.ok(sampleName, 'The authored reader fixture is present');
const sample=new URL(sampleName+'/',root);
const index=JSON.parse(readFileSync(new URL('reader.json',sample),'utf8'));
const bridge=readFileSync(new URL('../../apps/apple/ScienceReader/Resources/reader-bridge.js',import.meta.url),'utf8');
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox']});
try {
 for(const width of [390,1024]) {
  const page=await browser.newPage({viewport:{width,height:844},bypassCSP:true});
  await page.route(/^https?:/,r=>r.abort());
  await page.goto(new URL('index.html',sample).href);
  await page.evaluate(config=>{window.__readerBundleConfig={...config,manifest_sha256:'test-manifest'};window.webkit={messageHandlers:{reader:{postMessage(){}}}};},index);
  await page.addScriptTag({content:bridge});
  const result=await page.evaluate(()=>{
   const capture=window.__scienceReaderPDFPosition;
   const blocks=[...document.querySelectorAll('p[data-reader-block]')].filter(n=>n.textContent.length>150 && !n.querySelector('[data-reader-equation]') && n.textContent.split(/\s+/).length>20);
   const target=blocks[Math.floor(blocks.length/2)];target.scrollIntoView();
   const y=scrollY, html=document.body.innerHTML, position=capture();
   const noMutation=y===scrollY && html===document.body.innerHTML;
   const range=document.createRange();range.selectNodeContents(target);
   const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
   const before=selection.toString(), selected=capture();
   const unchanged=before===selection.toString() && scrollY===y;
   selection.removeAllRanges();
   const equation=document.querySelector('[data-reader-equation]');equation.click();
   const nearby=capture();
   return {position,selected,nearby,noMutation,unchanged,before};
  });
  assert.ok(result.position?.text.length>0);assert.equal(result.position.manifest_sha256,'test-manifest');
  assert.equal(result.noMutation,true);assert.equal(result.unchanged,true);
  assert.equal(result.selected.kind,'selection');assert.ok(result.selected.text.length>20);
  assert.equal(result.nearby.kind,'nearby');
  console.log(`PASS live viewport, selection, nearby equation, no scrolling/DOM changes (${width}px)`);
  // A live anchor near the end of a multi-screen block must not fall back to the block's opening.
  const local = await page.evaluate(async () => {
   window.__scienceReaderClearSelection();
   const target = [...document.querySelectorAll('p[data-reader-block]')].find(node => !node.querySelector('[data-reader-equation]'));
   target.replaceChildren(document.createTextNode('Unrelated opening material fills an earlier part of this unusually long paragraph. '.repeat(100)));
   const focus = document.createElement('span'); focus.style.display = 'block';
   focus.textContent = 'Distinctive nearby coastal measurements.';
   target.append(focus); await new Promise(resolve => setTimeout(resolve, 0));
   focus.scrollIntoView(); scrollBy(0, -innerHeight * .25 + 1);
   const before = scrollY, visible = window.__scienceReaderPDFPosition();
   const keptScroll = before === scrollY;
   const range = document.createRange(); range.setStart(focus.firstChild, 19); range.setEnd(focus.firstChild, 25);
   getSelection().removeAllRanges(); getSelection().addRange(range);
   const selected = window.__scienceReaderPDFPosition();
   const keptSelection = getSelection().toString();
   const rect = focus.getBoundingClientRect();
   const tapped = window.__scienceReaderPDFPosition({x:(rect.left + 10)/innerWidth,y:(rect.top + 5)/innerHeight});
   const tapKeptSelection = getSelection().toString() === keptSelection;
   window.__scienceReaderClearSelection();
   const equation = document.querySelector('[data-reader-equation]'), block = equation.closest('[data-reader-block]');
   block.insertBefore(document.createTextNode('Earlier material in an equation block. '.repeat(120)), equation);
   equation.before(document.createTextNode('Distinctive spectral calibration immediately precedes this mathematical expression. '));
   equation.after(document.createTextNode(' The following sentence concerns precisely this equation and its assumptions.'));
   await new Promise(resolve => setTimeout(resolve, 0));
   equation.click();
   const nearby = window.__scienceReaderPDFPosition();
   return {visible, selected, nearby, tapped, tapKeptSelection, keptSelection, keptScroll};
  });
  assert.ok(local.visible.text.includes('coastal measurements'), 'The viewport snapshot contains the actual late reading point');
  assert.ok(local.selected.text.includes('coastal measurements'), 'A short selection uses its immediate context');
  assert.equal(local.keptSelection, 'coasta');
  assert.equal(local.keptScroll, true);
  assert.ok(local.tapped.text.includes('coastal measurements'));
  assert.notEqual(local.tapped.kind, 'selection');
  assert.equal(local.tapKeptSelection, true);
  assert.ok(local.nearby.text.includes('spectral calibration'), 'Equation context stays beside the equation in a long block');
  assert.equal(local.nearby.kind, 'nearby');
  console.log(`PASS long-block reading point, short selected context, deep equation context (${width}px)`);
  await page.close();
 }
} finally {await browser.close();}
