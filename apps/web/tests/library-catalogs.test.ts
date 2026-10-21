import { describe, expect, it } from 'vitest';
import { PrivateState, decodeEvent, encodeEvent, type AppliedEvent } from '../src/lib/events';
import { CATALOG_ENTITY, INITIAL_CATALOG, LibraryCatalogs, arxivCatalogKey, catalogEvent, catalogName, catalogsOf, entryCatalogKey, sourceCatalogKey, type CatalogOperation } from '../src/lib/library-catalogs';
import type { ClientEntry } from '../src/lib/device-pdf';

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const key = 'arxiv:2305.18290', other = id(90), destination = id(91);
function record(n: number, operations: CatalogOperation[], parents: string[] = []): AppliedEvent {
  return { id: id(n), deviceID: id(99), payload: { ...catalogEvent(new PrivateState(), operations, id(n)), parents } };
}
function state(...events: AppliedEvent[]) { const s = new PrivateState(); s.applyBatch(events); return s; }

describe('encrypted library catalogs', () => {
  it('keeps one catalogs instance until a catalog record changes (C3)', () => {
    const s = state(record(1, [{ action: 'create', catalogID: other, name: 'Research' }]));
    const first = catalogsOf(s);
    expect(catalogsOf(s)).toBe(first);
    s.applyBatch([{ id: id(50), deviceID: id(99), payload: { kind: 'conversation', entityID: id(51), parents: [], text: 'A chat' } }]);
    expect(catalogsOf(s)).toBe(first);
    s.applyBatch([record(2, [{ action: 'assign', catalogID: other, paperKey: key }], [id(1)])]);
    const next = catalogsOf(s);
    expect(next).not.toBe(first); expect(next.catalogFor(key)).toBe(other); expect(first.catalogFor(key)).toBe(INITIAL_CATALOG);
  });
  it('choosing a default leaves existing papers in the original catalog', () => {
    const s = new LibraryCatalogs(state(record(1, [{ action: 'create', catalogID: other, name: 'Research' }, { action: 'makeDefault', catalogID: other }])));
    expect(s.defaultID).toBe(other); expect(s.catalogFor(key)).toBe(INITIAL_CATALOG);
  });
  it('uses causal ordering even when envelopes arrive in reverse', () => {
    const a = record(1, [{ action: 'create', catalogID: other, name: 'First' }]);
    const b = record(2, [{ action: 'rename', catalogID: other, name: 'Reading' }, { action: 'assign', catalogID: other, paperKey: key }], [a.id]);
    for (const events of [[a, b], [b, a]]) {
      const s = new LibraryCatalogs(state(...events)); expect(s.catalogFor(key)).toBe(other); expect(s.catalogs.find(c => c.id === other)?.name).toBe('Reading');
    }
    expect(arxivCatalogKey('https://arxiv.org/abs/2305.18290v2')).toBe(key);
  });
  it('defers missing parents and permits children of unknown future payloads', () => {
    const future: AppliedEvent = { id: id(1), deviceID: id(99), payload: { kind: 'note', entityID: CATALOG_ENTITY, parents: [], text: '{"format":"library-catalog-v2"}' } };
    const b = record(2, [{ action: 'rename', catalogID: INITIAL_CATALOG, name: 'Reading' }], [future.id]);
    const s = state(b); expect(new LibraryCatalogs(s).catalogs[0].name).toBe('Default');
    s.apply(future); expect(new LibraryCatalogs(s).catalogs[0].name).toBe('Reading');
  });
  it('key rotation does not change the winner of concurrent renames', () => {
    const a = record(1, [{ action: 'rename', catalogID: INITIAL_CATALOG, name: 'First' }]);
    const b = record(2, [{ action: 'rename', catalogID: INITIAL_CATALOG, name: 'Chosen' }]);
    const s = state(b, a), before = new LibraryCatalogs(s);
    s.apply({ ...a, id: id(5) }); s.apply({ ...b, id: id(4) });
    s.applyLocalReplacements(new Map([[a.id, id(5)], [b.id, id(4)]]));
    expect(new LibraryCatalogs(s)).toEqual(before); expect(before.catalogs[0].name).toBe('Chosen');
  });
  it('redirects assignments made concurrently with catalog deletion', () => {
    const a = record(1, [{ action: 'create', catalogID: other, name: 'Old' }, { action: 'create', catalogID: destination, name: 'Keep' }]);
    const b = record(2, [{ action: 'retire', catalogID: other, destinationID: destination }], [a.id]);
    const c = record(3, [{ action: 'assign', catalogID: other, paperKey: key }], [a.id]);
    for (const events of [[a, b, c], [c, b, a]]) expect(new LibraryCatalogs(state(...events)).catalogFor(key)).toBe(destination);
  });
  it('concurrent deletion cycles always leave a visible recovery catalog', () => {
    const a = record(1, [{ action: 'create', catalogID: other, name: 'Other' }, { action: 'assign', catalogID: other, paperKey: key }]);
    const b = record(2, [{ action: 'retire', catalogID: INITIAL_CATALOG, destinationID: other }], [a.id]);
    const c = record(3, [{ action: 'retire', catalogID: other, destinationID: INITIAL_CATALOG }], [a.id]);
    const s = new LibraryCatalogs(state(c, b, a));
    expect(s.catalogs).toHaveLength(1); expect(s.catalogs[0].id).toBe(s.catalogFor(key));
  });
  it('reads Swift uppercase UUIDs and remains an ordinary backward-compatible note', () => {
    const e = record(1, [{ action: 'rename', catalogID: INITIAL_CATALOG.toUpperCase(), name: 'Research' }]);
    const decoded = decodeEvent(encodeEvent(e.payload));
    expect(decoded.kind).toBe('note'); expect(decoded.conversationID).toBeUndefined();
    expect(new LibraryCatalogs(state({ ...e, payload: decoded })).catalogs[0].name).toBe('Research');
    expect(catalogName('  Reading  ')).toBe('Reading'); expect(catalogName('a'.repeat(81))).toBeNull();
    expect(catalogName('a\nb')).toBeNull(); expect(catalogName('a\u202eb')).toBeNull();
    expect(() => catalogEvent(new PrivateState(), [{ action: 'assign', catalogID: other, paperKey: 'private-url' }])).toThrow();
  });
  // NATIVE_REVIEW_20261021 A6, shared with LibraryCatalog.swift.
  it('files a web paper by its source from pending import to installed paper, keeping an earlier document-key move', () => {
    const source = 'openalex:W2741809807', sourceKey = 'source:' + source;
    expect(sourceCatalogKey(source)).toBe(sourceKey); expect(sourceCatalogKey('local:' + id(1))).toBeNull();
    expect(sourceCatalogKey('2305.18290')).toBeNull();
    const filed = new LibraryCatalogs(state(record(1, [{ action: 'create', catalogID: other, name: 'Thesis' }]),
      record(2, [{ action: 'assign', catalogID: other, paperKey: sourceKey }], [id(1)])));
    const pending = { kind: 'import', id: id(10), visible: true, source_id: source } as unknown as ClientEntry;
    const installed = { kind: 'item', id: id(11), document_id: id(12), visible: true, source_id: source } as unknown as ClientEntry;
    expect(filed.catalogFor(entryCatalogKey(pending, filed))).toBe(other);
    expect(filed.catalogFor(entryCatalogKey(installed, filed))).toBe(other);
    const legacy = new LibraryCatalogs(state(record(1, [{ action: 'create', catalogID: other, name: 'Thesis' },
      { action: 'assign', catalogID: other, paperKey: 'paper:' + id(12) }])));
    expect(entryCatalogKey(installed, legacy)).toBe('paper:' + id(12)); expect(legacy.catalogFor(entryCatalogKey(installed, legacy))).toBe(other);
    const arxiv = { kind: 'item', id: id(13), document_id: id(14), visible: true, source_id: '2305.18290' } as unknown as ClientEntry;
    expect(entryCatalogKey(arxiv, legacy)).toBe('arxiv:2305.18290');
  });
});
