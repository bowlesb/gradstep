#!/usr/bin/env node
// Paid, explicit timing of the paper's AI Explainer model call (CHAT.md "Paper AI Explainer", "Speed"). The server's own
// request for `action: "paper_explainer"` is built by runChat with stub dependencies (instructions, tools, the ¶-numbered paper from the
// browser's context builder), translated by the production adapter (openRouterChatParams: the pinned route, ZDR, price
// caps) and streamed straight from OpenRouter, so the numbers are the model's alone: time to the first byte and first
// reasoning, the count, the summary and each entry as the server's PaperExplainerStream would relay them, and the end; tokens
// (reasoning included), cache and billed cost. Each configuration runs `--runs` times in a row (the first may write the
// cache). Never part of npm test; spends OpenRouter credit (OPENROUTER_CHAT_API_KEY in .env.providers) under a durable
// ledger.
//
//   node scripts/paper-explainer-speed.mjs --configs=gemini-low,gemini-minimal [--runs=2] [--cap=0.3] [--bundle=… --id=… --revision=…]
//
// Configurations: <model>-<effort> (model gemini|haiku|sonnet|deepseek; effort as OpenRouter takes it, incl. `minimal`;
// `-nothink` turns reasoning off; `-asis` sends what the server sends). Results: .artifacts/paper-explainer-speed/<stamp>.json.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SpendLedger } from './model-bakeoff-support.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = `${ROOT}/.artifacts/paper-explainer-speed`;
mkdirSync(OUT, { recursive: true });
const arg = (name, fallback = null) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const BUNDLE = arg('bundle', '.artifacts/bundles/ecbc0a04588f');
const META = { id: arg('id', '2305.18290'), revision: Number(arg('revision', '3')) };
const configs = (arg('configs', 'gemini-medium') ?? '').split(',').filter(Boolean);
const RUNS = Number(arg('runs', '2'));
const CAP = Number(arg('cap', '0.3'));
const RESEARCH_ACTOR = 'bace0ff0-0000-4000-8000-000000000001';
const env = Object.fromEntries(readFileSync(`${ROOT}/.env.providers`, 'utf8').split('\n').filter(l => l.includes('=') && !l.trim().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const KEY = env.OPENROUTER_CHAT_API_KEY;
if (!KEY) { console.error('OPENROUTER_CHAT_API_KEY missing'); process.exit(2); }
const ledger = new SpendLedger(`${OUT}/spend.json`, CAP);

const { buildPaperContext } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
const chat = await import(`${ROOT}/supabase/functions/_shared/chat.ts`);
const { openRouterChatParams } = await import(`${ROOT}/supabase/functions/_shared/openrouter-chat.ts`);
const { paragraphCount } = await import(`${ROOT}/supabase/functions/_shared/chat-equation.ts`);
const { PaperExplainerStream, paperExplainer, paperExplainerJSON } = await import(`${ROOT}/supabase/functions/_shared/chat-paper-explainer.ts`);

const index = JSON.parse(readFileSync(resolve(ROOT, BUNDLE, 'reader.json'), 'utf8'));
const text = buildPaperContext(index);
const label = 'Explain this paper';

/** The server's own request (runChat with stub dependencies), for one profile. */
async function serverParams(profile) {
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
    capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'], profile,
    messages: [{ role: 'user', text: label }], action: 'paper_explainer' }, e => { if (e.event === 'error') errors.push(e.data); }, new AbortController().signal);
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

async function run(config) {
  const [model, effort, ...flags] = config.split('-');
  // The request is the server's for a valid profile; an effort it doesn't offer (`minimal`) is set on the body below.
  const profile = { model, effort: ['low', 'medium', 'high'].includes(effort) ? effort : 'low', length: 'standard' };
  const params = await serverParams(profile);
  const body = openRouterChatParams(params);
  // Profiles fix Gemini at medium; the configuration may ask for another level or none (as the server would send it).
  if (flags.includes('nothink')) body.reasoning = { enabled: false };
  else if (!flags.includes('asis')) body.reasoning = { effort };
  const started = Date.now();
  const outRate = model === 'sonnet' ? 11 : model === 'gemini' ? 4.2 : model === 'deepseek' ? 1.5 : 0.6, inRate = model === 'sonnet' ? 4.4 : model === 'gemini' ? 0.9 : model === 'deepseek' ? 0.4 : 0.25;
  const hold = ledger.reserve(Number((params.max_tokens * outRate / 1e6 + (Buffer.byteLength(JSON.stringify(body.messages)) / 2) * inRate / 1e6).toFixed(6)),
    { model: body.model, config, feature: 'paper_explainer_speed' });
  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST', redirect: 'error',
    headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json', 'X-Title': 'Gradstep paper explainer speed', 'X-OpenRouter-Cache': 'false', 'X-Session-ID': hold },
    body: JSON.stringify({ ...body, user: RESEARCH_ACTOR, session_id: hold, trace: { attempt_id: hold, feature: 'paper_explainer_speed', caller: 'research', sent_at: new Date().toISOString() } }),
    signal: AbortSignal.timeout(180_000) });
  const t = () => Date.now() - started;
  if (!response.ok) { const b = (await response.text()).split(KEY).join('[key]').slice(0, 500); if ([400, 401, 402, 403, 404, 422].includes(response.status)) ledger.settle(hold, 0); return { config, error: `HTTP ${response.status} ${b}` }; }
  const generation = response.headers.get('x-generation-id'); if (generation) ledger.identify(hold, generation);
  const parser = new PaperExplainerStream(paragraphCount(text));
  const marks = { headers_ms: t(), first_chunk_ms: null, first_reasoning_ms: null, first_content_ms: null, count_ms: null, summary_ms: null, items_ms: [], end_ms: null };
  let reasoningChars = 0, content = '', usage = null, finish = null, provider = null, announced = null;
  for await (const data of sse(response.body)) {
    if (data === '[DONE]') break;
    let event; try { event = JSON.parse(data); } catch { continue; }
    if (event.error) return { config, error: String(event.error.message ?? 'stream error').slice(0, 300) };
    marks.first_chunk_ms ??= t(); provider ??= event.provider ?? null;
    const choice = event.choices?.[0] ?? {}, delta = choice.delta ?? {};
    const r = (delta.reasoning ?? '') + (delta.reasoning_details ?? []).map(d => d.text ?? d.summary ?? '').join('');
    if (r || delta.reasoning_details?.length) { reasoningChars += r.length; marks.first_reasoning_ms ??= t(); }
    if (delta.content) {
      content += delta.content; marks.first_content_ms ??= t();
      for (const item of parser.push(delta.content)) {
        if (item.kind === 'items') { marks.count_ms ??= t(); announced = item.items; }
        else if (item.kind === 'summary') marks.summary_ms ??= t(); else marks.items_ms.push(t());
      }
    }
    if (choice.finish_reason) finish = choice.finish_reason;
    if (event.usage) usage = event.usage;
  }
  marks.end_ms = t();
  ledger.settle(hold, usage?.cost);
  const explainer = paperExplainer(paperExplainerJSON(content), paragraphCount(text));
  const streamed = parser.explainer();
  return { config, api_model: body.model, provider, finish, ...marks, announced, reasoning_chars: reasoningChars, content_chars: content.length,
    prompt_tokens: usage?.prompt_tokens ?? null, cached_tokens: usage?.prompt_tokens_details?.cached_tokens ?? null,
    cache_write_tokens: usage?.prompt_tokens_details?.cache_write_tokens ?? null, completion_tokens: usage?.completion_tokens ?? null,
    reasoning_tokens: usage?.completion_tokens_details?.reasoning_tokens ?? null, cost_usd: usage?.cost ?? null,
    background: explainer?.background.length ?? 0, ideas: explainer?.ideas.length ?? 0, links: explainer?.links.length ?? 0,
    summary_chars: explainer ? [...explainer.summary].length : 0,
    streamed_equal_final: JSON.stringify([...(streamed?.background ?? []), ...(streamed?.ideas ?? [])]) === JSON.stringify([...(explainer?.background ?? []), ...(explainer?.ideas ?? [])]),
    explainer, ...(explainer ? {} : { raw: content.slice(0, 4_000) }) };
}

