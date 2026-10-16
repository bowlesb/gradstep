#!/usr/bin/env node
// Paid, explicit model bake-off for the paper chat (CHAT.md "Choosing the chat model"). Each question goes to every
// contestant as the server would send it: the server's own request is built by runChat with stub dependencies (its
// instructions, tools, the ¶-numbered paper from the browser's context builder, the question and any figure), then
// translated to OpenRouter's chat format, pinned to the model maker's own endpoint. Answers end where a reader's would:
// a diagram, visual or figure-parts call ends the answer; look_at_figure asks again with that figure attached.
// Grading is blind (answers lettered in a seeded random order) against reference answers written from the paper.
// Never part of npm test; spends OpenRouter credit (OPENROUTER_API_KEY in .env.providers) and prints no key.
//
//   node scripts/model-bakeoff.mjs run    [--models=haiku-medium,...] [--questions=dpo-figure,...] [--cap=18]
//   node scripts/model-bakeoff.mjs judge  [--judge=opus] [--questions=...] [--cap=18]
//   node scripts/model-bakeoff.mjs report
//
// Questions: tests/model-bakeoff/<paper>.json. Results: .artifacts/bakeoff/{runs,judge}/…, report.md and report.json.
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = `${ROOT}/.artifacts/bakeoff`;
const QUESTIONS_DIR = `${ROOT}/tests/model-bakeoff`;
const arg = (name, fallback = null) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const list = name => arg(name)?.split(',').map(s => s.trim()).filter(Boolean) ?? null;
const COMMAND = process.argv[2];
const CAP_USD = Number(arg('cap', '18'));

