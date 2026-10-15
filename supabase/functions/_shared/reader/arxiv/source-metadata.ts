// A paper's library metadata read from the arXiv HTML a device already downloaded to prepare it (device code; docs/
// architecture/ARXIV_DEVICE_ONLY.md §5.2–5.3): zero extra requests to arXiv. LaTeXML's page carries the title
// (`h1.ltx_title_document`), the authors (`.ltx_creator.ltx_role_author .ltx_personname`), the abstract
// (`.ltx_abstract`), and arXiv's infobox: the exact version's licence (`#license-tr`) and the watermark
// (`arXiv:2305.18290v3 [cs.LG] 29 Jul 2024`) with the version, primary category and date. Built into its own small
// bundle (arxiv-source-metadata.js), never into the reader compiler, so preparing a paper is unchanged.
import { classes, elements, parseHTML, type DomNode } from '../html.ts';
import { isArxivCategory, licenseFromLabel, SOURCE_METADATA_FORMAT, SourceMetadataError, validateSourceMetadata, type SourceMetadata } from '../../source-metadata.ts';

const has = (node: DomNode, name: string) => classes(node).includes(name);
const SKIP = new Set(['script', 'style', 'annotation', 'annotation-xml', 'img', 'svg', 'object', 'button']);
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/** Readable text of a node: line breaks as spaces, footnotes and marks left out, math as its LaTeX in $…$. */
function readable(node: DomNode, out: string[] = []): string[] {
  if (node.type === 'text') { out.push(node.data); return out; }
  if (node.type !== 'tag' || SKIP.has(node.name) || has(node, 'ltx_note') || has(node, 'ltx_tag')) return out;
  if (node.name === 'br') { out.push(' '); return out; }
  if (node.name === 'math') {
    const tex = node.attribs?.alttext?.trim();
    if (tex) out.push(`$${tex}$`);
    return out;
  }
  for (const child of node.children ?? []) readable(child, out);
  return out;
}
const flat = (value: string) => value.replace(/\s+/g, ' ').trim();

/** The text of a person name up to its first line break (what follows is an affiliation, an address or an e-mail). */
// A mark (`sup`) separates names ("Shun Zou¹ Ziyu Ma²"); source line breaks are kept so a line naming an institution
// can be left out whole ("NVIDIA University of Minnesota – Twin Cities University of California, Berkeley").
const SEPARATOR = '\u0001';
function nameLine(node: DomNode): string {
  const parts: string[] = [];
  let stopped = false;
  const some = () => parts.join('').replaceAll(SEPARATOR, '').trim().length > 0;
  const visit = (n: DomNode) => {
    if (stopped) return;
    if (n.type === 'text') { parts.push(n.data); return; }
    if (n.type !== 'tag' || SKIP.has(n.name) || n.name === 'math' || has(n, 'ltx_note')
      || has(n, 'ltx_role_affiliation') || has(n, 'ltx_role_address') || has(n, 'ltx_contact') || has(n, 'ltx_role_email')) return;
    if (n.name === 'sup') { parts.push(SEPARATOR); return; }
    if (n.name === 'br') { if (some()) stopped = true; return; }
    if (n.name === 'a' && /^mailto:/i.test(n.attribs?.href ?? '')) return;
    for (const child of n.children ?? []) visit(child);
  };
  for (const child of node.children ?? []) visit(child);
  return parts.join('');
}

const AFFILIATION = /\b(universit|institut|laborator|lab\b|department|school|college|inc\b|corp|research|centre|center|academy|google|microsoft|meta\b|deepmind|openai|anthropic|nvidia|ltd|gmbh|hospital)/i;
// Footnote legends LaTeXML leaves inside the name, and title-page placeholders that are no one's name.
const NOT_A_NAME = /\b(equal(?:ly)? contribut|contributed equally|corresponding|project lead|work (?:was )?done|core contributor|first author|technical report|internship|these authors|homepage|github|\w*ject page)/i;
const PLACEHOLDER = /^(?:team|report|authors?|and|et al\.?|affiliation:?|contact:?|data|model|code|paper|project|page|website|demo|dataset|huggingface)$/i;
/** Names in one person-name line ("A, B and C", or separated by marks or runs of spaces), without marks, e-mails or
 * affiliation fragments. */
