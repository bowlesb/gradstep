// Chat answer profiles (docs/architecture/CHAT.md#models-effort-and-length): the server-versioned table of the
// model, effort and length a reader may choose in a chat, what each choice sends to the provider and how its credits
// are estimated. The server accepts only these combinations and freezes the chosen profile in the reservation's
// quote; clients only display the published table. Deno and Node compatible.
//
// 2026-10-16 (build 57 feedback, CHAT.md "Chat redesign from build 57 feedback"): the reader sets the model and the
// length; effort may be `auto`, which the server resolves to low, medium or high from the length and the question
// (`autoEffort`) before it holds credits, and it holds, quotes and records the resolved profile. DeepSeek V4.1 Flash
// joins as a fourth model through DeepSeek's Anthropic-compatible API (deepseek.ts). Both are additive to
// `chat-profiles-v1`: builds 57/58 decode only that version, refuse an unknown default, skip unknown model and effort
// ids and read the first 64 profiles, so the 27 profiles they know stay first and unchanged.
import { CHAT_EFFORT, CHAT_MAX_TOKENS, CHAT_MODEL, creditsFor, MICROUSD_PER_CREDIT, RATE_VERSION, ratesFor, TARIFF } from './anthropic.ts';

export const PROFILE_VERSION = 'chat-profiles-v1';
export type ModelChoice = 'haiku' | 'sonnet' | 'opus' | 'deepseek';
export type EffortChoice = 'low' | 'medium' | 'high';
/** What a request may name: an effort, or `auto` (the server picks one for each question, `autoEffort`). */
export type EffortRequest = EffortChoice | 'auto';
export type LengthChoice = 'brief' | 'standard' | 'detailed';
/** A resolved choice: what is held, quoted, sent and recorded. */
export interface Choice { model: ModelChoice; effort: EffortChoice; length: LengthChoice }
/** A request's choice as sent: its effort may still be `auto`. */
export interface RequestedChoice { model: ModelChoice; effort: EffortRequest; length: LengthChoice }
export type ChatProvider = 'anthropic' | 'deepseek';

/** The consent version that names DeepSeek as the processor when the reader chooses it (chat.ts CONSENT_VERSIONS). */
export const DEEPSEEK_CONSENT_VERSION = 'cloud-ai-v4';

interface ModelEntry { id: ModelChoice; label: string; detail: string; apiModel: string; fallbacks: boolean; provider: ChatProvider }
interface EffortEntry { id: EffortChoice; label: string; detail: string; thinkingTokens: number }
interface LengthEntry { id: LengthChoice; label: string; detail: string; answerTokens: number; instructions: string | null }

// Model IDs and capabilities checked with GET /v1/models on 2026-10-08: all three Claude models take adaptive thinking
// and `output_config.effort` (low/medium/high); Sonnet 5.5 falls back to Sonnet 5, Opus 5.5 to Opus 5 / Opus 4.8,
// Haiku 5.5 has no fallback models. DeepSeek V4.1 Flash (`deepseek-flash`, 2026-10-16): image input, tools, thinking,
// 1M context; its Anthropic-compatible endpoint accepted adaptive thinking, `output_config.effort` and a one-hour
// `cache_control` block in a live probe (CHAT.md "DeepSeek in chat"); no fallback models. Prices: anthropic.ts.
export const MODELS: readonly ModelEntry[] = Object.freeze([
  { id: 'haiku', label: 'Haiku', detail: 'Fastest and cheapest', apiModel: 'claude-haiku-5-5', fallbacks: false, provider: 'anthropic' },
  { id: 'sonnet', label: 'Sonnet', detail: 'Strong answers at a moderate cost', apiModel: CHAT_MODEL, fallbacks: true, provider: 'anthropic' },
  { id: 'opus', label: 'Opus', detail: 'Most capable; costs the most', apiModel: 'claude-opus-5-5', fallbacks: true, provider: 'anthropic' },
  { id: 'deepseek', label: 'DeepSeek', detail: 'Low cost; processed by DeepSeek', apiModel: 'deepseek-flash', fallbacks: false, provider: 'deepseek' },
]);
// Effort maps one to one onto the API's `output_config.effort`, with adaptive thinking on every model. The thinking
// allowance is added to the length's answer allowance: max_tokens covers thinking and the answer together.
export const EFFORTS: readonly EffortEntry[] = Object.freeze([
  { id: 'low', label: 'Low', detail: 'Thinks only when needed; quickest', thinkingTokens: 2_000 },
  { id: 'medium', label: 'Medium', detail: 'Thinks through harder questions', thinkingTokens: 4_000 },
  { id: 'high', label: 'High', detail: 'Thinks carefully; slowest', thinkingTokens: 8_000 },
]);
/** The published `auto` effort entry (no request ever carries it past `resolveChoice`). */
export const AUTO_EFFORT = Object.freeze({ id: 'auto' as const, label: 'Automatic', detail: 'Chosen for each question' });
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
/** What new clients start with (published as `default_auto`): Sonnet, effort chosen by the server, standard length. */
export const DEFAULT_AUTO_CHOICE: Readonly<RequestedChoice> = Object.freeze({ model: 'sonnet', effort: 'auto', length: 'standard' });

