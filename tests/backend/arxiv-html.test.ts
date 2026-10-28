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

const fontOptions = '[Path=fonts/, Extension=.otf, UprightFont=*-regular, BoldFont=*-bold, ItalicFont=*-italic, BoldItalicFont=*-bolditalic]\n'
 + '[Path=fonts/]\n[Extension=.ttf, UprightFont=*, BoldFont=*-Bold, ItalicFont=*-Oblique, BoldItalicFont=*-BoldOblique, Scale=0.8]';
function fontTitlePage(options = fontOptions) {
 return source.replace('<h1>Authored HTML fixture</h1><div class="ltx_authors">A. Author</div>',
  `<div class="ltx_para"><p class="ltx_p">${options}<span class="ltx_inline-block"><span class="ltx_ERROR">\\marcellus</span>`
  + '<span class="ltx_p">Authored HTML fixture</span><span class="ltx_p"><a href="https://example.org/project">Project</a></span>'
  + '<span class="ltx_p">A. Author</span></span></p></div>');
}
test('custom title pages omit leaked font options but keep their title, project and authors', () => {
 const result = convertArxivHTML(fontTitlePage(), url, () => ({...admitted,path:`assets/${'0'.repeat(64)}.png`}), {title:'Authored HTML fixture', authors:['A. Author']});
 assert.doesNotMatch(result.html, /Path=fonts|UprightFont|BoldItalicFont|Extension=/);
 assert.match(result.html, /Authored HTML fixture/); assert.match(result.html, /A\. Author/);
 assert.match(result.html, /href="https:\/\/example\.org\/project"/);
 assert.equal(result.index.equations.length, 2);
});
test('font-like content in body paragraphs or an unknown title-page option is retained', () => {
 const body = convertArxivHTML(source.replace('<p id="p1">', `<p>${fontOptions}</p><p id="p1">`), url, () => ({...admitted,path:`assets/${'0'.repeat(64)}.png`}));
 assert.match(body.html, /UprightFont/);
 const unknown = convertArxivHTML(fontTitlePage(fontOptions.replace('Scale=0.8','MeasuredAccuracy=0.8')), url, () => ({...admitted,path:`assets/${'0'.repeat(64)}.png`}),
  {title:'Authored HTML fixture', authors:['A. Author']});
 assert.match(unknown.html, /MeasuredAccuracy=0.8/);
});
// Authored reduction of DocPilot alg1.m8: an SVG rounded-box label inside an mtext token.
const badge = '<svg viewBox="0 0 20 10"><g><path d="M 0 2 L 0 8 C 0 9 1 10 2 10 L 18 10 C 19 10 20 9 20 8 L 20 2 C 20 1 19 0 18 0 L 2 0 C 1 0 0 1 0 2 Z"/>'
 + '<foreignObject><span class="ltx_foreignobject_content"><span>Navigate</span></span></foreignObject></g></svg>';
function build(text = source) {
 return composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,
  images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]])});
}

test('TikZ text badges inside math retain every label without source SVG or CSS',()=>{
 const labels=['Navigate','Extract','Focus','Solve'];
 const formula='<math alttext="a in actions"><mrow><mi>a</mi><mo>∈</mo><mo>{</mo>'
  +labels.map(label=>'<mtext>'+badge.replace('Navigate',label)+'</mtext>').join('<mo>,</mo>')+'<mo>}</mo></mrow></math>';
 const bundle=build(source.replace(math,formula));
 const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 for(const label of labels)assert.ok(html.includes(`<mtext>${label}</mtext>`));
 assert.ok(!/<svg|foreignobject|foreignObject|<path|viewBox/.test(html));
 assert.equal(checked.index.equations[0].latex,'a in actions');
});

// Revision 29: such a formula shows its LaTeX (`reader-math-fallback`) instead of refusing the paper; nothing of the
// picture reaches the page, and its label is not passed off as the formula.
test('arbitrary vector math is not silently reduced to its text label',()=>{
 const bad=[badge.replace(/d="[^"]+"/,'d="M 0 0 L 20 0 L 10 10 Z"'),
  badge.replace('</g>','<path d="M 1 1 L 5 5"/></g>'),
  badge.replace('</g>','<text>extra meaning</text></g>'),
  badge.replace('</g>','<script>bad()</script></g>'),
  badge.replace('Navigate','<img src="https://example.test/x"/>'),
  badge.replace('Navigate','<script src="https://example.test/x"></script>Navigate'),
  badge.replace('<svg ','<svg onload="bad()" ')];
 for(const svg of bad){
  const bundle=build(source.replace(math,`<math alttext="unknown"><mtext>${svg}</mtext></math>`));
  const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
  const html=new TextDecoder().decode(bundle.members.get('index.html'));
  assert.match(html,/<span class="reader-equation reader-inline reader-math-fallback" data-latex="unknown"[^>]*>\\\(unknown\\\)<\/span>/);
  assert.ok(!/<svg|<path|<script|<text|onload|example\.test|Navigate|extra meaning/.test(html));
  assert.equal(checked.index.equations[0].latex,'unknown');
 }
});

test('an algorithm with SVG math badges remains a text listing, not an empty image figure',()=>{
 const listing='<figure id="algorithm"><figcaption>Algorithm 1: Select an action</figcaption><p>Choose '
  +`<math alttext="action"><mtext>${badge}</mtext></math>`+' then return the answer.</p></figure>';
 const bundle=build(source.replace('<p id="p1">',listing+'<p id="p1">'));
 const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 assert.equal(checked.index.figures.length,1,'only the actual image is a figure');
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 assert.match(html,/<mtext>Navigate<\/mtext>/);
 assert.ok(checked.index.blocks.some(b=>b.text.includes('Algorithm 1')&&b.text.includes('return the answer')));
});

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

test('missing images and duplicate IDs fail preparation; missing TeX and unresolved references degrade (revision 29)',()=>{
 assert.throws(()=>build(source.replace('id="p1"','id="S1"')));
 assert.throws(()=>composeArxivReader({source:utf8(source),sourceID:'2601.01234',revision:2,images:new Map()}));
 assert.throws(()=>convertArxivHTML('<html>Challenge page</html>',url,()=>{throw Error('no image expected')}));
 // A reference to nothing on the page reads as its words; a formula without TeX takes its LaTeX from its MathML.
 const unlinked=build(source.replace('href="#bib1"','href="#missing"'));
 const html=new TextDecoder().decode(unlinked.members.get('index.html'));
 assert.match(html,/; see \[1\]\./);
 const untexed=validateReaderBundle(...(b=>[b.manifestBytes,b.members,b.manifestSHA256] as const)(build(source.replace(math,'<math><mi>x</mi></math>'))));
 assert.equal(untexed.index.equations[0].latex,'x');
});

test('LaTeXML conversion-error markers are dropped and counted, and the paper still reads; too many refuse it',()=>{
 // An undefined preamble macro, as LaTeXML emits it (2026-10-14: a real paper carried 288 of these and was refused).
 const marked=source.replace('An equation','<span id="p1.1" class="ltx_ERROR undefined">\\pdfauthor</span>An equation');
 const bundle=build(marked),checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const clean=validateReaderBundle(build().manifestBytes,build().members,build().manifestSHA256);
 assert.equal(checked.index.blocks.length,clean.index.blocks.length+1,'one note block more');
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 assert.ok(!html.includes('pdfauthor') && !html.includes('ltx_ERROR'),'the marker and its text are gone');
 assert.match(checked.index.blocks.at(-1)!.text,/^Note: arXiv’s HTML conversion of this version left out 1 unsupported command\. The PDF is complete\.$/);
 assert.equal(checked.index.blocks.at(-1)!.kind,'paragraph');
 assert.deepEqual(arxivHTMLAssets(marked,url),[url+'/figure.jpg'],'assets are still found');
 const many=source.replace('An equation','<span class="ltx_ERROR">x</span>'.repeat(1001)+'An equation');
 assert.throws(()=>build(many),/arxiv_conversion_error/);
});

