// Your AI usage (owner, 2026-10-22: "a table of my recent AI token spend for all the different activities … rows ordered
// by time, each row being an activity, and the exact cost"). The reader's own metered operations from `v1_ai_usage`
// (migration 0144), newest first, in credits — the product's unit: Gradstep shows no credit-to-dollar conversion
// (docs/architecture/OPERATIONS_AND_BILLING.md "Your AI usage"). The words here match the apps' AIUsage.swift exactly
// (tests/fixtures/ai-usage.json).
//
// Paper titles never come from the server. When this browser starts an answer it remembers, in this browser only, which
// conversation kind and paper the operation was for (`rememberProvenance`); the usage screen looks the title up in the
// library here. An operation started elsewhere shows its activity without a paper.
import { rpc } from './backend';
import type { ChatRequest } from './chat';

export const USAGE_ACTIVITIES = ['chat', 'figure_explainer', 'equation_explainer', 'study', 'related_papers', 'why_it_matters', 'add_paper',
  'diagram_repair', 'podcast', 'recommendations', 'tags', 'paper_lookup', 'web_search', 'paper_ocr', 'diagram', 'other'] as const;
export type UsageActivity = typeof USAGE_ACTIVITIES[number];
export const USAGE_OUTCOMES = ['completed', 'stopped', 'failed', 'in_progress', 'checking', 'free', 'not_charged'] as const;
export type UsageOutcome = typeof USAGE_OUTCOMES[number];
export const USAGE_PARTS = ['answer', 'title', 'suggestions', 'study_map', 'web_search', 'podcast_script', 'podcast_review', 'podcast_audio', 'tags', 'ocr'] as const;
export type UsagePartName = typeof USAGE_PARTS[number];
/** The periods offered (UTC days, today included). */
export const USAGE_PERIODS = [7, 30, 90, 365] as const;
export const USAGE_PAGE = 25;

export interface UsageTokens { input_tokens: number; cached_tokens: number; cache_write_tokens: number; output_tokens: number; searches: number; audio_ms: number }
export interface UsagePart extends UsageTokens { part: UsagePartName; model: string; calls: number; estimated: boolean; pending: boolean }
export interface UsageOperation extends UsageTokens {
  id: string; created_at: string; settled_at: string | null; kind: string; activity: UsageActivity; action: string | null; ending: string | null;
  outcome: UsageOutcome; paid_by: 'you' | 'gradstep'; credits: number | null; credits_held: number; model: string | null; calls: number;
  estimated: boolean; pending: boolean; parts: UsagePart[];
}
export interface UsageTotals extends UsageTokens { operations: number; credits: number; credits_held: number }
export interface UsageActivityCount { activity: UsageActivity; operations: number; credits: number }
export interface UsageCursor { created_at: string; id: string }
export interface UsagePage {
  days: number; activity: UsageActivity | null; operations: UsageOperation[];
  /** The whole window (with the activity filter): first page only. */
  totals: UsageTotals | null;
  /** Every activity in the window (no filter), for the filter chips: first page only. */
  activities: UsageActivityCount[] | null;
  next: UsageCursor | null;
}

const count = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;
const text = (v: unknown, max = 128): v is string => typeof v === 'string' && v.length > 0 && v.length <= max;
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
const time = (v: unknown): v is string => typeof v === 'string' && v.length <= 64 && !Number.isNaN(Date.parse(v));
const TOKEN_KEYS = ['input_tokens', 'cached_tokens', 'cache_write_tokens', 'output_tokens', 'searches', 'audio_ms'] as const;
const tokens = (o: Record<string, unknown>) => TOKEN_KEYS.every(k => count(o[k]));
const pick = (o: Record<string, unknown>): UsageTokens => Object.fromEntries(TOKEN_KEYS.map(k => [k, o[k]])) as unknown as UsageTokens;
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** A newer server's activity or part this browser doesn't know yet is shown as Other / Answer, not refused. */
const activityOf = (v: unknown): UsageActivity | undefined => !text(v, 64) ? undefined : (USAGE_ACTIVITIES as readonly string[]).includes(v) ? v as UsageActivity : 'other';
const partOf = (v: unknown): UsagePartName | undefined => !text(v, 64) ? undefined : (USAGE_PARTS as readonly string[]).includes(v) ? v as UsagePartName : 'answer';

function parsePart(v: unknown): UsagePart | undefined {
  const part = object(v) ? partOf(v.part) : undefined;
  if (!object(v) || !part || !text(v.model) || !count(v.calls) || !tokens(v)
    || typeof v.estimated !== 'boolean' || typeof v.pending !== 'boolean') return undefined;
  return { part, model: v.model, calls: v.calls, ...pick(v), estimated: v.estimated, pending: v.pending };
}

