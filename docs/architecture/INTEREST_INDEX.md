# Interest index: server layer (step 2)

Update, 2026-10-25: **the owner approved the §5 privacy notice and serving to `all`** ("2 and 3 sure";
[DECISIONS.md](../DECISIONS.md#interest-index-privacy-notice-approved-serving-may-go-to-all-owner-2026-10-25)). The
notice is placed on gradstep.ai/privacy and in the apps' Privacy & data (not deployed). Readiness fixes 0156 and 0157
are written and tested locally, not applied. Serving is still `staff`; the flip and its checks are in
[Serving to all](#serving-to-all-prepared-2026-10-25-not-run).

Status, 2026-10-24: **Phase B built and deployed to staging** (migration 0152, worker revision `gradstep-pipeline-00055-vzm`,
Edge function `interest-index`; serving `staff`). Evidence and as-built differences are in
[Phase B as built](#phase-b-as-built-staging-2026-10-24). The lead's interim decisions are recorded in
[DECISIONS.md](../DECISIONS.md#interest-index-server-layer-agent-design-2026-10-24-phase-b-built-on-staging-the-same-day).
The first client is the app's Related papers (device client below, 2026-10-24); step 3 reuses it. Proposal and owner decisions:
[proposals/INTEREST_INDEX.md](../proposals/INTEREST_INDEX.md). Offline reference code: `tools/interest-eval/`
(`topic_map.py`, `topic_rule2.py`, `terms.py`, `embed.py`, `common.py`).

Scope: **public papers only**. The server builds a public "map of the field" from the Feed pool and ships it to
devices. Each device then works out the reader's interests on its own (step 3). The server never computes, stores or
receives anyone's interest state.

## Summary of decisions

| # | Decision | Why (details below) |
|---|---|---|
| 1 | **gte-small, fp32 ONNX, run in the existing Cloud Run worker (Node)** behind a new `POST /interest` entry point, using `onnxruntime-node` and the pure-JS `@huggingface/tokenizers`. The model is baked into the image and pinned by checksum. | Measured identical to the step-1 vectors (min cos 1.0000 on 400 papers). It adds about 170 MB to the image and costs about $0–0.30 a month in CPU. There is no new service, secret or runtime. int8 is 2.5× faster but moves 8 % of top-10 neighbours, so it is rejected. |
| 2 | **pgvector `halfvec(384)`** for paper fingerprints. The `vector` extension is **not enabled** today (0.8.2 is available on staging), so the migration enables it in schema `extensions`. No ANN index. | No SQL runs a similarity search: devices and the worker do that in memory. An HNSW index can be added later for server-side similar-paper search. |
| 3 | **Public corpus = Feed-pool papers, kept 180 days** in a new table, beyond the pool's own 30 days. Catalog papers (public metadata of library papers) are embedded too, but **never enter the map, the term statistics or any shared artifact**. | 180 days gives about 100k papers at steady state, so about 20 / 670 / 2,500 nodes. The catalog is the union of readers' libraries, so publishing anything built from it would show readers what other readers hold. |
| 4 | **Due-based warm-started rebuild**: due once the map is 14 days old (7 once the corpus passes 50k papers), started in the weekend 06:00–10:00 UTC window or at any tick once 24 hours overdue; failures back off 10 min, 1 h, 6 h. It starts from the previous centroids. A leaf splits at 2× its target size (80 papers) and merges below ¼ (10). An ID is kept when membership Jaccard ≥ 0.5 and cos ≥ 0.9 with its previous version, and while it stays within 1 − cos 0.05 of its birth centroid. Retired IDs record their successors. New papers join the nearest leaf of the frozen map every day. | Cold k-means keeps only **10 %** of leaf IDs even on identical data. Warm start keeps **98 %** at 5 % turnover and **87–94 %** during the current growth spurts. Cohesion stays within 0.003 of a cold build. |
| 5 | **Term statistics as a versioned, gzip-compressed binary blob** (front-coded phrases, document frequency, conceptness), rebuilt weekly with the map. Per-paper top terms are cached in the database. | The blob is 0.30 MB today (57k phrases) and about 2 MB at 100k papers. Devices run TF-IDF and log-odds on full text locally. |
| 6 | **Delivery: one Edge function `interest-index`** (manifest plus immutable, content-addressed artifacts held in the database) **and one RPC `v1_interest_library_fingerprints`** that serves only the caller's own public library papers. | The artifacts are identical for every reader. The RPC derives the paper set from membership the server already holds, so neither path tells the server anything new. |
| 7 | **Privacy: bulk download of the pool, not a padded or k-anonymous fetch.** Library fingerprints come from membership, never from arbitrary IDs. Uploads and anything end-to-end encrypted are embedded on the device (step 3). | Padding with decoys either leaks other readers' catalog papers (catalog decoys) or adds nothing (pool decoys). See §5. |
| 8 | **No LLM calls.** Every node has a name slot, `name = null`, until November. | October's provider budget is at 82 %. Naming the map later costs about $2 once, then about $0.05 a week; that needs a separate approval. |
| 9 | **Cost: $0 fixed; about $0.05–0.50 a month in usage** (Cloud Run CPU, mostly inside the free tier; image storage; database and egress within the Pro allowances). No provider spend. | §6. |

## 1. Paper fingerprints

### Model and runtime (measured 2026-10-24)

The measurements ran in a scratch environment on an M1 Max under heavy load (load average 85–170 from other
sessions), so the throughputs below are pessimistic. All checks were single-threaded on CPU with ONNX Runtime 1.31,
over 400 random corpus papers. Papers average **308 tokens** (median 306, p95 414); 0.5 % are truncated at 512.

| Variant | Size | Load | Papers/s (1 thread) | Fidelity to the step-1 vectors (sentence-transformers fp32) |
|---|---|---|---|---|
| **fp32 ONNX** (`Xenova/gte-small@5927d17`, `onnx/model.onnx`, SHA-256 `398a2999…23b3`) | 133 MB | 0.2–0.6 s | 3.0–4.6 | **min cos 1.0000**, top-10 neighbour agreement 1.000; halfvec round trip cos 1.000000 |
| int8 dynamic-quantized ONNX | 34 MB | 0.1–0.25 s | 6.2–8.7 | min cos 0.993, top-10 agreement **0.92** |
| fp16 ONNX | 67 MB | — | not measured (fp16 kernels are slow on x86 CPU) | — |

- **The tokenizer must have padding disabled.** The ONNX export ships a `tokenizer.json` with fixed padding to 128
  tokens. Left on, pad tokens enter the mean pooling: short texts drift to cos 0.98, and every phrase embedding is
  corrupted (the concept filter passed 0 % of phrases instead of 17 %). The tokenizer is taken from
  `thenlper/gte-small@17e1f34` (MIT licence) with padding off, and a parity test pins this.
- **Choice: fp32.** At the planning rate of 3 papers/s on one Cloud Run vCPU, about 750 new papers on an announcement
  day take about 4 minutes of CPU. int8 would change one neighbour in twelve against the evaluated model, and uploads
  embedded on devices (step 3) must match the server.
- **Runtime: Node, inside the existing worker.**

  | Option | Image | Cold start | Ops | Verdict |
  |---|---|---|---|---|
  | **Node in the worker:** `onnxruntime-node@1.30.0` (linux-x64 binaries only, the other platforms pruned in the Dockerfile; about 35 MB of the package's 301 MB) + `@huggingface/tokenizers@0.2.0` (pure JS, 0.36 MB) + fp32 model 133 MB | +about 170 MB | Lazy model load (0.2–0.6 s) only on `/interest`. The paper pipeline's memory and code path are unchanged | Same image, deploy script, secret, egress guard and pg_cron/pg_net wake-up as `/podcast` | **Chosen** |
  | Python service or Cloud Run Job (numpy, scikit-learn, onnxruntime, tokenizers) | about +400 MB, separate image | Separate | New image, IAM, deploy script, and Cloud Scheduler or a token path for Jobs (pg_net cannot call the Jobs API) | Rejected. It would reuse the eval code, but scikit-learn's `CountVectorizer` builds the whole unpruned vocabulary in memory, which is too much at 100k papers on 2 GiB anyway |
  | transformers.js | Pulls `sharp` and `onnxruntime-web` | — | — | Rejected: unneeded dependencies |
- **Fingerprint version** `gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1`, recorded on every row and artifact:
  - Text recipe: `collapse_ws(title) + ". " + collapse_ws(abstract)`. Whitespace runs become one space and the ends
    are trimmed, as in `common._clean`.
  - Tokenization truncates at 512 tokens, with no prefix or prompt.
  - Mean pooling over the attention mask, then L2-normalised.
  - The model file's SHA-256 is checked at load. On a mismatch the worker refuses to embed (`interest_model_mismatch`).
  - The model is fetched at **build** time by `ADD --checksum=sha256:… https://huggingface.co/Xenova/gte-small/resolve/<commit>/onnx/model.onnx`.
    The running worker never downloads anything.
  - ONNX Runtime's built-in telemetry (on by default in 1.30) is switched off with `ORT_DISABLE_TELEMETRY=1` in the image,
    and the embedder refuses to load the runtime without it ([ONNX Runtime telemetry](#onnx-runtime-telemetry-closed-2026-10-24-worker-revision-gradstep-pipeline-00055-vzm)).

### Data

New table `app_private.interest_papers`. RLS is enabled with no policies, and it is reached only through
`security definer` functions (migration-092 pattern).

| Column | Notes |
|---|---|
| `source_id text primary key` | An arXiv id (new or old style) or `openalex:…`. Never `upload:%`. |
| `title`, `abstract`, `categories text[]` | Copied from `feed_papers` (pool) or the latest `catalog_metadata` row (catalog). Public CC0 metadata. |
| `pool_announced_on date` | Set for pool papers. Null for catalog-only papers. The map corpus is `pool_announced_on ≥ today − corpus_days`. |
| `in_catalog boolean` | The paper has a `catalog_metadata` row. Such rows are never pruned. |
| `text_sha256 bytea` | Digest of the exact embedded text. A revision or abstract change makes the row pending again. |
| `state` (`pending`, `embedded`, `failed`), `attempts`, `next_attempt_at` | Bounded retries: 3 attempts, then `failed` with a code. |
| `model_version text`, `fingerprint extensions.halfvec(384)`, `embedded_at`, `fp_seq bigint` | `fp_seq` comes from a sequence and orders publication into shards. The norm is checked to be within 1 ± 0.01. |
| `title_only boolean` | Abstract shorter than 50 characters. Embedded but kept out of the map and the term statistics. |
| `leaf_id bigint`, `leaf_map_version int` | The paper's leaf in the current published map. |
| `terms text[]`, `terms_version int` | Its top 5 terms (§3). |

**Which papers.**

- Every `app_private.feed_papers` row.
- Every catalog paper with public metadata: the latest `catalog_metadata` row per `source_id` that is not
  `upload:%`, has a title other than the `Uploaded PDF` placeholder, and has an abstract of at least 50 characters.
  Staging has 225 catalog rows, 224 of them with an abstract. Upload placeholders carry no abstract, so they are
  excluded twice over.
- Only metadata already in our tables is used. **No request goes to arXiv, DataCite, Hugging Face or anywhere else at
  run time.** The worker's egress guard stays on, and a test asserts the job makes no outbound request beyond
  Supabase.

**Backfill and incremental flow.**

1. `worker_interest_sync()` runs at the start of every `/interest` run. It is set-based SQL with anti-joins on
   `source_id` and `text_sha256`. It inserts or re-pends rows from the pool and the catalog. It prunes pool-only rows
   older than `corpus_days`; catalog rows are never pruned. Nothing touches the Feed's own upsert path.
2. The embed loop calls `worker_interest_embed_claim(64)` (lease-fenced), embeds the batch, and calls
   `worker_interest_embed_store(rows)`. That stores fingerprints, assigns each paper's leaf by descending the frozen
   map (§2), and stores its top terms (§3).
3. Once nothing is pending, or 30 minutes after the last shard, the newly embedded **pool** papers are published as one
   immutable shard (§4).
4. **Backfill:** 9,890 pool papers and 224 catalog papers take about 10,100 ÷ 3 ≈ 56 CPU-minutes. That is eight
   bounded runs, about 4 hours of wall time with a 10-minute gate. **Steady state:** 600–900 new pool papers per
   announcement day (measured: 595–835, with catch-up days of 1,359 and 2,192), about 4–5 minutes of CPU a day.

**Wake-up.** pg_cron job `science-reader-interest`, `*/10 * * * *`, calls `app_private.interest_kick()`, and a
statement trigger on `feed_papers` inserts calls it when the pool ingests papers (the incremental embedding hook). While
`interest_policy.enabled`, every call writes a heartbeat (`interest_state.last_tick_at`); it then posts `/interest`
through pg_net (the pipeline URL and secret from Vault, as `podcast_kick`) when no lease is live, it has not posted in
the last 2 minutes, and work is due: pending papers, pool papers not yet mirrored, a shard to publish, or a rebuild
due (below). A post that no run claims within 30 minutes, or no heartbeat for an hour, is an Attention item, so a dead
pg_cron, pg_net or worker shows up.

**Run limits.** One run per instance, in its own thread, under the worker's 840 s hard deadline, with a 780 s soft budget
(embedding stops claiming new batches 2 minutes in when a build is due; phrase embedding yields 150 s before the deadline).
The service stays at max 3 instances: `/interest` holds one of them
for at most about 13 minutes per run (780 s soft budget); rebuilds prefer the weekend morning window.

## 2. Topic map

### Build

- **Corpus:** fingerprints of pool papers inside the 180-day window that are not `title_only`. Rows are sorted by
  `source_id`, so a build is deterministic for a fixed seed.
- **Algorithm:** nested spherical k-means as in `topic_map.py`. There are 20 level-1 nodes, about size ÷ 150 level-2
  nodes per level-1 node, and about size ÷ 40 leaves per level-2 node. It is implemented in TypeScript (Lloyd's on unit
  vectors with normalised centroids, k-means++ with a seeded PRNG, `n_init` 4 for a cold build and 1 for a warm one,
  at most 50 iterations, empty clusters reseeded at the farthest point).
- **Canonical membership:** after convergence, each paper's membership is recomputed by descending the levels (nearest
  level-1 centroid, then the nearest level-2 node under it, then the nearest leaf). Devices use the same rule, so a
  paper's leaf is a pure function of its fingerprint and the map version.
- **Version 1** is a cold build. **Every later build is warm-started** from the previous version:
  - Level 1 keeps its 20 seeds, so the 20 IDs persist.
  - At levels 2 and 3, each previous node is re-homed under the new parent its centroid descends to, so a parent's
    split never renumbers its children.
  - Each previous node is one seed, except that a node whose current descent count is **≥ 2× its target** (300 or 80)
    contributes two seeds from a 2-means of its members, and a node **below ¼ of its target** (38 or 10) contributes
    none: its members merge into neighbours.
  - Uncovered regions get new seeds: papers whose cosine to every seed is below 0.80 seed new nodes.
- **ID rules.** `app_private.interest_nodes` holds the permanent, append-only identities: `id bigint` identity,
  `level`, `born_version`, `birth_centroid`, `retired_version`, `successors bigint[]`, `successor_shares real[]`.
  - A new node **keeps** the ID of the previous node that seeded it when membership Jaccard over the papers in both
    corpora is ≥ 0.5 and centroid cos is ≥ 0.9. After a split, the child with the higher Jaccard keeps it.
  - Any other new node gets a fresh ID. Any previous node not kept is **retired**, with successors: the nodes now
    holding its former members, with their shares.
  - **Drift cap:** a node whose centroid has moved more than 1 − cos 0.05 from its `birth_centroid` retires, and a
    fresh ID takes over with the retired one as its successor. An ID cannot slowly change meaning over months.
- **Per-version node data**, in `app_private.interest_node_versions`, keyed `(version, node_id)`: `parent_id`,
  `centroid halfvec(384)`, `size`, and c-TF-IDF `terms text[]` (6, computed as in `label_nodes`: 1–3-grams, document
  frequency ≥ 3 and ≤ 15 %, a √doc-share weighting, substring de-duplication). It also holds `central_source_ids` and
  `central_titles`: the 3 papers nearest the centroid, always pool papers, so they are public.
- **Name slot.** `interest_nodes` has `name text`, `name_source` (`llm` or `operator`), `named_version` and
  `named_centroid` columns. They stay null until November. Devices show the node's terms when there is no name.
  November's naming job will name nodes without a name, or whose centroid moved more than 0.03 from `named_centroid`,
  through the admitted OpenRouter path: about 3,200 nodes once (≈ $2 per the proposal), then about 60 a week. **No
  model is called in step 2.**
- **Versions.** `app_private.interest_map_versions` records `version`, `kind` (`cold`, `warm` or `reseed`),
  `model_version`, `corpus_papers`, `params jsonb`, `stats jsonb` (kept share per level, splits, merges, cohesion,
  durations) and `state` (`building`, `published`, `superseded` or `failed`). Publication of the map, the term
  statistics and their artifacts is **one transaction**. Node data for the last 4 published versions is kept; the
  permanent `interest_nodes` rows keep successor chains forever (about 60 new IDs a week).

### Daily: new papers join the frozen map

New papers descend to a leaf of the current published map. That increments the leaf's live count and running
fingerprint sum, used for the split and drift checks at the next rebuild. Nodes, centroids and IDs never change
between rebuilds.

### Rebuild cadence and how far the map can move (measured)

**Due-based, never a single missable slot** (migration 0153; lead's clarification 2026-10-24):

- **Due** once the published map is `rebuild_days` old: 14 days while the corpus is under 50,000 papers, then 7
  (`rebuild_days_growing`, `rebuild_days`, `weekly_after_papers`). The first map is due as soon as the backfill has
  nothing pending and the corpus has at least `min_corpus` papers.
- **Started** by the 10-minute kick in the preferred quiet window, weekend 06:00–10:00 UTC (`window_dows`,
  `window_start_hour`, `window_end_hour`; no announcements then). Once the map has been due for 24 hours
  (`overdue_hours`) it starts at the next tick whatever the day or hour. A window missed because the worker was down is
  caught by the next window or, at most, 24 hours after the due time; never two weeks later.
- **Failures back off**: a build that fails, is blocked by the stability gate, or is killed mid-build (its lease
  expires after `worker_interest_rebuild_mark`) retries after 10 minutes, then 1 hour, then every 6 hours, and a
  published build resets the count (`interest_state.rebuild_failures`, `rebuild_retry_at`). Two failures in a row are an
  Attention item. A build that is still embedding new phrases when its run ends is neither: the next run continues.
- **Stale map**: Attention when the map is older than `rebuild_days` + 2 days.

A build runs as one bounded run once the phrase vectors it needs are stored (phrase embedding resumes across runs); a
stale `building` version is abandoned by the next build and the published version keeps serving. The operator can
force one (`worker_interest_set_policy(null, null, true)`). A **reseed** (a cold build) happens only on a
fingerprint-model change or an explicit operator command; even then IDs map old→new by membership and get successors.

Measured on the 9.9k pool with the eval embeddings (scikit-learn k-means in a scratch script; Phase B repeats this as a
TypeScript rehearsal test):

| Scenario | Level-1 IDs kept | Level-2 kept | Leaves kept | Leaf cohesion (mean cos to centroid) |
|---|---|---|---|---|
| Cold rebuild, same data, different seed | 70 % | 34 % | **10 %** | — |
| Warm rebuild, same data | 100 % | 100 % | 100 % | — |
| Warm rebuild, 5 % of papers out and 5 % in (≈ one steady-state week of the 180-day window) | 100 % | 100 % | **98 %** | equal |
| Warm rebuild, 25 % out and 10 % in | 100 % | 94 % | 85 % | 0.920 vs 0.920 cold |
| Six successive warm weeks at 5 % turnover, against the first map | 100 % | 95 % | **82 %** | 0.926 vs 0.921 cold |
| Replay of the real pool's growth with split/merge (Oct 14 → 16 → 21 → 23: +33 %, +46 %, +14 %) | 100 % | — | **87 %, 68 %, 94 %** | within 0.003 of cold; leaf sizes 12–97, median 48–53 |

What this means:

- **At steady state** about 2 % of leaf IDs change a week.
- **During the first months** the pool is still growing, by 15–45 % a week, and leaves double and split, so 6–30 % of
  leaf IDs change per rebuild. Every retired ID names its successors, so a reader's named or hidden topics follow
  (step 3).
- **Level-1 IDs** stay in every measured case. They change only at a reseed or if the drift cap trips.
- **Median centroid movement per rebuild** is 1 − cos 0.0005–0.002, against the 0.05 drift cap.
- **Gates:** a rebuild that keeps fewer than 85 % of leaves raises an Attention item, and one below 50 % is **not
  published** unless the operator approves (both checked against the previous version).

## 3. Term statistics for devices

**Vocabulary and statistics** follow `terms.py`:

- The text counts the title twice, then the abstract.
- Token pattern `(?u)\b[a-zA-Z][a-zA-Z0-9\-]+\b`, lowercase.
- Stop words are scikit-learn's English list plus `DOMAIN_STOP`, removed **before** n-grams are formed (scikit-learn
  semantics).
- 1–3-grams whose document frequency is at least 3 and at most 10 % of the corpus, over the same pool corpus as the map.
- **Conceptness** = cos(phrase, normalised mean of the fingerprints of the papers that use it) − cos(phrase, corpus
  mean). Terms of art pass at ≥ 0.02.

**Measured on the 9.9k pool:**

- 57,133 phrases: 17,161 one-word, 37,093 two-word and 2,879 three-word. Median document frequency 4; 65 % of phrases
  have a frequency of at most 5.
- 17 % pass the concept filter (quantiles −0.041 / −0.019 / −0.002 / 0.013 / 0.039).
- Phrase embedding runs at 116 phrases/s on one loaded thread, so the whole vocabulary takes about 8 minutes once.
  After that, only new phrases are embedded.
- At 100k papers the vocabulary is extrapolated (Heaps' law, β ≈ 0.75) to about 250–350k phrases. Phase B measures it.

**Counting at scale (worker).** Two-pass typed-array hash counting with apriori pruning: unigrams first, then bigrams
whose words survive, then trigrams whose bigrams survive. Strings are kept only for n-grams that reach a document
frequency of 3. The estimated peak is under 600 MB at 100k papers. A TypeScript parity test against scikit-learn's
`CountVectorizer` on a fixture corpus pins the exact vocabulary and frequencies.

**Stored:** `app_private.interest_terms` (`term text primary key`, `ngram`, `df`, `conceptness real`, `emb_q8 bytea`,
`first_seen_version`). Embeddings are int8 with a per-vector scale (388 B): they are never used by SQL vector
operators, and this halves storage against halfvec. Phrases whose frequency falls below 3 are deleted at rebuild.
Storage is about 26 MB today and about 150 MB at 100k papers.

**Blob format** `gradstep-terms/1`: one gzip stream, so iOS Compression and the browser's `DecompressionStream` both
read it.

- Header: a length-prefixed JSON object with `version`, `map_version`, `model_version`, `corpus_papers` (N),
  `total_df` (Σ df, the background total that log-odds needs), the tokenizer spec (regex, lowercase, n-gram range,
  title weight 2, `min_df`, `max_df_share`), the **stop-word list itself**, the concept threshold, and the encoding of
  the fields below.
- Body: phrases sorted bytewise and front-coded (shared-prefix length, suffix, NUL), then document frequency as a
  varint, then conceptness as int8 (× 1000, clamped to ±127). Devices search the sorted, front-coded body directly
  (about 2–3 MB resident) instead of building a dictionary.
- **Size:** 0.56 MB raw and **0.30 MB gzipped** at 57k phrases (xz would save only 13 %); about **2 MB** at 100k papers.
- Phrase embeddings are **not** shipped: about 23 MB even for concept-passing phrases only. Devices re-rank their top
  candidates by closeness once their own gte-small exists (step 3); until then they rank by TF-IDF or log-odds behind
  the concept filter.
- Fixture texts with their expected n-grams ship in the repository for the Swift and browser tokenizer tests.

**Versioning.** The blob is rebuilt with each published map (weekly) and gets that map's version. Devices fetch a new
blob when theirs is more than 28 days old or the manifest says its format changed. Document frequencies move slowly;
the map moves weekly.

**Per-paper top-terms cache** (`interest_papers.terms`, top 5): for every embedded pool and catalog paper, the
`paper_terms` rule (TF-IDF on title and abstract, n-grams × 1.25, the top 40 re-ranked by closeness of
`interest_terms.emb_q8` to the paper's fingerprint, the concept filter, and de-duplication by substring and by
cos > 0.88). It is computed when a paper is embedded and recomputed for the 14-day window at each rebuild, about
10k papers in seconds. It is served with library fingerprints (§4) and later in `discover` results (step 4). Its
inputs are public, and the cache is per paper, never per reader.

## 4. Delivery to devices

### What a device downloads

| Artifact | Today (9.9k pool) | Steady state (about 100k corpus; 14-day window of about 8–10k papers) | Refresh |
|---|---|---|---|
| **Map** `gradstep-map/1`: per node `id`, `level`, `parent`, `size`, int8 centroid (388 B), 6 terms, 3 central titles and ids, `name` (null); retired IDs from the last 26 versions with successors and shares; gzip | about 340 nodes, ≈ 0.27 MB raw / **≈ 0.2 MB** gz | about 3,200 nodes, ≈ 2.6 MB raw / **≈ 1.6 MB** gz (centroids dominate) | Weekly |
| **Term statistics** `gradstep-terms/1` | **0.30 MB** gz | about **2 MB** gz | Weekly on the server; devices at most every 28 days |
| **Pool fingerprint shards** `gradstep-shard/1`: `source_id` plus int8 fingerprint (≈ 404 B per paper), papers in `fp_seq` order | **≈ 3.5–4 MB** for the whole 14-day window on first use | Same (bounded by the window); **≈ 300 KB per announcement day** | Daily, append-only |
| **Library fingerprints** through the RPC: int8, `leaf_id`, top terms (≈ 650 B per paper as JSON) | Owner's 62 papers ≈ 40 KB | 1,000 papers ≈ 0.65 MB once, then only additions | When public papers are added |

- **int8 on the wire.** Per-vector scale plus 384 int8 values. Against halfvec: min cos 0.99987, nearest-leaf
  agreement 99.91 %, top-10 neighbour agreement 97.4 % (measured on the pool). The library RPC also returns the
  server's `leaf_id`, so the device's own assignment is needed only for shard papers. A borderline disagreement on 0.1 %
  of candidates is harmless.
- **Per active device:** ≈ 4 MB on first use. About 16–22 MB a month at steady state (weekly map, monthly terms, daily
  shards). At 1,000 devices that is ≈ 20 GB a month of the plan's 250 GB of egress; at 20 devices, under 0.5 GB.
- **Device memory:** window fingerprints 4 MB, map about 2 MB, terms about 3 MB. Brute-force similarity over about
  10k × 384 int8 values is well under a millisecond per query with Accelerate (proposal: no ANN library).

### API surface

The surface is consistent with `discover`, `recommend` and `reader-artifact`: Edge functions for responses that are
not database RPCs, `v1_…` RPCs for authenticated reads, and `worker_…` RPCs for the service role. Every function is
`security definer`, with explicit grants as DATA_MODEL.md requires (revoke from public, anon and authenticated; grant
`v1_` to authenticated and `worker_` to service_role).

| Call | Who | Returns |
|---|---|---|
| `GET /functions/v1/interest-index` | Signed-in reader. Gate: `interest_policy.serving` `off`/`staff`/`all`, as `feed_serves`. Rate rule `interest-index` (manifest and artifacts alike): 240 per account an hour, 10,000 for the environment (0152 shipped 240 / 4,000; 0157 raises the environment limit for serving to `all`) | Manifest: `{format:1, model:{version, dim:384, text_recipe}, map:{version, built_at, artifact}, terms:{version, artifact}, shards:[{id, sha256, bytes, fp_seq_from, fp_seq_to, oldest_on, newest_on}], window_days:14}`, where `artifact = {id, sha256, bytes}`. `Cache-Control: private, max-age=600`. `404 interest_unavailable` when not served |
| `GET /functions/v1/interest-index?artifact=<id>` | Same | The artifact's bytes: `application/octet-stream`, `ETag` = SHA-256, `Cache-Control: private, max-age=31536000, immutable`. The device verifies the SHA-256 before use |
| `rpc v1_interest_library_fingerprints(p_source_ids text[] default null, p_after text default null, p_limit int default 500)` | Signed-in reader, same gate. Rate rule `interest-library`: 60 per account an hour, 5,000 for the environment (1,000 before 0157) | `{model_version, map_version, items:[{source_id, q8, leaf_id, terms, pending?}], next}`. **Only** papers that are visible in the caller's library (`library_query_entries`) or are the caller's in-flight imports, never `upload:%`. Other IDs in `p_source_ids` are silently omitted, so the call can never reveal whether a paper is in someone else's library. `pending: true` while not yet embedded |
| `worker_interest_*` | Service role (worker, cron) | `sync`, `embed_claim`, `embed_store`, `rebuild_claim`, corpus pages (fingerprints as base64 of `halfvec_send`, 2,000 rows a page), `stage_store`, `publish`, `shard_publish`, `status`, `kick`, `set_policy`, `request_rebuild` |

**Artifacts live in the database**, in `app_private.interest_artifacts` (`id uuid`, `kind` map/terms/shard, `version`,
`sha256 unique`, `bytes`, `content bytea` ≤ 16 MiB, `created_at`, `retired_at`). There is no Storage bucket:

- Publication is atomic with the map and term version it describes.
- No new bucket or storage policy is needed, and there are no orphaned objects.
- The existing encrypted database backups cover them.
- Sizes are small: at most about 10 MB a version, plus the window's shards.

Retention is the current version plus 2 previous versions of map and terms, and shards until their newest paper
leaves the 14-day window. If artifacts ever pass 16 MiB, they move to a private bucket behind the same manifest; the
clients would not change.

**Serving off by default.** The migration ships `enabled=false, serving='off'`. Phase B turns on `enabled` (backfill
and build), then sets `serving='staff'`. `all` waits for step 3's device layer and the privacy-notice line below. Both
are now done: the device layer shipped in TestFlight 92 and the owner approved the notice on 2026-10-25. The flip is
operator SQL, as `staff` was ([Serving to all](#serving-to-all-prepared-2026-10-25-not-run)).

## 5. Privacy

**Invariant:** the server never computes, stores or receives a reader's interest state: topics, weights, lifts,
chosen names, hidden flags, keywords or rankings. Step 3 syncs those only as an end-to-end encrypted blob (proposal,
under 100 KB).

Exception, For you (migration 0155, 2026-10-24; **accepted by the owner 2026-10-24**: "I see, a sounds fine then", after being told it sends nothing new: the server already holds the library list and the public titles and abstracts): the Feed's server ranking, which the owner accepted on 2026-10-08 over
server-visible library membership, also uses the public fingerprints of the reader's own library papers, per request,
under the same `interest_policy.serving` gate as this index. Nothing is stored and nothing from it is published
(PERSONALIZED_FEED.md "Similarity to the library"). Device-only signals stay on devices.

**What each piece reveals:**

| Device action | What the server learns | New? |
|---|---|---|
| Downloads the manifest, map, terms and shards | That the account uses the feature, and when. The bytes are identical for every reader | Only usage, the same class as `account_activity_days` route names |
| Calls `v1_interest_library_fingerprints()` with no arguments | Nothing beyond membership it already holds in plaintext (`library_query_entries`, accepted for the Feed 2026-10-08). The paper set is derived on the server, so the request carries no information | No |
| Calls it with `p_source_ids` (just-added papers) | Those IDs, which are already in its own library rows | No |
| Embeds an uploaded PDF or an end-to-end encrypted item | Nothing: on-device model (step 3) | — |

**How a device should get public fingerprints.** The three options:

1. **Bulk download of the pool (chosen for Feed candidates).** Every device fetches the same shards, which is perfect
   anonymity: the server cannot tell which candidates a device scores, ranks, opens or ignores. The cost is about
   4 MB once and 300 KB a day.
2. **Padded or k-anonymous fetch by ID (rejected).**
   - Decoys must come from a universe the device can name. Decoys from the pool add nothing, because the pool is
     already bulk.
   - Decoys or buckets from the catalog are worse than useless. The catalog is the union of readers' libraries, so a
     bucket response would hand each reader fingerprints, and therefore existence, of papers that **other readers**
     hold. In a 20-person beta that can identify a person.
   - For papers the server already knows are in the reader's library, padding protects nothing.
3. **Membership-derived library fetch (chosen for library papers).** The server returns only what it already knows
   the reader has, and refuses to act as an oracle for anything else.

**Leak-proof corpus.** Every artifact shared across accounts (map centroids, sizes, terms and central titles; term
statistics; shards) is a function of the **Feed pool alone**. The pool is public DataCite/arXiv CC0 metadata fetched
once for everyone. Catalog papers are embedded and assigned, but they never move a centroid, a size, a document
frequency or a central title, and they appear in no shared artifact. Tests assert this: adding a catalog-only paper
leaves every artifact byte-identical.

**Where library IDs are end-to-end encrypted:**

- Catalog assignments (LIBRARY_CATALOGS.md) and upload descriptors never leave the device, and nothing here needs
  them.
- If a future mode hides membership from the server, those papers take the device-embedding path, and the RPC simply
  has nothing to return for them.

**Deletion.** There are no per-account rows in any new table. Account deletion is unchanged; the rate windows and
activity days are already covered.

**Privacy notice, approved by the owner on 2026-10-25** ("2 and 3 sure", with serving to `all`; it was the draft for
"when serving goes to `all`"): "To find your topics, your devices download a public map of recent
arXiv research from our servers, the same file for everyone. Your topics are worked out on your devices; our servers
don't receive them. For you also ranks new papers by how close they are to the arXiv papers in your library, using their
public titles and abstracts; nothing from that comparison is kept."

Where it appears, word for word:

- **gradstep.ai/privacy** (`web/site/privacy/index.html`): a "Topics and For you" section after Papers. The Papers
  paragraph's library sentence now ends "used for synchronization and to rank the Feed's For you list", so that "For
  you also" follows from it.
- **The redesign draft** (`web/site-next/privacy/index.html`): Your library, after its For you sentence. That sentence
  said For you is ranked "without an AI model"; it now says "without sending it to an AI provider", because the
  fingerprints come from gte-small.
- **Settings › Privacy & data**: a "Topics and For you" section in the apps (`PrivacyView`, RootView.swift) and the
  browser (`PrivacyData.tsx`, `privacy-topics`).
- The Library topics ⓘ already says topics are "worked out on this device from its arXiv papers and a public map of
  recent research"; it is unchanged.

## 6. Cost and operations

### Cost (list prices: Cloud Run request billing tier 1, us-west1; Supabase Pro allowances as in PERSONALIZED_FEED.md)

| Line (per month) | Basis | Expected |
|---|---|---|
| Cloud Run CPU and memory, `/interest` | Daily embedding ≈ 22 days × 300 s, plus weekly rebuild ≈ 4.3 × 600 s, plus phrase embedding ≈ 500 s ≈ **10,000 vCPU-s and 20,000 GiB-s**. At $0.000024/vCPU-s and $0.0000025/GiB-s that is ≈ $0.29 before the free tier (180k vCPU-s and 360k GiB-s per billing account; the pipeline uses about 31k vCPU-s) | **$0–0.30** |
| Backfill, once | ≈ 3,400 vCPU-s plus vocabulary embedding ≈ 500 vCPU-s | **≈ $0.11** (≈ $0 inside the free tier) |
| Cloud Run requests | ≤ 150 posts a day (10-minute gate, posts only with work) | $0 |
| Artifact Registry | +≈ 170 MB per retained image version; above the 0.5 GB free tier, $0.10/GB-month | **$0.02–0.17**, depending on how many versions are kept |
| Supabase database storage | ≈ 55 MB now; ≈ 430 MB at steady state (papers 250 MB, terms 150 MB, nodes and artifacts about 30 MB), within the plan's 8 GB | $0 (database is 141 MB today) |
| Supabase egress | ≈ 20 GB at 1,000 devices, < 0.5 GB at 20; plus worker reads ≈ 0.4 GB per rebuild (≈ 1.7 GB a month) | $0 within 250 GB |
| Edge invocations | ≈ 2–5 per device a day; 1,000 devices ≈ 150k of the plan's 2M | $0 |
| Provider (AI) | No model call | **$0** |
| **Total** | **Fixed $0; usage ≈ $0.05–0.50 a month**, no change to the $100 budget | |

**Record per PROVIDER_SPENDING.md and OPERATIONS_AND_BILLING.md:**

- There is no provider attempt to admit, no reservation, and nothing to reconcile.
- Phase B adds a row to "Fixed commitments and observed usage": the interest index, Cloud Run usage in the existing
  worker, $0 fixed, the forecast above. It records measured CPU seconds from run logs after the first full week.
- November's naming is a separate approval: about $2 once through admitted OpenRouter calls under the provider limit,
  then about $0.05 a week.

### Admin health (ADMIN_HEALTH.md)

`app_private.interest_health()` joins `admin_health_extra()` as `interest_index`, read through `v1_admin_health`
(owner with MFA). The Health tab gets a small "Interest index" card and Attention items. Run history goes in
`app_private.interest_runs` (`kind` embed/rebuild/shard, times, `state`, `counts jsonb`, `error_code`), kept 90 days.

| Shown | Attention when |
|---|---|
| Corpus: pool papers in the window, embedded, pending, failed, oldest pending age; catalog papers embedded and pending | ≥ 50 papers pending for more than 24 h; more than 1 % failed in 24 h |
| Embedding: last run, papers per run, papers/s, model version, and the model SHA-256 the worker reports in `GET /health` | Model mismatch (worker refuses to embed) |
| Map: version, age, nodes per level, leaf sizes (minimum, median, maximum), last rebuild's kept share per level, splits, merges, cohesion | Map older than 9 days; rebuild failed twice; leaves kept < 85 % (warning) or < 50 % (blocked, awaiting the operator) |
| Terms: version, vocabulary size, concept-pass share | Size cap reached (500k phrases) |
| Artifacts: current map, terms and window shard sizes | Any artifact over 16 MiB (not published) |
| Delivery: manifest calls and distinct accounts over 24 h and 30 d (aggregates from rate windows only) | — |

There is also a free, read-only workflow check, `interest.health` (`scripts/workflow-checks.mjs`). It mirrors the
Attention rules, and a second check, `interest.manifest`, has a synthetic account fetch the manifest and one shard and
verify the SHA-256.

### Failure modes

| Failure | Effect | Handling |
|---|---|---|
| Model file missing or wrong checksum; tokenizer padding re-enabled | Wrong fingerprints | Load-time SHA-256 check; parity test against reference vectors; padding asserted off; `/health` reports the model hash and deploy verification compares it |
| Embedding slower than planned | Backlog | Runs are bounded and the backlog waits. The Feed and Recommendations do not depend on this, and Attention fires after 24 h |
| Worker killed mid-run | Partial batch | Lease fencing on claims; a stale lease expires; stores are idempotent by `(source_id, text_sha256)` |
| Rebuild stage times out or crashes | No new map | Staged and resumable; a `building` version expires after 24 h; the previous version keeps serving |
| Degenerate k-means (empty clusters, a tiny corpus) | Bad nodes | Reseed at the farthest point; minimum sizes; a cold build needs ≥ 2,000 corpus papers |
| Large ID churn | Readers' topics remapped | Stability gates (85 % warning, 50 % block); successors always recorded |
| Pool refresh off or DataCite outage | No new papers | The map ages and serving continues; Attention at 9 days |
| Artifact too large or corrupt | Devices cannot use it | Size cap before publish; SHA-256 in the manifest; devices keep their last good version |
| Device on an old map version | Old IDs | Successor chains in the map (26 versions) and permanent in `interest_nodes`; the interest state can be recomputed from library plus map |
| Corpus or vocabulary growth beyond plan | Storage and CPU | Policy caps: `corpus_days` 180, at most 150k corpus rows, at most 500k phrases; Attention |
| pgvector unavailable locally for tests | Migration fails locally | Phase B prerequisite: a Science Reader-owned PostgreSQL 17 + pgvector toolchain under `SCIENCE_READER_PG_BIN`. Staging runs PostgreSQL 17.11 with pgvector 0.8.2 available; the current portable 18.4 build has no pgvector. TextBrain's tool folder is not modified |
| Instance contention (max 3) | Imports wait about a minute | `/interest` soft budget of 300 to 480 s; rebuilds prefer the weekend 06:00–10:00 UTC window |

### Tests (Phase B)

Fast tier (`npm test`):

- **Tokenizer:** gte-small token IDs match Hugging Face `tokenizers` exactly on fixtures, and padding is off.
- **Text recipe and pooling:** mean pooling with the attention mask, L2 norm, int8 and halfvec codecs and their error
  bounds.
- **Spherical k-means:** seeded determinism; empty-cluster reseed; descent membership.
- **Warm start:** ID keep, split, merge and the drift cap on synthetic clusters; successor shares; the stability gate.
- **n-gram counting:** identical to scikit-learn `CountVectorizer` (vocabulary and frequencies) on a committed
  fixture, generated once by Python.
- **Terms:** c-TF-IDF node terms, conceptness, `paper_terms` and the log-odds totals match `terms.py` and
  `topic_map.py` on the fixture.
- **Artifact codecs:** round trips for front-coding, varints, int8 and gzip; golden files for the Swift and browser
  decoders.
- **`interest-index` Edge function:** auth, serving gate, rate limit, manifest shape, immutable caching and ETag, 404s.
- **Worker:** the `/interest` route (secret, maintenance, busy, hard deadline) and **no outbound request** other than
  Supabase.

Database (`scripts/test-database.py --interest-only`, new `tests/database/interest_index.sql`):

- Extension and `halfvec(384)` dimension; RLS and grants; the `default_privileges` check.
- Sync rules: pool, catalog, `upload:%` excluded, placeholder excluded, re-pend on a text change, pruning keeps
  catalog rows.
- Lease fencing; idempotent stores; norm check; model-version check.
- Atomic publish; ID tables; the successor and stability gate.
- **Library RPC:** only the caller's own library papers; other accounts' papers and catalog-only IDs are omitted (no
  oracle); uploads never; paging; the serving gate.
- **Leak-proof corpus:** a catalog-only paper leaves every artifact's SHA-256 unchanged.
- Admin health block and Attention; account deletion unaffected.
- `tests/database/interest_concurrency.py`: two workers claiming and publishing at once.

Slow, opt-in (`docs/TESTING.md`):

- Model parity: the fp32 ONNX model (checksum-verified, cached outside the repository) reproduces 20 reference vectors
  with cos ≥ 0.9999.
- Rebuild rehearsal on the eval corpus: the TypeScript map against `topic_map.py`'s cohesion (within 0.005), and the
  replay of warm rebuilds reproducing the stability table above.
- On staging after deployment: `interest.health` and `interest.manifest`.

## Phase B as built (staging, 2026-10-24)

**Deployed (staging, 2026-10-24 UTC).**

- Migrations `202610240152_interest_index.sql` (about 14:45 UTC) and `202610240153_interest_due_rebuild.sql` (about 15:16 UTC), each after
  an encrypted backup (`.artifacts/backups/20261024T143919Z-46df24ca16bc`, `20261024T151459Z-be593323ef99`).
  pgvector 0.8.2 is enabled in `extensions`.
- Edge function `interest-index` (in `infra/staging.json`, `verify_jwt = false`, auth in the handler).
- Worker revisions `gradstep-pipeline-00053-6rf`, then `00054-m9n` (commit `63602b24`). Both were built with Cloud Build
  (`deploy-pipeline-worker.py deploy --remote-build`, new) because the local Colima Docker VM hit I/O errors with the
  Mac's disk full. The image fetches the model by checksum at build time.
- Policy `enabled=true`, `serving='staff'`.

**Measured on staging.**

| What | Result |
|---|---|
| Backfill | 9,970 papers embedded: 9,890 pool + 80 catalog-only, 0 failed, 0 failed runs. Five runs from 14:59 to 16:29 UTC |
| Embedding speed (Cloud Run, 1 vCPU, fp32, including RPCs) | ≈ 2.8 papers/s (2,208 per 780 s run). Runs start about 20 minutes apart (lease plus the 10-minute kick) |
| First map (version 1, cold) | One run of 287 s: 56,972 phrases embedded (≈ 230/s), k-means, terms, artifacts. 20 / 68 / 246 nodes; leaf cohesion 0.9214 (scikit-learn cold build on the same pool: 0.9222) |
| Term statistics | 56,972 phrases, 10,387–10,691 passing the concept filter (18 %); the artifact is 285 KB |
| Map artifact | 143 KB (334 nodes) |
| Shards | 3 shards, 8,230 papers in the 14-day window, 2.6 MB |
| Database | 81 MB for the interest tables (estimate was ≈ 55 MB; term vectors and TOASTed text are larger than estimated) |
| Cloud Run usage, backfill plus first build | 3,965 instance-seconds ≈ 3,965 vCPU-s and 7,930 GiB-s ≈ $0.12 at list price, inside the free tier |
| Provider (AI) spend | $0 |

Example leaves (c-TF-IDF terms): "reasoning · cot · chain-of-thought · answer" (91 papers), "regret · bandits · bounds ·
sqrt", "agents · execution · agentic · tool", "inverse · posterior · sampling · diffusion". The phrases with the highest
conceptness include "quantum machine learning", "radiology reports", "backdoor attacks" and "quadrotor".

**End-to-end delivery check** (two synthetic `@example.invalid` accounts with the tester role, deleted afterwards
through `account-delete`; script in the session scratchpad):

- Before the role: the manifest answered 404 and the RPC `interest_unavailable`. With it, the manifest answered 200
  (`private, max-age=600`; map version 1, 3 shards, the model block).
- Every artifact downloaded with its SHA-256 matching the manifest and its ETag. `If-None-Match` answered 304. Each
  decoded: map 20 / 68 / 246 nodes with centroids, terms 56,972 phrases, shards 8,230 papers.
- Account A (1706.03762 from the catalog and one pool paper) received exactly its two papers: q8 fingerprints, leaves
  and top terms. For 1706.03762 the terms were "translation, encoder decoder, attention mechanisms, convolutional neural
  networks, transformer". Account B received only 2305.18290.
- When A asked for B's paper, a catalog-only paper and its own, it got only its own paper (no oracle).
- Anonymous RPC: 401. The `app_private` tables are not exposed (406).
- Workflow checks: `interest.health` and `config.edge-functions` (19 active) pass. `budget.health` fails on the existing
  83 % of October's $40, which this work does not change.

**Local evidence.**

- `npm test` passes in full.
- `scripts/test-database.py --interest-only` passes on PostgreSQL 17 + pgvector: migrations through 0153,
  `default_privileges`, `interest_index.sql` and `interest_rebuild_due.sql`.
- The slow embedder parity test (`tests/interest/embed-parity.test.ts`) passed with the fp32 model: 20 reference vectors
  at cos ≥ 0.9999, and padding in a batch changes nothing.
- A local end-to-end run (real migrations and `job.ts` over psql, 3,000 pool papers) covered backfill, a cold build, an
  incremental batch with leaves and terms, and a forced warm rebuild: leaf IDs kept 98.6 %, only new phrases embedded.

**Differences from the design.**

- Term statistics live only in the terms artifact (the worker reads it back); there is no `interest_terms` table.
  Phrase embeddings are kept in `interest_term_vectors` (int8).
- The pool-ingest hook is a statement trigger on `feed_papers` that calls the debounced `interest_kick`.
- The tokenizer is a dependency-free WordPiece implementation, equal to Hugging Face on all 81 fixtures, so there is no
  `@huggingface/tokenizers`.
- `/health` is unchanged; the readiness tooling compares it exactly.

**Known limits and follow-ups.**

- ONNX Runtime telemetry: closed 2026-10-24; see "ONNX Runtime telemetry" below.
- Backfill throughput is bounded by the 20-minute run spacing. A self-kick at release would roughly halve a future
  full re-embedding; it is not needed for the daily ≈ 750 papers.
- The admin Health card is built and type-checks, but the admin site was not redeployed (the database side, including
  Attention items, is live through `v1_admin_health`).
- The first client (Related papers in the app, 2026-10-24) reads the manifest and shards; step 3 adds the map and terms. The privacy line in §5 was approved by the owner on 2026-10-25.

## ONNX Runtime telemetry (closed 2026-10-24; worker revision `gradstep-pipeline-00055-vzm`)

Rule: servers make no unexpected outbound connections.

**Source.** The warning comes from ONNX Runtime's own native core, not from the tokenizer (the worker uses its own
WordPiece; `@huggingface/tokenizers` is not installed).

- ONNX Runtime 1.30.0 (`onnxruntime-node@1.30.0`, upstream tag `v1.30.0`, commit `f2c39fe2`) ships Microsoft's 1DS
  telemetry in its official POSIX builds: `onnxruntime/core/platform/posix/telemetry.cc`.
- It is **on by default** (`PosixTelemetry::enabled_{true}`).
- When the runtime environment initializes, it:
  - creates a 1DS log manager posting to `https://mobile.events.data.microsoft.com/OneCollector/1.0`;
  - persists a device id and an event cache under `$HOME/.cache/Microsoft/DeveloperTools/.onnxruntime/`
    (`deviceid`, `onnxruntime.db`);
  - queues events: process info (ORT version, OS, CPU model, memory, hashed device id), session creation (model
    producer, file and graph names, model hashes), load, run counts, and errors. No input text or embeddings.
- With no CA bundle the uploader cannot complete TLS. Its own warning is that log line.

**Switch.** `onnxruntime-node` exposes no telemetry API (only `env.logLevel`). The supported opt-out is the
environment variable `ORT_DISABLE_TELEMETRY` (`telemetry_environment.h`: "1", "true", "yes", "on" or "y"). It is latched
when the runtime initializes: no uploader is created, no event is logged and no device id is written.

- The image now sets `ENV ORT_DISABLE_TELEMETRY=1`.
- `interest-embed.ts` refuses to load the runtime without it (`interest_telemetry_enabled`), checked in
  `tests/backend/interest-telemetry.test.ts`.
- The Dockerfile line is asserted by `tests/operations/test_pipeline_deployment.py`.

**Proof** (local Colima VM, amd64 images from Cloud Build). A capture container shared each probe's network namespace
(`tcpdump -i any`). DNS pointed at 127.0.0.1, so lookups are visible but no name can reach a resolver. Evidence is under
the worktree's `.artifacts/interest-network-check/`.

| Image and condition | DNS / TCP | ORT device-id directory |
|---|---|---|
| Deployed revision 00054, as deployed (no CA bundle, no opt-out) | Repeated `A?`/`AAAA? mobile.events.data.microsoft.com` lookups (from 10 s after load, again a minute later); log line "No readable CA bundle…" | Created (`deviceid`, `onnxruntime.db*`) |
| The same with a CA bundle added ("if certificates were present") | The same lookups; with real DNS it would connect and upload | Created |
| Opt-out image (`ORT_DISABLE_TELEMETRY=1`), CA bundle present | **None** (no DNS, no TCP) over 75 s | Not created |
| Opt-out image with the variable cleared | The embedder refuses (`interest_telemetry_enabled`); the runtime never loads | — |
| Opt-out image: a full `/interest` run against staging with real DNS (claim, sync, embed 3 papers, release) | DNS only `coxhjvqpflgxkleydati.supabase.co`; TCP only to its two addresses (104.18.38.10:443, 172.64.149.246:443) | — |

On Cloud Run, revision 00055 loaded the model and embedded 3 re-pended papers at 17:08 UTC without the warning that
00053/00054 logged at every model load.

**What happened before the fix.**

- Revisions 00053 and 00054 (14:58–17:07 UTC, about 7 runs) looked up Microsoft's collector. On Cloud Run the lookups
  resolve, so they probably opened TCP and TLS toward it.
- With no CA bundle, TLS verification fails before HTTP, so no event payload could be sent. The device-id files lived in
  each instance's ephemeral filesystem and are gone.
- Separately, my local measurements on the owner's Mac (Python `onnxruntime` 1.31 at 06:25 and the Node parity test at
  07:34 PDT) ran with the same telemetry on and a system CA bundle, so they probably sent ORT's events. Those events hold
  library, OS and CPU facts, a hashed device id and gte-small's file name and hashes, never paper text.
- I deleted the state they left (`~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime`). The slow parity
  test now sets the opt-out itself.

## Device client (built 2026-10-24; first used by the Feed's Related papers)

`apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/Interest/` (tests in `InterestIndexClientTests`,
`RelatedPapersTests`; opt-in real-shard measurement `RelatedPapersMeasurementTests` with `INTEREST_MEASURE_DIR`):

- `InterestIndexClient` (actor): the manifest through an `InterestIndexTransport` (the app's `BackendClient` with the
  reader's session; `404 interest_unavailable` → `notServed`), kept for `max-age` 600 s in memory and on disk
  (`Caches/interest-index/manifest.json`). Each artifact is fetched once by `?artifact=<id>`, checked against the
  manifest's SHA-256 and size before use or storage, kept as `<sha256>.gsi`, and removed when the manifest no longer
  lists it. A damaged file on disk is fetched again; bytes that don't match are refused (`integrity`). When the server
  can't be reached, a kept manifest whose artifacts are all on disk still answers. `notServed` deletes the folder.
  Manifest bounds: format 1, 384 dimensions, lower-case hex digests, 1 B–16 MiB per artifact, at most 400 shards.
- `InterestArtifact` reads the `GSI1` gzip container (zlib, CRC checked, inflated size capped at 96 MiB);
  `InterestShard` its shard body; `InterestQ8` decodes q8 to floats (normalised). The format test reads a fixture made
  by the server's own `codec.ts` (`Fixtures/interest-shard-v1.gsi`).
- `InterestPool`: the window's shards as one contiguous normalised matrix (8,230 × 384 floats ≈ 12.6 MB); a paper
  listed twice keeps its later fingerprint; versions are stripped from IDs. `similarities(to:)` is one `vDSP_mmul`.
- Step 3 (below) decodes the map and term statistics and calls `v1_interest_library_fingerprints`.
- Measured on staging (one synthetic tester account, deleted afterwards): manifest 1,310 B in 0.30–0.46 s; three
  shards, 2,614,388 B for 8,230 papers, in 2.0–2.6 s sequentially from the Mac; decode 20 ms and nearest over the window 0.38 ms per
  paper (release build, M1 Max; debug 0.87 s and 2.6 ms).
- Privacy: unchanged from §5. The device downloads the same bytes as everyone; which paper it ranks stays on it.

## Device layer (step 3; built 2026-10-25, app local, not released)

The reader's topics, labels, keywords and Library chart, on the device; the reader's choices sync end to end encrypted.
Agent decisions (reversible) are in [DECISIONS.md](../DECISIONS.md#library-topics-on-the-device-interest-index-step-3-2026-10-25-agent-decisions-reversible).

| Piece | Code (`apps/apple/`) |
|---|---|
| Map (`gradstep-map/1`): nodes, q8 centroids, retired IDs and successors; canonical descent; `live(id)` follows successors | `ScienceReaderCore/…/Interest/InterestMap.swift` |
| Term statistics (`gradstep-terms/1`) and the scikit-learn tokenizer (`InterestPhrases`) | `…/Interest/InterestTerms.swift` |
| Interest state (per node: count, mass, Σ weight × fingerprint) and weights | `…/Interest/InterestState.swift` |
| Topic rule (step 2 + hysteresis) | `…/Interest/InterestTopics.swift` |
| Labels and per-paper keywords | `…/Interest/InterestLabels.swift` |
| Registry (sync records and merge) | `…/Interest/InterestRegistry.swift` |
| Library model (inputs → state → topics → slices) | `…/Interest/InterestLibrary.swift` |
| App service (artifacts, library fingerprints, engine actor, keyword store) | `ScienceReader/Services/LibraryInterest.swift` |
| When to recompute, inputs, encrypted writes, the reader's actions, UI fixture | `ScienceReader/ReaderModel+Interest.swift` |
| Library › All chart | `ScienceReader/Views/LibraryTopicsChart.swift` |
| Offline reference and fixtures | `tools/interest-eval/device_fixtures.py`, `fetch_device_inputs.py` |

### Inputs

- **Map and term statistics**: the manifest's `map` and `terms` artifacts through `InterestIndexClient` (shared with
  Related papers; kept by SHA-256), decoded once per version off the main actor. Terms are searched in place (sorted
  phrases, binary search; 57k phrases today); no dictionary is built.
- **Library fingerprints**: `v1_interest_library_fingerprints` with no arguments (the server derives the papers from
  membership), pages of 500, on the first load and whenever the map or terms change; afterwards only papers the
  device has no fingerprint for, by `p_source_ids` (≤ 500), each asked again at most every 10 minutes while
  `pending`. The server's `leaf_id` is used when its `map_version` matches the map; otherwise the device descends the
  map (agreement on the fixture: ≥ 37 of 38 papers, test). Fingerprints are kept in memory for the session, not on disk.
- **Which papers**: every library paper except the sample, in every catalog, archived ones at half weight. A paper's
  key is its public identifier without version.
- **Weights** (owner decisions 2026-10-24): `(archived ? 0.5 : 1) × (0.4 + 0.6 e^(−age/120 d)) × (own tags ? 1.5 : 1) ×
  (1 + 0.0625 × reading level + 0.25 if it has snippets + 0.25 if it has chats)`. Ages count whole UTC days, so devices
  agree on the same day. Reading level 0–4 from this device's progress (10 / 35 / 60 / 90 %) and the deepest level any of
  the reader's devices shared (registry); snippets and chats come from the synced notes and chats.
- **Uploaded and device PDFs are not in topics yet.** They have no public fingerprint, and an on-device gte-small is
  not practical in this step: the fp32 model is 133 MB (fp16 Core ML ≈ 67 MB; int8 34 MB moves 8 % of top-10
  neighbours, which the server rejected), it needs a WordPiece port with parity tests, and the owner has just moved the
  PDF models out of the app because of size. The chart's ⓘ says how many uploads are left out. A later option is the
  same model as an On-Demand Resource next to the PDF models, embedding title + first page on the device.

### State and topics

- `InterestState`: weights in 1/4096 and fingerprint components in 1/32768 as integers, so per-node sums are exact:
  add/remove is the exact inverse and the state is independent of arrival order (tests). Lift = the node's share of the
  reader's weighted mass ÷ its share of the map's pool papers (`size` ÷ Σ level-1 sizes).
- `InterestTopicRule` ports `topic_rule2.py`: deepest level first, nodes by lift; a node becomes a topic with ≥ 3
  unclaimed papers; leftovers rise; a level-1 node keeps its rest only with enough left; an outside paper folds into the
  topic of its nearest paper at cos ≥ 0.86; "emerging" = 2 outside papers in a leaf with lift ≥ 8. **Hysteresis**: a
  topic that is already shown keeps with 2 papers and leaves at 1. "Already shown" is the registry's synced `shown`
  register, so every device decides the same from the same inputs.
- **Parity with step 2**: on the owner's 62 papers over step 2's offline map the Swift rule reproduces step 2's 14
  topics exactly (nodes, papers, folded counts, shares to 1e-4, Other and its groups; anonymised fixture
  `interest-step2-topics.json`).
- On the published staging map (version 1), the owner's 62 papers give 15 topics and Other 11 % (7 papers); first
  computation 468 ms, again 41 ms (debug build, M1 Max; opt-in `InterestLibraryMeasurementTests`).

### Labels and keywords (until the map is named in November)

- **Topic label**: weighted log-odds with an informative Dirichlet prior (a0 = 1000) of the phrases the topic's papers
  use in their title (twice) and abstract against the pool's document frequencies; candidates shared by ≥ 2 papers
  (≥ 40 % above 4 papers); the top 60 re-ranked by `z/z_max + 2 (closeness − mean)`; behind the concept filter
  (conceptness ≥ 0.02); its 1–3 best terms, title-cased with usual acronyms, while the label stays ≤ 44 characters.
  Never a generic area or broad subject (vocabulary areas, `TagVocabulary.generic`, "attention", "regression"…).
- **No phrase embeddings on the device**, so "closeness" uses a stand-in: a phrase is the weighted centroid of the
  reader's papers that use it. Measured additions that made labels readable: +1 for a phrase the server's own per-paper
  terms chose (KeyBERT with real phrase embeddings, returned with the fingerprints), +0.5 for a two- or three-word phrase,
  single words in more than 2 % of the pool never label a topic, and one phrase labels one topic only (largest first).
  Without a usable phrase the map node's own terms label it.
- **Per-paper keywords**: sublinear TF-IDF (IDF from the pool) over the title twice, the abstract and, when the paper
  was read on this device, its full text from the encrypted full-text index (`FullTextSnapshot.bodyText`; the index's
  own postings are stemmed single words, which the pool's phrase statistics can't use), n-grams × 1.25, the top 40
  re-ranked by closeness to the paper (the same stand-in, plus the server's terms), behind the concept filter; five,
  in sentence case. Shown wherever the Library shows a paper's keywords (`LibraryTags`: table Tags column and chips,
  rows, the reader's header, filters), first four of them then two vocabulary names, unless the reader set their own
  tags. Computed at utility priority, cached per paper and recomputed only when its text changes (≈ 14 ms a paper for
  title and abstract, debug).
- Python reference of every device rule: `tools/interest-eval/device_fixtures.py`; the Swift port matches it exactly on
  a public 38-paper fixture (topics, shares to 1e-12, labels, keywords).

### Sync (end-to-end encrypted, no server change)

- Records are ordinary `PrivateEvent`s of kind `note`, entity `6f1e2d3c-4b5a-4968-8778-a69584736251`, no parents, `text`
  = compact JSON `{format: "gradstep-interest-v1", batch, device, topics[], shown[], reading[]}`:
  `topics` = `{id, e, n, h, c}` (map node, epoch, the reader's name or null, hidden, colour slot or null), `shown` =
  `{id, e, on}`, `reading` = `{p, e, l}` (paper key, epoch, level 0–4). Sealed and uploaded through the existing
  journal, outbox and `v2_*` sync as format-1 envelopes; the server stores ciphertext only.
- **Merge**: last writer wins per topic ID (user state and shown flag separately) and per (paper, device) for reading,
  ordered by (epoch, device, batch); an epoch is one more than the greatest the device has seen (Lamport). A paper's
  level is the maximum over devices. Old topic IDs follow the map's successors. The same records in any order give the
  same registry (tests).
- **Compatibility**: the Notes reducer, the catalog reducer, older builds and the browser ignore it (a `note` payload
  that isn't theirs; tested both ways in Swift; the browser's reducers filter by entity and by `gradstep-notes-`).
  Records of a later format are counted, never dropped.
- **Size and growth**: one record ≤ 64 KB of JSON; 200 renamed topics + 200 shown flags + 1,000 reading levels split
  into 3 records, the largest 44,022 B encrypted (test; under 100 KB). Writes: names, colours and hidden on the
  reader's action; shown flags only from a fully loaded library with every fingerprint present, at most once a minute;
  reading levels only when they increased, at most every 6 hours. A level only rises (5 steps), so a paper adds at most
  four reading entries per device ever.
- Never sent in plaintext (§5 invariant holds): topics, labels, weights, lifts, keywords and names stay on the device
  or inside sealed events.

### Library chart (owner decision 4)

Under the filter chips of Library › All (List and Table; not while searching or on another quick filter, so the chips
never move): a header row "Topics N" with the chosen topic as a ✕ chip, ⓘ and a chevron; opened, a 104 pt thin ring
(inner radius 72 %, 1 pt gaps) with the papers in topics in its centre and a legend (swatch, label, papers · share; two
columns on regular width). Up to eight largest topics are coloured by size from the chart palette (slots 1–8, validated
for adjacent segments on white and black) or by the reader's colour; the rest and the papers outside every topic are a
neutral Other whose row opens the smaller topics, "Outside topics" and hidden topics. A slice or row filters the list
to that topic (`ReaderModel.libraryTopicFilter`); again, or the chip, shows everything. Touch and hold: Rename…,
Colour, Hide topic (Show topic under Other). Collapsed or open is remembered (`library.topics.collapsed`). Identifiers
`library.topics.*`. UI fixture: `INTEREST_FIXTURE_DIR` = the Core fixtures folder.

### Seam for step 4 (For you in topic sections)

`InterestLibraryModel` (inside `LibraryInterest.engine`) holds the state; `InterestTopicSelection.topics` give node IDs
and papers and `centroid(of:)` the section anchor; `InterestPool` gives the window's candidates. Step 4 adds a ranking
over those and a Feed presentation; nothing in step 3 needs to change.

### Tests

- `InterestTopicsTests` (Swift Testing): step-2 parity; exact, order-independent state updates; weights; the published
  map's decode and descent; successors; term statistics and the tokenizer against scikit-learn (`ngrams.json`); the
  public library against the Python reference; hysteresis; label casing.
- `InterestRegistryTests`: last writer wins in any order; registers; successors; other reducers ignore records and
  vice versa; validation; encrypted size.
- `InterestLibraryMeasurementTests` (opt-in, `INTEREST_DEVICE_DIR`): a real library on the published artifacts.
- UI: `LibraryTopicsTests` (collapse remembered, legend row and slice filter, Table, rename and hide).

### Open

- Labels on broad level-1 "rest" topics are still weak ("Graph, Learned", "Answer, Languages, Questions" on the owner's
  library): those papers share no specific phrase. November's naming of map nodes and step 2's coherence test (demote
  grab-bags) address it; the reader can rename meanwhile.
- Topics cover every catalog; the chart filters the current catalog's list.
- Uploaded PDFs (above). The browser client is not built (step 5).

## Serving to all (prepared 2026-10-25; not run)

Owner approval: the §5 notice and `serving='all'`, 2026-10-25
([DECISIONS.md](../DECISIONS.md#interest-index-privacy-notice-approved-serving-may-go-to-all-owner-2026-10-25)).

**How `staff` was set.** By operator SQL, not by a migration or the admin site (Health only reads `serving`):
`public.worker_interest_set_policy(p_enabled, p_serving, …)` (0152, service role only). Staging's
`interest_policy.updated_at` is 2026-10-24 14:59:09 UTC, the start of the backfill, when Phase B set `enabled=true`
with `serving='staff'`. `staff` means an account with an `app_private.app_roles` row; on staging that is one account,
the owner's, of 51 open accounts. The flip uses the same function.

**What `all` changes.**

- Every signed-in reader on TestFlight 92 gets Library topics, and a Feed paper's details get related papers from the
  index (instead of the Feed-results fallback). Builds before 92 never call the index, and the browser doesn't use it yet
  (step 5).
- There is no client-side gate. The apps rely on the server's `404 interest_unavailable` (`InterestIndexError.notServed`)
  and ask again an hour later or at the next launch, so readers pick it up within about an hour.
- For you's similarity (`worker_feed_candidates_v2`, 0155) applies to every reader For you serves. For you itself is
  still `feed_policy.serving='staff'` on staging, so For you changes for nobody until the Feed's own switch moves
  (PERSONALIZED_FEED.md "Rollout", step 5: its own notice text, and `discover`'s limit below).
- Embedding is unchanged: catalog papers in any library are already embedded, whatever the serving.

**Readiness for 100–1,000 readers** (staging, read-only, 2026-10-25):

| Check | Finding | Action |
|---|---|---|
| What the app asks for (TestFlight 92) | `interest-index`: a manifest at most every 10 minutes while topics or related papers are worked out (≤ 6 in an hour of use). Each artifact is fetched once per digest and kept on disk: on first use the map (143 KB) and terms (285 KB), plus the window's shards (3, 2.6 MB) once related papers are opened; then about one shard a day, and map and terms after each rebuild. `interest-library`: at least one call per launch (a page per 500 papers), and at most one every 10 minutes while a paper has no fingerprint. Owner's measured peak: 12 and 7 requests in an hour | — |
| `interest-index` rule: 240 / 4,000 an hour (this document said 120 / 2,000) | About 650 readers using the app in the same clock hour fill the environment limit. It is shared, so past it every reader gets 429 for the rest of that hour | 0157: 10,000 (the column's maximum, as `library-read` and `sync-read`) |
| `interest-library` rule: 60 / 1,000 | One launch each by 1,000 readers in the same hour fills it | 0157: 5,000 |
| At a limit | A kept manifest whose artifacts are on disk still answers. Otherwise topics hide and related papers use the Feed results. No error is shown | — |
| Cache headers | Manifest `private, max-age=600`; artifacts `private, max-age=31536000, immutable` with `ETag` = SHA-256. The app keeps its own 600 s manifest and keeps artifacts by digest, so it never revalidates. For a later browser client: `If-None-Match` is compared only after the RPC has read the artifact from the database, so a 304 still costs that read and counts toward the limit | Note for step 5 |
| 0155 similarity per For you request | The similar tier (EXPLAIN ANALYZE of 0155's CTEs; synthetic libraries of embedded papers; 8,230 window papers): a 70-paper library takes 84–88 ms. At the 300-paper cap it took 1.28–3.80 s: the grouping sorted both fingerprints of 117 thousand pairs, about 175 MB, against a 3.5 MB work_mem | 0156: cosine first, 235–243 ms at 300 papers, same results |
| For you volume | `discover`: 60 per account, 600 for the environment an hour, shared by For you, topic chips, category chips and older builds' search. A For you request is about 0.45 s for the owner's 70 papers (PERSONALIZED_FEED.md timing) and about 0.6 s at 300 after 0156. 600 an hour is about 6 database-minutes an hour. At 1,000 readers the limit binds before the query does | The Feed's rollout decides; not this flip |
| Egress and invocations | About 16–22 MB a month per active device; 1,000 devices ≈ 20 GB of the plan's 250 GB. About 2–5 Edge calls per device a day | $0 |

**Steps for the lead after review** (staging `coxhjvqpflgxkleydati`; from the main checkout, which holds
`.env.staging`):

1. Merge the branch.
2. `python3 scripts/backup.py staging`: an encrypted backup (note its folder under `.artifacts/backups/`).
3. `python3 scripts/migrate-supabase.py staging`. This applies exactly 0156 and 0157; staging's ledger ends at 0155.
   Read back
   `select route, account_limit, environment_limit from app_private.api_rate_rules where route like 'interest-%';`:
   expect 240 / 10000 and 60 / 5000.
4. No Edge function deploy. 0156 keeps `worker_feed_candidates_v2`'s signature and result. `interest-index` and
   `discover` (ranking v3, deployed 2026-10-25 00:08 UTC) are unchanged.
5. Website before the flip, so the notice is live first: `node scripts/deploy-web.mjs site`. Then
   `curl -s https://gradstep.ai/privacy/ | grep -c 'Topics and For you'` should print 1.
6. The flip, through the Management API's SQL as for `staff`: `select public.worker_interest_set_policy(null, 'all');`
   (`null` keeps `enabled`). Read back `select enabled, serving, updated_at from app_private.interest_policy;`, which
   should show `true`, `all`.
7. Checks: `node scripts/workflow-checks.mjs --only=interest.health`. After some hours of use,
   `select public.worker_interest_status()->'delivery';` should show more than one account in 24 hours. Admin Health's
   Interest index card shows the same.
8. Optional, not needed for the flip:
   - `node scripts/deploy-web.mjs app` puts the section in the browser's Privacy & data (the browser doesn't use the
     index).
   - The apps' Settings › Privacy & data section ships in the next TestFlight build.

**Rollback:** `select public.worker_interest_set_policy(null, 'staff');`. The apps get `404 interest_unavailable`,
delete their kept index files and hide topics, and For you's similarity stops for readers without a role. 0156 and
0157 can stay.

## Decisions taken for Phase B (lead's interim decisions; the owner can revisit)

1. **Corpus window 180 days.**
2. **Rebuild every two weeks until the corpus reaches about 50,000 papers, then weekly**, warm-started; successors kept
   so synced topic IDs migrate (`rebuild_days_growing` 14, `rebuild_days` 7, `weekly_after_papers` 50,000).
3. **The privacy-notice line (§5) needs the owner's approval before public release**; it does not block staging.
   *Approved 2026-10-25, with serving to `all`.*
4. **Local database tests use Homebrew PostgreSQL 17 with pgvector** (docs/TESTING.md).
