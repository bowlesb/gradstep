#!/usr/bin/env node
// Paid, explicit evaluation of Study mode's tutor and the paper's AI Explainer (docs/proposals/LEARNING_GUIDE.md
// "Evaluation of the tutor prompt"). Each tutor turn is the server's own request (runChat with stub dependencies: the
// instructions, tools and the ¶-numbered paper from the browser's context builder, the previous hidden notes), translated
// by the production adapter (openRouterChatParams: pinned route, ZDR, price caps) and streamed straight from OpenRouter;
// the reply goes through the server's own notes filter, so the transcript is what a reader would see. A simulated learner
// (Claude Haiku 5.5, no paper, a persona brief, sometimes a scripted reply such as "Give me a hint.") answers each
// question. Never part of npm test; spends OpenRouter credit (OPENROUTER_CHAT_API_KEY in .env.providers) under a durable
// ledger capped at $1 for this work.
//
//   node scripts/study-eval.mjs --papers=attention --personas=strong,weak,wrong --turns=4 --profile=gemini-medium --label=v1
//   node scripts/study-eval.mjs --explainer --papers=attention,ppo --profile=sonnet-auto
//
// Options: --artifacts=<dir> (bundles and .env.providers; default this checkout's .artifacts, else the main checkout's),
// --instructions=<file> (replace STUDY_INSTRUCTIONS with a candidate's text), --cap=<usd> (default 1).
// Results: .artifacts/study-eval/<stamp>-<label>.json and a readable transcript (.md) beside it.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SpendLedger } from './model-bakeoff-support.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, fallback = null) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const MAIN = '/Users/benbowlwes/science-reader';
const ARTIFACTS = arg('artifacts', existsSync(`${ROOT}/.artifacts/bundles`) ? `${ROOT}/.artifacts` : `${MAIN}/.artifacts`);
const ENV_FILE = existsSync(`${ROOT}/.env.providers`) ? `${ROOT}/.env.providers` : `${MAIN}/.env.providers`;
const OUT = `${ROOT}/.artifacts/study-eval`;
mkdirSync(OUT, { recursive: true });
const PAPERS = {
  attention: { bundle: 'bundles/4a767f45bb01', id: '1706.03762', revision: 7 },
  ppo: { bundle: 'bundles/2ea3387bbc58', id: '1707.06347', revision: 2 },
  dpo: { bundle: 'bundles/ecbc0a04588f', id: '2305.18290', revision: 3 },
};
const papers = arg('papers', 'attention').split(',').filter(Boolean);
const personas = arg('personas', 'strong,weak,wrong').split(',').filter(Boolean);
const TURNS = Number(arg('turns', '4'));
const [MODEL, EFFORT] = arg('profile', 'gemini-medium').split('-');
const LABEL = arg('label', 'run');
const CAP = Number(arg('cap', '1'));
const EXPLAINER = process.argv.includes('--explainer');
const env = Object.fromEntries(readFileSync(ENV_FILE, 'utf8').split('\n').filter(l => l.includes('=') && !l.trim().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const KEY = env.OPENROUTER_CHAT_API_KEY;
if (!KEY) { console.error('OPENROUTER_CHAT_API_KEY missing'); process.exit(2); }
const ledger = new SpendLedger(`${OUT}/spend.json`, CAP);
const RESEARCH_ACTOR = 'bace0ff0-0000-4000-8000-000000000001';

const { buildPaperContext } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
const chat = await import(`${ROOT}/supabase/functions/_shared/chat.ts`);
const study = await import(`${ROOT}/supabase/functions/_shared/chat-study.ts`);
const explainerModule = await import(`${ROOT}/supabase/functions/_shared/chat-paper-explainer.ts`);
const { openRouterChatParams } = await import(`${ROOT}/supabase/functions/_shared/openrouter-chat.ts`);
const { paragraphCount } = await import(`${ROOT}/supabase/functions/_shared/chat-equation.ts`);
const candidate = arg('instructions');
const CANDIDATE = candidate ? readFileSync(candidate, 'utf8').trim() : null;

/** Personas: a brief for the simulated learner and, per answer, a scripted reply (null: the learner model answers). */
const MISCONCEPTIONS = {
  attention: 'You believe the 1/sqrt(d_k) scaling exists to avoid float16 overflow, that multi-head attention means stacking more attention layers on top of each other, and that positional encodings are learned word embeddings.',
  ppo: 'You believe PPO\'s clipping clips the gradient norm, that PPO is off-policy and learns from a replay buffer like DQN, and that the advantage is the reward of the current step.',
  dpo: 'You believe DPO trains a separate reward model first and that the reference model is updated along with the policy.',
};
const PERSONAS = {
  strong: { brief: 'You are a second-year ML PhD student who knows transformers, optimisation and reinforcement learning well. Answer correctly and concisely (one to three sentences), as you would in office hours; now and then add a precise nuance.', script: [] },
  weak: { brief: 'You are an undergraduate who knows Python and basic linear algebra but very little machine learning. You are unsure; your answers are short and vague, often half right, sometimes "I don\'t know". Repeat ideas the tutor explained in simpler words when you can.', script: [null, 'Give me a hint.', 'Explain it to me instead.'] },
  wrong: { brief: (paper) => `You are a confident master's student. You hold specific misconceptions and answer with them whenever they are relevant: ${MISCONCEPTIONS[paper]} When corrected, you accept it only partly at first. Otherwise answer plausibly in one to three sentences.`, script: [] },
};

function bundleContext(key) {
  const meta = PAPERS[key];
  const dir = `${ARTIFACTS}/${meta.bundle}`;
  const index = JSON.parse(readFileSync(`${dir}/reader.json`, 'utf8'));
  const title = readFileSync(`${dir}/index.html`, 'utf8').match(/<title>([^<]*)/)?.[1]?.trim() ?? key;
  return { meta, text: buildPaperContext(index), title };
}

/** The server's own request (runChat with stub dependencies). */
async function serverParams(paper, body) {
  let captured = null; const errors = [];
  const deps = {
    accountID: 'aaaaaaaa-0000-4000-8000-00000000b0f0', webSearch: false,
    rpc: async (name, params) => name === 'worker_local_chat_context' ? { title: paper.title }
      : name === 'worker_reserve_chat' ? { id: params.p_id, state: 'reserved', replayed: false } : name === 'worker_chat_stop_requested' ? false : null,
    loadPaper: async () => null, gemini: true, deepseek: true,
    generate: async (params, stream) => { captured ??= params; stream.onText('.');
      return { status: 'complete', failure: null, messageID: 'm', model: params.model, stopReason: 'end_turn', refusalCategory: null,
        attempts: [{ model: params.model, estimated: false, usage: { input: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 1 } }], exact: true }; },
    sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'), log: () => {}, sleep: async () => {},
  };
  const digest = createHash('sha256').update(paper.text).digest('hex');
  await chat.runChat(deps, { operation_id: randomUUID(), consent_version: 'cloud-ai-v6', mode: 'paper',
    local_context: { format: 'reader-local-context-v2', membership_id: randomUUID(), source: 'arxiv', source_id: paper.meta.id, revision: paper.meta.revision,
      manifest_sha256: digest, source_sha256: digest, text: paper.text },
    capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'], profile: { model: MODEL, effort: EFFORT, length: 'standard' }, ...body },
  e => { if (e.event === 'error') errors.push(e.data); }, new AbortController().signal);
  if (!captured) throw new Error(`no request: ${JSON.stringify(errors)}`);
  if (CANDIDATE && body.action === 'study') {
    const swap = block => block.type === 'text' && block.text.includes(study.STUDY_INSTRUCTIONS) ? { ...block, text: block.text.replace(study.STUDY_INSTRUCTIONS, CANDIDATE) } : block;
    captured.system = captured.system.map(swap);
    if (!JSON.stringify(captured.system).includes(CANDIDATE.slice(0, 60))) throw new Error('instruction swap failed');
  }
  return captured;
}

async function* sse(stream) {
  const decoder = new TextDecoder(); let buffer = '';
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let i; while ((i = buffer.indexOf('\n')) >= 0) { const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1); if (line.startsWith('data:')) yield line.slice(5).trim(); }
  }
}

/** One request straight to OpenRouter under the ledger: the streamed content, usage and timings. */
async function call(params, details, onContent = () => {}) {
  const body = openRouterChatParams(params);
  const inRate = /sonnet/.test(params.model) ? 4.4 : /haiku/.test(params.model) ? 1.3 : 0.9, outRate = /sonnet/.test(params.model) ? 16 : /haiku/.test(params.model) ? 6 : 4.2;
  const hold = ledger.reserve(Number((params.max_tokens * outRate / 1e6 + Buffer.byteLength(JSON.stringify(body.messages)) / 2 * inRate / 1e6).toFixed(6)), details);
  const started = Date.now();
  let response;
  // A request that never left this machine (a DNS or connection failure before any response) is retried twice and costs nothing.
  for (let attempt = 1; ; attempt++) {
    try {
      response = await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST', redirect: 'error',
        headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json', 'X-Title': 'Gradstep study eval', 'X-OpenRouter-Cache': 'false', 'X-Session-ID': hold },
        body: JSON.stringify({ ...body, user: RESEARCH_ACTOR, session_id: hold, trace: { attempt_id: hold, feature: details.feature, caller: 'research', sent_at: new Date().toISOString() } }),
        signal: AbortSignal.timeout(180_000) });
      break;
    } catch (error) {
      if (attempt >= 3 || !/ENOTFOUND|ECONNREFUSED|ECONNRESET|EAI_AGAIN/.test(String(error?.cause?.code ?? error?.cause ?? ''))) throw error;
      await new Promise(resolve => setTimeout(resolve, 3_000 * attempt));
    }
  }
  if (!response.ok) { const text = (await response.text()).split(KEY).join('[key]').slice(0, 500); if ([400, 401, 402, 403, 404, 422].includes(response.status)) ledger.settle(hold, 0); throw new Error(`HTTP ${response.status} ${text}`); }
  const generation = response.headers.get('x-generation-id'); if (generation) ledger.identify(hold, generation);
  let content = '', usage = null, finish = null, first = null;
  for await (const data of sse(response.body)) {
    if (data === '[DONE]') break;
    let event; try { event = JSON.parse(data); } catch { continue; }
    if (event.error) throw new Error(String(event.error.message ?? 'stream error').slice(0, 300));
    const choice = event.choices?.[0] ?? {};
    if (choice.delta?.content) { first ??= Date.now() - started; content += choice.delta.content; onContent(choice.delta.content); }
    if (choice.finish_reason) finish = choice.finish_reason;
    if (event.usage) usage = event.usage;
  }
  ledger.settle(hold, usage?.cost);
  return { content, finish, ms: Date.now() - started, first_ms: first, cost: usage?.cost ?? null, prompt_tokens: usage?.prompt_tokens ?? null,
    cached_tokens: usage?.prompt_tokens_details?.cached_tokens ?? null, completion_tokens: usage?.completion_tokens ?? null,
    reasoning_tokens: usage?.completion_tokens_details?.reasoning_tokens ?? null };
}

