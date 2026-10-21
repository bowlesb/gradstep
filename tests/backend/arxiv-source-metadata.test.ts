import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { extractSourceMetadata, parseWatermark, sourceMetadataFromAtom, splitAuthorLine } from '../../supabase/functions/_shared/reader/arxiv/source-metadata.ts';

// A paper's metadata read on the device from the arXiv HTML it already downloaded (docs/architecture/
// ARXIV_DEVICE_ONLY.md §5.3): no extra request to arXiv. The DPO front matter is CC BY 4.0 (see the fixture's note).
const now = new Date('2026-10-15T12:00:00Z');
const dpo = readFileSync(new URL('./fixtures/arxiv-html/2305.18290v3-front.html', import.meta.url), 'utf8');

test('DPO: title, the six authors (not its affiliations), abstract, licence, primary category and version date', () => {
  const result = extractSourceMetadata(dpo, '2305.18290', 3, now)!;
  const m = result.metadata;
  assert.equal(m.origin, 'arxiv_html');
  assert.equal(m.title, 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.deepEqual(m.authors, ['Rafael Rafailov', 'Archit Sharma', 'Eric Mitchell', 'Stefano Ermon', 'Christopher D. Manning', 'Chelsea Finn']);
  assert.match(m.abstract!, /^While large-scale unsupervised language models \(LMs\) learn broad world knowledge/);
  assert.equal(m.license_uri, 'https://creativecommons.org/licenses/by/4.0/');
  assert.deepEqual(m.categories, ['cs.LG']);
  assert.equal(m.version_date, '2024-07-29');
  assert.equal(m.html_available, true);
  assert.deepEqual(result.flags, []);
  // The page is version 3: asked for another version (or another paper), it gives nothing.
  assert.equal(extractSourceMetadata(dpo, '2305.18290', 2, now), null);
  assert.equal(extractSourceMetadata(dpo, '2305.18291', 3, now), null);
});

const page = (body: string, infobox = true) => `<!DOCTYPE html><html><head><title>Fallback title</title></head><body>
${infobox ? '<div class="ltx_page_header"><a id="license-tr" href="#">License: arXiv.org perpetual non-exclusive license</a><div id="watermark-tr">arXiv:2610.20000v2 [cs.CV] 09 Oct 2026</div></div>' : ''}
<article class="ltx_document">${body}</article></body></html>`;

test('a page without arXiv\'s infobox still gives a record, with licence, date and category unknown', () => {
  const html = page('<h1 class="ltx_title ltx_title_document">On $x$ and <math alttext="\\alpha"><mi>α</mi></math> Things</h1>'
    + '<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Ada Lovelace</span></span></div>', false);
  const m = extractSourceMetadata(html, '2610.20000', 2, now)!.metadata;
  assert.equal(m.title, 'On $x$ and $\\alpha$ Things');
  assert.deepEqual(m.authors, ['Ada Lovelace']);
  assert.equal(m.license_uri, null); assert.equal(m.version_date, null); assert.deepEqual(m.categories, []); assert.equal(m.abstract, null);
});

test('author blocks: marks separate names, legends and affiliation lines are left out, a logo with "Team" is no one', () => {
  const marks = page('<h1 class="ltx_title ltx_title_document">T</h1><div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">'
    + 'Shun Zou<sup>1,2∗</sup> Ziyu Ma<sup>2∗</sup> Yi Zou<sup>1</sup>\n<sup>1</sup>University of Somewhere\n<sup>2</sup>AMAP, Alibaba Group\n Project Page\n Data &amp; Model'
    + '</span></span></div>');
  assert.deepEqual(extractSourceMetadata(marks, '2610.20000', 2, now)!.metadata.authors, ['Shun Zou', 'Ziyu Ma', 'Yi Zou']);
  const legend = page('<h1 class="ltx_title ltx_title_document">T</h1><div class="ltx_authors">'
    + '<span class="ltx_creator ltx_role_author"><span class="ltx_personname">Yiwu Zhong<sup>⋆</sup> Equal contribution<sup>†</sup> Corresponding author</span></span>'
    + '<span class="ltx_creator ltx_role_author"><span class="ltx_personname">Jiantao Jiao\n\nNVIDIA University of Minnesota – Twin Cities University of California, Berkeley\n†Corresponding Author: j@x.com</span></span>'
    + '<span class="ltx_creator ltx_role_author"><span class="ltx_personname"><sup>2</sup>Stanford University <sup>3</sup>CZ Biohub</span></span>'
    + '<span class="ltx_creator ltx_role_author"><span class="ltx_personname">Grace Hopper<br>Navy Lab<br>grace@navy.example</span></span></div>');
  assert.deepEqual(extractSourceMetadata(legend, '2610.20000', 2, now)!.metadata.authors, ['Yiwu Zhong', 'Jiantao Jiao', 'Grace Hopper']);
  const logo = page('<h1 class="ltx_title ltx_title_document">T</h1><div class="ltx_authors"><span class="ltx_creator ltx_role_author">'
    + '<span class="ltx_personname"><img alt="logo" src="x.png"> Team</span></span></div>');
  assert.equal(extractSourceMetadata(logo, '2610.20000', 2, now), null, 'no author, no record: the device sends nothing');
  assert.deepEqual(splitAuthorLine('A. Author, B. Author and C. Author'), ['A. Author', 'B. Author', 'C. Author']);
  assert.deepEqual(splitAuthorLine('Ruchang Yao   Shi Guo   Junhao Zhuang'), ['Ruchang Yao', 'Shi Guo', 'Junhao Zhuang']);
});

test('watermarks: modern and old identifiers, a primary category only when it is one', () => {
  assert.deepEqual(parseWatermark('arXiv:2305.18290v3 [cs.LG] 29 Jul 2024'), { sourceID: '2305.18290', revision: 3, category: 'cs.LG', date: '2024-07-29' });
  assert.deepEqual(parseWatermark('arXiv:hep-th/9711200v3  [hep-th]  22 Jan 1998'), { sourceID: 'hep-th/9711200', revision: 3, category: 'hep-th', date: '1998-01-22' });
  assert.deepEqual(parseWatermark('arXiv:2610.20000v1 [xx.YY] 9 Oct 2026'), { sourceID: '2610.20000', revision: 1, category: null, date: '2026-10-09' });
  assert.equal(parseWatermark('no watermark here'), null);
});

test('the export API\'s Atom answer (the native fallback without HTML): arXiv categories only, primary first, no licence', () => {
  const atom = readFileSync(new URL('./fixtures/arxiv-api/2305.18290v3.xml', import.meta.url), 'utf8');
  const m = sourceMetadataFromAtom(atom, '2305.18290', 3, now)!.metadata;
  assert.equal(m.origin, 'arxiv_api');
  assert.equal(m.title, 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.deepEqual(m.authors, ['Rafael Rafailov', 'Archit Sharma', 'Eric Mitchell', 'Stefano Ermon', 'Christopher D. Manning', 'Chelsea Finn']);
  assert.deepEqual(m.categories, ['cs.LG', 'cs.AI', 'cs.CL']);
  assert.equal(m.version_date, '2024-07-29'); assert.equal(m.license_uri, null); assert.equal(m.html_available, false);
  assert.match(m.abstract!, /^While large-scale unsupervised language models/);
  assert.equal(sourceMetadataFromAtom(atom, '2305.18290', 2, now), null, 'another version');
  assert.equal(sourceMetadataFromAtom(atom.replace(/<entry>[\s\S]*<\/entry>/, ''), '2305.18290', 3, now), null, 'no entry');
  const acm = atom.replace('<category term="cs.CL"', '<category term="I.2.7" scheme="x"/><category term="cs.CL"');
  assert.deepEqual(sourceMetadataFromAtom(acm, '2305.18290', 3, now)!.metadata.categories, ['cs.LG', 'cs.AI', 'cs.CL'], 'ACM classes are left out');
});