function parseOperation(v: unknown): UsageOperation | undefined {
  const activity = object(v) ? activityOf(v.activity) : undefined;
  if (!object(v) || !uuid(v.id) || !time(v.created_at) || !(v.settled_at === null || time(v.settled_at)) || !text(v.kind, 32)
    || !activity || !(v.action === null || text(v.action, 64))
    || !(v.ending === null || text(v.ending, 64)) || !(USAGE_OUTCOMES as readonly unknown[]).includes(v.outcome)
    || (v.paid_by !== 'you' && v.paid_by !== 'gradstep') || !(v.credits === null || count(v.credits)) || !count(v.credits_held)
    || !(v.model === null || text(v.model)) || !count(v.calls) || !tokens(v) || typeof v.estimated !== 'boolean' || typeof v.pending !== 'boolean'
    || !Array.isArray(v.parts) || v.parts.length > 32) return undefined;
  const parts = v.parts.map(parsePart);
  if (parts.some(p => !p)) return undefined;
  return { id: v.id, created_at: v.created_at, settled_at: v.settled_at as string | null, kind: v.kind, activity,
    action: v.action as string | null, ending: v.ending as string | null, outcome: v.outcome as UsageOutcome, paid_by: v.paid_by,
    credits: v.credits as number | null, credits_held: v.credits_held, model: v.model as string | null, calls: v.calls, ...pick(v),
    estimated: v.estimated, pending: v.pending, parts: parts as UsagePart[] };
}

/** A page as `v1_ai_usage` returns it, or undefined when the reply isn't one (never a partly trusted page). */
export function parseUsagePage(value: unknown): UsagePage | undefined {
  if (!object(value) || !count(value.days) || !(value.activity === null || (USAGE_ACTIVITIES as readonly unknown[]).includes(value.activity))
    || !Array.isArray(value.operations) || value.operations.length > 50) return undefined;
  const operations = value.operations.map(parseOperation);
  if (operations.some(o => !o)) return undefined;
  let totals: UsageTotals | null = null;
  if (value.totals !== null && value.totals !== undefined) {
    const t = value.totals;
    if (!object(t) || !count(t.operations) || !count(t.credits) || !count(t.credits_held) || !tokens(t)) return undefined;
    totals = { operations: t.operations, credits: t.credits, credits_held: t.credits_held, ...pick(t) };
  }
  let activities: UsageActivityCount[] | null = null;
  if (value.activities !== null && value.activities !== undefined) {
    if (!Array.isArray(value.activities) || value.activities.length > USAGE_ACTIVITIES.length) return undefined;
    activities = [];
    for (const a of value.activities) {
      const activity = object(a) ? activityOf(a.activity) : undefined;
      if (!object(a) || !activity || !count(a.operations) || !count(a.credits)) return undefined;
      const same = activities.find(x => x.activity === activity);
      if (same) { same.operations += a.operations; same.credits += a.credits; } else activities.push({ activity, operations: a.operations, credits: a.credits });
    }
  }
  let next: UsageCursor | null = null;
  if (value.next !== null && value.next !== undefined) {
    if (!object(value.next) || !time(value.next.created_at) || !uuid(value.next.id)) return undefined;
    next = { created_at: value.next.created_at, id: value.next.id };
  }
  return { days: value.days, activity: value.activity as UsageActivity | null, operations: operations as UsageOperation[], totals, activities, next };
}

/** One page of the reader's own usage. */
export async function loadUsage(account: string, query: { days: number; activity: UsageActivity | null; before: UsageCursor | null },
  signal?: AbortSignal): Promise<UsagePage> {
  const value = await rpc<unknown>('v1_ai_usage', { p_days: query.days, p_activity: query.activity, p_before_created_at: query.before?.created_at ?? null,
    p_before_id: query.before?.id ?? null, p_limit: USAGE_PAGE }, { account, signal, maximum: 512 * 1024 });
  const page = parseUsagePage(value);
  if (!page) throw new Error('invalid_usage');
  return page;
}

// ---------- Where an operation came from (this browser only) ----------

/** What this browser knew when it started an answer: the conversation kind and the paper, never its title. */
export interface UsageProvenance { kind: 'paper' | 'general' | 'explain'; membership?: string; document?: string }

/** The kind of conversation a chat request was: a question started from a passage (Explain in Chat and the other
 * selection questions) is "explain"; the selection actions with their own activity keep it. */
