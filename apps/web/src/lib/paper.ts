import type { ClientEntry, LibraryPaper, LocalPDFPaper } from './device-pdf';
// What the library table shows for each entry: the native LibraryRowFacts, minus chats.
import { distinctiveKeyword, tagsFromCategories, TAG_VOCABULARY } from '../../../../supabase/functions/_shared/tag-vocabulary.ts';
import { isSourcePaper, readingSource, type ReaderPaper } from './reader-paper';
import type { Entry, Import, Item } from './library';
import { type ImportAction, importAction, importStatus, importStep, retryingAutomatically } from './progress';

const lower = (list: string[]) => new Set(list.map(t => t.toLowerCase()));

export const allowedKeyword=(name:string)=>!['artificial intelligence','machine learning','ai','ml','statistical ml'].includes(name.trim().toLowerCase());
/** Specific enough to tell this paper from others (builds 70 and 75: no LLM, Large language models, Reasoning,
 * Evaluation): derived keywords and catalog tags use it; a tag the reader typed only has to be allowed
 * (PaperKeywords.distinctive). */
export { distinctiveKeyword };
export function deriveKeywords(title:string,abstract:string):string[] {
  const norm=(s:string)=>' '+s.toLowerCase().replaceAll('-',' ').split(/[^\p{L}\p{N}]+/u).filter(Boolean).join(' ')+' ';
  const heading=norm(title),summary=norm(abstract);
  const ranked: [string,number][] = TAG_VOCABULARY.filter(t=>t.kind==='topic'&&distinctiveKeyword(t.name)).flatMap(t=>{
    const term=norm(t.name),singular=term.endsWith('s ')?term.slice(0,-2)+' ':term;
    const score=(heading.includes(term)||heading.includes(singular)?20:0)+(summary.includes(term)||summary.includes(singular)?8:0);
    return score?[[t.name,score] as [string,number]]:[];
  });
  for(const word of title.split(/[^\p{L}\p{N}-]+/u))if(word.length>=3&&word.length<=32&&(word.match(/\p{Lu}/gu)?.length??0)>=2&&distinctiveKeyword(word))ranked.push([word,25]);
  const seen=new Set<string>();return ranked.sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0])).flatMap(([name])=>{const key=name.toLowerCase();if(seen.has(key))return [];seen.add(key);return [name];}).slice(0,6);
}
/** What the reader sees: the catalog's tags minus those they removed, then their own (PaperTags.effective). */
export function effectiveTags(item: LibraryPaper): string[] {
  if (isSourcePaper(item)) return (item.tags_customized || item.user_tags?.length ? item.user_tags ?? [] : deriveKeywords(item.metadata.title ?? '',item.metadata.abstract ?? '')).filter(allowedKeyword);
  const hidden = lower(item.hidden_tags ?? []), result: string[] = [];
  const add = (tag: string) => { if (allowedKeyword(tag) && !result.some(t => t.toLowerCase() === tag.toLowerCase())) result.push(tag); };
  for (const tag of item.tags ?? []) if (!hidden.has(tag.toLowerCase()) && distinctiveKeyword(tag)) add(tag);
  for (const tag of item.user_tags ?? []) add(tag);
  return result;
}

export interface Row {
  key: string; entry: ClientEntry; title: string; firstAuthor: string | null; year: number | null; tags: string[]; added: number | null;
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

/** Readable in the browser's reader: a verified identity with a published reader artifact, or an arXiv paper, which
 * reads from its official HTML prepared on this device whether or not the server still has a copy (the server's paper
 * copies were deleted on 2026-10-16: DATA_HANDLING_AND_COSTS.md "Server paper copies: retired"). */
export function canRead(item: Item): boolean {
  const identity = item.visible && item.approval_id && item.version_id && item.metadata_id && item.original_object_id
    && ['pdf_ready', 'converted_ready', 'unavailable'].includes(item.readiness);
  if (!identity || !item.artifact_id) return false;
  if (readingSource(item)) return true;
  return item.render_availability !== undefined ? item.render_availability === 'available' : item.readiness === 'converted_ready';
}

function itemRow(item: Item): Row {
  const m = item.metadata, readable = canRead(item);
  let status: Row['status'] = null;
  if (!readable) status = item.readiness === 'unavailable' || item.render_availability === 'quarantined' ? { kind: 'problem', text: 'No reading copy' }
    : item.readiness === 'pdf_ready' ? { kind: 'problem', text: 'No reading copy' } : { kind: 'info', text: 'Not ready yet' };
  return {
    key: 'item:' + item.id, entry: item, title: m?.title ?? (item.source_id ? placeholder(item.source_id) : 'Untitled paper'),
    firstAuthor: m?.authors[0] ?? null, year: year(m?.published_at),
    // Intentional empty tags stay empty; category fallback is only for an item without a tag projection.
    tags: item.tags || item.user_tags || item.hidden_tags ? effectiveTags(item) : deriveKeywords(m?.title ?? '',m?.abstract ?? ''),
    added: item.added_at, source: sourceLabel(item.source_id, item.source_url), pages: item.page_count, readable, archived: item.archived === true,
    status, action: null, failed: false,
  };
}

function importRow(entry: Import): Row {
  const m = entry.metadata, step = importStep(entry), action = importAction(entry);
  const failed = entry.phase === 'failed' && !retryingAutomatically(entry);
  return {
    key: 'import:' + entry.id, entry, title: m?.title ?? placeholder(entry.source_id), firstAuthor: m?.authors[0] ?? null, year: year(m?.published_at),
    tags: (entry.tags_customized || entry.user_tags?.length ? entry.user_tags ?? [] : deriveKeywords(m?.title ?? '',m?.abstract ?? '')).filter(allowedKeyword), added: entry.added_at ?? null, source: sourceLabel(entry.source_id), pages: null, readable: isSourcePaper(entry), archived: entry.archived === true,
    status: isSourcePaper(entry) ? null : { kind: step || retryingAutomatically(entry) ? 'active' : failed || entry.phase === 'membership_conflict' ? 'problem' : 'info', text: importStatus(entry) },
    action: isSourcePaper(entry) ? null : action, failed,
  };
}

/** Visible items, and imports not yet resolved into a visible item. Reconciled entries are immutable;
 * a view-owned weak cache keeps unchanged row facts stable without retaining retired accounts/entries. */
export function rows(entries: Iterable<ClientEntry>, cache?: WeakMap<ClientEntry, Row>): Row[] {
  const all = [...entries], visibleItems = new Set(all.filter(e => e.kind === 'item' && e.visible).map(e => e.id));
  const out: Row[] = [];
  for (const e of all) {
    if (!e.visible) continue;
    if (e.kind === 'import' && e.library_item_id && visibleItems.has(e.library_item_id)) continue;
    let row = cache?.get(e);
    if (!row) { row = e.kind === 'local_pdf' ? {key:'local_pdf:'+e.id,entry:e,title:e.metadata.title,firstAuthor:null,year:null,tags:e.user_tags,added:e.added_at,source:'PDF on this device',pages:e.page_count,readable:true,archived:e.archived,status:{kind:'info',text:e.available?'PDF on this device':'Choose PDF on this device'},action:null,failed:false} : e.kind === 'item' ? itemRow(e) : importRow(e); cache?.set(e, row); }
    out.push(row);
  }
  return out;
}
