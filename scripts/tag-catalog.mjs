#!/usr/bin/env node
// Topic tags (docs/architecture/TAGS.md), staging only:
//
//   node scripts/tag-catalog.mjs status                      # counts: wanted, untagged, model, fallback, stale items
//   node scripts/tag-catalog.mjs run [--max=200]             # backfill now: the worker's own tagging loop until nothing is due
//   node scripts/tag-catalog.mjs sample 1706.03762 2305.18290 # classify arXiv papers directly (no database): tags and cost
//
// `run` uses the same claim/record/project RPCs as the pipeline worker, so every model call is held against the
// platform budget and recorded as provider usage (0 reader credits). `sample` calls the model outside the database
// budget: keep it to a handful of papers. Keys come from .env.staging / .env.providers and are never printed.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const dotenv = name => {
  const url = new URL(name, root);
  if (!existsSync(url)) return {};
  return Object.fromEntries(readFileSync(url, 'utf8').split('\n').filter(line => line.includes('=') && !line.trimStart().startsWith('#'))
    .map(line => { const i = line.indexOf('='); return [line.slice(0, i).trim(), line.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
};
const env = { ...dotenv('.env.providers'), ...dotenv('.env.staging') };
const [command = 'status', ...rest] = process.argv.slice(2);
const args = Object.fromEntries(rest.filter(a => a.startsWith('--')).map(a => { const [k, v] = a.slice(2).split('='); return [k, v ?? 'true']; }));
const ids = rest.filter(a => !a.startsWith('--'));

const { classifyPaper, createTagClient, tagCatalog, TAG_MODEL } = await import('../supabase/functions/_shared/tags.ts');

if (command === 'sample') {
  assert.ok(env.ANTHROPIC_API_KEY, 'ANTHROPIC_API_KEY missing from .env.providers');
  assert.ok(ids.length >= 1 && ids.length <= 20, 'name 1-20 arXiv IDs');
  const response = await fetch(`https://export.arxiv.org/api/query?id_list=${ids.join(',')}&max_results=${ids.length}`,
    { headers: { 'user-agent': 'Gradstep/0.1 (topic tag check)' }, signal: AbortSignal.timeout(60_000) });
  assert.equal(response.status, 200);
  const atom = await response.text();
  const decode = text => text.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
  const papers = [...atom.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].map(([, entry]) => ({
    id: /<id>https?:\/\/arxiv\.org\/abs\/([^<]+)<\/id>/.exec(entry)?.[1] ?? '?',
    title: decode(/<title>([\s\S]*?)<\/title>/.exec(entry)?.[1] ?? '').replace(/\s+/g, ' ').trim(),
    abstract: decode(/<summary>([\s\S]*?)<\/summary>/.exec(entry)?.[1] ?? '').replace(/\s+/g, ' ').trim(),
    categories: [...entry.matchAll(/<category term="([^"]+)"/g)].map(m => m[1]),
  }));
  const client = createTagClient(env.ANTHROPIC_API_KEY);
  let total = 0, inputTokens = 0, outputTokens = 0;
  for (const paper of papers) {
    const started = Date.now();
    const outcome = await classifyPaper(client, paper);
    total += outcome.microusd; inputTokens += outcome.usage?.input_tokens ?? 0; outputTokens += outcome.usage?.output_tokens ?? 0;
    console.log(`${paper.id}  ${paper.title.slice(0, 70)}\n    [${paper.categories.join(', ')}] ${Date.now() - started} ms, ${outcome.microusd} µ$`
      + `\n    → ${outcome.status === 'complete' ? outcome.tags.join(' · ') : 'FAILED ' + outcome.code}`);
  }
  console.log(`\n${papers.length} papers, ${TAG_MODEL}: ${inputTokens} input + ${outputTokens} output tokens = $${(total / 1e6).toFixed(4)}`
    + ` ($${(total / 1e6 / Math.max(1, papers.length)).toFixed(4)} per paper)`);
} else {
  assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati', 'staging only');
  assert.ok(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY, 'staging service credentials missing');
  process.env.SUPABASE_URL = env.SUPABASE_URL; process.env.SUPABASE_SERVICE_ROLE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
  const { pipelineService, rpcAdapter } = await import('../supabase/functions/_shared/pipeline-runtime.ts');
  const rpc = rpcAdapter(pipelineService());
  if (command === 'status') console.log(await rpc('worker_tags_status', {}));
  else if (command === 'run') {
    const client = env.ANTHROPIC_API_KEY ? createTagClient(env.ANTHROPIC_API_KEY) : null;
    const result = await tagCatalog({ rpc, classify: client ? input => classifyPaper(client, input) : null, uuid: randomUUID, now: Date.now,
      log: (event, fields = {}) => console.log(JSON.stringify({ event, ...fields })) },
    { deadline: Date.now() + 30 * 60_000, maxPapers: Number(args.max ?? 200) });
    console.log(result, await rpc('worker_tags_status', {}));
  } else throw new Error(`unknown command ${command}`);
}
