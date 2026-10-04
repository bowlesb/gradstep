import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { renderMMD } from '../renderer.mjs';
import { buildBundle, validateBundle, rendererIdentity } from '../bundle.mjs';
import { parseHTML, elements, serialize, namespaceIDs, sanitizeAndValidate } from '../dom.mjs';
import { sha256, jsonBytes, idIsSafe, pathIsSafe } from '../common.mjs';
import { encodePNG } from '../png.mjs';

const png = encodePNG(2, 2, Buffer.alloc(16, 255));
const image = new Map([['assets/test.png', { width: 2, height: 2 }]]);
const fixtureRoot = new URL('../../../tests/fixtures/reader/', import.meta.url);
const minimal = '# Test\n\nA short paragraph.';
function bundle(source = minimal, assets = new Map()) { return buildBundle({ sourceBytes: Buffer.from(source), assets, provenance: { authors: ['Authored regression fixture'], is_provider_output: false } }); }

test('exact math sources belong to the emitted nodes, including repeated inline math, matrix and numbered alignment', () => {
  const source = String.raw`# Math

Before $x_1+\alpha$ and $x_1+\alpha$ after.

\begin{align}\label{a}a&=b+c\\d&=e+f\end{align}

$$\begin{bmatrix}1&2\\3&4\end{bmatrix}$$

See \eqref{a}.
`;
  const result = renderMMD(source, new Map()), doc = parseHTML(result.html);
  assert.equal(result.index.equations.length, 4);
  assert.deepEqual(result.index.equations.slice(0, 2).map(e => e.latex), ['x_1+\\alpha', 'x_1+\\alpha']);
  assert.notEqual(result.index.equations[0].id, result.index.equations[1].id);
  assert.deepEqual(result.index.equations.map(e => e.source_form), ['body', 'body', 'environment', 'body']);
  for (const equation of result.index.equations) {
    const node = elements(doc, n => n.attribs['data-reader-equation'] === equation.id)[0];
    assert.equal(node.attribs.id, equation.id);
    assert.equal(elements(node, n => n.attribs.class === 'reader-latex')[0].children[0].data, equation.latex);
    assert.equal(elements(node, n => n.name === 'math').length, 1);
    assert.ok(elements(node, n => n.name === 'svg').length >= 1);
    const assistive = elements(node, n => n.attribs.class === 'reader-assistive-math')[0];
    assert.equal(node.attribs['aria-labelledby'], assistive.attribs.id);
    assert.equal(assistive.attribs.hidden, undefined);
    let parent = node.parent; while (!parent?.attribs?.['data-reader-block']) parent = parent.parent;
    assert.equal(parent.attribs.id, equation.block_id);
  }
  const link = elements(doc, n => n.name === 'a')[0]; assert.equal(link.attribs.href, `#${result.index.equations[2].id}`);
  const allIDs = elements(doc, n => 'id' in n.attribs).map(n => n.attribs.id); assert.equal(new Set(allIDs).size, allIDs.length);
  assert.ok(allIDs.every(idIsSafe));
});

test('currency, code and escaped raw HTML cannot become equations or executable markup', () => {
  const result = renderMMD('# Escapes\n\nCost \\$5. `$not_math$`.\n\n```tex\n$x+y$\n```\n\n<script src="https://invalid.test/code.js">oops</script>', new Map());
  assert.equal(result.index.equations.length, 0);
  assert.equal(elements(parseHTML(result.html), n => n.name === 'script').length, 0);
  assert.ok(result.html.includes('&lt;script'));
  assert.ok(result.index.blocks.some(b => b.kind === 'code' && b.text === '$x+y$'));
});

test('math parse failures and missing reference labels fail publication', () => {
  for (const source of [String.raw`# Error

$\frac{1}$`, String.raw`# Error

$\unknowncommand{1}$`, String.raw`# Error

See \eqref{missing}.`]) assert.throws(() => renderMMD(source, new Map()));
});

