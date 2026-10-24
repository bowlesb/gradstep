// The gte-small tokenizer (BERT uncased WordPiece; docs/architecture/INTEREST_INDEX.md §1), dependency-free so the
// worker, the tests and later the browser share one implementation. It reproduces Hugging Face `tokenizers` with
// thenlper/gte-small@17e1f347's tokenizer.json (BertNormalizer: clean text, CJK spacing, accent stripping, lowercase;
// BertPreTokenizer; WordPiece with "##", 100-character words) — with **no padding** and truncation at 512 tokens.
// That tokenizer.json pads every text to 128 tokens; padded positions entering the mean pooling corrupt short texts and
// every phrase embedding, so this encoder has no padding at all: one id per real token, [CLS] … [SEP].

export const CLS_ID = 101;
export const SEP_ID = 102;
export const UNK_ID = 100;
export const PAD_ID = 0;
export const MAX_TOKENS = 512;
const MAX_WORD_CHARS = 100;

const CONTROL = /[\p{Cc}\p{Cf}\p{Co}\p{Cn}]/u;
const WHITESPACE = /[\s\p{Zs}]/u;
const MARK = /\p{Mn}/gu;
const PUNCT = /[\p{P}]/u;

function isChinese(cp: number): boolean {
  return (cp >= 0x4e00 && cp <= 0x9fff) || (cp >= 0x3400 && cp <= 0x4dbf) || (cp >= 0x20000 && cp <= 0x2a6df)
    || (cp >= 0x2a700 && cp <= 0x2b73f) || (cp >= 0x2b740 && cp <= 0x2b81f) || (cp >= 0x2b820 && cp <= 0x2ceaf)
    || (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0x2f800 && cp <= 0x2fa1f);
}

function isPunctuation(ch: string, cp: number): boolean {
  // ASCII punctuation and symbols (Rust's is_ascii_punctuation) and every Unicode punctuation category.
  return (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64) || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) || PUNCT.test(ch);
}

/** BertNormalizer followed by BertPreTokenizer: the words WordPiece sees. */
export function preTokenize(text: string): string[] {
  let cleaned = '';
  for (const ch of text) {
    const cp = ch.codePointAt(0)!;
    if (cp === 0 || cp === 0xfffd) continue;
    if (ch === '\t' || ch === '\n' || ch === '\r' || WHITESPACE.test(ch)) { cleaned += ' '; continue; }
    if (CONTROL.test(ch)) continue;
    cleaned += isChinese(cp) ? ` ${ch} ` : ch;
  }
  // strip_accents follows lowercase (null in the config): NFD, drop nonspacing marks, then lowercase.
  const normalized = cleaned.normalize('NFD').replace(MARK, '').toLowerCase();
  const words: string[] = [];
  let current = '';
  for (const ch of normalized) {
    const cp = ch.codePointAt(0)!;
    if (ch === ' ' || WHITESPACE.test(ch)) { if (current) words.push(current); current = ''; continue; }
    if (isPunctuation(ch, cp)) { if (current) words.push(current); words.push(ch); current = ''; continue; }
    current += ch;
  }
  if (current) words.push(current);
  return words;
}

export class WordPiece {
  private readonly vocab: Map<string, number>;
  private readonly cache = new Map<string, number[]>();

  /** `vocabText` is vocab.txt: one token per line, the line number is its id. */
  constructor(vocabText: string) {
    const lines = vocabText.split('\n');
    if (lines.at(-1) === '') lines.pop();
    this.vocab = new Map(lines.map((token, id) => [token.replace(/\r$/, ''), id]));
    if (this.vocab.get('[CLS]') !== CLS_ID || this.vocab.get('[SEP]') !== SEP_ID || this.vocab.get('[UNK]') !== UNK_ID
      || this.vocab.get('[PAD]') !== PAD_ID) throw new Error('interest_vocab_invalid');
  }

  get size(): number { return this.vocab.size; }

  private word(word: string): number[] {
    const known = this.cache.get(word);
    if (known) return known;
    const chars = Array.from(word);
    let ids: number[] = [];
    if (chars.length > MAX_WORD_CHARS) ids = [UNK_ID];
    else {
      let start = 0;
      while (start < chars.length) {
        let end = chars.length, found = -1;
        while (start < end) {
          const piece = (start > 0 ? '##' : '') + chars.slice(start, end).join('');
          const id = this.vocab.get(piece);
          if (id !== undefined) { found = id; break; }
          end--;
        }
        if (found < 0) { ids = [UNK_ID]; break; }
        ids.push(found);
        start = end;
      }
    }
    if (this.cache.size < 200_000) this.cache.set(word, ids);
    return ids;
  }

  /** [CLS] tokens… [SEP], truncated to `maxTokens` in all. Never padded. */
  encode(text: string, maxTokens = MAX_TOKENS): number[] {
    const out = [CLS_ID];
    for (const word of preTokenize(text)) {
      for (const id of this.word(word)) {
        if (out.length >= maxTokens - 1) { out.push(SEP_ID); return out; }
        out.push(id);
      }
    }
    out.push(SEP_ID);
    return out;
  }
}
