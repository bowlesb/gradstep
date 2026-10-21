import { clientDeepSeekModel, ROUTER_CONSENT_VERSION } from "./openrouter-deepseek-pricing.ts";
import { clientClaudeModel } from './openrouter-claude-pricing.ts';
// Paid chat orchestration: validation, context, hold -> provider -> settle. Every model call goes to OpenRouter
// (owner, 2026-10-18 and 2026-10-21); web search is our search_web tool, run with Tavily.
// Deno and Node compatible (no Deno globals). Never log request or answer
// text; logs carry only operation IDs, codes and counts.
import {
  ADD_PAPER_TOOL, chatRequestParams, CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, creditsFor, holdFor, holdForParams, priceAttempts, promptCharacters, RATE_VERSION, readerPriceAttempts,
  SEARCH_WEB_TOOL, searchResultContent, TAVILY_CREDIT_MICROUSD, WEB_SEARCH_MAX_USES, tariffFor,
  webSearchHoldMicrousd, RELATED_SEARCH_MAX_USES, searchingStatus,
  type ChatStatus, type ChatTurn, type PaperContext, type ProviderAttempt, type ProviderOutcome, type StreamOptions,
} from './inference.ts';
import type { MessageParam, ModelRequest, ToolResultBlock } from './model-request.ts';
import { EFFORTS, GEMINI_CONSENT_VERSION, DEEPSEEK_CONSENT_VERSION, isDefaultChoice, parseChoice, PROFILE_VERSION, resolveChoice, resolveProfile,
  type ChatProfile, type RequestedChoice } from './chat-profiles.ts';
import { cleanTitle, TITLE_GRACE_MS, TITLE_MAX_TOKENS, TITLE_MODEL, titleRequestParams } from './chat-title.ts';
import { FOLLOW_UP_HOLD_PARAMS, FOLLOW_UP_MAX_TOKENS, FOLLOW_UP_MODEL, FOLLOW_UP_TIMEOUT_MS, followUpRequest, followUpRequestParams, SUGGEST_FOLLOW_UPS_TOOL } from './chat-follow-ups.ts';
import { EMPTY_STUDY_MAP, STUDY_HOLD_PARAMS, STUDY_INSTRUCTIONS, STUDY_MAX_TOKENS, STUDY_MODEL, STUDY_TIMEOUT_MS, studyMap, studyMapForPrompt, studyMapRequestParams, type StudyMap, UPDATE_STUDY_MAP_TOOL } from './chat-study.ts';
import { searchInput, type SearchInput, type SearchOutcome } from './tavily.ts';
import { visualRequest } from './chat-visual.ts';
import { figureBlocks, figureImages, figureInstructions, figureLookRequest, figurePartsFallbackText, figurePartsRequest, LOOK_AT_FIGURE_TOOL, SHOW_FIGURE_PARTS_TOOL, type FigureImage } from './chat-figures.ts';
import { EQUATION_BACKGROUND_INSTRUCTIONS, EQUATION_INSTRUCTIONS, EQUATION_MAX_TOKENS, equationFallbackText, equationSymbols, isEquationAction, paragraphCount, type EquationSymbols } from './chat-equation.ts';
import { FIGURE_DETAIL_INSTRUCTIONS, FIGURE_INSTRUCTIONS, FIGURE_SIMPLER_INSTRUCTIONS, FIGURE_VIEW_CAPABILITY, FIGURE_WALKTHROUGH_TOOL, figureDetail, figureDetailMaxTokens,
  figureMaxTokens, figureWalkthrough, figureWalkthroughText, offeredBoxes, isFigureAction, type FigureDetail, type FigureWalkthrough } from './chat-figure-view.ts';

/** The consent text the reader accepted. v2 names Tavily as a search provider; v1 (builds up to TestFlight 11) named
 * only Anthropic's search. Every answer now needs v5 or later, which names OpenRouter (runChecked: `consent_required`);
 * the older versions stay accepted by validation so those builds are told to update rather than refused as invalid. */
export const CONSENT_VERSION = 'cloud-ai-v2';
/** v3 (2026-10-15) also names the figure a question is about: only v3 (and later) requests may carry figure images. */
export const FIGURE_CONSENT_VERSION = 'cloud-ai-v3';
/** v4 (2026-10-16) is v3 plus DeepSeek, named as the processor when the reader chooses it: v4 or later is required. */
export { DEEPSEEK_CONSENT_VERSION };
export const CONSENT_VERSIONS: readonly string[] = ['cloud-ai-v1', CONSENT_VERSION, FIGURE_CONSENT_VERSION, DEEPSEEK_CONSENT_VERSION, GEMINI_CONSENT_VERSION, ROUTER_CONSENT_VERSION];
/** v2 and later name Tavily; v1 (builds up to TestFlight 11) named only Anthropic's search. */
const namesTavily = (version: string) => version === CONSENT_VERSION || version === FIGURE_CONSENT_VERSION || version === DEEPSEEK_CONSENT_VERSION || version === GEMINI_CONSENT_VERSION || version === ROUTER_CONSENT_VERSION;
/** v3 and later name the figure a question is about. */
export const namesFigures = (version: string) => version === FIGURE_CONSENT_VERSION || version === DEEPSEEK_CONSENT_VERSION || version === GEMINI_CONSENT_VERSION || version === ROUTER_CONSENT_VERSION;
/** v4 and later name DeepSeek. */
export const namesDeepSeek = (version: string) => version === DEEPSEEK_CONSENT_VERSION || version === GEMINI_CONSENT_VERSION || version === ROUTER_CONSENT_VERSION;
export const MAX_BODY_BYTES = 8 * 1024 * 1024;
export const MAX_TURNS = 60;
export const MAX_MESSAGE_BYTES = 200_000;
export const MAX_SELECTION_SCALARS = 4_000;
export const MAX_PAPER_BYTES = 2 * 1024 * 1024;
export const GENERATION_DEADLINE_MS = 130_000;

/** `consent_required` (2026-10-16): the request chose a model its consent version does not name (DeepSeek before v4). */
export type ChatErrorCode = 'insufficient_credits' | 'platform_budget_exhausted' | 'rate_limited' | 'document_unavailable'
  | 'provider_unavailable' | 'model_unavailable' | 'refused' | 'invalid_request' | 'operation_replayed' | 'service_unavailable' | 'consent_required';

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
  localContext?: LocalPaperContext | null;
  turns: ChatTurn[];
  selection: string | null;
  /** Selection action needing server work beyond an answer: Ingest (add the cited paper),
   * Related (find related papers; always searches the web when search is on), Why it matters
   * (`relevance`: the paper only, no web search), or a diagram the device could not draw
   * (`diagram_fix`: one corrected diagram; see DIAGRAM_FIX_MAX_TOKENS). */
  action: ChatAction | null;
  /** Client features: 'web_import' = the app shows web (non-arXiv) library entries. */
  capabilities: string[];
  /** Diagrams and HTML visuals may be drawn (the reader's "Visual answers" setting; on when a build says nothing). */
  visuals: boolean;
  /** The question's figure images (chat-figures.ts): paper chat, consent v3 only. */
  figures: FigureImage[];
  /** The reader's model, effort and length as sent (chat-profiles.ts; effort may be `auto`, resolved by `resolveChoice`
   * before the hold); null = the default profile (today's request). */
  choice: RequestedChoice | null;
  /** Also write a topic title for the conversation (chat-title.ts). */
  topicTitle: boolean;
  /** Also suggest follow-up questions after the answer (chat-follow-ups.ts); never for Ingest or a repair. */
  followUps: boolean;
  /** Study (`action: "study"`, chat-study.ts): the reader's knowledge map so far, as the device last received it
   * (an empty map on the first turn). Present exactly when the action is Study. */
  study?: StudyMap;
}

/** `reader-local-context-v2` (2026-10-14) is the same snapshot with the paper's blocks numbered `[¶N]` (headings,
 * display equations and figure captions marked), so answers can cite passages the reader can jump to. */
export type LocalContextFormat = 'reader-local-context-v1' | 'reader-local-context-v2';
export const LOCAL_CONTEXT_FORMATS: readonly LocalContextFormat[] = ['reader-local-context-v1', 'reader-local-context-v2'];
export interface LocalPaperContext {
  format: LocalContextFormat; membership_id: string; source: 'arxiv'; source_id: string; revision: number;
  manifest_sha256: string; source_sha256: string; text: string;
}

