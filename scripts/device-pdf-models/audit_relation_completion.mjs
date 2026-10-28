// Offline decoder audit. Model logits remain unchanged; inferred spans are reported separately with provenance.
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spansOf } from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
import { completeRelations } from './relation_completion.ts';

const [linesPath, predictionsPath, outPath, thresholdArgument = '0.65'] = process.argv.slice(2);
if (!outPath) throw new Error('Usage: audit_relation_completion.mjs LINES.jsonl PREDICTIONS.json OUT.json [THRESHOLD]');
const threshold = Number(thresholdArgument);
if (!(threshold > 0 && threshold < 1)) throw new Error('Invalid threshold');
const linesBytes = readFileSync(linesPath), predictionBytes = readFileSync(predictionsPath);
const lines = linesBytes.toString().trim().split('\n').map(JSON.parse), predictions = JSON.parse(predictionBytes);
const decoded = {}, changes = [];
let totalAdded = 0, totalRemoved = 0;
for (const row of lines) {
  const logits = new Array(row.glyphs.length);
  for (const w of row.windows) {
    const values = predictions.logits[w.index];
    if (!values || w.own[1] > values.length || w.own[1] - w.own[0] !== w.to - w.from) throw new Error(`Invalid window ${row.id}`);
    for (let i = w.from; i < w.to; i++) logits[i] = values[w.own[0] + i - w.from];
  }
  if (logits.filter(Number.isFinite).length !== row.glyphs.length) throw new Error(`Missing logits ${row.id}`);
  const before = spansOf(logits, threshold), after = completeRelations(row.glyphs, before);
  decoded[row.id] = after;
  const contains = (spans, i) => spans.some(([a, b]) => a <= i && i < b);
  const added = [], removed = [];
  row.glyphs.forEach((_, i) => {
    if (contains(after, i) && !contains(before, i)) added.push(i);
    if (contains(before, i) && !contains(after, i)) removed.push(i);
  });
  totalAdded += added.length; totalRemoved += removed.length;
  if (added.length || removed.length) changes.push({ id: row.id, paper: row.paper, page: row.page, source: row.source,
    text: row.text, before, after, added, removed,
    original: before.map(([a, b]) => row.glyphs.slice(a, b).map(g => g.text).join('')),
    completed: after.map(([a, b]) => row.glyphs.slice(a, b).map(g => g.text).join('')) });
}
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const summary = { lines: lines.length, changed_lines: changes.length, added_glyphs: totalAdded, removed_glyphs: totalRemoved };
writeFileSync(outPath, JSON.stringify({ threshold, lines_sha256: sha256(linesBytes), predictions_sha256: sha256(predictionBytes),
  inputs_sha256: predictions.inputs_sha256, decoded_spans: decoded, changes, summary }, null, 2) + '\n');
console.log(JSON.stringify(summary));
