#!/usr/bin/env node
// Paid, explicit check of "Go deeper" on a key concept of the paper's AI Explainer (JUDGMENT_LOG 27; CHAT.md "Go deeper on a
// key concept"): the server's own requests (runChat with stub dependencies, as paper-explainer-speed.mjs) sent straight to
// OpenRouter through the production adapter (pinned route, ZDR, price caps). First the explainer (so the concept reads the
// paper from the cache it wrote, as on a device), then each chosen concept, as the apps ask for it
// (ChatGenerationRequest.paperConcept: the concept's name, kind, line and paragraphs as the passage). Records timings (first
// output, each section as the server's PaperConceptStream would relay it, the end), tokens, cache and billed cost, and the
// checked concept for reading. Never part of npm test; spends OpenRouter credit under a durable ledger with a cap.
//
//   node scripts/paper-concept-probe.mjs --configs=gemini-minimal,haiku-low [--pick=b1,i1] [--cap=0.3] [--env=…/.env.providers]
//     [--bundle=… --id=… --revision=…] [--explainer=gemini-minimal]
//
// Configurations: <model>-<effort> (gemini|haiku|sonnet; effort as OpenRouter takes it, incl. `minimal`). Results:
// .artifacts/paper-concept-probe/<stamp>.json (and the ledger, spend.json, beside it).
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SpendLedger } from './model-bakeoff-support.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, fallback = null) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const OUT = resolve(ROOT, arg('out', '.artifacts/paper-concept-probe'));
mkdirSync(OUT, { recursive: true });
const BUNDLE = arg('bundle', '.artifacts/bundles/ecbc0a04588f');
const META = { id: arg('id', '2305.18290'), revision: Number(arg('revision', '3')) };
const configs = (arg('configs', 'gemini-minimal') ?? '').split(',').filter(Boolean);
const PICK = (arg('pick', 'b1,i1') ?? '').split(',').filter(Boolean);
const CAP = Number(arg('cap', '0.3'));
const RESEARCH_ACTOR = 'bace0ff0-0000-4000-8000-000000000001';
const env = Object.fromEntries(readFileSync(resolve(ROOT, arg('env', '.env.providers')), 'utf8').split('\n').filter(l => l.includes('=') && !l.trim().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const KEY = env.OPENROUTER_CHAT_API_KEY;
if (!KEY) { console.error('OPENROUTER_CHAT_API_KEY missing'); process.exit(2); }
const ledger = new SpendLedger(`${OUT}/spend.json`, CAP);

const { buildPaperContext } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
const chat = await import(`${ROOT}/supabase/functions/_shared/chat.ts`);
const { openRouterChatParams } = await import(`${ROOT}/supabase/functions/_shared/openrouter-chat.ts`);
const { paragraphCount } = await import(`${ROOT}/supabase/functions/_shared/chat-equation.ts`);
const { paperExplainer, paperExplainerJSON } = await import(`${ROOT}/supabase/functions/_shared/chat-paper-explainer.ts`);
const { PaperConceptStream, paperConcept, paperConceptJSON, paperConceptText } = await import(`${ROOT}/supabase/functions/_shared/chat-paper-concept.ts`);

const index = JSON.parse(readFileSync(resolve(ROOT, BUNDLE, 'reader.json'), 'utf8'));
const text = buildPaperContext(index);
const paragraphs = paragraphCount(text);

/** The concept as the apps send it (ChatGenerationRequest.paperConcept, PaperConcept.swift `selection`). */
function conceptQuote(item, kind) {
  return [`Concept: ${item.name}`, `Kind: ${kind === 'background' ? 'background the paper assumes' : "one of this paper's own ideas"}`,
    ...(item.line ? [`The explainer's line: ${item.line}`] : []), ...(item.paragraphs.length ? [`Paragraphs: ${item.paragraphs.map(n => `[¶${n}]`).join(' ')}`] : [])].join('\n');
}

/** The server's own request (runChat with stub dependencies). */
async function serverParams(profile, extra) {
  let captured = null; const errors = [];
  const deps = {
    accountID: 'aaaaaaaa-0000-4000-8000-00000000b0f0', webSearch: false,
    rpc: async (name, params) => name === 'worker_local_chat_context' ? { title: index.title }
      : name === 'worker_reserve_chat' ? { id: params.p_id, state: 'reserved', replayed: false } : name === 'worker_chat_stop_requested' ? false : null,
    loadPaper: async () => null, gemini: true, deepseek: true,
    generate: async (params, stream) => { captured ??= params; stream.onText('.');
      return { status: 'complete', failure: null, messageID: 'm', model: params.model, stopReason: 'end_turn', refusalCategory: null,
        attempts: [{ model: params.model, estimated: false, usage: { input: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 1 } }], exact: true }; },
    sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'), log: () => {}, sleep: async () => {},
  };
  const digest = createHash('sha256').update(text).digest('hex');
  await chat.runChat(deps, { operation_id: randomUUID(), consent_version: 'cloud-ai-v6', mode: 'paper',
    local_context: { format: 'reader-local-context-v2', membership_id: randomUUID(), source: 'arxiv', source_id: META.id, revision: META.revision,
      manifest_sha256: digest, source_sha256: digest, text },
    capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'], profile, ...extra }, e => { if (e.event === 'error') errors.push(e.data); }, new AbortController().signal);
  if (!captured) throw new Error(`no request: ${JSON.stringify(errors)}`);
  return captured;
}

async function* sse(stream) {
  const decoder = new TextDecoder(); let buffer = '';
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let i; while ((i = buffer.indexOf('\n')) >= 0) { const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1); if (line.startsWith('data:')) yield line.slice(5).trim(); }
  }
}

const RATES = { sonnet: [6.6, 16.5], gemini: [1.0, 4.2], haiku: [2.2, 5.5] };
async function send(config, extra, feature, onContent) {
  const [model, effort] = config.split('-');
  const profile = { model, effort: ['low', 'medium', 'high'].includes(effort) ? effort : 'low', length: 'standard' };
  const params = await serverParams(profile, extra);
  const body = openRouterChatParams(params);
  body.reasoning = { effort };
  const [inRate, outRate] = RATES[model];
  const hold = ledger.reserve(Number((params.max_tokens * outRate / 1e6 + (Buffer.byteLength(JSON.stringify(body.messages)) / 2) * inRate / 1e6).toFixed(6)),
    { model: body.model, config, feature });
  const started = Date.now(); const t = () => Date.now() - started;
  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST', redirect: 'error',
    headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json', 'X-Title': 'Gradstep concept probe', 'X-OpenRouter-Cache': 'false', 'X-Session-ID': hold },
    body: JSON.stringify({ ...body, user: RESEARCH_ACTOR, session_id: hold, trace: { attempt_id: hold, feature, caller: 'research', sent_at: new Date().toISOString() } }),
    signal: AbortSignal.timeout(180_000) });
  if (!response.ok) { const b = (await response.text()).split(KEY).join('[key]').slice(0, 400); if ([400, 401, 402, 403, 404, 422].includes(response.status)) ledger.settle(hold, 0); return { error: `HTTP ${response.status} ${b}` }; }
  const generation = response.headers.get('x-generation-id'); if (generation) ledger.identify(hold, generation);
  let content = '', usage = null, finish = null, first = null;
  for await (const data of sse(response.body)) {
    if (data === '[DONE]') break;
    let event; try { event = JSON.parse(data); } catch { continue; }
    if (event.error) return { error: String(event.error.message ?? 'stream error').slice(0, 300) };
    first ??= t();
    const choice = event.choices?.[0] ?? {};
    if (choice.delta?.content) { content += choice.delta.content; onContent?.(choice.delta.content, t()); }
    if (choice.finish_reason) finish = choice.finish_reason;
    if (event.usage) usage = event.usage;
  }
  ledger.settle(hold, usage?.cost);
  return { api_model: body.model, finish, first_chunk_ms: first, end_ms: t(), content, prompt_tokens: usage?.prompt_tokens ?? null,
    cached_tokens: usage?.prompt_tokens_details?.cached_tokens ?? null, cache_write_tokens: usage?.prompt_tokens_details?.cache_write_tokens ?? null,
    completion_tokens: usage?.completion_tokens ?? null, reasoning_tokens: usage?.completion_tokens_details?.reasoning_tokens ?? null, cost_usd: usage?.cost ?? null };
}

