// Offline validation and durable, conservative holds for the explicit paid experiment.
import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

export function validateQuestions(qs, papers) {
  const seen = new Set();
  if (!qs.length) throw new Error('No evaluation questions selected');
  for (const q of qs) {
    if (!/^[a-z][a-z0-9_-]+$/.test(q.id) || seen.has(q.id)) throw new Error(`Invalid or duplicate question id: ${q.id}`);
    seen.add(q.id);
    const p = papers(q.paper);
    if (!q.question?.trim() || !q.reference?.trim() || q.reference.length < 40 || !q.type
      || !Array.isArray(q.key_points) || !q.key_points.length || !Array.isArray(q.errors_to_penalize))
      throw new Error(`Incomplete reference: ${q.id}`);
    if (q.figure != null && (!Number.isInteger(q.figure) || q.figure < 1 || q.figure > p.index.figures.length))
      throw new Error(`Invalid figure: ${q.id}`);
    for (const k of q.key_points) if (!k.point?.trim() || !Array.isArray(k.paragraphs) || !k.paragraphs.length
      || k.paragraphs.some(n => !Number.isInteger(n) || n < 1 || n > p.index.blocks.length))
      throw new Error(`Invalid reference paragraph: ${q.id}`);
  }
  return qs;
}

export function validateGrades(grades, labels, keyPointCount, claimReview = false) {
  const fields = ['correctness', 'completeness', 'faithfulness', 'citations', 'clarity', 'overall'];
  if (!Array.isArray(grades) || grades.length !== labels.length) return false;
  const seen = new Set();
  for (const g of grades) {
    if (!labels.includes(g.label) || seen.has(g.label)) return false;
    seen.add(g.label);
    if (fields.some(f => typeof g[f] !== 'number' || !Number.isFinite(g[f]) || g[f] < 0 || g[f] > 10)
      || !Array.isArray(g.errors) || g.errors.some(e => typeof e !== 'string') || typeof g.comment !== 'string'
      || !Array.isArray(g.key_points_hit) || g.key_points_hit.some(n => !Number.isInteger(n) || n < 0 || n >= keyPointCount)) return false;
    if (claimReview && (typeof g.material_error !== 'boolean'
      || !Array.isArray(g.required_omissions) || g.required_omissions.some(x => typeof x !== 'string')
      || !Array.isArray(g.optional_omissions) || g.optional_omissions.some(x => typeof x !== 'string')
      || (g.material_error && !g.errors.length))) return false;
  }
  return true;
}

// Keep the most expensive declared rates for routing, plus tiers for conservative request admission.
export function rateCeiling(endpoints) {
  if (!endpoints.length) throw new Error('No matching pinned provider endpoint');
  const tiers = endpoints.flatMap(e => [e.pricing, ...(e.pricing?.overrides ?? [])]);
  const number = v => { const n = Number(v); if (v == null || !Number.isFinite(n) || n < 0) throw new Error('Invalid provider price'); return n; };
  for (const e of endpoints) { number(e.pricing?.prompt); number(e.pricing?.completion); }
  const maximum = keys => Math.max(0, ...tiers.flatMap(t => keys.filter(k => t[k] != null).map(k => number(t[k]))));
  return { input: maximum(['prompt', 'input_cache_read', 'input_cache_write', 'input_cache_write_1h']),
    output: maximum(['completion']), request: maximum(['request']), image: maximum(['image']), tiers };
}

