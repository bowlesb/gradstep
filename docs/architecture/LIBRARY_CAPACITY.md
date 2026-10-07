# Library capacity evolution

Status: **staged implementation authorized**, 2026-10-07. The owner approved the database direction and independent
review. [Library v4](LIBRARY_V4.md) records the first additive implementation in migrations 031/032, now applied to staging after encrypted backup (2026-10-07)
and not enabled in clients. The cache changes and larger-capacity rollout below remain future work. The
**4,000 retained-entry client bound and existing backend lifetime quotas remain unchanged**. React remains the
browser/admin framework; SwiftUI/Catalyst remains the Apple client.
This plan follows the owner's request for large libraries and careful infrastructure design in
[Decisions](../DECISIONS.md). Read the acceptance gates before changing limits.

## Current contract and evidence

| Boundary | Current behavior |
| --- | --- |
| Client projection | 4,000 retained items/imports, including hidden mappings and removed entries; not 4,000 visible papers |
| Backend lifetime rows | 2,000 membership rows and 2,000 import intents/account; 20,000 of each/environment |
| Mutation receipts | 12,000/account, 120,000/environment, with reserved withdrawal headroom |
| Journal | 8 MiB/10,000 batches/account; 64 MiB/100,000 batches/environment; compaction advances `retained_after` |
| Transfer | 256 MiB/account/month and 2 GiB/environment/month; additional request-rate limits |
| Pages | At most 100 entries/batches and 1 MiB; clients allow at most 256 pages per refresh |
| Native caches | 256 MiB complete presentation; 512 MiB/100 explicit bundle installations; separate limits |

These are internal beta controls, not subscription allowances. Removing a paper retains its membership identity
and fence; it does not restore lifetime row capacity. Sources: [migration 010](../../supabase/migrations/202610030010_library_import_contract.sql),
[Swift wire limits](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/LibraryWire.swift),
[browser reconciler](../../apps/web/src/lib/library.ts), and [native offline policy](NATIVE_OFFLINE_BUNDLES.md).

The v3 baseline fixes a **creation boundary**, not historical row values: later pages may contain newer
`state_seq` values. Both clients must finish the baseline and fixed-boundary catch-up before treating it as a
complete observation. Command receipts and individual row revisions never advance the account cursor.
[Migration 019](../../supabase/migrations/202610050019_web_import.sql) currently materializes full eligible rows
before selecting a page; repeated pages repeat that projection work. Migration 010 also uses global policy
locking and repeated count/sum scans. These are source findings, not measured hosted-query bottlenecks.

Implemented browser update isolation at `060bc92` preserves unchanged entries/row facts and moves display clocks
into active import rows. Local Chromium observations over about 3.4 seconds dropped script work from 825–1,097 ms
to 9–18 ms; the fixture still renders 3,999 rows from 4,000 retained entries. It exercises client wire capacity,
not the backend's item/import quota mix. [Evidence and limitations](BROWSER_READER.md#library-update-isolation--2026-10-07).
The separate [framework experiment](WEB_FRAMEWORK_EVALUATION.md) measured windowed rendering with 50,000 synthetic
records; it bypassed product sync/storage and does not establish 50,000-paper capacity. Product windowing, larger
capacity and browser offline library storage remain proposed work. Native encrypted per-row caching already exists.

## Separate replication, queries and assets

Use three explicit responsibilities in the next protocol version (called v4 here only as a working label):

- **Compact sync state:** account-scoped item/import identities, creation/state sequences, revisions, membership,
  removal fences, immutable pins, import-to-item mappings and availability. Keep grouped transitions atomic.
- **Query projection:** bounded list summaries and indexed fields needed for search, filtering, ordering and counts.
  A query result is a view of the library; it is not proof that an unseen entity is absent.
- **Immutable metadata and assets:** bibliographic records addressed by pinned `metadata_id`; original PDFs,
  render artifacts and verified manifests fetched separately. List queries never hydrate reader bundles.

Stop repeating complete abstracts in every progress event. A compact change can reference immutable metadata
already cached by ID. Advisory percentages may use a lighter update path, but acceptance, resolution, cancellation,
membership and availability remain durably reconciled. Missing referenced metadata produces a loading state, never
fabricated identity or a skipped cursor. Define byte/count limits for every new record and response.

Initially retain compact hidden import mappings and removal identities rather than discarding them to fit a limit.
Removing those from client replication later requires a separate command/lookup contract: existing native complete
observations and revision-zero semantics assume full coverage. Preserve the server's document-removal fences.

Keep account commit ordering and greatest-`state_seq` reconciliation. Apply each accepted batch and durable cursor
transactionally. A command acknowledgement establishes a required observation floor, not completion; a pull begun
before that acknowledgement may need another fresh boundary. Capture Add's observed cursor from the last published
complete snapshot. Preserve exact operation IDs/arguments through uncertain replies and pending overlays separately
from confirmed rows. [Command contract](NATIVE_LIBRARY_COMMANDS.md), [current data model](DATA_MODEL.md).

