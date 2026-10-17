// Chat profiles, 2026-10-16 (docs/architecture/CHAT.md "Chat redesign from build 57 feedback"): automatic effort is
// deterministic and follows the published rules; the table grows additively, so what builds 57/58 decode from it is
// exactly what they decoded before; DeepSeek and `auto` profiles are published with their estimates.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  asksForReasoning, AUTO_EFFORTS, autoEffort, carriesEquation, estimateCredits, parseChoice, publishedProfiles, resolveChoice, resolveProfile,
  type EffortChoice, type LengthChoice,
} from '../../supabase/functions/_shared/chat-profiles.ts';

// ---- Automatic effort ----

type Case = { question: string; selection?: string; figures?: number; want: [EffortChoice, EffortChoice, EffortChoice] };
// [brief, standard, detailed]
const CASES: Case[] = [
  { question: 'What is the main contribution of this paper?', want: ['low', 'low', 'medium'] },
  { question: 'Summarize the experiments in a few lines.', want: ['low', 'low', 'medium'] },
  { question: 'What dataset do they use for summarization?', want: ['low', 'low', 'medium'] },
  { question: 'Can you improve the wording of this paragraph?', want: ['low', 'low', 'medium'] },
  { question: 'What is this passage about?', selection: 'We derive our approach by first proving that the optimal policy has a closed form.', want: ['low', 'low', 'medium'] },
  { question: 'Why does DPO need a reference model?', want: ['low', 'medium', 'high'] },
  { question: 'Why is this important?', want: ['low', 'medium', 'high'] },
  { question: 'Why doesn’t the loss blow up when the policy drifts?', want: ['low', 'medium', 'high'] },
  { question: 'Derive the DPO loss from the KL-constrained objective.', want: ['low', 'medium', 'high'] },
  { question: 'Prove that the optimal policy has this form.', want: ['low', 'medium', 'high'] },
  { question: 'Show that the gradient raises the likelihood of preferred responses.', want: ['low', 'medium', 'high'] },
  { question: 'Go step by step through the Bradley–Terry part.', want: ['low', 'medium', 'high'] },
  { question: 'Walk me through Figure 1.', want: ['low', 'medium', 'high'] },
  { question: 'Compare DPO with PPO-based RLHF.', want: ['low', 'medium', 'high'] },
  { question: 'DPO vs. PPO: which is cheaper to train?', want: ['low', 'medium', 'high'] },
  { question: 'What are the trade-offs of a larger beta?', want: ['low', 'medium', 'high'] },
  { question: 'Give me the intuition behind the implicit reward.', want: ['low', 'medium', 'high'] },
  { question: 'Explain equation 7.', want: ['low', 'medium', 'high'] },
  { question: 'Can you explain the KL term?', want: ['low', 'medium', 'high'] },
  { question: 'How does the reference model work in practice?', want: ['low', 'medium', 'high'] },
  // An equation (the selection or the question) or a figure raises Standard only.
  { question: 'What does this mean?', selection: '\\mathcal{L}_{\\mathrm{DPO}}(\\pi_\\theta; \\pi_{\\mathrm{ref}}) = -\\mathbb{E}\\left[\\log \\sigma(\\cdot)\\right]', want: ['low', 'medium', 'medium'] },
  { question: 'What does this mean?', selection: 'where β = 0.1 controls the deviation from πref', want: ['low', 'medium', 'medium'] },
  { question: 'What is x_i here?', want: ['low', 'medium', 'medium'] },
  { question: 'What does \\( r(x, y) \\) stand for?', want: ['low', 'medium', 'medium'] },
  { question: 'What does Figure 2 show?', figures: 1, want: ['low', 'medium', 'medium'] },
];

test('automatic effort follows the published rules on a table of questions', () => {
  for (const c of CASES) {
    const signals = { question: c.question, selection: c.selection ?? null, figures: c.figures ?? 0 };
    const got = (['brief', 'standard', 'detailed'] as LengthChoice[]).map(length => autoEffort(length, signals));
    assert.deepEqual(got, c.want, `${c.question}${c.selection ? ` | ${c.selection.slice(0, 30)}` : ''}${c.figures ? ' | figure' : ''}`);
    // Pure and deterministic: the same inputs always pick the same effort.
    assert.deepEqual((['brief', 'standard', 'detailed'] as LengthChoice[]).map(length => autoEffort(length, { ...signals })), got);
  }
  // The picks stay within the published range for each length.
  for (const c of CASES) for (const length of ['brief', 'standard', 'detailed'] as LengthChoice[]) {
    const pick = autoEffort(length, { question: c.question, selection: c.selection ?? null, figures: c.figures ?? 0 });
    const order = ['low', 'medium', 'high'];
    assert.ok(order.indexOf(pick) >= order.indexOf(AUTO_EFFORTS[length].usual) && order.indexOf(pick) <= order.indexOf(AUTO_EFFORTS[length].highest));
  }
  assert.equal(asksForReasoning('improve, approve, provide'), false);
  assert.equal(carriesEquation('The model is trained on summaries and dialogues.'), false);
  assert.equal(carriesEquation(null), false);
});

