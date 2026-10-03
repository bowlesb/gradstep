# Mathpix processing and durable reader artifacts

Status: reviewed implementation direction, 2026-10-03. The transport adapter and eleven isolated tests exist. No paid submission, acquisition worker, quote/consent route, durable result collector or reader-artifact publication is deployed. The final reader requires this pipeline; original PDF delivery alone does not complete it.

## Separate acquisition from paid processing

Migration 010 defines account import intent, immutable exact-version metadata and asset approvals, membership fences and library change cursors. The next acquisition contract must establish bounded source access, reservations, verified originals and authorized downloads. A subsequent migration introduces the complete paid OCR lifecycle. Keep paid work disabled until that entire lifecycle and its failure schedules pass.

Reuse follows exact document bytes, provider/app scope and a versioned canonical OCR profile. An article title, DOI or arXiv identity alone is insufficient. Account library membership and private encrypted conversations remain separate from reusable publication assets. A renderer upgrade consumes retained raw OCR output without purchasing OCR again.

## Versioned provider profile

`_shared/mathpix.ts` implements fixed-origin `v3/pdf` transport. `science-reader-mmd-v1` freezes the complete options JSON and hashes a versioned domain, API, profile ID and those options. It retains equation tags, fonts and spacing; uses explicit inline/display math delimiters; preserves section numbering, hyperlinks, page breaks and margin notes; requests `mmd.zip`; and sets `metadata.improve_mathpix` to false. MMD and line data are collected separately. Renderer/sanitizer versions are outside this OCR identity.

The adapter captures an owned copy of the original PDF and submission checkpoint before suspension, checks the recorded byte and options hashes, and uses an opaque attempt UUID as its upload filename. Requests have a 30-second transport deadline, reject redirects and do not expose provider bodies or credentials in errors. Declared and actual response sizes are bounded; truncated uncompressed bodies, aborted reads and unexpected response formats fail. Limits are 64 KiB for status JSON, 8 MiB for MMD, 32 MiB for the archive and 16 MiB for line data. These are transport limits, not proof that parsing fits an Edge invocation.

No public route calls this adapter. Its `submitOnce` method does not itself authorize spending or guarantee durable at-most-once submission. A worker must first persist a fenced attempt and obtain the one-time submission grant described below. Any ambiguous POST outcome becomes `submission_uncertain`; the adapter never retries a paid POST automatically.

