// Podcast checker v3: verbatim evidence through one canonical form, claim-rule degradation, bounded
// diagnostics and the speech-size fit, on excerpts of the two staging seed-pilot papers (CC BY 4.0,
// tests/fixtures/podcast/evidence/attribution.txt). No network and no provider: local fixtures only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { applyCorrections, boundReport, checkScript, CHECKER_VERSION, FIVE_MINUTE_SHAPE, REPORT_MAX_BYTES, REVIEW_REASON_CODES, reviewRequest, SCRIPT_INSTRUCTIONS, scriptInstructions,
  type CheckReport, type ReviewCorrections, type Script } from '../../supabase/functions/_shared/podcast-script.ts';
import { canonicalQuote, evidenceNumbers, indexPaper, latexFromPaper, numberValue, spokenNumbers, verifyQuote,
  type PaperIndex } from '../../supabase/functions/_shared/podcast-evidence.ts';
import { fitSpeech, PART_OVERHEAD_BYTES, planSpeechChunks, shortStyle, speechRequest, spokenCharacterBudget } from '../../supabase/functions/_shared/podcast-speech.ts';

const fixture = (name: string) => readFileSync(new URL(`../fixtures/podcast/evidence/${name}`, import.meta.url), 'utf8');
const PERSONA = fixture('2610.09384v1-excerpt.mmd'), DECOUPLING = fixture('2610.10536v1-excerpt.mmd');
const INDEX: Record<'A' | 'B', PaperIndex> = { A: indexPaper(PERSONA), B: indexPaper(DECOUPLING) };
const TEXT = { A: PERSONA, B: DECOUPLING };
const draft = (name: string): Script => ({ ...JSON.parse(fixture(name)), review: { verdict: 'accept', issues: [] } });
const CODE = /^[a-z0-9][a-z0-9_:.-]{0,63}$/;
/** Every string a report holds is a short code (the database refuses anything else). */
const codesOnly = (value: unknown): boolean => typeof value === 'string' ? CODE.test(value) : Array.isArray(value) ? value.every(codesOnly)
  : value && typeof value === 'object' ? Object.entries(value).every(([k, v]) => /^[a-z][a-z0-9_]{0,31}$/.test(k) && codesOnly(v)) : true;
const storedSize = (report: CheckReport) => { const s = JSON.stringify(report); return s.length + (s.match(/[:,]/g)?.length ?? 0); };