test('graphics in running text are left out and counted; a paragraph holding one graphic is a figure (owner papers, 2026-10-14)',()=>{
 // An affiliation logo inside the author line (2610.16352) and an inline TikZ mark (2610.13021) no longer refuse the paper.
 const icon=source.replace('An equation','<span class="ltx_text"><img src="2601.01234v2/logo.png" class="ltx_graphics" alt="Refer to caption"></span>An equation');
 assert.deepEqual(arxivHTMLAssets(icon,url),[url+'/figure.jpg'],'the left-out graphic is never fetched');
 const bundle=build(icon),checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 assert.equal(checked.index.figures.length,1);
 assert.match(checked.index.blocks.at(-1)!.text,/left out 1 inline graphic\. The PDF is complete\.$/);
 assert.ok(!new TextDecoder().decode(bundle.members.get('index.html')).includes('logo.png'));
 // A bare \\includegraphics paragraph (2610.17288) reads as a figure, with its image acquired and published.
 const lone=source.replace('<p id="p1">','<p class="ltx_p"><span class="ltx_text ltx_align_center"><img src="2601.01234v2/lone.jpg" class="ltx_graphics" alt="Refer to caption"></span></p><p id="p1">');
 assert.deepEqual(arxivHTMLAssets(lone,url),[url+'/figure.jpg',url+'/lone.jpg']);
 const both=composeArxivReader({source:utf8(lone),sourceID:'2601.01234',revision:2,
  images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}],[url+'/lone.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]])});
 const loneChecked=validateReaderBundle(both.manifestBytes,both.members,both.manifestSHA256);
 assert.equal(loneChecked.index.figures.length,2);
 assert.ok(!loneChecked.index.blocks.some(b=>b.text.startsWith('Note:')),'nothing was left out');
 // Both counts in one note.
 const mixed=icon.replace('<p id="p1">','<p id="p1"><span class="ltx_ERROR undefined">\\reportid</span>');
 const mixedChecked=(()=>{const b=build(mixed);return validateReaderBundle(b.manifestBytes,b.members,b.manifestSHA256);})();
 assert.match(mixedChecked.index.blocks.at(-1)!.text,/left out 1 unsupported command and 1 inline graphic\./);
});

test('TikZ pictures: a framed text box reads as paragraphs; a diagram keeps its labels as SVG text (owner papers, 2026-10-14)',()=>{
 const picture=(id:string,label:string)=>`<svg id="${id}" class="ltx_picture" height="40" overflow="visible" version="1.1" viewBox="0 0 200 40" width="200"><g><path d="M 0 0 L 200 0 L 200 40 L 0 40 Z" fill="none" stroke="#000"></path>`+
  `<foreignObject style="font-size:10pt;" height="20" overflow="visible" transform="matrix(1 0 0 -1 0 30)" width="180"><span class="ltx_foreignobject_container"><span class="ltx_foreignobject_content"><span class="ltx_p">${label}</span></span></span></foreignObject></g></svg>`;
 // A lone picture holding a sentence (2610.13021's "Finding" boxes): the sentence is a paragraph, the frame is left out.
 const boxed=source.replace('<p id="p1">',`<div class="ltx_para"><span class="ltx_inline-block">${picture('S1.pic1','Finding 1: experience from basic tasks helps.')}</span></div><p id="p1">`);
 const bundle=build(boxed),checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 assert.ok(checked.index.blocks.some(b=>b.kind==='paragraph'&&b.text==='Finding 1: experience from basic tasks helps.'),'the box reads as text');
 assert.equal(checked.index.figures.length,1,'the frame is not a figure');
 assert.match(checked.index.blocks.at(-1)!.text,/left out 1 inline graphic\./);
 assert.deepEqual([...arxivInlineImages(boxed,url).keys()],[],'the frame is never serialized');
 // A labelled diagram inside a figure keeps its label as SVG text, which the device admission accepts.
 const figured=source.replace('<p id="p1">',`<figure id="S1.F9" class="ltx_figure">${picture('S1.F9.pic1','h_t')}<figcaption class="ltx_caption">Figure 9: A diagram.</figcaption></figure><p id="p1">`);
 const inline=arxivInlineImages(figured,url);
 assert.deepEqual([...inline.keys()],['#S1.F9.pic1']);
 const xml=inline.get('#S1.F9.pic1')!;
 assert.ok(!xml.includes('foreignObject')&&!xml.includes('<span'),'no HTML inside the SVG');
 assert.match(xml,/<text [^>]*dominant-baseline="central"[^>]*>h_t<\/text>/);
 // The label's own counter-flip moves to its group; the text adds no second flip (revision 22).
 assert.match(xml,/<g transform="matrix\(1 0 0 -1 0 30\)"><text [^>]*>h_t<\/text><\/g>/);
 assert.doesNotMatch(xml,/<text [^>]*transform=/);
});

/** The 2-D affine matrix each `<text>` is drawn with: every ancestor's transform composed, outermost first. */
function textMatrices(xml:string):{text:string;m:number[]}[] {
 const mul=(a:number[],b:number[])=>[a[0]*b[0]+a[2]*b[1],a[1]*b[0]+a[3]*b[1],a[0]*b[2]+a[2]*b[3],a[1]*b[2]+a[3]*b[3],a[0]*b[4]+a[2]*b[5]+a[4],a[1]*b[4]+a[3]*b[5]+a[5]];
 const parse=(t:string)=>[...t.matchAll(/(matrix|translate|scale)\(([^)]*)\)/g)].reduce((m,[,f,args])=>{
  const n=args.split(/[\s,]+/).filter(Boolean).map(Number);
  const step=f==='matrix'?n:f==='translate'?[1,0,0,1,n[0],n[1]??0]:[n[0],0,0,n[1]??n[0],0,0];
  return mul(m,step);},[1,0,0,1,0,0]);
 const stack:number[][]=[[1,0,0,1,0,0]],out:{text:string;m:number[]}[]=[];
 for (const [tag,close,name,attrs,self] of xml.matchAll(/<(\/?)([A-Za-z]+)([^>]*?)(\/?)>/g)) {
  void tag;
  if (close) { stack.pop(); continue; }
  const own=/\stransform="([^"]*)"/.exec(attrs)?.[1];
  const m=own?mul(stack.at(-1)!,parse(own)):stack.at(-1)!;
  if (name==='text') out.push({text:/<text[^>]*>([^<]*)<\/text>/.exec(xml.slice(xml.indexOf(tag)))?.[1]??'',m});
  if (!self) stack.push(m);
 }
 return out;
}

test('pgfplots labels in a flipped picture read upright, rotated ticks included, without TeX annotations (build 73, 2610.22371v1 Figure 3)',()=>{
 // Authored reduction of LaTeXML's pgfplots output: the picture's y-up flip on the outer group, each label a
 // foreignObject with its own counter-flip, x ticks rotated 45°, math labels carrying their TeX annotation.
 const label=(transform:string,width:number,height:number,base:number,content:string)=>
  `<g fill="#000000" stroke="#000000" transform="${transform}"><foreignObject style="font-size:10pt;" height="${height}" overflow="visible" transform="matrix(1 0 0 -1 0 ${base})" width="${width}">`
  +`<span class="ltx_foreignobject_container"><span class="ltx_foreignobject_content">${content}</span></span></foreignObject></g>`;
 const sigma='<math alttext="\\sigma" display="inline"><semantics><mi>σ</mi><annotation encoding="application/x-tex">\\sigma</annotation></semantics></math>';
 const down='<math alttext="\\downarrow" display="inline"><semantics><mo stretchy="false">↓</mo><annotation encoding="application/x-tex">\\downarrow</annotation></semantics></math>';
 const plot=`<figure id="S3.F3" class="ltx_figure"><svg id="S3.F3.pic1" class="ltx_picture" height="125.06" overflow="visible" version="1.1" viewBox="0 0 253.36 125.06" width="253.36">`
  +`<g fill="#000000" stroke="#000000" stroke-width="0.4pt" transform="translate(0,125.06) matrix(1 0 0 -1 0 0) translate(27.33,0) translate(0,35.66)">`
  +`<path style="fill:none" d="M 0 0 L 0 72.48 L 207.24 72.48 L 207.24 0 Z"></path>`
  +label('matrix(0.7071 0.7071 -0.7071 0.7071 -5.08 -19.36)',17.68,8.92,8.92,'<span class="ltx_text">0.5</span>')
  +label('matrix(0 1 -1 0 -12.4 10)',91.71,12.3,9.61,`<span class="ltx_text">Tracking EPE ${down}</span>`)
  +label('matrix(1 0 0 1 210 -4)',7.91,5.96,5.96,sigma)
  +`</g></svg><figcaption class="ltx_caption">Figure 3: Noise Level – Tracking.</figcaption></figure>`;
 const xml=arxivInlineImages(source.replace('<p id="p1">',plot+'<p id="p1">'),url).get('#S3.F3.pic1')!;
 assert.ok(!xml.includes('foreignObject')&&!xml.includes('\\sigma')&&!xml.includes('\\downarrow'),'SVG text only, no TeX source');
 const texts=textMatrices(xml);
 assert.deepEqual(texts.map(t=>t.text),['0.5','Tracking EPE ↓','σ']);
 for (const {text,m} of texts) {
  // Not mirrored: the composed linear part keeps its orientation (a double flip made it -1: upside-down letters).
  assert.ok(m[0]*m[3]-m[1]*m[2]>0,`"${text}" is drawn mirrored: ${m.map(v=>v.toFixed(3)).join(' ')}`);
 }
 // The tick reads up and to the right (pgfplots rotate=45), the axis label bottom to top, σ level.
 const [tick,axis,level]=texts.map(t=>t.m);
 assert.ok(tick[0]>0&&tick[1]<0,'45° tick rises to the right on screen');
 assert.ok(Math.abs(axis[0])<1e-9&&axis[1]<0,'the y-axis label runs upward');
 assert.ok(level[0]>0&&Math.abs(level[1])<1e-9&&level[3]>0,'σ is upright');
 // Labels are text, not strokes of the picture's line width.
 assert.ok(/<text [^>]*stroke="none"/.test(xml));
});

// Authored reductions of LaTeXML's itemize/enumerate markup (build 88: 2610.28711v1 §7's authors, 2610.14162v1's
// contributions): each item carries its label as `span.ltx_tag_item` and its words in `div.ltx_para > p.ltx_p`.
const ltxItem=(id:string,label:string,words:string)=>`<li id="${id}" class="ltx_item" style="list-style-type:none;"><span class="ltx_tag ltx_tag_item">${label}</span> \n`
 +`<div id="${id}.p1" class="ltx_para ltx_noindent">\n<p id="${id}.p1.1" class="ltx_p">${words}</p>\n</div></li>\n`;
test('a list item shows one marker, the paper\'s own label, without empty lines under it (build 88, 2610.28711v1, 2610.14162v1)',()=>{
 const bullet='<math id="S2.I1.i1.m1" alttext="\\bullet" display="inline"><semantics><mo>∙</mo><annotation encoding="application/x-tex">\\bullet</annotation></semantics></math>';
 const lists=source.replace('<ol><li>First item</li><li>Second item</li></ol>',
  `<ul id="S7.I1" class="ltx_itemize">${ltxItem('S7.I1.i1','•','Chuanmeng Bian')}${ltxItem('S7.I1.i2','•','Daren Chen')}</ul>`
  +`<ol id="S1.I3" class="ltx_enumerate">${ltxItem('S1.I3.i1','(i)','<span class="ltx_text ltx_font_bold">Fast inference.</span> Fewer steps.')}`
  +`${ltxItem('S1.I3.i2','(ii)','Lower budgets.')}</ol>`
  +`<ul id="S2.I1" class="ltx_itemize"><li id="S2.I1.i1" class="ltx_item" style="list-style-type:none;"><span class="ltx_tag ltx_tag_item">${bullet}</span> \n`
  +'<div class="ltx_para"><p class="ltx_p">A math bullet.</p>\n<p class="ltx_p">A second paragraph.</p></div></li></ul>'
  +'<ul class="ltx_itemize"><li class="ltx_item">No label of its own.</li></ul>'
  +'<dl class="ltx_description"><dt class="ltx_item"><span class="ltx_tag ltx_tag_item"><span class="ltx_text ltx_font_bold">Term:</span></span></dt>'
  +'<dd class="ltx_item"><div class="ltx_para"><p class="ltx_p">its description.</p></div></dd></dl>');
 const bundle=build(lists),checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 const items=[...html.matchAll(/<li\b([^>]*)>([\s\S]*?)<\/li>/g)];
 const named=(text:string)=>items.find(([, , body])=>body.includes(text))!;
 for (const [text,label] of [['Chuanmeng Bian','•'],['Daren Chen','•'],['Fewer steps','(i)'],['Lower budgets','(ii)'],['A math bullet','∙']] as const) {
  const [, attrs, body]=named(text);
  assert.match(attrs,/class="reader-custom-marker"/,`${text}: the list's own marker is off`);
  assert.ok(body.startsWith(`<span class="reader-marker">${label} </span>`),`${text}: one marker, the paper's: ${body.slice(0,90)}`);
  assert.equal(body.split(label).length-1,1,`${text}: the label once`);
  assert.doesNotMatch(body,/(<br>|\s)$/,`${text}: no empty line under the item`);
 }
 // Paragraphs inside one item stay apart; an item without a label keeps the list's marker.
 assert.match(named('A math bullet')[2],/A math bullet\.<br>\s*A second paragraph\.$/);
 const [, plainAttrs, plainBody]=named('No label of its own.');
 assert.doesNotMatch(plainAttrs,/reader-custom-marker/); assert.equal(plainBody,'No label of its own.');
 // A description list is one paragraph, its terms inline, without empty lines at its end.
 assert.match(html,/<p [^>]*data-reader-kind="paragraph"[^>]*><strong>Term:<\/strong>\s*its description\.<\/p>/);
 // The index reads each label as a word of its own; the math label is accounted for, not an equation.
 const listed=checked.index.blocks.filter(b=>b.kind==='list').map(b=>b.text);
 for (const text of ['• Chuanmeng Bian','• Daren Chen','(i) Fast inference. Fewer steps.','(ii) Lower budgets.'])
  assert.ok(listed.includes(text),`${text} in ${JSON.stringify(listed)}`);
 assert.ok(!checked.index.equations.some(e=>e.latex==='\\bullet'));
 // A numbered reference's "[1]" is its marker the same way (no list bullet beside it).
 const cited=build(source.replace('<li id="bib1">[1] Author.','<li id="bib1" class="ltx_bibitem"><span class="ltx_tag ltx_tag_bibitem">[1]</span>\n<span class="ltx_bibblock">Author.'));
 assert.match(new TextDecoder().decode(cited.members.get('index.html')),/<li class="reader-custom-marker"[^>]*><span class="reader-marker">\[1\] <\/span>\s*Author\./);
});