## Paged query consistency and indexes

Add a bounded query RPC with deterministic keyset ordering and an ID/kind tie-breaker. Bind its opaque continuation
to account, backend dataset epoch, query/filter/sort, search version and query revision. Auth checks
apply on every page. A query cursor must never substitute for the replication cursor or a mutation precondition.

Independent review selected **indexed current query rows with explicit invalidation** for the first stage.
Query-affecting changes advance the account's query revision; ticking progress does not. Each page observes one
database snapshot. A changed revision requires a fresh query generation, so pages from different result sets cannot
be appended together. This avoids adding history tables and leases before measuring their need. Versioned rows and
bounded leases remain an option if churn causes repeated restarts; their retention, age and byte budgets would need
a separate design. Existing v2/v3 semantics remain unchanged.

Keep the current snapshot's ordering/filter fields coherent while refreshing its replacement; restore the user's
row anchor when the replacement is ready. Current removals/quarantine still invalidate reading immediately, even
when an older query contains that row. Query counts belong to their boundary and may become stale. Test these
behaviors during active imports/tag changes before enabling the new query contract in a client.

Index authorized account membership plus supported archive/recent/title/year/source/tag paths. Fetch candidate IDs
before constructing large JSON projections. Review query plans at representative and maximum field sizes; do not
assume the existing publication FTS index implements library search. Current surfaces differ: the
[browser Library](../../apps/web/src/ui/Library.tsx) matches one substring across title/authors/tags/source/venue,
without abstracts or term-wise AND; [native search](NATIVE_LIBRARY_SEARCH.md) supports whitespace-separated AND
terms across its richer metadata fields, including abstracts. Proposed shared target: pinned title, authors,
abstract, identifiers and effective tags/categories, with explicitly chosen AND/substring rules. Record that
cross-surface behavior before implementation; richer browser matching is a feature change, not existing parity.
Specify Unicode folding, null ordering and collation/version, and test the deliberately selected semantics.

Replace repeated quota scans with transactionally maintained accounting only after validating concurrency and the
existing lock order. Keep withdrawal headroom and strict limits; approximate counters cannot authorize growth.
Plan bounded per-account journal retirement to avoid an environment-wide resync wave. Measure before replacing
the current global mutex; a short correct critical section is preferable to unsafe quota concurrency.

## Durable local cache and retirement

Extend native `EncryptedStore` and its authenticated per-row cache. For the browser, add a versioned encrypted
IndexedDB cache under the durable device-key lifecycle; an unsupported key store still fails closed. Bind cache
records to canonical backend origin/project, account, local writer generation, format and record identity.
An environment display label alone is insufficient deployment identity. Do not persist in-memory request tickets.

The checkpoint authenticates exact row references, complete cursor and generation. Resume catch-up from a validated
complete checkpoint. Build a cold baseline/resync in a separate generation; atomically switch the active generation
only after its baseline and catch-up validate. Persist continuation/boundary separately from completeness so work
can resume across bounded scheduling slices. An unfinished baseline must never replace the last complete library.

Maintain a single writer or transactional generation checks across tabs/actors. Fence worker/query/network results
by account session, source generation and request identity; cancellation alone does not prove work has stopped.
Clear presentation immediately on sign-out and drain already-accepted writes according to existing retirement
rules. Ordinary sign-out retains permitted encrypted account storage; forgetting keys/account deletion must also
invalidate pending writes so late callbacks cannot recreate cache data. Preserve private outboxes and drafts during
ordinary cache replacement; explicit forgetting/account deletion follows the established deletion policy.

Distinguish absence, browser eviction, corrupt ciphertext, unknown formats and disk-full. Fail affected derived
cache reads explicitly while preserving unrelated private records and recoverable bytes. Test atomic local-format
upgrades and older-writer rejection. Cache roots/cursors must not advance when required child writes fail.
Preserve native sticky eligibility guards: a later outage or stale install cannot undo an observed quarantine.

## Private fields and offline completeness

