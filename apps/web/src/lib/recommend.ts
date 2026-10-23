// AI recommendations in the browser (docs/architecture/AI_RECOMMENDATIONS.md; server: supabase/functions/recommend).
// One request adds 1, 3 or 5 papers like a paper (or like the catalog being viewed) and streams each as it is added,
// with a one-line reason. The browser then puts each added paper in the catalog the reader was viewing (catalogs are
// encrypted on this device), as after any server Add. Remove and Undo use the library's ordinary removal paths.
// The run belongs to the page, not to its dialog: closing the dialog never stops it.
import { BackendError, functionStream } from './backend';
import { distinctiveKeyword, effectiveTags } from './paper';
import type { ClientEntry, LibraryPaper } from './device-pdf';
import { WHERE_TO_BUY } from './account-summary';

export type RecommendCount = 1 | 3 | 5;
export const RECOMMEND_COUNTS: readonly RecommendCount[] = [1, 3, 5];
export const RECOMMEND_CREDITS = 1;
const MAX_STREAM_BYTES = 256 * 1024;
const SOURCE = /^(\d{4}\.\d{4,5}|[a-z][a-z0-9.-]*\/\d{7}|openalex:W\d{1,12})$/;
const ARXIV = /^(\d{4}\.\d{4,5}|[a-z][a-z0-9.-]*\/\d{7})$/;
/** The server's keyword rule (recommend.ts KEYWORD): words, digits and a little punctuation, 2–60 characters. */
const KEYWORD = /^[\p{L}\p{N}][\p{L}\p{N} '’.+&/()-]{0,59}$/u;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---------- Seeds ----------

/** A paper the server can recommend from: in the library with its details (an arXiv or open-access paper), never a
 * PDF that stays on this device (its title never leaves it). */
export function eligibleSeed(entry: ClientEntry): entry is LibraryPaper {
  if (entry.kind === 'local_pdf' || !entry.visible || typeof entry.source_id !== 'string' || !SOURCE.test(entry.source_id)) return false;
  const title = (entry as { metadata?: { title?: unknown } }).metadata?.title;
  return typeof title === 'string' && title.trim().length > 0;
}

/** The keywords the reader sees on the paper (as Find similar papers searches them), specific ones only, as the server
 * accepts them: at most `limit`. */
export function recommendKeywords(paper: LibraryPaper, limit: number): string[] {
  const out: string[] = [];
  for (const raw of effectiveTags(paper)) {
    const k = raw.normalize('NFKC').replace(/\s+/g, ' ').trim();
    if (k.length < 2 || k.length > 60 || !KEYWORD.test(k) || !distinctiveKeyword(k) || out.some(x => x.toLowerCase() === k.toLowerCase())) continue;
    out.push(k);
    if (out.length >= limit) break;
  }
  return out;
}

const addedAt = (e: ClientEntry) => (e as { added_at?: number }).added_at ?? (e as { created_seq?: number }).created_seq ?? 0;
/** A catalog's seeds: its eight most recently added papers with server details. */
export function catalogSeeds(entries: readonly ClientEntry[], inCatalog: (entry: ClientEntry) => boolean, limit = 8): LibraryPaper[] {
  const seen = new Set<string>();
  return entries.filter((e): e is LibraryPaper => eligibleSeed(e) && inCatalog(e)).sort((a, b) => addedAt(b) - addedAt(a))
    .filter(e => { const s = e.source_id!; if (seen.has(s)) return false; seen.add(s); return true; }).slice(0, limit);
}

export interface RecommendBody { operation_id: string; count: RecommendCount; scope: 'paper' | 'catalog'; seeds: { source_id: string; keywords: string[] }[] }
export function recommendBody(scope: 'paper' | 'catalog', seeds: readonly LibraryPaper[], count: RecommendCount, operationID = crypto.randomUUID()): RecommendBody {
  const perSeed = scope === 'paper' ? 6 : 3;
  return { operation_id: operationID, count, scope, seeds: seeds.slice(0, scope === 'paper' ? 1 : 8).map(s => ({ source_id: s.source_id!, keywords: recommendKeywords(s, perSeed) })) };
}

// ---------- Events ----------

export type PickStatus = 'added' | 'present' | 'failed';
export interface RecommendedPaper { source_id: string; revision: number | null; title: string; authors: string[]; year: number | null; reason: string; status: PickStatus; import_id: string | null }
export type RecommendEvent =
  | { type: 'status'; phase: 'searching' }
  | { type: 'status'; phase: 'choosing'; candidates: number }
  | { type: 'paper'; ordinal: number; paper: RecommendedPaper }
  | { type: 'done'; added: number; requested: number; credits: number; charged: boolean; reason?: 'none_related' | 'not_added' }
  | { type: 'error'; code: string; retry_after?: number };

const text = (v: unknown, max: number) => typeof v === 'string' && v.length <= max && !/[\u0000-\u001f\u007f]/.test(v) ? v : null;
const count = (v: unknown, max = 1000) => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= max ? v as number : null;

/** One event, bounded and checked; anything unknown or malformed is dropped. */
export function decodeEvent(value: unknown): RecommendEvent | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  switch (v.type) {
    case 'status':
      if (v.phase === 'searching') return { type: 'status', phase: 'searching' };
      if (v.phase === 'choosing') return { type: 'status', phase: 'choosing', candidates: count(v.candidates) ?? 0 };
      return null;
    case 'paper': {
      const p = v.paper as Record<string, unknown> | null;
      if (!p || typeof p !== 'object') return null;
      const source = text(p.source_id, 128), title = text(p.title, 300), reason = text(p.reason, 200);
      const status = p.status === 'added' || p.status === 'present' || p.status === 'failed' ? p.status : null;
      if (!source || !SOURCE.test(source) || !title?.trim() || reason === null || !status) return null;
      const authors = Array.isArray(p.authors) ? p.authors.map(a => text(a, 120)).filter((a): a is string => !!a).slice(0, 3) : [];
      const importID = typeof p.import_id === 'string' && UUID.test(p.import_id) ? p.import_id.toLowerCase() : null;
      const year = count(p.year, 3000);
      return { type: 'paper', ordinal: count(v.ordinal, 5) ?? 0, paper: { source_id: source, revision: count(p.revision, 10_000), title: title.trim(), authors,
        year: year && year > 1900 ? year : null, reason: reason.trim(), status, import_id: status === 'added' ? importID : null } };
    }
    case 'done': {
      const added = count(v.added, 5), requested = count(v.requested, 5), credits = count(v.credits, 100);
      if (added === null || requested === null || credits === null || typeof v.charged !== 'boolean') return null;
      const reason = v.reason === 'none_related' || v.reason === 'not_added' ? v.reason : undefined;
      return { type: 'done', added, requested, credits, charged: v.charged, ...(reason ? { reason } : {}) };
    }
    case 'error': {
      const code = typeof v.code === 'string' && /^[a-z_]{1,64}$/.test(v.code) ? v.code : 'service_unavailable';
      const wait = typeof v.retry_after === 'number' && Number.isFinite(v.retry_after) && v.retry_after > 0 ? Math.min(v.retry_after, 600) : undefined;
      return { type: 'error', code, ...(wait ? { retry_after: wait } : {}) };
    }
    default: return null;
  }
}

