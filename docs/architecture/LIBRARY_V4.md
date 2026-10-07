# Library v4 foundation

Status: implemented and independently reviewed; local validation passed, 2026-10-07. The owner authorized
the database work after reviewing [capacity evolution](LIBRARY_CAPACITY.md). This is an
additive backend foundation; installed clients continue using v2/v3. No capacity increase,
new subscription allowance, client cache replacement or hosted deployment is implied.

## Decision and boundaries

Separate compact replication, immutable metadata hydration and library queries. Canonical
membership/import rows, command receipts, removal fences and commit ordering remain the
authority. Keep the existing journal while v2/v3 clients use it; v4 removes metadata from
bounded journal pages at read time, without maintaining a second journal. This first stage
reduces transfer and cold-page projection work, not the legacy journal's storage cost.

Independent review recommended **current indexed query rows with explicit invalidation**
before adding version history and snapshot leases. A query continuation binds its account,
dataset epoch, search semantics, normalized query and query revision. A meaningful result-set
change returns `library_query_restart_required`; clients must replace that query generation,
never append mismatched pages. Progress ticks and availability decorations do not invalidate
ordering. This is a correctness contract, not yet evidence of seamless scrolling under churn.
Versioned query snapshots remain an option if workload testing demonstrates restart starvation.

## Compact replication and metadata

Migration 031 creates one compact current row per retained item/import, maintained in the
same transaction as the existing journal batch. Its JSON is the existing entry minus only
`metadata`; immutable IDs, revisions, tags, removal fences, hidden import mappings and
availability remain present. A conflicting equal revision is an error. The backfill reads
canonical current rows, never assumes the retained journal contains every entity.

`v4_library_page` keeps the established creation-boundary baseline contract. Later pages can
contain newer row values; a baseline is incomplete until fixed-boundary catch-up finishes.
`v4_library_changes` compacts stored historical batches, preserving grouped changes and their
original order. A command acknowledgement is still an observation floor, not a complete
library cursor. Pages retain the 100-row/batch and 1 MiB bounds and existing transfer quotas.

`v4_library_metadata(p_dataset_epoch, p_metadata_ids)` accepts at most 24 distinct IDs and returns complete immutable metadata
records. Every ID must be referenced by this account's retained projection, including its
existing tombstones/mappings. A missing or unauthorized ID fails the whole request with the
same error. Knowledge of another catalog UUID grants no access. PDFs and reader bundles use
the existing authorized Storage/reader contracts.

Current commands never replace a retained metadata pin. A future pin upgrade or record-retirement migration must
preserve hydration authority for IDs still deliverable in the retained journal, or force a complete resync.

## Query contract

Migration 032 adds a shared search projection per immutable metadata record and small
account-scoped query rows. Full normalized abstracts/authors are stored once per metadata
identity, not once per reader. These are derived indexes, not another source of truth.

`v4_library_query(p_query, p_cursor, p_limit)` supports:

- Up to 50 rows and 1 MiB, with keyset continuation and deterministic kind/ID tie-breakers.
- Recent, title and year order; ascending/descending, missing title/year last in either direction.
- Active/archived/all, source and effective-tag filters. Resolved imports coalesce with their
  visible membership, as in the current client. Private reading activity/chat counts stay local.
- Exact tag filters use Unicode simple lowercase without compatibility normalization, preserving distinct
  labels such as `ML` and `ＭＬ`. Text search still matches their NFKC forms. When effective tags are empty,
  friendly category fallback names match the shared vocabulary and current browser behavior.
- At most 512 UTF-8 query bytes and 16 whitespace-separated AND terms, matched as literal
  substrings across title, individual authors, abstract, venue, categories, source identity
  and effective tags. `%`, `_` and backslash have no wildcard meaning.
