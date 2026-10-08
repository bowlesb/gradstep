// Paid chat orchestration: validation, context, hold -> provider -> settle.
// Deno and Node compatible (no Deno globals). Never log request or answer
// text; logs carry only operation IDs, codes and counts.
import {
  ADD_PAPER_TOOL, CHAT_MAX_TOKENS, chatRequestParams, CREATE_DIAGRAM_TOOL, creditsFor, holdFor, priceAttempts, promptCharacters, RATE_VERSION,
  SEARCH_WEB_TOOL, searchResultContent, TAVILY_CREDIT_MICROUSD, WEB_SEARCH_MAX_USES, WEB_SEARCH_MICROUSD, WEB_SEARCH_TOOL,
  webSearchHoldMicrousd, RELATED_SEARCH_MAX_USES, RELATED_WEB_SEARCH_TOOL, searchingStatus,
  type ChatStatus, type ChatTurn, type PaperContext, type ProviderAttempt, type ProviderOutcome, type StreamOptions,
} from './anthropic.ts';
import { searchInput, type SearchInput, type SearchOutcome } from './tavily.ts';
import type Anthropic from '@anthropic-ai/sdk';

/** The consent text the reader accepted. v2 names Tavily as a search provider;
 * v1 (builds up to TestFlight 11) names only Anthropic's, so v1 answers never use Tavily. */
export const CONSENT_VERSION = 'cloud-ai-v2';
export const CONSENT_VERSIONS: readonly string[] = ['cloud-ai-v1', CONSENT_VERSION];
export const MAX_BODY_BYTES = 512 * 1024;
export const MAX_TURNS = 60;
export const MAX_MESSAGE_BYTES = 200_000;
export const MAX_SELECTION_SCALARS = 4_000;
export const MAX_PAPER_BYTES = 2 * 1024 * 1024;
export const GENERATION_DEADLINE_MS = 130_000;

export type ChatErrorCode = 'insufficient_credits' | 'platform_budget_exhausted' | 'rate_limited' | 'document_unavailable'
  | 'provider_unavailable' | 'refused' | 'invalid_request' | 'operation_replayed' | 'service_unavailable';

export class ChatFailure extends Error {
  readonly code: ChatErrorCode;
  constructor(code: ChatErrorCode) { super(code); this.code = code; }
}
/** A database exception message (RAISE text) from PostgREST. */
export class RpcFailure extends Error {
  readonly reason: string;
  constructor(reason: string) { super('rpc_failed'); this.reason = reason; }
}

export interface ChatRequest {
  operationID: string;
  consentVersion: string;
  mode: 'paper' | 'general';
  documentID: string | null;
  turns: ChatTurn[];
  selection: string | null;
  /** Selection action needing server work beyond an answer: Ingest (add the cited paper),
   * Related (find related papers; always searches the web when search is on), Why it matters
   * (`relevance`: the paper only, no web search), or a diagram the device could not draw
   * (`diagram_fix`: one corrected diagram; see DIAGRAM_FIX_MAX_TOKENS). */
  action: ChatAction | null;
  /** Client features: 'web_import' = the app shows web (non-arXiv) library entries. */
  capabilities: string[];
}

export const CLIENT_CAPABILITIES = ['web_import'] as const;
export type ChatAction = 'ingest' | 'related' | 'relevance' | 'diagram_fix';
const CHAT_ACTIONS: readonly string[] = ['ingest', 'related', 'relevance', 'diagram_fix'];
/** A diagram repair: the broken source and Mermaid's error, as one user turn from the device. */
export const DIAGRAM_FIX_MAX_BYTES = 24_000;
/** A repair writes one diagram (no prose): a small output allowance keeps its hold and cost small. */
export const DIAGRAM_FIX_MAX_TOKENS = 2_000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
function invalid(): never { throw new ChatFailure('invalid_request'); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function onlyKeys(value: Record<string, unknown>, allowed: readonly string[]) {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) invalid();
}
function id(value: unknown): string {
  if (typeof value !== 'string' || !UUID.test(value)) invalid();
  return value.toLowerCase();
}

/** Strict, bounded validation. Unknown fields are rejected, not ignored. */
export function validateChatRequest(input: unknown): ChatRequest {
  const body = record(input);
  onlyKeys(body, ['operation_id', 'consent_version', 'mode', 'document_id', 'messages', 'selection', 'action', 'capabilities']);
  if (typeof body.consent_version !== 'string' || !CONSENT_VERSIONS.includes(body.consent_version)) invalid();
  const consentVersion = body.consent_version;
  const mode = body.mode;
  if (mode !== 'paper' && mode !== 'general') invalid();
  const operationID = id(body.operation_id);
  let documentID: string | null = null;
  if (mode === 'paper') documentID = id(body.document_id);
  else if (body.document_id !== undefined && body.document_id !== null) invalid();
  if (!Array.isArray(body.messages) || body.messages.length < 1 || body.messages.length > MAX_TURNS) invalid();
  let bytes = 0;
  const turns = body.messages.map(raw => {
    const turn = record(raw);
    onlyKeys(turn, ['role', 'text']);
    if (turn.role !== 'user' && turn.role !== 'assistant') invalid();
    if (typeof turn.text !== 'string' || !turn.text.trim()) invalid();
    bytes += encoder.encode(turn.text).length;
    if (bytes > MAX_MESSAGE_BYTES) invalid();
    return { role: turn.role, text: turn.text } as ChatTurn;
  });
  if (turns[0].role !== 'user' || turns[turns.length - 1].role !== 'user') invalid();
  let selection: string | null = null;
  if (body.selection !== undefined && body.selection !== null) {
    const value = record(body.selection);
    onlyKeys(value, ['quote']);
    if (typeof value.quote !== 'string' || !value.quote.trim() || [...value.quote].length > MAX_SELECTION_SCALARS) invalid();
    selection = value.quote;
  }
  let action: ChatAction | null = null;
  if (body.action !== undefined && body.action !== null) {
    if (typeof body.action !== 'string' || !CHAT_ACTIONS.includes(body.action)) invalid();
    action = body.action as ChatAction;
    // A repair is general (no paper), one bounded turn, no selection; every other action acts on a selection.
    if (action === 'diagram_fix') {
      if (mode !== 'general' || selection !== null || turns.length !== 1 || encoder.encode(turns[0].text).length > DIAGRAM_FIX_MAX_BYTES) invalid();
    } else if (selection === null) invalid();
  }
  let capabilities: string[] = [];
  if (body.capabilities !== undefined && body.capabilities !== null) {
    if (!Array.isArray(body.capabilities) || body.capabilities.length > 8) invalid();
    // Unknown features from newer builds are ignored, not rejected.
    capabilities = [...new Set(body.capabilities.map(value => typeof value === 'string' && value.length <= 32 ? value : invalid()))]
      .filter(value => (CLIENT_CAPABILITIES as readonly string[]).includes(value)).sort();
  }
  return { operationID, consentVersion, mode, documentID, turns, selection, action, capabilities };
}

