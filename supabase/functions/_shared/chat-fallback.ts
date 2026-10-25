// An answer's fallback model (2026-10-25; docs/architecture/CHAT.md "A fallback when the chosen model fails before
// writing"). Owner, TestFlight 92: "Speed and reliability seem to be not great for ai provider calls." On staging, Gemini
// 3.8 Flash on its pinned Google Vertex US endpoint answered 8 of 12 calls in the 24 hours before (429s, a stall, a broken
// stream) while Claude Haiku 5.5 on the same endpoint answered 37 of 37 in a week; OpenRouter's own endpoint inventory
// showed the Flash endpoint up 80 % of the last day, Haiku's 100 %.
//
// When the chosen model fails before anything of its answer reached us (refused busy or unavailable, a stall, a stream
// broken before its first output), the answer is asked once of its fallback: one answer, labelled with the model that
// wrote it (`done.model`; every client already shows "· by Claude Haiku 5.5" when it differs from the chosen profile's).
// The fallback is a second admitted attempt in the same operation: it is sent only when the database finds room for its
// whole ceiling inside the hold the reader accepted (otherwise the reader gets the first failure, as before), the reader
// pays only for the attempt that answered, and an unfinished attempt is never the reader's.
//
// Privacy: a pair is listed only when the fallback goes to the same processors under the same terms as the primary — the
// same pinned endpoint (Google Vertex, US), zero data retention required, data collection denied, no OpenRouter provider
// fallback, no response cache — and under the same consent (v5 and later name Google through OpenRouter and Anthropic).
// Deno and Node compatible.
import { GEMINI_ENDPOINT, GEMINI_MODEL } from './gemini-pricing.ts';
import { ROUTER_CLAUDE_ENDPOINT } from './openrouter-claude-pricing.ts';
import type { ModelRequest } from './model-request.ts';
import type { ProviderOutcome } from './inference.ts';

export const FALLBACK_HAIKU = 'anthropic/claude-haiku-5.5';
/** Primary model → its one fallback. Claude Sonnet and Opus, DeepSeek and Haiku itself have none: none failed this way on
 * staging (Claude 52/52 in the week; DeepSeek on DeepInfra 34/35, the other one the reader leaving), and every other pair
 * changes a processor, a location or the answer's quality class, which is the owner's decision. */
export const FALLBACK_MODELS: Readonly<Record<string, string>> = Object.freeze({ [GEMINI_MODEL]: FALLBACK_HAIKU });
// A pair is only valid on one pinned endpoint (openrouter-chat.ts sends each model to its own): keep them the same.
if (GEMINI_ENDPOINT !== ROUTER_CLAUDE_ENDPOINT) throw new Error('fallback pair must share its pinned endpoint');

/** First-data deadlines (ms from sending) when a fallback can still answer: a silent primary is given up on sooner, so the
 * reader waits for the fallback instead of for the 60 s limit (openrouter-chat.ts FIRST_DATA_DEADLINE_MS, which still
 * applies when there is no fallback, and to the fallback itself). Measured first output on the pinned Flash route
 * (2026-10-22–25): explainers at low or minimal effort 1.5–12 s, a few slow ones that still finished 18.9 s (a figure's
 * summary in the 2026-10-25 probe) and 24 s; chat at medium 4.3–17.3 s (25 s at most for a figure question), slow but
 * finished 33.8 and 36 s. Haiku's whole calls took 1.3 s (median) and 2.7 s (p90) in the week. The views (figure,
 * equation, the paper's explainer) give up after 25 s, answers (which say "Still waiting for the model…" from 12 s)
 * after 30 s: past every ordinary start, and the fallback still finishes well inside the 60 s a silent model got before. */
export const FALLBACK_FIRST_DATA_MS = Object.freeze({ view: 25_000, answer: 30_000 });

/** Whether a failed attempt may be asked again of a fallback: the provider's failure (not ours, not the reader's Stop),
 * before any of the model's output reached us, and not one another model can't fix or mustn't be asked: our key or the
 * account's balance (401, 402), the request itself (400, 413, 422), a refusal to answer it (403, moderation), or a request
 * our own server never sent. */
export function fallbackEligible(outcome: ProviderOutcome): boolean {
  if (outcome.status !== 'failed' || outcome.cause || outcome.noOutput !== true) return false;
  if (outcome.failure !== 'provider_error' && outcome.failure !== 'provider_rejected') return false;
  const status = outcome.httpStatus;
  if (typeof status === 'number' && [400, 401, 402, 403, 413, 422].includes(status)) return false;
  // Never dispatched (our attribution or admission could not be recorded): nothing reached the provider.
  if (outcome.exact && !outcome.messageID && typeof status !== 'number' && !outcome.stalled) return false;
  return true;
}

/** The same request for the fallback model: the same instructions, paper (with its cache breakpoint), turns, figures,
 * tools and output allowance. Effort is the request's (Gemini's `minimal`, the paper explainer's, is Claude's `low`); a
 * request that turned reasoning off keeps it off. */
export function fallbackParams(params: ModelRequest, model: string): ModelRequest {
  const effort = params.output_config?.effort === 'minimal' ? 'low' : params.output_config?.effort ?? 'low';
  return { ...params, model, output_config: { ...params.output_config, effort } };
}
