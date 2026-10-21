import { isRouterDeepSeek, routerDeepSeekRates, ROUTER_DEEPSEEK_TARIFF } from "./openrouter-deepseek-pricing.ts";
import type { OpenRouterAttribution } from "./openrouter-transport.ts";
import { isRouterClaude, routerClaudeRates, ROUTER_CLAUDE_TARIFF } from './openrouter-claude-pricing.ts';
// Paid model calls: pricing and holds, the request a chat answer sends, its tools, and the outcome every adapter returns.
// OpenRouter is the only inference provider (owner, 2026-10-18; reaffirmed 2026-10-21 "exclusively use open router"):
// openrouter-chat.ts sends every call. Deno and Node compatible. Never log prompts, answers or keys here.
import { IMAGE_HOLD_TOKENS } from './chat-figures.ts';
import { GEMINI_MODEL, GEMINI_RATES, GEMINI_TARIFF } from './gemini-pricing.ts';
import type { Effort, ModelRequest, TextBlock, ToolDefinition, ToolResultBlock, ContentBlock, MessageParam } from './model-request.ts';

/** The default answer model (Sonnet 5.5 through OpenRouter's Google Vertex route). */
export const CHAT_MODEL = 'anthropic/claude-sonnet-5.5';
export const CHAT_MAX_TOKENS = 8000;
// Chat and paper Q&A: `low` effort. It also skips reasoning on simple turns, keeping time-to-first-token and cost down.
export const CHAT_EFFORT = 'low' as const;
export const RATE_VERSION = 'beta-credits-v1';
// beta-credits-v1: one credit is $0.01 charged at twice provider cost.
export const MICROUSD_PER_CREDIT = 5_000;
// Output observed before a stream ended without final usage (abort/error): at least this many tokens per second.
export const ESTIMATED_OUTPUT_TOKENS_PER_SECOND = 100;

/** How long the paper block stays in the route's prompt cache (Claude through Vertex honors the one-hour breakpoint). */
export const PAPER_CACHE_TTL = '1h' as const;
/** Provider prices in micro-USD per token ($/MTok = µ$/token). */
export interface TokenRates { input: number; cacheWrite5m: number; cacheWrite1h: number; cacheRead: number; output: number }
/** A model no reviewed OpenRouter card names is held and priced above every card (Opus 5.5 through Vertex is $4.40 in,
 * $22 out): it can only arise from our own mistake, and it must never under-hold. */
export const UNKNOWN_MODEL_RATES: TokenRates = Object.freeze({ input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25 });
/** Attempts held for a model without a reviewed card. */
export const UNKNOWN_MODEL_HOLD_ATTEMPTS = 3;
/** DeepSeek's tokenizer and tool template cannot be counted before the request (no count endpoint), so the byte
 * estimate gets twice the margin a Claude prompt gets. */
export const DEEPSEEK_HOLD_ATTEMPTS = 2;

/** The reviewed OpenRouter card a model is quoted and priced at (migration 0101 holds each card's validity); null for a
 * model without one. */
export function tariffFor(model: string): string | null {
  if (isRouterDeepSeek(model)) return ROUTER_DEEPSEEK_TARIFF;
  if (isRouterClaude(model)) return ROUTER_CLAUDE_TARIFF;
  if (model === GEMINI_MODEL) return GEMINI_TARIFF;
  return null;
}

/** `promptTokens` (the whole prompt: uncached, cache-write and cache-read tokens) chooses Haiku 5.5's tier. */
export function ratesFor(model: string | null | undefined, promptTokens = 0): { rates: TokenRates; known: boolean } {
  if (typeof model === 'string' && isRouterDeepSeek(model)) return { rates: routerDeepSeekRates(model), known: true };
  if (typeof model === 'string' && isRouterClaude(model)) return { rates: routerClaudeRates(model, promptTokens), known: true };
  if (model === GEMINI_MODEL) return { rates: GEMINI_RATES, known: true };
  return { rates: UNKNOWN_MODEL_RATES, known: false };
}

export interface TokenUsage { input: number; cacheWrite5m: number; cacheWrite1h: number; cacheRead: number; output: number }
/** One billed request to OpenRouter. */
export interface ProviderAttempt {
  model: string | null; usage: TokenUsage; estimated: boolean;
  /** Exact billed inference cost from OpenRouter final usage (cache storage included; credit-purchase fees excluded). */
  billedMicrousd?: number;
  /** Google cache storage creation overlaps input/read tokens; keep it out of the disjoint token counts above. */
  cacheStorageTokens?: number;
  /** An attempt cut short (a Stop, a dropped stream): the micro-USD of the part that was written, which is all a reader
   * can be charged for it (PROVIDER_SPENDING.md "Stopped answers and unresolved attempts"). Absent on a finished attempt,
   * whose whole price reached the reader. */
  readerMicrousd?: number;
}