/** `text/event-stream` bytes → events: only `data:` lines carry JSON; comments (`: ping`) and other fields are ignored. */
export class RecommendStreamParser {
  private decoder = new TextDecoder(); private buffer = '';
  consume(chunk: Uint8Array): RecommendEvent[] { this.buffer += this.decoder.decode(chunk, { stream: true }); return this.lines(false); }
  finish(): RecommendEvent[] { this.buffer += this.decoder.decode(); return this.lines(true); }
  private lines(final: boolean): RecommendEvent[] {
    const out: RecommendEvent[] = [];
    const parts = this.buffer.split('\n');
    this.buffer = final ? '' : parts.pop() ?? '';
    if (this.buffer.length > 65_536) throw new BackendError('invalid_response');
    for (const raw of parts) {
      const line = raw.replace(/\r$/, '');
      if (!line.startsWith('data:')) continue;
      let value: unknown;
      try { value = JSON.parse(line.slice(5).trim()); } catch { continue; }
      const event = decodeEvent(value);
      if (event) out.push(event);
    }
    return out;
  }
}

/** The request's events from functions/v1/recommend. The token must outlive the request: the server adds the papers as
 * the reader. Non-200 replies (a refused body, a signed-out session) throw their code. */
export async function* streamRecommend(account: string, body: RecommendBody, signal: AbortSignal): AsyncGenerator<RecommendEvent> {
  const parser = new RecommendStreamParser();
  for await (const chunk of functionStream('recommend', body, { account, signal, maximum: MAX_STREAM_BYTES, minimumValidity: 300 })) {
    for (const event of parser.consume(chunk)) yield event;
  }
  for (const event of parser.finish()) yield event;
}

