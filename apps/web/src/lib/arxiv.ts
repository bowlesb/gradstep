// arXiv identity from pasted text (ScienceReaderCore/ArxivReference.swift on the apps).
// A paper identity, never an address to fetch; the backend receives canonical fields only.

import { arxivReference, type ArxivReference } from '../../../../supabase/functions/_shared/arxiv.ts';
export type { ArxivReference };

/** The server's own parser (supabase/functions/_shared/arxiv.ts), so the browser accepts exactly the identities the
 * server does (D8: the copy differed on control characters, explicit default ports and the 128 limit); null when it
 * names no arXiv paper. */
export function parseArxiv(input: string): ArxivReference | null {
  try { return arxivReference(input); } catch { return null; }
}
