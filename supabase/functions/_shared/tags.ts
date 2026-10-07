// Catalog topic tags (docs/architecture/TAGS.md, migration 029). The pipeline worker claims
// paper versions that readers have (or are adding), asks Claude Haiku to choose 3-7 tags from
// Gradstep's vocabulary given only the title and abstract (structured output constrained to the
// vocabulary), and records them under a platform-funded hold (never charged to readers). When
// the model is unavailable (no key, budget exhausted or paused, a failed call) the paper's arXiv
// categories give fallback tags, upgraded by the model later. Recorded tags reach each reader's
// library entry through worker_tags_project (a new state_seq per item).
//
// Deno and Node compatible; dependencies are injected so tests drive it with fakes. Never logs
// titles, abstracts, prompts or the API key.
import Anthropic from '@anthropic-ai/sdk';
import { sha256 } from './http.ts';
import { TAG_NAMES, TAG_VOCABULARY, TAG_VOCABULARY_VERSION, tagsFromCategories, vocabularyName } from './tag-vocabulary.ts';

export const TAG_MODEL = 'claude-haiku-4-5-20251001';
export const TAG_MAX_TOKENS = 256;
export const MAX_TAGS = 7;
/** Claude Haiku 4.5: $1 / $5 per million input / output tokens, as micro-USD per token. */
export const HAIKU_RATES = Object.freeze({ input: 1, output: 5, cacheWrite5m: 1.25, cacheRead: 0.1 });
const MAX_TITLE = 400, MAX_ABSTRACT = 4000;

export interface TagInput { title: string; abstract: string | null; categories: string[] }
export interface TagUsage { input_tokens: number; output_tokens: number; estimated?: boolean }
export type Classification =
  | { status: 'complete'; tags: string[]; messageID: string; model: string; usage: TagUsage; microusd: number }
  /** `messageID` is set when the provider returned a (billed) message; otherwise the cost may be an estimate. */
  | { status: 'failed'; code: string; messageID: string | null; model: string | null; usage: TagUsage | null; microusd: number };

const clean = (value: string | null | undefined, limit: number) => (value ?? '').replace(/\s+/g, ' ').trim().slice(0, limit);

/** The fixed instructions and vocabulary (identical for every paper). */
export const TAG_SYSTEM_PROMPT = [
  'You assign topic tags to machine learning research papers for Gradstep, a paper reader. Readers browse and filter their',
  'library by these tags, so the same tags must mean the same thing on every paper.',
  '',
  'Choose 3 to 7 tags from the vocabulary below:',
  '- 1 or 2 areas: the broad fields the paper belongs to.',
  '- 2 to 5 topics: the methods, problems or applications that are central to the paper.',
  '',
  'Tag what the paper contributes or studies. Do not tag what it only compares against (baselines), evaluates on, cites as',
  'background or uses as a standard tool: a diffusion paper that beats GANs is not about GANs. Prefer the most specific tags',
  'that fit, and choose only as many as truly fit: three accurate tags are better than six with a weak one. Use "Machine',
  'learning" only when no more specific area fits. Judge from the title and abstract alone; the arXiv categories are the',
  'authors\' own coarse labels and only a hint.',
  '',
  'Areas:',
  ...TAG_VOCABULARY.filter(tag => tag.kind === 'area').map(tag => `- ${tag.name}: ${tag.definition}`),
  '',
  'Topics:',
  ...TAG_VOCABULARY.filter(tag => tag.kind === 'topic').map(tag => `- ${tag.name}: ${tag.definition}`),
].join('\n');

/** Structured output: a list of vocabulary names (the API enforces the enum). */
export const TAG_SCHEMA = Object.freeze({
  type: 'object',
  properties: { tags: { type: 'array', items: { type: 'string', enum: [...TAG_NAMES] } } },
  required: ['tags'],
  additionalProperties: false,
});

export function tagRequest(input: TagInput): Anthropic.MessageCreateParamsNonStreaming {
  const abstract = clean(input.abstract, MAX_ABSTRACT);
  const categories = input.categories.filter(c => /^[A-Za-z-]{1,16}(\.[A-Za-z-]{1,16})?$/.test(c)).slice(0, 12);
  const paper = [
    '<paper>',
    `<title>${clean(input.title, MAX_TITLE)}</title>`,
    abstract ? `<abstract>${abstract}</abstract>` : '<abstract>(not available)</abstract>',
    categories.length ? `<arxiv_categories>${categories.join(', ')}</arxiv_categories>` : '',
    '</paper>',
  ].filter(Boolean).join('\n');
  return {
    model: TAG_MODEL, max_tokens: TAG_MAX_TOKENS,
    system: TAG_SYSTEM_PROMPT,
    messages: [{ role: 'user', content: paper }],
    output_config: { format: { type: 'json_schema', schema: { ...TAG_SCHEMA } } },
  };
}

