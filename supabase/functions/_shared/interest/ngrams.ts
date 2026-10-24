// Phrase counting with scikit-learn CountVectorizer semantics (docs/architecture/INTEREST_INDEX.md §3), as
// tools/interest-eval/terms.py: the text is the title twice then the abstract; lowercase; tokens match
// `(?u)\b[a-zA-Z][a-zA-Z0-9\-]+\b` (Python's Unicode word boundaries); stop words are removed before n-grams are formed;
// 1–3-grams; a phrase is kept when min_df <= document frequency <= max_df_share × documents.
//
// Counting is apriori-pruned so memory stays bounded at 100k papers: a bigram is counted only when both its words reach
// min_df, a trigram only when both its bigrams do (a phrase is never in more papers than its parts).
import { STOP_WORDS } from './stopwords.ts';

const WORD = '[\\p{L}\\p{N}_]';
// Python's \b: a word character on exactly one side.
const BOUNDARY = `(?:(?<=${WORD})(?!${WORD})|(?<!${WORD})(?=${WORD}))`;
const TOKEN = new RegExp(`${BOUNDARY}[a-zA-Z][a-zA-Z0-9\\-]+${BOUNDARY}`, 'gu');
const STOP = new Set(STOP_WORDS);

export function documentText(title: string, abstract: string): string {
  return `${title}. ${title}. ${abstract}`;
}

/** Tokens after lowercasing and stop-word removal. */
export function tokens(text: string): string[] {
  const out: string[] = [];
  for (const m of text.toLowerCase().matchAll(TOKEN)) if (!STOP.has(m[0])) out.push(m[0]);
  return out;
}

/** Every 1–3-gram of a token list (with repeats), in scikit-learn's order. */
export function ngrams(words: string[]): string[] {
  const out = [...words];
  for (let n = 2; n <= 3; n++) for (let i = 0; i + n <= words.length; i++) out.push(words.slice(i, i + n).join(' '));
  return out;
}

export interface Vocabulary {
  terms: string[];          // phrase per term index
  df: Int32Array;           // document frequency per term
  ngram: Uint8Array;        // 1, 2 or 3
  docs: number;             // documents counted
  /** Per document: term indices and counts (parallel arrays), term indices ascending. */
  docTerms: { ids: Int32Array; counts: Int32Array }[];
}

/** Counts the corpus's phrases. `maxDfShare` caps document frequency at share × documents (a float, as sklearn). */
export function countVocabulary(texts: string[], minDf: number, maxDfShare: number): Vocabulary {
  const n = texts.length;
  const wordId = new Map<string, number>();
  const words: string[] = [];
  const docWords: Int32Array[] = new Array(n);
  const wordDf: number[] = [];
  for (let d = 0; d < n; d++) {
    const ids = tokens(texts[d]).map(w => {
      let id = wordId.get(w);
      if (id === undefined) { id = words.length; wordId.set(w, id); words.push(w); wordDf.push(0); }
      return id;
    });
    docWords[d] = Int32Array.from(ids);
    for (const id of new Set(ids)) wordDf[id]++;
  }
  const keepWord = (id: number) => wordDf[id] >= minDf;
  const W = 2 ** 21;
  if (words.length >= W) throw new Error('interest_vocabulary_too_large');
  // Bigrams of frequent words.
  const bigramDf = new Map<number, number>();
  for (const doc of docWords) {
    const seen = new Set<number>();
    for (let i = 0; i + 1 < doc.length; i++) if (keepWord(doc[i]) && keepWord(doc[i + 1])) seen.add(doc[i] * W + doc[i + 1]);
    for (const key of seen) bigramDf.set(key, (bigramDf.get(key) ?? 0) + 1);
  }
  const keepBigram = (a: number, b: number) => (bigramDf.get(a * W + b) ?? 0) >= minDf;
  const trigramDf = new Map<string, number>();
  for (const doc of docWords) {
    const seen = new Set<string>();
    for (let i = 0; i + 2 < doc.length; i++) if (keepBigram(doc[i], doc[i + 1]) && keepBigram(doc[i + 1], doc[i + 2])) seen.add(`${doc[i]},${doc[i + 1]},${doc[i + 2]}`);
    for (const key of seen) trigramDf.set(key, (trigramDf.get(key) ?? 0) + 1);
  }
  const high = maxDfShare * n;
  const ok = (df: number) => df >= minDf && df <= high;
  // Term indices: sorted phrases (stable, and the order scikit-learn reports).
  const entries: [string, number, number, string][] = []; // phrase, df, ngram, key
  for (let id = 0; id < words.length; id++) if (ok(wordDf[id])) entries.push([words[id], wordDf[id], 1, `w${id}`]);
  for (const [key, df] of bigramDf) if (ok(df)) entries.push([`${words[Math.floor(key / W)]} ${words[key % W]}`, df, 2, `b${key}`]);
  for (const [key, df] of trigramDf) if (ok(df)) entries.push([key.split(',').map(i => words[Number(i)]).join(' '), df, 3, `t${key}`]);
  entries.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const index = new Map(entries.map((e, i) => [e[3], i]));
  const docTerms = docWords.map(doc => {
    const counts = new Map<number, number>();
    const add = (key: string) => { const t = index.get(key); if (t !== undefined) counts.set(t, (counts.get(t) ?? 0) + 1); };
    for (let i = 0; i < doc.length; i++) {
      add(`w${doc[i]}`);
      if (i + 1 < doc.length) add(`b${doc[i] * W + doc[i + 1]}`);
      if (i + 2 < doc.length) add(`t${doc[i]},${doc[i + 1]},${doc[i + 2]}`);
    }
    const ids = Int32Array.from([...counts.keys()].sort((a, b) => a - b));
    return { ids, counts: Int32Array.from(ids, t => counts.get(t)!) };
  });
  return { terms: entries.map(e => e[0]), df: Int32Array.from(entries, e => e[1]), ngram: Uint8Array.from(entries, e => e[2]), docs: n, docTerms };
}
