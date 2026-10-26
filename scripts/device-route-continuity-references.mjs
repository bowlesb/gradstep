// Local, read-only paragraph references for auditing changed PDF joins. No fetch or model calls.
// node scripts/device-route-continuity-references.mjs CORPUS BEFORE OUTPUT.json
import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { convertArxivHTML, arxivHTMLURL } from '../supabase/functions/_shared/reader/arxiv-html.ts';
import { readBundle } from './device-route-accuracy.mjs';
const [corpus, before, out] = process.argv.slice(2);
const result = [];
for (const paper of readdirSync(before).sort()) {
  const html = join(before, paper, 'index.html');
  if (!existsSync(html)) continue;
  const words = blocks => blocks.map(b => ({ id: b.id, kind: b.kind, words: b.tokens.filter(t => t.w).map(t => t.w) }));
  const row = { paper, before: words(readBundle(readFileSync(html, 'utf8'), { device: true })) };
  try {
    const meta = JSON.parse(readFileSync(join(corpus, paper, 'meta.json'), 'utf8'));
    const [, id, revision] = meta.arxiv_id ? [null, meta.arxiv_id, meta.revision] : /^(.+?)v(\d+)$/.exec(paper);
    const reference = convertArxivHTML(readFileSync(join(corpus, paper, 'source.html'), 'utf8'), arxivHTMLURL(id, Number(revision)),
      () => ({ path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 }), { title: meta.title, authors: meta.authors });
    row.reference = words(readBundle(reference.html));
  } catch (e) { row.reference_error = e.code ?? e.message; }
  result.push(row);
}
writeFileSync(out, JSON.stringify(result));
console.log(`${result.length} papers, ${result.filter(r => r.reference).length} accepted references`);
