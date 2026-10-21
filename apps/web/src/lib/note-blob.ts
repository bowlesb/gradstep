// Snippet image blobs (NOTES_AND_SNIPPETS.md "Blob cryptography"): a fresh 32-byte key and 12-byte nonce per blob,
// AES-256-GCM, stored blob = nonce ‖ ciphertext ‖ tag, AAD = `science-reader/snippet-blob/v1\n{account}\n{blob}\n` with
// lowercase canonical UUIDs. `sha256` is over the stored blob. Opening checks the length and digest, the tag, the media
// type's magic bytes and (before display) the image's own dimensions against the record. The key lives only inside the
// encrypted entry record; the server sees opaque bytes. Fixture: tests/fixtures/notes/notes-v1.json (`blob`).
import { type Bytes, concat, fromBase64, randomBytes, sha256Hex, toBase64, utf8, wireUUID } from './bytes';
import type { MediaDescriptor, MediaType } from './notes';
import { NOTES_LIMITS } from './notes';

export class BlobError extends Error {
  constructor(readonly code: 'blob_length' | 'blob_digest' | 'blob_tag' | 'blob_type' | 'blob_dimensions' | 'blob_key') { super(code); }
}
const subtle = () => globalThis.crypto.subtle;
export const blobAAD = (account: string, blobID: string): Bytes => utf8(`science-reader/snippet-blob/v1\n${wireUUID(account)}\n${wireUUID(blobID)}\n`);

async function aes(key: Bytes, usage: KeyUsage): Promise<CryptoKey> {
  if (key.length !== 32) throw new BlobError('blob_key');
  return subtle().importKey('raw', key, { name: 'AES-GCM' }, false, [usage]);
}

export interface SealedBlob { blobID: string; stored: Bytes; key: Bytes; sha256: string }
/** Encrypts one image for upload. `vector` is for the published fixture only; production always draws fresh values. */
export async function sealBlob(plaintext: Bytes, account: string, blobID: string, vector?: { key: Bytes; nonce: Bytes }): Promise<SealedBlob> {
  const key = vector?.key ?? randomBytes(32), nonce = vector?.nonce ?? randomBytes(12);
  if (nonce.length !== 12) throw new BlobError('blob_key');
  const body = new Uint8Array(await subtle().encrypt({ name: 'AES-GCM', iv: nonce, additionalData: blobAAD(account, blobID), tagLength: 128 }, await aes(key, 'encrypt'), plaintext));
  const stored = concat(nonce, body);
  return { blobID: wireUUID(blobID), stored, key, sha256: await sha256Hex(stored) };
}

/** The image a stored blob holds, after the length, digest, tag and magic-byte checks. */
export async function openBlob(stored: Bytes, media: MediaDescriptor, account: string): Promise<Bytes> {
  if (stored.length !== media.bytes || stored.length < 29) throw new BlobError('blob_length');
  if (await sha256Hex(stored) !== media.sha256) throw new BlobError('blob_digest');
  let plain: Bytes;
  try {
    plain = new Uint8Array(await subtle().decrypt({ name: 'AES-GCM', iv: stored.slice(0, 12), additionalData: blobAAD(account, media.blobID), tagLength: 128 },
      await aes(fromBase64(media.key), 'decrypt'), stored.slice(12)));
  } catch (error) { if (error instanceof BlobError) throw error; throw new BlobError('blob_tag'); }
  if (sniffImage(plain) !== media.type) throw new BlobError('blob_type');
  return plain;
}

const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
export function sniffImage(bytes: Uint8Array): MediaType | null {
  if (bytes.length >= 8 && PNG.every((b, i) => bytes[i] === b)) return 'image/png';
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  return null;
}

/** Width and height from the image's own header (PNG IHDR, JPEG SOFn), without decoding pixels. */
export function headerSize(bytes: Uint8Array): { width: number; height: number } | null {
  const type = sniffImage(bytes);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (type === 'image/png') {
    if (bytes.length < 24 || String.fromCharCode(...bytes.subarray(12, 16)) !== 'IHDR') return null;
    return { width: view.getUint32(16), height: view.getUint32(20) };
  }
  if (type === 'image/jpeg') {
    let at = 2;
    while (at + 9 < bytes.length) {
      if (bytes[at] !== 0xff) return null;
      const marker = bytes[at + 1];
      if (marker === 0xff) { at++; continue; }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { at += 2; continue; }
      const length = view.getUint16(at + 2);
      if (length < 2) return null;
      // SOF0–SOF15 except DHT (C4), JPG (C8) and DAC (CC).
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return { height: view.getUint16(at + 5), width: view.getUint16(at + 7) };
      at += 2 + length;
    }
  }
  return null;
}

/** The record's dimensions match the image's header (and, in a browser, its decoded size: see `decodedSize`). */
export function checkDimensions(plain: Uint8Array, media: MediaDescriptor): void {
  const size = headerSize(plain);
  if (!size || size.width !== media.width || size.height !== media.height) throw new BlobError('blob_dimensions');
}

/** A media descriptor for a sealed image (the record keeps it inside the encrypted entry). */
export function descriptor(sealed: SealedBlob, type: MediaType, width: number, height: number): MediaDescriptor {
  return { blobID: sealed.blobID, key: toBase64(sealed.key), sha256: sealed.sha256, bytes: sealed.stored.length, type, width, height };
}

/** Plaintext limits before sealing: the full image ≤ 2 MiB, a thumbnail ≤ 64 KiB. */
export const MAX_FULL_PLAINTEXT = NOTES_LIMITS.fullBytes - 28, MAX_THUMB_PLAINTEXT = NOTES_LIMITS.thumbBytes - 28;
