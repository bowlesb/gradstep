# Browser library storage — gate 2

**Reviewed design, storage foundation implemented 2026-10-08.** This extends
[BROWSER_OFFLINE_STORAGE](BROWSER_OFFLINE_STORAGE.md), after the schema-2 private journal.
The browser foundation is being implemented in an isolated branch; this document does not
claim deployment, enabled customer UI, cold offline startup, or completed capacity acceptance.
Root approved the three-store design and a single final reader-install transaction, subject
to measured memory and structured-clone acceptance. Saved-copy implementation has an independent
owner. No backend/native change or paid/provider operation is authorized by this work.

The source review used integration `f04b744`, including the future-IDB-version refusal fix. The current local
foundation adds schema-3 activation, bounded key inventory and fenced multi-head CAS in `idb.ts`; the complete
v5 reader/descriptors/copies remain gated below.
`library-descriptor.ts`, `KeyRing.descriptorKeys`, and the frozen descriptor interoperability
fixtures are existing reviewed crypto; use them without inventing a second envelope format.
The native descriptor/chunk queue in ASSET_SPENDING is a design contract. The current
`PDFUploadQueue.swift` is still a legacy queue and is not a safe implementation donor.

## Schema, scope and activation

Keep the IndexedDB database `gradstep`. Schema 3 adds `library`, `libraryDescriptors`, and
`readerCopies` beside `devices`, `activity`, and `journal`. Define separate constants for the
latest schema (3), journal introduction (2), and library introduction (3). Merely changing the
latest-version constant must not disable a deferred schema-2 journal or upgrade it implicitly.
New library records must not enter `journalPrefix`: journal loading verifies the exact child
count and its existing commit API compares one journal head.

Existing profiles activate schema 3 only after the existing explicit close/copy-old-tabs
acknowledgement and cooperative update proposal. Defer if a cooperating tab reports unsaved
work. A timeout or a BroadcastChannel reply set is not proof that all old tabs drained. The
compatibility release must reject an opened DB newer than its supported version even when
`indexedDB.databases()` is absent or throws; `f04b744` fixes that path. Never delete storage or
force refresh to unblock an upgrade. Preserve schema-2 journal behavior when activation is
deferred; the legacy read family remains available below source level 4. Show an explicit
update-needed state if an already adopted v5 partition cannot safely be read or written.

Each new domain uses keys prefixed by the existing device/account key, a domain name, and a
digest of the exact configured backend URL. Stable head slots point to children named by the
random local-store incarnation and opaque UUIDs/ordinals. Account scope includes exact backend
URL/project, environment, canonical account UUID, device ID and local-store incarnation;
`staging` alone does not identify a deployment. Titles, filenames, paths, descriptor payloads,
indexes and membership data are sealed values, never public IDB keys.

Domain codecs start at format 1 with authenticated minimum-reader/minimum-writer fields.
Heads authenticate scope, generation/revision, child identities/digests, counts and charged
ciphertext bytes. Child AAD includes domain, kind, format, full scope and immutable identity.
Use the existing nonextractable local AES-GCM key and a fresh nonce for every sealed record.
No raw keyring, management token, recovery code, signed URL or delivery grant is persisted here.
Unknown future codecs preserve bytes and refuse the domain. Missing heads with existing
children are damage, never permission to initialize an empty partition.

## Atomic storage interface

Add a finite multi-head compare-and-swap interface in `idb.ts`, separate from `journalAccess`:

- `read(keys)` obtains the requested domain heads in one readonly transaction.
- `keys(store, lower, upper, limit)` is a bounded key-only inventory; do not hydrate all copies.
- `commit(compare, put, remove, deviceGuard)` compares exact predecessor ciphertext for each
  head, then applies the finite mutation in one readwrite transaction with `devices`.

The required device guard is the captured device key/ID, WriterFence, and synchronous
`current()` predicate. The transaction checks the same stored admission/incarnation, login
lifetime, writer generation/instance, device identity and persisted-current-auth condition as
the journal. It resolves only after transaction completion; use strict durability where
supported. All encryption, hashing, validation and network work happens outside the transaction.
An account writer Web Lock reduces competing plans; CAS is the authority. Network leadership
and one-reader-install locks are separate and do not hold the local writer lock across fetch.
Broadcast only opaque invalidation hints, never private text or authorization decisions.

A complete library update atomically commits its checkpoint/changed rows and affected saved-copy
eligibility/directory. A copy installation compares the exact latest library and copy heads plus
its captured save/remove intent before publishing. Reads that decrypt or verify asynchronously
must revalidate their exact roots, intent and live authority before exposing a result.

## Complete v5 library and command parity

The library domain has a small independent protocol/adoption head and a replaceable complete
presentation checkpoint with per-row ciphertext. Durable v5 adoption and pending online-command
intent/receipts must not belong only to a disposable presentation checkpoint. Same-ID recovery
of an online command is distinct from accepting new mutations while offline, which remains out
of scope. Explicit Forget intentionally erases adoption and every account-domain record.

