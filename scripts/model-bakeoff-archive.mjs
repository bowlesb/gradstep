// Preserve the paid experiment's non-secret evidence in the repository. Full papers and figure bytes stay local.
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const root = '.artifacts/bakeoff';
const destination = 'docs/reviews/model-comparison-20261016';
const json = file => JSON.parse(readFileSync(file, 'utf8'));
const records = kind => existsSync(`${root}/${kind}`) ? readdirSync(`${root}/${kind}`).sort().flatMap(dir =>
  readdirSync(`${root}/${kind}/${dir}`).filter(f => f.endsWith('.json')).sort().map(f => json(`${root}/${kind}/${dir}/${f}`))) : [];
const ledger = json(`${root}/spend-ledger.json`);
if (existsSync(`${root}/paid-run.lock`)) throw new Error('Archive only after all paid requests finish');
const evidence = {
  schema: 'paper-model-comparison-evidence-v1',
  archived_at: new Date().toISOString(),
  source_hashes: json('tests/model-bakeoff/_sources.json'),
  screening: json('tests/model-bakeoff/_screening.json'),
  report: json(`${root}/report.json`),
  runs: records('runs'),
  judging: records('judge'),
  catalogue: readdirSync(`${root}/catalogue`).filter(f => f.endsWith('.json')).sort().map(f => {
    const saved = json(`${root}/catalogue/${f}`);
    if (Array.isArray(saved)) return { file: f, options: saved };
    return { file: f, checked_at: saved.checked_at, model: saved.data.id, architecture: saved.data.architecture,
      endpoints: saved.data.endpoints.filter(e => ['anthropic', 'openai', 'google-ai-studio', 'xiaomi', 'z-ai', 'alibaba', 'deepseek', 'deepinfra/fp8']
        .some(tag => e.tag === tag || e.tag.startsWith(tag + '/')))
        .map(e => ({ tag: e.tag, quantization: e.quantization, pricing: e.pricing, supported_parameters: e.supported_parameters })) };
  }),
  spend: { completion_reported: ledger.reduce((s, r) => s + (r.cost ?? 0), 0),
    unresolved_holds: ledger.filter(r => r.cost == null),
    provider_account: existsSync(`${root}/provider-balance-latest.json`) ? json(`${root}/provider-balance-latest.json`) : null },
  manual_review: existsSync(`${root}/manual-review.json`) ? json(`${root}/manual-review.json`) : null,
};
mkdirSync(destination, { recursive: true });
const bytes = JSON.stringify(evidence, null, 1) + '\n';
writeFileSync(`${destination}/evidence.json`, bytes);
writeFileSync(`${destination}/evidence.sha256`, createHash('sha256').update(bytes).digest('hex') + '  evidence.json\n');
console.log(`${evidence.runs.length} attempt records, ${evidence.judging.length} grading records preserved (${Buffer.byteLength(bytes)} bytes)`);
