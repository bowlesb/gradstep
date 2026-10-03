# Data model and invariants

Status: approved design direction, with migrations 001–007 applied to staging and protected by a migration hash ledger. Device-held keys are selected in [Decisions](../DECISIONS.md). Production is not provisioned. See [implementation evidence](../IMPLEMENTATION_STATUS.md) for the boundary between implemented contracts and planned behavior.

## Boundaries

Use separate Science Reader staging and production projects. Do not put Science Reader users, roles, subscriptions, or files into TextBrain's projects. Within each project, separate catalog, application-private, processing, billing, and support concerns. Schema namespaces can express those boundaries, but grants, RLS, and server authorization enforce them. Expose only intentional API views/RPCs, not all service tables.

Keep global service authorization separate from content ownership. A support operator can read submitted reports, not users' private chats. An admin role grants no decryption key. A customer's editable profile never contains an authoritative role, credit balance, or subscription entitlement.

## Publications, bytes, and conversions

| Record | Responsibility | Identity / constraint |
|---|---|---|
| `publications` | Bibliographic identity, title, authors, venue | Stable UUID; title matching can suggest a merge but never performs one automatically |
| `publication_identifiers` | Normalized external identifiers and verified provenance | Unique identifier within its namespace; explicit relationships for distinct publication versions |
| `publication_versions` | Source-specific revision, publication date, licensing evidence | Stable UUID; arXiv revision belongs here, not in a mutable paper title |
| `documents` | A particular original file and access scope | SHA-256 over verified bytes; scope is `shared_catalog` or `owner_private` |
| `version_documents` | Verified relationship between a publication version and a file | Allows multiple encodings/files for one version without conflating them |
| `document_sources` | Acquisition URL, resolved canonical identity, provenance | Server-validated sources; remove credentials/query secrets from persisted URLs |
| `ocr_runs` | Raw OCR result for exact input/options/provider | Unique logical work key: document + provider + normalized OCR-options digest |
| `render_artifacts` | Cleaned HTML, Markdown, figures, geometry, manifest | OCR result + renderer version; new rendering does not automatically pay for new OCR |
| `stored_objects` | Object identity, checksum, size, media type, lifecycle | Immutable storage paths; explicit state and owner/scope, not a filename as authority |

For `documents`, enforce a database constraint: a private document has exactly one owner; a shared catalog document has no private owner and requires approved reuse eligibility. Use separate partial uniqueness rules for `(sha256)` in shared scope and `(owner_user_id, sha256)` in private scope. Private duplicate checks must not reveal other users' uploads.

A verified immutable public source version may resolve directly to an existing canonical file. Uploaded PDFs are hashed before reuse. An annotated upload or materially different file must not be replaced by another file merely because its DOI/arXiv identifier matches. Hash matches do not authorize moving private files into public scope.