export function provenanceFor(request: Pick<ChatRequest, 'documentID' | 'localContext' | 'selection' | 'action'>): UsageProvenance {
  const paper = !!(request.documentID || request.localContext);
  const kind = !paper ? 'general' : request.selection && !request.action ? 'explain' : 'paper';
  return { kind, ...(request.localContext ? { membership: request.localContext.membership_id } : {}),
    ...(request.documentID ? { document: request.documentID } : {}) };
}

const PROVENANCE_LIMIT = 2_000;
const provenanceKey = (account: string) => `gradstep.usage-provenance.v1.${account}`;

/** The remembered operations of one account in this browser (empty when storage is unavailable). */
export function recallProvenance(account: string, storage: Pick<Storage, 'getItem'> | null = safeStorage()): Map<string, UsageProvenance> {
  try {
    const raw = storage?.getItem(provenanceKey(account));
    const list = raw ? JSON.parse(raw) as unknown : [];
    const out = new Map<string, UsageProvenance>();
    if (!Array.isArray(list)) return out;
    for (const entry of list) {
      if (!Array.isArray(entry) || !uuid(entry[0]) || !['paper', 'general', 'explain'].includes(entry[1])) continue;
      const p: UsageProvenance = { kind: entry[1] };
      if (text(entry[2], 64)) p.membership = entry[2];
      if (text(entry[3], 64)) p.document = entry[3];
      out.set(entry[0], p);
    }
    return out;
  } catch { return new Map(); }
}

/** Remembers one operation, keeping the newest PROVENANCE_LIMIT. Storage failures are ignored: the row then shows its
 * activity without a paper. */
export function rememberProvenance(account: string, operationID: string, p: UsageProvenance,
  storage: Pick<Storage, 'getItem' | 'setItem'> | null = safeStorage()): void {
  try {
    if (!storage || !uuid(operationID)) return;
    const raw = storage.getItem(provenanceKey(account));
    const list = (raw ? JSON.parse(raw) as unknown : []) as unknown[];
    const kept = (Array.isArray(list) ? list : []).filter(e => Array.isArray(e) && e[0] !== operationID);
    kept.push([operationID, p.kind, p.membership ?? null, p.document ?? null]);
    storage.setItem(provenanceKey(account), JSON.stringify(kept.slice(-PROVENANCE_LIMIT)));
  } catch { /* private window, full or blocked storage */ }
}

/** Forgets one account's remembered operations (sign-out keeps them; account deletion and a cleared browser don't). */
export function forgetProvenance(account: string, storage: Pick<Storage, 'removeItem'> | null = safeStorage()): void {
  try { storage?.removeItem(provenanceKey(account)); } catch { /* ignored */ }
}

function safeStorage(): Storage | null {
  try { return typeof localStorage === 'undefined' ? null : localStorage; } catch { return null; }
}

// ---------- Words (the same in AIUsage.swift; tests/fixtures/ai-usage.json) ----------

const ACTIVITY_LABELS: Record<UsageActivity, string> = {
  chat: 'Chat', figure_explainer: 'Figure explainer', equation_explainer: 'Equation explainer', study: 'Study', related_papers: 'Related papers',
  why_it_matters: 'Why it matters', add_paper: 'Add paper', diagram_repair: 'Diagram repair', podcast: 'Podcast', recommendations: 'Recommendations',
  tags: 'Tags', paper_lookup: 'Paper lookup', web_search: 'Web search', paper_ocr: 'PDF conversion', diagram: 'Diagram', other: 'Other',
};
/** The filter chip's name for an activity (chat is one chip: paper, general and passage questions alike). */
export function activityName(activity: UsageActivity): string { return ACTIVITY_LABELS[activity]; }

/** The row's activity: chat is named for what this browser knew when it started it. */
export function activityLabel(activity: UsageActivity, provenance?: UsageProvenance | null): string {
  if (activity !== 'chat' || !provenance) return ACTIVITY_LABELS[activity];
  return provenance.kind === 'explain' ? 'Explain in Chat' : provenance.kind === 'paper' ? 'Paper chat' : 'General chat';
}

const PART_LABELS: Record<UsagePartName, string> = {
  answer: 'Answer', title: 'Chat title', suggestions: 'Suggested questions', study_map: 'Study map', web_search: 'Web search',
  podcast_script: 'Script', podcast_review: 'Script check', podcast_audio: 'Audio', tags: 'Tags', ocr: 'PDF conversion',
};
export function partLabel(part: UsagePartName): string { return PART_LABELS[part]; }

/** A short word beside the credits when the row isn't an ordinary finished charge. */
/** Whether a row's tokens are what the provider reported for a finished request (Swift `AIUsageOutcome.reportsTokens`).
 * Before migration 0160 a request that didn't finish, wasn't charged or hasn't been settled carried what was set aside for
 * it, not what was used; since 0160 the server counts only provider-reported tokens. */