const env = Object.fromEntries(readFileSync(`${ROOT}/.env.providers`, 'utf8').split('\n')
  .filter(l => l.includes('=') && !l.trim().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const KEY = env.OPENROUTER_API_KEY;
if (!KEY && COMMAND !== 'report') { console.error('OPENROUTER_API_KEY is missing from .env.providers'); process.exit(2); }
const redact = text => KEY ? String(text).replaceAll(KEY, '[key]') : String(text);

/** The papers: compiled reader bundles (device-route compiles for the October 2026 ones, see reader-device-compile.mjs). */
const PAPERS = {
  dpo: { bundle: '.artifacts/bundles/ecbc0a04588f', id: '2305.18290', revision: 3 },
  mamba: { bundle: '.artifacts/bundles/1c734458ee39', id: '2312.00752', revision: 2 },
  muon: { bundle: '.artifacts/bakeoff/bundles/2610.19844v1', id: '2610.19844', revision: 1 },
  prism: { bundle: '.artifacts/bakeoff/bundles/2610.14704v1', id: '2610.14704', revision: 1 },
  apertus: { bundle: '.artifacts/bakeoff/bundles/2610.15542v1', id: '2610.15542', revision: 1 },
};

/** Contestants: OpenRouter id, reasoning effort (where the model takes one) and the maker's own endpoint. */
const MODELS = {
  'sonnet-medium': { id: 'anthropic/claude-sonnet-5.5', effort: 'medium', provider: 'anthropic' },
  'haiku-medium': { id: 'anthropic/claude-haiku-5.5', effort: 'medium', provider: 'anthropic' },
  'haiku-high': { id: 'anthropic/claude-haiku-5.5', effort: 'high', provider: 'anthropic' },
  'luna-high': { id: 'openai/gpt-6-luna', effort: 'high', provider: 'openai' },
  'sol-low': { id: 'openai/gpt-6.1-sol', effort: 'low', provider: 'openai' },
  'sol-medium': { id: 'openai/gpt-6.1-sol', effort: 'medium', provider: 'openai' },
  'gemini-flash-medium': { id: 'google/gemini-3.8-flash', effort: 'medium', provider: 'google-ai-studio' },
  'argon-medium': { id: 'google/gemini-4-argon', effort: 'medium', provider: 'google-ai-studio' },
  'mimo-pro': { id: 'xiaomi/mimo-v2.6-pro', effort: null, provider: 'xiaomi' },
  'mimo-flash': { id: 'xiaomi/mimo-v2.6-flash', effort: null, provider: 'xiaomi' },
  'glm-flash': { id: 'z-ai/glm-5.3-flash', effort: null, provider: 'z-ai' },
  'qwen-flash': { id: 'qwen/qwen3.8-flash', effort: null, provider: 'alibaba' },
  'deepseek-flash': { id: 'deepseek/deepseek-v4.1-flash', effort: null, provider: 'deepseek' },
};
const JUDGES = {
  opus: { id: 'anthropic/claude-opus-5.5', effort: 'high', provider: 'anthropic' },
  sol: { id: 'openai/gpt-6.1-sol', effort: 'high', provider: 'openai' },
};
// Explicit cache breakpoints only reach these makers; the others cache automatically.
const BREAKPOINTS = new Set(['anthropic', 'google-ai-studio']);

const papers = {};
function paper(key) {
  if (papers[key]) return papers[key];
  const meta = PAPERS[key]; if (!meta) throw new Error(`unknown paper ${key}`);
  const dir = `${ROOT}/${meta.bundle}`;
  const index = JSON.parse(readFileSync(`${dir}/reader.json`, 'utf8'));
  const manifest = JSON.parse(readFileSync(`${dir}/manifest.json`, 'utf8'));
  return papers[key] = { key, ...meta, dir, index, manifest, text: buildPaperContext(index) };
}

const { buildPaperContext, CITATION_PATTERN } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
const chat = await import(`${ROOT}/supabase/functions/_shared/chat.ts`);
const { visualRequest } = await import(`${ROOT}/supabase/functions/_shared/chat-visual.ts`);
const { figureLookRequest, figurePartsRequest, figureImages: checkFigures } = await import(`${ROOT}/supabase/functions/_shared/chat-figures.ts`);

function questions() {
  const all = readdirSync(QUESTIONS_DIR).filter(f => f.endsWith('.json')).flatMap(f => JSON.parse(readFileSync(`${QUESTIONS_DIR}/${f}`, 'utf8')));
  const only = list('questions');
  return only ? all.filter(q => only.includes(q.id)) : all;
}

// ---------- Figures, prepared as the app sends them (JPEG on white, long side ≤ 1,568 px, ≤ 1.15 MP) ----------
function figureFor(p, n) {
  const figure = p.index.figures[n - 1]; if (!figure) throw new Error(`${p.key}: no figure ${n}`);
  const path = figure.asset_paths[0];
  const member = p.manifest.members.find(m => m.path === path);
  const dir = `${OUT}/figures`; mkdirSync(dir, { recursive: true });
  const file = `${dir}/${p.key}-${n}.jpg`;
  if (!existsSync(file)) {
    const scale = Math.min(1, 1568 / Math.max(member.width, member.height), Math.sqrt(1.15e6 / (member.width * member.height)));
    const side = Math.max(8, Math.floor(Math.max(member.width, member.height) * scale));
    execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '85', '-Z', String(side), `${p.dir}/${path}`, '--out', file], { stdio: 'ignore' });
  }
  const dims = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', file], { encoding: 'utf8' });
  const width = Number(/pixelWidth: (\d+)/.exec(dims)[1]), height = Number(/pixelHeight: (\d+)/.exec(dims)[1]);
  const label = /^\s*((?:Figure|Fig\.|Table)\s*\d+)/i.exec(figure.caption)?.[1] ?? `Figure ${n}`;
  return { id: `F${n}`, paragraph: p.index.blocks.findIndex(b => b.id === figure.block_id) + 1, caption: figure.caption.slice(0, 1200),
    media_type: 'image/jpeg', data: readFileSync(file).toString('base64'), width, height, label };
}
function figureByLabel(p, label) {
  const n = p.index.figures.findIndex(f => new RegExp(`^\\s*${label.replace(' ', '\\s*')}\\b`, 'i').test(f.caption));
  return n >= 0 ? figureFor(p, n + 1) : null;
}

