// The account menu's AI credits and Subscription plan (native Settings › AI credits): the same reads the apps make
// (`v1_credit_balance`, `v1_store_summary`), shown as they are. The browser sells nothing: credits and plans are bought in
// the Gradstep app on iPhone, iPad or Mac, so nothing here grants, spends or estimates credits. Every place that sends a
// reader to buy says so with WHERE_TO_BUY, which also tells someone without an Apple device that the web can't sell yet.
// Free AI (migration 0150; docs/PRICING_HOW_IT_WORKS.md): the balance says whether this month's free credits can pay now,
// and why not; the wording matches the apps' (plans and packs are bought there).
import { rpc } from './backend';

/** Why free AI can't pay right now: this month's credits spent, today's share, the account's monthly cost share, everyone's
 * free AI for the month (the pool), or the owner paused it. */
export type FreeReason = 'used' | 'daily' | 'account' | 'pool' | 'paused';
export interface FreeAI { monthly: number; available: number; usable: boolean; reason: FreeReason | null; resumes_at: string | null; daily: number }
export interface CreditBalance { available: number; reserved: number; unlimited_testing?: boolean; free?: FreeAI | null }
/** `undefined` while unknown (loading or a failed read: the menu shows a dash, never a made-up value). */
export interface AccountSummary { balance: CreditBalance | undefined; plan: string | null | undefined; periodMonths?: number | null }

const REASONS: readonly string[] = ['used', 'daily', 'account', 'pool', 'paused'];
const count = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;

/** The balance's `free` object, null (not on the free tier), or undefined when it isn't one. */
export function parseFree(value: unknown): FreeAI | null | undefined {
  if (value === null) return null;
  const f = value as Partial<FreeAI> | undefined;
  if (!f || typeof f !== 'object' || !count(f.monthly) || !count(f.available) || !count(f.daily) || typeof f.usable !== 'boolean') return undefined;
  if (!(f.reason === null || (typeof f.reason === 'string' && REASONS.includes(f.reason)))) return undefined;
  if (!(f.resumes_at === null || (typeof f.resumes_at === 'string' && !Number.isNaN(Date.parse(f.resumes_at))))) return undefined;
  return { monthly: f.monthly, available: f.available, usable: f.usable, reason: f.reason as FreeReason | null, resumes_at: f.resumes_at, daily: f.daily };
}

/** A balance as the server returns it, or undefined when it isn't one. */
export function parseBalance(value: unknown): CreditBalance | undefined {
  const b = value as (Partial<CreditBalance> & { free?: unknown }) | null;
  if (!(b && Number.isSafeInteger(b.available) && b.available! >= 0 && Number.isSafeInteger(b.reserved) && b.reserved! >= 0
    && (b.unlimited_testing === undefined || typeof b.unlimited_testing === 'boolean'))) return undefined;
  // Older servers send no `free`; a `free` that isn't one makes the whole answer unknown rather than half-read.
  const free = 'free' in b ? parseFree(b.free) : undefined;
  if ('free' in b && free === undefined) return undefined;
  return { available: b.available!, reserved: b.reserved!, ...(b.unlimited_testing === undefined ? {} : { unlimited_testing: b.unlimited_testing }),
    ...(free === undefined ? {} : { free }) };
}

/** The active subscription's plan (`standard`, `pro`), null with none, undefined when the answer isn't a summary. */
export function parsePlan(value: unknown): string | null | undefined {
  const v = value as { plan?: unknown } | null;
  if (!v || typeof v !== 'object' || !('plan' in v)) return undefined;
  if (v.plan === null) return null;
  return typeof v.plan === 'string' && /^[a-z][a-z0-9_-]{0,31}$/.test(v.plan) ? v.plan : undefined;
}
/** Monthly (1) or yearly (12) billing of the active plan, as the summary says (migration 0150); null when it doesn't. */
export function parsePeriod(value: unknown): number | null {
  const p = (value as { period_months?: unknown } | null)?.period_months;
  return p === 1 || p === 12 ? p : null;
}

/** As native names it (StoreSummary.planName): Plus and Pro, "(yearly)" for an annual plan; "Free" without one, a dash
 * while unknown. */
export function planLabel(plan: string | null | undefined, periodMonths?: number | null): string {
  if (plan === undefined) return '—';
  if (plan === null) return 'Free';
  const name = plan === 'pro' ? 'Pro' : plan === 'standard' ? 'Plus' : plan.charAt(0).toUpperCase() + plan.slice(1);
  return periodMonths === 12 ? `${name} (yearly)` : name;
}

export function creditsLabel(balance: CreditBalance | undefined, locale?: string): string {
  return balance?.unlimited_testing ? 'Unlimited testing' : balance ? balance.available.toLocaleString(locale) : '—';
}

