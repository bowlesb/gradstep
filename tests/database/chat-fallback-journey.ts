// Zero-spend chat journey against the real migrated database (migration 0163, JUDGMENT_LOG 55): the actual chat code
// (runChat, the fallback, admittedModelCalls and the OpenRouter adapter) calls the real SQL functions through psql with
// PostgREST-style named arguments; OpenRouter is a local fake. Staging, 2026-10-28 14:12 and 14:14 UTC: a paper explainer
// on Gemini Flash was silent for 25 s, "Switching to Claude Haiku 5.5…" was said, Haiku's admission was denied
// (`operation_ceiling`) and the reader got `provider_unavailable`. Here every action that has a fallback is run with a
// silent Flash (and the explainer with refusals that cost nothing, and a 502), and the database is read back: Haiku
// answers inside the hold the reader accepted, the reader pays only Haiku's answer, the silent ceiling is Gradstep's.
// Run by tests/database/chat_fallback_journey.py on a disposable database.
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { openRouterChat } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { admittedModelCalls } from '../../supabase/functions/_shared/provider-spending.ts';
import { RpcFailure, runChat, type ChatDependencies, type ChatEvent } from '../../supabase/functions/_shared/chat.ts';
import { creditsFor, retryOnceWhenBusy } from '../../supabase/functions/_shared/inference.ts';
import { GEMINI_OPENROUTER_MODEL } from '../../supabase/functions/_shared/gemini-pricing.ts';

const [psql, port, db] = [process.env.CHAT_JOURNEY_PSQL!, process.env.CHAT_JOURNEY_PORT!, process.env.CHAT_JOURNEY_DB!];
if (!psql || !/^\d+$/.test(port ?? '') || !/^science_reader_test_/.test(db ?? '')) throw new Error('a disposable loopback database is required');
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG')));

function sql(text: string): string {
  const result = spawnSync(psql, ['-h', '127.0.0.1', '-p', port, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db], { input: text, encoding: 'utf8', env });
  if (result.status !== 0) {
    const message = /ERROR:\s+([^\n]+)/.exec(result.stderr)?.[1]?.trim() ?? 'database_error';
    throw new RpcFailure(/^[a-z_]{1,64}$/.test(message) ? message : `database_error: ${message}`);
  }
  return result.stdout.trim();
}
const json = <T>(text: string) => JSON.parse(text) as T;
function literal(value: unknown): string {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return String(value);
  if (typeof value === 'string') return `'${value.replace(/'/g, "''")}'`;
  return `'${JSON.stringify(value).replace(/'/g, "''")}'`;
}
/** As PostgREST calls it for the service role: named arguments; the RAISE text is the error's reason. */
const rpc: ChatDependencies['rpc'] = async (name, params) => {
  if (!/^worker_[a-z0-9_]+$/.test(name)) throw new Error(`unexpected rpc ${name}`);
  const args = Object.entries(params).map(([k, v]) => `${k} => ${literal(v)}`).join(', ');
  const out = sql(`set role service_role;\nselect public.${name}(${args});\n`);
  if (out === '') return null;
  if (out === 't' || out === 'f') return out === 't';
  try { return JSON.parse(out); } catch { return out; }
};
const sha256Hex = async (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');

const accountID = randomUUID();
sql(`insert into auth.users(id,email,email_confirmed_at) values('${accountID}','chat-journey-163@gradstep.test.org',now());
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('${accountID}','adjustment','chat-journey-163',1000,now()-interval '1 day',null,'Chat fallback journey');`);

// The fake OpenRouter: Flash silent (headers, then keep-alive comments only until the request is given up on) or refusing;
// Haiku answers at once with OpenRouter's billed cost (500 µ$, one credit; 50 µ$ for a title or suggestions).
const usage = { prompt_tokens: 1000, completion_tokens: 200, prompt_tokens_details: { cached_tokens: 0, cache_write_tokens: 0 }, cost: 0.0005 };
const chunk = (id: string, model: string, delta: unknown, rest: Record<string, unknown> = {}) => ({ id, model, provider: 'Google', choices: [{ delta, finish_reason: null }], ...rest });
let generation = 0;
function fakeOpenRouter(flash: 'silent' | 429 | 503 | 502, sent: string[]): typeof fetch {
  return async (url, init) => {
    if (String(url).includes('/generation?id=')) return new Response(null, { status: 404 });
    const body = JSON.parse(String(init?.body)) as { model: string; max_tokens: number };
    const id = `gen-journey-${++generation}`;
    sent.push(body.model);
    if (body.model === GEMINI_OPENROUTER_MODEL && flash === 'silent') {
      return new Response(new ReadableStream({ start(c) {
        c.enqueue(new TextEncoder().encode(': OPENROUTER PROCESSING\n\n'));
        init?.signal?.addEventListener('abort', () => c.error(new DOMException('stopped', 'AbortError')), { once: true });
      } }), { headers: { 'x-generation-id': id } });
    }
    if (body.model === GEMINI_OPENROUTER_MODEL) {
      return new Response(JSON.stringify({ error: { code: flash, message: 'not now' } }), { status: flash, headers: { 'x-generation-id': id } });
    }
    const events = [chunk(id, body.model, { content: 'Haiku wrote this part [¶2].' }),
      // The title and suggestions (small allowances) cost a tenth of the answer, inside their own ceilings.
      chunk(id, body.model, {}, { choices: [{ delta: {}, finish_reason: 'stop' }], usage: body.max_tokens > 1_000 ? usage : { ...usage, cost: 0.00005 } })];
    const bytes = new TextEncoder().encode(events.map(e => `data: ${JSON.stringify(e)}\n\n`).join('') + 'data: [DONE]\n\n');
    return new Response(new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); } }), { headers: { 'x-generation-id': id } });
  };
}