/** Fixed key order: the reservation's request digest. */
export function canonicalRequest(request: ChatRequest): string {
  return JSON.stringify({
    consent_version: request.consentVersion, document_id: request.documentID,
    messages: request.turns.map(turn => ({ role: turn.role, text: turn.text })),
    mode: request.mode, operation_id: request.operationID,
    selection: request.selection === null ? null : { quote: request.selection },
    ...(request.action ? { action: request.action } : {}),
    ...(request.capabilities.length ? { capabilities: request.capabilities } : {}),
  });
}

export async function readChatBody(request: Request, maximum = MAX_BODY_BYTES, timeoutMs = 20_000): Promise<unknown> {
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) invalid();
  if (!request.body) invalid();
  const reader = request.body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { void reader.cancel(); reject(new ChatFailure('invalid_request')); }, timeoutMs);
  });
  try {
    const parts: Uint8Array[] = []; let length = 0;
    while (true) {
      const { done, value } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      length += value.byteLength;
      if (length > maximum) { void reader.cancel(); invalid(); }
      parts.push(value);
    }
    const joined = new Uint8Array(length); let offset = 0;
    for (const part of parts) { joined.set(part, offset); offset += part.byteLength; }
    try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(joined)); }
    catch { return invalid(); }
  } finally { if (timer) clearTimeout(timer); reader.releaseLock(); }
}

const BASE_INSTRUCTIONS = `You are the research assistant in Gradstep, an app people use to read machine-learning papers.
Lead with the answer, then the reasoning that supports it. Start directly with the content: no label such as "Answer:". Keep answers focused; use short Markdown sections or lists when they help.
Write mathematics in LaTeX with \\( ... \\) for inline math and \\[ ... \\] for display math. Do not use dollar-sign delimiters.
If you are unsure or something is outside what you can verify, say so plainly. Never invent citations, results, or paper details.`;
const PAPER_INSTRUCTIONS = `The reader is asking about the paper in the <paper> block (Mathpix Markdown of the full text).
Ground answers in the paper and point to where support comes from, such as "Section 3.2", "Eq. (4)", "Table 2" or "Figure 1". When the paper does not settle a question, say so and keep outside knowledge clearly separate from what the paper states.
A <selected_passage> block, when present, is the text the reader highlighted for this question.`;
const GENERAL_INSTRUCTIONS = `This is a general research conversation that is not tied to a specific paper. A <selected_passage> block, when present, is text the reader highlighted.`;

const INGEST_INSTRUCTIONS = `The reader used "Ingest" on the selected passage: they want the paper it references added to their library.
Identify that paper, using the paper's bibliography when the passage is an in-text citation. Write one short sentence naming it
(title, first author, year), then call add_paper once with its exact title, first author and year (and the arXiv id only if it appears in the text).
The paper need not be on arXiv: the app also finds open-access copies elsewhere.
Do not say whether it was added; the app reports that. If the passage does not reference a specific paper, say so and do not call the tool.`;

// The legacy app's "Similar" searched the web (Tavily) for related work; this is its successor.
const RELATED_INSTRUCTIONS = `The reader used "Related" on the selected passage: they want papers related to it. You must search the web before answering. You have up to ${RELATED_SEARCH_MAX_USES} searches: spend them on distinct angles (the method's name, the problem it solves, recent follow-ups with the current year, earlier work it builds on) rather than one broad query, and run them together in one step (several searches at once) rather than one after another. Then list 4–8 papers, most relevant first, as a numbered list. Each item: the title in bold, first author et al. and year, one sentence on how it relates to the passage, and an arXiv (https://arxiv.org/abs/…) or DOI link when you found one. Prefer peer-reviewed or widely cited work; never invent papers or links.`;
const RELATED_OFFLINE_INSTRUCTIONS = `The reader used "Related" on the selected passage: they want papers related to it. List 4–8 papers you are confident exist (title, first author, year, one sentence on the relation), most relevant first. Say plainly that you could not search the web, and never invent papers or links.`;

// Why it matters: the legacy app's relevance prompt ("Using ONLY the paper's content (do NOT search the web)").
const RELEVANCE_INSTRUCTIONS = `The reader used "Why it matters" on the selected passage: explain the role it plays in this paper and why it matters to the paper's method, argument and results. Use only the paper's own content: do not search the web or bring in other papers or outside sources. If the paper does not make the passage's role clear, say so.`;

// The legacy app's Mermaid label rules (app/api/chat/route.ts), which kept its diagrams parseable.
const MERMAID_RULES = `Mermaid syntax rules (a diagram that breaks them cannot be drawn):
- Use only ASCII in labels: no Unicode math symbols (×, →, ∂, Σ, ⋆, Greek letters) and no LaTeX. Write text equivalents instead ("*" or "times" for ×, "->" for →, "sum", "sigma").
- Wrap any label that contains characters other than letters, digits and spaces in double quotes: A["Linear (d -> 4d)"], A -->|"x * W"| B. Never put a double quote inside a label (use single quotes).
- Safe characters in labels: letters, digits, spaces, hyphens, underscores, periods, commas, colons, slashes.
- Node IDs are short plain words without spaces (A, enc1, loss); never use "end" as an ID.
- Keep labels short; one statement per line.`;

const DIAGRAM_INSTRUCTIONS = `Only when the reader explicitly asks for a diagram, flowchart or other visual: write your explanation first, then call create_diagram once with Mermaid source.
Never write Mermaid, SVG or HTML diagram markup in the answer text.
Diagrams are read on a phone: prefer top-to-bottom layouts (flowchart TD), short node labels, and at most about 12 nodes.
${MERMAID_RULES}`;