/** "November 1": the UTC day free AI comes back. */
export function resumeDate(resumesAt: string | null): string {
  if (!resumesAt || Number.isNaN(Date.parse(resumesAt))) return 'next month';
  return new Date(resumesAt).toLocaleDateString('en-US', { month: 'long', day: 'numeric', timeZone: 'UTC' });
}

/** The account menu's "Free AI this month" value. */
export function freeAILabel(free: FreeAI): string {
  if (free.usable) return `${free.available.toLocaleString('en-US')} of ${free.monthly.toLocaleString('en-US')} left`;
  if (free.reason === 'daily') return 'Back tomorrow';
  if (free.reason === 'paused') return 'Paused';
  return `Used up · back ${resumeDate(free.resumes_at)}`;
}

/** Where credits come from, for readers with and without an Apple device (owner, 2026-10-23). */
export const WHERE_TO_BUY = 'Credits can’t be bought on the web yet. If you have an iPhone, iPad or Mac, credits added in the Gradstep app work here right away.';
/** What a reader is told when free AI can't pay (the apps' words; purchases happen in the apps). */
export function freeAIMessage(reason: FreeReason | null, resumesAt: string | null, premiumModel = false): string | null {
  if (premiumModel && reason === null) return `Free AI covers the fast models (Gemini Flash, DeepSeek and Haiku); choose one in AI options. Sonnet and Opus need credits. ${WHERE_TO_BUY}`;
  switch (reason) {
    case 'pool': return `This month’s free AI has all been used. It comes back on ${resumeDate(resumesAt)}. Reading is unaffected. ${WHERE_TO_BUY}`;
    case 'used': case 'account': return `You’ve used this month’s free AI. It comes back on ${resumeDate(resumesAt)}. Reading is unaffected. ${WHERE_TO_BUY}`;
    case 'daily': return `You’ve used today’s free AI. More tomorrow. ${WHERE_TO_BUY}`;
    case 'paused': return `Free AI is paused for now. Reading is unaffected. ${WHERE_TO_BUY}`;
    default: return null;
  }
}

const PREMIUM = /sonnet|opus/i;
/** For an `insufficient_credits` refusal: the free-AI explanation when the latest balance gives one (free AI can't pay now,
 * or it can but the chosen model is a premium one), else null and the usual words stay. */
export function freeAIRefusal(balance: CreditBalance | null | undefined, model?: string | null): string | null {
  const free = balance?.free;
  if (!free) return null;
  if (!free.usable) return freeAIMessage(free.reason, free.resumes_at);
  return model && PREMIUM.test(model) ? freeAIMessage(null, null, true) : null;
}
/** A refusal's text: the free-AI explanation for insufficient_credits when there is one, otherwise `fallback`'s. */
export function creditRefusalText(code: string, fallback: (code: string) => string, balance: CreditBalance | null | undefined, model?: string | null): string {
  return (code === 'insufficient_credits' && freeAIRefusal(balance, model)) || fallback(code);
}

/** Both reads at once; one failing leaves only its own value unknown. */
export async function loadAccountSummary(account: string, signal?: AbortSignal): Promise<AccountSummary> {
  const [balance, store] = await Promise.allSettled([
    rpc<unknown>('v1_credit_balance', {}, { account, signal }), rpc<unknown>('v1_store_summary', {}, { account, signal })]);
  return { balance: balance.status === 'fulfilled' ? parseBalance(balance.value) : undefined,
    plan: store.status === 'fulfilled' ? parsePlan(store.value) : undefined,
    ...(store.status === 'fulfilled' && parsePeriod(store.value) ? { periodMonths: parsePeriod(store.value) } : {}) };
}

/** The ⓘ beside each row (native CreditsStoreView's wording). */
export const CREDITS_INFO = 'Credits pay for AI answers, web searches, podcast episodes and paper recommendations; each uses credits based on what it asks for and how long the answer is. Recommendations use 1 credit per request that adds papers.';
export const PLAN_INFO = 'Reading papers is always free. AI uses credits. Free: 50 credits a month (about 15 answers) with the fast models, while this month’s free AI lasts. Plus: 600 credits a month (about 200 answers), every model. Pro: 2,000 credits a month (about 650 answers), every model. Credit packs: 300 or 700 credits that never expire. Plan credits renew each month and don’t carry over. Plans and packs are bought in the Gradstep app on iPhone, iPad or Mac; they can’t be bought on the web yet.';
export const FREE_AI_INFO = 'Free accounts get 50 credits a month for the fast models while this month’s free AI lasts. Web search, podcasts and Sonnet or Opus need credits.';
