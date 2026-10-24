// Term rankings for public papers and map nodes (docs/architecture/INTEREST_INDEX.md §3), as
// tools/interest-eval/terms.py and topic_map.label_nodes:
// - conceptness: cos(phrase, mean fingerprint of the papers using it) − cos(phrase, corpus mean);
// - paperCandidates / finishPaperTerms: sublinear TF-IDF (IDF from the corpus, n-grams × 1.25), the top 40 re-ranked by closeness of the phrase
//   to the paper, then the concept filter and de-duplication (substring, or phrase cos > 0.88);
// - nodeTerms: class-based TF-IDF over a level's nodes, weighted by the square root of the share of the node's papers
//   using the phrase, de-duplicated by substring.
import { DIM } from './codec.ts';
import { documentText, ngrams, tokens, type Vocabulary } from './ngrams.ts';

export const MIN_CONCEPT = 0.02;
const DUP_COS = 0.88;

function dotv(a: Float32Array, b: Float32Array, bo = 0): number {
  let s = 0;
  for (let i = 0; i < DIM; i++) s += a[i] * b[bo + i];
  return s;
}

/** Conceptness for every vocabulary phrase; `termVec(t)` is the phrase's unit embedding. Chunked to bound memory. */
export function conceptness(vocab: Vocabulary, E: Float32Array, termVec: (t: number) => Float32Array, chunk = 20_000): Float32Array {
  const V = vocab.terms.length, out = new Float32Array(V);
  const g = new Float32Array(DIM);
  for (let d = 0; d < vocab.docs; d++) for (let i = 0; i < DIM; i++) g[i] += E[d * DIM + i];
  let gn = 0; for (let i = 0; i < DIM; i++) gn += g[i] * g[i]; gn = Math.sqrt(gn) || 1;
  for (let i = 0; i < DIM; i++) g[i] /= gn;
  for (let start = 0; start < V; start += chunk) {
    const end = Math.min(V, start + chunk), S = new Float32Array((end - start) * DIM);
    for (let d = 0; d < vocab.docs; d++) {
      const { ids } = vocab.docTerms[d];
      for (let j = 0; j < ids.length; j++) {
        const t = ids[j];
        if (t < start || t >= end) continue;
        const o = (t - start) * DIM, eo = d * DIM;
        for (let i = 0; i < DIM; i++) S[o + i] += E[eo + i];
      }
    }
    for (let t = start; t < end; t++) {
      const o = (t - start) * DIM;
      let n = 0; for (let i = 0; i < DIM; i++) n += S[o + i] ** 2; n = Math.sqrt(n) || 1;
      const v = termVec(t);
      out[t] = dotv(v, S, o) / n - dotv(v, g);
    }
  }
  return out;
}

export interface TermInfo { df: number; conceptness: number }

/**
 * A paper's top 40 candidate phrases by sublinear TF-IDF (terms.py paper_terms, first half): phrases of its title
 * (twice) and abstract that the term statistics hold, IDF from the corpus of `documents` papers, n-grams x 1.25.
 */
export function paperCandidates(title: string, abstract: string, lookup: (term: string) => TermInfo | undefined, documents: number): [string, number][] {
  const counts = new Map<string, number>();
  for (const g of ngrams(tokens(documentText(title, abstract)))) counts.set(g, (counts.get(g) ?? 0) + 1);
  const scored: [string, number][] = [];
  for (const [term, c] of counts) {
    const info = lookup(term);
    if (!info) continue;
    scored.push([term, (1 + Math.log(c)) * (Math.log((1 + documents) / (1 + info.df)) + 1) * (term.includes(' ') ? 1.25 : 1)]);
  }
  scored.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  return scored.slice(0, 40);
}

/**
 * Second half: re-rank by closeness of each phrase to the paper (2 x deviation from the mean), then keep concepts,
 * skip substrings of a kept phrase and near-duplicates (phrase cos > 0.88). Phrases without a vector are skipped.
 */
export function finishPaperTerms(candidates: [string, number][], paper: Float32Array, vec: (term: string) => Float32Array | undefined,
  lookup: (term: string) => TermInfo | undefined, k = 5, minConcept = MIN_CONCEPT): string[] {
  const usable = candidates.filter(([t]) => vec(t));
  if (!usable.length) return [];
  const max = usable[0][1];
  const close = usable.map(([t]) => dotv(vec(t)!, paper));
  const mean = close.reduce((s, x) => s + x, 0) / close.length;
  const order = usable.map(([t, w], i) => [t, w / max + 2 * (close[i] - mean)] as [string, number])
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  const picked: string[] = [];
  for (const [t] of order) {
    if ((lookup(t)?.conceptness ?? -1) < minConcept) continue;
    if (picked.some(p => t.includes(p) || p.includes(t))) continue;
    const v = vec(t)!;
    if (picked.some(p => dotv(v, vec(p)!) > DUP_COS)) continue;
    picked.push(t);
    if (picked.length === k) break;
  }
  return picked;
}

/** Class-based TF-IDF terms for each class (a list of document rows), over one level's classes. */
export function nodeTerms(vocab: Vocabulary, classes: number[][], k: number, eligible?: (t: number) => boolean): string[][] {
  const perClass = classes.map(rows => {
    const count = new Map<number, number>(), docs = new Map<number, number>();
    let total = 0;
    for (const d of rows) {
      const { ids, counts } = vocab.docTerms[d];
      for (let j = 0; j < ids.length; j++) {
        if (eligible && !eligible(ids[j])) continue;
        count.set(ids[j], (count.get(ids[j]) ?? 0) + counts[j]);
        docs.set(ids[j], (docs.get(ids[j]) ?? 0) + 1);
        total += counts[j];
      }
    }
    return { count, docs, total, size: rows.length };
  });
  const colsum = new Map<number, number>();
  for (const c of perClass) for (const [t, x] of c.count) colsum.set(t, (colsum.get(t) ?? 0) + x);
  const A = perClass.reduce((s, c) => s + c.total, 0) / Math.max(1, perClass.length);
  return perClass.map(c => {
    const weights: [number, number][] = [];
    for (const [t, x] of c.count) {
      const tf = x / Math.max(1, c.total), idf = Math.log(1 + A / Math.max(1, colsum.get(t)!));
      weights.push([t, tf * idf * Math.sqrt(Math.min(1, c.docs.get(t)! / Math.max(1, c.size)))]);
    }
    weights.sort((a, b) => b[1] - a[1] || a[0] - b[0]);
    const out: string[] = [];
    for (const [t] of weights.slice(0, 40)) {
      const phrase = vocab.terms[t];
      if (out.some(p => p.includes(phrase) || phrase.includes(p))) continue;
      out.push(phrase);
      if (out.length === k) break;
    }
    return out;
  });
}
