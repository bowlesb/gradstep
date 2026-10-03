# Privacy, key custody, and synchronization

Status: device-held keys approved; iPhone/iPad first, browser reader deferred. Implementation and verification remain in progress. This is not a shipped privacy guarantee.

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

### Local persistence format 2

Use SQLite transactions with WAL and full synchronization for local history. Each immutable event envelope is additionally AES-GCM sealed with the device's local-store key, binding account, local ordinal, and event ID. No private text, title, anchor, or key enters an SQL column. The encrypted metadata record contains account identity, contiguous download cursor, pending event IDs, record count, generation, and a SHA-256 hash-chain commitment to the ordered encrypted records. On open, authenticate all records and the commitment before exposing state. Missing, reordered, substituted, or corrupt records must not become an empty store.

Appending commits a sealed record, outbox membership, and updated commitment in one transaction. Pulling commits all new records, matching outbox removals, and the page cursor together. Acknowledging an upload changes only encrypted outbox metadata; it never advances the pull cursor. Metadata scales with the bounded unsent queue, not total history. Existing records are immutable, so ordinary edits no longer rewrite the history file. The initial reducer remains in memory; paged indexes will be needed for very large libraries.

Set directory protection, permissions, and backup exclusion before creating the database; SQLite's database, journal, and WAL contain ciphertext for private content. Generation checks reject a second stale writer. A write failure rolls back the transaction and leaves the prior in-memory view unchanged. An ambiguous commit is reconciled against the encrypted metadata before further writes are allowed. An unrecoverable I/O failure requires reopening; it never resets the store.

This unreleased format replaces the development-only whole-file checkpoint. Existing incompatible files are preserved and rejected explicitly, not overwritten. There is no migration of NAS user data. Local authenticated storage detects corruption and partial substitution; it cannot prevent an attacker who controls the entire device from rolling back a complete older database and its keys.

### Rotation with offline edits

Before uploading, refresh the device envelope and pull all committed events. This resolves a successful upload whose acknowledgement was lost. A committed key rotation holds the same keyring lock as event append, so after the new epoch is visible, no new old-epoch event can commit later. Only after that catch-up may the client replace remaining old-epoch outbox events.

Replacement preserves logical entity/conversation IDs and content, assigns new event IDs and current-author/current-epoch envelopes, and remaps causal parents. Include every pending descendant of a replaced event. Committed events are never rewritten. All replacement records, an authenticated local replacement marker, and the new outbox commit atomically. A crash before commit leaves the old queue; a crash after commit leaves exact new envelopes ready for retry. A second rotation repeats the same pull-first procedure. A revoked device without a new envelope cannot upload.

Local metadata format 3 adds replacement markers to the authenticated record journal. It reads existing format-2 event rows and advances the metadata format on the next transaction, without rewriting history. Older clients reject format 3 before reducing it. The cryptographic container domains remain version 2; the authenticated metadata format is separate. Markers are local bookkeeping for events proven absent from the server, not new cloud payload kinds. Readers verify content preservation, parent remapping, and that no retained event still refers to a retired local event.

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
- **Streaming turns:** local encrypted partial state; final/interrupted status is explicit. Duplicate delivery cannot create a second assistant message or second charge.
- **Notes/highlights:** explicit revisions; retain concurrent text changes rather than silently choose one. Changes to independent records commute. Stable anchors include document/artifact version and text context.
- **Reading position:** store per-device positions plus a causally versioned shared resume position. An old offline reading session must not automatically replace a later intentional position on reconnect. Preserve alternatives when intent is ambiguous; do not use maximum page number as the definition of progress.
- **Deletion:** durable tombstones dominate stale edits. An offline device cannot resurrect deleted content. Keep tombstones until the acknowledged-device/retention policy makes compaction safe; expired devices re-bootstrap from a verified snapshot.
- **Corruption/unknown versions:** do not advance the cursor past unprocessable content or overwrite a valid encrypted store with an empty one. Show recovery/update state and preserve recoverable data.
- **Sign-out/account changes:** partition all state by account. Retain or discard pending local work only through an explicit user action; never upload it under the next account. Wipe scoped local keys/caches according to the chosen sign-out policy.

For future web/macOS clients, freeze wire formats and merge rules independently of Swift UI code. Run interoperability fixtures before onboarding a new surface. Web-delivered application code and browser storage have a different trust/availability boundary; cross-surface compatibility does not make those platforms identical.

## Required verification before TestFlight privacy claims

Two devices offline at once; concurrent messages and notes; missed realtime events; crash before/after upload acknowledgement; cursor commit ordering; duplicate and corrupt envelopes; two first-device enrollments; key loss; second-device enrollment; device revocation with a surviving auth token; account switching; deletion followed by a late offline edit; complete restore of encrypted rows and blobs. Verify that server tables and logs contain no private plaintext for the declared encrypted categories.