// The device checks each diagram with the bundled Mermaid before showing it; one that fails is sent back once.
const DIAGRAM_FIX_INSTRUCTIONS = `You draw diagrams for Gradstep, an app for reading machine-learning papers. The reader's app could not draw a Mermaid diagram from an earlier answer. The message gives its title, the error Mermaid reported and its source.
Call create_diagram once with a corrected diagram: the same title and the same content, changing only what is needed to make it valid Mermaid. Write no other text.
${MERMAID_RULES}`;

const WEB_SEARCH_INSTRUCTIONS = `You can search the web. Search when the question needs information beyond the paper or your knowledge may be out of date: related or follow-up work, recent results, comparisons with other models or methods, or checking a specific claim or number. Do not search for what the paper itself answers. Name the sources you rely on. If you used web search, end your answer with a line "Sources:" followed by one line per page you relied on (at most 8), each exactly in the form "1. Page title — https://…".`;

/** The instructions in two parts: what every answer with the same tools shares (`shared`, cached with the
 * paper) and the selection action's own (`action`, sent after the paper), so that Related or Why it matters
 * right after a question about the same paper reads the paper from the prompt cache instead of rewriting it. */
export function chatInstructionParts(mode: 'paper' | 'general', action: ChatAction | null = null, webSearch = false): { shared: string; action: string | null } {
  if (action === 'diagram_fix') return { shared: DIAGRAM_FIX_INSTRUCTIONS, action: null };
  // Why it matters never searches (its request carries no search tool either).
  const search = webSearch && action !== 'relevance';
  const tools = action === 'ingest' ? INGEST_INSTRUCTIONS : `${DIAGRAM_INSTRUCTIONS}${search ? `\n\n${WEB_SEARCH_INSTRUCTIONS}` : ''}`;
  const own = action === 'related' ? (search ? RELATED_INSTRUCTIONS : RELATED_OFFLINE_INSTRUCTIONS) : action === 'relevance' ? RELEVANCE_INSTRUCTIONS : null;
  return { shared: `${BASE_INSTRUCTIONS}\n\n${mode === 'paper' ? PAPER_INSTRUCTIONS : GENERAL_INSTRUCTIONS}\n\n${tools}`, action: own };
}
export function chatInstructions(mode: 'paper' | 'general', action: ChatAction | null = null, webSearch = false): string {
  const parts = chatInstructionParts(mode, action, webSearch);
  return parts.action ? `${parts.shared}\n\n${parts.action}` : parts.shared;
}

/** Cited web sources, appended to the answer as inert text (titles cleaned). */
export function sourcesText(sources: readonly { url: string; title: string | null }[]): string {
  const rows = sources.filter(source => /^https:\/\//.test(source.url)).slice(0, 8)
    .map((source, index) => `${index + 1}. ${source.title ? `${display(source.title)} — ` : ''}${source.url.replace(/\s/g, '').slice(0, 500)}`);
  return rows.length ? `\n\nSources:\n${rows.join('\n')}` : '';
}

const MERMAID_TYPES = /^(?:flowchart|graph|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|gantt|pie|mindmap|timeline|journey|quadrantChart|xychart-beta|block-beta|sankey-beta|gitGraph|requirementDiagram|packet-beta|architecture-beta|kanban|radar-beta)\b/;
export interface DiagramRequest { title: string; source: string }
/** Validates the model's create_diagram input. The source is untrusted and is
 * only ever rendered on device by Mermaid in strict mode without network. */
export function diagramRequest(input: unknown): DiagramRequest | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const value = input as Record<string, unknown>;
  if (Object.keys(value).some(key => !['title', 'mermaid'].includes(key))) return null;
  const title = typeof value.title === 'string' ? value.title.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim() : '';
  const source = typeof value.mermaid === 'string' ? value.mermaid.replace(/\r\n?/g, '\n').trim() : '';
  if (!title || [...title].length > 120 || !source || new TextEncoder().encode(source).length > 12_000) return null;
  const firstLine = source.split('\n').map(line => line.trim()).find(line => line && !line.startsWith('%%'));
  return firstLine && MERMAID_TYPES.test(firstLine) ? { title, source } : null;
}

export interface PaperRequest { title: string; year: number | null; firstAuthor: string | null; arxivID: string | null }
/** Validates the model's add_paper input (untrusted: paper text can steer it). */
export function paperRequest(input: unknown): PaperRequest | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  // Extra keys (a model sometimes adds "venue" or "authors") are ignored, not fatal.
  const value = input as Record<string, unknown>;
  const title = typeof value.title === 'string' ? value.title.replace(/\s+/g, ' ').trim() : '';
  if (title.length < 3 || title.length > 400) return null;
  const year = Number.isInteger(value.year) && (value.year as number) >= 1900 && (value.year as number) <= 2100 ? value.year as number : null;
  const author = typeof value.first_author === 'string' ? value.first_author.replace(/\s+/g, ' ').trim() : '';
  const arxivID = typeof value.arxiv_id === 'string' && value.arxiv_id.length <= 64 ? value.arxiv_id.trim() : null;
  return { title, year, firstAuthor: author.length >= 2 && author.length <= 200 ? author : null, arxivID };
}
/** `web`: an open-access copy found through OpenAlex (`source_id` openalex:W…, `host` serves the PDF).
 * `link`: where a paper without an open copy can be found (closed results only). */
export interface FoundPaper { source_id: string; title: string; year: number | null; kind?: 'arxiv' | 'web'; host?: string | null; link?: string | null }
/** `closed`: the paper exists but has no arXiv or open-access copy. `needs_update`: only an open-access
 * copy exists and this app build cannot show web papers. */