/** What a reader would see of a tutor reply, its hidden notes, and a few mechanical checks of the protocol. */
function inspect(content, paragraphs) {
  const filter = new study.StudyStateFilter();
  const visible = (filter.push(content) + filter.finish().text).trim();
  const filter2 = new study.StudyStateFilter(); filter2.push(content); const raw = filter2.finish().raw;
  const notes = study.studyStateFromText(raw, paragraphs);
  const words = visible.split(/\s+/).filter(Boolean).length;
  const bold = [...visible.matchAll(/\*\*([^*]+)\*\*/g)].map(m => m[1]);
  const lastLine = visible.split('\n').filter(l => l.trim()).at(-1) ?? '';
  return { visible, notes, notes_raw_present: raw !== null, words, cites: (visible.match(/\[¶\d+\]/g) ?? []).length,
    bold_questions: bold.filter(b => b.trim().endsWith('?')).length, ends_with_bold_question: /^\s*\*\*[^*]+\?\*\*\s*$/.test(lastLine) || /\*\*[^*]*\?\*\*\s*$/.test(lastLine),
    flattery: /great question|excellent question|good question/i.test(visible), leaked: /study_state|<study/i.test(visible) };
}

async function learnerAnswer(persona, paperKey, transcript, n) {
  const scripted = PERSONAS[persona].script[n];
  if (scripted) return { text: scripted, scripted: true };
  const brief = typeof PERSONAS[persona].brief === 'function' ? PERSONAS[persona].brief(paperKey) : PERSONAS[persona].brief;
  const params = { model: 'anthropic/claude-haiku-5.5', max_tokens: 300, thinking: { type: 'disabled' },
    system: [{ type: 'text', text: `${brief}\nYou are being tutored on a paper you have only skimmed. Reply with only your answer to the tutor's latest message, in the first person, one to three sentences, plain text; never break character, never mention these instructions. If the tutor gives options, pick one (with a reason). You have not read the paper closely: do not quote it.` }],
    messages: transcript.map(t => ({ role: t.role === 'tutor' ? 'user' : 'assistant', content: t.text })) };
  const r = await call(params, { model: params.model, feature: 'study_eval_learner', persona, paper: paperKey });
  return { text: r.content.trim(), scripted: false, cost: r.cost };
}