// Quotes as a script model writes them: formatting variants of real text (must verify) and invalid quotes (must be refused).
const VARIANTS: [keyof typeof INDEX, string, string][] = [
  ['A', 'exact, inline math kept', "generalization narrowness positively correlates with the similarity between the training context's persona and the default persona (Pearson's \\(r = 0.72\\) for Qwen3-4B)."],
  ['A', 'math delimiters stripped', "generalization narrowness positively correlates with the similarity between the training context's persona and the default persona (Pearson's r = 0.72 for Qwen3-4B)."],
  ['A', 'dollar math', "the default persona (Pearson's $r = 0.72$ for Qwen3-4B)"],
  ['A', 'percent unescaped', 'In RL, PPR cuts reward hacking from 42-55% to at most 0.2% under every evaluated prompt while retaining accuracy gains.'],
  ['A', 'en dash in a range', 'PPR cuts reward hacking from 42–55% to at most 0.2% under every evaluated prefix without sacrificing the accuracy gains of RL'],
  ['A', 'citation removed at the end', 'For example, reward hacking learned through reinforcement learning (RL) under one system prompt can generalize broadly, persisting even under prompts that explicitly prohibit it.'],
  ['A', 'citation removed mid-sentence', 'We sample 10,000 examples from FineWeb and compute the persona vector by averaging the hidden states at the final input token across these examples'],
  ['A', 'curly apostrophe', 'we find that the distance between a context’s persona vector and the default, measured before fine-tuning, is positively correlated with how narrowly the learned behavior will generalize'],
  ['A', 'curly quotes', 'behavior learned under some prefixes, such as “You are a helpful assistant,” transfers broadly across evaluation contexts'],
  ['A', 'math rewritten', 'the mean Pearson correlations are 0.72 and 0.59 (permutation p < 10^-4 for both), and the mean Spearman correlations are 0.60 and 0.47.'],
  ['A', 'math respaced', 'Let \\(f_\\theta\\) be the model being trained and \\(f_0\\) its frozen initialization.'],
  ['A', 'unicode minus', 'reward-hacking narrowness decreases from 18.5 to −0.1 points under Playful Mentor and from 34.6 to 2.0 under Competitor'],
  ['A', 'line-break hyphen in the source', "we compute the distance between each Stage-2 prefix's persona vector and the default persona vector before and after Stage 1"],
  ['A', 'ligature', 'Prior ﬁne-tuning under the default context can broaden generalization in subsequent training under other contexts.'],
  ['A', 'soft hyphen', 'generalization nar­rowness positively correlates with the similarity between the training context'],
  ['A', 'fullwidth punctuation in the source table', 'You are a counselor who provides compassionate guidance and emotional support to those seeking help.'],
  ['A', 'caption with escaped percent', 'Figure 2: Goblin mention rate (%) of Llama-3.1-8B across training (rows) and evaluation (columns) prefixes.'],
  ['B', 'citation brackets removed', 'Reinforcement learning with verifiable rewards (RLVR) has become the dominant recipe for improving the reasoning abilities of language models.'],
  ['B', 'times sign as x', 'A single round of ExpDis already outperforms DAPO trained for 4x as many steps.'],
  ['B', 'greek letter in unicode', 'We find that performance roughly peaks at λ = 0.5 and conduct all experiments with this value of λ.'],
  ['B', 'greek letter spelled out', 'We find that performance roughly peaks at lambda = 0.5 and conduct all experiments with this value of lambda.'],
  ['B', 'citation and math stripped', 'Shao et al. observe that RL improves majority-vote accuracy but not pass@k'],
  ['B', 'diacritics dropped', 'Simsek and Barto explore with a policy rewarded for improving a separate task value function that never sees this reward'],
  ['B', 'superscript rewritten', 'E^3 keeps separate exploration and exploitation policies and explicitly switches between them'],
  ['B', 'markdown emphasis', 'This decoupling allows us to **aggressively scale exploration** without degrading the student policy.'],
  ['B', 'macro braces', 'A trajectory passes the filter only if (1) its final \\boxed{} answer is correct'],
];
const INVALID: [keyof typeof INDEX, string, string, string][] = [
  ['A', 'paraphrase', 'PPR reduces reward hacking to almost zero while keeping the accuracy improvements from RL.', 'not_found'],
  ['A', 'wrong number', 'the mean Pearson correlations are 0.27 and 0.59', 'not_found'],
  ['A', 'two sentences spliced', 'PPR cuts reward hacking from 42-55\\% to at most 0.2\\% and achieves the highest accuracy under the Default and Anti-hack prefixes.', 'not_found'],
  ['A', 'negation inserted', 'We do claim that persona distance and generalization narrowness are linearly related on every dataset.', 'not_found'],
  ['A', 'number cut at its decimal point', "The safety prompt reduces the fine-tuned model's acceptance to 26", 'not_found'],
  ['A', 'across a heading', 'better alignment of LLMs. 1 Introduction LLMs are commonly fine-tuned with a consistent context', 'not_found'],
  ['A', 'formula only', '\\(r = 0.72\\)', 'math_only'],
  ['A', 'name only', 'Qwen3-4B', 'too_short'],
  ['B', 'decimal point dropped', 'find that mean accuracy drops by at most 16 points', 'not_found'],
  ['B', 'explanatory aside removed', 'Finally, we replace RND with a kNN-based or an elliptical novelty bonus and find that mean accuracy drops by at most 1.6 points', 'not_found'],
  ['B', 'formula only', '\\(\\lambda = 0.5\\)', 'math_only'],
  ['B', 'over the length bound', 'We '.repeat(140) + 'cap the resulting set at 500 trajectories per round.', 'too_long'],
];

