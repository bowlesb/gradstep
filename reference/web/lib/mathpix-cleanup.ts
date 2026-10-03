// ─── Mathpix HTML/Markdown Cleanup ──────────────────────────────────
// Post-processes Mathpix output to fix common PDF-to-HTML artifacts:
//  - <br> tags within paragraph blocks (mid-sentence line breaks)
//  - Hyphen-broken words across line breaks
//  - Concatenated compound words (Mathpix joins hyphenated words at column breaks)


/**
 * Clean Mathpix HTML output.
 * Removes spurious <br> tags inside paragraph <div> blocks while preserving
 * intentional breaks in author/address blocks.
 */
export function cleanMathpixHtml(html: string): string {
  // 1. Handle hyphenated breaks: word-<br>\ncontinuation → word-continuation
  //    Keep the hyphen, remove the break and whitespace
  html = html.replace(/(\w)-<br\s*\/?>\s*\n?\s*(\w)/gi, "$1-$2");

  // 2. Remove <br> + optional whitespace/newline within paragraph text → space
  //    This catches: "the masked<br>\nword" → "the masked word"
  //    But we avoid touching <br> inside <pre>, <code>, or author blocks
  html = html.replace(/<br\s*\/?>\s*\n?\s*/gi, (match, offset) => {
    // Check if we're inside a <pre> or <code> block by looking backwards
    const before = html.substring(Math.max(0, offset - 500), offset);
    const lastPreOpen = before.lastIndexOf("<pre");
    const lastPreClose = before.lastIndexOf("</pre");
    if (lastPreOpen > lastPreClose) return match; // inside <pre>

    const lastCodeOpen = before.lastIndexOf("<code");
    const lastCodeClose = before.lastIndexOf("</code");
    if (lastCodeOpen > lastCodeClose) return match; // inside <code>

    return " ";
  });

  // 2b. Handle hyphen-broken words across </div><div> column breaks:
  //     "computa-</div><div>tional" → "computa-tional"
  html = html.replace(/(\w)-<\/div>\s*\n?\s*<div(?:\s[^>]*)?>(\w)/gi, "$1-$2");

  // 2c. Merge </div><div> breaks that occur mid-sentence (Mathpix column-break artifact).
  //     Only merge when the text before </div> doesn't end with sentence-ending punctuation.
  html = html.replace(/<\/div>\s*\n?\s*<div(?:\s[^>]*)?>/gi, (match, offset) => {
    // Look back to find text content before this </div>
    const before = html.substring(Math.max(0, offset - 200), offset);
    // Strip HTML tags to get the actual text ending
    const textBefore = before.replace(/<[^>]+>/g, "").trim();
    if (!textBefore) return match; // empty — keep the break
    const lastChar = textBefore[textBefore.length - 1];
    // If text ends with sentence punctuation, this is likely an intentional paragraph break
    if (".!?:".includes(lastChar)) return match;
    // Otherwise it's a mid-sentence column break — merge with a space
    return " ";
  });

  // 3. Collapse multiple spaces into one (from the replacements above)
  html = html.replace(/  +/g, " ");

  // 3b. Strip Mathpix CDN font stylesheets (CMU fonts).
  //     These fail with CORS errors when loaded inside an srcdoc iframe
  //     (origin "null"). The paper falls back to system serif fonts.
  html = html.replace(
    /<link[^>]*href="https?:\/\/cdn\.mathpix\.com\/fonts\/[^"]*"[^>]*\/?>/gi,
    ""
  );

  // 3c. Fix broken URLs from line-break removal.
  //     When a URL spans PDF lines, step 2 can produce "github. com",
  //     "arxiv. org", or "https: //" etc. Rejoin them.
  //     Fix protocol break: "https: //" or "http: //" → "https://"
  html = html.replace(/https?\s*:\s*\/\//gi, (m) => m.replace(/\s+/g, ""));
  //     Handle href="..." attributes (most reliable context)
  html = html.replace(
    /href="([^"]*)"/gi,
    (_m, url: string) => `href="${url.replace(/\.\s+/g, ".")}"`
  );
  //     Handle visible URL text: https://word. word or http://word. word
  html = html.replace(
    /https?:\/\/[^\s<"]+/gi,
    (url) => url.replace(/\.\s+/g, ".")
  );

  // 4. Split references that are crammed into a single block.
  //    Mathpix often outputs all references as one <div>[1] ... [2] ... [3] ...</div>.
  //    Split them into separate <p> elements for readability.
  html = html.replace(
    /(<h[1-3]\b[^>]*>(?:\s*(?:<[^>]+>))*\s*References?\s*(?:<[^>]+>)*\s*<\/h[1-3]>)([\s\S]*?)(?=<h[1-3]\b|$)/gi,
    (_match, heading, body) => {
      // Split on reference markers like [1], [2], etc.
      // Use non-capturing group to avoid extra array elements from captured groups
      const parts = body.split(/(?=\[\d+\])/);
      if (parts.length <= 2) return heading + body; // not enough to split
      const refs = parts
        .map((p: string) => p.trim())
        .filter((p: string) => /^\[\d+\]/.test(p))
        .map((p: string) => {
          // Strip wrapping <div> if present, we'll re-wrap in <p>
          const inner = p.replace(/^<div[^>]*>|<\/div>$/gi, "").trim();
          return inner ? `<p style="margin:0.4em 0;text-indent:-2em;padding-left:2em;">${inner}</p>` : "";
        })
        .filter((p: string) => p.length > 0)
        .join("\n");
      return heading + `\n<div class="references-list">${refs}</div>`;
    }
  );

  // 5. Hide in-paper "Contents" / "Table of Contents" sections entirely.
  //    These render as ugly text blocks from PDF conversion (all entries
  //    merged into one paragraph) and we already have our own structured
  //    TOC overlay extracted from headings.
  html = html.replace(
    /(<h([1-3])\b[^>]*>(?:\s*(?:<[^>]+>))*\s*(?:Table\s+of\s+)?Contents\s*(?:<[^>]+>)*\s*<\/h\2>)([\s\S]*?)(?=<h[1-3]\b|$)/gi,
    (_match, heading, _level, body) => {
      // Hide if the body looks like a TOC (dotted leaders, numbered sections,
      // or just a large text block following a "Contents" heading)
      const stripped = body.replace(/<[^>]+>/g, "").trim();
      const looksLikeToc =
        stripped.length > 100 &&
        (/\.{2,}/g.test(stripped) || /\d+\.\d+\s+\w/g.test(stripped) || /\d+\s+\w.*\d+\s+\w/g.test(stripped));
      if (looksLikeToc) {
        return `<div class="paper-toc-collapsed" style="display:none">${heading}${body}</div>`;
      }
      return heading + body;
    }
  );

  // 6. Hide figures that appear before the Abstract heading.
  //    These are typically header logos or banner images from the PDF that
  //    look odd rendered inline above the paper content.
  const abstractPos = html.search(/<h[1-6][^>]*>[^<]*Abstract[^<]*<\/h[1-6]>/i);
  if (abstractPos > 0) {
    const beforeAbstract = html.substring(0, abstractPos);
    const afterAbstract = html.substring(abstractPos);
    const cleaned = beforeAbstract
      .replace(/<figure[^>]*>[\s\S]*?<\/figure>/gi,
        (m) => `<div style="display:none">${m}</div>`)
      .replace(/<div\s+class="figure_img"[^>]*>[\s\S]*?<\/div>(?:\s*<\/div>)?/gi,
        (m) => `<div style="display:none">${m}</div>`);
    html = cleaned + afterAbstract;
  }

  // 7. Promote complex inline math to block display.
  //    Mathpix sometimes marks large equations as math-inline when they should
  //    be display math. Promote if the LaTeX is long or contains display-level
  //    operators like \sum, \prod, \frac with substantial nesting.
  html = html.replace(
    /<span\s+([^>]*class="math-inline[^"]*"[^>]*)>/gi,
    (match, attrs: string) => {
      const latexMatch = attrs.match(/data-latex="([^"]*)"/);
      if (!latexMatch) return match;
      const latex = latexMatch[1];
      const isComplex = latex.length > 80 &&
        (/\\(sum|prod|int|iint|oint)\b/.test(latex) ||
         /\\frac\s*\{[^}]{10,}\}/.test(latex) ||
         (latex.match(/\{/g) || []).length > 6);
      if (isComplex) {
        return `<span ${attrs.replace("math-inline", "math-block")} style="display:block;margin:20px 0;text-align:center;">`;
      }
      return match;
    }
  );

  // 8. Fix all-caps table captions (Mathpix preserves PDF uppercase styling).
  //    Convert to sentence case while preserving acronyms (2+ uppercase letters)
  //    and Roman numerals (TABLE IV → Table IV).
  html = html.replace(
    /<div\s+class="caption_table">([\s\S]*?)<\/div>/gi,
    (_match, inner: string) => {
      // Only fix if the text content is predominantly uppercase
      const textOnly = inner.replace(/<[^>]+>/g, "");
      const upperCount = (textOnly.match(/[A-Z]/g) || []).length;
      const letterCount = (textOnly.match(/[A-Za-z]/g) || []).length;
      if (letterCount === 0 || upperCount / letterCount < 0.6) {
        return `<div class="caption_table">${inner}</div>`;
      }
      // Process text segments (not HTML tags): lowercase words, keep short acronyms
      const fixed = inner.replace(/>([^<]+)</g, (_m, text: string) => {
        const converted = text.replace(/[A-Z]{2,}/g, (word: string) => {
          // Keep short acronyms (2-5 chars like PSNR, SSIM, DIV2K) uppercase
          if (word.length <= 5) return word;
          // Longer runs → title case
          return word.charAt(0) + word.slice(1).toLowerCase();
        });
        return `>${converted}<`;
      });
      // Also handle text at the start (before any tags)
      const fixedOuter = fixed.replace(/^([^<]+)/, (text: string) => {
        return text.replace(/[A-Z]{2,}/g, (word: string) => {
          if (word.length <= 5) return word;
          return word.charAt(0) + word.slice(1).toLowerCase();
        });
      });
      return `<div class="caption_table">${fixedOuter}</div>`;
    }
  );

  return html;
}