// ---------- The server's own request (runChat with stub dependencies) ----------
async function serverParams(p, question, figures) {
  const captured = [];
  const errors = [];
  const deps = {
    accountID: 'aaaaaaaa-0000-4000-8000-00000000b0f0', nativeSearch: false, webSearch: false,
    rpc: async (name, params) => {
      switch (name) {
        case 'worker_local_chat_context': return { title: p.index.title };
        case 'worker_reserve_chat': return { id: params.p_id, state: 'reserved', replayed: false };
        case 'worker_chat_stop_requested': return false;
        default: return null;
      }
    },
    loadPaper: async () => null,
    generate: async (params, stream) => {
      captured.push(params); stream.onText('.');
      return { status: 'complete', failure: null, messageID: 'm', model: params.model, stopReason: 'end_turn', refusalCategory: null,
        attempts: [{ model: params.model, estimated: false, usage: { input: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 1 } }], exact: true };
    },
    sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'),
    log: () => {}, sleep: async () => {},
  };
  const digest = createHash('sha256').update(p.text).digest('hex');
  const body = { operation_id: randomUUID(), consent_version: 'cloud-ai-v3', mode: 'paper',
    local_context: { format: 'reader-local-context-v2', membership_id: randomUUID(), source: 'arxiv', source_id: p.id, revision: p.revision,
      manifest_sha256: digest, source_sha256: digest, text: p.text },
    messages: [{ role: 'user', text: question }], capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'],
    profile: { model: 'sonnet', effort: 'medium', length: 'standard' },
    ...(figures.length ? { figures: figures.map(({ label: _label, ...f }) => f) } : {}) };
  await chat.runChat(deps, body, event => { if (event.event === 'error') errors.push(event.data); }, new AbortController().signal);
  if (!captured.length) throw new Error(`the server built no request: ${JSON.stringify(errors)}`);
  return captured[0];
}

/** Anthropic Messages params → OpenRouter chat completion messages and tools. */
function translate(params, model) {
  const breakpoints = BREAKPOINTS.has(model.provider);
  const system = breakpoints
    ? { role: 'system', content: params.system.map(b => ({ type: 'text', text: b.text, ...(b.cache_control ? { cache_control: b.cache_control } : {}) })) }
    : { role: 'system', content: params.system.map(b => b.text).join('\n\n') };
  const part = block => {
    if (block.type === 'text') return { type: 'text', text: block.text };
    if (block.type === 'image') return { type: 'image_url', image_url: { url: `data:${block.source.media_type};base64,${block.source.data}` } };
    throw new Error(`unexpected content block ${block.type}`);
  };
  const messages = [system, ...params.messages.map(m => ({ role: m.role, content: typeof m.content === 'string' ? m.content : m.content.map(part) }))];
  const tools = (params.tools ?? []).filter(t => t.input_schema).map(t => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.input_schema } }));
  return { messages, tools };
}

// ---------- OpenRouter, streamed (time to first text) ----------
async function* sse(stream) {
  const decoder = new TextDecoder(); let buffer = '';
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let i;
    while ((i = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1);
      if (line.startsWith('data: ')) yield line.slice(6);
    }
  }
}
async function complete(model, messages, tools, maxTokens = 16_000) {
  const body = { model: model.id, messages, ...(tools?.length ? { tools } : {}), stream: true, max_tokens: maxTokens, usage: { include: true },
    ...(model.effort ? { reasoning: { effort: model.effort } } : {}),
    provider: { order: [model.provider], allow_fallbacks: false, require_parameters: true } };
  const started = Date.now();
  let response;
  for (let attempt = 0; ; attempt++) {
    response = await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST',
      headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json', 'X-Title': 'Science Reader model bake-off' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(400_000) }).catch(error => ({ ok: false, status: 0, text: async () => error.message }));
    if (response.ok || attempt >= 2 || ![0, 429, 500, 502, 503, 529].includes(response.status)) break;
    await new Promise(r => setTimeout(r, 5_000 * (attempt + 1)));
  }
  if (!response.ok) return { error: `HTTP ${response.status} ${redact(await response.text()).slice(0, 400)}`, seconds: (Date.now() - started) / 1000 };
  let text = '', reasoning = 0, firstText = null, firstToken = null, finish = null, usage = null, provider = null, error = null;
  const calls = [];
  for await (const data of sse(response.body)) {
    if (data === '[DONE]') break;
    let event; try { event = JSON.parse(data); } catch { continue; }
    if (event.error) { error = redact(event.error.message ?? JSON.stringify(event.error)).slice(0, 400); break; }
    provider ??= event.provider ?? null;
    const choice = event.choices?.[0]; const delta = choice?.delta ?? {};
    if (delta.reasoning) { reasoning += delta.reasoning.length; firstToken ??= Date.now(); }
    if (delta.content) { text += delta.content; firstText ??= Date.now(); firstToken ??= Date.now(); }
    for (const call of delta.tool_calls ?? []) {
      const slot = calls[call.index ?? 0] ??= { name: '', arguments: '' };
      if (call.function?.name) slot.name += call.function.name;
      if (call.function?.arguments) slot.arguments += call.function.arguments;
      firstToken ??= Date.now();
    }
    if (choice?.finish_reason) finish = choice.finish_reason;
    if (event.usage) usage = event.usage;
  }
  const seconds = (t) => t ? Number(((t - started) / 1000).toFixed(1)) : null;
  return { text, toolCalls: calls.filter(Boolean).map(c => { let input = null; try { input = JSON.parse(c.arguments || '{}'); } catch { /* invalid */ } return { name: c.name, input, raw: input ? undefined : c.arguments.slice(0, 500) }; }),
    finish, usage, provider, error, reasoningChars: reasoning, firstText: seconds(firstText), firstToken: seconds(firstToken), seconds: seconds(Date.now()) };
}
const costOf = usage => Number(usage?.cost ?? 0);

