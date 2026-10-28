// App-owned, network-free retrieval model. Evaluated unchanged by JavaScriptCore and the corpus harness.
// Offsets always address the original PDFPage.string UTF-16 text, never the normalized copy.
var PDFPositionMatcher = (() => {
  'use strict';
  const version = 'lexical-pdf-position-v1';
  const limits = Object.freeze({pages: 512, characters: 8000000, pageCharacters: 200000, tokens: 350000, query: 2400});
  const stop = new Set('a an and are as at be been by can for from has have if in is it its of on or our that the their these this to was we were which will with'.split(' '));
  function tokens(text) {
    const result = [];
    const pattern = /[\p{L}\p{N}]+(?:(?:\u00ad|[-\u2010]\s*\n\s*)[\p{L}\p{N}]+)*/gu;
    for (const m of text.matchAll(pattern)) {
      const word = m[0].replace(/\u00ad|[-\u2010]\s*\n\s*/g, '').normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase();
      result.push({word, start: m.index, end: m.index + m[0].length});
    }
    return result;
  }
  function create(pages) {
    if (!Array.isArray(pages) || !pages.length || pages.length > limits.pages) throw Error('PDF position limits');
    let characters = 0;
    const all = [], postings = new Map();
    pages.forEach((text, page) => {
      if (typeof text !== 'string' || text.length > limits.pageCharacters || (characters += text.length) > limits.characters) throw Error('PDF position limits');
      const words = tokens(text);
      if (all.length + words.length > limits.tokens) throw Error('PDF position limits');
      for (const token of words) {
        const at = all.length;
        all.push({...token, page});
        if (!postings.has(token.word)) postings.set(token.word, []);
        postings.get(token.word).push(at);
      }
    });
    const none = reason => ({status: 'unmatched', reason, ranges: [], version});
    return {match(query) {
      if (typeof query !== 'string' || query.length > limits.query) return none('query-limit');
      const q = tokens(query).slice(0, 100), unique = new Set(q.map(t => t.word));
      if (q.length < 6 || [...unique].filter(w => w.length > 2 && !stop.has(w)).length < 4) return none('insufficient-text');
      if (!all.length) return none('no-text');
      const weight = w => stop.has(w) ? 0.15 : 1 + Math.log(1 + all.length / (postings.get(w)?.length || 1));
      const weights = new Map([...unique].map(w => [w, weight(w)]));
      const total = [...weights.values()].reduce((a,b) => a+b, 0);
      const pairs = new Set(q.slice(1).map((t,i) => q[i].word + '\0' + t.word));
      // The opening identifies the requested place. A paragraph's later continuation after a float/footer
      // must not win simply because it contains more of the remaining words.
      const opening = new Set(q.slice(0, 16).map(t => t.word));
      const openingPairs = new Set(q.slice(1, 16).map((t,i) => q[i].word + '\0' + t.word));
      const openingTotal = [...opening].reduce((sum,w) => sum + weights.get(w), 0);
      const anchors = q.map((t,i) => ({i, hits: postings.get(t.word) || [], word: t.word}))
        .filter(t => t.hits.length && t.hits.length <= 128 && !stop.has(t.word))
        .sort((a,b) => a.hits.length - b.hits.length).slice(0, 8);
      const starts = new Set();
      for (const anchor of anchors) for (const at of anchor.hits) {
        for (const delta of [-4, 0, 4]) starts.add(Math.max(0, at - anchor.i + delta));
      }
      const candidates = [];
      for (const start of [...starts].slice(0, 2048)) for (const size of [q.length, q.length + 8]) {
        const end = Math.min(all.length, start + size), seen = new Set(), seenPairs = new Set();
        let first = -1, last = -1;
        for (let i = start; i < end; i++) {
          const word = all[i].word;
          if (unique.has(word)) { seen.add(word); if (first < 0) first = i; last = i; }
          if (i > start) { const pair = all[i-1].word + '\0' + word; if (pairs.has(pair)) seenPairs.add(pair); }
        }
        const openingCoverage = [...seen].filter(w => opening.has(w)).reduce((sum,w) => sum + weights.get(w), 0) / openingTotal;
        const openingOrder = [...seenPairs].filter(p => openingPairs.has(p)).length / openingPairs.size;
        if (openingCoverage < 0.7 || openingOrder < 0.5) continue;
        const coverage = [...seen].reduce((sum,w) => sum + weights.get(w), 0) / total;
        const order = seenPairs.size / pairs.size;
        const score = 0.65 * coverage + 0.35 * order;
        if (coverage < 0.62 || order < 0.18 || score < 0.67 || first < 0) continue;
        candidates.push({first, last, score, coverage, order});
      }
      candidates.sort((a,b) => b.score-a.score || (a.last-a.first)-(b.last-b.first) || a.first-b.first);
      const best = candidates[0];
      if (!best) return none('weak-text');
      // Overlapping retrieval windows describe one place, not competing predictions.
      const rival = candidates.find(c => c.last < best.first || c.first > best.last);
      if (rival && best.score - rival.score < 0.055) return none('ambiguous');
      const ranges = [];
      for (let i = best.first; i <= best.last; i++) {
        const token = all[i], prev = ranges[ranges.length-1];
        if (prev?.page === token.page) prev.length = token.end - prev.location;
        else ranges.push({page: token.page, location: token.start, length: token.end-token.start});
      }
      return {status: 'matched', ranges, score: best.score, version};
    }, tokenCount: all.length};
  }
  return Object.freeze({version, limits, create});
})();
