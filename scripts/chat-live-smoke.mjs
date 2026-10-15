#!/usr/bin/env node
// Paid, explicit live check of the chat agent on staging (docs/TESTING.md): one disposable account with synthetic
// credits, the DPO v3 metadata membership (no PDF), then one or two real questions carrying a reader-local-context-v2
// snapshot built with the browser's own context builder. Prints event names, citations (and whether each resolves),
// follow-ups, credits and the answer text; never a token, key or password. Deletes the account at the end through
// account-delete, as a reader would, and confirms the auth user is gone. About $0.25 of provider spend per run.
//
//   node scripts/chat-live-smoke.mjs [--questions=1|2] [--index=.artifacts/bundles/<id>/reader.json]
//
// --questions=2 sends the first suggested follow-up as a second turn (exercises the prompt cache). --index names any
// compiled reader index for arXiv 2305.18290 (default: the DPO bundle under .artifacts/bundles); the server only sees
// its text, so a device-compiled bundle gives the same evidence.
import { existsSync, readFileSync } from 'node:fs';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'coxhjvqpflgxkleydati';
const QUESTIONS = Number(process.argv.find(a => a.startsWith('--questions='))?.split('=')[1] ?? 1);
// --study: a tutored conversation instead (chat-study.ts): the opening turn, a partly right answer, a "don't know"; the
// map after each turn is printed (counts, states, next step). About three Sonnet answers plus three Haiku map updates.
const STUDY = process.argv.includes('--study');
/** `--question=…` asks this instead of the built-in first question (e.g. one that invites a visual answer). */
const QUESTION = process.argv.find(a => a.startsWith('--question='))?.slice(11) ?? null;
/** `--figure=N` attaches the bundle's figure N image (consent cloud-ai-v3), as the app does for a question naming it. */
const FIGURE = Number(process.argv.find(a => a.startsWith('--figure='))?.slice(9) ?? 0);
/** `--look`: no figure attached, the device says it can answer a figure request (`figure_requests`); when the model asks for
 * one (`figure_request`), the question goes again with that figure, as the apps do (2026-10-15). */