/**
 * Clean Mathpix markdown output.
 * Fixes hyphen-broken lines and common missing-space compound words.
 */
export function cleanMathpixMarkdown(md: string): string {
  // 1. Join hyphen-broken lines: "agri-\ncultural" → "agri-cultural"
  //    Keep the hyphen — it may be a meaningful compound word (e.g. "preference-aligned")
  //    or a line-break artifact. Keeping it is safer than removing it.
  md = md.replace(/(\w)-\n(\w)/g, "$1-$2");

  // 2. Fix broken URLs from line-break artifacts
  //    "https: //" → "https://"
  md = md.replace(/https?\s*:\s*\/\//gi, (m) => m.replace(/\s+/g, ""));
  //    "github. com" → "github.com"
  md = md.replace(
    /https?:\/\/[^\s)>\]]+/gi,
    (url) => url.replace(/\.\s+/g, ".")
  );

  return md;
}

// ─── Embed LaTeX in Math Spans ─────────────────────────────────────

/**
 * Embed original LaTeX as data-latex attributes on math-inline and math-block
 * spans in the Mathpix HTML. This allows the equation explain button to access
 * the LaTeX source even though MathJax SVGs have empty textContent.
 *
 * Works by extracting all $...$ and $$...$$ expressions from the markdown in
 * order, then matching them to math-inline/math-block spans in the HTML.
 */