// ---------- run ----------
let spent = 0;
function spentSoFar() {
  let total = 0;
  for (const kind of ['runs', 'judge']) {
    const base = `${OUT}/${kind}`; if (!existsSync(base)) continue;
    for (const dir of readdirSync(base)) for (const f of readdirSync(`${base}/${dir}`)) total += JSON.parse(readFileSync(`${base}/${dir}/${f}`, 'utf8')).cost ?? 0;
  }
  return total;
}

function checks(p, answer, figures) {
  const cites = [...answer.text.matchAll(CITATION_PATTERN)].map(m => Number(m[1]));
  const visual = answer.toolCalls.find(c => c.name === 'create_visual');
  const diagram = answer.toolCalls.find(c => c.name === 'create_diagram');
  const parts = answer.toolCalls.find(c => c.name === 'show_figure_parts');
  return { citations: cites.length, citations_resolvable: cites.filter(n => n >= 1 && n <= p.index.blocks.length).length,
    visual: visual ? !!visualRequest(visual.input) : null, diagram: diagram ? !!chat.diagramRequest(diagram.input) : null,
    figure_parts: parts ? !!figurePartsRequest(parts.input, checkFigures(figures.map(({ label: _l, ...f }) => f))) : null,
    characters: answer.text.length };
}

async function ask(name, model, q) {
  const file = `${OUT}/runs/${name}/${q.id}.json`;
  if (existsSync(file)) { const done = JSON.parse(readFileSync(file, 'utf8')); if (!done.error) return done; }
  const p = paper(q.paper);
  let figures = q.figure ? [figureFor(p, q.figure)] : [];
  let params = await serverParams(p, q.question, figures);
  let { messages, tools } = translate(params, model);
  let answer = await complete(model, messages, tools);
  const rounds = [answer];
  // A figure request: the device attaches that figure and asks again (never twice).
  const look = !figures.length && !answer.error ? answer.toolCalls.find(c => c.name === 'look_at_figure') : null;
  const wanted = look ? figureLookRequest(look.input) : null;
  const shown = wanted ? figureByLabel(p, wanted.figure) : null;
  if (shown) {
    figures = [shown];
    params = await serverParams(p, q.question, figures);
    ({ messages, tools } = translate(params, model));
    answer = await complete(model, messages, tools);
    rounds.push(answer);
  }
  const record = { model: name, openrouter_id: model.id, effort: model.effort, question: q.id, paper: q.paper, type: q.type,
    looked_at: shown?.label ?? null, figure_attached: figures[0]?.label ?? null,
    text: answer.text, tool_calls: answer.toolCalls, finish: answer.finish, provider: answer.provider, error: answer.error ?? null,
    first_text_s: rounds[0].firstText, first_token_s: rounds[0].firstToken, total_s: rounds.reduce((s, r) => s + (r.seconds ?? 0), 0),
    usage: rounds.map(r => r.usage), cost: rounds.reduce((s, r) => s + costOf(r.usage), 0),
    checks: answer.error ? null : checks(p, answer, figures), ran_at: new Date().toISOString() };
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(record, null, 1));
  spent += record.cost;
  const u = answer.usage ?? {};
  console.log(`${name.padEnd(20)} ${q.id.padEnd(22)} ${record.error ? `ERROR ${record.error}` : `$${record.cost.toFixed(4)} in ${u.prompt_tokens ?? '?'} (cached ${u.prompt_tokens_details?.cached_tokens ?? 0}) out ${u.completion_tokens ?? '?'} (reasoning ${u.completion_tokens_details?.reasoning_tokens ?? '?'}) first ${record.first_text_s ?? '-'} s, ${record.total_s.toFixed(1)} s ${record.provider ?? ''}${shown ? ` looked at ${shown.label}` : ''} cites ${record.checks.citations_resolvable}/${record.checks.citations}`}`);
  return record;
}

