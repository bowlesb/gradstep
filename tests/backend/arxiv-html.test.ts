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

test('missing images, duplicate IDs, missing TeX and unresolved references fail preparation',()=>{
 for(const text of [source.replace('id="p1"','id="S1"'),
  source.replace('href="#bib1"','href="#missing"'),source.replace(math,'<math><mi>x</mi></math>')])assert.throws(()=>build(text));
 assert.throws(()=>composeArxivReader({source:utf8(source),sourceID:'2601.01234',revision:2,images:new Map()}));
 assert.throws(()=>convertArxivHTML('<html>Challenge page</html>',url,()=>{throw Error('no image expected')}));
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
 assert.match(xml,/<g transform="matrix\(1 0 0 -1 0 30\)">/);
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

test('the authors block reads as names with single marks, affiliations and notes, without footnotemark labels or e-mail',()=>{
 const note=(id,mark,role='footnotemark',body='')=>`<span id="${id}" class="ltx_note ltx_role_${role}"><sup class="ltx_note_mark">${mark}</sup><span class="ltx_note_outer"><span class="ltx_note_content"><sup class="ltx_note_mark">${mark}</sup><span class="ltx_note_type">${role}: </span>${body||`<span class="ltx_tag ltx_tag_note">${mark}</span>`}</span></span></span>`;
 const authors=`<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Rafael Rafailov ${note('fx1','2')}</span>${note('id1','†','thanks','Equal contribution; more junior authors listed earlier.')}</span>`
  +`<span class="ltx_author_before">  </span><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Archit Sharma${note('fx2','1')}  ${note('fx3','2')}</span></span>`
  +`<span class="ltx_author_before">  </span><span class="ltx_creator ltx_role_author"><span class="ltx_personname">${note('fx10','2')}  Stanford University ${note('fx11','3')}  CZ Biohub</span>`
  +`<span class="ltx_author_notes"><span class="ltx_author_notes_content"><span class="ltx_contact ltx_role_email"><span class="ltx_contact_name">Email: </span><a href="mailto:"><span class="ltx_text">{rafailov}@cs.stanford.edu</span></a></span></span></span></span></div>`;
 const bundle=build(source.replace('<div class="ltx_authors">A. Author</div>',authors+'<p>See <a href="#id1">the note</a>.</p>'));
 const html=new TextDecoder().decode(bundle.members.get('index.html'));
 const block=/<p class="reader-authors"[^>]*>(.*?)<\/p>/s.exec(html)?.[1]??'';
 assert.equal(block,'Rafael Rafailov<sup>2,†</sup>, Archit Sharma<sup>1,2</sup><br><sup>2</sup>Stanford University · <sup>3</sup>CZ Biohub<br><sup>†</sup> Equal contribution; more junior authors listed earlier.');
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
 assert.equal(block,'Chenghao Yue<sup>1</sup>, Hao Wang<sup>2</sup>, Jiahao Chen<sup>3</sup>, Gayoung Kim<sup>4</sup><br><sup>1</sup>Tsinghua University · <sup>2</sup>Dalian University of Technology · <sup>3</sup>Peking University · <sup>4</sup>A+HRI Laboratory, Incheon National University.<br><a href="https://seen-e.github.io/PRISM/" rel="noopener noreferrer">https://seen-e.github.io/PRISM/</a>');
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
 assert.match(bare,/<p class="reader-authors"[^>]*><strong>Team<\/strong><\/p>/);
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
 assert.equal(block,'Yu Wang, Yansheng Li<br><sup>1</sup>Wuhan University · <sup>2</sup>DreamX Team, Alibaba Group<br><sup>†</sup> Project leader');
 assert.ok(!/dreamx_logo|October 13|\[ \[|<sup><\/sup>/.test(html),'plumbing, the date line and empty marks are gone');
 assert.match(html,/left out 6 unsupported commands/);
});
