// Word segmentation using the wordninja algorithm (dynamic programming + word frequency).
// Splits concatenated words: "parameterefficient" → ["parameter", "efficient"]
// Based on https://github.com/keredson/wordninja

import { readFileSync } from "fs";
import { gunzipSync } from "zlib";
import { join } from "path";

// Load word frequency list (sorted by frequency, most common first)
let WORDS: Map<string, number> | null = null;
let MAX_WORD_LEN = 0;

function ensureLoaded(): Map<string, number> {
  if (WORDS) return WORDS;
  const gzPath = join(process.cwd(), "lib", "wordninja_words.txt.gz");
  const text = gunzipSync(readFileSync(gzPath)).toString();
  const lines = text.split("\n").filter((l) => l.trim());
  WORDS = new Map();
  for (let i = 0; i < lines.length; i++) {
    const w = lines[i].trim().toLowerCase();
    if (w) {
      // Cost = log(rank * ln(total_words)) — lower rank = lower cost = more likely
      WORDS.set(w, Math.log((i + 1) * Math.log(lines.length)));
      if (w.length > MAX_WORD_LEN) MAX_WORD_LEN = w.length;
    }
  }
  return WORDS;
}

/** Split a concatenated string into its component words using dynamic programming. */
export function splitWords(s: string): string[] {
  const words = ensureLoaded();
  const lc = s.toLowerCase();
  const n = lc.length;
  if (n === 0) return [];

  // cost[i] = best cost to segment lc[0..i-1]
  const cost: number[] = new Array(n + 1).fill(Infinity);
  const split: number[] = new Array(n + 1).fill(0); // split point for backtracking
  cost[0] = 0;

  for (let i = 1; i <= n; i++) {
    for (let j = Math.max(0, i - MAX_WORD_LEN); j < i; j++) {
      const word = lc.substring(j, i);
      const wordCost = words.get(word);
      if (wordCost !== undefined) {
        const candidate = cost[j] + wordCost;
        if (candidate < cost[i]) {
          cost[i] = candidate;
          split[i] = j;
        }
      }
    }
    // Fallback: single character (unknown word fragment) — high cost
    if (cost[i] === Infinity) {
      cost[i] = cost[i - 1] + Math.log(n * Math.log(126000));
      split[i] = i - 1;
    }
  }

  // Backtrack to find the words
  const result: string[] = [];
  let i = n;
  while (i > 0) {
    result.unshift(s.substring(split[i], i)); // use original case
    i = split[i];
  }
  return result;
}

/**
 * Fix concatenated compound words in text.
 * Finds words longer than minLen characters, runs word segmentation,
 * and re-joins with hyphens if the word was actually multiple words.
 */
export function fixConcatenatedWords(text: string, minLen = 13): string {
  return text.replace(/\b[a-zA-Z]+\b/g, (word) => {
    if (word.length < minLen) return word;
    const parts = splitWords(word);
    if (parts.length <= 1) return word;
    // Only fix if all parts are 3+ chars (avoid splitting into tiny fragments)
    if (parts.some((p) => p.length < 3)) return word;
    return parts.join("-");
  });
}

/**
 * Fix concatenated words in HTML (only in text content, not inside tags).
 */
export function fixConcatenatedWordsHtml(html: string, minLen = 13): string {
  return html.replace(/>([^<]+)</g, (_m, content: string) => {
    return `>${fixConcatenatedWords(content, minLen)}<`;
  });
}
