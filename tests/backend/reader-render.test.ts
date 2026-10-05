import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { MATHPIX_OPTIONS_SHA256, openMathpixResult } from '../../supabase/functions/_shared/mathpix-result.ts';
import {
  admitReaderImage, readMathpixArchive, ReaderRenderError, renderMathpixReader, renderRetainedMathpixResult,
  RENDERER_ID, validateReaderBundle,
} from '../../supabase/functions/_shared/reader/index.ts';
import type { MathpixReaderBundle, MathpixReaderInput } from '../../supabase/functions/_shared/reader/index.ts';
import { canonicalBytes, sha256Hex } from '../../supabase/functions/_shared/reader/util.ts';

const fixtures = new URL('../fixtures/reader-mathpix/', import.meta.url);
const read = (name: string) => new Uint8Array(readFileSync(new URL(name, fixtures)));
const encode = (text: string) => new TextEncoder().encode(text);
const decode = (bytes: Uint8Array) => new TextDecoder().decode(bytes);
const provenance = { ocr: { api: 'v3/pdf', profile: 'science-reader-mmd-v1', options_sha256: MATHPIX_OPTIONS_SHA256 },
  provider_job_id: 'synthetic-job', document: { sha256: 'a'.repeat(64), page_count: 1 } };
const rejects = (code: string | RegExp) => (error: unknown) => error instanceof ReaderRenderError &&
  (typeof code === 'string' ? error.code === code : code.test(error.code));

function input(mmd: string | Uint8Array, images: Record<string, Uint8Array> = {}, extra: Partial<MathpixReaderInput> = {}): MathpixReaderInput {
  return { archive: new Map([['paper.mmd', typeof mmd === 'string' ? encode(mmd) : mmd], ...Object.entries(images)]), provenance, ...extra };
}
function html(bundle: MathpixReaderBundle): string { return decode(bundle.members.get('index.html')!); }
function png(width: number, height: number, { colorType = 2, extra = [] as Uint8Array[] } = {}): Uint8Array {
  const chunk = (name: string, body: Uint8Array) => {
    const out = new Uint8Array(body.length + 12), view = new DataView(out.buffer);
    view.setUint32(0, body.length); out.set(encode(name), 4); out.set(body, 8);
    let crc = 0xffffffff;
    for (const byte of out.subarray(4, 8 + body.length)) { crc ^= byte; for (let n = 0; n < 8; n++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
    view.setUint32(8 + body.length, (crc ^ 0xffffffff) >>> 0);
    return out;
  };
  const header = new Uint8Array(13), view = new DataView(header.buffer);
  view.setUint32(0, width); view.setUint32(4, height); header[8] = 8; header[9] = colorType;
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : 1;
  const rows = new Uint8Array((width * channels + 1) * height).fill(90);
  for (let row = 0; row < height; row++) rows[row * (width * channels + 1)] = 0;
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), ...extra.map(body => chunk('tEXt', body)),
    chunk('IDAT', new Uint8Array(deflateSync(rows))), chunk('IEND', new Uint8Array())];
  return Uint8Array.from(parts.flatMap(part => [...part]));
}

// Rebuilds a consistent manifest around changed members, so tests exercise
// content validation rather than only hash mismatches.
function repack(bundle: MathpixReaderBundle, change: (members: Map<string, Uint8Array>) => void) {
  const members = new Map(bundle.members); change(members);
  const manifest = JSON.parse(decode(bundle.manifestBytes));
  manifest.members = manifest.members.filter((member: { path: string }) => members.has(member.path)).map((member: { path: string }) => ({
    ...member, bytes: members.get(member.path)!.length, sha256: sha256Hex(members.get(member.path)!) }));
  const manifestBytes = canonicalBytes(manifest);
  return () => validateReaderBundle(manifestBytes, members, sha256Hex(manifestBytes));
}
const replaceHTML = (from: string | RegExp, to: string) => (members: Map<string, Uint8Array>) => {
  const before = decode(members.get('index.html')!), after = before.replace(from, to);
  assert.notEqual(after, before);
  members.set('index.html', encode(after));
};

let hostile: Promise<MathpixReaderBundle> | null = null;
const hostileBundle = () => hostile ??= renderMathpixReader(input(read('hostile.mmd'), { 'images/figure.jpg': read('figure-exif.jpg') },
  { attribution: 'Synthetic fixture authored for Science Reader tests.' }));