test('evidence: formatting variants of real text verify and are stored as the paper’s own span, at its offset', () => {
  for (const [paper, kind, quote] of VARIANTS) {
    const result = verifyQuote(INDEX[paper], quote);
    assert.ok(result.ok, `${kind}: ${JSON.stringify(result)}`);
    if (!result.ok) continue;
    for (const span of result.spans) {
      // Integrity: the stored quote is the pinned text itself (whitespace-normalized), found at its offset.
      assert.equal(TEXT[paper].slice(span.offset).replace(/\s+/g, ' ').indexOf(span.quote), 0, `${kind}: verbatim at offset`);
      assert.ok(span.quote.length >= 12 && span.quote.length <= 600);
    }
  }
  // The span keeps the paper's markup and numbers exactly (never the model's rendering).
  const stripped = verifyQuote(INDEX.A, 'In RL, PPR cuts reward hacking from 42-55% to at most 0.2% under every evaluated prompt while retaining accuracy gains.');
  assert.ok(stripped.ok && stripped.spans[0].quote === 'In RL, PPR cuts reward hacking from 42-55\\% to at most 0.2\\% under every evaluated prompt while retaining accuracy gains.');
  assert.deepEqual(stripped.ok && stripped.repairs, ['escapes']);
  const math = verifyQuote(INDEX.A, "the default persona (Pearson's r = 0.72 for Qwen3-4B)");
  assert.ok(math.ok && math.spans[0].quote.endsWith("(Pearson's \\(r = 0.72\\) for Qwen3-4B)."), 'never cut inside a formula; closing bracket and period kept');
  const minus = verifyQuote(INDEX.A, 'narrowness decreases from 18.5 to 0.1 points under Playful Mentor');
  assert.ok(minus.ok && minus.spans[0].quote.includes('to -0.1 points'), 'the paper’s sign is kept in the stored span');
  const exact = verifyQuote(INDEX.B, 'We cap the resulting set at 500 trajectories per round.');
  assert.ok(exact.ok && exact.repairs.length === 0 && exact.spans[0].quote === 'We cap the resulting set at 500 trajectories per round.');
});

test('evidence: page-split sentences, ellipses and citation-only removals; nothing is joined across real boundaries', () => {
  // Mathpix emits pages in order, so a sentence can run around a page break and its floats.
  const split = verifyQuote(INDEX.B, 'Others find that RL can expand this set through prolonged training, or that the model learns new skills by composing existing ones.');
  assert.ok(split.ok, JSON.stringify(split));
  if (split.ok) {
    assert.deepEqual(split.spans.map(s => s.quote), ['Others find that RL can expand this set through prolonged', 'training [25], or that the model learns new skills by composing existing ones']);
    assert.ok(split.repairs.includes('page_split') && split.repairs.includes('citations'));
  }
  const tail = verifyQuote(INDEX.A, 'We investigate whether dependence on these two sets of token positions differs with the narrowness of generalization.');
  assert.ok(tail.ok && tail.spans.length === 1 && tail.spans[0].quote.startsWith('investigate whether'), 'a side too short to stand alone is left out');
  const ellipsis = verifyQuote(INDEX.A, 'the mean Pearson correlations are 0.72 and 0.59 … and the mean Spearman correlations are 0.60 and 0.47.');
  assert.ok(ellipsis.ok && ellipsis.spans.length === 2 && ellipsis.repairs.includes('ellipsis'), 'each fragment verified on its own');
  // A paragraph that ends a sentence is never joined to the next one.
  assert.equal(verifyQuote(INDEX.A, 'remains poorly understood. We propose the Persona Hierarchy Model to explain the variation').ok, false);
});

test('evidence: invalid quotes are refused with a reason and offsets only', () => {
  for (const [paper, kind, quote, reason] of INVALID) {
    const result = verifyQuote(INDEX[paper], quote);
    assert.equal(result.ok, false, `${kind} must be refused`);
    if (result.ok) continue;
    assert.equal(result.reason, reason, kind);
    assert.deepEqual(Object.keys(result.diagnostic).sort(), ['canonical', 'chars', 'matched', 'offset']);
    assert.ok(Object.values(result.diagnostic).every(Number.isInteger));
  }
  const near = verifyQuote(INDEX.A, 'the mean Pearson correlations are 0.27 and 0.59');
  assert.ok(!near.ok && near.diagnostic.matched === canonicalQuote('the mean Pearson correlations are 0.7').length - 1 && near.diagnostic.offset > 0,
    'the diagnostic says how far the quote matched and where');
});

