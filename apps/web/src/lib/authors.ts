/** Author lists, the same way on every surface (the native LibraryFormat has the same rules): rows and columns show
 * family names, three at most, then how many more; cards with room show full names, six at most; a byline names
 * the first author "et al.". The reader's own author block is rendered by the arXiv HTML compiler. */
const SUFFIXES = new Set(['jr', 'jr.', 'sr', 'sr.', 'ii', 'iii', 'iv', 'phd', 'ph.d.']);
const PARTICLES = new Set(['van', 'von', 'der', 'den', 'de', 'del', 'della', 'di', 'da', 'du', 'dos', 'das', 'le', 'la', 'ter', 'ten', 'bin', 'al', 'el']);
const clean = (names: readonly string[]) => names.map(n => n.replace(/\s+/g, ' ').trim()).filter(Boolean);

/** "Ashish Vaswani" → "Vaswani"; "Vaswani, Ashish" → "Vaswani"; "Ludwig van Beethoven" → "van Beethoven". */
export function familyName(name: string): string {
  const trimmed = name.replace(/\s+/g, ' ').trim();
  const comma = trimmed.indexOf(',');
  if (comma >= 0) {
    const family = trimmed.slice(0, comma).trim(), rest = trimmed.slice(comma + 1).trim().toLowerCase();
    if (family && !SUFFIXES.has(rest)) return family;
  }
  const words = trimmed.split(' ');
  while (words.length > 1 && SUFFIXES.has(words[words.length - 1].toLowerCase().replace(/,$/, ''))) words.pop();
  let index = words.length - 1;
  if (index < 0) return trimmed;
  while (index > 1 && PARTICLES.has(words[index - 1].toLowerCase())) index -= 1;
  return words.slice(index).join(' ').replace(/,$/, '');
}

/** One author → the full name; two or three → family names; more → three family names and "+N". */
export function compactAuthors(names: readonly string[]): string {
  const authors = clean(names);
  if (authors.length === 0) return '';
  if (authors.length === 1) return authors[0];
  const shown = authors.slice(0, 3).map(familyName).join(', ');
  return authors.length > 3 ? `${shown} +${authors.length - 3}` : shown;
}

/** Full names, `limit` at most, then "+N" (feed and podcast cards, the player's "Paper by" line). */
export function authorLine(names: readonly string[], limit = 6): string {
  const authors = clean(names);
  if (authors.length === 0) return '';
  const shown = authors.slice(0, limit).join(', ');
  return authors.length > limit ? `${shown} +${authors.length - limit}` : shown;
}

/** "Vaswani et al." (a byline under a title), or the one author's full name. */
export function firstAuthorLine(names: readonly string[]): string {
  const authors = clean(names);
  if (authors.length === 0) return '';
  return authors.length > 1 ? `${familyName(authors[0])} et al.` : authors[0];
}