async function run() {
  const names = list('models') ?? Object.keys(MODELS);
  const qs = questions();
  spent = spentSoFar();
  console.log(`${names.length} models × ${qs.length} questions; spent so far $${spent.toFixed(2)} (cap $${CAP_USD})`);
  // Models in parallel; each model's questions in order, paper by paper, so its cache warms as a reader's would.
  const queue = [...names];
  const worker = async () => {
    for (let name; (name = queue.shift());) {
      const model = MODELS[name]; if (!model) { console.log(`unknown model ${name}`); continue; }
      for (const q of qs) {
        if (spent >= CAP_USD) { console.log(`cap reached ($${spent.toFixed(2)}); stopping ${name}`); return; }
        try { await ask(name, model, q); } catch (error) { console.log(`${name} ${q.id} FAILED ${redact(error.stack ?? error)}`); }
      }
    }
  };
  await Promise.all(Array.from({ length: Number(arg('concurrency', '6')) }, worker));
  console.log(`done; spent $${spentSoFar().toFixed(2)}`);
}

// ---------- judge ----------
function seeded(seed) { let x = createHash('sha256').update(seed).digest().readUInt32LE(0) || 1; return () => ((x ^= x << 13, x ^= x >>> 17, x ^= x << 5) >>> 0) / 2 ** 32; }
function shuffle(items, seed) { const r = seeded(seed), a = [...items]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }
function rendered(record) {
  const parts = [record.text.trim() || '(no text)'];
  for (const call of record.tool_calls ?? []) {
    if (call.name === 'create_diagram') parts.push(`[Diagram shown to the reader — ${call.input?.title ?? ''}]\n${String(call.input?.source ?? call.raw ?? '').slice(0, 3000)}`);
    else if (call.name === 'create_visual') parts.push(`[Visual shown to the reader — ${call.input?.title ?? ''}; its text:]\n${String(call.input?.html ?? call.raw ?? '').replace(/<style[\s\S]*?<\/style>/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 3000)}`);
    else if (call.name === 'show_figure_parts') parts.push(`[Figure parts shown to the reader]\n${JSON.stringify(call.input ?? call.raw).slice(0, 3000)}`);
    else parts.push(`[Tool call ${call.name}]`);
  }
  if (record.looked_at) parts.unshift(`(The model asked to see ${record.looked_at}; it was attached and the question asked again.)`);
  return parts.join('\n\n');
}
const RUBRIC = `You grade answers written by different AI models to a learner's question about one scientific paper. The models saw the
paper exactly as you do (each block begins with its paragraph marker [¶N]) and were told to cite paragraphs as [¶N]. You are
given a reference answer and key points written and checked by a careful expert from the paper; trust the paper itself over
the reference if they ever disagree, and say so.

Grade every answer independently and strictly, on 0–10 scales:
- correctness: are its claims about the paper (and its maths) right? A wrong number, equation, step or reading of the figure
  costs heavily. For an unanswerable question, the answer must say the paper does not give it; a made-up answer scores ≤2.
  For a false premise, the answer must correct it; going along with it scores ≤3.
- completeness: does it cover the key points the question needs (list which key points it hits)?
- faithfulness: does it avoid claims the paper does not support (invented results, numbers, details, citations to the wrong
  place)? Outside knowledge clearly marked as such is fine.
- citations: do its [¶N] markers point to paragraphs that actually support the sentence they follow? Check them against the
  paper. No citations at all scores ≤3; plausible but wrong paragraphs score low.
- clarity: is it clear, well-organized and at the right length for a learner on a phone? Padding and repetition cost.
- overall: your holistic 0–10 judgment of how good this answer is for the learner, weighting correctness and faithfulness most.
Diagrams and visuals are shown to the reader as drawn; judge whether their content is correct and helpful.
Do not reward length for its own sake. Do not guess which model wrote which answer.

Reply with JSON only, no prose before or after:
{"grades":[{"label":"A","key_points_hit":[0,2],"errors":["short description of each wrong or unsupported claim"],
 "correctness":0,"completeness":0,"faithfulness":0,"citations":0,"clarity":0,"overall":0,"comment":"one or two sentences"}]}`;

