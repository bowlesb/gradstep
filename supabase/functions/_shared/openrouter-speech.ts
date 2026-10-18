// OpenRouter TTS has no provider pin. Require ZDR + no collection; store the actual endpoint from its receipt.
// Gemini rejects MP3 on this endpoint. Explicitly request 24 kHz mono signed 16-bit PCM, then validate/wrap WAV.
import { openRouterPost, OpenRouterNotDispatched } from './openrouter-transport.ts';
import { SPEECH_MODEL, MAX_SPEECH_RESPONSE_BYTES, parseWav, wavBytes, type SpeechProvider } from './podcast-speech.ts';
const MODEL = `google/${SPEECH_MODEL}`;
const obj = (v: unknown): Record<string, any> => v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, any> : {};
const count = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0 ? v as number : null;

// Speech ignores endpoint pins and output caps. Check every currently eligible ZDR endpoint before buying
// audio: a newly added endpoint or changed serving limit must not silently invalidate the reserved ceiling.
async function eligibleSpeechProviders(fetcher: typeof fetch, signal: AbortSignal): Promise<{ providers: Set<string>; models: Set<string> }> {
  const response = await fetcher('https://openrouter.ai/api/v1/endpoints/zdr', { signal, redirect: 'error' });
  if (!response.ok) { await response.body?.cancel(); throw new Error('speech_routes_unavailable'); }
  const raw = await response.text();
  if (raw.length > 4_194_304) throw new Error('speech_routes_invalid');
  const data = obj(JSON.parse(raw)).data;
  if (!Array.isArray(data)) throw new Error('speech_routes_invalid');
  const routes = data.filter(r => r.model_id === MODEL);
  if (!routes.length || routes.some(r => !['google-vertex/global', 'google-ai-studio'].includes(r.tag)
    || !['Google', 'Google Vertex', 'Google Vertex AI', 'Google AI Studio'].includes(r.provider_name)
    || !Number.isFinite(Number(r.pricing?.prompt)) || Number(r.pricing.prompt) < 0 || Number(r.pricing.prompt) > 0.000001
    || !Number.isFinite(Number(r.pricing?.completion)) || Number(r.pricing.completion) < 0 || Number(r.pricing.completion) > 0.000018
    || !Number.isSafeInteger(r.max_completion_tokens) || r.max_completion_tokens <= 0 || r.max_completion_tokens > 16_384))
    throw new Error('speech_routes_changed');
  return { providers: new Set(routes.map(r => r.provider_name)),
    models: new Set([MODEL, ...routes.map(r => String(r.name).split(' | ')[1]).filter(m => new RegExp(`^${MODEL.replaceAll('.', '\\.')}-[0-9]{8}$`).test(m))]) };
}

export function normalizeOpenRouterSpeech(bytes: Uint8Array): Uint8Array {
  if (new TextDecoder().decode(bytes.subarray(0, 4)) === 'RIFF') {
    const pcm = parseWav(bytes);
    if (pcm.durationMs > 656000) throw new Error('audio_duration_invalid');
    return bytes;
  }
  if (!bytes.length || bytes.length % 2 || bytes.length > 656 * 24000 * 2) throw new Error('audio_pcm_invalid');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), samples = new Int16Array(bytes.length / 2);
  for (let i = 0; i < samples.length; i++) samples[i] = view.getInt16(i * 2, true);
  return wavBytes(samples);
}