test('native title/heading byte limits and ambiguous equation labels fail before publication', () => {
  assert.doesNotThrow(() => renderMMD('# ' + 'x'.repeat(2000), new Map()));
  for (const source of ['# ' + 'x'.repeat(2001), '# ' + 'é'.repeat(1001), '# Title\n\n## ' + 'x'.repeat(2001), '# Title\n\n## ']) assert.throws(() => renderMMD(source, new Map()), /document_title/);
  assert.throws(() => renderMMD(String.raw`# Duplicate labels

\begin{equation}\label{same}x=1\end{equation}

\begin{equation}\label{same}y=2\end{equation}

See \ref{same}.`, new Map()), /ambiguous_source_label/);
});

test('remote Markdown images, LaTeX hyperlinks and hidden CSS resource references are rejected', () => {
  for (const source of ['# External\n\n![image](https://invalid.test/p.png)', '# External\n\n[link](https://invalid.test/)', String.raw`# External

$\href{https://invalid.test/}{x}$`, String.raw`# External

$\style{background-image:url(https://invalid.test/a)}{x}$`]) assert.throws(() => renderMMD(source, new Map()));
});

test('source and macro-expanded HTML-extension attributes cannot hide or restyle equations', () => {
  for (const expression of [String.raw`\style{display:none}{x}`, String.raw`\style{font-size:999999999px;position:absolute}{x}`, String.raw`\class{reader-latex}{x}`, String.raw`\cssId{other}{x}`, String.raw`\newcommand{\hide}[1]{\style{display:none}{#1}}\hide{x}`]) assert.throws(() => renderMMD(`# Styling\n\n$${expression}$`, new Map()), /author_math_attributes|equation_dimensions/);
  assert.throws(() => renderMMD(String.raw`# Oversize

$$\rule{1000000em}{10em}$$`, new Map()), /equation_dimensions/);
});

test('a document cannot inherit TeX macros from an earlier successful or failed document', () => {
  assert.doesNotThrow(() => renderMMD(String.raw`# First

$\newcommand{\reviewprobe}{x}\reviewprobe$`, new Map()));
  assert.throws(() => renderMMD(String.raw`# Second

$\reviewprobe$`, new Map()), /math_error/);
  assert.throws(() => renderMMD(String.raw`# Failed

$\newcommand{\failedprobe}{y}\style{display:none}{\failedprobe}$`, new Map()), /author_math_attributes/);
  assert.throws(() => renderMMD(String.raw`# After failure

$\failedprobe$`, new Map()), /math_error/);
});

test('sanitizer rejects active SVG/MathML, CSS imports/URLs, external resources and broken fragments', () => {
  const malicious = [
    '<svg><foreignObject><div>x</div></foreignObject></svg>', '<svg><script>x</script></svg>', '<svg><animate attributeName="href"></animate></svg>',
    '<svg><use href="https://invalid.test/a#b"></use></svg>', '<svg><use href="data:image/svg+xml,bad"></use></svg>', '<svg><use href="#missing"></use></svg>',
    '<math><merror>bad</merror></math>', '<math><annotation-xml encoding="text/html"><div>bad</div></annotation-xml></math>',
    '<p style="background:url(https://invalid.test/x)">x</p>', '<p style="@import url(x)">x</p>', '<p onclick="alert(1)">x</p>',
    '<img src="blob:a" alt="bad" width="1" height="1">', '<a href="javascript:alert(1)">x</a>', '<svg><image href="https://invalid.test/a"></image></svg>',
  ];
  for (const html of malicious) assert.throws(() => sanitizeAndValidate(html, new Set()), html);
});

