// Paper podcasts: script/evidence checker, speech adapter, audio validation, the
// bounded worker job against a fake database, Edge API and single-use delivery.
// No network, no provider or Storage calls: every transport is a local fake.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { writeFileSync } from 'node:fs';
import { applyCorrections, checkScript, stripSpokenMarkup, SCRIPT_INSTRUCTIONS, correctionLimit, draftRequest, FIVE_MINUTE_BOUNDS, fitsInput, fixtureScript, parseReview, parseScript, rejectPolicy, requestBytes, REVIEW_SCHEMA,
  reviewRequest, scriptCost, scriptDocument, type CheckReport, type ReviewCorrections, type Script, type ScriptCallResult, type ScriptParams,
  type ScriptProvider } from '../../supabase/functions/_shared/podcast-script.ts';
import { alignSegments, fixtureAudio, impersonatedTokenSource, joinChunks, parseWav, planSpeechChunks, speechCost, speechRequest, verifyAudio,
  vertexSpeechProvider, wavBytes, type SpeechProvider, type SpeechRequest } from '../../supabase/functions/_shared/podcast-speech.ts';
import { podcastAudioBounds, podcastCheckerBounds, runPodcast, type PodcastDeps } from '../../supabase/functions/_shared/podcast-worker.ts';
import { handlePodcast, podcastError, type PodcastAPIDeps } from '../../supabase/functions/_shared/podcast-api.ts';
import { deliverPodcastMember } from '../../supabase/functions/_shared/podcast-delivery.ts';
import { ffmetadata, ffmpegArguments, ffmpegEncoder, verifyProbe } from '../../services/pipeline-worker/podcast-encode.ts';
import { createHandler } from '../../services/pipeline-worker/server.ts';

const sha = (bytes: Uint8Array | string) => createHash('sha256').update(bytes).digest('hex');
const PRIVATE = 'PRIVATE-PAPER-SENTENCE-NEVER-LOGGED';

const PAPER = `# Sparse Mixture Routing
## Abstract
We propose sparse routing for mixture-of-experts language models. ${PRIVATE} appears only in the paper body.
## 1 Introduction
Dense models scale poorly with expert count because every token visits every expert.
## 3 Method
Each token is routed to the top 2 of 64 experts by a learned gate, as in $g(x)=\\operatorname{softmax}(W x)$.
The load-balancing loss keeps expert utilization within 5% of uniform.
## 4 Results
Sparse routing reaches 41.2 perplexity on the benchmark versus 43.9 for the dense baseline.
Training throughput improves by 1.8x at equal compute.
## 5 Limitations
We only evaluate English text and models up to 1.3B parameters, so the results may not transfer to larger scales.
`;

function goodScript(): Script {
  const seg = (id: string, chapter: string, speaker: 'explainer' | 'skeptic', text: string, claim: Script['segments'][number]['claim_type'],
    quotes: string[] = [], math: { latex: string; spoken: string }[] = []) =>
    ({ id, chapter, speaker, text, style: 'curious, measured', claim_type: claim, evidence: quotes.map(q => ({ quote: q, section: '' })), math });
  const filler = ' The hosts talk this through carefully and slowly so the listener can follow every step of the argument.';
  return {
    title: 'Sparse routing for experts', limitations: ['Only English text and models up to 1.3B parameters were evaluated.'],
    chapters: [{ id: 'c1', title: 'The question' }, { id: 'c2', title: 'The method' }, { id: 'c3', title: 'The evidence' }, { id: 'c4', title: 'Caveats' }],
    segments: [
      seg('s1', 'c1', 'explainer', 'Today we look at a paper about routing tokens to experts.' + filler, 'context'),
      seg('s2', 'c1', 'skeptic', 'Why does routing matter at all?' + filler, 'context'),
      seg('s3', 'c1', 'explainer', 'The authors argue dense models scale poorly with more experts.' + filler, 'author_interpretation',
        ['Dense models scale poorly with expert count because every token visits every expert.']),
      seg('s4', 'c2', 'explainer', 'Each token goes to the top 2 of 64 experts, chosen by a learned gate.' + filler, 'paper_result',
        ['Each token is routed to the top 2 of 64 experts by a learned gate'], [{ latex: 'g(x)=\\operatorname{softmax}(W x)', spoken: 'a softmax gate' }]),
      seg('s5', 'c2', 'skeptic', 'And balance? They say utilization stays within 5% of uniform.' + filler, 'paper_result',
        ['The load-balancing loss keeps expert utilization within 5% of uniform.']),
      seg('s6', 'c3', 'explainer', 'Perplexity is 41.2 against 43.9 for the dense baseline.' + filler, 'paper_result',
        ['Sparse routing reaches 41.2 perplexity on the benchmark versus 43.9 for the dense baseline.']),
      seg('s7', 'c3', 'skeptic', 'Throughput improves by 1.8x at equal compute, which is the practical win.' + filler, 'paper_result',
        ['Training throughput improves by 1.8x at equal compute.']),
      seg('s8', 'c4', 'skeptic', 'But they only test English and models up to 1.3B parameters.' + filler + filler, 'paper_result',
        ['We only evaluate English text and models up to 1.3B parameters']),
      seg('s9', 'c4', 'explainer', 'So treat the larger-scale story as open.' + filler + filler + filler, 'context'),
    ].concat(Array.from({ length: 6 }, (_, i) => seg(`s${10 + i}`, 'c4', i % 2 ? 'skeptic' : 'explainer',
      'That caveat is worth repeating for anyone planning to build on this work.' + filler + filler, 'context'))),
    review: { verdict: 'accept', issues: [] },
  };
}

/** An empty correction set: the review approves the draft as written. */
const ACCEPT: ReviewCorrections = { delete: [], replace: [], claims: [], verdict: 'accept', reasons: [] };

test('script requests: no tools, no fallback, no thinking, profile output caps and a provable input bound', () => {
  const draft = draftRequest(PAPER, 'Sparse Mixture Routing', 6000);
  assert.equal(draft.model, 'claude-sonnet-5-5');
  assert.equal(draft.max_tokens, 6000);
  assert.deepEqual(draft.thinking, { type: 'between_tools' });
  assert.equal((draft as { tools?: unknown }).tools, undefined);
  assert.equal((draft as { fallbacks?: unknown }).fallbacks, undefined);
  assert.equal((draft as { betas?: unknown }).betas, undefined);
  const review = reviewRequest(PAPER, null, goodScript(), 4000);
  assert.equal(review.max_tokens, 4000);
  assert.match(JSON.stringify(review.messages), /<draft>/);
  assert.ok(requestBytes(draft) < 80_000 && fitsInput(requestBytes(draft), null, 80_000));
  assert.equal(fitsInput(90_000, null, 80_000), false, 'over the byte bound without a count');
  assert.equal(fitsInput(300_000, 70_000, 80_000), true, 'free count with margin admits');
  assert.equal(fitsInput(300_000, 76_000, 80_000), false, 'margin refuses near the cap');
  const cost = scriptCost({ state: 'succeeded', requestID: 'r', model: 'claude-sonnet-5-5', stopReason: 'end_turn', text: '', failure: null,
    usage: { input: 20_000, output: 3_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 } });
  assert.equal(cost.microusd, 70_000);
  assert.deepEqual(cost.units, { input_tokens: 20_000, cache_write_5m_tokens: 0, cache_write_1h_tokens: 0, cache_read_tokens: 0, output_tokens: 3_000 });
});

test('checker v3 accepts verbatim evidence, removes each unsupported claim on its own (never relabels it) and refuses rejected reviews', () => {
  const ok = checkScript(goodScript(), PAPER);
  assert.equal(ok.ok, true, ok.ok ? '' : ok.problems.join(','));
  if (ok.ok) {
    assert.equal(ok.report.outcome, 'accepted');
    assert.ok(PAPER.slice(ok.script.segments[5].evidence[0].offset).startsWith('Sparse routing reaches 41.2'), 'offset into the pinned text');
    assert.equal(scriptDocument(ok.script), scriptDocument((checkScript(goodScript(), PAPER) as { script: never }).script), 'deterministic');
  }
  // Each broken turn is removed; the rest of the script stands and is reported as degraded.
  const cases: [string, (s: Script) => void, string][] = [
    ['s6', s => { s.segments[5].evidence[0].quote = 'Sparse routing gets 41.2 perplexity versus 43.9.'; }, 'evidence_missing'],
    ['s7', s => { s.segments[6].text = 'Throughput improves by 2.5x at equal compute.'; }, 'number_not_in_evidence'],
    ['s2', s => { s.segments[1].text = 'It is 99 percent better.'; }, 'unsupported_number'],
    // Emphasis, a label and a dollar wrapper are stripped since 2026-10-14; angle brackets are markup a voice cannot read.
    ['s1', s => { s.segments[0].text = 'Speaker 1: <b>hello</b> $x$'; }, 'markup'],
    // No heading marks or cross-block quotes: the quote is dropped and its claim goes with it.
    ['s6', s => { s.segments[5].evidence[0].quote = '## 4 Results Sparse routing reaches 41.2 perplexity'; }, 'evidence_missing'],
    ['s6', s => { s.segments[5].evidence[0].quote = 'at equal compute. We only evaluate English text'; }, 'evidence_missing'],
    ['s6', s => { s.segments[5].evidence = []; }, 'evidence_missing'],
  ];
  for (const [id, mutate, reason] of cases) {
    const script = goodScript(); mutate(script);
    const result = checkScript(script, PAPER);
    assert.ok(result.ok, `${id} ${reason}: ${result.ok ? '' : result.problems.join(',')}`);
    if (!result.ok) continue;
    assert.equal(result.report.outcome, 'degraded');
    assert.deepEqual(result.report.removals, [{ segment: id, reason }]);
    assert.deepEqual(result.script.segments.map(s => s.id), script.segments.map(s => s.id).filter(s => s !== id));
    for (const kept of result.script.segments) assert.equal(kept.claim_type, script.segments.find(s => s.id === kept.id)!.claim_type);
  }
  const rejected = goodScript(); rejected.review = { verdict: 'reject', issues: [] };
  assert.ok((checkScript(rejected, PAPER) as { problems: string[] }).problems.includes('review_rejected'));
  const wrapped = goodScript(); wrapped.segments[5].evidence[0].quote = 'reaches 41.2 perplexity on the benchmark versus 43.9 for the dense baseline. Training throughput improves by 1.8x';
  const joined = checkScript(wrapped, PAPER);
  assert.ok(joined.ok && joined.report.outcome === 'accepted', 'consecutive lines of one paragraph read as one passage');
  assert.equal(parseScript('{"title":"x"}'), null);
  assert.equal(parseScript(JSON.stringify(goodScript()))?.segments.length, 15);
  assert.equal(parseScript(JSON.stringify(goodScript()))?.review, undefined, 'a draft never carries a verdict');
});

test('review correction set: strict schema, a limit derived from the unchanged output cap, applied deterministically', () => {
  // Structured outputs: every object closed and fully required, no size keywords (the API does not accept them).
  const walk = (node: unknown): void => {
    if (!node || typeof node !== 'object') return;
    const o = node as Record<string, unknown>;
    for (const key of ['maxLength', 'minLength', 'maxItems', 'minItems', 'minimum', 'maximum']) assert.ok(!(key in o), `no ${key}`);
    if (o.type === 'object') {
      assert.equal(o.additionalProperties, false);
      assert.deepEqual([...(o.required as string[])].sort(), Object.keys(o.properties as object).sort());
    }
    for (const value of Object.values(o)) walk(value);
  };
  walk(REVIEW_SCHEMA);
  assert.deepEqual(Object.keys(REVIEW_SCHEMA.properties), ['delete', 'replace', 'claims', 'verdict', 'reasons'], 'the verdict comes after the corrections, its reasons last');
  assert.ok(!('segments' in REVIEW_SCHEMA.properties) && !('title' in REVIEW_SCHEMA.properties), 'the review never re-emits the script');
  // Short, 5, 10 and 20 minutes keep their review caps (2,600 / 4,000 / 10,000 / 19,000 output tokens).
  assert.deepEqual([2_600, 4_000, 10_000, 19_000].map(correctionLimit), [6, 10, 25, 47]);
  const request = reviewRequest(PAPER, null, goodScript(), 4_000);
  assert.equal(request.max_tokens, 4_000);
  assert.match(JSON.stringify(request.messages), /at most 10 corrections in total/);
  assert.match(JSON.stringify(request.messages), /Do not rewrite or repeat the script/);
  assert.match(JSON.stringify(request.messages), /count the resulting spoken words/);
  assert.match(JSON.stringify(request.messages), /replacement should normally be at least two complete sentences/);

  const draft = goodScript(); delete draft.review;
  // Empty lists approve the draft as written.
  const same = applyCorrections(draft, ACCEPT, 10);
  assert.ok(same.ok);
  if (same.ok) {
    assert.deepEqual(same.script.segments, draft.segments);
    assert.deepEqual(same.script.review, { verdict: 'accept', issues: [], reasons: [] });
    assert.equal(checkScript(same.script, PAPER).ok, true);
  }
  // Delete, replace (text and formula notes) and claim corrections, keyed by segment id.
  const review = parseReview(JSON.stringify({
    delete: [{ segment: 's15', problem: 'repeats the caveat' }],
    replace: [{ segment: 's4', text: 'Each token goes to the top 2 of 64 experts, picked by a learned gate.', math: [], problem: 'formula note not needed' }],
    claims: [{ segment: 's3', claim_type: 'paper_result', evidence: [{ quote: 'Dense models scale poorly with expert count because every token visits every expert.', section: '1 Introduction' }],
      problem: 'a stated result, not an interpretation' }],
    verdict: 'accept', reasons: [] }))!;
  const applied = applyCorrections(draft, review, 10);
  assert.ok(applied.ok);
  if (applied.ok) {
    assert.equal(applied.corrections, 3);
    assert.deepEqual(applied.script.segments.map(s => s.id), draft.segments.map(s => s.id).filter(id => id !== 's15'));
    const s4 = applied.script.segments.find(s => s.id === 's4')!, s3 = applied.script.segments.find(s => s.id === 's3')!;
    assert.equal(s4.text, 'Each token goes to the top 2 of 64 experts, picked by a learned gate.');
    assert.deepEqual(s4.math, []); assert.deepEqual(s4.evidence, draft.segments[3].evidence, 'a rewrite keeps its evidence');
    assert.equal(s4.speaker, 'explainer'); assert.equal(s4.chapter, 'c2');
    assert.equal(s3.claim_type, 'paper_result'); assert.equal(s3.evidence[0].section, '1 Introduction'); assert.equal(s3.text, draft.segments[2].text);
    assert.deepEqual(applied.script.review!.issues.map(i => [i.segment, i.action]), [['s15', 'delete'], ['s4', 'replace'], ['s3', 'claims']]);
    assert.equal(checkScript(applied.script, PAPER).ok, true);
    assert.equal(draft.segments.length, 15, 'the draft itself is never mutated');
  }
  // Refusals: unknown or ambiguous ids, conflicts, over the limit, an emptied chapter. Never a silent pass.
  const problems = (r: ReturnType<typeof applyCorrections>) => r.ok ? [] : r.problems;
  assert.deepEqual(problems(applyCorrections(draft, { ...ACCEPT, delete: [{ segment: 's99', problem: '' }] }, 10)), ['correction_unknown_segment:s99']);
  assert.deepEqual(problems(applyCorrections(draft, { ...ACCEPT, delete: [{ segment: 'x<y>', problem: '' }] }, 10)), ['correction_unknown_segment:?'], 'model text never reaches logs');
  const twice = { ...draft, segments: [...draft.segments, { ...draft.segments[0] }] };
  assert.deepEqual(problems(applyCorrections(twice, { ...ACCEPT, delete: [{ segment: 's1', problem: '' }] }, 10)), ['correction_ambiguous_segment:s1']);
  assert.deepEqual(problems(applyCorrections(draft, { ...ACCEPT, delete: [{ segment: 's4', problem: '' }], replace: [review.replace[0]] }, 10)), ['correction_conflict:s4']);
  assert.deepEqual(problems(applyCorrections(draft, { ...ACCEPT, replace: [review.replace[0], review.replace[0]] }, 10)), ['correction_conflict:s4']);
  assert.equal(applyCorrections(draft, { ...ACCEPT, replace: [review.replace[0]], claims: [{ ...review.claims[0], segment: 's4' }] }, 10).ok, true, 'rewrite and re-annotate one segment');
  const many = { ...ACCEPT, delete: ['s10', 's11', 's12'].map(segment => ({ segment, problem: '' })) };
  assert.deepEqual(problems(applyCorrections(draft, many, 2)), ['correction_limit']);
  assert.deepEqual(problems(applyCorrections(draft, { ...ACCEPT, delete: ['s1', 's2', 's3'].map(segment => ({ segment, problem: '' })) }, 10)), ['correction_empty_chapter:c1']);
  // A rejection carries no corrections forward; the checker refuses it.
  const rejected = applyCorrections(draft, { ...ACCEPT, delete: [{ segment: 's99', problem: '' }], verdict: 'reject' }, 10);
  assert.ok(rejected.ok && rejected.script.segments.length === 15);
  if (rejected.ok) assert.ok((checkScript(rejected.script, PAPER) as { problems: string[] }).problems.includes('review_rejected'));
  // Wrong shapes are refused, never read as approval.
  assert.equal(parseReview('{"verdict":"accept"}'), null);
  assert.equal(parseReview(JSON.stringify({ ...ACCEPT, verdict: 'maybe' })), null);
  assert.equal(parseReview(JSON.stringify({ ...ACCEPT, claims: [{ segment: 's1', claim_type: 'opinion', evidence: [], problem: '' }] })), null);
  assert.equal(parseReview(JSON.stringify({ ...ACCEPT, replace: [{ segment: 's1', text: '', math: [], problem: '' }] })), null);
  assert.equal(parseReview(JSON.stringify(goodScript())), null, 'a whole script is not a correction set');
});

