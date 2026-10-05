# Privacy, key custody, and synchronization

Status: device-held keys approved; iPhone/iPad first, with the browser reader authorized afterward. Implementation and verification remain in progress. This is not a shipped privacy guarantee.

## Recommendation and alternatives

Encrypt private conversation history, chat titles, selected passages, notes, highlights, and private generated diagrams before durable cloud storage. Prefer device-held keys, with account authentication and key recovery treated as separate operations.

| Model | Database/storage theft | Service can decrypt history? | New device / lost devices |
|---|---|---|---|
| Platform disk encryption + RLS | Protects storage media; readable application queries still return plaintext | Yes | Ordinary account recovery |
| Application encryption, server-held key | A database-only export is insufficient when the key service is separate | Yes, through authorized application/key service | Ordinary account-assisted recovery |
| Device-held keys for private content | Server stores ciphertext and wrapped key material | No standing key to decrypt stored history | Approved device or saved recovery code |

Supabase documents storage and backup encryption. That is a useful baseline, but it does not make authenticated database queries return encrypted message bodies. [Supabase security measures](https://supabase.com/legal/customer-resources/data-processing-addendum)

Device-held keys have a real product cost: losing all approved devices and the recovery code loses access to encrypted history. The service can help recover the account but cannot secretly recover the content. The onboarding/recovery design must explain this without adding a password prompt to ordinary reading or chatting.

Server-managed content keys are excluded from the selected design. Do not retain a second plaintext chat store or add account-assisted content recovery that bypasses the user's device/recovery keys.

## Account sign-in and identity linking

The user requested TextBrain's Apple/Google interaction pattern on 2026-10-03 and delegated the password decision. Launch customer sign-in uses native Sign in with Apple, Google through `ASWebAuthenticationSession`, and an email one-time code fallback. No username/password form is planned for customers. The current password-based development fixture interface is not the launch policy. Provider configuration, custom email delivery, and end-to-end verification are still outstanding.

Use dedicated app/provider registrations for this backend. Native Apple sign-in binds a secure random nonce to the identity token (SHA-256 in Apple's request, raw nonce in the Supabase exchange). Google uses a per-attempt random PKCE verifier and S256 challenge. Accept only the configured callback scheme/host/path and one bounded authorization code; never ingest bearer tokens from URL fragments. Bind each result to the active sign-in attempt and authentication generation. Cancellation, sign-out, account switching, or a newer sign-in invalidates older callbacks before they can save a session. Keep verifiers/nonces in memory and require a fresh sign-in after process termination. Never log identity tokens, callback URLs, codes, or provider response bodies.

TextBrain's local reference implements native Apple token exchange and a retained system browser session for Google, explicitly hopping its `@Sendable` callback onto the main actor. Reuse that interaction and concurrency pattern, with a defined failed-start path and exactly-once continuation completion. The new app's existing account-scoped session/key handling remains authoritative.

Supabase's stable user UUID owns library membership, encryption keys, reports, and purchases. Only the Auth service may establish identity links. Verified same-email linking follows its documented policy; Apple private relay addresses can differ from Google addresses, so offer explicit linking while already signed in. Never merge separate user UUIDs or transfer purchases based on a client-supplied email or matching display name. If an identity already belongs to another account, preserve both accounts and report the conflict. Login/account recovery does not recover private-content keys. Manual-linking behavior, callback account binding, identity removal, and Apple token revocation on account deletion need integration tests before release.

Email delivery must use a verified sender with bounded sending/verification rates and code expiry before exposing the fallback. Administrators still require server-enforced MFA regardless of their initial sign-in provider. [Supabase Apple sign-in](https://supabase.com/docs/guides/auth/social-login/auth-apple), [Google sign-in](https://supabase.com/docs/guides/auth/social-login/auth-google), [identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking).

## Information visible to the service

| Data | Proposed treatment |
|---|---|
| Eligible shared papers, reusable OCR, public metadata | Readable by the processing/search service; reuse according to access/license policy |
| Private uploaded papers | Owner-scoped storage and explicit cloud OCR processing; this does not automatically inherit the private-chat E2EE claim |
| Chats, titles, selected-text anchors, notes, private diagrams | Encrypted by the client before persistence and synchronization |
| Library membership, file size, timing, devices, usage, subscription | Service-visible metadata needed for access, synchronization, and billing |
| AI requests and responses | Selected plaintext visible to the chosen cloud provider and processing service during the request |
| Submitted bug screenshots/notes | Explicitly shared with support after preview; separate support retention/access policy |

Protect local private content too: encrypted persistence, protected Keychain keys, and no plaintext message bodies in logs, crash reports, analytics, notification previews, or unencrypted search indexes. Search private history locally using an encrypted index or an in-memory index rebuilt from encrypted records. Decide the exact local storage implementation in the prototype; SwiftData alone is not a custom encryption system.

### Local encrypted event journal

Use SQLite transactions with WAL and full synchronization for local history. Each immutable event envelope is additionally AES-GCM sealed with the device's local-store key, binding account, local ordinal, and event ID. No private text, title, anchor, or key enters an SQL column. The encrypted metadata record contains account identity, contiguous download cursor, pending event IDs, record count, generation, and a SHA-256 hash-chain commitment to the ordered encrypted records. On open, authenticate all records and the commitment before exposing state. Missing, reordered, substituted, or corrupt records must not become an empty store.

Appending commits a sealed record, outbox membership, and updated commitment in one transaction. Pulling commits all new records, matching outbox removals, and the page cursor together. Acknowledging an upload changes only encrypted outbox metadata; it never advances the pull cursor. Metadata scales with the bounded unsent queue, not total history. Existing records are immutable, so ordinary edits no longer rewrite the history file. The initial reducer remains in memory; paged indexes will be needed for very large libraries.

Dependent local writes use a bounded atomic batch: a new conversation root and its first user message either commit together with both outbox entries or leave no partial conversation. The caller allocates stable event IDs before the write; exact/rebased retries retain existing envelopes. A local snapshot returns state, committed generation, and pending count together. Account-scoped presentation ignores older snapshot generations so late sync completion cannot replace newer visible history. This local generation is not a server cursor or a cross-device conflict rule.

An in-flight save owns a stable composer identity and draft revision, not whichever chat is visible on completion. Paper/general contexts select independent composers; historical conversations recover their own drafts. Completing the original save may add its durable history but cannot select it over a newer chat, override a later explicit branch choice, or clear a newer edit, including identical replacement text. Unsent new conversations remain accessible in All chats, including a failed first save after the user moved elsewhere. Reopening one preserves the newer draft; explicit discard never cancels a committing save. Initial guest intent may retain a bounded local sample/general draft through sign-in; signed-in account changes still clear scoped state. Signed-in drafts survive process termination using the encrypted checkpoints described below; guest drafts remain session-only. A follow-up draft whose conversation was deleted remains available to recover or discard its text, while Send stays blocked for that conversation. The encrypted save of a question always completes first and never depends on the provider. Only then may an answer be requested for that captured saved turn, after first-use cloud-processing consent; see [paid AI chat](CHAT.md).

Account sessions, local-store activation, and sync-attempt presentation have separate ownership checks. A previous sync can contribute already-durable data from the current store without replacing a newer attempt's status, error, or recovery prompt. Device/key refresh callbacks also belong to their activation. Local activation drains accepted writes before updating keys and reuses the existing account's SQLite actor; rejecting a stale callback must not strand its original composer in a saving state. Sign-out clears presentation immediately and retires the old writer so it refuses new work. A replacement session waits for retired sync and accepted writes before opening another store, including an immediate return to the same account.

Set directory protection, permissions, and backup exclusion before creating the database; SQLite's database, journal, and WAL contain ciphertext for private content. Generation checks reject a second stale writer. A write failure rolls back the transaction and leaves the prior in-memory view unchanged. An ambiguous commit is reconciled against the encrypted metadata before further writes are allowed. An unrecoverable I/O failure requires reopening; it never resets the store.

On iOS, the directory, main database, and write-ahead log use complete file protection. SQLite's `-shm` file is a mapped coordination index containing no database content; preserve the platform's mapping-safe protection class instead of forcing complete protection onto that mapping. The physical-device check verifies database/WAL protection, index protection, backup exclusion, and absence of the plaintext fixture across all files. It does not establish locked-device behavior: stopping work and closing/reopening the store around protected-data availability still requires implementation and testing. [SQLite WAL format](https://www.sqlite.org/walformat.html), [WebKit investigation of protected shared-memory crashes](https://bugs.webkit.org/show_bug.cgi?id=197390).

This unreleased format replaces the development-only whole-file checkpoint. Existing incompatible files are preserved and rejected explicitly, not overwritten. There is no migration of NAS user data. Local authenticated storage detects corruption and partial substitution; it cannot prevent an attacker who controls the entire device from rolling back a complete older database and its keys.

### Device-local encrypted drafts

Drafts were introduced in metadata format 4 / SQLite schema 3, followed by the separate [durable library command queue](NATIVE_LIBRARY_COMMANDS.md) in format 5 / schema 4. The current metadata format 6 / SQLite schema 5 adds [account-scoped offline bundle and complete-library caches](NATIVE_OFFLINE_BUNDLES.md), retaining draft/history domains and upgrading the complete store atomically. A fresh actor reopening an existing store advances its writer generation. Cache children are not loaded during private-history recovery; damage to a derived cache child does not reset private records. The draft invariants below remain unchanged.

Unsent signed-in chat drafts use mutable encrypted `local_drafts` rows in the same account-scoped SQLite store as history. They are not cloud events and do not enter the sync outbox. Guest drafts remain in memory; the product must call them session-only. A saved local draft is available on this device, not on another phone or the future browser reader.

Each row is AES-GCM sealed with the separate local-store key, with account and composer UUID bound into the `science-reader/local-draft/v1` authenticated-data domain. Only the opaque composer UUID and ciphertext appear in SQL. Encrypted metadata format 4 contains a bounded manifest of draft-row ciphertext digests, so missing, substituted, or individually rolled-back rows fail authentication/integrity checks rather than becoming empty drafts. The existing event journal and its cryptographic domains are unchanged. A validated format-2/3 database upgrades transactionally to SQLite schema version 3 and encrypted metadata format 4 without rewriting event records. Unknown formats/schema versions are preserved and rejected. A failed upgrade rolls back its schema and metadata changes; older clients reject the new metadata format, and already-open older writers fail the metadata-generation check.

A `LocalDraft` records the composer UUID, optional paper/conversation identity, monotonic checkpoint revision, independently changing text-revision UUID, edit time, selected causal head, explicit branch-choice UUID, and last acknowledged submission receipt. Paper/general scopes and different composers never share text. An older checkpoint returns the latest committed value; an equal revision must match the original checkpoint or its canonical committed value. New edits, including edits back to identical text, get new text-revision UUIDs. A late checkpoint cannot clear a newer edit or reset a conversation binding promoted by a successful send. Head IDs are resolved through the existing event-rebase mapping when read, retaining the intended branch after content-key rotation.

`commitDraftSubmission` commits the conversation root when needed, user event, outbox entries, and draft consumption receipt in one SQLite transaction. It clears text only when the stored text revision matches the captured send. Newer text stays in that composer and is bound to the newly saved conversation. A newer explicit branch choice survives completion. Until a checkpoint acknowledges that exact submission receipt, it cannot undo the head advanced by the send; after acknowledgment, later observed continuations can advance the head normally. An arbitrary nonnil receipt UUID does not grant acknowledgment. Exact retries retain the captured submission/event IDs and return existing envelopes; a different submission ID for an already consumed text revision is rejected. Only the latest receipt is retained per composer, and its captured checkpoint revision fences older submissions.

A crash before the message transaction commits leaves the last durable draft and no partial conversation; a crash after commit leaves the message and consumed draft together even if the UI callback never ran. Recovery does not automatically submit a provider request. `LocalStoreSnapshot` returns history, generation, pending count, and restorable drafts from one committed actor state. UI saves are acknowledged only after the corresponding checkpoint commits, and newer live typing must not be overwritten by a restore or stale acknowledgment. Accepted/coalesced writes must participate in the account retirement barrier before sign-out returns to the same account; clearing account presentation remains immediate. Uncommitted final keystrokes are not guaranteed to survive instant process termination.

Discard captures the latest observed checkpoint revision and rejects deletion when a newer durable revision exists. Accepted deletion leaves an encrypted tombstone; every later checkpoint for that composer ID is rejected by that writer. If the user edits while deletion is in flight, the surviving edit needs a new composer UUID. Empty consumed rows and tombstones are collected only when a fresh store actor opens, after integrity verification, in a transaction that advances the local generation and fences old actors. Reusing the same actor for same-account key activation does not collect them while old callbacks could still arrive.

Limits are 128 nonempty drafts, 1,024 total draft/receipt/tombstone rows, 200,000 UTF-8 bytes per text, 262,144 encrypted bytes per row, and 8 MiB of encrypted draft rows per account store. Capacity or I/O failure preserves the previous checkpoint and reports failure; it never truncates or evicts unsent text. Empty coordination rows may use space until the next fresh store open. These bounds are independent of the encrypted event outbox's limits.

Content-key epoch changes retain the device's separate local-store key and do not re-encrypt these draft rows. Ordinary sign-out retains the account-partitioned local key/store while clearing visible data. Losing that local key loses these local-only drafts; a cloud recovery code cannot reconstruct them. A future local-key replacement must migrate metadata, history, and drafts together with a crash-safe key handoff, rather than resetting or separately moving the draft table. Future cross-surface draft sync needs an explicit encrypted checkpoint/conflict protocol; this local format makes no cross-device merge or synchronization claim.

### Rotation with offline edits

Before uploading, refresh the device envelope and pull all committed events. This resolves a successful upload whose acknowledgement was lost. A committed key rotation holds the same keyring lock as event append, so after the new epoch is visible, no new old-epoch event can commit later. Only after that catch-up may the client replace remaining old-epoch outbox events.

Replacement preserves logical entity/conversation IDs and content, assigns new event IDs and current-author/current-epoch envelopes, and remaps causal parents. Include every pending descendant of a replaced event. Committed events are never rewritten. All replacement records, an authenticated local replacement marker, and the new outbox commit atomically. A crash before commit leaves the old queue; a crash after commit leaves exact new envelopes ready for retry. A second rotation repeats the same pull-first procedure. A revoked device without a new envelope cannot upload.

Replacement markers were introduced in local metadata format 3 and remain supported by format 4. A validated format-2/3 store now upgrades to format 4 when opened, without rewriting history. Older clients reject unsupported metadata formats before reducing them. The event cryptographic container domains remain version 2; the authenticated metadata format is separate. Markers are local bookkeeping for events proven absent from the server, not new cloud payload kinds. Readers verify content preservation, parent remapping, and that no retained event still refers to a retired local event.

Retained device keys allow offline reading before the server is reachable. Network failure does not erase local history or bootstrap replacement keys. Cloud synchronization still refreshes authority before pushing, and account changes invalidate all outstanding UI work.

## Device-held key design

- Generate content keys with the operating-system secure random source. Use a reviewed, versioned envelope format built on CryptoKit AES-GCM and standard key-agreement/key-derivation primitives. Use fresh nonces and bind account, object/event identity, format, and key version into authenticated data.
- Keep device private keys and the active key bundle in the non-synchronizing Data Protection Keychain. Use key accessibility appropriate to explicitly supported foreground/background behavior; never permit plaintext fallback when the device is locked or a key is unavailable.
- The server stores device public keys, recipient-bound encrypted envelopes, and a recovery-code-wrapped package. It never receives the library key or recovery code.
- Add a device through an authenticated request approved by a retained device, with a compared phrase/QR binding the exact recipient key. An account login must not be sufficient to substitute a new decryption key.
- Bootstrap is atomic: two first devices cannot independently create competing account keyrings. A losing device must join/recover the existing keyring.
- Device revocation rotates the future-write encryption epoch and write-management authority. Reject stale epochs even if an old account session remains valid. Retain historical keys only for authorized historical reads.
- Revocation cannot erase copies a previously authorized device already decrypted. Recovery packages and device envelopes need explicit replacement and deletion lifecycle rules.

TextBrain contains designs and code for these concerns. Review dependencies and failure cases before reuse; do not copy its legacy cutover, note migration, or broad product-specific protocol without need. Cross-runtime known-answer vectors, corruption tests, nonce rules, enrollment tests, and revocation tests are required before describing the implementation as working.

### Enrollment renewal and ambiguous approval

Persist an enrollment candidate's private key, device ID, challenge, local-store key, request ID, and exact envelope before sending the request. Request expiry never expires the recipient key. Renew an expired request with a new request ID while retaining that recipient, including when the current key epoch changes. A delayed approval of either request must remain decryptable after a restart. Only a positive server record marking that candidate revoked permits replacing its identity; revoked identities cannot be reactivated.

Use the server's unexpired-request list to decide whether a request needs renewal. A local timestamp is informational only: clock skew, suspension, and delayed submission cannot establish server expiry. Check the candidate's current device envelope before renewal and after an ambiguous approval, then authenticate the server envelope before activating it. A missing envelope or transport failure preserves pending keys. A duplicate-device conflict caused by an older request winning the race is resolved through that same recipient's envelope.

Serialize key-changing operations in each account's manager across suspension points. An overlapping prepare/bootstrap/recovery attempt returns a retryable busy state rather than mutating the same pending candidate. Check cancellation before durable writes. Persist the active device before removing its pending record; a crash between these writes is recoverable. This uses the existing versioned enrollment/device RPCs and does not change encrypted formats or database identities.

## Cloud AI boundary

The client decrypts only the context it is using, sends a bounded request over TLS, receives the response, and encrypts the persisted conversation locally. The backend authenticates and meters every provider operation without requiring a durable plaintext chat table. Private generated diagrams and tool outputs return to the client for the same encrypted lifecycle.

Public paper context can be retrieved by the server if access is authorized. Private note/history selection happens on the device. Library-wide private-chat semantic search or unattended processing of encrypted history is not a server capability of this model.

Do not place plaintext prompts/responses into queues, diagnostics, support attachments, provider-error logs, or tracing payloads. Store request IDs, counts, status, and costs independently. For initial streaming chat, disconnect/cancellation leaves an explicitly interrupted local turn and settles actual usage; it does not silently create an unencrypted server transcript for recovery. A future background private-content job needs a separately designed bounded job envelope.

This protects stored history at Science Reader, not plaintext while it is being processed by AI. Provider retention must be checked for the exact model, account, and route. Anthropic's ordinary commercial API retention is generally up to 30 days with exceptions; some models have additional requirements. Do not promise zero retention based on application-side deletion alone. [Anthropic retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)

Mathpix processing has its own boundary. Set the documented privacy option, retrieve all needed artifacts, then request provider cleanup once durable verification succeeds. Retain enough provider IDs to reconcile cleanup. An `improve_mathpix` setting alone must not be advertised as immediate deletion of all PDF-derived output. [Mathpix privacy](https://docs.mathpix.com/concepts/privacy), [Mathpix retention](https://docs.mathpix.com/concepts/data-retention)

## Sync protocol

The local encrypted store is the working copy. A durable local transaction commits both the user's change and its upload intent. UI acknowledgement follows that commit. The network is a transport for immutable encrypted events and blobs, not the sole copy of unsent work.

Each event has a stable UUID, account, author device, format/epoch, authenticated encrypted payload, and an exact ciphertext digest. Retrying an event reuses the same ID and bytes. The server accepts exact repeats but refuses a different payload under an existing ID. Clients remove outbox entries only after validating acknowledgement and durably committing their new checkpoint.

The server assigns account-scoped cursors under a transaction/lock discipline that prevents a later committed cursor from overtaking an earlier uncommitted event. A bare sequence with independent transactions is insufficient: a client must not skip a late commit forever. Persist acknowledgement cursors with the reduced local state atomically.

On launch, foreground, login, reconnect, or a realtime notification, fetch everything after the last durable cursor in bounded pages. Realtime is a latency optimization. Catch-up works when every realtime event is missed. Supabase documents background disconnection behavior, so a persistent WebSocket cannot be the recovery mechanism. [Supabase reconnect behavior](https://supabase.com/docs/guides/troubleshooting/realtime-handling-silent-disconnections-in-backgrounded-applications-592794)

`v2_pull_events` limits both count and serialized bytes and supplies `next_cursor` plus `has_more`. A short page can still have a continuation; the client must follow it before considering catch-up complete or rebasing pending events. Validate the supplied cursor against the last event, and reject a non-progressing continuation. Quota rejection preserves local state/outbox and never triggers key replacement. The legacy v1 endpoint rejects a byte-truncated page explicitly instead of letting an older reader mistake it for the end.

## Conflicts and lifecycle

- **Completed chat messages:** append-only with stable message/turn identities and explicit causal parents. Concurrent continuations retain both branches; never overwrite one device's answer with the other device's answer.
- **Displayed branch:** retain the head already observed in each conversation during the account session. A sync may advance that path, but a newly arrived sibling must not replace it because its UUID sorts first. A deleted message remains a causal anchor: follow its surviving descendants, or project the previous path with deleted text removed. Keep that projected path as “Earlier messages” in the picker rather than selecting an unrelated sibling. A new send may extend that anchor without restoring deleted text; a conversation tombstone still blocks all continuation. A simultaneous, previously unseen fork has no known user preference; pick deterministically once and then retain that choice. Resolve local key-rotation replacement IDs before comparing paths. Only an explicit branch choice or local send requests scrolling to the latest message. An explicit choice made during a save takes precedence over its late completion.
- **Streaming turns:** local encrypted partial state; final/interrupted status is explicit. Duplicate delivery cannot create a second assistant message or second charge.
- **Notes/highlights:** explicit revisions; retain concurrent text changes rather than silently choose one. Changes to independent records commute. Stable anchors include document/artifact version and text context.
- **Reading position:** store per-device positions plus a causally versioned shared resume position. An old offline reading session must not automatically replace a later intentional position on reconnect. Preserve alternatives when intent is ambiguous; do not use maximum page number as the definition of progress.
- **Deletion:** durable tombstones dominate stale edits. An offline device cannot resurrect deleted content. Keep tombstones until the acknowledged-device/retention policy makes compaction safe; expired devices re-bootstrap from a verified snapshot.
- **Corruption/unknown versions:** do not advance the cursor past unprocessable content or overwrite a valid encrypted store with an empty one. Show recovery/update state and preserve recoverable data.
- **Sign-out/account changes:** partition all state by account. Retain or discard pending local work only through an explicit user action; never upload it under the next account. Wipe scoped local keys/caches according to the chosen sign-out policy.

For future web/macOS clients, freeze wire formats and merge rules independently of Swift UI code. Run interoperability fixtures before onboarding a new surface. Web-delivered application code and browser storage have a different trust/availability boundary; cross-surface compatibility does not make those platforms identical.

## Required verification before TestFlight privacy claims

Two devices offline at once; concurrent messages and notes; missed realtime events; crash before/after upload acknowledgement; cursor commit ordering; duplicate and corrupt envelopes; two first-device enrollments; key loss; second-device enrollment; device revocation with a surviving auth token; account switching; deletion followed by a late offline edit; complete restore of encrypted rows and blobs. Verify that server tables and logs contain no private plaintext for the declared encrypted categories.

## Account deletion (implemented 2026-10-05)

Settings → Delete account (typed DELETE) calls the `account-delete` function. Migration 017's
`worker_delete_account_begin` refuses while paid work is held (`account_busy`), closes the account (any remaining
login token is then rejected by `app_private.actor()`), deletes encrypted history (capacity counters adjusted once;
25k events in ~40 ms), keys and devices, the library (items, imports, receipts, journal), support reports with
their messages, status history and attachments, rate counters and roles, and stops pending private conversions. The
function then empties the account's folders — `private/<account>/`, `support/<account>/` and each private
conversion's `raw/<sha>/` and `reader/<sha>/` (validated shapes only) — marks tracked files deleted
(`worker_delete_account_finish`) and deletes the login; the app erases this device's account folder and Keychain
items. A repeat call authenticates with the login alone and resumes, and the paper worker sweeps unfinished or
raced deletions every minute (`worker_account_deletions_pending`); `worker_account_deletion_status` and
`node scripts/finish-account-deletion.mjs ACCOUNT` are the operator views.

Kept under the account's random ID, which no longer maps to an email once the login is gone (owner decision):
credit, usage, operation, subscription and audit records, and the records of which papers were converted privately
for the account (pipeline papers, owner-private documents and their immutable approvals) without their files.
Append-only receipts, key transitions and report status history can be deleted only by that transaction for that
account.

Before public release: Sign in with Apple token revocation on deletion (App Review 5.1.1(v)), and releasing an
active App Store subscription's binding so it can attach to a new account; backup expiry of deleted data.

## Paper search

Library › arXiv search text goes from the app to our `discover` function, which queries OpenAlex (ranking) and arXiv
(metadata) from the server. No account ID, email or device information is sent to either; the account's request
counters keep only counts.