References: [PDF request](https://docs.mathpix.com/reference/post-v3-pdf), [shared options and statuses](https://docs.mathpix.com/reference/shared-types), [supported outputs](https://docs.mathpix.com/reference/supported-formats).

## Quote, consent and attempt identity

Retain `ocr_runs(document, provider, options_digest)` as logical work identity. A processing coordinator owns separate paid `provider_attempts`; current `job_attempts` are lease claims and must not be repurposed as financial attempts. Legacy job funding fields cannot be overwritten to model a retry. Gate legacy transitions for the new protocol.

A quote binds the verified original object, document hash and page count, OCR profile/app scope, provider/privacy policy, immutable rate version, customer-credit ceiling, service-spend ceiling, expiry and current membership/import intent. The authorization command has an immutable request digest and explicit consent version.

Under the documented lock order, authorization first reconciles exact command replay, then rechecks intent and scope. An existing compatible artifact is reused without an OCR hold. Existing active work accepts another account interest without changing its funder. New work atomically reserves customer credits, service spending and output capacity, creates one funded attempt and enqueues it. Waiters never become funders implicitly. Cancellation and reconciliation retain reserved command-receipt capacity even when ordinary additions are at quota.

## Submission, uncertainty and cancellation

Persist an attempt and submission intent before POST. `begin_submission(attempt, generation, request_digest)` grants permission only on its first transition. A replay reports current state and must not grant another POST, including when the first permission response was lost.

Timeouts, expired submit leases and lost responses retain both financial holds and leave ordinary resubmit queues. A narrow idempotent evidence route can record a late provider ID against that same attempt and request digest after its worker lease expires; this does not authorize stale publication. A uniquely verified match in the provider's searchable results can reconcile an accepted upload using filename, arguments, timing and provider ID. No result or several candidates does not prove nonacceptance. No automatic safe `v3/pdf` POST idempotency guarantee is assumed. [Mathpix result lookup](https://docs.mathpix.com/reference/pdf-results)

Before submission intent, funding cancellation fences the worker, settles zero, releases holds and leaves any remaining shared interests awaiting a fresh consenting funder. After submission intent, cancellation/removal detaches the account interest while collection and expense reconciliation continue. The submission gate checks current account membership/import intent under the account lock: a removal that wins prevents submission. A new paid retry requires a new authorization and attempt after the prior attempt has been reconciled and settled. Polling, collecting and rendering have separate retry counters and cannot initiate a paid retry.

## Collect, verify, render and publish

Wait for document status `completed`; 100% page progress is insufficient. Wait separately for the `mmd.zip` conversion's own completed status. Retain MMD, line/equation data and the original archive in controlled storage. Validate archive paths, duplicate names, expanded bytes, entry count, image formats/dimensions and every referenced asset before publication. ZIP signatures and basic output JSON validation in the transport adapter do not establish a usable bundle.

A raw-result manifest identifies every required object by immutable ID, role, bytes and checksum. No temporary provider image URL may be required for durable reading. A pinned renderer emits sanitized offline HTML, stable block/equation/figure anchors, SVG math with LaTeX/assistive MathML, and bundled styles/fonts. Artifact publication validates the entire manifest, not just its JSON object. [Mathpix renderer source](https://github.com/Mathpix/mathpix-markdown-it)

Native integration must preserve generated stable heading IDs, resolve figures through verified bundle-scoped resources, and derive selected-equation source from the same parser nodes. Do not copy the archival blanket removal of pre-abstract figures, generic adjacent-div merging or ordinal regex equation association. Evaluate equation-heavy papers, tables, diagrams and offline transitions in the actual reader.

Commit durable raw publication and corresponding settlement atomically once required outputs and usage evidence are verified. Rendering can then retry independently. Terminal provider/collection/render failure also needs a settlement path so a broken renderer cannot leave holds indefinitely. Provider deletion is a separately retried cleanup operation after verified durable collection; it does not remove our financial reconciliation obligations.

Initially retain all published originals, raw results and render manifests. Garbage collection covers expired unpublished reservations and orphan uploads only. At capacity, reject new work. Future eviction requires a reviewed availability/replica contract because immutable approvals and artifacts point to specific object identities.

## Accounting, privacy and operations

Provider page/progress fields do not establish an invoice amount. Record a pinned-rate expense estimate and later reconcile aggregate provider periods with immutable adjustments. One aggregate invoice cannot be forced into the existing unique job-specific invoice-reference shape. Customer credits remain separately bounded by the accepted quote. [Usage endpoint](https://docs.mathpix.com/reference/ocr-usage)

`improve_mathpix:false` does not establish zero retention for PDFs. Describe the exact account/endpoint retention policy, including provider-held page images/text and any verified account override, before obtaining consent. Do not claim encrypted processing: the provider receives the uploaded paper. Private cloud-chat disclosures are separate. [Retention](https://docs.mathpix.com/concepts/data-retention), [privacy options](https://docs.mathpix.com/concepts/privacy)

Acquire budget periods before capacity policy, funding account, document, work, attempt and object locks. Re-read identities after locking. Never acquire budget/account locks from a helper while already holding a work/attempt lock. Publication creates a durable projection outbox and releases work locks; fanout then updates one account under the library lock order. Each update checks current interest and preserves removal fences and established artifact pins.

Required deterministic schedules include simultaneous funders, lost authorization and submission-grant responses, accepted POST with lost ID, late ID after lease expiry, cancellation on both sides of submission, removal/re-add before publication, delayed uploads, quota exhaustion with cancellation available, missing bundle members, renderer failure without another POST, cleanup/publication races and interrupted fanout. A real equation-heavy import through offline native reading remains the release gate after these contracts pass.
