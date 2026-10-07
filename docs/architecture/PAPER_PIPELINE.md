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
   CC BY 4.0 / CC0 papers are eligible for the shared catalog. Others split into one private
   conversion per interested account (`private_split`: `owner_private` document under
   `private/<owner>/`, owner-funded OCR, never shared; see DECISIONS).
4. **Download.** `worker_pipeline_admit_download` first (environment storage cap 5 GiB / 50k objects,
   1 GiB of private originals per owner, private downloads need available credits). Then
   `https://arxiv.org/pdf/<id>v<rev>`, bounded to 64 MiB, page count via pdf-lib (~100 ms for a 40 MB
   PDF), stored at `paper-assets/[private/<owner>/]originals/<sha256>.pdf`. Identical bytes
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
8. **Render.** MathML reader bundle (`timestep-mathpix-mathml-v1`) from the archived MMD and images
   (sentences split at page breaks are rejoined first; see READER_RENDERER),
   stored under `reader/<manifest sha>/`; `worker_pipeline_published` creates the render artifact and
   marks it available.
9. **Resolve.** `worker_pipeline_sync_imports` (separate transaction, never holding the paper row)
   projects progress (`finding/downloading/converting/rendering`) onto imports and resolves them
   through the existing `worker_resolve_import`, producing a `converted_ready` library item.

## Web papers

Migration 019 (Ingest of a cited paper with no arXiv copy;
[decision](../DECISIONS.md#ingest-adds-papers-from-the-web-owner-asked-2026-10-05)). Same stages, with these
differences:

- **Identity.** `v2_begin_web_import(operation, 'openalex:W<digits>', observed cursor)` (no revision; digest tag
  `web-import-v1`). The prefix can never equal an arXiv ID, so the shared/private slot indexes and every
  `source_id` comparison are unchanged. Catalog: identifiers `openalex:W…` (namespace added) and the DOI, version
  `('web','v1')`, `catalog_metadata.source_revision = 1`.
- **Metadata** (`worker_pipeline_web_metadata`): the worker reads the work from `api.openalex.org` (redirects only
  within it, 2 MiB cap): title, authors, abstract, publication date, venue (`categories` empty), DOI, up to three
  PDF locations (`openPDFLocations`: the best open-access location, then PDFs on free ML venue hosts whatever
  OpenAlex's open-access label says, then other open-access locations; http upgraded to https; arXiv-hosted,
  IP-literal and local names dropped) and the landing page. Ingest uses the same rule to decide whether a match
  has an open copy. The paper is always `eligible = false` (check
  `pipeline_web_private`) and splits privately; `license_uri` is the landing page. No location → failed
  `download_failed`, retryable from metadata.
- **Download.** Locations are re-read from OpenAlex first (`worker_pipeline_web_locations` records a changed list;
  the recorded list is the fallback), then tried in order (`fetchFirstWebPDF`) within one 110 s budget (inside the
  180 s lease; with under 30 s left in the invocation the paper is deferred to a fresh one): https on the default
  port to a public DNS name, host resolved before every hop (`Deno.resolveDns`, else DNS over HTTPS; any private,
  loopback, link-local, shared, Teredo, documentation or reserved address refuses the hop; `dns_fallback` /
  `dns_unresolved` are logged), every redirect re-checked (at most 5; never to arXiv), `text/html` or a body not
  starting `%PDF-` refused (landing pages, bot challenges), 64 MiB cap, 60 s per request. 401/403/404 and the like
  are permanent `download_failed` (retryable by the reader); 429/5xx, resets and running out of budget are
  transient. Since migration 027 (2026-10-07) bodies are sniffed, refusals are told apart (`pdf_restricted`, `source_blocked`,
  `not_pdf`), PubMed Central is fetched from NLM open data, and download failures that can change are retried automatically;
  see [self-healing downloads](PIPELINE_RELIABILITY.md#self-healing-downloads-migration-027). Admission, page limits, `countPages`, the private path and `worker_pipeline_original` are the arXiv
  ones. Metadata text has control characters removed (the reader's attribution refuses them).
- **Provenance.** `approve_private_asset` records the landing page and PDF locations in the owner-private
  approval; the reader attribution names the paper and links the landing page ("Converted for the personal use of
  one Science Reader account; not redistributed").
- **Library reads.** Entries carry `source: "web"`, `source_id: "openalex:W…"`, and `source_url` = the OpenAlex
  work page for imports and the landing page for items. Builds before 019 reject any non-arXiv entry and would
  stop syncing, so `v2_library_page`/`v2_library_changes` omit web entries (a change batch left empty is skipped;
  the page limit counts returned batches) and `v3_library_page`/`v3_library_changes` return everything. An arXiv
  import whose bytes match a web-pinned item ends as `membership_conflict` without an item, so a v2 reader never
  sees a reference to a hidden item; a web import never pins a legacy unpinned item either. A future source kind
  needs a new read version.
- **Stored progress** (all imports, from 019). `import_requests.progress` is written by
  `worker_pipeline_sync_imports` together with a new `state_seq`, instead of being computed from the paper's live
  stage, so an import entry's JSON at a given `state_seq` never changes (clients and the offline cache require
  that). New imports start at `finding`.

## Delivery and chat context

`reader-artifact?item_id=` authenticates the user, calls `worker_reader_descriptor` (visible item,
available render), verifies the stored manifest hash, and returns signed member URLs (15 min) plus the
trusted manifest digest. The app re-verifies every member before encrypted installation.
`worker_chat_context` returns the archived MMD path for a document the account can read.

## Failure handling

Every fenced call renews the 180 s lease; paper rows use `FOR NO KEY UPDATE` so the customer import
trigger never waits on a worker. Transient errors back off (`15 × 2^n` s, max 10 min). After 5 failures
metadata/download/fund/render fail with a resumable stage that a user Retry (or a new importer) restarts.

Every credit hold has an exit:

| Situation | Exit |
|---|---|
| Funded but the original can't be prepared (3 tries) | `worker_pipeline_abandon_funding`: settle 0/0, retry restarts at download |
| Funder withdrew before the grant | `begin_submit` releases the hold and refunds from another interested account |
| POST result lost (lease expired, RPC failed) | `worker_pipeline_submitted` is keyed by attempt, retried, and accepts a late job id after `uncertain` |
| Genuinely uncertain POST | Operator: `pipeline-ops.py resolve ATTEMPT --job ID` (resume polling) or `--pages N` (release, no customer charge) |
| Provider error, deleted job, unusable output, > 6 h | `worker_pipeline_ocr_failed`: customer not charged, estimated provider cost recorded |

Submit and wait never give up on *transient* errors. Import projection runs per link with its own backoff
(`next_sync_at`), locks link accounts in id order first, and never fails the shared paper.
Identical bytes never pay twice: an existing render is reused; retained raw OCR (another slot or an older
renderer version) is re-rendered without a charge; an existing artifact is adopted on publish.

Measured on hosted staging Edge (2026-10-05): MathML rendering of the 27-page DPO paper takes 0.7–0.8 s
with a ~55 MB heap; pdf-lib counts pages of a 40 MB PDF in ~100 ms (local).

## Operations

- `scripts/deploy-staging.py staging` — migrations, bucket (64 MiB objects), secrets, functions, schedule.
- `scripts/pipeline-ops.py status|budget --usd N|enable|disable|grant ACCOUNT CREDITS KEY|kick`.
- The monthly platform budget (`platform_budgets`) is the hard provider-spend cap; an actual cost above
  a hold freezes new work automatically.
