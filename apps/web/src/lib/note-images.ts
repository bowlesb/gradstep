// Snippet images made on this device (NOTES_AND_SNIPPETS.md "Media cryptography and local durability"): the full image
// as PNG (JPEG only when a PNG would exceed 2 MiB, for photographic crops), longest edge ≤ 4,096 px and ≤ 6 MP; the
// thumbnail as JPEG, longest edge 480 px, ≤ 64 KiB. Re-encoding through a canvas strips any metadata. The composer
// previews these exact bytes, so nothing is changed after the reader has seen it.
import type { Bytes } from './bytes';
import { MAX_FULL_PLAINTEXT, MAX_THUMB_PLAINTEXT, headerSize } from './note-blob';
import { NOTES_LIMITS, type MediaType } from './notes';

export interface PreparedImage { bytes: Bytes; type: MediaType; width: number; height: number }
export interface PreparedSnippetImage { full: PreparedImage; thumb: PreparedImage }
export class SnippetImageError extends Error { constructor(readonly code: 'image_too_large' | 'image_unreadable' | 'image_unsupported') { super(code); } }

type Surface = OffscreenCanvas | HTMLCanvasElement;
function surface(width: number, height: number): Surface {
  if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(width, height);
  const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height; return canvas;
}
async function encode(canvas: Surface, type: MediaType, quality?: number): Promise<Bytes> {
  const blob = 'convertToBlob' in canvas ? await canvas.convertToBlob({ type, quality })
    : await new Promise<Blob | null>(resolve => (canvas as HTMLCanvasElement).toBlob(resolve, type, quality));
  if (!blob || blob.type !== type) throw new SnippetImageError('image_unsupported');
  return new Uint8Array(await blob.arrayBuffer());
}
function draw(source: CanvasImageSource, width: number, height: number, opaque: boolean): Surface {
  const canvas = surface(width, height), context = canvas.getContext('2d') as CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D | null;
  if (!context) throw new SnippetImageError('image_unsupported');
  if (opaque) { context.fillStyle = '#fff'; context.fillRect(0, 0, width, height); } // JPEG has no transparency
  context.imageSmoothingQuality = 'high';
  context.drawImage(source, 0, 0, width, height);
  return canvas;
}
function fit(width: number, height: number, edge: number, pixels = Infinity) {
  const scale = Math.min(1, edge / Math.max(width, height), Math.sqrt(pixels / (width * height)));
  return { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) };
}
function checked(bytes: Bytes, type: MediaType, width: number, height: number): PreparedImage {
  const size = headerSize(bytes);
  if (!size || size.width !== width || size.height !== height) throw new SnippetImageError('image_unsupported');
  return { bytes, type, width, height };
}

/** The full image and thumbnail for a snippet, from any decodable image (a crop's PNG, a figure's verified asset). */
export async function prepareSnippetImage(input: Blob): Promise<PreparedSnippetImage> {
  let bitmap: ImageBitmap;
  try { bitmap = await createImageBitmap(input); } catch { throw new SnippetImageError('image_unreadable'); }
  try {
    if (!bitmap.width || !bitmap.height) throw new SnippetImageError('image_unreadable');
    const { width, height } = fit(bitmap.width, bitmap.height, NOTES_LIMITS.fullEdge, NOTES_LIMITS.fullPixels);
    let full: PreparedImage = checked(await encode(draw(bitmap, width, height, false), 'image/png'), 'image/png', width, height);
    if (full.bytes.length > MAX_FULL_PLAINTEXT) full = checked(await encode(draw(bitmap, width, height, true), 'image/jpeg', 0.92), 'image/jpeg', width, height);
    if (full.bytes.length > MAX_FULL_PLAINTEXT) throw new SnippetImageError('image_too_large');
    let thumb: PreparedImage | null = null;
    for (const edge of [NOTES_LIMITS.thumbEdge, 360, 240]) {
      const t = fit(width, height, edge), canvas = draw(bitmap, t.width, t.height, true);
      for (const quality of [0.82, 0.7, 0.58, 0.46]) {
        const bytes = await encode(canvas, 'image/jpeg', quality);
        if (bytes.length <= MAX_THUMB_PLAINTEXT) { thumb = checked(bytes, 'image/jpeg', t.width, t.height); break; }
      }
      if (thumb) break;
    }
    if (!thumb) throw new SnippetImageError('image_too_large');
    return { full, thumb };
  } finally { bitmap.close(); }
}

/** The decoded size must match the record before an image is shown (the header was checked when it was opened). */
export async function decodedSize(bytes: Bytes, type: MediaType): Promise<{ width: number; height: number }> {
  const bitmap = await createImageBitmap(new Blob([bytes], { type }));
  try { return { width: bitmap.width, height: bitmap.height }; } finally { bitmap.close(); }
}