test('a picture\'s labels of several lines are drawn line by line in their box, without phantom struts (build 88, 2610.14162v1 Figure 3)',()=>{
 // Authored reduction of the step boxes: a 10pt minipage label 7.68em wide with two paragraphs, each green word after a
 // `\phantom{Ag}` strut LaTeXML keeps as hidden text, beside a one-line "Step 1" label.
 const phantom='<span class="ltx_text ltx_phantom"><span style="visibility:hidden">Ag</span></span>';
 const steps=`<figure id="S1.F3" class="ltx_figure"><svg id="S1.F3.pic2" class="ltx_picture" height="160" overflow="visible" version="1.1" viewBox="0 0 130 160" width="130">`
  +'<g fill="#000000" stroke="#000000" transform="translate(0,160) matrix(1 0 0 -1 0 0)"><path style="fill:none" d="M 1 0 L 1 -124 L 120 -124 L 120 0 Z"></path>'
  +'<g transform="matrix(1.0 0.0 0.0 1.0 7.76 -18.5)"><foreignObject style="font-size:11pt;" height="12.3" overflow="visible" transform="matrix(1 0 0 -1 0 9.61)" width="41.57">'
  +'<span class="ltx_foreignobject_container"><span class="ltx_foreignobject_content"><span class="ltx_text ltx_font_sansserif ltx_font_bold">Step 1</span></span></span></foreignObject></g>'
  +'<g transform="matrix(1.0 0.0 0.0 1.0 7.76 -97.36)"><foreignObject style="font-size:10pt;" height="125.84" overflow="visible" transform="matrix(1 0 0 -1 0 66.38)" width="106.27">'
  +'<span class="ltx_foreignobject_container"><span class="ltx_foreignobject_content">\n<span class="ltx_inline-block ltx_minipage ltx_align_middle" style="width:7.68em;">\n'
  +`<span class="ltx_p ltx_align_left">${phantom}<span class="ltx_text">However,</span></span>\n`
  +`<span class="ltx_p ltx_align_left"><span class="ltx_text">it </span>${phantom}<span class="ltx_text">is</span><span class="ltx_text"> a important </span>${phantom}<span class="ltx_text">to</span>`
  +'<span class="ltx_text"> the the the </span><span class="ltx_text ltx_font_bold">and</span><span class="ltx_text"> the.</span></span>\n</span></span></span></foreignObject></g>'
  +'</g></svg><figcaption class="ltx_caption">Figure 3: NCM generation trajectory.</figcaption></figure>';
 const xml=arxivInlineImages(fragment(steps),url).get('#S1.F3.pic2')!;
 assert.doesNotMatch(xml,/Ag/,'a phantom strut is never drawn');
 assert.ok(!xml.includes('foreignObject')&&!xml.includes('<span'),'SVG text only');
 const texts=textMatrices(xml);
 // The one-line label is unchanged: centred in its box.
 assert.match(xml,/<text dominant-baseline="central" font-size="14.67" stroke="none" text-anchor="middle" x="20.785" y="6.15">Step 1<\/text>/);
 // The minipage reads in lines from its top-left corner, each within its 7.68em (102.4 px) at half an em a letter and a
 // quarter for a space.
 const lines=[...xml.matchAll(/<text font-size="13.33" stroke="none" text-anchor="start" x="0" y="([\d.]+)">([\s\S]*?)<\/text>/g)]
  .map(([, y, body])=>({y:Number(y),text:body.replace(/<[^>]+>/g,'')}));
 assert.deepEqual(lines.map(l=>l.text),['However,','it is a','important to the','the the and the.']);
 assert.ok(lines.every((l,i)=>i===0||l.y>lines[i-1].y),'top to bottom');
 assert.ok(lines.every(l=>(l.text.replace(/ /g,'').length*0.5+(l.text.split(' ').length-1)*0.25)*13.33<=102.4+1),'each line within the minipage');
 assert.match(xml,/<tspan font-weight="bold"> and<\/tspan>/,'bold words stay bold');
 for (const {text,m} of texts) assert.ok(m[0]*m[3]-m[1]*m[2]>0,`"${text}" is drawn mirrored`);
 // Rows of a tabular in a label are lines of their own, their cells side by side.
 const tabular='<figure id="S1.F4" class="ltx_figure"><svg id="S1.F4.pic1" class="ltx_picture" height="40" overflow="visible" version="1.1" viewBox="0 0 300 40" width="300">'
  +'<g><foreignObject style="font-size:10pt;" height="40" overflow="visible" width="300"><span class="ltx_foreignobject_container"><span class="ltx_foreignobject_content">'
  +'<span class="ltx_tabular"><span class="ltx_tbody"><span class="ltx_tr"><span class="ltx_td"><span class="ltx_text ltx_font_bold">German:</span></span><span class="ltx_td">Es besteht</span></span>'
  +'<span class="ltx_tr"><span class="ltx_td"><span class="ltx_text ltx_font_bold">Reference:</span></span><span class="ltx_td">However</span></span></span></span>'
  +'</span></span></foreignObject></g></svg><figcaption class="ltx_caption">Figure 4: Rows.</figcaption></figure>';
 const rows=arxivInlineImages(fragment(tabular),url).get('#S1.F4.pic1')!;
 assert.deepEqual([...rows.matchAll(/<text [^>]*>([\s\S]*?)<\/text>/g)].map(([, body])=>body.replace(/<[^>]+>/g,'')),['German: Es besteht','Reference: However']);
});

test('a table inside inline blocks (resizebox) reads as a table block (KAN, 2404.19756)',()=>{
 const wrapped=source.replace('<p id="p1">','<div class="ltx_inline-block ltx_align_center"><span class="ltx_transformed_outer"><span class="ltx_transformed_inner"><table class="ltx_tabular"><tr><td>Layer</td><td>Width</td></tr></table></span></span></div><p id="p1">');
 const bundle=build(wrapped),checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const clean=validateReaderBundle(build().manifestBytes,build().members,build().manifestSHA256);
 assert.equal(checked.index.blocks.filter(b=>b.kind==='table').length,clean.index.blocks.filter(b=>b.kind==='table').length+1);
 assert.ok(checked.index.blocks.some(b=>b.kind==='table'&&/Layer Width/.test(b.text)));
});

test('a list item holding a table keeps the table (KAN, 2404.19756)',()=>{
 const listed=source.replace('<p id="p1">','<ol class="ltx_enumerate"><li class="ltx_item"><div class="ltx_para">Compare:<table class="ltx_tabular"><tr><td>Depth</td><td>Error</td></tr></table></div></li></ol><p id="p1">');
 const bundle=build(listed),checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const item=checked.index.blocks.find(b=>b.kind==='list');
 assert.ok(item&&item.text.startsWith('Compare:'),'the item reads');
 assert.match(new TextDecoder().decode(bundle.members.get('index.html')),/<li[^>]*>Compare:<table>/);
});