test('canonical form: one transformation for both sides', () => {
  assert.equal(canonicalQuote('Pearson’s \\(r = 0.72\\) [3]'), canonicalQuote("Pearson's r=0.72"));
  assert.equal(canonicalQuote('42-55\\%'), canonicalQuote('42–55%'));
  assert.equal(canonicalQuote('ﬁne-tuning'), 'finetuning');
  assert.equal(canonicalQuote('\\lambda'), canonicalQuote('λ'));
  assert.equal(canonicalQuote('LLMs. \\({ } ^ { 1 }\\)'), 'llms', 'Mathpix footnote marks');
  assert.notEqual(canonicalQuote('1.6 points'), canonicalQuote('16 points'), 'decimal points between digits are kept');
  assert.equal(canonicalQuote('(Lu et al., 2026; OpenAI, 2026) text'), 'text', 'author-year citations');
  assert.equal(canonicalQuote('(Section 4) text'), 'section4text', 'other parentheticals are text');
});

test('spoken numbers: names and existing paper references are not claims; other digits need the segment’s own evidence', () => {
  // The staging failures: digits in model names (job 1, unsupported_number:s9) and numbers outside the cited quote (job 2, number_not_in_evidence:s13).
  assert.deepEqual(spokenNumbers(INDEX.A, 'They run all of this on Qwen3-4B and Llama-3.1-8B-Instruct.'), []);
  assert.deepEqual(spokenNumbers(INDEX.B, 'The base models are Qwen3-1.7B, Qwen3-4B and Ministral-3-3B-Instruct-2512.'), []);
  assert.deepEqual(spokenNumbers(INDEX.B, 'It wins on pass@1 and pass@64, including on AIME24.'), []);
  assert.deepEqual(spokenNumbers(INDEX.A, 'Section 4 is all correlation, and Figure 3 shows it; Table 2 lists the targets.'), []);
  assert.deepEqual(spokenNumbers(INDEX.A, 'Section 14 says so.'), ['14'], 'a section that does not exist is a number');
  assert.deepEqual(spokenNumbers(INDEX.A, 'Qwen3-14B does better.'), ['3', '14'], 'a name the paper never uses is not exempt');
  assert.deepEqual(spokenNumbers(INDEX.B, 'Each run gets 300 RL steps, 1,200 for the long DAPO run, and the 4B model is used.'), ['300', '1200', '4']);
  // Evidence numbers are read from the paper's span, with Mathpix's spaced-out digit groups rejoined.
  assert.deepEqual([...evidenceNumbers(['Standard GRPO & \\(\\mathbf { 4 5 . 4 } \\pm 6.3\\) & 32,768 and 1,2,4'])].sort(), ['1', '2', '32768', '4', '45.4', '6.3']);
  assert.deepEqual([numberValue('100.0'), numberValue('0.50'), numberValue('007')], ['100', '0.5', '7']);
  // Formula notes: the paper's LaTeX modulo whitespace and delimiters; anything else is not from the paper.
  assert.ok(latexFromPaper(INDEX.A, 'f_{\\theta}') && latexFromPaper(INDEX.A, '\\(f _ { 0 }\\)') && !latexFromPaper(INDEX.A, 'f_{\\phi}'));
});

test('checker v3 on the two seed papers: realistic drafts degrade instead of failing, and every kept claim is supported', () => {
  for (const [name, paper, text, removals] of [
    ['2610.09384v1-draft.json', INDEX.A, PERSONA, [{ segment: 's11', reason: 'number_not_in_evidence' }, { segment: 's18', reason: 'evidence_missing' }]],
    ['2610.10536v1-draft.json', INDEX.B, DECOUPLING, [{ segment: 's13', reason: 'number_not_in_evidence' }]],
  ] as const) {
    const script = draft(name);
    const result = checkScript(script, text, { index: paper });
    assert.ok(result.ok, `${name}: ${result.ok ? '' : result.problems.join(' ')}`);
    if (!result.ok) continue;
    assert.equal(result.report.outcome, 'degraded');
    assert.deepEqual(result.report.removals, removals);
    assert.equal(result.report.checker, CHECKER_VERSION);
    // The staging failure classes (names and section references in unevidenced turns) no longer remove anything.
    for (const id of name.startsWith('2610.09384') ? ['s9', 's13'] : ['s12']) assert.ok(result.script.segments.some(s => s.id === id), `${id} kept`);
    for (const segment of result.script.segments) {
      for (const e of segment.evidence) assert.equal(text.slice(e.offset).replace(/\s+/g, ' ').indexOf(e.quote), 0, `${segment.id}: verbatim evidence`);
      const stated = evidenceNumbers(segment.evidence.map(e => e.quote));
      for (const n of spokenNumbers(paper, segment.text)) assert.ok(stated.has(n), `${segment.id}: ${n} stated by its evidence`);
      if (segment.claim_type === 'paper_result' || segment.claim_type === 'author_interpretation') assert.ok(segment.evidence.length > 0);
    }
    assert.deepEqual(result.script.segments.map(s => s.evidence.map(e => e.id)).flat(), result.script.segments.flatMap(s => s.evidence).map((_, i) => `e${i + 1}`));
    const evidence = result.report.evidence!;
    assert.ok(evidence.unverified / evidence.checked <= 0.3 && evidence.unverified <= 2);
    assert.ok(codesOnly(result.report) && storedSize(result.report) <= REPORT_MAX_BYTES);
  }
});