const LOOK = process.argv.includes('--look');
/** `--equation`: the equation view's two requests on DPO's loss (EQUATION_VIEW.md): symbols, then background. */
const EQUATION = process.argv.includes('--equation');
let forced = 0;
const INDEX = process.argv.find(a => a.startsWith('--index='))?.slice(8) ?? `${ROOT}/.artifacts/bundles/ecbc0a04588f/reader.json`;
const dotenv = path => Object.fromEntries(readFileSync(path, 'utf8').split('\n').filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const env = dotenv(`${ROOT}/.env.staging`);
if (!env.SUPABASE_URL?.startsWith(`https://${PROJECT_REF}.`) || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) { console.error('staging env missing'); process.exit(2); }
const secrets = new Set(Object.values(env).filter(v => typeof v === 'string' && v.length >= 8));
const redact = s => { let o = String(s); for (const x of secrets) o = o.split(x).join('[redacted]'); return o.replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[jwt]'); };
const log = (...p) => console.log(redact(`${new Date().toISOString().slice(11, 19)} ${p.join(' ')}`));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const service = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
async function http(url, { method = 'GET', headers = {}, body, timeoutMs = 60_000 } = {}) {
  const r = await fetch(url, { method, headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
  const text = await r.text(); let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: r.status, json, text };
}
async function rpc(name, params, token) {
  const r = await http(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, { method: 'POST', body: params ?? {},
    headers: token === 'service' ? service : { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } });
  if (r.status >= 300) throw new Error(`${name}: HTTP ${r.status} ${r.json?.message ?? r.json?.code ?? ''}`.trim());
  return r.json;
}

// 1. Context from the cached DPO bundle (text only reaches the server; digests are opaque to it).
const { buildPaperContext, CITATION_PATTERN } = await import(`${ROOT}/apps/web/src/lib/paper-context.ts`);
if (!existsSync(INDEX)) { console.error(`no reader index at ${INDEX}; pass --index=<path to a compiled reader.json for 2305.18290>`); process.exit(2); }
const index = JSON.parse(readFileSync(INDEX, 'utf8'));
const text = buildPaperContext(index);
const lock = JSON.parse(readFileSync(`${ROOT}/tests/corpus/reader-lock.json`, 'utf8')).papers.find(p => p.key === '2305.18290v3');
// Opaque to the server (format-checked only): the index digest stands in for the device's manifest digest.
const manifest_sha256 = createHash('sha256').update(readFileSync(INDEX)).digest('hex');
log(`context: ${index.blocks.length} blocks, ${Buffer.byteLength(text)} bytes`);

// 2. Disposable account with synthetic credits.
const email = `gradstep-smoke-agentv2-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
secrets.add(password);
const created = await http(`${env.SUPABASE_URL}/auth/v1/admin/users`, { method: 'POST', headers: service, body: { email, password, email_confirm: true } });
if (created.status >= 300 || !created.json?.id) throw new Error(`create account: HTTP ${created.status}`);
const accountID = created.json.id;
log(`account ${accountID} created`);
let token = null, exit = 0;
try {
  await rpc('worker_grant_credits', { p_account_id: accountID, p_source: 'adjustment', p_external_key: `operator:agent-v2-smoke:${accountID}`,
    p_credits: 400, p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Agent v2 live smoke synthetic grant' }, 'service');
  const signin = await http(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: { email, password } });
  if (signin.status !== 200 || !signin.json?.access_token) throw new Error(`sign-in: HTTP ${signin.status}`);
  token = signin.json.access_token; secrets.add(token);
  const balance = await rpc('v1_credit_balance', {}, token);
  log(`balance ${balance.available} available`);

  // 3. DPO v3 metadata membership (source_only, no PDF).
  const membershipID = randomUUID();
  const page = await rpc('v3_library_page', { p_cursor: null, p_limit: 100 }, token);
  await rpc('v2_begin_import', { p_operation_id: membershipID, p_source_id: '2305.18290', p_observed_cursor: page.baseline_cursor ?? 0, p_requested_revision: 3 }, token);
  let member;
  for (let n = 0; n < 60; n++) {
    const r = await rpc('v3_library_page', { p_cursor: null, p_limit: 100 }, token);
    member = r.entries.find(e => e.kind === 'import' && e.id === membershipID);
    if (member?.phase === 'source_only' || member?.phase === 'failed') break;
    await sleep(3000);
  }
  if (member?.phase !== 'source_only' || member.source_revision !== 3) throw new Error(`membership phase ${member?.phase ?? 'missing'} ${member?.error_code ?? ''}`);
  log(`membership ${membershipID} source_only: ${member.metadata?.title}`);

  // The bundle's figure N as the app sends it (the DPO figures are JPEGs within the provider's resolution already).
  const figureImages = n => {
    const figure = index.figures.find(f => new RegExp(`^\\s*Figure\\s*${n}\\b`).test(f.caption));
    if (!figure) throw new Error(`no Figure ${n} in the bundle`);
    const path = figure.asset_paths[0], bytes = readFileSync(`${dirname(INDEX)}/${path}`);
    const member = JSON.parse(readFileSync(`${dirname(INDEX)}/manifest.json`, 'utf8')).members.find(m => m.path === path);
    return [{ id: 'F1', paragraph: index.blocks.findIndex(b => b.id === figure.block_id) + 1, caption: figure.caption.slice(0, 1200),
      media_type: path.endsWith('.png') ? 'image/png' : 'image/jpeg', data: bytes.toString('base64'), width: member.width, height: member.height }];
  };

  // 4. Questions.
  const local_context = { format: 'reader-local-context-v2', membership_id: membershipID, source: 'arxiv', source_id: '2305.18290', revision: 3,
    manifest_sha256, source_sha256: lock.html.sha256, text };
  const turns = [];
  let equationAction = null, equationLatex = '';
  let followUps = [], studyMap = { concepts: [], links: [], focus: null, journey: [], next: 'calibrate' };
  const ask = async question => {
    turns.push({ role: 'user', text: question });
    const figures = forced ? figureImages(forced) : FIGURE && turns.length === 1 ? figureImages(FIGURE) : [];
    let requested = null;
    const body = { operation_id: randomUUID(), consent_version: figures.length || LOOK ? 'cloud-ai-v3' : 'cloud-ai-v2', mode: 'paper', local_context, messages: turns,
      topic_title: turns.length === 1, capabilities: LOOK ? ['visual_answers', 'figure_requests'] : ['visual_answers'], ...(figures.length ? { figures } : {}),
      ...(STUDY ? { action: 'study', study: studyMap } : equationAction ? { action: equationAction, selection: { quote: equationLatex } } : { follow_ups: true }) };
    if (equationAction) { delete body.topic_title; body.messages = [{ role: 'user', text: question }]; }
    if (figures.length) log(`attached ${figures.map(f => `${f.id} ¶${f.paragraph} ${f.width}×${f.height} ${Math.round(f.data.length * 3 / 4 / 1024)} KB`).join(', ')}`);
    const started = Date.now();
    const r = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'text/event-stream',
      apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(180_000) });
    log(`chat HTTP ${r.status} ${r.headers.get('content-type')}`);
    if (r.status !== 200) { log(await r.text()); throw new Error('chat request failed'); }
    let answer = '', buffer = '', first = 0; const events = []; let done = null; followUps = [];
    const reader = r.body.getReader(); const decoder = new TextDecoder();
    const dispatch = frame => {
      let name = 'message', data = '';
      for (const line of frame.split('\n')) { if (line.startsWith('event:')) name = line.slice(6).trim(); else if (line.startsWith('data:')) data += line.slice(5).trim(); }
      if (!data) return;
      let payload; try { payload = JSON.parse(data); } catch { payload = data; }
      events.push(name);
      if (name === 'text' || name === 'delta') { if (!first) first = Date.now(); answer += payload.text ?? payload.delta ?? ''; }
      else if (name === 'followups') followUps = payload.questions ?? [];
      else if (name === 'study') { studyMap = payload.map; log(`study map: ${studyMap.concepts.length} concepts ${JSON.stringify(studyMap.concepts.map(c => `${c.label}:${c.state}`))} links ${studyMap.links.length} focus ${studyMap.focus} next ${studyMap.next} journey ${studyMap.journey.join('>')}`); }
      else if (name === 'figure_parts') log(`figure parts: “${payload.title}” on ${payload.figure} ¶${payload.paragraph}: ${payload.parts.map(p => `${p.label} [${p.box.map(n => n.toFixed(2)).join(',')}]`).join(' | ')}`);
      else if (name === 'visual') log(`visual: “${payload.title}”, ${Buffer.byteLength(payload.html)} bytes of HTML, elements ${[...new Set((payload.html.match(/<([a-z][a-z0-9]*)/gi) || []).map(t => t.slice(1).toLowerCase()))].join(' ')}`);
      else if (name === 'figure_request') { requested = payload.figure; log(`figure request: ${payload.figure}`); }
      else if (name === 'equation') log(`equation: “${payload.summary}” ${payload.symbols.length} symbols: ${payload.symbols.map(x => `${x.symbol} (${x.source}${x.paragraph ? ` ¶${x.paragraph}` : ''}): ${x.meaning}`).join(' | ')}`);
      else if (name === 'done') done = payload;
      else log(`event ${name} ${JSON.stringify(payload).slice(0, 300)}`);
    };
    for (;;) {
      const { value, done: end } = await reader.read();
      if (end) break;
      buffer += decoder.decode(value, { stream: true });
      let i; while ((i = buffer.indexOf('\n\n')) >= 0) { dispatch(buffer.slice(0, i)); buffer = buffer.slice(i + 2); }
    }
    if (buffer.trim()) dispatch(buffer);
    const seconds = ((Date.now() - started) / 1000).toFixed(1), firstS = first ? ((first - started) / 1000).toFixed(1) : 'n/a';
    const cites = [...answer.matchAll(CITATION_PATTERN)].map(m => Number(m[1]));
    log(`events: ${[...new Set(events)].join(',')} | ${seconds} s total, first text ${firstS} s`);
    log(`done: ${JSON.stringify(done)}`);
    log(`citations: [${cites.join(', ')}] (${cites.filter(n => n >= 1 && n <= index.blocks.length).length} resolvable of ${cites.length})`);
    log(`follow-ups (${followUps.length}): ${JSON.stringify(followUps)}`);
    console.log('--- answer ---\n' + redact(answer) + '\n--- end ---');
    // The model asked for a figure: the same question again with it (the first answer was only the request).
    if (LOOK && requested && !figures.length && /^Figure \d+$/.test(requested)) {
      turns.pop(); forced = Number(requested.split(' ')[1]);
      log(`asking again with ${requested} attached`);
      try { await ask(question); } finally { forced = 0; }
      return;
    }
    turns.push({ role: 'assistant', text: answer });
  };
  if (EQUATION) {
    const loss = index.equations.find(e => e.display && /DPO/.test(e.latex) && /\\sigma/.test(e.latex));
    if (!loss) throw new Error('no DPO loss equation in the bundle');
    equationLatex = loss.latex.replace(/\\(begin|end)\{equation\*?\}/g, '').trim();
    log(`equation ${loss.id} ¶${index.blocks.findIndex(b => b.id === loss.block_id) + 1}: ${equationLatex.slice(0, 120)}…`);
    for (const action of ['equation', 'equation_background']) { equationAction = action; turns.length = 0; await ask('Equation (7)'); }
  } else if (STUDY) {
    await ask('Start studying this paper.');
    await ask('I think the reference model is the model you start from, and the loss compares how much more likely the chosen answer is than the rejected one under the policy versus the reference.');
    await ask('I’m not sure what beta does. Is it a learning rate?');
  } else {
    await ask(QUESTION ?? 'Why does the DPO objective need a reference model, and which equation defines the loss?');
    if (QUESTIONS >= 2 && followUps.length) await ask(followUps[0]);
  }
  const after = await rpc('v1_credit_balance', {}, token);
  log(`balance after: ${after.available} available, ${after.held ?? 0} held (spent ${balance.available - after.available} credits)`);
} catch (error) { exit = 1; log(`FAILED: ${error.message}`); }
finally {
  // 5. Cleanup through account-delete, then confirm the auth user is gone.
  let deleted = null;
  if (token) deleted = await http(`${env.SUPABASE_URL}/functions/v1/account-delete`, { method: 'POST', body: { confirm: 'delete my account' },
    headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } });
  if (!deleted || deleted.status !== 200) {
    log(`account-delete ${deleted?.status ?? 'skipped'}; removing the auth user with the service role`);
    const r = await http(`${env.SUPABASE_URL}/auth/v1/admin/users/${accountID}`, { method: 'DELETE', headers: service });
    log(`admin delete HTTP ${r.status}`);
  } else log('account-delete HTTP 200');
  const users = await http(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=500`, { headers: service });
  const remaining = (users.json?.users ?? []).filter(u => u.id === accountID || u.email === email);
  log(`cleanup: ${remaining.length === 0 ? 'auth user gone' : 'AUTH USER STILL PRESENT'}`);
  if (remaining.length) exit = 1;
}
process.exit(exit);