export function emptyUsage(): TokenUsage { return { input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 }; }

/** What a reader can be charged for these attempts (micro-USD, possibly fractional): a cut-short attempt's written part,
 * a finished attempt's price, and nothing for an estimate without an observation of what was written (an estimate is
 * the platform's liability, never the reader's bill). */
export function readerPriceAttempts(attempts: readonly ProviderAttempt[]): number {
  let total = 0;
  for (const attempt of attempts) {
    if (typeof attempt.readerMicrousd === 'number' && Number.isFinite(attempt.readerMicrousd) && attempt.readerMicrousd >= 0) total += attempt.readerMicrousd;
    else if (!attempt.estimated) total += priceAttempts([attempt]);
  }
  return total;
}

/** Exact micro-USD (possibly fractional) for the attempts; callers round up once. OpenRouter's reported cost when it
 * came with the attempt, else the model's card. */
export function priceAttempts(attempts: readonly ProviderAttempt[]): number {
  let total = 0;
  for (const attempt of attempts) {
    if (!attempt.estimated && typeof attempt.billedMicrousd === 'number' && Number.isFinite(attempt.billedMicrousd) && attempt.billedMicrousd >= 0) {
      total += attempt.billedMicrousd;
      continue;
    }
    const u = attempt.usage;
    const { rates } = ratesFor(attempt.model, u.input + u.cacheWrite5m + u.cacheWrite1h + u.cacheRead);
    total += u.input * rates.input + u.cacheWrite5m * rates.cacheWrite5m + u.cacheWrite1h * rates.cacheWrite1h
      + u.cacheRead * rates.cacheRead + u.output * rates.output;
  }
  return total;
}

export function creditsFor(microusd: number): number { return Math.ceil(Math.max(0, microusd) / MICROUSD_PER_CREDIT); }
export function estimateTokens(characters: number): number { return Math.ceil(Math.max(0, characters) / 3); }

/**
 * How one request to `model` is held: the rate card every token is held at and how many full attempts. Claude through
 * OpenRouter: its own Vertex card, one attempt (no server-side fallback on this route; Haiku 5.5 at the tier the
 * estimated prompt falls in, and the byte estimate never undercounts tokens, so it never picks the cheaper tier
 * wrongly). DeepSeek through OpenRouter: its DeepInfra card, `DEEPSEEK_HOLD_ATTEMPTS`. Gemini Flash: its card, one
 * attempt. Anything else: the unknown card, `UNKNOWN_MODEL_HOLD_ATTEMPTS`.
 */
export function holdRule(model: string, promptTokens: number): { rates: TokenRates; attempts: number } {
  if (isRouterDeepSeek(model)) return { rates: routerDeepSeekRates(model), attempts: DEEPSEEK_HOLD_ATTEMPTS };
  if (isRouterClaude(model)) return { rates: routerClaudeRates(model, promptTokens), attempts: 1 };
  if (model === GEMINI_MODEL) return { rates: GEMINI_RATES, attempts: 1 };
  return { rates: UNKNOWN_MODEL_RATES, attempts: UNKNOWN_MODEL_HOLD_ATTEMPTS };
}

/**
 * Hold ceiling: every estimated input token at the cache-write rate plus the whole output budget (reasoning counts
 * toward max_tokens), times the attempts. `inputCharacters` is the weighted count from `promptCharacters`;
 * `hourCharacters` is the part cached for an hour (the paper, `PAPER_CACHE_TTL`), held at the one-hour write rate so a
 * hold always covers the real write.
 */
export function holdFor(inputCharacters: number, maxTokens = CHAT_MAX_TOKENS, model = CHAT_MODEL, hourCharacters = 0): { inputTokens: number; microusd: number; credits: number } {
  const inputTokens = estimateTokens(inputCharacters);
  const hourTokens = Math.min(inputTokens, estimateTokens(hourCharacters));
  const { rates, attempts } = holdRule(model, inputTokens);
  const microusd = Math.ceil((hourTokens * rates.cacheWrite1h + (inputTokens - hourTokens) * rates.cacheWrite5m + maxTokens * rates.output) * attempts);
  return { inputTokens, microusd, credits: creditsFor(microusd) };
}