test('checker v5 removes a dangling question when its answer was removed', () => {
  const script: Script = {
    title: 'Coherent host turns', limitations: [],
    chapters: [{ id: 'c1', title: 'Opening' }, { id: 'c2', title: 'Evidence' }, { id: 'c3', title: 'Close' }],
    segments: [
      { id: 's1', chapter: 'c1', speaker: 'explainer', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'We begin with the question.' },
      { id: 's2', chapter: 'c1', speaker: 'skeptic', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'What does the paper test?' },
      { id: 's3', chapter: 'c1', speaker: 'explainer', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'It compares two approaches.' },
      { id: 's4', chapter: 'c2', speaker: 'skeptic', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'Can we trust that comparison?' },
      { id: 's5', chapter: 'c2', speaker: 'explainer', style: 'clear', claim_type: 'context', evidence: [], math: [], text: '**unusable markup**' },
      { id: 's6', chapter: 'c2', speaker: 'skeptic', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'We mark that issue for later.' },
      { id: 's7', chapter: 'c3', speaker: 'explainer', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'The closing caveat matters.' },
      { id: 's8', chapter: 'c3', speaker: 'skeptic', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'That gives the listener a clear ending.' },
    ],
    review: { verdict: 'accept', issues: [] },
  };
  const result = checkScript(script, PERSONA, { fixture: true });
  assert.ok(result.ok, result.ok ? '' : result.problems.join(', '));
  if (!result.ok) return;
  assert.deepEqual(result.report.removed, { markup: 1, unanswered_question: 1 });
  assert.deepEqual(result.report.removals, [{ segment: 's5', reason: 'markup' }, { segment: 's4', reason: 'unanswered_question' }]);
  assert.deepEqual(result.script.segments.map(s => s.id), ['s1', 's2', 's3', 's6', 's7', 's8']);
});

test('checker v5 does not use an unrelated later turn as a removed answer', () => {
  const script: Script = {
    title: 'No dangling prompt', limitations: [],
    chapters: [{ id: 'c1', title: 'Opening' }],
    segments: [
      { id: 's1', chapter: 'c1', speaker: 'skeptic', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'What does this comparison establish?' },
      { id: 's2', chapter: 'c1', speaker: 'explainer', style: 'clear', claim_type: 'context', evidence: [], math: [], text: '**removed answer**' },
      { id: 's3', chapter: 'c1', speaker: 'explainer', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'The closing limitation still matters.' },
      { id: 's4', chapter: 'c1', speaker: 'skeptic', style: 'clear', claim_type: 'context', evidence: [], math: [], text: 'That is the point to carry forward.' },
    ],
    review: { verdict: 'accept', issues: [] },
  };
  const result = checkScript(script, PERSONA, { fixture: true });
  assert.ok(result.ok, result.ok ? '' : result.problems.join(', '));
  if (!result.ok) return;
  assert.deepEqual(result.report.removals, [{ segment: 's2', reason: 'markup' }, { segment: 's1', reason: 'unanswered_question' }]);
  assert.deepEqual(result.script.segments.map(s => s.id), ['s3', 's4']);
});

