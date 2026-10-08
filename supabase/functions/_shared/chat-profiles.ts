// Chat answer profiles (docs/architecture/CHAT.md#models-effort-and-length): the server-versioned table of the
// model, effort and length a reader may choose in a chat, what each choice sends to Anthropic and how its credits
// are estimated. The server accepts only these combinations and freezes the chosen profile in the reservation's
// quote; clients only display the published table. Deno and Node compatible.
import { CHAT_EFFORT, CHAT_MAX_TOKENS, CHAT_MODEL, creditsFor, MICROUSD_PER_CREDIT, RATE_VERSION, ratesFor, TARIFF } from './anthropic.ts';

export const PROFILE_VERSION = 'chat-profiles-v1';
export type ModelChoice = 'haiku' | 'sonnet' | 'opus';
export type EffortChoice = 'low' | 'medium' | 'high';
export type LengthChoice = 'brief' | 'standard' | 'detailed';
export interface Choice { model: ModelChoice; effort: EffortChoice; length: LengthChoice }

interface ModelEntry { id: ModelChoice; label: string; detail: string; apiModel: string; fallbacks: boolean }
interface EffortEntry { id: EffortChoice; label: string; detail: string; thinkingTokens: number }
interface LengthEntry { id: LengthChoice; label: string; detail: string; answerTokens: number; instructions: string | null }

// Model IDs and capabilities checked with GET /v1/models on 2026-10-08: all three take adaptive thinking and
// `output_config.effort` (low/medium/high); Sonnet 5.5 falls back to Sonnet 5, Opus 5.5 to Opus 5 / Opus 4.8,
// Haiku 5.5 has no fallback models. Prices: anthropic.ts (TARIFF).
export const MODELS: readonly ModelEntry[] = Object.freeze([
  { id: 'haiku', label: 'Haiku', detail: 'Fastest and cheapest', apiModel: 'claude-haiku-5-5', fallbacks: false },
  { id: 'sonnet', label: 'Sonnet', detail: 'Strong answers at a moderate cost', apiModel: CHAT_MODEL, fallbacks: true },
  { id: 'opus', label: 'Opus', detail: 'Most capable; costs the most', apiModel: 'claude-opus-5-5', fallbacks: true },
]);
// Effort maps one to one onto the API's `output_config.effort`, with adaptive thinking on every model. The thinking
// allowance is added to the length's answer allowance: max_tokens covers thinking and the answer together.
export const EFFORTS: readonly EffortEntry[] = Object.freeze([
  { id: 'low', label: 'Low', detail: 'Thinks only when needed; quickest', thinkingTokens: 2_000 },
  { id: 'medium', label: 'Medium', detail: 'Thinks through harder questions', thinkingTokens: 4_000 },
  { id: 'high', label: 'High', detail: 'Thinks carefully; slowest', thinkingTokens: 8_000 },
]);
// Instructions follow the paper (after its cache breakpoint), so a length never invalidates the cached paper.
export const LENGTHS: readonly LengthEntry[] = Object.freeze([
  { id: 'brief', label: 'Brief', detail: 'A few sentences', answerTokens: 1_000,
    instructions: 'The reader chose brief answers: answer in a few sentences or a short list (about 150 words at most) unless they ask for more. Leave out background they did not ask for.' },
  { id: 'standard', label: 'Standard', detail: 'Focused answers', answerTokens: 6_000, instructions: null },
  { id: 'detailed', label: 'Detailed', detail: 'Thorough, with derivations and caveats', answerTokens: 10_000,
    instructions: 'The reader chose detailed answers: be thorough. Walk through the reasoning and any derivations step by step, state assumptions and caveats, and give an example where it helps, organized under short headings.' },
]);

/** Today's behavior (and every request without a profile): Sonnet 5.5, effort low, 8,000 output tokens. */
export const DEFAULT_CHOICE: Readonly<Choice> = Object.freeze({ model: 'sonnet', effort: 'low', length: 'standard' });

export interface ChatProfile extends Choice {
  /** `sonnet-low-standard`: recorded with the quote and returned with the answer. */
  id: string;
  apiModel: string;
  /** Output allowance for the whole answer, thinking included (all rounds share it). */
  maxTokens: number;
  fallbacks: boolean;
  /** Added after the paper; null for Standard (today's instructions). */
  lengthInstructions: string | null;
}

const model = (id: ModelChoice) => MODELS.find(entry => entry.id === id)!;
const effort = (id: EffortChoice) => EFFORTS.find(entry => entry.id === id)!;
const length = (id: LengthChoice) => LENGTHS.find(entry => entry.id === id)!;

