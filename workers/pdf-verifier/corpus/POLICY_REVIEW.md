# Proposed verifier policy review — not implemented

The public-paper corpus exposes compatibility gaps in frozen pilot v1. Keep that build/profile immutable. Any revised policy needs its own source/build/profile identities, independent review, regression evidence and hosted admission; it cannot be an exception for particular paper hashes or publishers.

## Smallest proposed change

Separate **policy-incompatible** from **structurally malformed** in diagnostics. Today wrapper `-5` (warnings) maps to `malformed`, obscuring the cause. Neither label provides a successful page-count attestation, and neither should let acquisition retry unchanged bytes indefinitely. Preserve a finite, typed cause in the receipt while keeping arbitrary parser strings private.

The narrowest candidate for acceptance is **validated but inconsistent linearization hints**, because sequential page-tree traversal and stream checks do not need those hints. Continue running the checker; permit only explicitly classified hint disagreements after all of the following succeed:

- Exact-byte binding, input and resource admission, strict header/EOF checks, no encryption, no recovery and no parser-limit event.
- A finite, acyclic resolved page tree with a trustworthy count inside the profile; every required object has an unambiguous identity.
- All existing indirect-object, filter, stream-decode and page-content checks finish under their bounds. Hint warnings must not cause an early success or skip these checks.
- The complete warning set contains only reviewed hint classes: the observed per-page hint object-count disagreement, first-page shared-identifier entry, and shared-object-list/hint disagreements. Unknown linearization errors, malformed hint streams, unexpected object/header/xref warnings and any mixed warning set remain refused.
- Hint data is never used as document identity, a page-count authority or a basis for skipping bytes. A downstream reader must not rely on these hints for trusted structure. Require a fresh narrow-host verification receipt under the new identity; v1 failures are not rewritten.

This proposes a typed classification in pinned qpdf code or an equally reviewable adapter. Matching arbitrary warning strings broadly or treating every `qpdf_e_linearization` warning as benign is not sufficient. The current research string-pattern counters describe observations only and must not become a production allowlist.

For the present sample this makes Layer Normalization a **candidate for further complete verification**, not a promised pass: v1 stops at its hints and has not yet checked all later streams/content. It does not admit the other four warning cases.

## Conditions that remain rejected

- Deep kernel processes and DeiT: unresolved/mismatched object headers or xref identity remain refused. A tolerant reader opening the PDF is not evidence that the verifier resolved the intended objects.
- CURL and MSA Transformer: zero-offset live xref objects still fail the initial revision. qpdf substitutes null for this common writer defect. A later exception could be reviewed only if an independent bounded graph walk proves every affected object unreachable from all retained trailer/root/page/resource/content/annotation/metadata references, no repair altered a reachable object, and all normal checks then pass. No such proof exists in this corpus work. Broadly permitting missing/null objects would risk accepting missing pages or content.
- Unknown warnings, decoding errors, recovery, encryption, cycles, ambiguous object identities, unsupported filters and all existing resource-limit failures remain refused. Full object resolution stays required.
- The four papers above 5 MiB continue to fail pilot admission. A larger-input route needs separately measured host and parser bounds; it is not a filename or publisher exception.

## Can the decoded-stream cap increase inside the same 64 MiB heap?

**Technically possible, not established safe by these results.** `BoundedDiscard` does not retain cumulative decoded output. The pinned qpdf Flate pipeline passes bounded output chunks, and DCT decoding writes scanlines to its downstream pipeline. Consequently a cumulative 64 MiB output budget would not itself allocate a 64 MiB buffer. JPEG compressed-input and internal decoder buffers, qpdf's object/cache allocations, page-content buffers, JS copies and the host still consume memory; the fixed WASM heap is not a process-memory bound.

All three resource cases stopped at 32 MiB during stream decoding, with no token/page-content/global-parser limit. Their eventual decoded totals, later stream warnings and later CPU/memory costs are unknown. The largest observed 93.70 MiB post-run RSS snapshot is not peak evidence. CPU below 271 ms at the refusal boundary does not establish the cost of completing a larger or hostile input.

A **separate research experiment**, after review, could test a 64 MiB cumulative-stream budget while retaining the fixed 64 MiB heap, 5 MiB input, 50 pages, 32 MiB page-content budget and every other guard. First collect the complete decoded totals of these three papers, true host peak if the host can measure it, and bounded failure behavior on expansion/image/content adversaries. Require measured CPU/wall headroom and enforceable whole-host memory/termination boundaries. If those cannot be demonstrated, keep the Edge pilot cap and use a separately admitted isolated verifier host. No stream cap is changed by this proposal.

## Required executable regressions before any v2 admission

1. Re-run all 24 exact corpus hashes and existing synthetic hostile fixtures; record newly accepted cases, unchanged failures and complete verification costs. Keep original v1 outcomes as the comparison.
2. Generate distinct hint mismatches around valid pages and show only the reviewed typed classes can complete. Valid hint warnings combined with invalid xref/header, bad stream, cycle, unsupported filter or bad EOF must still fail.
3. Exercise every refused hint class, malformed/truncated hint stream and unexpected warning code. A qpdf change that changes classification must fail the identity/profile gate, not silently expand acceptance.
4. Construct zero-offset objects that are unreferenced, metadata-referenced, resource-referenced and page-tree-referenced. They all remain refused in the first revision. Keep mismatched object-number/generation and missing-header fixtures refused, including object-stream variants.
5. Exercise exact decoded-byte boundary, one-byte overflow, many-stream cumulative overflow, large JPEG scanlines, structural Flate bombs, repeated page content, nesting and allocation/stack traps. No cap failure may expose a verified page count or admit a partial bundle.
6. Kill a verifier at its wall deadline and reconcile a finite negative result. Lost receipts, duplicate callbacks, profile mismatch and wrong input hash must remain fenced. Corpus success does not replace those acquisition/host contracts.

The outcome of this review should be an explicit versioned policy and rollout decision, not a broader warning-ignore switch.
