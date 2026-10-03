// ─── Figure Extraction from Mathpix HTML ────────────────────────────
// Extracts figures (images + captions + surrounding context) from
// Mathpix-converted paper HTML.

export interface ExtractedFigure {
  /** Figure number if detected (e.g. "1", "2a"), null otherwise */
  figureNumber: string | null;
  /** The <img> src (CDN URL or data URI) */
  src: string;
  /** Caption text (e.g. "Figure 1: Overview of the architecture") */
  caption: string | null;
  /** Surrounding paragraph text for context */
  context: string | null;
  /** Order of appearance in the document (0-based) */
  index: number;
}

/**
 * Extract figures from Mathpix HTML output.
 *
 * Mathpix typically outputs images as:
 * - <img> tags with CDN URLs or base64 data URIs
 * - Sometimes wrapped in <figure> elements
 * - Captions in nearby <p>, <figcaption>, or <div> elements
 * - Figure labels like "Figure 1:", "Fig. 1:", "FIGURE 1." in caption text
 */
export function extractFigures(html: string): ExtractedFigure[] {
  const figures: ExtractedFigure[] = [];
  const processedSrcs = new Set<string>();
  let match;

  // Strategy 1: Mathpix-style <div class="figure_img"> with optional <div class="caption_figure">
  // The figure_img div contains the <img>. Caption may be:
  //  (a) in a following caption_figure div, or
  //  (b) inline text after the <img> within the same figure_img div
  const mathpixFigureRegex =
    /<div\s+class="figure_img"[^>]*>([\s\S]*?)<\/div>(?:\s*<\/div>)?\s*(?:<div\s+class="caption_figure"[^>]*>([\s\S]*?)<\/div>)?/gi;

  while ((match = mathpixFigureRegex.exec(html)) !== null) {
    const imgBlock = match[1];
    const captionBlock = match[2] || "";
    const imgMatch = imgBlock.match(/<img[^>]+src="([^"]+)"[^>]*>/i);
    if (!imgMatch) continue;

    const src = decodeHtmlEntities(imgMatch[1]);
    if (isLikelyIcon(src, imgBlock)) continue;
    processedSrcs.add(src);

    // Try caption from caption_figure div first, then inline text, then nearby search
    let caption = stripHtml(captionBlock).trim() || null;
    if (!caption) {
      // Extract text after the <img> tag within the figure_img div
      const afterImg = imgBlock.substring(imgBlock.indexOf(imgMatch[0]) + imgMatch[0].length);
      const inlineCaption = stripHtml(afterImg).trim();
      if (inlineCaption.length > 5) caption = inlineCaption;
    }
    // If caption looks truncated (ends mid-sentence), extend by searching nearby
    if (caption && caption.length > 5 && !/[.!?)}\]]$/.test(caption.trim())) {
      const extended = findNearbyCaption(html, match.index!, match[0].length);
      if (extended && extended.length > caption.length) caption = extended;
    }
    const figNum = caption ? extractFigureNumber(caption) : null;

    figures.push({
      figureNumber: figNum,
      src,
      caption,
      context: getContext(html, match.index!, 300),
      index: figures.length,
    });
  }

  // Strategy 2: Find <figure> elements with <img> and optional <figcaption>
  const figureBlockRegex = /<figure[^>]*>([\s\S]*?)<\/figure>/gi;

  while ((match = figureBlockRegex.exec(html)) !== null) {
    const block = match[1];
    const imgMatch = block.match(/<img[^>]+src="([^"]+)"[^>]*>/i);
    if (!imgMatch) continue;

    const src = decodeHtmlEntities(imgMatch[1]);
    if (processedSrcs.has(src)) continue;
    if (isLikelyIcon(src, block)) continue;
    processedSrcs.add(src);

    const captionMatch = block.match(/<figcaption[^>]*>([\s\S]*?)<\/figcaption>/i);
    let caption = captionMatch ? stripHtml(captionMatch[1]).trim() : null;
    // If no figcaption, look for inline text after <img> or nearby caption
    if (!caption) {
      caption = findNearbyCaption(html, match.index!, match[0].length);
    }
    const figNum = caption ? extractFigureNumber(caption) : null;

    figures.push({
      figureNumber: figNum,
      src,
      caption,
      context: getContext(html, match.index!, 300),
      index: figures.length,
    });
  }

  // Strategy 3: Find standalone <img> tags not already captured
  const imgRegex = /<img[^>]+src="([^"]+)"[^>]*>/gi;
  while ((match = imgRegex.exec(html)) !== null) {
    const src = decodeHtmlEntities(match[1]);
    if (processedSrcs.has(src)) continue;

    // Get surrounding text to find captions
    const surroundingText = html.substring(
      Math.max(0, match.index - 500),
      Math.min(html.length, match.index + match[0].length + 500)
    );

    if (isLikelyIcon(src, surroundingText)) continue;
    processedSrcs.add(src);

    // Look for caption-like text near the image
    const caption = findNearbyCaption(html, match.index, match[0].length);
    const figNum = caption ? extractFigureNumber(caption) : null;

    figures.push({
      figureNumber: figNum,
      src,
      caption,
      context: getContext(html, match.index, 300),
      index: figures.length,
    });
  }

  return figures;
}