Source licenses and reuse eligibility are version-specific. Discovery metadata can exist without permission to distribute full text. When full-text reuse is not eligible, use an owner-private path or source link according to the applicable rights; do not infer sharing rights from a publicly reachable URL. [arXiv license information](https://info.arxiv.org/help/license/index.html)

Originals, conversion outputs, and image bytes are durable assets. Download complete result bundles, validate archive paths and size, store images under our control, and rewrite references. Mathpix-generated URLs are not durable storage. Rendering assets must also be available offline. [Mathpix retention](https://docs.mathpix.com/concepts/data-retention)

## Personal library

`library_items` grants an account access to a document/version and records membership and lifecycle. Its `(user_id, document_id)` identity is unique within an account. A client may refer only to an eligible shared document or its own private document. Adding a library item never grants mutation authority over global catalog records.

The service may see library membership to authorize downloads, processing, and quotas; this reveals reading interests. That limit must be disclosed separately from encrypted chat content. Personal labels, collection names, highlights, reading positions, and notes can live in the encrypted private-state stream. Public metadata is searchable on the server; personal encrypted fields are searched on the device.

Removing a library item creates an account-scoped deletion event. It does not cascade into shared documents or other accounts. Garbage collection requires an explicit catalog/private-file policy and reference checks. Account deletion removes private relationships and starts a verified private-object deletion workflow, without deleting eligible catalog assets that other users rely on.

Do not add an unused team/organization layer to every record. The identities above permit later explicit sharing grants or group-owned documents, but no team product, shared chat keys, or collaboration membership is silently promised for v1.

## Private state with device-held keys

| Record | Server-visible fields | Content boundary |
|---|---|---|
| `keyrings` | Account, active epoch/key identifiers, wrapped recovery package, management verifier | No raw data key or recovery code |
| `devices` | Account, device ID, public key, enrollment/revocation state | No device private key |
| `device_envelopes` | Recipient, epoch, wrapped key bundle | Only intended device can unwrap |
| `enrollment_requests` | Recipient public key, challenge, expiry, approval state | Account login alone cannot approve |
| `sync_events` | Account, event ID, epoch, ciphertext, digest, committed cursor | Chat/notes/anchors/relationships encoded inside ciphertext |
| `encrypted_blobs` | Opaque ID, owner, checksum, length, key epoch, storage reference | Private filenames and relationships remain encrypted |
| `device_cursors` | Device, last acknowledged committed position, timestamp | Operational progress only |

See [Privacy and sync](PRIVACY_AND_SYNC.md) for the consistency model. This avoids adding plaintext `chat_messages.content`, `chats.title`, or public `diagrams.body_html` and trying to remove them after launch. Private diagrams returned by an AI tool follow the encrypted conversation lifecycle.

## Durable processing

`processing_jobs` describes work, not a user's subscription. `job_attempts` records bounded attempts and external provider IDs. `job_requests` links interested accounts and library imports to shared work. `job_leases` or equivalent locked job fields provide a lease generation/fencing token; stale workers cannot publish completion after their lease has been replaced.

Example OCR state transitions:

`queued → claimed → submitting → awaiting_provider → collecting → ready`

Failures distinguish `retryable`, `failed`, `cancelled`, and `submission_uncertain`. A paid submission timeout without a provider ID is not proof that no work was accepted. Reconcile by provider metadata when possible; otherwise quarantine for operator review. Polling an existing job never re-submits the PDF.

Atomically claim one active logical OCR job for a work key. Persist submission intent before the outbound call and the provider ID immediately afterward. The database cannot transactionally roll back a provider bill; uniqueness plus reconciliation is required. Exactly-once billing cannot be promised just because a queue delivers within a visibility window.

Completing a job validates the lease, publishes an immutable artifact manifest, settles its reservations, and advances durable state. Object uploads and Postgres commits are not one transaction: use pending object records, idempotent verification, manifest publication, and delayed orphan cleanup. Consumers only see ready manifests.

## Monetary records

Keep these separate: `plans`, immutable `price_versions`, verified `subscription_events`, derived `entitlements`, `allowance_periods`, `credit_ledger_entries`, `credit_reservations`, `provider_usage_events`, `spend_reservations`, and `provider_reconciliations`.

- Monetary arithmetic uses integer minor units or fixed-precision numeric types, never binary floats.
- Each grant, reservation, capture, release, and refund has a stable operation/idempotency key. Corrections are compensating entries, not edits to history.
- A materialized available balance is maintained in the same transaction as its ledger entries. Row locks/constraints prevent concurrent overspend; the ledger remains reconstructible.
- Provider costs and customer credit charges are different facts. Refunding a failed user action does not erase the actual provider bill.
- Subscription allowance grants are unique by account, entitlement, and period. Annual subscriptions can issue monthly allowances without granting the annual amount twice.
- Apple notification deduplication includes environment. Original transactions are bound to one app account; restores cannot duplicate grants across accounts.

The exact rate card and allowance sizes remain benchmark outputs. See [Operations and billing](OPERATIONS_AND_BILLING.md).

## Support and operator access

`support_reports`, `support_messages`, `support_attachments`, `support_status_events`, and `admin_audit_events` have a separate support access policy. `app_roles` is writable only by a trusted role-management path. Reporter access is scoped to their own reports; operator access requires a server-controlled role and appropriate authentication assurance.

Support screenshots and notes are intentionally disclosed content, not encrypted private-chat history. Attachments use private object storage with authorized reads. See [Testing feedback](../TESTING_FEEDBACK.md).

## Query, evolution, and deletion rules

- Index frequent access paths: account + committed cursor; account + library ID; job state + next attempt; document + work key; account + allowance period; report status + created time.
- Every mutating RPC takes an authenticated actor and verifies referenced objects' scope. A foreign key alone does not enforce same-owner relationships. Use composite foreign keys/constraints where ownership is duplicated and policy tests for every join.
- Avoid `ON DELETE CASCADE` from one user's library into shared articles, monetary audit history, or multi-request processing jobs.
- Use additive migrations first, explicit backfills, and a documented minimum writer/protocol version before removing old fields. Older TestFlight/App Store clients and devices returning after long offline periods are part of the migration design.
- Encrypted payload changes need client readers/versioning; a database backfill cannot assume access to plaintext.
- Deletion workflows include active storage, object backups, search indexes, cached derived artifacts, provider cleanup, and applicable retained billing metadata. Publish retention periods before public release; do not describe account deletion as immediate removal from all backups.

## Pre-migration proof

The staging foundation was deployed after local scope, lease, accounting, encryption-envelope, retry, and concurrency tests. Hosted isolation tests also pass. Complete duplicate-import integration, deletion workflows, and restoration of both rows and objects before production or real beta data. The original plan grouped the restore proof with the first migration; that proof remains outstanding and is a release gate, not evidence already obtained.