test('review reasons (checker v4): strict codes, repair before rejecting, segment-scoped rejects become removals within the limits', () => {
  // Schema: a strict enum of codes, each with its segment ids; the prompt asks for repair first and reasons with every reject.
  const reasons = REVIEW_SCHEMA.properties.reasons;
  assert.deepEqual(reasons.items.properties.code.enum, ['misrepresents_main_result', 'fabricated_detail', 'wrong_numbers', 'unsupported_claims',
    'speculation_presented_as_finding', 'too_many_problems', 'other']);
  assert.deepEqual(reasons.items.properties.segments, { type: 'array', items: { type: 'string' } });
  const task = JSON.stringify(reviewRequest(PAPER, null, goodScript(), 4_000).messages);
  assert.match(task, /Repair before you reject/);
  assert.match(task, /\\"reject\\" is only for a draft that misrepresents the paper's main result, contains fabricated content/);
  assert.match(task, /more problems than 10 corrections can fix/);
  assert.match(task, /With \\"reject\\", list at least one reason for every problem your corrections leave unfixed, naming each affected segment/);
  assert.doesNotMatch(task, /"reject" with empty lists/, 'no longer invited to reject without saying why');

  // Parsing: codes from the enum only, duplicates merged, a missing list or a non-id refused (never read as approval).
  const review = (verdict: 'accept' | 'reject', list: unknown[], extra: Partial<ReviewCorrections> = {}) => ({ ...ACCEPT, ...extra, verdict, reasons: list });
  const parsed = parseReview(JSON.stringify(review('reject', [{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'unsupported_claims', segments: ['s2'] },
    { code: 'wrong_numbers', segments: ['s7', 's6'] }])))!;
  assert.deepEqual(parsed.reasons, [{ code: 'wrong_numbers', segments: ['s6', 's7'] }, { code: 'unsupported_claims', segments: ['s2'] }]);
  assert.equal(parseReview(JSON.stringify({ ...ACCEPT, reasons: undefined })), null, 'reasons are required by the schema');
  assert.equal(parseReview(JSON.stringify(review('reject', [{ code: 'looks_wrong', segments: [] }]))), null, 'unknown code');
  assert.equal(parseReview(JSON.stringify(review('reject', [{ code: 'other', segments: [7] }]))), null, 'segment ids are strings');
  assert.equal(parseReview(JSON.stringify(review('reject', [{ code: 'other' }]))), null);
  assert.deepEqual(parseReview(JSON.stringify(review('accept', [{ code: 'wrong_numbers', segments: ['s6'] }])))!.reasons, [{ code: 'wrong_numbers', segments: ['s6'] }],
    'allowed with accept');

  // Policy: only segment-scoped reasons that each name draft segments convert a reject; anything else stands.
  const draft = goodScript(); delete draft.review;
  const policy = (list: ReviewCorrections['reasons'], script = draft) => rejectPolicy(list, script);
  assert.deepEqual(policy([{ code: 'unsupported_claims', segments: ['s2'] }, { code: 'wrong_numbers', segments: ['s6', 's2'] },
    { code: 'speculation_presented_as_finding', segments: ['s3'] }]), { remove: ['s2', 's6', 's3'] });
  assert.deepEqual(policy([]), { rule: 'review_reasons_missing' });
  for (const code of ['misrepresents_main_result', 'fabricated_detail', 'too_many_problems', 'other'] as const) {
    assert.deepEqual(policy([{ code: 'wrong_numbers', segments: ['s6'] }, { code, segments: ['s7'] }]), { rule: 'review_reason_severe' }, code);
  }
  assert.deepEqual(policy([{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'unsupported_claims', segments: [] }]), { rule: 'review_reason_unscoped' });
  assert.deepEqual(policy([{ code: 'wrong_numbers', segments: ['s99'] }]), { rule: 'review_reason_unknown_segment' });
  const twice = { ...draft, segments: [...draft.segments, { ...draft.segments[5] }] };
  assert.deepEqual(policy([{ code: 'wrong_numbers', segments: ['s6'] }], twice), { rule: 'review_reason_unknown_segment' }, 'ambiguous id');

  // A converted reject: its rewrite applies; the named turns and its own deletion are left to the checker, which counts them.
  const REWRITTEN = 'Each token goes to the top 2 of 64 experts, which keeps most of them idle. The hosts talk this through carefully so the listener can follow.';
  const converted = applyCorrections(draft, review('reject', [{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'unsupported_claims', segments: ['s9'] }], {
    delete: [{ segment: 's15', problem: 'repeats the caveat' }],
    replace: [{ segment: 's4', text: REWRITTEN, math: [], problem: 'plainer' },
      { segment: 's9', text: 'So the larger-scale story stays open.', math: [], problem: 'tighter' }] }) as ReviewCorrections, 10);
  assert.ok(converted.ok && converted.action === 'remove_segments' && converted.corrections === 3);
  if (!converted.ok) return;
  assert.equal(converted.script.segments.length, 15, 'nothing is deleted before the checker');
  assert.equal(converted.script.segments[3].text, REWRITTEN);
  assert.deepEqual(converted.script.review!.remove, [{ segment: 's15', reason: 'review_deleted' }, { segment: 's6', reason: 'review_flagged' },
    { segment: 's9', reason: 'review_flagged' }], 'a named turn is removed even when also rewritten');
  const checked = checkScript(converted.script, PAPER);
  assert.ok(checked.ok, checked.ok ? '' : checked.problems.join());
  assert.equal(checked.report.outcome, 'degraded');
  assert.deepEqual(checked.report.segments, { checked: 15, kept: 12, removed: 3 });
  assert.deepEqual(checked.report.removed, { review_flagged: 2, review_deleted: 1 });
  assert.deepEqual(checked.report.removals, [{ segment: 's6', reason: 'review_flagged' }, { segment: 's9', reason: 'review_flagged' },
    { segment: 's15', reason: 'review_deleted' }]);
  assert.deepEqual(checked.report.review, { verdict: 'reject', corrections: 3, action: 'remove_segments' });
  assert.deepEqual(checked.report.reasons, [{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'unsupported_claims', segments: ['s9'] }]);
  assert.deepEqual(checked.script.segments.map(s => s.id), draft.segments.map(s => s.id).filter(id => !['s6', 's9', 's15'].includes(id)));
  assert.equal(checked.script.segments[3].text, REWRITTEN);
  // Their own corrections are still validated; the correction limit does not bound the named turns.
  assert.deepEqual((applyCorrections(draft, review('reject', [{ code: 'wrong_numbers', segments: ['s6'] }],
    { delete: [{ segment: 's99', problem: '' }] }) as ReviewCorrections, 10) as { problems: string[] }).problems, ['correction_unknown_segment:s99']);
  assert.ok(applyCorrections(draft, review('reject', [{ code: 'unsupported_claims', segments: ['s2', 's9', 's10', 's11'] }]) as ReviewCorrections, 2).ok);

  // The v3 limits decide: more than 30% of the draft's turns removed in all, or a chapter losing its support, rejects.
  const limited = (list: ReviewCorrections['reasons'], extra: Partial<ReviewCorrections> = {}) => {
    const r = applyCorrections(draft, review('reject', list, extra) as ReviewCorrections, 10);
    assert.ok(r.ok && r.action === 'remove_segments');
    return checkScript((r as { script: Script }).script, PAPER, { bounds: { ...FIVE_MINUTE_BOUNDS, words: [200, 1000] } });
  };
  const share = limited([{ code: 'unsupported_claims', segments: ['s9', 's10', 's11', 's12'] }], { delete: [{ segment: 's13', problem: '' }] });
  assert.ok(!share.ok && share.problems.includes('segments_removed_share'), '5 of 15 turns (33%), counting the review\'s own deletion');
  assert.ok(limited([{ code: 'unsupported_claims', segments: ['s9', 's10', 's11', 's12'] }]).ok, '4 of 15 (27%) stays within the limit');
  const support = limited([{ code: 'unsupported_claims', segments: ['s3'] }]);
  assert.ok(!support.ok && support.problems.includes('chapter_unsupported:c1'), 'the opening chapter keeps its framing but loses its only evidenced claim');
  assert.deepEqual(support.report.reasons, [{ code: 'unsupported_claims', segments: ['s3'] }]);
  const emptied = limited([{ code: 'wrong_numbers', segments: ['s6', 's7'] }]);
  assert.ok(!emptied.ok && emptied.problems.includes('empty_chapter:c3'), 'the evidence chapter loses every turn');

  // A reject that stands records why, with its codes; the staging case (no reasons at all) still rejects.
  for (const [list, rule] of [[[], 'review_reasons_missing'], [[{ code: 'fabricated_detail', segments: ['s6'] }], 'review_reason_severe'],
    [[{ code: 'unsupported_claims', segments: [] }], 'review_reason_unscoped']] as [ReviewCorrections['reasons'], string][]) {
    const stands = applyCorrections(draft, review('reject', list, { delete: [{ segment: 's15', problem: '' }] }) as ReviewCorrections, 10);
    assert.ok(stands.ok && stands.action === 'reject' && stands.corrections === 0 && stands.script.segments.length === 15);
    const result = checkScript((stands as { script: Script }).script, PAPER);
    assert.ok(!result.ok);
    assert.deepEqual(result.report.rules.slice(0, 2), ['review_rejected', rule]);
    assert.deepEqual(result.report.review, { verdict: 'reject', corrections: 1, action: 'reject' });
    assert.deepEqual(result.report.reasons, list.length ? list : undefined);
  }
});

test('fixture script quotes real passages and is labeled synthetic', () => {
  const fixture = fixtureScript(PAPER, 'Sparse Mixture Routing');
  assert.match(fixture.title, /^Synthetic fixture: /);
  const checked = checkScript(fixture, PAPER, { fixture: true });
  assert.equal(checked.ok, true, checked.ok ? '' : checked.problems.join());
});

function tone(seconds: number, gaps: number[] = []): Uint8Array {
  const rate = 24_000, samples = new Int16Array(Math.round(seconds * rate));
  for (let i = 0; i < samples.length; i++) {
    const t = i / rate;
    const silent = gaps.some(g => t >= g && t < g + 0.4);
    samples[i] = silent ? 0 : Math.round(Math.sin(2 * Math.PI * 200 * t) * 5000);
  }
  return wavBytes(samples);
}

test('WAV validation, dead air, duration bounds and silence-snapped timing', () => {
  const wav = tone(10, [3, 7]);
  const pcm = parseWav(wav);
  assert.equal(pcm.durationMs, 10_000);
  assert.equal(verifyAudio(pcm, { minMs: 1_000, maxMs: 20_000 }), null);
  assert.equal(verifyAudio(pcm, { minMs: 20_000, maxMs: 30_000 }), 'audio_too_short');
  assert.equal(verifyAudio(parseWav(wavBytes(new Int16Array(24_000 * 3))), { minMs: 1_000, maxMs: 20_000 }), 'audio_silent');
  const timings = alignSegments(['a'.repeat(30), 'b'.repeat(40), 'c'.repeat(30)], pcm);
  assert.equal(timings[0].start_ms, 0);
  assert.ok(Math.abs(timings[1].start_ms - 3_200) <= 300, `snapped near the first gap: ${timings[1].start_ms}`);
  assert.ok(Math.abs(timings[2].start_ms - 7_200) <= 300, `snapped near the second gap: ${timings[2].start_ms}`);
  assert.equal(timings[2].end_ms, 10_000);
  const truncated = wav.slice(0, wav.byteLength - 10);
  assert.throws(() => parseWav(truncated), /audio_truncated/);
  const stereo = wavBytes(new Int16Array(100)); new DataView(stereo.buffer).setUint16(22, 2, true);
  assert.throws(() => parseWav(stereo), /audio_format_invalid/);
  const fx = parseWav(fixtureAudio((checkScript(fixtureScript(PAPER, 'x'), PAPER, { fixture: true }) as { script: never }).script));
  assert.ok(fx.durationMs > 5_000 && verifyAudio(fx, { minMs: 1_000, maxMs: 660_000 }) === null);
});

test('speech request: two fixed voices in speechConfig, speaker/style as metadata, never inline labels', () => {
  const checked = checkScript(goodScript(), PAPER);
  assert.ok(checked.ok);
  const request = speechRequest(checked.script, { explainer: 'Sadaltager', skeptic: 'Erinome' }, 16_384);
  const body = request.body as { contents: { parts: { text: string; speechMetadata: { speaker: string } }[] }[]; generationConfig: Record<string, unknown> };
  assert.deepEqual(body.generationConfig.responseModalities, ['AUDIO']);
  assert.equal(body.generationConfig.maxOutputTokens, undefined, 'Vertex TTS refuses maxOutputTokens; the grant is kept beside the request');
  assert.equal(request.audioTokens, 16_384);
  assert.deepEqual((body.generationConfig.speechConfig as { multiSpeakerVoiceConfig: { speakerVoiceConfigs: unknown[] } }).multiSpeakerVoiceConfig.speakerVoiceConfigs,
    [{ speaker: 'Explainer', voiceConfig: { voice: 'Sadaltager' } }, { speaker: 'Skeptic', voiceConfig: { voice: 'Erinome' } }]);
  assert.ok(body.contents[0].parts.every(p => !/^(Explainer|Skeptic|Speaker)/.test(p.text) && ['Explainer', 'Skeptic'].includes(p.speechMetadata.speaker)));
  assert.ok(request.bytes < 8_192);
  assert.equal(speechCost({ text_input_tokens: 8_192, audio_output_tokens: 16_384 }, { text_input: 1, audio_output: 18 }), 303_104);
});

const speechResponse = (audio: Uint8Array, usage: unknown = { promptTokenCount: 1500, candidatesTokensDetails: [{ modality: 'AUDIO', tokenCount: 3750 }] }) =>
  new Response(JSON.stringify({ responseId: 'resp-1', modelVersion: 'gemini-3.8-flash-tts',
    candidates: [{ finishReason: 'STOP', content: { parts: [{ inlineData: { mimeType: 'audio/wav', data: Buffer.from(audio).toString('base64') } }] } }],
    ...(usage ? { usageMetadata: usage } : {}) }), { status: 200, headers: { 'content-type': 'application/json' } });

test('Vertex speech adapter: one POST, usage recorded, rejections free, ambiguous outcomes held', async () => {
  const checked = checkScript(goodScript(), PAPER);
  assert.ok(checked.ok);
  const request = speechRequest(checked.script, { explainer: 'Sadaltager', skeptic: 'Erinome' }, 16_384);
  const calls: { url: string; init?: RequestInit }[] = [];
  const make = (respond: () => Response | Promise<Response>) => vertexSpeechProvider({ project: 'gradstep', tokens: async () => 'token-fixture-value',
    fetch: (async (url: string | URL | Request, init?: RequestInit) => { calls.push({ url: String(url), init }); return respond(); }) as typeof fetch });
  const ok = await make(() => speechResponse(tone(2)) ).generate(request, new AbortController().signal);
  assert.equal(ok.state, 'succeeded');
  assert.deepEqual(ok.usage, { text_input_tokens: 1500, audio_output_tokens: 3750 });
  assert.equal(ok.finishReason, 'STOP');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://aiplatform.googleapis.com/v1/projects/gradstep/locations/global/publishers/google/models/gemini-3.8-flash-tts:generateContent');
  assert.equal((calls[0].init?.headers as Record<string, string>).Authorization, 'Bearer token-fixture-value');
  assert.equal((await make(() => new Response('{}', { status: 400 })).generate(request, new AbortController().signal)).state, 'rejected');
  assert.equal((await make(() => new Response('{}', { status: 429 })).generate(request, new AbortController().signal)).state, 'rejected');
  assert.equal((await make(() => new Response('{}', { status: 503 })).generate(request, new AbortController().signal)).state, 'unknown');
  assert.equal((await make(() => { throw new Error('reset'); }).generate(request, new AbortController().signal)).state, 'unknown');
  const noUsage = await make(() => speechResponse(tone(2), null)).generate(request, new AbortController().signal);
  assert.equal(noUsage.state, 'unknown', 'paid response without usage keeps the liability');
  assert.equal(noUsage.failure, 'usage_missing');
  const noToken = await vertexSpeechProvider({ project: 'gradstep', tokens: async () => { throw new Error('no'); },
    fetch: (async () => { throw new Error('must not send'); }) as typeof fetch }).generate(request, new AbortController().signal);
  assert.equal(noToken.state, 'rejected', 'no token means no POST and no charge');
});

test('speech identity: worker identity mints a short-lived token for the dedicated account; no key material', async () => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const tokens = impersonatedTokenSource('gradstep-podcast-speech@gradstep.iam.gserviceaccount.com', (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init });
    if (String(url).startsWith('http://metadata.google.internal')) return Response.json({ access_token: 'worker-identity-token-value' });
    return Response.json({ accessToken: 'speech-token-value-1234567890', expireTime: new Date(Date.now() + 300_000).toISOString() });
  }) as typeof fetch);
  assert.equal(await tokens(new AbortController().signal), 'speech-token-value-1234567890');
  assert.equal(await tokens(new AbortController().signal), 'speech-token-value-1234567890');
  assert.equal(calls.length, 2, 'cached until near expiry');
  assert.equal((calls[0].init?.headers as Record<string, string>)['Metadata-Flavor'], 'Google');
  assert.match(calls[1].url, /iamcredentials\.googleapis\.com\/v1\/projects\/-\/serviceAccounts\/gradstep-podcast-speech%40gradstep\.iam\.gserviceaccount\.com:generateAccessToken$/);
  assert.deepEqual(JSON.parse(String(calls[1].init?.body)), { scope: ['https://www.googleapis.com/auth/cloud-platform'], lifetime: '300s' });
  assert.throws(() => impersonatedTokenSource('not an account'), /speech_account_invalid/);
});

