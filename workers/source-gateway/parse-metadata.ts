/** Bounded pure XML bridge for the local metadata-execution harness.
 *
 * This consumes a response already bound to its grant by the supervisor. It
 * grants no network/database authority and never fetches a URL. The standalone
 * invocation is intended for Deno with --deny-net --no-prompt --cached-only.
 */
import {
  arxivAtomRecord, arxivCatalogArguments, arxivReference, arxivReuseEvidence,
  type ArxivMetadata, type ArxivRecord,
} from '../../supabase/functions/_shared/arxiv.ts';
import { sha256 } from '../../supabase/functions/_shared/http.ts';
import { SourceError } from '../../supabase/functions/_shared/source-xml.ts';

export const MAX_PARSER_INPUT = 1_572_864;
export const MAX_PARSER_OUTPUT = 45_000;
const MAX_BODY = 1_048_576;
const encoder = new TextEncoder();

export type MetadataParseResult =
  | { schema_version: 1; kind: 'result'; body_sha256: string; result: Record<string, unknown> }
  | { schema_version: 1; kind: 'failure'; error_code: 'source_not_found' | 'invalid_source_metadata'; retryable: false }
  | { schema_version: 1; kind: 'rejected'; reason: 'invalid_parser_input' | 'parser_failure' };

class InvalidInput extends Error {}
function requireInput(condition: unknown): asserts condition {
  if (!condition) throw new InvalidInput();
}
function object(value: unknown, fields: readonly string[]): Record<string, unknown> {
  requireInput(value !== null && typeof value === 'object' && !Array.isArray(value));
  const result = value as Record<string, unknown>;
  const actual = Object.keys(result).sort(), expected = [...fields].sort();
  requireInput(actual.length === expected.length && actual.every((key, i) => key === expected[i]));
  return result;
}
function string(value: unknown, limit: number, nonempty = false): string {
  requireInput(typeof value === 'string' && encoder.encode(value).byteLength <= limit && (!nonempty || value.length > 0));
  return value;
}
function integer(value: unknown, minimum: number, maximum: number): number {
  requireInput(typeof value === 'number' && Number.isSafeInteger(value) && value >= minimum && value <= maximum);
  return value;
}
function instant(value: unknown): string {
  const text = string(value, 24, true);
  requireInput(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(text));
  requireInput(Number.isFinite(Date.parse(text)) && new Date(text).toISOString() === text);
  return text;
}
function optional<T>(value: unknown, parse: (value: unknown) => T): T | null {
  return value === null ? null : parse(value);
}
function strings(value: unknown, count: number, bytes: number): string[] {
  requireInput(Array.isArray(value) && value.length <= count);
  return value.map(item => string(item, bytes, true));
}
function pinnedRecord(value: unknown, sourceID: string, revision: number): ArxivRecord {
  const record = object(value, ['sourceID', 'revision', 'metadata']);
  requireInput(record.sourceID === sourceID && record.revision === revision);
  const fields = object(record.metadata, ['title', 'authors', 'abstract', 'published_at', 'updated_at', 'categories', 'venue']);
  const metadata: ArxivMetadata = {
    title: string(fields.title, 2000, true), authors: strings(fields.authors, 512, 256),
    abstract: optional(fields.abstract, value => string(value, 24_000)),
    published_at: optional(fields.published_at, instant), updated_at: optional(fields.updated_at, instant),
    categories: strings(fields.categories, 64, 64), venue: optional(fields.venue, value => string(value, 1024)),
  };
  requireInput(metadata.categories.every(value => /^[A-Za-z][A-Za-z0-9.-]{0,63}$/.test(value)));
  requireInput(encoder.encode(JSON.stringify(metadata)).byteLength <= 30_000);
  const pinned = { sourceID, revision, metadata };
  arxivCatalogArguments(pinned);
  return pinned;
}