const image = { id: 'F1', paragraph: 2, caption: 'Figure 2: Left. The frontier.', media_type: 'image/jpeg',
  data: Buffer.from([0xff, 0xd8, 0xff, 0xe0, ...Array(20).fill(7)]).toString('base64'), width: 10, height: 10 };
const device = ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'];
const paperText = '[¶1] Intro.\n\n[¶2] Figure 2: Left. The frontier. Softmax normalises the scores.\n\n[¶3] L = -log σ(β x)';
const local = (text = paperText) => ({ mode: 'paper', local_context: { format: 'reader-local-context-v2', source: 'local', text } });
// About 168 KB: Haiku's byte-estimated prompt passes its 100k-token tier, so its ceiling is above Flash's (the 14:12 case).
const longPaper = `[¶1] ${'The model and its loss. '.repeat(7_000)}`;
const explainer = (text?: string) => ({ ...local(text), action: 'paper_explainer', capabilities: device, messages: [{ role: 'user', text: 'Explain this paper' }] });
interface Case { name: string; flash: 'silent' | 429 | 503 | 502; body: Record<string, unknown>; sides?: boolean }
const CASES: Case[] = [
  { name: 'paper explainer, long paper (the 14:12 case)', flash: 'silent', body: explainer(longPaper) },
  { name: 'paper explainer', flash: 'silent', body: explainer() },
  { name: 'Go deeper (paper_concept)', flash: 'silent', body: { ...local(), action: 'paper_concept', capabilities: device,
    selection: { quote: 'Concept: Softmax\nKind: background the paper assumes' }, messages: [{ role: 'user', text: 'Go deeper: Softmax' }] } },
  { name: 'figure explainer', flash: 'silent', body: { ...local(), action: 'figure', capabilities: device, selection: { quote: image.caption },
    figures: [image], messages: [{ role: 'user', text: 'Figure 2' }] } },
  { name: 'equation explainer', flash: 'silent', body: { ...local(), action: 'equation', selection: { quote: 'L = -\\log \\sigma(\\beta x)' },
    messages: [{ role: 'user', text: 'Equation (1)' }] } },
  { name: 'Study turn', flash: 'silent', body: { ...local(), action: 'study', messages: [{ role: 'user', text: 'Quiz me and help me learn this paper.' }] } },
  { name: 'paper answer', flash: 'silent', body: { ...local(), messages: [{ role: 'user', text: 'What does the loss do?' }] } },
  { name: 'general answer with its title and suggestions', flash: 'silent', body: { mode: 'general', topic_title: true, follow_ups: true,
    messages: [{ role: 'user', text: 'What does the dot mean?' }] }, sides: true },
  { name: 'paper explainer, Flash refused 429', flash: 429, body: explainer() },
  { name: 'paper explainer, Flash refused 503', flash: 503, body: explainer() },
  { name: 'paper explainer, Flash 502 before its first output', flash: 502, body: explainer() },
];

