// Two-voice speech through Gemini 3.8 Flash TTS on Vertex AI (global endpoint),
// plus WAV validation and approximate transcript timing. No API keys: the worker
// impersonates a dedicated service account for a five-minute token. Logs carry
// ids and counts only — never transcript text, audio or tokens.
import type { CheckedScript, CheckedSegment } from './podcast-script.ts';
import type { OpenRouterAttribution } from './openrouter-transport.ts';

export const SPEECH_MODEL = 'gemini-3.8-flash-tts';
export const SAMPLE_RATE = 24_000;
/** Speaker labels are request metadata only (speechMetadata), never read aloud. */
export const SPEECH_SPEAKERS = { explainer: 'Explainer', skeptic: 'Skeptic' } as const;
/** Largest base64 JSON response accepted: 16,384 audio tokens at 25/s is 655 s of 24 kHz mono PCM (~31 MB). */
export const MAX_SPEECH_RESPONSE_BYTES = 48 * 1024 * 1024;

export interface SpeechVoices { explainer: string; skeptic: string }
/** `audioTokens` is the granted output allowance. It is never sent: Vertex's gemini-3.8-flash-tts refuses
 * `maxOutputTokens` (400 INVALID_ARGUMENT, probed 2026-10-09), so a call is bounded only by the serving limit and
 * every grant must cover it (SPEECH_SERVING_MAX_OUTPUT). */
export interface SpeechRequest { body: Record<string, unknown>; bytes: number; audioTokens: number }
/** The provider's own per-call output limit: what a call can actually produce with no cap sent. */
export const SPEECH_SERVING_MAX_OUTPUT = 16_384;

type SpokenSegment = Pick<CheckedSegment, 'text' | 'speaker' | 'style'>;
const speechPart = (s: SpokenSegment) => ({ text: s.text, speechMetadata: { speaker: SPEECH_SPEAKERS[s.speaker], style: s.style || 'clear, conversational' } });

/** A provable input bound: request text and metadata bytes, plus fixed framing allowance. */
export function speechRequest(script: { segments: SpokenSegment[] }, voices: SpeechVoices, audioTokens: number): SpeechRequest {
  const parts = script.segments.map(speechPart);
  const body = {
    contents: [{ role: 'user', parts }],
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: { multiSpeakerVoiceConfig: { speakerVoiceConfigs: [
        { speaker: SPEECH_SPEAKERS.explainer, voiceConfig: { voice: voices.explainer } },
        { speaker: SPEECH_SPEAKERS.skeptic, voiceConfig: { voice: voices.skeptic } }] } },
    },
  };
  return { body, bytes: new TextEncoder().encode(JSON.stringify(parts)).byteLength + 256, audioTokens };
}

// ----------------------------------------------------------------------------
// Chunked speech: a script longer than one call holds is split between segments
// (preferably where a chapter starts, else where the speaker changes), each chunk
// within the per-call input limit, and the profile's audio budget is shared out
// in proportion to each chunk's words. A plan that needs more calls than the
// profile allows is refused before any speech is bought.
// ----------------------------------------------------------------------------
export interface SpeechLimits {
  /** Per-call input cap (request bytes, a provable token bound). */ maxInputTokens: number;
  maxCalls: number; /** Per-call output cap. */ perCallOutputTokens: number; /** Profile total. */ maxAudioTokens: number;
  /** When the provider ignores an output cap, every paid chunk must reserve this serving limit. */ servingOutputLimit?: number;
}
export interface SpeechChunk { start: number; end: number; bytes: number; words: number; audioTokens: number }
/** Slowest pace a chunk's audio allowance must cover: 120 words a minute at 25 audio tokens a second. */
export const AUDIO_TOKENS_PER_WORD = 12.5;