function capture(value: unknown) {
  const root = object(value, ['schema_version', 'request', 'pinned_record', 'body_base64', 'body_sha256', 'observed_at']);
  requireInput(root.schema_version === 1);
  const request = object(root.request, ['source_id', 'revision', 'stage', 'byte_ceiling']);
  const sourceID = string(request.source_id, 128, true);
  const revision = optional(request.revision, value => integer(value, 1, 2_147_483_647));
  const stage = request.stage;
  requireInput(stage === 'atom' || stage === 'license');
  requireInput(stage === 'atom' || revision !== null);
  const reference = arxivReference(sourceID + (revision === null ? '' : `v${revision}`));
  requireInput(reference.sourceID === sourceID && reference.revision === revision);
  const ceiling = integer(request.byte_ceiling, 1, MAX_BODY);
  const observedAt = instant(root.observed_at);
  const expectedDigest = string(root.body_sha256, 64);
  requireInput(/^[0-9a-f]{64}$/.test(expectedDigest));
  const encoded = string(root.body_base64, 4 * Math.ceil(ceiling / 3));
  requireInput(encoded.length % 4 === 0 && /^[A-Za-z0-9+/]*={0,2}$/.test(encoded));
  const decoded = atob(encoded);
  requireInput(decoded.length <= ceiling && btoa(decoded) === encoded);
  const bytes = Uint8Array.from(decoded, value => value.charCodeAt(0));
  // Own nested metadata arrays and every body byte before the asynchronous hash.
  const pinned = stage === 'license' ? pinnedRecord(root.pinned_record, sourceID, revision!) : null;
  requireInput(stage !== 'atom' || root.pinned_record === null);
  return { stage, reference, pinned, bytes, observedAt, expectedDigest };
}

export async function parseMetadata(input: unknown): Promise<MetadataParseResult> {
  let captured: ReturnType<typeof capture>;
  try { captured = capture(input); }
  catch { return { schema_version: 1, kind: 'rejected', reason: 'invalid_parser_input' }; }
  try {
    const bodyDigest = await sha256(captured.bytes);
    if (bodyDigest !== captured.expectedDigest) return { schema_version: 1, kind: 'rejected', reason: 'invalid_parser_input' };
    let result: Record<string, unknown>;
    if (captured.stage === 'atom') {
      const record = arxivAtomRecord(captured.bytes, captured.reference);
      result = { revision: record.revision, metadata: arxivCatalogArguments(record).p_metadata,
        atom_published_at: record.metadata.published_at, atom_updated_at: record.metadata.updated_at };
    } else {
      const reuse = await arxivReuseEvidence(captured.bytes, captured.pinned!, captured.observedAt);
      result = reuse.eligible
        ? { eligible: true, license_uri: reuse.licenseURI, evidence: reuse.evidence }
        : { eligible: false, reason: reuse.reason };
    }
    const output: MetadataParseResult = { schema_version: 1, kind: 'result', body_sha256: bodyDigest, result };
    if (encoder.encode(JSON.stringify(output)).byteLength > MAX_PARSER_OUTPUT) throw new InvalidInput();
    return output;
  } catch (error) {
    if (error instanceof SourceError) return { schema_version: 1, kind: 'failure',
      error_code: error.code === 'source_not_found' ? 'source_not_found' : 'invalid_source_metadata', retryable: false };
    return { schema_version: 1, kind: 'rejected', reason: 'parser_failure' };
  }
}

async function main(): Promise<void> {
  let output: MetadataParseResult;
  const reader = Deno.stdin.readable.getReader();
  try {
    const parts: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      requireInput(total <= MAX_PARSER_INPUT);
      parts.push(new Uint8Array(value));
    }
    const input = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) { input.set(part, offset); offset += part.byteLength; }
    const parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(input));
    output = await parseMetadata(parsed);
  } catch {
    output = { schema_version: 1, kind: 'rejected', reason: 'invalid_parser_input' };
  } finally { reader.releaseLock(); }
  const bytes = encoder.encode(JSON.stringify(output) + '\n');
  let written = 0;
  while (written < bytes.byteLength) written += await Deno.stdout.write(bytes.subarray(written));
}

// Imported Node tests exercise the pure function. Only a Deno entrypoint owns
// stdin/stdout; the parent is responsible for a finite process watchdog.
if (import.meta.main && typeof Deno !== 'undefined') await main();