test('degradation limits: unverifiable evidence or removed claims beyond 30%, or a chapter losing its support, reject the script', () => {
  const base = draft('2610.10536v1-draft.json');
  const rejected = (mutate: (s: Script) => void) => { const s = structuredClone(base); mutate(s); const r = checkScript(s, DECOUPLING, { index: INDEX.B }); assert.ok(!r.ok); return r; };
  // Paraphrase eight of twenty-three quotes (35%): the draft is too far from its paper to repair.
  const many = rejected(s => s.segments.filter(x => x.evidence.length).slice(0, 8).forEach(x => { x.evidence[0].quote = 'A sentence the paper never contains, written by the model.'; }));
  assert.ok(!many.ok && many.problems.includes('evidence_unverified_share'));
  assert.equal(many.report.outcome, 'rejected'); assert.ok(many.report.rules.includes('evidence_unverified_share'));
  // Unsupported numbers in eight of twenty-four turns (33%).
  const removed = rejected(s => s.segments.slice(0, 8).forEach(x => { x.text += ' That is 99 percent of it.'; }));
  assert.ok(!removed.ok && removed.problems.includes('segments_removed_share'));
  // The caveats chapter loses its only evidenced claims: the limitations would be heard without support.
  const caveats = rejected(s => s.segments.filter(x => x.chapter === 'c5' && x.evidence.length).forEach(x => { x.evidence = []; }));
  assert.ok(!caveats.ok && caveats.problems.includes('chapter_unsupported:c5'));
  // A chapter that loses every turn.
  const empty = rejected(s => s.segments.filter(x => x.chapter === 'c1').forEach(x => { x.text = 'Host 1: **markup**'; }));
  assert.ok(!empty.ok && empty.problems.includes('empty_chapter:c1'));
  // A rejected review is never repaired.
  const review = rejected(s => { s.review = { verdict: 'reject', issues: [] }; });
  assert.ok(!review.ok && review.problems.includes('review_rejected'));
  // A material claim is removed, never relabeled as context.
  const one = structuredClone(base); one.segments[1].evidence = [];
  const kept = checkScript(one, DECOUPLING, { index: INDEX.B });
  assert.ok(kept.ok && !kept.script.segments.some(s => s.id === 's2'));
  if (kept.ok) for (const s of kept.script.segments) assert.equal(s.claim_type, one.segments.find(x => x.id === s.id)!.claim_type, `${s.id} keeps its claim type`);
  // A formula note that is not from the paper is dropped on its own; the turn stays.
  const note = structuredClone(base); note.segments[8].math = [{ latex: '\\lambda = 0.9', spoken: 'lambda equals nought point nine' }, { latex: '\\lambda = 0.5', spoken: 'lambda one half' }];
  const noted = checkScript(note, DECOUPLING, { index: INDEX.B });
  assert.ok(noted.ok && noted.script.segments.find(s => s.id === 's9')!.math.map(m => m.latex).join() === '\\lambda = 0.5' && noted.report.math!.dropped === 1);
});

test('reports: counts, codes, ids and offsets only; bounded to the event size whatever the script', () => {
  const s = draft('2610.09384v1-draft.json');
  // Every quote wrong and every turn broken: the largest report a script can produce.
  for (const x of s.segments) { x.evidence = [1, 2, 3, 4].map(() => ({ quote: x.text, section: 'Secret section text' })); x.text += ' 12345'; }
  const result = checkScript(s, PERSONA, { index: INDEX.A });
  assert.ok(!result.ok);
  const report = result.report;
  assert.ok(storedSize(report) <= REPORT_MAX_BYTES, `report ${storedSize(report)} bytes`);
  assert.ok(codesOnly(report), 'the database accepts only codes');
  assert.ok(report.items!.length > 0 && report.items!.every(i => /^s\d+$/.test(i.segment) && Number.isInteger(i.offset)));
  const serialized = JSON.stringify(report);
  for (const text of ['Secret section', 'persona', 'Qwen3', s.segments[0].text.slice(0, 20)]) assert.ok(!serialized.includes(text), `no "${text}" in the report`);
  assert.equal(report.evidence!.excess, s.segments.length, 'quotes past the third are counted, not checked');
  // boundReport trims itemized lists, never the counts.
  const huge: CheckReport = { ...report, items: Array.from({ length: 40 }, (_, k) => ({ segment: `s${k + 1}`, item: 0, reason: 'not_found', chars: 300, canonical: 250, matched: 10, offset: 123456 })) };
  const bounded = boundReport(huge);
  assert.ok(storedSize(bounded) <= REPORT_MAX_BYTES && JSON.stringify(bounded.evidence) === JSON.stringify(report.evidence) && bounded.items!.length < 40);
  // Every reason code naming many turns (v4): segment lists are trimmed after items and removals; every code is kept.
  const reasons = REVIEW_REASON_CODES.map(code => ({ code, segments: s.segments.map(x => x.id) }));
  const coded = boundReport({ ...huge, reasons, review: { verdict: 'reject', corrections: 10, action: 'reject' } });
  assert.ok(storedSize(coded) <= REPORT_MAX_BYTES && codesOnly(coded), `report ${storedSize(coded)} bytes`);
  assert.deepEqual(coded.reasons!.map(r => r.code), [...REVIEW_REASON_CODES]);
  assert.ok(coded.reasons!.every(r => r.segments.length <= 20) && JSON.stringify(coded.evidence) === JSON.stringify(report.evidence));
});