test('a caption-only figure after a lone graphic paragraph reads as the figure then its caption (2610.17288 Figure 1)',()=>{
 const captioned=source.replace('<p id="p1">','<div class="ltx_para"><p class="ltx_p ltx_align_center"><span class="ltx_text ltx_inline-block"><img src="2601.01234v2/teaser.jpg" class="ltx_graphics" alt="[Uncaptioned image]"></span></p></div><figure class="ltx_figure"><figcaption class="ltx_caption"><span class="ltx_tag">Figure 1: </span>A teaser.</figcaption></figure><p id="p1">');
 const bundle=composeArxivReader({source:utf8(captioned),sourceID:'2601.01234',revision:2,
  images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}],[url+'/teaser.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]])});
 const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const kinds=checked.index.blocks.map(b=>b.kind);
 const figure=kinds.indexOf('figure');
 assert.equal(checked.index.figures.length,2,'the teaser is a full figure');
 assert.equal(checked.index.blocks[figure+1].kind,'paragraph');
 assert.match(checked.index.blocks[figure+1].text,/^Figure 1: A teaser\.$/);
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 assert.match(html,/<p class="reader-caption"[^>]*>/);
 assert.match(html,/<figure[^>]*>(?:(?!<\/figure>).)*<img alt="[^"]*" height="\d+" src="assets\/[a-f0-9]{64}\.jpg" width="\d+">/s,'the teaser is a full-size figure image, not a legend symbol');
 assert.equal((html.match(/reader-inline-image/g)||[]).length,0,'no inline image class in this paper');
 assert.ok(!kinds.includes('table')||kinds.filter(k=>k==='table').length===1,'the caption is not a table block');
});

test('inconsistent TeX is rejected; MathML outside the vocabulary shows its TeX rather than silently losing the equation',()=>{
 assert.throws(()=>build(source.replace(math,math.replace('>x^2</annotation>','>x^3</annotation>'))),/arxiv_math_mismatch/);
 // Revision 29: a formula the reader can't draw shows its LaTeX; the paper opens.
 const html=new TextDecoder().decode(build(source.replace(math,math.replace('<msup>','<maction>').replace('</msup>','</maction>'))).members.get('index.html'));
 assert.match(html,/<span class="reader-equation reader-inline reader-math-fallback" data-latex="x\^2"[^>]*>\\\(x\^2\\\)<\/span>/);
 assert.doesNotMatch(html,/maction/);
});

test('math styling or attributes outside the allow-list are left out, never refuse the paper (2606.05868 on build 55)',()=>{
 for(const replacement of [math.replace('<mi>x</mi>','<mi href="https://evil.example">x</mi>'),
  math.replace('<mi>x</mi>','<mi style="vertical-align:-2.1pt">x</mi>'),math.replace('<mi>x</mi>','<mi style="width:calc(1px)">x</mi>')]){
  const html=new TextDecoder().decode(build(source.replace(math,replacement)).members.get('index.html'));
  assert.doesNotMatch(html,/evil\.example|vertical-align|calc\(/,'nothing of the unknown attribute reaches the page');
  assert.match(html,/<mi>x<\/mi>/,'the formula keeps its content');
 }
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
 const inline=arxivInlineImages(text,url);
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
 // The reader owns its colours: a source math background is left out (build 43: boxed ± in dark mode).
 assert.ok(!/mathbackground/.test(new TextDecoder().decode(bundle.members.get('index.html'))),'no source math background');
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

test('the authors block reads as names with single marks, affiliations and notes, without footnotemark labels or e-mail',()=>{
 const note=(id,mark,role='footnotemark',body='')=>`<span id="${id}" class="ltx_note ltx_role_${role}"><sup class="ltx_note_mark">${mark}</sup><span class="ltx_note_outer"><span class="ltx_note_content"><sup class="ltx_note_mark">${mark}</sup><span class="ltx_note_type">${role}: </span>${body||`<span class="ltx_tag ltx_tag_note">${mark}</span>`}</span></span></span>`;
 const authors=`<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Rafael Rafailov ${note('fx1','2')}</span>${note('id1','†','thanks','Equal contribution; more junior authors listed earlier.')}</span>`
  +`<span class="ltx_author_before">  </span><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Archit Sharma${note('fx2','1')}  ${note('fx3','2')}</span></span>`
  +`<span class="ltx_author_before">  </span><span class="ltx_creator ltx_role_author"><span class="ltx_personname">${note('fx10','2')}  Stanford University ${note('fx11','3')}  CZ Biohub</span>`
  +`<span class="ltx_author_notes"><span class="ltx_author_notes_content"><span class="ltx_contact ltx_role_email"><span class="ltx_contact_name">Email: </span><a href="mailto:"><span class="ltx_text">{rafailov}@cs.stanford.edu</span></a></span></span></span></span></div>`;
 const bundle=build(source.replace('<div class="ltx_authors">A. Author</div>',authors+'<p>See <a href="#id1">the note</a>.</p>'));
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 const block=/<p class="reader-authors"[^>]*>(.*?)<\/p>/s.exec(html)?.[1]??'';
 assert.equal(block,'Rafael Rafailov<sup>2,†</sup>, Archit Sharma<sup>1,2</sup> <span class="reader-affiliations"><sup>2</sup>Stanford University<br><sup>3</sup>CZ Biohub</span> <span class="reader-notes"><sup>†</sup> Equal contribution; more junior authors listed earlier.</span>');
 assert.ok(!/footnotemark|Email|stanford\.edu/.test(block));
 const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 const authorsBlock=checked.index.blocks.find(b=>html.includes(`id="${b.id}" `)&&html.includes(`class="reader-authors" data-reader-block="${b.id}"`)) ?? checked.index.blocks[1];
 // Links to the notes resolve to the authors block.
 assert.match(html,new RegExp(`href="#${authorsBlock.id}">the note</a>`));
 assert.ok(checked.index.blocks.some(b=>b.text.startsWith('Rafael Rafailov')));
});

test('authors with one "Affiliation:" contact each get numbered marks; e-mail and labels go, a project page gets its own line',()=>{
 const creator=(name,affiliation,extra='')=>`<span class="ltx_creator ltx_role_author"><span class="ltx_personname">${name}\n</span><span class="ltx_author_notes"><span class="ltx_author_notes_content"><span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>${affiliation}${extra}\n</span></span></span></span>`;
 const authors=`<div class="ltx_authors">${creator('Chenghao Yue','Tsinghua University')}<span class="ltx_author_before">  </span>${creator('Hao Wang','Dalian University of Technology')}`
  +`<span class="ltx_author_before">  </span>${creator('Jiahao Chen','Peking University','<a href="https://seen-e.github.io/PRISM/" title="" class="ltx_ref ltx_href ltx_font_typewriter">https://seen-e.github.io/PRISM/</a>')}`
  +`<span class="ltx_author_before">  </span>${creator('Gayoung Kim',' A+HRI Laboratory, Incheon National University. <span class="ltx_text ltx_font_typewriter">{7rdud36, jow}@inu.ac.kr</span>')}</div>`;
 const bundle=build(source.replace('<div class="ltx_authors">A. Author</div>',authors));
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 const block=/<p class="reader-authors"[^>]*>(.*?)<\/p>/s.exec(html)?.[1]??'';
 assert.equal(block,'Chenghao Yue<sup>1</sup>, Hao Wang<sup>2</sup>, Jiahao Chen<sup>3</sup>, Gayoung Kim<sup>4</sup> <span class="reader-affiliations"><sup>1</sup>Tsinghua University<br><sup>2</sup>Dalian University of Technology<br><sup>3</sup>Peking University<br><sup>4</sup>A+HRI Laboratory, Incheon National University.<br><a href="https://seen-e.github.io/PRISM/" rel="noopener noreferrer">https://seen-e.github.io/PRISM/</a></span>');
});

test('a name that was a graphic (a team logo) is replaced by the library author metadata',()=>{
 const authors='<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname"><span class="ltx_text ltx_font_bold"><img src="2601.01234v2/figure.jpg" class="ltx_graphics" alt="[Uncaptioned image]"></span><span class="ltx_text ltx_font_bold"> Team</span></span></span></div>';
 const text=source.replace('<div class="ltx_authors">A. Author</div>',authors);
 const named=composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]]),authors:['LoongSage Team']});
 const html=new TextDecoder().decode(named.members.get('index.html'));
 assert.match(html,/<p class="reader-authors"[^>]*>LoongSage Team<\/p>/);
 assert.match(html,/left out 1 inline graphic/);
 // Without metadata the words that remain are shown, as before.
 const bare=new TextDecoder().decode(build(text).members.get('index.html'));
 assert.match(bare,/<p class="reader-authors"[^>]*>Team<\/p>/);
 // The same source and metadata give the same bundle on every device; different metadata is a different bundle.
 assert.equal(composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]]),authors:['LoongSage Team']}).manifestSHA256,named.manifestSHA256);
 assert.notEqual(build(text).manifestSHA256,named.manifestSHA256);
});

test('a title page a template left in error markers is read by macro: abstract after the header, affiliations and notes in it, plumbing and the date line left out',()=>{
 const marker=(name)=>`<span class="ltx_ERROR undefined">${name}</span>`;
 const preamble=`<div id="tp1" class="ltx_para ltx_noindent">${marker('\\\\DreamXLogo')}<p id="tp1.2" class="ltx_p">figures/dreamx_logo.png\n${marker('\\\\DreamXRunningTitle')}Urbex\n${marker('\\\\DreamXHeaderRight')}October 13, 2026\n${marker('\\\\DreamXAuthorLineBreak')}\n1]Wuhan University\n2]DreamX Team, Alibaba Group\n${marker('\\\\contribution')}[†]Project leader\n${marker('\\\\reportabstract')}City-scale 3D grounding is commonly formulated as candidate ranking.</p></div>`;
 const authors=`<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Yu Wang\n</span></span><span class="ltx_author_before">  </span><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Yansheng Li\n</span><span class="ltx_author_notes"><span class="ltx_author_notes_content"><span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>[\n</span><span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>[\n</span></span></span></span></div><div class="ltx_dates">October 13, 2026</div>`;
 const text=source.replace('<h1>Authored HTML fixture</h1><div class="ltx_authors">A. Author</div>',preamble+'<h1>Authored HTML fixture</h1>'+authors);
 const bundle=build(text); const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 assert.deepEqual(checked.index.blocks.slice(0,5).map(b=>[b.kind,b.text.slice(0,32)]),[['heading','Authored HTML fixture'],['paragraph','Yu Wang, Yansheng Li 1Wuhan Univ'],['heading','Abstract'],['paragraph','City-scale 3D grounding is commo'],['heading','1 Introduction']]);
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 const block=/<p class="reader-authors"[^>]*>(.*?)<\/p>/s.exec(html)?.[1]??'';
 assert.equal(block,'Yu Wang, Yansheng Li <span class="reader-affiliations"><sup>1</sup>Wuhan University<br><sup>2</sup>DreamX Team, Alibaba Group</span> <span class="reader-notes"><sup>†</sup> Project leader</span>');
 assert.ok(!/dreamx_logo|October 13|\[ \[|<sup><\/sup>/.test(html),'plumbing, the date line and empty marks are gone');
 assert.match(html,/left out 6 unsupported commands/);
});

// Audit 2026-10-15 (docs/proposals/READER_ARCHITECTURE_RETHINK.md): the shapes that refused real papers now degrade.
const fragment = (body) => source.replace('<p id="p1">', body + '<p id="p1">');
const blocksOf = (bundle) => validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256).index.blocks.map(b => [b.kind, b.text.slice(0, 40)]);

test('an algorithm figure (caption plus a listing with math) is a table block, not a refusal', () => {
 const bundle = build(fragment(`<figure id="alg1" class="ltx_float ltx_float_algorithm"><figcaption class="ltx_caption"><span class="ltx_tag">Algorithm 1 </span>Sampling</figcaption><div class="ltx_listing"><div class="ltx_listingline">repeat ${math} until done</div></div></figure>`));
 const blocks = blocksOf(bundle);
 assert.ok(blocks.some(([kind, text]) => kind === 'table' && /Sampling/.test(text) && /repeat/.test(text)), JSON.stringify(blocks.slice(0, 4)));
 assert.equal(validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256).index.equations.length, 3);
});

test('an "equation" without math reads as a paragraph', () => {
 const bundle = build(fragment('<table id="S5.Ex1" class="ltx_equation ltx_eqn_table"><tbody><tr class="ltx_equation ltx_eqn_row"><td class="ltx_eqn_cell"><span class="ltx_markedasmath">{dataset}__{planner}.json</span></td></tr></tbody></table>'));
 assert.ok(blocksOf(bundle).some(([kind, text]) => kind === 'paragraph' && text.includes('{dataset}__{planner}.json')));
});

test('a figure inside a list item becomes its own block after the list; the item keeps its words', () => {
 const bundle = build(fragment(`<ul class="ltx_itemize"><li class="ltx_item">First point <figure id="S1.F9" class="ltx_figure"><img src="2601.01234v2/figure.jpg"><figcaption>Figure 9: Inside an item.</figcaption></figure></li><li class="ltx_item">Second point</li></ul>`));
 const blocks = blocksOf(bundle);
 const first = blocks.findIndex(([, text]) => text === 'First point'), figure = blocks.findIndex(([kind, text]) => kind === 'figure' && /Inside an item/.test(text));
 assert.ok(first >= 0 && figure > first && blocks[first + 1][1] === 'Second point', JSON.stringify(blocks.slice(0, 6)));
});

test('a TikZ picture whose label holds a table reads as a table block', () => {
 const bundle = build(fragment('<div class="ltx_para"><p class="ltx_p"><svg class="ltx_picture" viewBox="0 0 10 10"><foreignObject width="10" height="10"><table><tbody><tr><td>cell a</td><td>cell b</td></tr></tbody></table></foreignObject></svg></p></div>'));
 assert.ok(blocksOf(bundle).some(([kind, text]) => kind === 'table' && /cell a/.test(text)));
});

