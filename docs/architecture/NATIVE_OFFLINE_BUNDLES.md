# Native offline reading bundles

2026-10-13 next contract: [HTML-first reader](HTML_FIRST_READER.md) retains the encrypted installer, offline reader
and interaction model but adds an arXiv HTML profile and a local bundle identity without server PDF dependencies.
Every original stays on device. Existing authored/Mathpix verification below does not establish HTML support or
the new local intake flow. Those additions now have Core and iPhone/iPad Simulator coverage and signed iOS/Catalyst archives; see HTML_FIRST_READER.md for exact evidence and limits.

Status, 2026-10-04: **Core persistence and native installation/reopening are implemented and independently reviewed.** The encrypted install–terminate–relaunch journey passes on iPhone and iPad Simulators. It uses a Simulator-only Debug synthetic account/library fixture, the existing authored bundle and real encrypted SQLite storage. It does not invent membership for a real server account or exempt the sample from eligibility rules. Library, Paper, Contents, figures and chat retain their navigation. The current native suite has 210 passing tests, three expected live/device skips and no failures, including the later search, retention, authentication and restoration-projection regressions. Production artifact delivery, real-account offline acceptance and the final [Mathpix pipeline](MATHPIX_PIPELINE.md) remain separate gates.

## Build 14 → 15 cache upgrade (2026-10-07, local review)

The cache checkpoint now records format 3, covering the topic tags and import progress fields added in builds
that decode migrations 029/030. A complete server observation replaces a readable older-format snapshot rather
than comparing fields that the old build could not preserve. Downloaded bytes, private notes/chats and pending
commands are unchanged.

A conflicting current-format presentation may be rebuilt only when the existing checkpoint and rows authenticate,
immutable identities and retained entries agree, sequences do not go backwards, and every saved reader eligibility
policy accepts the observation. Rebuilding never resets quarantine, availability revisions or membership history;
unreadable cache policy remains a reported failure. A failed ordered save still halts further cache installs.
The draft's latest-snapshot-only retry is omitted because it could skip a failed quarantine followed by an outage.
The error therefore asks the reader to reopen the app.

Verified in the offline-save worktree, `.artifacts/offline-save-review/`:

- Core: **207 Swift tests plus 4 OAuth XCTest tests pass** (`core-final.log`), including the 56-entry build-15 shape,
  format upgrade/restart, metadata-only repair, retained quarantine after local removal, unreadable-policy refusal,
  changed pins and same-cursor entry additions. The existing 4,000-row/137.8 MB encrypted fixture also passes.
- iPhone 17 Pro Simulator: **321 unit tests, 5 opt-in skips, zero failures**, plus both authored and Mathpix
  encrypted-paper relaunch journeys (`ios-final.xcresult`). Equations, figure assets, offline badges and saved
  questions survive restart; representative equation-action and figure-caption attachments were reviewed.
- Mac Catalyst: **298 applicable unit tests, 4 opt-in skips, zero failures** (`mac-verified.xcresult`). The existing
  development identity signs and launches the fixture build on macOS 26.3.1. Both test targets now explicitly
  support Catalyst and macOS 14, matching the app; otherwise Xcode preflight incorrectly required macOS 26.4.
  A final development-signed arm64/x86_64 build also passes (`mac-universal-final.xcresult`). The citation
  underline assertion now follows hover capability; both that test and the new native cache regression pass
  again on iPhone (`ios-platform-check.xcresult`). No production rendering rule changed.

The builds use only `fixture.invalid` and a public fixture key. No hosted application/provider calls, physical-device work, deployment
or TestFlight upload was performed. Mac keyboard/UI workflows, live sign-in, sync and purchases remain separate
acceptance gates. Existing simulator/WebKit and older fixture cleanup warnings do not constitute a runtime failure.

The [Core verifier](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/ReaderBundle.swift) retains exact authenticated `manifestData`. The [native loader](../../apps/apple/ScienceReader/Services/ReaderBundleLoader.swift) has directory and memory entry points sharing PNG/JPEG structural and ImageIO admission (JPEG only for the Mathpix MathML profile). [OfflineCache](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/OfflineCache.swift) and [OfflineCacheStorage](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/OfflineCacheStorage.swift) provide encrypted complete-presentation and bundle persistence through `EncryptedStore`. The [native coordinator](../../apps/apple/ScienceReader/Services/ReaderBundleCoordinator.swift) owns install/open verification, accepted writes, removal, cache ordering and retirement. ReaderModel restores the directory and complete presentation before network synchronization, then hydrates only a selected paper.