// ---------------------------------------------------------------------------
// Worker job against a fake database
// ---------------------------------------------------------------------------
const SPEC = { id: 'podcast-5min-v1', version: 1, target_seconds: 300, min_seconds: 120, max_seconds: 660, max_source_bytes: 400000,
  script: { model: 'claude-sonnet-5-5', calls: [{ route: 'podcast_script', max_input_tokens: 80000, max_output_tokens: 6000 },
    { route: 'podcast_review', max_input_tokens: 80000, max_output_tokens: 4000 }] },
  speech: { model: 'gemini-3.8-flash-tts', max_input_tokens: 8192, max_output_tokens: 16384, voices: { explainer: 'Sadaltager', skeptic: 'Erinome' },
    rates_microusd_per_token: { text_input: 1, audio_output: 18 } },
  storage: { audio_bytes: 16777216, transcript_bytes: 4194304, manifest_bytes: 262144 } };
const PAPER_BYTES = new TextEncoder().encode(PAPER);
const OWNER = '46000000-0000-4000-8000-00000000000a';

test('v2 podcast lengths enforce their advertised word and audio windows; v1 remains compatible', () => {
  const v2 = {
    version: 2, target_seconds: 300, min_seconds: 120, max_seconds: 660,
    shape: { duration: 'about five minutes', words: [650, 800] as [number, number], chapters: [4, 6] as [number, number], segments: [16, 28] as [number, number] },
    checker: { words: [450, 1000] as [number, number], chapters: [3, 8] as [number, number], segments: [8, 80] as [number, number], max_spoken_characters: 6000, min_evidenced: 5 },
  };
  // Version 2 and later: the writer's range with the tolerance band (80% of the floor, 125% of the ceiling).
  assert.deepEqual(podcastCheckerBounds(v2), { ...v2.checker, words: [520, 1000] });
  assert.deepEqual(podcastAudioBounds(v2, false), { minMs: 240_000, maxMs: 375_000 });
  assert.deepEqual(podcastAudioBounds({ ...v2, version: 1 }, false), { minMs: 120_000, maxMs: 660_000 });
  assert.deepEqual(podcastAudioBounds(v2, true), { minMs: 1_000, maxMs: 660_000 });
});

function harness(options: { origin?: 'generated' | 'fixture'; scope?: 'shared' | 'private'; script?: Partial<ScriptProvider>; speech?: SpeechProvider | null;
  failRpc?: (name: string, n: number) => Error | null; uploadFails?: 'lost_but_written' | 'missing'; scripts?: (Script | ReviewCorrections)[]; claimed?: boolean;
  spec?: Record<string, unknown>; resume?: Record<string, unknown> | null; speechRefused?: boolean } = {}) {
  const calls: { name: string; params: Record<string, unknown> }[] = [], logs: unknown[] = [], uploads = new Map<string, Uint8Array>();
  let n = 0, attempts = 0, claimed = false;
  // Model outputs in call order: the draft, then the review's correction set.
  const queue = [...(options.scripts ?? [(() => { const s = goodScript(); delete s.review; return s; })(), ACCEPT])];
  const generate = async (): Promise<ScriptCallResult> => ({ state: 'succeeded', requestID: `req_${++attempts}`, model: 'claude-sonnet-5-5', stopReason: 'end_turn',
    text: JSON.stringify(queue.shift()), failure: null, usage: { input: 20_000, output: 3_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 } });
  const deps: PodcastDeps = {
    rpc: async <T>(name: string, params: Record<string, unknown>) => {
      calls.push({ name, params }); n++;
      const injected = options.failRpc?.(name, n); if (injected) throw injected;
      switch (name) {
        case 'worker_podcast_recover': return { recovered: false } as T;
        case 'worker_podcast_claim':
          if (claimed || options.claimed === false) return { claimed: false } as T;
          claimed = true;
          return { claimed: true, job_id: '46000000-0000-4000-8000-000000000101', claim_id: String(params.p_claim_id), generation: 1,
            origin: options.origin ?? 'generated', funding_kind: 'platform_seed', scope: options.scope ?? 'shared', owner_id: options.scope === 'private' ? OWNER : null,
            episode_id: '46000000-0000-4000-8000-000000000201', spec: options.spec ?? SPEC, metadata: { title: 'Sparse Mixture Routing' },
            resume: options.resume ?? null,
            source: { document_id: '46000000-0000-4000-8000-000000000301', bucket: 'paper-assets', path: 'raw/x/standalone.mmd', sha256: sha(PAPER_BYTES),
              bytes: PAPER_BYTES.byteLength, normalization_version: 'mathpix-standalone-mmd-v1' } } as T;
        case 'worker_podcast_advance': return { state: params.p_state, canceled: false } as T;
        case 'worker_podcast_attempt_begin': return { granted: true, attempt_id: params.p_attempt_id, account_id: OWNER,
          operation_id: '46000000-0000-4000-8000-000000000401', ceiling_microusd: 1 } as T;
        case 'worker_podcast_speech_begin': {
          const chunks = params.p_chunks as { attempt_id: string; audio_tokens: number }[];
          if (options.speechRefused) return { granted: false, reason: 'operation_ceiling', ordinal: 1 } as T;
          return { granted: true, attempts: chunks.map((c, i) => ({ granted: true, attempt_id: c.attempt_id, account_id: OWNER, ordinal: i,
            operation_id: '46000000-0000-4000-8000-000000000401', ceiling_microusd: 8192 + c.audio_tokens * 18 })) } as T;
        }
        case 'worker_podcast_checkpoint': return { state: params.p_stage === 'draft' ? 'checking' : 'synthesizing', canceled: false } as T;
        case 'worker_podcast_yield': return { state: (options.resume as { stage?: string } | null | undefined)?.stage === 'review' ? 'checking' : 'queued', canceled: false } as T;
        case 'worker_provider_attempt_finish': return null as T;
        case 'worker_podcast_asset_plan': return { objects: (params.p_objects as { role: string; path: string }[]).map((o, i) => ({ role: o.role, id: `obj-${i}`, path: o.path, verified: false })) } as T;
        case 'worker_podcast_asset_write': {
          const planned = (calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[])[Number(String(params.p_object_id).slice(4))];
          return { write: true, verified: false, bucket: 'podcast-assets', path: planned.path } as T;
        }
        case 'worker_podcast_asset_written': return null as T;
        case 'worker_podcast_publish': return { state: 'ready', canceled: false, release: { release_id: 'rel', state: 'pending_review' } } as T;
        case 'worker_podcast_fail': return { state: 'failed' } as T;
        case 'worker_podcast_checked': return { recorded: true } as T;
      }
      throw new Error('unexpected_rpc');
    },
    storage: {
      download: async (bucket, path, maximum) => {
        if (bucket === 'paper-assets') { assert.ok(maximum >= PAPER_BYTES.byteLength); return PAPER_BYTES; }
        const stored = uploads.get(path); if (!stored) throw new Error('missing'); return stored;
      },
      upload: async (bucket, path, bytes) => {
        assert.equal(bucket, 'podcast-assets');
        if (options.uploadFails === 'lost_but_written') { uploads.set(path, bytes); throw new Error('lost'); }
        if (options.uploadFails === 'missing') throw new Error('storage_upload_failed');
        uploads.set(path, bytes);
      },
    },
    script: { countTokens: async () => null, generate, ...options.script },
    ...(options.scriptProviders ? { scriptProviders: options.scriptProviders } : {}),
    speech: options.speech === undefined ? { generate: async () => ({ state: 'succeeded', requestID: 'resp-1', model: 'gemini-3.8-flash-tts', finishReason: 'STOP',
      audio: tone(150, [20, 40, 60, 80, 100, 120]), mimeType: 'audio/wav', usage: { text_input_tokens: 1500, audio_output_tokens: 3750 }, failure: null }) } : options.speech,
    encoder: { encode: async (wav, chapters) => { const pcm = parseWav(wav); assert.ok(chapters.length >= 1);
      return { bytes: new Uint8Array([1, 2, 3, 4]), durationMs: pcm.durationMs, mediaType: 'audio/mp4', encoder: { codec: 'aac' } }; } },
    sha256Hex: async bytes => sha(bytes), uuid: () => crypto.randomUUID(), now: () => Date.now(),
    log: (event, fields) => logs.push({ event, ...fields }),
  };
  return { deps, calls, logs, uploads, names: () => calls.map(c => c.name) };
}

test('generated job: grants precede each paid call, usage recorded, exact inventory, review-pending publication, no content in logs', async () => {
  const h = harness();
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.deepEqual(result, { processed: 1, recovered: 0, state: 'ready', failure: null });
  const names = h.names();
  const begins = h.calls.filter(c => c.name === 'worker_podcast_attempt_begin').map(c => c.params.p_route);
  assert.deepEqual(begins, ['podcast_script', 'podcast_review']);
  // Five minutes is one speech call at the full per-call cap: the same 303,104 micro-USD grant as before chunking.
  const speech = h.calls.filter(c => c.name === 'worker_podcast_speech_begin');
  assert.equal(speech.length, 1);
  assert.deepEqual((speech[0].params.p_chunks as { audio_tokens: number }[]).map(c => c.audio_tokens), [16384]);
  assert.ok(names.indexOf('worker_podcast_speech_begin') < names.indexOf('worker_provider_attempt_finish', names.indexOf('worker_podcast_speech_begin')));
  assert.ok(!names.includes('worker_podcast_checkpoint'), 'five minutes runs in one request');
  const finishes = h.calls.filter(c => c.name === 'worker_provider_attempt_finish');
  assert.deepEqual(finishes.map(f => [f.params.p_state, f.params.p_actual_microusd]), [['succeeded', 70000], ['succeeded', 70000], ['succeeded', 69000]]);
  assert.deepEqual(finishes[2].params.p_actual_units, { text_input_tokens: 1500, audio_output_tokens: 3750, audio_ms: 150000 });
  assert.deepEqual(h.calls.filter(c => c.name === 'worker_podcast_advance').map(c => c.params.p_state), ['checking', 'synthesizing', 'verifying', 'publishing']);
  const plan = h.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { role: string; path: string; bytes: number; sha256: string }[];
  assert.deepEqual(plan.map(o => o.role), ['audio', 'transcript', 'manifest']);
  assert.ok(plan.every(o => /^shared\/[0-9a-f]{64}\/(audio\.m4a|transcript\.json|manifest\.json)$/.test(o.path)));
  for (const object of plan) assert.equal(sha(h.uploads.get(object.path)!), object.sha256);
  const transcript = JSON.parse(new TextDecoder().decode(h.uploads.get(plan[1].path)!));
  assert.equal(transcript.timing, 'approximate');
  assert.equal(transcript.segments.length, 15);
  assert.ok(transcript.segments.every((s: { start_ms: number; end_ms: number }) => s.end_ms >= s.start_ms));
  assert.equal(transcript.chapters[0].start_ms, 0);
  const manifest = JSON.parse(new TextDecoder().decode(h.uploads.get(plan[2].path)!));
  assert.equal(manifest.identity.speech_model, 'gemini-3.8-flash-tts');
  assert.deepEqual(manifest.identity.voices, { explainer: 'Sadaltager', skeptic: 'Erinome' });
  const publish = h.calls.find(c => c.name === 'worker_podcast_publish')!.params.p_release as Record<string, unknown>;
  assert.equal(publish.manifest_sha256, plan[2].sha256);
  assert.equal(publish.segments, 15);
  assert.ok(!JSON.stringify([h.logs, h.calls.filter(c => c.name !== 'worker_podcast_asset_plan')]).includes(PRIVATE), 'no paper text in logs or RPCs');
  assert.ok(!JSON.stringify(h.logs).includes('41.2'), 'no script text in logs');
});

