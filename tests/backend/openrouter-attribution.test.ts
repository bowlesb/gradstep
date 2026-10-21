import test from 'node:test';
import assert from 'node:assert/strict';
import { openRouterPost, rpcAttribution, OpenRouterNotDispatched } from '../../supabase/functions/_shared/openrouter-transport.ts';
import { guardedFetch, ModelEgressBlocked } from '../../supabase/functions/_shared/egress.ts';
import { openRouterScriptProvider } from '../../supabase/functions/_shared/openrouter-script.ts';
import { openRouterSpeechProvider, normalizeOpenRouterSpeech } from '../../supabase/functions/_shared/openrouter-speech.ts';
import { speechRequest, parseWav } from '../../supabase/functions/_shared/podcast-speech.ts';
const accountID = 'aaaaaaaa-0000-4000-8000-000000000001', operationID = 'bbbbbbbb-0000-4000-8000-000000000001',
  attemptID = 'cccccccc-0000-4000-8000-000000000001';
const body = { model: 'anthropic/claude-haiku-5.5', provider: { only: ['google-vertex/us'] } };
const signal = () => new AbortController().signal;
const speechRoute = { name: 'Google | google/gemini-3.8-flash-tts-20260922', model_id: 'google/gemini-3.8-flash-tts', provider_name: 'Google', tag: 'google-vertex/global',
  pricing: { prompt: '0.0000005', completion: '0.000009' }, max_completion_tokens: 16384 };

test('every paid send has durable account, operation, attempt, feature and time; replay and lost grant send nothing', async () => {
  for (const grant of ['ok', 'refused', 'lost'] as const) {
    let dispatched = false, sent = 0; const sequence: string[] = [];
    const attribution = rpcAttribution({ accountID, operationID, rpc: async (name, p) => {
      sequence.push(name); assert.equal(p.p_account_id, accountID); assert.equal(p.p_operation_id, operationID);
      assert.equal(p.p_attempt_id, attemptID); assert.deepEqual(p.p_metadata, { transport_model: body.model,
        endpoint: 'google-vertex/us', feature: 'figure_detail', caller: 'chat' });
      if (grant === 'lost') throw new Error('lost ack');
      if (grant === 'refused' || dispatched) return false; dispatched = true; return true;
    } }, attemptID, 'figure_detail', 'chat');
    const options = { apiKey: 'never-log', fetch: (async (_url: any, init: any) => {
      sequence.push('POST'); sent++; const value = JSON.parse(init.body);
      assert.equal(value.user, accountID); assert.equal(value.session_id, operationID);
      assert.equal(value.trace.attempt_id, attemptID); assert.ok(Number.isFinite(Date.parse(value.trace.sent_at)));
      assert.equal(new Headers(init.headers).get('X-Session-ID'), operationID); return new Response('{}');
    }) as typeof fetch };
    if (grant === 'ok') await openRouterPost(options, 'chat/completions', body, signal(), attribution);
    else await assert.rejects(openRouterPost(options, 'chat/completions', body, signal(), attribution), OpenRouterNotDispatched);
    await assert.rejects(openRouterPost(options, 'chat/completions', body, signal(), attribution), OpenRouterNotDispatched);
    assert.equal(sent, grant === 'ok' ? 1 : 0); assert.equal(sequence[0], 'worker_openrouter_dispatch');
  }
});

test('missing attribution and direct model endpoints cannot become an untracked fallback', async () => {
  let sent = 0; const fetcher = async () => { sent++; return new Response('{}'); };
  await assert.rejects(openRouterPost({ apiKey: 'fixture', fetch: fetcher }, 'chat/completions', body, signal(), undefined), OpenRouterNotDispatched);
  const guarded = guardedFetch(fetcher, 'test');
  for (const host of ['api.anthropic.com', 'api.deepseek.com', 'us-aiplatform.googleapis.com', 'generativelanguage.googleapis.com', 'texttospeech.googleapis.com'])
    await assert.rejects(guarded(`https://${host}/anything`), ModelEgressBlocked);
  assert.equal(sent, 0);
  const redirect = guardedFetch(async () => new Response(null, { status: 307, headers: { location: 'https://api.anthropic.com/v1/messages' } }), 'test');
  await assert.rejects(redirect('https://example.org'), ModelEgressBlocked);
});

