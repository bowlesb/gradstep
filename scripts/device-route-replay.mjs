#!/usr/bin/env node
// The device route's converter again on recorded host answers (docs/reviews/DEVICE_PDF_ROUTE_20261021.md): the pages,
// layout detections, tagger logits and recognitions a Mac run wrote down (`DevicePDFRouteTool --record`) are replayed
// through this checkout's converter in Node, so a rule change is scored in seconds, without the models. Images are
// blank pixels of the asked size; a tagger line or crop the record lacks counts as a miss (printed).
//
//   node scripts/device-route-replay.mjs --from <variant with record.json> --to <new variant> [--only id,…]
//   then: node scripts/device-route-accuracy.mjs score --variant <new variant>
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const FROM = join(ROOT, '.artifacts/device-route/accuracy', arg('--from', ''));
const TO = join(ROOT, '.artifacts/device-route/accuracy', arg('--to', ''));
const only = (arg('--only', '') ?? '').split(',').filter(Boolean);
const { composeDevicePDFReader } = await import(`${ROOT}/supabase/functions/_shared/reader/device-pdf/bundle.ts`);
const { replayHost } = await import(`${ROOT}/supabase/functions/_shared/reader/device-pdf/record.ts`);

const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = bytes => { let c = 0xffffffff; for (const b of bytes) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => { const out = Buffer.alloc(12 + data.length); out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); data.copy(out, 8); out.writeUInt32BE(crc(out.subarray(4, 8 + data.length)), 8 + data.length); return out; };
/** A grey PNG of the size asked (the pixels do not matter to the scores; distinct sizes keep distinct paths). */
function png(width, height, shade) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 0;
  const row = Buffer.alloc(width + 1, shade); row[0] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.concat(Array(height).fill(row)))), chunk('IEND', Buffer.alloc(0))]);
}

let n = 0;
for (const key of readdirSync(FROM).filter(k => existsSync(join(FROM, k, 'record.json'))).sort()) {
  if (only.length && !only.includes(key)) continue;
  const record = JSON.parse(readFileSync(join(FROM, key, 'record.json'), 'utf8'));
  let distinct = 0;
  const host = replayHost(record, r => {
    const w = Math.max(1, r.rect[2] - r.rect[0]), h = Math.max(1, r.rect[3] - r.rect[1]);
    return { png: png(w, h, 200 + (distinct++ % 50)).toString('base64'), width: w, height: h, ...(r.clean ? { rect: r.rect } : {}) };
  });
  const started = Date.now();
  let bundle;
  try { bundle = composeDevicePDFReader({ ...record.input, trace: true }, host); }
  catch (e) { console.log(`${key}: ${e.code ?? e.message}`); continue; }
  const out = join(TO, key);
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, 'index.html'), bundle.members.get('index.html'));
  writeFileSync(join(out, 'reader.json'), bundle.members.get('reader.json'));
  writeFileSync(join(out, 'index.json'), JSON.stringify(bundle.trace));
  // The source run's timings stay (the replay has no models); the replay's own seconds are noted beside them.
  const source = JSON.parse(readFileSync(join(FROM, key, 'conversion.json'), 'utf8'));
  writeFileSync(join(out, 'conversion.json'), JSON.stringify({ ...bundle.summary, host_seconds: source.host_seconds, model_load_seconds: source.model_load_seconds,
    replay: { from: arg('--from'), seconds: (Date.now() - started) / 1000, misses: host.misses } }, null, 1));
  if (host.misses.tags || host.misses.crops) console.log(`${key}: replay misses ${JSON.stringify(host.misses)}`);
  n += 1;
}
console.log(`${n} papers replayed into ${TO}`);