// Staging job 57d019e2 was this paper (2610.09384, five minutes, worker 00015): 11 of 11 quotes verified and the checker
// would have kept 20 of 22 turns, but the review said "reject" with empty lists. The simulated draft of the same paper:
test('review reasons on the persona paper: an unexplained reject still fails; segment-scoped reasons remove their turns; severe reasons fail', () => {
  const base = draft('2610.09384v1-draft.json'); delete base.review;
  const review = (verdict: 'accept' | 'reject', reasons: ReviewCorrections['reasons'], extra: Partial<ReviewCorrections> = {}): ReviewCorrections =>
    ({ delete: [], replace: [], claims: [], ...extra, verdict, reasons });
  const run = (r: ReviewCorrections) => {
    const applied = applyCorrections(base, r, 10);
    assert.ok(applied.ok);
    return { action: (applied as { action: string }).action, result: checkScript((applied as { script: Script }).script, PERSONA, { index: INDEX.A }) };
  };
  // Accepted as written, the checker alone degrades it (two of 26 turns removed).
  const accepted = run(review('accept', []));
  assert.ok(accepted.result.ok && accepted.result.report.segments!.removed === 2);
  // The staging shape: reject, empty lists, no reason. It stands, and the report now says why.
  const unexplained = run(review('reject', []));
  assert.equal(unexplained.action, 'reject');
  assert.ok(!unexplained.result.ok);
  assert.deepEqual(unexplained.result.report.rules, ['review_rejected', 'review_reasons_missing']);
  assert.deepEqual(unexplained.result.report.review, { verdict: 'reject', corrections: 0, action: 'reject' });
  // Segment-scoped reasons with a repair: the named turns go, on top of the checker's own removals (5 of 26, 19%).
  const scoped = run(review('reject', [{ code: 'speculation_presented_as_finding', segments: ['s12'] }, { code: 'wrong_numbers', segments: ['s16', 's19'] }],
    { replace: [{ segment: 's13', text: 'The evidence so far is all correlation, though. On its own that would not convince me.', math: [], problem: 'drop section number' }] }));
  assert.equal(scoped.action, 'remove_segments');
  assert.ok(scoped.result.ok, scoped.result.ok ? '' : scoped.result.problems.join());
  const report = scoped.result.report;
  assert.equal(report.outcome, 'degraded');
  assert.deepEqual(report.segments, { checked: 26, kept: 21, removed: 5 });
  assert.deepEqual(report.removed, { review_flagged: 3, number_not_in_evidence: 1, evidence_missing: 1 });
  assert.deepEqual(report.reasons, [{ code: 'speculation_presented_as_finding', segments: ['s12'] }, { code: 'wrong_numbers', segments: ['s16', 's19'] }]);
  assert.ok(codesOnly(report) && storedSize(report) <= REPORT_MAX_BYTES);
  assert.ok(!JSON.stringify(report).includes('correlation') && !JSON.stringify(report).includes('section number'), 'no review text in the report');
  for (const id of ['s12', 's16', 's19']) assert.ok(!scoped.result.ok || !scoped.result.script.segments.some(s => s.id === id), `${id} removed`);
  // Two more named turns would remove 8 of 26 (31%): the limits reject it.
  const over = run(review('reject', [{ code: 'unsupported_claims', segments: ['s12', 's16', 's19', 's21', 's23', 's24'] }]));
  assert.ok(!over.result.ok && over.result.problems.includes('segments_removed_share'));
  // Severe reasons stand, whatever turns they name.
  const severe = run(review('reject', [{ code: 'misrepresents_main_result', segments: ['s10'] }, { code: 'wrong_numbers', segments: ['s16'] }]));
  assert.ok(!severe.result.ok);
  assert.deepEqual(severe.result.report.rules, ['review_rejected', 'review_reason_severe']);
  assert.deepEqual(severe.result.report.reasons, [{ code: 'misrepresents_main_result', segments: ['s10'] }, { code: 'wrong_numbers', segments: ['s16'] }]);
});

