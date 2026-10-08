// Paid AI chat (functions/v1/chat, docs/architecture/CHAT.md) — a port of ScienceReaderCore/ChatStream.swift and the
// app's ChatGeneration rules: the bounded request built from the decrypted branch, the incremental SSE parser, failure
// wording, and what an outcome keeps (complete, interrupted, or nothing). The request carries plaintext only to the
// chat function; the answer comes back here and is sealed into encrypted history.
import { BackendError, functionStream } from './backend';
import type { Role, TurnStatus } from './events';

export const CONSENT_VERSION = 'cloud-ai-v2';
export const MAX_TURNS = 60, MAX_MESSAGE_BYTES = 200_000, MAX_SELECTION_SCALARS = 4_000, MAX_STREAM_BYTES = 2 * 1024 * 1024;
export type ChatAction = 'ingest' | 'related' | 'relevance' | 'diagram_fix';
export interface ChatTurn { role: Role; text: string }
export interface ChatRequest { operationID: string; documentID: string | null; turns: ChatTurn[]; selection: string | null; action: ChatAction | null }

const bytes = (s: string) => new TextEncoder().encode(s).length;
const scalars = (s: string, limit: number) => { const all = [...s]; return all.length > limit ? all.slice(0, limit).join('') : s; };

/** The newest turns that fit the server bounds, starting and ending with a user turn (ChatGenerationRequest.make). */
export function makeRequest(operationID: string, documentID: string | null, transcript: ChatTurn[], selection: string | null, action: ChatAction | null = null): ChatRequest {
  const usable = transcript.filter(t => t.text.trim());
  const last = usable.at(-1);
  if (!last || last.role !== 'user') throw new BackendError('invalid_request');
  if (bytes(last.text) > MAX_MESSAGE_BYTES) throw new BackendError('invalid_request');
  const kept: ChatTurn[] = [];
  let total = 0;
  for (const turn of [...usable].reverse()) {
    const size = bytes(turn.text);
    if (kept.length >= MAX_TURNS || total + size > MAX_MESSAGE_BYTES) break;
    kept.push(turn); total += size;
  }
  kept.reverse();
  while (kept.length && kept[0].role !== 'user') kept.shift();
  const quote = selection === null ? null : scalars(selection, MAX_SELECTION_SCALARS);
  const kept_quote = quote && quote.trim() ? quote : null;
  return { operationID, documentID, turns: kept, selection: kept_quote, action: kept_quote ? action : null };
}

export function requestBody(r: ChatRequest): Record<string, unknown> {
  const body: Record<string, unknown> = { operation_id: r.operationID, consent_version: CONSENT_VERSION, mode: r.documentID ? 'paper' : 'general',
    messages: r.turns.map(t => ({ role: t.role, text: t.text })) };
  if (r.documentID) body.document_id = r.documentID;
  if (r.selection) body.selection = { quote: r.selection };
  if (r.action) body.action = r.action;
  if (r.action === 'ingest') body.capabilities = ['web_import']; // Add paper may add an open-access web paper
  return body;
}

// ---------- Stream events ----------

export type ProgressKind = 'searching' | 'reading' | 'finding_paper' | 'adding_paper';
export interface Progress { kind: ProgressKind; query?: string }
export type StreamEvent =
  | { type: 'delta'; text: string } | { type: 'diagram'; title: string; source: string } | { type: 'status'; progress: Progress }
  | { type: 'done'; stopReason: string; credits: number } | { type: 'error'; code: string };

export function progressText(p: Progress): string {
  switch (p.kind) {
    case 'searching': return p.query ? `Searching the web for “${p.query}”` : 'Searching the web…';
    case 'reading': return 'Reading results…';
    case 'finding_paper': return 'Finding the paper…';
    case 'adding_paper': return 'Adding to your library…';
  }
}

/** Incremental, bounded `text/event-stream` parser (ChatSSEParser): unknown events and comments are ignored; malformed known ones are fatal. */
export class SSEParser {
  static readonly maximumLine = 256 * 1024;
  private line: number[] = [];
  private afterCR = false;
  private name = '';
  private data: number[] = [];
  private hasData = false;

