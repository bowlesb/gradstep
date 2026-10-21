// Wire-compatible with ScienceReaderCore/LibraryCatalog.swift. These are encrypted note payloads,
// not a new strict event kind: older readers keep them without losing their history.
import { parseArxiv } from './arxiv';
import { isUUID } from './bytes';
import { isWebSourceID } from './library';
import { PrivateState, type PrivateEvent } from './events';
import type { ClientEntry } from './device-pdf';

export const CATALOG_ENTITY = 'ad734100-688f-4fd1-9379-a0f1b0186c42';
export const INITIAL_CATALOG = 'c2436200-0be6-4cbb-8b72-75605729a980';
const FORMAT = 'library-catalog-v1';
export interface Catalog { id: string; name: string }
export interface CatalogOperation {
  action: 'create' | 'rename' | 'makeDefault' | 'assign' | 'retire';
  catalogID: string; name?: string; paperKey?: string; destinationID?: string;
}
interface Batch { format: string; batchID: string; operations: CatalogOperation[] }
const bytes = (text: string) => new TextEncoder().encode(text).length;
export function catalogName(raw: string): string | null {
  const name = raw.replace(/^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/gu, '');
  return name && [...name].length <= 80 && bytes(name) <= 240 && !/[\p{Cc}\p{Cf}]/u.test(name) ? name : null;
}
export const arxivCatalogKey = (raw: string) => { const ref = parseArxiv(raw); return ref ? 'arxiv:' + ref.sourceID : null; };
export const documentCatalogKey = (id: string) => 'paper:' + id.toLowerCase();
/** A web (open-access) paper keeps one key from its pending import to the installed paper (LibraryCatalog.swift
 *  `sourceKey`). Older readers ignore a batch with this key, so it is written in a batch of its own. */
export const sourceCatalogKey = (sourceID: string) => isWebSourceID(sourceID) ? 'source:' + sourceID : null;
/** Pass the catalog state: a web paper moved under its document key (before source keys) stays there until moved again. */
export function entryCatalogKey(entry: ClientEntry, catalogs?: LibraryCatalogs): string {
  const arxiv = entry.source_id && arxivCatalogKey(entry.source_id);
  if (arxiv) return arxiv;
  const document = documentCatalogKey(entry.kind === 'item' ? entry.document_id : entry.kind === 'import' ? entry.document_id ?? entry.id : entry.id);
  const source = entry.kind !== 'local_pdf' && entry.source_id ? sourceCatalogKey(entry.source_id) : null;
  if (!source) return document;
  return !catalogs || catalogs.isAssigned(source) || !catalogs.isAssigned(document) ? source : document;
}
function validKey(key: string) {
  if (key.startsWith('source:')) return sourceCatalogKey(key.slice(7)) === key;
  return key.startsWith('arxiv:') ? arxivCatalogKey(key.slice(6)) === key : key.startsWith('paper:') && isUUID(key.slice(6)) && key === key.toLowerCase();
}
function decode(text: string): Batch | null {
  try {
    if (bytes(text) > 32768) return null;
    const b = JSON.parse(text) as Batch;
    if (b.format !== FORMAT || !isUUID(b.batchID) || !Array.isArray(b.operations) || !b.operations.length || b.operations.length > 64) return null;
    const operations: CatalogOperation[] = [];
    for (const o of b.operations) {
      if (!o || !isUUID(o.catalogID)) return null;
      // JSONEncoder omits optional nil fields; JSONDecoder accepts explicit null too.
      const absent = (v: unknown) => v === undefined || v === null;
      switch (o.action) {
        case 'create': case 'rename':
          if (typeof o.name !== 'string' || catalogName(o.name) !== o.name || !absent(o.paperKey) || !absent(o.destinationID)) return null; break;
        case 'makeDefault': if (!absent(o.name) || !absent(o.paperKey) || !absent(o.destinationID)) return null; break;
        case 'assign': if (!absent(o.name) || !absent(o.destinationID) || typeof o.paperKey !== 'string' || !validKey(o.paperKey)) return null; break;
        case 'retire': if (!absent(o.name) || !absent(o.paperKey) || !isUUID(o.destinationID) || o.destinationID.toLowerCase() === o.catalogID.toLowerCase()) return null; break;
        default: return null;
      }
      operations.push({ ...o, catalogID: o.catalogID.toLowerCase(), destinationID: o.destinationID?.toLowerCase() });
    }
    return { format: FORMAT, batchID: b.batchID.toLowerCase(), operations };
  } catch { return null; }
}
export function catalogEvent(state: PrivateState, operations: CatalogOperation[], batchID = crypto.randomUUID()): PrivateEvent {
  const text = JSON.stringify({ format: FORMAT, batchID, operations });
  if (!decode(text) || state.isDeleted(CATALOG_ENTITY)) throw Error('This catalog change couldn’t be saved.');
  const parents = state.revisions(CATALOG_ENTITY).map(e => e.id);
  if (parents.length > 100) throw Error('Sync your library before changing catalogs.');
  return { kind: 'note', entityID: CATALOG_ENTITY, parents, text };
}