// ---------- The reader's words ----------

export function errorMessage(code: string): string {
  switch (code) {
    case 'daily_limit': return 'You’ve asked for recommendations 20 times today. Try again tomorrow.';
    case 'insufficient_credits': return `You’re out of AI credits. ${WHERE_TO_BUY}`;
    case 'seed_unavailable': return 'This paper’s details aren’t ready yet. Try again in a minute.';
    case 'rate_limited': case 'request_rate_limit': return 'Too many requests. Try again in a minute.';
    case 'unavailable': return 'Recommendations are switched off for now.';
    case 'connection': return 'Couldn’t reach Gradstep. Check your connection. If papers were added, they’re in your library.';
    default: return 'Recommendations aren’t available right now. Nothing was charged.';
  }
}
/** Whether Try again (a new request) can help. */
export const retryable = (code: string) => !['daily_limit', 'insufficient_credits', 'unavailable'].includes(code);
export const papersLabel = (n: number) => `${n} ${n === 1 ? 'paper' : 'papers'}`;
export const creditLabel = (credits: number) => credits ? `${credits} ${credits === 1 ? 'credit' : 'credits'}` : 'No credit used';

// ---------- One request ----------

export type Removal = 'none' | 'removing' | 'removed' | 'failed';
export interface RunRow { paper: RecommendedPaper; removal: Removal }
export interface RunState {
  operationID: string; scope: 'paper' | 'catalog'; count: RecommendCount;
  /** The source paper's title, or the catalog's name. */
  subject: string; catalogName: string | null;
  phase: 'searching' | 'choosing' | 'done' | 'failed';
  candidates: number | null;
  rows: RunRow[];
  outcome: { added: number; credits: number; charged: boolean; reason?: 'none_related' | 'not_added' } | null;
  error: { code: string; message: string; retryable: boolean } | null;
  /** Some added papers couldn't be put in the catalog being viewed (they are still added). */
  catalogIssue: boolean;
  undone: boolean;
}

export interface RunDeps {
  stream(body: RecommendBody, signal: AbortSignal): AsyncIterable<RecommendEvent>;
  /** Put an added paper in the catalog the reader was viewing (null: no catalogs here). */
  assign(sourceID: string): Promise<void>;
  refresh(): Promise<void>;
  /** Remove one added paper from the library (cancel its import, or remove its item); throws when it couldn't. */
  remove(paper: RecommendedPaper): Promise<void>;
  sleep?(ms: number): Promise<void>;
}

