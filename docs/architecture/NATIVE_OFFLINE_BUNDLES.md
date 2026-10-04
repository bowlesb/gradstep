# Native offline reading bundles

Status, 2026-10-03: **Implementation proposal; storage and model integration are not implemented.** The first slice explicitly installs the existing authored bundle into one account's encrypted store, then supports offline relaunch. Preserve Library, Paper, Contents, figures and chat. Production artifact delivery and the final [Mathpix pipeline](MATHPIX_PIPELINE.md) remain separate gates.

The [Core verifier](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/ReaderBundle.swift) now retains exact authenticated `manifestData`. The [native loader](../../apps/apple/ScienceReader/Services/ReaderBundleLoader.swift) has directory and memory entry points sharing PNG/container/ImageIO admission. These are prerequisites, not durable installation. Library presentation is still memory-only.

## Selected policy and bounds

Per account and deployment, allow **512 MiB of committed bundle ciphertext and 100 installations**, whichever limit is reached first. Allow one install at a time, explicit downloads only, and no automatic eviction. Blocked copies still count. Refusing an install preserves every existing copy. Local-copy removal leaves membership, history and drafts intact.

Count sealed bundle directory, headers and member bytes, including encryption overhead; the 32 MiB plaintext payload limit is not the charged ciphertext size. Preserve current per-bundle limits: 512 members, 32 MiB aggregate member bytes, 16 MiB per member, 256 KiB raw manifest and 16,000,000 aggregate image pixels. Do not change renderer admission to fit the cache.

Use a separate **256 MiB logical ciphertext cap for complete library presentation**. [LibraryWire](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/LibraryWire.swift) permits 4,000 retained entries. Its metadata validation already bounds the same JSONEncoder representation to 32,768 bytes. A versioned local row can reserve 64 KiB sealed: metadata stays a typed JSON object, with less than 8 KiB conservatively reserved for the remaining bounded fields, local identity/version envelope and AES-GCM overhead. That envelope allows 3.1 KiB for source ID plus derived URL, including worst-case JSON scalar escaping; 1.2 KiB for three 64-byte readiness/availability strings; 1 KiB for UUIDs, canonical timestamps and numeric values; and 2 KiB for fixed keys, enums, booleans, the local envelope and encryption overhead. Use the same slash-escaping policy and canonical timestamp encoding. Prove that envelope against every field when implementing; do not base64-encode metadata or silently truncate fields.

At 4,000 sealed rows of 64 KiB plus a sealed checkpoint of at most 1 MiB, the maximum is **263,192,576 bytes (251 MiB)**, below the separate 256 MiB cap. Test maximum valid metadata, escaping/Unicode, all optional fields, unknown bounded availability values and the full entry count. A future wire expansion needs an explicit local-format/bounds review.

These are logical quotas, **not physical disk or process-memory guarantees**. SQLite pages, indexes, free pages, WAL, transactions and private history require additional space. Removal frees logical capacity but does not promise file shrinkage or secure erasure. Free-space preflight is advisory; disk-full rollback must preserve the last committed state. Do not add automatic VACUUM to this slice.

Lazy member reads are necessary: existing SQLite blob bindings/reads copy Data, and verification owns immutable copies. Never hydrate the 512 MiB cache on activation. One maximum bundle still requires input, verification, encryption/SQLite and image-decoding headroom. A full library presentation can itself approach 128 MiB before Swift object overhead. Iterate bounded rows off the main actor, avoiding a second giant serialized snapshot, and measure maximum-case memory, WAL growth and write latency. If full presentation hydration is unsuitable on the supported devices, implement paged local presentation before beta; do not advertise a partial snapshot as complete or silently reduce the server's 4,000-entry contract.

## Persistence layout and authentication

Extend the existing account-partitioned [EncryptedStore](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/EncryptedStore.swift), using its local-store key, protected database and serialized writer. Cache records are not private-history events or sync-outbox entries. Use versioned local DTOs; do not persist reconciler tickets or reconstruct them from Codable data.

Proposed tables:

| Table | Encrypted contents and bounds |
| --- | --- |
| `local_library_cache_checkpoint` | One sealed checkpoint: format, deployment/account, committed complete cursor, informational capture time and exact opaque row-ID/ciphertext-digest manifest; at most 1 MiB. |
| `local_library_cache_entries` | Opaque local row UUID plus sealed complete item/import DTO, including hidden entries/tombstones and import mappings; at most 4,000 rows, 64 KiB sealed each. |
| `local_reader_bundle_index` | One sealed directory, at most 128 KiB: shared deployment/account scope and at most 100 installation summaries, immutable bindings, header digests/lengths, charged bytes, local revisions and latest observed eligibility guards. |
| `local_reader_bundle_headers` | Installation UUID plus sealed header: exact raw manifest bytes, binding and member ordinal/ciphertext-digest/length list; at most 512 KiB sealed. This accommodates the bounded manifest even if its Data is base64-encoded in the header DTO. |
| `local_reader_bundle_members` | Installation UUID, bounded ordinal and directly sealed raw member bytes; primary key on installation/ordinal, foreign key to its header. At most 512 per installation, each at most its 16 MiB plaintext ceiling plus AES-GCM overhead. |