export interface ChatProfile extends Choice {
  /** `sonnet-low-standard`: recorded with the quote and returned with the answer. */
  id: string;
  apiModel: string;
  /** Output allowance for the whole answer, thinking included (all rounds share it). */
  maxTokens: number;
  fallbacks: boolean;
  /** Who serves the answer (and whose admission, breaker and usage rows it uses). */
  provider: ChatProvider;
  /** Added after the paper; null for Standard (today's instructions). */
  lengthInstructions: string | null;
}

const model = (id: ModelChoice) => MODELS.find(entry => entry.id === id)!;
const effort = (id: EffortChoice) => EFFORTS.find(entry => entry.id === id)!;
const length = (id: LengthChoice) => LENGTHS.find(entry => entry.id === id)!;

/** The provider that serves an API model (an Anthropic model unless it is one of DeepSeek's). */
export function providerForModel(apiModel: string): ChatProvider {
  return apiModel.startsWith('deepseek-') ? 'deepseek' : 'anthropic';
}

export function isDefaultChoice(choice: RequestedChoice): boolean {
  return choice.model === DEFAULT_CHOICE.model && choice.effort === DEFAULT_CHOICE.effort && choice.length === DEFAULT_CHOICE.length;
}

export function resolveProfile(choice: Choice | null): ChatProfile {
  const c = choice ?? DEFAULT_CHOICE, m = model(c.model), e = effort(c.effort), l = length(c.length);
  return { model: c.model, effort: c.effort, length: c.length, id: `${c.model}-${c.effort}-${c.length}`, apiModel: m.apiModel,
    maxTokens: l.answerTokens + e.thinkingTokens, fallbacks: m.fallbacks, provider: m.provider, lengthInstructions: l.instructions };
}

/** A request's `profile` field: exactly `{model, effort, length}` with known values (effort may be `auto`); null when
 * absent. Throws on anything else. */
export function parseChoice(value: unknown): RequestedChoice | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw new TypeError('profile');
  const v = value as Record<string, unknown>;
  if (Object.keys(v).length !== 3 || !MODELS.some(m => m.id === v.model) || !(v.effort === AUTO_EFFORT.id || EFFORTS.some(e => e.id === v.effort))
    || !LENGTHS.some(l => l.id === v.length)) throw new TypeError('profile');
  return { model: v.model as ModelChoice, effort: v.effort as EffortRequest, length: v.length as LengthChoice };
}