test('podcast structured generation uses the same attributed OpenRouter transport and exact bill', async () => {
  let sent: any; const provider = openRouterScriptProvider({ apiKey: 'fixture', fetch: async (_url, init) => {
    sent = JSON.parse(String(init?.body));
    return new Response(`data: ${JSON.stringify({ id: 'gen-script', model: sent.model,
      choices: [{ delta: { content: '{"title":"An episode"}' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 100, completion_tokens: 20, cost: 0.000123 } })}\n\ndata: [DONE]\n\n`);
  } });
  const result = await provider.generate({ model: 'deepseek-v4-pro', max_tokens: 200, system: 'rules', messages: [{ role: 'user', content: 'source' }],
    output_config: { format: { type: 'json_schema', schema: { type: 'object', properties: { title: { type: 'string' } } } } } }, signal(),
    { accountID, operationID, attemptID, feature: 'podcast_script', caller: 'podcast', dispatch: async () => true });
  assert.equal(sent.model, 'deepseek/deepseek-v4-pro-0813'); assert.equal(sent.user, accountID);
  assert.equal(sent.response_format.type, 'json_schema'); assert.deepEqual(sent.provider.only, ['deepinfra/fp8']);
  assert.deepEqual(sent.reasoning, { enabled: false }, 'bounded script output cannot be consumed by hidden reasoning');
  assert.equal(result.state, 'succeeded'); assert.ok(Math.abs(result.billedMicrousd! - 123) < 0.00001); assert.equal(result.model, 'deepseek-v4-pro');
});

test('Sonnet scripts retain required reasoning at low effort inside the admitted output cap', async () => {
  let sent: any;
  const provider = openRouterScriptProvider({ apiKey: 'fixture', fetch: async (_url, init) => {
    sent = JSON.parse(String(init?.body));
    return new Response(`data: ${JSON.stringify({ id: 'gen-sonnet', model: sent.model,
      choices: [{ delta: { content: '{}' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 100, completion_tokens: 20, cost: 0.0004 } })}\n\ndata: [DONE]\n\n`);
  } });
  const result = await provider.generate({ model: 'claude-sonnet-5-5', max_tokens: 4800,
    thinking: { type: 'between_tools' }, output_config: { effort: 'medium' },
    system: 'rules', messages: [{ role: 'user', content: 'source' }] }, signal(),
    { accountID, operationID, attemptID, feature: 'podcast_script', caller: 'podcast', dispatch: async () => true });
  assert.equal(result.state, 'succeeded'); assert.deepEqual(sent.reasoning, { effort: 'low' });
  assert.equal(sent.max_tokens, 4800); assert.deepEqual(sent.provider.only, ['google-vertex/us']);
});

test('speech uses explicit policy and two voices; missing bill holds liability without another generation', async () => {
  for (const missing of [false, true]) {
    let posts = 0, receipts = 0, sent: any;
    const speech = openRouterSpeechProvider({ apiKey: 'fixture',
      fetch: async (url, init) => {
        if (String(url).endsWith('/endpoints/zdr')) return Response.json({ data: [speechRoute] });
        if (init?.method === 'POST') { posts++; sent = JSON.parse(String(init.body));
          return new Response(new Uint8Array([1, 2, 3, 4]), { headers: { 'x-generation-id': 'gen-speech', 'content-type': 'audio/pcm' } }); }
        assert.match(String(url), /generation\?id=gen-speech/);
        return new Response(JSON.stringify({ data: missing ? {} : { id: 'gen-speech', model: 'google/gemini-3.8-flash-tts',
          provider_name: 'Google', external_user: accountID, session_id: operationID, cancelled: false, native_tokens_prompt: 10, native_tokens_completion: 100, total_cost: 0.000905, finish_reason: 'stop' } }));
      } });
    const request = speechRequest({ segments: [{ text: 'Hello', speaker: 'explainer', style: 'clear' }, { text: 'Why?', speaker: 'skeptic', style: 'curious' }] },
      { explainer: 'Kore', skeptic: 'Puck' }, 16384);
    const result = await speech.generate(request, signal(), { accountID, operationID, attemptID, feature: 'podcast_speech', caller: 'podcast',
      dispatch: async () => true, receipt: async metadata => { receipts++; assert.equal(metadata.generation_id, 'gen-speech'); return true; } });
    assert.equal(posts, 1); assert.equal(sent.provider.zdr, true); assert.equal(sent.provider.data_collection, 'deny'); assert.equal(sent.response_format, 'pcm');
    assert.equal(sent.provider.options['google-vertex'].responseFormat.audio.sampleRate, 24000);
    assert.deepEqual(sent.input.map((x: any) => x.voice), ['Kore', 'Puck']); assert.equal(sent.user, accountID);
    assert.equal(result.state, missing ? 'unknown' : 'succeeded'); assert.equal(receipts, missing ? 0 : 1);
    if (!missing) { assert.equal(result.billedMicrousd, 905); assert.equal(result.finishReason, 'STOP'); }
  }
});

