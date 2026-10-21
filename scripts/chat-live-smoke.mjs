#!/usr/bin/env node
// Paid, explicit live check of the chat agent on staging (docs/TESTING.md): one disposable account with synthetic
// credits, the DPO v3 metadata membership (no PDF), then one or two real questions carrying a reader-local-context-v2
// snapshot built with the browser's own context builder. Prints event names, citations (and whether each resolves),
// follow-ups, credits and the answer text; never a token, key or password. Deletes the account at the end through
// account-delete, as a reader would, and confirms the auth user is gone. About $0.25 of provider spend per run.
//
//   node scripts/chat-live-smoke.mjs [--questions=1|2] [--index=.artifacts/bundles/<id>/reader.json]
//   node scripts/chat-live-smoke.mjs --profile=sonnet-auto-standard            (automatic effort: done names the pick)
//   node scripts/chat-live-smoke.mjs --profile=gemini-auto-standard --no-auxiliaries (isolate the main provider; no title/follow-up calls)
//   node scripts/chat-live-smoke.mjs --profile=deepseek-auto-standard --eval   (the recorded DeepSeek check, under $0.10)
//   node scripts/chat-live-smoke.mjs --figure-view=1 --warm                     (the figure view on DPO's Figure 1)
//   node scripts/chat-live-smoke.mjs --paper=2610.16784v1 --index=<bundle>/reader.json --figure-view=4 --table-view=1
//   node scripts/chat-live-smoke.mjs --ingest="Zzyzx et al. A paper that does not exist. 2031."   (Add paper; not charged)
//
// --figure-view=N (FIGURE_VIEW.md): the figure view's requests on figure N, prepared as the browser prepares a figure
// (stacked panels, at most 1,568 px and 1.15 MP, JPEG on white): the walkthrough (`figure`), then one part again, more
// simply (`figure_simpler`, on the first section with a box, else the second). (`figure_detail`, "Extract the subfigure",
// was removed from the apps on 2026-10-21 and is no longer exercised here.) --table-view=N does the same for table N,
// rendered from the bundle's own HTML in headless Chromium as a device shows it. --warm asks one chat question first, so
// the walkthrough's cache read shows it shares the chat's cached prefix. Writes the image sent, the image with the
// walkthrough's boxes drawn and numbered, and a JSON record (sections, boxes, credits, seconds, usage) under
// .artifacts/figure-view/. --figure-walkthrough-only skips the two follow-up actions. --paper=<id>v<rev> names the arXiv paper the --index bundle is (default DPO 2305.18290v3).
//
// --questions=2 sends the first suggested follow-up as a second turn (exercises the prompt cache). --index names any
// compiled reader index for arXiv 2305.18290 (default: the DPO bundle under .artifacts/bundles); the server only sees
// its text, so a device-compiled bundle gives the same evidence.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
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
/** `--equation`: symbols, then background on DPO's loss; `--equation=symbols` reruns only the structured request. */
const EQUATION = process.argv.includes('--equation') || process.argv.includes('--equation=symbols');
/** `--figure-view=N`, `--table-view=N`, `--warm`, `--paper=<id>v<rev>`: the figure view (see the header). */
const FIGURE_VIEW = Number(process.argv.find(a => a.startsWith('--figure-view='))?.slice(14) ?? 0);
const TABLE_VIEW = Number(process.argv.find(a => a.startsWith('--table-view='))?.slice(13) ?? 0);
const WARM = process.argv.includes('--warm');
// Isolate a changed walkthrough contract without paying again for the unchanged simpler action.
const WALKTHROUGH_ONLY = process.argv.includes('--figure-walkthrough-only');
/** `--ingest=<reference text>`: Add paper from the chat on that reference (CHAT.md "Add paper after settlement"); prints
 * the report and the operation's settlement (an add that doesn't happen settles 0 credits with the cost absorbed). */
const INGEST = process.argv.find(a => a.startsWith('--ingest='))?.slice(9) ?? null;
/** `--action=<related|relevance>` with `--selection=<text>`: a selection action as the apps send it; `--caps=a,b` replaces
 * the capabilities sent (e.g. visual_answers,figure_requests,figure_view,stop_signal as build 62 sends them). */