function localPaperContext(input: unknown): LocalPaperContext {
  const c = record(input);
  onlyKeys(c, ['format', 'membership_id', 'source', 'source_id', 'revision', 'manifest_sha256', 'source_sha256', 'text']);
  if (!LOCAL_CONTEXT_FORMATS.includes(c.format as LocalContextFormat) || c.source !== 'arxiv' || typeof c.source_id !== 'string' ||
    !/^(?:\d{4}\.\d{4,5}|[a-z][a-z.-]+(?:\.[A-Z]{2})?\/\d{7})$/.test(c.source_id) ||
    !Number.isSafeInteger(c.revision) || (c.revision as number) < 1 || (c.revision as number) > 2147483647 ||
    typeof c.manifest_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(c.manifest_sha256) ||
    typeof c.source_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(c.source_sha256) ||
    typeof c.text !== 'string' || !c.text.trim() || encoder.encode(c.text).length > MAX_PAPER_BYTES ||
    /[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(c.text)) invalid();
  return { format: c.format as LocalContextFormat, membership_id: id(c.membership_id), source: 'arxiv', source_id: c.source_id,
    revision: c.revision as number, manifest_sha256: c.manifest_sha256, source_sha256: c.source_sha256, text: c.text };
}

/** 'web_import' = the app shows web (non-arXiv) library entries; 'visual_answers' = the app draws HTML visuals and
 * Mermaid diagrams and the reader has them on. A request that names no capabilities at all (builds before the
 * setting) still gets diagrams. 'figure_view' (2026-10-16) = the build has the figure view (chat-figure-view.ts): its paper
 * chats carry the figure_walkthrough tool, so a walkthrough reads the same cached prefix. */
export const CLIENT_CAPABILITIES = ['web_import', 'visual_answers', 'figure_requests', 'stop_signal', FIGURE_VIEW_CAPABILITY] as const;
/** How a paid answer ended (owner decision 2026-10-16; docs/architecture/CHAT.md "When an answer stops early"). The
 * reader pays for work that finishes (`completed`) or for the part they chose to stop (`stopped`: the app said so with
 * v1_chat_stop; `left`: a build without the `stop_signal` capability closed the stream, which can't be told apart from a
 * dropped connection, so it is charged as a Stop, as before). Every other ending costs the reader nothing: the provider
 * failing or overloading (`provider`), our server (`server`), our own time or length limit (`limit`), the connection
 * between our server and the reader dropping (`connection`), or a refusal (`refusal`). Gradstep pays the provider and the
 * cost stays in the month's spend. */
export type ChatEnding = 'completed' | 'stopped' | 'left' | 'provider' | 'server' | 'limit' | 'connection' | 'refusal';
export type UnchargedReason = Exclude<ChatEnding, 'completed' | 'stopped' | 'left'>;
export const CHARGED_ENDINGS: readonly ChatEnding[] = ['completed', 'stopped', 'left'];
/** Stop reasons that mean the answer was cut off by a bound, not finished. */
const LIMIT_STOP_REASONS: readonly string[] = ['max_tokens', 'model_context_window_exceeded'];
/** A Stop's record (v1_chat_stop) may still be on its way when the stream closes: one more look after this long. */
export const STOP_GRACE_MS = 1_500;
export type ChatAction = 'ingest' | 'related' | 'relevance' | 'diagram_fix' | 'study' | 'equation' | 'equation_background' | 'figure' | 'figure_simpler' | 'figure_detail';
// `figure_detail` is deprecated (2026-10-21): accepted from older builds only; remove once no supported build sends it
// (chat-figure-view.ts FIGURE_ACTIONS).
const CHAT_ACTIONS: readonly string[] = ['ingest', 'related', 'relevance', 'diagram_fix', 'study', 'equation', 'equation_background', 'figure', 'figure_simpler', 'figure_detail'];
/** The equation and figure views: no conversation (one turn, no title, no suggestions), and no tool result relayed. */
const isViewAction = (action: ChatAction | null) => isEquationAction(action) || isFigureAction(action);
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
  onlyKeys(body, ['operation_id', 'consent_version', 'mode', 'document_id', 'local_context', 'messages', 'selection', 'action', 'capabilities', 'profile', 'figures', 'topic_title', 'follow_ups', 'study']);
  if (typeof body.consent_version !== 'string' || !CONSENT_VERSIONS.includes(body.consent_version)) invalid();
  const consentVersion = body.consent_version;
  const mode = body.mode;
  if (mode !== 'paper' && mode !== 'general') invalid();
  const operationID = id(body.operation_id);
  let documentID: string | null = null;
  const localContext = body.local_context == null ? null : localPaperContext(body.local_context);
  if (localContext && (mode !== 'paper' || body.document_id != null)) invalid();
  if (mode === 'paper' && !localContext) documentID = id(body.document_id);
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
    } else if (action === 'study') {
      // Study tutors the numbered paper on the device ([¶N] citations); a selection may start it on a passage.
      if (mode !== 'paper' || localContext?.format !== 'reader-local-context-v2') invalid();
    } else if (isViewAction(action)) {
      // The equation view: the tapped equation in the numbered paper on the device, one turn (EQUATION_VIEW.md). The
      // figure view: the figure's caption (or, to explain one part more simply, that part's text), one turn (FIGURE_VIEW.md).
      if (mode !== 'paper' || localContext?.format !== 'reader-local-context-v2' || selection === null || turns.length !== 1) invalid();
    } else if (selection === null) invalid();
  }
  // The knowledge map travels with every Study turn (an empty one first) and with nothing else.
  let study: StudyMap | undefined;
  if (action === 'study') {
    if (body.study === undefined || body.study === null) invalid();
    const map = studyMap(body.study);
    if (!map) invalid();
    study = map;
  } else if (body.study !== undefined && body.study !== null) invalid();
  let capabilities: string[] = [];
  if (body.capabilities !== undefined && body.capabilities !== null) {
    if (!Array.isArray(body.capabilities) || body.capabilities.length > 8) invalid();
    // Unknown features from newer builds are ignored, not rejected.
    capabilities = [...new Set(body.capabilities.map(value => typeof value === 'string' && value.length <= 32 ? value : invalid()))]
      .filter(value => (CLIENT_CAPABILITIES as readonly string[]).includes(value)).sort();
  }
  let choice: RequestedChoice | null;
  try { choice = parseChoice(body.profile); } catch { invalid(); }
  // The default profile, named or not, is the same request (and the same digest). `auto` is its own request.
  if (choice && isDefaultChoice(choice)) choice = null;
  // Each provider processes the request only when the reader's consent names it.
  if (choice?.model === 'gemini' && ![GEMINI_CONSENT_VERSION, ROUTER_CONSENT_VERSION].includes(consentVersion)) throw new ChatFailure('consent_required');
  if (choice?.model === 'deepseek' && !namesDeepSeek(consentVersion)) throw new ChatFailure('consent_required');
  if (body.topic_title !== undefined && body.topic_title !== null && typeof body.topic_title !== 'boolean') invalid();
  const topicTitle = body.topic_title === true;
  if (body.follow_ups !== undefined && body.follow_ups !== null && typeof body.follow_ups !== 'boolean') invalid();
  const followUps = body.follow_ups === true;
  // A diagram repair is its own small request: the default model, no title, no follow-ups. Ingest's answer is a report.
  if (action === 'diagram_fix' && (choice !== null || topicTitle || followUps)) invalid();
  if (action === 'ingest' && followUps) invalid();
  // The tutor ends every turn with its own question: no follow-up suggestions beside it.
  if (action === 'study' && followUps) invalid();
  // The equation and figure views are no conversation: no title, no suggestions.
  if (isViewAction(action) && (topicTitle || followUps)) invalid();
  const visuals = body.capabilities === undefined || body.capabilities === null || capabilities.includes('visual_answers');
  let figures: FigureImage[];
  try { figures = figureImages(body.figures); } catch { invalid(); }
  // Figures only in a paper chat whose consent names them, and never with Add paper or a diagram repair.
  if (figures!.length && (!namesFigures(consentVersion) || mode !== 'paper' || action === 'ingest' || action === 'diagram_fix' || isEquationAction(action))) invalid();
  // The figure view: exactly that figure's image, from a build that has the view (its chats carry the walkthrough tool).
  if (isFigureAction(action) && (figures!.length !== 1 || !capabilities.includes(FIGURE_VIEW_CAPABILITY))) invalid();
  return { operationID, consentVersion, mode, documentID, turns, selection, action, capabilities, visuals, figures: figures!, choice, topicTitle, followUps,
    ...(localContext ? { localContext } : {}), ...(study ? { study } : {}) };
}