export function embedLatexAttributes(html: string, markdown: string): string {
  // Extract LaTeX expressions from markdown in order
  const latexExpressions: { tex: string; display: boolean }[] = [];
  // Match display math ($$...$$) and inline math ($...$)
  // Process the markdown to find all math in document order
  const mathRegex = /\$\$([\s\S]*?)\$\$|\$([^\$\n]+?)\$/g;
  let m;
  while ((m = mathRegex.exec(markdown)) !== null) {
    if (m[1] !== undefined) {
      latexExpressions.push({ tex: m[1].trim(), display: true });
    } else if (m[2] !== undefined) {
      latexExpressions.push({ tex: m[2].trim(), display: false });
    }
  }

  if (latexExpressions.length === 0) return html;

  // Match math spans in HTML in order and embed data-latex
  let inlineIdx = 0;
  let blockIdx = 0;

  // Separate into inline and display lists
  const inlineLatex = latexExpressions.filter((e) => !e.display);
  const blockLatex = latexExpressions.filter((e) => e.display);

  html = html.replace(
    /<span\s+class="(math-inline|math-block)([^"]*)"/g,
    (match, type: string, rest: string) => {
      let tex = "";
      if (type === "math-inline" && inlineIdx < inlineLatex.length) {
        tex = inlineLatex[inlineIdx++].tex;
      } else if (type === "math-block" && blockIdx < blockLatex.length) {
        tex = blockLatex[blockIdx++].tex;
      }
      if (tex) {
        // Escape HTML entities in the attribute value
        const escaped = tex
          .replace(/&/g, "&amp;")
          .replace(/"/g, "&quot;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;");
        return `<span data-latex="${escaped}" class="${type}${rest}"`;
      }
      return match;
    }
  );

  return html;
}

