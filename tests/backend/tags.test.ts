import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { BROAD_CATEGORIES, distinctiveKeyword, GENERIC_KEYWORDS, specificTagsFromCategories, TAG_NAMES, TAG_VOCABULARY, TAG_VOCABULARY_VERSION, tagsFromCategories, vocabularyName } from '../../supabase/functions/_shared/tag-vocabulary.ts';
import { classifyPaper, createTagClient, estimateMicrousd, parseTags, priceUsage, TAG_MODEL, TAG_SCHEMA, TAG_SYSTEM_PROMPT, tagCatalog,
  tagRequest, type Classification, type ClaimedVersion, type TaggingDeps } from '../../supabase/functions/_shared/tags.ts';

const root = new URL('../../', import.meta.url);

test('the vocabulary is curated: 60-120 distinct names within the server text rules, each defined', () => {
  assert.ok(TAG_VOCABULARY.length >= 60 && TAG_VOCABULARY.length <= 120, `${TAG_VOCABULARY.length} tags`);
  assert.equal(new Set(TAG_NAMES.map(name => name.toLowerCase())).size, TAG_NAMES.length);
  for (const tag of TAG_VOCABULARY) {
    // migration 030 valid_tag_list: trimmed, single spaces, 1-40 characters, no control characters.
    assert.ok(tag.name === tag.name.trim() && !/\s\s/.test(tag.name) && tag.name.length >= 1 && [...tag.name].length <= 40, tag.name);
    assert.ok(tag.definition.length > 10 && tag.definition.length <= 120, tag.name);
  }
  assert.ok(TAG_VOCABULARY.filter(tag => tag.kind === 'area').length >= 10);
  const categories = TAG_VOCABULARY.flatMap(tag => tag.categories ?? []);
  assert.equal(new Set(categories).size, categories.length, 'a category maps to one tag');
  for (const name of ['Diffusion models', 'Reinforcement learning', 'Alignment', 'Mixture of experts', 'Computer vision', 'Speech and audio']) {
    assert.ok(TAG_NAMES.includes(name), name);
  }
  assert.match(TAG_VOCABULARY_VERSION, /^[a-z0-9-]{1,64}$/);
});

test('the app carries the same vocabulary (names, kinds, definitions, categories, version)', () => {
  const swift = readFileSync(new URL('apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/TagVocabulary.swift', root), 'utf8');
  const rows = [...swift.matchAll(/^\s*\.init\((".*?"), \.(area|topic), (".*?")(?:, \[(.*?)\])?\),$/gm)].map(match => ({
    name: JSON.parse(match[1]), kind: match[2], definition: JSON.parse(match[3]),
    categories: match[4] ? match[4].split(', ').map(value => JSON.parse(value)) : [],
  }));
  assert.deepEqual(rows, TAG_VOCABULARY.map(tag => ({ name: tag.name, kind: tag.kind, definition: tag.definition, categories: tag.categories ?? [] })));
  assert.ok(swift.includes(`public static let version = "${TAG_VOCABULARY_VERSION}"`));
  // The generic keywords (builds 70 and 75): the same list on both sides.
  const generic = /public static let generic: Set<String> = \[([\s\S]*?)\]/.exec(swift);
  assert.ok(generic, 'TagVocabulary.generic');
  assert.deepEqual([...generic[1].matchAll(/"(.*?)"/g)].map(match => match[1]).sort(), [...GENERIC_KEYWORDS].sort());
  // The broad subject classes the keyword fallback skips (build 78): the same list on both sides.
  const broad = /public static let broadCategories: Set<String> = \[([\s\S]*?)\]/.exec(swift);
  assert.ok(broad, 'TagVocabulary.broadCategories');
  assert.deepEqual([...broad[1].matchAll(/"(.*?)"/g)].map(match => match[1]).sort(), [...BROAD_CATEGORIES].sort());
});