async function ask(body: Record<string, unknown>, flash: Case['flash'], operationID = randomUUID()) {
  const sent: string[] = [], events: ChatEvent[] = [], logs: Record<string, unknown>[] = [];
  const feature = typeof body.action === 'string' ? body.action : 'chat';
  const router = openRouterChat({ apiKey: 'fixture', sleep: async () => {}, firstDataMs: 2_000, waitingMs: 1_000, receiptWaitMs: 50,
    fetch: fakeOpenRouter(flash, sent) });
  const generate = retryOnceWhenBusy(admittedModelCalls({ accountID, operationID, feature, rpc, sha256Hex }, router), { sleep: async () => {}, random: () => 0.5 });
  const deps: ChatDependencies = { accountID, rpc, sha256Hex, generate, gemini: true, fallback: true, fallbackFirstDataMs: { view: 300, answer: 300 },
    loadPaper: async () => null, log: e => logs.push(e), sleep: async () => {},
    aiSwitches: async () => await rpc('worker_ai_switches', {}) as never };
  await runChat(deps, { operation_id: operationID, consent_version: 'cloud-ai-v6', profile: { model: 'gemini', effort: 'auto', length: 'standard' }, ...body },
    e => events.push(e), new AbortController().signal);
  return { operationID, sent, events, logs };
}
interface Ledger {
  op: { state: string; credit_ceiling: number; spend_ceiling_microusd: number; actual_credits: number; provider_liability_microusd: number };
  quote: { credit_ceiling: number; spend_ceiling_microusd: number };
  attempts: { model: string; state: string; ceiling: number; failure: string | null; feature: string | null }[];
  carried: { carried_microusd: number; fallback_attempt_id: string }[] | null;
  ending: { ending: string; charged: boolean; credits: number };
  usage: { model: string; credits: number };
}
function ledger(operationID: string): Ledger {
  return json<Ledger>(sql(`select jsonb_build_object(
    'op',(select to_jsonb(o) from app_private.metered_operations o where o.id='${operationID}'),
    'quote',(select to_jsonb(q) from app_private.chat_quotes q where q.operation_id='${operationID}'),
    'attempts',(select jsonb_agg(jsonb_build_object('model',a.model,'state',a.state,'ceiling',a.ceiling_microusd,'failure',a.failure_code,
      'feature',a.transport_metadata->>'feature') order by a.created_at,a.id) from app_private.provider_attempts a where a.operation_id='${operationID}'),
    'carried',(select jsonb_agg(e.details) from app_private.provider_attempt_events e join app_private.provider_attempts a on a.id=e.attempt_id
      where a.operation_id='${operationID}' and e.state='carried'),
    'ending',(select to_jsonb(e) from app_private.chat_endings e where e.operation_id='${operationID}'),
    'usage',(select to_jsonb(u) from app_private.usage_operations('${accountID}',now()-interval '1 day') u where u.id='${operationID}'));`));
}

