// Anthropic provider boundary for paid chat. Deno and Node compatible: no
// runtime globals beyond fetch/AbortSignal, so tests can drive the real SDK
// with a fake fetch. Never log prompts, answers, or the API key here.
import { IMAGE_HOLD_TOKENS } from './chat-figures.ts';
import Anthropic from '@anthropic-ai/sdk';

export const CHAT_MODEL = 'claude-sonnet-5-5';
export const CHAT_MAX_TOKENS = 8000;
// Chat and paper Q&A: the model guidance recommends `low` for chat. It also
// skips thinking on simple turns, keeping time-to-first-token and cost down.
export const CHAT_EFFORT = 'low' as const;
// Server-side refusal fallback ("default" routes by refusal category; for this
// model it retries cyber/frontier_llm declines on Claude Sonnet 5).
export const FALLBACK_BETA = 'server-side-fallback-2026-07-01';
export const RATE_VERSION = 'beta-credits-v1';
// beta-credits-v1: one credit is $0.01 charged at twice provider cost.
export const MICROUSD_PER_CREDIT = 5_000;
// Upper bound used only when a stream ends without final usage (abort/error).
const ESTIMATED_OUTPUT_TOKENS_PER_SECOND = 100;

/** Provider prices in micro-USD per token. */
/** How long the paper block stays in Anthropic's prompt cache. */
export const PAPER_CACHE_TTL = '1h' as const;
export interface TokenRates { input: number; cacheWrite5m: number; cacheWrite1h: number; cacheRead: number; output: number }
// Anthropic list prices, https://platform.claude.com/docs/en/about-claude/pricing (read 2026-10-08), $/MTok = µ$/token.
// Claude Sonnet 5.5 and Opus 5.5 cache reads are 0.05x input ($0.10 and $0.20); other models 0.1x.
export const TARIFF = 'anthropic-list-prices-2026-10-08';
const SONNET: TokenRates = Object.freeze({ input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.1, output: 10 });
const SONNET_5: TokenRates = Object.freeze({ input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2, output: 10 });
const OPUS_5_5: TokenRates = Object.freeze({ input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2, output: 20 });
// Claude Opus 5 and Opus 4.8: Opus 5.5's server-side fallback targets (`allowed_fallback_models`).
const OPUS_5: TokenRates = Object.freeze({ input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25 });
// Claude Haiku 5.5 is priced by prompt length: a prompt over 100,000 tokens pays the higher rates for the whole request.
export const HAIKU_LONG_PROMPT_TOKENS = 100_000;
const HAIKU: TokenRates = Object.freeze({ input: 0.1, cacheWrite5m: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01, output: 0.5 });
const HAIKU_LONG: TokenRates = Object.freeze({ input: 0.5, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05, output: 2.5 });
const HAIKU_4_5: TokenRates = Object.freeze({ input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5 });
// Unknown serving model: price at the highest rate card any model this route
// can be served by carries (Claude Opus 5 / 4.8, Opus 5.5's fallbacks).
// DeepSeek (podcast script provider, 2026-10-14): PEAK list prices in micro-USD per token (input cache miss, output;
// cache hits as cache reads; no cache-write price). Off-peak bills less; the card never under-prices.
const DEEPSEEK_V4_PRO: TokenRates = Object.freeze({ input: 1.32, cacheWrite5m: 1.32, cacheWrite1h: 1.32, cacheRead: 0.044, output: 3.96 });
const DEEPSEEK_FLASH: TokenRates = Object.freeze({ input: 0.3, cacheWrite5m: 0.3, cacheWrite1h: 0.3, cacheRead: 0.006, output: 1.2 });
/** The tariff a DeepSeek chat quote records: DeepSeek's PEAK list prices for `deepseek-flash` ($0.30/M input cache miss,
 * $0.006/M cache hit, $1.20/M output), https://api-docs.deepseek.com/quick_start/pricing/ re-read 2026-10-16. */
export const DEEPSEEK_TARIFF = 'deepseek-peak-list-prices-2026-10-16';
/** DeepSeek chat answers: two attempts' headroom. There is no fallback, but its tokenizer and tool template cannot be
 * counted before the request (no count endpoint), so the byte estimate gets twice the margin a Claude prompt gets. */
