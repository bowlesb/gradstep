# Paper pipeline (Edge)

Status 2026-10-05: implemented in migration 014, `supabase/functions/_shared/pipeline.ts`,
`paper-worker`, and `reader-artifact`. Replaces the unprovisioned Linux executor design
(012/013 candidates deleted; history in git before commit `39cc8ce`).

## Flow

1. **Import.** `v2_begin_import` (unchanged customer API) inserts an import; a trigger links it to a
   shared `pipeline_papers` row keyed by `(arXiv id, requested revision or 0 = latest)` and wakes the
   worker through `pg_net` (no-op where `pg_net`/Vault are absent). `pg_cron` also invokes the worker
   every minute.
2. **Claim.** `worker_pipeline_claim` picks one due paper with `FOR UPDATE SKIP LOCKED`, bumps its
   generation and leases it. Every stage function verifies `(claim id, generation, unexpired lease)`.
3. **Metadata.** Atom + OAI arXivRaw (globally spaced 3 s apart via `worker_pipeline_arxiv_slot`).
   CC BY 4.0 / CC0 papers are eligible for the shared catalog. Others currently end `source_only`
   (planned: per-account private conversions — see DECISIONS).
4. **Download.** `https://arxiv.org/pdf/<id>v<rev>`, bounded to 64 MiB, page count via pdf-lib
   (~100 ms for a 40 MB PDF), stored at `paper-assets/originals/<sha256>.pdf`. Identical bytes
   from any slot reuse an existing reader without another charge.
5. **Fund.** `page_limit = min(pages, 80)`. The first interested account with credits gets a hold of
   `page_limit × 1` credits and `page_limit × $0.005` of platform budget (`worker_reserve_operation`).
   No credits → import fails retryable (`insufficient_credits`); budget exhausted → wait.
6. **Submit.** Payload prepared first, then `worker_pipeline_begin_submit` grants exactly one POST.
   A second begin for the same attempt (lost acknowledgement) marks it `ocr_uncertain`; the hold
   stays until an operator reconciles. Mathpix gets `page_ranges: 1-<page_limit>` (part of the OCR
   options hash). PDFs > 8 MiB are submitted by a 1-hour signed Storage URL.
7. **Wait/collect.** Poll status and the `mmd.zip` conversion; store `standalone.mmd`,
   `output.mmd.zip`, `lines.json` and a canonical raw manifest under `raw/<manifest sha>/`. Settle on
   processed pages (`lines.json`), capped at the hold; record `provider_usage_events`.
   Provider-reported failure settles 0 credits to the customer (cost still counted).
8. **Render.** MathML reader bundle (`timestep-mathpix-mathml-v1`) from the archived MMD and images,
   stored under `reader/<manifest sha>/`; `worker_pipeline_published` creates the render artifact and
   marks it available.
9. **Resolve.** `worker_pipeline_sync_imports` (separate transaction, never holding the paper row)
   projects progress (`finding/downloading/converting/rendering`) onto imports and resolves them
   through the existing `worker_resolve_import`, producing a `converted_ready` library item.

## Delivery and chat context

`reader-artifact?item_id=` authenticates the user, calls `worker_reader_descriptor` (visible item,
available render), verifies the stored manifest hash, and returns signed member URLs (15 min) plus the
trusted manifest digest. The app re-verifies every member before encrypted installation.
`worker_chat_context` returns the archived MMD path for a document the account can read.

## Failure handling

Transient errors back off (`15 × 2^n` s, max 10 min). After 5 failures metadata/download/fund/render
fail with a resumable stage that a user Retry restarts. Submit/wait never give up on transient errors
because they hold credits. Lost leases are ignored by the fenced RPCs (`stale_pipeline_claim`).

## Operations

- `scripts/deploy-staging.py staging` — migrations, bucket (64 MiB objects), secrets, functions, schedule.
- `scripts/pipeline-ops.py status|budget --usd N|enable|disable|grant ACCOUNT CREDITS KEY|kick`.
- The monthly platform budget (`platform_budgets`) is the hard provider-spend cap; an actual cost above
  a hold freezes new work automatically.