test('speech size: the five-minute prompt fits its single 8,192-byte call; styles shorten before refusal; refusal only when impossible', () => {
  // 28 segments of full-length styles leave 4,900 spoken characters (40 segments would leave only 3,900).
  assert.equal(spokenCharacterBudget({ maxInputTokens: 8_192, maxCalls: 1 }, 28), 4_900);
  assert.equal(spokenCharacterBudget({ maxInputTokens: 8_192, maxCalls: 1 }, 40), 3_900);
  assert.deepEqual(FIVE_MINUTE_SHAPE.segments, [16, 28]);
  assert.match(SCRIPT_INSTRUCTIONS, /650 to 800 spoken words in total and never more than 4,900 characters of spoken text across all segments/);
  assert.match(SCRIPT_INSTRUCTIONS, /16 to 28 segments/);
  // Longer profiles keep their checker bound: their chunked speech holds more than it.
  assert.match(scriptInstructions({ duration: 'about ten minutes', words: [1350, 1650], chapters: [6, 8], segments: [30, 80] }, 12_500, { maxInputTokens: 8_192, maxCalls: 3 }), /never more than 12,500 characters/);
  // The quoting rules reach both passes.
  for (const text of [SCRIPT_INSTRUCTIONS, JSON.stringify(reviewRequest('paper', null, draft('2610.10536v1-draft.json'), 4_000).messages)]) {
    assert.match(text, /Never use an ellipsis, never join two passages/);
    assert.match(text, /Every number spoken in a segment must appear in that segment's own evidence quotes/);
    assert.match(text, /Model, dataset and benchmark names may be written exactly as the paper writes them/);
  }
  const limits = { maxInputTokens: 8_192, maxCalls: 1, perCallOutputTokens: 16_384, maxAudioTokens: 16_384 };
  // The simulated drafts fit with room to spare.
  const checked = checkScript(draft('2610.09384v1-draft.json'), PERSONA, { index: INDEX.A });
  assert.ok(checked.ok);
  if (checked.ok) {
    const fit = fitSpeech(checked.script.segments, limits);
    assert.ok(fit.plan && fit.plan.length === 1 && fit.stylesShortened === 0 && fit.bytes <= 8_192);
    assert.equal(fit.bytes, speechRequest({ segments: fit.segments }, { explainer: 'a', skeptic: 'b' }, 1).bytes, 'the same bound speechRequest computes');
  }
  // A 40-segment draft at the top of v2's range: over the bound as written, inside it once delivery directions are short.
  const turn = (i: number) => ({ chapter: `c${1 + Math.floor(i / 10)}`, speaker: (i % 2 ? 'skeptic' : 'explainer') as 'explainer' | 'skeptic',
    style: 'curious, measured, gently skeptical and warm', text: 'A plain spoken sentence about the result and what it means for the reader, '.repeat(2).slice(0, 112) });
  const forty = Array.from({ length: 40 }, (_, i) => turn(i));
  assert.equal(planSpeechChunks(forty, limits), null, 'v2 would have failed script_too_long_for_speech here');
  const fit = fitSpeech(forty, limits);
  assert.ok(fit.plan && fit.stylesShortened === 40 && fit.segments.every(s => s.style.length <= 24) && fit.bytes <= 8_192);
  assert.deepEqual(fit.segments.map(s => s.text), forty.map(s => s.text), 'never a spoken word');
  assert.equal(shortStyle('curious, measured, gently skeptical and warm', 24), 'curious, measured');
  // Truly impossible: even the shortest directions leave the spoken text over the bound.
  const long = Array.from({ length: 40 }, (_, i) => ({ ...turn(i), text: 'x'.repeat(200) }));
  const refused = fitSpeech(long, limits);
  assert.equal(refused.plan, null); assert.ok(refused.bytes > refused.budget);
  assert.ok(PART_OVERHEAD_BYTES > 50 && PART_OVERHEAD_BYTES < 80);
});