export function openRouterSpeechProvider(options: { apiKey: string; fetch?: typeof fetch }): SpeechProvider {
  return { async generate(request, signal, attribution) {
    let requestID: string | null = null;
    const failed = (state: 'unknown' | 'rejected', failure: string) => ({ state, requestID, model: SPEECH_MODEL,
      finishReason: null, audio: null, mimeType: null, usage: null, failure });
    if (Date.now() >= Date.parse('2027-01-01T00:00:00Z')) return failed('rejected', 'tariff_expired');
    const config = obj(obj(request.body.generationConfig).speechConfig).multiSpeakerVoiceConfig;
    const voices = new Map((obj(config).speakerVoiceConfigs ?? []).map((v: any) => [v.speaker, v.voiceConfig?.voice]));
    const parts = obj((request.body.contents as unknown[])?.[0]).parts;
    if (!Array.isArray(parts) || !parts.length) return failed('rejected', 'speech_input_invalid');
    const input = parts.map(raw => { const p = obj(raw), metadata = obj(p.speechMetadata);
      return { text: p.text, voice: voices.get(metadata.speaker), instructions: metadata.style }; });
    if (input.some(p => typeof p.text !== 'string' || typeof p.voice !== 'string')) return failed('rejected', 'speech_input_invalid');
    let eligible: Awaited<ReturnType<typeof eligibleSpeechProviders>>;
    try { eligible = await eligibleSpeechProviders(options.fetch ?? fetch, signal); }
    catch { return failed('rejected', 'speech_routes_unavailable'); }
    try {
      const format = { responseFormat: { audio: { mimeType: 'audio/l16', sampleRate: 24000 } } };
      const response = await openRouterPost(options, 'audio/speech', { model: MODEL, input, response_format: 'pcm',
        provider: { zdr: true, data_collection: 'deny', options: { 'google-vertex': format, 'google-ai-studio': format } } }, signal, attribution);
      requestID = response.headers.get('x-generation-id');
      if (!response.ok) { await response.body?.cancel();
        return failed([400, 401, 402, 403, 404, 413, 422, 429].includes(response.status) ? 'rejected' : 'unknown', `http_${response.status}`); }
      const reader = response.body?.getReader(), chunks: Uint8Array[] = [];
      let size = 0;
      if (!reader) return failed('unknown', 'audio_missing');
      try { for (;;) { const { value, done } = await reader.read(); if (done) break;
        size += value.byteLength; if (size > MAX_SPEECH_RESPONSE_BYTES) throw new Error('audio_limit'); chunks.push(value); }
      } finally { await reader.cancel().catch(() => {}); }
      if (!requestID || !/^[a-zA-Z0-9._:-]{1,256}$/.test(requestID)) return failed('unknown', 'usage_missing');
      // Receipt GETs cannot buy another generation. A missing/late receipt leaves the full admitted liability.
      let receipt: Record<string, any> = {};
      for (let n = 0; n < 8; n++) {
        if (n) await new Promise<void>((resolve, reject) => {
          const stop = () => { clearTimeout(timer); reject(new Error('deadline')); };
          const timer = setTimeout(() => { signal.removeEventListener('abort', stop); resolve(); }, Math.min(4000, 250 * 2 ** (n - 1)));
          signal.addEventListener('abort', stop, { once: true });
          if (signal.aborted) stop();
        });
        const r = await (options.fetch ?? fetch)(`https://openrouter.ai/api/v1/generation?id=${encodeURIComponent(requestID)}`,
          { signal, redirect: 'error', headers: { authorization: `Bearer ${options.apiKey}`, 'X-Session-ID': attribution!.operationID } });
        if (r.ok) { const raw = await r.text(); if (raw.length <= 65_536) receipt = obj(obj(JSON.parse(raw)).data); break; }
        await r.body?.cancel();
        if (r.status !== 404) break;
      }
      const tin = count(receipt.native_tokens_prompt), tout = count(receipt.native_tokens_completion);
      if (receipt.id !== requestID || !eligible.models.has(receipt.model) || !eligible.providers.has(receipt.provider_name)
        || receipt.external_user !== attribution!.accountID || receipt.session_id !== attribution!.operationID
        || typeof receipt.total_cost !== 'number' || !Number.isFinite(receipt.total_cost) || receipt.total_cost < 0 || receipt.total_cost > 30
        || tin === null || tout === null) return failed('unknown', 'usage_missing');
      const billedMicrousd = Math.ceil(receipt.total_cost * 1_000_000);
      if (!await attribution?.receipt?.({ generation_id: requestID, model: MODEL, resolved_model: receipt.model, provider: receipt.provider_name,
        total_cost_microusd: billedMicrousd })) return failed('unknown', 'receipt_unrecorded');
      const base = { state: 'succeeded' as const, requestID, model: SPEECH_MODEL, billedMicrousd,
        usage: { text_input_tokens: tin, audio_output_tokens: tout }, failure: null };
      if (!size || !['audio/pcm', 'audio/l16', 'audio/wav'].includes(response.headers.get('content-type')?.split(';')[0].toLowerCase() ?? '')
        || receipt.cancelled !== false || ![null, 'stop'].includes(receipt.finish_reason))
        return { ...base, finishReason: 'INCOMPLETE', audio: null, mimeType: null };
      const bytes = new Uint8Array(size); let at = 0; for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
      try { return { ...base, finishReason: 'STOP', audio: normalizeOpenRouterSpeech(bytes), mimeType: 'audio/wav' }; }
      catch { return { ...base, finishReason: 'INVALID_AUDIO', audio: null, mimeType: null }; }
    } catch (error) { return failed(error instanceof OpenRouterNotDispatched ? 'rejected' : 'unknown',
      error instanceof OpenRouterNotDispatched ? 'attribution_unavailable' : signal.aborted ? 'deadline' : 'transport_unknown'); }
  } };
}