export class LibraryCatalogs {
  readonly catalogs: Catalog[];
  readonly defaultID: string;
  private assignments = new Map<string, string>();
  private redirects = new Map<string, string>();
  private active: Set<string>;
  private fallback: string;
  constructor(state = new PrivateState()) {
    const names = new Map([[INITIAL_CATALOG, 'Default']]), retired = new Set<string>();
    let preferred = INITIAL_CATALOG;
    if (!state.isDeleted(CATALOG_ENTITY)) {
      const records = new Map([...state.events].filter(([, e]) => e.payload.entityID === CATALOG_ENTITY));
      const remaining = new Map<string, number>(), children = new Map<string, string[]>(), heights = new Map<string, number>(), queue: string[] = [];
      for (const [id, { payload }] of records) {
        remaining.set(id, payload.parents.length);
        for (const p of payload.parents) children.set(p, [...children.get(p) ?? [], id]);
        if (!payload.parents.length) { heights.set(id, 0); queue.push(id); }
      }
      for (let i = 0; i < queue.length; i++) for (const child of children.get(queue[i]) ?? []) {
        heights.set(child, Math.max(heights.get(child) ?? 0, (heights.get(queue[i]) ?? 0) + 1));
        remaining.set(child, remaining.get(child)! - 1);
        if (remaining.get(child) === 0) queue.push(child);
      }
      const batches = queue.flatMap(id => {
        const e = records.get(id)!.payload;
        const b = e.kind === 'note' && !e.documentID && !e.conversationID && e.text ? decode(e.text) : null;
        return b ? [{ id, height: heights.get(id)!, batch: b }] : [];
      }).sort((a, b) => a.height - b.height || compare(a.batch.batchID, b.batch.batchID) || compare(a.id, b.id));
      const seen = new Set<string>();
      for (const { batch } of batches) {
        if (seen.has(batch.batchID)) continue; seen.add(batch.batchID);
        for (const o of batch.operations) switch (o.action) {
          case 'create': if (!names.has(o.catalogID) && !retired.has(o.catalogID)) names.set(o.catalogID, o.name!); break;
          case 'rename': if (names.has(o.catalogID)) names.set(o.catalogID, o.name!); break;
          case 'makeDefault': preferred = o.catalogID; break;
          case 'assign': this.assignments.set(o.paperKey!, o.catalogID); break;
          case 'retire': if (!retired.has(o.catalogID)) { retired.add(o.catalogID); names.delete(o.catalogID); this.redirects.set(o.catalogID, o.destinationID!); } break;
        }
      }
    }
    if (!names.size) names.set(INITIAL_CATALOG, 'Default');
    this.active = new Set(names.keys()); this.fallback = names.has(INITIAL_CATALOG) ? INITIAL_CATALOG : [...names.keys()].sort()[0];
    this.catalogs = [...names].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name) || compare(a.id, b.id));
    this.defaultID = this.resolve(preferred);
  }
  resolve(id: string): string {
    const seen = new Set<string>();
    while (this.redirects.has(id)) { if (seen.has(id)) return this.fallback; seen.add(id); id = this.redirects.get(id)!; }
    return this.active.has(id) ? id : this.fallback;
  }
  catalogFor(key: string): string { return this.resolve(this.assignments.get(key) ?? INITIAL_CATALOG); }
  isAssigned(key: string): boolean { return this.assignments.has(key); }
}
const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