export function reportsTokens(outcome: UsageOutcome): boolean {
  return !(outcome === 'failed' || outcome === 'not_charged' || outcome === 'in_progress' || outcome === 'checking');
}
/** Said where the parts' tokens would be, when they aren't shown. */
export function unreportedTokens(outcome: UsageOutcome): string | null {
  if (outcome === 'failed' || outcome === 'not_charged') return 'Its tokens aren’t shown: what was set aside for it isn’t what was used.';
  if (outcome === 'in_progress' || outcome === 'checking') return 'Its tokens are shown once it’s settled.';
  return null;
}

export function outcomeLabel(outcome: UsageOutcome): string | null {
  switch (outcome) {
    case 'completed': return null;
    case 'stopped': return 'Stopped';
    case 'failed': return 'Didn’t finish · not charged';
    case 'in_progress': return 'In progress';
    case 'checking': return 'Being checked';
    // The cost already says Free.
    case 'free': return null;
    case 'not_charged': return 'Not charged';
  }
}

/** Whole numbers with thousands separators, the same on every device (the fixture is exact). */
export function grouped(n: number): string { return Math.trunc(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ','); }

/** The row's cost, exactly: credits charged, the hold while it runs, or Free. */
export function creditsText(op: Pick<UsageOperation, 'outcome' | 'credits' | 'credits_held'>): string {
  if (op.outcome === 'in_progress' || op.outcome === 'checking') return `Up to ${grouped(op.credits_held)}`;
  if (op.outcome === 'free') return 'Free';
  const n = op.credits ?? 0;
  return `${grouped(n)} ${n === 1 ? 'credit' : 'credits'}`;
}

/** 950 → "950", 1,500 → "1.5k", 20,000 → "20k", 1,250,000 → "1.3M". */
export function compact(n: number): string {
  if (n < 1_000) return String(n);
  // 999,999 is "1M", not "1000k".
  const [value, unit] = n < 999_500 ? [n / 1_000, 'k'] : [n / 1_000_000, 'M'];
  const rounded = value < 10 ? Math.round(value * 10) / 10 : Math.round(value);
  return `${rounded}${unit}`;
}

/** Tokens a row or part used, short: "1.6k in · 20k cached · 750 out · 1 search · 5 min audio"; "≈" when some of its
 * calls have no provider count (left out of the figures since migration 0160); "—" when nothing has been reported yet.
 * Cache writes count as input (they are input tokens kept for the next question). */
export function tokensText(t: UsageTokens & { estimated: boolean }, exact = false): string {
  const number = exact ? grouped : compact;
  const pieces: string[] = [];
  const input = t.input_tokens + t.cache_write_tokens;
  if (input || t.output_tokens || t.cached_tokens) {
    pieces.push(`${number(input)} in`);
    if (t.cached_tokens) pieces.push(`${number(t.cached_tokens)} cached`);
    pieces.push(`${number(t.output_tokens)} out`);
  }
  if (t.searches) pieces.push(`${grouped(t.searches)} ${t.searches === 1 ? 'search' : 'searches'}`);
  if (t.audio_ms) pieces.push(audioText(t.audio_ms));
  if (!pieces.length) return '—';
  return (t.estimated ? '≈ ' : '') + pieces.join(' · ');
}

export function audioText(ms: number): string {
  const seconds = Math.round(ms / 1000);
  return seconds < 60 ? `${seconds} s audio` : `${Math.round(seconds / 60)} min audio`;
}

const MODEL_WORDS: Record<string, string> = {
  claude: 'Claude', sonnet: 'Sonnet', haiku: 'Haiku', opus: 'Opus', gemini: 'Gemini', flash: 'Flash', pro: 'Pro', lite: 'Lite',
  deepseek: 'DeepSeek', tts: 'TTS', gpt: 'GPT', mini: 'mini', chat: 'Chat',
};
/** A model as readers know it: "anthropic/claude-sonnet-5.5" → "Claude Sonnet 5.5", "deepseek/deepseek-v4.1-flash-1017" →
 * "DeepSeek V4.1 Flash", "search-basic" → "Tavily search". */
