# Data model and invariants

Status: approved design direction, with migrations 001–009 applied to staging and protected by a migration hash ledger. Device-held keys are selected in [Decisions](../DECISIONS.md). Production is not provisioned. See [implementation evidence](../IMPLEMENTATION_STATUS.md) for the boundary between implemented contracts and planned behavior.

The discovery/import review below was recorded on 2026-10-03. It describes required future behavior, not an implemented API or a passed workflow test. Applied migrations 001–009 remain immutable; design and test the relevant additive 010+ migrations before changing staging.

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

For `documents`, enforce a database constraint: a private document has exactly one owner; a shared catalog document has no private owner and requires approved reuse eligibility. Use separate partial uniqueness rules for `(sha256)` in shared scope and `(owner_id, sha256)` in private scope. Private duplicate checks must not reveal other users' uploads.

A verified immutable public source version may resolve directly to an existing canonical file. Uploaded PDFs are hashed before reuse. An annotated upload or materially different file must not be replaced by another file merely because its DOI/arXiv identifier matches. Hash matches do not authorize moving private files into public scope.

Source licenses and reuse eligibility are version-specific. Discovery metadata can exist without permission to distribute full text. When full-text reuse is not eligible, use an owner-private path or source link according to the applicable rights; do not infer sharing rights from a publicly reachable URL. [arXiv license information](https://info.arxiv.org/help/license/index.html)

Originals, conversion outputs, and image bytes are durable assets. Download complete result bundles, validate archive paths and size, store images under our control, and rewrite references. Mathpix-generated URLs are not durable storage. Rendering assets must also be available offline. [Mathpix retention](https://docs.mathpix.com/concepts/data-retention)

## Personal library

`library_items` grants an account access to a document/version and records membership and lifecycle. Its `(account_id, document_id)` identity is unique within an account. A client may refer only to an eligible shared document or its own private document. Adding a library item never grants mutation authority over global catalog records.

The service may see library membership to authorize downloads, processing, and quotas; this reveals reading interests. That limit must be disclosed separately from encrypted chat content. Personal labels, collection names, highlights, reading positions, and notes can live in the encrypted private-state stream. Public metadata is searchable on the server; personal encrypted fields are searched on the device.

Removing a library item creates an account-scoped deletion event. It does not cascade into shared documents or other accounts. Garbage collection requires an explicit catalog/private-file policy and reference checks. Account deletion removes private relationships and starts a verified private-object deletion workflow, without deleting eligible catalog assets that other users rely on.

Do not add an unused team/organization layer to every record. The identities above permit later explicit sharing grants or group-owned documents, but no team product, shared chat keys, or collaboration membership is silently promised for v1.

## Discovery and import contract — designed, not implemented

Native and browser readers use the same versioned search, import, library, and artifact contracts. The archival web backend is a UX reference, not a deployable implementation of these ownership boundaries.

### Search identity and result fields

A result has a stable identity, title, source, and normalized source identifier. Authors, publication date/year, venue, abstract, public topics, and exact revision are optional values, not invented defaults. Return provenance/fetch time, source availability, account library/import references, and explicit capabilities such as readable, importable, processing, or source-link-only. Metadata-only results remain discoverable without pretending a PDF is available.

Keep the base arXiv identifier separate from its revision. Resolve an unversioned source once and pin the version used for an import; a later revision does not replace the file beneath notes or reading anchors. Support both historical and current arXiv identifiers. Title similarity suggests candidates, not identity; DOI agreement alone cannot establish byte equality. [arXiv version identifiers](https://info.arxiv.org/help/arxiv_identifier.html)

Search title, authors, identifiers, abstract, and public topics as promised by the interface. Search personal encrypted fields locally. A source adapter returns partial failures separately from no matches. A client query generation fences late responses after query/source/account changes; cancellation alone is insufficient. Retain useful cached results during refresh, with their actual freshness. Provider rank is ordering evidence, not a relevance percentage.

Library pages require deterministic ordering with an ID tie-breaker, bounded count/bytes, and explicit continuation. Bind cursors to the query/sort and a documented snapshot or reconciliation boundary so concurrent additions/removals cannot silently disappear between pages. An account change cursor includes removals and import transitions; Realtime only prompts catch-up. External adapters must document their own paging consistency instead of claiming a stable provider snapshot they cannot supply.

### Import identity and membership

Introduce an account-scoped import request before downloading or uploading bytes. Its required contract is: client operation ID, immutable request digest, source reference, state revision, resolved version/document/library/job references, approved quote/operation reference where needed, and typed error with retryability. Same ID and digest returns the existing outcome; a changed request conflicts. Bound retained requests, uploads, metadata, and download attempts independently of provider credits.

The normal progression is `accepted → resolving → acquiring → verified → awaiting_authorization → processing → ready`; eligible ready artifacts can skip authorization and processing. Each stage has a resumable durable checkpoint. A failed stage records whether retry is safe, blocked, or needs reconciliation. Restart resumes the stage rather than creating another import. Upload sessions are account-bound, expiring, size-limited, and finalized only after server byte/type/page/checksum verification.

Keep verified-document membership in `library_items`. A library projection displays unresolved imports alongside existing papers and coalesces a resolved request with its library item. Preserve an explicit import-to-item mapping so the UI does not flash duplicate rows or lose selection. Separate source aliases that resolve to identical authorized bytes converge without conflating distinct revisions or annotated PDFs.

Membership add/remove commands need stable operation IDs and a server revision. Completion may attach an artifact to an import, but must not restore membership after a later remove/cancel. An explicit new add can restore it. Removal of a local view, account membership, an import request, and shared processing interest are distinct actions; funding transitions are specified in [Operations and billing](OPERATIONS_AND_BILLING.md#import-cancellation-and-retry-contract--designed-not-implemented).

### Topics and private labels

Public topics describe a publication version. Record canonical topic IDs, taxonomy/alias version, evidence provenance, classifier version, input digest, and classification state. Source categories and deterministic normalization can provide initial topics without OCR. Optional paid classification has its own bounded, idempotent operation. Distinguish pending, completed with no suitable topics, and failed; retain known good topics during refresh. Topic failure never prevents reading or repeats OCR.

Personal tag definitions, tag assignments, collection names, hidden-topic choices, and private descriptors use versioned encrypted events and a local search index. Define concurrent add/remove/rename behavior and an older-client read/write compatibility gate before emitting new event kinds; the current encrypted format has no tag representation. Automatic public classification must not overwrite personal labels. Feed personalization may use disclosed library membership and public topics, but must not upload private labels implicitly.

`publications` is a global catalog. Metadata extracted from a private/unpublished upload must not automatically be inserted there. Keep such descriptors account-scoped, with private display names and filenames encrypted; server processing may receive bounded plaintext only for the explicitly authorized operation. A verified association with an existing public publication does not publish the private file or its annotations.

### Gaps to resolve before the next migration

- Migration 001's `v1_library` applies an unordered `LIMIT 500`, chooses an arbitrary version association, and omits source/revision/topics/import state. Its search vector excludes authors and keywords. Introduce a versioned, deterministic paged contract rather than extending the silent cap.
- No pre-document import record, revisioned membership command, or account library change cursor exists. Migration 005's `worker_request_ocr` currently clears `removed_at` unconditionally and returns terminal jobs without a retry policy.
- Shared `reuse_evidence` currently only requires nonempty JSON. Require a validated decision tied to source version, evidence, policy version, and eligibility state; public reachability alone is insufficient.
- Private descriptor scope, public topic provenance/classification jobs, encrypted personal tag semantics, and renderer compatibility selection are not implemented. A newly generated artifact must not silently displace the version referenced by existing anchors.

Test scope constraints and retry/removal schedules before choosing final columns and RPCs. The executable release gates are listed in [Operations and billing](OPERATIONS_AND_BILLING.md#discovery-and-import-failure-schedules-required).

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

History storage projections count ciphertext bytes and event rows per account and environment, and are maintained by transactional triggers. Account projections cascade only when their account is removed; they are derived bookkeeping, not shared content or monetary history. Monthly download counters are separate from persistent storage and provider credits. The versioned page API bounds both event count and encoded response bytes. See the capacity/compatibility contract in [Operations and billing](OPERATIONS_AND_BILLING.md).

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

The staging foundation was deployed after local scope, lease, accounting, encryption-envelope, retry, and concurrency tests. Hosted isolation and native two-client sync tests pass. Signed database/object exports restore successfully into a disposable local database, including the schema after migration 009. Complete duplicate-import integration, deletion workflows, and a hosted replacement-project restore including Auth/MFA before production or real beta data. A local restore is evidence for its tested scope, not a hosted disaster-recovery guarantee.