test('private job writes under the owner prefix', async () => {
  const h = harness({ scope: 'private' });
  await runPodcast(h.deps, Date.now() + 600_000);
  const plan = h.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  assert.ok(plan.every(o => o.path.startsWith(`private/${OWNER}/`)));
});

test('fixture job: zero spend, labeled, no provider grants', async () => {
  const h = harness({ origin: 'fixture', script: { generate: async () => { throw new Error('must not call'); } }, speech: null });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.state, 'ready');
  assert.ok(!h.names().includes('worker_podcast_attempt_begin'));
  const plan = h.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  const transcript = JSON.parse(new TextDecoder().decode(h.uploads.get(plan[1].path)!));
  assert.equal(transcript.origin, 'fixture');
  assert.match(transcript.disclosure, /^Synthetic fixture/);
});

test('oversized source is refused before any grant; never truncated', async () => {
  const counted: number[] = [];
  const big = harness({ script: { countTokens: async () => { counted.push(1); return 79_000; } } });
  // A source over the byte bound with a too-large count: no grant, no paid call.
  const original = big.deps.storage.download;
  const padded = new TextEncoder().encode(PAPER + 'x'.repeat(90_000));
  big.deps.storage.download = async (bucket, path, maximum) => bucket === 'paper-assets' ? padded : original(bucket, path, maximum);
  big.deps.rpc = (inner => async <T>(name: string, params: Record<string, unknown>) => {
    const value = await inner<T>(name, params);
    if (name === 'worker_podcast_claim' && (value as { claimed?: boolean }).claimed) {
      const claim = value as unknown as { source: { sha256: string; bytes: number } };
      claim.source.sha256 = sha(padded); claim.source.bytes = padded.byteLength;
    }
    return value;
  })(big.deps.rpc);
  const result = await runPodcast(big.deps, Date.now() + 600_000);
  assert.equal(result.failure, 'source_too_large');
  assert.equal(counted.length, 1, 'free count only when the byte bound is exceeded');
  assert.ok(!big.names().includes('worker_podcast_attempt_begin'));
  assert.deepEqual(big.calls.at(-1)?.params.p_failure, 'source_too_large');
  assert.equal(big.calls.at(-1)?.params.p_quality, false);
});

test('source digest mismatch stops before any paid call', async () => {
  const h = harness();
  h.deps.storage.download = async () => new TextEncoder().encode(PAPER.replace('41.2', '99.9'));
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.failure, 'source_integrity_failed');
  assert.ok(!h.names().includes('worker_podcast_attempt_begin'));
});

test('unknown script outcome keeps the liability and stops; no further grants or retries', async () => {
  const h = harness({ script: { generate: async () => ({ state: 'unknown', requestID: null, model: null, stopReason: null, text: null, usage: null, failure: 'transport_unknown' }) } });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.failure, 'script_outcome_unknown');
  assert.equal(h.calls.filter(c => c.name === 'worker_podcast_attempt_begin').length, 1);
  const finish = h.calls.find(c => c.name === 'worker_provider_attempt_finish')!.params;
  assert.equal(finish.p_state, 'unknown'); assert.equal(finish.p_actual_microusd, null);
});

test('checker rejection is a quality failure (customer charged zero) after recorded usage, with its report recorded first', async () => {
  // The review "corrects" three claims to paraphrases: 3 of 6 quotes (50%) unverifiable is beyond repair.
  const paraphrase = 'paraphrased claim that is not in the paper text';
  const bad: ReviewCorrections = { ...ACCEPT, claims: ['s3', 's4', 's6'].map(segment => ({ segment, claim_type: 'paper_result' as const,
    evidence: [{ quote: paraphrase, section: 'Secret section' }], problem: 'tighter quote' })) };
  const h = harness({ scripts: [goodScript(), bad] });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.failure, 'script_evidence_rejected');
  const fail = h.calls.at(-1)!;
  assert.equal(fail.name, 'worker_podcast_fail'); assert.equal(fail.params.p_quality, true);
  assert.equal(h.calls.filter(c => c.name === 'worker_provider_attempt_finish').length, 2);
  assert.ok(!h.names().includes('worker_podcast_asset_plan'));
  // The report is recorded with the job immediately before the failure settles it: counts, codes and offsets only.
  const checked = h.calls.at(-2)!;
  assert.equal(checked.name, 'worker_podcast_checked');
  const report = checked.params.p_report as CheckReport;
  assert.equal(report.outcome, 'rejected'); assert.equal(report.checker, 'podcast-checker-v5');
  assert.ok(report.rules.includes('evidence_unverified_share'), report.rules.join());
  assert.deepEqual([report.evidence!.checked, report.evidence!.unverified], [6, 3]);
  assert.deepEqual(report.items!.map(i => [i.segment, i.reason]), [['s3', 'not_found'], ['s4', 'not_found'], ['s6', 'not_found']]);
  assert.deepEqual(report.removals!.map(r => r.segment), ['s3', 's4', 's6']);
  assert.ok(!JSON.stringify([report, h.logs]).includes(paraphrase) && !JSON.stringify(report).includes('Secret'), 'no model or paper text');
  assert.deepEqual(h.logs.find(l => (l as { event: string }).event === 'podcast_script_checked'), { event: 'podcast_script_checked',
    job_id: '46000000-0000-4000-8000-000000000101', outcome: 'rejected', kept: 12, removed: 3, evidence: 6, unverified: 3, first: report.rules[0] });
});

test('checker report: recorded before speech when accepted or degraded; a missing recorder never stops the job', async () => {
  const draft = goodScript(); delete draft.review;
  draft.segments[8].text = 'They compare against 7 baselines, which is a lot.'; // an unsupported number in an unevidenced turn: removed, not fatal
  const h = harness({ scripts: [draft, ACCEPT] });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.state, 'ready', result.failure ?? '');
  const names = h.names();
  assert.ok(names.indexOf('worker_podcast_checked') > names.lastIndexOf('worker_provider_attempt_finish', names.indexOf('worker_podcast_speech_begin') - 1)
    && names.indexOf('worker_podcast_checked') < names.indexOf('worker_podcast_speech_begin'), 'after the review, before speech is granted');
  const report = h.calls.find(c => c.name === 'worker_podcast_checked')!.params.p_report as CheckReport;
  assert.equal(report.outcome, 'degraded');
  assert.deepEqual(report.removals, [{ segment: 's9', reason: 'unsupported_number' }]);
  assert.deepEqual(report.speech, { bytes: report.speech!.bytes, budget: 8192, calls: 1, styles_shortened: 0 });
  assert.ok(report.speech!.bytes < 8192);
  const plan = h.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  const transcript = JSON.parse(new TextDecoder().decode(h.uploads.get(plan[1].path)!));
  assert.ok(!transcript.segments.some((s: { id: string }) => s.id === 's9'), 'the removed claim is not in the episode');
  // Before migration 050 is applied the recorder is missing: the job carries on and says so in its logs.
  const missing = harness({ failRpc: name => name === 'worker_podcast_checked' ? new Error('function_not_found') : null });
  assert.equal((await runPodcast(missing.deps, Date.now() + 600_000)).state, 'ready');
  assert.ok(missing.logs.some(l => (l as { event: string }).event === 'podcast_check_unrecorded'));
  // A fence error while recording means another worker owns the job: stop without writing.
  const stale = harness({ failRpc: name => name === 'worker_podcast_checked' ? new Error('stale_podcast_claim') : null });
  const stopped = await runPodcast(stale.deps, Date.now() + 600_000);
  assert.equal(stopped.failure, 'stale_podcast_claim');
  assert.ok(!stale.names().includes('worker_podcast_speech_begin') && !stale.names().includes('worker_podcast_fail'));
});

test('five-minute speech size: delivery directions shorten to fit; a script that cannot fit fails before any speech grant', async () => {
  const filler = 'The hosts slow down to walk through what this passage says and why it matters.';
  const long = (style: string, words: number) => {
    const draft = goodScript(); delete draft.review;
    draft.segments = [...draft.segments.slice(2, 8), ...Array.from({ length: 38 }, (_, i) => ({ id: `s${20 + i}`, chapter: 'c4',
      speaker: (i % 2 ? 'skeptic' : 'explainer') as 'explainer' | 'skeptic', style, text: `${filler} ${'Listen carefully here. '.repeat(words)}`.trim(),
      claim_type: 'context' as const, evidence: [], math: [] }))];
    draft.segments.unshift({ ...goodScript().segments[0], text: 'Today we look at sparse routing.' }, { ...goodScript().segments[1], text: 'Why does routing matter?' });
    return draft;
  };
  // 46 turns with long delivery directions: over 8,192 bytes as written, inside once the directions are short.
  const fits = harness({ scripts: [long('curious, measured, gently skeptical, warm', 0), ACCEPT] });
  assert.equal((await runPodcast(fits.deps, Date.now() + 600_000)).state, 'ready');
  const report = fits.calls.find(c => c.name === 'worker_podcast_checked')!.params.p_report as CheckReport;
  assert.ok(report.speech!.styles_shortened > 0 && report.speech!.bytes <= 8192, JSON.stringify(report.speech));
  const sent = fits.calls.find(c => c.name === 'worker_podcast_speech_begin')!;
  assert.equal((sent.params.p_chunks as unknown[]).length, 1);
  // Spoken text alone is over the bound: nothing can make it fit, so no speech is bought.
  const refused = harness({ scripts: [long('calm', 1), ACCEPT] });
  assert.equal((await runPodcast(refused.deps, Date.now() + 600_000)).failure, 'script_too_long_for_speech');
  assert.ok(!refused.names().includes('worker_podcast_speech_begin'));
  const recorded = refused.calls.find(c => c.name === 'worker_podcast_checked')!.params.p_report as CheckReport;
  assert.equal(recorded.stage, 'speech'); assert.equal(recorded.outcome, 'rejected'); assert.deepEqual(recorded.rules, ['speech_too_long']);
  assert.ok(recorded.speech!.bytes > recorded.speech!.budget && recorded.speech!.calls === 0);
  assert.equal(refused.calls.at(-1)!.params.p_quality, true, 'a quality failure: the customer is charged zero');
});

// The staging seed pilot (worker revision 00013): drafts of 4,785 and 4,497 output tokens (cap 6,000), then
// reviews stopped at exactly their 4,000-token cap, so both jobs failed `script_incomplete` while checking.
const QUOTED: [string, string][] = [['Dense models scale poorly with expert count because every token visits every expert.', '1 Introduction'],
  ['Each token is routed to the top 2 of 64 experts by a learned gate', '3 Method'], ['The load-balancing loss keeps expert utilization within 5% of uniform.', '3 Method'],
  ['Sparse routing reaches 41.2 perplexity on the benchmark versus 43.9 for the dense baseline.', '4 Results'], ['Training throughput improves by 1.8x at equal compute.', '4 Results'],
  ['We only evaluate English text and models up to 1.3B parameters, so the results may not transfer to larger scales.', '5 Limitations']];
/** A checker-valid five-minute draft (5 chapters, 30 segments, ~945 words) of ~4,800 output tokens, the pilot's size. */
function pilotDraft(): Script {
  const lines = ['The authors frame the problem around how routing decides which experts see each token in a large language model.',
    'So the question is whether the evidence in this passage really carries the weight the authors put on it here.'];
  const segments = Array.from({ length: 30 }, (_, i) => {
    const evidenced = i % 10 !== 9;
    return { id: `s${i + 1}`, chapter: `c${Math.floor(i / 6) + 1}`, speaker: (i % 2 ? 'skeptic' : 'explainer') as 'explainer' | 'skeptic',
      style: i % 2 ? 'skeptical, fair' : 'curious, measured',
      text: lines[i % 2] + ' Listen closely to how the two hosts unpack it before moving on.',
      claim_type: (evidenced ? (i % 2 ? 'author_interpretation' : 'paper_result') : 'context') as Script['segments'][number]['claim_type'],
      evidence: evidenced ? [0, 1, 2].map(k => ({ quote: QUOTED[(i + k) % QUOTED.length][0], section: QUOTED[(i + k) % QUOTED.length][1] })) : [],
      math: i === 7 ? [{ latex: 'g(x)=\\operatorname{softmax}(W x)', spoken: 'a softmax gate over the experts' }] : [] };
  });
  return { title: 'Sparse routing for mixture-of-experts models', limitations: ['Only English text and models up to 1.3B parameters were evaluated.'],
    chapters: ['The question', 'The method', 'The evidence', 'What it means', 'Caveats'].map((title, i) => ({ id: `c${i + 1}`, title })), segments };
}
/** Output tokens at ~4 characters each (the pilot draft: 19,195 characters, 4,799 tokens; staging measured 4,785 and 4,497). */
const outputTokens = (text: string) => Math.ceil(text.length / 4);
/** A fake Sonnet 5.5 that stops at max_tokens like the API and bills the pilot's measured input sizes. */
function pilotModel(review: (draft: Script) => unknown) {
  const calls: { max: number; output: number; stop: string }[] = [];
  const generate = async (params: ScriptParams): Promise<ScriptCallResult> => {
    const reviewing = JSON.stringify(params.messages).includes('<draft>');
    const full = JSON.stringify(reviewing ? review(pilotDraft()) : pilotDraft());
    const output = Math.min(outputTokens(full), params.max_tokens), stop = outputTokens(full) > params.max_tokens ? 'max_tokens' : 'end_turn';
    calls.push({ max: params.max_tokens, output, stop });
    return { state: 'succeeded', requestID: `req_${calls.length}`, model: 'claude-sonnet-5-5', stopReason: stop, text: full.slice(0, output * 4), failure: null,
      // Input: the paper (~29,575 tokens), then the paper plus the draft (~34,500), as billed on staging.
      usage: { input: reviewing ? 34_500 : 29_575, output, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 } };
  };
  return { calls, script: { countTokens: async () => null, generate } };
}