test('SVG fragment renaming keeps exact references and viewBox case', () => {
  const doc = parseHTML('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><defs><path id="glyph-old" d="M0 0L1 1"></path></defs><use href="#glyph-old"></use></svg>');
  namespaceIDs(doc, 'equation-one');
  const safe = sanitizeAndValidate(serialize(doc), new Set());
  assert.equal(elements(safe, n => n.name === 'svg')[0].attribs.viewBox, '0 0 10 10');
  assert.equal(elements(safe, n => n.name === 'use')[0].attribs.href, '#equation-one-1');
  assert.throws(() => namespaceIDs(parseHTML('<span id="x"></span><span id="x"></span>'), 'dup'));
});

test('figure sidecar is derived from the surviving figure and validates its complete local asset set', () => {
  const result = renderMMD('# Figure\n\n![An authored diagram](assets/test.png "Figure 1. Caption")', image);
  assert.equal(result.index.figures.length, 1);
  const figure = result.index.figures[0]; assert.equal(figure.id, figure.block_id);
  const node = elements(parseHTML(result.html), n => n.name === 'figure')[0]; assert.equal(node.attribs['data-reader-figure'], figure.id);
  assert.equal(elements(node, n => n.name === 'img')[0].attribs.src, figure.asset_paths[0]);
  assert.equal(figure.caption, 'Figure 1. Caption'); assert.equal(figure.alt, 'An authored diagram');
  assert.throws(() => renderMMD('# Missing\n\n![no](assets/missing.png)', image), /asset_reference/);
  assert.throws(() => renderMMD('# Inline\n\nBefore ![no](assets/test.png) after', image), /figure_context/);
  assert.throws(() => bundle(minimal, new Map([['assets/test.png', png]])), /unused_asset/);
});

test('footnote forward and backward links remain unique and resolvable after deterministic renaming', () => {
  const result = renderMMD(String.raw`# Notes

A claim\footnote{First note.} and another\footnote{Second note.}`, new Map());
  const doc = parseHTML(result.html), ids = new Set(elements(doc, n => n.attribs.id).map(n => n.attribs.id));
  const links = elements(doc, n => n.name === 'a'); assert.equal(links.length, 4);
  assert.ok(links.every(n => ids.has(n.attribs.href.slice(1))));
  assert.ok(result.index.blocks.some(b => b.kind === 'list' && b.text.includes('First note.')));
});

test('same and fresh processes produce identical HTML, sidecar, build identity and manifest', () => {
  const source = String.raw`# Stable

$x$ then $x$.

\begin{equation}\label{eq}y=x^2\end{equation}

See \eqref{eq}. A note\footnote{Stable footnote.}`;
  const one = bundle(source), two = bundle(source); assert.deepEqual(two.manifestBytes, one.manifestBytes); assert.deepEqual(two.members, one.members);
  const script = `import {buildBundle} from './bundle.mjs';const r=buildBundle({sourceBytes:Buffer.from(${JSON.stringify(source)}),provenance:{authors:['Authored regression fixture'],is_provider_output:false}});console.log(r.manifestSHA);`;
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', script], { cwd: new URL('../', import.meta.url), encoding: 'utf8', timeout: 15000 });
  assert.equal(child.status, 0, child.stderr); assert.equal(child.stdout.trim(), one.manifestSHA);
  assert.match(rendererIdentity(), /^[a-f0-9]{64}$/);
});

test('manifest hash, member hash, actual byte counts and closure are independent rejection gates', () => {
  const result = bundle('# Image\n\n![An image](assets/test.png)', new Map([['assets/test.png', png]]));
  assert.doesNotThrow(() => validateBundle(result.manifestBytes, result.members, result.manifestSHA));
  assert.throws(() => validateBundle(result.manifestBytes, result.members, '0'.repeat(64)), /manifest_integrity/);
  const changed = new Map(result.members); changed.set('index.html', Buffer.from('corrupt')); assert.throws(() => validateBundle(result.manifestBytes, changed, result.manifestSHA), /member_integrity/);
  const missing = new Map(result.members); missing.delete('assets/test.png'); assert.throws(() => validateBundle(result.manifestBytes, missing, result.manifestSHA), /member_count/);
  const extra = new Map(result.members); extra.set('extra.js', Buffer.from('bad')); assert.throws(() => validateBundle(result.manifestBytes, extra, result.manifestSHA), /member_count/);
  const manifest = structuredClone(result.manifest); manifest.members.find(m => m.role === 'image').width = 100;
  const bytes = jsonBytes(manifest); assert.throws(() => validateBundle(bytes, result.members, sha256(bytes)), /member_image/);
});