  consume(chunk: Uint8Array): StreamEvent[] {
    const out: StreamEvent[] = [];
    for (const byte of chunk) {
      if (this.afterCR) { this.afterCR = false; if (byte === 0x0a) continue; }
      if (byte === 0x0a || byte === 0x0d) {
        this.afterCR = byte === 0x0d;
        const event = this.endLine();
        if (event) out.push(event);
        continue;
      }
      if (this.line.length >= SSEParser.maximumLine) throw new BackendError('stream_malformed');
      this.line.push(byte);
    }
    return out;
  }

  private endLine(): StreamEvent | null {
    const line = this.line;
    this.line = [];
    if (!line.length) return this.dispatch();
    if (line[0] === 0x3a) return null;
    const colon = line.indexOf(0x3a);
    const field = new TextDecoder().decode(new Uint8Array(colon < 0 ? line : line.slice(0, colon)));
    let value = colon < 0 ? [] : line.slice(colon + 1);
    if (value[0] === 0x20) value = value.slice(1);
    if (field === 'event') {
      try { this.name = new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(value)); } catch { throw new BackendError('stream_malformed'); }
    } else if (field === 'data') {
      if (this.hasData) this.data.push(0x0a);
      for (const byte of value) this.data.push(byte); this.hasData = true;
      if (this.data.length > SSEParser.maximumLine) throw new BackendError('stream_malformed');
    }
    return null;
  }

  private dispatch(): StreamEvent | null {
    const name = this.name, data = this.data, hasData = this.hasData;
    this.name = ''; this.data = []; this.hasData = false;
    if (!hasData) return null;
    let v: Record<string, unknown> | null = null;
    try { v = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(data))) as Record<string, unknown>; } catch { v = null; }
    const bad = (): never => { throw new BackendError('stream_malformed'); };
    switch (name) {
      case 'delta': return typeof v?.text === 'string' ? { type: 'delta', text: v.text } : bad();
      case 'diagram': {
        const title = typeof v?.title === 'string' ? v.title.trim() : '', source = typeof v?.source === 'string' ? v.source : '';
        return title && [...title].length <= 200 && source.trim() && bytes(source) <= 16_000 ? { type: 'diagram', title, source } : bad();
      }
      case 'status': {
        // Informational: unknown kinds or malformed statuses are ignored, never fatal.
        const kind = v?.kind;
        if (kind !== 'searching' && kind !== 'reading' && kind !== 'finding_paper' && kind !== 'adding_paper') return null;
        const query = kind === 'searching' && typeof v?.query === 'string' ? v.query.replace(/[\u0000-\u001f\u007f]/g, ' ').split(/\s+/).join(' ').trim().slice(0, 200) : '';
        return { type: 'status', progress: query ? { kind, query } : { kind } };
      }
      case 'done': return typeof v?.stop_reason === 'string' && Number.isSafeInteger(v.credits) && (v.credits as number) >= 0
        ? { type: 'done', stopReason: v.stop_reason, credits: v.credits as number } : bad();
      case 'error': return typeof v?.code === 'string' && v.code.length <= 64 ? { type: 'error', code: v.code } : bad();
      default: return null;
    }
  }
}

/** The answer's events. The token is refreshed to at least five minutes of validity first (Ingest acts as the user afterwards). */
export async function* streamAnswer(account: string, request: ChatRequest, signal: AbortSignal): AsyncGenerator<StreamEvent> {
  const parser = new SSEParser();
  for await (const chunk of functionStream('chat', requestBody(request), { account, signal, maximum: MAX_STREAM_BYTES, minimumValidity: 300 })) {
    for (const event of parser.consume(chunk)) yield event;
  }
}

// ---------- Outcomes ----------

export type Outcome = { kind: 'completed'; stopReason: string } | { kind: 'failed'; code: string } | { kind: 'cancelled' };
/** What to keep: complete text, an explicitly interrupted partial, or nothing (a refusal's partial is discarded). */
export function resolution(outcome: Outcome, text: string): { status: TurnStatus | null; issue: string | null } {
  const empty = !text.trim();
  switch (outcome.kind) {
    case 'completed':
      if (empty) return { status: null, issue: 'provider_unavailable' };
      return { status: outcome.stopReason === 'end_turn' || outcome.stopReason === 'stop_sequence' ? 'complete' : 'interrupted', issue: null };
    case 'failed':
      if (outcome.code === 'refused') return { status: null, issue: 'refused' };
      return { status: empty ? null : 'interrupted', issue: outcome.code };
    case 'cancelled': return { status: empty ? null : 'interrupted', issue: null };
  }
}