test('speech refuses a changed eligible endpoint, tariff or serving cap before dispatch', async () => {
  for (const route of [{ ...speechRoute, tag: 'unreviewed' }, { ...speechRoute, max_completion_tokens: 32768 },
    { ...speechRoute, pricing: { prompt: '0.000002', completion: '0.000009' } }]) {
    let dispatched = false;
    const provider = openRouterSpeechProvider({ apiKey: 'fixture', fetch: async (url, init) => {
      assert.equal(init?.method, undefined); assert.match(String(url), /endpoints\/zdr$/); return Response.json({ data: [route] });
    } });
    const result = await provider.generate(speechRequest({ segments: [{ text: 'Hello', speaker: 'explainer', style: 'clear' }] },
      { explainer: 'Kore', skeptic: 'Puck' }, 16384), signal(), { accountID, operationID, attemptID, feature: 'podcast_speech', caller: 'podcast',
      dispatch: async () => { dispatched = true; return true; } });
    assert.equal(result.state, 'rejected'); assert.equal(dispatched, false);
  }
});

test('speech reconciles a delayed dated-model receipt without purchasing another generation', async () => {
  for (const wrongAccount of [false, true]) {
    let posts = 0, gets = 0, stored = 0;
    const provider = openRouterSpeechProvider({ apiKey: 'fixture', fetch: async (url, init) => {
      if (String(url).endsWith('/endpoints/zdr')) return Response.json({ data: [speechRoute] });
      if (init?.method === 'POST') { posts++;
        return new Response(new Uint8Array([0, 0, 255, 127]), { headers: { 'x-generation-id': 'gen-late', 'content-type': 'audio/pcm' } }); }
      if (++gets === 1) return new Response(null, { status: 404 });
      return Response.json({ data: { id: 'gen-late', model: 'google/gemini-3.8-flash-tts-20260922',
        provider_name: 'Google', external_user: wrongAccount ? operationID : accountID, session_id: operationID,
        cancelled: false, finish_reason: null, native_tokens_prompt: 10, native_tokens_completion: 100, total_cost: 0.000905 } });
    } });
    const result = await provider.generate(speechRequest({ segments: [{ text: 'Hello', speaker: 'explainer', style: 'clear' }] },
      { explainer: 'Kore', skeptic: 'Puck' }, 16384), signal(), { accountID, operationID, attemptID, feature: 'podcast_speech', caller: 'podcast',
      dispatch: async () => true, receipt: async metadata => {
        stored++; assert.equal(metadata.model, speechRoute.model_id);
        assert.equal(metadata.resolved_model, 'google/gemini-3.8-flash-tts-20260922'); return true;
      } });
    assert.equal(posts, 1); assert.equal(gets, 2); assert.equal(stored, wrongAccount ? 0 : 1);
    assert.equal(result.state, wrongAccount ? 'unknown' : 'succeeded');
    if (!wrongAccount) { assert.equal(result.finishReason, 'STOP'); assert.equal(result.billedMicrousd, 905); assert.ok(result.audio); }
  }
});

test('speech PCM normalization preserves samples and rejects truncated or excessive audio', () => {
  const wav = normalizeOpenRouterSpeech(new Uint8Array([0, 0, 255, 127, 0, 128]));
  const pcm = parseWav(wav);
  assert.equal(pcm.durationMs, 0); // Three samples round down to zero milliseconds.
  assert.deepEqual(wav.subarray(wav.length - 6), new Uint8Array([0, 0, 255, 127, 0, 128]));
  assert.deepEqual(normalizeOpenRouterSpeech(wav), wav);
  for (const bytes of [new Uint8Array(), new Uint8Array([1]), new Uint8Array(656 * 24000 * 2 + 2), new TextEncoder().encode('RIFFbad')])
    assert.throws(() => normalizeOpenRouterSpeech(bytes));
});