test('rehashing cannot make an unsafe body, false equation parent or missing resource valid', () => {
  const original = bundle('# Math\n\n$x+1$\n\nSecond paragraph.');
  function revise(path, bytes) {
    const members = new Map(original.members); members.set(path, bytes); const manifest = structuredClone(original.manifest);
    Object.assign(manifest.members.find(m => m.path === path), { bytes: bytes.length, sha256: sha256(bytes) }); const manifestBytes = jsonBytes(manifest);
    return () => validateBundle(manifestBytes, members, sha256(manifestBytes));
  }
  const html = original.members.get('index.html').toString();
  assert.throws(revise('index.html', Buffer.from(html.replace('<body>', '<body><img src="https://invalid.test/p.png" alt="x" width="1" height="1">'))), /asset_reference/);
  assert.throws(revise('index.html', Buffer.from(html.replace('<body>', '<body><script>alert(1)</script>'))));
  assert.throws(revise('index.html', Buffer.from(html.replace('<body>', '<body style="display:none">'))), /html_structure/);
  assert.throws(revise('index.html', Buffer.from(html.replace('<html lang="en">', '<html lang="en"><p>outside body</p>'))), /html_structure/);
  const badIndex = structuredClone(original.index); badIndex.equations[0].block_id = badIndex.blocks.at(-1).id;
  assert.throws(revise('reader.json', jsonBytes(badIndex)), /equation_parent/);
  badIndex.equations[0].block_id = original.index.equations[0].block_id; badIndex.equations[0].latex = 'different';
  assert.throws(revise('reader.json', jsonBytes(badIndex)), /equation_representation/);
  assert.throws(revise('reader.css', Buffer.from('@import "https://invalid.test/style";')), /style_reference/);
});

test('path and member collisions never map to another bundle resource', () => {
  for (const path of ['../a.png', '/a.png', 'a//b.png', 'a/../b.png', 'a/%2e.png', 'a/é.png', 'a\\b.png', '.hidden/a.png']) assert.equal(pathIsSafe(path), false, path);
  assert.throws(() => bundle(minimal, new Map([['assets/A.png', png], ['assets/a.png', png]])), /asset_path/);
});

test('authored sample preserves the existing navigation titles and requires no executable resource', () => {
  const source = readFileSync(new URL('sample.mmd', fixtureRoot));
  const result = buildBundle({ sourceBytes: source, assets: new Map(['attention', 'evaluation'].map(name => [`assets/${name}.png`, readFileSync(new URL(`assets/${name}.png`, fixtureRoot))])), provenance: JSON.parse(readFileSync(new URL('provenance.json', fixtureRoot))) });
  assert.equal(result.index.title, 'Reading machine learning papers');
  assert.deepEqual(result.index.headings.map(h => h.title), ['1. Start with the question', '2. Read the equations in context', '3. Check the evaluation', '4. Follow the references', 'References']);
  assert.equal(result.index.equations.length, 7); assert.equal(result.index.figures.length, 2);
  assert.notEqual(result.index.figures[0].id, result.index.figures[1].id); assert.notDeepEqual(result.index.figures[0].asset_paths, result.index.figures[1].asset_paths);
  assert.ok(result.index.blocks.some(b => b.kind === 'table'));
  assert.ok([...result.members.keys()].every(path => !/\.(js|woff2?)$/.test(path)));
});
