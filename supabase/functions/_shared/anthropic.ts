// Anthropic provider boundary for paid chat. Deno and Node compatible: no
// runtime globals beyond fetch/AbortSignal, so tests can drive the real SDK
// with a fake fetch. Never log prompts, answers, or the API key here.
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
export interface TokenRates { input: number; cacheWrite5m: number; cacheWrite1h: number; cacheRead: number; output: number }
const SONNET: TokenRates = Object.freeze({ input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2, output: 10 });
// Unknown serving model: price at the highest current general-availability
// rate card supplied for this route (Claude Opus 5.5, $4 / $20 per MTok).
export const UNKNOWN_MODEL_RATES: TokenRates = Object.freeze({ input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.4, output: 20 });
const KNOWN_RATES: Readonly<Record<string, TokenRates>> = Object.freeze({ 'claude-sonnet-5-5': SONNET, 'claude-sonnet-5': SONNET });

export function ratesFor(model: string | null | undefined): { rates: TokenRates; known: boolean } {
  const canonical = typeof model === 'string' ? model.replace(/-\d{8}$/, '') : '';
  const rates = Object.hasOwn(KNOWN_RATES, canonical) ? KNOWN_RATES[canonical] : undefined;
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
    const { rates } = ratesFor(attempt.model), u = attempt.usage;
    total += u.input * rates.input + u.cacheWrite5m * rates.cacheWrite5m + u.cacheWrite1h * rates.cacheWrite1h
      + u.cacheRead * rates.cacheRead + u.output * rates.output;
  }
  return total;
}

export function creditsFor(microusd: number): number { return Math.ceil(Math.max(0, microusd) / MICROUSD_PER_CREDIT); }
export function estimateTokens(characters: number): number { return Math.ceil(Math.max(0, characters) / 3); }

/** Headroom for a refused attempt plus a server-side fallback attempt that may
 * be priced at a higher tier (unknown models price at Opus 5.5). */
export const FALLBACK_HOLD_FACTOR = 3;

/**
 * Hold ceiling: every estimated input token at the cache-write rate plus the
 * whole output budget (thinking counts toward max_tokens), times the fallback
 * headroom. `inputCharacters` is the weighted count from `promptCharacters`.
 */
