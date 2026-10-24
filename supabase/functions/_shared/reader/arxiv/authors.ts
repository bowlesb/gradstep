// The paper's authors as a typeset header (arXiv converter component): names with their marks, then the
// affiliations, any address and the notes, each on its own line (ARXIV_CSS). Shared by LaTeXML's author block
// (`authorsBlock`) and the header read from a custom title page (front-matter.ts).
import { el, elements, normalizeSpace, outText, textContent, type DomNode, type OutNode } from '../html.ts';
import { block, bind, children, fold, has, type ArxivContext, type Child } from './context.ts';
import { equation } from './math.ts';
import { inline } from './inline.ts';

// The authors (LaTeXML `div.ltx_authors`), read as a typeset header rather than as LaTeXML prints it: each name
// once with its affiliation marks, then the affiliations, any address (a project page) and the notes the marks
// and daggers point to, each on its own line. Left out: duplicated marks and "footnotemark:" labels, "Affiliation:"
// contact labels, e-mail addresses. Authors whose affiliations come without marks (one "Affiliation:" each) get
// numbered marks in order. A name that was a graphic (a team logo) is replaced by the library's author metadata
// when the caller passes it (owner reports, 2026-10-14: "gross author presentation", "what is this Team business").
// Author text helpers, shared by LaTeXML's author block and a custom title page read into the header.
export const MARKS = /[\d,†‡*§¶‖]/g, LEADING_MARKS = /^[\d,†‡*§¶‖\s]+/;
export const EMAIL = /\{[^}]*\}@[\w.-]+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
export const plain = (parts: Child[]) => normalizeSpace(parts.map(part => typeof part === 'string' ? part : outText(part)).join(''));
export const isSup = (part: Child): part is OutNode & { name: 'sup' } => typeof part === 'object' && part.name === 'sup';
export const isBr = (part: Child) => typeof part === 'object' && part.name === 'br';
// Collapsed whitespace, no e-mail, no space around a mark, consecutive marks as one ("1,2"), tidy punctuation, no
// brackets left empty by what was left out ("Name (a@b.org)", an e-mail link or an icon; 2610.21306v1), trimmed ends.
export const tidy = (parts: Child[]): Child[] => {
  const out: Child[] = [];
  for (const part of parts) {
    if (typeof part === 'string') {
      const last = out[out.length - 1];
      const text = (isSup(last) ? part.trimStart() : part).replace(EMAIL, '').replace(/\s+/g, ' ');
      if (!text) continue;
      if (typeof last === 'string') out[out.length - 1] = (last + text).replace(/\s+/g, ' '); else out.push(text);
    } else if (isSup(part)) {
      if (!outText(part).trim()) continue; // a mark that was an icon (an envelope, 2610.12978)
      const last = out[out.length - 1];
      if (typeof last === 'string') { const trimmed = last.trimEnd(); if (trimmed) out[out.length - 1] = trimmed; else out.pop(); }
      const previous = out[out.length - 1];
      if (isSup(previous)) {
        const marks = [...new Set([...outText(previous).split(','), ...outText(part).split(',')].map(m => m.trim()).filter(Boolean))];
        previous.children = [marks.join(',')];
      } else out.push(part);
    } else if (part.name === 'br' || part.name === 'a') out.push(part);
    else {
      // An emphasis wrapper: tidied inside, and left out when nothing is left in it (a logo that was dropped).
      const inner = tidy(part.children);
      if (inner.length) out.push({ ...part, children: inner });
    }
  }
  for (let i = 0; i < out.length; i++) {
    const part = out[i];
    if (typeof part === 'string') out[i] = part.replace(/\s*[([]\s*(?:[,;]\s*)*[)\]]/g, '').replace(/\s+([.,;:])/g, '$1').replace(/:\s*\./g, '.').replace(/\.{2,}/g, '.').replace(/\s+/g, ' ');
  }
  if (typeof out[0] === 'string') { out[0] = out[0].trimStart(); if (!out[0]) out.shift(); }
  const last = out[out.length - 1];
  if (typeof last === 'string') { out[out.length - 1] = last.trimEnd().replace(/^[\s,;:]+/, ''); if (!out[out.length - 1]) out.pop(); }
  return out;
};
// An affiliation line ("²Stanford University ³CZ Biohub"): each mark starts an entry; entries read "a · b".
export const entries = (parts: Child[]): Child[][] => {
  const list: Child[][] = [];
  for (const part of parts) {
    if (isSup(part) || !list.length) list.push([]);
    list[list.length - 1].push(part);
  }
  return list.map(tidy).filter(entry => plain(entry).replace(MARKS, '').trim());
};
/** A run of names and affiliations without LaTeXML's creator structure (a tabular's cells, a custom title page,
 * 2610.10238 and 2610.14075): "Name<sup>1</sup>" is an author, "<sup>1</sup>Place" an affiliation, and a unit without
 * marks lists names ("A, B and C"). */