test('without an h1 the catalog title heads the paper and its bold repeat is left out; a stub page is unavailable', () => {
 const text = source.replace('<h1>Authored HTML fixture</h1><div class="ltx_authors">A. Author</div>', '<div class="ltx_para"><p class="ltx_p"><span class="ltx_text ltx_font_bold">A Bold Paragraph Title</span></p></div>');
 const titled = composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }]]), title: 'A Bold Paragraph Title' });
 const blocks = blocksOf(titled);
 assert.deepEqual(blocks[0], ['heading', 'A Bold Paragraph Title']);
 assert.ok(!blocks.some(([kind, t]) => kind === 'paragraph' && t === 'A Bold Paragraph Title'), 'the repeat is gone');
 assert.throws(() => build(text), /arxiv_title/, 'no title anywhere');
 const stub = '<html><body><article class="ltx_document"><div class="ltx_para"><p class="ltx_p">See pages 1-last of 0_main.pdf</p></div></article></body></html>';
 assert.throws(() => composeArxivReader({ source: utf8(stub), sourceID: '2601.01234', revision: 2, images: new Map(), title: 'Adam' }), /arxiv_article/);
});

test('a top-level svg is a figure, not a tiny inline image', () => {
 const text = fragment('<svg id="S1.F3" class="ltx_picture" viewBox="0 0 10 10"><rect width="4" height="4"/></svg>');
 const inline = arxivInlineImages(text, url);
 assert.deepEqual([...inline.keys()], ['#S1.F3'], 'the picture is the figure\'s own image');
 const png = admitReaderImage(new Uint8Array(readFileSync(new URL('../fixtures/reader/assets/attention.png', import.meta.url))));
 const images = new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }], ['#S1.F3', { ...png, inputSHA256: sha256Hex(utf8(inline.get('#S1.F3')!)) }]]);
 const bundle = composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images });
 const checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 assert.equal(checked.index.figures.length, 2, 'the fixture figure and the svg');
 assert.ok(!/reader-inline-image/.test(new TextDecoder().decode(bundle.members.get('index.html'))));
});

test('front matter reads first even when LaTeXML put a figure or a venue line before the title', () => {
 const text = source.replace('<h1>Authored HTML fixture</h1>', '<div class="ltx_para"><p class="ltx_p">AI for Chip Design</p></div><figure id="S0.F1" class="ltx_figure"><img src="2601.01234v2/figure.jpg"><figcaption>Figure 1: Samples.</figcaption></figure><h1>Authored HTML fixture</h1>');
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const blocks = checked.index.blocks.map(b => [b.kind, b.text]);
 assert.deepEqual(blocks[0], ['heading', 'Authored HTML fixture']);
 assert.equal(blocks[1][0], 'paragraph', 'the authors follow the title');
 assert.equal(blocks.findIndex(([, t]) => t === 'AI for Chip Design') , 2, 'the venue line follows the front matter');
 assert.ok(/Figure 1: Samples/.test(blocks[3][1]), JSON.stringify(blocks.slice(0, 5)));
 assert.equal(checked.index.figures[0].caption, 'Figure 1: Samples.', 'figures are indexed in page order');
});

test('the library names head a paper whose HTML has no author block; a paragraph repeating them and an empty one are left out', () => {
 const text = source.replace('<div class="ltx_authors">A. Author</div>', '<span class="ltx_rule" style="width:100%"> </span><div class="ltx_para"><p class="ltx_p"><span class="ltx_text ltx_font_bold">Ada Lovelace</span> <span class="ltx_text ltx_font_bold">Alan Turing</span></p></div>');
 const bundle = composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }]]), authors: ['Ada Lovelace', 'Alan Turing'] });
 const checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const blocks = checked.index.blocks.map(b => [b.kind, b.text]);
 assert.deepEqual(blocks.slice(0, 2), [['heading', 'Authored HTML fixture'], ['paragraph', 'Ada Lovelace, Alan Turing']], JSON.stringify(blocks.slice(0, 4)));
 assert.ok(!blocks.some(([, t]) => t === ''), 'no empty block');
 assert.match(new TextDecoder().decode(bundle.members.get('index.html')), /class="reader-authors"[^>]*>Ada Lovelace, Alan Turing</);
});

test('a math mark beside a name and a footnote in running text keep their symbols', () => {
 const dagger = '<math alttext="\\dagger" display="inline"><semantics><mo>†</mo><annotation encoding="application/x-tex">\\dagger</annotation></semantics></math>';
 const text = source.replace('<div class="ltx_authors">A. Author</div>', `<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Zihao Pan<sup class="ltx_sup">1</sup><sup class="ltx_sup">${dagger}</sup></span></span></div>`)
  .replace('<p id="p1">', '<p class="ltx_p">Results<span class="ltx_note ltx_role_footnotetext"><sup class="ltx_note_mark">†</sup><span class="ltx_note_outer"><span class="ltx_note_content"><sup class="ltx_note_mark">†</sup><span class="ltx_note_type">footnotetext: </span>Corresponding authors.</span></span></span> follow.</p><p id="p1">');
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const html = new TextDecoder().decode(bundle.members.get('index.html'));
 assert.match(html, /Zihao Pan<sup>1,†<\/sup>/, html.slice(0, 600));
 assert.ok(checked.index.blocks.some(b => b.text === 'Results† Corresponding authors. follow.'), JSON.stringify(checked.index.blocks.map(b => b.text).slice(0, 6)));
 assert.ok(!html.includes('footnotetext'));
});

test('a block longer than the index allows is excerpted, never a refusal', () => {
 const bundle = build(fragment(`<p class="ltx_p">${'Author Name, '.repeat(2000)}end.</p>`));
 const long = blocksOf(bundle).find(([, t]) => t.startsWith('Author Name,'));
 assert.ok(long, 'the block is there');
 assert.ok(new TextDecoder().decode(bundle.members.get('index.html')).includes('end.'), 'the reader keeps the whole text');
});

test('panels laid out in a tabular of graphics are the figure\'s images; publication notes under the title are left out', () => {
 const text = source.replace('<h1>Authored HTML fixture</h1>', '<h1>Authored HTML fixture</h1><span class="ltx_pubnotes ltx_pubnotes_meta"><span class="ltx_pubnotes_content"><span class="ltx_pubnote">Revised: October 5, 2026</span></span></span>')
  .replace('<p id="p1">', '<figure id="S4.F1" class="ltx_figure"><table class="ltx_tabular"><tbody><tr><td><img src="2601.01234v2/figure.jpg"></td><td><img src="2601.01234v2/figure.jpg"></td></tr></tbody></table><figcaption>Figure 1: Two panels.</figcaption></figure><p id="p1">');
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const panels = checked.index.figures.find(f => f.caption === 'Figure 1: Two panels.');
 assert.ok(panels && panels.asset_paths.length === 1, JSON.stringify(checked.index.figures));
 assert.equal(checked.index.blocks[1].kind, 'paragraph', 'the authors follow the title');
 assert.ok(!checked.index.blocks.some(b => /Revised:/.test(b.text)));
 assert.ok(!checked.index.blocks.at(-1)!.text.startsWith('Note:'), 'nothing was left out');
});

test('a custom title page (2610.15371): the catalog title heads it, its logo is no figure, its rule is no block', () => {
 const text = source.replace('<h1>Authored HTML fixture</h1><div class="ltx_authors">A. Author</div>', '<div class="ltx_titlepage"><p class="ltx_p"><span class="ltx_rule" style="width:345pt"> </span><span class="ltx_text"></span></p><p class="ltx_p"><img src="2601.01234v2/figure.jpg" class="ltx_graphics"></p><p class="ltx_p"><span class="ltx_text ltx_font_bold">A Sovereign Model</span></p><p class="ltx_p"><span class="ltx_text ltx_font_bold">Core Team:<span class="ltx_text ltx_font_medium"> Ada Lovelace, Alan Turing</span></span></p></div>');
 const bundle = composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }]]), authors: ['Ada Lovelace', 'Alan Turing'], title: 'A Sovereign Model' });
 const checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const blocks = checked.index.blocks.map(b => [b.kind, b.text]);
 // The role line ("Core Team: …") names the catalog's authors: it folds into the header (build 46's title-page fold).
 assert.deepEqual(blocks.slice(0, 3), [['heading', 'A Sovereign Model'], ['paragraph', 'Ada Lovelace, Alan Turing'], ['heading', '1 Introduction']], JSON.stringify(blocks.slice(0, 5)));
 assert.equal(checked.index.figures.length, 1, 'the fixture figure only; the logo is not one');
 assert.match(checked.index.blocks.at(-1)!.text, /left out 1 inline graphic/);
});

test('an author block set as a table (2610.10238): the first row\'s cells are the authors, the next the affiliations, marks plain, names unbolded', () => {
 const cell = (name, mark) => `<span class="ltx_td ltx_align_center"><span class="ltx_text ltx_font_bold">${name}<sup class="ltx_sup"><span class="ltx_text ltx_font_italic">${mark}</span></sup></span></span>`;
 const text = source.replace('<div class="ltx_authors">A. Author</div>', `<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname"><span class="ltx_tabular"><span class="ltx_thead"><span class="ltx_tr">${cell('Hao Wang', '1,2')}${cell('Qiwei Zeng', '2')}${cell('Lei Bi', '2')}</span></span><span class="ltx_tbody"><span class="ltx_tr"><span class="ltx_td"><sup class="ltx_sup">1</sup>The University of Sydney <sup class="ltx_sup">2</sup>Shanghai Jiao Tong University</span></span></span></span></span></span></div>`);
 const bundle = build(text), html = new TextDecoder().decode(bundle.members.get('index.html'));
 const block = /<p class="reader-authors"[^>]*>([\s\S]*?)<\/p>/.exec(html)![1];
 assert.equal(block, 'Hao Wang<sup>1,2</sup>, Qiwei Zeng<sup>2</sup>, Lei Bi<sup>2</sup> <span class="reader-affiliations"><sup>1</sup>The University of Sydney<br><sup>2</sup>Shanghai Jiao Tong University</span>');
});

