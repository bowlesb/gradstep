// Paper podcasts: script/evidence checker, speech adapter, audio validation, the
// bounded worker job against a fake database, Edge API and single-use delivery.
// No network, no provider or Storage calls: every transport is a local fake.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { writeFileSync } from 'node:fs';
import { checkScript, draftRequest, fitsInput, fixtureScript, parseScript, requestBytes, reviewRequest, scriptCost, scriptDocument,
  type Script, type ScriptCallResult, type ScriptProvider } from '../../supabase/functions/_shared/podcast-script.ts';
import { alignSegments, fixtureAudio, impersonatedTokenSource, parseWav, speechCost, speechRequest, verifyAudio, vertexSpeechProvider,
  wavBytes, type SpeechProvider } from '../../supabase/functions/_shared/podcast-speech.ts';
import { runPodcast, type PodcastDeps } from '../../supabase/functions/_shared/podcast-worker.ts';
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

test('checker accepts verbatim evidence and refuses unsupported numbers, paraphrased quotes, markup and rejected reviews', () => {
  const ok = checkScript(goodScript(), PAPER);
  assert.equal(ok.ok, true, ok.ok ? '' : ok.problems.join(','));
  if (ok.ok) {
    assert.ok(ok.script.segments[5].evidence[0].offset > 0);
    assert.equal(scriptDocument(ok.script), scriptDocument(checkScript(goodScript(), PAPER).ok ? (checkScript(goodScript(), PAPER) as { script: never }).script : ok.script));
  }
  const paraphrase = goodScript(); paraphrase.segments[5].evidence[0].quote = 'Sparse routing gets 41.2 perplexity versus 43.9.';
  assert.ok(!checkScript(paraphrase, PAPER).ok);
  const number = goodScript(); number.segments[6].text = 'Throughput improves by 2.5x at equal compute.';
  assert.deepEqual((checkScript(number, PAPER) as { problems: string[] }).problems, ['number_not_in_evidence:s7']);
  const bare = goodScript(); bare.segments[1].text = 'It is 99 percent better.';
  assert.ok((checkScript(bare, PAPER) as { problems: string[] }).problems.includes('unsupported_number:s2'));
  const markup = goodScript(); markup.segments[0].text = 'Speaker 1: **hello** $x$';
  assert.ok((checkScript(markup, PAPER) as { problems: string[] }).problems.includes('segment_markup:s1'));
  const rejected = goodScript(); rejected.review = { verdict: 'reject', issues: [] };
  assert.ok((checkScript(rejected, PAPER) as { problems: string[] }).problems.includes('review_rejected'));
  const material = goodScript(); material.segments[5].evidence = [];
  assert.ok((checkScript(material, PAPER) as { problems: string[] }).problems.includes('evidence_missing:s6'));
  assert.equal(parseScript('{"title":"x"}', false), null);
  assert.equal(parseScript(JSON.stringify(goodScript()), true)?.review?.verdict, 'accept');
  assert.equal(parseScript(JSON.stringify({ ...goodScript(), review: undefined }), true), null, 'review pass must return a verdict');
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
  assert.equal(body.generationConfig.maxOutputTokens, 16_384);
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

function harness(options: { origin?: 'generated' | 'fixture'; scope?: 'shared' | 'private'; script?: Partial<ScriptProvider>; speech?: SpeechProvider | null;
  failRpc?: (name: string, n: number) => Error | null; uploadFails?: 'lost_but_written' | 'missing'; scripts?: Script[]; claimed?: boolean } = {}) {
  const calls: { name: string; params: Record<string, unknown> }[] = [], logs: unknown[] = [], uploads = new Map<string, Uint8Array>();
  let n = 0, attempts = 0, claimed = false;
  const queue = [...(options.scripts ?? [(() => { const s = goodScript(); delete s.review; return s; })(), goodScript()])];
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
            episode_id: '46000000-0000-4000-8000-000000000201', spec: SPEC, metadata: { title: 'Sparse Mixture Routing' },
            source: { document_id: '46000000-0000-4000-8000-000000000301', bucket: 'paper-assets', path: 'raw/x/standalone.mmd', sha256: sha(PAPER_BYTES),
              bytes: PAPER_BYTES.byteLength, normalization_version: 'mathpix-standalone-mmd-v1' } } as T;
        case 'worker_podcast_advance': return { state: params.p_state, canceled: false } as T;
        case 'worker_podcast_attempt_begin': return { granted: true, attempt_id: params.p_attempt_id, account_id: OWNER,
          operation_id: '46000000-0000-4000-8000-000000000401', ceiling_microusd: 1 } as T;
        case 'worker_provider_attempt_finish': return null as T;
        case 'worker_podcast_asset_plan': return { objects: (params.p_objects as { role: string; path: string }[]).map((o, i) => ({ role: o.role, id: `obj-${i}`, path: o.path, verified: false })) } as T;
        case 'worker_podcast_asset_write': {
          const planned = (calls.find(c => c.name === 'worker_podcast_asset_plan')!.params.p_objects as { path: string }[])[Number(String(params.p_object_id).slice(4))];
          return { write: true, verified: false, bucket: 'podcast-assets', path: planned.path } as T;
        }
        case 'worker_podcast_asset_written': return null as T;
        case 'worker_podcast_publish': return { state: 'ready', canceled: false, release: { release_id: 'rel', state: 'pending_review' } } as T;
        case 'worker_podcast_fail': return { state: 'failed' } as T;
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
  assert.deepEqual(begins, ['podcast_script', 'podcast_review', 'podcast_speech']);
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

test('checker rejection is a quality failure (customer charged zero) after recorded usage', async () => {
  const bad = goodScript(); bad.segments[5].evidence[0].quote = 'paraphrased claim that is not in the paper text';
  const h = harness({ scripts: [goodScript(), bad] });
  const result = await runPodcast(h.deps, Date.now() + 600_000);
  assert.equal(result.failure, 'script_evidence_rejected');
  const fail = h.calls.at(-1)!;
  assert.equal(fail.name, 'worker_podcast_fail'); assert.equal(fail.params.p_quality, true);
  assert.equal(h.calls.filter(c => c.name === 'worker_provider_attempt_finish').length, 2);
  assert.ok(!h.names().includes('worker_podcast_asset_plan'));
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

test('without provider credentials generated jobs are not claimed', async () => {
  const h = harness({ claimed: false });
  const result = await runPodcast(h.deps, Date.now() + 600_000, { generated: false });
  assert.equal(result.processed, 0);
  assert.equal(h.calls.find(c => c.name === 'worker_podcast_claim')!.params.p_generated, false);
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
