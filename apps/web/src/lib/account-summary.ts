// The account menu's AI credits and Subscription plan (native Settings › AI credits): the same reads the apps make
// (`v1_credit_balance`, `v1_store_summary`), shown as they are. The browser sells nothing: credits and plans are bought in
// the Gradstep app on iPhone, iPad or Mac, so nothing here grants, spends or estimates credits.
import { rpc } from './backend';

export interface CreditBalance { available: number; reserved: number; unlimited_testing?: boolean }
/** `undefined` while unknown (loading or a failed read: the menu shows a dash, never a made-up value). */
export interface AccountSummary { balance: CreditBalance | undefined; plan: string | null | undefined }

/** A balance as the server returns it, or undefined when it isn't one. */
export function parseBalance(value: unknown): CreditBalance | undefined {
  const b = value as Partial<CreditBalance> | null;
  return b && Number.isSafeInteger(b.available) && b.available! >= 0 && Number.isSafeInteger(b.reserved) && b.reserved! >= 0
    && (b.unlimited_testing === undefined || typeof b.unlimited_testing === 'boolean')
    ? { available: b.available!, reserved: b.reserved!, ...(b.unlimited_testing === undefined ? {} : { unlimited_testing: b.unlimited_testing }) } : undefined;
}

/** The active subscription's plan (`standard`, `pro`), null with none, undefined when the answer isn't a summary. */
export function parsePlan(value: unknown): string | null | undefined {
  const v = value as { plan?: unknown } | null;
  if (!v || typeof v !== 'object' || !('plan' in v)) return undefined;
  if (v.plan === null) return null;
  return typeof v.plan === 'string' && /^[a-z][a-z0-9_-]{0,31}$/.test(v.plan) ? v.plan : undefined;
}

/** As native names it (StoreSummary.planName); "None" without one, a dash while unknown. */
export function planLabel(plan: string | null | undefined): string {
  if (plan === undefined) return '—';
  if (plan === null) return 'None';
  return plan === 'pro' ? 'Pro' : plan === 'standard' ? 'Standard' : plan.charAt(0).toUpperCase() + plan.slice(1);
}

export function creditsLabel(balance: CreditBalance | undefined, locale?: string): string {
  return balance?.unlimited_testing ? 'Unlimited testing' : balance ? balance.available.toLocaleString(locale) : '—';
}

/** Both reads at once; one failing leaves only its own value unknown. */
export async function loadAccountSummary(account: string, signal?: AbortSignal): Promise<AccountSummary> {
  const [balance, store] = await Promise.allSettled([
    rpc<unknown>('v1_credit_balance', {}, { account, signal }), rpc<unknown>('v1_store_summary', {}, { account, signal })]);
  return { balance: balance.status === 'fulfilled' ? parseBalance(balance.value) : undefined,
    plan: store.status === 'fulfilled' ? parsePlan(store.value) : undefined };
}

/** The ⓘ beside each row (native CreditsStoreView's wording). */
export const CREDITS_INFO = 'Credits pay for AI answers, web searches, podcast episodes and paper recommendations; each uses credits based on what it asks for and how long the answer is. Recommendations use 1 credit per request that adds papers. Credits are bought in the Gradstep app on iPhone, iPad or Mac.';
export const PLAN_INFO = 'A plan adds credits each month. Plans are chosen and managed in the Gradstep app on iPhone, iPad or Mac.';
