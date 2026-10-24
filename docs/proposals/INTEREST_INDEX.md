# Interest index (approved 2026-10-24; step 1 done)

Owner, 2026-10-24: "one of the most important new features needs to be about maintaining a better nuanced and
personalized understanding of what the user has in their library … topics … unique to them … not things like Machine
Learning, not things like regression … performant, kept up to date, use a reasonable amount of storage and memory, and
support very fast operations." Features: (A) better keywords, (B) better ranked recommendations in sections per topic,
(C) a pie chart of the library's topics. Proposal page: https://claude.ai/artifact/QBatnYQerYYTnbEA9uxngY

## Proposed design

1. **Paper fingerprints (public, server).** One small open embedding model (candidates: gte-small 384-d, bge-small,
   SPECTER2 768-d, EmbeddingGemma, voyage-4-lite; chosen by the step-1 evaluation) embeds title + abstract once per Feed
   pool and catalog paper; stored as pgvector `halfvec`. Devices embed only uploaded PDFs (titles are E2EE).
2. **Topic map (public, server).** Hierarchical k-means over public ML papers: ~20 / ~200 / ~3,000 nodes, each named
   once by an LLM from c-TF-IDF terms and representative titles (≈ $2 per build). Append-only IDs: new papers join the
   nearest frozen leaf; grown or drifted leaves split into new IDs; rebuilds map old→new by centroid and membership.
3. **Interest state (private, device; synced as an E2EE blob).** Per map node: weighted count and fingerprint sum
   (BIRCH-style, so add/remove are exact O(d) updates). Topics are chosen by lift (user share ÷ background share), going
   deeper when the child has ≥3 papers, ≥~40% of the parent's user mass and >2× the parent's lift; hysteresis (appear at
   3, leave below 2); personal splits for nodes with >~15 papers in two clear groups. Synced: chosen topics (map IDs,
   user names, hidden flags, colours by ID) and an append-only feedback log, < 100 KB.

Signals: adds/removes with the existing age fade, archive ×0.5, user tags ×1.5, Feed feedback; on device only: reading
depth, snippets, chats, uploaded PDFs. Ranking per topic section: 0.5 kNN(3) + 0.15 centroid + 0.15 freshness + 0.1
popularity + 0.1 authors − 0.4 dismissed similarity, MMR inside sections, sections sized by topic mass, one exploration
section; an on-device logistic re-ranker after ~50 labelled events. Keywords: map leaf name + KeyBERT-style phrases
scored against background document frequency, computed once per public paper on the server.

Brute-force SIMD (Accelerate) is enough at this scale (~30k vectors); FAISS/USearch/sqlite-vec are not needed.
Estimated cost ≈ $1–3/month plus ≈ $2–5 once. Alternatives considered: per-user clustering on device (naming per user,
unstable IDs) and server-only (cannot use device-only signals; breaks under library E2EE). Semantic Scholar embeddings
or recommendations are not proposed (revocable terms; per-user calls would send libraries out).

## Plan

1. Offline evaluation on the owner's staging library (hold-out ranking in the 25k pool; trial topic map shown to the
   owner) — no AI spend. 2. Server layer (built and live on staging 2026-10-24, serving staff:
   [architecture/INTEREST_INDEX.md](../architecture/INTEREST_INDEX.md)). 3. Device layer + Library chart + keywords +
   sync. 4. Feed in sections. 5. Web when web work resumes.

## Sync

Recomputed identically on each device: counts and topic IDs (library, fingerprints and map are shared). Synced as an
E2EE blob/events (< 100 KB): chosen topics with user names and hidden flags; the Feed feedback log (grow-only set by
event UUID); per-paper interest weights, which carry device-only reading depth to other devices without syncing reading
history. Registry merges last-writer-wins per topic ID with an (epoch, device) tie-break.

## Owner decisions (2026-10-24: "All your questions sound fine")

