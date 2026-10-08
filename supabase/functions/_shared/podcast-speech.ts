// Two-voice speech through Gemini 3.8 Flash TTS on Vertex AI (global endpoint),
// plus WAV validation and approximate transcript timing. No API keys: the worker
// impersonates a dedicated service account for a five-minute token. Logs carry
// ids and counts only — never transcript text, audio or tokens.
import type { CheckedScript } from './podcast-script.ts';

export const SPEECH_MODEL = 'gemini-3.8-flash-tts';
export const VERTEX_LOCATION = 'global';
export const SAMPLE_RATE = 24_000;
/** Speaker labels are request metadata only (speechMetadata), never read aloud. */
export const SPEECH_SPEAKERS = { explainer: 'Explainer', skeptic: 'Skeptic' } as const;
/** Largest base64 JSON response accepted: 16,384 audio tokens at 25/s is 655 s of 24 kHz mono PCM (~31 MB). */
export const MAX_SPEECH_RESPONSE_BYTES = 48 * 1024 * 1024;

export interface SpeechVoices { explainer: string; skeptic: string }
export interface SpeechRequest { body: Record<string, unknown>; bytes: number }

/** A provable input bound: request text and metadata bytes, plus fixed framing allowance. */
export function speechRequest(script: CheckedScript, voices: SpeechVoices, maxOutputTokens: number): SpeechRequest {
  const parts = script.segments.map(s => ({ text: s.text, speechMetadata: { speaker: SPEECH_SPEAKERS[s.speaker], style: s.style || 'clear, conversational' } }));
  const body = {
    contents: [{ role: 'user', parts }],
    generationConfig: {
      responseModalities: ['AUDIO'], maxOutputTokens,
      speechConfig: { multiSpeakerVoiceConfig: { speakerVoiceConfigs: [
        { speaker: SPEECH_SPEAKERS.explainer, voiceConfig: { voice: voices.explainer } },
        { speaker: SPEECH_SPEAKERS.skeptic, voiceConfig: { voice: voices.skeptic } }] } },
    },
  };
  return { body, bytes: new TextEncoder().encode(JSON.stringify(parts)).byteLength + 256 };
}

export interface SpeechResult {
  state: 'succeeded' | 'rejected' | 'unknown';
  requestID: string | null; model: string | null; finishReason: string | null;
  audio: Uint8Array | null; mimeType: string | null;
  usage: { text_input_tokens: number; audio_output_tokens: number } | null;
  failure: string | null;
}
export interface SpeechProvider { generate(request: SpeechRequest, signal: AbortSignal): Promise<SpeechResult> }

/** List-price cost (January 2027 rates, even during the 50% promotional credit): reconciled later from invoices. */
export function speechCost(usage: { text_input_tokens: number; audio_output_tokens: number }, rates: { text_input: number; audio_output: number }): number {
  return Math.ceil(usage.text_input_tokens * rates.text_input + usage.audio_output_tokens * rates.audio_output);
}

export type TokenSource = (signal: AbortSignal) => Promise<string>;

/**
 * Short-lived access token for a dedicated speech service account. The worker's
 * own Cloud Run identity (metadata server) must hold
 * roles/iam.serviceAccountTokenCreator on that account and nothing broader.
 */
