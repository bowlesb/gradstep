import { isRouterDeepSeek, routedDeepSeekModel, ROUTER_CONSENT_VERSION } from "./openrouter-deepseek-pricing.ts";
import { isRouterClaude, routedClaudeModel } from './openrouter-claude-pricing.ts';
// Chat answer profiles (docs/architecture/CHAT.md#models-effort-and-length): the server-versioned table of the
// model, effort and length a reader may choose in a chat, what each choice sends to the provider and how its credits
// are estimated. The server accepts only these combinations and freezes the chosen profile in the reservation's
// quote; clients only display the published table. Deno and Node compatible.
//
// 2026-10-16 (build 57 feedback, CHAT.md "Chat redesign from build 57 feedback"): the reader sets the model and the
// length; effort may be `auto`, which the server resolves to low, medium or high from the length and the question
// (`autoEffort`) before it holds credits, and it holds, quotes and records the resolved profile. DeepSeek V4.1 Flash
// joins as a fourth model (through OpenRouter to DeepInfra since 2026-10-18). Both are additive to
// `chat-profiles-v1`: builds 57/58 decode only that version, refuse an unknown default, skip unknown model and effort
// ids and read the first 64 profiles, so the 27 profiles they know stay first, with the same ids and choices.
//
// Every model is served through OpenRouter (owner, 2026-10-18; 2026-10-21 "exclusively use open router"): Claude and
// Gemini on its Google Vertex route, DeepSeek on DeepInfra. Estimates use those reviewed cards.
import { CHAT_EFFORT, CHAT_MAX_TOKENS, CHAT_MODEL, creditsFor, MICROUSD_PER_CREDIT, RATE_VERSION, ratesFor } from './inference.ts';

import { GEMINI_MODEL } from './gemini-pricing.ts';

export const PROFILE_VERSION = 'chat-profiles-v1';
export type ModelChoice = 'haiku' | 'sonnet' | 'opus' | 'deepseek' | 'gemini';
export type EffortChoice = 'low' | 'medium' | 'high';
/** What a request may name: an effort, or `auto` (the server picks one for each question, `autoEffort`). */
export type EffortRequest = EffortChoice | 'auto';
export type LengthChoice = 'brief' | 'standard' | 'detailed';
/** A resolved choice: what is held, quoted, sent and recorded. */
export interface Choice { model: ModelChoice; effort: EffortChoice; length: LengthChoice }
/** A request's choice as sent: its effort may still be `auto`. */
export interface RequestedChoice { model: ModelChoice; effort: EffortRequest; length: LengthChoice }
/** Who serves every answer: OpenRouter, the only inference provider. */
export type ChatProvider = 'openrouter';
/** The model family a choice belongs to (it orders the published table and names the upstream route). */
type ModelFamily = 'claude' | 'deepseek' | 'gemini';

/** The consent version that named DeepSeek directly (builds before OpenRouter); OpenRouter's DeepSeek needs v6. */
export const DEEPSEEK_CONSENT_VERSION = 'cloud-ai-v4';
/** The consent that names OpenRouter (and its Google Vertex route): required for every answer. */
export const GEMINI_CONSENT_VERSION = 'cloud-ai-v5';

/** `clientModel`: the stable model identity clients have always seen in `done` (chat.ts answeringModel); the request
 * goes to its OpenRouter model (`routedModel`). */
interface ModelEntry { id: ModelChoice; label: string; detail: string; clientModel: string; family: ModelFamily }
interface EffortEntry { id: EffortChoice; label: string; detail: string; thinkingTokens: number }
interface LengthEntry { id: LengthChoice; label: string; detail: string; answerTokens: number; instructions: string | null }