/** Fixed key order: the reservation's request digest. */
export function canonicalRequest(request: ChatRequest): string {
  return JSON.stringify({
    consent_version: request.consentVersion, document_id: request.documentID,
    messages: request.turns.map(turn => ({ role: turn.role, text: turn.text })),
    mode: request.mode, operation_id: request.operationID,
    selection: request.selection === null ? null : { quote: request.selection },
    ...(request.action ? { action: request.action } : {}),
    ...(request.figures.length ? { figures: request.figures.map(f => ({ id: f.id, paragraph: f.paragraph, caption: f.caption, media_type: f.mediaType,
      width: f.width, height: f.height, data: f.data })) } : {}),
    ...(request.capabilities.length ? { capabilities: request.capabilities } : {}),
    ...(request.choice ? { profile: { effort: request.choice.effort, length: request.choice.length, model: request.choice.model } } : {}),
    ...(request.topicTitle ? { topic_title: true } : {}),
    ...(request.followUps ? { follow_ups: true } : {}),
    ...(request.localContext ? { local_context: request.localContext } : {}),
    ...(request.study ? { study: request.study } : {}),
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
const PAPER_INSTRUCTIONS = `The reader is asking about the paper in the <paper> block (its full text, with equations in LaTeX).
Ground answers in the paper and point to where support comes from, such as "Section 3.2", "Eq. (4)", "Table 2" or "Figure 1". When the paper does not settle a question, say so and keep outside knowledge clearly separate from what the paper states.
A <selected_passage> block, when present, is the text the reader highlighted for this question.`;
const GENERAL_INSTRUCTIONS = `This is a general research conversation that is not tied to a specific paper. A <selected_passage> block, when present, is text the reader highlighted.`;

// Grounded citations (2026-10-14): a numbered context lets an answer point at the exact passage; the reader's
// app turns each marker into a link into the paper. Only for contexts the device numbered (local context v2).
const CITATION_INSTRUCTIONS = `The paper's blocks are numbered: each paragraph, heading, equation, figure caption and table starts with a marker such as [¶12]. When a statement relies on a specific passage, cite it by writing that marker right after the statement, exactly as it appears ([¶12]; several markers may follow one another: [¶12][¶15]). Cite the most specific block: the equation or figure itself rather than the paragraph around it. Cite only markers that exist in the paper, and never cite for general knowledge. Markers are in addition to naming sections ("Section 3.2"), not a replacement.`;

// Follow-up suggestions (2026-10-14): shown as one-tap questions under the answer; never part of the answer text.

const INGEST_INSTRUCTIONS = `The reader used "Ingest" on the selected passage: they want the paper it references added to their library.
Identify that paper, using the paper's bibliography when the passage is an in-text citation. Write one short sentence naming it
(title, first author, year), then call add_paper once with its exact title, first author and year (and the arXiv id only if it appears in the text).
The paper need not be on arXiv: the app also finds open-access copies elsewhere.
Do not say whether it was added; the app reports that. If the passage does not reference a specific paper, say so and do not call the tool.`;

// The legacy app's "Similar" searched the web (Tavily) for related work; this is its successor.
const RELATED_INSTRUCTIONS = `The reader used "Related" on the selected passage: they want papers related to it. You must search the web before answering. You have up to ${RELATED_SEARCH_MAX_USES} searches: spend them on distinct angles (the method's name, the problem it solves, recent follow-ups with the current year, earlier work it builds on) rather than one broad query, and run them together in one step (several searches at once) rather than one after another. Then list 4–8 papers, most relevant first, as a numbered list. Each item: the title in bold, first author et al. and year, one sentence on how it relates to the passage, and an arXiv (https://arxiv.org/abs/…) or DOI link when you found one. Prefer peer-reviewed or widely cited work; never invent papers or links.`; // egress-ok: prompt
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

const DIAGRAM_INSTRUCTIONS = `When the reader asks for a diagram or flowchart, or a boxes-and-arrows graph with short labels is clearly the best explanation: write your explanation first, then call create_diagram once with Mermaid source.
Never write Mermaid, SVG or HTML diagram markup in the answer text.
Diagrams are read on a phone: prefer top-to-bottom layouts (flowchart TD), short node labels, and at most about 12 nodes.
${MERMAID_RULES}`;

/** Visual answers (chat-visual.ts): richer layouts than a Mermaid graph, drawn by the device from a sanitized fragment. */
const VISUAL_INSTRUCTIONS = `When a visual would explain the point better than prose — how a method flows step by step, how components connect, a timeline, a decision tree, or a side-by-side comparison with highlights — write your explanation first, then call create_visual once with a self-contained HTML fragment. Keep the written answer complete on its own; the visual supplements it. Use create_visual for annotated steps, comparison tables and drawn diagrams with labels (inline SVG: rects, lines, paths, text, arrows with markers); use create_diagram instead when a plain boxes-and-arrows graph is the natural form. Never call both in one answer, and never put HTML, SVG or Mermaid in the answer text.
Visual rules: no scripts, no images, no external resources or fonts, links to https only; one <style> element or inline styles; narrow vertical layouts for a phone (an SVG with a viewBox and width="100%"); relative font sizes; plain system colours that read in light and dark modes (avoid pure white or black backgrounds); under 12,000 bytes.`;

const NO_VISUAL_INSTRUCTIONS = `The reader has turned visual answers off: answer in prose, with Markdown tables when they help; never draw diagrams or HTML.`;

// The device checks each diagram with the bundled Mermaid before showing it; one that fails is sent back once.
const DIAGRAM_FIX_INSTRUCTIONS = `You draw diagrams for Gradstep, an app for reading machine-learning papers. The reader's app could not draw a Mermaid diagram from an earlier answer. The message gives its title, the error Mermaid reported and its source.
Call create_diagram once with a corrected diagram: the same title and the same content, changing only what is needed to make it valid Mermaid. Write no other text.
${MERMAID_RULES}`;

const WEB_SEARCH_INSTRUCTIONS = `You can search the web. Search when the question needs information beyond the paper or your knowledge may be out of date: related or follow-up work, recent results, comparisons with other models or methods, or checking a specific claim or number. Do not search for what the paper itself answers. Name the sources you rely on. If you used web search, end your answer with a line "Sources:" followed by one line per page you relied on (at most 8), each exactly in the form "1. Page title — https://…".`;

/** The instructions in two parts: what every answer with the same tools shares (`shared`, cached with the
 * paper) and the selection action's own (`action`, sent after the paper), so that Related or Why it matters
 * right after a question about the same paper reads the paper from the prompt cache instead of rewriting it. */
export interface InstructionOptions {
  /** The paper context carries [¶N] markers (local context v2): ask for grounded citations. */
  citations?: boolean;
  /** Study: the reader's knowledge map for this turn (chat-study.ts); sent after the paper like an action's own text. */
  studyMap?: StudyMap;
  /** Diagrams and HTML visuals may be drawn (default true; the reader's "Visual answers" setting). */
  visuals?: boolean;
}
export function chatInstructionParts(mode: 'paper' | 'general', action: ChatAction | null = null, webSearch = false, options: InstructionOptions = {}): { shared: string; action: string | null } {
  if (action === 'diagram_fix') return { shared: DIAGRAM_FIX_INSTRUCTIONS, action: null };
  // Why it matters never searches (its request carries no search tool either).
  const search = webSearch && action !== 'relevance';
  const visuals = options.visuals ?? true;
  const tools = action === 'ingest' ? INGEST_INSTRUCTIONS
    : `${visuals ? `${DIAGRAM_INSTRUCTIONS}\n\n${VISUAL_INSTRUCTIONS}` : NO_VISUAL_INSTRUCTIONS}${search ? `\n\n${WEB_SEARCH_INSTRUCTIONS}` : ''}`;
  const own = action === 'related' ? (search ? RELATED_INSTRUCTIONS : RELATED_OFFLINE_INSTRUCTIONS) : action === 'relevance' ? RELEVANCE_INSTRUCTIONS
    : action === 'study' ? `${STUDY_INSTRUCTIONS}\n\n${studyMapForPrompt(options.studyMap ?? EMPTY_STUDY_MAP)}`
    : action === 'equation' ? EQUATION_INSTRUCTIONS : action === 'equation_background' ? EQUATION_BACKGROUND_INSTRUCTIONS
    : action === 'figure' ? FIGURE_INSTRUCTIONS : action === 'figure_simpler' ? FIGURE_SIMPLER_INSTRUCTIONS
    : action === 'figure_detail' ? FIGURE_DETAIL_INSTRUCTIONS : null;
  const paper = mode === 'paper' ? `${PAPER_INSTRUCTIONS}${options.citations ? `\n\n${CITATION_INSTRUCTIONS}` : ''}` : GENERAL_INSTRUCTIONS;
  return { shared: `${BASE_INSTRUCTIONS}\n\n${paper}\n\n${tools}`, action: own };
}
export function chatInstructions(mode: 'paper' | 'general', action: ChatAction | null = null, webSearch = false, options: InstructionOptions = {}): string {
  const parts = chatInstructionParts(mode, action, webSearch, options);
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
/** Ingest outcomes that added nothing for a reason that isn't the reader's: not charged, and the report says so. A turn
 * without an add (`no_call`: the model couldn't tell which paper the passage names) added nothing either (live check
 * 2026-10-16: 38 credits for "I haven't added anything"). */
export const INGEST_NOT_ADDED: readonly string[] = ['failed', 'not_found', 'unavailable', 'closed', 'needs_update', 'invalid_input', 'no_call'];
/** Ingest after the model's turn: find the paper the add_paper call names and add it as the reader. Returns the outcome
 * and the report to show (null when there is nothing to say). Durable counts and timings only, never text. */
async function runIngest(deps: ChatDependencies, request: ChatRequest, outcome: ProviderOutcome, signal: AbortSignal,
  status: (data: ChatStatus) => void): Promise<{ result: IngestResult | 'invalid_input' | 'no_call'; report: string | null }> {
  const call = outcome.stopReason === 'tool_use' ? outcome.toolCalls?.find(c => c.name === 'add_paper') : undefined;
  const wanted = call ? paperRequest(call.input) : null;
  const record = (units: Record<string, unknown>) => deps.rpc('worker_record_provider_usage', { p_account_id: deps.accountID,
    p_operation_id: request.operationID, p_provider: 'ingest', p_provider_event_id: `operation:${request.operationID}`,
    p_model: 'find-paper', p_microusd: 0, p_units: units })
    .catch(() => deps.log({ event: 'chat_usage_record_failed', operation_id: request.operationID, provider: 'ingest' }));
  if (!wanted) {
    // Never end silently: say why nothing was added, and record it.
    const result = call ? 'invalid_input' as const : 'no_call' as const;
    deps.log({ event: 'chat_ingest', operation_id: request.operationID, result });
    // Counts only (A23): the model chose these key names, so the immutable ledger keeps how many there were, not the names.
    await record({ result, stop_reason: outcome.stopReason, key_count: call && call.input && typeof call.input === 'object' ? Math.min(Object.keys(call.input).length, 64) : null });
    return { result, report: call ? '\n\nI couldn’t read the paper’s details, so it wasn’t added. Try Add paper again. Not charged.' : '\n\nNot charged.' };
  }
  if (!deps.findPaper || !deps.importPaper || signal.aborted) return { result: 'stopped', report: null };
  const budget = AbortSignal.any([signal, AbortSignal.timeout(deps.ingestDeadlineMs ?? INGEST_DEADLINE_MS)]);
  const web = request.capabilities.includes('web_import');
  const clock = deps.now ?? Date.now, started = clock();
  status({ kind: 'finding_paper' });
  const search = await deps.findPaper(wanted, budget, { web,
    tavily: namesTavily(request.consentVersion) && deps.webSearch === true }).catch((): FindResult => ({ status: 'unavailable' }));
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
  await record({ result, kind: found?.kind ?? null, find_ms: findMs, total_ms: clock() - started, web, budget_expired: budget.aborted });
  return { result, report: ingestReport(wanted, found, result) + (INGEST_NOT_ADDED.includes(result) ? ' Not charged.' : '') };
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
  /** A visual answer (chat-visual.ts), sent once before `done`; builds that predate it ignore unknown events. */
  | { event: 'visual'; data: { title: string; html: string } }
  /** Parts of an attached figure (chat-figures.ts), sent once before `done`. */
  | { event: 'figure_request'; data: { figure: string } }
  | { event: 'figure_parts'; data: { figure: string; paragraph: number; title: string; parts: { label: string; box: [number, number, number, number]; note: string }[] } }
  /** Progress while the server searches or adds a paper. Builds that predate it ignore unknown events. */
  | { event: 'status'; data: ChatStatus }
  /** The conversation's topic title (requested with `topic_title`), sent once before `done`; never logged or stored. */
  | { event: 'title'; data: { text: string } }
  /** Follow-up questions the answer suggested (2026-10-14), sent once before `done`; never logged or stored. */
  | { event: 'followups'; data: { questions: string[] } }
  | { event: 'study'; data: { map: StudyMap } }
  /** The equation view's checked symbols (EQUATION_VIEW.md). */
  | { event: 'equation'; data: EquationSymbols }
  /** The figure view's checked walkthrough (FIGURE_VIEW.md), sent once before `done`. */
  | { event: 'figure'; data: FigureWalkthrough }
  | { event: 'figure_detail'; data: FigureDetail }
  /** `model`: the model that served the answer (a fallback model when one did); `profile`: the chosen profile, `auto`
   * resolved; `effort`: the effort the server picked, present only when the request asked for `auto`. */
  | { event: 'done'; data: { stop_reason: string; credits: number; usage: Record<string, number>; model?: string; profile?: string; effort?: string;
    /** Whether the reader paid for this answer (2026-10-16); `reason` names why not (an answer cut off at its length is `limit`). */
    charged?: boolean; reason?: UnchargedReason } }
  /** `credits` (2026-10-14): what a failed answer cost the reader. `charged`/`reason` (2026-10-16): present on every error
   * after the credits were held (always `charged: false`, with why); absent on errors before any hold, which charge nothing. */
  | { event: 'error'; data: { code: ChatErrorCode; credits?: number; retry_after?: number; charged?: boolean; reason?: UnchargedReason } };

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
  /** Null when OpenRouter is not configured in this environment. Serves every model in the profile table, each on its
   * pinned OpenRouter route (provider-spending.ts admittedModelCalls around openrouter-chat.ts). */
  generate: ((params: ModelRequest, options: StreamOptions) => Promise<ProviderOutcome>) | null;
  /** DeepSeek may answer (CHAT_DEEPSEEK on or hidden, with a key). Off, a DeepSeek choice is `invalid_request`. */
  deepseek?: boolean;
  gemini?: boolean;
  /** Whether an admitted model's reviewed price card stays valid for this answer (A4, migration 0101: the chat function
   * reads app_private.openrouter_tariffs). Absent: every model is open and admission alone decides. */
  modelAvailable?: (apiModel: string) => Promise<boolean>;
  sha256Hex(bytes: Uint8Array): Promise<string>;
  log(entry: LogEntry): void;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  deadlineMs?: number;
  ingestDeadlineMs?: number;
  /** Bound on the follow-up suggestion request after the answer (tests shorten it). */
  followUpTimeoutMs?: number;
  /** Bound on the Study knowledge-map request after the answer (tests shorten it). */
  studyTimeoutMs?: number;
  /** The caller's available credits (for the hold cap); null if unknown. */
  availableCredits?: () => Promise<number | null>;
  /** Offer web search (server setting; off by default): our search_web tool, run with `search`. */
  webSearch?: boolean;
  /** Tavily, the search provider (absent when not configured). `ready` is false while it is paused after a failure or its
   * plan allowance is used up; the answer is then written without search. */
  search?: { ready(): Promise<boolean>; run(input: SearchInput, signal: AbortSignal): Promise<SearchOutcome> };
  /** Ingest: the paper that strictly matches the citation, if any: on arXiv, else (with `web`)
   * an open-access copy found through OpenAlex. */
  findPaper?: (request: PaperRequest, signal: AbortSignal, options: { web: boolean; tavily?: boolean }) => Promise<FindResult>;
  /** Ingest: adds one found paper to the caller's library (as the caller). */
  importPaper?: (paper: FoundPaper, signal: AbortSignal) => Promise<'added' | 'present' | 'failed'>;
}

const RESERVE_ERRORS: Record<string, ChatErrorCode> = {
  insufficient_credits: 'insufficient_credits', platform_budget_exhausted: 'platform_budget_exhausted',
  // Review A9 (migration 0105): an account's testing allowance reached its monthly provider-cost cap.
  testing_cap_reached: 'insufficient_credits',
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
    const wait = RETRY_AFTER_SECONDS[code];
    if (!signal.aborted) emit({ event: 'error', data: { code, ...(wait ? { retry_after: wait } : {}) } });
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
  // The reader's model, effort and length, `auto` resolved from the length and this question before anything is held
  // (chat-profiles.ts autoEffort); the quote, the request and the answer all carry the resolved profile.
  const choice = resolveChoice(request.choice, { question: request.turns.at(-1)!.text, selection: request.selection, figures: request.figures.length });
  const profile = resolveProfile(choice);
  // Every answer goes to OpenRouter, so the reader's consent must name it (v5, or v6 which also names DeepSeek's route).
  if (![GEMINI_CONSENT_VERSION, ROUTER_CONSENT_VERSION].includes(request.consentVersion)) { await admitted(); throw new ChatFailure('consent_required'); }
  if (profile.model === 'deepseek' && request.consentVersion !== ROUTER_CONSENT_VERSION) {
    await admitted(); throw new ChatFailure('consent_required');
  }
  // Ingest, Why it matters (the paper only), Study (the paper only) and diagram repairs never search.
  const search = !['ingest', 'relevance', 'diagram_fix', 'study'].includes(request.action ?? '') && deps.webSearch === true;
  // Our search_web tool (Tavily), when its consent is given and it is ready (checked while the paper loads).
  const tavilyReady = search && namesTavily(request.consentVersion) && deps.search
    ? deps.search.ready().catch(() => false) : Promise.resolve(false);
  const balance = deps.availableCredits ? settled(deps.availableCredits()) : null;
  await admitted();

  if (!deps.generate) throw new ChatFailure('provider_unavailable');
  // A model the server does not offer here (DeepSeek switched off or without a key) is not a choice it accepts.
  if (profile.model === 'gemini' && deps.gemini !== true) throw new ChatFailure('invalid_request');
  if (profile.model === 'deepseek' && deps.deepseek !== true) throw new ChatFailure('invalid_request');
  // A4: a model whose price card lapses before this answer could finish is unavailable (no hold, no retry loop); the
  // title, suggestions and map run only while their own model's card holds.
  if (deps.modelAvailable && !await deps.modelAvailable(profile.apiModel)) throw new ChatFailure('model_unavailable');
  const sidesAvailable = !deps.modelAvailable || await deps.modelAvailable(TITLE_MODEL);
  const tavily = await tavilyReady === true;
  // Every model searches through our search_web tool or not at all: no provider-native search is offered.
  const searchOffered = tavily;
  // Related always searches before it answers: say so at once, not after the paper loads and the model's
  // first round has chosen its queries (that first status used to arrive ~4 s in).
  if (request.action === 'related' && searchOffered && !signal.aborted) emit({ event: 'status', data: searchingStatus(undefined) });
  const searchCap = request.action === 'related' ? RELATED_SEARCH_MAX_USES : WEB_SEARCH_MAX_USES;
  const repair = request.action === 'diagram_fix';
  const study = request.action === 'study';
  // The equation view's symbols are one JSON object, held back and checked before the device sees them.
  const symbolsOnly = request.action === 'equation';
  // The figure view's walkthrough is one tool call, checked before the device sees it; any words are held back with it.
  const walkthroughOnly = request.action === 'figure';
  // One part extracted (owner, build 62; deprecated 2026-10-21, older builds only): the same tool with one section and its
  // box, checked and held back the same way.
  const detailOnly = request.action === 'figure_detail';
  const heldBack = symbolsOnly || walkthroughOnly || detailOnly;
  // Flash counts reasoning against max_tokens: the live DPO symbol request used the old 2,000-token
  // allowance before completing its JSON. Keep the answer allowance plus the profile's reasoning room.
  const symbolTokens = EQUATION_MAX_TOKENS + (profile.model === 'gemini' ? EFFORTS.find(e => e.id === profile.effort)!.thinkingTokens : 0);
  // The resolved profile (above); a repair always uses the default model with its own small allowance.
  const maxTokens = repair ? DIAGRAM_FIX_MAX_TOKENS : symbolsOnly ? symbolTokens : walkthroughOnly ? figureMaxTokens(profile.effort)
    : detailOnly ? figureDetailMaxTokens(profile.effort) : profile.maxTokens;
  const instructions = chatInstructionParts(request.mode, request.action, searchOffered,
    { citations: request.localContext?.format === 'reader-local-context-v2', visuals: request.visuals, ...(request.study ? { studyMap: request.study } : {}) });
  // The length's instructions follow the paper with the action's own, so neither invalidates the cached paper.
  // A Study turn has its own length (one step, one question); the profile's length would contradict it.
  const offersParts = request.visuals && request.mode === 'paper' && request.action !== 'ingest' && !repair;
  // A device that can answer a figure request (and may send figures: consent v3) is offered look_at_figure with the parts
  // tool, whether or not this question has a figure, so the tools (part of the cached prefix) stay the same per device.
  const offersLook = offersParts && request.capabilities.includes('figure_requests') && namesFigures(request.consentVersion);
  // A build with the figure view (consent v3 or later) has figure_walkthrough in every paper chat, so its walkthroughs
  // and its chats share the cached tools; the tool is the walkthrough's form, never offered for Add paper or a repair.
  const offersWalkthrough = request.mode === 'paper' && request.action !== 'ingest' && !repair && namesFigures(request.consentVersion)
    && request.capabilities.includes(FIGURE_VIEW_CAPABILITY);
  const figureView = isFigureAction(request.action);
  // The figure view's own instructions say how to read its figure; the chat's figure instructions (parts) do not apply.
  const trailing = [instructions.action, figureView ? null : figureInstructions(request.figures, offersParts, offersLook),
    repair || study || heldBack ? null : profile.lengthInstructions].filter(Boolean).join('\n\n') || null;
  const makeParams = (paper: PaperContext | null) => chatRequestParams({ instructions: instructions.shared, actionInstructions: trailing,
    paper, turns: request.turns, selection: request.selection, maxTokens, figures: request.figures.length ? figureBlocks(request.figures) : undefined,
    model: { id: profile.apiModel, effort: profile.effort }, tools: request.action === 'ingest' ? [ADD_PAPER_TOOL]
      : [...(request.action === 'diagram_fix' ? [CREATE_DIAGRAM_TOOL] : request.visuals ? [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, ...(request.mode === 'paper' ? [SHOW_FIGURE_PARTS_TOOL] : []), ...(offersLook ? [LOOK_AT_FIGURE_TOOL] : [])] : []),
        ...(offersWalkthrough ? [FIGURE_WALKTHROUGH_TOOL] : []),
        ...(tavily ? [SEARCH_WEB_TOOL] : [])] });
  const held = balance ? await balance : null;
  const available = held?.ok ? held.value : null;
  if (deps.availableCredits && (available === null || !Number.isSafeInteger(available) || available < 0)) throw new ChatFailure('service_unavailable');
  // The history/instructions/output budget already imply this minimum hold.
  // Refuse clearly insufficient balances before downloading the paper; cheap
  // general chats still use their own quote, not an invented 50-credit minimum.
  const minimum = Math.min(HOLD_CAP_MINIMUM_CREDITS, holdFor(promptCharacters(makeParams(null)), maxTokens, profile.apiModel).credits);
  if (available !== null && available < minimum) throw new ChatFailure('insufficient_credits');

  let paper: PaperContext | null = null;
  if (request.localContext) {
    const local = request.localContext;
    let membership: { title?: string };
    try { membership = await deps.rpc('worker_local_chat_context', { p_account_id: deps.accountID,
      p_membership_id: local.membership_id, p_source_id: local.source_id, p_revision: local.revision }) as typeof membership; }
    catch (error) { throw new ChatFailure(reason(error) === 'document_unavailable' ? 'document_unavailable' : 'service_unavailable'); }
    if (!membership || typeof membership.title !== 'string') throw new ChatFailure('document_unavailable');
    paper = { title: membership.title, text: local.text };
  } else if (request.mode === 'paper') {
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
  const hold = holdForParams(params);
  if (searchOffered) {
    // Each search's round and results (inference.ts webSearchHoldMicrousd).
    hold.microusd += webSearchHoldMicrousd(hold.inputTokens, searchCap, params.model);
  }
  // The topic title is a second, small request in the same operation: its whole ceiling is held too.
  const titleParams = request.topicTitle && sidesAvailable ? titleRequestParams({ turns: request.turns, selection: request.selection, paperTitle: paper?.title ?? null }) : null;
  const titleHold = titleParams ? holdForParams(titleParams) : null;
  if (titleHold) hold.microusd += titleHold.microusd;
  // Follow-up suggestions are a third small request, after the answer: its ceiling (every excerpt at its limit) is held too.
  const followUpHold = request.followUps && sidesAvailable && !repair && request.action !== 'ingest' ? holdForParams(FOLLOW_UP_HOLD_PARAMS) : null;
  if (followUpHold) hold.microusd += followUpHold.microusd;
  // Study: the knowledge-map request after the answer is held at its largest (a full map, both excerpts at their limits).
  const studyHold = study && sidesAvailable ? holdForParams(STUDY_HOLD_PARAMS) : null;
  if (studyHold) hold.microusd += studyHold.microusd;
  hold.credits = creditsFor(hold.microusd);
  if (available !== null && Number.isSafeInteger(available) && available >= HOLD_CAP_MINIMUM_CREDITS && available < hold.credits) {
    hold.credits = available;
  }
  const digest = await deps.sha256Hex(encoder.encode(canonicalRequest(request)));
  if (signal.aborted) return;

  let reservation: { replayed?: unknown; state?: unknown };
  try {
    // The quote freezes what this hold was sized for (migration 047): the profile and its model, the output
    // allowance (thinking included), the rate version and tariff, the input estimate, searches and the title.
    reservation = await deps.rpc('worker_reserve_chat', {
      p_account_id: deps.accountID, p_id: request.operationID, p_request_sha256: `\\x${digest}`,
      p_rate_version: RATE_VERSION, p_credits: hold.credits, p_microusd: hold.microusd,
      p_quote: chatQuote(profile, params, hold.inputTokens, searchOffered ? searchCap : 0, titleHold?.microusd ?? null, followUpHold?.microusd ?? null, repair, studyHold?.microusd ?? null),
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
  // Our own time limit is told apart from the reader leaving: reaching it never charges the reader.
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; deadline.abort(); }, deps.deadlineMs ?? GENERATION_DEADLINE_MS);
  const stop = () => deadline.abort();
  signal.addEventListener('abort', stop, { once: true });
  let outcome: ProviderOutcome;
  let wroteText = false, answerTail = '', answerHead = '', heldText = '';
  const stats: SearchStats = { tavily: 0, credits: 0, failures: 0 };
  // Status lines go only to this reader's stream (the search query included); logs keep counts only.
  const status = (data: ChatStatus) => { if (!signal.aborted) emit({ event: 'status', data }); };
  // The title is written alongside the answer (from the question, not the answer), so it adds no wait.
  const titleStop = new AbortController();
  const stopTitle = () => titleStop.abort();
  deadline.signal.addEventListener('abort', stopTitle, { once: true });
  const titling = titleParams && titleHold ? writeTitle(deps.generate, titleParams, titleHold.inputTokens, titleStop.signal, now) : null;
  let title: TitleResult | null = null;
  // Whether the reader had left when the answer itself ended (A12): leaving later, during the title's grace, the
  // suggestions or the map, does not turn a finished answer into an unpaid one.
  let leftDuringAnswer = false;
  try {
    outcome = await generateAnswer(deps, deps.generate, request.operationID, params, {
      signal: deadline.signal, inputEstimateTokens: hold.inputTokens, now,
      onText: text => { if (text.trim()) wroteText = true; answerTail = (answerTail + text).slice(-4000); if (answerHead.length < ANSWER_HEAD_CHARACTERS) answerHead = (answerHead + text).slice(0, ANSWER_HEAD_CHARACTERS);
        if (heldBack) { heldText = (heldText + text).slice(0, 40_000); return; }
        if (!signal.aborted && text) emit({ event: 'delta', data: { text } }); },
      onStatus: status,
    }, { tavily, cap: searchCap }, stats);
    leftDuringAnswer = signal.aborted;
    if (titling) {
      // A title still being written gets a short grace period; abandoning it still settles its attempt.
      const grace = setTimeout(stopTitle, outcome.status === 'complete' && !signal.aborted ? TITLE_GRACE_MS : 0);
      try { title = await titling; } finally { clearTimeout(grace); }
    }
  } finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', stop);
    deadline.signal.removeEventListener('abort', stopTitle);
  }
  // The answer's own rounds (searches and fees included): what a Stop pays for.
  const answer = outcome;
  // A finished answer: complete, not refused and not cut off at its length. Only it gets suggestions or a map update.
  const finished = answer.status === 'complete' && answer.stopReason !== 'refusal' && !LIMIT_STOP_REASONS.includes(answer.stopReason ?? '');
  // The title's request is part of this operation: priced, held and recorded with the answer's.
  if (title?.outcome.attempts.length) {
    outcome = { ...outcome, attempts: [...outcome.attempts, ...title.outcome.attempts], exact: outcome.exact && title.outcome.exact };
  }
  // Follow-up suggestions read the finished answer, so they come after it (bounded; the answer is already on the
  // device). Only a complete, non-refused answer with text gets them; the request is part of this operation too.
  let suggested: FollowUpResult | null = null;
  // An answer that asked for a figure is not the answer: the device asks again with it, and that one gets suggestions.
  const asksForFigure = offersLook && !request.figures.length && !isEquationAction(request.action) && !!outcome.toolCalls?.some(c => c.name === 'look_at_figure');
  if (followUpHold && finished && wroteText && !asksForFigure && !signal.aborted) {
    const params = followUpRequestParams({ paperTitle: paper?.title ?? null, selection: request.selection, question: request.turns.at(-1)!.text, answer: answerHead });
    suggested = await suggestFollowUps(deps.generate, params, followUpHold.inputTokens, AbortSignal.any([signal, AbortSignal.timeout(deps.followUpTimeoutMs ?? FOLLOW_UP_TIMEOUT_MS)]), now);
    if (suggested.outcome.attempts.length) {
      outcome = { ...outcome, attempts: [...outcome.attempts, ...suggested.outcome.attempts], exact: outcome.exact && suggested.outcome.exact };
    }
  }
  // Study: the knowledge map is updated from the exchange after the answer (the previous map, the reader's answer,
  // the tutor's reply; never the paper). The reader's first message starts the study and is no answer.
  let studied: StudyResult | null = null;
  if (studyHold && request.study && finished && wroteText && !signal.aborted) {
    const params = studyMapRequestParams({ map: request.study, answer: request.turns.length > 1 ? request.turns.at(-1)!.text : null, reply: answerHead });
    studied = await updateStudyMap(deps.generate, params, studyHold.inputTokens, AbortSignal.any([signal, AbortSignal.timeout(deps.studyTimeoutMs ?? STUDY_TIMEOUT_MS)]), now);
    if (studied.outcome.attempts.length) {
      outcome = { ...outcome, attempts: [...outcome.attempts, ...studied.outcome.attempts], exact: outcome.exact && studied.outcome.exact };
    }
  }

  const described = symbolsOnly ? equationSymbols(heldText, paragraphCount(paper?.text ?? '')) : null;
  const symbolWords = symbolsOnly && !described ? equationFallbackText(heldText) : '';
  // The figure view's walkthrough, checked; without one, the words in its call (else the model's own) are the description.
  const walkthroughCall = offersWalkthrough ? answer.toolCalls?.find(c => c.name === FIGURE_WALKTHROUGH_TOOL.name) : undefined;
  const paragraphs = walkthroughCall ? paragraphCount(paper?.text ?? '') : 0;
  const walkthrough = walkthroughOnly && walkthroughCall ? figureWalkthrough(walkthroughCall.input, paragraphs) : null;
  const walkthroughWords = walkthroughOnly && !walkthrough
    ? ((walkthroughCall ? figureWalkthroughText(walkthroughCall.input, paragraphs) : '') || heldText.trim()).slice(0, 12_000) : '';
  // One part extracted: its section with a usable box; without one, its words (else the model's own) reach the reader
  // without a crop, and the device says the part couldn't be cropped.
  const detail = detailOnly && walkthroughCall ? figureDetail(walkthroughCall.input, paragraphs) : null;
  const detailWords = detailOnly && !detail
    ? ((walkthroughCall ? figureWalkthroughText(walkthroughCall.input, paragraphs) : '') || heldText.trim()).slice(0, 6_000) : '';
  // How the answer ended decides whether the reader pays (owner decision 2026-10-16, CHAT.md "When an answer stops
  // early"): work that finished, or the part the reader chose to stop. Anything else that ended it costs them nothing.
  // The figure view delivers only what it shows: a walkthrough or words (its tool calls are never relayed otherwise).
  const showsWork = symbolsOnly ? !!described || !!symbolWords : walkthroughOnly ? !!walkthrough || !!walkthroughWords : detailOnly ? !!detail || !!detailWords
    : figureView ? wroteText : wroteText || !!answer.toolCalls?.length;
  const ending = await answerEnding(deps, request, answer, { readerLeft: leftDuringAnswer, timedOut, delivered: showsWork });
  const charged = CHARGED_ENDINGS.includes(ending);
  // Provider spend (the platform budget): OpenRouter's cost of every attempt. Tavily searches within its prepaid plan
  // add nothing (a fixed commitment); the reader's price adds Tavily's per-credit price.
  const actual = Math.ceil(priceAttempts(outcome.attempts));
  // What reached the reader: the answer's own rounds and, with a completed answer, the title, suggestions and map that
  // were relayed. A side request that failed, came back unusable or too late is Gradstep's cost.
  // Side requests are relayed only to a reader still connected (every emit below checks); one who left gets none of them.
  const sides = ending === 'completed' && !signal.aborted ? [title?.text ? title.outcome : null, suggested?.questions ? suggested.outcome : null, studied?.map ? studied.outcome : null] : [];
  const delivered = readerPriceAttempts(answer.attempts) + sides.reduce((sum, part) => sum + (part ? readerPriceAttempts(part.attempts) : 0), 0);
  const priced = Math.ceil(delivered + stats.credits * TAVILY_CREDIT_MICROUSD);
  // Ingest: at most one add per request, only of a strictly matched arXiv paper, only when the turn ended in the tool
  // call (not cut off). It runs before the settlement (import takes no hold) so an add that doesn't happen costs the
  // reader nothing (owner, 2026-10-16: provider cost without value for the reader is Gradstep's); the reader's own
  // Stop still pays for the part written.
  const ingest = outcome.status === 'complete' && outcome.stopReason !== 'refusal' && request.action === 'ingest'
    ? await runIngest(deps, request, outcome, signal, status) : null;
  const notAdded = ingest !== null && INGEST_NOT_ADDED.includes(ingest.result);
  // The customer is never charged above the hold, but the platform budget records the true provider cost (an overrun
  // is recorded and alerted, migration 079). A stopped answer charges only what was written (`readerMicrousd`: from
  // OpenRouter's generation record when it could be read, else the streamed output), nothing when no text or tool call
  // arrived; the conservative estimate stays the platform's liability until it is resolved (A1, 2026-10-21).
  const credits = charged && !notAdded && (answer.status === 'complete' || answer.messageID) ? Math.min(creditsFor(priced), hold.credits) : 0;
  // Gradstep pays the rest: everything for an uncharged ending, the undelivered side requests otherwise.
  const absorbed = credits > 0 ? Math.max(0, actual - Math.ceil(delivered)) : actual;
  if (credits > 0 && priced > hold.microusd) deps.log({ event: 'chat_usage_exceeded_hold', operation_id: request.operationID, actual_microusd: priced, hold_microusd: hold.microusd });
  else if (credits > 0 && creditsFor(priced) > hold.credits) deps.log({ event: 'chat_credits_capped_at_balance', operation_id: request.operationID, credits: creditsFor(priced), hold_credits: hold.credits });
  const settledAs = await settle(deps, request.operationID, { credits, microusd: actual, action: request.action ?? 'answer', ending, absorbed });
  // A23: the reader is told what was recorded. A settlement the database refused, or one that could not be confirmed and
  // reads back unsettled, is settled later by the stale sweep as our server's ending, charging nothing.
  const reported = settledAs === 'settled' ? { credits, charged } : await settlementReadback(deps, request.operationID);
  await recordUsage(deps, request.operationID, outcome, actual);
  if (stats.tavily || stats.failures) await recordSearchUsage(deps, request.operationID, stats);
  // Counts only (never text): whether answers search the web, per selection action.
  if (outcome.rejectionReason) deps.log({ event: 'chat_provider_rejected', operation_id: request.operationID,
    provider: profile.provider, status: outcome.httpStatus ?? null, reason: outcome.rejectionReason });
  deps.log({ event: 'chat_answer', operation_id: request.operationID, action: request.action ?? 'none', mode: request.mode, ending,
    charged: reported.charged, credits: reported.credits, ...(settledAs === 'settled' ? {} : { settlement: settledAs }),
    web_search_offered: searchOffered, search_provider: tavily ? 'tavily' : 'none',
    web_searches: stats.tavily, tavily_searches: stats.tavily, search_failures: stats.failures,
    sources: outcome.sources?.length ?? 0, profile: repair ? 'diagram_fix' : profile.id,
    // Whether the effort in `profile` was picked by the server (`auto`), and who answered.
    auto_effort: request.choice?.effort === 'auto', provider: profile.provider,
    // Whether a title was written (never the title itself), and how many follow-ups were suggested (never their text).
    title: !titleParams ? 'not_requested' : title?.text ? 'written' : title?.outcome.status === 'complete' ? 'unusable' : 'failed',
    ...(followUpHold ? { follow_ups: !suggested ? 'skipped' : suggested.questions ? 'written' : suggested.outcome.status === 'complete' ? 'unusable' : 'failed',
      follow_up_count: suggested?.questions?.length ?? 0 } : {}),
    // Study: whether the map was updated and its size (never a concept name).
    ...(studyHold ? { study: !studied ? 'skipped' : studied.map ? 'written' : studied.outcome.status === 'complete' ? 'unusable' : 'failed',
      study_concepts: studied?.map?.concepts.length ?? request.study?.concepts.length ?? 0 } : {}) });

  if (signal.aborted) return;
  // Every event after the hold says whether the reader paid; when not, why (a machine-readable reason for the clients).
  const billing = reported.charged ? { charged: true }
    : { charged: false, reason: (charged ? 'server' : ending) as UnchargedReason };
  const reportedCredits = reported.credits;
  if (outcome.status === 'complete') {
    if (outcome.stopReason === 'refusal') { emit({ event: 'error', data: { code: 'refused', credits: 0, charged: false, reason: 'refusal' } }); return; }
    // Ingest's report, after the settlement it decided (run before it, below).
    if (ingest?.report && !signal.aborted) emit({ event: 'delta', data: { text: ingest.report } });
    const usage = outcome.attempts.reduce((sum, attempt) => ({
      input_tokens: sum.input_tokens + attempt.usage.input,
      cache_creation_input_tokens: sum.cache_creation_input_tokens + attempt.usage.cacheWrite5m + attempt.usage.cacheWrite1h,
      cache_read_input_tokens: sum.cache_read_input_tokens + attempt.usage.cacheRead,
      output_tokens: sum.output_tokens + attempt.usage.output,
    }), { input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0 });
    // Web results must be shown with the answer that used them.
    // Unless the answer already ends with its own Sources section.
    if (outcome.sources?.length && !heldBack && !signal.aborted && !/\n\nSources:\n/.test(answerTail)) {
      const text = sourcesText(outcome.sources);
      if (text) { emit({ event: 'delta', data: { text } }); wroteText = true; }
    }
    // Diagram: relayed once to the device, which stores it encrypted. Only calls from
    // rounds that ended in tool use are reported (none cut off mid-call).
    const drawing = request.action !== 'ingest' && !isViewAction(request.action) ? outcome.toolCalls?.find(c => c.name === 'create_diagram') : undefined;
    if (drawing) {
      const diagram = diagramRequest(drawing.input);
      deps.log({ event: diagram ? 'chat_diagram' : 'chat_diagram_invalid_input', operation_id: request.operationID });
      if (diagram && !signal.aborted) {
        // The device keeps a diagram only with a non-empty answer (a repair replaces one; it needs no text).
        if (!wroteText && !repair) emit({ event: 'delta', data: { text: `Diagram: “${diagram.title}”` } });
        emit({ event: 'diagram', data: diagram });
      }
    }
    // Figure parts: the regions of an attached figure the device crops and shows, relayed once (format figure-parts-v1).
    const breakdown = offersParts && request.figures.length && !figureView ? outcome.toolCalls?.find(c => c.name === 'show_figure_parts') : undefined;
    if (breakdown) {
      const parts = figurePartsRequest(breakdown.input, request.figures);
      deps.log({ event: parts ? 'chat_figure_parts' : 'chat_figure_parts_invalid_input', operation_id: request.operationID });
      if (parts && !signal.aborted) {
        // Without prose of its own, the answer is the parts' notes (the reader always has the explanation in the chat).
        if (!wroteText) emit({ event: 'delta', data: { text: figurePartsFallbackText(parts) } });
        emit({ event: 'figure_parts', data: parts });
      }
    }
    // A figure request: the device attaches that figure and asks again (only when none was attached; never twice).
    const look = offersLook && !request.figures.length && !isEquationAction(request.action) ? outcome.toolCalls?.find(c => c.name === 'look_at_figure') : undefined;
    if (look) {
      const wanted = figureLookRequest(look.input);
      deps.log({ event: wanted ? 'chat_figure_request' : 'chat_figure_request_invalid_input', operation_id: request.operationID });
      if (wanted && !signal.aborted) emit({ event: 'figure_request', data: wanted });
    }
    // Visual: one sanitized HTML fragment, relayed once like a diagram; the device keeps it encrypted (format html-v1).
    const shown = request.action !== 'ingest' && request.action !== 'diagram_fix' && !isViewAction(request.action) && request.visuals ? outcome.toolCalls?.find(c => c.name === 'create_visual') : undefined;
    if (shown) {
      const visual = visualRequest(shown.input);
      deps.log({ event: visual ? 'chat_visual' : 'chat_visual_invalid_input', operation_id: request.operationID });
      if (visual && !signal.aborted) {
        if (!wroteText) emit({ event: 'delta', data: { text: `Visual: “${visual.title}”` } });
        emit({ event: 'visual', data: visual });
      }
    }
    // The equation view's symbols: checked JSON, relayed once (format equation-symbols-v1). Without usable JSON the
    // model's words are the description, so the reader still sees something for what was paid.
    if (symbolsOnly && !signal.aborted) {
      deps.log({ event: described ? 'chat_equation' : 'chat_equation_invalid_output', operation_id: request.operationID, symbols: described?.symbols.length ?? 0 });
      if (described) emit({ event: 'equation', data: described });
      else if (symbolWords) emit({ event: 'delta', data: { text: symbolWords } });
    }
    // The figure view's walkthrough: checked, relayed once (format figure-walkthrough-v1). Without a usable one the
    // model's words are the description, so the reader still sees what was paid for (counts only in the log).
    if (walkthroughOnly && !signal.aborted) {
      deps.log({ event: walkthrough ? 'chat_figure_walkthrough' : 'chat_figure_walkthrough_invalid_output', operation_id: request.operationID,
        called: !!walkthroughCall, sections: walkthrough?.sections.length ?? 0, boxes: walkthrough?.sections.filter(s => s.box).length ?? 0,
        boxes_offered: walkthroughCall ? offeredBoxes(walkthroughCall.input) : 0 });
      if (walkthrough) emit({ event: 'figure', data: walkthrough });
      else if (walkthroughWords) emit({ event: 'delta', data: { text: walkthroughWords } });
    }
    // One part extracted: checked, relayed once (format figure-detail-v1); without a usable box, its words.
    if (detailOnly && !signal.aborted) {
      deps.log({ event: detail ? 'chat_figure_detail' : 'chat_figure_detail_invalid_output', operation_id: request.operationID,
        called: !!walkthroughCall, boxes_offered: walkthroughCall ? offeredBoxes(walkthroughCall.input) : 0 });
      if (detail) emit({ event: 'figure_detail', data: detail });
      else if (detailWords) emit({ event: 'delta', data: { text: detailWords } });
    }
    // An ordinary answer that called figure_walkthrough anyway (it is only the figure view's): never relayed as one, and
    // when it wrote nothing else, its words are the answer.
    if (walkthroughCall && !isViewAction(request.action) && !wroteText && !signal.aborted) {
      const words = figureWalkthroughText(walkthroughCall.input, paragraphs);
      deps.log({ event: 'chat_figure_walkthrough_in_answer', operation_id: request.operationID });
      if (words) emit({ event: 'delta', data: { text: words.slice(0, 12_000) } });
    }
    // Follow-up questions: relayed once, never stored (chat-follow-ups.ts; counted in chat_answer).
    if (suggested?.questions && !signal.aborted) emit({ event: 'followups', data: { questions: suggested.questions } });
    // Study: the updated knowledge map, relayed once; the device keeps it with the conversation and sends it back.
    if (studied?.map && !signal.aborted) emit({ event: 'study', data: { map: studied.map } });
    if (signal.aborted) return;
    if (title?.text) emit({ event: 'title', data: { text: title.text } });
    // A tool call ends the provider turn; the server completed it.
    const stopReason = outcome.stopReason === 'tool_use' ? 'end_turn' : outcome.stopReason ?? 'end_turn';
    // Which model answered (the serving model of the last attempt, a fallback when one ran) and with which profile.
    const served = answeringModel(outcome);
    // `profile` is the resolved profile; `effort` (2026-10-16) names the effort the server picked when the request said `auto`.
    emit({ event: 'done', data: { stop_reason: stopReason, credits: reportedCredits, usage, ...(served ? { model: served } : {}),
      profile: repair ? 'diagram_fix' : profile.id, ...(request.choice?.effort === 'auto' ? { effort: profile.effort } : {}), ...billing } });
    return;
  }
  // A4: a card that lapsed between the check above and admission: the model is unavailable, not a fault to retry.
  if (outcome.rejectionReason === 'tariff_expired') {
    emit({ event: 'error', data: { code: 'model_unavailable', credits: reportedCredits, ...billing } });
    return;
  }
  // A13: an unfunded OpenRouter account (402) fails every model alike: it is the service's, not the chosen model's.
  // Keep the operator's billing detail private and ask the reader to come back later instead of switching models;
  // a quick retry cannot help. Settlement above is unchanged.
  if (ending === 'provider' && outcome.failure === 'provider_billing') {
    deps.log({ event: 'chat_provider_billing', operation_id: request.operationID, provider: profile.provider });
    emit({ event: 'error', data: { code: 'service_unavailable', credits: reportedCredits, ...billing, retry_after: PROVIDER_BILLING_RETRY_SECONDS } });
    return;
  }
  const code: ChatErrorCode = ending === 'server' ? 'service_unavailable' : 'provider_unavailable';
  const retryAfter = ending === 'provider' && outcome.retryAfterMs != null ? Math.min(3600, Math.max(1, Math.ceil(outcome.retryAfterMs / 1000))) : RETRY_AFTER_SECONDS[code]!;
  emit({ event: 'error', data: { code, credits: reportedCredits, ...billing, retry_after: retryAfter } });
}

/** How a held answer ended (see ChatEnding). A refusal stays a refusal; a finished turn with something to show is
 * completed even if the reader left as it finished or afterwards (A12: the answer was written; CHAT.md "charged as
 * finished"); then the reader leaving while it was written (their Stop, recorded by v1_chat_stop, or a dropped
 * connection; builds without `stop_signal` can't say which), then an answer cut short by our time limit, our server or
 * the provider, a length limit, and a finished turn with nothing to show (the provider's). */
async function answerEnding(deps: ChatDependencies, request: ChatRequest, answer: ProviderOutcome,
  state: { readerLeft: boolean; timedOut: boolean; delivered: boolean }): Promise<ChatEnding> {
  if (answer.status === 'complete' && answer.stopReason === 'refusal') return 'refusal';
  if (answer.status === 'complete' && !LIMIT_STOP_REASONS.includes(answer.stopReason ?? '') && state.delivered) return 'completed';
  if (state.readerLeft) {
    if (!request.capabilities.includes('stop_signal')) return 'left';
    return await stopRequested(deps, request.operationID) ? 'stopped' : 'connection';
  }
  // The deadline matters only if it cut the answer short (it may fire during the title's grace, after a finished answer).
  if (answer.status !== 'complete') return state.timedOut ? 'limit' : answer.cause ?? 'provider';
  if (LIMIT_STOP_REASONS.includes(answer.stopReason ?? '')) return 'limit';
  return state.delivered ? 'completed' : 'provider';
}

/** Whether the reader pressed Stop: their app records it (v1_chat_stop) before it closes the stream. A record still on
 * its way gets one more look after a short wait; one that can't be read counts as not pressed (nothing is charged). */
async function stopRequested(deps: ChatDependencies, operationID: string): Promise<boolean> {
  const sleep = deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms)));
  for (let look = 0; look < 2; look++) {
    try {
      if (await deps.rpc('worker_chat_stop_requested', { p_account_id: deps.accountID, p_operation_id: operationID }) === true) return true;
    } catch { /* unknown: not pressed */ }
    if (look === 0) await sleep(STOP_GRACE_MS);
  }
  return false;
}

/** How long to wait after the model gateway refused for its account's balance (A13): an operator must top it up. */
export const PROVIDER_BILLING_RETRY_SECONDS = 300;
/** Seconds a client should wait before asking again, by error (Resilience, fix 6); absent where waiting won't help. */
export const RETRY_AFTER_SECONDS: Partial<Record<ChatErrorCode, number>> = { rate_limited: 60, provider_unavailable: 10, service_unavailable: 10 };

/** The reservation's frozen quote (migration 047, `worker_reserve_chat`): what the hold was sized for. No prompt text. */
export function chatQuote(profile: ChatProfile, params: ModelRequest, inputTokens: number,
  maxSearches: number, titleMicrousd: number | null, followUpMicrousd: number | null, repair: boolean, studyMicrousd: number | null = null): Record<string, string | number | null> {
  // The answer and auxiliaries retain their exact billed OpenRouter model identities and reviewed cards.
  return { profile_version: PROFILE_VERSION, profile: repair ? 'diagram_fix' : profile.id, model: params.model,
    effort: (params.output_config?.effort ?? 'low') as string, length: repair ? 'repair' : profile.length,
    tariff: tariffFor(params.model) ?? 'unreviewed',
    max_output_tokens: params.max_tokens, input_estimate_tokens: inputTokens, max_searches: maxSearches,
    title_model: titleMicrousd === null ? null : TITLE_MODEL, title_max_tokens: titleMicrousd === null ? null : TITLE_MAX_TOKENS,
    title_ceiling_microusd: titleMicrousd,
    ...(followUpMicrousd === null ? {} : { follow_ups_model: FOLLOW_UP_MODEL, follow_ups_max_tokens: FOLLOW_UP_MAX_TOKENS, follow_ups_ceiling_microusd: followUpMicrousd }),
    ...(studyMicrousd === null ? {} : { study_model: STUDY_MODEL, study_max_tokens: STUDY_MAX_TOKENS, study_ceiling_microusd: studyMicrousd }) };
}

/** The model that wrote the answer: the last attempt's serving model, when it is a plausible model identifier. */
function answeringModel(outcome: ProviderOutcome): string | null {
  const served = outcome.model ?? outcome.attempts.at(-1)?.model ?? null;
  const model = served ? clientDeepSeekModel(clientClaudeModel(served)) : null; // Stable client identity; attempts and quotes retain the billed route.
  return model && /^[a-z0-9][a-z0-9./-]{0,63}$/.test(model) ? model : null;
}

/** How much of the answer the follow-up request may read (chat-follow-ups.ts bounds it again). */
const ANSWER_HEAD_CHARACTERS = 2_400;

interface FollowUpResult { outcome: ProviderOutcome; questions: string[] | null }
/** One follow-up suggestion request (the tool call forced) through the same admitted provider adapter. Never throws. */
async function suggestFollowUps(generate: NonNullable<ChatDependencies['generate']>, params: ModelRequest,
  inputEstimateTokens: number, signal: AbortSignal, now: () => number): Promise<FollowUpResult> {
  try {
    const outcome = await generate(params, { signal, inputEstimateTokens, now, onText: () => { /* a forced tool call writes no text */ } });
    const call = outcome.status === 'complete' ? outcome.toolCalls?.find(c => c.name === SUGGEST_FOLLOW_UPS_TOOL.name) : undefined;
    return { outcome, questions: call ? followUpRequest(call.input) : null };
  } catch {
    return { outcome: { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null, refusalCategory: null,
      attempts: [{ model: params.model, estimated: true, usage: { input: inputEstimateTokens, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }],
      exact: false }, questions: null };
  }
}

interface StudyResult { outcome: ProviderOutcome; map: StudyMap | null }
/** One knowledge-map request (the tool call forced) through the same admitted provider adapter. Never throws. */
async function updateStudyMap(generate: NonNullable<ChatDependencies['generate']>, params: ModelRequest,
  inputEstimateTokens: number, signal: AbortSignal, now: () => number): Promise<StudyResult> {
  try {
    const outcome = await generate(params, { signal, inputEstimateTokens, now, onText: () => { /* a forced tool call writes no text */ } });
    const call = outcome.status === 'complete' ? outcome.toolCalls?.find(c => c.name === UPDATE_STUDY_MAP_TOOL.name) : undefined;
    return { outcome, map: call ? studyMap(call.input) : null };
  } catch {
    return { outcome: { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null, refusalCategory: null,
      attempts: [{ model: params.model, estimated: true, usage: { input: inputEstimateTokens, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }],
      exact: false }, map: null };
  }
}

interface TitleResult { outcome: ProviderOutcome; text: string | null }
/** One title request through the same admitted provider adapter as the answer. Never throws. */
async function writeTitle(generate: NonNullable<ChatDependencies['generate']>, params: ModelRequest,
  inputEstimateTokens: number, signal: AbortSignal, now: () => number): Promise<TitleResult> {
  let raw = '';
  try {
    const outcome = await generate(params, { signal, inputEstimateTokens, now, purpose: 'topic_title', onText: text => { raw = (raw + text).slice(0, 2_000); } });
    const usable = outcome.status === 'complete' && outcome.stopReason === 'end_turn';
    return { outcome, text: usable ? cleanTitle(raw) : null };
  } catch {
    return { outcome: { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null, refusalCategory: null,
      attempts: [{ model: params.model, estimated: true, usage: { input: inputEstimateTokens, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }],
      exact: false }, text: null };
  }
}

export interface SearchStats { tavily: number; credits: number; failures: number }
/** Smallest output allowance worth another round after searches. */
const MIN_ROUND_TOKENS = 1_024;

/**
 * The answer, in rounds: search_web (Tavily) is a client tool, so a round that ends
 * in searches is answered with their results and the answer continues. At most one
 * round per allowed search plus one to answer, sharing one output allowance. If Tavily
 * fails, the rest of the answer is written without search. Never throws:
 * a failed round ends the answer with what is known about billing.
 */
async function generateAnswer(deps: ChatDependencies, generate: NonNullable<ChatDependencies['generate']>, operationID: string,
  params: ModelRequest, options: StreamOptions,
  search: { tavily: boolean; cap: number }, stats: SearchStats): Promise<ProviderOutcome> {
  const attempts: ProviderAttempt[] = [], calls: NonNullable<ProviderOutcome['toolCalls']> = [];
  // Pages each Tavily search returned (in rank order): the source list when the answer writes none.
  const searched: { url: string; title: string | null }[][] = [];
  const extra: MessageParam[] = [];
  let tavily = search.tavily, searches = 0, exact = true;
  let firstID: string | null = null, wrote = false, separate = false;
  for (let round = 0; ; round++) {
    const used = attempts.reduce((sum, attempt) => sum + attempt.usage.output, 0);
    let opening = true, outcome: ProviderOutcome;
    try {
      outcome = await generate({ ...params, messages: [...params.messages, ...marked(extra)],
        max_tokens: params.max_tokens - used }, { ...options, onText: text => {
        // A round after searches starts a new paragraph.
        if (opening && text) { if (separate && !/^\s/.test(text)) text = `\n\n${text}`; opening = false; }
        if (text.trim()) wrote = true;
        options.onText(text);
      } });
    } catch {
      // The adapters never throw for a provider's failure: a throw is our own code failing.
      outcome = { status: 'failed', failure: 'provider_error', messageID: null, model: null, stopReason: null, refusalCategory: null,
        attempts: [{ model: null, estimated: true, usage: { input: options.inputEstimateTokens, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }], exact: false,
        cause: 'server' };
    }
    firstID ??= outcome.messageID;
    attempts.push(...outcome.attempts); exact &&= outcome.exact;
    const finish = (): ProviderOutcome => {
      const all = [...calls, ...(outcome.stopReason === 'tool_use' ? outcome.toolCalls ?? [] : [])].filter(call => call.name !== SEARCH_WEB_TOOL.name);
      const { toolCalls: _calls, sources: _sources, ...last } = outcome;
      return { ...last, messageID: firstID ?? outcome.messageID, attempts, exact, ...(all.length ? { toolCalls: all } : {}),
        ...(searched.length ? { sources: searchedPages(searched) } : {}) };
    };
    const left = params.max_tokens - attempts.reduce((sum, attempt) => sum + attempt.usage.output, 0);
    const continuation = outcome.stopReason === 'tool_use' && outcome.toolCalls?.some(call => call.name === SEARCH_WEB_TOOL.name);
    if (outcome.status !== 'complete' || !outcome.content || options.signal.aborted || round >= search.cap || left < MIN_ROUND_TOKENS) {
      // A turn that wanted another round past our round or output bound ends at our limit.
      if (continuation && outcome.status === 'complete') outcome = { ...outcome, status: 'failed', failure: 'provider_error', cause: 'limit' };
      return finish();
    }
    const previous = extra.at(-1);
    const append = () => {
      if (previous?.role === 'assistant') previous.content = [...previous.content as unknown[], ...outcome.content!] as typeof previous.content;
      else extra.push({ role: 'assistant', content: outcome.content as MessageParam['content'] });
    };
    const roundCalls = outcome.stopReason === 'tool_use' ? outcome.toolCalls ?? [] : [];
    if (!roundCalls.some(call => call.name === SEARCH_WEB_TOOL.name) || roundCalls.some(call => !call.id)) return finish();
    calls.push(...roundCalls);
    const results = await Promise.all(roundCalls.map(async (call): Promise<ToolResultBlock> => {
      const reply = (content: ToolResultBlock['content'], error = false): ToolResultBlock =>
        ({ type: 'tool_result', tool_use_id: call.id!, content, ...(error ? { is_error: true } : {}) });
      if (call.name !== SEARCH_WEB_TOOL.name) return reply(call.name === CREATE_DIAGRAM_TOOL.name ? 'The diagram is shown with your answer.' : 'Done.');
      searches++;
      const input = searchInput(call.input);
      if (searches > search.cap) return reply('No searches are left for this answer. Answer with what you have.', true);
      if (!input) return reply('Invalid search: give a short query.', true);
      if (!tavily || !deps.search) return reply(SEARCH_UNAVAILABLE, true);
      options.onStatus?.(searchingStatus(input.query));
      const result = await deps.search.run(input, options.signal).catch((): SearchOutcome => ({ status: 'failed', failure: 'unavailable', retryAfterMs: null }));
      if (result.status === 'ok') {
        stats.tavily++; stats.credits += result.credits;
        searched.push(result.results.map(page => ({ url: page.url, title: page.title || null })));
        return reply(searchResultContent(result.results));
      }
      stats.failures++; tavily = false;
      deps.log({ event: 'chat_search_failed', operation_id: operationID, provider: 'tavily', failure: result.failure });
      return reply(SEARCH_UNAVAILABLE, true);
    }));
    // Results are in (at least one search succeeded): the answer continues from them.
    if (results.some(result => !result.is_error && Array.isArray(result.content)) && !options.signal.aborted) options.onStatus?.({ kind: 'reading' });
    append();
    extra.push({ role: 'user', content: results });
    separate = wrote;
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

const SEARCH_UNAVAILABLE = 'Web search is unavailable right now. Answer without it and say briefly that you could not search.';

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

/** One settlement: the credits the reader pays, the provider spend for the budget, and how the answer ended with the
 * provider cost Gradstep absorbs (migration 079, worker_settle_chat: settled and recorded in one transaction). */
interface Settlement { credits: number; microusd: number; action: ChatAction | 'answer'; ending: ChatEnding; absorbed: number }
/** `settled`: acknowledged. `rejected`: the database refused it (nothing recorded). `unknown`: no acknowledgement after
 * the retries (it may have committed). */
async function settle(deps: ChatDependencies, operationID: string, settlement: Settlement): Promise<'settled' | 'rejected' | 'unknown'> {
  const sleep = deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms)));
  // Settlement is idempotent for identical amounts, so a lost acknowledgement
  // may be retried. It is never repeated with different amounts.
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await deps.rpc('worker_settle_chat', { p_account_id: deps.accountID, p_id: operationID, p_actual_credits: settlement.credits,
        p_actual_microusd: settlement.microusd, p_action: settlement.action, p_ending: settlement.ending, p_absorbed_microusd: settlement.absorbed });
      return 'settled';
    } catch (error) {
      const failure = reason(error);
      if (failure !== 'transport' || attempt === 3) {
        deps.log({ event: 'chat_settle_failed', operation_id: operationID, reason: failure === 'transport' ? 'transport' : 'rejected' });
        return failure === 'transport' ? 'unknown' : 'rejected';
      }
      await sleep(250 * attempt);
    }
  }
  return 'unknown';
}

/** What an unconfirmed settlement recorded (worker_operation_outcome): its credits and whether the reader paid; an
 * operation still open (or unreadable) charges nothing, as the stale sweep will settle it. */
async function settlementReadback(deps: ChatDependencies, operationID: string): Promise<{ credits: number; charged: boolean }> {
  try {
    const outcome = await deps.rpc('worker_operation_outcome', { p_account_id: deps.accountID, p_operation_id: operationID }) as
      { state?: unknown; actual_credits?: unknown; charged?: unknown } | null;
    if (outcome?.state === 'settled' && Number.isSafeInteger(outcome.actual_credits)) {
      return { credits: outcome.actual_credits as number, charged: outcome.charged === true };
    }
  } catch { /* unreadable: as unsettled */ }
  return { credits: 0, charged: false };
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

/** The operation's usage summary under OpenRouter. Each admitted attempt already wrote its own usage row
 * (`attempt:<id>`), so the database keeps this summary only for operations without attempts (migration 034). */
async function recordUsage(deps: ChatDependencies, operationID: string, outcome: ProviderOutcome, microusd: number) {
  if (!outcome.attempts.length) return;
  const provider = 'openrouter';
  const units = {
    estimated: !outcome.exact, stop_reason: outcome.stopReason, refusal_category: outcome.refusalCategory, failure: outcome.failure,
    web_searches: 0,
    attempts: outcome.attempts.map(attempt => ({ model: attempt.model, estimated: attempt.estimated, input_tokens: attempt.usage.input,
      cache_write_5m_tokens: attempt.usage.cacheWrite5m, cache_write_1h_tokens: attempt.usage.cacheWrite1h,
      cache_read_tokens: attempt.usage.cacheRead, output_tokens: attempt.usage.output,
      ...(attempt.cacheStorageTokens ? { cache_storage_tokens: attempt.cacheStorageTokens } : {}) })),
  };
  try {
    await deps.rpc('worker_record_provider_usage', {
      p_account_id: deps.accountID, p_operation_id: operationID, p_provider: provider,
      p_provider_event_id: outcome.messageID ?? `operation:${operationID}`,
      p_model: outcome.model ?? outcome.attempts[0].model ?? 'unknown', p_units: units, p_microusd: microusd,
    });
  } catch { deps.log({ event: 'chat_usage_record_failed', operation_id: operationID }); }
}
