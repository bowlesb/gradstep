# Native durable library commands

Status, 2026-10-03: **Core encrypted queue and native integration implemented and verified with deterministic fixtures**. Twenty-one focused Core queue cases pass; the complete package passes 98 Swift Testing cases plus four XCTest cases. The signed native suite passes 114 cases with three live/device checks skipped, including eleven coordinator schedules, eight transport checks, eleven library-service schedules and five model journeys. Two existing search/navigation journeys also pass. New Add/Pending screens were captured and inspected on iPad. These are local storage and simulated-HTTP workflow checks; live populated native mutation/acquisition remains unverified. Migration 010 is applied and immutable; this change needs no server migration and does not enable acquisition or paid processing. It builds on [the library contract](DATA_MODEL.md#migration-010--applied-and-verified-in-staging) and [local encrypted storage](PRIVACY_AND_SYNC.md#local-encrypted-event-journal).

## Storage and ownership

Use the existing account-scoped `EncryptedStore` actor and SQLite transaction discipline. Add a separate `local_library_commands(id, sealed)` table; do not encode these commands as `PrivateEvent`, append them to `records`, or put them in the encrypted-history outbox. Library membership is already service-visible. Local encryption protects the device copy; it does not make membership end-to-end encrypted.

Prefer this over another database or `SupportOutbox`-style files: one writer, protected directory, integrity checkpoint, ambiguous-commit reconciliation, and retirement barrier already exist. A second store would introduce another key/version/writer lifecycle without providing a required atomic boundary. Command transactions do not modify private history, drafts, or the private-history download cursor.

Authenticated metadata upgrades **format 4 → 5** and SQLite **schema 3 → 4** in one transaction after validating the complete old store. Older supported formats 2/3 upgrade directly while retaining their existing history. A required command ciphertext-digest manifest and monotonic local command sequence are added to encrypted metadata. Each row is sealed with the local-store key and a new `science-reader/local-library-command/v1` AAD domain binding account, backend deployment identity, and row UUID. The deployment identity binds to the configured Supabase origin/project, not only the mutable display label “staging.” Unknown versions or inconsistent manifests preserve the database and fail closed. Older writers fail the metadata/version comparison; private event envelopes and their wire format remain unchanged.

Limits per account/device: 64 independent unfinished targets, one reserved successor per target (128 unfinished rows total), 512 total rows, 16 KiB per sealed row, 8 MiB combined. Request bytes are limited to 2 KiB, retained receipt result to 2 KiB, and optional pending-row display text to 1 KiB. Store typed identities and small display hints, not arbitrary search-result JSON or full response entries. Reserve the successor row/bytes when admitting the first action so a full queue still permits its Cancel/reversal. Completion replaces the existing row and must fit its reserved maximum; a full queue cannot prevent acknowledgement, cancellation of an unissued intent, or cleanup. No unresolved operation is evicted to admit another.

Every mutation is registered with `ReaderLocalPersistence.acceptWrite` before UI acknowledgement. Sign-out clears presentation immediately, closes the command coordinator to new work, cancels transport, and drains accepted local transactions. Retire/join the coordinator before a replacement writer opens, including immediate return to the same account. A late response that was not already accepted for a local commit is ignored and reconciled by exact replay on return. Never hold a SQLite transaction across a network await.

`storeChanged`, integrity failure, or an unresolved local commit halts dispatch and rejects new commands until the store is explicitly reopened/reconciled. Do not continue networking with an old in-memory queue, reset the store, or mint replacement operations. An already-issued remote attempt remains uncertain through this pause.

Every queue snapshot validates current encrypted disk metadata against the actor's checkpoint, including its generation. After a safely rolled-back transient file error, a successful snapshot can authorize an explicit foreground/manual recovery attempt. A stale writer or unresolved commit stays fenced by `needsReopen`; snapshot reads cannot clear that fence.

Ordinary sign-out retains this account's encrypted queue and key. Content-key epoch changes do not change command IDs or arguments: rows use the separate local-store key. Future local-key replacement must migrate this table with metadata, history, and drafts. Loss of that key loses unsubmitted commands; cloud recovery cannot recreate them. A fresh authenticated library pull can recover server state, but must not automatically regenerate a lost uncertain command. Mutations require an unlocked, activated local store; library reads can remain available while private-key recovery is needed. Guest actions remain session-only and require explicit signed-in acceptance; they are never silently submitted to a later account.

## Intent, request and attempt are different records of progress

A sealed row contains a stable local intent UUID/sequence, account/deployment, row revision, typed action/target, captured observation, optional predecessor, frozen request, attempt marker, immutable receipt result, catch-up requirement, and bounded status/error. Time is not conflict authority; this implementation does not persist a retry schedule.

| Action | Capture from the user's observation | Frozen RPC arguments |
|---|---|---|
| Begin arXiv import | Normalized base source ID, optional exact revision, last **complete** library cursor | `v2_begin_import`: new operation UUID, source ID/revision, captured `observed_cursor` |
| Add/Remove known document | Actual document UUID; observed membership revision, including tombstones; approved asset identity for Add | `v2_set_library_item`: new operation UUID, document UUID, presence, captured revision, fixed optional approval UUID |
| Cancel/Retry existing import | Actual import UUID and observed `intent_revision` | Corresponding `v2_cancel_import`/`v2_retry_import`: new operation UUID, import UUID, captured revision |

Revision zero means absence in a complete library observation, not absence from a search result or unfinished baseline. Retry is available only for an observed failed, retryable import. A cancelled import needs a new explicit Add/import intent; `v2_retry_import` cannot revive it.

Before the first request, durably store the endpoint, exact encoded body, operation UUID, and a versioned digest binding those bytes and the account/deployment. Encode optional arguments consistently. This local digest need not reproduce PostgreSQL's JSONB digest; the stored body must reproduce the same SQL arguments. No retry edits the body, cursor, approval, revision, source, or UUID. Never reuse an operation UUID for another endpoint.

Use states such as `held`, `prepared`, `submittedUnknown`, `receiptAwaitingCatchup`, `needsReview`, `blocked`, and `finished`. Mark an attempt as possibly submitted **before** invoking transport. A crash between that commit and actual transmission is deliberately treated as uncertain. Timeout, cancellation, malformed/oversize response, process death, and lost acknowledgement cannot prove the RPC did not commit.

A source entered before any complete library observation stays unsubmitted input with no invented cursor or network authority. The Core queue does not yet persist this pre-baseline input. After a successful first pull, require a fresh user acceptance before freezing it; do not silently assign a newer observed cursor to an old offline gesture. With a prior complete snapshot, an offline gesture can freeze its original cursor/revision immediately. A later refresh never rebases it. Initial import means “queued on this device” until the server accepts it, and cannot promise offline acquisition, available bytes, or completed OCR.

## Exact replay, receipts and publication

One account coordinator dispatches at most one command at a time, using existing auth-generation checks, redirect refusal, actual response-byte bounds, and typed decoding. Each dispatch owns an opaque local handle, attempt UUID, exact frozen request, and the current store writer identity. The coordinator does not merge command-response entries into the reconciler; it uses them only to validate the receipt and establish the required catch-up floor.

If persisting an acknowledgement/failure is interrupted, a new attempt can supersede the uncertain marker with a fresh attempt UUID and the identical frozen request. Old callbacks then fail ownership checks. `canAttempt` expresses exact-retry eligibility, not whether the coordinator currently has transport running. This prevents a recoverable storage interruption from stranding work until process restart; the coordinator still serializes and bounds dispatch. A fresh store owner also fences old attempts without changing their request bytes.

Bind the decoded result to the captured request beyond generic wire validation: expected kind and target; begin-import result ID equals its operation UUID; cancel/retry result ID equals the import UUID; membership entries have the requested document UUID. An applied membership/import-intent command has the expected resulting revision; begin starts at revision 1. A replay's **current entry** may have advanced or reversed since that historical result. Existing pinned approval may differ from a redundant Add's supplied approval because 010 preserves established pins. Do not reject a valid replay merely because current presence/phase differs from the original action.

Persist a validated immutable result before announcing server acceptance. Its historical result must match on subsequent replay; `replayed` and the current entry are not immutable. Response loss before this local commit leaves the original request available for exact replay. A `revision_conflict` receipt is final for that operation: retrying it cannot apply a new revision. Show the current state and require a new explicit action/new UUID. If the requested effect is already current, describe it as already satisfied, not as an applied receipt.

**Do not publish a library snapshot directly from a command response.** A Cancel can withdraw both an import and its item, but its response contains only the import. Feed owned observations into the working reconciler if useful, then complete ordinary grouped catch-up. Persist a required observation floor equal to the maximum of receipt `seq` and returned entry `state_seq`; never assign that floor to the account cursor. An already-running pull with an older fixed upper boundary must finish, followed by another bounded cycle through the floor. For an absent-item conflict without a sequence, require a fresh complete pull begun after the response. Only a fully reconciled snapshot resolves the pending presentation.

If compaction resets the reconciler while a command is in flight, an otherwise owned/account-validated receipt can still be saved locally. A new baseline/catch-up fulfills the receipt's floor without carrying an old reconciler ticket across reset. If the account or coordinator was retired, discard the callback entirely; its exact stored request remains recoverable. Command receipt sequence, maximum row sequence, private-history cursor, and local store generation are four different values.

Keep structured server errors separate from receipts. Auth/lock/key failures pause; rate/capacity failures preserve the request and show a retryable reason. An unknown error never mints a replacement request automatically. A later rejection cannot erase uncertainty from an earlier possibly committed attempt, particularly because 010 performs some access checks before receipt replay. A trusted `operation_id_conflict` stops exact retry and places the original command plus any unfrozen successor in `needsReview`, preserving their evidence until explicit dismissal; it creates no receipt and cannot authorize a reversal. Each foreground/manual drain permits one transport attempt per operation, at most 16 distinct operations, and stops at the first error. Runnable Cancel and Remove commands take priority over additions, so an Add rejected at capacity cannot starve an unrelated action that frees capacity. Held reversals still wait for their own predecessor receipt. Remaining work stays visible. There is no retry timer or persisted time-based backoff in this implementation.

## Reversals, cancellation and removal

Keep the last complete server projection separate from typed local pending overlays. Pending imports use local intent/import identity and source metadata; they are never `Paper` values with fabricated document UUIDs. Removal may hide the local document or mark it pending according to the existing interaction, but the recoverable pending status must remain accessible. A failed operation cannot silently erase the last confirmed item. Receipt acceptance alone does not hide a ready import before its grouped item mapping arrives.

An unissued intent can be discarded transactionally only if the durable attempt marker proves no transport was started. Once possibly submitted, HTTP cancellation cannot undo it. Continue exact reconciliation and preserve a requested reversal as a separate held successor; never replace the first request's arguments.

The UI's Cancel action calls one atomic store method that inspects the current durable row and either discards it or holds its reversal. It must not decide from a snapshot and issue a second actor call: dispatch or receipt cleanup can intervene. A retained completed parent can still supply its own applied revision; an already-pruned handle is stale and never recreated. In that case refresh the visible state and require a fresh explicit action. A queue candidate cancelled before its attempt starts is similarly re-read rather than reported as a failed network request.

Allow one active action and one held successor per known target. For a user's reversal of their own pending Add/Remove, the successor may derive its precondition from the predecessor's **applied receipt revision**, not the newest returned row. Likewise Cancel after an uncertain begin-import waits for its applied receipt and uses that import's initial intent revision. Persist this dependency and materialize the successor's immutable request atomically with the predecessor receipt, so a crash cannot forget the reversal. If another device has since advanced the revision, the successor conflicts instead of overriding unseen intent. If the predecessor conflicts, leave the successor for explicit review. Never dispatch a dependent action before its predecessor is resolved. Further local changes may replace an entirely unissued held successor with a fresh intent, not mutate a dispatched command.

Cancel means withdraw **one import interest**. It must not be translated into a document Remove: another import or explicit Add may still own membership. Conversely explicit Remove uses the known document's membership revision and lets 010 establish its permanent removal fence. An unresolved source alias cannot be assigned a guessed document identity; its old observed cursor lets the server suppress a late restoration after Remove. Automatic worker checkpoints change `state_seq`, not the import intent revision, so ordinary progress must not require a new Cancel operation.

Finished rows may be pruned transactionally after their catch-up requirement is met and dependent successors have durable frozen requests. All acknowledgements/retries require an existing exact `(intentID, localSequence, attemptID)` row; they never upsert a missing command. The insertion API allocates fresh sequence/identity for a new user action, while retry takes an existing opaque handle. This permits bounded terminal cleanup without an unbounded UUID tombstone ledger. Late callbacks to pruned rows are stale. Ambiguous local commits use the existing encrypted metadata comparison; never recover by calling “enqueue new action” again. Unfinished or uncertain rows are retained regardless of age.

## API boundary and implementation order

Implemented public Core shapes (initializers and status fields omitted here; see `LocalLibraryCommand.swift`):

```swift
enum LibraryMutation: Codable, Equatable, Sendable {
    case beginImport(sourceID: String, requestedRevision: Int?, observedCursor: Int64)
    case setMembership(documentID: UUID, present: Bool,
                       expectedRevision: Int64, approvalID: UUID?)
    case cancelImport(importID: UUID, expectedRevision: Int64)
    case retryImport(importID: UUID, expectedRevision: Int64)
}
struct LibraryCommandScope: Equatable, Sendable { // immutable after binding
    let accountID: UUID
    let deploymentID: String // canonical configured Supabase origin/project
}
struct LocalLibraryCommandHandle: Equatable, Sendable {
    let intentID: UUID
    let localSequence: Int64
}
struct FrozenLibraryRequest: Equatable, Sendable {
    let operationID: UUID
    let endpoint: String // validated closed RPC allowlist
    let body: Data
    let digest: Data
}
struct LibraryCommandAttempt: Equatable, Sendable {
    let scope: LibraryCommandScope
    let handle: LocalLibraryCommandHandle
    let attemptID: UUID
    let request: FrozenLibraryRequest
}
struct LocalLibraryCommandSnapshot: Equatable, Sendable {
    let generation: Int64 // existing local store generation
    let commands: [LocalLibraryCommand] // bounded typed state/status rows
}

// EncryptedStore: actor-local, synchronous SQLite transactions; no network.
enqueueLibraryCommand(scope:mutation:display:) -> LocalLibraryCommandHandle
holdLibrarySuccessor(_:after:) -> LocalLibraryCommandHandle
beginLibraryAttempt(_:) -> LibraryCommandAttempt
cancelLibraryCommand(_:) -> LocalLibraryCommandSnapshot
recordLibraryReceipt(_:for:) -> LocalLibraryCommandSnapshot
recordLibraryFailure(_:for:) -> LocalLibraryCommandSnapshot
discardUnissuedLibraryIntent(_:expectedRevision:) -> LocalLibraryCommandSnapshot
reconcileLibraryCommands(completeSnapshot:) -> LocalLibraryCommandSnapshot
```

The store methods additionally take the command scope where it is not already bound into an attempt; `libraryCommandSnapshot`, `dismissLibraryCommand`, and `pruneLibraryCommands` expose observation/cleanup. `LibraryService` captures preconditions from its complete projection; the store validates typed bounds and persists them unchanged. Source normalization comes from the separate `ArxivReference` component, not a second URL parser in this queue. A held successor only describes a reversal of its known parent target; it receives immutable wire preconditions from that parent's validated applied result. No public completion API accepts arbitrary endpoint/body replacements.

Only `LibraryCompleteObservation`, constructed by a ready reconciler with no ahead-of-cursor entries or missing import/item mappings, can satisfy reconciliation. The coordinator guarantees a fresh post-receipt pull and passes the exact owned handle/receipt-ID pairs; a caller-supplied cursor alone is insufficient. `LibraryService` retains projection ownership and enforces a fresh complete pull after receipts; a separate command coordinator handles persistence/transport lifecycle. Expose independent queue and library generations/status so a failed pull cannot overwrite a later receipt or vice versa. Restore only pending display hints and exact intents initially: this implementation does **not** persist a full library/file cache or promise browsing the entire library offline after restart. Future web clients use the same server receipts and conflict semantics with their own device-local queue; queues themselves are not synchronized.

Implement/test core storage and the pure command state machine first, then bounded mocked transport/coordinator retirement, then existing Library/Browse actions and fixture journeys. Acquisition and actual asset availability remain separate release gates.

## Required deterministic schedules

1. Crash before enqueue commit; after commit before dispatch; after marking submitted before POST; after server commit before response; after receipt commit before UI/catch-up. No duplicated import or changed UUID/body.
2. Change normalized source/revision/cursor/approval under an existing handle; mixed endpoint or foreign-account delivery; immutable receipt changes. Reject without losing the original row.
3. Offline Remove revision N; another device Add/Remove advances it; reconnect. Exact original command conflicts; no automatic rebase. Lost Remove acknowledgement followed by another device Restore returns the old receipt plus current presence without removing again.
4. Begin lost acknowledgement → Cancel; Add lost acknowledgement → Remove; predecessor conflict; process death between receipt and successor dispatch. Exactly one frozen successor with the predecessor's revision, or explicit review.
5. Cancel races with resolution and alias B; explicit Add survives Cancel; explicit Remove precedes a late unresolved alias. Publish complete change groups with no duplicate paper or invented document ID.
6. Receipt/entry ahead of an already-fixed catch-up boundary; conflict with no ID; compaction during command delivery; malformed page after receipt. No cursor jump or partial publication; next refresh remains recoverable.
7. Sign-out at each local/network await; immediate same-account return; different-account login; old cancellation-ignoring callback. Immediate clear, one writer, no cross-account upload/publication, exact reconciliation on return.
8. Queue/byte limit, terminal cleanup, child dependencies, protected-storage failure, ambiguous COMMIT, corrupt/missing row, stale writer, format upgrade rollback and downgrade. Completion/reconciliation remains possible at capacity; unsent intent is never evicted.
9. Content-key rotation, missing local key, failed recovery, restart offline, and expired auth. Retain exact queued arguments where keys remain; accurately distinguish local pending intent from an accepted server import or available paper.

## Native integration evidence

- `.artifacts/library-command-core-tests.log`: full Core package, including authenticated format-4→5/schema-3→4 upgrade and rollback.
- `.artifacts/library-command-verified-native.xcresult`: final signed native suite, 114 passed / three live-device checks skipped / zero failures.
- `.artifacts/library-model-rendered-ipad.xcresult`: five model workflows with real Keychain/encrypted SQLite, simulated Auth/private sync/library HTTP, and settled UIKit sheet captures. Add → lost response → exact retry → one server import → Cancel and Remove → preserved private chat/draft pass. The capture helper waits for completed presentation and actual visible rows; an intermediate blank screenshot was not accepted as evidence.
- `.artifacts/library-command-navigation.xcresult`: existing search/open/return and Contents/chat/reader-location journeys, two passed.

The coordinator prioritizes runnable withdrawals at capacity, persists its submitted marker before HTTP, and requires complete post-receipt catch-up before clearing pending presentation. A transient local write rollback halts dispatch until explicit refresh authenticates the current disk metadata; a replaced writer remains halted. Unknown HTTP failures remain uncertain submissions, not definitive rejections. No native fixture contacts a live provider or downloads a paper.