export function impersonatedTokenSource(serviceAccount: string, fetcher: typeof fetch = fetch): TokenSource {
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$/.test(serviceAccount)) throw new Error('speech_account_invalid');
  let cached: { token: string; expires: number } | null = null;
  return async signal => {
    if (cached && cached.expires - Date.now() > 60_000) return cached.token;
    const own = await fetcher('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
      { headers: { 'Metadata-Flavor': 'Google' }, redirect: 'error', signal });
    if (own.status !== 200) { await own.body?.cancel(); throw new Error('speech_identity_unavailable'); }
    const ownToken = (await own.json() as { access_token?: unknown }).access_token;
    if (typeof ownToken !== 'string' || ownToken.length < 20) throw new Error('speech_identity_unavailable');
    const minted = await fetcher(`https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${encodeURIComponent(serviceAccount)}:generateAccessToken`, {
      method: 'POST', redirect: 'error', signal,
      headers: { Authorization: `Bearer ${ownToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ scope: ['https://www.googleapis.com/auth/cloud-platform'], lifetime: '300s' }) });
    if (minted.status !== 200) { await minted.body?.cancel(); throw new Error('speech_identity_unavailable'); }
    const value = await minted.json() as { accessToken?: unknown; expireTime?: unknown };
    if (typeof value.accessToken !== 'string' || typeof value.expireTime !== 'string') throw new Error('speech_identity_unavailable');
    cached = { token: value.accessToken, expires: Date.parse(value.expireTime) || Date.now() + 240_000 };
    return cached.token;
  };
}

async function boundedJSON(response: Response, maximum: number): Promise<unknown> {
  const declared = response.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) { await response.body?.cancel(); throw new Error('speech_response_too_large'); }
  if (!response.body) throw new Error('speech_response_empty');
  const reader = response.body.getReader(), parts: Uint8Array[] = []; let size = 0;
  while (true) {
    const next = await reader.read(); if (next.done) break;
    size += next.value.byteLength;
    if (size > maximum) { await reader.cancel(); throw new Error('speech_response_too_large'); }
    parts.push(next.value);
  }
  const joined = new Uint8Array(size); let offset = 0;
  for (const part of parts) { joined.set(part, offset); offset += part.byteLength; }
  return JSON.parse(new TextDecoder().decode(joined));
}

function base64Bytes(value: string): Uint8Array {
  const scope = globalThis as { Buffer?: { from(v: string, e: string): Uint8Array } };
  if (scope.Buffer) return new Uint8Array(scope.Buffer.from(value, 'base64'));
  const binary = atob(value); const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** One generateContent POST per granted attempt; no client retries. */
export function vertexSpeechProvider(options: { project: string; tokens: TokenSource; fetch?: typeof fetch; timeoutMs?: number }): SpeechProvider {
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(options.project)) throw new Error('speech_project_invalid');
  const fetcher = options.fetch ?? fetch;
  const url = `https://aiplatform.googleapis.com/v1/projects/${options.project}/locations/${VERTEX_LOCATION}/publishers/google/models/${SPEECH_MODEL}:generateContent`;
  return {
    async generate(request, signal) {
      let token: string;
      // No request has been sent yet: failing to mint a token is a rejection with zero usage.
      try { token = await options.tokens(signal); }
      catch { return { state: 'rejected', requestID: null, model: null, finishReason: null, audio: null, mimeType: null, usage: null, failure: 'speech_identity_unavailable' }; }
      const deadline = AbortSignal.any([signal, AbortSignal.timeout(options.timeoutMs ?? 300_000)]);
      let response: Response;
      try {
        response = await fetcher(url, { method: 'POST', redirect: 'error', signal: deadline,
          headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(request.body) });
      } catch {
        return { state: 'unknown', requestID: null, model: null, finishReason: null, audio: null, mimeType: null, usage: null, failure: 'transport_unknown' };
      }
      const requestID = response.headers.get('x-goog-request-id') ?? null;
      // Google does not bill requests failing with a client error; a 5xx or a lost
      // body keeps the whole ceiling until reconciled from billing evidence.
      if (response.status >= 400 && response.status < 500 && response.status !== 408) {
        await response.body?.cancel();
        return { state: 'rejected', requestID, model: null, finishReason: null, audio: null, mimeType: null, usage: null, failure: `http_${response.status}` };
      }
      if (response.status !== 200) {
        await response.body?.cancel();
        return { state: 'unknown', requestID, model: null, finishReason: null, audio: null, mimeType: null, usage: null, failure: `http_${response.status}` };
      }
      let value: Record<string, unknown>;
      try { value = await boundedJSON(response, MAX_SPEECH_RESPONSE_BYTES) as Record<string, unknown>; }
      catch { return { state: 'unknown', requestID, model: null, finishReason: null, audio: null, mimeType: null, usage: null, failure: 'response_unreadable' }; }
      const candidate = (value.candidates as Record<string, unknown>[] | undefined)?.[0];
      const part = ((candidate?.content as Record<string, unknown> | undefined)?.parts as Record<string, unknown>[] | undefined)?.[0];
      const inline = part?.inlineData as { mimeType?: unknown; data?: unknown } | undefined;
      const usage = value.usageMetadata as Record<string, unknown> | undefined;
      const audioTokens = (usage?.candidatesTokensDetails as { modality?: unknown; tokenCount?: unknown }[] | undefined)
        ?.filter(d => d.modality === 'AUDIO').reduce((sum, d) => sum + (Number.isSafeInteger(d.tokenCount) ? d.tokenCount as number : 0), 0)
        ?? (Number.isSafeInteger(usage?.candidatesTokenCount) ? usage!.candidatesTokenCount as number : null);
      const textTokens = Number.isSafeInteger(usage?.promptTokenCount) ? usage!.promptTokenCount as number : null;
      const id = typeof value.responseId === 'string' && /^[A-Za-z0-9._:/-]{1,200}$/.test(value.responseId) ? value.responseId : requestID;
      const model = typeof value.modelVersion === 'string' ? value.modelVersion.slice(0, 128) : null;
      const audio = typeof inline?.data === 'string' ? base64Bytes(inline.data) : null;
      if (textTokens === null || audioTokens === null || !audioTokens) {
        // Paid response without usage: keep the full liability; never infer usage.
        return { state: 'unknown', requestID: id, model, finishReason: typeof candidate?.finishReason === 'string' ? candidate.finishReason : null,
          audio, mimeType: typeof inline?.mimeType === 'string' ? inline.mimeType : null, usage: null, failure: 'usage_missing' };
      }
      return { state: 'succeeded', requestID: id, model, finishReason: typeof candidate?.finishReason === 'string' ? candidate.finishReason : null,
        audio, mimeType: typeof inline?.mimeType === 'string' ? inline.mimeType : null,
        usage: { text_input_tokens: textTokens, audio_output_tokens: audioTokens }, failure: null };
    },
  };
}

// ----------------------------------------------------------------------------
// WAV validation and timing
// ----------------------------------------------------------------------------
export interface Pcm { samples: Int16Array; sampleRate: number; durationMs: number }

/** 16-bit PCM mono 24 kHz RIFF/WAVE with a complete data chunk; anything else is refused. */
export function parseWav(bytes: Uint8Array): Pcm {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset: number) => String.fromCharCode(...bytes.subarray(offset, offset + 4));
  if (bytes.byteLength < 44 || tag(0) !== 'RIFF' || tag(8) !== 'WAVE') throw new Error('audio_container_invalid');
  let offset = 12, format: { channels: number; rate: number; bits: number; codec: number } | null = null, data: Uint8Array | null = null;
  while (offset + 8 <= bytes.byteLength) {
    const id = tag(offset), size = view.getUint32(offset + 4, true), body = offset + 8;
    if (id === 'fmt ') {
      if (size < 16) throw new Error('audio_container_invalid');
      format = { codec: view.getUint16(body, true), channels: view.getUint16(body + 2, true), rate: view.getUint32(body + 4, true), bits: view.getUint16(body + 14, true) };
    } else if (id === 'data') {
      // Some encoders write 0xFFFFFFFF for streamed sizes; only an exact, complete chunk is accepted.
      if (body + size > bytes.byteLength) throw new Error('audio_truncated');
      data = bytes.subarray(body, body + size);
      break;
    }
    offset = body + size + (size % 2);
  }
  if (!format || !data) throw new Error('audio_container_invalid');
  if (format.codec !== 1 || format.channels !== 1 || format.rate !== SAMPLE_RATE || format.bits !== 16 || data.byteLength % 2) throw new Error('audio_format_invalid');
  const samples = new Int16Array(data.byteLength / 2);
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  for (let i = 0; i < samples.length; i++) samples[i] = dv.getInt16(i * 2, true);
  return { samples, sampleRate: format.rate, durationMs: Math.round(samples.length * 1000 / format.rate) };
}

export function wavBytes(samples: Int16Array, sampleRate = SAMPLE_RATE): Uint8Array {
  const out = new Uint8Array(44 + samples.length * 2), view = new DataView(out.buffer);
  const put = (offset: number, text: string) => { for (let i = 0; i < 4; i++) out[offset + i] = text.charCodeAt(i); };
  put(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); put(8, 'WAVE'); put(12, 'fmt ');
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); put(36, 'data');
  view.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) view.setInt16(44 + i * 2, samples[i], true);
  return out;
}