test('hostile provider text stays inert and only safe HTTPS links survive', async () => {
  const bundle = await hostileBundle(), page = html(bundle);
  validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
  assert.equal(bundle.index.title, 'Hostile x^2 Fixture <script>alert("title")</script>');
  for (const forbidden of ['<script', '<iframe', '<svg', '<img src=x', '<a href="javascript', '<a href="data', '<a href="http:', '<a href="file', '<a href="paper.pdf']) {
    assert.ok(!page.includes(forbidden), forbidden);
  }
  assert.ok(!/<[^>]+\son[a-z]+=/i.test(page), 'no event-handler attributes');
  assert.match(page, /&lt;img src=x onerror=alert\(1\)&gt;/, 'provider markup is shown as text');
  assert.match(page, /&lt;script&gt;alert\("title"\)&lt;\/script&gt;/);
  const anchors = [...page.matchAll(/<a ([^>]*)>/g)].map(match => match[1]);
  assert.deepEqual(anchors.filter(attrs => !attrs.startsWith('href="#')), [
    'href="https://example.com/a?b=1&amp;c=2" rel="noopener noreferrer"', 'href="https://example.org/path" rel="noopener noreferrer"']);
  assert.ok(anchors.some(attrs => /^href="#e-[a-f0-9]{12}-\d+"$/.test(attrs)), 'equation references resolve to generated IDs');
  assert.ok(page.includes('plain insecure,'), 'non-HTTPS links keep only their text');
  assert.match(decode(bundle.members.get('NOTICE.txt')!), /Document attribution\n=+\nSynthetic fixture authored/);
  assert.equal(bundle.stats.links, 2);
});

