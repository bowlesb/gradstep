// Starter questions for an empty chat (docs/architecture/CHAT.md, chat redesign 2026-10-16; owner, build 57: "a list of
// good ones, not always the same boring ones"). Chosen on the device from the shared pool (chat-starters.json): three
// different categories, at least one about this paper's own structure when it has any, drawn afresh for each new chat
// from its seed. The native app implements the same selection (ChatStarters.swift); both test against
// tests/fixtures/chat-starters-cases.json, so a seed gives the same three questions everywhere.
import pool from './chat-starters.json';

export interface StarterPaper { figures: string[]; tables: string[]; equations: number; headings: string[] }
export interface Starter { category: string; icon: string; text: string }

/** mulberry32: a small 32-bit generator both clients can reproduce exactly. */
export function starterRandom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a) >>> 0;
    t = ((t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t) >>> 0;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const SKIPPED = /^(abstract|introduction|related work|related works|background|preliminar|notation|problem (setup|setting|formulation|statement)|experiment|results|evaluation|discussion|conclusion|limitation|future work|appendix|references|bibliography|acknowledg|broader impact|ethic|summary)/i;
const GENERIC = /^(method|methods|methodology|approach|our approach|proposed method|the proposed method|model|our method|framework)$/i;

/** The paper's method section: the first numbered top-level heading that isn't front or back matter, without its
 * number; null when there is none or its name is generic ("Method"). */
export function methodHeading(headings: string[]): string | null {
  for (const raw of headings) {
    const m = /^\s*(?:\d+|[IVX]+)\.?\s+(.+?)\s*$/.exec(raw);
    if (!m) continue;
    const title = m[1];
    if (/^\d/.test(title) || SKIPPED.test(title)) continue;
    if (GENERIC.test(title) || title.length > 60) return null;
    return title;
  }
  return null;
}

/** "Figure 2: …" → "2"; the figures or tables a caption list names, in order, unique, the first eight. */
export function captionNumbers(captions: string[], word: 'Figure' | 'Table'): string[] {
  const pattern = word === 'Figure' ? /^\s*(?:Figure|Fig\.)\s*(\d{1,3})\b/i : /^\s*Table\s*(\d{1,3})\b/i;
  const out: string[] = [];
  for (const caption of captions) {
    const m = pattern.exec(caption);
    if (m && !out.includes(m[1])) out.push(m[1]);
    if (out.length === 8) break;
  }
  return out;
}

const STRUCTURE = ['method', 'figure', 'equation', 'table'];

export function chooseStarters(paper: StarterPaper | null, seed: number): Starter[] {
  const random = starterRandom(seed), pick = (n: number) => Math.floor(random() * n);
  if (!paper) {
    const left = [...pool.general], out: Starter[] = [];
    while (out.length < 3 && left.length) { const [g] = left.splice(pick(left.length), 1); out.push({ category: 'general', icon: g.icon, text: g.text }); }
    return out;
  }
  const method = methodHeading(paper.headings);
  const usable = (category: string, templates: string[]) => templates.filter(t =>
    (!t.includes('{figure}') || paper.figures.length > 0) && (!t.includes('{table}') || paper.tables.length > 0)
    && (!t.includes('{method}') || method !== null) && (category !== 'equation' || paper.equations > 0)
    && (category !== 'figure' || paper.figures.length > 0) && (category !== 'table' || paper.tables.length > 0));
  const categories = pool.paper.map(c => ({ ...c, usable: usable(c.category, c.templates) })).filter(c => c.usable.length > 0);
  const structural = categories.filter(c => STRUCTURE.includes(c.category) && (c.category !== 'method' || method !== null));
  const chosen: typeof categories = [];
  if (structural.length) chosen.push(structural[pick(structural.length)]);
  const rest = categories.filter(c => !chosen.includes(c));
  while (chosen.length < 3 && rest.length) chosen.push(rest.splice(pick(rest.length), 1)[0]);
  return chosen.map(c => {
    let text = c.usable[pick(c.usable.length)];
    if (text.includes('{figure}')) text = text.replace('{figure}', paper.figures[pick(paper.figures.length)]);
    if (text.includes('{table}')) text = text.replace('{table}', paper.tables[pick(paper.tables.length)]);
    if (text.includes('{method}')) text = text.replace('{method}', method!);
    return { category: c.category, icon: c.icon, text };
  });
}
