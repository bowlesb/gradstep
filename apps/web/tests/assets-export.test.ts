// Download your assets (lib/assets-export.ts): the shared fixture (tests/fixtures/assets-export/assets-export-v1.json;
// Swift AssetsExportTests) gives the same files and the same zip bytes on both clients, and the zip opens as a zip.
// UPDATE_EXPORT_FIXTURE=1 rewrites `expected` from this implementation (review the files in the diff).
import { describe, expect, it } from 'vitest';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { buildExport, crc32, day, fileName, stamp, zip, type ExportInput } from '../src/lib/assets-export';
import { fromHex } from '../src/lib/bytes';

const FIXTURE = resolve(__dirname, '../../../tests/fixtures/assets-export/assets-export-v1.json');
const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8')) as { input: ExportInput; images: Record<string, string>; expected: unknown };
const sha = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
const isText = (path: string) => /\.(md|mmd|html)$/.test(path);

function render() {
  const images = new Map(Object.entries(fixture.images).map(([id, hex]) => [id, fromHex(hex)!]));
  const result = buildExport(fixture.input, images);
  const archive = zip(result.files, fixture.input.exportedAt);
  return {
    fileName: result.fileName,
    skipped: result.skipped,
    files: result.files.map(f => isText(f.path) ? { path: f.path, text: new TextDecoder().decode(f.data) } : { path: f.path, sha256: sha(f.data) }),
    zipBytes: archive.length,
    zipSHA256: sha(archive),
  };
}

/** The zip's entries as a reader finds them: through the central directory, each local header checked against it. */
function unzip(bytes: Uint8Array): { name: string; data: Uint8Array }[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const end = bytes.length - 22;
  expect(view.getUint32(end, true)).toBe(0x06054b50);
  const count = view.getUint16(end + 10, true);
  let at = view.getUint32(end + 16, true);
  const out: { name: string; data: Uint8Array }[] = [];
  for (let i = 0; i < count; i++) {
    expect(view.getUint32(at, true)).toBe(0x02014b50);
    const crc = view.getUint32(at + 16, true), size = view.getUint32(at + 20, true), nameLength = view.getUint16(at + 28, true);
    const offset = view.getUint32(at + 42, true), name = new TextDecoder().decode(bytes.subarray(at + 46, at + 46 + nameLength));
    expect(view.getUint32(offset, true)).toBe(0x04034b50);
    expect(view.getUint16(offset + 6, true)).toBe(0x0800);
    const local = offset + 30 + view.getUint16(offset + 26, true);
    const data = bytes.subarray(local, local + size);
    expect(crc32(data)).toBe(crc);
    out.push({ name, data });
    at += 46 + nameLength;
  }
  return out;
}

describe('Download your assets', () => {
  it('makes the shared fixture’s files and zip exactly (the apps make the same)', () => {
    const rendered = render();
    if (process.env.UPDATE_EXPORT_FIXTURE) writeFileSync(FIXTURE, JSON.stringify({ ...fixture, expected: rendered }, null, 1) + '\n');
    expect(rendered).toEqual(JSON.parse(readFileSync(FIXTURE, 'utf8')).expected);
  });

  it('is a zip every reader opens: README first, every entry under one folder, contents intact', () => {
    const images = new Map(Object.entries(fixture.images).map(([id, hex]) => [id, fromHex(hex)!]));
    const result = buildExport(fixture.input, images);
    const archive = zip(result.files, fixture.input.exportedAt);
    // EXPORT_ZIP_OUT=<path>: also write it, to open with the system's own tools (`unzip -t`, Archive Utility).
    if (process.env.EXPORT_ZIP_OUT) writeFileSync(process.env.EXPORT_ZIP_OUT, archive);
    const entries = unzip(archive);
    expect(entries.map(e => e.name)).toEqual(result.files.map(f => f.path));
    expect(entries[0]!.name).toBe(`${result.root}/README.md`);
    expect(entries.every(e => e.name.startsWith(`${result.root}/`))).toBe(true);
    expect(entries.find(e => e.name.endsWith('/snippets/images/e1.png'))!.data).toEqual(images.get('e1'));
    // The image a device couldn't read is said, not silently dropped.
    expect(result.skipped).toContain('An image in “Ideas” wasn’t available on this device.');
  });

  it('names files from titles safely and the same way the apps do', () => {
    expect(fileName('  .hidden: résumé\tnotes ')).toBe('hidden résumé notes');
    expect(fileName('a/b\\c*?"<>|d')).toBe('a b c d');
    expect(fileName('...')).toBe('Untitled');
    expect(fileName('x'.repeat(70) + ' tail', 60)).toBe('x'.repeat(60));
    expect(fileName('é', 10)).toBe('é');
    expect(day(0)).toBe('1970-01-01');
    expect(stamp(1792677600000)).toBe('2026-10-22 14:00 UTC');
  });

  it('is empty but still explains itself with nothing kept', () => {
    const result = buildExport({ exportedAt: 1792677600000, chats: [], diagrams: [], collections: [], explanations: [], skipped: [] }, new Map());
    expect(result.files.map(f => f.path)).toEqual(['Gradstep export 2026-10-22/README.md']);
    expect(new TextDecoder().decode(result.files[0]!.data)).toContain('Downloaded papers aren’t included');
  });
});