export type FindResult = { status: 'found' | 'closed' | 'needs_update'; paper: FoundPaper } | { status: 'not_found' | 'unavailable' };
export type IngestResult = 'added' | 'present' | 'failed' | 'not_found' | 'unavailable' | 'stopped' | 'closed' | 'needs_update';
const display = (text: string) => text.replace(/[\u0000-\u001f\u007f-\u009f*_`[\]<>\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 300);
const inertURL = (url: string | null | undefined) => url && /^https:\/\/[!-~]{1,300}$/.test(url) && !/[[\]<>`*_\\]/.test(url) ? url : null;
export function ingestReport(request: PaperRequest, found: FoundPaper | null, result: IngestResult): string {
  const wanted = `“${display(request.title)}”`;
  const web = found?.kind === 'web';
  const title = found ? `“${display(found.title)}”` : wanted;
  const paper = !found ? wanted : web ? `${title} (open-access PDF${found.host ? ` from ${display(found.host)}` : ''})` : `${title} (arXiv:${found.source_id})`;
  switch (result) {
    case 'added': return `\n\nQueued ${paper} for your library.`;
    case 'present': return `\n\n${paper} is already in your library.`;
    case 'failed': return `\n\nI found ${paper} but couldn't add it right now.${web ? ' Try Ingest again later.' : ' You can add it from Library → arXiv.'}`;
    case 'closed': {
      const link = inertURL(found?.link);
      return `\n\n${title} isn't openly available (no arXiv or open-access copy), so it wasn't added.${link ? ` It's at ${link}` : ''}`;
    }
    case 'needs_update': return `\n\n${title} isn't on arXiv. Adding open-access papers from other sites needs the latest Gradstep version.`;
    case 'not_found': return `\n\nI couldn't find ${wanted} on arXiv or as an open-access paper, so it wasn't added.`;
    default: return `\n\nI couldn't search for ${wanted} right now, so it wasn't added. Try again later.`;
  }
}
/** Owner decision (2026-10-05): a reader whose balance is at least this but
 * below the full hold may still ask; the credit hold is capped at their
 * balance and the platform absorbs a rare overrun. The platform-budget hold
 * (micro-USD) is never reduced. */
export const HOLD_CAP_MINIMUM_CREDITS = 50;

/** Ingest work after settlement: bounded so the answer still completes. */
export const INGEST_DEADLINE_MS = 45_000;

export type ChatEvent = { event: 'delta'; data: { text: string } }
  | { event: 'diagram'; data: { title: string; source: string } }
  /** Progress while the server searches or adds a paper. Builds that predate it ignore unknown events. */
  | { event: 'status'; data: ChatStatus }
  | { event: 'done'; data: { stop_reason: string; credits: number; usage: Record<string, number> } }
  | { event: 'error'; data: { code: ChatErrorCode } };

export function sseFrame(message: ChatEvent): string {
  return `event: ${message.event}\ndata: ${JSON.stringify(message.data)}\n\n`;
}

export type LogEntry = Record<string, string | number | boolean | null>;
type PaperLocation = { bucket?: unknown; path?: unknown; title?: unknown; byte_count?: unknown } | null;
export interface ChatDependencies {
  accountID: string;
  rpc(name: string, params: Record<string, unknown>): Promise<unknown>;
  /** Returns the stored object bytes, or null when it is missing. */
  loadPaper(bucket: string, path: string, expectedBytes?: number): Promise<Uint8Array | null>;
  /** Null when the provider is not configured in this environment. */
  generate: ((params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: StreamOptions) => Promise<ProviderOutcome>) | null;
  sha256Hex(bytes: Uint8Array): Promise<string>;
  log(entry: LogEntry): void;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  deadlineMs?: number;
  ingestDeadlineMs?: number;
  /** The caller's available credits (for the hold cap); null if unknown. */
  availableCredits?: () => Promise<number | null>;
  /** Offer web search (server setting; off by default). Anthropic's search serves it,
   * or backs up `search` when that is configured. */
  webSearch?: boolean;
  /** Native backup requires a separately verified provider-enforced cost bound.
   * Production leaves this false until that deployment gate is implemented. */
  nativeSearch?: boolean;
  /** Tavily, the primary search provider (absent when not configured). `ready` is false
   * while it is paused after a failure or its plan allowance is used up. */
  search?: { ready(): Promise<boolean>; run(input: SearchInput, signal: AbortSignal): Promise<SearchOutcome> };
  /** Ingest: the paper that strictly matches the citation, if any: on arXiv, else (with `web`)
   * an open-access copy found through OpenAlex. */
  findPaper?: (request: PaperRequest, signal: AbortSignal, options: { web: boolean; tavily?: boolean }) => Promise<FindResult>;
  /** Ingest: adds one found paper to the caller's library (as the caller). */
  importPaper?: (paper: FoundPaper, signal: AbortSignal) => Promise<'added' | 'present' | 'failed'>;
}

const RESERVE_ERRORS: Record<string, ChatErrorCode> = {
  insufficient_credits: 'insufficient_credits', platform_budget_exhausted: 'platform_budget_exhausted',
  too_many_active_operations: 'rate_limited', operation_id_conflict: 'invalid_request',
  account_unavailable: 'service_unavailable', invalid_reservation: 'invalid_request',
};
function reason(error: unknown): string { return error instanceof RpcFailure ? error.reason : 'transport'; }

/**
 * Run one chat turn and emit SSE events. Resolves after settlement; never
 * rejects for ordinary failures (they become an `error` event).
 */
export async function runChat(deps: ChatDependencies, body: unknown, emit: (event: ChatEvent) => void, signal: AbortSignal): Promise<void> {
  try {
    await runChecked(deps, body, emit, signal);
  } catch (error) {
    const code = error instanceof ChatFailure ? error.code : 'service_unavailable';
    if (!(error instanceof ChatFailure)) deps.log({ event: 'chat_unexpected_failure' });
    if (!signal.aborted) emit({ event: 'error', data: { code } });
  }
}

/** A started call whose failure is handled where it is awaited (never an unhandled rejection). */
type Settled<T> = { ok: true; value: T } | { ok: false; error: unknown };
function settled<T>(promise: Promise<T>): Promise<Settled<T>> {
  return promise.then(value => ({ ok: true as const, value }), error => ({ ok: false as const, error }));
}

async function runChecked(deps: ChatDependencies, body: unknown, emit: (event: ChatEvent) => void, signal: AbortSignal) {
  // Time to first text (owner feedback build 16 #8): the rate limit still decides first, but the reads that do
  // not depend on it (balance, search policy) start alongside it instead of one by one. The paper's context
  // still follows the credit check: it authorizes and accounts the Storage read.
  const consumed = settled(deps.rpc('worker_consume_request', { p_account_id: deps.accountID, p_route: 'chat' }));
  const admitted = async () => {
    const result = await consumed;
    if (!result.ok) throw new ChatFailure(reason(result.error) === 'request_rate_limit' ? 'rate_limited' : 'service_unavailable');
  };
  let request: ChatRequest;
  try { request = validateChatRequest(body); } catch (error) { await admitted(); throw error; }
  // Ingest, Why it matters (the paper only) and diagram repairs never search.
  const search = !['ingest', 'relevance', 'diagram_fix'].includes(request.action ?? '') && deps.webSearch === true;
  // Tavily first when the reader's consent names it (checked while the paper loads);
  // otherwise, and as its backup, Anthropic's search.
  const tavilyReady = search && request.consentVersion === CONSENT_VERSION && deps.search
    ? deps.search.ready().catch(() => false) : Promise.resolve(false);
  const balance = deps.availableCredits ? settled(deps.availableCredits()) : null;
  await admitted();

  if (!deps.generate) throw new ChatFailure('provider_unavailable');
  const tavily = await tavilyReady === true;
  const nativeSearch = search && deps.nativeSearch === true;
  const searchOffered = tavily || nativeSearch;
  // Related always searches before it answers: say so at once, not after the paper loads and the model's
  // first round has chosen its queries (that first status used to arrive ~4 s in).
  if (request.action === 'related' && searchOffered && !signal.aborted) emit({ event: 'status', data: searchingStatus(undefined) });
  const searchCap = request.action === 'related' ? RELATED_SEARCH_MAX_USES : WEB_SEARCH_MAX_USES;
  const repair = request.action === 'diagram_fix';
  const maxTokens = repair ? DIAGRAM_FIX_MAX_TOKENS : CHAT_MAX_TOKENS;
  const instructions = chatInstructionParts(request.mode, request.action, searchOffered);
  const makeParams = (paper: PaperContext | null) => chatRequestParams({ instructions: instructions.shared, actionInstructions: instructions.action,
    paper, turns: request.turns, selection: request.selection, maxTokens, tools: request.action === 'ingest' ? [ADD_PAPER_TOOL]
      : [CREATE_DIAGRAM_TOOL, ...(tavily ? [SEARCH_WEB_TOOL] : nativeSearch ? [request.action === 'related' ? RELATED_WEB_SEARCH_TOOL : WEB_SEARCH_TOOL] : [])] });
  const held = balance ? await balance : null;
  const available = held?.ok ? held.value : null;
  if (deps.availableCredits && (available === null || !Number.isSafeInteger(available) || available < 0)) throw new ChatFailure('service_unavailable');
  // The history/instructions/output budget already imply this minimum hold.
  // Refuse clearly insufficient balances before downloading the paper; cheap
  // general chats still use their own quote, not an invented 50-credit minimum.
  const minimum = Math.min(HOLD_CAP_MINIMUM_CREDITS, holdFor(promptCharacters(makeParams(null)), maxTokens).credits);
  if (available !== null && available < minimum) throw new ChatFailure('insufficient_credits');

  let paper: PaperContext | null = null;
  if (request.mode === 'paper') {
    let context: PaperLocation;
    try { context = await deps.rpc('worker_chat_context', { p_account_id: deps.accountID, p_document_id: request.documentID }) as PaperLocation; }
    catch (error) { throw new ChatFailure(reason(error) === 'document_unavailable' ? 'document_unavailable' : 'service_unavailable'); }
    if (!context || typeof context.bucket !== 'string' || typeof context.path !== 'string') throw new ChatFailure('document_unavailable');
    const byteCount = typeof context.byte_count === 'number' ? context.byte_count : undefined;
    if (byteCount !== undefined && (!Number.isSafeInteger(byteCount) || byteCount <= 0 || byteCount > MAX_PAPER_BYTES)) throw new ChatFailure('document_unavailable');
    const bytes = await deps.loadPaper(context.bucket, context.path, byteCount);
    if (!bytes || !bytes.length || bytes.length > MAX_PAPER_BYTES) throw new ChatFailure('document_unavailable');
    let text: string;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { throw new ChatFailure('document_unavailable'); }
    paper = { title: typeof context.title === 'string' ? context.title : null, text };
  }
  const params = makeParams(paper);
  // A repair is its own metered operation: held and settled like any answer, with its smaller output allowance.
  const hold = holdFor(promptCharacters(params), params.max_tokens);
  if (searchOffered) {
    // Sized for Anthropic's search, which also bounds Tavily and a mid-answer switch between them.
    hold.microusd += webSearchHoldMicrousd(hold.inputTokens, searchCap);
    hold.credits = creditsFor(hold.microusd);
  }
  if (available !== null && Number.isSafeInteger(available) && available >= HOLD_CAP_MINIMUM_CREDITS && available < hold.credits) {
    hold.credits = available;
  }
  const digest = await deps.sha256Hex(encoder.encode(canonicalRequest(request)));
  if (signal.aborted) return;

  let reservation: { replayed?: unknown; state?: unknown };
  try {
    reservation = await deps.rpc('worker_reserve_operation', {
      p_account_id: deps.accountID, p_id: request.operationID, p_kind: 'chat', p_request_sha256: `\\x${digest}`,
      p_rate_version: RATE_VERSION, p_credits: hold.credits, p_microusd: hold.microusd,
    }) as typeof reservation;
  } catch (error) {
    const code = RESERVE_ERRORS[reason(error)];
    // An ambiguous transport failure may have committed the hold; leave it
    // for reconciliation instead of guessing which invocation owns it.
    if (!code) deps.log({ event: 'chat_reserve_uncertain', operation_id: request.operationID });
    throw new ChatFailure(code ?? 'service_unavailable');
  }
  if (!reservation || reservation.replayed !== false) throw new ChatFailure('operation_replayed');

  // From here the hold exists: settle exactly once on every path.
  const now = deps.now ?? Date.now;
  const deadline = new AbortController();
  const timer = setTimeout(() => deadline.abort(), deps.deadlineMs ?? GENERATION_DEADLINE_MS);
  const stop = () => deadline.abort();
  signal.addEventListener('abort', stop, { once: true });
  let outcome: ProviderOutcome;
  let wroteText = false, answerTail = '';
  const stats: SearchStats = { tavily: 0, credits: 0, failures: 0, failover: false };
  // Status lines go only to this reader's stream (the search query included); logs keep counts only.
  const status = (data: ChatStatus) => { if (!signal.aborted) emit({ event: 'status', data }); };
  try {
    outcome = await generateAnswer(deps, deps.generate, request.operationID, params, {
      signal: deadline.signal, inputEstimateTokens: hold.inputTokens, now,
      onText: text => { if (text.trim()) wroteText = true; answerTail = (answerTail + text).slice(-4000); if (!signal.aborted && text) emit({ event: 'delta', data: { text } }); },
      onStatus: status,
    }, { tavily, backup: nativeSearch, cap: searchCap }, stats);
  } finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', stop);
  }

  const tokens = priceAttempts(outcome.attempts), anthropicFees = (outcome.webSearches ?? 0) * WEB_SEARCH_MICROUSD;
  // Provider spend (the platform budget): tokens and Anthropic's per-search fee. Tavily
  // searches within its prepaid plan add nothing (a fixed commitment). The reader's price
  // adds Tavily's per-credit price, so a search costs the reader about the same either way.
  const actual = Math.ceil(tokens + anthropicFees);
  const priced = Math.ceil(tokens + anthropicFees + stats.credits * TAVILY_CREDIT_MICROUSD);
  // The customer is never charged above the hold, but the platform budget
  // records the true provider cost: an overrun freezes new paid work.
  const credits = Math.min(creditsFor(priced), hold.credits);
  if (priced > hold.microusd) deps.log({ event: 'chat_usage_exceeded_hold', operation_id: request.operationID, actual_microusd: priced, hold_microusd: hold.microusd });
  else if (creditsFor(priced) > hold.credits) deps.log({ event: 'chat_credits_capped_at_balance', operation_id: request.operationID, credits: creditsFor(priced), hold_credits: hold.credits });
  await settle(deps, request.operationID, credits, actual);
  await recordUsage(deps, request.operationID, outcome, actual);
  if (stats.tavily || stats.failures) await recordSearchUsage(deps, request.operationID, stats);
  // Counts only (never text): whether answers search the web, per selection action.
  deps.log({ event: 'chat_answer', operation_id: request.operationID, action: request.action ?? 'none', mode: request.mode,
    web_search_offered: searchOffered, search_provider: tavily ? 'tavily' : nativeSearch ? 'anthropic' : 'none',
    web_searches: (outcome.webSearches ?? 0) + stats.tavily, tavily_searches: stats.tavily, search_failures: stats.failures,
    failover: stats.failover, sources: outcome.sources?.length ?? 0 });

  if (signal.aborted) return;
  if (outcome.status === 'complete') {
    if (outcome.stopReason === 'refusal') { emit({ event: 'error', data: { code: 'refused' } }); return; }
    // Ingest: at most one add per request, only of a strictly matched arXiv
    // paper, only when the turn ended in the tool call (not cut off).
    const call = request.action === 'ingest' && outcome.stopReason === 'tool_use'
      ? outcome.toolCalls?.find(c => c.name === 'add_paper') : undefined;
    const wanted = call ? paperRequest(call.input) : null;
    if (request.action === 'ingest' && !wanted) {
      // Never end silently: say why nothing was added, and record it.
      const result = call ? 'invalid_input' : 'no_call';
      deps.log({ event: 'chat_ingest', operation_id: request.operationID, result });
      if (call && !signal.aborted) emit({ event: 'delta', data: { text: '\n\nI couldn’t read the paper’s details, so it wasn’t added. Try Add paper again.' } });
      await deps.rpc('worker_record_provider_usage', { p_account_id: deps.accountID, p_operation_id: request.operationID, p_provider: 'ingest',
        p_provider_event_id: `operation:${request.operationID}`, p_model: 'find-paper', p_microusd: 0,
        p_units: { result, stop_reason: outcome.stopReason, keys: call && call.input && typeof call.input === 'object' ? Object.keys(call.input).slice(0, 8).join(',') : null } })
        .catch(() => deps.log({ event: 'chat_usage_record_failed', operation_id: request.operationID, provider: 'ingest' }));
    }
    if (wanted && deps.findPaper && deps.importPaper && !signal.aborted) {
      const budget = AbortSignal.any([signal, AbortSignal.timeout(deps.ingestDeadlineMs ?? INGEST_DEADLINE_MS)]);
      const web = request.capabilities.includes('web_import');
      const clock = deps.now ?? Date.now, started = clock();
      status({ kind: 'finding_paper' });
      const search = await deps.findPaper(wanted, budget, { web,
        tavily: request.consentVersion === CONSENT_VERSION && deps.webSearch === true }).catch((): FindResult => ({ status: 'unavailable' }));
      const findMs = clock() - started;
      const found = 'paper' in search ? search.paper : null;
      let result: IngestResult = search.status === 'found' ? 'failed' : search.status;
      if (signal.aborted) result = 'stopped';
      else if (search.status === 'found' && search.paper.kind === 'web' && !web) result = 'needs_update';
      else if (search.status === 'found' && budget.aborted) result = 'unavailable';
      else if (search.status === 'found') {
        status({ kind: 'adding_paper' });
        result = await deps.importPaper(search.paper, budget).catch(() => 'failed' as const);
      }
      deps.log({ event: 'chat_ingest', operation_id: request.operationID, result });
      // Durable outcome (counts and timings only), so failures are visible without the log service.
      await deps.rpc('worker_record_provider_usage', { p_account_id: deps.accountID, p_operation_id: request.operationID, p_provider: 'ingest',
        p_provider_event_id: `operation:${request.operationID}`, p_model: 'find-paper', p_microusd: 0,
        p_units: { result, kind: found?.kind ?? null, find_ms: findMs, total_ms: clock() - started, web, budget_expired: budget.aborted } })
        .catch(() => deps.log({ event: 'chat_usage_record_failed', operation_id: request.operationID, provider: 'ingest' }));
      if (!signal.aborted) emit({ event: 'delta', data: { text: ingestReport(wanted, found, result) } });
    }
    const usage = outcome.attempts.reduce((sum, attempt) => ({
      input_tokens: sum.input_tokens + attempt.usage.input,
      cache_creation_input_tokens: sum.cache_creation_input_tokens + attempt.usage.cacheWrite5m + attempt.usage.cacheWrite1h,
      cache_read_input_tokens: sum.cache_read_input_tokens + attempt.usage.cacheRead,
      output_tokens: sum.output_tokens + attempt.usage.output,
    }), { input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0 });
    // Web results must be shown with the answer that used them.
    // Unless the answer already ends with its own Sources section.
    if (outcome.sources?.length && !signal.aborted && !/\n\nSources:\n/.test(answerTail)) {
      const text = sourcesText(outcome.sources);
      if (text) { emit({ event: 'delta', data: { text } }); wroteText = true; }
    }
    // Diagram: relayed once to the device, which stores it encrypted. Only calls from
    // rounds that ended in tool use are reported (none cut off mid-call).
    const drawing = request.action !== 'ingest' ? outcome.toolCalls?.find(c => c.name === 'create_diagram') : undefined;
    if (drawing) {
      const diagram = diagramRequest(drawing.input);
      deps.log({ event: diagram ? 'chat_diagram' : 'chat_diagram_invalid_input', operation_id: request.operationID });
      if (diagram && !signal.aborted) {
        // The device keeps a diagram only with a non-empty answer (a repair replaces one; it needs no text).
        if (!wroteText && !repair) emit({ event: 'delta', data: { text: `Diagram: “${diagram.title}”` } });
        emit({ event: 'diagram', data: diagram });
      }
    }
    if (signal.aborted) return;
    // A tool call ends the provider turn; the server completed it.
    const stopReason = outcome.stopReason === 'tool_use' ? 'end_turn' : outcome.stopReason ?? 'end_turn';
    emit({ event: 'done', data: { stop_reason: stopReason, credits, usage } });
    return;
  }
  emit({ event: 'error', data: { code: 'provider_unavailable' } });
}