// Routes and prices: openrouter-claude-pricing.ts (Claude 5.5 through Google Vertex; reasoning at the chosen effort, no
// server-side fallback), openrouter-deepseek-pricing.ts (DeepSeek V4.1 Flash through DeepInfra) and gemini-pricing.ts.
export const MODELS: readonly ModelEntry[] = Object.freeze([
  { id: 'haiku', label: 'Haiku', detail: 'Quick, economical explanations', clientModel: 'claude-haiku-5-5', family: 'claude' },
  { id: 'sonnet', label: 'Sonnet', detail: 'Strong answers at a moderate cost', clientModel: 'claude-sonnet-5-5', family: 'claude' },
  { id: 'opus', label: 'Opus', detail: 'Most capable; costs the most', clientModel: 'claude-opus-5-5', family: 'claude' },
  { id: 'deepseek', label: 'DeepSeek', detail: 'Low cost; processed by DeepSeek', clientModel: 'deepseek-flash', family: 'deepseek' },
  { id: 'gemini', label: 'Gemini Flash', detail: 'Recommended for paper questions; lower cost', clientModel: GEMINI_MODEL, family: 'gemini' },
]);
/** The OpenRouter model a choice is sent as. */
const routedModel = (m: ModelEntry) => routedDeepSeekModel(routedClaudeModel(m.clientModel));
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

/** The figures-and-tables activity's default (published as `default_figures`, owner 2026-10-22). */
export const FIGURES_DEFAULT: Readonly<Choice> = Object.freeze({ model: 'sonnet', effort: 'low', length: 'standard' });

export interface ChatProfile extends Choice {
  /** `sonnet-low-standard`: recorded with the quote and returned with the answer. */
  id: string;
  /** The OpenRouter model the answer is sent as (`anthropic/claude-sonnet-5.5`). */
  apiModel: string;
  /** Output allowance for the whole answer, thinking included (all rounds share it). */
  maxTokens: number;
  /** Who serves the answer (and whose admission, breaker and usage rows it uses). */
  provider: ChatProvider;
  /** Added after the paper; null for Standard (today's instructions). */
  lengthInstructions: string | null;
}

const model = (id: ModelChoice) => MODELS.find(entry => entry.id === id)!;
const effort = (id: EffortChoice) => EFFORTS.find(entry => entry.id === id)!;
const length = (id: LengthChoice) => LENGTHS.find(entry => entry.id === id)!;

/** OpenRouter for every model it has a reviewed route for; null for anything else (never sent). */
export function providerForModel(apiModel: string): ChatProvider | null {
  return (apiModel === GEMINI_MODEL || isRouterClaude(apiModel) || isRouterDeepSeek(apiModel)) ? 'openrouter' : null;
}

export function isDefaultChoice(choice: RequestedChoice): boolean {
  return choice.model === DEFAULT_CHOICE.model && choice.effort === DEFAULT_CHOICE.effort && choice.length === DEFAULT_CHOICE.length;
}

export function resolveProfile(choice: Choice | null): ChatProfile {
  const c = choice ?? DEFAULT_CHOICE, m = model(c.model), e = effort(c.effort), l = length(c.length);
  return { model: c.model, effort: c.effort, length: c.length, id: `${c.model}-${c.effort}-${c.length}`, apiModel: routedModel(m),
    maxTokens: l.answerTokens + e.thinkingTokens, provider: 'openrouter', lengthInstructions: l.instructions };
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
  const chosen = requested.model === 'gemini' ? 'medium' : requested.effort === 'auto' ? autoEffort(requested.length, signals) : requested.effort;
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
  /** Off/hidden until consent, accounting and the deployed adapter are verified. */
  gemini?: boolean;
  /** Whether a model's reviewed price card stays valid long enough to offer it (A4, migration 0101); absent: all are. */
  available?: (apiModel: string) => boolean;
}

/** The published `tariff`: every estimate in the table is priced at its model's reviewed OpenRouter card (each quote
 * records the card it was held at: inference.ts tariffFor). */
export const PUBLISHED_TARIFF = 'openrouter-reviewed-cards';

/** `GET functions/v1/chat`: the table clients display. Versioned; clients send only `{model, effort, length}`.
 * Additive since 2026-10-16: the 27 Claude profiles first, with their ids and choices unchanged (old builds read only
 * the first 64 and skip what they do not know), then DeepSeek's nine, then the `auto` profiles; `efforts` lists `auto`
 * last; models carry their `provider` (OpenRouter) and required consent. Flash's profiles are appended; updated clients
 * prefer `default_recommended`. */