/** Strip HTML tags from a string */
function stripHtml(html: string): string {
  return html.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
}

/** Decode common HTML entities in URLs (e.g. &amp; → &) */
function decodeHtmlEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"');
}

/** Check if an image is likely a tiny icon/logo rather than a figure */
function isLikelyIcon(src: string, surroundingHtml: string): boolean {
  // Check for tiny inline images by looking at width/height attributes
  const sizeMatch = surroundingHtml.match(
    /<img[^>]*src="[^"]*"[^>]*(?:width|height)="(\d+)"/i
  );
  if (sizeMatch && parseInt(sizeMatch[1]) < 30) return true;

  // Check Mathpix CDN URL parameters for small crop dimensions
  // e.g. ?height=46&width=77 — both dimensions must be small
  const urlHeight = src.match(/[?&]height=(\d+)/i);
  const urlWidth = src.match(/[?&]width=(\d+)/i);
  if (urlHeight && urlWidth) {
    const h = parseInt(urlHeight[1]);
    const w = parseInt(urlWidth[1]);
    if (h < 80 && w < 80) return true;
  }

  // Skip common icon patterns
  if (/icon|logo|badge|favicon|avatar/i.test(src)) return true;

  // Very short data URIs are likely tiny images
  if (src.startsWith("data:") && src.length < 200) return true;

  return false;
}

/** Extract figure number from caption text */
function extractFigureNumber(text: string): string | null {
  // Match patterns like: "Figure 1", "Fig. 2a", "FIGURE 3:", "Figure S1"
  const match = text.match(
    /(?:figure|fig\.?)\s*([S]?\d+[a-z]?)/i
  );
  return match ? match[1] : null;
}

/** Find caption text near an image in the HTML */
function findNearbyCaption(
  html: string,
  imgIndex: number,
  imgLength: number
): string | null {
  // Look in a window after the image (captions usually follow)
  const afterStart = imgIndex + imgLength;
  const afterWindow = html.substring(afterStart, afterStart + 1500);

  // Strategy: find "Figure N:" or "Fig. N:" text, then grab everything
  // from that label to the next heading, double-newline, or new figure label
  const figLabelMatch = afterWindow.match(
    /(?:figure|fig\.?)\s*([S]?\d+[a-z]?)[\s:.]/i
  );
  if (figLabelMatch) {
    const labelStart = afterWindow.indexOf(figLabelMatch[0]);
    // Grab text from the label onwards, strip HTML, stop at next figure label or heading
    const rest = afterWindow.substring(labelStart);
    const stripped = stripHtml(rest);
    // Stop at next "Figure N" label, or take up to 1000 chars
    const nextFigMatch = stripped.substring(10).search(/(?:figure|fig\.?)\s*[S]?\d+[a-z]?[\s:.]/i);
    const caption = nextFigMatch > 0
      ? stripped.substring(0, nextFigMatch + 10).trim()
      : stripped.slice(0, 1000).trim();
    if (caption.length > 10) return caption;
  }

  // Also look before the image (some papers put captions above)
  const beforeWindow = html.substring(
    Math.max(0, imgIndex - 800),
    imgIndex
  );
  const beforeFigMatch = beforeWindow.match(
    /(?:figure|fig\.?)\s*([S]?\d+[a-z]?)[\s:.]/i
  );
  if (beforeFigMatch) {
    const labelStart = beforeWindow.indexOf(beforeFigMatch[0]);
    const rest = beforeWindow.substring(labelStart);
    const stripped = stripHtml(rest);
    if (stripped.length > 10) return stripped.slice(0, 1000).trim();
  }

  return null;
}

/** Get surrounding text context (stripped of HTML) for a position in the document */
function getContext(html: string, position: number, radius: number): string | null {
  const start = Math.max(0, position - radius);
  const end = Math.min(html.length, position + radius);
  const raw = html.substring(start, end);
  const text = stripHtml(raw).trim();
  return text.length > 20 ? text.slice(0, 500) : null;
}