console.log(`${index.title}: ${Buffer.byteLength(text)} bytes, ${paragraphs} blocks`);
const explainerConfig = arg('explainer', 'gemini-minimal');
const explained = await send(explainerConfig, { messages: [{ role: 'user', text: 'Explain this paper' }], action: 'paper_explainer' }, 'paper_concept_probe_explainer');
if (explained.error) { console.error(`explainer: ${explained.error}`); process.exit(1); }
const explainer = paperExplainer(paperExplainerJSON(explained.content), paragraphs);
if (!explainer) { console.error('explainer: no usable JSON'); process.exit(1); }
console.log(`explainer (${explainerConfig}): end ${(explained.end_ms / 1000).toFixed(1)} s | cached ${explained.cached_tokens} write ${explained.cache_write_tokens} | $${explained.cost_usd?.toFixed(4)}`);
for (const item of [...explainer.background, ...explainer.ideas]) console.log(`  ${item.id}: ${item.name} ${item.paragraphs.map(n => `¶${n}`).join(' ')}`);

const results = [];
for (const id of PICK) {
  const kind = explainer.background.some(i => i.id === id) ? 'background' : 'idea';
  const item = [...explainer.background, ...explainer.ideas].find(i => i.id === id);
  if (!item) { console.log(`no concept ${id}`); continue; }
  for (const config of configs) {
    const parser = new PaperConceptStream(paragraphs), sections = [];
    let parts = null;
    const r = await send(config, { messages: [{ role: 'user', text: `Go deeper: ${item.name}` }], action: 'paper_concept', selection: { quote: conceptQuote(item, kind) } },
      'paper_concept_probe', (piece, at) => { for (const s of parser.push(piece)) { if (s.kind === 'parts') parts = s.parts; else sections.push(at); } });
    if (r.error) { console.log(`${id} ${config}: ${r.error}`); results.push({ id, config, error: r.error }); continue; }
    const concept = paperConcept(paperConceptJSON(r.content), paragraphs);
    const streamedEqual = JSON.stringify(parser.concept()?.sections ?? []) === JSON.stringify(concept?.sections ?? []);
    const s = ms => ms == null ? '-' : (ms / 1000).toFixed(1);
    console.log(`${id} ${config}: first ${s(r.first_chunk_ms)} sections [${sections.map(s).join(' ')}] of ${parts ?? '-'} end ${s(r.end_ms)} | in ${r.prompt_tokens} cached ${r.cached_tokens} write ${r.cache_write_tokens} out ${r.completion_tokens} reasoning ${r.reasoning_tokens} | $${r.cost_usd?.toFixed(4)} | ${concept?.sections.length ?? 0} sections, streamed=final ${streamedEqual} | ${r.finish}`);
    const { content, ...numbers } = r;
    results.push({ id, kind, name: item.name, config, ...numbers, parts, sections_ms: sections, streamed_equal_final: streamedEqual, concept,
      markdown: concept ? paperConceptText(paperConceptJSON(content), paragraphs) : null, ...(concept ? {} : { raw: content.slice(0, 4_000) }) });
  }
}
const file = `${OUT}/${new Date().toISOString().replace(/[:.]/g, '-')}.json`;
const { content: _, ...explainerNumbers } = explained;
writeFileSync(file, JSON.stringify({ paper: META, explainer: { config: explainerConfig, ...explainerNumbers, explainer }, results }, null, 1));
console.log(`recorded ${file}; ledger actual $${ledger.actual.toFixed(4)} outstanding $${ledger.outstanding.toFixed(4)}`);
