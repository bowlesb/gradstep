// OpenRouter's own record of one generation (GET /api/v1/generation?id=): its final cost and native token counts. It
// appears a few seconds after the generation ends (404 until then) and exists for streams that were cancelled or broke
// before the final usage chunk. A GET reads a bill; it can never buy another generation. Shared by chat (a stopped or
// broken stream, PROVIDER_SPENDING.md "Stopped answers and unresolved attempts"), speech (binary audio has no usage
// chunk) and the reconciler (attempts still unresolved after the request ended). Only numbers and short identifiers
// leave this module; the record is matched to our account and operation before it is believed.
const LABEL = /^[a-zA-Z0-9 ./_:-]{1,128}$/;
const MAX_RECORD_CHARS = 65_536;
/** The most one generation may cost before its record is treated as implausible (micro-USD): far above any ceiling. */
export const MAX_GENERATION_MICROUSD = 30_000_000;

export interface GenerationRecord {
  id: string;
  /** The model OpenRouter served (may carry a dated suffix). */
  model: string;
  /** The inference provider that served it (OpenRouter's provider name). */
  provider: string;
  /** OpenRouter's total cost for the generation, micro-USD (rounded up). */
  totalMicrousd: number;
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  cancelled: boolean | null;
  finishReason: string | null;
}
export interface GenerationLookupOptions {
  apiKey: string;
  fetch?: typeof fetch;
  /** Waits between tries (tests replace it); must reject when `signal` aborts. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
}

const object = (v: unknown): Record<string, unknown> => v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {};
const count = (v: unknown): number | null => Number.isSafeInteger(v) && (v as number) >= 0 ? v as number : null;

function wait(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const stop = () => { clearTimeout(timer); reject(new Error('deadline')); };
    const timer = setTimeout(() => { signal.removeEventListener('abort', stop); resolve(); }, ms);
    signal.addEventListener('abort', stop, { once: true });
    if (signal.aborted) stop();
  });
}

/** Parses and checks one record against the generation, account and operation it must belong to. */
export function generationRecord(value: unknown, id: string, identity: { accountID: string; operationID: string }): GenerationRecord | null {
  const r = object(object(value).data);
  const prompt = count(r.native_tokens_prompt), completion = count(r.native_tokens_completion);
  const cached = r.native_tokens_cached === undefined || r.native_tokens_cached === null ? 0 : count(r.native_tokens_cached);
  if (r.id !== id || r.external_user !== identity.accountID || r.session_id !== identity.operationID
    || typeof r.total_cost !== 'number' || !Number.isFinite(r.total_cost) || r.total_cost < 0 || r.total_cost * 1_000_000 > MAX_GENERATION_MICROUSD
    || prompt === null || completion === null || cached === null || cached > prompt
    || typeof r.model !== 'string' || !LABEL.test(r.model) || typeof r.provider_name !== 'string' || !LABEL.test(r.provider_name)) return null;
  return { id, model: r.model, provider: r.provider_name, totalMicrousd: Math.ceil(r.total_cost * 1_000_000),
    promptTokens: prompt, completionTokens: completion, cachedTokens: cached,
    cancelled: typeof r.cancelled === 'boolean' ? r.cancelled : null,
    // A reason outside the closed shape is kept only as `other` (never its text), so it can't pass for `stop`.
    finishReason: typeof r.finish_reason === 'string' ? /^[a-z_]{1,32}$/.test(r.finish_reason) ? r.finish_reason : 'other' : null };
}

/** What one lookup established: the record, or why there is none. `absent`: OpenRouter answered 404 to every read (it
 * has no record of the generation, or has not written it yet). `invalid`: it returned a record for this generation that
 * fails the checks (another account or operation, implausible numbers): a record exists. `unreadable`: anything else (a
 * 401 from a lapsed key, a 5xx, a timeout, an abort, a body that is not a record): nothing is known. Only `absent` may
 * ever count as "no record" (the reconciler's assumed zero, migration 0162). */
export type GenerationRead = { record: GenerationRecord } | { missing: 'absent' | 'invalid' | 'unreadable' };

/** Reads one generation's record, waiting while OpenRouter has not written it yet (404): `tries` reads, the first at
 * once and then after 250 ms doubling to at most 4 s. Never throws. */
export async function readGeneration(options: GenerationLookupOptions, id: string, identity: { accountID: string; operationID: string },
  signal: AbortSignal, tries = 8): Promise<GenerationRead> {
  if (!/^[a-zA-Z0-9._:-]{1,256}$/.test(id)) return { missing: 'unreadable' };
  const sleep = options.sleep ?? wait;
  try {
    for (let n = 0; n < tries; n++) {
      if (n) await sleep(Math.min(4000, 250 * 2 ** (n - 1)), signal);
      const response = await (options.fetch ?? fetch)(`https://openrouter.ai/api/v1/generation?id=${encodeURIComponent(id)}`,
        { signal, redirect: 'error', headers: { authorization: `Bearer ${options.apiKey}`, 'X-Session-ID': identity.operationID } });
      if (response.ok) {
        const raw = await response.text();
        if (raw.length > MAX_RECORD_CHARS) return { missing: 'unreadable' };
        const value: unknown = JSON.parse(raw);
        const record = generationRecord(value, id, identity);
        if (record) return { record };
        // A record that names this generation but fails a check exists; one that does not name it is not a record.
        return { missing: object(object(value).data).id === id ? 'invalid' : 'unreadable' };
      }
      await response.body?.cancel().catch(() => {});
      if (response.status !== 404) return { missing: 'unreadable' };
    }
    return { missing: 'absent' };
  } catch { /* aborted, transport or malformed */ }
  return { missing: 'unreadable' };
}

/** The record, or null for any other outcome: the caller keeps the attempt's whole ceiling as unresolved liability. */
export async function lookupGeneration(options: GenerationLookupOptions, id: string, identity: { accountID: string; operationID: string },
  signal: AbortSignal, tries = 8): Promise<GenerationRecord | null> {
  const read = await readGeneration(options, id, identity, signal, tries);
  return 'record' in read ? read.record : null;
}