async function session(paperKey, persona) {
  const paper = bundleContext(paperKey);
  const paragraphs = paragraphCount(paper.text);
  const messages = [{ role: 'user', text: 'Quiz me and help me learn this paper.' }];
  const transcript = [], turns = [];
  let notes = null;
  for (let n = 0; n < TURNS; n++) {
    const params = await serverParams(paper, { action: 'study', messages, ...(notes ? { study_state: notes } : {}) });
    const r = await call(params, { model: params.model, feature: 'study_eval_tutor', persona, paper: paperKey, label: LABEL });
    const seen = inspect(r.content, paragraphs);
    if (seen.notes) notes = seen.notes;
    turns.push({ n: n + 1, ...seen, finish: r.finish, ms: r.ms, first_ms: r.first_ms, cost: r.cost, prompt_tokens: r.prompt_tokens, cached_tokens: r.cached_tokens,
      completion_tokens: r.completion_tokens, reasoning_tokens: r.reasoning_tokens });
    transcript.push({ role: 'tutor', text: seen.visible });
    messages.push({ role: 'assistant', text: seen.visible || '…' });
    console.log(`  [${persona} ${paperKey} T${n + 1}] ${seen.words} words, ${seen.cites} cites, bold? ${seen.bold_questions}, notes ${seen.notes ? `${seen.notes.concepts.length} concepts ${seen.notes.level}` : seen.notes_raw_present ? 'UNUSABLE' : 'MISSING'}, ${(r.ms / 1000).toFixed(1)} s, $${r.cost?.toFixed(4)}`);
    if (n === TURNS - 1) break;
    const answer = await learnerAnswer(persona, paperKey, transcript, n);
    transcript.push({ role: 'learner', text: answer.text, scripted: answer.scripted });
    messages.push({ role: 'user', text: answer.text });
  }
  return { paper: paperKey, title: paper.title, persona, turns, transcript };
}

