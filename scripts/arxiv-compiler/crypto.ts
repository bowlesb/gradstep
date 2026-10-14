// The device compiler only needs SHA-256; this adapter is build-local and does
// not replace encryption, randomness, or any platform crypto implementation.
import { sha256 } from '@noble/hashes/sha256';
export function createHash(algorithm: string) {
  if (algorithm !== 'sha256') throw new Error('hash_algorithm');
  const hash = sha256.create();
  return { update(bytes: Uint8Array) { hash.update(bytes); return this; }, digest(format: string) {
    if (format !== 'hex') throw new Error('hash_format');
    return Array.from(hash.digest(), b => b.toString(16).padStart(2, '0')).join('');
  } };
}