Store only the cache-checkpoint and bundle-index ciphertext digests in authenticated main metadata. The index includes account/deployment once; summaries do not duplicate long deployment strings or full titles. Keep member manifests and library rows out of main metadata so a draft checkpoint does not rewrite the entire cache. Read display metadata from cached library rows or the selected bundle header when needed.

The authentication chain is main metadata → checkpoint/index → entry/header ciphertext → member ciphertext. Use distinct versioned AAD domains with unambiguous account/deployment, row/installation identity, full artifact binding and member ordinal. Fresh AES-GCM nonces are mandatory. Manifest hashes additionally bind plaintext paths, roles, lengths and contents. Validate ciphertext length in SQLite before allocating blob Data, then verify exact row sets, digests, AEAD and decoded bounds.

Plan a coherent metadata-format 5 → 6 and SQLite-schema 4 → 5 migration, preserving existing earlier-format upgrades. Audit every initializer, migration, commit and reopen/writer fence: current commits explicitly reset format to 5, and some readers test equality with 5. Updating only DDL would be unsafe. A fresh actor reopening the store must advance the writer generation even when no drafts are pruned and no library commands exist; ordinary same-account activation still reuses its actor. Migration is atomic after validating the existing store; stale older writers cannot downgrade or publish over it. Private event wire formats and content-key epochs do not change.

Do not decrypt cache bodies during private-history/draft recovery. Missing, oversized or corrupt cache children fail the affected presentation/bundle retrieval, retain their bytes and charged capacity, and never reset private data. Private writes preserve cache roots even when a child is unreadable. An authenticated valid directory permits explicit removal of a damaged bundle without decrypting its damaged members. Corruption of the authenticated main metadata or underlying database remains subject to the existing store-wide fail-closed rules.

## Minimal APIs and transactions

Names are provisional; all operations require the active store/account scope.

| API | Required behavior |
| --- | --- |
| `cachedLibraryPresentation(scope)` | Restore the last complete presentation only; no live observation or command authority. |
| `saveLibraryPresentation(observation, scope)` | Accept an owned live `LibraryCompleteObservation`; atomically save complete rows/cursor and installed-copy eligibility guards. |
| `listInstalledReaderBundles(scope)` | Return at most 100 summaries and charged bytes, including blocked, damaged-header and no-longer-visible copies. No member hydration. |
| `beginReaderInstall(binding)`, `cancelReaderInstall(ticket)` | One ephemeral writer-owned operation ticket; cancellation revokes this operation, not membership. |
| `commitReaderInstall(ticket, admittedBundle)` | Atomically insert a fully verified installation after current binding/eligibility/capacity checks. Exact installed-binding replay is idempotent. |
| `readReaderBundle(installationID)`, `validateReaderOpen(token)` | Read only the selected immutable payload; recheck account/writer, installation revision and current eligibility after asynchronous native verification, before presentation. |
| `removeReaderBundle(id, expectedRevision)` | Atomically delete that installation, release its logical charge and invalidate pending work for it. Preserve membership/history/drafts. |

`ReaderArtifactBinding` is deployment, account, document ID, artifact ID and independently trusted manifest SHA-256. The compiled fixture supplies it initially. Future authorized delivery must supply it independently of downloaded bytes; a URL or manifest's self-reported hash is not authority. Do not silently substitute a different artifact.

Installation sequence:

1. Capture account/session, writer activation, binding and operation ticket; own the input bytes. Run Core verification and the shared native PNG/ImageIO checks off the main actor and outside a SQL transaction. A Core-only `VerifiedReaderBundle` is not proof that native image admission ran.
2. Register the accepted commit with `ReaderLocalPersistence.acceptWrite` before awaiting it, following the existing retirement barrier. Prepare bounded ciphertext outside the transaction; measure whether this delays private writes unacceptably.
3. In one `BEGIN IMMEDIATE`, compare current authenticated metadata with the actor checkpoint, recheck the live ticket, current eligibility and both quotas, then insert members/header, update index/root digests and advance generation. No await occurs inside the transaction. Use current writer state, not a global generation captured before verification: unrelated draft writes may legitimately have advanced it.
4. Announce “Downloaded” only after commit. Reuse existing commit-uncertainty/reopen handling. Failure preserves the old copy; replay cannot duplicate an installation. Cancellation/removal prevents a stale operation from reinstalling it; a subsequent install needs new explicit intent. No durable downloading row or automatic restart is required for the initial local-fixture slice.