test('the keyword fallback names a narrower subject, never machine learning, AI, language or vision (build 78)', () => {
  assert.deepEqual(specificTagsFromCategories(['cs.IR', 'cs.LG', 'cs.CL']), ['Information retrieval']);
  assert.deepEqual(specificTagsFromCategories(['cs.LG', 'stat.ML', 'cs.AI', 'cs.CL', 'cs.CV']), []);
  assert.deepEqual(specificTagsFromCategories(['cs.RO', 'cs.CR', 'math.OC']), ['Robotics', 'Security']);
});

test('generic keywords never describe a paper; specific ones and the vocabulary spelling do', () => {
  for (const name of ['LLM', 'LLMs', 'Large language models', 'Reasoning', 'Evaluation', ' benchmarks ', 'Machine learning', 'AI']) {
    assert.equal(distinctiveKeyword(name), false, name);
  }
  for (const name of ['Mathematical reasoning', 'Tool use', 'Mixture of experts', 'TreeCut', 'Robotics']) assert.equal(distinctiveKeyword(name), true, name);
  for (const name of GENERIC_KEYWORDS) assert.equal(name, name.trim().toLowerCase());
});

test('fallback tags come from arXiv categories that mean the same thing', () => {
  assert.deepEqual(tagsFromCategories(['cs.CL', 'cs.LG']), ['Natural language processing', 'Machine learning']);
  assert.deepEqual(tagsFromCategories(['cs.LG', 'stat.ML', 'cs.CV', 'cs.RO']), ['Machine learning', 'Computer vision', 'Robotics']);
  assert.deepEqual(tagsFromCategories(['cs.LG', 'stat.ML', 'cs.CV', 'cs.RO'], 2), ['Machine learning', 'Computer vision']);
  assert.deepEqual(tagsFromCategories(['hep-th', 'cs.DC']), [], 'broader or unrelated categories give no tags');
  assert.equal(vocabularyName('  diffusion MODELS '), 'Diffusion models');
  assert.equal(vocabularyName('Diffusion'), null);
});

test('library query migration preserves the shared category fallback mapping', () => {
  const migration = readFileSync(new URL('supabase/migrations/202610070032_library_query.sql', root), 'utf8');
  const mapping = migration.match(/select '(\{"cs\.LG"[^\n]+\})'::jsonb->>value name/);
  assert.ok(mapping, 'versioned SQL category mapping exists');
  assert.deepEqual(JSON.parse(mapping[1]), Object.fromEntries(TAG_VOCABULARY.flatMap(tag =>
    (tag.categories ?? []).map(category => [category, tag.name]))));
});

test('the request: Haiku 5.5 through OpenRouter, the vocabulary as an enum, title and abstract only', () => {
  const request = tagRequest({ title: '  Attention   Is All You Need ', abstract: 'We propose the Transformer.\n\nIt uses attention.',
    categories: ['cs.CL', 'cs.LG', 'not a category!'] });
  assert.equal(request.model, 'anthropic/claude-haiku-5.5');
  assert.equal(TAG_MODEL, 'anthropic/claude-haiku-5.5');
  assert.ok(request.max_tokens <= 512);
  assert.equal(request.system, TAG_SYSTEM_PROMPT);
  for (const tag of TAG_VOCABULARY) assert.ok(TAG_SYSTEM_PROMPT.includes(`- ${tag.name}: ${tag.definition}`), tag.name);
  const format = request.output_config?.format as { type: string; schema: typeof TAG_SCHEMA };
  assert.equal(format.type, 'json_schema');
  assert.deepEqual((format.schema.properties.tags.items as { enum: string[] }).enum, [...TAG_NAMES]);
  assert.equal(format.schema.additionalProperties, false);
  const content = request.messages[0].content as string;
  assert.match(content, /<title>Attention Is All You Need<\/title>/);
  assert.match(content, /<abstract>We propose the Transformer\. It uses attention\.<\/abstract>/);
  assert.match(content, /<arxiv_categories>cs\.CL, cs\.LG<\/arxiv_categories>/);
  assert.ok(!content.includes('not a category'));
  const long = tagRequest({ title: 'x', abstract: 'y'.repeat(20_000), categories: [] }).messages[0].content as string;
  assert.ok(long.length < 4_200 && long.includes('<abstract>') && !long.includes('arxiv_categories'));
  assert.match(tagRequest({ title: 'x', abstract: null, categories: [] }).messages[0].content as string, /not available/);
});