// ---------- Automatic effort ----------
// Deterministic and pure: the same question, selection, figures and length always pick the same effort, so a replayed
// request digests and quotes identically. The rules (CHAT.md "Automatic effort (server)"):
//   Brief → low. Standard → low, or medium when the question asks for reasoning or carries an equation or figures.
//   Detailed → medium, or high when the question asks for reasoning.
/** Which efforts `auto` can pick for each length: the usual one (the published estimate) and the highest (its max). */
export const AUTO_EFFORTS: Readonly<Record<LengthChoice, { usual: EffortChoice; highest: EffortChoice }>> = Object.freeze({
  brief: { usual: 'low', highest: 'low' }, standard: { usual: 'low', highest: 'medium' }, detailed: { usual: 'medium', highest: 'high' },
});

// A question asks for reasoning when it asks to derive, prove or show something, to go step by step, why something
// does or is so, to compare or weigh trade-offs, for intuition, to explain an equation or a term, or how something works.
const REASONING: readonly RegExp[] = [
  /\bderiv(?:e|es|ed|ing|ation|ations)\b/,
  /\bprov(?:e|es|ed|en|ing)\b|\bproofs?\b/,
  /\bshow(?:s|ing)? (?:that|why|how)\b/,
  /\bstep[ -]by[ -]step\b/,
  /\bwalk (?:me |us )?through\b/,
  /\bwhy (?:does|do|did|is|are|was|were|would|should|can|could|must|doesn'?t|don'?t|isn'?t|aren'?t|can'?t|won'?t)\b/,
  /\bcompar(?:e|es|ed|ing|ison|isons)\b|\bversus\b|\bvs\.?(?=\s)|\bdifference between\b|\bdiffers? from\b/,
  /\btrade[ -]?offs?\b/,
  /\bintuit(?:ion|ions|ive|ively)\b/,
  /\bexplain\w*\b[^.?!\n]{0,80}\b(?:equation|eq\.|eqn|formula|term|expression|objective|loss|derivation|theorem|lemma|proof|bound|identity)s?\b/,
  /\bhow (?:does|do|did|would|could|can|is|are)\b[^.?!\n]{0,100}\bwork(?:s|ed|ing)?\b/,
];
/** Whether a question asks for reasoning (case-insensitive; typographic apostrophes read as plain ones). */
export function asksForReasoning(question: string): boolean {
  const text = question.toLowerCase().replace(/[‘’]/g, "'");
  return REASONING.some(pattern => pattern.test(text));
}