export function planSpeechChunks(segments: (SpokenSegment & { chapter: string })[], limits: SpeechLimits): SpeechChunk[] | null {
  const n = segments.length;
  if (!n || limits.maxCalls < 1) return null;
  const encoder = new TextEncoder();
  const bytes = segments.map(s => encoder.encode(JSON.stringify(speechPart(s))).byteLength);
  const words = segments.map(s => s.text.split(/\s+/).filter(Boolean).length);
  // speechRequest's bound: the JSON array ("[" parts joined by "," "]") plus 256.
  const size = (a: number, b: number) => { let t = 2 + (b - a - 1) + 256; for (let i = a; i < b; i++) t += bytes[i]; return t; };
  if (bytes.some(b => b + 2 + 256 > limits.maxInputTokens)) return null;
  let k = 1;
  for (let a = 0, i = 0; i < n; i++) if (size(a, i + 1) > limits.maxInputTokens) { k++; a = i; }
  if (k > limits.maxCalls) return null;
  // Exactly k chunks, chosen to land on natural pauses and keep chunks similar in length.
  const total = words.reduce((x, y) => x + y, 0), ideal = Math.max(1, total / k);
  const span = (a: number, b: number) => { let t = 0; for (let i = a; i < b; i++) t += words[i]; return t; };
  const seam = (i: number) => segments[i].chapter !== segments[i - 1].chapter ? 0 : segments[i].speaker !== segments[i - 1].speaker ? 1 : 3;
  const cost: number[][] = Array.from({ length: k + 1 }, () => new Array(n + 1).fill(Infinity));
  const from: number[][] = Array.from({ length: k + 1 }, () => new Array(n + 1).fill(-1));
  cost[0][0] = 0;
  for (let j = 1; j <= k; j++) {
    for (let b = j; b <= n; b++) {
      for (let a = j - 1; a < b; a++) {
        if (!Number.isFinite(cost[j - 1][a]) || size(a, b) > limits.maxInputTokens) continue;
        const balance = 4 * ((span(a, b) - ideal) / ideal) ** 2;
        const c = cost[j - 1][a] + (a > 0 ? seam(a) : 0) + balance;
        if (c < cost[j][b]) { cost[j][b] = c; from[j][b] = a; }
      }
    }
  }
  if (!Number.isFinite(cost[k][n])) return null;
  const bounds: [number, number][] = [];
  for (let j = k, b = n; j > 0; j--) { const a = from[j][b]; bounds.unshift([a, b]); b = a; }
  const chunks = bounds.map(([a, b]) => {
    const w = span(a, b);
    const proportional = Math.min(limits.perCallOutputTokens, Math.floor(limits.maxAudioTokens * (total ? w / total : 1 / k)));
    // Vertex Gemini TTS currently rejects maxOutputTokens, so a proportional grant
    // below its serving limit could be overrun. Versioned production profiles opt into
    // a full serving grant per chunk; the proportional path remains for old fixtures
    // and callers that use a provider with a real output cap.
    const audioTokens = limits.servingOutputLimit === undefined ? proportional : limits.servingOutputLimit;
    return { start: a, end: b, bytes: size(a, b), words: w, audioTokens };
  });
  if (limits.servingOutputLimit !== undefined && (limits.perCallOutputTokens < limits.servingOutputLimit
    || chunks.length * limits.servingOutputLimit > limits.maxAudioTokens)) return null;
  // Every chunk must be able to finish at a slow pace; otherwise refuse rather than buy a cut-off take.
  if (chunks.some(c => c.audioTokens < Math.ceil(c.words * AUDIO_TOKENS_PER_WORD))) return null;
  return chunks;
}

// ----------------------------------------------------------------------------
// Fitting a checked script into its speech calls. Every call is bounded by request
// bytes (spoken text plus per-segment speaker/style metadata plus 258 bytes of
// framing), a provable bound on input tokens. The script prompt states a spoken-
// character limit derived from the same arithmetic; here, before anything is
// bought, an over-budget script first has its delivery directions shortened
// (metadata only, never a spoken word) and fails only when even that cannot fit.
// ----------------------------------------------------------------------------
/** Delivery directions the prompt asks for (at most three words) and the shortest kept when space is needed. */
export const STYLE_MAX_CHARS = 24, STYLE_MIN_CHARS = 12;
/** speechRequest's fixed allowance plus the JSON array brackets. */
const REQUEST_FRAMING_BYTES = 258;
/** Bytes one part adds beyond its text and style: the JSON keys, the longer speaker label and one separator. */
export const PART_OVERHEAD_BYTES = new TextEncoder().encode(JSON.stringify(speechPart({ text: '', speaker: 'explainer', style: 'x' }))).byteLength - 'x'.length + 1;

export interface SpeechBudget { maxInputTokens: number; maxCalls: number }
/**
 * Spoken characters a script may use so that `maxSegments` segments with full-length styles fit the
 * profile's speech calls, with a 10% margin for multi-byte characters, JSON escapes and chunk seams.
 */
export function spokenCharacterBudget(budget: SpeechBudget, maxSegments: number): number {
  const room = budget.maxCalls * (budget.maxInputTokens - REQUEST_FRAMING_BYTES) - maxSegments * (PART_OVERHEAD_BYTES + STYLE_MAX_CHARS);
  return Math.max(0, Math.floor(room * 0.9 / 100) * 100);
}

/** A delivery direction cut at a word or comma boundary. */
export function shortStyle(style: string, max: number): string {
  const s = style.replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  const cut = s.slice(0, max + 1);
  const at = Math.max(cut.lastIndexOf(','), cut.lastIndexOf(' '));
  return (at > 0 ? cut.slice(0, at) : s.slice(0, max)).replace(/[\s,;]+$/, '');
}