export function isDefaultChoice(choice: Choice): boolean {
  return choice.model === DEFAULT_CHOICE.model && choice.effort === DEFAULT_CHOICE.effort && choice.length === DEFAULT_CHOICE.length;
}

export function resolveProfile(choice: Choice | null): ChatProfile {
  const c = choice ?? DEFAULT_CHOICE, m = model(c.model), e = effort(c.effort), l = length(c.length);
  return { model: c.model, effort: c.effort, length: c.length, id: `${c.model}-${c.effort}-${c.length}`, apiModel: m.apiModel,
    maxTokens: l.answerTokens + e.thinkingTokens, fallbacks: m.fallbacks, lengthInstructions: l.instructions };
}

/** A request's `profile` field: exactly `{model, effort, length}` with known values; null when absent. Throws on anything else. */
export function parseChoice(value: unknown): Choice | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw new TypeError('profile');
  const v = value as Record<string, unknown>;
  if (Object.keys(v).length !== 3 || !MODELS.some(m => m.id === v.model) || !EFFORTS.some(e => e.id === v.effort)
    || !LENGTHS.some(l => l.id === v.length)) throw new TypeError('profile');
  return { model: v.model as ModelChoice, effort: v.effort as EffortChoice, length: v.length as LengthChoice };
}

// ---------- Published estimates ----------
// Planning assumptions, not measurements: a question about a 25-page paper (~40,000 tokens with the instructions
// and tools). The first question writes the paper to the prompt cache; a follow-up reads it back with ~1,500 tokens
// of conversation. Typical answer and thinking lengths per choice are assumptions to be replaced by measured ones.
export const ESTIMATE_BASIS = Object.freeze({ prompt_tokens: 41_500, question_tokens: 300, follow_up_tokens: 1_800,
  answer_tokens: { brief: 250, standard: 900, detailed: 2_200 } as Record<LengthChoice, number>,
  thinking_tokens: { low: 200, medium: 1_200, high: 3_000 } as Record<EffortChoice, number> });

export interface ProfileEstimate { low: number; high: number; max: number }
export function estimateCredits(profile: ChatProfile): ProfileEstimate {
  const b = ESTIMATE_BASIS, output = b.answer_tokens[profile.length] + b.thinking_tokens[profile.effort];
  const first = ratesFor(profile.apiModel, b.prompt_tokens + b.question_tokens).rates;
  const followUp = ratesFor(profile.apiModel, b.prompt_tokens + b.follow_up_tokens).rates;
  // The most one answer on that paper can cost without web search or a refusal fallback: the whole prompt
  // written to the cache and the full output allowance (the server's hold is larger and covers both).
  const most = ratesFor(profile.apiModel, b.prompt_tokens + b.question_tokens).rates;
  const low = b.prompt_tokens * followUp.cacheRead + b.follow_up_tokens * followUp.input + output * followUp.output;
  const high = b.prompt_tokens * first.cacheWrite5m + b.question_tokens * first.input + output * first.output;
  const max = (b.prompt_tokens + b.question_tokens) * most.cacheWrite5m + profile.maxTokens * most.output;
  return { low: creditsFor(low), high: creditsFor(high), max: creditsFor(max) };
}

/** `GET functions/v1/chat`: the table clients display. Versioned; clients send only `{model, effort, length}`. */
export function publishedProfiles() {
  const profiles = MODELS.flatMap(m => EFFORTS.flatMap(e => LENGTHS.map(l => {
    const profile = resolveProfile({ model: m.id, effort: e.id, length: l.id });
    return { id: profile.id, model: m.id, effort: e.id, length: l.id, api_model: profile.apiModel,
      max_output_tokens: profile.maxTokens, credits: estimateCredits(profile) };
  })));
  return {
    version: PROFILE_VERSION, rate_version: RATE_VERSION, tariff: TARIFF, microusd_per_credit: MICROUSD_PER_CREDIT,
    default: { ...DEFAULT_CHOICE },
    models: MODELS.map(m => ({ id: m.id, label: m.label, detail: m.detail, api_model: m.apiModel })),
    efforts: EFFORTS.map(e => ({ id: e.id, label: e.label, detail: e.detail })),
    lengths: LENGTHS.map(l => ({ id: l.id, label: l.label, detail: l.detail })),
    profiles,
    estimate_note: 'For a question about a typical 25-page paper. Web searches add about 2 credits each.',
  };
}

// Kept in step with anthropic.ts: the default profile is exactly the request the chat function made before profiles.
if (resolveProfile(null).maxTokens !== CHAT_MAX_TOKENS || resolveProfile(null).apiModel !== CHAT_MODEL || DEFAULT_CHOICE.effort !== CHAT_EFFORT) {
  throw new Error('chat profile default drifted from the deployed request');
}