- NFKC normalization followed by Unicode simple lowercase through PostgreSQL's built-in
  `pg_c_utf8`, with bytewise `C` ordering. Accents are retained; this is neither stemming nor
  a claim of parity with Apple's locale-sensitive search. The normalization version binds
  PostgreSQL major/collation version, and incompatible upgrades reject v4 queries pending
  a reviewed rebuild. [PostgreSQL collation contract](https://www.postgresql.org/docs/17/collation.html).

A bounded title-prefix index narrows candidates; the **full normalized title** decides order
inside a prefix group. Long/multibyte titles must never exceed B-tree key limits or be silently
truncated for ordering. Full metadata remains available separately; list summaries include
the first three authors and the complete author count.
The cursor carries the anchor's kind/ID, not an unbounded title. The server resolves its full ordering tuple
within the unchanged query revision. Trigram candidates support longer search terms; terms without three
consecutive alphanumeric characters are checked against the account's joined metadata, avoiding a whole-catalog
trigram scan that cannot eliminate candidates.
When an account has at most 50 visible retained rows, all terms use its joined metadata; a count bounded at 51
chooses that path inside the same snapshot. Larger accounts keep the selective trigram path for longer terms.
This avoids repeating global-catalog scans for a one-page library while preserving identical matching rules.

The account query revision advances only when membership, mappings, search/filter/order or
stable summary fields change. One `STABLE` private query observes the revision, rows and
continuation from the same database snapshot. Response state may contain newer progress or
availability than earlier pages. It never authorizes reading an unavailable artifact, proves
absence from unloaded pages, or advances the replication cursor.

## Lifecycle, bounds and rollout

New customer read wrappers acquire an account `KEY SHARE` guard and recheck closure before
rate/transfer writes. This excludes account deletion while remaining compatible with legacy
writers' account `NO KEY UPDATE`. Private tables have RLS and no customer grants; only the
explicit authenticated RPCs are exposed. Derived account rows cascade from `library_sync_state`,
which deletion removes even though the billing account itself remains.

There are no query-session, history or lease rows in this stage. Current projections inherit
existing canonical row limits; normalization expansion and index overhead must be measured
separately. No new cap may strand Remove/Cancel or other existing mutations. Existing receipt,
journal, transfer and provider budgets remain in force. Search rate limits and response limits
bound requests, not every possible database CPU cost; heavy-use monitoring remains necessary.

Dataset identity is persisted, so **restoring a database must rotate its dataset epoch** before
v4 clients reconnect. A restored backup alone cannot invalidate old continuation tokens.
The local restore quarantine hook performs this rotation when the v4 configuration exists. Normalization upgrades
require rebuilding derived indexes and rotating the epoch together; merely changing `search_version` is invalid.

Before enabling v4 in a client: verify populated upgrades, old-wire equivalence, grouped
changes, concurrent query mutations/deletion, long titles/Unicode/wildcards, query restarts,
authorization and index plans. Then implement durable cache/query generations and restore
row anchors on replacement. Test 10k/50k workloads in disposable fixtures before proposing
larger limits. This migration does not retire old clients, operation IDs or tombstones.

## Deployment prerequisites

A read-only check of the dedicated staging project on 2026-10-07 confirmed PostgreSQL **17.11** and the required
`pg_catalog.pg_c_utf8` collation. `pg_trgm` was not installed; 032 creates it in `extensions`. A differently located
existing extension causes a deliberate deployment failure requiring review. This check made no schema changes.
Local tests use PostgreSQL 18; the normalization version explicitly differs across these majors. Do not copy local
derived rows into staging or describe local performance as a hosted benchmark.

Apply the additive migrations through the normal reviewed migration/checkpoint process. Each migration has a
15-second lock-acquisition timeout and backfills under account/write locks. Measure deployed row counts and the
expected lock window before applying; a large backfill is not an online-migration guarantee. Applied predecessors
are untouched. Recheck legacy reads, mutation replay, current-projection coverage and account cleanup after rollout.

## Validation and integration checkpoint — 2026-10-07

The branch `codex/library-v4-foundation-20261007` includes main through `97c0bef`. All checks below are local
unless explicitly marked read-only staging prerequisites above:

- `python3 scripts/test-database.py`: all 23 SQL test files, existing concurrency/upgrade checks, populated
  030→031→032 upgrades, legacy wire/function/receipt equivalence, and independent-session read/write/deletion
  races pass. Query tests include byte-limited pages, identical UUIDs across kinds, full-title prefix collisions,
  missing values, import coalescing before filtering, literal Unicode search, 50/51-row strategy transitions,
  current decoration with stable cursors, stale generations and derived-only deletion cleanup.
- Restore quarantine: **13 tests pass**, including the current schema and rejection of all pre-restore v4 cursor
  forms. Migration-ledger checks: **8 pass**. Backend tag checks: **10 pass**, including exact parity between the
  frozen SQL fallback mapping and shared/native vocabulary. The worktree reused main's locked SDK read-only for
  the backend test; no provider calls were made.
- `python3 scripts/benchmark-library-query.py`: **276 measurements** over 92 cases, 20/50/51/10k/50k synthetic
  retained-row accounts and 5k metadata records. Maximum observed server query **405 ms**, largest page **114,871
  bytes**; predefined limits were 5 seconds/1 MiB. Full ordering checks and disposable-database cleanup pass.
  [Independent plan/storage review](../reviews/LIBRARY_V4_QUERY_BENCHMARK_20261007.md) records source hashes,
  warm-cache conditions, physical storage and the improvements supported by measured index plans.

Deep recent pages now seek on their typed ordering tuple; ascending-title pages seek to their prefix and retain
full-title comparison. Limits of this evidence remain material: local PostgreSQL 18 is not hosted 17 performance;
metadata repeats across the large fixtures; title-descending/year access, long prefix groups, larger catalogs,
concurrent users and cold caches need capacity-specific testing. At the 50/51-row search-strategy boundary, a
16-common-term query rose from 9 to 167 ms median; larger-account catalog work remains. The own-text GIN index had
no scans in this workload and needs a cost review before scale-up. No quota, client capacity or SLA changes follow.

For integration, review the additive files and merge this branch; do not edit already-applied migrations. Next
steps are a current encrypted checkpoint, bounded staging backfill/rehearsal and hosted regression checks, then
separately reviewed client query/cache adoption, windowing and anchor restoration. Existing clients keep using
v2/v3 until those gates pass. This checkpoint does not claim a deployed web reader, working Mac distribution,
offline browser support or a repaired credit system.