export interface SearchStats { tavily: number; credits: number; failures: number; failover: boolean }
/** Smallest output allowance worth another round after searches. */
const MIN_ROUND_TOKENS = 1_024;
type MessageParam = Anthropic.Beta.Messages.BetaMessageParam;
type ToolResult = Anthropic.Beta.Messages.BetaToolResultBlockParam;

/**
 * The answer, in rounds: search_web (Tavily) is a client tool, so a round that ends
 * in searches is answered with their results and the answer continues. At most one
 * round per allowed search plus one to answer, sharing one output allowance. If Tavily
 * fails, the rest of the answer uses Anthropic's search (when on). Never throws:
 * a failed round ends the answer with what is known about billing.
 */
async function generateAnswer(deps: ChatDependencies, generate: NonNullable<ChatDependencies['generate']>, operationID: string,
  params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options: StreamOptions,
  search: { tavily: boolean; backup: boolean; cap: number }, stats: SearchStats): Promise<ProviderOutcome> {
  const attempts: ProviderAttempt[] = [], calls: NonNullable<ProviderOutcome['toolCalls']> = [];
  const sources = new Map<string, string | null>();
  // Pages each Tavily search returned (in rank order): the source list when the answer writes none.
  const searched: { url: string; title: string | null }[][] = [];
  const extra: MessageParam[] = [];
  let tools = params.tools, tavily = search.tavily, searches = 0, anthropicSearches = 0, exact = true;
  let firstID: string | null = null, wrote = false, separate = false;
  for (let round = 0; ; round++) {
    const used = attempts.reduce((sum, attempt) => sum + attempt.usage.output, 0);
    const remaining = Math.max(0, search.cap - searches - anthropicSearches);
    // Native search's max_uses is per API request. Never reset it on pause_turn
    // or after a client-tool round. With no allowance the tool is unavailable.
    if (tools) tools = tools.flatMap(tool => 'name' in tool && tool.name === 'web_search'
      ? remaining > 0 ? [{ ...tool, max_uses: remaining }] : [] : [tool]);
    let opening = true, outcome: ProviderOutcome;
    try {
      outcome = await generate({ ...params, messages: [...params.messages, ...marked(extra)], ...(tools ? { tools } : {}),
        max_tokens: params.max_tokens - used }, { ...options, onText: text => {
        // A round after searches starts a new paragraph.
        if (opening && text) { if (separate && !/^\s/.test(text)) text = `\n\n${text}`; opening = false; }
        if (text.trim()) wrote = true;
        options.onText(text);
      } });
    } catch {
      outcome = { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null, refusalCategory: null,
        attempts: [{ model: null, estimated: true, usage: { input: options.inputEstimateTokens, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }], exact: false };
    }
    firstID ??= outcome.messageID;
    attempts.push(...outcome.attempts); exact &&= outcome.exact; anthropicSearches += outcome.webSearches ?? 0;
    for (const source of outcome.sources ?? []) if (!sources.has(source.url)) sources.set(source.url, source.title);
    const finish = (): ProviderOutcome => {
      const all = [...calls, ...(outcome.stopReason === 'tool_use' ? outcome.toolCalls ?? [] : [])].filter(call => call.name !== SEARCH_WEB_TOOL.name);
      const { toolCalls: _calls, webSearches: _searches, sources: _sources, ...last } = outcome;
      return { ...last, messageID: firstID ?? outcome.messageID, attempts, exact, ...(all.length ? { toolCalls: all } : {}),
        ...(anthropicSearches ? { webSearches: anthropicSearches } : {}),
        ...(sources.size ? { sources: [...sources].map(([url, title]) => ({ url, title })) }
          : searched.length ? { sources: searchedPages(searched) } : {}) };
    };
    const left = params.max_tokens - attempts.reduce((sum, attempt) => sum + attempt.usage.output, 0);
    const continuation = outcome.stopReason === 'pause_turn'
      || (outcome.stopReason === 'tool_use' && outcome.toolCalls?.some(call => call.name === SEARCH_WEB_TOOL.name));
    if (outcome.status !== 'complete' || !outcome.content || options.signal.aborted || round >= search.cap || left < MIN_ROUND_TOKENS) {
      if (continuation && outcome.status === 'complete') outcome = { ...outcome, status: 'failed', failure: 'provider_error' };
      return finish();
    }
    const previous = extra.at(-1);
    const append = () => {
      if (previous?.role === 'assistant') previous.content = [...previous.content as unknown[], ...outcome.content!] as typeof previous.content;
      else extra.push({ role: 'assistant', content: outcome.content as MessageParam['content'] });
    };
    // A long server-side search turn paused: send it back to continue it.
    if (outcome.stopReason === 'pause_turn') {
      if (search.cap - searches - anthropicSearches <= 0) {
        outcome = { ...outcome, status: 'failed', failure: 'provider_error' };
        return finish();
      }
      append(); separate = false; continue;
    }
    const roundCalls = outcome.stopReason === 'tool_use' ? outcome.toolCalls ?? [] : [];
    if (!roundCalls.some(call => call.name === SEARCH_WEB_TOOL.name) || roundCalls.some(call => !call.id)) return finish();
    calls.push(...roundCalls);
    let failed = false;
    const canSwitch = () => search.backup && search.cap - searches - anthropicSearches > 0;
    const results = await Promise.all(roundCalls.map(async (call): Promise<ToolResult> => {
      const reply = (content: ToolResult['content'], error = false): ToolResult =>
        ({ type: 'tool_result', tool_use_id: call.id!, content, ...(error ? { is_error: true } : {}) });
      if (call.name !== SEARCH_WEB_TOOL.name) return reply(call.name === CREATE_DIAGRAM_TOOL.name ? 'The diagram is shown with your answer.' : 'Done.');
      searches++;
      const input = searchInput(call.input);
      if (searches + anthropicSearches > search.cap) return reply('No searches are left for this answer. Answer with what you have.', true);
      if (!input) return reply('Invalid search: give a short query.', true);
      if (!tavily || !deps.search) return reply(unavailable(canSwitch()), true);
      options.onStatus?.(searchingStatus(input.query));
      const result = await deps.search.run(input, options.signal).catch((): SearchOutcome => ({ status: 'failed', failure: 'unavailable', retryAfterMs: null }));
      if (result.status === 'ok') {
        stats.tavily++; stats.credits += result.credits;
        searched.push(result.results.map(page => ({ url: page.url, title: page.title || null })));
        return reply(searchResultContent(result.results));
      }
      stats.failures++; tavily = false; failed = true;
      deps.log({ event: 'chat_search_failed', operation_id: operationID, provider: 'tavily', failure: result.failure });
      return reply(unavailable(canSwitch()), true);
    }));
    // Results are in (at least one search succeeded): the answer continues from them.
    if (results.some(result => !result.is_error && Array.isArray(result.content)) && !options.signal.aborted) options.onStatus?.({ kind: 'reading' });
    append();
    extra.push({ role: 'user', content: results });
    separate = wrote;
    const searchesLeft = search.cap - searches - anthropicSearches;
    if (failed && search.backup && searchesLeft > 0) {
      // The rest of this answer searches with Anthropic. search_web stays defined: the conversation uses it.
      stats.failover = true;
      tools = [...(params.tools ?? []), { ...WEB_SEARCH_TOOL, max_uses: searchesLeft }];
    }
  }
}

/** The searches' pages, each search's best first, without repeats. */
function searchedPages(lists: readonly { url: string; title: string | null }[][]): { url: string; title: string | null }[] {
  const pages = new Map<string, string | null>();
  for (let rank = 0; lists.some(list => rank < list.length); rank++) {
    for (const list of lists) if (rank < list.length && !pages.has(list[rank].url)) pages.set(list[rank].url, list[rank].title);
  }
  return [...pages].map(([url, title]) => ({ url, title }));
}

function unavailable(backup: boolean): string {
  return backup ? 'search_web is unavailable for the rest of this answer. Use the web_search tool instead.'
    : 'Web search is unavailable right now. Answer without it and say briefly that you could not search.';
}

/** The conversation so far with one cache breakpoint, on its last block: each round
 * reads everything before it from the cache (with the paper's, two of four breakpoints). */
function marked(extra: MessageParam[]): MessageParam[] {
  return extra.map((message, index) => {
    if (index !== extra.length - 1 || message.role !== 'user' || !Array.isArray(message.content) || !message.content.length) return message;
    const content = [...message.content];
    content[content.length - 1] = { ...content[content.length - 1], cache_control: { type: 'ephemeral' } } as typeof content[number];
    return { ...message, content };
  });
}

async function settle(deps: ChatDependencies, operationID: string, credits: number, microusd: number) {
  const sleep = deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms)));
  // Settlement is idempotent for identical amounts, so a lost acknowledgement
  // may be retried. It is never repeated with different amounts.
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await deps.rpc('worker_settle_operation', { p_account_id: deps.accountID, p_id: operationID, p_actual_credits: credits, p_actual_microusd: microusd });
      return;
    } catch (error) {
      const failure = reason(error);
      if (failure !== 'transport' || attempt === 3) {
        deps.log({ event: 'chat_settle_failed', operation_id: operationID, reason: failure === 'transport' ? 'transport' : 'rejected' });
        return;
      }
      await sleep(250 * attempt);
    }
  }
}

