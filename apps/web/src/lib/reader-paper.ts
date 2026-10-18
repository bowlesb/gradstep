import type { ClientEntry, LibraryPaper } from './device-pdf';
// Presentation identities are separate from server PDF document identities.
import type { Entry, Import, Item, Metadata } from './library';
import type { SourcePaperReference } from './events';
import type { VerifiedBundle } from './bundle';
export type SourcePaper = Import & { source:'arxiv'; phase:'source_only'; source_revision:number; metadata:Metadata;
  artifact_id?:never; readiness?:never; render_availability?:never; render_availability_revision?:never;
  scope?:never; page_count?:never; tags?:never; hidden_tags?:never; membership_revision?:never };
export type ReaderPaper = Item | SourcePaper;
export function isSourcePaper(e: ClientEntry): e is SourcePaper {
 return e.kind === 'import' && e.visible && e.source === 'arxiv' && e.phase === 'source_only' && !!e.source_revision && !!e.metadata && !e.document_id;
}
export const isReaderPaper = (e: ClientEntry): e is ReaderPaper => e.kind === 'item' || isSourcePaper(e);
export const paperIdentity = (e: ReaderPaper): string => e.kind === 'item' ? e.document_id : e.id;
export const paperReference = (e: ReaderPaper): SourcePaperReference | undefined => e.kind === 'item' ? undefined :
 ({format:'source-membership-v1',membershipID:e.id,source:'arxiv',sourceID:e.source_id,revision:e.source_revision});

/** What the reader prepares on this device: a membership's exact arXiv HTML, or, for an arXiv paper that joined the
 * library before the HTML-first reader (a server-processed bundle, no membership), the same official HTML by its
 * exact revision. Reading only: chat keeps the item's server document (`paperReference` stays membership-only). */
export const readingSource = (e: ReaderPaper): SourcePaperReference | undefined => e.kind === 'import' ? paperReference(e) :
 e.source === 'arxiv' && e.source_id && e.source_revision ? {format:'source-membership-v1',membershipID:e.id,source:'arxiv',sourceID:e.source_id,revision:e.source_revision} : undefined;

export const readerCacheKey = (account: string, item: ReaderPaper): string => JSON.stringify([account,item.id,item.artifact_id,item.readiness,item.render_availability,item.render_availability_revision,item.source_id,item.source_revision]);

export const isLibraryPaper = (e:ClientEntry):e is LibraryPaper => e.kind === 'local_pdf' || isReaderPaper(e);

/** The papers prepared in this tab (memory only, the newest three): the reader opens them at once, and the library's
 * row says so (PaperDeviceCopy's check). Observable so the library can show which. */
export class ReaderBundles extends Map<string, VerifiedBundle> {
  private listeners = new Set<() => void>();
  private revision = 0;
  override set(key: string, value: VerifiedBundle) { super.set(key, value); this.changed(); return this; }
  override delete(key: string) { const removed = super.delete(key); if (removed) this.changed(); return removed; }
  override clear() { const had = this.size > 0; super.clear(); if (had) this.changed(); }
  private changed() { this.revision++; for (const listener of this.listeners ?? []) listener(); }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  getVersion = () => this.revision;
}

/** Added in the last three days and never opened: the row's "new" dot (ReaderModel.isNew). An import's added time is
 * when its metadata was recorded, moments after Add. */
export function isNewPaper(e: ClientEntry, opened: boolean, now = Date.now()): boolean {
  if (opened) return false;
  const added = e.kind === 'item' || e.kind === 'local_pdf' ? e.added_at : e.added_at ?? e.metadata_recorded_at;
  return typeof added === 'number' && now - added >= 0 && now - added < 3 * 24 * 3600 * 1000;
}
