// "Papers in this answer" (B2): the papers an answer names by arXiv ID or DOI, found in this browser from the answer's
// own text; nothing is fetched and no model is asked. A port of ScienceReaderCore/ChatPaperMentions.swift (same patterns,
// order, deduplication, titles and limit), checked against its tests in tests/paper-mentions.test.ts.
import { parseArxiv, type ArxivReference } from './arxiv';

export interface PaperMention {
  /** `arxiv:<source ID>` or `doi:<lowercased DOI>`: stable across answers. */
  id: string;
  kind: 'arxiv' | 'doi';
  /** arXiv: the reference (with the version the answer gave, if any). */
  arxiv?: ArxivReference;
  /** DOI: as written in the answer. */
  doi?: string;
  /** The title the answer gives it (a link's text or the item's leading title), if any. */
  title: string | null;
  /** "arXiv 2305.18290" or "DOI 10.2307/2334029". */
  label: string;
  /** The paper's page: arXiv's abstract page or the DOI resolver. */
  url: string;
}

/** At most this many papers are listed under one answer. */
export const MAXIMUM_MENTIONS = 8;
const MAXIMUM_PARSED = 200_000;
const DOI = /\b10\.\d{4,9}\/[-._;()/:A-Za-z0-9]+/g;
const ARXIV_LINK = /arxiv\.org\/(?:abs|pdf)\/((?:[a-z][a-z-]*(?:\.[a-z]{2})?\/\d{7})|(?:\d{4}\.\d{4,5}))(v\d+)?(?![\d])/gi;
const ARXIV_NAME = /\barxiv(?::\s*|\s+)((?:[a-z][a-z-]*(?:\.[a-z]{2})?\/\d{7})|(?:\d{4}\.\d{4,5}))(v\d+)?(?!\d)/gi;
const ARXIV_DOI = /^10\.48550\/arxiv\.(.+)$/i;
const LINK = /\[([^\]\n]{1,300})\]\(([^)\s]{1,2000})\)/g;

/** The answer without its trailing Sources list (ChatRichText.trailingSources): that list already shows those links. */
export function withoutTrailingSources(text: string): string {
  let at = text.lastIndexOf('\n\nSources:\n'), start: number;
  if (at >= 0) start = at + '\n\nSources:\n'.length;
  else if (text.startsWith('Sources:\n')) { at = 0; start = 'Sources:\n'.length; }
  else return text;
  const lines = text.slice(start).split('\n').filter(l => l.trim());
  if (lines.length < 1 || lines.length > 8) return text;
  for (const line of lines) {
    const match = /^\d{1,2}\. (?:(.{1,300}) — )?(https:\/\/[^\s]{1,500})$/.exec(line);
    if (!match) return text;
    try { const url = new URL(match[2]); if (url.protocol !== 'https:' || !url.hostname) return text; } catch { return text; }
  }
  return text.slice(0, at);
}