/** One request and what the reader did with its papers. Subscribers are told after every change. */
export class RecommendationRun {
  private listeners = new Set<() => void>();
  private controller = new AbortController();
  private body: RecommendBody;
  state: RunState;
  constructor(private deps: RunDeps, body: RecommendBody, subject: string, catalogName: string | null) {
    this.body = body;
    this.state = { operationID: body.operation_id, scope: body.scope, count: body.count, subject, catalogName, phase: 'searching', candidates: null,
      rows: [], outcome: null, error: null, catalogIssue: false, undone: false };
  }
  subscribe(listener: () => void) { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  private set(change: Partial<RunState>) { this.state = { ...this.state, ...change }; for (const l of this.listeners) l(); }
  /** Stops listening (the page or account is going away). The server still finishes the request. */
  dispose() { this.controller.abort(); this.listeners.clear(); }
  get running() { return this.state.phase === 'searching' || this.state.phase === 'choosing'; }

  async start(): Promise<void> {
    let waited = false;
    for (;;) {
      const again = await this.once();
      if (again === null || waited) return;
      waited = true;
      await (this.deps.sleep ?? (ms => new Promise(r => setTimeout(r, ms))))(again * 1000);
      if (this.controller.signal.aborted) return;
    }
  }
  /** One stream; returns seconds to wait before re-sending the same request (in_progress), else null. */
  private async once(): Promise<number | null> {
    let assigning: Promise<void> = Promise.resolve();
    try {
      for await (const event of this.deps.stream(this.body, this.controller.signal)) {
        switch (event.type) {
          case 'status': this.set(event.phase === 'choosing' ? { phase: 'choosing', candidates: event.candidates } : { phase: 'searching' }); break;
          case 'paper':
            if (this.state.rows.some(r => r.paper.source_id === event.paper.source_id)) break;
            this.set({ rows: [...this.state.rows, { paper: event.paper, removal: 'none' }] });
            if (event.paper.status === 'added') {
              const source = event.paper.source_id;
              assigning = assigning.then(async () => {
                try { await this.deps.assign(source); } catch { this.set({ catalogIssue: true }); }
                await this.deps.refresh().catch(() => {});
              });
            }
            break;
          case 'done':
            await assigning;
            this.set({ phase: 'done', outcome: { added: event.added, credits: event.credits, charged: event.charged, ...(event.reason ? { reason: event.reason } : {}) } });
            return null;
          case 'error':
            await assigning;
            if (event.code === 'in_progress') return event.retry_after ?? 5;
            this.fail(event.code);
            return null;
        }
      }
      await assigning;
      // The stream ended without an outcome: papers already shown stay added.
      if (this.running) this.fail('connection');
    } catch (error) {
      await assigning;
      if (this.controller.signal.aborted) return null;
      this.fail(error instanceof BackendError ? (error.code === 'invalid_request' ? 'service_unavailable' : error.code) : 'connection');
    }
    return null;
  }
  private fail(code: string) {
    this.set({ phase: 'failed', error: { code, message: errorMessage(code), retryable: retryable(code) } });
  }

  /** Try again: a new request (a new operation id), from the start. */
  retry(): Promise<void> {
    if (this.running) return Promise.resolve();
    this.body = { ...this.body, operation_id: crypto.randomUUID() };
    this.set({ operationID: this.body.operation_id, phase: 'searching', candidates: null, rows: [], outcome: null, error: null, catalogIssue: false, undone: false });
    return this.start();
  }

  async remove(sourceID: string): Promise<void> {
    const row = this.state.rows.find(r => r.paper.source_id === sourceID);
    if (!row || row.paper.status !== 'added' || row.removal === 'removing' || row.removal === 'removed') return;
    const mark = (removal: Removal) => this.set({ rows: this.state.rows.map(r => r.paper.source_id === sourceID ? { ...r, removal } : r) });
    mark('removing');
    try { await this.deps.remove(row.paper); mark('removed'); } catch { mark('failed'); }
  }
  /** Removes every added paper still here (one at a time: each is its own library change). */
  async undo(): Promise<void> {
    for (const row of this.state.rows) if (row.paper.status === 'added' && row.removal !== 'removed') await this.remove(row.paper.source_id);
    if (this.state.rows.every(r => r.paper.status !== 'added' || r.removal === 'removed')) this.set({ undone: true });
  }
  get addedCount() { return this.state.rows.filter(r => r.paper.status === 'added' && r.removal !== 'removed').length; }
}

/** The status line while a request runs. */
export function statusText(state: RunState): string {
  const subject = state.scope === 'paper' ? `papers like “${state.subject}”` : `papers for ${state.subject}`;
  if (state.phase === 'searching') return `Finding ${subject}…`;
  if (state.phase === 'choosing') return state.rows.length
    ? `Adding ${state.rows.length} of ${state.count}…`
    : `Choosing the best ${state.count} of ${state.candidates ?? 0}…`;
  return '';
}
/** The footer once it is done. */
export function footerText(state: RunState): string | null {
  const o = state.outcome;
  if (state.phase !== 'done' || !o) return null;
  if (o.added === 0) return o.reason === 'not_added' ? 'Couldn’t add these papers. Nothing was charged.' : 'No closely related papers found. Nothing was charged.';
  if (state.undone) return `Removed the ${papersLabel(o.added)} again · ${creditLabel(o.credits)}`;
  return `Added ${papersLabel(o.added)}${state.catalogName ? ` to ${state.catalogName}` : ''} · ${creditLabel(o.credits)}`;
}
export const isArxivSource = (source: string) => ARXIV.test(source);