export function failureText(code: string): string {
  switch (code) {
    case 'question_ready':
    case 'consent_declined': return 'Your question is saved. No answer was requested.';
    case 'consent_unsaved': return 'Your choice couldn’t be saved in this browser. Try again.';
    case 'branch_required': return 'Choose a complete conversation branch before continuing.';
    case 'conversation_deleted': return 'This conversation was deleted. Start a new chat to continue.';
    case 'answer_too_large': return 'The answer reached this browser’s size limit. The partial answer is saved.';
    case 'storage': return 'The answer couldn’t be saved to your encrypted history. Try again.';
    case 'local_save': return 'This edit couldn’t be saved on this device. Keep this tab open and copy your text, or try again after freeing browser storage.';
    case 'question_unsaved': return 'Your question couldn’t be saved, so no answer was requested. Try again.';
    case 'storage_retired': return 'No answer was requested: Gradstep was updated in another tab. Your question is saved; continue in the updated tab.';
    case 'insufficient_credits': return 'Not enough credits for this answer. Your question is saved. Credits can be added in Gradstep on iPhone, iPad or Mac.';
    case 'platform_budget_exhausted': return 'AI answers are paused right now. Your papers and saved chats still work.';
    case 'rate_limited': return 'Too many requests right now. Try again in a moment.';
    case 'document_unavailable': return 'This paper isn’t ready for questions yet. Try again after it finishes processing.';
    case 'provider_unavailable': return 'The AI service couldn’t finish this answer. Try again.';
    case 'refused': return 'This request can’t be answered. Try rephrasing your question.';
    case 'invalid_request': return 'This conversation couldn’t be sent. Try starting a new chat.';
    case 'operation_replayed': return 'This answer was already requested. Try again to request a new one.';
    case 'sign_in_required':
    case 'authentication_required': return 'Sign in again to get answers.';
    case 'transport': return 'The connection was interrupted before the answer finished.';
    default: return 'The answer couldn’t be completed. Try again.';
  }
}
export const retryable = (code: string) => !['invalid_request', 'refused', 'storage_retired'].includes(code);

/** Bounded by the encrypted event limit (UTF-8 bytes) on a code point boundary. */
export function boundedText(text: string, maximum = 200_000): string {
  if (bytes(text) <= maximum) return text;
  let out = '', size = 0;
  for (const ch of text) { const n = bytes(ch); if (size + n > maximum) break; out += ch; size += n; }
  return out;
}

// ---------- Selection actions (ChatTitle.swift) ----------

export type SelectionAction = 'define' | 'relevance' | 'similar' | 'ingest';
export const SELECTION_ACTIONS: { action: SelectionAction; title: string }[] = [
  { action: 'define', title: 'Explain' }, { action: 'relevance', title: 'Why it matters' }, { action: 'similar', title: 'Related' }, { action: 'ingest', title: 'Add paper' },
];
const PREFIX: Record<SelectionAction, string> = {
  define: 'Explain in plain terms, including any symbols: ', relevance: 'Why does this matter to the paper\'s method and results? ',
  similar: 'Find related papers, earlier and recent, with links: ', ingest: 'Find and add the paper referenced in this passage: ',
};
const EQUATION_PREFIX = 'Explain this equation: ';
const EQUATION_SUFFIX = '\n\nBriefly cover the background needed to read it, its overall message, what each symbol means, and how its notation compares with common ML conventions.';
export const actionFor: Record<SelectionAction, ChatAction | null> = { define: null, relevance: 'relevance', similar: 'related', ingest: 'ingest' };

export function selectionPrompt(action: SelectionAction, quote: string): string {
  if (action === 'define' && isSingleEquation(quote)) return EQUATION_PREFIX + quote + EQUATION_SUFFIX;
  return PREFIX[action] + quote;
}