/** The vocabulary's own names from the model's answer: deduplicated, in its order, at most seven. */
export function parseTags(text: string): string[] | null {
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  const tags = (value as { tags?: unknown })?.tags;
  if (!Array.isArray(tags)) return null;
  const result: string[] = [];
  for (const tag of tags) {
    const name = typeof tag === 'string' ? vocabularyName(tag) : null;
    if (name && !result.includes(name)) result.push(name);
    if (result.length === MAX_TAGS) break;
  }
  return result;
}

export function priceUsage(usage: { input_tokens?: number | null; output_tokens?: number | null;
  cache_creation_input_tokens?: number | null; cache_read_input_tokens?: number | null }): number {
  const n = (value: number | null | undefined) => Number.isSafeInteger(value) && (value as number) > 0 ? value as number : 0;
  return Math.ceil(n(usage.input_tokens) * HAIKU_RATES.input + n(usage.output_tokens) * HAIKU_RATES.output
    + n(usage.cache_creation_input_tokens) * HAIKU_RATES.cacheWrite5m + n(usage.cache_read_input_tokens) * HAIKU_RATES.cacheRead);
}

/** Upper bound when a call may have been processed but returned nothing (connection lost). */
export function estimateMicrousd(request: Anthropic.MessageCreateParamsNonStreaming): number {
  const characters = JSON.stringify(request.system).length + JSON.stringify(request.messages).length + JSON.stringify(TAG_SCHEMA).length;
  return Math.ceil(Math.ceil(characters / 3) * HAIKU_RATES.input + request.max_tokens * HAIKU_RATES.output);
}

/** One classification. Never throws: every path says what is known about billing. */
export async function classifyPaper(client: Anthropic, input: TagInput): Promise<Classification> {
  const request = tagRequest(input);
  let message: Anthropic.Message;
  try {
    message = await client.messages.create(request);
  } catch (error) {
    // A typed HTTP status means the request was refused and not billed; a lost connection may have been.
    if (error instanceof Anthropic.APIError && typeof error.status === 'number' && !(error instanceof Anthropic.APIConnectionError)) {
      return { status: 'failed', code: error.status === 429 || error.status >= 500 ? 'provider_unavailable' : 'provider_rejected',
        messageID: null, model: null, usage: null, microusd: 0 };
    }
    return { status: 'failed', code: 'provider_transport', messageID: null, model: null, usage: null, microusd: estimateMicrousd(request) };
  }
  const usage: TagUsage = { input_tokens: message.usage?.input_tokens ?? 0, output_tokens: message.usage?.output_tokens ?? 0 };
  const microusd = priceUsage(message.usage ?? {});
  const text = message.content.find((block): block is Anthropic.TextBlock => block.type === 'text')?.text ?? '';
  const tags = message.stop_reason === 'end_turn' ? parseTags(text) : null;
  if (!tags || !tags.length) {
    return { status: 'failed', code: message.stop_reason === 'refusal' ? 'provider_refused' : 'invalid_output',
      messageID: message.id, model: message.model, usage, microusd };
  }
  return { status: 'complete', tags, messageID: message.id, model: message.model, usage, microusd };
}

export function createTagClient(apiKey: string, fetcher?: typeof fetch): Anthropic {
  // SDK logging off: its error paths could include request details.
  return new Anthropic({ apiKey, maxRetries: 0, timeout: 30_000, logLevel: 'off', ...(fetcher ? { fetch: fetcher } : {}) });
}

export interface ClaimedVersion {
  version_id: string; claim_id: string; metadata_id: string;
  title: string | null; abstract: string | null; categories: unknown[];
  /** True when a platform-funded hold was reserved for a model call. */
  model: boolean; hold_microusd: number; model_refused: string | null;
  method: 'model' | 'categories' | null; tags: string[];
}
interface Recorded { revision: number; method: string; changed: boolean; items: { account_id: string; item_id: string }[] }

export interface TaggingDeps {
  rpc<T>(name: string, params: Record<string, unknown>): Promise<T>;
  /** Null when no model is configured: only fallback tags are recorded. */
  classify: ((input: TagInput) => Promise<Classification>) | null;
  uuid(): string;
  now(): number;
  log(event: string, fields?: Record<string, string | number | boolean | null>): void;
}
export interface TaggingResult { model: number; fallback: number; failed: number; projected: number }

const encoder = new TextEncoder();