// ─── Table of Contents Extraction ──────────────────────────────────

export interface TocEntry {
  level: number;
  id: string;
  title: string;
}

/**
 * Extract table of contents from Mathpix HTML.
 * Parses <h1>–<h6> tags with `id` attributes.
 * Filters out the paper title (first h1) and "Abstract" heading.
 */
/**
 * Infer heading depth from academic numbering conventions.
 * Returns a relative depth (1=top, 2=mid, 3=sub) or 0 if no pattern detected.
 *
 * Standard academic hierarchy:
 *   Roman numerals (I., II., III.)  → top-level sections
 *   Capital letters (A., B., C.)    → subsections
 *   Numbered items  (1), 2), 1.)    → sub-subsections
 */
function isValidRomanNumeral(s: string): boolean {
  // Validate against the standard Roman numeral pattern (up to ~39 covers any paper)
  return /^(X{0,3})(IX|IV|V?I{0,3})$/.test(s) && s.length > 0;
}

function inferDepthFromNumbering(title: string): number {
  const t = title.trimStart();
  // Roman numeral prefix: "III. Foo" or "IV. Foo" — validate it's actually a Roman numeral
  const romanMatch = t.match(/^([IVXLC]+)[\.\s]/);
  if (romanMatch && isValidRomanNumeral(romanMatch[1])) return 1;
  // Capital letter prefix: "A. Foo" or "A Foo" (single letter followed by dot/space)
  if (/^[A-Z][\.\s]\s*\S/.test(t) && !/^[A-Z][a-z]/.test(t)) return 2;
  // Numbered prefix: "1) Foo", "1. Foo", "12) Foo"
  if (/^\d+[.)]\s/.test(t)) return 3;
  return 0;
}

export function extractToc(html: string): TocEntry[] {
  const entries: TocEntry[] = [];
  // Match heading tags with id attributes
  const headingRegex = /<h([1-6])\s+[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/gi;
  let match;
  let skippedFirstH1 = false;

  while ((match = headingRegex.exec(html)) !== null) {
    const level = parseInt(match[1], 10);
    const id = match[2];
    // Strip HTML tags from the title text
    const title = match[3].replace(/<[^>]+>/g, "").trim();

    if (!title) continue;

    // Skip the first h1 (paper title)
    if (level === 1 && !skippedFirstH1) {
      skippedFirstH1 = true;
      continue;
    }

    // Skip non-content headings (but keep References/Bibliography — useful for navigation)
    if (/^(abstract|contents|table\s+of\s+contents)$/i.test(title)) continue;

    entries.push({ level, id, title });
  }

  // If all entries share the same HTML heading level (common Mathpix artifact),
  // try to infer hierarchy from academic numbering conventions.
  const distinctLevels = new Set(entries.map((e) => e.level));
  if (distinctLevels.size === 1 && entries.length > 1) {
    const baseLevel = entries[0].level;
    let anyInferred = false;
    for (const entry of entries) {
      const depth = inferDepthFromNumbering(entry.title);
      if (depth > 0) {
        entry.level = baseLevel + depth - 1;
        anyInferred = true;
      }
    }
    // If only some entries had numbering, leave un-numbered ones at base level
    // (they're likely top-level headings without numbering)
    if (!anyInferred) {
      // No standard numbering detected — leave levels as-is
    }
  }

  return entries;
}