export const DEEPSEEK_HOLD_ATTEMPTS = 2;
export const UNKNOWN_MODEL_RATES: TokenRates = OPUS_5;
const KNOWN_RATES: Readonly<Record<string, TokenRates>> = Object.freeze({
  'claude-sonnet-5-5': SONNET, 'claude-sonnet-5': SONNET_5, 'claude-opus-5-5': OPUS_5_5, 'claude-opus-5': OPUS_5,
  'claude-opus-4-8': OPUS_5, 'claude-haiku-5-5': HAIKU, 'claude-haiku-4-5': HAIKU_4_5,
  'deepseek-v4-pro': DEEPSEEK_V4_PRO, 'deepseek-flash': DEEPSEEK_FLASH,
});

/** `promptTokens` (the whole prompt: uncached, cache-write and cache-read tokens) chooses Haiku 5.5's tier. */
export function ratesFor(model: string | null | undefined, promptTokens = 0): { rates: TokenRates; known: boolean } {
  const canonical = typeof model === 'string' ? model.replace(/-\d{8}$/, '') : '';
  const rates = Object.hasOwn(KNOWN_RATES, canonical) ? KNOWN_RATES[canonical] : undefined;
  if (rates === HAIKU && promptTokens > HAIKU_LONG_PROMPT_TOKENS) return { rates: HAIKU_LONG, known: true };
  return rates ? { rates, known: true } : { rates: UNKNOWN_MODEL_RATES, known: false };
}

export interface TokenUsage { input: number; cacheWrite5m: number; cacheWrite1h: number; cacheRead: number; output: number }
/** One billed sampling attempt (the requested model or a fallback hop). */
export interface ProviderAttempt { model: string | null; usage: TokenUsage; estimated: boolean }

export function emptyUsage(): TokenUsage { return { input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 }; }

/** Exact micro-USD (possibly fractional) for the attempts; callers round up once. */
export function priceAttempts(attempts: readonly ProviderAttempt[]): number {
  let total = 0;
  for (const attempt of attempts) {
    const u = attempt.usage;
    const { rates } = ratesFor(attempt.model, u.input + u.cacheWrite5m + u.cacheWrite1h + u.cacheRead);
    total += u.input * rates.input + u.cacheWrite5m * rates.cacheWrite5m + u.cacheWrite1h * rates.cacheWrite1h
      + u.cacheRead * rates.cacheRead + u.output * rates.output;
  }
  return total;
}

export function creditsFor(microusd: number): number { return Math.ceil(Math.max(0, microusd) / MICROUSD_PER_CREDIT); }
export function estimateTokens(characters: number): number { return Math.ceil(Math.max(0, characters) / 3); }

/** Headroom for a refused attempt plus a server-side fallback attempt that may
 * be priced at a higher tier (Sonnet's fallback is Sonnet 5; unknown models price at Opus 5). */
export const FALLBACK_HOLD_FACTOR = 3;

/**
 * How one request to `model` is held: the rate card every token is held at and how many full attempts.
 * Sonnet 5.5 (the default, unchanged): its own rates, three attempts' headroom. Opus 5.5: its fallbacks' higher
 * Opus 5 rates for the requested attempt and one fallback. Haiku 5.5: no fallback, one attempt at the tier the
 * estimated prompt falls in (the byte estimate never undercounts tokens, so it never picks the cheaper tier wrongly).
 * DeepSeek V4.1 Flash (chat, 2026-10-16): its own peak rates, `DEEPSEEK_HOLD_ATTEMPTS` (2).
 * Any other model: the unknown rate card, three attempts.
 */
export function holdRule(model: string, promptTokens: number): { rates: TokenRates; attempts: number } {
  switch (model) {
    case CHAT_MODEL: return { rates: SONNET, attempts: FALLBACK_HOLD_FACTOR };
    case 'claude-opus-5-5': return { rates: OPUS_5, attempts: 2 };
    case 'claude-haiku-5-5': return { rates: ratesFor(model, promptTokens).rates, attempts: 1 };
    case 'deepseek-flash': return { rates: DEEPSEEK_FLASH, attempts: DEEPSEEK_HOLD_ATTEMPTS };
    default: return { rates: UNKNOWN_MODEL_RATES, attempts: FALLBACK_HOLD_FACTOR };
  }
}

/**
 * Hold ceiling: every estimated input token at the cache-write rate plus the
 * whole output budget (thinking counts toward max_tokens), times the fallback
 * headroom. `inputCharacters` is the weighted count from `promptCharacters`;
 * `hourCharacters` is the part cached for an hour (the paper, `PAPER_CACHE_TTL`),
 * held at the one-hour write rate so a hold always covers the real write.
 */