Public metadata, archive state and personal tags are service-visible and can use server indexes. Personal tags
follow the later [tag decision](TAGS.md), which supersedes the earlier encrypted-label proposal. Opened, Progress,
Unread/Reading and private chat counts remain device-side; do not upload those fields or their derived indexes.
[Reading activity policy](PRIVACY_AND_SYNC.md#device-local-reading-activity-2026-10-05).

Exact global combinations of public search and private filters require a complete compact membership/candidate
index. Sorting only loaded pages is incorrect. While that index is incomplete, show preparation or an explicitly
limited offline scope rather than claiming global results. Full abstract search offline requires retained abstract
coverage; a metadata ID alone cannot provide it. Derived local search runs off the main thread with supersession.

Do not add plaintext indexes for reading activity or decrypted chat data. Begin with a worker-owned derived index
from encrypted records; a larger persistent encrypted index needs a reviewed format and leakage model. The current
5,000-entry activity eviction policy also needs review before larger libraries: forgetting an opened marker cannot
silently turn a previously opened paper into a confidently “Unread” paper. Compact activity and detailed reading
locations may need separate bounds. No activity/privacy policy changes are made here.

## Storage bounds and safe cleanup

Budget decoded working memory, compact metadata, full metadata, original PDFs, rendered bundles, query versions,
journals, replay receipts and pending commands separately. Keep existing native cache limits until a revised policy
is reviewed. Account for ciphertext overhead, SQLite/WAL/index growth, browser quotas and temporary replacement
generations. Do not derive worst-case capacity from average paper metadata or synthetic fixture heap size.

Evict only explicitly disposable payloads under a documented policy; pinned offline copies retain current policy.
Never evict unsent work, uncertain commands, necessary fences or replay evidence to admit another download. A page
not loaded is not a deletion. A completed replacement baseline can retire absent local entries only under a defined
coverage contract; losing a cursor must not discard private history or turn stale cache bytes into fresh authority.

Do not prune server operation IDs/receipts by age alone: replay after forgetting the ID could execute again. Keep
compact replay records initially. Sustainable cleanup needs a separately reviewed operation-epoch/retirement
contract that refuses expired uncertain requests rather than treating them as new. Bound compact fence/import
history explicitly; “compact” does not mean free or unlimited. Account deletion follows the existing deletion policy.

## Implementation sequence and release gates

1. **No backend migration:** retain row isolation and complete command publication while adding client windowing
   and prepared background search. Preserve keyboard focus, selection, row anchors, browser Find/printing and
   accessible result counts; verify command-completeness changes separately from capacity performance.
2. **Local-format work:** prototype encrypted cache/checkpoint restoration and incremental indexes at existing
   limits. Native and browser need atomic upgrades, retirement and crash tests before enabling persistence changes.
3. **Backend design review:** settle compact wire shapes, query snapshot/expiry, dataset epoch, indexes, counters,
   retirement and storage budgets. Benchmark candidate SQL locally; no provisioning or migration follows implicitly.
4. **Additive implementation:** new versioned RPCs/projections with existing v2/v3 reads/writes preserved. Backfill
   and compare projections against canonical state before switching readers; do not introduce a second authority.
5. **Compatible rollout:** ship native and browser decoders, cache upgrades and capability handling first. Enable
   larger accounts only when supported clients work; older clients must receive a deliberate update-required path,
   never silently truncated libraries. Plan rollback for accounts that can no longer fit an older client.
6. **Capacity acceptance:** validate candidate 10k and 50k workloads, then select public/internal limits from
   measured resource use and the operating budget. These are test targets, not accepted capacity or allowances.

Required evidence before raising limits:

- Correct full result sets against a reference model during adds/removes, import resolution/cancel, tag/archive
  changes, duplicate aliases, page-boundary ties and missed realtime notifications. No duplicate or omitted entities.
- Bounded catch-up that resumes after interruption; journal compaction, query expiry and dataset-epoch changes
  require controlled resync. Test command receipts ahead of an already-running pull and failed post-receipt refresh.
- Crash/disk-full/corrupt-child tests before and after row/cursor commits and generation swaps; account switching,
  same-account relogin, concurrent tabs, forgotten keys and late cancellation-ignoring callbacks cannot publish/write.
- Global public/private filter parity, Unicode and null ordering, offline scope accuracy, stable reader return,
  keyboard/VoiceOver traversal and focused rows that disappear. Verify reduced motion and large text layouts.
- Real paged protocol fixtures mixing live items, terminal imports, tombstones and maximum-size metadata; repeated
  import/remove churn must not conceal lifetime growth. Do not reuse a visible-row fixture as backend quota evidence.
- Cold network bytes/requests/time, warm first-view time, search/sort latency, main-thread tasks, retained memory,
  disk/WAL growth, query plans and resync frequency recorded separately on declared devices/network conditions.
  Set numerical budgets and observation windows before each acceptance run; passing correctness alone is insufficient.
- Native, Chromium and supported Safari key/storage workflows verified independently. Current Safari key-persistence
  limitations remain a browser release gate; table benchmarks do not waive them. No physical iPhone work while paused.

Before migration review, choose the proposed snapshot lease/retention budgets, compact-history retirement policy,
offline-search coverage and encrypted-index approach, activity-retention semantics and old-client transition.
These decisions must fit the existing incremental operating budget; none authorizes a spending increase.