## Selected policy and bounds

Per account and deployment, allow **512 MiB of committed bundle ciphertext and 100 installations**, whichever limit is reached first. Allow one install at a time, explicit downloads only, and no automatic eviction. Blocked copies still count. Refusing an install preserves every existing copy. Local-copy removal leaves membership, history and drafts intact.

Count sealed bundle directory, headers and member bytes, including encryption overhead; the 32 MiB plaintext payload limit is not the charged ciphertext size. Preserve current per-bundle limits: 512 members, 32 MiB aggregate member bytes, 16 MiB per member, 256 KiB raw manifest and 16,000,000 aggregate image pixels. Do not change renderer admission to fit the cache.

Installation admission reserves the full **128 KiB mutable directory ceiling inside the 512 MiB limit**, so a nearly full cache still permits later eligibility/cursor updates. Header and member charges are calculated exactly before member encryption. The public listing reports actual committed ciphertext, not the reserved directory ceiling; that small difference is deliberately unavailable for new installations.

Use a separate **256 MiB logical ciphertext cap for complete library presentation**. [LibraryWire](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/LibraryWire.swift) permits 4,000 retained entries. Its metadata validation already bounds the same JSONEncoder representation to 32,768 bytes. Each versioned local row has a 64 KiB sealed limit: metadata stays a typed JSON object, with less than 8 KiB conservatively reserved for the remaining bounded fields, local identity/version envelope, eligibility policy and AES-GCM overhead. That envelope allows 3.1 KiB for source ID plus derived URL, including worst-case JSON scalar escaping; 1.2 KiB for three 64-byte readiness/availability strings; 1 KiB for UUIDs, timestamps and numeric values; and 2 KiB for fixed keys, enums, booleans, the local envelope/policy and encryption overhead. The cache uses the same slash-escaping policy and an explicitly local numeric timestamp codec to preserve decoded `Date` values exactly; network timestamps retain their ISO-string contract. Metadata is neither base64-encoded nor truncated.

At 4,000 sealed rows of 64 KiB plus a sealed checkpoint of at most 1 MiB, the maximum is **263,192,576 bytes (251 MiB)**, below the separate 256 MiB cap. Test maximum valid metadata, escaping/Unicode, all optional fields, unknown bounded availability values and the full entry count. A future wire expansion needs an explicit local-format/bounds review.

These are logical quotas, **not physical disk or process-memory guarantees**. SQLite pages, indexes, free pages, WAL, transactions and private history require additional space. Removal frees logical capacity but does not promise file shrinkage or secure erasure. Free-space preflight is advisory; disk-full rollback must preserve the last committed state. Do not add automatic VACUUM to this slice.

Lazy member reads are necessary: existing SQLite blob bindings/reads copy Data, and verification owns immutable copies. Never hydrate the 512 MiB cache on activation. One maximum bundle still requires input, verification, encryption/SQLite and image-decoding headroom. A full library presentation can itself approach 128 MiB before Swift object overhead. Iterate bounded rows off the main actor, avoiding a second giant serialized snapshot, and measure maximum-case memory, WAL growth and write latency. If full presentation hydration is unsuitable on the supported devices, implement paged local presentation before beta; do not advertise a partial snapshot as complete or silently reduce the server's 4,000-entry contract.

Retain at most the selected downloaded bundle in the model's paper and search rows. Selection of another document/artifact/manifest releases other decoded handles; metadata refresh can carry only that selected binding after the usual eligibility checks. Library/chat navigation without a new paper selection may keep this single handle for return. Reopening an evicted handle uses the ordinary encrypted read and native verification; it never reattaches a captured stale row's bytes. This is memory eviction only: installed ciphertext, reading locations and private conversations remain. WebKit or figure views can still own their immutable handle until dismantling, so model eviction is not an immediate process-memory or WebContent-release claim.

The offline badge derives from the current installation and its permission, independently of loaded bytes. A permitted installed copy is available; a blocked installed copy has a compact unavailable indicator. The coordinator exposes observation for its bounded availability summaries/guards, while tasks and complete catalog observations remain unobserved. Sample availability requires its verified bundled handle. Neither a metadata refresh nor a new search is necessary just to update availability.

