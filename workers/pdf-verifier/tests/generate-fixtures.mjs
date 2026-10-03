// Deterministic synthetic PDFs. Generated files stay in the ignored build tree.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { deflateSync } from 'node:zlib';

const root = new URL('../../../', import.meta.url);
const destination = new URL('.artifacts/pdf-verifier/fixtures/', root);
await mkdir(destination, { recursive: true });
const B = (text) => Buffer.from(text, 'latin1');

function classic(objects) {
  const chunks = [B('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')];
  const offsets = [0];
  let length = chunks[0].length;
  objects.forEach((object, i) => {
    offsets.push(length);
    const bytes = Buffer.concat([B(`${i + 1} 0 obj\n`), Buffer.isBuffer(object) ? object : B(object), B('\nendobj\n')]);
    chunks.push(bytes); length += bytes.length;
  });
  chunks.push(B(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n` +
    offsets.slice(1).map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('') +
    `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${length}\n%%EOF\n`));
  return Buffer.concat(chunks);
}

function stream(dictionary, bytes) {
  return Buffer.concat([B(`<< ${dictionary} /Length ${bytes.length} >>\nstream\n`), bytes, B('\nendstream')]);
}

function pages(count, extra = '', contentStream = undefined) {
  const content = B('BT /F1 12 Tf 40 100 Td (Synthetic verifier fixture) Tj ET\n');
  return classic([
    `<< /Type /Catalog /Pages 2 0 R ${extra} >>`,
    `<< /Type /Pages /Count ${count} /Kids [${Array.from({ length: count }, (_, i) => `${i + 5} 0 R`).join(' ')}] >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    contentStream ?? stream('', content),
    ...Array.from({ length: count }, () => '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 3 0 R >> >> /Contents 4 0 R >>'),
  ]);
}

// Root catalog inside an object stream forces the parser to materialize decoded
// object bytes. The expanded string is large but the original file is tiny.
function objectStream(expandedBytes) {
  const catalog = Buffer.concat([B('1 0 << /Type /Catalog /Pages 2 0 R /Padding ('), Buffer.alloc(expandedBytes, 65), B(') >>')]);
  const objects = new Map([
    [2, B('<< /Type /Pages /Count 1 /Kids [3 0 R] >>')],
    [3, B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> >>')],
    [4, stream('/Type /ObjStm /N 1 /First 4 /Filter /FlateDecode', deflateSync(catalog))],
  ]);
  const chunks = [B('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')];
  const offsets = {};
  let length = chunks[0].length;
  for (const [id, object] of objects) {
    offsets[id] = length;
    const bytes = Buffer.concat([B(`${id} 0 obj\n`), object, B('\nendobj\n')]);
    chunks.push(bytes); length += bytes.length;
  }
  offsets[5] = length;
  const xref = Buffer.alloc(6 * 7);
  const entry = (id, type, first, second) => {
    xref[id * 7] = type; xref.writeUInt32BE(first, id * 7 + 1); xref.writeUInt16BE(second, id * 7 + 5);
  };
  entry(0, 0, 0, 65535); entry(1, 2, 4, 0);
  for (let id = 2; id <= 5; id++) entry(id, 1, offsets[id], 0);
  chunks.push(B('5 0 obj\n'), stream('/Type /XRef /Size 6 /Root 1 0 R /W [1 4 2]', xref),
    B(`\nendobj\nstartxref\n${offsets[5]}\n%%EOF\n`));
  return Buffer.concat(chunks);
}

const fixtures = new Map();
for (const count of [0, 1, 25, 50, 51]) fixtures.set(`pages-${count}`, { bytes: pages(count), expected: count === 0 ? 'malformed' : count > 50 ? 'page_limit' : 'verified', pages: count });
const one = pages(1);
fixtures.set('not-pdf', { bytes: B('this is not a PDF'), expected: 'malformed' });
fixtures.set('missing-xref', { bytes: one.subarray(0, one.indexOf('xref\n')), expected: 'malformed' });
fixtures.set('missing-eof', { bytes: one.subarray(0, one.lastIndexOf('%%EOF')), expected: 'malformed' });
fixtures.set('bad-xref', { bytes: B(one.toString('latin1').replace(/startxref\n\d+/, 'startxref\n1')), expected: 'malformed' });
fixtures.set('missing-endobj', { bytes: B(one.toString('latin1').replace('endobj', '      ')), expected: 'malformed' });
fixtures.set('untrusted-page-count', { bytes: B(one.toString('latin1').replace('/Count 1', '/Count 9')), expected: 'verified', pages: 1 });
fixtures.set('parser-nesting', { bytes: pages(1, `/Extra ${'['.repeat(200)}0${']'.repeat(200)}`), expected: 'parser_resource_limit' });
fixtures.set('corrupt-flate', { bytes: pages(1, '', stream('/Filter /FlateDecode', B('corrupt'))), expected: 'malformed' });
fixtures.set('unsupported-filter', { bytes: pages(1, '', stream('/Filter /UnsupportedTest', B('opaque'))), expected: 'unsupported' });
fixtures.set('stream-budget', { bytes: pages(1, '', stream('/Filter /FlateDecode', deflateSync(Buffer.alloc(32 * 1024 * 1024 + 1, 32)))), expected: 'parser_resource_limit' });
fixtures.set('repeated-content-budget', { bytes: pages(2, '', stream('/Filter /FlateDecode', deflateSync(Buffer.alloc(16 * 1024 * 1024 + 1, 32)))), expected: 'parser_resource_limit' });
fixtures.set('content-token-budget', { bytes: pages(1, '', stream('/Filter /FlateDecode', deflateSync(B('q '.repeat(1000001))))), expected: 'parser_resource_limit' });
fixtures.set('object-stream-small', { bytes: objectStream(1024), expected: 'verified', pages: 1 });
fixtures.set('object-stream-oom', { bytes: objectStream(80 * 1024 * 1024), expected: 'resource_limit' });

// Apache-2.0 upstream qpdf regression files, retained only in ignored artifacts.
const upstream = new URL('.artifacts/pdf-verifier/sources/qpdf-12.4.2/qpdf/qtest/qpdf/', root);
for (const name of ['job-json-encrypt-40.pdf', 'encrypted-positive-P.pdf']) {
  fixtures.set(name.slice(0, -4), { bytes: await readFile(new URL(name, upstream)), expected: 'encrypted', source: `qpdf-12.4.2/qpdf/qtest/qpdf/${name}` });
}

const manifest = [];
for (const [name, fixture] of fixtures) {
  await writeFile(new URL(`${name}.pdf`, destination), fixture.bytes);
  manifest.push({ name, file: `${name}.pdf`, expected: fixture.expected, pages: fixture.pages,
    bytes: fixture.bytes.length, sha256: createHash('sha256').update(fixture.bytes).digest('hex'), source: fixture.source ?? 'local synthetic generator' });
}
await writeFile(new URL('manifest.json', destination), JSON.stringify(manifest, null, 2) + '\n');
console.log(JSON.stringify(manifest.map(({ name, bytes, expected }) => ({ name, bytes, expected }))));