async function judgeQuestion(judgeName, judge, q) {
  const file = `${OUT}/judge/${judgeName}/${q.id}.json`;
  if (existsSync(file)) { const done = JSON.parse(readFileSync(file, 'utf8')); if (!done.error) return done; }
  const dir = `${OUT}/runs`;
  const records = readdirSync(dir).map(m => `${dir}/${m}/${q.id}.json`).filter(existsSync).map(f => JSON.parse(readFileSync(f, 'utf8'))).filter(r => !r.error);
  if (!records.length) return null;
  const order = shuffle(records, `${q.id}:${judgeName}`);
  const labels = order.map((_, i) => String.fromCharCode(65 + i));
  const p = paper(q.paper);
  const breakpoints = BREAKPOINTS.has(judge.provider);
  const paperText = `<paper title="${p.index.title.replace(/"/g, ' ')}">\n${p.text}\n</paper>`;
  const system = breakpoints ? [{ type: 'text', text: RUBRIC }, { type: 'text', text: paperText, cache_control: { type: 'ephemeral' } }] : `${RUBRIC}\n\n${paperText}`;
  const keyPoints = q.key_points.map((k, i) => `${i}. ${k.point} (¶${k.paragraphs.join(', ¶')})`).join('\n');
  const figure = q.figure ? figureFor(p, q.figure) : null;
  const prompt = [
    `Question (${q.type}${figure ? `; ${figure.label} was attached as an image, shown here too` : ''}):\n${q.question}`,
    `Reference answer:\n${q.reference}`, `Key points (numbered from 0):\n${keyPoints}`,
    `Errors to penalize:\n- ${q.errors_to_penalize.join('\n- ')}`, q.notes ? `Notes for the grader:\n${q.notes}` : null,
    ...order.map((r, i) => `===== Answer ${labels[i]} =====\n${rendered(r)}`),
    `Grade answers ${labels.join(', ')}.`,
  ].filter(Boolean).join('\n\n');
  const content = figure ? [{ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${figure.data}` } }, { type: 'text', text: prompt }] : prompt;
  const reply = await complete(judge, [{ role: 'system', content: system }, { role: 'user', content }], null, 32_000);
  let grades = null;
  if (!reply.error) { try { grades = JSON.parse(reply.text.slice(reply.text.indexOf('{'), reply.text.lastIndexOf('}') + 1)).grades; } catch { /* below */ } }
  const record = { judge: judgeName, question: q.id, labels: Object.fromEntries(order.map((r, i) => [labels[i], r.model])),
    grades, error: reply.error ?? (grades ? null : `unparseable: ${reply.text.slice(0, 300)}`), cost: costOf(reply.usage), usage: reply.usage, raw: grades ? undefined : reply.text };
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(record, null, 1));
  console.log(`${judgeName} ${q.id.padEnd(22)} ${record.error ? `ERROR ${record.error}` : `$${record.cost.toFixed(4)} ${order.length} answers`}`);
  return record;
}

async function judgeAll() {
  const judgeName = arg('judge', 'opus'); const judge = JUDGES[judgeName];
  if (!judge) throw new Error(`unknown judge ${judgeName}`);
  const qs = questions(); spent = spentSoFar();
  console.log(`${judgeName} grades ${qs.length} questions; spent so far $${spent.toFixed(2)} (cap $${CAP_USD})`);
  const queue = [...qs];
  const worker = async () => {
    for (let q; (q = queue.shift());) {
      if (spentSoFar() >= CAP_USD) { console.log('cap reached; stopping'); return; }
      try { await judgeQuestion(judgeName, judge, q); } catch (error) { console.log(`${q.id} FAILED ${redact(error.stack ?? error)}`); }
    }
  };
  await Promise.all(Array.from({ length: Number(arg('concurrency', '3')) }, worker));
  console.log(`done; spent $${spentSoFar().toFixed(2)}`);
}

// ---------- report ----------
function report() {
  const qs = questions(); const byId = Object.fromEntries(qs.map(q => [q.id, q]));
  const runs = {}; const runDir = `${OUT}/runs`;
  for (const m of existsSync(runDir) ? readdirSync(runDir) : []) for (const f of readdirSync(`${runDir}/${m}`)) {
    const r = JSON.parse(readFileSync(`${runDir}/${m}/${f}`, 'utf8')); if (byId[r.question]) (runs[m] ??= {})[r.question] = r;
  }
  const grades = {}; const judgeDir = `${OUT}/judge`;
  for (const j of existsSync(judgeDir) ? readdirSync(judgeDir) : []) for (const f of readdirSync(`${judgeDir}/${j}`)) {
    const r = JSON.parse(readFileSync(`${judgeDir}/${j}/${f}`, 'utf8'));
    for (const g of r.grades ?? []) { const model = r.labels[g.label]; if (model) ((grades[model] ??= {})[r.question] ??= {})[j] = g; }
  }
  const mean = xs => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
  const median = xs => { if (!xs.length) return null; const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };
  const rows = Object.keys(runs).map(model => {
    const rs = Object.values(runs[model]);
    const ok = rs.filter(r => !r.error);
    const overall = Object.entries(grades[model] ?? {}).map(([, byJudge]) => mean(Object.values(byJudge).map(g => g.overall)));
    const field = name => mean(Object.values(grades[model] ?? {}).flatMap(byJudge => Object.values(byJudge).map(g => g[name])));
    const byType = {};
    for (const [qid, byJudge] of Object.entries(grades[model] ?? {})) (byType[byId[qid].type] ??= []).push(mean(Object.values(byJudge).map(g => g.overall)));
    return { model, answered: ok.length, failed: rs.length - ok.length, overall: mean(overall), correctness: field('correctness'), faithfulness: field('faithfulness'),
      citations: field('citations'), completeness: field('completeness'), clarity: field('clarity'),
      cost_total: rs.reduce((s, r) => s + (r.cost ?? 0), 0), cost_per_answer: mean(ok.map(r => r.cost ?? 0)),
      first_text_median_s: median(ok.map(r => r.first_text_s ?? r.first_token_s).filter(x => x != null)), total_median_s: median(ok.map(r => r.total_s)),
      cites_resolvable: mean(ok.map(r => r.checks?.citations ? r.checks.citations_resolvable / r.checks.citations : 0)),
      by_type: Object.fromEntries(Object.entries(byType).map(([t, xs]) => [t, mean(xs)])) };
  }).sort((a, b) => (b.overall ?? -1) - (a.overall ?? -1));
  const f = (x, d = 1) => x == null ? '–' : x.toFixed(d);
  const lines = ['| Model | Overall | Correct | Faithful | Citations | Complete | Clear | $ per answer | First text (median s) | Answered |', '|---|---|---|---|---|---|---|---|---|---|',
    ...rows.map(r => `| ${r.model} | ${f(r.overall)} | ${f(r.correctness)} | ${f(r.faithfulness)} | ${f(r.citations)} | ${f(r.completeness)} | ${f(r.clarity)} | ${f(r.cost_per_answer, 4)} | ${f(r.first_text_median_s)} | ${r.answered}/${r.answered + r.failed} |`)];
  const types = [...new Set(qs.map(q => q.type))];
  lines.push('', `| Model | ${types.join(' | ')} |`, `|---|${types.map(() => '---').join('|')}|`, ...rows.map(r => `| ${r.model} | ${types.map(t => f(r.by_type[t])).join(' | ')} |`));
  mkdirSync(OUT, { recursive: true });
  writeFileSync(`${OUT}/report.md`, lines.join('\n') + '\n');
  writeFileSync(`${OUT}/report.json`, JSON.stringify({ generated_at: new Date().toISOString(), rows, grades, questions: qs.map(q => q.id) }, null, 1));
  console.log(lines.join('\n'));
}

// `dry`: the requests each question would send (sizes, tools, figure), without calling anything.
async function dry() {
  for (const q of questions()) {
    const p = paper(q.paper);
    const figures = q.figure ? [figureFor(p, q.figure)] : [];
    const params = await serverParams(p, q.question, figures);
    const { messages, tools } = translate(params, MODELS['haiku-medium']);
    const chars = JSON.stringify(messages).length;
    console.log(`${q.id.padEnd(22)} system ${params.system.map(b => b.text.length).join('+')} chars, ${messages.length} messages, ${chars} request chars, tools ${tools.map(t => t.function.name).join(',')}${figures.length ? `, ${figures[0].label} ${figures[0].width}×${figures[0].height}` : ''}, max_tokens ${params.max_tokens}`);
  }
}

if (COMMAND === 'dry') await dry();
else if (COMMAND === 'run') await run();
else if (COMMAND === 'judge') await judgeAll();
else if (COMMAND === 'report') report();
else { console.error('usage: node scripts/model-bakeoff.mjs run|judge|report [--models=…] [--questions=…] [--judge=opus|sol] [--cap=18]'); process.exit(2); }