const results = [];
console.log(`${index.title}: ${Buffer.byteLength(text)} bytes context`);
for (const config of configs) for (let n = 0; n < RUNS; n++) {
  const r = await run(config); r.run = n + 1; results.push(r);
  const s = ms => ms == null ? '-' : (ms / 1000).toFixed(1);
  console.log(r.error ? `${config} #${n + 1}: ${r.error}` : `${config} #${n + 1}: first ${s(r.first_chunk_ms)} reasoning ${s(r.first_reasoning_ms)} content ${s(r.first_content_ms)} count ${r.announced ?? '-'}@${s(r.count_ms)} summary ${s(r.summary_ms)} (${r.summary_chars} ch) items [${r.items_ms.map(s).join(' ')}] end ${s(r.end_ms)} | in ${r.prompt_tokens} cached ${r.cached_tokens} write ${r.cache_write_tokens} out ${r.completion_tokens} reasoning ${r.reasoning_tokens} | $${r.cost_usd?.toFixed(4)} | ${r.background}+${r.ideas} entries, ${r.links} links streamed=final ${r.streamed_equal_final} | ${r.finish}`);
}
const file = `${OUT}/${new Date().toISOString().replace(/[:.]/g, '-')}.json`;
writeFileSync(file, JSON.stringify({ paper: META, results }, null, 1));
console.log(`recorded ${file.slice(ROOT.length + 1)}; ledger actual $${ledger.actual.toFixed(4)} outstanding $${ledger.outstanding.toFixed(4)}`);