function frameRms(samples: Int16Array, rate: number, frameMs: number): Float64Array {
  const size = Math.max(1, Math.round(rate * frameMs / 1000)), frames = new Float64Array(Math.ceil(samples.length / size));
  for (let f = 0; f < frames.length; f++) {
    let sum = 0, n = 0;
    for (let i = f * size; i < Math.min(samples.length, (f + 1) * size); i++) { sum += samples[i] * samples[i]; n++; }
    frames[f] = n ? Math.sqrt(sum / n) : 0;
  }
  return frames;
}

/** Duration bounds, non-silent audio and no long dead air. The model's limit is not proof of a natural ending. */
export function verifyAudio(pcm: Pcm, bounds: { minMs: number; maxMs: number }): string | null {
  if (pcm.durationMs < bounds.minMs) return 'audio_too_short';
  if (pcm.durationMs > bounds.maxMs) return 'audio_too_long';
  const frames = frameRms(pcm.samples, pcm.sampleRate, 100);
  const overall = Math.sqrt(frames.reduce((sum, v) => sum + v * v, 0) / Math.max(1, frames.length));
  if (overall < 150) return 'audio_silent';
  let quiet = 0;
  for (const v of frames) { quiet = v < 40 ? quiet + 1 : 0; if (quiet > 80) return 'audio_dead_air'; }
  return null;
}

