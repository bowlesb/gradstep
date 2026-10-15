// Popularity for the Feed's shared pool (docs/architecture/PERSONALIZED_FEED.md, "Popularity"):
// Hugging Face Papers upvotes, read from its public daily lists by the pool refresh while it holds
// the refresh claim (migration 046) — never per reader request. At most six listing days a run (the
// database plans which), at most two pages each, a second apart, anonymous; a 429 ends the run and
// the days are tried again on a later refresh. Papers not listed keep no value: unknown, not zero.
// Pure helpers (Deno + Node); the feed-refresh function supplies the transport and database.
import { readBounded } from './feed-pool.ts';

export const POPULARITY_SOURCE = 'huggingface';
export const HF_MAX_BYTES = 4 * 1024 * 1024;
/** Hugging Face's page size limit for daily papers. */
export const HF_PAGE = 100;
export const HF_PAGES_PER_DAY = 2;
export const HF_SPACING_MS = 1_000;
export const MAX_UPVOTES = 1_000_000;
const USER_AGENT = 'Gradstep/0.1 (research paper reader; +https://gradstep.ai; mailto:hello@gradstep.ai)';
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const ARXIV = /^\d{4}\.\d{4,5}$/;

/** One listing day's page: `https://huggingface.co/api/daily_papers?date=…&limit=100&p=…`. */
export function dailyPapersURL(day: string, page: number): string {
  if (!DAY.test(day) || Number.isNaN(Date.parse(`${day}T00:00:00Z`)) || !Number.isInteger(page) || page < 0 || page >= HF_PAGES_PER_DAY) {
    throw new Error('invalid_signal_request');
  }
  return `https://huggingface.co/api/daily_papers?date=${day}&limit=${HF_PAGE}&p=${page}`;
}

export interface Upvote { source_id: string; upvotes: number }

/** The arXiv papers and upvote counts in one daily-papers response. Anything else in an entry is
 * ignored; entries without a modern arXiv identifier or a whole, bounded count are skipped. `entries`
 * is how many the page held (a full page means there may be another). */
export function parseDailyPapers(bytes: Uint8Array): { items: Upvote[]; entries: number; skipped: number } {
  let value: unknown;
  try { value = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Error('invalid_signals'); }
  if (!Array.isArray(value) || value.length > HF_PAGE * 2) throw new Error('invalid_signals');
  const best = new Map<string, number>();
  let skipped = 0;
  for (const entry of value) {
    const paper = (entry as { paper?: { id?: unknown; upvotes?: unknown } } | null)?.paper;
    const id = paper?.id, upvotes = paper?.upvotes;
    if (typeof id !== 'string' || !ARXIV.test(id) || typeof upvotes !== 'number' || !Number.isInteger(upvotes) || upvotes < 0 || upvotes > MAX_UPVOTES) {
      skipped++; continue;
    }
    best.set(id, Math.max(best.get(id) ?? 0, upvotes));
  }
  return { items: [...best].map(([source_id, upvotes]) => ({ source_id, upvotes })), entries: value.length, skipped };
}

export interface SignalPlan { source: string; enabled: boolean; days: string[] }
export type SignalDayStatus = 'ok' | 'failed' | 'busy';
export interface SignalOutcome { status: 'ok' | 'busy' | 'failed' | 'off'; days: number; requests: number; matched: number; code?: string }

export interface SignalDeps {
  /** `worker_feed_signal_plan` under the refresh claim. */
  plan(claimID: string): Promise<SignalPlan>;
  /** `worker_feed_signals_record` under the refresh claim. */
  record(claimID: string, day: string, status: SignalDayStatus, items: Upvote[]): Promise<{ matched: number }>;
  fetch: typeof fetch;
  sleep(ms: number): Promise<void>;
}

/** One popularity pass under the refresh claim. Never throws. A throttled source (429) stops the pass
 * and records the day as busy; two failed days stop it too (the source is probably down). */
export async function runSignals(deps: SignalDeps, claimID: string): Promise<SignalOutcome> {
  let requests = 0, matched = 0, done = 0, failures = 0;
  let plan: SignalPlan;
  try { plan = await deps.plan(claimID); } catch { return { status: 'failed', days: 0, requests, matched, code: 'plan_failed' }; }
  if (!plan.enabled) return { status: 'off', days: 0, requests, matched };
  const days = (Array.isArray(plan.days) ? plan.days : []).filter(day => typeof day === 'string' && DAY.test(day)).slice(0, 6);
  const record = async (day: string, status: SignalDayStatus, items: Upvote[]) => {
    try { matched += (await deps.record(claimID, day, status, items)).matched; return true; } catch { return false; }
  };
  for (const day of days) {
    const items = new Map<string, number>();
    let outcome: SignalDayStatus = 'ok';
    for (let page = 0; page < HF_PAGES_PER_DAY; page++) {
      if (requests > 0) await deps.sleep(HF_SPACING_MS);
      requests++;
      try {
        const response = await deps.fetch(dailyPapersURL(day, page), { redirect: 'error', signal: AbortSignal.timeout(15_000),
          headers: { accept: 'application/json', 'user-agent': USER_AGENT } });
        if (response.status === 429) { void response.body?.cancel().catch(() => {}); outcome = 'busy'; break; }
        if (!response.ok) { void response.body?.cancel().catch(() => {}); outcome = 'failed'; break; }
        const parsed = parseDailyPapers(await readBounded(response, HF_MAX_BYTES));
        for (const item of parsed.items) items.set(item.source_id, Math.max(items.get(item.source_id) ?? 0, item.upvotes));
        if (parsed.entries < HF_PAGE) break;
      } catch {
        outcome = 'failed'; break;
      }
    }
    if (outcome === 'busy') {
      await record(day, 'busy', []);
      return { status: 'busy', days: done, requests, matched };
    }
    if (outcome === 'failed') {
      await record(day, 'failed', []);
      if (++failures >= 2) return { status: 'failed', days: done, requests, matched, code: 'source_failed' };
      continue;
    }
    if (!await record(day, 'ok', [...items].map(([source_id, upvotes]) => ({ source_id, upvotes })))) {
      return { status: 'failed', days: done, requests, matched, code: 'record_failed' };
    }
    done++;
  }
  return { status: failures ? 'failed' : 'ok', days: done, requests, matched, ...(failures ? { code: 'source_failed' } : {}) };
}
