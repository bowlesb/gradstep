// The device compiler admits a PNG it keeps as it came with the reader's own PNG admission (images.ts), which
// inflates the stream with Node's zlib. This build-local adapter gives it the same answer in the browser with
// fflate: the inflated bytes, bounded by the expected length, and whether the whole stream was consumed (a stream
// with bytes after its trailer, or one that ends early, is refused as `png_compression`, as on the server).
import { unzlibSync } from 'fflate';
export function inflateSync(compressed: Uint8Array, options: { info?: boolean; maxOutputLength?: number }) {
  const limit = options.maxOutputLength ?? 0;
  // fflate fills the given buffer and stops without a word, so one spare byte tells a longer stream from an exact one.
  const buffer = unzlibSync(compressed, { out: new Uint8Array(limit + 1) });
  if (buffer.length !== limit) throw new Error('png_compression');
  // Consumed to its end: without its last byte the trailer is incomplete and inflation fails.
  let consumed = compressed.length;
  try { unzlibSync(compressed.subarray(0, compressed.length - 1), { out: new Uint8Array(limit) }); consumed = compressed.length - 1; } catch { /* the whole stream was needed */ }
  return { buffer, engine: { bytesWritten: consumed } };
}
