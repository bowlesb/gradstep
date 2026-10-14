// The paper as the chat model reads it (`reader-local-context-v2`): the verified reader index, block by block, each
// block numbered `[¶N]` in index order so an answer can cite the exact passage and the reader can jump to it.
// Headings keep their level, display equations their LaTeX, figures and tables their captions. The same text is
// produced natively (ScienceReaderCore `PaperChatContext`); tests/fixtures/reader-arxiv/local-context-v2.txt is
// the shared golden output both implementations must match byte for byte.
import type { ReaderIndex } from './bundle';

export const PAPER_CONTEXT_FORMAT = 'reader-local-context-v2';
/** `[¶12]` as an answer cites it; the block number is 1-based in `index.blocks` order. */
export const CITATION_PATTERN = /\[¶(\d{1,5})\]/g;

export function buildPaperContext(index: ReaderIndex): string {
  const levels = new Map(index.headings.map(h => [h.id, h.level]));
  const equations = new Map<string, ReaderIndex['equations']>();
  for (const equation of index.equations) {
    const list = equations.get(equation.block_id);
    if (list) list.push(equation); else equations.set(equation.block_id, [equation]);
  }
  const figures = new Map(index.figures.map(f => [f.block_id, f]));
  const parts: string[] = [];
  index.blocks.forEach((block, i) => {
    const marker = `[¶${i + 1}]`;
    let body: string;
    switch (block.kind) {
      case 'heading': {
        const level = levels.get(block.id) ?? (i === 0 ? 1 : 2);
        body = `${'#'.repeat(Math.max(1, Math.min(6, level)))} ${block.text}`;
        break;
      }
      case 'equation': {
        const list = equations.get(block.id);
        body = list?.length ? list.map(e => e.source_form === 'environment' ? e.latex : `\\[ ${e.latex} \\]`).join('\n') : block.text;
        break;
      }
      case 'figure': {
        const figure = figures.get(block.id);
        body = `[Figure] ${figure?.caption || block.text || figure?.alt || ''}`.trimEnd();
        break;
      }
      case 'table': body = `[Table] ${block.text}`.trimEnd(); break;
      case 'list': body = `- ${block.text}`; break;
      default: body = block.text;
    }
    parts.push(body ? `${marker} ${body}` : marker);
  });
  return parts.join('\n\n');
}

/** The block a cited marker names (1-based), or null when the answer cites a block the paper lacks. */
export function citedBlock(index: ReaderIndex, marker: number): ReaderIndex['blocks'][number] | null {
  return Number.isInteger(marker) && marker >= 1 && marker <= index.blocks.length ? index.blocks[marker - 1] : null;
}