export function holdFor(inputCharacters: number, maxTokens = CHAT_MAX_TOKENS, model = CHAT_MODEL, hourCharacters = 0): { inputTokens: number; microusd: number; credits: number } {
  const inputTokens = estimateTokens(inputCharacters);
  const hourTokens = Math.min(inputTokens, estimateTokens(hourCharacters));
  const { rates, attempts } = holdRule(model, inputTokens);
  const microusd = Math.ceil((hourTokens * rates.cacheWrite1h + (inputTokens - hourTokens) * rates.cacheWrite5m + maxTokens * rates.output) * attempts);
  return { inputTokens, microusd, credits: creditsFor(microusd) };
}

/** The characters of the system blocks cached for an hour (weighted as `promptCharacters` weighs them). */
export function hourCachedCharacters(params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming): number {
  const blocks = (Array.isArray(params.system) ? params.system : []).filter(b => (b as { cache_control?: { ttl?: string } }).cache_control?.ttl === '1h');
  return blocks.length ? new TextEncoder().encode(JSON.stringify(blocks)).byteLength * 3 : 0;
}

/** The hold for one admitted request, from its own model, prompt and output allowance. */
export function holdForParams(params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming): { inputTokens: number; microusd: number; credits: number } {
  return holdFor(promptCharacters(params), params.max_tokens, params.model, hourCachedCharacters(params));
}

type Usage = Anthropic.Beta.Messages.BetaUsage;
function count(value: number | null | undefined): number { return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : 0; }
function splitWrites(total: number, detail: { ephemeral_5m_input_tokens: number; ephemeral_1h_input_tokens: number } | null | undefined) {
  const hour = Math.min(total, count(detail?.ephemeral_1h_input_tokens));
  return { cacheWrite5m: total - hour, cacheWrite1h: hour };
}

/** Usage per attempt. With fallbacks, `iterations` is the billing source of truth. */
export function attemptsFromUsage(model: string | null, usage: Usage | null | undefined): ProviderAttempt[] {
  if (!usage) return [];
  const sampled = (usage.iterations ?? []).filter(item => item.type === 'message' || item.type === 'fallback_message');
  if (sampled.length) {
    return sampled.map(item => {
      const writes = count(item.cache_creation_input_tokens);
      return { model: item.model ?? model, estimated: false, usage: { input: count(item.input_tokens),
        ...splitWrites(writes, item.cache_creation), cacheRead: count(item.cache_read_input_tokens), output: count(item.output_tokens) } };
    });
  }
  const writes = count(usage.cache_creation_input_tokens);
  return [{ model, estimated: false, usage: { input: count(usage.input_tokens), ...splitWrites(writes, usage.cache_creation),
    cacheRead: count(usage.cache_read_input_tokens), output: count(usage.output_tokens) } }];
}

export interface ChatTurn { role: 'user' | 'assistant'; text: string }
export interface PaperContext { title: string | null; text: string }

/**
 * Stable instructions first, then the paper (cached prefix), then the turns.
 * Nothing volatile precedes the cache breakpoint.
 */
/** Ingest's one client tool. The server finds the paper by title (strict
 * match; arXiv first, then an open-access copy through OpenAlex) and adds it as
 * the reader; the result is reported to the reader directly, so the tool needs
 * no second model call. */
export const ADD_PAPER_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: 'add_paper',
  description: 'Adds the paper the reader selected (a reference or citation) to their Gradstep library. '
    + 'The app looks up the exact title on arXiv and, failing that, an open-access copy elsewhere, and adds the match. Call it at most once.',
  input_schema: {
    type: 'object',
    properties: {
      title: { type: 'string', description: "The referenced paper's full title, exactly as in the bibliography." },
      year: { type: 'integer', description: 'Publication year, if known.' },
      first_author: { type: 'string', description: "The first author's name as cited (e.g. \"J. Schulman\")." },
      arxiv_id: { type: 'string', description: 'The arXiv identifier, only if it appears in the paper text.' },
    },
    required: ['title'],
    additionalProperties: false,
  },
};

/** Diagrams: Mermaid source only. The server relays it to the device, which
 * stores it encrypted and draws it with a bundled, sandboxed Mermaid. */
export const CREATE_DIAGRAM_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: 'create_diagram',
  description: 'Draws a diagram the reader can open from your answer and later from All diagrams. Use it only when the reader '
    + 'explicitly asks for a diagram, flowchart or other visual. Mermaid syntax only. Call it at most once, after your text.',
  input_schema: {
    type: 'object',
    properties: {
      title: { type: 'string', description: 'A short title (under 80 characters).' },
      mermaid: { type: 'string', description: 'Mermaid source starting with the diagram type (e.g. "flowchart TD"). Under about 40 nodes, '
        + 'short ASCII labels (math as plain text, no LaTeX or Unicode symbols), labels with punctuation in double quotes, no click or link directives.' },
    },
    required: ['title', 'mermaid'],
  },
};