/** The characters of the system blocks cached for an hour (weighted as `promptCharacters` weighs them). */
export function hourCachedCharacters(params: ModelRequest): number {
  const blocks = (Array.isArray(params.system) ? params.system : []).filter(b => b.cache_control?.ttl === '1h');
  return blocks.length ? new TextEncoder().encode(JSON.stringify(blocks)).byteLength * 3 : 0;
}

/** The hold for one admitted request, from its own model, prompt and output allowance. */
export function holdForParams(params: ModelRequest): { inputTokens: number; microusd: number; credits: number } {
  // One byte per token already bounds user content; this extra allowance covers OpenRouter's translated tool template.
  return holdFor(promptCharacters(params) + 3 * 1024, params.max_tokens, params.model, hourCachedCharacters(params));
}

export interface ChatTurn { role: 'user' | 'assistant'; text: string }
export interface PaperContext { title: string | null; text: string }

/** Ingest's one client tool. The server finds the paper by title (strict
 * match; arXiv first, then an open-access copy through OpenAlex) and adds it as
 * the reader; the result is reported to the reader directly, so the tool needs
 * no second model call. */
export const ADD_PAPER_TOOL: ToolDefinition = {
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
export const CREATE_DIAGRAM_TOOL: ToolDefinition = {
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
export const CREATE_VISUAL_TOOL: ToolDefinition = {
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

/** Web search in chat: `search_web`, a function tool the model calls through OpenRouter and our server runs with
 * Tavily (docs/architecture/CHAT.md "Web search"). Off unless the server enables it; at most three searches per answer.
 * No provider-native search tool is offered: its cost could not be bounded before the request, and it would not be an
 * OpenRouter generation. */
export const WEB_SEARCH_MAX_USES = 3;
/** Related (finding related papers) plans several targeted searches. */
export const RELATED_SEARCH_MAX_USES = 5;
/** Per search, held with the answer: above Tavily's pay-as-you-go $0.008 a credit (a basic search is one credit). */
export const WEB_SEARCH_MICROUSD = 10_000;
/** Tavily search: the reader is charged Tavily's pay-as-you-go price per credit
 * ($0.008; a basic search is one credit) however the plan was paid for. Searches
 * within the prepaid plan add nothing to provider spend (a fixed commitment). */
export const TAVILY_CREDIT_MICROUSD = 8_000;
export const SEARCH_WEB_TOOL: ToolDefinition = {
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
/** search_web results as search_result blocks (sent to the model as text naming each page's address). The answer
 * names its sources itself (WEB_SEARCH_INSTRUCTIONS); otherwise the server lists the searched pages. */
export function searchResultContent(results: readonly { url: string; title: string; text: string; published: string | null }[])
  : ToolResultBlock['content'] {
  if (!results.length) return [{ type: 'text', text: 'No results.' }];
  return results.map(result => ({ type: 'search_result' as const, source: result.url, title: result.title,
    content: [{ type: 'text' as const, text: result.published ? `Published ${result.published}. ${result.text}` : result.text }],
    citations: { enabled: false } }));
}
/** Tokens of search results held per search (Tavily's results are about 2,500 tokens: five extracts of 1,500 characters). */
export const WEB_SEARCH_RESULT_TOKENS = 30_000;
/** Extra hold when search is offered. Each search adds a round that re-reads the whole prompt (held at the uncached
 * write rate) and the results gathered so far (on average two reads of each search's results). */
export function webSearchHoldMicrousd(promptTokens: number, maxUses = WEB_SEARCH_MAX_USES, model = CHAT_MODEL): number {
  // Results lengthen later rounds' prompts, which can move Haiku 5.5 into its long-prompt tier.
  const { rates } = holdRule(model, promptTokens + maxUses * WEB_SEARCH_RESULT_TOKENS);
  return Math.ceil(maxUses * (WEB_SEARCH_MICROUSD + promptTokens * rates.cacheWrite5m + 2 * WEB_SEARCH_RESULT_TOKENS * rates.input));
}

/** `actionInstructions` (a selection action's own) follow the paper, after its cache breakpoint, so answers
 * with different actions on the same paper share the cached prefix (tools, shared instructions, paper). */
export function chatRequestParams(input: { instructions: string; actionInstructions?: string | null; paper: PaperContext | null;
  turns: readonly ChatTurn[]; selection: string | null; tools?: readonly ToolDefinition[]; maxTokens?: number;
  /** The question's figures (chat-figures.ts), placed before its text in the last turn. */
  figures?: readonly ContentBlock[];
  /** A reader's chosen model and effort (chat-profiles.ts, `auto` already resolved); the default is Sonnet 5.5 at `low`. */
  model?: { id: string; effort: Effort } })
  : ModelRequest {
  const model = input.model ?? { id: CHAT_MODEL, effort: CHAT_EFFORT };
  const system: TextBlock[] = [{ type: 'text',
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
  const messages: MessageParam[] = input.turns.map((turn, index) => {
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
    system, messages,
    ...(input.tools?.length ? { tools: [...input.tools] } : {}),
  };
}

/** The request's size for the hold and per-attempt ceilings: three "characters" per UTF-8 byte, so the estimate is
 * one token per byte. Real prompts tokenize at 2–3 bytes per token (dense math and markup below 2.3): a 2–3× margin, on
 * purpose. A bytes-only count was deployed on 2026-10-14 (chat function 118) and sized a follow-up attempt's ceiling
 * at 242 micro-USD against 271 actual; that overrun paused every paid request on staging, so the margin returned the
 * same hour. Nested tool results and definitions count, not just top-level text blocks. */
export function promptCharacters(params: ModelRequest): number {
  // An image counts as the tokens it is billed (chat-figures.ts IMAGE_HOLD_TOKENS), not as its base64 text.
  let images = 0;
  const json = JSON.stringify({ system: params.system ?? [], messages: params.messages, tools: params.tools ?? [] }, (_key, value) => {
    if (value && typeof value === 'object' && (value as { type?: unknown }).type === 'image') { images += 1; return { type: 'image' }; }
    return value;
  });
  return new TextEncoder().encode(json).byteLength * 3 + images * IMAGE_HOLD_TOKENS * 3;
}

/** `provider_billing`: OpenRouter refused for the organization's balance (HTTP 402); counted for Health › Attention. */
export type ProviderFailure = 'aborted' | 'provider_error' | 'provider_rejected' | 'provider_billing';
export interface ProviderOutcome {
  /** complete: the provider returned a final message (including a refusal). */
  status: 'complete' | 'failed';
  failure: ProviderFailure | null;
  messageID: string | null;
  /** The HTTP status of a provider error response (429, 529…), and its Retry-After: what a retry or the reader waits. */
  httpStatus?: number | null;
  /** Fixed diagnostic category only; never the provider's raw error text or submitted content. */
  rejectionReason?: 'privacy_zdr' | 'privacy_policy' | 'route_unavailable' | 'authentication' | 'balance' | 'request_parameters' | 'tariff_expired' | 'unknown';
  retryAfterMs?: number | null;
  /** Provider transport request ID (OpenRouter's generation id) for support/reconciliation; never content. */
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
  /** Web pages the answer's searches returned (must be shown with it when the answer names none itself). */
  sources?: { url: string; title: string | null }[];
  /** Why a failed outcome failed when it was not the provider's doing (2026-10-16, CHAT.md "When an answer stops
   * early"): `server`, our own server (an admission it could not grant or record, a fault in our code); `limit`, our own
   * bound (the next round no longer fits the hold or the search allowance). Absent: the provider failed. */
  cause?: 'server' | 'limit';
  /** The generation receipt still being written (C6): awaited with the attempt's finish, never before the outcome returns. */
  receipt?: Promise<boolean>;
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
  attribution?: OpenRouterAttribution;
  /** Closed auxiliary purpose; never derived from question/title text. */
  purpose?: 'topic_title';
  signal: AbortSignal;
  onText: (text: string) => void;
  /** Progress between pieces of text (our search rounds). */
  onStatus?: (status: ChatStatus) => void;
  /** Estimated input tokens, charged at the uncached rate when billing is uncertain. */
  inputEstimateTokens: number;
  now?: () => number;
}

/** The longest wait worth a retry inside one answer; a longer Retry-After (or a breaker's cool-off) goes to the reader. */
export const BUSY_RETRY_MAX_MS = 5_000;
/** One more try when the provider refused the request before starting it, as busy (429) or overloaded (529): after its
 * Retry-After (or 1–3 s), at most 5 s, never after the first token. The refused try started nothing: it admitted and
 * settled its own grant (zero for a 429; a 529's kept as a liability by the platform), and the reader is charged only
 * for the answer that runs, as for any answer. Resilience (docs/architecture/RESILIENCE.md, fix 7). */
export function retryOnceWhenBusy<O extends { signal: AbortSignal }>(
  generate: (params: ModelRequest, options: O) => Promise<ProviderOutcome>,
  deps: { sleep?: (ms: number) => Promise<void>; random?: () => number; log?: (entry: Record<string, string | number | boolean | null>) => void } = {}) {
  const sleep = deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms))), random = deps.random ?? Math.random;
  return async (params: ModelRequest, options: O): Promise<ProviderOutcome> => {
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
