// Reading-flow repair on provider MMD before rendering. Mathpix keeps PDF page
// order: a sentence that continues on the next page is split by `\pagebreak`,
// and a figure or table placed at the top of that page lands mid-sentence.
// Only that explicit marker is used; column breaks and ordinary paragraph
// ends are left alone.

const TERMINAL = /[.!?:;]["'”’)\]]*\s*$/u;
const COMMAND_LINE = /^\s*(?:\\(?:begin|end|section|subsection|subsubsection|paragraph|caption|title|author|includegraphics|item|footnote|footnotetext|pagebreak)\b|\|)/;
const DISPLAY_END = /(?:\\\]|\$\$|\\end\{[^}]*\}|\\\\)\s*$/;
const FLOAT_START = /^\s*\\begin\{(figure|table)\*?\}/;
const MAX_FLOAT_LINES = 400;

const MAX_FOOTNOTE_LINES = 40;
/** End-of-line checks look at a bounded tail (pathological lines stay linear). */
const tail = (line: string) => line.slice(-256).trimEnd();

/** Start index of the page footnote (`\footnotetext{…}`) or float
 * (`\begin{figure|table}…\end{…}`) block ending at `end`, if any. */
function trailingBlockStart(lines: string[], end: number): number | null {
  const float = /\\end\{(figure|table)\*?\}\s*$/.exec(tail(lines[end]));
  if (!float && lines[end].trim() !== '}') return null;
  const opener = float ? new RegExp(`^\\s*\\\\begin\\{${float[1]}\\*?\\}`) : /^\s*\\footnotetext\{/;
  const limit = float ? MAX_FLOAT_LINES : MAX_FOOTNOTE_LINES;
  if (float && opener.test(lines[end])) return end; // one-line float
  for (let k = end - 1; k >= 0 && end - k <= limit; k--) {
    if (!float && !lines[k].trim()) return null;
    if (opener.test(lines[k])) return k;
  }
  return null;
}

/** Joins a paragraph split by `\pagebreak` when the text before the break
 * stops mid-sentence and the text after it starts in lower case. Footnotes
 * and floats between the two halves keep their order and move to just after
 * the joined paragraph. */
export function joinPageSplits(source: string): string {
  const lines = source.split('\n');
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() !== '\\pagebreak') continue;
    // The paragraph's last line, skipping blank lines, page footnotes and
    // floats placed at the bottom of the page.
    let p = i - 1;
    const before: string[][] = [];
    while (p >= 0) {
      if (!lines[p].trim()) { p--; continue; }
      const start = trailingBlockStart(lines, p);
      if (start === null) break;
      before.unshift(lines.slice(start, p + 1));
      p = start - 1;
    }
    if (p < 0) continue;
    const prev = lines[p];
    const prevTail = tail(prev);
    if (!/\p{L}/u.test(prevTail) || TERMINAL.test(prevTail) || COMMAND_LINE.test(prev.slice(0, 256)) || DISPLAY_END.test(prevTail)) continue;
    let j = i + 1;
    const floats: string[][] = [];
    while (j < lines.length) {
      if (!lines[j].trim()) { j++; continue; }
      const float = FLOAT_START.exec(lines[j]);
      if (!float) break;
      const end = new RegExp(`^\\s*\\\\end\\{${float[1]}\\*?\\}`);
      // The closing line may be the opening line itself (a one-line float).
      const closes = new RegExp(`\\\\end\\{${float[1]}\\*?\\}`);
      let k = j;
      while (k < lines.length && k - j < MAX_FLOAT_LINES && !(k === j ? closes.test(lines[k]) : end.test(lines[k]))) k++;
      if (k >= lines.length || k - j >= MAX_FLOAT_LINES) { j = -1; break; }
      floats.push(lines.slice(j, k + 1));
      j = k + 1;
    }
    if (j < 0 || j >= lines.length || !/^\p{Ll}/u.test(lines[j])) continue;
    const joiner = /\p{L}-$/u.test(prevTail) ? '' : ' ';
    const merged = prev.trimEnd() + joiner + lines[j];
    // The joined paragraph runs until the next blank line or page break;
    // moved blocks follow it (so a later break can still be joined).
    let end = j + 1;
    while (end < lines.length && lines[end].trim() && lines[end].trim() !== '\\pagebreak') end++;
    const moved = [...before, ...floats].flatMap(block => ['', ...block]);
    lines.splice(p, end - p, merged, ...lines.slice(j + 1, end), ...moved);
    i = p;
  }
  return lines.join('\n');
}