For presentation, seal bounded changed rows and reuse unchanged ciphertext. Commit changed rows, exact checkpoint, main-metadata digest and eligibility updates together. Reject older complete cursors and inconsistent content at the same cursor. Neither a receipt sequence nor a maximum row sequence is a complete cursor. Optional cache-write failure preserves the old cache and reports local persistence failure; it does not invalidate an otherwise valid live observation or replace command reconciliation.

Restore cached presentation before awaiting network work, then start a fresh pull while retaining it. Keep it separate from live `LibraryCompleteObservation`: cached state cannot resolve a pending command or satisfy receipt-before-catch-up requirements. Offline command capture from a restarted cached snapshot remains outside this slice; retain [Native library commands](NATIVE_LIBRARY_COMMANDS.md).

## Availability, session retirement and presentation

Local verified readability and remote download availability are separate. An ordinary remote storage outage preserves an eligible verified local copy. The current model's `canReadStructured` gate must not discard it solely because remote storage is unavailable.

An explicit matching quarantine or incompatibility observation retains encrypted bytes and their capacity charge, blocks reopening, and immediately clears the affected reader/selection/figure handle. Publish the live block and advance the coordinator's policy generation before waiting for disk. Fence in-flight install/open presentation against that generation; serialized store operations consult the latest persisted guard and never replace it with eligibility captured in an old ticket. If installation commits first, the later block still applies. If the block commits first, an older install cannot clear it.

Order guards by the complete cursor, item state sequence and explicit availability revision, not wall-clock dates. A newer explicit compatible/available observation, followed by current native validation, may clear the corresponding block. Missing, unknown, older positive or ordinary unavailable observations cannot clear it. Removing the blocked local copy does not erase its library observation; reinstall must consult that observation rather than infer eligibility from an absent installation.

If persisting a block fails, retain the live block and report the failure; do not claim durable acknowledgement. Offline restarts know only the last successfully committed observation. **This cache does not provide immediate offline revocation.**

Membership removal hides the library row but does not automatically delete its explicit offline copy or chat data. The bounded installed-copy API must expose such copies for reclamation even when normal Library no longer shows them. The initial slice tests listing/removal without requiring a new storage-manager destination; any new navigation or independent opening route receives a separate concrete UX review.

Use the existing cached account identity and local key for offline restoration; do not require a successful token refresh before opening local data. Follow [Privacy and sync](PRIVACY_AND_SYNC.md#local-encrypted-event-journal): sign-out immediately clears presentation, stops new operations and invalidates callbacks; accepted old-account writes drain before a replacement writer activates. Fence callbacks by account session, writer activation, operation and artifact binding. Ordinary sign-out retains encrypted account partitions. Missing keys never allow plaintext fallback. Guest sample behavior remains memory-only and cannot inherit an account installation.

Reopen through the shared memory loader after decryption. Retain the immutable custom-scheme handler and existing document/manifest callback scopes; no plaintext extraction directories or network subresources. Keep membership, immutable artifact pins and availability consistent with [Data model](DATA_MODEL.md) and [Acquisition](ACQUISITION.md).

## Six acceptance gates

1. **Durable offline reading:** install, terminate, relaunch with all network unavailable and cached authentication expired, then use equations, figures and Contents and save a paper question through existing encrypted chat storage. Preserve exact raw-manifest formatting across reopen.
2. **Atomicity, capacity and isolation:** reject missing/substituted members, wrong bindings/hashes, malformed images, quota boundaries and the 101st installation. Exercise disk-full and interruption around commit; preserve previous copies and private history/drafts. Test maximum bundle/member/image limits and all 4,000 maximum-envelope library rows; measure memory, transaction latency and WAL headroom. Corrupt one derived cache child without making private data unusable.
3. **Ownership and retirement:** switch/sign out/reactivate the same account during verification, commit and open. Accepted writes drain; stale callbacks, cancelled installs and remove-versus-install races cannot resurrect or present old data.
4. **Presentation versus command truth:** partial/failed pulls retain the last complete cache; distinguish optional cache-write failure from pull failure. Cached state, command receipts, stale cursors and inconsistent equal-cursor contents cannot falsely complete catch-up.
5. **Availability ordering:** remote outage preserves local reading; explicit quarantine/incompatibility clears presentation and blocks reopen after a successful checkpoint/restart while retaining bytes. Exercise blocks arriving during install/open, older completions, removal/reinstall and a newer explicit compatible observation. Do not claim offline freshness.
6. **Removal and migration:** remove an ordinary, blocked or damaged copy, including one whose library membership is gone; reclaim logical capacity without changing membership/history/drafts. Verify atomic format migration and stale-writer refusal. A failed migration leaves the previous recoverable private store intact.

Implement Core persistence/failure tests first, then the account-owned coordinator/model and one Simulator install–restart journey. New storage controls, production downloads, physical-device locked-state behavior, cross-device reading-position sync and completed Mathpix import-to-read delivery remain separate work.
