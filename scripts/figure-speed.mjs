#!/usr/bin/env node
// Paid, explicit timing of the figure walkthrough's model call (FIGURE_VIEW.md "Speed"). The server's own request for
// `action: "figure"` is built by runChat with stub dependencies (instructions, tools, the ¶-numbered paper from the
// browser's context builder, the figure prepared by the browser's own code), translated by the production adapter
// (openRouterChatParams: the pinned Google Vertex route, ZDR, price caps) and streamed straight from OpenRouter, so the
// numbers are the model's alone: time to the first byte, first reasoning, first argument characters, the summary and
// each section as the server's FigureWalkthroughStream would emit them, and the end; tokens (reasoning included), cache
// and billed cost. Each configuration runs twice in a row (the first may write the cache, the second reads it).
// Never part of npm test; spends OpenRouter credit (OPENROUTER_CHAT_API_KEY in .env.providers) under a durable ledger.
//
//   node scripts/figure-speed.mjs --paper=dpo --figure=2 --configs=gemini-medium,haiku-low [--runs=2] [--cap=0.6]
//
// Configurations: <model>-<effort>, model gemini|haiku|sonnet, effort low|medium|high (Gemini also minimal), plus
// `-nothink` for reasoning off. Results: .artifacts/figure-speed/<stamp>.json and a table on stdout.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SpendLedger } from './model-bakeoff-support.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = `${ROOT}/.artifacts/figure-speed`;
mkdirSync(OUT, { recursive: true });
const arg = (name, fallback = null) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const PAPERS = {
  dpo: { bundle: '.artifacts/bundles/ecbc0a04588f', id: '2305.18290', revision: 3 },
  mamba: { bundle: '.artifacts/bundles/1c734458ee39', id: '2312.00752', revision: 2 },
  muon: { bundle: '.artifacts/bakeoff/bundles/2610.19844v1', id: '2610.19844', revision: 1 },
  prism: { bundle: '.artifacts/bakeoff/bundles/2610.14704v1', id: '2610.14704', revision: 1 },
};
const paperKey = arg('paper', 'dpo'), figureNumber = Number(arg('figure', '2'));
const configs = (arg('configs', 'gemini-medium') ?? '').split(',').filter(Boolean);
const RUNS = Number(arg('runs', '2'));
const CAP = Number(arg('cap', '0.6'));
const RESEARCH_ACTOR = 'bace0ff0-0000-4000-8000-000000000001';
const env = Object.fromEntries(readFileSync(`${ROOT}/.env.providers`, 'utf8').split('\n').filter(l => l.includes('=') && !l.trim().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const KEY = env.OPENROUTER_CHAT_API_KEY;
if (!KEY) { console.error('OPENROUTER_CHAT_API_KEY missing'); process.exit(2); }
const ledger = new SpendLedger(`${OUT}/spend.json`, CAP);

const { buildPaperContext } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
const chat = await import(`${ROOT}/supabase/functions/_shared/chat.ts`);
const { openRouterChatParams } = await import(`${ROOT}/supabase/functions/_shared/openrouter-chat.ts`);
const { FigureWalkthroughStream, figureWalkthrough } = await import(`${ROOT}/supabase/functions/_shared/chat-figure-view.ts`);
const { paragraphCount } = await import(`${ROOT}/supabase/functions/_shared/chat-equation.ts`);

const meta = PAPERS[paperKey];
const dir = `${ROOT}/${meta.bundle}`;
const index = JSON.parse(readFileSync(`${dir}/reader.json`, 'utf8'));
const text = buildPaperContext(index);
const figure = index.figures.find(f => new RegExp(`^\\s*Figure\\s*${figureNumber}\\b`).test(f.caption));
if (!figure) throw new Error(`no Figure ${figureNumber}`);
const ordinal = index.figures.indexOf(figure) + 1;
const prepared = JSON.parse(execFileSync(process.execPath, [`${ROOT}/scripts/model-bakeoff-figure.mjs`, dir, String(ordinal)],
  { cwd: ROOT, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }));
const image = { id: 'F1', paragraph: prepared.paragraph, caption: prepared.caption, media_type: prepared.mediaType, data: prepared.data, width: prepared.width, height: prepared.height };
// The selection as the clients send it: the caption, then the figure's own sub-figures when it has several (figure-structure.ts).
const { build } = await import('esbuild');
const structureModule = await build({ entryPoints: [`${ROOT}/apps/web/src/lib/figure-structure.ts`], bundle: true, write: false, format: 'esm', platform: 'node' });
const { figureMarkup, figureStructure, structureQuote, structureFits } = await import(`data:text/javascript;base64,${Buffer.from(structureModule.outputFiles[0].text).toString('base64')}`);
const manifest = JSON.parse(readFileSync(`${dir}/manifest.json`, 'utf8'));
const markup = figureMarkup(readFileSync(`${dir}/${manifest.entrypoint ?? 'index.html'}`, 'utf8'), figure.id);
const sizes = figure.asset_paths.map(path => { const m = manifest.members.find(x => x.path === path); return m?.width && m.height ? { width: m.width, height: m.height } : null; });
const structure = markup && figure.asset_paths.length > 1 ? figureStructure(markup, figure.asset_paths, sizes, figure.caption) : null;
const quote = [...structureQuote(figure.caption, structureFits(structure, image) ? structure : null)].slice(0, 4_000).join('');

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
    local_context: { format: 'reader-local-context-v2', membership_id: randomUUID(), source: 'arxiv', source_id: meta.id, revision: meta.revision,
      manifest_sha256: digest, source_sha256: digest, text },
    messages: [{ role: 'user', text: `Figure ${figureNumber}` }], capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'],
    profile, action: 'figure', selection: { quote }, figures: [image] }, e => { if (e.event === 'error') errors.push(e.data); }, new AbortController().signal);
  if (!captured) throw new Error(`no request: ${JSON.stringify(errors)}`);
  return captured;
}