test('a custom title page without an author block (2610.14075): names with marks, affiliations and notes read into the header; the date and e-mail lines go; a subtitle stays', () => {
 const text = source.replace('<h1>Authored HTML fixture</h1><div class="ltx_authors">A. Author</div>', '<h1>Authored HTML fixture</h1><div class="ltx_para"><p class="ltx_p">A Controlled Study for Tabletop Manipulation</p></div><div class="ltx_para"><p class="ltx_p">Public Technical Report Date: October 2026</p></div><div class="ltx_para"><p class="ltx_p">Yuhui Duan<sup class="ltx_sup">1</sup> Shi Jin<sup class="ltx_sup">1</sup> Yan Ding<sup class="ltx_sup">2,*</sup></p></div><div class="ltx_para"><p class="ltx_p"><sup class="ltx_sup">1</sup>Soochow University <sup class="ltx_sup">2</sup>Fudan University</p></div><div class="ltx_para"><p class="ltx_p"><sup class="ltx_sup">*</sup>Corresponding authors: someone@example.com, other@example.com</p></div>');
 const bundle = composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }]]), authors: ['Yuhui Duan', 'Shi Jin', 'Yan Ding'] });
 const checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256), html = new TextDecoder().decode(bundle.members.get('index.html'));
 const block = /<p class="reader-authors"[^>]*>([\s\S]*?)<\/p>/.exec(html)![1];
 assert.equal(block, 'Yuhui Duan<sup>1</sup>, Shi Jin<sup>1</sup>, Yan Ding<sup>2,*</sup> <span class="reader-affiliations"><sup>1</sup>Soochow University<br><sup>2</sup>Fudan University</span> <span class="reader-notes"><sup>*</sup> Corresponding authors</span>');
 const texts = checked.index.blocks.map(b => b.text);
 assert.equal(texts[2], 'A Controlled Study for Tabletop Manipulation', JSON.stringify(texts.slice(0, 5)));
 assert.ok(!texts.some(t => /Date:|example\.com/.test(t)), 'the date and e-mail lines are gone');
});

test('an inline picture carries the pattern the page defined elsewhere; a reference nothing defines is left out', () => {
 const text = source.replace('<p id="p1">', '<svg id="shared" class="ltx_picture" width="0" height="0"><defs><pattern id="pgfpat3" width="4" height="4"><path d="M0 0L4 4"/></pattern></defs></svg><figure id="S4.F9" class="ltx_figure"><svg id="S4.F9.pic1" class="ltx_picture" viewBox="0 0 10 10"><defs><pattern href="#pgfpat3" id="pgfupat20"/></defs><rect width="4" height="4" fill="url(#pgfupat20)"/><use href="#nowhere"/></svg><figcaption>Figure 9: Patterned.</figcaption></figure><p id="p1">');
 const inline = arxivInlineImages(text, url);
 const xml = inline.get('#S4.F9.pic1')!;
 assert.ok(xml, [...inline.keys()].join());
 assert.match(xml, /<pattern [^>]*id="pgfpat3"/, 'the shared pattern travels with the picture');
 assert.ok(!xml.includes('#nowhere'), 'the dangling reference is left out');
});

test('a size command LaTeXML left in a caption is no word of the paper (2610.14075: "\\scriptsize①")', () => {
 const text = source.replace('<p id="p1">', '<figure id="S9.F7" class="ltx_figure"><img src="2601.01234v2/figure.jpg"><figcaption>Figure 1: Overview. \\scriptsize① The design crosses FoV. \\scriptsize② Each rollout is scored.</figcaption></figure><p id="p1">');
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const caption = checked.index.figures.find(f => /Overview/.test(f.caption))!.caption;
 assert.equal(caption, 'Figure 1: Overview. ① The design crosses FoV. ② Each rollout is scored.');
 assert.ok(!new TextDecoder().decode(bundle.members.get('index.html')).includes('scriptsize'));
});

test('build 43 (2610.18683): a second line of marked names is authors, not affiliations; a macro definition paragraph goes; math colours go; unresolved citations go with their parentheses', () => {
 const text = source.replace('<div class="ltx_authors">A. Author</div>', '<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Bowen Ding<sup class="ltx_sup">1</sup>, Futing Wang<sup class="ltx_sup">1</sup><br class="ltx_break">Heyuan Deng<sup class="ltx_sup">4</sup> Fei Mi<sup class="ltx_sup">4,‡</sup><br class="ltx_break"><sup class="ltx_sup">1</sup>Zhejiang University <sup class="ltx_sup">4</sup>Huawei</span></span></div>')
  .replace('<p id="p1">', '<div class="ltx_para"><p class="ltx_p">[1]<span class="ltx_text ltx_font_bold">for each</span> #1 <span class="ltx_text ltx_font_bold">do</span></p></div><div class="ltx_para"><p class="ltx_p">Applications in software engineering (<span class="ltx_text ltx_font_bold">?</span>), assistance (<span class="ltx_text ltx_font_bold">??</span>) and PPO (<span class="ltx_text ltx_font_bold">?</span>) address this with <math alttext="\\pm" display="inline"><semantics><mo style="--ltx-bg-color:#EBEBFF;" mathbackground="#EBEBFF" mathcolor="#16697A">±</mo><annotation encoding="application/x-tex">\\pm</annotation></semantics></math> noise.</p></div><p id="p1">');
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const html = new TextDecoder().decode(bundle.members.get('index.html'));
 const block = /<p class="reader-authors"[^>]*>([\s\S]*?)<\/p>/.exec(html)![1];
 assert.equal(block, 'Bowen Ding<sup>1</sup>, Futing Wang<sup>1</sup>, Heyuan Deng<sup>4</sup>, Fei Mi<sup>4,‡</sup> <span class="reader-affiliations"><sup>1</sup>Zhejiang University<br><sup>4</sup>Huawei</span>');
 const texts = checked.index.blocks.map(b => b.text);
 assert.ok(!texts.some(t => /for each #1/.test(t)), 'the macro definition is gone');
 assert.ok(texts.some(t => t === 'Applications in software engineering, assistance and PPO address this with \\pm noise.'), JSON.stringify(texts.slice(0, 8)));
 assert.ok(!/mathbackground|mathcolor/.test(html), 'the reader owns its colours');
 assert.match(texts.at(-1)!, /1 unsupported command.*3 unresolved citations/);
});

test('a table drawn as a TikZ picture is the figure\'s own image; a picture beside words stays a legend symbol', () => {
 const text = source.replace('<p id="p1">', `<figure id="A5.T11" class="ltx_table"><figcaption>Table 11: An example.</figcaption><div class="ltx_logical-block"><div class="ltx_para"><span class="ltx_inline-block"><svg id="A5.T11.p1.pic1" class="ltx_picture" viewBox="0 0 528 610" width="528" height="610"><rect width="100" height="40"/></svg></span></div></div></figure><p id="p1">`);
 const inline = arxivInlineImages(text, url);
 assert.deepEqual([...inline.keys()], ['#A5.T11.p1.pic1']);
 const png = admitReaderImage(new Uint8Array(readFileSync(new URL('../fixtures/reader/assets/attention.png', import.meta.url))));
 const images = new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }], ['#A5.T11.p1.pic1', { ...png, inputSHA256: sha256Hex(utf8(inline.get('#A5.T11.p1.pic1')!)) }]]);
 const bundle = composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images });
 const html = new TextDecoder().decode(bundle.members.get('index.html'));
 const figure = /<figure[^>]*>[\s\S]*?Table 11[\s\S]*?<\/figure>/.exec(html)![0];
 assert.ok(/<img [^>]*src="assets\/[a-f0-9]{64}\.png"/.test(figure) && !/reader-inline-image/.test(figure), figure.slice(0, 400));
});

test('a graphic that is not one of the paper\'s assets (page chrome, an empty src) is left out and counted, never a refusal (2610.20570)', () => {
 const text = source.replace('<p id="p1">', '<figure id="S9.F1" class="ltx_figure"><img src="/static/base/1.0.1/images/funders/simons-foundation.png"><img src="2601.01234v2/figure.jpg"><figcaption>Figure 9: Funded.</figcaption></figure><div class="ltx_para"><p class="ltx_p">Smiley <img src="" class="ltx_graphics"> bones.</p></div><p id="p1">');
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const figure = checked.index.figures.find(f => /Funded/.test(f.caption))!;
 assert.equal(figure.asset_paths.length, 1, 'the paper\'s own image stays');
 assert.ok(checked.index.blocks.some(b => b.text === 'Smiley bones.'));
 assert.match(checked.index.blocks.at(-1)!.text, /left out 2 inline graphics/);
});

test('several captions in one figure read as its caption and paragraphs; images past the figure limit are left out and counted (2610.20608, 2610.20584)', () => {
 const sub = (n) => `<span class="ltx_inline-block"><img src="2601.01234v2/figure.jpg"><figcaption>(${n}) panel ${n}</figcaption></span>`;
 const grid = Array.from({ length: 20 }, () => '<img src="2601.01234v2/figure.jpg">').join('');
 const text = source.replace('<p id="p1">', `<figure id="S9.F1" class="ltx_figure">${sub('a')}${sub('b')}<figcaption>Figure 9: Two panels.</figcaption></figure><figure id="S9.F2" class="ltx_figure">${grid}<figcaption>Figure 10: A grid.</figcaption></figure><p id="p1">`);
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const two = checked.index.figures.find(f => /Two panels/.test(f.caption))!, grid10 = checked.index.figures.find(f => /A grid/.test(f.caption))!;
 assert.ok(two && grid10, JSON.stringify(checked.index.figures.map(f => f.caption)));
 const html = new TextDecoder().decode(bundle.members.get('index.html'));
 assert.match(html, /<p>\(a\) panel a<\/p>/, 'a sub-caption is a paragraph inside the figure');
 assert.equal((html.match(/<img /g) || []).length, 1 + 2 + 16, 'the fixture figure, two panels, sixteen of twenty');
 assert.match(checked.index.blocks.at(-1)!.text, /left out 4 inline graphics/);
});

test('math inside the date line goes with the date line (2610.20570: a coverage refusal)', () => {
 const text = source.replace('<h1>Authored HTML fixture</h1>', `<h1>Authored HTML fixture</h1><div class="ltx_dates">(October ${math} 2026)</div>`);
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 assert.ok(!checked.index.blocks.some(b => /October/.test(b.text)), 'the date line is gone');
});

test('a picture without an id is named and referenced like any other (2610.20584)', () => {
 const text = source.replace('<p id="p1">', '<figure id="S9.F3" class="ltx_figure"><svg class="ltx_picture" viewBox="0 0 10 10" width="10" height="10"><rect width="4" height="4"/></svg><figcaption>Figure 9: Unnamed.</figcaption></figure><p id="p1">');
 const inline = arxivInlineImages(text, url);
 assert.deepEqual([...inline.keys()], ['#srpic1']);
});

test('a dropped paragraph takes its equations out of the index (2610.20570)', () => {
 const text = source.replace('<p id="p1">', `<div class="ltx_para"><p class="ltx_p">[1]<span class="ltx_text ltx_font_bold">for each</span> #1 ${math} <span class="ltx_text ltx_font_bold">do</span></p></div><p id="p1">`);
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 assert.equal(checked.index.equations.length, 2, 'the fixture\'s two equations only');
});

