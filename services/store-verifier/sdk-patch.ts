// Build-time mitigation for Apple Node SDK issue447. Keep the installed SDK's
// copyright/license and all chain/signature/status checks; change only the two
// reviewed date/freshness hunks. No runtime monkeypatch or alternate verifier.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

export const SDK_SOURCE_SHA256 = '2ab29caa890958dcfc6dc4789fd5a500e8249102e037045525d35e5c15541bf1';
export const SDK_PATCHED_SHA256 = 'e2bbd098d9572596e6fa7572b69ee96fa4c34d5db5479672bc3a91a2c47241ad';
export const OCSP_FRESHNESS_POLICY = 'strict-utc-v1';
// Resolve from the exact importing module, never from a possibly different
// service-local node_modules directory. SDK3.1.0 uses the same CJS main for ESM.
const sdkRequire = createRequire(new URL('../../supabase/functions/_shared/app-store.ts', import.meta.url));
export function resolvedSDKPath(): string {
  return sdkRequire.resolve('@apple/app-store-server-library/dist/jws_verification.js');
}
const hash = (value: string) => createHash('sha256').update(value).digest('hex');

const OLD_DATE = String.raw`    parseX509Date(date) {
        return new Date(date.replace(/^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)$/, '$4:$5:$6 $2/$3/$1'));
    }`;
const NEW_DATE = String.raw`    parseX509Date(date) {
        // Science Reader strict-utc-v1: RFC6960 section4.2.2.1 / RFC5280 section4.1.2.5.2.
        const match = typeof date === 'string' && date.length === 15 && /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(date);
        if (!match) {
            throw new VerificationException(VerificationStatus.FAILURE);
        }
        const [year, month, day, hour, minute, second] = match.slice(1).map(Number);
        const parsed = new Date(0);
        parsed.setUTCFullYear(year, month - 1, day);
        parsed.setUTCHours(hour, minute, second, 0);
        if (year < 1 || !Number.isFinite(parsed.getTime()) || parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1
            || parsed.getUTCDate() !== day || parsed.getUTCHours() !== hour || parsed.getUTCMinutes() !== minute || parsed.getUTCSeconds() !== second) {
            throw new VerificationException(VerificationStatus.FAILURE);
        }
        return parsed;
    }`;
const OLD_FRESHNESS = `            const issueDate = this.parseX509Date(singleResponse.thisupdate);
            const nextDate = this.parseX509Date(singleResponse.nextupdate);
            if (singleResponse.status.status !== 'good' || new Date().getTime() + MAX_SKEW < issueDate.getTime() || nextDate.getTime() < new Date().getTime() - MAX_SKEW) {`;
const NEW_FRESHNESS = `            const issueDate = this.parseX509Date(singleResponse.thisupdate);
            const nextDate = this.parseX509Date(singleResponse.nextupdate);
            const producedDate = this.parseX509Date(parsedResponse.prodat);
            const now = Date.now();
            if (singleResponse.status.status !== 'good' || now + MAX_SKEW < issueDate.getTime() || nextDate.getTime() < now - MAX_SKEW
                || now + MAX_SKEW < producedDate.getTime() || nextDate.getTime() < issueDate.getTime()
                || producedDate.getTime() + MAX_SKEW < issueDate.getTime()) {`;

/** Pure, exact-source transformation, usable for independent diff review. */
export function patchSDKSource(source: string): string {
  if (hash(source) !== SDK_SOURCE_SHA256) throw new Error('sdk_source_mismatch');
  let result = source;
  for (const [before, after] of [[OLD_DATE, NEW_DATE], [OLD_FRESHNESS, NEW_FRESHNESS]]) {
    if (result.split(before).length !== 2) throw new Error('sdk_patch_hunk_mismatch');
    result = result.replace(before, after);
  }
  return result;
}
export function sdkPatchProofForHash(actualHash: unknown) {
  return { policy: OCSP_FRESHNESS_POLICY, applied: actualHash === SDK_PATCHED_SHA256,
    source_sha256: SDK_SOURCE_SHA256, patched_sha256: SDK_PATCHED_SHA256 };
}
export function sdkPatchProof() {
  try { return sdkPatchProofForHash(hash(readFileSync(resolvedSDKPath(), 'utf8'))); }
  catch { return sdkPatchProofForHash(null); }
}
export function applySDKPatch() {
  const path = resolvedSDKPath();
  const source = readFileSync(path, 'utf8');
  if (hash(source) === SDK_PATCHED_SHA256) return sdkPatchProof();
  const patched = patchSDKSource(source);
  if (hash(patched) !== SDK_PATCHED_SHA256) throw new Error('sdk_patch_output_mismatch');
  writeFileSync(path, patched);
  if (!sdkPatchProof().applied) throw new Error('sdk_patch_write_mismatch');
  return sdkPatchProof();
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length !== 3 || process.argv[2] !== '--apply') throw new Error('invalid_patch_command');
  console.log(JSON.stringify(applySDKPatch()));
}