test('answers map to the vocabulary: case, duplicates and unknown names, at most seven', () => {
  assert.deepEqual(parseTags('{"tags":["transformers","Transformers","Large language models","Not a tag"]}'), ['Transformers', 'Large language models']);
  assert.equal(parseTags('{"tags":'), null);
  assert.equal(parseTags('{"other":[]}'), null);
  assert.equal(parseTags(JSON.stringify({ tags: TAG_NAMES.slice(0, 10) }))?.length, 7);
  assert.equal(priceUsage({ input_tokens: 2900, output_tokens: 40 }), 341, 'Vertex US route rates');
  assert.equal(priceUsage({ input_tokens: 10, output_tokens: 0, cache_read_input_tokens: 10, cache_creation_input_tokens: 4 }), 2);
});

const attribution = { accountID: 'aaaaaaaa-0000-4000-8000-000000000001', operationID: 'bbbbbbbb-0000-4000-8000-000000000001', attemptID: 'cccccccc-0000-4000-8000-000000000001', feature: 'catalog_tags', caller: 'catalog', dispatch: async () => true };
function fakeRouter(handler: (body: Record<string, unknown>) => Response | Promise<Response>) {
  const calls: Record<string, unknown>[] = [];
  const client = createTagClient('test-key', (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body)); calls.push(body);
    return handler(body);
  }) as typeof fetch);
  return { client, calls };
}
const message = (text: string, stop = 'end_turn') => new Response('data: ' + JSON.stringify({ id: 'msg_tags_1', model: TAG_MODEL,
  choices: [{ delta: { content: text }, finish_reason: stop === 'end_turn' ? 'stop' : 'content_filter' }],
  usage: { prompt_tokens: 2900, completion_tokens: 40, cost: 0.000341 } }) + '\n\ndata: [DONE]\n\n', { headers: { 'content-type': 'text/event-stream' } });

test('a classification is priced from usage; refusals, bad output and errors fall back with what is known about billing', async () => {
  const input = { title: 'Direct Preference Optimization', abstract: 'We fine-tune language models from preferences.', categories: ['cs.LG'] };
  const ok = fakeRouter(() => message('{"tags":["Machine learning","Preference optimization","Alignment","Large language models"]}'));
  const done = await classifyPaper(ok.client, input, attribution);
  assert.deepEqual(done, { status: 'complete', tags: ['Machine learning', 'Preference optimization', 'Alignment', 'Large language models'],
    messageID: 'msg_tags_1', model: 'anthropic/claude-haiku-5.5', usage: { input_tokens: 2900, output_tokens: 40 }, microusd: 341 });
  assert.equal(ok.calls.length, 1);
  assert.equal((ok.calls[0].response_format as { type: string }).type, 'json_schema');
  assert.ok(!JSON.stringify(ok.calls[0]).includes('test-key'));

  const refused = await classifyPaper(fakeRouter(() => message('', 'refusal')).client, input, attribution);
  assert.equal(refused.status, 'failed');
  assert.equal(refused.status === 'failed' && refused.code, 'provider_refused');
  assert.equal(refused.messageID, 'msg_tags_1');
  assert.equal(refused.microusd, 341, 'a refused message is still billed');
  const invalid = await classifyPaper(fakeRouter(() => message('{"tags":["Not a tag"]}')).client, input, attribution);
  assert.equal(invalid.status === 'failed' && invalid.code, 'invalid_output');

  const rejected = await classifyPaper(fakeRouter(() => new Response(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'x' } }),
    { status: 400, headers: { 'content-type': 'application/json' } })).client, input, attribution);
  assert.deepEqual(rejected, { status: 'failed', code: 'provider_rejected', messageID: null, model: null, usage: null, microusd: 0 });
  const lost = await classifyPaper(fakeRouter(() => { throw new TypeError('socket hang up'); }).client, input, attribution);
  assert.equal(lost.status === 'failed' && lost.code, 'provider_transport');
  assert.equal(lost.microusd, estimateMicrousd(tagRequest(input)), 'a lost call is charged its upper bound');
  assert.ok(lost.microusd > 1_000 && lost.microusd < 5_000, `${lost.microusd} µ$ conservative byte bound fits the revised hold`);
});