// An equation: LaTeX (a command such as \frac or \sigma, \( \) or \[ \] delimiters, $…$), a sub- or superscript, a
// single-letter variable set equal to something, or mathematical symbols and Greek letters as the reader's selection
// of rendered math carries them.
const EQUATION: readonly RegExp[] = [
  /\\[a-zA-Z]{2,}/,
  /\\[([]/,
  /\$[^$\n]{1,200}\$/,
  /[A-Za-z0-9)\]}][_^]\s*[{(A-Za-z0-9]/,
  /(?:^|[^A-Za-z0-9])[A-Za-z]\s*=\s*[-A-Za-z0-9\\(]/,
  /[∑∏∫∮∂∇√∞≈≠≤≥∈∉∝⊂⊆⊇∀∃→⇒⇔↦⋅×÷±∥⟨⟩α-ωΑ-Ω]/u,
];
/** Whether a text carries an equation (the selection the question is about, or the question itself). */
export function carriesEquation(text: string | null | undefined): boolean {
  return !!text && EQUATION.some(pattern => pattern.test(text));
}

export interface EffortSignals {
  /** The newest question (the last user turn). */
  question: string;
  /** The selected passage, when the question is about one. */
  selection: string | null;
  /** Figure images attached to the question. */
  figures: number;
}
/** The effort `auto` resolves to for one question. */
export function autoEffort(lengthID: LengthChoice, signals: EffortSignals): EffortChoice {
  if (lengthID === 'brief') return 'low';
  const reasoning = asksForReasoning(signals.question);
  if (lengthID === 'detailed') return reasoning ? 'high' : 'medium';
  return reasoning || signals.figures > 0 || carriesEquation(signals.selection) || carriesEquation(signals.question) ? 'medium' : 'low';
}
/** A request's choice with `auto` resolved (null stays null: the default profile). */
export function resolveChoice(requested: RequestedChoice | null, signals: EffortSignals): Choice | null {
  if (!requested) return null;
  const chosen = requested.effort === 'auto' ? autoEffort(requested.length, signals) : requested.effort;
  return { model: requested.model, effort: chosen, length: requested.length };
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

export interface PublishOptions {
  /** DeepSeek is offered (CHAT_DEEPSEEK=on with a key); off or `hidden` (accepted for checks, not shown) leaves it out. */
  deepseek: boolean;
}

/** `GET functions/v1/chat`: the table clients display. Versioned; clients send only `{model, effort, length}`.
 * Additive since 2026-10-16: the 27 Claude profiles first and unchanged (old builds read only the first 64 and skip
 * what they do not know), then DeepSeek's nine, then the `auto` profiles; `efforts` lists `auto` last; models carry
 * their `provider` (and DeepSeek its `consent_version`); `default_auto` is what new clients start with. */
export function publishedProfiles(options: PublishOptions = { deepseek: false }) {
  const models = MODELS.filter(m => m.provider !== 'deepseek' || options.deepseek);
  const explicit = (list: readonly ModelEntry[]) => list.flatMap(m => EFFORTS.flatMap(e => LENGTHS.map(l => {
    const profile = resolveProfile({ model: m.id, effort: e.id, length: l.id });
    return { id: profile.id, model: m.id, effort: e.id as EffortRequest, length: l.id, api_model: profile.apiModel,
      max_output_tokens: profile.maxTokens, credits: estimateCredits(profile) };
  })));
  // An `auto` profile: the estimate of the effort usually picked for its length, the maximum of the highest it can pick.
  const auto = models.flatMap(m => LENGTHS.map(l => {
    const usual = resolveProfile({ model: m.id, effort: AUTO_EFFORTS[l.id].usual, length: l.id });
    const highest = resolveProfile({ model: m.id, effort: AUTO_EFFORTS[l.id].highest, length: l.id });
    const typical = estimateCredits(usual), most = estimateCredits(highest);
    return { id: `${m.id}-auto-${l.id}`, model: m.id, effort: AUTO_EFFORT.id as EffortRequest, length: l.id, api_model: highest.apiModel,
      max_output_tokens: highest.maxTokens, credits: { low: typical.low, high: typical.high, max: most.max } };
  }));
  return {
    version: PROFILE_VERSION, rate_version: RATE_VERSION, tariff: TARIFF, microusd_per_credit: MICROUSD_PER_CREDIT,
    default: { ...DEFAULT_CHOICE },
    default_auto: { ...DEFAULT_AUTO_CHOICE },
    models: models.map(m => ({ id: m.id, label: m.label, detail: m.detail, api_model: m.apiModel, provider: m.provider,
      ...(m.provider === 'deepseek' ? { consent_version: DEEPSEEK_CONSENT_VERSION } : {}) })),
    efforts: [...EFFORTS.map(e => ({ id: e.id as EffortRequest, label: e.label, detail: e.detail })), { ...AUTO_EFFORT }],
    lengths: LENGTHS.map(l => ({ id: l.id, label: l.label, detail: l.detail })),
    profiles: [...explicit(models.filter(m => m.provider === 'anthropic')), ...explicit(models.filter(m => m.provider === 'deepseek')), ...auto],
    estimate_note: 'For a question about a typical 25-page paper. Web searches add about 2 credits each.',
  };
}

// Kept in step with anthropic.ts: the default profile is exactly the request the chat function made before profiles.
if (resolveProfile(null).maxTokens !== CHAT_MAX_TOKENS || resolveProfile(null).apiModel !== CHAT_MODEL || DEFAULT_CHOICE.effort !== CHAT_EFFORT) {
  throw new Error('chat profile default drifted from the deployed request');
}