export const trimEdges = (unit: Child[]): Child[] => {
  const out = [...unit];
  if (typeof out[0] === 'string') { out[0] = out[0].replace(/^[\s,;:·]+/, ''); if (!out[0]) out.shift(); }
  const last = out[out.length - 1];
  if (typeof last === 'string') { out[out.length - 1] = last.replace(/[\s,;:·]+$/, ''); if (!out[out.length - 1]) out.pop(); }
  return out;
};
/** Emphasis around names and inside marks is left out (italic names in a title-page table, 1707.03017; italic
 * marks, 2610.18072): a name is plain text with plain marks. */
export const unwrap = (parts: Child[]): Child[] => parts.flatMap(part => typeof part === 'string' ? [part]
  : isSup(part) ? [el('sup', {}, [plain(part.children)])]
  : ['em', 'i', 'strong', 'b', 'u', 'span'].includes(part.name) ? unwrap(part.children) : [part]);
export const splitNames = (unit: Child[]): Child[][] => {
  if (unit.some(part => typeof part !== 'string')) return [unit];
  const text = plain(unit).replace(/^[A-Z][A-Za-z ]{1,30}:\s*/, '');
  return text.split(/\s*(?:,|;|\band\b|&)\s*/).map(name => name.trim()).filter(Boolean).map(name => [name]);
};
export const parseRun = (parts: Child[]): { names: Child[][]; affiliations: Child[][] } => {
  const names: Child[][] = [], affiliations: Child[][] = [];
  let current: Child[] = [], mode: 'name' | 'affiliation' | null = null;
  const flush = () => {
    const unit = trimEdges(tidy(current)); current = [];
    if (plain(unit).replace(MARKS, '').trim()) (mode === 'affiliation' ? affiliations : names).push(unit);
    mode = null;
  };
  // A mark right after a name's mark (two marks in a row: "Ethan Perez¹²" set as two `sup`, 1707.03017) is the same
  // name's, not an affiliation's start.
  let afterName = false;
  for (const part of parts) {
    if (isBr(part)) { flush(); afterName = false; continue; }
    if (isSup(part)) {
      if (mode === 'name') { current.push(part); flush(); afterName = true; continue; }
      if (mode === null && afterName && names.length) { names[names.length - 1] = tidy([...names[names.length - 1], part]); continue; }
      if (mode === 'affiliation') flush();
      current.push(part); mode = 'affiliation';
    } else { if (mode === null) mode = 'name'; current.push(part); }
    afterName = false;
  }
  flush();
  return { names: names.flatMap(unit => unit.some(isSup) ? [unit] : splitNames(unit)), affiliations };
};
/** The header's author paragraph: the names with their marks, then the affiliations and the notes each on its own
 * line in a smaller face (ARXIV_CSS; owner, build 42: "still ugly", "needs space after author section"). */