Native cache-save tasks are retained only as `Void` completion/error barriers. Discard the store's returned catalog before returning the bounded installation directory to its publisher. Keep the prior task's throwing dependency, cache failure latch, and retirement drain: dropping a payload must not let a later checkpoint skip a failed quarantine write. The coordinator still retains its latest live observation for policy continuity; this change does not pretend to eliminate every catalog owner.

The independently reviewed retention follow-up passes `.artifacts/native-retention-verified.xcresult` (175 cases, three expected skips, zero failures). Real two-installation regressions cover synchronous selection eviction from model/search rows, encrypted reopening through stale captured rows, history/unsent-draft routes, unchanged refresh/chat/tab retention, both disk copies surviving, and cancellation-ignoring verification joining before replacement. A separate observation test proves immediate live-quarantine invalidation without a model catalog publication. The complete encrypted relaunch/equation/figure/chat journey also passes in `.artifacts/native-retention-ui-phone.xcresult` and `native-retention-ui-tablet.xcresult`, including the available-offline badge before the paper is opened. These establish bounded model ownership and UI behavior; current process-footprint measurements remain separate.

## Persistence layout and authentication

Extend the existing account-partitioned [EncryptedStore](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/EncryptedStore.swift), using its local-store key, protected database and serialized writer. Cache records are not private-history events or sync-outbox entries. Use versioned local DTOs; do not persist reconciler tickets or reconstruct them from Codable data.

Implemented tables:

| Table | Encrypted contents and bounds |
| --- | --- |
| `local_library_cache_checkpoint` | One sealed checkpoint: format, deployment/account, committed complete cursor, informational capture time and exact opaque row-ID/ciphertext-digest manifest; at most 1 MiB. |
| `local_library_cache_entries` | Opaque local row UUID plus sealed complete item/import DTO, including hidden entries/tombstones, import mappings and per-item sticky eligibility policy independent of installed copies; at most 4,000 rows, 64 KiB sealed each. |
| `local_reader_bundle_index` | One sealed directory, at most 128 KiB: shared deployment/account scope and at most 100 installation summaries, immutable bindings, header digests/lengths, charged bytes, local revisions and latest observed eligibility guards. |
| `local_reader_bundle_headers` | Installation UUID plus sealed header: exact raw manifest bytes, binding and member ordinal/ciphertext-digest/length list; at most 512 KiB sealed. This accommodates the bounded manifest even if its Data is base64-encoded in the header DTO. |
| `local_reader_bundle_members` | Installation UUID, bounded ordinal and directly sealed raw member bytes; primary key on installation/ordinal, foreign key to its header. At most 512 per installation, each at most its 16 MiB plaintext ceiling plus AES-GCM overhead. |

Store only the cache-checkpoint and bundle-index ciphertext digests in authenticated main metadata. The index includes account/deployment once; summaries do not duplicate long deployment strings or full titles. Keep member manifests and library rows out of main metadata so a draft checkpoint does not rewrite the entire cache. Read display metadata from cached library rows or the selected bundle header when needed.

The authentication chain is main metadata → checkpoint/index → entry/header ciphertext → member ciphertext. Distinct versioned AAD domains bind account/deployment, row/installation identity, full artifact binding and member ordinal. Each write uses fresh AES-GCM nonces. Manifest hashes additionally bind plaintext paths, roles, lengths and contents. SQL `CASE` checks blob type/length before selecting its payload, followed by a bounded Swift copy and verification of exact row sets, digests, AEAD and decoded bounds.

The current local format is **encrypted metadata 6 / SQLite schema 5**, with validated format-2/3/4/5 upgrades. Initializers, migrations, commit paths and writer checks use the new format coherently. A fresh actor reopening an existing store advances the writer generation even when no drafts are pruned and no library commands exist; ordinary same-account activation still reuses its actor. Migration is atomic after validating the existing store; stale older writers cannot downgrade or publish over it. Private event wire formats and content-key epochs do not change.

Do not decrypt cache bodies during private-history/draft recovery. Missing, oversized or corrupt cache children fail the affected presentation/bundle retrieval, retain their bytes and charged capacity, and never reset private data. Private writes preserve cache roots even when a child is unreadable. An authenticated valid directory permits explicit removal of a damaged bundle without decrypting its damaged members. Corruption of the authenticated main metadata or underlying database remains subject to the existing store-wide fail-closed rules.