export function requestCeiling(messages, tools, maxTokens, rates) {
  if (!Number.isInteger(maxTokens) || maxTokens <= 0) throw new Error('Invalid output allowance');
  // Count every serialized UTF-8 byte (including image data) as a token, plus framing overhead.
  // This intentionally over-reserves; it is an admission estimate, not a price forecast.
  const input = Buffer.byteLength(JSON.stringify({ messages, tools })) + 16384;
  const images = messages.flatMap(m => Array.isArray(m.content) ? m.content : []).filter(c => c.type === 'image_url').length;
  // A tier above even this byte-based token bound cannot apply. Unknown/time-based overrides remain included.
  // This never uses observed cache hits or an optimistic tokenizer estimate to release budget.
  const eligible = rates.tiers?.filter(t => typeof t.min_prompt_tokens !== 'number'
    || !Number.isFinite(t.min_prompt_tokens) || t.min_prompt_tokens <= input);
  const maximum = (keys, fallback) => eligible?.length
    ? Math.max(0, ...eligible.flatMap(t => keys.filter(k => t[k] != null).map(k => Number(t[k])))) : fallback;
  const price = { input: maximum(['prompt', 'input_cache_read', 'input_cache_write', 'input_cache_write_1h'], rates.input),
    output: maximum(['completion'], rates.output), request: maximum(['request'], rates.request), image: maximum(['image'], rates.image) };
  return Math.ceil(1e6 * 1.25 * (input * price.input + maxTokens * price.output + price.request + images * price.image)) / 1e6;
}

// A missing streaming bill is settled only by the provider record for that exact generation.
export function generationCharge(row, response) {
  const data = response?.data;
  if (response?.status !== 200 || !row.generation || data?.id !== row.generation
    || typeof data.model !== 'string' || !(data.model === row.model || data.model.startsWith(row.model + '-'))
    || typeof data.total_cost !== 'number' || !Number.isFinite(data.total_cost) || data.total_cost < 0)
    throw new Error('Generation metadata does not establish this request charge');
  if (row.cost != null && Math.abs(row.cost - data.total_cost) > 1e-6)
    throw new Error('Generation cost conflicts with the settled request');
  return data.total_cost;
}

export class SpendLedger {
  constructor(path, cap) {
    if (!Number.isFinite(cap) || cap <= 0 || cap > 18) throw new Error('The authorized experiment cap must be > 0 and <= $18');
    this.path = path; this.cap = cap;
    this.rows = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : [];
    if (!Array.isArray(this.rows) || this.rows.some(r => !Number.isFinite(r.hold) || r.hold < 0
      || (r.cost != null && (!Number.isFinite(r.cost) || r.cost < 0)))) throw new Error('Invalid spend ledger');
  }
  get exposure() { return this.rows.reduce((s, r) => s + (r.cost ?? r.hold), 0); }
  get actual() { return this.rows.reduce((s, r) => s + (r.cost ?? 0), 0); }
  get outstanding() { return this.rows.reduce((s, r) => s + (r.cost == null ? r.hold : 0), 0); }
  save() { writeFileSync(`${this.path}.tmp`, JSON.stringify(this.rows, null, 2)); renameSync(`${this.path}.tmp`, this.path); }
  identify(id, generation) {
    const r = this.rows.find(r => r.id === id);
    if (!r || typeof generation !== 'string' || !generation) throw new Error('Invalid generation identity');
    if (r.generation && r.generation !== generation) throw new Error('Generation identity changed');
    r.generation = generation; this.save();
  }
  reserve(hold, details) {
    if (!Number.isFinite(hold) || hold < 0) throw new Error('Invalid hold');
    if (this.rows.some(r => r.overrun)) throw new Error('Prior reservation overrun requires reconciliation');
    if (this.exposure + hold > this.cap + 1e-9) throw new Error(`Budget admission refused: $${this.exposure.toFixed(3)} spent/held + $${hold.toFixed(3)} hold > $${this.cap}`);
    const row = { id: randomUUID(), hold, cost: null, ...details, at: new Date().toISOString() };
    this.rows.push(row); this.save(); return row.id;
  }
  settle(id, cost) {
    const r = this.rows.find(r => r.id === id);
    if (!r || r.cost != null) throw new Error('Unknown or already settled hold');
    // An interrupted response or missing cost retains the entire hold across restarts.
    if (typeof cost !== 'number' || !Number.isFinite(cost) || cost < 0) return;
    r.cost = cost; r.finished_at = new Date().toISOString(); r.overrun = cost > r.hold; this.save();
  }
}
