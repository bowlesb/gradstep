// One interest index run (docs/architecture/INTEREST_INDEX.md), driven by the worker's POST /interest:
//   claim (one run at a time, lease-fenced) → sync the pool and catalog → embed pending papers (leaf by descent on the
//   published map, top terms from the published term statistics) → publish a shard of new pool fingerprints → when
//   due, build and publish a new map version with its term statistics.
// Every RPC is a service-role database call; the only other dependency is the embedder. No request leaves for anywhere
// but the database: no arXiv, no model hub, no provider.
import {
  DIM, base64, dequantize, fromBase64, fromHalfvecSend, mapBody, normalize, pack, quantize, readMapCentroids, readTerms, shardBody,
  termsBody, unpack, vectorText, type MapNode, type TermStat,
} from './codec.ts';
import { assignIDs, buildMap, childIndex, descend, type PreviousNode } from './map-build.ts';
import { countVocabulary, documentText } from './ngrams.ts';
import { STOP_WORDS } from './stopwords.ts';
import { conceptness, finishPaperTerms, nodeTerms, paperCandidates, type TermInfo } from './terms.ts';

export const MODEL_VERSION = 'gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1';
export const TOKEN_PATTERN = '(?u)\\b[a-zA-Z][a-zA-Z0-9\\-]+\\b';

export interface InterestDeps {
  rpc<T>(name: string, params: Record<string, unknown>): Promise<T>;
  /** Unit gte-small embeddings of the given texts, in order. */
  embed(texts: string[]): Promise<Float32Array[]>;
  modelVersion: string;
  now(): number;
  uuid(): string;
  log(event: string, fields?: Record<string, unknown>): void;
}

interface Policy {
  model_version: string; corpus_days: number; window_days: number; min_corpus: number; top_k: number; mid_size: number;
  leaf_size: number; min_df: number; max_df_share: number; label_max_df_share: number; concept_min: number;
  keep_jaccard: number; keep_cos: number; drift_max: number;
}
interface Claim { claimed: boolean; reason?: string; policy: Policy; map_version: number | null; map_artifact: string | null; terms_artifact: string | null; rebuild_due: boolean }
interface Current { version: number; nodes: (MapNode & { centroid: Float32Array })[]; terms: Map<string, TermInfo>; documents: number }

/** The embedded text, as app_private.interest_text: whitespace runs collapsed, ends trimmed. */
export function interestText(title: string, abstract: string | null): string {
  const clean = (s: string) => s.replace(/[ \t\n\v\f\r]+/g, ' ').replace(/^ +| +$/g, '');
  return `${clean(title)}. ${clean(abstract ?? '')}`;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource));
  return Array.from(digest, b => b.toString(16).padStart(2, '0')).join('');
}