export function splitAuthorLine(line: string): string[] {
  // A line that starts with a mark ("²AMAP, Alibaba Group") numbers an affiliation.
  const kept = line.split('\n').filter(part => !part.trimStart().startsWith(SEPARATOR) && !AFFILIATION.test(part) && !/@/.test(part)).join(SEPARATOR);
  const cleaned = kept.replace(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, ' ').replace(/[†‡*∗⋆§¶‖♠♣♢♡♯♭]+/g, ' ');
  return cleaned.split(/\u0001|\s*[,;&]\s*|\s+and\s+|\s{2,}/).map(name => name.replace(/\s+/g, ' ').replace(/^[\d\s,.]+|[\d\s,]+$/g, '').trim())
    .filter(name => /\p{L}/u.test(name) && [...name].length <= 256 && !AFFILIATION.test(name) && !NOT_A_NAME.test(name)
      && !PLACEHOLDER.test(name) && name.split(' ').length <= 8);
}

/** A "person" whose first content is a footnote mark is an affiliation LaTeXML set as an author ("²Stanford University
 * ³CZ Biohub", 2305.18290). */
function startsWithMark(node: DomNode): boolean {
  let verdict: boolean | null = null;
  const visit = (n: DomNode) => {
    if (verdict !== null) return;
    if (n.type === 'text') { if (n.data.trim()) verdict = false; return; }
    if (n.type !== 'tag') return;
    if (n.name === 'sup' || has(n, 'ltx_note')) { verdict = true; return; }
    for (const child of n.children ?? []) visit(child);
  };
  for (const child of node.children ?? []) visit(child);
  return verdict === true;
}

export function extractAuthors(root: DomNode): string[] {
  const creators = elements(root, n => has(n, 'ltx_creator') && has(n, 'ltx_role_author'));
  const personNames = creators.length
    ? creators.flatMap(c => elements(c, n => has(n, 'ltx_personname')).slice(0, 1))
    : elements(root, n => has(n, 'ltx_personname'));
  const names: string[] = [];
  for (const person of personNames) {
    if (startsWithMark(person)) continue;
    for (const name of splitAuthorLine(nameLine(person))) if (!names.includes(name)) names.push(name);
  }
  return names.slice(0, 512);
}

/** "arXiv:2305.18290v3 [cs.LG] 29 Jul 2024" → its identifier, version, primary category and date. */
export function parseWatermark(text: string): { sourceID: string; revision: number; category: string | null; date: string | null } | null {
  const m = /arXiv:([0-9]{4}\.[0-9]{4,5}|[a-z-]+(?:\.[A-Z]{2})?\/[0-9]{7})v([1-9][0-9]{0,3})\s*(?:\[([^\]]+)\])?\s*([0-9]{1,2})\s+([A-Za-z]{3})[a-z]*\s+([0-9]{4})/.exec(text.replace(/\s+/g, ' '));
  if (!m) return null;
  const month = MONTHS.indexOf(m[5].toLowerCase());
  const date = month < 0 ? null : `${m[6]}-${String(month + 1).padStart(2, '0')}-${m[4].padStart(2, '0')}`;
  return { sourceID: m[1], revision: Number(m[2]), category: m[3] && isArxivCategory(m[3]) ? m[3] : null, date };
}

/** The record from the export API's Atom answer for exactly `sourceID` version `revision` (the native fallback for a
 * paper without HTML, §5.2: one request, made by the device). Categories are arXiv's, primary first; the licence is
 * not in the Atom feed, so it stays unknown. Null when the answer is not that version. */