const CALL = 'Call figure_walkthrough once with the whole walkthrough, even when part of the image is unclear or cut off (say so in the text). Write no other text, use no other tool and do not search the web.';
const TEXT = 'Write the whole walkthrough as one JSON object in your reply, with exactly the fields of the figure_walkthrough tool\'s input ({"summary": "…", "sections": [{…}, …]}, summary first), even when part of the image is unclear or cut off (say so in the text), and nothing else: no tool call, no code fence, no other text. Do not search the web.';
async function* sse(stream) {
  const decoder = new TextDecoder(); let buffer = '';
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let i; while ((i = buffer.indexOf('\n')) >= 0) { const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1); if (line.startsWith('data:')) yield line.slice(5).trim(); }
  }
}

async function run(config) {
  const [model, effort, ...flags] = config.split('-');
  const profile = { model, effort: effort === 'minimal' ? 'low' : effort, length: 'standard' };
  const params = await serverParams(profile);
  // `text`: the walkthrough written as one JSON object in the reply instead of the tool call (same fields).
  if (flags.includes('text')) {
    const swap = block => block.type === 'text' && block.text.includes(CALL) ? { ...block, text: block.text.replace(CALL, TEXT) } : block;
    params.system = params.system.map(swap);
    params.messages = params.messages.map(m => Array.isArray(m.content) ? { ...m, content: m.content.map(swap) } : m);
    if (!JSON.stringify(params).includes('nothing else: no tool call')) throw new Error('instruction swap failed');
  }
  const body = openRouterChatParams(params);
  // Profiles fix Gemini at medium and Claude at its effort; the configuration may ask for another level or none.
  if (flags.includes('nothink')) body.reasoning = { enabled: false };
  else body.reasoning = { effort };
  const started = Date.now();
  const hold = ledger.reserve(Number((params.max_tokens * (model === 'sonnet' ? 11 : model === 'gemini' ? 4.2 : 0.6) / 1e6
    // Input: a token per two text bytes (real prompts: 2–3) at the one-hour cache-write rate; the image as 3,000 tokens.
    + ((Buffer.byteLength(JSON.stringify(body.messages)) - image.data.length) / 2 + 3_000) * (model === 'sonnet' ? 4.4 : model === 'gemini' ? 0.9 : 0.25) / 1e6).toFixed(6)),
    { model: body.model, config, paper: paperKey, figure: figureNumber, feature: 'figure_speed' });
  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST', redirect: 'error',
    headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json', 'X-Title': 'Gradstep figure speed', 'X-OpenRouter-Cache': 'false', 'X-Session-ID': hold },
    body: JSON.stringify({ ...body, user: RESEARCH_ACTOR, session_id: hold, trace: { attempt_id: hold, feature: 'figure_speed', caller: 'research', sent_at: new Date().toISOString() } }),
    signal: AbortSignal.timeout(180_000) });
  const t = () => Date.now() - started;
  const headers = t();
  if (!response.ok) { const body = (await response.text()).split(KEY).join('[key]').slice(0, 500); if ([400, 401, 402, 403, 404, 422].includes(response.status)) ledger.settle(hold, 0); return { config, error: `HTTP ${response.status} ${body}` }; }
  const generation = response.headers.get('x-generation-id'); if (generation) ledger.identify(hold, generation);
  const parser = new FigureWalkthroughStream(paragraphCount(text)), textParser = new FigureWalkthroughStream(paragraphCount(text));
  const marks = { headers_ms: headers, first_chunk_ms: null, first_reasoning_ms: null, first_content_ms: null, first_args_ms: null, summary_ms: null, sections_ms: [], end_ms: null };
  let argsChunks = 0, reasoningChars = 0, content = '', args = '', usage = null, finish = null, provider = null;
  const chunkSizes = [];
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
      for (const item of textParser.push(delta.content)) { if (item.kind === 'summary') marks.summary_ms ??= t(); else marks.sections_ms.push(t()); }
    }
    for (const call of delta.tool_calls ?? []) {
      const piece = call.function?.arguments ?? '';
      if (!piece) continue;
      marks.first_args_ms ??= t(); argsChunks++; chunkSizes.push(piece.length); args += piece;
      for (const item of parser.push(piece)) {
        if (item.kind === 'summary') marks.summary_ms ??= t(); else marks.sections_ms.push(t());
      }
    }
    if (choice.finish_reason) finish = choice.finish_reason;
    if (event.usage) usage = event.usage;
  }
  marks.end_ms = t();
  ledger.settle(hold, usage?.cost);
  let input = null; try { input = JSON.parse(args || content.slice(content.indexOf('{'), content.lastIndexOf('}') + 1)); } catch { /* cut off */ }
  const walkthrough = input ? figureWalkthrough(input, paragraphCount(text)) : null;
  return { config, api_model: body.model, provider, finish, ...marks, args_chunks: argsChunks, args_chars: args.length,
    median_chunk_chars: chunkSizes.sort((a, b) => a - b)[Math.floor(chunkSizes.length / 2)] ?? null, reasoning_chars: reasoningChars,
    content_chars: content.length, prompt_tokens: usage?.prompt_tokens ?? null, cached_tokens: usage?.prompt_tokens_details?.cached_tokens ?? null,
    cache_write_tokens: usage?.prompt_tokens_details?.cache_write_tokens ?? null, completion_tokens: usage?.completion_tokens ?? null,
    reasoning_tokens: usage?.completion_tokens_details?.reasoning_tokens ?? null, cost_usd: usage?.cost ?? null,
    sections: walkthrough?.sections.length ?? 0, boxes: walkthrough?.sections.filter(s => s.box).length ?? 0, walkthrough,
    ...(walkthrough ? {} : { raw: (args || content).slice(0, 4_000) }) };
}