const codeOf = (error: unknown) => (error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected');

export interface InterestRunResult { processed: number; counts: Record<string, unknown> }

export async function runInterest(deps: InterestDeps, deadline: number): Promise<InterestRunResult> {
  const claimID = deps.uuid();
  const claim = await deps.rpc<Claim>('worker_interest_claim', { p_claim: claimID });
  if (!claim.claimed) return { processed: 0, counts: { skipped: claim.reason } };
  const counts: Record<string, unknown> = {};
  let error: string | null = null, processed = 0;
  try {
    if (claim.policy.model_version !== deps.modelVersion) throw new Error('interest_model_mismatch');
    counts.sync = await deps.rpc('worker_interest_sync', { p_claim: claimID });
    const current = await loadCurrent(deps, claimID, claim);
    const embedUntil = claim.rebuild_due ? Math.min(deadline, deps.now() + 120_000) : deadline;
    const embedded = await embedPending(deps, claimID, current, embedUntil);
    counts.embedded = embedded.stored; counts.embed_failed = embedded.failed; processed += embedded.stored;
    counts.shard = await publishShard(deps, claimID);
    if (claim.rebuild_due && deps.now() < deadline - 60_000) counts.rebuild = await rebuild(deps, claimID, claim.policy, deadline);
  } catch (e) {
    error = codeOf(e);
    deps.log('interest_run_error', { code: error });
  }
  await deps.rpc('worker_interest_release', { p_claim: claimID, p_state: error ? 'failed' : 'finished', p_counts: counts, p_error: error });
  return { processed, counts: { ...counts, ...(error ? { error } : {}) } };
}

async function artifact(deps: InterestDeps, claimID: string, id: string): Promise<Uint8Array> {
  const a = await deps.rpc<{ content: string; sha256: string }>('worker_interest_artifact_service', { p_claim: claimID, p_id: id });
  const bytes = fromBase64(a.content);
  if (await sha256Hex(bytes) !== a.sha256) throw new Error('interest_artifact_digest');
  return bytes;
}

async function loadCurrent(deps: InterestDeps, claimID: string, claim: Claim): Promise<Current | null> {
  if (!claim.map_version || !claim.map_artifact || !claim.terms_artifact) return null;
  const map = await unpack(await artifact(deps, claimID, claim.map_artifact));
  const nodes = map.header.nodes as MapNode[];
  const centroids = readMapCentroids(map.body, nodes.length);
  const terms = await unpack(await artifact(deps, claimID, claim.terms_artifact));
  const stats = new Map(readTerms(terms.body).map(t => [t.term, { df: t.df, conceptness: t.conceptness }]));
  return { version: claim.map_version, nodes: nodes.map((n, i) => ({ ...n, centroid: centroids[i] })), terms: stats,
    documents: Number(terms.header.corpus_papers) };
}

class VectorCache {
  readonly vectors = new Map<string, Float32Array>();
  private readonly deps: InterestDeps;
  private readonly claimID: string;
  constructor(deps: InterestDeps, claimID: string) { this.deps = deps; this.claimID = claimID; }
  async fetch(terms: string[]): Promise<void> {
    const need = [...new Set(terms)].filter(t => !this.vectors.has(t));
    for (let i = 0; i < need.length; i += 5000) {
      const found = await this.deps.rpc<Record<string, string>>('worker_interest_term_vectors', { p_claim: this.claimID, p_terms: need.slice(i, i + 5000) });
      for (const [term, q8] of Object.entries(found)) this.vectors.set(term, normalize(dequantize(fromBase64(q8))));
    }
  }
  get = (term: string) => this.vectors.get(term);
}

async function embedPending(deps: InterestDeps, claimID: string, current: Current | null, until: number) {
  let stored = 0, failed = 0;
  const cache = new VectorCache(deps, claimID);
  const children = current ? childIndex(current.nodes) : null;
  const lookup = (t: string) => current?.terms.get(t);
  while (deps.now() < until) {
    const rows = await deps.rpc<{ source_id: string; title: string; abstract: string | null; text_sha256: string }[]>(
      'worker_interest_embed_claim', { p_claim: claimID, p_limit: 32 });
    if (!rows.length) break;
    let vectors: Float32Array[];
    try { vectors = await deps.embed(rows.map(r => interestText(r.title, r.abstract))); }
    catch (e) {
      await deps.rpc('worker_interest_embed_fail', { p_claim: claimID, p_source_ids: rows.map(r => r.source_id), p_code: codeOf(e) });
      failed += rows.length;
      continue;
    }
    const candidates = current ? rows.map(r => paperCandidates(r.title, r.abstract ?? '', lookup, current.documents)) : [];
    if (current) await cache.fetch(candidates.flatMap(c => c.map(([t]) => t)));
    const payload = rows.map((r, i) => {
      const v = vectors[i];
      const row: Record<string, unknown> = { source_id: r.source_id, text_sha256: r.text_sha256, model_version: deps.modelVersion,
        fingerprint: vectorText(v), q8: base64(quantize(v)) };
      if (current) {
        row.map_version = current.version;
        row.leaf_id = descend(v, current.nodes, children!).id;
        row.terms = finishPaperTerms(candidates[i], v, cache.get, lookup);
      }
      return row;
    });
    const result = await deps.rpc<{ stored: number }>('worker_interest_embed_store', { p_claim: claimID, p_rows: payload });
    stored += result.stored;
  }
  return { stored, failed };
}

async function publishShard(deps: InterestDeps, claimID: string) {
  const due = await deps.rpc<{ due: boolean; rows: { source_id: string; announced_on: string; q8: string; fp_seq: number }[] }>(
    'worker_interest_shard_due', { p_claim: claimID, p_max: 20000 });
  if (!due.due || !due.rows.length) return null;
  const rows = due.rows;
  const days = rows.map(r => r.announced_on).sort();
  const header = { kind: 'shard' as const, format: 1 as const, model_version: deps.modelVersion, papers: rows.length,
    fp_seq_from: rows[0].fp_seq, fp_seq_to: rows.at(-1)!.fp_seq, oldest_on: days[0], newest_on: days.at(-1)! };
  const content = await pack(header, shardBody(rows.map(r => ({ sourceID: r.source_id, announcedOn: r.announced_on, q8: fromBase64(r.q8) }))));
  await deps.rpc('worker_interest_shard_publish', { p_claim: claimID, p_shard: { ...header, content: base64(content), sha256: await sha256Hex(content) } });
  return { papers: rows.length, bytes: content.length };
}

interface CorpusRow { source_id: string; fp: string; title: string; abstract: string | null; pool_announced_on: string | null; in_map: boolean; leaf_id: number | null }

async function rebuild(deps: InterestDeps, claimID: string, policy: Policy, deadline: number) {
  const started = deps.now();
  const rows: CorpusRow[] = [];
  for (let after: string | null = null; ;) {
    const page = await deps.rpc<CorpusRow[]>('worker_interest_corpus_page', { p_claim: claimID, p_after: after, p_limit: 2000 });
    rows.push(...page);
    if (page.length < 2000) break;
    after = page.at(-1)!.source_id;
  }
  const map = rows.filter(r => r.in_map);
  const n = map.length;
  if (n < policy.min_corpus) return { skipped: 'corpus_too_small', corpus: n };
  const X = new Float32Array(n * DIM);
  map.forEach((r, i) => X.set(normalize(fromHalfvecSend(fromBase64(r.fp))), i * DIM));
  const vocab = countVocabulary(map.map(r => documentText(r.title, r.abstract ?? '')), policy.min_df, policy.label_max_df_share);
  const eligible = (t: number) => vocab.df[t] <= policy.max_df_share * n;
  const shipped = vocab.terms.filter((_, t) => eligible(t));

  // Phrase vectors: reuse stored ones, embed the rest; resume in the next run if time runs short.
  const cache = new VectorCache(deps, claimID);
  await cache.fetch(shipped);
  const missing = shipped.filter(t => !cache.get(t));
  let embeddedPhrases = 0;
  for (let i = 0; i < missing.length; i += 256) {
    if (deps.now() > deadline - 150_000) return { phase: 'phrases', embedded_phrases: embeddedPhrases, remaining: missing.length - i, corpus: n };
    const batch = missing.slice(i, i + 256);
    const vectors = await deps.embed(batch);
    const store: Record<string, string> = {};
    batch.forEach((t, j) => { store[t] = base64(quantize(vectors[j])); cache.vectors.set(t, normalize(dequantize(quantize(vectors[j])))); });
    await deps.rpc('worker_interest_term_vectors_store', { p_claim: claimID, p_rows: store });
    embeddedPhrases += batch.length;
  }

  // The map, warm-started from the published version.
  const prev = await deps.rpc<{ version: number | null; nodes: { id: number; level: 1 | 2 | 3; parent: number | null; centroid: string; birth: string }[];
    retired: { id: number; successors: number[]; shares: number[] }[] }>('worker_interest_previous_nodes', { p_claim: claimID });
  const previous: PreviousNode[] = prev.nodes.map(p => ({ id: p.id, level: p.level, parent: p.parent,
    centroid: normalize(fromHalfvecSend(fromBase64(p.centroid))), birth: normalize(fromHalfvecSend(fromBase64(p.birth))) }));
  const previousLeaf = Int32Array.from(map, r => (r.leaf_id === null ? -1 : r.leaf_id));
  const result = buildMap(X, n, previous.length ? previous : null, previousLeaf, {
    topK: policy.top_k, midSize: policy.mid_size, leafSize: policy.leaf_size,
    keepJaccard: policy.keep_jaccard, keepCos: policy.keep_cos, driftMax: policy.drift_max });
  const fresh = result.nodes.filter(b => b.id < 0).length;
  assignIDs(result, fresh ? await deps.rpc<number[]>('worker_interest_node_ids', { p_claim: claimID, p_count: fresh }) : []);

  // Terms: conceptness of shipped phrases, c-TF-IDF node terms per level, the 3 most central papers per node.
  const zero = new Float32Array(DIM);
  const conc = conceptness(vocab, X, t => cache.get(vocab.terms[t]) ?? zero);
  const nodeTermsOf = new Map<number, string[]>();
  for (const level of [1, 2, 3]) {
    const nodes = result.nodes.filter(b => b.level === level);
    nodeTerms(vocab, nodes.map(b => b.members), 6).forEach((terms, i) => nodeTermsOf.set(nodes[i].id, terms));
  }
  const central = (members: number[], c: Float32Array) => members.map(r => {
    let s = 0; for (let i = 0; i < DIM; i++) s += X[r * DIM + i] * c[i]; return [r, s] as [number, number];
  }).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([r]) => map[r]);
  const stats: TermStat[] = [];
  vocab.terms.forEach((term, t) => { if (eligible(t)) stats.push({ term, df: vocab.df[t], conceptness: conc[t] }); });
  const lookup = new Map(stats.map(s => [s.term, { df: s.df, conceptness: s.conceptness }]));

  const version = await deps.rpc<number>('worker_interest_build_begin', { p_claim: claimID, p_kind: result.stats.kind, p_corpus: n,
    p_params: { top_k: policy.top_k, mid_size: policy.mid_size, leaf_size: policy.leaf_size, min_df: policy.min_df,
      max_df_share: policy.max_df_share, keep_jaccard: policy.keep_jaccard, keep_cos: policy.keep_cos, drift_max: policy.drift_max },
    p_stats: { ...result.stats, vocabulary: vocab.terms.length, shipped_terms: stats.length,
      concept_pass: stats.filter(s => s.conceptness >= policy.concept_min).length, retired: result.retired.length,
      new_nodes: fresh, embedded_phrases: embeddedPhrases, seconds: Math.round((deps.now() - started) / 1000) } });

  const nodesOut = result.nodes.map(b => ({ id: b.id, level: b.level, parent: b.parent, size: b.members.length,
    terms: nodeTermsOf.get(b.id) ?? [], central: central(b.members, b.centroid).map(r => ({ source_id: r.source_id, title: r.title.slice(0, 300) })),
    name: null }));
  const builtAt = new Date(deps.now()).toISOString();
  const mapArtifact = await pack({ kind: 'map', format: 1, version, model_version: deps.modelVersion, built_at: builtAt,
    params: { top_k: policy.top_k, mid_size: policy.mid_size, leaf_size: policy.leaf_size },
    nodes: nodesOut, retired: [...prev.retired, ...result.retired.map(t => ({ id: t.id, successors: t.successors, shares: t.shares }))] },
    mapBody(result.nodes.map(b => b.centroid)));
  const termsArtifact = await pack({ kind: 'terms', format: 1, version, map_version: version, model_version: deps.modelVersion,
    built_at: builtAt, corpus_papers: n, total_df: stats.reduce((s, x) => s + x.df, 0), phrases: stats.length,
    tokenizer: { token_pattern: TOKEN_PATTERN, lowercase: true, ngram: [1, 3], title_weight: 2, stop_words_before_ngrams: true },
    stop_words: STOP_WORDS, min_df: policy.min_df, max_df_share: policy.max_df_share, concept_min: policy.concept_min,
    conceptness_scale: 1000 }, termsBody(stats));

  for (let i = 0; i < result.nodes.length; i += 300) {
    await deps.rpc('worker_interest_build_nodes', { p_claim: claimID, p_version: version, p_nodes: result.nodes.slice(i, i + 300).map((b, j) => ({
      id: b.id, parent: b.parent, level: b.level, centroid: vectorText(b.centroid), size: b.members.length,
      terms: nodesOut[i + j].terms, central_source_ids: nodesOut[i + j].central.map(c => c.source_id),
      central_titles: nodesOut[i + j].central.map(c => c.title) })) });
  }
  // Leaves for every embedded paper (map papers from the build, the rest by descent) and top terms for the window's pool
  // papers and catalog papers.
  const children = childIndex(result.nodes);
  const windowStart = new Date(deps.now() - policy.window_days * 86_400_000).toISOString().slice(0, 10);
  const leafBySource = new Map(map.map((r, i) => [r.source_id, result.leafOf[i]]));
  const out: { source_id: string; leaf_id: number; terms?: string[] }[] = [];
  const termRows: { r: CorpusRow; v: Float32Array; c: [string, number][] }[] = [];
  for (const r of rows) {
    const v = normalize(fromHalfvecSend(fromBase64(r.fp)));
    const leaf = leafBySource.get(r.source_id) ?? descend(v, result.nodes, children).id;
    out.push({ source_id: r.source_id, leaf_id: leaf });
    if (r.pool_announced_on === null || r.pool_announced_on >= windowStart) termRows.push({ r, v, c: paperCandidates(r.title, r.abstract ?? '', t => lookup.get(t), n) });
  }
  const termsOf = new Map(termRows.map(({ r, v, c }) => [r.source_id, finishPaperTerms(c, v, cache.get, t => lookup.get(t), 5, policy.concept_min)]));
  for (const row of out) { const t = termsOf.get(row.source_id); if (t) row.terms = t; }
  for (let i = 0; i < out.length; i += 5000) {
    await deps.rpc('worker_interest_build_rows', { p_claim: claimID, p_version: version, p_rows: out.slice(i, i + 5000) });
  }
  const published = await deps.rpc<{ published: boolean; reason?: string }>('worker_interest_build_publish', {
    p_claim: claimID, p_version: version, p_retired: result.retired,
    p_map: { content: base64(mapArtifact), sha256: await sha256Hex(mapArtifact) },
    p_terms: { content: base64(termsArtifact), sha256: await sha256Hex(termsArtifact) } });
  return { version, published: published.published, reason: published.reason ?? null, corpus: n, nodes: result.nodes.length,
    levels: result.stats.levels, map_bytes: mapArtifact.length, terms_bytes: termsArtifact.length, phrases: stats.length,
    embedded_phrases: embeddedPhrases, seconds: Math.round((deps.now() - started) / 1000) };
}