/** Tavily searches for this answer: counts only. No provider spend while they are within
 * the prepaid plan; `list_microusd` is their pay-as-you-go value. Feeds the plan allowance. */
async function recordSearchUsage(deps: ChatDependencies, operationID: string, stats: SearchStats) {
  try {
    await deps.rpc('worker_record_provider_usage', {
      p_account_id: deps.accountID, p_operation_id: operationID, p_provider: 'tavily', p_provider_event_id: `operation:${operationID}`,
      p_model: 'search-basic', p_microusd: 0,
      p_units: { searches: stats.tavily, credits: stats.credits, failed: stats.failures, list_microusd: stats.credits * TAVILY_CREDIT_MICROUSD },
    });
  } catch { deps.log({ event: 'chat_usage_record_failed', operation_id: operationID, provider: 'tavily' }); }
}

async function recordUsage(deps: ChatDependencies, operationID: string, outcome: ProviderOutcome, microusd: number) {
  if (!outcome.attempts.length) return;
  const units = {
    estimated: !outcome.exact, stop_reason: outcome.stopReason, refusal_category: outcome.refusalCategory, failure: outcome.failure,
    web_searches: outcome.webSearches ?? 0,
    attempts: outcome.attempts.map(attempt => ({ model: attempt.model, estimated: attempt.estimated, input_tokens: attempt.usage.input,
      cache_write_5m_tokens: attempt.usage.cacheWrite5m, cache_write_1h_tokens: attempt.usage.cacheWrite1h,
      cache_read_tokens: attempt.usage.cacheRead, output_tokens: attempt.usage.output })),
  };
  try {
    await deps.rpc('worker_record_provider_usage', {
      p_account_id: deps.accountID, p_operation_id: operationID, p_provider: 'anthropic',
      p_provider_event_id: outcome.messageID ?? `operation:${operationID}`,
      p_model: outcome.model ?? outcome.attempts[0].model ?? 'unknown', p_units: units, p_microusd: microusd,
    });
  } catch { deps.log({ event: 'chat_usage_record_failed', operation_id: operationID }); }
}