/** Visual answers (chat-visual.ts): one HTML fragment beside an answer, sanitized by the server and drawn by the
 * device in a frame with no scripts and no network. */
export const CREATE_VISUAL_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: 'create_visual',
  description: 'Shows a visual beside your answer, read on a phone: a flow chart or pipeline drawn as inline SVG, a timeline, a '
    + 'decision tree, a comparison table, annotated steps. Use it when a picture or a structured layout explains the point better '
    + 'than prose, and keep the written answer complete on its own. Self-contained HTML fragment: headings, paragraphs, lists, '
    + 'tables, inline CSS or one <style> element, and inline SVG (shapes, lines, text; arrows with markers). No scripts, no images, '
    + 'no external resources, links to https only. Under 12,000 bytes; narrow vertical layouts; relative font sizes. Call it at '
    + 'most once, after your text; never also call create_diagram in the same answer.',
  input_schema: {
    type: 'object',
    properties: {
      title: { type: 'string', description: 'A short title (under 80 characters).' },
      html: { type: 'string', description: 'The HTML fragment (no <html>, <head> or <body>).' },
    },
    required: ['title', 'html'],
  },
};

/** Web search in chat: Tavily (`search_web`, a client tool the server runs) when
 * the reader's consent names it, Anthropic's server-side search as the backup
 * (docs/architecture/CHAT.md). Off unless the server enables it; at most three
 * searches per answer. */
export const WEB_SEARCH_MAX_USES = 3;
/** $10 per 1,000 searches. */
export const WEB_SEARCH_MICROUSD = 10_000;
// The basic search tool, not web_search_20260209: that version filters results by running
// model-written code, which failed in production (2026-10-06: code exit 1 on most searches, the
// model then reported search as failed and leaked its filtering notes into the answer).
export const WEB_SEARCH_TOOL: Anthropic.Beta.Messages.BetaWebSearchTool20250305 = {
  type: 'web_search_20250305', name: 'web_search', max_uses: WEB_SEARCH_MAX_USES,
};
/** Related (finding related papers) plans several targeted searches. */
export const RELATED_SEARCH_MAX_USES = 5;
export const RELATED_WEB_SEARCH_TOOL: Anthropic.Beta.Messages.BetaWebSearchTool20250305 = {
  type: 'web_search_20250305', name: 'web_search', max_uses: RELATED_SEARCH_MAX_USES,
};
/** Tavily search: the reader is charged Tavily's pay-as-you-go price per credit
 * ($0.008; a basic search is one credit) however the plan was paid for. Searches
 * within the prepaid plan add nothing to provider spend (a fixed commitment). */
export const TAVILY_CREDIT_MICROUSD = 8_000;
export const SEARCH_WEB_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: 'search_web',
  description: 'Searches the web and returns the most relevant pages, each with its address and an extract. Use a focused query '
    + '(a few words to a sentence). Set academic to true to search only scholarly sites (arXiv, OpenReview, ACL Anthology, '
    + 'conference proceedings, journals), for example when looking for papers.',
  input_schema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'The search query.' },
      academic: { type: 'boolean', description: 'Only scholarly sites (for finding papers). Default false.' },
    },
    required: ['query'],
  },
};
/** search_web results as search_result blocks, citations off (a request's search results must all use the
 * same setting). Citable blocks switch citations on mid-answer, and that switch invalidates the prompt cache
 * of everything after the tool definitions: on staging the round after the searches rewrote the whole paper
 * (cache_read 0, ~56k tokens written again) instead of reading it. The answer names its sources itself
 * (WEB_SEARCH_INSTRUCTIONS); otherwise the server lists the searched pages. */
export function searchResultContent(results: readonly { url: string; title: string; text: string; published: string | null }[])
  : Anthropic.Beta.Messages.BetaToolResultBlockParam['content'] {
  if (!results.length) return [{ type: 'text', text: 'No results.' }];
  return results.map(result => ({ type: 'search_result' as const, source: result.url, title: result.title,
    content: [{ type: 'text' as const, text: result.published ? `Published ${result.published}. ${result.text}` : result.text }],
    citations: { enabled: false } }));
}
/** Tokens of search results assumed per search. */
export const WEB_SEARCH_RESULT_TOKENS = 30_000;
/** Extra hold when search is offered. Each search adds a pass that re-reads the
 * whole prompt (held at the uncached write rate) and the results gathered so far
 * (on average two reads of each search's results). Sized for Anthropic's search;
 * it also bounds Tavily searches (fewer result tokens, a lower fee), so one hold
 * covers an answer that fails over from one provider to the other. */