export function modelLabel(model: string | null): string {
  if (!model) return '—';
  if (/^search-/.test(model)) return 'Tavily search';
  const words = (model.split('/').pop() ?? model).split(/[-_]/).filter(w => w && !/^\d{4}$/.test(w));
  const out: string[] = [];
  for (const w of words) {
    // A version split on dashes ("5-5") joins back with a dot.
    if (/^\d+$/.test(w) && out.length && /^\d+(\.\d+)*$/.test(out[out.length - 1])) { out[out.length - 1] += `.${w}`; continue; }
    out.push(MODEL_WORDS[w.toLowerCase()] ?? (/^v\d/i.test(w) ? w.toUpperCase() : /^\d/.test(w) ? w : w.charAt(0).toUpperCase() + w.slice(1)));
  }
  return out.join(' ') || model;
}

/** The period's name: "Last 7 days", "Last 12 months". */
export function periodLabel(days: number): string { return days === 365 ? 'Last 12 months' : `Last ${days} days`; }

/** Totals for the period: "63 credits · 8 requests · 1.6M tokens". */
export function totalsText(t: UsageTotals): string {
  const tokensUsed = t.input_tokens + t.cache_write_tokens + t.cached_tokens + t.output_tokens;
  const pieces = [`${grouped(t.credits)} ${t.credits === 1 ? 'credit' : 'credits'}`, `${grouped(t.operations)} ${t.operations === 1 ? 'request' : 'requests'}`];
  if (tokensUsed) pieces.push(`${compact(tokensUsed)} tokens`);
  if (t.credits_held) pieces.push(`${grouped(t.credits_held)} held`);
  return pieces.join(' · ');
}

// ---------- Credits by activity (owner, build 82: "a pie chart summarizing the cost types and their cost") ----------

/** One ring segment and legend row: a named activity, or Other (everything small or past the fourth). `slot` is the
 * colour's place in the chart palette (0–3 by size; Other is the neutral): neighbours on the ring are always adjacent
 * slots, the order the palette is validated for (docs/DESIGN.md "Credits by activity"). */
export interface UsageSlice { activity: UsageActivity | null; label: string; credits: number; percent: string; slot: number | 'other'; members: string[] }
/** At most four named segments, each at least 4% of the period's credits; the rest is one Other. */
export const SLICE_NAMED = 4, SLICE_MIN_SHARE = 0.04;

/** The ring for the All view, or [] when there is nothing to compare (no credits, or one activity holds them all). */
export function usageSlices(activities: readonly UsageActivityCount[]): UsageSlice[] {
  const charged = activities.filter(a => a.credits > 0)
    .sort((a, b) => b.credits - a.credits || activityName(a.activity).localeCompare(activityName(b.activity)));
  const total = charged.reduce((sum, a) => sum + a.credits, 0);
  if (!total || charged.length < 2) return [];
  const named = charged.filter((a, i) => i < SLICE_NAMED && a.credits >= total * SLICE_MIN_SHARE && a.activity !== 'other');
  const rest = charged.filter(a => !named.includes(a));
  const slices: UsageSlice[] = named.map((a, i) => ({ activity: a.activity, label: activityName(a.activity), credits: a.credits,
    percent: percentText(a.credits, total), slot: i, members: [] }));
  if (rest.length) {
    const credits = rest.reduce((sum, a) => sum + a.credits, 0);
    slices.push({ activity: null, label: 'Other', credits, percent: percentText(credits, total), slot: 'other',
      members: rest.filter(a => a.activity !== 'other').map(a => activityName(a.activity)) });
  }
  return slices.length < 2 ? [] : slices;
}

/** A share in whole percent, half up ("<1%" for a sliver, ">99%" beside one), integer arithmetic so every device
 * writes the same. */
export function percentText(part: number, total: number): string {
  const n = Math.floor((part * 200 + total) / (total * 2));
  return n < 1 ? '<1%' : n >= 100 && part < total ? '>99%' : `${n}%`;
}

/** The chart in words (its accessible name): "Credits by activity: Podcast 55 credits, 85%; Chat 7 credits, 11%; …". */
export function slicesSummary(slices: readonly UsageSlice[]): string {
  return 'Credits by activity: ' + slices.map(s => `${s.label} ${grouped(s.credits)} ${s.credits === 1 ? 'credit' : 'credits'}, ${s.percent}`
    + (s.members.length ? ` (${s.members.join(', ')})` : '')).join('; ');
}

/** The ⓘ beside the totals: what affects cost (the same words in the apps). */
export const USAGE_INFO = 'What a request costs depends on how much the model reads and writes. A paper chat sends the paper with each question; '
  + 'questions soon after reuse a cached copy, which costs much less. Longer conversations, longer answers, higher effort and larger models cost '
  + 'more; web searches, the chat’s title and its suggested questions are small extra calls inside the same request. Credits are settled from the '
  + 'tokens the provider reports: a stopped answer is charged for the part written, and one that fails isn’t charged. Paper titles come from '
  + 'this device’s library and never leave it.';