const ACTION = process.argv.find(a => a.startsWith('--action='))?.slice(9) ?? null;
const SELECTION = process.argv.find(a => a.startsWith('--selection='))?.slice(12) ?? null;
const CAPS = process.argv.find(a => a.startsWith('--caps='))?.slice(7).split(',').filter(Boolean) ?? null;
const PAPER = (() => {
  const value = process.argv.find(a => a.startsWith('--paper='))?.slice(8) ?? '2305.18290v3';
  const m = /^(\d{4}\.\d{4,5})v(\d+)$/.exec(value);
  if (!m) { console.error('--paper=<arXiv id>v<revision>'); process.exit(2); }
  return { key: value, id: m[1], revision: Number(m[2]) };
})();
/** `--profile=deepseek-auto-standard` (model-effort-length): the answer profile to ask with (2026-10-16: effort may be
 * `auto`; DeepSeek goes with consent cloud-ai-v4, which names it). */
const PROFILE = (() => {
  const value = process.argv.find(a => a.startsWith('--profile='))?.slice(10);
  if (!value) return null;
  const [model, effort, length] = value.split('-');
  if (!model || !effort || !length) { console.error('--profile=model-effort-length'); process.exit(2); }
  return { model, effort, length };
})();
/** `--eval`: the recorded model check (CHAT.md "DeepSeek in chat"): four questions on DPO, each a new conversation, with
 * the profile from --profile: equations (every \( \) and \[ \] segment typeset by the browser's temml, no $ delimiters),
 * [¶N] citations that resolve, a visual or diagram that parses, Figure 1 attached and read (its example prompt is only in
 * the image) with figure parts, and streaming; then each answer's quote and provider attempts from the database.
 * Writes .artifacts/chat-eval/<time>.json (checks and numbers; the answers print to the console only). */
const EVAL = process.argv.includes('--eval');
const EVAL_QUESTIONS = [
  { key: 'equations', question: 'Why does the DPO objective need a reference model, and which equation defines the loss?' },
  { key: 'derivation', question: 'Derive the DPO loss from the KL-constrained reward maximization objective, step by step.' },
  { key: 'visual', question: 'Show me how the DPO training pipeline works, as a visual I can read on my phone.' },
  { key: 'figure', question: 'What does Figure 1 show? Walk me through each part of it.', figure: 1 },
];
const results = [];
// The browser's math renderer (apps/web), to check that every equation an answer writes typesets.
const temml = EVAL ? (await import(`${resolve(dirname(fileURLToPath(import.meta.url)), '..')}/apps/web/node_modules/temml/dist/temml.mjs`)).default : null;
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
if (!existsSync(INDEX)) { console.error(`no reader index at ${INDEX}; pass --index=<path to a compiled reader.json for ${PAPER.id}>`); process.exit(2); }
if (PAPER.id !== '2305.18290' && !process.argv.some(a => a.startsWith('--index='))) { console.error(`pass --index=<reader.json of ${PAPER.key}>`); process.exit(2); }
const index = JSON.parse(readFileSync(INDEX, 'utf8'));
const text = buildPaperContext(index);
const lock = JSON.parse(readFileSync(`${ROOT}/tests/corpus/reader-lock.json`, 'utf8')).papers.find(p => p.key === PAPER.key);
// Opaque to the server (format-checked only): the source's digest when the corpus lock has it, else the index's.
const source_sha256 = lock?.html?.sha256 ?? createHash('sha256').update(readFileSync(INDEX)).digest('hex');
// Opaque to the server (format-checked only): the index digest stands in for the device's manifest digest.
const manifest_sha256 = createHash('sha256').update(readFileSync(INDEX)).digest('hex');
log(`context: ${index.blocks.length} blocks, ${Buffer.byteLength(text)} bytes`);

