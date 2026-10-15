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