export function holdFor(inputCharacters: number, maxTokens = CHAT_MAX_TOKENS): { inputTokens: number; microusd: number; credits: number } {
  const inputTokens = estimateTokens(inputCharacters);
  const microusd = Math.ceil((inputTokens * SONNET.cacheWrite5m + maxTokens * SONNET.output) * FALLBACK_HOLD_FACTOR);
  return { inputTokens, microusd, credits: creditsFor(microusd) };
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
/** search_web results as citable search_result blocks (citations always on: a
 * request's search results must all use the same setting). */
export function searchResultContent(results: readonly { url: string; title: string; text: string; published: string | null }[])
  : Anthropic.Beta.Messages.BetaToolResultBlockParam['content'] {
  if (!results.length) return [{ type: 'text', text: 'No results.' }];
  return results.map(result => ({ type: 'search_result' as const, source: result.url, title: result.title,
    content: [{ type: 'text' as const, text: result.published ? `Published ${result.published}. ${result.text}` : result.text }],
    citations: { enabled: true } }));
}
/** Tokens of search results assumed per search. */
export const WEB_SEARCH_RESULT_TOKENS = 30_000;
/** Extra hold when search is offered. Each search adds a pass that re-reads the
 * whole prompt (held at the uncached write rate) and the results gathered so far
 * (on average two reads of each search's results). Sized for Anthropic's search;
 * it also bounds Tavily searches (fewer result tokens, a lower fee), so one hold
 * covers an answer that fails over from one provider to the other. */
export function webSearchHoldMicrousd(promptTokens: number, maxUses = WEB_SEARCH_MAX_USES): number {
  return Math.ceil(maxUses * (WEB_SEARCH_MICROUSD + promptTokens * SONNET.cacheWrite5m + 2 * WEB_SEARCH_RESULT_TOKENS * SONNET.input));
}

export function chatRequestParams(input: { instructions: string; paper: PaperContext | null; turns: readonly ChatTurn[]; selection: string | null;
  tools?: readonly Anthropic.Beta.Messages.BetaToolUnion[]; maxTokens?: number })
  : Anthropic.Beta.Messages.MessageCreateParamsNonStreaming {
  const system: Anthropic.Beta.Messages.BetaTextBlockParam[] = [{ type: 'text', text: input.instructions }];
  if (input.paper) {
    const cleaned = input.paper.title?.replace(/["<>\n\r]/g, ' ').trim().slice(0, 300);
    const title = cleaned ? ` title="${cleaned}"` : '';
    system.push({ type: 'text', text: `<paper${title}>\n${input.paper.text}\n</paper>`, cache_control: { type: 'ephemeral' } });
  }
  const messages: Anthropic.Beta.Messages.BetaMessageParam[] = input.turns.map((turn, index) => {
    if (index === input.turns.length - 1 && input.selection) {
      return { role: 'user', content: [
        { type: 'text', text: `<selected_passage>\n${input.selection}\n</selected_passage>` },
        { type: 'text', text: turn.text },
      ] };
    }
    return { role: turn.role, content: turn.text };
  });
  return {
    model: CHAT_MODEL, max_tokens: input.maxTokens ?? CHAT_MAX_TOKENS,
    thinking: { type: 'adaptive' }, output_config: { effort: CHAT_EFFORT },
    betas: [FALLBACK_BETA], fallbacks: 'default',
    system, messages,
    ...(input.tools?.length ? { tools: [...input.tools] } : {}),
  };
}

/** Weighted character count for the hold estimate (all prompt text sent):
 * ASCII counts 1 (≈3 per token); every UTF-8 byte of non-ASCII text counts 3,
 * i.e. one token per byte, which bounds CJK and rare-symbol tokenization. */
export function promptCharacters(params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming): number {
  let total = 0;
  const weigh = (text: string) => {
    for (const ch of text) { const code = ch.codePointAt(0)!; total += code < 0x80 ? 1 : 3 * (code < 0x800 ? 2 : code < 0x10000 ? 3 : 4); }
  };
  const add = (content: unknown) => {
    if (typeof content === 'string') { weigh(content); return; }
    if (Array.isArray(content)) for (const block of content) if (block && typeof block === 'object' && typeof (block as { text?: unknown }).text === 'string') weigh((block as { text: string }).text);
  };
  add(params.system);
  for (const message of params.messages) add(message.content);
  if (params.tools?.length) weigh(JSON.stringify(params.tools));
  return total;
}

export type ProviderFailure = 'aborted' | 'provider_error' | 'provider_rejected';
export interface ProviderOutcome {
  /** complete: the provider returned a final message (including a refusal). */
  status: 'complete' | 'failed';
  failure: ProviderFailure | null;
  messageID: string | null;
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
}

/**
 * The function and tests construct clients here so error classes come from the
 * same SDK instance that `streamChat` checks with instanceof.
 */
export function createAnthropicClient(options: { apiKey: string; fetch?: typeof fetch; maxRetries?: number; timeout?: number }): Anthropic {
  // SDK logging stays off: its debug/error paths could include request or
  // response details, and this function logs only sanitized codes itself.
  return new Anthropic({ apiKey: options.apiKey, maxRetries: options.maxRetries ?? 1, timeout: options.timeout ?? 60_000,
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
      return { status: 'failed', failure, messageID: null, model: null, stopReason: null, refusalCategory: null, attempts, exact: !billedWithoutStart };
    }
    const elapsed = Math.max(0, now() - startedAt);
    const output = Math.min(params.max_tokens, Math.max(Math.ceil(visible / 3), Math.ceil(elapsed / 1000 * ESTIMATED_OUTPUT_TOKENS_PER_SECOND)));
    const [start] = attemptsFromUsage(sawFallback ? null : model, startUsage);
    const usage = start ? { ...start.usage, output: Math.max(start.usage.output, output) } : { ...emptyUsage(), input: options.inputEstimateTokens, output };
    // Each search seen implied another pass over the prompt plus its results.
    usage.input += searchesSeen * (Math.max(0, options.inputEstimateTokens) + WEB_SEARCH_RESULT_TOKENS);
    return { status: 'failed', failure, messageID, model, stopReason: null, refusalCategory: null,
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
    return { status: 'complete', failure: null, messageID: message.id, model: message.model, stopReason: message.stop_reason,
      refusalCategory: message.stop_details?.category ?? null, attempts, exact: true, ...(toolCalls.length ? { toolCalls } : {}),
      content: message.content as unknown[],
      ...(webSearches ? { webSearches } : {}), ...(sources.size ? { sources: [...sources].map(([url, title]) => ({ url, title })) } : {}) };
  } catch (error) {
    stream?.abort();
    if (error instanceof Anthropic.APIUserAbortError || options.signal.aborted) return partial('aborted', true);
    // A typed HTTP status before message_start means the request was rejected
    // (429/5xx/4xx) and not billed; mid-stream error events still bill output.
    if (error instanceof Anthropic.APIError && typeof error.status === 'number' && !(error instanceof Anthropic.APIConnectionError)) {
      return partial(error.status >= 500 || error.status === 429 ? 'provider_error' : 'provider_rejected', false);
    }
    return partial('provider_error', true);
  }
}