// ---------- The figure view (FIGURE_VIEW.md): --figure-view=N, --table-view=N, --warm ----------
// A build with the figure view: its chats and its figure requests send the same capabilities and profile, so the server's
// tools (figure_walkthrough among them) and cached prefix are the chat's.
const FIGURE_DEVICE = ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'];
const FIGURE_PROFILE = PROFILE ?? { model: 'sonnet', effort: 'auto', length: 'standard' };
let chromium = null;
async function browserPage() {
  if (!chromium) {
    const { createRequire } = await import('node:module');
    chromium = await createRequire(`${ROOT}/apps/web/package.json`)('playwright').chromium.launch();
  }
  const page = await chromium.newPage({ deviceScaleFactor: 2 });
  await page.setContent('<!doctype html><meta charset="utf-8"><body>');
  return page;
}
/** The figure as the browser's chat prepares it (apps/web/src/lib/chat-figures.ts): panels stacked at the widest panel's
 * width with 2 % white gaps, scaled to at most 1,568 px and 1.15 MP, JPEG 0.85 on white. */
async function prepareFigureImage(parts) {
  const page = await browserPage();
  try {
    return await page.evaluate(async parts => {
      const bitmaps = await Promise.all(parts.map(p => createImageBitmap(new Blob([Uint8Array.from(atob(p.data), c => c.charCodeAt(0))], { type: p.type }))));
      let source = bitmaps[0];
      if (bitmaps.length > 1) {
        const width = Math.max(...bitmaps.map(b => b.width)), gap = Math.max(1, Math.round(width * 0.02));
        const heights = bitmaps.map(b => Math.round(b.height * width / b.width)), height = heights.reduce((a, b) => a + b, 0) + gap * (bitmaps.length - 1);
        const canvas = new OffscreenCanvas(width, height), ctx = canvas.getContext('2d');
        ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, width, height);
        let top = 0; bitmaps.forEach((b, i) => { ctx.drawImage(b, 0, top, width, heights[i]); top += heights[i] + gap; });
        source = canvas;
      }
      const long = Math.max(source.width, source.height), short = Math.min(source.width, source.height);
      const limit = Math.min(1568, Math.sqrt(1_150_000 * long / short), long), scale = limit / long;
      const w = Math.max(1, Math.round(source.width * scale)), h = Math.max(1, Math.round(source.height * scale));
      const canvas = new OffscreenCanvas(w, h), ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, h); ctx.drawImage(source, 0, 0, w, h);
      const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.85 });
      const data = await new Promise(resolve => { const r = new FileReader(); r.onload = () => resolve(String(r.result).split(',')[1]); r.readAsDataURL(blob); });
      return { data, width: w, height: h };
    }, parts);
  } finally { await page.close(); }
}
/** Table N as the reader shows it: the bundle's own HTML and stylesheet, the table's block captured as an image. */
async function tableImage(n) {
  const block = index.blocks.find(b => b.kind === 'table' && new RegExp(`^\\s*Table\\s*${n}\\b`).test(b.text ?? ''));
  if (!block) throw new Error(`no Table ${n} in the bundle`);
  const page = await browserPage();
  try {
    // Wide enough for the whole table: no column scrolled out of view (the reader's column scrolls a wide table sideways).
    await page.setViewportSize({ width: 1600, height: 1200 });
    await page.goto(`file://${dirname(INDEX)}/index.html`);
    const caption = await page.evaluate(id => {
      const root = document.getElementById(id), table = root.querySelector('table');
      document.body.style.maxWidth = 'none';
      for (const node of [root, ...root.querySelectorAll('*')]) { node.style.overflow = 'visible'; node.style.maxWidth = 'none'; }
      // The caption wraps to the table's width, so the image is the table and its caption, not a page-wide strip.
      if (table) root.style.width = `${Math.ceil(table.getBoundingClientRect().width) + 8}px`;
      return root.querySelector('.reader-caption, figcaption')?.textContent?.replace(/\s+/g, ' ').trim() ?? null;
    }, block.id) ?? (block.text ?? '').slice(0, 300);
    const element = page.locator(`[id="${block.id}"]`).first();
    const png = await element.screenshot({ type: 'png' });
    return { paragraph: index.blocks.indexOf(block) + 1, caption, parts: [{ data: png.toString('base64'), type: 'image/png' }], label: `table${n}` };
  } finally { await page.close(); }
}
function figureSource(n) {
  const figure = index.figures.find(f => new RegExp(`^\\s*Figure\\s*${n}\\b`).test(f.caption));
  if (!figure) throw new Error(`no Figure ${n} in the bundle`);
  const manifest = JSON.parse(readFileSync(`${dirname(INDEX)}/manifest.json`, 'utf8'));
  const parts = figure.asset_paths.map(path => ({ data: readFileSync(`${dirname(INDEX)}/${path}`).toString('base64'),
    type: manifest.members.find(m => m.path === path)?.media_type ?? (path.endsWith('.png') ? 'image/png' : 'image/jpeg') }));
  return { paragraph: index.blocks.findIndex(b => b.id === figure.block_id) + 1, caption: figure.caption, parts, label: `figure${n}` };
}
/** One chat request, its events read as the apps read them. */
async function figureRequest(body, token) {
  const started = Date.now();
  const r = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'text/event-stream',
    apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(180_000) });
  if (r.status !== 200) { log(await r.text()); throw new Error(`chat HTTP ${r.status}`); }
  const out = { events: [], text: '', figure: null, done: null, error: null, first: 0 };
  const reader = r.body.getReader(), decoder = new TextDecoder(); let buffer = '';
  const dispatch = frame => {
    let name = 'message', data = '';
    for (const line of frame.split('\n')) { if (line.startsWith('event:')) name = line.slice(6).trim(); else if (line.startsWith('data:')) data += line.slice(5).trim(); }
    if (!data) return;
    const payload = JSON.parse(data); out.events.push(name);
    if (!out.first && name !== 'status') out.first = Date.now();
    if (name === 'delta') out.text += payload.text; else if (name === 'figure') out.figure = payload;
    else if (name === 'done') out.done = payload; else if (name === 'error') out.error = payload;
  };
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let i; while ((i = buffer.indexOf('\n\n')) >= 0) { dispatch(buffer.slice(0, i)); buffer = buffer.slice(i + 2); }
  }
  if (buffer.trim()) dispatch(buffer);
  out.seconds = Number(((Date.now() - started) / 1000).toFixed(1)); out.firstSeconds = out.first ? Number(((out.first - started) / 1000).toFixed(1)) : null;
  log(`events ${out.events.join(',')} | ${out.seconds} s (first event ${out.firstSeconds} s) | done ${JSON.stringify(out.done ?? out.error)}`);
  return out;
}
/** The walkthrough's boxes drawn on the image that was sent, numbered by section, so they can be checked by eye. */
async function drawBoxes(image, sections, file) {
  const page = await browserPage();
  try {
    const png = await page.evaluate(async ({ image, sections }) => {
      const bitmap = await createImageBitmap(new Blob([Uint8Array.from(atob(image.data), c => c.charCodeAt(0))], { type: 'image/jpeg' }));
      const canvas = new OffscreenCanvas(bitmap.width, bitmap.height), ctx = canvas.getContext('2d');
      ctx.drawImage(bitmap, 0, 0);
      const colors = ['#d62728', '#1f77b4', '#2ca02c', '#9467bd'];
      let k = 0;
      sections.forEach((s, i) => {
        if (!s.box) return;
        const color = colors[k++ % colors.length], x = s.box.x * bitmap.width, y = s.box.y * bitmap.height, w = s.box.w * bitmap.width, h = s.box.h * bitmap.height;
        ctx.lineWidth = Math.max(3, Math.round(bitmap.width / 300)); ctx.strokeStyle = color; ctx.strokeRect(x, y, w, h);
        const tag = `${i + 1} ${s.label || s.title}`.slice(0, 40), size = Math.max(14, Math.round(bitmap.width / 60));
        ctx.font = `bold ${size}px sans-serif`;
        const width = ctx.measureText(tag).width + 8;
        ctx.fillStyle = color; ctx.fillRect(x, Math.max(0, y - size - 6), width, size + 6);
        ctx.fillStyle = '#fff'; ctx.fillText(tag, x + 4, Math.max(size, y - 4));
      });
      const blob = await canvas.convertToBlob({ type: 'image/png' });
      return await new Promise(resolve => { const r = new FileReader(); r.onload = () => resolve(String(r.result).split(',')[1]); r.readAsDataURL(blob); });
    }, { image, sections });
    writeFileSync(file, Buffer.from(png, 'base64'));
  } finally { await page.close(); }
}
async function figureViews({ local_context, token }) {
  const dir = `${ROOT}/.artifacts/figure-view`; mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const record = { paper: PAPER.key, profile: FIGURE_PROFILE, ran_at: new Date().toISOString(), runs: [] };
  const base = { consent_version: 'cloud-ai-v6', mode: 'paper', local_context, capabilities: FIGURE_DEVICE, profile: FIGURE_PROFILE };
  if (WARM) {
    log('=== warm: one chat question from the same device (writes the paper to the cache) ===');
    const chat = await figureRequest({ ...base, operation_id: randomUUID(), messages: [{ role: 'user', text: 'In two sentences, what is this paper\'s main contribution?' }] }, token);
    record.runs.push({ kind: 'chat', seconds: chat.seconds, credits: chat.done?.credits ?? null, usage: chat.done?.usage ?? null, events: [...new Set(chat.events)] });
  }
  const targets = [...(FIGURE_VIEW ? [figureSource(FIGURE_VIEW)] : []), ...(TABLE_VIEW ? [await tableImage(TABLE_VIEW)] : [])];
  for (const target of targets) {
    const prepared = await prepareFigureImage(target.parts);
    const name = target.label.replace('figure', 'Figure ').replace('table', 'Table ');
    const figures = [{ id: 'F1', paragraph: target.paragraph, caption: [...target.caption].slice(0, 1200).join(''), media_type: 'image/jpeg', ...prepared }];
    writeFileSync(`${dir}/${PAPER.key}-${target.label}-sent.jpg`, Buffer.from(prepared.data, 'base64'));
    log(`=== ${name} (¶${target.paragraph}, ${prepared.width}×${prepared.height}, ${Math.round(prepared.data.length * 3 / 4 / 1024)} KB): walkthrough ===`);
    const walk = await figureRequest({ ...base, operation_id: randomUUID(), action: 'figure', selection: { quote: figures[0].caption }, messages: [{ role: 'user', text: name }], figures }, token);
    const w = walk.figure;
    if (w) {
      log(`summary: ${w.summary}`);
      w.sections.forEach((s, i) => log(`  ${i + 1}. ${s.label ? `${s.label} ` : ''}${s.title} [¶${s.paragraphs.join(',¶')}]${s.box ? ` box x=${s.box.x} y=${s.box.y} w=${s.box.w} h=${s.box.h}` : ''} (${[...s.text].length} chars)`));
      console.log('--- walkthrough ---\n' + redact(w.sections.map((s, i) => `${i + 1}. ${s.label} ${s.title}\n${s.text}`).join('\n\n')) + '\n--- end ---');
      await drawBoxes(prepared, w.sections, `${dir}/${PAPER.key}-${target.label}-boxes.png`);
      log(`boxes drawn: .artifacts/figure-view/${PAPER.key}-${target.label}-boxes.png`);
    } else console.log('--- words (no walkthrough) ---\n' + redact(walk.text) + '\n--- end ---');
    record.runs.push({ kind: 'figure', target: name, paragraph: target.paragraph, image: { width: prepared.width, height: prepared.height, kb: Math.round(prepared.data.length * 3 / 4 / 1024) },
      seconds: walk.seconds, events: [...new Set(walk.events)], credits: walk.done?.credits ?? null, charged: walk.done?.charged ?? null, effort: walk.done?.effort ?? null,
      model: walk.done?.model ?? null, usage: walk.done?.usage ?? null, error: walk.error, walkthrough: w });
    // One part again, more simply: the first section with a box, else the second.
    const part = w ? (w.sections.find(s => s.box) ?? w.sections[1] ?? w.sections[0]) : null;
    if (part && !WALKTHROUGH_ONLY) {
      log(`=== ${name}: explain more simply "${part.label} ${part.title}" ===`);
      const simpler = await figureRequest({ ...base, operation_id: randomUUID(), action: 'figure_simpler', selection: { quote: part.text }, messages: [{ role: 'user', text: `${name} ${part.label}`.trim() }], figures }, token);
      console.log('--- simpler ---\n' + redact(simpler.text) + '\n--- end ---');
      record.runs.push({ kind: 'figure_simpler', target: name, section: `${part.label} ${part.title}`.trim(), seconds: simpler.seconds, first_text_s: simpler.firstSeconds,
        events: [...new Set(simpler.events)], credits: simpler.done?.credits ?? null, charged: simpler.done?.charged ?? null, usage: simpler.done?.usage ?? null,
        characters: simpler.text.length, error: simpler.error });
    }
  }
  const file = `${dir}/${stamp}-${PAPER.key}.json`;
  writeFileSync(file, JSON.stringify(record, null, 1));
  log(`recorded ${file.slice(ROOT.length + 1)}`);
}

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
  await rpc('v2_begin_import', { p_operation_id: membershipID, p_source_id: PAPER.id, p_observed_cursor: page.baseline_cursor ?? 0, p_requested_revision: PAPER.revision }, token);
  let member;
  for (let n = 0; n < 60; n++) {
    const r = await rpc('v3_library_page', { p_cursor: null, p_limit: 100 }, token);
    member = r.entries.find(e => e.kind === 'import' && e.id === membershipID);
    if (member?.phase === 'source_only' || member?.phase === 'failed') break;
    await sleep(3000);
  }
  if (member?.phase !== 'source_only' || member.source_revision !== PAPER.revision) throw new Error(`membership phase ${member?.phase ?? 'missing'} ${member?.error_code ?? ''}`);
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
  const local_context = { format: 'reader-local-context-v2', membership_id: membershipID, source: 'arxiv', source_id: PAPER.id, revision: PAPER.revision,
    manifest_sha256, source_sha256, text };
  const turns = [];
  let equationAction = null, equationLatex = '';
  let followUps = [], studyMap = { concepts: [], links: [], focus: null, journey: [], next: 'calibrate' };
  const ask = async (question, figureNumber = 0) => {
    turns.push({ role: 'user', text: question });
    const figures = forced ? figureImages(forced) : (figureNumber || FIGURE) && turns.length === 1 ? figureImages(figureNumber || FIGURE) : [];
    let requested = null;
    const consent = 'cloud-ai-v6'; // Current native/browser consent, including OpenRouter-routed Claude.
    const body = { operation_id: randomUUID(), consent_version: consent, mode: 'paper', local_context, messages: turns,
      topic_title: turns.length === 1, capabilities: LOOK ? ['visual_answers', 'figure_requests'] : ['visual_answers'], ...(figures.length ? { figures } : {}),
      ...(PROFILE ? { profile: PROFILE } : {}),
      ...(STUDY ? { action: 'study', study: studyMap } : equationAction ? { action: equationAction, selection: { quote: equationLatex } }
        : INGEST ? { action: 'ingest', selection: { quote: INGEST } } : ACTION ? { action: ACTION, selection: { quote: SELECTION ?? 'x' }, follow_ups: true } : { follow_ups: true }) };
    if (INGEST) delete body.topic_title;
    if (process.argv.includes('--no-auxiliaries')) { delete body.topic_title; delete body.follow_ups; }
    if (CAPS) body.capabilities = CAPS;
    if (equationAction) { delete body.topic_title; body.messages = [{ role: 'user', text: question }]; }
    if (figures.length) log(`attached ${figures.map(f => `${f.id} ¶${f.paragraph} ${f.width}×${f.height} ${Math.round(f.data.length * 3 / 4 / 1024)} KB`).join(', ')}`);
    const started = Date.now();
    const r = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'text/event-stream',
      apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(180_000) });
    log(`chat HTTP ${r.status} ${r.headers.get('content-type')}`);
    if (r.status !== 200) { log(await r.text()); throw new Error('chat request failed'); }
    let answer = '', buffer = '', first = 0; const events = []; let done = null, failure = null, parts = null, visual = null, diagram = null; followUps = [];
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
      else if (name === 'figure_parts') { parts = payload; log(`figure parts: “${payload.title}” on ${payload.figure} ¶${payload.paragraph}: ${payload.parts.map(p => `${p.label} [${p.box.map(n => n.toFixed(2)).join(',')}]`).join(' | ')}`); }
      else if (name === 'visual') { visual = payload; log(`visual: “${payload.title}”, ${Buffer.byteLength(payload.html)} bytes of HTML, elements ${[...new Set((payload.html.match(/<([a-z][a-z0-9]*)/gi) || []).map(t => t.slice(1).toLowerCase()))].join(' ')}`); }
      else if (name === 'diagram') { diagram = payload; log(`diagram: “${payload.title}”, ${payload.source.split('\n')[0]}`); }
      else if (name === 'error') { failure = payload; log(`event error ${JSON.stringify(payload)}`); }
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
    if (failure || !done) throw new Error(`Chat did not complete: ${failure?.code ?? 'missing_done'}`);
    if (!answer.trim() && !requested && !events.some(e => ['equation', 'figure', 'ingest'].includes(e)))
      throw new Error('Chat completed without an answer or a usable tool result');
    if (equationAction && (failure || done?.stop_reason !== 'end_turn'
      || (equationAction === 'equation' ? !events.includes('equation') : !answer.trim())))
      throw new Error(`${equationAction} did not deliver a complete explanation`);
    if (EVAL) {
      // Every math segment as the browser typesets it (temml, errors thrown), and no dollar delimiters.
      const segments = [...answer.matchAll(/\\\(([\s\S]+?)\\\)|\\\[([\s\S]+?)\\\]/g)].map(m => ({ tex: m[1] ?? m[2], display: m[2] !== undefined }));
      const invalid = segments.filter(s => { try { temml.renderToString(s.tex, { displayMode: s.display, throwOnError: true, trust: false, maxExpand: 1000 }); return false; } catch { return true; } });
      const dollars = /(^|[^\\])\$[^$\n]+\$/.test(answer.replace(/```[\s\S]*?```/g, ''));
      const deltas = events.filter(e => e === 'delta').length;
      results.push({ operation_id: body.operation_id, profile: done?.profile ?? null, effort: done?.effort ?? null, model: done?.model ?? null,
        credits: done?.credits ?? null, error: failure?.code ?? null, stop_reason: done?.stop_reason ?? null,
        first_text_s: first ? Number(((first - started) / 1000).toFixed(1)) : null, total_s: Number(seconds), deltas, characters: answer.length,
        math_segments: segments.length, math_invalid: invalid.length, math_invalid_examples: invalid.slice(0, 3).map(s => s.tex.slice(0, 80)), dollar_delimiters: dollars,
        citations: cites.length, citations_resolvable: cites.filter(n => n >= 1 && n <= index.blocks.length).length,
        visual: visual ? Buffer.byteLength(visual.html) : null, diagram: diagram ? diagram.source.split('\n')[0].slice(0, 40) : null,
        figure_parts: parts ? parts.parts.length : null, figure_attached: figures.length,
        // Figure 1's example prompt ("write me a poem about the history of jazz") is only in the image, never in the text.
        image_read: figures.length ? /jazz|poem/i.test(answer) || !!parts?.parts.some(p => /jazz|poem/i.test(`${p.label} ${p.note}`)) : null,
        follow_ups: followUps.length, usage: done?.usage ?? null });
    }
    // The model asked for a figure: the same question again with it (the first answer was only the request).
    if (LOOK && requested && !figures.length && /^Figure \d+$/.test(requested)) {
      turns.pop(); forced = Number(requested.split(' ')[1]);
      log(`asking again with ${requested} attached`);
      try { await ask(question); } finally { forced = 0; }
      return;
    }
    turns.push({ role: 'assistant', text: answer });
  };
  if (INGEST) {
    const before = await rpc('v1_credit_balance', {}, token);
    await ask('Add this paper to my library.');
    const after = await rpc('v1_credit_balance', {}, token);
    log(`balance ${before.available} → ${after.available} available`);
  } else if (FIGURE_VIEW || TABLE_VIEW) {
    await figureViews({ local_context, token, ask });
  } else if (EQUATION) {
    const loss = index.equations.find(e => e.display && /DPO/.test(e.latex) && /\\sigma/.test(e.latex));
    if (!loss) throw new Error('no DPO loss equation in the bundle');
    equationLatex = loss.latex.replace(/\\(begin|end)\{equation\*?\}/g, '').trim();
    log(`equation ${loss.id} ¶${index.blocks.findIndex(b => b.id === loss.block_id) + 1}: ${equationLatex.slice(0, 120)}…`);
    for (const action of process.argv.includes('--equation=symbols') ? ['equation'] : ['equation', 'equation_background']) {
      equationAction = action; turns.length = 0; await ask('Equation (7)');
    }
  } else if (EVAL) {
    for (const item of EVAL_QUESTIONS) { turns.length = 0; log(`=== ${item.key} ===`); await ask(item.question, item.figure ?? 0); results.at(-1).key = item.key; }
  } else if (STUDY) {
    await ask('Start studying this paper.');
    await ask('I think the reference model is the model you start from, and the loss compares how much more likely the chosen answer is than the rejected one under the policy versus the reference.');
    await ask('I’m not sure what beta does. Is it a learning rate?');
  } else {
    await ask(QUESTION ?? 'Why does the DPO objective need a reference model, and which equation defines the loss?');
    if (QUESTIONS >= 2) await ask(followUps[0] ?? 'What is the main limitation of that answer? Explain using the paper.');
  }
  const after = await rpc('v1_credit_balance', {}, token);
  log(`balance after: ${after.available} available, ${after.held ?? 0} held (spent ${balance.available - after.available} credits)`);
  if (EVAL) {
    // Each answer's frozen quote and provider attempts (read-only management query; staging only).
    let rows = { quotes: [], attempts: [] };
    try {
      const managementToken = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
      secrets.add(managementToken);
      const ids = results.map(r => r.operation_id).filter(id => /^[0-9a-f-]{36}$/.test(id)).map(id => `'${id}'`).join(',');
      const sql = async query => {
        const r = await http(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, { method: 'POST', headers: { Authorization: `Bearer ${managementToken}` },
          body: { query, read_only: true } });
        if (r.status >= 300) throw new Error(`management query HTTP ${r.status}`);
        return r.json;
      };
      rows.quotes = await sql(`select operation_id::text op, profile, model, effort, length, tariff, max_output_tokens, credit_ceiling, spend_ceiling_microusd
        from app_private.chat_quotes where operation_id in (${ids})`);
      rows.attempts = await sql(`select operation_id::text op, provider, model, state, ceiling_microusd, actual_microusd, actual_units, pricing_snapshot->>'tariff' tariff
        from app_private.provider_attempts where operation_id in (${ids}) order by created_at`);
    } catch (error) { log(`usage rows unavailable: ${error.message}`); }
    for (const r of results) {
      r.quote = rows.quotes.find(q => q.op === r.operation_id) ?? null;
      r.attempts = rows.attempts.filter(a => a.op === r.operation_id).map(({ op: _op, ...a }) => a);
      r.provider_usd = r.attempts.reduce((sum, a) => sum + Number(a.actual_microusd ?? 0), 0) / 1e6;
      log(`${r.key}: ${r.profile} ${r.credits} credits, $${r.provider_usd.toFixed(5)} (${r.attempts.map(a => `${a.provider}/${a.model}:${a.state}:${a.actual_microusd}`).join(', ')}); `
        + `math ${r.math_segments - r.math_invalid}/${r.math_segments}${r.dollar_delimiters ? ' $!' : ''}; citations ${r.citations_resolvable}/${r.citations}; `
        + `visual ${r.visual ?? '-'} diagram ${r.diagram ?? '-'} parts ${r.figure_parts ?? '-'} image ${r.image_read ?? '-'}; deltas ${r.deltas}, first ${r.first_text_s} s, total ${r.total_s} s`);
    }
    const dir = `${ROOT}/.artifacts/chat-eval`; mkdirSync(dir, { recursive: true });
    const file = `${dir}/${new Date().toISOString().replace(/[:.]/g, '-')}-${PROFILE ? `${PROFILE.model}-${PROFILE.effort}-${PROFILE.length}` : 'default'}.json`;
    writeFileSync(file, JSON.stringify({ profile: PROFILE, ran_at: new Date().toISOString(), results }, null, 1));
    log(`recorded ${file.slice(ROOT.length + 1)}`);
  }
} catch (error) { exit = 1; log(`FAILED: ${error.message}`); }
finally {
  await chromium?.close().catch(() => {});
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