1. Design approved. 2. Device-only signals (reading depth, snippets, chats) count, on the user's devices only.
3. Start step 1 now with no AI spend; name the map in November (October's provider budget is at 82%).
4. The chart goes at the top of Library › All, collapsible, slices filter.

## Step 1 result (2026-10-24; branch `interest-eval`, report `.artifacts/interest-eval/REPORT.md`)

Data: the owner's library is 62 papers (in `library_v4_entries`, added 10-19…10-24); the Feed pool held 9,890 papers.
Leave-one-out ranking (kNN-3): gte-small AUC 0.756, bge-small 0.754, SPECTER2+proximity 0.733 — differences within
noise; R@50 ≈ 2–5% (random 0.5%). Held-out papers from topics with ≥3 other papers: AUC 0.83 (43% in top 10%); from
small topics 0.61 — supports topic sections plus exploration. **Model: gte-small** (fastest, smallest, portable).
EmbeddingGemma skipped (gated), voyage skipped (no paid calls). Topic selection: the proposed descent rule rarely
descends on a 62-paper library; a relaxed rule (≥25% of parent mass, >1.5× lift) and comparing against all descendants
surfaces niches (multi-agent interaction, KV-cache compression, RAG evidence). Unnamed (TF-IDF) labels are bland; LLM
naming stays planned for November.

## Step 2 results (2026-10-24, offline, `tools/interest-eval/topic_rule2.py` and `terms.py`)

Owner, 2026-10-24: if a reader clearly follows sparse attention, calling the interest "attention" or "transformers"
is not helpful; "agents" is fine for a passive interest. Asked whether TF-IDF can find the terms unique to a paper and
evolve over time.

- **Specificity-first topic rule.** Deepest node first: a map node becomes a topic once ≥ 3 of the reader's papers in it
  are not already claimed by a narrower topic; unclaimed papers rise to the parent; a top-level node keeps its rest as
  a broad topic only when ≥ 3 remain. The narrowest grouping the library supports wins, so a sparse-attention reader
  gets "sparse attention" (a ~30-paper leaf in this pool) and a passive agents reader gets "agents". On the owner's 62
  papers: 14 topics, among them multi-agent interaction (lift 30), parameter-efficient fine-tuning (5.5), hybrid /
  recurrent architectures (KV-cache node, 4.7) and reasoning-trace distillation, where step 1 showed only broad areas.
- **"Other" folded.** A paper outside every topic joins the topic holding its nearest paper when cos ≥ 0.86
  (gte-small); the rest is labelled by its top-level areas ("control · robot · motion (2)"). Other fell from 19 % to
  11 %. Two papers in a small, high-lift leaf are listed as *emerging* and become a topic at the third.
- **Term layer (TF-IDF family, no ML training).** Candidates are 1–3-grams in ≥ 3 corpus papers. A phrase must be a
  *concept*: its embedding closer to the papers that use it than to the corpus as a whole (+0.02; "speculative
  decoding" +0.058, "kv cache" +0.037, filler such as "natively" −0.002 or "comparable quality" −0.054 is dropped).
  Three rankings: per paper, TF-IDF with IDF from the public pool, re-ranked by closeness to the paper; per library,
  weighted log-odds with an informative Dirichlet prior against the pool (robust at small counts, where raw TF-IDF
  crowns one-off terms); per topic, the same log-odds re-ranked by closeness to the topic. The term layer catches
  interests that clusters split: parameter-efficient fine-tuning spans 4 of the owner's papers in 3 clusters.
- **Evolving.** All statistics are sums, so adding or removing a paper is exact and cheap; IDF / background counts come
  from the public pool and shift as fields move (a phrase that becomes common stops being distinctive); recency weights
  decay older papers. On the device this runs on full text (the paper body is local), with document frequencies
  shipped from the server's public pool — no private text leaves the device.
- **Open.** Topic names from c-TF-IDF and log-odds are still rough on 3–4-paper topics ("word, transformer");
  LLM naming of map nodes (November budget) fixes the node half, noun-phrase candidates the term half. Some broad
  "rest" topics are grab-bags; a coherence test (mean pairwise similarity of the topic's papers) should demote them.