export const renderAuthors = (names: Child[][], affiliations: Child[][], addresses: Child[][], notes: { mark: string; body: Child[] }[]): Child[] => {
  const out: Child[] = [];
  names.forEach((name, index) => { if (index) out.push(', '); out.push(...name); });
  const lines = (units: Child[][]): Child[] => units.flatMap((unit, index) => index ? [el('br'), ...unit] : unit);
  if (affiliations.length || addresses.length) out.push(' ', el('span', { class: 'reader-affiliations' }, lines([...affiliations, ...addresses])));
  if (notes.length) out.push(' ', el('span', { class: 'reader-notes' }, lines(notes.map(note => note.mark ? [el('sup', {}, [note.mark]), ' ', ...note.body] : note.body))));
  return out;
};

export function authorsBlock(cx: ArxivContext, n: DomNode): OutNode {
  return block(cx, n, 'p', 'paragraph', id => {
    for (const e of elements(n, () => true)) bind(cx, e, id);
    const INLINE = ['em', 'i', 'strong', 'b', 'u', 's', 'sub', 'sup', 'code'];
    const MARK_SYMBOLS: Record<string, string> = { '†': '†', '‡': '‡', '*': '*', '∗': '*', '⋆': '*', '§': '§', '¶': '¶', '‖': '‖' };
    const mathText = (m: DomNode): string => m.type === 'text' ? m.data : m.type !== 'tag' || ['annotation', 'annotation-xml'].includes(m.name) ? '' : children(m).map(mathText).join('').trim();
    const notes: { mark: string; body: Child[] }[] = [], seenNotes = new Set<string>();
    const addresses: Child[][] = [], seenAddresses = new Set<string>();
    const bracketed = (c: DomNode): boolean => {
      const siblings = c.parent ? children(c.parent) : [], at = siblings.indexOf(c);
      return at >= 0 && /[([]$/.test(siblings.slice(0, at).map(textContent).join('').trimEnd()) && /^[)\]]/.test(siblings.slice(at + 1).map(textContent).join('').trimStart());
    };
    const drop = (c: DomNode): Child[] => { for (const m of elements(c, x => x.name === 'math')) cx.skippedMath.add(m); return []; };
    const walk = (c: DomNode): Child[] => {
      if (c.type === 'text') return [c.data];
      if (c.type !== 'tag') return [];
      if (c.name === 'math') {
        // A mark set as math ($\dagger$ beside a name, 2610.12978) is its symbol; an equation span has no text.
        const symbol = MARK_SYMBOLS[mathText(c)]; if (symbol) { drop(c); return [symbol]; }
        return [equation(cx, c, id)];
      }
      if (['svg', 'img', 'object'].includes(c.name)) { cx.omittedGraphics += 1; return drop(c); }
      if (has(c, 'ltx_note')) {
        const first = elements(c, x => has(x, 'ltx_note_mark'))[0];
        const mark = first ? normalizeSpace(textContent(first)) : '';
        const content = elements(c, x => has(x, 'ltx_note_content'))[0];
        const body: Child[] = [];
        for (const x of content ? children(content) : []) {
          if (x.type === 'tag' && (has(x, 'ltx_note_mark') || has(x, 'ltx_note_type') || has(x, 'ltx_tag'))) drop(x); else body.push(...walk(x));
        }
        const text = plain(tidy(body));
        if (text && !seenNotes.has(mark + '\u0000' + text)) { seenNotes.add(mark + '\u0000' + text); notes.push({ mark, body: tidy(body) }); }
        return mark ? [el('sup', {}, [mark])] : [];
      }
      if (has(c, 'ltx_contact_name') || has(c, 'ltx_role_email')) return drop(c);
      if (c.name === 'a') {
        const href = c.attribs?.href ?? '';
        if (/^mailto:/i.test(href)) return drop(c);
        const rendered = inline(cx, c, id);
        // A web address on its own (a project page) gets its own line, once, and none when its words were a dropped
        // icon (an ORCID badge, 2610.19857v1: empty lines); one in brackets belongs to the words around it
        // ("Zhejiang University (zju.edu.cn)", 2610.21306v1, whose eight authors each left "()" behind).
        if (/^https?:/i.test(href) && !bracketed(c)) {
          const key = plain(rendered);
          if (key && !seenAddresses.has(href + '\u0000' + key)) { seenAddresses.add(href + '\u0000' + key); addresses.push(rendered); }
          return [];
        }
        return rendered;
      }
      if (has(c, 'ltx_author_before') || has(c, 'ltx_author_after')) return [' '];
      if (c.name === 'br') return [el('br')];
      // A mark is its text (a template's italic "1,2" is no emphasis, 2610.10238); the block has one face, so
      // bold or italic wrappers around names are left out.
      if (c.name === 'sup') { const text = plain(children(c).flatMap(walk)); return text ? [el('sup', {}, [text])] : []; }
      // An author block set as a table (2610.10238): a row is a line, a cell is a unit.
      if (has(c, 'ltx_tr')) return [...children(c).flatMap(walk), el('br')];
      if (has(c, 'ltx_td') || has(c, 'ltx_th')) return [...children(c).flatMap(walk), ' '];
      const name = INLINE.includes(c.name) ? c.name : null;
      const result = children(c).flatMap(walk);
      return name ? [el(name, {}, result)] : result;
    };
    const affiliations = new Map<string, Child[]>();
    const addAffiliations = (parts: Child[]): string[] => {
      const keys: string[] = [];
      for (const entry of entries(parts)) {
        const key = plain(entry).replace(LEADING_MARKS, '').toLowerCase();
        if (!key) continue;
        if (!affiliations.has(key)) affiliations.set(key, entry);
        keys.push(key);
      }
      return keys;
    };
    const creators: { name: Child[]; keys: string[]; lost: boolean }[] = [];
    for (const creator of elements(n, c => has(c, 'ltx_creator'))) {
      const person = elements(creator, c => has(c, 'ltx_personname'))[0];
      const graphicsBefore = cx.omittedGraphics;
      const parts = walk(person ?? creator);
      const lost = cx.omittedGraphics > graphicsBefore;
      // Lines after the name (LaTeXML's `\\` in an author block) are that author's affiliations.
      const cut = parts.findIndex(isBr);
      const head = tidy(cut >= 0 ? parts.slice(0, cut) : parts);
      const startsWithMark = isSup(head[0]);
      const text = plain(head).replace(LEADING_MARKS, '');
      const keys: string[] = [];
      let name: Child[] | null = null;
      if (text && !startsWithMark) name = head; else if (text) keys.push(...addAffiliations(head));
      // A name run together with its affiliations (no mark or break between them: "Jiantao Jiao NVIDIA University of
      // Minnesota – Twin Cities University of California, Berkeley", 2610.10478): the library's name is the name and
      // the rest one affiliation, before any comma could split the rest into names.
      if (name && cx.metadataAuthors.length) {
        const words = normalizeSpace(name.filter(part => typeof part === 'string').join(' '));
        const match = cx.metadataAuthors.some(a => fold(a) === fold(words)) ? null
          : cx.metadataAuthors.find(a => fold(words).startsWith(fold(a) + ' '));
        const rest = match ? normalizeSpace(words.slice(words.toLowerCase().indexOf(match.toLowerCase()) + match.length)).replace(/^[\s,;:–-]+/, '') : '';
        if (match && rest.length >= 3) { name = [match, ...name.filter(isSup)]; keys.push(...addAffiliations([rest])); }
      }
      // Several authors in one creator (a tabular's cells, names run together with their marks): each is one.
      const more: Child[][] = [];
      if (name) {
        const run = parseRun(name);
        if (run.names.length >= 2) {
          for (const unit of run.affiliations) keys.push(...addAffiliations(unit));
          more.push(...run.names.slice(1)); name = run.names[0];
        }
      }
      if (cut >= 0) {
        // Lines after the first: more authors when they carry marks ("Heyuan Deng⁴ Fei Mi⁴,‡", 2610.18683),
        // otherwise that author's affiliations (LaTeXML's `\\` under a name).
        const rest = parseRun(parts.slice(cut + 1));
        for (const unit of rest.names) { if (unit.some(isSup) && name) more.push(unit); else keys.push(...addAffiliations(unit)); }
        for (const unit of rest.affiliations) keys.push(...addAffiliations(unit));
      }
      for (const extra of person ? children(creator).filter(c => c !== person) : []) {
        // A note beside the name (a dagger for equal contribution) marks the name; anything else is an affiliation.
        const marksOnly = extra.type === 'tag' && (has(extra, 'ltx_note')
          || (elements(extra, x => has(x, 'ltx_note')).length > 0 && !normalizeSpace(textContent(extra).replace(MARKS, '')).length));
        const rendered = walk(extra);
        if (marksOnly && name) name = tidy([...name, ...rendered]); else keys.push(...addAffiliations(rendered));
      }
      if (name || lost) creators.push({ name: name ?? [], keys: [...new Set(keys)], lost });
      for (const unit of more) creators.push({ name: unit, keys: [], lost: false });
    }
    // A title page read by macro (templatePreamble): its affiliations and contribution notes belong here.
    for (const entry of cx.templateAffiliations.splice(0)) addAffiliations([el('sup', {}, [entry.mark]), entry.text]);
    for (const note of cx.templateNotes.splice(0)) {
      if (!seenNotes.has(note.mark + '\u0000' + note.text)) { seenNotes.add(note.mark + '\u0000' + note.text); notes.push({ mark: note.mark, body: [note.text] }); }
    }
    // An affiliation that is only punctuation (a template's "[", 2610.18356) says nothing.
    for (const [key, entry] of [...affiliations]) if (!/[\p{L}\p{N}]/u.test(plain(entry).replace(LEADING_MARKS, ''))) affiliations.delete(key);
    for (const [key, entry] of [...affiliations]) {
      const words = plain(entry).replace(LEADING_MARKS, '');
      if (!/^(corresponding author|equal contribution|contributed equally|project lead)/i.test(words)) continue;
      const mark = /^[\s]*([†‡*∗§¶‖])/.exec(plain(entry))?.[1] ?? '';
      notes.push({ mark, body: [words.replace(/[\s,;:]+$/, '')] }); affiliations.delete(key);
    }
    for (const c of creators) c.keys = c.keys.filter(key => affiliations.has(key));
    const named = creators.filter(c => c.name.length);
    // A name that was a graphic, or no name at all: the library's author metadata names them.
    const useMetadata = cx.metadataAuthors.length > 0 && (creators.some(c => c.lost) || !named.length);
    const affiliationMarked = named.some(c => c.name.some(part => isSup(part) && /\d/.test(outText(part))));
    if (!useMetadata && !affiliationMarked && affiliations.size >= 2 && named.some(c => c.keys.length)) {
      const numbers = new Map([...affiliations.keys()].map((key, index) => [key, String(index + 1)]));
      for (const c of named) {
        const marks = c.keys.map(key => numbers.get(key)).filter((m): m is string => !!m);
        if (marks.length) c.name = tidy([...c.name, el('sup', {}, [marks.join(',')])]);
      }
      for (const [key, entry] of affiliations) affiliations.set(key, tidy([el('sup', {}, [numbers.get(key)!]), ...entry]));
    }
    const out = renderAuthors(useMetadata ? [[cx.metadataAuthors.join(', ')]] : named.map(c => c.name), [...affiliations.values()], addresses, notes);
    if (out.length) return out;
    // Nothing recognisable: the block's own words, with any math inside counted as left out.
    for (const m of elements(n, x => x.name === 'math')) if (!cx.usedMath.has(m)) cx.skippedMath.add(m);
    return [normalizeSpace(textContent(n))];
  }, { class: 'reader-authors' });
}