test('five-minute pilot: a ~4,800-token draft cannot be re-emitted under the 4,000-token review cap; a small correction set fits and publishes', async () => {
  const draftTokens = outputTokens(JSON.stringify(pilotDraft()));
  assert.ok(draftTokens >= 4_700 && draftTokens <= 4_900, `draft ${draftTokens} tokens`);
  assert.equal(checkScript({ ...pilotDraft(), review: { verdict: 'accept', issues: [] } }, PAPER).ok, true, 'the draft itself is valid');

  // Checker v1's review contract (the whole corrected script plus a verdict), reproduced with the fake: cut at the cap.
  const v1 = pilotModel(draft => ({ ...draft, review: { verdict: 'accept', issues: [] } }));
  const before = harness({ script: v1.script });
  assert.equal((await runPodcast(before.deps, Date.now() + 600_000)).failure, 'script_incomplete');
  assert.deepEqual(v1.calls, [{ max: 6_000, output: draftTokens, stop: 'end_turn' }, { max: 4_000, output: 4_000, stop: 'max_tokens' }]);
  assert.deepEqual(before.calls.filter(c => c.name === 'worker_provider_attempt_finish').map(c => c.params.p_actual_microusd),
    [29_575 * 2 + draftTokens * 10, 109_000], 'the staging attempts: ~$0.107 draft, $0.109 truncated review');
  assert.deepEqual(before.calls.filter(c => c.name === 'worker_podcast_advance').map(c => c.params.p_state), ['checking']);
  assert.equal(before.calls.at(-1)!.params.p_quality, true);

  // Since checker v2: the same draft, reviewed as a three-entry correction set.
  const corrections: ReviewCorrections = {
    delete: [{ segment: 's30', problem: 'repeats an earlier transition' }],
    replace: [{ segment: 's19', text: 'Each token goes to the top 2 of 64 experts, so most experts never see most tokens.', math: [],
      problem: 'states the routing rule plainly' }],
    claims: [{ segment: 's3', claim_type: 'author_interpretation', evidence: [{ quote: QUOTED[0][0], section: QUOTED[0][1] }],
      problem: 'interpretation, quoted from the introduction' }],
    verdict: 'accept', reasons: [{ code: 'wrong_numbers', segments: ['s19'] }] };
  const v2 = pilotModel(() => corrections);
  const after = harness({ script: v2.script });
  const outcome = await runPodcast(after.deps, Date.now() + 600_000);
  assert.equal(outcome.state, 'ready', outcome.failure ?? '');
  const reviewTokens = v2.calls[1].output;
  assert.ok(reviewTokens < 300, `correction set ${reviewTokens} tokens`);
  assert.deepEqual(v2.calls.map(c => [c.max, c.stop]), [[6_000, 'end_turn'], [4_000, 'end_turn']], 'same caps, nothing cut off');
  const [draftCost, reviewCost] = after.calls.filter(c => c.name === 'worker_provider_attempt_finish').map(c => c.params.p_actual_microusd as number);
  assert.equal(draftCost, 29_575 * 2 + draftTokens * 10);
  assert.equal(reviewCost, 34_500 * 2 + reviewTokens * 10);
  assert.ok(reviewCost < 72_000, 'the review costs ~$0.07 instead of $0.109');
  const plan = after.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  const transcript = JSON.parse(new TextDecoder().decode(after.uploads.get(plan[1].path)!));
  const ids = transcript.segments.map((s: { id: string }) => s.id);
  assert.equal(ids.length, 29); assert.ok(!ids.includes('s30'));
  const segment = (id: string) => transcript.segments.find((s: { id: string }) => s.id === id);
  assert.equal(segment('s19').text, corrections.replace[0].text);
  assert.equal(segment('s3').claim_type, 'author_interpretation'); assert.deepEqual(segment('s3').evidence.map((e: { quote: string }) => e.quote), [QUOTED[0][0]]);
  const manifest = JSON.parse(new TextDecoder().decode(after.uploads.get(plan[2].path)!));
  assert.equal(manifest.identity.checker, 'podcast-checker-v5');
  assert.equal(manifest.review_sha256, sha(JSON.stringify(corrections)), 'draft and correction set recorded as lineage');
  assert.equal((after.calls.find(c => c.name === 'worker_podcast_publish')!.params.p_release as { checker_version: string }).checker_version, 'podcast-checker-v5');
  assert.ok(!JSON.stringify(after.logs).includes('most experts never see'), 'no script text in logs');
});

test('corrections naming unknown segments or emptying a chapter fail as a quality rejection after both passes are recorded', async () => {
  for (const [bad, first] of [
    [{ ...ACCEPT, replace: [{ segment: 's99', text: 'A sentence for a segment that does not exist.', math: [], problem: '' }] }, 'correction_unknown_segment:s99'],
    [{ ...ACCEPT, delete: ['s1', 's2', 's3'].map(segment => ({ segment, problem: '' })) }, 'correction_empty_chapter:c1'],
  ] as [ReviewCorrections, string][]) {
    const h = harness({ scripts: [goodScript(), bad] });
    assert.equal((await runPodcast(h.deps, Date.now() + 600_000)).failure, 'script_corrections_invalid');
    const fail = h.calls.at(-1)!;
    assert.equal(fail.name, 'worker_podcast_fail'); assert.equal(fail.params.p_quality, true, 'the customer is charged zero');
    assert.equal(h.calls.filter(c => c.name === 'worker_provider_attempt_finish').length, 2);
    assert.ok(!h.names().includes('worker_podcast_speech_begin'), 'no speech is bought');
    assert.deepEqual(h.logs.find(l => (l as { event: string }).event === 'podcast_review_invalid'), { event: 'podcast_review_invalid', job_id: '46000000-0000-4000-8000-000000000101', problems: 1, first, verdict: 'accept', reasons: null });
  }
  // A review whose output is not a correction set is invalid, never approval.
  const whole = harness({ scripts: [goodScript(), goodScript()] });
  assert.equal((await runPodcast(whole.deps, Date.now() + 600_000)).failure, 'script_invalid');
  // Invalid corrections still record the review's verdict and reason codes.
  const coded = harness({ scripts: [goodScript(), { ...ACCEPT, delete: [{ segment: 's99', problem: 'gone' }], verdict: 'reject',
    reasons: [{ code: 'unsupported_claims', segments: ['s2'] }] }] });
  assert.equal((await runPodcast(coded.deps, Date.now() + 600_000)).failure, 'script_corrections_invalid');
  const invalid = coded.calls.find(c => c.name === 'worker_podcast_checked')!.params.p_report as CheckReport;
  assert.equal(invalid.stage, 'review'); assert.deepEqual(invalid.rules, ['correction_unknown_segment:s99']);
  assert.deepEqual(invalid.review, { verdict: 'reject', corrections: 1, action: 'reject' });
  assert.deepEqual(invalid.reasons, [{ code: 'unsupported_claims', segments: ['s2'] }]);
});