export type Segment = { kind: 'text'; text: string } | { kind: 'math'; body: string; display: boolean; closed: boolean };
/** Prose and formulas (`\(…\)`, `\[…\]`, `$$…$$`, `$…$` when closed, `\begin{…}…\end{…}`), as ChatTitle.segments splits them. */
export function segments(text: string): Segment[] {
  const out: Segment[] = [];
  let prose = '', i = 0;
  const emit = (s: Segment) => { if (prose) { out.push({ kind: 'text', text: prose }); prose = ''; } out.push(s); };
  while (i < text.length) {
    const two = text.slice(i, i + 2);
    if (two === '\\[' || two === '\\(') {
      const closer = two === '\\[' ? '\\]' : '\\)', end = text.indexOf(closer, i + 2);
      if (end >= 0) { emit({ kind: 'math', body: text.slice(i + 2, end), display: two === '\\[', closed: true }); i = end + 2; }
      else { emit({ kind: 'math', body: text.slice(i + 2), display: two === '\\[', closed: false }); i = text.length; }
    } else if (text.startsWith('\\begin{', i)) {
      const nameEnd = text.indexOf('}', i + 7), name = nameEnd > 0 ? text.slice(i + 7, nameEnd) : '';
      const end = nameEnd > 0 ? text.indexOf(`\\end{${name}}`, nameEnd) : -1;
      if (end >= 0) { const after = end + 6 + name.length; emit({ kind: 'math', body: text.slice(i, after), display: true, closed: true }); i = after; }
      else { emit({ kind: 'math', body: text.slice(i), display: true, closed: false }); i = text.length; }
    } else if (two === '$$') {
      const end = text.indexOf('$$', i + 2);
      if (end >= 0) { emit({ kind: 'math', body: text.slice(i + 2, end), display: true, closed: true }); i = end + 2; }
      else { emit({ kind: 'math', body: text.slice(i + 2), display: true, closed: false }); i = text.length; }
    } else if (text[i] === '$' && i + 1 < text.length && !/\s/.test(text[i + 1])) {
      let end = -1;
      for (let j = i + 1; j < text.length; j++) {
        if (text[j] === '$' && !/\s/.test(text[j - 1]) && text[j - 1] !== '\\' && (j + 1 === text.length || !/[0-9]/.test(text[j + 1]))) { end = j; break; }
      }
      if (end > 0) { emit({ kind: 'math', body: text.slice(i + 1, end), display: false, closed: true }); i = end + 1; }
      else { prose += text[i]; i++; }
    } else { prose += text[i]; i++; }
  }
  if (prose) out.push({ kind: 'text', text: prose });
  return out;
}

export function isSingleEquation(quote: string): boolean {
  let formula: { body: string; display: boolean } | null = null;
  for (const s of segments(quote)) {
    if (s.kind === 'text') { if (!/^[\s.,;:]*$/.test(s.text)) return false; continue; }
    if (!s.closed || formula || !s.body.trim()) return false;
    formula = s;
  }
  if (!formula) return false;
  return formula.display || /[=<>≤≥≈]|\\(?:leq?|geq?|approx|propto|equiv|neq|ne|simeq|cong)(?![A-Za-z])/.test(formula.body);
}

/** A saved title (the first question): a known prompt becomes "Label · passage" (display only; nothing saved changes). */
export function chatTitle(saved: string): { label: string | null; text: string; truncated: boolean } {
  const truncated = [...saved].length >= 100;
  const text = saved.trim();
  const prompts: [string, string][] = [...SELECTION_ACTIONS.map(a => [PREFIX[a.action], a.title] as [string, string]), [EQUATION_PREFIX, 'Explain'],
    ['Explain this in plain terms, in the context of this paper (for notation or an equation, say what each symbol means): ', 'Explain'],
    ['Define this in the context of the paper: ', 'Define'], ['What role does this passage play in the paper\'s argument? Connect it to the method and the results: ', 'Why it matters'],
    ['Explain why this passage matters to the paper: ', 'Why it matters'], ['Find papers related to this passage — earlier work it builds on and recent follow-ups — with links: ', 'Related'],
    ['Find related research and explain the connections: ', 'Related']];
  for (const [prefix, label] of prompts) {
    if (text.startsWith(prefix)) {
      let rest = text.slice(prefix.length);
      const cut = rest.indexOf('\n\n');
      if (cut >= 0 && EQUATION_SUFFIX.startsWith(rest.slice(cut))) rest = rest.slice(0, cut);
      return { label, text: rest.trim(), truncated: truncated && cut < 0 };
    }
    if (text === prefix.trim() || (truncated && text && prefix.startsWith(text))) return { label, text: '', truncated: false };
  }
  return { label: null, text, truncated };
}