function harness(claims: ClaimedVersion[][], classify: TaggingDeps['classify'], options: { failRecord?: boolean; items?: number } = {}) {
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const logs: { event: string; fields?: Record<string, unknown> }[] = [];
  let now = 0;
  const deps: TaggingDeps = {
    async rpc<T>(name: string, params: Record<string, unknown>): Promise<T> {
      calls.push({ name, params });
      if (name === 'worker_tags_claim') return (claims.shift() ?? []) as T;
      if (name === 'worker_tags_record') {
        if (options.failRecord) throw new Error('stale_tag_claim');
        return { revision: 1, method: params.p_method, changed: true,
          items: Array.from({ length: options.items ?? 1 }, (_, n) => ({ account_id: `a${n}`, item_id: `i${n}` })) } as T;
      }
      if (name === 'worker_tags_project') return true as T;
      if (name === 'worker_tags_pending_projection') return [{ account_id: 'late', item_id: 'late-item' }] as T;
      throw new Error('unexpected_rpc');
    },
    classify, uuid: () => `claim-${calls.length}`, now: () => (now += 1_000),
    log: (event, fields) => { logs.push({ event, fields }); },
  };
  return { deps, calls, logs };
}
const claimed = (id: string, model: boolean, categories = ['cs.CL', 'cs.LG']): ClaimedVersion => ({
  version_id: id, claim_id: 'c-' + id, metadata_id: 'm-' + id, title: 'A title', abstract: 'An abstract', categories,
  model, hold_microusd: model ? 40_000 : 0, model_refused: model ? null : 'platform_budget_exhausted', method: null, tags: [] });

test('a tagging run: model tags under a hold, the category fallback without one, projections, then stragglers', async () => {
  const seen: unknown[] = [];
  const classify = async (input: unknown): Promise<Classification> => {
    seen.push(input);
    return { status: 'complete', tags: ['Natural language processing', 'Transformers', 'Long context'], messageID: 'msg_1',
      model: 'anthropic/claude-haiku-5.5', usage: { input_tokens: 2900, output_tokens: 40 }, microusd: 341 };
  };
  const { deps, calls, logs } = harness([[claimed('v1', true), claimed('v2', false)]], classify, { items: 2 });
  const result = await tagCatalog(deps, { deadline: 1_000_000 });
  assert.deepEqual(result, { model: 1, fallback: 1, failed: 0, projected: 5 });
  assert.equal(seen.length, 1, 'only the funded version is sent to the model');
  const claim = calls[0];
  assert.equal(claim.name, 'worker_tags_claim');
  assert.deepEqual({ ...claim.params, p_claim_id: undefined }, { p_claim_id: undefined, p_limit: 3, p_model: true, p_vocabulary: TAG_VOCABULARY_VERSION });
  const [modelRecord, fallbackRecord] = calls.filter(call => call.name === 'worker_tags_record').map(call => call.params);
  assert.deepEqual({ ...modelRecord, p_input_sha256: undefined }, { p_version_id: 'v1', p_claim_id: 'c-v1', p_metadata_id: 'm-v1',
    p_vocabulary: TAG_VOCABULARY_VERSION, p_input_sha256: undefined, p_model_attempted: true,
    p_tags: ['Natural language processing', 'Transformers', 'Long context'], p_method: 'model', p_model: 'anthropic/claude-haiku-5.5',
    p_provider_event_id: 'msg_1', p_units: { input_tokens: 2900, output_tokens: 40 }, p_microusd: 341 });
  assert.match(modelRecord.p_input_sha256 as string, /^\\x[0-9a-f]{64}$/);
  assert.deepEqual({ ...fallbackRecord, p_input_sha256: undefined }, { p_version_id: 'v2', p_claim_id: 'c-v2', p_metadata_id: 'm-v2',
    p_vocabulary: TAG_VOCABULARY_VERSION, p_input_sha256: undefined, p_model_attempted: false,
    p_tags: ['Natural language processing', 'Machine learning'], p_method: 'categories', p_model: null, p_provider_event_id: null,
    p_units: null, p_microusd: 0 });
  assert.equal(calls.filter(call => call.name === 'worker_tags_project').length, 5, 'two items per version, then one straggler');
  assert.equal(calls.at(-1)?.name, 'worker_tags_project');
  assert.ok(!JSON.stringify(logs).includes('A title') && !JSON.stringify(logs).includes('An abstract'), 'logs carry no paper text');
});