const results = [];
console.log(`paper ${paperKey} (${Buffer.byteLength(text)} bytes context), Figure ${figureNumber} (${image.width}×${image.height}, ${Math.round(image.data.length * 3 / 4 / 1024)} KB)${quote !== figure.caption.slice(0, 4_000) ? `; structure: ${structure.parts.length} sub-figures` : ''}`);
if (process.argv.includes('--dry')) { console.log(quote); process.exit(0); }
for (const config of configs) for (let n = 0; n < RUNS; n++) {
  const r = await run(config); r.run = n + 1; results.push(r);
  const s = ms => ms == null ? '-' : (ms / 1000).toFixed(1);
  console.log(r.error ? `${config} #${n + 1}: ${r.error}` : `${config} #${n + 1}: headers ${s(r.headers_ms)} first ${s(r.first_chunk_ms)} reasoning ${s(r.first_reasoning_ms)} args ${s(r.first_args_ms)} summary ${s(r.summary_ms)} sections [${r.sections_ms.map(s).join(' ')}] end ${s(r.end_ms)} | chunks ${r.args_chunks} (median ${r.median_chunk_chars} ch) | in ${r.prompt_tokens} cached ${r.cached_tokens} write ${r.cache_write_tokens} out ${r.completion_tokens} reasoning ${r.reasoning_tokens} | $${r.cost_usd?.toFixed(4)} | ${r.sections} sections ${r.boxes} boxes | ${r.finish}`);
}
const file = `${OUT}/${new Date().toISOString().replace(/[:.]/g, '-')}-${paperKey}-fig${figureNumber}.json`;
writeFileSync(file, JSON.stringify({ paper: paperKey, figure: figureNumber, image: { width: image.width, height: image.height, kb: Math.round(image.data.length * 3 / 4 / 1024) }, results }, null, 1));
console.log(`recorded ${file.slice(ROOT.length + 1)}; ledger actual $${ledger.actual.toFixed(4)} outstanding $${ledger.outstanding.toFixed(4)}`);
