// Local evaluation only: list the newly suppressed physical margin lines, with their exact PDF locations.
// node scripts/device-pdf-models/audit_margins.mjs RECORDS OUTPUT.json
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { join } from 'node:path';
import { byX, composeAccents, lineText, linesOf, typicalGap, union, useLigatures, useLineBands, useWordGaps, visible } from '../../supabase/functions/_shared/reader/device-pdf/geometry.ts';
import { aliasFont, aliasText } from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
import { furniture, longMarginGlyphs, marginGlyphLines, venueNotice } from '../../supabase/functions/_shared/reader/device-pdf/structure.ts';
const [records, output] = process.argv.slice(2), rows = [];
for (const paper of readdirSync(records).sort()) {
  const file = join(records, paper, 'record.json');
  if (!existsSync(file) && !existsSync(file + '.gz')) continue;
  const r = JSON.parse(existsSync(file) ? readFileSync(file, 'utf8') : gunzipSync(readFileSync(file + '.gz')).toString());
  useWordGaps(null); useLineBands(!!r.input.lineBands, !!r.input.lineReturns); useLigatures(!!r.input.ligatures);
  const pages = r.pages.map(p => {
    const glyphs = p.glyphs.text.map((_, i) => Object.fromEntries(Object.entries(p.glyphs).map(([k, v]) => [k, v[i]])));
    if (r.input.fontAliases) for (const g of glyphs) { const font = g.font; g.text = aliasText(g.text, font); g.font = aliasFont(font, r.input.tagger); }
    if (r.input.accents) composeAccents(glyphs);
    return { ...p, glyphs, protected: p.detections.filter(d => ['figure', 'table', 'caption', 'display', 'listing'].includes(d.cls)).map(d => d.box.map(v => v / p.scale / (150 / 72))) };
  });
  if (r.input.wordGaps) useWordGaps(typicalGap(pages));
  const known = furniture(pages), removed = longMarginGlyphs(pages), lines = [];
  pages.forEach((p, page) => {
    const old = new Set(marginGlyphLines(p.glyphs, p.height).filter(([t]) => known.has(t)).flatMap(([, gs]) => gs));
    if (!page && r.input.venueNotice) for (const g of venueNotice(p.glyphs, p.height)) old.add(g);
    for (const gs of linesOf(p.glyphs.filter(visible))) {
      if (!gs.some(g => removed[page].has(g) && !old.has(g))) continue;
      const parts = [];
      for (const g of byX(gs)) {
        const last = parts.at(-1)?.at(-1);
        if (!last || g.x0 - last.x1 > 2 * Math.max(g.size, last.size)) parts.push([]);
        parts.at(-1).push(g);
      }
      lines.push({ page, box: union(gs), text: lineText(gs, [])[0], segments: parts.map(part => ({ box: union(part), text: lineText(part, [])[0] })) });
    }
  });
  rows.push({ paper, pdf_sha256: r.input.pdf.sha256, pages: pages.length, lines });
}
writeFileSync(output, JSON.stringify(rows, null, 1) + '\n');
console.log(JSON.stringify(rows.filter(r => r.lines.length).map(r => ({ paper: r.paper, lines: r.lines.length }))));
