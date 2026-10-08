// Selections and passage anchors — ports of ReaderSelection.resolvedQuote (ReaderBundle.swift) and
// TextAnchor.passage (PassageAnchor.swift). Only block and equation IDs cross from the frame for math; the LaTeX
// comes from the verified bundle index, never from a frame message.
import type { VerifiedBundle } from './bundle';
import type { TextAnchor } from './events';

export interface SelectionPart { kind: 'text' | 'equation'; blockID: string; text?: string; equationID?: string }
export interface Selection { manifest: string; parts: SelectionPart[]; context: { prefix: string; suffix: string } | null }

const utf8 = (s: string) => new TextEncoder().encode(s).length;

export function resolveQuote(bundle: VerifiedBundle, selection: Selection): string | null {
  if (selection.manifest !== bundle.manifestSHA256 || selection.parts.length < 1 || selection.parts.length > 512) return null;
  const blocks = new Set(bundle.index.blocks.map(b => b.id));
  const equations = new Map(bundle.index.equations.map(e => [e.id, e]));
  const seen = new Set<string>();
  let out = '';
  for (const part of selection.parts) {
    if (!blocks.has(part.blockID)) return null;
    if (part.kind === 'text') {
      if (part.equationID !== undefined || part.text === undefined || utf8(part.text) > 20_000 || part.text.includes('\0')) return null;
      out += part.text;
    } else {
      const equation = part.equationID ? equations.get(part.equationID) : undefined;
      if (part.text !== undefined || !equation || seen.has(equation.id) || equation.block_id !== part.blockID) return null;
      seen.add(equation.id);
      out += equation.source_form === 'environment' ? `\n${equation.latex}\n` : equation.display ? `\n\\[${equation.latex}\\]\n` : `\\(${equation.latex}\\)`;
    }
    if (utf8(out) > 20_000) return null;
  }
  return out.trim() || null;
}

const collapse = (s: string) => s.split(/\s+/).filter(Boolean).join(' ');
/** The anchor a selection action saves on its new conversation (32 characters of context each side, whitespace collapsed). */
export function passageAnchor(artifactID: string, selection: Selection, quote: string): TextAnchor | null {
  const q = quote.trim();
  if (!q || utf8(q) > 20_000) return null;
  const prefix = [...collapse(selection.context?.prefix ?? '')].slice(-32).join('');
  const suffix = [...collapse(selection.context?.suffix ?? '')].slice(0, 32).join('');
  const element = selection.parts[0]?.blockID;
  return { artifactID, quote: q, prefix: utf8(prefix) <= 1000 ? prefix : '', suffix: utf8(suffix) <= 1000 ? suffix : '',
    elementID: element && utf8(element) >= 1 && utf8(element) <= 200 ? element : undefined };
}

/** What the bridge needs to find a passage (`__scienceReaderSetMarks`, `__scienceReaderGoToPassage`); no conversation text. */
export const bridgeAnchor = (conversationID: string, anchor: TextAnchor, artifactID: string | undefined) =>
  ({ id: conversationID, quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, element: anchor.elementID ?? null, same: anchor.artifactID === artifactID });
