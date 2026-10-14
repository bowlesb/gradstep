import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivAssetURL, arxivHTMLAssets, arxivHTMLURL, arxivInlineImages, convertArxivHTML } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { composeArxivReader } from '../../supabase/functions/_shared/reader/arxiv-bundle.ts';
import { admitReaderImage } from '../../supabase/functions/_shared/reader/images.ts';
import { validateReaderBundle } from '../../supabase/functions/_shared/reader/validate.ts';
import { canonicalBytes, sha256Hex, utf8 } from '../../supabase/functions/_shared/reader/util.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';

const url = arxivHTMLURL('2601.01234', 2);
const math = '<math alttext="x^2" display="inline"><semantics><msup><mi>x</mi><mn>2</mn></msup><annotation encoding="application/x-tex">x^2</annotation></semantics></math>';
const source = readFileSync(new URL('../fixtures/reader-arxiv/source.html', import.meta.url), 'utf8');
const raw = new Uint8Array(readFileSync(new URL('../fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)));
const admitted = admitReaderImage(raw);
function build(text = source) {
 return composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,
  images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]])});
}

test('arXiv HTML produces the existing verified reader contract without PDF/OCR identities',()=>{
 const bundle=build(); const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 assert.equal(checked.index.title,'Authored HTML fixture');
 assert.equal(checked.index.equations.length,2); assert.equal(checked.index.figures.length,1);
 assert.deepEqual(checked.index.headings.map(h=>h.title),['1 Introduction','References']);
 assert.equal(checked.index.equations[0].latex,'x^2');
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 assert.ok(!/evil\(|Website|<script|onload/.test(html));
 assert.match(html,new RegExp(`href="#${checked.index.figures[0].id}"`));
 assert.match(html,/<th>Value<\/th>/);
 assert.equal(checked.provenance.format,'arxiv-html-reader-provenance-v2');
 assert.ok(!('document' in checked.provenance)); assert.ok(!('provider_job_id' in checked.provenance));
});

test('same pinned input is deterministic and changed content gets different anchors',()=>{
 const a=build(),b=build(),c=build(source.replace('An equation','Another equation'));
 assert.equal(a.manifestSHA256,b.manifestSHA256);assert.notEqual(a.index.blocks[0].id,c.index.blocks[0].id);
});

test('assets stay in the exact official source revision and never become PDF fetches',()=>{
 assert.deepEqual(arxivHTMLAssets(source,url),[url+'/figure.jpg']);
 for(const src of ['https://evil.example/figure.png','../other.png','2601.01234v1/figure.png','2601.01234v2/paper.pdf','//127.0.0.1/a.png','2601.01234v2/%2e%2e/a.png'])
  assert.throws(()=>arxivAssetURL(src,url));
 assert.equal(arxivHTMLURL('hep-th/9901001',1),'https://arxiv.org/html/hep-th/9901001v1');
 assert.throws(()=>arxivHTMLURL('2601.01234',0));
});

test('missing images, duplicate IDs, conversion errors, missing TeX and unresolved references fail preparation',()=>{
 for(const text of [source.replace('id="p1"','id="S1"'),source.replace('An equation','<span class="ltx_ERROR">bad</span>'),
  source.replace('href="#bib1"','href="#missing"'),source.replace(math,'<math><mi>x</mi></math>')])assert.throws(()=>build(text));
 assert.throws(()=>composeArxivReader({source:utf8(source),sourceID:'2601.01234',revision:2,images:new Map()}));
 assert.throws(()=>convertArxivHTML('<html>Challenge page</html>',url,()=>{throw Error('no image expected')}));
});

test('unsafe MathML and inconsistent TeX are rejected rather than silently losing equations',()=>{
 for(const replacement of [math.replace('<mi>x</mi>','<mi href="https://evil.example">x</mi>'),math.replace('>x^2</annotation>','>x^3</annotation>'),
  math.replace('<msup>','<maction>').replace('</msup>','</maction>')])assert.throws(()=>build(source.replace(math,replacement)));
});

test('independent verification rejects a self-consistently rehashed foreign source provenance',()=>{
 const bundle=build(),members=new Map(bundle.members);
 const provenance=JSON.parse(new TextDecoder().decode(members.get('provenance.json')));
 provenance.source.url='https://evil.example/html/2601.01234v2';members.set('provenance.json',canonicalBytes(provenance));
 const manifest=JSON.parse(new TextDecoder().decode(bundle.manifestBytes));
 for(const m of manifest.members){m.sha256=sha256Hex(members.get(m.path)!);m.bytes=members.get(m.path)!.length;}
 const bytes=canonicalBytes(manifest);assert.throws(()=>validateReaderBundle(bytes,members,sha256Hex(bytes)));
});

test('grouped captions and inline vector legends preserve figure order, text and image provenance',()=>{
 const text=readFileSync(new URL('../fixtures/reader-arxiv/figures.html',import.meta.url),'utf8');
 const inline=arxivInlineImages(text);
 assert.deepEqual([...inline.keys()],['#legend-symbol']);
 assert.deepEqual(arxivHTMLAssets(text,url),[url+'/figure.jpg']);
 const png=admitReaderImage(new Uint8Array(readFileSync(new URL('../fixtures/reader/assets/attention.png',import.meta.url))));
 const images=new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}],
  ['#legend-symbol',{...png,inputSHA256:sha256Hex(utf8(inline.get('#legend-symbol')!))}]]);
 const bundle=composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,images});
 const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 assert.equal(checked.index.figures.length,4);
 assert.deepEqual(checked.index.figures.map(f=>f.caption),['','Figure 1: First panel x^2 .','Figure 2: Second panel.','Figure 3: Legend and illustration.']);
 assert.match(checked.index.blocks.at(-1)!.text,/Retained legend text.*Second legend line y/);
 assert.equal(checked.index.equations.length,2);
 assert.match(new TextDecoder().decode(bundle.members.get('index.html')),/mathbackground="#E8F3F4"/);
 assert.equal((checked.provenance.inline_image_inputs as unknown[]).length,1);
 // Legacy output grammars must not silently admit this extension.
 assert.throws(()=>validateHTML(bundle.members.get('index.html')!,bundle.index,new Map()));
 images.get('#legend-symbol')!.inputSHA256='0'.repeat(64);
 assert.throws(()=>composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,images}));
});

test('installed v1 HTML bundles remain independently readable',()=>{
 const p=JSON.parse(readFileSync(new URL('../fixtures/reader-arxiv/package.json',import.meta.url),'utf8'));
 assert.equal(validateReaderBundle(Buffer.from(p.manifest,'base64'),new Map(p.members.map((m:{path:string;base64:string})=>[m.path,Buffer.from(m.base64,'base64')])),p.manifestSHA256).manifest.format,'reader-bundle-v1');
});