export interface SpeechFit<T> { segments: T[]; plan: SpeechChunk[] | null; bytes: number; budget: number; stylesShortened: number }
/** The speech plan for a checked script, shortening delivery directions only if that is what it takes to fit. */
export function fitSpeech<T extends SpokenSegment & { chapter: string }>(segments: T[], limits: SpeechLimits): SpeechFit<T> {
  const encoder = new TextEncoder();
  const bytes = (list: T[]) => REQUEST_FRAMING_BYTES + Math.max(0, list.length - 1)
    + list.reduce((n, s) => n + encoder.encode(JSON.stringify(speechPart(s))).byteLength, 0);
  const budget = limits.maxCalls * limits.maxInputTokens;
  let current = segments, shortened = 0;
  for (const max of [Infinity, STYLE_MAX_CHARS, STYLE_MIN_CHARS]) {
    if (max !== Infinity) {
      const next = current.map(s => { const style = shortStyle(s.style, max); return style === s.style ? s : { ...s, style }; });
      shortened = next.filter((s, i) => s.style !== segments[i].style).length;
      current = next;
    }
    const plan = planSpeechChunks(current, limits);
    if (plan) return { segments: current, plan, bytes: bytes(current), budget, stylesShortened: shortened };
  }
  return { segments: current, plan: null, bytes: bytes(current), budget, stylesShortened: shortened };
}

export interface SpeechResult {
  billedMicrousd?: number;
  state: 'succeeded' | 'rejected' | 'unknown';
  requestID: string | null; model: string | null; finishReason: string | null;
  audio: Uint8Array | null; mimeType: string | null;
  usage: { text_input_tokens: number; audio_output_tokens: number } | null;
  failure: string | null;
}
export interface SpeechProvider { generate(request: SpeechRequest, signal: AbortSignal, attribution?: OpenRouterAttribution): Promise<SpeechResult> }

/** List-price cost (January 2027 rates, even during the 50% promotional credit): reconciled later from invoices. */
export function speechCost(usage: { text_input_tokens: number; audio_output_tokens: number }, rates: { text_input: number; audio_output: number }): number {
  return Math.ceil(usage.text_input_tokens * rates.text_input + usage.audio_output_tokens * rates.audio_output);
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

/**
 * Joins chunk takes into one take. A single chunk is returned untouched. Several
 * are trimmed of edge silence (keeping a natural tail), matched in speech level
 * (at most ±6 dB), faded over 12 ms at each seam to avoid clicks and separated by
 * a 450 ms pause, the length of an ordinary turn change. `spans` locate each chunk
 * in the joined audio so its segments' timing and chapters stay exact.
 */
export function joinChunks(chunks: Pcm[], options: { pauseMs?: number; fadeMs?: number } = {}): { pcm: Pcm; parts: Pcm[]; spans: Timing[] } {
  if (chunks.length === 1) return { pcm: chunks[0], parts: chunks, spans: [{ start_ms: 0, end_ms: chunks[0].durationMs }] };
  const rate = SAMPLE_RATE, frameMs = 20, quiet = 60, keep = Math.round(rate * 0.12);
  const pause = Math.round(rate * (options.pauseMs ?? 450) / 1000), fade = Math.round(rate * (options.fadeMs ?? 12) / 1000);
  const trimmed = chunks.map(c => {
    const frames = frameRms(c.samples, rate, frameMs), size = Math.round(rate * frameMs / 1000);
    const first = frames.findIndex(v => v >= quiet), last = frames.length - 1 - [...frames].reverse().findIndex(v => v >= quiet);
    if (first < 0) return c.samples;
    return c.samples.subarray(Math.max(0, first * size - keep), Math.min(c.samples.length, (last + 1) * size + keep));
  });
  const level = trimmed.map(t => {
    const frames = frameRms(t, rate, frameMs).filter(v => v >= quiet);
    return frames.length ? Math.sqrt(frames.reduce((x, v) => x + v * v, 0) / frames.length) : 0;
  });
  const sorted = level.filter(v => v > 0).sort((a, b) => a - b), median = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
  const parts = trimmed.map((t, i) => {
    const gain = level[i] > 0 && median > 0 ? Math.min(2, Math.max(0.5, median / level[i])) : 1;
    const out = new Int16Array(t.length);
    for (let s = 0; s < t.length; s++) {
      const edge = Math.min(1, s / Math.max(1, fade), (t.length - 1 - s) / Math.max(1, fade));
      out[s] = Math.max(-32768, Math.min(32767, Math.round(t[s] * gain * edge)));
    }
    return { samples: out, sampleRate: rate, durationMs: Math.round(out.length * 1000 / rate) };
  });
  const length = parts.reduce((x, p) => x + p.samples.length, 0) + pause * (parts.length - 1);
  const all = new Int16Array(length), spans: Timing[] = [];
  let offset = 0;
  parts.forEach((p, i) => {
    if (i) offset += pause;
    all.set(p.samples, offset);
    spans.push({ start_ms: Math.round(offset * 1000 / rate), end_ms: Math.round((offset + p.samples.length) * 1000 / rate) });
    offset += p.samples.length;
  });
  return { pcm: { samples: all, sampleRate: rate, durationMs: Math.round(all.length * 1000 / rate) }, parts, spans };
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