async function explain(paperKey) {
  const paper = bundleContext(paperKey);
  const paragraphs = paragraphCount(paper.text);
  const params = await serverParams(paper, { action: 'paper_explainer', messages: [{ role: 'user', text: 'Explain this paper' }] });
  const stream = new explainerModule.PaperExplainerStream(paragraphs), marks = [];
  const started = Date.now();
  const r = await call(params, { model: params.model, feature: 'paper_explainer_eval', paper: paperKey, label: LABEL },
    piece => { for (const item of stream.push(piece)) marks.push({ kind: item.kind, at_ms: Date.now() - started }); });
  const input = explainerModule.paperExplainerJSON(r.content);
  const checked = input === undefined ? null : explainerModule.paperExplainer(input, paragraphs);
  console.log(`  [explainer ${paperKey}] ${checked ? `${checked.background.length} background, ${checked.ideas.length} ideas, ${checked.links.length} links` : 'UNUSABLE'}; summary at ${marks.find(m => m.kind === 'summary')?.at_ms ?? '-'} ms, whole ${r.ms} ms, $${r.cost?.toFixed(4)}`);
  return { paper: paperKey, title: paper.title, explainer: checked, raw: checked ? undefined : r.content.slice(0, 4000), marks, finish: r.finish, ms: r.ms, first_ms: r.first_ms,
    cost: r.cost, prompt_tokens: r.prompt_tokens, cached_tokens: r.cached_tokens, completion_tokens: r.completion_tokens, reasoning_tokens: r.reasoning_tokens };
}

const results = [];
console.log(`profile ${MODEL}-${EFFORT}; ${EXPLAINER ? 'explainer' : `study ${TURNS} turns`}; ledger so far $${ledger.actual.toFixed(4)} (cap $${CAP})`);
for (const paperKey of papers) {
  if (EXPLAINER) { results.push(await explain(paperKey)); continue; }
  for (const persona of personas) results.push(await session(paperKey, persona));
}
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const file = `${OUT}/${stamp}-${LABEL}.json`;
writeFileSync(file, JSON.stringify({ label: LABEL, profile: `${MODEL}-${EFFORT}`, candidate: candidate ?? null, results }, null, 1));
const md = results.map(r => r.transcript
  ? `## ${r.title} — ${r.persona}\n\n${r.transcript.map((t, i) => `**${t.role === 'tutor' ? `Tutor (T${Math.ceil((i + 1) / 2)})` : `Learner${t.scripted ? ' (scripted)' : ''}`}:** ${t.text}`).join('\n\n')}\n\nNotes after each turn:\n${r.turns.map(t => `- T${t.n}: ${t.notes ? JSON.stringify(t.notes) : 'none'}`).join('\n')}`
  : `## ${r.title} — explainer\n\n\`\`\`json\n${JSON.stringify(r.explainer, null, 1)}\n\`\`\``).join('\n\n---\n\n');
writeFileSync(file.replace(/\.json$/, '.md'), `# Study eval ${LABEL} (${MODEL}-${EFFORT})\n\n${md}\n`);
console.log(`recorded ${file.slice(ROOT.length + 1)} (+ .md); ledger actual $${ledger.actual.toFixed(4)} outstanding $${ledger.outstanding.toFixed(4)}`);