export function publishedProfiles(options: PublishOptions = { deepseek: false }) {
  const models = MODELS.filter(m => (m.family !== 'deepseek' || options.deepseek) && (m.family !== 'gemini' || options.gemini)
    && options.available?.(routedModel(m)) !== false);
  const recommendGemini = !!options.gemini && models.some(m => m.id === 'gemini');
  const explicit = (list: readonly ModelEntry[]) => list.flatMap(m => EFFORTS.filter(e => m.id !== 'gemini' || e.id === 'medium').flatMap(e => LENGTHS.map(l => {
    const profile = resolveProfile({ model: m.id, effort: e.id, length: l.id });
    return { id: profile.id, model: m.id, effort: e.id as EffortRequest, length: l.id, api_model: profile.apiModel,
      max_output_tokens: profile.maxTokens, credits: estimateCredits(profile) };
  })));
  // An `auto` profile: the estimate of the effort usually picked for its length, the maximum of the highest it can pick.
  const auto = models.flatMap(m => LENGTHS.map(l => {
    const usual = resolveProfile({ model: m.id, effort: m.id === 'gemini' ? 'medium' : AUTO_EFFORTS[l.id].usual, length: l.id });
    const highest = resolveProfile({ model: m.id, effort: m.id === 'gemini' ? 'medium' : AUTO_EFFORTS[l.id].highest, length: l.id });
    const typical = estimateCredits(usual), most = estimateCredits(highest);
    return { id: `${m.id}-auto-${l.id}`, model: m.id, effort: AUTO_EFFORT.id as EffortRequest, length: l.id, api_model: highest.apiModel,
      max_output_tokens: highest.maxTokens, credits: { low: typical.low, high: typical.high, max: most.max } };
  }));
  return {
    version: PROFILE_VERSION, rate_version: RATE_VERSION, tariff: PUBLISHED_TARIFF, microusd_per_credit: MICROUSD_PER_CREDIT,
    default: { ...DEFAULT_CHOICE },
    default_auto: { ...DEFAULT_AUTO_CHOICE },
    ...(recommendGemini ? { default_recommended: { model: 'gemini', effort: 'medium', length: 'standard' } } : {}),
    // Figures and tables (owner, 2026-10-22: "change the default to Sonnet for that one"): Sonnet at low effort, fast and
    // a careful reader of images (FIGURE_VIEW.md "Speed"). Clients that know it start that activity there; older ones ignore it.
    ...(models.some(m => m.id === FIGURES_DEFAULT.model) ? { default_figures: { ...FIGURES_DEFAULT } } : {}),
    models: models.map(m => ({ id: m.id, label: m.label, detail: `${m.detail} · OpenRouter → ${m.family === 'deepseek' ? 'DeepInfra' : 'Google Vertex'}`,
      api_model: routedModel(m), provider: 'openrouter' as ChatProvider,
      consent_version: m.family === 'deepseek' ? ROUTER_CONSENT_VERSION : GEMINI_CONSENT_VERSION })),
    efforts: [...EFFORTS.map(e => ({ id: e.id as EffortRequest, label: e.label, detail: e.detail })), { ...AUTO_EFFORT }],
    lengths: LENGTHS.map(l => ({ id: l.id, label: l.label, detail: l.detail })),
    profiles: [...explicit(models.filter(m => m.family === 'claude')), ...explicit(models.filter(m => m.family === 'deepseek')), ...auto.filter(p => p.model !== 'gemini'), ...explicit(models.filter(m => m.family === 'gemini')), ...auto.filter(p => p.model === 'gemini')],
    estimate_note: 'For a question about a typical 25-page paper. Web searches add about 2 credits each.',
  };
}

// Kept in step with inference.ts: the default profile is exactly the request the chat function makes without one.
if (resolveProfile(null).maxTokens !== CHAT_MAX_TOKENS || resolveProfile(null).apiModel !== CHAT_MODEL || DEFAULT_CHOICE.effort !== CHAT_EFFORT) {
  throw new Error('chat profile default drifted from the deployed request');
}