export function sourceMetadataFromAtom(xml: string, sourceID: string, revision: number, now = new Date()):
  { metadata: SourceMetadata; flags: string[] } | null {
  const root = parseHTML(xml, true);
  const entries = elements(root, n => n.name === 'entry');
  if (entries.length !== 1) return null;
  const entry = entries[0];
  const child = (name: string) => (entry.children ?? []).filter(n => n.type === 'tag' && n.name === name);
  const text = (node: DomNode | undefined) => node ? flat(readable(node).join('')) : '';
  const id = /arxiv\.org\/abs\/(.+)v([1-9][0-9]{0,3})$/.exec(text(child('id')[0]));
  if (!id || id[1] !== sourceID || Number(id[2]) !== revision) return null;
  const authors = child('author').map(a => text((a.children ?? []).find(n => n.type === 'tag' && n.name === 'name'))).filter(Boolean);
  const primary = elements(entry, n => n.name === 'arxiv:primary_category')[0]?.attribs?.term;
  const categories = [...new Set([primary, ...child('category').map(c => c.attribs?.term)].filter((c): c is string => typeof c === 'string' && isArxivCategory(c)))];
  const updated = /^([0-9]{4}-[0-9]{2}-[0-9]{2})T/.exec(text(child('updated')[0]))?.[1] ?? null;
  const summary = text(child('summary')[0]);
  if (!text(child('title')[0]) || !authors.length) return null;
  try {
    return validateSourceMetadata({ format: SOURCE_METADATA_FORMAT, source_id: sourceID, revision, origin: 'arxiv_api',
      title: [...text(child('title')[0])].slice(0, 2000).join(''), authors: authors.slice(0, 512).map(a => [...a].slice(0, 256).join('')),
      abstract: summary ? [...summary].slice(0, 24_000).join('') : null, categories: categories.slice(0, 64), license_uri: null,
      version_date: updated, html_available: false, observed_at: now.toISOString() }, { sourceID, revision }, now);
  } catch (error) {
    if (error instanceof SourceMetadataError) return null;
    throw error;
  }
}

/** The record for `sourceID` version `revision` read from its page, or null when the page doesn't give what a library
 * entry needs (a title and at least one author) or isn't that version. A page without arXiv's infobox still gives a
 * record, with its licence, date and category unknown. */
export function extractSourceMetadata(html: string, sourceID: string, revision: number, now = new Date()):
  { metadata: SourceMetadata; flags: string[] } | null {
  const root = parseHTML(html);
  const byID = (id: string) => elements(root, n => n.attribs?.id === id)[0];
  const watermarkNode = byID('watermark-tr');
  const watermark = watermarkNode ? parseWatermark(readable(watermarkNode).join('')) : null;
  if (watermark && (watermark.sourceID !== sourceID || watermark.revision !== revision)) return null;
  const heading = elements(root, n => n.name === 'h1' && has(n, 'ltx_title_document'))[0];
  const titleNode = heading ?? elements(root, n => n.name === 'title')[0];
  const title = titleNode ? flat(readable(titleNode).join('')) : '';
  const authors = extractAuthors(root);
  const abstractNode = elements(root, n => has(n, 'ltx_abstract'))[0];
  const paragraphs = abstractNode ? elements(abstractNode, n => n.name === 'p').map(p => flat(readable(p).join(''))).filter(Boolean) : [];
  const abstract = paragraphs.length ? paragraphs.join('\n\n') : abstractNode ? flat(readable(abstractNode).join('').replace(/^\s*Abstract\s*/i, '')) || null : null;
  const licenseNode = byID('license-tr');
  if (!title || !authors.length) return null;
  try {
    return validateSourceMetadata({ format: SOURCE_METADATA_FORMAT, source_id: sourceID, revision, origin: 'arxiv_html', title: [...title].slice(0, 2000).join(''),
      authors: authors.map(a => [...a].slice(0, 256).join('')), abstract: abstract ? [...abstract].slice(0, 24_000).join('') : null,
      categories: watermark?.category ? [watermark.category] : [], license_uri: licenseNode ? licenseFromLabel(readable(licenseNode).join('')) : null,
      version_date: watermark?.date ?? null, html_available: true, observed_at: now.toISOString() }, { sourceID, revision }, now);
  } catch (error) {
    if (error instanceof SourceMetadataError) return null;
    throw error;
  }
}
