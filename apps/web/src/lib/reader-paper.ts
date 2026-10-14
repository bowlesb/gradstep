import type { ClientEntry, LibraryPaper } from './device-pdf';
// Presentation identities are separate from server PDF document identities.
import type { Entry, Import, Item, Metadata } from './library';
import type { SourcePaperReference } from './events';
export type SourcePaper = Import & { source:'arxiv'; phase:'source_only'; source_revision:number; metadata:Metadata;
  artifact_id?:never; readiness?:never; render_availability?:never; render_availability_revision?:never;
  scope?:never; page_count?:never; tags?:never; hidden_tags?:never; added_at?:never; membership_revision?:never };
export type ReaderPaper = Item | SourcePaper;
export function isSourcePaper(e: ClientEntry): e is SourcePaper {
 return e.kind === 'import' && e.visible && e.source === 'arxiv' && e.phase === 'source_only' && !!e.source_revision && !!e.metadata && !e.document_id;
}
export const isReaderPaper = (e: ClientEntry): e is ReaderPaper => e.kind === 'item' || isSourcePaper(e);
export const paperIdentity = (e: ReaderPaper): string => e.kind === 'item' ? e.document_id : e.id;
export const paperReference = (e: ReaderPaper): SourcePaperReference | undefined => e.kind === 'item' ? undefined :
 ({format:'source-membership-v1',membershipID:e.id,source:'arxiv',sourceID:e.source_id,revision:e.source_revision});

export const readerCacheKey = (account: string, item: ReaderPaper): string => JSON.stringify([account,item.id,item.artifact_id,item.readiness,item.render_availability,item.render_availability_revision,item.source_id,item.source_revision]);

export const isLibraryPaper = (e:ClientEntry):e is LibraryPaper => e.kind === 'local_pdf' || isReaderPaper(e);