export function tagInput(candidate: ClaimedVersion): TagInput {
  return { title: clean(candidate.title, MAX_TITLE), abstract: clean(candidate.abstract, MAX_ABSTRACT) || null,
    categories: (Array.isArray(candidate.categories) ? candidate.categories : []).filter((c): c is string => typeof c === 'string').slice(0, 64) };
}

async function project(deps: TaggingDeps, items: { account_id: string; item_id: string }[]): Promise<number> {
  let projected = 0;
  for (const item of items) {
    try { if (await deps.rpc<boolean>('worker_tags_project', { p_account_id: item.account_id, p_item_id: item.item_id })) projected++; }
    catch (error) { deps.log('tags_project_failed', { code: error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unknown' }); }
  }
  return projected;
}

/**
 * Tags due versions until none is due, `maxPapers` were handled or the deadline nears, then
 * finishes projections an earlier run left behind. Claims a few at a time: each model claim
 * holds platform budget until recorded.
 */
export async function tagCatalog(deps: TaggingDeps, options: { deadline: number; batch?: number; maxPapers?: number }): Promise<TaggingResult> {
  const result: TaggingResult = { model: 0, fallback: 0, failed: 0, projected: 0 };
  const batch = options.batch ?? 3, maxPapers = options.maxPapers ?? 30;
  let handled = 0;
  while (handled < maxPapers && deps.now() < options.deadline - 20_000) {
    const claimID = deps.uuid();
    const claimed = await deps.rpc<ClaimedVersion[]>('worker_tags_claim', { p_claim_id: claimID, p_limit: Math.min(batch, maxPapers - handled),
      p_model: deps.classify !== null, p_vocabulary: TAG_VOCABULARY_VERSION });
    if (!Array.isArray(claimed) || !claimed.length) break;
    for (const candidate of claimed) {
      handled++;
      const input = tagInput(candidate);
      const inputSHA = await sha256(encoder.encode(JSON.stringify([TAG_VOCABULARY_VERSION, TAG_MODEL, input.title, input.abstract, input.categories])));
      let outcome: Classification | null = null;
      if (candidate.model && deps.classify) {
        try { outcome = await deps.classify(input); }
        catch { outcome = { status: 'failed', code: 'classifier_error', messageID: null, model: null, usage: null, microusd: estimateMicrousd(tagRequest(input)) }; }
      }
      const fallback = tagsFromCategories(input.categories);
      const params: Record<string, unknown> = {
        p_version_id: candidate.version_id, p_claim_id: candidate.claim_id, p_metadata_id: candidate.metadata_id,
        p_vocabulary: TAG_VOCABULARY_VERSION, p_input_sha256: '\\x' + inputSHA,
        p_model_attempted: outcome !== null,
        ...(outcome?.status === 'complete'
          ? { p_tags: outcome.tags, p_method: 'model', p_model: outcome.model, p_provider_event_id: outcome.messageID,
              p_units: outcome.usage, p_microusd: outcome.microusd }
          : { p_tags: fallback, p_method: 'categories', p_model: outcome?.model ?? (outcome && outcome.microusd > 0 ? TAG_MODEL : null),
              // An unbilled refusal has no event; a possibly billed lost call is recorded as an estimate.
              p_provider_event_id: outcome?.messageID ?? (outcome && outcome.microusd > 0 ? `tags-estimate:${candidate.claim_id}:${candidate.version_id}` : null),
              p_units: outcome?.usage ?? (outcome && outcome.microusd > 0 ? { input_tokens: 0, output_tokens: 0, estimated: true } : null),
              p_microusd: outcome?.microusd ?? 0 }),
      };
      try {
        const recorded = await deps.rpc<Recorded>('worker_tags_record', params);
        if (outcome?.status === 'complete') result.model++; else result.fallback++;
        if (outcome?.status === 'failed') deps.log('tags_model_failed', { version: candidate.version_id, code: outcome.code });
        deps.log('tags_recorded', { version: candidate.version_id, method: recorded.method, changed: recorded.changed,
          count: (params.p_tags as string[]).length, microusd: params.p_microusd as number, refused: candidate.model_refused });
        result.projected += await project(deps, recorded.items ?? []);
      } catch (error) {
        result.failed++;
        deps.log('tags_record_failed', { version: candidate.version_id, code: error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unknown' });
      }
    }
  }
  try {
    result.projected += await project(deps, await deps.rpc<{ account_id: string; item_id: string }[]>('worker_tags_pending_projection', { p_limit: 100 }));
  } catch (error) {
    deps.log('tags_pending_failed', { code: error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unknown' });
  }
  return result;
}
