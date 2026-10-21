// What a snippet records about where it came from (NOTES_AND_SNIPPETS.md "Source provenance and reopening"), built
// from the open paper and its verified bundle only — never guessed from a title or a newer revision. Pure.
import type { ReaderIndex, VerifiedBundle } from './bundle';
import type { EntryAnchor, EntrySource } from './notes';
import { NOTES_LIMITS } from './notes';
import type { ReaderPaper } from './reader-paper';
import { bundleRevision } from './reader-versions';

const encoder = new TextEncoder();
/** Text cut (at a character boundary) to a UTF-8 byte bound. */
export function clip(text: string, maxBytes: number): string {
  if (encoder.encode(text).length <= maxBytes) return text;
  let out = '';
  for (const c of text) { if (encoder.encode(out + c).length > maxBytes - 3) break; out += c; }
  return out + '…';
}

/** The section heading a block sits under (the last heading before it), or null. */
export function sectionOf(index: Pick<ReaderIndex, 'blocks' | 'headings'>, blockID: string | undefined): string | null {
  if (!blockID) return null;
  const headings = new Map(index.headings.map(h => [h.id, h.title]));
  let title: string | null = null;
  for (const block of index.blocks) {
    if (headings.has(block.id)) title = headings.get(block.id)!;
    if (block.id === blockID) return title;
  }
  return null;
}

export function paperSource(paper: ReaderPaper, index: Pick<ReaderIndex, 'blocks' | 'headings'>, blockID?: string, label?: string | null): EntrySource {
  const m = paper.metadata, arxiv = !!paper.source_id && (paper.kind === 'import' || paper.source === 'arxiv');
  const section = sectionOf(index, blockID);
  return {
    kind: arxiv ? 'arxiv' : 'document', title: clip(m?.title ?? 'Untitled paper', NOTES_LIMITS.sourceTitleBytes),
    authors: (m?.authors ?? []).slice(0, NOTES_LIMITS.authors).map(a => clip(a, NOTES_LIMITS.authorBytes)),
    sourceID: arxiv ? paper.source_id! : null, revision: arxiv && paper.source_revision ? paper.source_revision : null,
    url: arxiv ? `https://arxiv.org/abs/${paper.source_id}${paper.source_revision ? `v${paper.source_revision}` : ''}` : null,
    section: section ? clip(section, NOTES_LIMITS.sectionBytes) : null, label: label ? clip(label, NOTES_LIMITS.labelBytes) : null,
    membershipID: paper.id.toLowerCase(),
  };
}

const ID = /^[0-9A-Za-z_-]{1,200}$/;
/** The anchor: exact bundle identity, the blocks the snippet covers (≤ 64, known to the index), and for a drawn region
 * its rectangle relative to the paper's viewport with that viewport's size and scale. */
export function snippetAnchor(bundle: Pick<VerifiedBundle, 'manifestSHA256' | 'manifest' | 'index'>, blocks: readonly string[], options: {
  rect?: [number, number, number, number]; viewport?: [number, number, number]; quote?: string | null } = {}): EntryAnchor {
  const known = new Set(bundle.index.blocks.map(b => b.id));
  const blockIDs = [...new Set(blocks)].filter(id => ID.test(id) && known.has(id)).slice(0, NOTES_LIMITS.blockIDs);
  const unit = (n: number) => Math.min(1, Math.max(0, Math.round(n * 10_000) / 10_000));
  const rect = options.rect && options.rect.every(Number.isFinite) ? [[unit(options.rect[0]), unit(options.rect[1]), unit(options.rect[2]), unit(options.rect[3])] as [number, number, number, number]] : [];
  const viewport = options.viewport && options.viewport.every(n => Number.isFinite(n) && n > 0 && n <= 100_000) ? options.viewport : null;
  return { manifestSHA256: bundle.manifestSHA256, rendererRevision: bundleRevision(bundle), blockIDs, rects: rect, viewport: rect.length ? viewport : null,
    quote: options.quote ? clip(options.quote, NOTES_LIMITS.quoteBytes) : null };
}