test('equations keep exact LaTeX, source form, MathML and copyable fallbacks', async () => {
  const bundle = await hostileBundle(), page = html(bundle), equations = bundle.index.equations;
  assert.deepEqual(equations.map(e => [e.latex, e.display, e.source_form]), [
    ['x^2', false, 'body'], ['\\alpha_i = \\frac{1}{2}', false, 'body'], ['\\frac{a', false, 'body'],
    ['\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n', true, 'body'],
    ['\\begin{equation}\nE = mc^2 \\label{eq:energy}\n\\end{equation}', true, 'environment'], ['y', false, 'body'], ['\\beta', false, 'body']]);
  assert.equal(bundle.stats.mathFallbacks, 1);
  assert.match(page, /reader-math-fallback" data-latex="\\frac\{a"[^>]*>\\\(\\frac\{a\\\)<\/span>/);
  assert.match(page, /<span class="reader-equation reader-display reader-tagged"[^>]*><math display="block">.*?<\/math><span class="reader-tag">\(1\)<\/span><\/span>/s);
  assert.ok(!/<mlabeledtr|data-mjx|mjx-eqn|<svg|\sstyle=|\sclass="math-/.test(page));
  for (const equation of equations) assert.ok(bundle.index.blocks.some(block => block.id === equation.block_id));
  assert.equal(bundle.index.blocks.find(block => block.text.startsWith('\\begin{equation}'))?.kind, 'equation');
});

test('figures, tables, lists and footnotes become stable reading blocks', async () => {
  const bundle = await hostileBundle(), page = html(bundle), index = bundle.index;
  const again = await renderMathpixReader(input(read('hostile.mmd'), { 'images/figure.jpg': read('figure-exif.jpg') },
    { attribution: 'Synthetic fixture authored for Science Reader tests.' }));
  assert.equal(again.manifestSHA256, bundle.manifestSHA256, 'rendering is deterministic');
  assert.deepEqual(index.blocks.map(block => block.kind), ['heading', 'heading', 'paragraph', 'heading', 'paragraph', 'paragraph',
    'equation', 'equation', 'paragraph', 'figure', 'list', 'list', 'table', 'paragraph', 'list']);
  assert.deepEqual(index.headings.map(heading => [heading.level, heading.title]), [[2, 'Abstract'], [2, '1 Links']]);
  assert.equal(index.figures.length, 1);
  const [figure] = index.figures;
  assert.equal(figure.alt, 'A red block');
  assert.equal(figure.caption, 'Figure 1: A small red block used as a hostile-input fixture.');
  const image = bundle.members.get(figure.asset_paths[0])!;
  assert.match(figure.asset_paths[0], /^assets\/[a-f0-9]{64}\.jpg$/);
  assert.ok(!decode(image).includes('Exif'), 'EXIF metadata is not republished');
  assert.ok(decode(read('figure-exif.jpg')).includes('Exif'));
  assert.match(page, /<div class="reader-table"[^>]*><table><tbody><tr><td>Name<\/td><td>Value<\/td><\/tr>/);
  assert.match(page, /<p class="reader-caption">Table 1: A tiny table\.<\/p><\/div>/);
  assert.match(page, /<sup><a href="#b-[a-f0-9]{12}-15">\[1\]<\/a><\/sup>/);
  assert.match(page, /<hr>\n<ol class="reader-footnotes"><li data-reader-block=/);
  const manifest = JSON.parse(decode(bundle.manifestBytes));
  assert.equal(manifest.renderer.id, RENDERER_ID);
  assert.equal(manifest.source.kind, 'mathpix-mmd');
  assert.deepEqual(manifest.members.map((member: { path: string; role: string }) => member.role).sort(),
    ['html', 'image', 'index', 'notice', 'provenance', 'style']);
  const record = JSON.parse(decode(bundle.members.get('provenance.json')!));
  assert.equal(record.format, 'mathpix-reader-provenance-v2');
  assert.equal(record.provider_job_id, 'synthetic-job');
  assert.deepEqual(record.image_inputs.map((row: { archive_path: string; media_type: string }) => [row.archive_path, row.media_type]), [['images/figure.jpg', 'image/jpeg']]);
});

test('image references cannot escape the archive, fetch or publish malformed rasters', async () => {
  const figure = (src: string) => `\\title{Images}\n\n![Alt text](${src})\n`;
  for (const src of ['https://cdn.example.com/x.jpg', '../outside.jpg', '/images/a.jpg', 'images/%2e%2e/a.jpg', 'images/missing.jpg', 'paper.mmd']) {
    await assert.rejects(renderMathpixReader(input(figure(src), { 'images/a.jpg': read('figure-exif.jpg') })), rejects('asset_reference'), src);
  }
  const jpeg = read('figure-exif.jpg');
  const cases: [Uint8Array, string][] = [
    [jpeg.subarray(0, jpeg.length - 40), 'jpeg_'], [jpeg.subarray(0, jpeg.length - 2), 'jpeg_'], [Uint8Array.from([...jpeg, 0]), 'jpeg_'],
    [encode('GIF89a not supported'), 'image_format'], [png(4, 4, { colorType: 3 }), 'png_profile'],
    [png(8193, 1), 'image_dimensions'],
  ];
  const corrupt = png(4, 4); corrupt[30] ^= 1;
  cases.push([corrupt, 'png_structure']);
  const shortStream = png(4, 4); const idat = decode(shortStream).indexOf('IDAT');
  cases.push([Uint8Array.from([...shortStream.subarray(0, idat - 4), 0, 0, 0, 1, ...encode('IDAT'), 0x78, 0x9c, 0, 0, 0, 0, ...encode('IEND')]), 'png_structure']);
  for (const [bytes, code] of cases) {
    await assert.rejects(renderMathpixReader(input(figure('images/a.img'), { 'images/a.img': bytes })), rejects(code.endsWith('_') ? new RegExp(`^${code}`) : code), code);
  }
  // A valid PNG is re-containerized: ancillary text is dropped, pixels kept.
  const tagged = png(6, 3, { extra: [encode('Comment\0private metadata')] });
  const admitted = admitReaderImage(tagged);
  assert.equal(admitted.mediaType, 'image/png');
  assert.ok(!decode(admitted.bytes).includes('private metadata'));
  assert.deepEqual(admitReaderImage(admitted.bytes).bytes, admitted.bytes, 'canonical images are a fixed point');
  const bundle = await renderMathpixReader(input(figure('images/a.png'), { 'images/a.png': tagged, 'images/unused.png': encode('never inspected') }));
  assert.equal(bundle.index.figures[0].alt, 'Alt text');
  assert.deepEqual([...bundle.members.keys()].filter(path => path.startsWith('assets/')), [`assets/${sha256Hex(admitted.bytes)}.png`]);
});

test('sources are bounded, macro definitions are refused and titles are required', async () => {
  await assert.rejects(renderMathpixReader(input(`\\title{Big}\n\n${'x'.repeat(2 * 1024 * 1024)}`)), rejects('source_limit'));
  for (const definition of ['\\newcommand{\\foo}{x}', '\\def\\foo{x}', '\\renewcommand{\\vec}{x}', '\\DeclareMathOperator{\\Tr}{Tr}', '\\let\\a\\b']) {
    await assert.rejects(renderMathpixReader(input(`\\title{Macro}\n\n\\(${definition}\\)\n`)), rejects('unsupported_macro_definition'), definition);
  }
  await assert.rejects(renderMathpixReader(input('Just a paragraph.\n')), rejects('document_title'));
  const fallback = await renderMathpixReader(input('Just a paragraph with \\(z\\).\n', {}, { titleFallback: 'Catalog title' }));
  assert.equal(fallback.index.title, 'Catalog title');
  assert.match(html(fallback), /<h1 data-reader-block="b-[a-f0-9]{12}-0" data-reader-kind="heading" id="b-[a-f0-9]{12}-0">Catalog title<\/h1>/);
  await assert.rejects(renderMathpixReader({ ...input('\\title{A}\n'), archive: new Map([['a.mmd', encode('\\title{A}')], ['b.mmd', encode('\\title{B}')]]) }), rejects('mmd_ambiguous'));
  await assert.rejects(renderMathpixReader(input('\\title{A}\n', {}, { provenance: { ...provenance, ocr: { ...provenance.ocr, options_sha256: 'b'.repeat(64) } } })), rejects('provenance_ocr'));
  await assert.rejects(renderMathpixReader(input(new Uint8Array([0xff, 0xfe]))), rejects('source_encoding'));
});

test('the validator independently refuses consistent-hash bundles with unsafe or contradictory content', async () => {
  const bundle = await hostileBundle();
  assert.throws(() => validateReaderBundle(bundle.manifestBytes, bundle.members, 'f'.repeat(64)), rejects('manifest_integrity'));
  const attacks: [(members: Map<string, Uint8Array>) => void, RegExp][] = [
    [replaceHTML('<hr>', '<script>alert(1)</script><hr>'), /^(html_node_type|top_level)$/],
    [replaceHTML('<hr>', '<hr onclick="alert(1)">'), /^html_attribute:hr$/],
    [replaceHTML('href="https://example.org/path"', 'href="javascript:alert(1)"'), /^link_reference$/],
    [replaceHTML(' rel="noopener noreferrer">https://example.org', '>https://example.org'), /^link_reference$/],
    [replaceHTML('<mi>y</mi>', '<mi href="https://example.com">y</mi>'), /^math_attribute$/],
    [replaceHTML('<mi>y</mi>', '<mglyph src="https://example.com/x.png"></mglyph>'), /^math_element$/],
    [replaceHTML('data-latex="y"', 'data-latex="z"'), /^(index_identity|equation_identity)$/],
    [replaceHTML('<p class="reader-caption">', '<p class="reader-caption"><img alt="x" height="1" src="x.png" width="1">'), /^html_content_model$/],
    [replaceHTML('<p class="reader-caption">', '<p class="reader-caption"><div>'), /^(html_canonical|html_content_model)$/],
    [replaceHTML('</ol>', '</ol>\n<p>stray text</p>'), /^top_level$/],
    [replaceHTML('<hr>', '<hr><style>body{}</style>'), /^(html_node_type|top_level)$/],
    [replaceHTML('<table>', '<table><caption>x</caption>'), /^(html_tag|table_structure)$/],
    [members => { members.set('reader.css', encode('body{background:url(https://example.com/x)}')); }, /^style_reference$/],
    [members => { const path = [...members.keys()].find(p => p.startsWith('assets/'))!; members.set(path, read('figure-exif.jpg')); }, /^member_path$/],
    [members => { const record = JSON.parse(decode(members.get('provenance.json')!)); record.extra = true; members.set('provenance.json', canonicalBytes(record)); }, /^provenance_format$/],
    [members => { const index = JSON.parse(decode(members.get('reader.json')!)); index.equations.pop(); members.set('reader.json', canonicalBytes(index)); }, /^index_identity$/],
    [members => { const index = JSON.parse(decode(members.get('reader.json')!)); index.blocks[2].text = 'changed'; members.set('reader.json', canonicalBytes(index)); }, /^index_identity$/],
    [members => { members.set('NOTICE.txt', encode('No notices')); }, /^notice_invalid$/],
  ];
  for (const [change, code] of attacks) {
    assert.throws(repack(bundle, change), rejects(code), String(code));
  }
  const extra = new Map(bundle.members); extra.set('extra.js', encode('alert(1)'));
  assert.throws(() => validateReaderBundle(bundle.manifestBytes, extra, bundle.manifestSHA256), rejects('member_count'));
});

const dpo = '/Users/benbowlwes/science-reader/.artifacts/spike-2305.18290/';
// CC BY 4.0 credit carried in the committed app fixture's NOTICE.txt.
const DPO_ATTRIBUTION = decode(read('dpo-attribution.txt'));
const dpoProvenance = { ocr: { api: 'v3/pdf', profile: 'science-reader-mmd-v1', options_sha256: MATHPIX_OPTIONS_SHA256 },
  provider_job_id: 'cc092181-9d12-4eb3-b5de-d2ca288fc556',
  document: { sha256: '92cb3a2b71362acda98a789b03d88688fd33cf5fcf13f81d2b1de30ee7d3b67a', page_count: 27 } };
test('real DPO Mathpix output renders a complete validated bundle', { skip: !existsSync(`${dpo}output.mmd.zip`) && 'DPO capture is not present locally' }, async () => {
  const archive = await readMathpixArchive(new Uint8Array(readFileSync(`${dpo}output.mmd.zip`)));
  const started = performance.now();
  const bundle = await renderMathpixReader({ archive, provenance: dpoProvenance });
  const elapsed = performance.now() - started;
  validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
  const index = bundle.index, page = html(bundle);
  assert.equal(index.title, 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.equal(index.equations.length, 270);
  assert.equal(index.figures.length, 4);
  assert.equal(bundle.stats.mathFallbacks, 0);
  assert.ok(index.headings.some(heading => heading.title === '3 Preliminaries' && heading.level === 2));
  assert.ok(index.headings.some(heading => heading.title === '5.1 Your Language Model Is Secretly a Reward Model' && heading.level === 3));
  assert.equal(index.equations.filter(equation => equation.display).length, 32);
  assert.ok(index.equations.some(equation => equation.latex.startsWith('\\begin{equation*}\np ^ { * } \\left( y _ { 1 } \\succ')));
  assert.equal((page.match(/class="reader-equation reader-display reader-tagged"/g) ?? []).length, 20);
  assert.ok(bundle.stats.links >= 30);
  assert.ok(!/<a href="(?!https:\/\/|#)/.test(page));
  const manifest = JSON.parse(decode(bundle.manifestBytes));
  assert.deepEqual(manifest.members.filter((member: { role: string }) => member.role === 'image').map((member: { media_type: string }) => member.media_type),
    ['image/jpeg', 'image/jpeg', 'image/jpeg', 'image/jpeg']);
  const total = [...bundle.members.values()].reduce((sum, bytes) => sum + bytes.length, 0);
  assert.ok(total < 1_000_000, `bundle bytes ${total}`);
  assert.ok(elapsed < 5000, `render took ${elapsed} ms`);

  // The retained-output entry derives identical provenance from the raw manifest.
  const rawDirectory = `${dpo}raw/6a0c96f70ba442bac1b520aeac9dd2d34b687fa18d1f66359de120e12ab8450e/`;
  if (existsSync(`${rawDirectory}manifest.json`)) {
    const manifestBytes = new Uint8Array(readFileSync(`${rawDirectory}manifest.json`));
    const rawMembers = new Map(['standalone.mmd', 'output.mmd.zip', 'lines.json'].map(name => [name, new Uint8Array(readFileSync(rawDirectory + name))]));
    const renderInput = await openMathpixResult({ manifestBytes, expectedSHA256: sha256Hex(manifestBytes), rawMembers });
    const retained = await renderRetainedMathpixResult(renderInput);
    assert.equal(retained.manifestSHA256, bundle.manifestSHA256);
  }
});

test('the committed DPO app fixture is exactly what this renderer produces', { skip: !existsSync(`${dpo}output.mmd.zip`) && 'DPO capture is not present locally' }, async () => {
  const fixture = new URL('../../apps/apple/ScienceReader/Resources/ReaderSamples/', import.meta.url);
  const archive = await readMathpixArchive(new Uint8Array(readFileSync(`${dpo}output.mmd.zip`)));
  const bundle = await renderMathpixReader({ archive, provenance: dpoProvenance, attribution: DPO_ATTRIBUTION });
  const directory = new URL(`${bundle.manifestSHA256}/`, fixture);
  assert.ok(existsSync(directory), `expected committed fixture ${bundle.manifestSHA256}`);
  assert.deepEqual(new Uint8Array(readFileSync(new URL('manifest.json', directory))), bundle.manifestBytes);
  for (const [path, bytes] of bundle.members) assert.deepEqual(new Uint8Array(readFileSync(new URL(path, directory))), bytes, path);
});