test('auto is a request value, resolved to a concrete profile; explicit efforts pass through unchanged', () => {
  assert.deepEqual(parseChoice({ model: 'sonnet', effort: 'auto', length: 'standard' }), { model: 'sonnet', effort: 'auto', length: 'standard' });
  assert.deepEqual(parseChoice({ model: 'deepseek', effort: 'low', length: 'brief' }), { model: 'deepseek', effort: 'low', length: 'brief' });
  for (const bad of [{ model: 'sonnet', effort: 'Auto', length: 'standard' }, { model: 'sonnet', effort: 'max', length: 'standard' },
    { model: 'deepseek-flash', effort: 'auto', length: 'standard' }]) assert.throws(() => parseChoice(bad));
  const why = { question: 'Why does this work?', selection: null, figures: 0 };
  assert.deepEqual(resolveChoice({ model: 'sonnet', effort: 'auto', length: 'standard' }, why), { model: 'sonnet', effort: 'medium', length: 'standard' });
  assert.deepEqual(resolveChoice({ model: 'opus', effort: 'low', length: 'detailed' }, why), { model: 'opus', effort: 'low', length: 'detailed' });
  assert.equal(resolveChoice(null, why), null);
  assert.equal(resolveProfile(resolveChoice({ model: 'deepseek', effort: 'auto', length: 'detailed' }, why)).id, 'deepseek-high-detailed');
});

// ---- The published table and the builds that decode it ----

/** ChatProfileTable.decode as shipped in builds 57/58 (ScienceReaderCore/ChatProfiles.swift) and the browser's
 * decodeProfileTable (apps/web/src/lib/chat-profiles.ts) at the same time: frozen here, because those builds will not
 * change. Returns what such a build offers, or null when it would refuse the table. */
function decodeAsBuild57(body: string) {
  if (Buffer.byteLength(body) > 64 * 1024) return null;
  const wire = JSON.parse(body);
  const MODELS = ['haiku', 'sonnet', 'opus'], EFFORTS = ['low', 'medium', 'high'], LENGTHS = ['brief', 'standard', 'detailed'];
  // Swift decodes every array element strictly: one malformed entry fails the whole table.
  const named = (list: unknown) => list === undefined || (Array.isArray(list) && list.every(n => typeof n?.id === 'string' && typeof n?.label === 'string'
    && (n.detail === undefined || typeof n.detail === 'string')));
  if (wire.version !== 'chat-profiles-v1' || !named(wire.models) || !named(wire.efforts) || !named(wire.lengths) || !Array.isArray(wire.profiles)) return null;
  const integer = (n: unknown) => Number.isSafeInteger(n);
  if (!wire.profiles.every((p: Record<string, any>) => typeof p.model === 'string' && typeof p.effort === 'string' && typeof p.length === 'string'
    && p.credits && integer(p.credits.low) && integer(p.credits.high) && integer(p.credits.max))) return null;
  const d = wire.default;
  if (!MODELS.includes(d?.model) || !EFFORTS.includes(d?.effort) || !LENGTHS.includes(d?.length)) return null;
  const text = (value: string, limit: number) => { const flat = value.replace(/[\p{Cc}\p{Cf}]/gu, '').trim(); return flat && [...flat].length <= limit ? flat : null; };
  const options = (list: { id: string; label: string; detail?: string }[] | undefined, keys: string[]) => Object.fromEntries((list ?? [])
    .filter(n => keys.includes(n.id) && text(n.label, 24)).map(n => [n.id, { label: text(n.label, 24), detail: n.detail ? text(n.detail, 80) ?? '' : '' }]));
  const estimates: Record<string, { low: number; high: number; max: number }> = {};
  for (const p of wire.profiles.slice(0, 64)) {
    if (!MODELS.includes(p.model) || !EFFORTS.includes(p.effort) || !LENGTHS.includes(p.length)) continue;
    if (p.credits.low < 0 || p.credits.low > p.credits.high || p.credits.high > p.credits.max || p.credits.max >= 1_000_000) continue;
    estimates[`${p.model}-${p.effort}-${p.length}`] = p.credits;
  }
  if (!estimates[`${d.model}-${d.effort}-${d.length}`]) return null;
  return { default: `${d.model}-${d.effort}-${d.length}`, models: options(wire.models, MODELS), efforts: options(wire.efforts, EFFORTS),
    lengths: options(wire.lengths, LENGTHS), estimates, note: typeof wire.estimate_note === 'string' ? text(wire.estimate_note, 200) : null };
}

const build57 = readFileSync(new URL('../fixtures/chat-profiles-v1-build57.json', import.meta.url), 'utf8');