## Authenticated per-row restoration projection

The repeated [constant-row layout measurements](NATIVE_RESOURCE_ACCEPTANCE.md#constant-row-library-layout)
reduce presentation overhead but still exceed the library memory investigation
trigger. The implemented, independently reviewed projection targets transient
overlap during restoration: the previous native path retained every decoded
`LibraryEntry` while building Paper/import collections and joined author strings.
The new path maps each authenticated row directly to native presentation data.
This is not a whole-catalog memory bound.

Keep the encrypted row/checkpoint schema, ciphertext limits, complete cursor and
existing materialization API. The complete-only
`cachedLibraryProjection<Row: Sendable>(scope:project:)` read whose synchronous,
`@Sendable` projector maps one validated `LibraryEntry` to an optional final row
does not retain the original item DTO in the native result.
Core constructs the result only after the entire read transaction succeeds. Its
scope, committed cursor, capture time and validated entry count remain separate
from its projected row count. The result is presentation evidence, never a live
`LibraryCompleteObservation` or command authority.

Share validation with the existing materializer. Authenticate the root and
checkpoint and require the exact stored row-ID set. For each bounded sealed row,
verify its size, digest, AAD, format, identity, reader policy, state sequence and
complete entry contract before projection. Retain compact item-ID/document-ID,
duplicate-document and import-target facts to validate all cross-row links at
the end; a corrupt last row or missing target must fail the whole result. Check
cancellation between rows and again after final validation, before returning.
The projector neither awaits nor publishes UI or mutates the store. Discard an
unreturned projection on every error/cancellation. No new table, migration,
plaintext index, outbox write or weaker integrity check is part of this slice.

Direct Core projection reads check cancellation before and between rows, during
canonical sorting and after final validation. The legacy materializer also
prepares accepted cache mutations, so it preserves its existing uncancelled
drain behavior. Native restoration is registered as accepted coordinator work:
it drains on retirement, then account/activation guards reject late publication.
It does not promise immediate cancellation of the underlying native read.

Native projection values contain complete display/search metadata, immutable
pins and small visibility/mapping/sequence/capability facts. Preserve visible
pending-import metadata and hidden import IDs needed for display deduplication.
Do not retain whole item DTOs, reader payloads, model/coordinator references or
mutation capabilities in the item projector. The MainActor then applies one
complete projection after the existing account, activation, store/coordinator
and winning-live-publication checks; selected verified bytes may be carried only
from current eligible state. Keep the existing full-field matching and global
sort semantics. Core returns the existing `LibraryOrderingKey` order, making
equal-date input order deterministic rather than depending on Dictionary
iteration; normal Library search still performs its selected global sort.
A generic projector can itself retain data, so this design only
removes the extra whole decoded DTO accumulation in the native path. It does not
bound all retained metadata or change live service/reconciler observations.

Author joining and metadata conversion remain inside the full restore clock.
Probe format 4 records cache-actor waiting, authentication, validation and native
mapping in `restoreProjectionElapsedMS`, separately from final MainActor
publication. The shorter publication phase cannot be compared with the earlier
phase as if author joining had disappeared. The full restore clock and complete
restore/search/write joins remain unchanged before footprint sampling.

The full Core run passes 128 Swift Testing tests plus four OAuth XCTest tests
in `.artifacts/native-projection-core-final.log`. Its 19 cache tests include
all-4,000-row content/order agreement, late-row corruption, duplicate documents,
wrong/missing import targets, extra/missing children, all-nil projection,
projector failures, cancellation and unchanged private state. A cancelled legacy
read followed by an accepted quarantine save verifies preserved drain behavior.

The native run passes 210 tests with three expected skips in
`.artifacts/offline-projection-native-reviewed.xcresult`. New real-SQLite
schedules cover complete/Unicode/optional metadata, hidden mappings, full-field
AND search and global ordering, plus sign-out while a completed projection is
held before publication. Existing activation, live-publication, quarantine,
outage and selection checks remain. The first metadata test incorrectly treated
token-refresh arrival as completion of local restoration; the corrected test
observes actual snapshot publication or a cache error before joining search.
The first failed run is preserved; no production change was needed for that fix.

Both search/open/return/scope and encrypted-relaunch/equation/figure/chat journeys
pass on each iPhone/iPad Simulator (four tests), in
`offline-projection-{iphone,ipad}-ui.xcresult` under `.artifacts/`. Exact source,
binary and capture hashes are in `offline-projection-native-source.json`.
Optimized resource results are recorded separately in
[Native resource acceptance](NATIVE_RESOURCE_ACCEPTANCE.md).

If remaining retention still exceeds the trigger, separately design a
lightweight complete catalog with bounded row hydration and a root-bound search
view. Re-decrypting all rows on each keystroke could add seconds, contend with
the store writer and delay cancellation; do not adopt that tradeoff without
measurement. No paged-search or storage redesign is selected here.

## Minimal APIs and transactions

The implemented Core APIs require the active store/account scope. Native image validation and session retirement remain the caller's responsibility.

| API | Required behavior |
| --- | --- |
| `cachedLibraryPresentation(scope)` | Restore the last complete presentation only; no live observation or command authority. |
| `cachedLibraryProjection(scope, project)` | Authenticate and validate the same complete checkpoint, then return projected rows in canonical order without accumulating every original DTO; never partial publication or live authority. |
| `saveLibraryPresentation(observation, scope)` | Accept an owned live `LibraryCompleteObservation`; atomically save complete rows/cursor and installed-copy eligibility guards. |
| `listInstalledReaderBundles(scope)` | Return at most 100 summaries, charged bytes and the authenticated store generation from the same read transaction, including blocked, damaged-header and no-longer-visible copies. No member hydration. |
| `beginReaderInstall(binding)`, `cancelReaderInstall(ticket)` | One ephemeral writer-owned operation ticket; cancelling an ended exact ticket is idempotent and cannot cancel a later operation. Cancellation does not change membership. |
| `commitReaderInstall(ticket, admittedBundle)` | Atomically insert a fully verified installation after current binding/eligibility/capacity checks. Exact installed-binding replay is idempotent. |
| `readReaderBundle(id, scope)`, `validateReaderOpen(token)` | Read only the selected immutable payload; the token carries full binding and access revision. Recheck account/writer, installation revision and current eligibility after asynchronous native verification, before presentation. |
| `removeReaderBundle(id, expectedRevision, scope)` | Atomically delete that installation, release its logical charge and invalidate pending work for it. Preserve membership/history/drafts. |

`ReaderArtifactBinding` is deployment, account, document ID, artifact ID and independently trusted manifest SHA-256. The compiled fixture supplies it initially. Future authorized delivery must supply it independently of downloaded bytes; a URL or manifest's self-reported hash is not authority. Do not silently substitute a different artifact.

Installation sequence:

1. Capture account/session, writer activation, binding and operation ticket; own the input bytes. Run Core verification and the shared native PNG/JPEG/ImageIO checks off the main actor and outside a SQL transaction. A Core-only `VerifiedReaderBundle` is not proof that native image admission ran.
2. Register the accepted commit with `ReaderLocalPersistence.acceptWrite` before awaiting it, following the existing retirement barrier. Prepare bounded ciphertext outside the transaction; measure whether this delays private writes unacceptably.
3. In one `BEGIN IMMEDIATE`, compare current authenticated metadata with the actor checkpoint, recheck the live ticket, current eligibility and both quotas, then insert members/header, update index/root digests and advance generation. No await occurs inside the transaction. Use current writer state, not a global generation captured before verification: unrelated draft writes may legitimately have advanced it.
4. Announce “Downloaded” only after commit. Reuse existing commit-uncertainty/reopen handling. Failure preserves the old copy; replay cannot duplicate an installation. Cancellation/removal prevents a stale operation from reinstalling it; a subsequent install needs new explicit intent. No durable downloading row or automatic restart is required for the initial local-fixture slice.

For presentation, seal bounded changed rows and reuse unchanged ciphertext. Commit changed rows, exact checkpoint, main-metadata digest and eligibility updates together. Reject older complete cursors, inconsistent content at the same cursor, disappearing retained identities and changes to immutable pins. Neither a receipt sequence nor a maximum row sequence is a complete cursor. Optional cache-write failure preserves the old cache and reports local persistence failure; it does not invalidate an otherwise valid live observation or replace command reconciliation.

Directory snapshots carry the authenticated metadata generation so a delayed listing cannot resurrect a removed copy in native presentation. An installation's separate access revision advances only when membership visibility or a blocking decision changes. Ordinary cursor progress or a remote outage persists the latest guard without invalidating verification of the same immutable bytes. Block/unblock transitions invalidate older open tokens even if the final state is readable again.

Restore cached presentation before awaiting network work, then start a fresh pull while retaining it. Keep it separate from live `LibraryCompleteObservation`: cached state cannot resolve a pending command or satisfy receipt-before-catch-up requirements. Offline command capture from a restarted cached snapshot remains outside this slice; retain [Native library commands](NATIVE_LIBRARY_COMMANDS.md).

During key activation, join command-coordinator callbacks before pausing bundle writes and prevent new model refreshes. At most one existing model refresh may cross that pause. Apply its eligibility immediately and retain its exact complete observation; the winning activation registers that checkpoint before accepting later refreshes or resuming commands. Cancellation still joins any accepted key update before resuming the prior writer. Never collapse an intervening quarantine into a later ordinary outage. A second unexpected deferred publication halts cache persistence instead of silently skipping policy history.

Cached import IDs, including hidden resolved mappings, may suppress duplicate queued-import rows. That is display deduplication only: ambiguous commands remain in the durable Changes queue until live catch-up resolves them. Captured paper-selection actions resolve against the current account's current library row and installed binding, so a stale button cannot reintroduce decrypted bytes after quarantine, removal or sign-out.

## Availability, session retirement and presentation

Local verified readability and remote download availability are separate. An ordinary remote storage outage preserves an eligible verified local copy. The current model's `canReadStructured` gate must not discard it solely because remote storage is unavailable.

An explicit matching quarantine or incompatibility observation retains encrypted bytes and their capacity charge, blocks reopening, and immediately clears the affected reader/selection/figure handle. Publish the live block and advance the coordinator's policy generation before waiting for disk. Fence in-flight install/open presentation against that generation; serialized store operations consult the latest persisted guard and never replace it with eligibility captured in an old ticket. If installation commits first, the later block still applies. If the block commits first, an older install cannot clear it.

Order guards by the complete cursor, item state sequence and explicit availability revision, not wall-clock dates. A newer explicit compatible/available observation, followed by current native validation, may clear the corresponding block. Missing, unknown, older positive or ordinary unavailable observations cannot clear it. Removing the blocked local copy does not erase its library observation; reinstall must consult that observation rather than infer eligibility from an absent installation.

If persisting an observation fails, retain live blocks and halt that activation's cache-persistence chain; do not skip the failed observation and claim a later save persisted every intervening policy transition. New installs must wait for accepted observation saves and remain refused while that chain is halted. A retry may resume only when it preserves the complete accepted ordering; otherwise a new activation must reconcile it. Existing network presentation/command reconciliation remain independent. Offline restarts know only the last successfully committed observation. **This cache does not provide immediate offline revocation.**

Membership removal hides the library row but does not automatically delete its explicit offline copy or chat data. The bounded installed-copy API must expose such copies for reclamation even when normal Library no longer shows them. The initial slice tests listing/removal without requiring a new storage-manager destination; any new navigation or independent opening route receives a separate concrete UX review.

Use the existing cached account identity and local key for offline restoration; do not require a successful token refresh before opening local data. Follow [Privacy and sync](PRIVACY_AND_SYNC.md#local-encrypted-event-journal): sign-out immediately clears presentation, stops new operations and invalidates callbacks; accepted old-account writes drain before a replacement writer activates. Fence callbacks by account session, writer activation, operation and artifact binding. Ordinary sign-out retains encrypted account partitions. Missing keys never allow plaintext fallback. Guest sample behavior remains memory-only and cannot inherit an account installation.

Reopen through the shared memory loader after decryption. Retain the immutable custom-scheme handler and existing document/manifest callback scopes; no plaintext extraction directories or network subresources. Keep membership, immutable artifact pins and availability consistent with [Data model](DATA_MODEL.md) and [Paper pipeline](PAPER_PIPELINE.md).

## Six acceptance gates

1. **Durable offline reading:** install, terminate, relaunch with all network unavailable and cached authentication expired, then use equations, figures and Contents and save a paper question through existing encrypted chat storage. Preserve exact raw-manifest formatting across reopen. The first synthetic Debug journey validates the storage/reader path only; an independent cached-authentication test and later authorized real-account artifact delivery must establish those additional boundaries.
2. **Atomicity, capacity and isolation:** reject missing/substituted members, wrong bindings/hashes, malformed images, quota boundaries and the 101st installation. Exercise disk-full and interruption around commit; preserve previous copies and private history/drafts. Test maximum bundle/member/image limits and all 4,000 maximum-envelope library rows; measure memory, transaction latency and WAL headroom. Corrupt one derived cache child without making private data unusable.
3. **Ownership and retirement:** switch/sign out/reactivate the same account during verification, commit and open. Accepted writes drain; stale callbacks, cancelled installs and remove-versus-install races cannot resurrect or present old data.
4. **Presentation versus command truth:** partial/failed pulls retain the last complete cache; distinguish optional cache-write failure from pull failure. Cached state, command receipts, stale cursors and inconsistent equal-cursor contents cannot falsely complete catch-up.
5. **Availability ordering:** remote outage preserves local reading; explicit quarantine/incompatibility clears presentation and blocks reopen after a successful checkpoint/restart while retaining bytes. Exercise blocks arriving during install/open, older completions, removal/reinstall and a newer explicit compatible observation. Do not claim offline freshness.
6. **Removal and migration:** remove an ordinary, blocked or damaged copy, including one whose library membership is gone; reclaim logical capacity without changing membership/history/drafts. Verify atomic format migration and stale-writer refusal. A failed migration leaves the previous recoverable private store intact.

## Current evidence and remaining verification

The full Core package passes **128 Swift Testing tests plus 4 separate OAuth XCTest tests (132 total)** in `.artifacts/native-projection-core-final.log`. This local run targets `arm64e-apple-macos14.0`. Coverage includes exact manifest restart, format-5 migration and migration rollback, earlier-format upgrade fixtures, fresh-writer fencing, partial-write rollback, cancellation/removal, sticky quarantine through removal/reinstall, ordinary-outage access-token continuity, corrupt-cache-child cases while private history/drafts remain usable, and the projection regressions above.

The maximum presentation fixture round-trips all 4,000 entries with 32,768-byte metadata, escaped/unknown fields and exact timestamps. Sealed rows total **137,816,679 bytes**, with a **34,455-byte maximum row**. The local wall times were about 2.57 seconds to commit and 2.33 seconds to restore. Separate real storage tests exercise 512 members, the 101st-copy refusal and the byte quota: after fifteen 32 MiB plaintext bundles, another 32 MiB bundle is refused without partial writes, while a 31 MiB bundle fits. Reopening/listing reads the compact directory rather than every member.

These Core measurements do **not** establish peak RSS, physical disk/WAL headroom, iOS latency or memory use, actual OS disk-full behavior or a process killed during commit. SQL-trigger failures verify transaction rollback; they do not replace those remaining failure tests.

The native restart journey installs the authored bundle under a synthetic membership, terminates the app, reopens encrypted rows, uses Contents/equation actions, saves an equation question, returns to the passage, opens a figure, and verifies the paper and saved question after a second restart. It passes on iPhone 17 Pro and iPad Pro 11-inch Simulators (`.artifacts/offline-reader-restart-reviewed.xcresult` and `offline-reader-restart-ipad.xcresult`). Relaunch has no sample-loader fallback or backend transport. The first iPhone run exposed test overscrolling past the intended figure; the recording showed a valid figure on screen before the test scrolled beyond it. The corrected journey waits for the passage return and uses bounded direction-aware scrolling; production scroll behavior did not change. Independent portrait screenshot review found no material equation/figure/chat layout regression. Raw LaTeX in saved chat remains later chat-rendering work.

The separate native model fixture uses normal cached Auth and device keys, real encrypted SQLite and held/failing HTTP responses. Its nine tests pass in `.artifacts/offline-native-reviewed.xcresult`, including opening before an expired-token refresh returns, preserving ordinary-outage readability, quarantine during key activation persisting before a later outage, sign-out during verification, stale selection refusal and cached-import display deduplication without granting live command authority. First-key recovery also preserves a pre-existing live observation while a newer in-flight quarantine arrives. The same full run passes all 154 native cases, with three expected live/device skips and no failures; it includes eleven bundle-coordinator checks and three new activation/retirement join regressions. Those regressions hold real accepted work or the Core actor, verifying that supersession, caller cancellation and sign-out cannot shorten an accepted key update's lifetime.

New storage controls, maximum-case iOS memory/latency, real disk-full/process-kill coverage, production downloads, physical-device locked-state behavior, cross-device reading-position sync and completed Mathpix import-to-read delivery remain separate work.
