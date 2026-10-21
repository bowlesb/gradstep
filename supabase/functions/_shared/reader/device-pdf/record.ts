// Evaluation only (docs/reviews/DEVICE_PDF_ROUTE_20261021.md): what the host answered during one conversion, so the
// converter's rules can be changed and re-run in Node in seconds against the same model outputs
// (scripts/device-route-replay.mjs) instead of re-running the models. Never part of a bundle.
import type { DevicePDFHost, DevicePDFInput, ImageRequest, ImageResult, PageInput, RecogniseRequest, TagLine } from './types.ts';

type Recognition = { latex: string; probs: number[] } | null;
export interface DevicePDFRecord {
  format: 'device-pdf-record-v1';
  input: DevicePDFInput;
  pages: PageInput[];
  tags: [string, number[]][];
  recognitions: [string, Recognition][];
}

export const tagKey = (l: TagLine): string => `${l.char.join(',')}|${l.font.join(',')}|${l.x.map(v => Number(v).toFixed(3)).join(',')}`;
export const cropKey = (c: RecogniseRequest): string => `${c.page}:${c.rect.join(',')}`;

/** The host, with every answer the converter's rules depend on written down. */
export function recordingHost(host: DevicePDFHost, input: DevicePDFInput): { host: DevicePDFHost; record: DevicePDFRecord } {
  const record: DevicePDFRecord = { format: 'device-pdf-record-v1', input: { ...input, record: undefined }, pages: [], tags: [], recognitions: [] };
  const submitted = new Map<number, RecogniseRequest[]>();
  const wrapped: DevicePDFHost = {
    ...host,
    page: i => { const p = host.page(i); record.pages[i] = p; return p; },
    tag: lines => { const out = host.tag(lines); lines.forEach((l, i) => record.tags.push([tagKey(l), (out[i] ?? []).map(Number)])); return out; },
    recognise: crops => { const out = host.recognise(crops); crops.forEach((c, i) => record.recognitions.push([cropKey(c), out[i] ?? null])); return out; },
  };
  if (host.submit && host.collect) {
    wrapped.submit = crops => { const t = host.submit!(crops); submitted.set(t, crops); return t; };
    wrapped.collect = ticket => {
      const out = host.collect!(ticket);
      (submitted.get(ticket) ?? []).forEach((c, i) => record.recognitions.push([cropKey(c), out[i] ?? null]));
      return out;
    };
  }
  return { host: wrapped, record };
}

/** A host that answers from a record: the same pages and model outputs; images are made by `image` (any pixels of the
 * asked size); a tagger line or crop the record lacks reads as no math / unread. */
export function replayHost(record: DevicePDFRecord, image: (request: ImageRequest) => ImageResult): DevicePDFHost & { misses: { tags: number; crops: number } } {
  const tags = new Map(record.tags), recognitions = new Map(record.recognitions);
  const misses = { tags: 0, crops: 0 };
  return {
    misses,
    page: i => record.pages[i],
    tag: lines => lines.map(l => { const hit = tags.get(tagKey(l)); if (!hit) { misses.tags += 1; return l.font.map(() => -10); } return hit; }),
    recognise: crops => crops.map(c => { const k = cropKey(c); if (!recognitions.has(k)) { misses.crops += 1; return null; } return recognitions.get(k) ?? null; }),
    image,
  };
}