test('build 46 headers: a title keeps no line breaks; a logo before the author lines goes; an author table after the abstract folds in; a name run into its affiliations splits; notes split by mark', () => {
 const title = source.replace('<h1>Authored HTML fixture</h1>', '<h1>Before They Can Solve:<br class="ltx_break">Predicting Performance</h1>');
 const titled = new TextDecoder().decode(build(title).members.get('index.html'));
 assert.match(titled, /<h1[^>]*>Before They Can Solve: Predicting Performance<\/h1>/);

 const page = source.replace('<h1>Authored HTML fixture</h1><div class="ltx_authors">A. Author</div>', '<h1>Authored HTML fixture</h1>'
  + '<figure class="ltx_figure"><img src="2601.01234v2/figure.jpg"></figure><div class="ltx_para"><p class="ltx_p"><span class="ltx_text ltx_font_italic">October 2026</span></p></div>'
  + '<div class="ltx_para"><p class="ltx_p">Ada Lovelace<sup class="ltx_sup">1,∗</sup> Alan Turing<sup class="ltx_sup">2</sup></p></div>'
  + '<div class="ltx_para"><p class="ltx_p"><sup class="ltx_sup">1</sup> Analytical Engines <sup class="ltx_sup">2</sup> Bletchley Park</p></div>'
  + '<div class="ltx_para"><p class="ltx_p"><sup class="ltx_sup">∗</sup> Equal contribution. <sup class="ltx_sup">†</sup> Corresponding authors.</p></div>'
  + '<div class="ltx_abstract"><h6 class="ltx_title">Abstract</h6><p class="ltx_p">We study engines.</p></div>'
  + '<table class="ltx_tabular"><tr><td><span class="ltx_text ltx_font_italic">Grace Hopper<sup class="ltx_sup">3</sup><sup class="ltx_sup">4</sup></span></td></tr><tr><td><sup class="ltx_sup">3</sup>Navy <sup class="ltx_sup">4</sup>Yale</td></tr><tr><td>grace@navy.mil</td></tr></table>');
 const bundle = composeArxivReader({ source: utf8(page), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }]]), authors: ['Ada Lovelace', 'Alan Turing', 'Grace Hopper'] });
 const html = new TextDecoder().decode(bundle.members.get('index.html'));
 const header = /<p class="reader-authors"[^>]*>([\s\S]*?)<\/p>/.exec(html)![1];
 assert.match(header, /^Ada Lovelace<sup>1,∗<\/sup>, Alan Turing<sup>2<\/sup>, Grace Hopper<sup>3,4<\/sup> <span class="reader-affiliations">/, header);
 assert.match(header, /Analytical Engines<br><sup>2<\/sup>Bletchley Park<br><sup>3<\/sup>Navy<br><sup>4<\/sup>Yale/);
 assert.match(header, /<span class="reader-notes"><sup>∗<\/sup> Equal contribution\.<br><sup>†<\/sup> Corresponding authors\.<\/span>/);
 const checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 assert.ok(!checked.index.blocks.some(b => /October 2026|navy\.mil|Grace Hopper3/.test(b.text) && !/^Ada Lovelace/.test(b.text)), JSON.stringify(checked.index.blocks.slice(0, 6).map(b => b.text)));
 assert.equal(checked.index.figures.length, 1, 'the logo is gone; the fixture figure stays');

 const runTogether = source.replace('<div class="ltx_authors">A. Author</div>', '<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname"><span class="ltx_text">Ada Lovelace</span> <span class="ltx_text">Analytical Engines</span><span class="ltx_text"> <span class="ltx_text">University of London, Kensington</span><br class="ltx_break"><span class="ltx_text"><sup class="ltx_sup">†</sup>Corresponding Author: ada@engines.org</span></span></span></span></div>');
 const run = composeArxivReader({ source: utf8(runTogether), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', { ...admitted, inputSHA256: sha256Hex(raw) }]]), authors: ['Ada Lovelace'] });
 const runHeader = /<p class="reader-authors"[^>]*>([\s\S]*?)<\/p>/.exec(new TextDecoder().decode(run.members.get('index.html')))![1];
 assert.ok(runHeader.startsWith('Ada Lovelace'), runHeader);
 assert.ok(!/Kensington<\/sup>|, Kensington/.test(runHeader.split('<span')[0]), 'the affiliation is not a name: ' + runHeader);
 assert.match(runHeader, /<span class="reader-notes"><sup>†<\/sup> Corresponding Author<\/span>/, runHeader);
});

test('picture panels under one caption are one figure, panel captions inside, a panel reference opens it (2610.19525 Figure 1)', () => {
 const panel = (n: string) => `<figure id="S8.F1.sf${n}" class="ltx_figure ltx_figure_panel"><img src="2601.01234v2/figure.jpg"><figcaption>(${n}) Panel ${n}.</figcaption></figure>`;
 const text = source.replace('<p id="p1">', `<figure id="S8.F1" class="ltx_figure">${panel('a')}${panel('b')}<figcaption>Figure 1: Two panels in one figure.</figcaption></figure><p id="pref">See <a href="#S8.F1.sfb" class="ltx_ref">1(b)</a>.</p><p id="p1">`);
 const bundle = build(text), checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
 const one = checked.index.figures.find(f => /Two panels in one figure/.test(f.caption));
 assert.ok(one, JSON.stringify(checked.index.figures.map(f => f.caption)));
 assert.equal(one!.caption, 'Figure 1: Two panels in one figure.');
 assert.ok(!checked.index.figures.some(f => /^\(a\)|^\(b\)/.test(f.caption)), 'panels are not figures of their own');
 assert.ok(!checked.index.blocks.some(b => b.kind === 'paragraph' && /^Figure 1:/.test(b.text)), 'the caption is the figure\'s, not a paragraph');
 const html = new TextDecoder().decode(bundle.members.get('index.html'));
 assert.match(html, /<p>\(a\) Panel a\.<\/p>/);
 assert.match(html, new RegExp(`href="#${one!.id}"`), 'a reference to panel (b) opens the figure');
});

// Revision 14 (staging-library sweep, 2026-10-15): what arXiv's HTML lacks or a template left behind reads honestly.
function buildWith(text: string, catalog: { title?: string; authors?: string[] } = {}) {
 const bundle=composeArxivReader({source:utf8(text),sourceID:'2601.01234',revision:2,
  images:new Map([[url+'/figure.jpg',{...admitted,inputSHA256:sha256Hex(raw)}]]),...catalog});
 const checked=validateReaderBundle(bundle.manifestBytes,bundle.members,bundle.manifestSHA256);
 return {checked,html:new TextDecoder().decode(bundle.members.get('index.html'))};
}

test('a figure whose image arXiv\'s HTML lost says so before its caption (CyberArena, 2610.19005)',()=>{
 const lost='<figure class="ltx_figure" id="S1.F9"><img src="" id="S1.F9.g1" class="ltx_graphics ltx_missing ltx_missing_image" alt="Refer to caption"><figcaption class="ltx_caption">Figure 9: Lost on arXiv.</figcaption></figure>';
 const {checked,html}=buildWith(source.replace('<ol>',lost+'<ol>'));
 assert.match(html,/<p class="reader-caption"[^>]*><em>This figure is not in arXiv’s HTML version of the paper; the PDF has it\.<\/em> Figure 9: Lost on arXiv\.<\/p>/);
 assert.equal(checked.index.figures.length,1,'no figure entry without an image');
 assert.doesNotMatch(html,/inline graphic/,'not counted as a stray graphic');
 // A caption whose figure had no graphic at all (\captionof after an unwrapped image) gets no note.
 const plain=buildWith(source.replace('<ol>','<figure id="S1.F8"><figcaption>Figure 8: Just a caption.</figcaption></figure><ol>')).html;
 assert.match(plain,/<p class="reader-caption"[^>]*>Figure 8: Just a caption\.<\/p>/);
});

test('a title set as a picture is named by the catalog title, in the heading and the index (VideoJev, 2610.18615)',()=>{
 const pictured=source.replace('<h1>Authored HTML fixture</h1>','<h1 class="ltx_title ltx_title_document"><span class="ltx_text"><object type="image/svg+xml" data="2601.01234v2/title.svg" class="ltx_graphics"></object></span></h1>');
 const {checked,html}=buildWith(pictured,{title:'VideoJev: A Catalog Title',authors:['A. Author']});
 assert.equal(checked.index.title,'VideoJev: A Catalog Title');
 assert.match(html,/<h1[^>]*>VideoJev: A Catalog Title<\/h1>/);
 assert.throws(()=>buildWith(pictured.replace('</h1>','</h1><h1>Second</h1>')),'two titles still refuse');
});

test('an author block naming none of the paper\'s authors gives way to the catalog; real names with marks stay (2610.20588)',()=>{
 const placeholder=buildWith(source.replace('<div class="ltx_authors">A. Author</div>','<div class="ltx_authors">Lorem Dolor</div>'),{authors:['Walter Simoncini','Ada Lovelace']}).html;
 assert.match(placeholder,/<p class="reader-authors"[^>]*>Walter Simoncini, Ada Lovelace<\/p>/);
 const real=buildWith(source.replace('<div class="ltx_authors">A. Author</div>','<div class="ltx_authors">Rafael Rafailov<sup>2,†</sup>, Berkay Köprü</div>'),{authors:['Rafael Rafailov','Berkay Kopru']}).html;
 assert.match(real,/Rafael Rafailov<sup>2,†<\/sup>, Berkay Köprü/,'the HTML\'s own spelling and marks are kept');
});

test('a heading with no words is no heading: links to it go to the next block (2207.00729, refused index_heading)',()=>{
 const runIn='<section class="ltx_paragraph" id="S1.P1"><h4 class="ltx_title ltx_title_paragraph"></h4><div class="ltx_para"><p class="ltx_p">Run-in paragraph.</p></div></section>';
 const {checked,html}=buildWith(source.replace('<ol>',runIn+'<p>See <a href="#S1.P1">that paragraph</a>.</p><ol>'));
 assert.deepEqual(checked.index.headings.map(h=>h.title),['1 Introduction','References']);
 assert.doesNotMatch(html,/<h4[^>]*><\/h4>/);
 const target=checked.index.blocks.find(b=>b.text==='Run-in paragraph.')!;
 assert.match(html,new RegExp(`<a href="#${target.id}">that paragraph</a>`));
});

test('a mark set as a formula reads as its symbol in the title page\'s notes (PrismaCoder, 2610.20538)',()=>{
 const star='<math alttext="\\ast" display="inline"><semantics><mo>∗</mo><annotation encoding="application/x-tex">\\ast</annotation></semantics></math>';
 const page=source.replace('<div class="ltx_authors">A. Author</div>',`<div class="ltx_para"><p class="ltx_p">a@x.org, b@y.org <br class="ltx_break"><sup class="ltx_sup">${star}</sup> Equal contribution</p></div>`);
 const {html}=buildWith(page,{authors:['Ada Lovelace','Alan Turing']});
 assert.match(html,/<span class="reader-notes"><sup>∗<\/sup> Equal contribution<\/span>/);
 assert.doesNotMatch(html.replace(/<math[\s\S]*?<\/math>|<[^>]+>/g,' '),/\\ast|, ,/);
});

