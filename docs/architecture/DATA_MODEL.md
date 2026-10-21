# Data model and invariants

2026-10-13 direction: [HTML-first reader](HTML_FIRST_READER.md#identity-persistence-and-synchronization) requires
logical paper/version membership independent of a server PDF document, original object or OCR run. Local originals
and prepared bundles are separate records; cloud availability cannot be inferred from local readiness. Design an
additive, capability-versioned protocol before changing schema. The document/OCR identities below describe the
current/historical server flow, not required fake rows for HTML. No data migration or schema change was made.

Status: approved design direction, with migrations 001–009 applied to staging and protected by a migration hash ledger. Device-held keys are selected in [Decisions](../DECISIONS.md). Production is not provisioned. See [implementation evidence](../IMPLEMENTATION_STATUS.md) for the boundary between implemented contracts and planned behavior.

The discovery/import review below was recorded on 2026-10-03. Migration 010 now implements the library/import foundation; the acquisition, paid processing and full reader workflow requirements remain future work unless explicitly verified below. Applied migrations 001–010 are immutable; design and test new additive migrations before changing staging.

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

The normal progression is `accepted → resolving → acquiring → verified → awaiting_authorization → processing → ready`; eligible ready artifacts can skip authorization and processing. Each stage has a resumable durable checkpoint. A failed stage records whether retry is safe, blocked, or needs reconciliation. Restart resumes the stage rather than creating another import. Upload sessions are account-bound, expiring, size-limited, and finalized only after server byte/type/page/checksum verification. (Built 2026-10-07 by migration 039, with verification moved to the pipeline worker and a separate private bucket: [PDF uploads](PDF_UPLOADS.md).)

Keep verified-document membership in `library_items`. A library projection displays unresolved imports alongside existing papers and coalesces a resolved request with its library item. Preserve an explicit import-to-item mapping so the UI does not flash duplicate rows or lose selection. Separate source aliases that resolve to identical authorized bytes converge without conflating distinct revisions or annotated PDFs.

Membership add/remove commands need stable operation IDs and a server revision. Completion may attach an artifact to an import, but must not restore membership after a later remove/cancel. An explicit new add can restore it. Removal of a local view, account membership, an import request, and shared processing interest are distinct actions; funding transitions are specified in [Operations and billing](OPERATIONS_AND_BILLING.md#import-cancellation-and-retry-contract--designed-not-implemented).

### Topics and private labels

Public topics describe a publication version. Record canonical topic IDs, taxonomy/alias version, evidence provenance, classifier version, input digest, and classification state. Source categories and deterministic normalization can provide initial topics without OCR. Optional paid classification has its own bounded, idempotent operation. Distinguish pending, completed with no suitable topics, and failed; retain known good topics during refresh. Topic failure never prevents reading or repeats OCR.

Update 2026-10-07: topic tags are implemented differently — see [Topic tags](TAGS.md). Catalog tags come from a curated vocabulary per publication version (`catalog_tags`, model or arXiv-category provenance, vocabulary version, input digest); a reader's own and hidden tags are **service-visible** library-item fields synced like archive state, not encrypted events. The rest of this paragraph remains the plan for collections and other private descriptors. Personal tag definitions, tag assignments, collection names, hidden-topic choices, and private descriptors use versioned encrypted events and a local search index. Define concurrent add/remove/rename behavior and an older-client read/write compatibility gate before emitting new event kinds; the current encrypted format has no tag representation. Automatic public classification must not overwrite personal labels. Feed personalization may use disclosed library membership and public topics, but must not upload private labels implicitly.

`publications` is a global catalog. Metadata extracted from a private/unpublished upload must not automatically be inserted there. (2026-10-07: an uploaded paper's catalog rows hold a neutral placeholder; its title is service-visible on its upload row, deleted with the account, not encrypted — [PDF uploads](PDF_UPLOADS.md).) Keep such descriptors account-scoped, with private display names and filenames encrypted; server processing may receive bounded plaintext only for the explicitly authorized operation. A verified association with an existing public publication does not publish the private file or its annotations.

### Findings addressed by migration 010 and remaining boundaries

- Migration 001's `v1_library` applies an unordered `LIMIT 500`, chooses an arbitrary version association, and omits source/revision/topics/import state. Migration 010 adds a versioned, deterministic paged contract. Search indexing across authors/keywords and native/browser adoption remain required.
- Migration 010 adds pre-document imports, revisioned membership commands and an account change cursor, and removes the legacy OCR route's unconditional membership restoration. Paid retry authorization remains a later contract.
- Legacy shared `reuse_evidence` only requires nonempty JSON. Migration 010 requires immutable version-specific asset approval for its v2 shared-document path; the acquisition worker must substantiate that evidence. Public reachability alone is insufficient.
- Private descriptor scope, public topic provenance/classification jobs, encrypted personal tag semantics, and renderer compatibility selection are not implemented. A newly generated artifact must not silently displace the version referenced by existing anchors.

Test scope constraints and retry/removal schedules before choosing final columns and RPCs. The executable release gates are listed in [Operations and billing](OPERATIONS_AND_BILLING.md#discovery-and-import-failure-schedules-required).

### Migration 010 — applied and verified in staging

`202610030010_library_import_contract.sql` implements the account library/import foundation described above and is applied to staging with its immutable hash. Local evidence on 2026-10-03: `python3 scripts/test-database.py` passes the existing database suites and new `test_library_import.sql`; `python3 tests/database/library_concurrency.py` passes real concurrent-session schedules and a 009→010 upgrade with existing membership/removal rows. Hosted PostgreSQL 17 checks verify paging, replay, cancellation/tombstones, privilege denial and account isolation; mutating synthetic fixtures are rolled back. The pre-deployment encrypted backup and 84-table local restore pass. This is database contract evidence, not a live acquisition, PDF download, Mathpix, native, or browser workflow claim. Applied migrations 001–010 are immutable.

`v2_library_page(cursor, limit)` returns current entries whose immutable creation sequence is at most `baseline_cursor`, with deterministic creation/ID/kind continuation. It is **not** a historical state snapshot: a later page may contain `state_seq > baseline_cursor`. Native and browser clients keep the greatest `state_seq` for each kind/ID, complete all baseline pages, then pull `v2_library_changes(after: baseline_cursor, through: H1)` through its fixed upper boundary. A command response or a high row revision must not advance the account catch-up cursor. Apply every change batch and its cursor atomically; a resolved import and its item mapping share one batch. Hidden import rows preserve that mapping.

The Swift core now implements this bounded wire decoder and a value-type reconciler with account/session request tickets. It retains hidden imports and tombstones, preserves established pins, rejects conflicting equal revisions, and applies pages atomically. Eighteen focused tests pass, including large baselines and interrupted/reordered observations. The native LibraryService and bounded transport now use this component: only a complete baseline/catch-up becomes a published snapshot, failures retain the last complete presentation and exact retry ticket, and account retirement invalidates old requests. ReaderModel adopts snapshots under its reader-session and monotonically increasing publication generation; a separate refresh-attempt owner controls status/error delivery. Pending imports remain typed rows beside document-backed papers. Current availability gates cached reading capabilities, and a removal clears active reader selection without deleting encrypted conversations. Deterministic native tests cover these transitions. Library persistence and customer mutation commands remain separate work.

Command receipts retain the original result and return the current entity separately. Known-document writes compare membership revisions; source imports carry the user's observed library cursor and retain their original accepted intent across checkpoints/retry. Explicit Remove leaves a permanent document-level fence. Cancel withdraws one import interest: it removes import-created membership only when no still-valid resolved interests remain, and does not create a fence against an independent unresolved Add. Direct Add establishes independent membership that an import cancellation cannot remove. Duplicate aliases preserve established source/artifact pins. Metadata, approval records, document byte identity, stored-object identity and render-artifact identity cannot be rewritten behind a pin.

The first successful v2 command receipt sets an account's `v2_writes_started` flag in the same transaction. Thereafter v1 membership writes fail with `library_update_required`; their signatures and prior v1-only behavior remain available before that boundary. A v1 Add also cannot restore an existing removal fence. Legacy reads remain available with their existing limitations. The legacy OCR RPC no longer changes membership, uses budget→account→document lock order, and accepts only verified compatible cached artifacts. New paid work through its old, unquoted signature fails with `ocr_authorization_required`; existing-job observation is retained. Compatible renderer versions default to an empty allowlist.

The per-account library cursor is derived bookkeeping and cascades when a deletable account is removed, so pristine synthetic-account cleanup remains possible. Membership, import and immutable receipt references independently prevent unsafe account deletion; a rejected deletion preserves the cursor and retained records atomically. Local fixtures cover both pristine deletion and the receipt-only deletion gate. A complete customer account-deletion/retention workflow is still required.

Beta capacity defaults are explicit, separate from credits. Since migration 0142 (owner, 2026-10-21: no import quota) there is no lifetime limit on membership rows, import intents, immutable receipts or shared catalog records (the policy columns are NULL); imports in flight are bounded at 100/account and 2,000/environment, and request rates remain. Until 0142 the defaults were 2,000 lifetime membership rows and 2,000 import intents/account (20,000 each/environment); 10 active acquisition intents/account and 100/environment; 12,000 immutable receipts/account and 120,000/environment, with reserved receipt capacity for actual removals/cancellations. Journal limits are 8 MiB/10,000 batches per account and 64 MiB/100,000 batches per environment. At journal capacity, a serialized compaction advances `retained_after` and requires old readers to restart a baseline; it never deletes current rows, receipts, IDs or removal fences. Other quota failures roll back the entire operation without consuming a cursor. Catalog metadata is capped at 10,000 observations/32 MiB (32 KiB each); reuse approvals at 10,000/16 MiB of evidence (8 KiB each). Page responses are at most 100 entries/batches and 1 MiB of encoded JSON. Monthly library transfer limits are 256 MiB/account and 2 GiB/environment, with request-rate limits and a separately schedulable transfer-counter cleanup routine. These are internal beta limits, not published subscription allowances.

The source slice accepts normalized arXiv base IDs and separate revisions. Its restricted service fixtures publish immutable metadata and revision-matched CC0/CC-BY 4.0 approval evidence, verify original-object identity, checkpoint imports, and resolve exact eligible bytes without charging OCR credits. This does not itself fetch or independently substantiate licensing evidence: the future adapter must validate that evidence against the pinned revision. Source categories are public metadata, not private tags or a completed topic classifier. `pdf_ready` is an early development capability; the intended reader still requires Mathpix equations/text/figures, validated durable conversion bundles, compatible artifact pins, and complete offline assets. Authorized original-PDF delivery, acquisition leases, aggregate source throttling, original storage/egress reservations, quote/consent/funding, paid submission reconciliation and complete bundle publication remain required before enabling their respective workers or declaring the app's import→read flow complete.

## Private state with device-held keys

| Record | Server-visible fields | Content boundary |
|---|---|---|
| `keyrings` | Account, active epoch/key identifiers, wrapped recovery package, management verifier | No raw data key or recovery code |
| `devices` | Account, device ID, public key, enrollment/revocation state | No device private key |
| `device_envelopes` | Recipient, epoch, wrapped key bundle | Only intended device can unwrap |
| `enrollment_requests` | Recipient public key, challenge, expiry, approval state | Account login alone cannot approve |
| `sync_events` | Account, event ID, epoch, ciphertext, digest, committed cursor | Chat/notes/anchors/relationships encoded inside ciphertext |
| `encrypted_blobs` | Opaque ID, owner, checksum, length, key epoch, storage reference | Private filenames and relationships remain encrypted. Built for Notes images as `note_assets` (migration 095, staging): account, blob ID, stored-bytes SHA-256, length, pending/ready; the per-blob key lives only in the encrypted entry ([Notes](NOTES_AND_SNIPPETS.md#server-status--blob-api-live-on-staging-2026-10-21-utc)) |
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
- Function and object grants are explicit (2026-10-21, review D5). Supabase's project defaults grant every new
  `public` table, sequence and function to `anon`, `authenticated` and `service_role`, and PostgreSQL's global default
  lets PUBLIC execute a new function; migration 001's per-schema revoke of PUBLIC could not remove that global default.
  Every migration therefore revokes `public, anon, authenticated` on each function it creates and grants
  `authenticated` only to versioned client RPCs (`v<n>_…`) and owner-checked admin calls, `service_role` to `worker_…`.
  Migration 135 removes the migrating role's default grants to `anon` and `authenticated` in `public` (functions,
  tables, sequences), so revoking PUBLIC is enough and a new public table is never readable by clients by default.
  The local test bootstrap emulates Supabase's defaults, and `tests/database/default_privileges.sql` fails on any
  public function `anon` can execute or any non-RPC `authenticated` can execute.
- Avoid `ON DELETE CASCADE` from one user's library into shared articles, monetary audit history, or multi-request processing jobs.
- Use additive migrations first, explicit backfills, and a documented minimum writer/protocol version before removing old fields. Older TestFlight/App Store clients and devices returning after long offline periods are part of the migration design.
- Encrypted payload changes need client readers/versioning; a database backfill cannot assume access to plaintext.
- Deletion workflows include active storage, object backups, search indexes, cached derived artifacts, provider cleanup, and applicable retained billing metadata. Publish retention periods before public release; do not describe account deletion as immediate removal from all backups.

## Pre-migration proof

The staging foundation was deployed after local scope, lease, accounting, encryption-envelope, retry, and concurrency tests. Hosted isolation and native two-client sync tests pass. Signed database/object exports restore successfully into a disposable local database, including the schema after migration 009. Complete duplicate-import integration, deletion workflows, and a hosted replacement-project restore including Auth/MFA before production or real beta data. A local restore is evidence for its tested scope, not a hosted disaster-recovery guarantee.