Negotiate `v1_reader_capabilities` per account/login before selecting a family. Only its exact
missing-RPC response may choose legacy full-v3, and only when this account/deployment has never
durably adopted v5. Transient errors, unauthorized/malformed capabilities, absent v5 dependencies
and schema-cache inconsistency must not downgrade a v5 partition. Disabled PDF ingress still
allows existing upload rows and their descriptors to be read.

Full-v5 is body format 2, source level 4, and a required dataset epoch. Compact-v4/v5 are different
protocols. Decode upload identities, descriptor references, hidden imports/source-null tombstones,
all current typed item fields and `auto_retry_at`; pin the decoded field set in snapshot tests.
Validate account/context on every page before applying rows or cursors. Persist only a complete
baseline plus fixed-boundary catch-up, including retained identity mappings and tombstones.

A validated same-context v5 checkpoint seeds a reconciler as `catching_up`, never ready. Fresh
authenticated catch-up is required to produce a CompleteObservation, capture a command or admit
a new download. A changed context stages a fresh full baseline and catch-up, then atomically
replaces the checkpoint, allowing lower cursors only at that boundary. Keep strict monotonic
identity/revision checks within one context. Epochless v3 snapshots cannot establish continuity
for command authority on restart.

Enable all six migration-042 adapters with v5 reads: begin import, set library membership, cancel
import, retry import, archive, and tags. Freeze the endpoint family, epoch, operation ID, body and
cursor/revision preconditions from the supplying CompleteObservation. Never substitute v2 or a
new epoch during retry. Validate the receipt epoch before comparing its floor; show success only
after a canonical complete read observes the receipt. A lost response reuses exactly the same ID
and body. An accepted receipt followed by a failed pull retries only the pull. A detected context
change preserves old pending intent as needs-review. A server advertising v5 but lacking the
write wrappers fails explicitly; it does not silently disable commands or downgrade reads.

## Private descriptors and complete title index

The independent descriptor domain contains authenticated exact envelope references/cache and a
separate bounded outbox. Replacing a library row/checkpoint must not erase a pending title edit.
Hydration batches at most 24 distinct exact ID/revision requests, verifies response format/account,
source identity, reference ID/revision/key epoch/digest, then uses the existing descriptor codec.
A stale-reference response triggers bounded catch-up; it is not stored under the old request.
Retain unsupported, missing-key and corrupt envelopes as bounded opaque evidence and present a
neutral locked title. Do not make one failed private title break the whole library or retry forever.
Source-null tombstones cannot manufacture a source identity for hydration.

Derive search/sort over the entire complete library: visible and archived items plus displayed
imports, including rows outside the viewport. Index generation binds the complete library head,
descriptor-head generation and key epoch. Hydrate from cached envelopes on reopen and rebuild the
plaintext index in memory. Publish completeness only once every required reference is resolved
or explicitly locked; show Updating titles during hydration and Some titles are locked when
results are incomplete. Partial private-title search cannot claim a complete No results result.
Invalidate in-flight search and ordering when another device changes a title or keys/context change.
Private display names and filenames never enter server search queries, URLs or provider prompts.

The exact descriptor outbox is designed as scope/context, source ID, expected revision, immutable
sealed envelope, mutation ID, local edit intent, phase, and recorded result/conflicting reference.
Seal once and durably commit before dispatch. Caller device and management token are supplied from
current approved authority at dispatch, not persisted as request identity. Persist a receipt before
observation. An attached edit completes only after fresh library reference plus exact hydration;
an unattached source uses authoritative upload status. A conflict retains the edit for explicit
review. Unknown outcomes are never resealed. Detected dataset changes pause entries as needs-review.

**Descriptor writes remain paused in this browser slice.** No code may dispatch the existing
unfenced PUT or invent a legacy fallback while the following server contract is missing.

### Concrete contract request to the backend owner

Add a separately reviewed epoch-bound descriptor PUT accepting `p_dataset_epoch` plus the existing
source/expected revision/caller/token/exact envelope arguments. It must reject a mismatched epoch
before interpreting old revision preconditions and hold a final config-row epoch fence through
commit, as migration 042 does for ordinary library commands. A response must bind account and epoch.

Preserve current same-ID receipt semantics: current caller authorization/management authority is
required; an accepted exact envelope may be replayed by a surviving or recovered approved device,
regardless of its original author/key epoch. The request identity must remain immutable; changing
source, expected revision or envelope under one mutation ID must fail. Specify whether epoch is
part of that identity and how a restored database with no receipt rejects an old-domain mutation.
It must not accept a receipt or apply an old command under a replacement epoch. Clarify the
permissions/grants for authenticated callers and maintain source ownership checks, receipt/rate
limits and finite error responses. No read-only receipt resolver is currently available; one may
be separately designed if resolving old-domain outcomes without mutation is required.