// Revision 22 (owner, build 69 "Broken sources list", 2610.22353v1): affiliations and the e-mail paragraph after the
// abstract read in the header, under the names; every institution and contact is kept.
const headerOf = (html: string) => /<p class="reader-authors"[^>]*>([\s\S]*?)<\/p>/.exec(html)![1];
test('affiliations and the e-mail paragraph after the abstract read in the header (2610.22353v1)', () => {
  const html = source.replace('<section id="S1">', '<p><sup>1</sup> ETH Zurich\t<sup>2</sup> The University of Hong Kong\t<sup>3</sup> Max Planck Institute\t<sup>4</sup> WU Vienna</p>'
    + '<p>{bingcong.li, niao.he}@inf.ethz.ch, {haoma, mayi}@hku.hk, <br class="ltx_break">michael@tuebingen.mpg.de</p><section id="S1">');
  const {html: rendered, checked} = buildWith(html);
  const header = headerOf(rendered);
  assert.match(header, /^A\. Author <span class="reader-affiliations"><sup>1<\/sup> ETH Zurich<br><sup>2<\/sup> The University of Hong Kong<br><sup>3<\/sup> Max Planck Institute<br><sup>4<\/sup> WU Vienna<br>\{bingcong\.li, niao\.he\}@inf\.ethz\.ch, \{haoma, mayi\}@hku\.hk,<br>michael@tuebingen\.mpg\.de<\/span>$/, header);
  assert.doesNotMatch(rendered, /reader-affiliation-lines/, 'nothing is left after the abstract');
  assert.ok(!checked.index.blocks.some(b => b.kind === 'paragraph' && !/^A\. Author/.test(b.text) && /ETH Zurich|tuebingen/.test(b.text)), 'no separate affiliation or contact block');
  assert.ok(checked.index.blocks.find(b => /^A\. Author/.test(b.text))!.text.includes('michael@tuebingen.mpg.de'), 'the header\'s index text has the contacts');
  assert.equal(checked.index.equations.length, 2);
  // The same paragraphs before the abstract also join the header; a contact paragraph not beside them stays where it is.
  const apart = buildWith(source.replace('<section id="S1">', '<p><sup>1</sup> ETH Zurich <sup>2</sup> Example Institute</p><p>A short remark.</p><p>contact@example.org</p><section id="S1">')).html;
  assert.match(headerOf(apart), /<sup>2<\/sup> Example Institute<\/span>$/);
  assert.match(apart, /<p [^>]*>contact@example\.org<\/p>/);
});

test('affiliation lines keep indexed math marks and contacts; the equation entry follows its line into the header', () => {
 const dagger='<math alttext="\\dagger" display="inline"><mo>†</mo></math>';
 const paragraph=`<p><sup>${dagger}</sup> ETH Zurich contact@example.org <sup>2</sup> Example Institute</p>`;
 const {html,checked}=buildWith(source.replace('<section id="S1">',paragraph+'<section id="S1">'));
 const header=headerOf(html);
 assert.match(header,/class="reader-affiliations"><sup><span [^>]*data-reader-equation=/); assert.match(header,/contact@example.org/);
 const mark=checked.index.equations.find(e=>e.latex==='\\dagger')!;
 assert.ok(mark,'the mark is still an indexed equation');
 assert.equal(mark.block_id,checked.index.blocks.find(b=>/^A\. Author/.test(b.text))!.id,'in the header block');
 // Without an author block the lines stay where the paper put them, one per institution (revisions 19–21).
 const anonymous=buildWith(source.replace('<div class="ltx_authors">A. Author</div>','').replace('<section id="S1">',paragraph+'<section id="S1">')).html;
 assert.doesNotMatch(anonymous,/reader-authors/);
 assert.match(anonymous,/<span class="reader-affiliation-lines"><sup>[\s\S]*ETH Zurich contact@example\.org<br><sup>2<\/sup> Example Institute<\/span>/);
});

// Revision 24 (fresh-paper sweep before TestFlight 90, VLA-Δ 2610.21306v1): a formula in a heading that Unicode spells
// reads as its characters, so the title (index, Contents, <title>) never shows a macro; the author block keeps the web
// address an affiliation put in brackets and leaves no empty brackets behind.
const formula = (latex: string, mathml: string) => `<math alttext="${latex}" display="inline"><semantics>${mathml}<annotation encoding="application/x-tex">${latex}</annotation></semantics></math>`;
test('a formula in a title or heading that Unicode spells is text, never its macro; others stay equations (2610.21306v1)', () => {
  const delta = formula('\\Delta', '<mi mathvariant="normal">Δ</mi>');
  const html = source.replace('<h1>Authored HTML fixture</h1>', `<h1 class="ltx_title ltx_title_document">VLA-${delta}: Learning Physical State Transition</h1>`)
    .replace('<h2>1 Introduction</h2>', `<h2>1 Scaling ${formula('\\tau^{2}', '<msup><mi>τ</mi><mn>2</mn></msup>')} with ${formula('\\lambda&lt;1', '<mrow><mi>λ</mi><mo>&lt;</mo><mn>1</mn></mrow>')}, ${formula('\\mathcal{S}_{0}', '<msub><mi>𝒮</mi><mn>0</mn></msub>')} and ${formula('\\big(1-\\frac{1}{e}\\big)', '<mrow><mo>(</mo><mn>1</mn><mo>−</mo><mfrac><mn>1</mn><mi>e</mi></mfrac><mo>)</mo></mrow>')}</h2>`)
    .replace('<h2>References</h2>', `<h2>${formula('p_{T}', '<msub><mi>p</mi><mi>T</mi></msub>')} References, ${formula('a\\times b', '<mrow><mi>a</mi><mo>×</mo><mi>b</mi></mrow>')} (${formula('-1', '<mrow><mo>−</mo><mn>1</mn></mrow>')})</h2>`);
  const {checked, html: rendered} = buildWith(html);
  assert.equal(checked.index.title, 'VLA-Δ: Learning Physical State Transition');
  assert.match(rendered, /<h1 [^>]*>VLA-Δ: Learning Physical State Transition<\/h1>/);
  assert.match(rendered, /<title>VLA-Δ: Learning Physical State Transition<\/title>/);
  assert.equal(checked.index.blocks[0].text, 'VLA-Δ: Learning Physical State Transition');
  // Variables in italics, as the formula sets them; a relation spaced; a fraction (no Unicode form) stays math.
  assert.match(rendered, /<h2 [^>]*>1 Scaling <em>τ<\/em>² with <em>λ<\/em> &lt; 1, 𝒮₀ and <span class="reader-equation reader-inline"[^>]*data-latex="\\big\(1-\\frac\{1\}\{e\}\\big\)"/);
  assert.equal(checked.index.headings[0].title, '1 Scaling τ² with λ < 1, 𝒮₀ and \\big(1-\\frac{1}{e}\\big)');
  // A script Unicode has no letter for ("T" below the line) keeps the formula.
  assert.match(rendered, /<h2 [^>]*><span class="reader-equation reader-inline"[^>]*data-latex="p_\{T\}"/);
  // A binary operator between operands is spaced; a sign is not.
  assert.equal(checked.index.headings[1].title, 'p_{T} References, a × b (−1)');
  assert.deepEqual(checked.index.equations.map(e => e.latex).sort(), ['\\big(1-\\frac{1}{e}\\big)', 'p_{T}', 'x^2', 'x^2'].sort(), 'the text formulas are no equations');
  // What the reader shows as words has no macro (the sweep's macro_leak check).
  assert.doesNotMatch(rendered.replace(/<math[\s\S]*?<\/math>|<[^>]+>/g, ' '), /\\[A-Za-z]{3,}/);
  // In running text the same formula is still an equation.
  const body = buildWith(source.replace('An equation ', `An equation ${delta} `)).checked;
  assert.ok(body.index.equations.some(e => e.latex === '\\Delta'));
});

test('an affiliation keeps its bracketed web address, and brackets emptied by a dropped e-mail go; real brackets stay (2610.21306v1)', () => {
  const creator = (name: string, affiliation: string) => `<span class="ltx_creator ltx_role_author"><span class="ltx_personname">${name}\n</span><span class="ltx_author_notes"><span class="ltx_author_notes_content"><span class="ltx_contact ltx_role_affiliation"><span class="ltx_contact_name">Affiliation: </span>${affiliation}\n</span></span></span></span>`;
  const zju = 'Zhejiang University (<a href="https://zju.edu.cn" title="" class="ltx_ref ltx_href">zju.edu.cn</a>)';
  const authors = `<div class="ltx_authors">${creator('Qi Lu', zju)}<span class="ltx_author_before">  </span>${creator('Jiarun Li', zju)}`
    + `<span class="ltx_author_before">  </span>${creator('Ce Zhang', 'Central South University (<a href="https://csu.edu.cn" title="" class="ltx_ref ltx_href">csu.edu.cn</a>)')}</div>`;
  const header = headerOf(buildWith(source.replace('<div class="ltx_authors">A. Author</div>', authors)).html);
  assert.equal(header, 'Qi Lu<sup>1</sup>, Jiarun Li<sup>1</sup>, Ce Zhang<sup>2</sup> <span class="reader-affiliations"><sup>1</sup>Zhejiang University (<a href="https://zju.edu.cn/" rel="noopener noreferrer">zju.edu.cn</a>)<br><sup>2</sup>Central South University (<a href="https://csu.edu.cn/" rel="noopener noreferrer">csu.edu.cn</a>)</span>');
  // An e-mail in brackets (as text or a mailto link) is left out with its brackets; brackets with words in them stay; a
  // project page given by several authors is listed once.
  const page = '<a href="https://example.org/project" class="ltx_ref ltx_href">https://example.org/project</a>';
  // An address whose words were an icon (an ORCID badge) leaves no empty line.
  const orcid = '<a href="https://orcid.org/0000-0000-0000-0000" class="ltx_ref ltx_href"><img src="2601.01234v2/orcid.png" class="ltx_graphics" alt=""></a>';
  const mixed = `<div class="ltx_authors">${creator('Ada Lovelace', 'MIT (CSAIL) (ada@mit.edu)' + page + orcid)}<span class="ltx_author_before">  </span>`
    + `${creator('Alan Turing', 'Bletchley Park [Hut 8] [<a href="mailto:alan@example.org">alan@example.org</a>]' + page)}</div>`;
  assert.equal(headerOf(buildWith(source.replace('<div class="ltx_authors">A. Author</div>', mixed)).html),
    'Ada Lovelace<sup>1</sup>, Alan Turing<sup>2</sup> <span class="reader-affiliations"><sup>1</sup>MIT (CSAIL)<br><sup>2</sup>Bletchley Park [Hut 8]<br><a href="https://example.org/project" rel="noopener noreferrer">https://example.org/project</a></span>');
});