// Staging job 57d019e2 (worker 00015, checker v3): every quote verified and the checker would have kept 20 of 22
// turns, but the review returned "reject" with empty lists and no reason, so the job failed script_evidence_rejected.
test('review reasons in the worker: a segment-scoped reject degrades and publishes; a severe or unexplained reject fails, with its codes recorded', async () => {
  const draft = () => { const s = goodScript(); delete s.review; return s; };
  const reject = (reasons: ReviewCorrections['reasons'], extra: Partial<ReviewCorrections> = {}): ReviewCorrections => ({ ...ACCEPT, ...extra, verdict: 'reject', reasons });
  const report = (h: ReturnType<typeof harness>) => h.calls.find(c => c.name === 'worker_podcast_checked')!.params.p_report as CheckReport;

  // Segment-scoped reasons naming their turns: those turns are removed and the episode publishes, degraded.
  const scoped = harness({ scripts: [draft(), reject([{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'unsupported_claims', segments: ['s2'] }])] });
  const published = await runPodcast(scoped.deps, Date.now() + 600_000);
  assert.equal(published.state, 'ready', published.failure ?? '');
  const degraded = report(scoped);
  assert.equal(degraded.checker, 'podcast-checker-v5'); assert.equal(degraded.outcome, 'degraded'); assert.deepEqual(degraded.rules, []);
  assert.deepEqual(degraded.review, { verdict: 'reject', corrections: 0, action: 'remove_segments' });
  assert.deepEqual(degraded.reasons, [{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'unsupported_claims', segments: ['s2'] }]);
  assert.deepEqual(degraded.removals, [{ segment: 's2', reason: 'review_flagged' }, { segment: 's6', reason: 'review_flagged' }]);
  assert.deepEqual(degraded.segments, { checked: 15, kept: 13, removed: 2 });
  const plan = scoped.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  const transcript = JSON.parse(new TextDecoder().decode(scoped.uploads.get(plan[1].path)!));
  assert.deepEqual(transcript.segments.map((s: { id: string }) => s.id), draft().segments.map(s => s.id).filter(id => id !== 's2' && id !== 's6'));
  assert.equal((scoped.calls.find(c => c.name === 'worker_podcast_publish')!.params.p_release as { checker_version: string }).checker_version, 'podcast-checker-v5');
  assert.deepEqual(scoped.logs.find(l => (l as { event: string }).event === 'podcast_reviewed'), { event: 'podcast_reviewed', job_id: '46000000-0000-4000-8000-000000000101',
    verdict: 'reject', action: 'remove_segments', corrections: 0, deleted: 0, reasons: 'wrong_numbers,unsupported_claims', flagged: 2 });

  // Severe reasons, a reason naming no turn, or no reason at all (the staging case): the reject stands.
  for (const [review, rule] of [
    [reject([{ code: 'wrong_numbers', segments: ['s6'] }, { code: 'misrepresents_main_result', segments: [] }]), 'review_reason_severe'],
    [reject([{ code: 'fabricated_detail', segments: ['s7'] }]), 'review_reason_severe'],
    [reject([{ code: 'unsupported_claims', segments: [] }]), 'review_reason_unscoped'],
    [reject([]), 'review_reasons_missing'],
  ] as [ReviewCorrections, string][]) {
    const h = harness({ scripts: [draft(), review] });
    assert.equal((await runPodcast(h.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected', rule);
    assert.equal(h.calls.at(-1)!.name, 'worker_podcast_fail'); assert.equal(h.calls.at(-1)!.params.p_quality, true, 'the customer is charged zero');
    assert.ok(!h.names().includes('worker_podcast_speech_begin'), 'no speech is bought');
    const rejected = report(h);
    assert.equal(h.calls.at(-2)!.name, 'worker_podcast_checked', 'recorded before the failure settles');
    assert.equal(rejected.outcome, 'rejected'); assert.deepEqual(rejected.rules, ['review_rejected', rule]);
    assert.deepEqual(rejected.review, { verdict: 'reject', corrections: 0, action: 'reject' });
    assert.deepEqual(rejected.reasons, review.reasons.length ? review.reasons : undefined);
    // Every quote verified and no turn removed: only the verdict rejected it.
    assert.deepEqual([rejected.evidence!.unverified, rejected.segments!.removed], [0, 0]);
  }
  // A reason naming a turn the draft does not have stands too; a malformed id is recorded as "unknown" (050 accepts codes only).
  const unknown = harness({ scripts: [draft(), reject([{ code: 'unsupported_claims', segments: ['s2', 'x<y>'] }])] });
  assert.equal((await runPodcast(unknown.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected');
  assert.deepEqual(report(unknown).rules, ['review_rejected', 'review_reason_unknown_segment']);
  assert.deepEqual(report(unknown).reasons, [{ code: 'unsupported_claims', segments: ['s2', 'unknown'] }]);

  // Converted, but beyond the limits: more than 30% of turns removed rejects (the review's own deletion counts too).
  const many = harness({ scripts: [draft(), reject([{ code: 'unsupported_claims', segments: ['s10', 's11', 's12', 's13'] }],
    { delete: [{ segment: 's14', problem: 'repeats the caveat' }] })] });
  assert.equal((await runPodcast(many.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected');
  assert.ok(report(many).rules.includes('segments_removed_share'), report(many).rules.join());
  assert.deepEqual(report(many).removed, { review_flagged: 4, review_deleted: 1 });
  assert.ok(!JSON.stringify([many.logs, report(many), report(scoped)]).includes('repeats the caveat'), 'no problem text in logs or reports');
});

// Repair (migration 062, 2026-10-14): staging jobs 17cc7dbd and da14208a were accepted by the review, lost the turns whose
// numbers were not in their evidence, and fell under the word floor. With the repair call in the profile, the writer is
// asked once for replacement turns and the checker runs again.
// The repair is gated by the call's presence, not the version (the v1 audio bounds keep the fake 150 s speech valid here).
const REPAIR_SPEC = { ...SPEC, script: { ...SPEC.script, calls: [...SPEC.script.calls,
  { route: 'podcast_script_repair', max_input_tokens: 88000, max_output_tokens: 6000 }] } };
/** goodScript, thinned: three context turns speak a digit with no evidence (removed), the rest of the caveats are short. */
function thinScript(): Script {
  const s = goodScript(); delete s.review;
  for (const seg of s.segments) if (/^s1[0-5]$/.test(seg.id)) seg.text = 'That caveat is worth repeating for anyone planning to build on this work.';
  s.segments.find(x => x.id === 's10')!.text = 'Version 2 of this idea would need a bigger study.';
  s.segments.find(x => x.id === 's12')!.text = 'Round 3 of experiments might change that picture.';
  s.segments.find(x => x.id === 's14')!.text = 'About 7 teams are said to be trying it.';
  return s;
}
test('a script under the word floor after removals is repaired once: the writer gets the kept turns and the removals, the checker runs again, the episode publishes', async () => {
  // The thinned draft alone: 12 of 15 turns kept, 346 words against a floor of 450, the only problem the word budget.
  const first = checkScript({ ...thinScript(), review: { verdict: 'accept', issues: [] } }, PAPER);
  assert.equal(first.ok, false); if (first.ok) throw new Error('unreachable');
  assert.deepEqual(first.problems, ['word_budget']); assert.equal(first.report.words, 346); assert.equal(first.kept.length, 12);
  // The repair returns the full-length script (new ids for the three replaced turns).
  const repaired = goodScript(); delete repaired.review;
  for (const [from, to] of [['s10', 's16'], ['s12', 's17'], ['s14', 's18']]) repaired.segments.find(x => x.id === from)!.id = to;
  const sent: ScriptParams[] = [];
  const h = harness({ spec: REPAIR_SPEC, scripts: [thinScript(), ACCEPT, repaired] });
  const inner = h.deps.script!.generate;
  h.deps.script = { ...h.deps.script!, generate: async (params, signal) => { sent.push(params); return inner(params, signal); } };
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.deepEqual(result, { processed: 1, recovered: 0, state: 'ready', failure: null });
  assert.deepEqual(h.calls.filter(c => c.name === 'worker_podcast_attempt_begin').map(c => c.params.p_route), ['podcast_script', 'podcast_review', 'podcast_script_repair']);
  // The repair request: the paper, the kept turns as the checker kept them, the removed turns with their reason codes; the draft schema out.
  const request = sent[2];
  assert.equal(request.max_tokens, 6000);
  const text = (request.messages[0].content as { text: string }[]).map(c => c.text).join('\n');
  assert.match(text, /<kept>/); assert.match(text, /<removed>/); assert.match(text, /"id":"s10","reason":"unsupported_number"/);
  assert.match(text, /Version 2 of this idea/); assert.ok(!text.includes('"id":"s10","chapter"'), 'a removed turn is not among the kept ones');
  assert.match(text, /Sparse routing reaches 41.2 perplexity/, 'kept evidence travels as the checker located it');
  assert.ok(text.includes('<paper'), 'the paper is read again');
  // Both checks recorded: the rejected first one, then the accepted repair; the published transcript carries the new ids.
  const reports = h.calls.filter(c => c.name === 'worker_podcast_checked').map(c => c.params.p_report as CheckReport);
  assert.deepEqual(reports.map(r => [r.outcome, r.rules, r.words]), [['rejected', ['word_budget'], 346], ['accepted', [], 601]]);
  const plan = h.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  const transcript = JSON.parse(new TextDecoder().decode(h.uploads.get(plan[1].path)!));
  const ids = transcript.segments.map((x: { id: string }) => x.id);
  assert.deepEqual(ids.filter((id: string) => ['s16', 's17', 's18'].includes(id)), ['s16', 's17', 's18'], 'the replacement turns are published in place');
  assert.ok(!ids.some((id: string) => ['s10', 's12', 's14'].includes(id)), 'the removed ids are gone');
  assert.ok(h.logs.some(l => (l as { event: string }).event === 'podcast_script_repairing'));
  const finishes = h.calls.filter(c => c.name === 'worker_provider_attempt_finish');
  assert.equal(finishes.length, 4, 'draft, review, repair and speech are each billed');
  assert.ok(!JSON.stringify(h.logs).includes('Version 2 of this idea'), 'no script text in logs');
});

test('a repair that still fails, a problem other than the word floor, too many words, or a profile without the call: no second repair, the job fails or proceeds as before', async () => {
  const report = (h: ReturnType<typeof harness>) => h.calls.filter(c => c.name === 'worker_podcast_checked').map(c => c.params.p_report as CheckReport);
  // The repair returns the same thin script: rejected again, both checks recorded, charged zero, no speech.
  const again = harness({ spec: REPAIR_SPEC, scripts: [thinScript(), ACCEPT, thinScript()] });
  assert.equal((await runPodcast(again.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected');
  assert.deepEqual(again.calls.filter(c => c.name === 'worker_podcast_attempt_begin').map(c => c.params.p_route), ['podcast_script', 'podcast_review', 'podcast_script_repair']);
  assert.deepEqual(report(again).map(r => [r.outcome, r.rules]), [['rejected', ['word_budget']], ['rejected', ['word_budget']]]);
  assert.equal(again.calls.at(-1)!.name, 'worker_podcast_fail'); assert.equal(again.calls.at(-1)!.params.p_quality, true);
  assert.ok(!again.names().includes('worker_podcast_speech_begin'));
  // A version-2 profile has no repair call: the first rejection stands, one check recorded.
  const v2 = harness({ scripts: [thinScript(), ACCEPT] });
  assert.equal((await runPodcast(v2.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected');
  assert.deepEqual(v2.calls.filter(c => c.name === 'worker_podcast_attempt_begin').map(c => c.params.p_route), ['podcast_script', 'podcast_review']);
  assert.equal(report(v2).length, 1);
  // Too many words is repaired too (DeepSeek's first live draft, 876 words against 650–800): one trim pass, then the
  // checker again. A trim that lands in range publishes; one that comes back as long fails as before. The draft is
  // padded past a 700-word ceiling while staying under the spoken-character cap, which is not a repairable problem.
  const words = (script: Script) => script.segments.reduce((n, seg) => n + seg.text.split(/\s+/).filter(Boolean).length, 0);
  const long = goodScript(); delete long.review;
  while (words(long) <= 760) for (const seg of long.segments) seg.text += ' The hosts talk this through step by step.';
  assert.ok(long.segments.reduce((n, seg) => n + seg.text.length, 0) < 5_800, 'padded within the spoken-character cap');
  const TRIM_SPEC = { ...REPAIR_SPEC, checker: { ...FIVE_MINUTE_BOUNDS, words: [450, 700] } };
  const trimmed = goodScript(); delete trimmed.review;
  const over = harness({ spec: TRIM_SPEC, scripts: [long, ACCEPT, trimmed] });
  assert.equal((await runPodcast(over.deps, Date.now() + 600_000)).failure, null, 'the trimmed script publishes');
  const trimCall = over.calls.find(c => c.name === 'worker_podcast_attempt_begin' && c.params.p_route === 'podcast_script_repair');
  assert.ok(trimCall, 'a trim repair was attempted');
  assert.ok((report(over)[0].words ?? 0) > 700, 'the first check recorded the long draft');
  const stillLong = harness({ spec: TRIM_SPEC, scripts: [long, ACCEPT, long] });
  assert.equal((await runPodcast(stillLong.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected');
  assert.equal(stillLong.calls.filter(c => c.name === 'worker_podcast_attempt_begin' && c.params.p_route === 'podcast_script_repair').length, 1, 'one repair only');
  // A removal share beyond the limit is not repaired either (the review's deletions count): the existing rule stands.
  const reject = (reasons: ReviewCorrections['reasons'], extra: Partial<ReviewCorrections> = {}): ReviewCorrections => ({ ...ACCEPT, ...extra, verdict: 'reject', reasons });
  const draft = () => { const s = goodScript(); delete s.review; return s; };
  const many = harness({ spec: REPAIR_SPEC, scripts: [draft(), reject([{ code: 'unsupported_claims', segments: ['s10', 's11', 's12', 's13'] }], { delete: [{ segment: 's14', problem: 'repeats the caveat' }] })] });
  assert.equal((await runPodcast(many.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected');
  assert.ok(!many.calls.some(c => c.name === 'worker_podcast_attempt_begin' && c.params.p_route === 'podcast_script_repair'));
});

test('lost grant acknowledgement never becomes a provider call', async () => {
  let sent = 0;
  const h = harness({ failRpc: name => name === 'worker_podcast_attempt_begin' ? new Error('network_lost') : null,
    script: { generate: async () => { sent++; throw new Error('must not send'); } } });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(sent, 0);
  assert.equal(result.failure, 'provider_admission_unavailable');
});

test('a stale claim stops the worker without recording a failure for the new owner', async () => {
  const h = harness({ failRpc: (name, n) => name === 'worker_podcast_advance' && n > 0 ? new Error('stale_podcast_claim') : null });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.failure, 'stale_podcast_claim');
  assert.ok(!h.names().includes('worker_podcast_fail'));
});

test('speech that ran out of tokens or returned no usage never publishes', async () => {
  const cut = harness({ speech: { generate: async () => ({ state: 'succeeded', requestID: 'r', model: 'm', finishReason: 'MAX_TOKENS', audio: tone(150),
    mimeType: 'audio/wav', usage: { text_input_tokens: 1, audio_output_tokens: 16384 }, failure: null }) } });
  assert.equal((await runPodcast(cut.deps, Date.now() + 600_000)).failure, 'speech_incomplete');
  const unknown = harness({ speech: { generate: async () => ({ state: 'unknown', requestID: 'r', model: 'm', finishReason: 'STOP', audio: tone(150),
    mimeType: 'audio/wav', usage: null, failure: 'usage_missing' }) } });
  assert.equal((await runPodcast(unknown.deps, Date.now() + 600_000)).failure, 'speech_outcome_unknown');
  assert.equal(unknown.calls.filter(c => c.name === 'worker_provider_attempt_finish').at(-1)!.params.p_state, 'unknown');
});

test('upload with a lost response is recorded only after the exact bytes are proven; otherwise the write stays uncertain', async () => {
  const lost = harness({ uploadFails: 'lost_but_written' });
  assert.equal((await runPodcast(lost.deps, Date.now() + 600_000)).state, 'ready');
  assert.equal(lost.calls.filter(c => c.name === 'worker_podcast_asset_written').length, 3);
  const missing = harness({ uploadFails: 'missing' });
  assert.equal((await runPodcast(missing.deps, Date.now() + 600_000)).failure, 'upload_failed');
  assert.ok(!missing.names().includes('worker_podcast_asset_written'), 'an unproven write is never marked written');
});

test('a paid call that cannot finish inside the request is never sent', async () => {
  const h = harness();
  const result = await runPodcast(h.deps, Date.now() + 300_000);
  assert.equal(result.failure, 'deadline_before_paid_call');
  assert.ok(!h.names().includes('worker_podcast_attempt_begin'), 'no grant, no POST, zero charge');
});

test('a lost write confirmation is retried (replay-safe), never left unresolved', async () => {
  let lost = 0;
  const h = harness({ failRpc: name => name === 'worker_podcast_asset_written' && lost++ === 0 ? new Error('network_lost') : null });
  assert.equal((await runPodcast(h.deps, Date.now() + 600_000)).state, 'ready');
  assert.equal(h.calls.filter(c => c.name === 'worker_podcast_asset_written').length, 4);
});

test('without provider credentials generated jobs are not claimed', async () => {
  const h = harness({ claimed: false });
  const result = await runPodcast(h.deps, Date.now() + 600_000, { generated: false });
  assert.equal(result.processed, 0);
  assert.equal(h.calls.find(c => c.name === 'worker_podcast_claim')!.params.p_generated, false);
});

// ---------------------------------------------------------------------------
// Lengths: chunked speech and staged (checkpointed) ten/twenty-minute jobs
// ---------------------------------------------------------------------------
const TEN = { ...SPEC, id: 'podcast-10min-v1', target_seconds: 600, min_seconds: 300, max_seconds: 1080, staged: true,
  shape: { duration: 'about ten minutes', words: [1350, 1650], chapters: [6, 8], segments: [30, 80] },
  checker: { words: [900, 2000], chapters: [4, 12], segments: [16, 160], max_spoken_characters: 12500, min_evidenced: 10 },
  script: { model: 'claude-sonnet-5-5', calls: [{ route: 'podcast_script', max_input_tokens: 80000, max_output_tokens: 12000, window_seconds: 420 },
    { route: 'podcast_review', max_input_tokens: 93000, max_output_tokens: 10000, window_seconds: 360 }] },
  speech: { ...SPEC.speech, max_calls: 3, max_audio_tokens: 27000, window_seconds: 420 },
  storage: { audio_bytes: 12582912, transcript_bytes: 4194304, manifest_bytes: 262144 } };
// Vertex TTS takes no output cap, so every chunk must be granted the serving limit (16,384). The 048 ten-minute
// profile shares out 27,000 and is refused before speech; a revised profile grants each chunk the serving limit.
const TEN_SERVING = { ...TEN, speech: { ...TEN.speech, max_audio_tokens: 163_840 } };
const QUOTES = ['Dense models scale poorly with expert count because every token visits every expert.',
  'Each token is routed to the top 2 of 64 experts by a learned gate', 'The load-balancing loss keeps expert utilization within 5% of uniform.',
  'Sparse routing reaches 41.2 perplexity on the benchmark versus 43.9 for the dense baseline.', 'Training throughput improves by 1.8x at equal compute.',
  'We only evaluate English text and models up to 1.3B parameters'];

/** A faithful ten-minute script: 6 chapters x 8 segments, ~1,700 words, every other segment evidenced (no digits spoken). */
function tenMinuteScript(review = true): Script {
  const filler = ' The two hosts slow down here and walk through what the passage says, what it assumes and why a careful reader should care about it.';
  const segments = Array.from({ length: 48 }, (_, i) => ({ id: `s${i + 1}`, chapter: `c${Math.floor(i / 8) + 1}`,
    speaker: (i % 2 ? 'skeptic' : 'explainer') as 'explainer' | 'skeptic', style: 'curious, measured',
    text: (i % 2 ? 'The skeptic asks whether that claim really holds up.' : 'The paper reports a specific result on this point.') + filler,
    claim_type: (i % 2 ? 'context' : 'paper_result') as Script['segments'][number]['claim_type'],
    evidence: i % 2 ? [] : [{ quote: QUOTES[(i / 2) % QUOTES.length], section: '' }], math: [] }));
  return { title: 'Sparse routing, at length', limitations: ['Only English text was evaluated.'],
    chapters: Array.from({ length: 6 }, (_, i) => ({ id: `c${i + 1}`, title: `Part ${['one', 'two', 'three', 'four', 'five', 'six'][i]}` })), segments,
    ...(review ? { review: { verdict: 'accept' as const, issues: [] } } : {}) };
}

/** Speech fake: a take of ~0.4 s per word (150 wpm) with 300 ms of silence at each edge; louder or quieter per call. */
function wordTake(request: SpeechRequest, gain = 1): Uint8Array {
  const parts = ((request.body.contents as { parts: { text: string }[] }[])[0]).parts;
  const words = parts.reduce((n, p) => n + p.text.split(/\s+/).filter(Boolean).length, 0);
  const rate = 24_000, edge = Math.round(rate * 0.3), voiced = Math.round(words * 0.4 * rate);
  const samples = new Int16Array(voiced + 2 * edge);
  for (let i = 0; i < voiced; i++) samples[edge + i] = Math.round(Math.sin(2 * Math.PI * 180 * i / rate) * 4000 * gain * ((i / rate) % 6 < 5.6 ? 1 : 0.05));
  return wavBytes(samples);
}

test('speech plan: one call at the full cap for five minutes; long scripts split at chapter starts within every limit', () => {
  const five = checkScript(goodScript(), PAPER);
  assert.ok(five.ok);
  if (!five.ok) return;
  assert.deepEqual(planSpeechChunks(five.script.segments, { maxInputTokens: 8192, maxCalls: 1, perCallOutputTokens: 16384, maxAudioTokens: 16384 })
    ?.map(c => [c.start, c.end, c.audioTokens]), [[0, 15, 16384]]);
  const ten = checkScript(tenMinuteScript(), PAPER, { bounds: TEN.checker as never });
  assert.ok(ten.ok, ten.ok ? '' : ten.problems.join(','));
  if (!ten.ok) return;
  const limits = { maxInputTokens: 8192, maxCalls: 3, perCallOutputTokens: 16384, maxAudioTokens: 27000 };
  const plan = planSpeechChunks(ten.script.segments, limits)!;
  assert.ok(plan.length >= 2 && plan.length <= 3, `chunks: ${plan.length}`);
  assert.equal(plan[0].start, 0); assert.equal(plan.at(-1)!.end, 48);
  for (let i = 1; i < plan.length; i++) assert.equal(plan[i].start, plan[i - 1].end, 'contiguous, every segment once');
  for (const c of plan) {
    assert.ok(c.bytes <= 8192, 'each request within the input limit');
    assert.equal(speechRequest({ segments: ten.script.segments.slice(c.start, c.end) }, SPEC.speech.voices, c.audioTokens).bytes, c.bytes, 'same bound as the request');
    assert.ok(c.audioTokens <= 16384 && c.audioTokens >= c.words * 12.5, 'each chunk can finish at a slow pace');
    if (c.start > 0) assert.notEqual(ten.script.segments[c.start].chapter, ten.script.segments[c.start - 1].chapter, 'seams fall where a chapter starts');
  }
  assert.ok(plan.reduce((n, c) => n + c.audioTokens, 0) <= 27000, 'total audio within the profile');
  assert.equal(planSpeechChunks(ten.script.segments, { ...limits, maxCalls: 1 }), null, 'more calls than the profile allows: refused before any speech');
  assert.equal(planSpeechChunks(ten.script.segments, { ...limits, maxAudioTokens: 5000 }), null, 'an allowance too small to finish is refused');
});

test('speech plan with a provider serving limit grants the full limit to every chunk', () => {
  const ten = checkScript(tenMinuteScript(), PAPER, { bounds: TEN.checker as never });
  assert.ok(ten.ok, ten.ok ? '' : ten.problems.join(','));
  if (!ten.ok) return;
  const limits = { maxInputTokens: 8192, maxCalls: 3, perCallOutputTokens: 16384, maxAudioTokens: 3 * 16384, servingOutputLimit: 16384 };
  const plan = planSpeechChunks(ten.script.segments, limits);
  assert.ok(plan && plan.length >= 2 && plan.length <= 3);
  if (!plan) return;
  assert.ok(plan.every(chunk => chunk.audioTokens === 16384));
  assert.equal(plan.reduce((sum, chunk) => sum + chunk.audioTokens, 0), plan.length * 16384);
  assert.equal(planSpeechChunks(ten.script.segments, { ...limits, maxAudioTokens: 27000 }), null,
    'a serving-limit profile cannot use a smaller proportional total');
  const widerRequestCap = planSpeechChunks(ten.script.segments, { ...limits, perCallOutputTokens: 20000 });
  assert.ok(widerRequestCap && widerRequestCap.every(chunk => chunk.audioTokens === 16384), 'grant is the serving limit, not a caller cap');
});

test('chunk join: one take untouched; several trimmed, level-matched and joined at a natural pause with exact spans', () => {
  const one = parseWav(tone(3));
  assert.equal(joinChunks([one]).pcm, one);
  // 0.75 vs 1.25 is a 4.4 dB difference: within the ±6 dB the join corrects.
  const quiet = parseWav(wordTake({ body: { contents: [{ parts: [{ text: 'word '.repeat(60) }] }] }, bytes: 0 }, 0.75));
  const loud = parseWav(wordTake({ body: { contents: [{ parts: [{ text: 'word '.repeat(80) }] }] }, bytes: 0 }, 1.25));
  const joined = joinChunks([quiet, loud]);
  assert.equal(joined.spans.length, 2);
  const gap = joined.spans[1].start_ms - joined.spans[0].end_ms;
  assert.ok(gap >= 440 && gap <= 460, `pause ${gap} ms`);
  // Edge silence trimmed to ~120 ms each side: the take is shorter than the two inputs plus the pause.
  assert.ok(joined.pcm.durationMs < quiet.durationMs + loud.durationMs);
  assert.equal(verifyAudio(joined.pcm, { minMs: 1_000, maxMs: 120_000 }), null, 'no dead air or silence at the seam');
  const rms = (p: { samples: Int16Array }) => { let s = 0, n = 0; for (const v of p.samples) if (Math.abs(v) > 200) { s += v * v; n++; } return Math.sqrt(s / Math.max(1, n)); };
  const ratio = rms(joined.parts[0]) / rms(joined.parts[1]);
  assert.ok(ratio > 0.9 && ratio < 1.1, `levels matched (${ratio.toFixed(2)})`);
  assert.equal(joined.parts[0].samples[0], 0, 'faded in, no click');
});

test('ten minutes runs in stages: draft and reviewed script are checkpointed, speech chunks are granted together and sent together', async () => {
  // Request 1: the draft only, then a checkpoint that releases the claim.
  const first = harness({ spec: TEN, scripts: [tenMinuteScript(false)] });
  assert.deepEqual(await runPodcast(first.deps, Date.now() + 780_000), { processed: 1, recovered: 0, state: 'checking', failure: null });
  assert.deepEqual(first.calls.filter(c => c.name === 'worker_podcast_attempt_begin').map(c => c.params.p_route), ['podcast_script']);
  const draft = first.calls.find(c => c.name === 'worker_podcast_checkpoint')!;
  assert.equal(draft.params.p_stage, 'draft');
  assert.ok(!first.names().includes('worker_podcast_advance'), 'parked by the checkpoint, not advanced');
  assert.match(JSON.stringify(first.calls.find(c => c.name === 'worker_podcast_attempt_begin')), /podcast_script/);
  // Request 2: resumes at the review with the stored draft.
  const second = harness({ spec: TEN, scripts: [ACCEPT], resume: { stage: 'review', document: draft.params.p_document } });
  assert.equal((await runPodcast(second.deps, Date.now() + 780_000)).state, 'synthesizing');
  assert.deepEqual(second.calls.filter(c => c.name === 'worker_podcast_attempt_begin').map(c => c.params.p_route), ['podcast_review']);
  const script = second.calls.find(c => c.name === 'worker_podcast_checkpoint')!;
  assert.equal(script.params.p_stage, 'script');
  assert.equal((script.params.p_document as { draft_sha256: string }).draft_sha256, (draft.params.p_document as { draft_sha256: string }).draft_sha256);
  assert.equal((script.params.p_document as { review_sha256: string }).review_sha256, sha(JSON.stringify(ACCEPT)), 'the correction set is part of the lineage');
  // Request 3: every chunk granted in one call, all sent before any returns, then joined, encoded and published.
  let inFlight = 0, peak = 0;
  const third = harness({ spec: TEN_SERVING, resume: { stage: 'speech', document: script.params.p_document }, speech: { generate: async request => {
    inFlight++; peak = Math.max(peak, inFlight); await new Promise(r => setTimeout(r, 20)); inFlight--;
    return { state: 'succeeded', requestID: `resp-${peak}`, model: 'gemini-3.8-flash-tts', finishReason: 'STOP', audio: wordTake(request, 0.8 + Math.random() * 0.4),
      mimeType: 'audio/wav', usage: { text_input_tokens: 2000, audio_output_tokens: 7000 }, failure: null };
  } } });
  assert.equal((await runPodcast(third.deps, Date.now() + 780_000)).state, 'ready');
  assert.ok(!third.names().includes('worker_podcast_attempt_begin'), 'no script calls are bought again');
  const grant = third.calls.find(c => c.name === 'worker_podcast_speech_begin')!.params.p_chunks as { audio_tokens: number }[];
  assert.ok(grant.length >= 2 && grant.length <= 3);
  assert.equal(peak, grant.length, 'chunks are sent together');
  assert.ok(grant.every(c => c.audio_tokens === 16_384), 'each chunk is granted the serving limit');
  assert.equal(third.calls.filter(c => c.name === 'worker_provider_attempt_finish').length, grant.length, 'every chunk result recorded');
  assert.deepEqual(third.calls.filter(c => c.name === 'worker_podcast_advance').map(c => c.params.p_state), ['verifying', 'publishing']);
  const plan = third.calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[];
  const transcript = JSON.parse(new TextDecoder().decode(third.uploads.get(plan[1].path)!));
  assert.equal(transcript.segments.length, 48);
  for (let i = 1; i < 48; i++) assert.ok(transcript.segments[i].start_ms >= transcript.segments[i - 1].end_ms - 1, `segment ${i} in order`);
  // Chapters begin exactly where their first segment begins, in the joined take.
  for (const chapter of transcript.chapters) {
    const firstSegment = transcript.segments.find((s: { chapter: string }) => s.chapter === chapter.id);
    assert.equal(chapter.start_ms, firstSegment.start_ms);
  }
  const manifest = JSON.parse(new TextDecoder().decode(third.uploads.get(plan[2].path)!));
  assert.equal(manifest.identity.speech_calls, grant.length);
  assert.equal(manifest.identity.profile, 'podcast-10min-v1:1');
  assert.ok(manifest.duration_ms >= 300_000 && manifest.duration_ms <= 1_080_000);
});

test('a stage that cannot fit the rest of the request is handed back, never started', async () => {
  const draft = { format: 1, draft: tenMinuteScript(false), draft_sha256: 'a'.repeat(64), models: { podcast_script: 'claude-sonnet-5-5' } };
  const h = harness({ spec: TEN, resume: { stage: 'review', document: draft } });
  const result = await runPodcast(h.deps, Date.now() + 200_000);
  assert.deepEqual(result, { processed: 1, recovered: 0, state: 'checking', failure: null });
  assert.ok(h.names().includes('worker_podcast_yield'));
  assert.ok(!h.names().includes('worker_podcast_attempt_begin'), 'no grant, no POST');
  assert.ok(!h.names().includes('worker_podcast_fail'));
});

test('chunked speech: a refused batch sends nothing; one unknown chunk keeps its liability after every result is recorded', async () => {
  const script = { format: 1, final: tenMinuteScript(), draft_sha256: 'a'.repeat(64), models: {} };
  let sent = 0;
  const refused = harness({ spec: TEN_SERVING, resume: { stage: 'speech', document: script }, speechRefused: true,
    speech: { generate: async () => { sent++; throw new Error('must not send'); } } });
  assert.equal((await runPodcast(refused.deps, Date.now() + 780_000)).failure, 'provider_admission_refused');
  assert.equal(sent, 0);
  let n = 0;
  const partial = harness({ spec: TEN_SERVING, resume: { stage: 'speech', document: script }, speech: { generate: async request => (n++ === 0
    ? { state: 'unknown', requestID: null, model: null, finishReason: null, audio: null, mimeType: null, usage: null, failure: 'transport_unknown' }
    : { state: 'succeeded', requestID: 'r2', model: 'gemini-3.8-flash-tts', finishReason: 'STOP', audio: wordTake(request), mimeType: 'audio/wav',
      usage: { text_input_tokens: 1000, audio_output_tokens: 7000 }, failure: null }) } });
  assert.equal((await runPodcast(partial.deps, Date.now() + 780_000)).failure, 'speech_outcome_unknown');
  const finishes = partial.calls.filter(c => c.name === 'worker_provider_attempt_finish').map(c => c.params.p_state).sort();
  assert.deepEqual(finishes, ['succeeded', 'unknown'].concat(Array(finishes.length - 2).fill('succeeded')).sort());
  assert.ok(!partial.names().includes('worker_podcast_asset_plan'));
});

test('a paper that fits the draft but not the review (paper + draft) is refused before any paid call', async () => {
  const h = harness({ script: { countTokens: async () => 72_000 } });
  const padded = new TextEncoder().encode(PAPER + 'x'.repeat(70_000));
  const original = h.deps.storage.download;
  h.deps.storage.download = async (bucket, path, maximum) => bucket === 'paper-assets' ? padded : original(bucket, path, maximum);
  h.deps.rpc = (inner => async <T>(name: string, params: Record<string, unknown>) => {
    const value = await inner<T>(name, params);
    if (name === 'worker_podcast_claim' && (value as { claimed?: boolean }).claimed) {
      const claim = value as unknown as { source: { sha256: string; bytes: number } };
      claim.source.sha256 = sha(padded); claim.source.bytes = padded.byteLength;
    }
    return value;
  })(h.deps.rpc);
  assert.equal((await runPodcast(h.deps, Date.now() + 600_000)).failure, 'source_too_large');
  assert.ok(!h.names().includes('worker_podcast_attempt_begin'), 'no grant: the review could not have fit');
});

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------
test('encoder: escaped chapter metadata, fixed mono AAC arguments and a strict probe', async () => {
  const meta = ffmetadata([{ title: 'A=b; c#d\\e\nf', start_ms: 0, end_ms: 1000 }, { title: 'Two', start_ms: 1000, end_ms: 2000 }], 'T');
  assert.match(meta, /^;FFMETADATA1\n/);
  assert.match(meta, /title=A\\=b\\; c\\#d\\\\e f/);
  assert.equal((meta.match(/\[CHAPTER\]/g) ?? []).length, 2);
  const args = ffmpegArguments('in.wav', 'meta.txt', 'out.m4a');
  for (const [flag, value] of [['-ac', '1'], ['-c:a', 'aac'], ['-b:a', '64k'], ['-ar', '24000'], ['-f', 'mp4'], ['-map_chapters', '1']]) {
    assert.equal(args[args.indexOf(flag) + 1], value);
  }
  const probe = (extra: Record<string, unknown> = {}) => JSON.stringify({ streams: [{ codec_type: 'audio', codec_name: 'aac', channels: 1, sample_rate: '24000' }],
    format: { duration: '301.25', format_name: 'mov,mp4,m4a,3gp,3g2,mj2' }, chapters: [{}, {}], ...extra });
  assert.equal(verifyProbe(probe(), 2), 301_250);
  assert.throws(() => verifyProbe(probe({ chapters: [{}] }), 2), /encoding_invalid/);
  assert.throws(() => verifyProbe(probe({ streams: [{ codec_type: 'audio', codec_name: 'mp3', channels: 1, sample_rate: '24000' }] }), 2), /encoding_invalid/);
  const chapterTrack = { codec_type: 'data', codec_name: 'bin_data', codec_tag_string: 'text' };
  const audioStream = { codec_type: 'audio', codec_name: 'aac', channels: 1, sample_rate: '24000' };
  assert.equal(verifyProbe(probe({ streams: [audioStream, chapterTrack] }), 2), 301_250, 'the MP4 chapter text track is expected');
  assert.throws(() => verifyProbe(probe({ streams: [audioStream, { codec_type: 'video', codec_name: 'png' }] }), 2), /encoding_invalid/);
  assert.throws(() => verifyProbe(probe({ streams: [audioStream, chapterTrack, chapterTrack] }), 2), /encoding_invalid/);
  // The subprocess path with a fake spawner (no ffmpeg on the test host).
  const spawned: string[][] = [];
  const spawner = ((binary: string, argv: string[]) => {
    spawned.push([binary, ...argv]);
    const child = new EventEmitter() as EventEmitter & { stdout: PassThrough; stderr: PassThrough; kill(): void };
    child.stdout = new PassThrough(); child.stderr = new PassThrough(); child.kill = () => {};
    setImmediate(() => {
      if (binary === 'ffmpeg') writeFileSync(argv[argv.length - 1], Buffer.from([0, 0, 0, 24]));
      else child.stdout.write(probe());
      child.stdout.end(); child.emit('close', 0);
    });
    return child;
  }) as unknown as Parameters<typeof ffmpegEncoder>[0] extends infer O ? O extends { spawner?: infer S } ? S : never : never;
  const encoded = await ffmpegEncoder({ spawner }).encode(tone(1), [{ title: 'a', start_ms: 0, end_ms: 500 }, { title: 'b', start_ms: 500, end_ms: 1000 }], 'T',
    new AbortController().signal);
  assert.equal(encoded.durationMs, 301_250);
  assert.deepEqual([...encoded.bytes], [0, 0, 0, 24]);
  assert.deepEqual(spawned.map(s => s[0]), ['ffmpeg', 'ffprobe']);
});

// ---------------------------------------------------------------------------
// Edge API and delivery
// ---------------------------------------------------------------------------
const ACCOUNT = '46000000-0000-4000-8000-0000000000aa';
const RELEASE = '46000000-0000-4000-8000-0000000000bb';
function api(overrides: Partial<PodcastAPIDeps> = {}, transcript?: Uint8Array) {
  const calls: { kind: string; name: string; params: Record<string, unknown> }[] = [];
  const doc = transcript ?? new TextEncoder().encode(JSON.stringify({ format: 1, speakers: { explainer: 'Host 1', skeptic: 'Host 2' }, disclosure: 'AI audio',
    timing: 'approximate', chapters: [{ id: 'c1', title: 'Intro', start_ms: 0 }], segments: [{ id: 's1', speaker: 'explainer', text: 'Hi', start_ms: 0, end_ms: 1000 }] }));
  const deps: PodcastAPIDeps = {
    user: async () => ({ accountID: ACCOUNT, rpc: async <T>(name: string, params: Record<string, unknown>) => { calls.push({ kind: 'user', name, params }); return { ok: name } as T; } }),
    service: async <T>(name: string, params: Record<string, unknown>) => {
      calls.push({ kind: 'service', name, params });
      if (name === 'worker_podcast_release') return { episode: { release_id: RELEASE, state: 'ready' },
        transcript: { bucket: 'podcast-assets', path: `shared/${'a'.repeat(64)}/transcript.json`, sha256: sha(doc), bytes: doc.byteLength } } as T;
      return { grant_id: 'g', expires_at: 'soon', members: [{ role: 'audio', id: '46000000-0000-4000-8000-0000000000cc', bytes: 10, sha256: 'a'.repeat(64), media_type: 'audio/mp4' }] } as T;
    },
    download: async () => doc, origin: 'https://project.supabase.co/', randomHex: () => 'f'.repeat(64), ...overrides,
  };
  return { deps, calls };
}
const req = (path: string, init?: RequestInit) => new Request(`https://edge.test/functions/v1/podcast${path}`, init);
const headers = { 'Cache-Control': 'no-store' };

test('Edge API: customer RPCs, validated inputs, transcript integrity and single-use member URLs', async () => {
  const h = api();
  assert.equal((await (await handlePodcast(req('?action=catalog&limit=10'), h.deps, headers)).json()).ok, 'v1_podcast_catalog');
  assert.deepEqual(h.calls[0].params, { p_after: null, p_limit: 10 });
  await assert.rejects(handlePodcast(req('?action=catalog&limit=500'), h.deps, headers), /invalid_podcast_cursor/);
  await assert.rejects(handlePodcast(req('?action=quote'), h.deps, headers), /method_unavailable/);
  await assert.rejects(handlePodcast(req('?action=paper&item_id=nope'), h.deps, headers), /invalid_id/);
  const quote = await handlePodcast(req('?action=quote', { method: 'POST', body: JSON.stringify({ item_id: RELEASE, request_id: ACCOUNT }) }), h.deps, headers);
  assert.equal((await quote.json()).ok, 'v1_podcast_quote');
  assert.equal(h.calls.at(-1)!.params.p_profile, undefined, 'no length means the default (five minutes)');
  await handlePodcast(req('?action=quote', { method: 'POST', body: JSON.stringify({ item_id: RELEASE, request_id: ACCOUNT, profile: 'podcast-10min-v1' }) }), h.deps, headers);
  assert.equal(h.calls.at(-1)!.params.p_profile, 'podcast-10min-v1');
  // The writer (2026-10-14) is forwarded as p_writer; a malformed one is refused before any call.
  await handlePodcast(req('?action=quote', { method: 'POST', body: JSON.stringify({ item_id: RELEASE, request_id: ACCOUNT, profile: 'podcast-5min-v1', writer: 'anthropic' }) }), h.deps, headers);
  assert.deepEqual(h.calls.at(-1)?.params, { p_item_id: RELEASE, p_request_id: ACCOUNT, p_profile: 'podcast-5min-v1', p_writer: 'anthropic' });
  await assert.rejects(handlePodcast(req('?action=quote', { method: 'POST', body: JSON.stringify({ item_id: RELEASE, request_id: ACCOUNT, writer: 'Sonnet 5.5' }) }), h.deps, headers), /podcast_writer_unavailable/);
  await assert.rejects(handlePodcast(req('?action=quote', { method: 'POST', body: JSON.stringify({ item_id: RELEASE, request_id: ACCOUNT, profile: 'Long!' }) }), h.deps, headers),
    /podcast_profile_unavailable/);
  assert.equal(podcastError('podcast_profile_unavailable').status, 400);
  await assert.rejects(handlePodcast(req('?action=start', { method: 'POST', body: JSON.stringify({ quote_id: RELEASE, request_id: ACCOUNT }) }), h.deps, headers), /consent_required/);
  const episode = await (await handlePodcast(req(`?action=episode&release_id=${RELEASE}`), h.deps, headers)).json();
  assert.equal(episode.episode.chapters[0].title, 'Intro');
  assert.equal(episode.episode.transcript.segments[0].text, 'Hi');
  assert.ok(!JSON.stringify(episode).includes('podcast-assets') && !JSON.stringify(episode).includes('shared/'), 'no storage location leaks');
  const tampered = api({ download: async () => new TextEncoder().encode('{"format":1}') });
  await assert.rejects(handlePodcast(req(`?action=episode&release_id=${RELEASE}`), tampered.deps, headers), /podcast_integrity_failed/);
  const download = await (await handlePodcast(req('?action=download', { method: 'POST', body: JSON.stringify({ release_id: RELEASE }) }), h.deps, headers)).json();
  assert.equal(download.grant.members[0].url, `https://project.supabase.co/functions/v1/podcast-member?grant=${'f'.repeat(64)}&member=46000000-0000-4000-8000-0000000000cc`);
  const create = h.calls.find(c => c.name === 'worker_podcast_delivery_create')!;
  assert.equal(create.params.p_account_id, ACCOUNT);
  assert.equal(create.params.p_token_sha256, '\\x' + sha('f'.repeat(64)), 'only the token hash is stored');
  await assert.rejects(handlePodcast(req('?action=states', { method: 'POST', body: JSON.stringify({ release_ids: [] }) }), h.deps, headers), /invalid_podcast_request/);
  assert.equal(podcastError('insufficient_credits').status, 402);
  assert.equal(podcastError('relation "app_private.podcast_jobs" does not exist').code, 'service_unavailable', 'raw errors never leak');
});

test('member delivery: one redemption, no Range, integrity before bytes, observation recorded', async () => {
  const audio = new Uint8Array([9, 8, 7, 6]);
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const deps = (bytes = audio) => ({ account: async () => ACCOUNT,
    rpc: async <T>(name: string, params: Record<string, unknown>) => { calls.push({ name, params });
      return (name === 'worker_podcast_delivery_redeem' ? { grant_id: 'g1', bucket: 'podcast-assets', path: `shared/${'b'.repeat(64)}/audio.m4a`,
        bytes: 4, sha256: sha(audio), media_type: 'audio/mp4' } : null) as T; },
    download: async () => bytes });
  const url = `https://edge.test/functions/v1/podcast-member?grant=${'e'.repeat(64)}&member=46000000-0000-4000-8000-0000000000cc`;
  await assert.rejects(deliverPodcastMember(new Request(url, { headers: { range: 'bytes=0-1' } }), deps(), headers), /podcast_range_unavailable/);
  await assert.rejects(deliverPodcastMember(new Request(url + '&extra=1'), deps(), headers), /invalid_podcast_grant/);
  const response = await deliverPodcastMember(new Request(url), deps(), headers);
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [9, 8, 7, 6]);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  assert.equal(response.headers.get('Accept-Ranges'), 'none');
  assert.deepEqual(calls.at(-1)!.params.p_observation, 'response_created');
  await assert.rejects(deliverPodcastMember(new Request(url), deps(new Uint8Array([1, 1, 1, 1])), headers), /podcast_integrity_failed/);
  assert.deepEqual(calls.at(-1)!.params.p_observation, 'integrity_failed');
  assert.equal(calls.at(-1)!.params.p_response_bytes, 0);
});

// ---------------------------------------------------------------------------
// Worker HTTP routing
// ---------------------------------------------------------------------------
function fakeExchange(url: string, method = 'POST', secret = 's'.repeat(40)) {
  const request = Object.assign(new PassThrough(), { method, url, headers: { 'x-pipeline-secret': secret } });
  let status = 0, body = '';
  const response = { writeHead: (s: number) => { status = s; }, end: (b: string) => { body = b; } };
  return { request, response, result: () => ({ status, body: body ? JSON.parse(body) : null }) };
}

test('worker server: POST /podcast runs the bounded podcast thread, separately guarded; maintenance refuses', async () => {
  let pipelineRuns = 0, podcastRuns = 0;
  const handle = createHandler(async () => { pipelineRuns++; return { processed: 0, ms: 1 }; },
    { maintenance: false, revision: 'gradstep-pipeline-00099-abc', podcast: async () => { podcastRuns++; return { processed: 1, ms: 2 }; } });
  const one = fakeExchange('/podcast');
  await handle(one.request as never, one.response as never, 's'.repeat(40));
  assert.deepEqual(one.result(), { status: 200, body: { accepted: true, processed: 1 } });
  assert.equal(podcastRuns, 1); assert.equal(pipelineRuns, 0);
  const paper = fakeExchange('/');
  await handle(paper.request as never, paper.response as never, 's'.repeat(40));
  assert.equal(pipelineRuns, 1);
  const paused = createHandler(async () => ({ processed: 0, ms: 0 }), { maintenance: true, podcast: async () => { podcastRuns++; return { processed: 1, ms: 1 }; } });
  const refused = fakeExchange('/podcast');
  await paused(refused.request as never, refused.response as never, 's'.repeat(40));
  assert.equal(refused.result().status, 503); assert.equal(podcastRuns, 1);
  const anonymous = fakeExchange('/podcast', 'POST', 'wrong');
  await handle(anonymous.request as never, anonymous.response as never, 's'.repeat(40));
  assert.equal(anonymous.result().status, 401);
});

test('a chunk granted less than the serving limit is refused before any speech is bought (no output cap can be sent)', async () => {
  const first = harness({ spec: TEN, scripts: [tenMinuteScript(false)] });
  await runPodcast(first.deps, Date.now() + 780_000);
  const draft = first.calls.find(c => c.name === 'worker_podcast_checkpoint')!;
  const second = harness({ spec: TEN, scripts: [ACCEPT], resume: { stage: 'review', document: draft.params.p_document } });
  await runPodcast(second.deps, Date.now() + 780_000);
  const script = second.calls.find(c => c.name === 'worker_podcast_checkpoint')!;
  const third = harness({ spec: TEN, resume: { stage: 'speech', document: script.params.p_document },
    speech: { generate: async () => { throw new Error('must not be called'); } } });
  const result = await runPodcast(third.deps, Date.now() + 780_000);
  assert.equal(result.failure, 'speech_grant_below_serving_limit');
  assert.ok(!third.names().includes('worker_podcast_speech_begin'), 'nothing granted or sent');
});


// DeepSeek as the script provider (2026-10-14): a spec naming `deepseek` sends every script call there, never to the
// Anthropic provider, and prices them from the DeepSeek card; a spec naming a provider the worker lacks fails
// script_unavailable before any paid call.
test('a spec naming deepseek routes the draft and the review to that provider at its prices; a missing provider is script_unavailable', async () => {
  const seen: string[] = [];
  const outputs = [(() => { const d = goodScript(); delete d.review; return d; })(), ACCEPT];
  const deepseek: ScriptProvider = { countTokens: async () => null, generate: async params => {
    seen.push(params.model);
    return { state: 'succeeded', requestID: `ds_${seen.length}`, model: 'deepseek-v4-pro', stopReason: 'end_turn', text: JSON.stringify(outputs.shift()),
      usage: { input: 50_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 5_000 }, failure: null }; } };
  // The harness's version-1 shape (later versions bound the fake speech's duration); the provider gates on the spec's field, not the version.
  const spec = { ...SPEC, script: { ...SPEC.script, provider: 'deepseek', model: 'deepseek-v4-pro' } };
  const h = harness({ spec, script: { generate: async () => { throw new Error('anthropic must not be called'); } }, scriptProviders: { deepseek } });
  await runPodcast(h.deps, Date.now() + 600_000);
  assert.deepEqual(seen, ['deepseek-v4-pro', 'deepseek-v4-pro'], `draft and review went to DeepSeek with the spec model; calls: ${h.names().join(',')}`);
  const finishes = h.calls.filter(c => c.name === 'worker_provider_attempt_finish');
  assert.ok(finishes.length >= 2);
  assert.equal(Number(finishes[0].params.p_actual_microusd), Math.ceil(50_000 * 1.32 + 5_000 * 3.96), 'priced from the DeepSeek card');
  assert.ok(!h.names().includes('worker_podcast_fail'), 'the episode completes');
  const missing = harness({ spec, script: { generate: async () => { throw new Error('must not call'); } } });
  await runPodcast(missing.deps, Date.now() + 600_000);
  assert.ok(missing.names().includes('worker_podcast_fail'), 'no provider for the spec fails the job');
  assert.ok(JSON.stringify(missing.calls).includes('script_unavailable'));
  assert.ok(!missing.names().includes('worker_provider_attempt_finish'), 'nothing was attempted');
});


// Spoken markup (owner's first episode, 2026-10-14): emphasis, backticks, inline-math wrappers and a speaker label come
// off the spoken text and the turn stays; a backslash command or braces still make the turn unreadable.
test('readable markup is stripped from a turn instead of cutting it; real markup still removes', () => {
  assert.equal(stripSpokenMarkup('Explainer: The **key** idea is `attention` with \\(d_k\\) and $O(n^2)$ cost.'), 'The key idea is attention with d_k and O(n^2) cost.');
  assert.equal(stripSpokenMarkup('A *subtle* point, _really_.'), 'A subtle point, really.');
  const script = goodScript(); script.review = { verdict: 'accept', issues: [], reasons: [] };
  const first = script.segments[0];
  first.text = `**${first.text}**`;
  const result = checkScript(script, PAPER, { bounds: { ...FIVE_MINUTE_BOUNDS, words: [200, 1000] } });
  assert.ok(result.ok, `emphasis alone no longer costs the turn: ${result.ok ? '' : JSON.stringify({ problems: result.problems, removals: result.report.removals, words: result.report.words })}`);
  assert.equal(result.script.segments[0].text, goodScript().segments[0].text);
  assert.equal(result.report.repaired?.spoken_markup, 1);
  const broken = goodScript(); broken.review = { verdict: 'accept', issues: [], reasons: [] };
  broken.segments[0].text = 'The loss is \\frac{a}{b} here.';
  const cut = checkScript(broken, PAPER, { bounds: { ...FIVE_MINUTE_BOUNDS, words: [200, 1000] } });
  assert.ok(cut.report.removals?.some(r => r.reason === 'markup'), 'a backslash command still cuts the turn');
});

test('the writer is told to open with a plain welcome and close the same way', () => {
  assert.match(SCRIPT_INSTRUCTIONS, /first segment opens the episode: the explainer welcomes the listener/);
  assert.match(SCRIPT_INSTRUCTIONS, /without ending on a question/);
});

// A check that passes but leaves the dialogue broken (the opener removed, or a reply left without its question): one
// repair pass rewrites the removed turns; a profile without the repair call refuses the episode instead.
test('a removed opening turn is repaired before the episode is spoken, or refused without the repair call', async () => {
  const headless = goodScript(); delete headless.review;
  headless.segments[0].text = 'Welcome to the episode about ' + 'x'.repeat(10) + '?';  // the opener as a question the next turn does not answer (same speaker)
  headless.segments[1].speaker = headless.segments[0].speaker;
  const whole = goodScript(); delete whole.review;
  const repaired = harness({ spec: REPAIR_SPEC, scripts: [headless, ACCEPT, whole] });
  assert.equal((await runPodcast(repaired.deps, Date.now() + 600_000)).failure, null, 'the repaired episode publishes');
  assert.ok(repaired.calls.some(c => c.name === 'worker_podcast_attempt_begin' && c.params.p_route === 'podcast_script_repair'), 'the repair ran');
  assert.ok(repaired.logs.some((l: any) => l.event === 'podcast_script_repairing' && l.broken === true));
  const refused = harness({ scripts: [headless, ACCEPT] });
  assert.equal((await runPodcast(refused.deps, Date.now() + 600_000)).failure, 'script_evidence_rejected', 'no repair call: never spoken mid-thought');
  assert.ok(!refused.names().includes('worker_podcast_speech_begin'));
});