Source proof: migration 039 lines 1492–1553 has no dataset-epoch argument/check. Its request digest
at 1523 excludes dataset epoch; 1525–1530 returns an existing receipt before the stale-author/key
check at 1532; 1540–1547 applies when the current descriptor revision/ID match. Therefore a restore
that removes a former receipt and restores a matching expected revision can permit an old mutation
again if current authority/key conditions still hold. This is a control-flow inference, not a
hosted reproduction. Client preflight cannot close a restore occurring between preflight and PUT.
By contrast, migration 042 lines 31–42 and 45–100 check the requested epoch and hold the final
`FOR SHARE` config lock until command commit. Descriptor hydration (039 lines 1555–1577) also has
no epoch; accept it only against an exact observed reference including digest/key epoch and current
local context generation, never revision number alone.

## Saved copies and ordered eligibility

The independent copy owner will implement directory → header → raw members, all authenticated.
`VerifiedBundle` must preserve the exact raw manifest bytes; JSON re-serialization is not a hash
proof. Delivery must compare item/document/artifact to the selected typed item. A saved binding
includes account/deployment/dataset, item/document/approval/version, artifact/manifest, membership
intent and availability revision. Reuse RAM only when that exact binding and current eligibility
remain valid. Normal reading does not automatically promise a downloaded copy.

For the first implementation, prepare and verify one bundle (at most 32 MiB aggregate members),
encrypt outside IDB, then put all members/header/directory/counters in one final fenced transaction.
No partial record set is committed, so no implicit orphan cleanup or staging namespace is needed.
This choice is provisional on actual peak memory and structured-clone measurement. If it fails,
introduce a separately reviewed authenticated staging manifest, charge all staged/retired bytes,
then atomically publish the directory; do not improvise unreferenced child writes.

On open, authenticate raw stored bytes and rerun the existing verifier, then revalidate roots,
intent and live authorization after all awaits. Never deserialize a trusted VerifiedBundle or
cached DOM. Known removal/quarantine/incompatibility immediately retires the live handle and
increments local policy generation before awaiting guard persistence. Persist ordered observations;
a failed guard transaction leaves that observation pending and latches a cache-safety error. An
outage, unknown state or older observation cannot skip or clear the failure. Do not claim a failed
write itself was durable.

Port the native eligibility reducer. Same-context newer authoritative positive state can clear
eligible guards. During a dataset transition ordinary previously eligible copies remain readable
while the new baseline stages. A new complete observation blocks missing/removed/changed artifacts;
previously blocked old-domain bindings remain blocked. `reader-artifact/index.ts` lines 25–32 and
61–65 accepts item/transport and returns artifact/manifest identity but no epoch-bound authorization
proof, so this slice has no safe cross-epoch unblocking path. Local Remove download deletes bytes
without erasing retained unsafe binding evidence.

## Bounds, failures and acceptance

Preserve 4,000 complete retained entries, 64 KiB per sealed row and 256 MiB total library-domain
ciphertext. The current native checkpoint limit is 2 MiB, including at most 4,000 retained unsafe
artifact bindings; these are never evicted to fit. Proposed descriptor bounds are 4,000 exact
reference records at 8 KiB each and 128 pending edits at 16 KiB each. Charge them within the library
allocation, reserving 4 MiB for coordination/pending-work records. Measure exact encoded counters
before finalizing admission; a 4,000-entry limit alone does not prove all maximally sized rows plus
descriptors fit. Overflow preserves existing records and reports an explicit capacity condition.

Copies remain 100 installations/512 MiB ciphertext inclusive of blocked copies and overhead, with
a 128 KiB directory reserve and 512 KiB maximum header. Explicit remove only; no silent LRU. Never
hydrate all saved bundles to list storage. Storage estimates are advisory and persistence requests
must report their actual result. Quota errors roll back, preserve unsynced work and show controls.
Corruption in library/copy records cannot reset the private journal or descriptor outbox. Unknown
future formats preserve bytes and give an update instruction.

Sign-out/auth retirement aborts presentation/network work and rejects late writes/publication while
retaining sealed partitions. Forget extends its existing transaction to all three new store
prefixes, device/activity/journal records, then leaves only the fresh opaque admission-incarnation
fence. No extra asynchronous cleanup may recreate a forgotten partition. Gate 2 still needs online
key preparation and available app assets; gate 3 owns cold disconnected startup and the app shell.

Required tests include real-IDB atomic abort/quota behavior, concurrent root conflicts, auth
retirement/same-account new login, Forget during crypto, old-version opening without version
enumeration, and deferred schema-2 journal access. Protocol fixtures cover all six exact v5 commands,
wrong context on every page/receipt, complete hidden mappings, lost response, post-receipt failed
pull, lower-cursor context reset and refusal to downgrade. Descriptor tests include existing frozen
vectors, exact hydration, locked keys, title beyond the first page, rename generation invalidation
and paused writes. Copy tests cover save/remove/guard races after verification, failed guard then
outage, same-context positive unblock, cross-context sticky blocks, corrupt-child isolation, quota,
reopen without hosted delivery, cancellation and measured bounded memory. Use isolated local
fixtures; no provider, hosted, deployment or physical-phone operation is part of acceptance.