export interface Timing { start_ms: number; end_ms: number }
/**
 * Approximate segment timing for one multi-speaker take: proportional to text
 * length, each boundary snapped to the quietest 100 ms within ±2.5 s. Clients
 * label it approximate; it is a seek aid, not a word alignment.
 */
export function alignSegments(texts: string[], pcm: Pcm): Timing[] {
  const total = texts.reduce((sum, t) => sum + Math.max(1, t.length), 0);
  const frames = frameRms(pcm.samples, pcm.sampleRate, 20);
  const frameMs = 20, boundaries: number[] = [0];
  let cumulative = 0;
  for (let i = 0; i < texts.length - 1; i++) {
    cumulative += Math.max(1, texts[i].length);
    const estimate = pcm.durationMs * cumulative / total;
    let best = estimate, bestEnergy = Infinity;
    const lo = Math.max(boundaries[boundaries.length - 1] + 200, estimate - 2500), hi = Math.min(pcm.durationMs - 200, estimate + 2500);
    for (let t = lo; t <= hi; t += frameMs) {
      let energy = 0;
      for (let k = 0; k < 5; k++) energy += frames[Math.min(frames.length - 1, Math.floor(t / frameMs) + k - 2)] ?? 0;
      if (energy < bestEnergy - 1e-9) { bestEnergy = energy; best = t; }
    }
    boundaries.push(Math.round(Math.max(boundaries[boundaries.length - 1], Math.min(best, pcm.durationMs))));
  }
  boundaries.push(pcm.durationMs);
  return texts.map((_, i) => ({ start_ms: boundaries[i], end_ms: Math.max(boundaries[i], boundaries[i + 1]) }));
}

/** Labeled synthetic fixture audio: two tones for the two hosts, separated by silence. Zero spend. */
export function fixtureAudio(script: CheckedScript): Uint8Array {
  const rate = SAMPLE_RATE, pieces: Int16Array[] = [];
  for (const s of script.segments) {
    const seconds = Math.min(8, Math.max(1.2, s.text.length * 0.05)), n = Math.round(rate * seconds);
    const tone = new Int16Array(n), hz = s.speaker === 'explainer' ? 220 : 330;
    for (let i = 0; i < n; i++) {
      const envelope = Math.min(1, i / (rate * 0.05), (n - i) / (rate * 0.05));
      tone[i] = Math.round(Math.sin(2 * Math.PI * hz * i / rate) * 6000 * envelope * (0.85 + 0.15 * Math.sin(2 * Math.PI * 3 * i / rate)));
    }
    pieces.push(tone, new Int16Array(Math.round(rate * 0.35)));
  }
  const length = pieces.reduce((sum, p) => sum + p.length, 0), all = new Int16Array(length);
  let offset = 0; for (const p of pieces) { all.set(p, offset); offset += p.length; }
  return wavBytes(all, rate);
}
