// The TypeScript port on recorded signals with the rules of rules.py (the same as tests/backend/device-pdf/synthetic.ts).
//   node --experimental-strip-types scripts/device-pdf-reference/run_ts.mjs <signals.json> <out dir> [vocab.json] [paper.pdf]
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
const { composeDevicePDFReader } = await import('../../supabase/functions/_shared/reader/device-pdf/bundle.ts');
const { host, mathIDs } = await import('../../tests/backend/device-pdf/synthetic.ts');
const [signalsPath, outDir, vocabPath, pdfPath] = process.argv.slice(2);
const signals = JSON.parse(readFileSync(signalsPath, 'utf8'));
const vocab = signals.tagger ?? JSON.parse(readFileSync(vocabPath, 'utf8'));
const pdf = signals.pdf ?? (() => { const b = readFileSync(pdfPath); return { sha256: createHash('sha256').update(b).digest('hex'), bytes: b.length, name: pdfPath.split('/').pop() }; })();
void mathIDs;
const bundle = composeDevicePDFReader({ pdf, pages: signals.pages.length, models: [], tagger: vocab, trace: true }, host(signals.pages, { vocab }));
mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/index.json`, JSON.stringify(bundle.trace));
console.log(JSON.stringify(bundle.summary));