test('a failed model call records the fallback with its cost; no model means no hold is asked for', async () => {
  const failing = async (): Promise<Classification> => ({ status: 'failed', code: 'provider_transport', messageID: null, model: null, usage: null, microusd: 4321 });
  const { deps, calls } = harness([[claimed('v1', true)]], failing);
  assert.deepEqual(await tagCatalog(deps, { deadline: 1_000_000 }), { model: 0, fallback: 1, failed: 0, projected: 2 });
  const record = calls.find(call => call.name === 'worker_tags_record')!.params;
  assert.equal(record.p_method, 'categories');
  assert.equal(record.p_model_attempted, true);
  assert.equal(record.p_microusd, 40000, 'unknown result retains the entire admitted ceiling');
  assert.deepEqual(record.p_units, { input_tokens: 0, output_tokens: 0, estimated: true });
  assert.equal(record.p_provider_event_id, 'tags-estimate:c-v1:v1', 'an estimate is still recorded as provider usage');
  assert.equal(record.p_model, TAG_MODEL);

  const throwing = async (): Promise<Classification> => { throw new Error('bug'); };
  const thrown = harness([[claimed('v1', true)]], throwing);
  await tagCatalog(thrown.deps, { deadline: 1_000_000 });
  assert.ok((thrown.calls.find(call => call.name === 'worker_tags_record')!.params.p_microusd as number) > 0, 'a thrown classifier is charged its bound');

  const keyless = harness([[claimed('v1', false)]], null);
  await tagCatalog(keyless.deps, { deadline: 1_000_000 });
  assert.equal(keyless.calls[0].params.p_model, false);
});

test('a tag input whose byte bound exceeds its admitted hold never calls the model', async () => {
  const candidate = claimed('v1', true); candidate.hold_microusd = 100;
  let generated = 0;
  const { deps, calls } = harness([[candidate]], async () => { generated++; throw new Error('must not send'); });
  await tagCatalog(deps, { deadline: 1_000_000 });
  assert.equal(generated, 0);
  const record = calls.find(call => call.name === 'worker_tags_record')!.params;
  assert.equal(record.p_method, 'categories'); assert.equal(record.p_microusd, 0);
  assert.equal(record.p_model_attempted, false); assert.equal(record.p_provider_event_id, null);
});

test('runs stop at their bounds; a record that fails is counted and logged, not thrown', async () => {
  const { deps, calls, logs } = harness([[claimed('v1', false)], [claimed('v2', false)], [claimed('v3', false)]], null, { failRecord: true });
  const result = await tagCatalog(deps, { deadline: 1_000_000, batch: 1, maxPapers: 2 });
  assert.deepEqual(result, { model: 0, fallback: 0, failed: 2, projected: 1 });
  assert.equal(calls.filter(call => call.name === 'worker_tags_claim').length, 2);
  assert.ok(logs.some(log => log.event === 'tags_record_failed' && log.fields?.code === 'stale_tag_claim'));
  const late = harness([[claimed('v1', false)]], null);
  assert.deepEqual(await tagCatalog(late.deps, { deadline: 5_000 }), { model: 0, fallback: 0, failed: 0, projected: 1 }, 'no claim near the deadline');
  assert.equal(late.calls.filter(call => call.name === 'worker_tags_claim').length, 0);
});