function arxivMention(id: string, version: string, title: string | null): PaperMention | null {
  const reference = parseArxiv(id + version);
  if (!reference) return null;
  const identifier = reference.sourceID + (reference.revision !== null ? `v${reference.revision}` : '');
  return { id: `arxiv:${reference.sourceID}`, kind: 'arxiv', arxiv: reference, title, label: `arXiv ${identifier}`, url: `https://arxiv.org/abs/${identifier}` };
}
function doiMention(doi: string, title: string | null): PaperMention {
  // Swift's urlPathAllowed without ?#; (DOIs keep their slashes and parentheses).
  const path = [...doi].map(c => /[A-Za-z0-9\-._~!$&'()*+,=:@/]/.test(c) ? c : encodeURIComponent(c)).join('');
  return { id: `doi:${doi.toLowerCase()}`, kind: 'doi', doi, title, label: `DOI ${doi}`, url: `https://doi.org/${path}` };
}

/** Drops punctuation that ends a sentence or closes a link around the DOI. */
export function trimmedDOI(value: string): string {
  let doi = value;
  for (;;) {
    const last = doi.at(-1);
    if (last && '.,;:'.includes(last)) { doi = doi.slice(0, -1); continue; }
    if (last === ')' && (doi.match(/\(/g)?.length ?? 0) < (doi.match(/\)/g)?.length ?? 0)) { doi = doi.slice(0, -1); continue; }
    return doi;
  }
}

/** Plain title text, or null when it is not a usable title (an address, an ID, a label such as "Note:"). */
export function cleanTitle(raw: string): string | null {
  const stripped = raw.replace(/[*_`]/g, '').replace(/\s+/g, ' ').replace(/^[\s—–\-,;]+|[\s—–\-,;]+$/g, '');
  const lowered = stripped.toLowerCase(), length = [...stripped].length;
  if (length < 4 || length > 300 || !stripped.includes(' ') || stripped.endsWith(':') || lowered.startsWith('http') || lowered.includes('arxiv.org')
    || lowered.startsWith('arxiv') || lowered.startsWith('doi') || /^\d{4}\.\d{4,5}/.test(stripped) || /^10\.\d{4,9}\//.test(stripped) || !/[A-Za-z]/.test(stripped)) return null;
  return stripped;
}

/** A list item's or line's leading title: `**Title**`, `*Title*`, `[Title](…)` or a quoted title. */
export function leadingTitle(line: string): string | null {
  let rest = line.trim();
  const marker = /^(?:[-*+]|\d{1,3}[.)])\s+/.exec(rest);
  if (marker) rest = rest.slice(marker[0].length);
  for (const [open, close] of [['**', '**'], ['__', '__'], ['*', '*'], ['_', '_'], ['“', '”'], ['"', '"'], ['[', ']']]) {
    if (!rest.startsWith(open)) continue;
    const body = rest.slice(open.length), end = body.indexOf(close);
    if (end < 0) continue;
    return cleanTitle(body.slice(0, end));
  }
  return null;
}

/** The papers an answer names, in order of first mention, deduplicated and capped at MAXIMUM_MENTIONS. Papers that
 * appear only in its trailing Sources list are left out: that list already shows them. */
export function paperMentions(answer: string): PaperMention[] {
  let text = withoutTrailingSources(answer);
  if (new TextEncoder().encode(text).length > MAXIMUM_PARSED) text = new TextDecoder().decode(new TextEncoder().encode(text).slice(0, MAXIMUM_PARSED)).replace(/�$/, '');
  if (!/arxiv/i.test(text) && !text.includes('10.')) return [];
  type Found = { at: number; mention: PaperMention };
  const found: Found[] = [];
  for (const pattern of [ARXIV_LINK, ARXIV_NAME]) {
    for (const match of text.matchAll(pattern)) {
      const mention = arxivMention(match[1], match[2] ?? '', null);
      if (mention) found.push({ at: match.index!, mention });
    }
  }
  for (const match of text.matchAll(DOI)) {
    const doi = trimmedDOI(match[0]);
    if (doi.length < 8 || doi.length > 200) continue;
    const arxiv = ARXIV_DOI.exec(doi), viaArxiv = arxiv ? arxivMention(arxiv[1], '', null) : null;
    found.push({ at: match.index!, mention: viaArxiv ?? doiMention(doi, null) });
  }
  found.sort((a, b) => a.at - b.at);
  const links = [...text.matchAll(LINK)].map(m => ({ label: m[1], start: m.index! + m[0].indexOf('](') + 2, end: m.index! + m[0].length - 1 }));
  const lineStart = (at: number) => text.lastIndexOf('\n', at - 1) + 1;
  const lineAt = (at: number) => { const start = lineStart(at), end = text.indexOf('\n', at); return text.slice(start, end < 0 ? undefined : end + 1); };
  // How many distinct papers each line names: a line's leading title belongs to its only paper.
  const perLine = new Map<number, Set<string>>();
  for (const f of found) { const start = lineStart(f.at); perLine.set(start, (perLine.get(start) ?? new Set()).add(f.mention.id)); }
  const order: string[] = [], mentions = new Map<string, PaperMention>();
  for (const f of found) {
    let title: string | null = null;
    const link = links.find(l => f.at >= l.start && f.at < l.end);
    if (link) title = cleanTitle(link.label);
    if (title === null && perLine.get(lineStart(f.at))?.size === 1) title = leadingTitle(lineAt(f.at));
    const existing = mentions.get(f.mention.id);
    if (existing) { if (existing.title === null && title !== null) mentions.set(f.mention.id, { ...existing, title }); continue; }
    if (order.length >= MAXIMUM_MENTIONS) continue;
    order.push(f.mention.id); mentions.set(f.mention.id, { ...f.mention, title });
  }
  return order.map(id => mentions.get(id)!);
}