test('builds 57/58 retain their choices and prices when the table grows', () => {
  const before = decodeAsBuild57(build57);
  assert.ok(before && Object.keys(before.estimates).length === 27 && before.default === 'sonnet-low-standard');
  // Display descriptions are server-controlled; the inaccurate superlative is corrected for every build.
  before.models.haiku.detail = 'Quick, economical explanations';
  for (const deepseek of [true, false]) for (const gemini of [true, false]) {
    const table = publishedProfiles({ deepseek, gemini }), body = JSON.stringify(table);
    assert.ok(Buffer.byteLength(body) < 32 * 1024, `the table stays well under the 64 KiB decoders' limit (${Buffer.byteLength(body)} bytes)`);
    assert.deepEqual(decodeAsBuild57(body), before, `deepseek ${deepseek}`);
    // The version and the default are the ones those builds require; the 27 profiles they know come first, unchanged.
    assert.equal(table.version, 'chat-profiles-v1');
    assert.deepEqual(table.default, { model: 'sonnet', effort: 'low', length: 'standard' });
    assert.deepEqual(table.profiles.slice(0, 27), JSON.parse(build57).profiles);
    assert.ok(table.profiles.length <= 64, 'every profile is within what an old decoder reads');
  }
});

test('the table publishes DeepSeek, the automatic effort and its profiles, and the default new clients start with', () => {
  const table = publishedProfiles({ deepseek: true });
  assert.deepEqual(table.default_auto, { model: 'sonnet', effort: 'auto', length: 'standard' });
  assert.deepEqual(table.models.map(m => [m.id, m.api_model, m.provider]), [['haiku', 'claude-haiku-5-5', 'anthropic'], ['sonnet', 'claude-sonnet-5-5', 'anthropic'],
    ['opus', 'claude-opus-5-5', 'anthropic'], ['deepseek', 'deepseek-flash', 'deepseek']]);
  const deepseek = table.models.find(m => m.id === 'deepseek')! as Record<string, unknown>;
  assert.equal(deepseek.label, 'DeepSeek'); assert.equal(deepseek.consent_version, 'cloud-ai-v4');
  for (const m of table.models) { assert.ok(m.label.length <= 24 && m.detail.length <= 80); }
  assert.deepEqual(table.efforts.at(-1), { id: 'auto', label: 'Automatic', detail: 'Chosen for each question' });
  assert.deepEqual(table.efforts.map(e => e.id), ['low', 'medium', 'high', 'auto']);
  assert.equal(table.profiles.length, 27 + 9 + 12); assert.equal(new Set(table.profiles.map(p => p.id)).size, table.profiles.length);
  const byID = new Map(table.profiles.map(p => [p.id, p]));
  // Every entry is ordered (low <= high <= max); DeepSeek's sit between Haiku's and Sonnet's.
  for (const p of table.profiles) assert.ok(p.credits.low <= p.credits.high && p.credits.high <= p.credits.max, `${p.id} estimate is ordered`);
  for (const e of ['low', 'medium', 'high']) for (const l of ['brief', 'standard', 'detailed']) {
    const [h, d, s] = ['haiku', 'deepseek', 'sonnet'].map(m => byID.get(`${m}-${e}-${l}`)!);
    assert.equal(d.api_model, 'deepseek-flash'); assert.equal(d.max_output_tokens, s.max_output_tokens, 'allowances do not depend on the model');
    assert.ok(h.credits.max <= d.credits.max && d.credits.max < s.credits.max && d.credits.high < s.credits.high, `${e}/${l}: DeepSeek between Haiku and Sonnet`);
  }
  // DeepSeek's documented estimate (CHAT.md): about 1–3 credits for a typical question, at most 5.
  assert.deepEqual(byID.get('deepseek-low-standard')!.credits, { low: 1, high: 3, max: 5 });
  // An auto profile: the estimate of the effort usually picked, the maximum (and allowance) of the highest it can pick.
  for (const m of ['haiku', 'sonnet', 'opus', 'deepseek']) for (const l of ['brief', 'standard', 'detailed'] as LengthChoice[]) {
    const auto = byID.get(`${m}-auto-${l}`)!, usual = byID.get(`${m}-${AUTO_EFFORTS[l].usual}-${l}`)!, highest = byID.get(`${m}-${AUTO_EFFORTS[l].highest}-${l}`)!;
    assert.equal(auto.effort, 'auto');
    assert.deepEqual(auto.credits, { low: usual.credits.low, high: usual.credits.high, max: highest.credits.max }, auto.id);
    assert.equal(auto.max_output_tokens, highest.max_output_tokens);
  }
  assert.deepEqual(byID.get('sonnet-auto-standard')!.credits, { low: 4, high: 24, max: 41 });
  assert.deepEqual(byID.get('sonnet-auto-detailed')!.credits, { low: 9, high: 28, max: 57 });
  // Without DeepSeek (off, or hidden while its check runs) nothing of it is published.
  const off = publishedProfiles({ deepseek: false });
  assert.ok(!JSON.stringify(off).includes('deepseek')); assert.equal(off.profiles.length, 27 + 9);
  assert.equal(estimateCredits(resolveProfile({ model: 'deepseek', effort: 'low', length: 'standard' })).max, 5);
});
