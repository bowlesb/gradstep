// What the library table shows for each entry: the native LibraryRowFacts, minus chats.
import { tagsFromCategories } from '../../../../supabase/functions/_shared/tag-vocabulary.ts';
import type { Entry, Import, Item } from './library';
import { type ImportAction, importAction, importStatus, importStep, retryingAutomatically } from './progress';

const lower = (list: string[]) => new Set(list.map(t => t.toLowerCase()));

/** What the reader sees: the catalog's tags minus those they removed, then their own (PaperTags.effective). */
export function effectiveTags(item: Item): string[] {
  const hidden = lower(item.hidden_tags ?? []), result: string[] = [];
  const add = (tag: string) => { if (!result.some(t => t.toLowerCase() === tag.toLowerCase())) result.push(tag); };
  for (const tag of item.tags ?? []) if (!hidden.has(tag.toLowerCase())) add(tag);
  for (const tag of item.user_tags ?? []) add(tag);
  return result;
}

export interface Row {
  key: string; entry: Entry; title: string; firstAuthor: string | null; year: number | null; tags: string[]; added: number | null;
  source: string; pages: number | null; readable: boolean; archived: boolean; status: { kind: 'none' | 'active' | 'info' | 'problem'; text: string } | null;
  action: ImportAction | null; failed: boolean;
}

const year = (date?: string) => (date ? Number(date.slice(0, 4)) : null);
const placeholder = (sourceID: string) => sourceID.startsWith('openalex:W') ? 'Open-access paper' : `arXiv ${sourceID}`;
function sourceLabel(sourceID?: string, url?: string): string {
  if (!sourceID) return '';
  if (!sourceID.startsWith('openalex:')) return sourceID;
  try { return url ? new URL(url).hostname.replace(/^www\./, '') : 'Open access'; } catch { return 'Open access'; }
}

/** Readable in the browser's reader: a verified identity with a published reader artifact. */
export function canRead(item: Item): boolean {
  const identity = item.visible && item.approval_id && item.version_id && item.metadata_id && item.original_object_id
    && ['pdf_ready', 'converted_ready', 'unavailable'].includes(item.readiness);
  if (!identity || !item.artifact_id) return false;
  return item.render_availability !== undefined ? item.render_availability === 'available' : item.readiness === 'converted_ready';
}

function itemRow(item: Item): Row {
  const m = item.metadata, readable = canRead(item);
  let status: Row['status'] = null;
  if (!readable) status = item.readiness === 'unavailable' || item.render_availability === 'quarantined' ? { kind: 'problem', text: 'Unavailable' }
    : item.readiness === 'pdf_ready' ? { kind: 'info', text: 'Not converted' } : { kind: 'info', text: 'Not ready yet' };
  return {
    key: 'item:' + item.id, entry: item, title: m?.title ?? (item.source_id ? placeholder(item.source_id) : 'Untitled paper'),
    firstAuthor: m?.authors[0] ?? null, year: year(m?.published_at),
    // Intentional empty tags stay empty; category fallback is only for an item without a tag projection.
    tags: item.tags || item.user_tags || item.hidden_tags ? effectiveTags(item) : tagsFromCategories(m?.categories ?? []),
    added: item.added_at, source: sourceLabel(item.source_id, item.source_url), pages: item.page_count, readable, archived: item.archived === true,
    status, action: null, failed: false,
  };
}

function importRow(entry: Import): Row {
  const m = entry.metadata, step = importStep(entry), action = importAction(entry);
  const failed = entry.phase === 'failed' && !retryingAutomatically(entry);
  return {
    key: 'import:' + entry.id, entry, title: m?.title ?? placeholder(entry.source_id), firstAuthor: m?.authors[0] ?? null, year: year(m?.published_at),
    tags: tagsFromCategories(m?.categories ?? []), added: null, source: sourceLabel(entry.source_id), pages: null, readable: false, archived: false,
    status: { kind: step || retryingAutomatically(entry) ? 'active' : failed || entry.phase === 'membership_conflict' ? 'problem' : 'info', text: importStatus(entry) },
    action, failed,
  };
}

/** Visible items, and imports not yet resolved into a visible item. Reconciled entries are immutable;
 * a view-owned weak cache keeps unchanged row facts stable without retaining retired accounts/entries. */
export function rows(entries: Iterable<Entry>, cache?: WeakMap<Entry, Row>): Row[] {
  const all = [...entries], visibleItems = new Set(all.filter(e => e.kind === 'item' && e.visible).map(e => e.id));
  const out: Row[] = [];
  for (const e of all) {
    if (!e.visible) continue;
    if (e.kind === 'import' && e.library_item_id && visibleItems.has(e.library_item_id)) continue;
    let row = cache?.get(e);
    if (!row) { row = e.kind === 'item' ? itemRow(e) : importRow(e); cache?.set(e, row); }
    out.push(row);
  }
  return out;
}