export function webSearchHoldMicrousd(promptTokens: number, maxUses = WEB_SEARCH_MAX_USES, model = CHAT_MODEL): number {
  // Results lengthen later rounds' prompts, which can move Haiku 5.5 into its long-prompt tier.
  const { rates } = holdRule(model, promptTokens + maxUses * WEB_SEARCH_RESULT_TOKENS);
  return Math.ceil(maxUses * (WEB_SEARCH_MICROUSD + promptTokens * rates.cacheWrite5m + 2 * WEB_SEARCH_RESULT_TOKENS * rates.input));
}

/** `actionInstructions` (a selection action's own) follow the paper, after its cache breakpoint, so answers
 * with different actions on the same paper share the cached prefix (tools, shared instructions, paper). */
export function chatRequestParams(input: { instructions: string; actionInstructions?: string | null; paper: PaperContext | null;
  turns: readonly ChatTurn[]; selection: string | null; tools?: readonly Anthropic.Beta.Messages.BetaToolUnion[]; maxTokens?: number;
  /** The question's figures (chat-figures.ts), placed before its text in the last turn. */
  figures?: readonly Anthropic.Beta.Messages.BetaContentBlockParam[];
  /** A reader's chosen model and effort (chat-profiles.ts, `auto` already resolved); the default is today's Sonnet 5.5 at `low`. */
  model?: { id: string; effort: 'low' | 'medium' | 'high'; fallbacks: boolean } })
  : Anthropic.Beta.Messages.MessageCreateParamsNonStreaming {
  const model = input.model ?? { id: CHAT_MODEL, effort: CHAT_EFFORT, fallbacks: true };
  const system: Anthropic.Beta.Messages.BetaTextBlockParam[] = [{ type: 'text',
    text: input.paper || !input.actionInstructions ? input.instructions : `${input.instructions}\n\n${input.actionInstructions}` }];
  if (input.paper) {
    const cleaned = input.paper.title?.replace(/["<>\n\r]/g, ' ').trim().slice(0, 300);
    const title = cleaned ? ` title="${cleaned}"` : '';
    // The paper is cached for an hour (owner, 2026-10-16): readers pause longer than five minutes between questions,
    // and each pause re-wrote the whole paper (25 % of chat input read from cache on staging). One-hour writes cost
    // 1.6× a five-minute write and are held and settled at their own rate (`holdFor`, `priceAttempts`).
    system.push({ type: 'text', text: `<paper${title}>\n${input.paper.text}\n</paper>`, cache_control: { type: 'ephemeral', ttl: PAPER_CACHE_TTL } });
    if (input.actionInstructions) system.push({ type: 'text', text: input.actionInstructions });
  }
  const messages: Anthropic.Beta.Messages.BetaMessageParam[] = input.turns.map((turn, index) => {
    if (index === input.turns.length - 1 && (input.selection || input.figures?.length)) {
      return { role: 'user', content: [
        ...(input.selection ? [{ type: 'text' as const, text: `<selected_passage>\n${input.selection}\n</selected_passage>` }] : []),
        ...(input.figures ?? []),
        { type: 'text', text: turn.text },
      ] };
    }
    return { role: turn.role, content: turn.text };
  });
  return {
    model: model.id, max_tokens: input.maxTokens ?? CHAT_MAX_TOKENS,
    thinking: { type: 'adaptive' }, output_config: { effort: model.effort },
    // Server-side refusal fallback only where the model has fallback targets (Haiku 5.5 has none).
    ...(model.fallbacks ? { betas: [FALLBACK_BETA], fallbacks: 'default' as const } : {}),
    system, messages,
    ...(input.tools?.length ? { tools: [...input.tools] } : {}),
  };
}

/** Conservative serialized input size, in the legacy three-characters/token
 * scale accepted by holdFor. One token per UTF-8 byte avoids an ASCII prose
 * heuristic undercounting code, citations and rare symbols. Include nested tool
 * results and definitions, not just top-level text blocks. */
/** Prompt size in characters for the hold: the UTF-8 bytes of everything sent (estimateTokens divides by three; the
 * byte count already triples multi-byte text, and English prose runs about four bytes per token). Until 2026-10-14
 * this returned three times the bytes, so holds ran about 80× the actual cost and refused small balances. */
/** The request's size for the hold and per-attempt ceilings: three "characters" per UTF-8 byte, so the estimate is
 * one token per byte. Real prompts tokenize at 2–3 bytes per token (dense math and markup below 2.3): a 2–3× margin, on
 * purpose. A bytes-only count was deployed on 2026-10-14 (chat function 118) and sized a follow-up attempt's ceiling
 * at 242 micro-USD against 271 actual; that overrun paused every paid request on staging, so the margin returned the
 * same hour. A real token count (the count-tokens endpoint) is the cost audit's open item 3. */
export function promptCharacters(params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming): number {
  // An image counts as the tokens it is billed (chat-figures.ts IMAGE_HOLD_TOKENS), not as its base64 text.
  let images = 0;
  const json = JSON.stringify({ system: params.system ?? [], messages: params.messages, tools: params.tools ?? [] }, (_key, value) => {
    if (value && typeof value === 'object' && (value as { type?: unknown }).type === 'image') { images += 1; return { type: 'image' }; }
    return value;
  });
  return new TextEncoder().encode(json).byteLength * 3 + images * IMAGE_HOLD_TOKENS * 3;
}

/** `provider_billing`: the provider refused for the account's own balance ("Your credit balance is too low", staging
 * 2026-10-16 ~15:00 UTC: every Claude request failed until the owner topped it up); counted for Health › Attention. */
export type ProviderFailure = 'aborted' | 'provider_error' | 'provider_rejected' | 'provider_billing';
/** Anthropic's refusal for the account's prepaid balance (HTTP 400 `invalid_request_error`). */
export function isBillingRejection(status: number, message: unknown): boolean {
  return (status === 400 || status === 402) && /credit balance|billing|insufficient (?:balance|credit)/i.test(String(message ?? ''));
}
export interface ProviderOutcome {
  /** complete: the provider returned a final message (including a refusal). */
  status: 'complete' | 'failed';
  failure: ProviderFailure | null;
  messageID: string | null;
  /** The HTTP status of a provider error response (429, 529…), and its Retry-After: what a retry or the reader waits. */
  httpStatus?: number | null;
  retryAfterMs?: number | null;
  /** Provider transport request ID for support/reconciliation; never content. */
  requestID?: string | null;
  model: string | null;
  stopReason: string | null;
  refusalCategory: string | null;
  attempts: ProviderAttempt[];
  /** False when any billed quantity had to be estimated. */
  exact: boolean;
  /** Client tool calls in the final message (unvalidated input). */
  toolCalls?: { id?: string; name: string; input: unknown }[];
  /** The final message's content, sent back unchanged to continue after client tool calls. */
  content?: unknown[];
  /** Web searches performed (reported, or seen in the stream when cut short). */
  webSearches?: number;
  /** Web sources cited by the answer (must be shown with it). */
  sources?: { url: string; title: string | null }[];
  /** Why a failed outcome failed when it was not the provider's doing (2026-10-16, CHAT.md "When an answer stops
   * early"): `server`, our own server (an admission it could not grant or record, a fault in our code); `limit`, our own
   * bound (the next round no longer fits the hold or the search allowance). Absent: the provider failed. */
  cause?: 'server' | 'limit';
}

/**
 * The function and tests construct clients here so error classes come from the
 * same SDK instance that `streamChat` checks with instanceof.
 */
export function createAnthropicClient(options: { apiKey: string; fetch?: typeof fetch; maxRetries?: 0; timeout?: number }): Anthropic {
  // SDK logging stays off: its debug/error paths could include request or
  // response details, and this function logs only sanitized codes itself.
  // Every transport attempt needs a durable grant. SDK retries are invisible
  // to that boundary and can repeat a billed call after its response was lost.
  return new Anthropic({ apiKey: options.apiKey, maxRetries: 0, timeout: options.timeout ?? 60_000,
    logLevel: 'off', ...(options.fetch ? { fetch: options.fetch } : {}) });
}

/** Server work during an answer, relayed to the reader's device as an SSE `status` event.
 * `query` (searching only) goes to that device alone; it is never logged. */
export interface ChatStatus { kind: 'searching' | 'reading' | 'finding_paper' | 'adding_paper'; query?: string }
export const STATUS_QUERY_CHARS = 200;
/** A search query for a status line: control characters removed, whitespace collapsed, bounded. */
export function statusQuery(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const query = [...value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim()].slice(0, STATUS_QUERY_CHARS).join('');
  return query || undefined;
}
export function searchingStatus(query: unknown): ChatStatus {
  const text = statusQuery(query);
  return text ? { kind: 'searching', query: text } : { kind: 'searching' };
}

export interface StreamOptions {
  signal: AbortSignal;
  onText: (text: string) => void;
  /** Progress between pieces of text (Anthropic's server-side search). */
  onStatus?: (status: ChatStatus) => void;
  /** Estimated input tokens, charged at the uncached rate when billing is uncertain. */
  inputEstimateTokens: number;
  now?: () => number;
}

/**
 * Stream one chat turn. Never throws: every path returns what is known about
 * billing so the caller can settle exactly once.
 */
export async function streamChat(client: Anthropic, params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming,
  options: StreamOptions): Promise<ProviderOutcome> {
  const now = options.now ?? Date.now;
  let messageID: string | null = null, model: string | null = null, startedAt = 0, visible = 0, sawFallback = false, searchesSeen = 0;
  let startUsage: Usage | null = null;
  // Anthropic's search: its query streams in as the block's input; the search runs once the block ends.
  const searchInputs = new Map<number, string>();
  const partial = (failure: ProviderFailure, billedWithoutStart: boolean): ProviderOutcome => {
    if (!messageID) {
      // A rejected HTTP request is not billed. Otherwise the provider may have
      // processed input before we lost the stream: charge the estimate.
      const attempts: ProviderAttempt[] = billedWithoutStart ? [{ model: params.model, estimated: true,
        usage: { ...emptyUsage(), input: Math.max(0, options.inputEstimateTokens) } }] : [];
      return { status: 'failed', failure, messageID: null, requestID: stream?.request_id ?? null,
        model: null, stopReason: null, refusalCategory: null, attempts, exact: !billedWithoutStart };
    }
    const elapsed = Math.max(0, now() - startedAt);
    const output = Math.min(params.max_tokens, Math.max(Math.ceil(visible / 3), Math.ceil(elapsed / 1000 * ESTIMATED_OUTPUT_TOKENS_PER_SECOND)));
    const [start] = attemptsFromUsage(sawFallback ? null : model, startUsage);
    const usage = start ? { ...start.usage, output: Math.max(start.usage.output, output) } : { ...emptyUsage(), input: options.inputEstimateTokens, output };
    // Each search seen implied another pass over the prompt plus its results.
    usage.input += searchesSeen * (Math.max(0, options.inputEstimateTokens) + WEB_SEARCH_RESULT_TOKENS);
    return { status: 'failed', failure, messageID, requestID: stream?.request_id ?? null, model, stopReason: null, refusalCategory: null,
      attempts: [{ model: sawFallback ? null : model, usage, estimated: true }], exact: false, ...(searchesSeen ? { webSearches: searchesSeen } : {}) };
  };
  let stream: ReturnType<typeof client.beta.messages.stream> | undefined;
  try {
    if (options.signal.aborted) return partial('aborted', false);
    stream = client.beta.messages.stream(params, { signal: options.signal });
    for await (const event of stream) {
      if (event.type === 'message_start') {
        messageID = event.message.id; model = event.message.model; startUsage = event.message.usage; startedAt = now();
      } else if (event.type === 'content_block_start' && (event.content_block as { type: string }).type === 'fallback') {
        sawFallback = true;
      } else if (event.type === 'content_block_start' && event.content_block.type === 'server_tool_use' && event.content_block.name === 'web_search') {
        searchesSeen++;
        searchInputs.set(event.index, '');
      } else if (event.type === 'content_block_delta' && event.delta.type === 'input_json_delta' && searchInputs.has(event.index)) {
        searchInputs.set(event.index, (searchInputs.get(event.index)! + event.delta.partial_json).slice(0, 4_000));
      } else if (event.type === 'content_block_stop' && searchInputs.has(event.index)) {
        let query: unknown;
        try { query = (JSON.parse(searchInputs.get(event.index)!) as { query?: unknown } | null)?.query; } catch { query = undefined; }
        searchInputs.delete(event.index);
        options.onStatus?.(searchingStatus(query));
      } else if (event.type === 'content_block_start' && (event.content_block as { type: string }).type === 'web_search_tool_result') {
        options.onStatus?.({ kind: 'reading' });
      } else if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
        visible += event.delta.text.length;
        options.onText(event.delta.text);
      }
    }
    const message = await stream.finalMessage();
    const attempts = attemptsFromUsage(message.model, message.usage);
    const toolCalls: { id: string; name: string; input: unknown }[] = [];
    const sources = new Map<string, string | null>();
    for (const block of message.content as Anthropic.Beta.Messages.BetaContentBlock[]) {
      // Only the serving attempt's calls count: a fallback restarts the turn.
      if ((block as { type: string }).type === 'fallback') { toolCalls.length = 0; sources.clear(); }
      else if (block.type === 'tool_use') toolCalls.push({ id: block.id, name: block.name, input: block.input });
      else if (block.type === 'text') {
        for (const citation of block.citations ?? []) {
          if (citation.type === 'web_search_result_location' && !sources.has(citation.url)) sources.set(citation.url, citation.title);
          // search_web (Tavily) results: the source is the page address the server supplied.
          else if (citation.type === 'search_result_location' && /^https:\/\//.test(citation.source) && !sources.has(citation.source)) {
            sources.set(citation.source, citation.title ?? null);
          }
        }
      }
    }
    const webSearches = Math.max(searchesSeen, count(message.usage.server_tool_use?.web_search_requests));
    const finalUsage = message.usage && Number.isSafeInteger(message.usage.input_tokens) && message.usage.input_tokens >= 0
      && Number.isSafeInteger(message.usage.output_tokens) && message.usage.output_tokens >= 0 && attempts.length > 0;
    return { status: 'complete', failure: null, messageID: message.id, requestID: stream.request_id ?? null, model: message.model, stopReason: message.stop_reason,
      refusalCategory: message.stop_details?.category ?? null, attempts, exact: !!finalUsage, ...(toolCalls.length ? { toolCalls } : {}),
      content: message.content as unknown[],
      ...(webSearches ? { webSearches } : {}), ...(sources.size ? { sources: [...sources].map(([url, title]) => ({ url, title })) } : {}) };
  } catch (error) {
    stream?.abort();
    if (error instanceof Anthropic.APIUserAbortError || options.signal.aborted) return partial('aborted', true);
    // Explicit validation/auth/rate-limit rejections precede processing. A 5xx
    // or timeout can follow processing: retain uncertainty, even before start.
    if (error instanceof Anthropic.APIError && typeof error.status === 'number' && !(error instanceof Anthropic.APIConnectionError)) {
      const rejected = [400, 401, 403, 404, 413, 422, 429].includes(error.status);
      const outcome = partial(error.status >= 500 || error.status === 429 ? 'provider_error'
        : isBillingRejection(error.status, error.message) ? 'provider_billing' : 'provider_rejected', !rejected);
      return { ...outcome, httpStatus: error.status, retryAfterMs: retryAfterMs(error.headers) };
    }
    return partial('provider_error', true);
  }
}

/** Retry-After from an SDK error's headers (seconds or an HTTP date), in milliseconds; null when absent. */
function retryAfterMs(headers: unknown): number | null {
  let value: string | null | undefined;
  try { value = headers instanceof Headers ? headers.get('retry-after') : (headers as Record<string, string> | undefined)?.['retry-after']; } catch { value = null; }
  if (!value) return null;
  if (/^\d{1,6}$/.test(value.trim())) return Number(value.trim()) * 1000;
  const at = Date.parse(value);
  return Number.isFinite(at) ? Math.max(0, at - Date.now()) : null;
}

/** The longest wait worth a retry inside one answer; a longer Retry-After (or a breaker's cool-off) goes to the reader. */
export const BUSY_RETRY_MAX_MS = 5_000;
/** One more try when the provider refused the request before starting it, as busy (429) or overloaded (529): after its
 * Retry-After (or 1–3 s), at most 5 s, never after the first token. The refused try started nothing: it admitted and
 * settled its own grant (zero for a 429; a 529's kept as a liability by the platform), and the reader is charged only
 * for the answer that runs, as for any answer. Resilience (docs/architecture/RESILIENCE.md, fix 7). */
export function retryOnceWhenBusy<O extends { signal: AbortSignal }>(
  generate: (params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: O) => Promise<ProviderOutcome>,
  deps: { sleep?: (ms: number) => Promise<void>; random?: () => number; log?: (entry: Record<string, string | number | boolean | null>) => void } = {}) {
  const sleep = deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms))), random = deps.random ?? Math.random;
  return async (params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: O): Promise<ProviderOutcome> => {
    const first = await generate(params, options);
    const busy = first.status === 'failed' && !first.messageID && (first.httpStatus === 429 || first.httpStatus === 529);
    if (!busy || options.signal.aborted) return first;
    const wait = first.retryAfterMs ?? 1_000 + random() * 2_000;
    if (wait > BUSY_RETRY_MAX_MS) return first;
    deps.log?.({ event: 'provider_busy_retry', status: first.httpStatus ?? null, wait_ms: Math.round(wait) });
    await sleep(Math.max(250, wait));
    if (options.signal.aborted) return first;
    return generate(params, options);
  };
}