const results: Record<string, string> = {};
let replayBody: Record<string, unknown> | null = null, replayID = '';
for (const c of CASES) {
  const run = await ask(c.body, c.flash);
  const done = run.events.at(-1)!;
  assert.equal(done.event, 'done', `${c.name}: ${JSON.stringify(done.data)} (sent ${run.sent.join(', ')})`);
  assert.equal((done.data as { model?: string }).model, 'claude-haiku-5-5', c.name);
  assert.equal((done.data as { charged?: boolean }).charged, true, c.name);
  const l = ledger(run.operationID);
  const flash = l.attempts.find(a => a.model === 'gemini-3.8-flash')!, haiku = l.attempts.filter(a => a.model === 'anthropic/claude-haiku-5.5');
  assert.deepEqual(l.attempts.filter(a => a.state === 'denied'), [], `${c.name}: nothing refused (the fallback, the title, the suggestions)`);
  assert.ok(haiku.some(a => a.state === 'succeeded' && a.feature === (typeof c.body.action === 'string' ? c.body.action : 'chat')), c.name);
  const silent = c.flash === 'silent' || c.flash === 502;
  assert.equal(flash.state, silent ? 'unknown' : 'rejected', c.name);
  assert.equal(flash.failure, 'provider_error', c.name);
  // The reader's hold is the quote's, before and after; the provider ceiling grows by the silent ceiling only.
  assert.equal(l.op.state, 'settled', c.name);
  assert.equal(l.op.credit_ceiling, l.quote.credit_ceiling, c.name);
  assert.equal(l.op.spend_ceiling_microusd, l.quote.spend_ceiling_microusd + (silent ? flash.ceiling : 0), c.name);
  assert.deepEqual(l.carried?.map(x => x.carried_microusd) ?? [], silent ? [flash.ceiling] : [], c.name);
  // The reader pays Haiku's answer (and a title it delivered), never the silent attempt, never above the quote.
  if (!c.sides) assert.equal(l.op.actual_credits, creditsFor(500), c.name);
  assert.ok(l.op.actual_credits >= creditsFor(500) && l.op.actual_credits <= l.quote.credit_ceiling, c.name);
  assert.equal(l.op.provider_liability_microusd, silent ? flash.ceiling : 0, `${c.name}: the silent ceiling is Gradstep's liability`);
  assert.deepEqual([l.ending.ending, l.ending.charged], ['completed', true], c.name);
  assert.equal(l.usage.model, 'anthropic/claude-haiku-5.5', `${c.name}: Your AI usage names the model that wrote it`);
  const line = run.logs.find(e => e.event === 'chat_fallback')!;
  assert.equal(line.result, 'answered', c.name); assert.equal(line.carried, silent ? true : undefined, c.name);
  results[c.name] = `${silent ? 'carried' : 'nothing to carry'}; ${l.op.actual_credits} credit(s) of ${l.quote.credit_ceiling}`;
  if (!replayBody) { replayBody = c.body; replayID = run.operationID; }
}

// The device's retry of an operation whose silent attempt was carried is a replay, as for any other.
const replay = await ask(replayBody!, 'silent', replayID);
assert.deepEqual(replay.events.at(-1), { event: 'error', data: { code: 'operation_replayed' } }, JSON.stringify(replay.events.at(-1)));
assert.deepEqual(replay.sent, [], 'a replay sends nothing');

// The month: every hold released, only the silent ceilings still reserved (Gradstep's), no overrun recorded anywhere.
const month = json<{ reserved: number; liability: number; open: number; anomalies: number }>(sql(`select jsonb_build_object(
  'reserved',(select reserved_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
  'liability',(select coalesce(sum(provider_liability_microusd),0) from app_private.metered_operations),
  'open',(select count(*) from app_private.metered_operations where state<>'settled'),
  'anomalies',(select count(*) from app_private.budget_anomalies));`));
assert.equal(month.open, 0);
assert.equal(month.reserved, month.liability, 'the month reserves exactly the unresolved silent ceilings');
assert.equal(month.anomalies, 0, 'no operation passed its ceiling');
for (const [name, result] of Object.entries(results)) console.log(`ok ${name}: ${result}`);
console.log(`${CASES.length} journeys answered by the fallback inside the reader's hold; replay refused; month reserves ${month.reserved} µ$ of silent ceilings`);
