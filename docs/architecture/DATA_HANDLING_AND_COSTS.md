# Data handling and cost explanation

2026-10-13 verified staging direction: every PDF is downloaded/processed only on the device,
initial structured preparation uses arXiv HTML without an OCR charge, and a future local model has no Mathpix
fallback. Explicit paper chat still sends necessary text to cloud AI under the existing consent and metering.
[HTML-first reader](HTML_FIRST_READER.md) defines the exact boundary. Native/browser explainers now describe the enforced boundary; historical usage and outstanding OCR reservations remain accounted for.

Status: owner-requested product explanation, 2026-10-09. This document is the source for the short
**How Gradstep works** screen in the native and browser clients. It is explanatory product copy, not a
provider privacy guarantee or a substitute for the applicable privacy policy and paper licences.

## The data paths

Gradstep separates local paper storage, encrypted synchronization and requested AI processing:

- Library metadata, tags and encrypted chat events can sync through Supabase. Chat and note
  content is encrypted before synchronization; device-held keys or the recovery code are needed to read it.
- New PDF downloads, intake, viewing and processing happen only on the user's device. Exact official arXiv HTML
  is compiled locally into the structured reader. The server's historical copies of papers (PDFs, Mathpix output and
  reader bundles from before 2026-10-13) are retired and deleted on the owner's decision of 2026-10-16
  ([below](#server-paper-copies-retired)). Browser PDFs stay in the selected device file/tab and must be chosen again after reopening.
- A paper chat sends the question, selected passage, conversation context and verified reader text to the chosen
  cloud model under explicit consent. Stored-history encryption does not hide requested computation from that provider.
  Since 2026-10-16 the chosen model may be DeepSeek's (consent `cloud-ai-v4` names it): DeepSeek then receives the
  answer's request, including any figure image, while Anthropic's Claude Haiku still writes the chat's title and
  suggested follow-up questions from the question and a short excerpt.
- A future local PDF model is not installed yet. There is no Mathpix fallback or OCR charge for local HTML preparation.
- Optional web search sends search queries to the configured search provider. Provider retention and handling
  follow that provider's terms; Gradstep does not promise zero provider retention.

## The cost paths

A credit is a Gradstep usage unit, not cash or a provider's own credit. Before paid work begins, the server
quotes the expected and maximum usage and reserves a bounded amount. It settles the actual measured provider
usage afterward. Operation identities make retries and lost responses idempotent, so one request is not charged
twice because a network acknowledgement was lost.

**When work stops early (owner decision 2026-10-16).** The reader pays for work that finishes, or for the part of an
answer they chose to stop. If the provider fails or overloads partway, our server fails, an answer reaches our own time
limit (130 s) or length limit, the connection between our server and the reader drops, or the model refuses, the reader
is charged nothing: their hold is released and any text already shown stays theirs. Gradstep still pays the provider
for that work, and records it as absorbed cost in the month's provider spend and on the admin's Health tab; it counts
against the same budget and is never hidden. A title, suggested questions or a study-map update that could not be
delivered is Gradstep's cost too. Podcasts already charged only for a ready episode or the used part of one the reader
canceled. Definitions for each paid feature: [CHAT.md](CHAT.md#when-an-answer-stops-early--2026-10-16).

Chat, search and podcasts have separate provider attempts, limits and accounting. Ready-made catalog podcasts avoid repeating provider work. Historical OCR charges remain in the ledger. Customer credit accounting, provider
expense, platform budgets and unresolved provider liability remain separate records. Account and platform gates
stop a user, retry loop or provider outage from creating an unlimited bill.

The measured cost of a chat depends on paper and conversation size, cached context, model, effort, answer length,
tools/search and the tokens actually used. The user sees the profile's estimate and maximum before generation,
then the final credit charge afterward.

## Current model policy

The current chat profiles are server-enforced:

- **Haiku** is the fast, lower-cost choice for simpler work.
- **Sonnet** is the default balance of quality and cost.
- **Opus** is reserved for harder reasoning.
- **DeepSeek** (DeepSeek V4.1 Flash, `deepseek-flash`, since 2026-10-16 on staging): a low-cost model from another
  provider, offered only when the reader chooses it under consent `cloud-ai-v4`, priced at DeepSeek's peak list rates
  and admitted, recorded and circuit-broken as provider `deepseek` (docs/architecture/CHAT.md "DeepSeek in chat").
  It passed a recorded check on DPO (equations, citations, a figure question, visual tools) before it was offered. At
  list prices Claude Haiku 5.5 is still the cheapest per token; DeepSeek sits between Haiku and Sonnet.

Effort is chosen by the server for each question when the client asks for `auto` (new clients do): low for Brief,
medium for Standard questions that ask for reasoning or carry an equation or figure, high for Detailed reasoning
questions. The quote and the answer record the effort used.

The server records the model that actually answered, including an approved fallback. A cheaper provider is not a
drop-in replacement for scientific reading. Before adding DeepSeek or another provider, we must compare equation
and citation quality, long-paper grounding, privacy/retention terms, latency, structured tool behavior and actual
measured cost on representative journeys. Price alone is not a sufficient launch criterion.

## DeepSeek comparison (research only; not a routing decision)

The current official DeepSeek API page lists `deepseek-flash` (DeepSeek-V4.1-Flash) at **$0.15/M input,
$0.60/M output and $0.003/M cache-hit input off-peak**, rising to **$0.30/$1.20/$0.006** at peak. Its
`deepseek-v4-pro` rates are **$0.66/$1.98/$0.022** off-peak and **$1.32/$3.96/$0.044** peak. Peak windows,
model names and prices can change; these figures were read 2026-10-09 from the [official DeepSeek pricing page]
(https://api-docs.deepseek.com/quick_start/pricing/).

The deployed Gradstep tariff for Sonnet 5.5 is $2/M uncached input, $10/M output and $0.10/M cache-read input.
Against that card, Flash is approximately **13.3× cheaper on uncached input and 16.7× cheaper on output
off-peak** (about 6.7× and 8.3× at peak). V4 Pro is approximately **3× cheaper on input and 5× cheaper on
output off-peak**. These are token-rate comparisons, not a quality-adjusted product cost; a different tokenization,
longer answer, extra validation pass or fallback can erase part of the apparent saving. Anthropic's current
[official pricing documentation](https://platform.claude.com/docs/en/about-claude/pricing) describes the
Sonnet cache-read multipliers and the same token accounting principle.

**Update 2026-10-14:** DeepSeek is now enabled for one use only: writing podcast episode scripts, when the reader chooses it as the writer (docs/architecture/PAPER_PODCASTS.md; migrations 063–065). Chat does not use it.

**Update 2026-10-16:** chat may now use `deepseek-flash` too, when the reader chooses DeepSeek (owner request on
TestFlight build 57; migration 078). It is opt-in per chat, bounded by the same credit and provider-spend controls,
and was published only after the recorded check in docs/architecture/CHAT.md: on four DPO questions it typeset every
equation, cited only passages that exist, read a figure from its image and called the visual and figure-parts tools,
for $0.038 against $0.273 for the same questions on Sonnet. Its first text arrives later (8–23 s at medium effort). This comparison itself enabled no traffic. Any future trial must be opt-in at the server profile level,
bounded by the same credit and provider-spend controls, and accepted only after the quality and data-handling
review passes.

## Server paper copies: retired

Owner decision, 2026-10-16: "Yes, we can even delete them now, so it's obvious we have zero on our system", for the
inventory of 2026-10-15. Staging data is disposable and no legacy data migration is wanted (AGENTS.md). Podcast audio
and transcripts, the text a device sends for an episode and report attachments are not paper copies and are out of
scope. Database: migration 080 (`202610160080_server_paper_copies_retired.sql`); deletion:
`scripts/delete-paper-copies.mjs`; what counts as a copy: `scripts/paper-copies.mjs`; guard: the `storage.no-papers`
workflow check.

### Inventory (re-counted 2026-10-16 before deletion)

Storage's own listing (Storage API, recursive) and `storage.objects` agree, and every object is tracked as `verified` in
`app_private.stored_objects` (the 2026-10-09 inventory reconciliation still holds: no untracked or missing object).

| Bucket / prefix | Objects | Bytes | What it is |
|---|---:|---:|---|
| `paper-assets/originals/` | 28 | 209,137,904 | Shared-catalog PDFs |
| `paper-assets/private/<account>/originals/` | 47 | 170,668,581 | Private PDFs, 9 accounts (`legacy_private` arXiv conversions and web papers) |
| `paper-assets/raw/<sha>/` | 300 | 163,482,296 | Mathpix output: `standalone.mmd`, `lines.json`, `output.mmd.zip`, `manifest.json` (75 runs) |
| `paper-assets/reader/<sha>/` | 1,256 | 105,979,674 | Server reader bundles: `index.html`, `reader.json`, figures, manifest, notices (75 bundles) |
| **`paper-assets` total** | **1,631** | **649,268,455** (619.2 MiB) | 75 live documents of 86 (11 went with account deletions) |
| `paper-uploads` | 0 | 0 | PDF upload chunks (fenced since 058) |
| `podcast-assets` (control) | 18 | 12,308,378 | Episode audio/transcripts: 15 shared, 3 private. Not touched |
| `private-content`, `support` (controls) | 0 | 0 | Episode source text (deleted when made), report screenshots. Not touched |

Rows that name these objects, all **kept** as history (accounting, provider attempts and encrypted chat bindings point
at them, and the foreign-key graph spans the ledger): `stored_objects` (1,631 verified + 118 already deleted),
`paper_asset_manifest_members` (1,491), `paper_asset_availability` (172), `documents`, `render_artifacts` and `ocr_runs`
(86 each), `catalog_asset_approvals.original_object_id`, `pipeline_papers` (document/original/artifact ids),
`podcast_sources` (13 server-text pins of past episodes), `reader_delivery_grants`/`_redemptions`, `acquisition_jobs`,
`ocr_attempts`, `library_items` and `library_asset_projection` (96 items in 23 accounts: 90 arXiv, of which 81 visible;
6 web papers from other sites; no uploads). Only three things change: each object's state (verified -> deleting ->
deleted, the lifecycle account deletion already uses), each paper copy's availability (unavailable, reason `missing`, at
a new revision) and the library projection (recomputed and emitted, ids kept). No table is dropped.

### Every path that read or wrote them, and what it does now

| Path | Before | After retirement |
|---|---|---|
| `reader-artifact` (`worker_reader_descriptor`) | Signed URLs or one-use grants for a legacy bundle | 403 `reader_unavailable` (needs a verified manifest and `render_availability=available`) |
| `reader-member` (grant redemption) | Streams one member | 403 `reader_grant_unavailable` |
| `chat`, legacy item (`worker_chat_context`, `standalone.mmd`) | Server text as context | `document_unavailable` (080; it would have been `asset_inventory_incomplete`, a generic failure, under the enforced inventory) |
| `chat`, local context (`worker_local_chat_context`) | Source memberships only | Also a legacy arXiv library item (080), so a client can send the text its reader prepared |
| Podcasts (`podcast_item_pin`, `podcast_approval_pin`) | Server text pins episodes and seeds | No pin: the quote says `source_unavailable`; no seed candidates. Existing episodes keep playing |
| Podcasts, device text (`podcast_device_pin`, `v1_podcast_paper`) | A source membership's text from the device (066) | Also a legacy arXiv library item (081): the quote names the item and sends the text prepared on the device, pinned only to the item's exact arXiv source and revision; its episodes are found by the item and belong to its document |
| Original PDFs (`v2_original_descriptor`, `worker_authorize_original_read`) | Fenced in 058 | Unchanged (`pdf_device_only`) |
| Writers: pipeline asset/original RPCs, `upload-pdf` | Fenced in 058 (`pdf_device_only`, HTTP 410); the Cloud Run worker is metadata-only and its PDF code is deleted | Also refused by the 080 fence: no `paper-assets`/`paper-uploads` row can be registered (`paper_copies_retired`). Storage has no policies, so only the service role could write, and no deployed code does |
| Account deletion | Lists `private/<account>/` and private `raw/`/`reader/` folders | The bucket stays (an absent bucket would fail the listing); the folders are empty |
| `scripts/backup.py` (manual, encrypted) | Copies every verified object | No paper copy is verified, so none is copied |

Clients, as read from the code (native builds 57–60 are the same here except build 57's no-HTML screen; the browser is
deployed with this change):

| Client | Legacy arXiv item | Legacy item from another site (6 web papers) | Chat / Listen on a legacy item |
|---|---|---|---|
| iPhone, iPad, Mac 57–60 | `canReadStructured` is false once the row says unavailable: no prefetch and no server fallback. Opens from arXiv on the device as before ("Opens from arXiv"); a copy already installed on the device keeps opening. Without arXiv HTML: builds 58–60 "No web version of this paper" with Open PDF (on the device); build 57 the arXiv reason | Row: orange "No readable copy on this device", status "Reader unavailable". Opened: "Couldn't open this paper — This paper has no reading copy on the server. You can save its PDF on this device." | Chat: "This paper isn't ready for questions yet. Try again after it finishes processing." (the server no longer has its text; a native update can send the device text as the browser does). Listen: "Open this paper first so it's ready on this device, then try again." (the server accepts the device text from migration 081; a native update must send it, as the browser does) |
| Browser (this release) | Opens from arXiv on the device; the row is a cloud ("downloads when you open it"). Without arXiv HTML: "No web version of this paper" with Open PDF; the server is asked only while the row still says available, and its refusal keeps arXiv's reason | Row: "⚠ No reading copy", "!" badge, not a link; opened by URL: "Gradstep's servers don't keep a reading copy of this paper." | Chat sends the text prepared in this tab, naming the library item (falls back to the document id when the paper can't be prepared). Listen: the text prepared in this tab, quoted with the library item (migration 081; browser from this release) |

Nothing errors, loops or shows a generic failure: before the projection changes the native prefetch and fallback would
have repeated 403s on every library publication; after it they never ask.

### Procedure

`node scripts/delete-paper-copies.mjs` (dry run, the default) prints Storage's counts and bytes per bucket and prefix,
the controls and the tracked rows. `--apply` (staging only; the project ref is asserted): (1) `worker_paper_copies_retire`
turns the fence on, marks availability unavailable and schedules every tracked copy (refused while any paper write is
unresolved); (2) `worker_paper_copies_project` recomputes and emits the library rows, so devices stop asking before any
file goes; (3) page by page, removes the files from Storage, lists their folders again, and only then confirms them
`deleted`; (4) removes any untracked object on a pipeline path (anything else stops the run); (5) lists Storage again:
zero objects in the paper buckets, controls unchanged, zero tracked live. Counts only go to `.artifacts/paper-copies/`.

### Evidence (staging, 2026-10-16)

- Migration 080 applied and verified in the ledger after 079. Browser deployed first (Pages `768a86a0`, then
  `afa4262f`), so the browser never saw an unavailable row without the new reading rules; How Gradstep works now says
  the earlier copies were deleted (browser `e855f3c6`; the apps from their next build).
- `delete-paper-copies.mjs --apply`: retired at 06:35:52 UTC; 172 availability rows marked; 96 library rows projected;
  1,631 objects (649,268,455 bytes) removed in two pages, each re-listed before it was confirmed; 0 untracked objects;
  complete at 06:36:42 UTC. Report: `.artifacts/paper-copies/2026-10-16T06-35-52-126Z-apply.json` (counts only).
- Afterwards: Storage lists 0 objects in `paper-assets` and `paper-uploads`; `storage.objects` holds only
  `podcast-assets` (18 objects, 12,308,378 bytes, as before); the 1,749 tracked `paper-assets` rows are all `deleted`;
  every library projection is unavailable/unavailable.
- Server answers on real rows, in rolled-back transactions: legacy arXiv item `reader_unavailable`,
  `document_unavailable`, no podcast pin, device-text chat accepted; web item the same, device text refused.
- `storage.no-papers` passed and was recorded locally and from the hosted job's new image.
- No provider spend. Storage use falls by 649 MB; the Supabase plan's fixed cost is unchanged.

### Keeping it at zero

`storage.no-papers` (`scripts/workflow-checks.mjs`, every suite: the 6-hourly canary, daily and weekly) fails when
Storage lists any object in `paper-assets` or `paper-uploads`, when any paper copy is tracked as pending, verified or
deleting, or when the fence is off. Free; no account.

### What this does not cover

- Supabase's daily database backups (7 days) still hold the rows that name the deleted files until they age out; they hold
  no file bytes (Storage objects are not part of database backups).
- Manual encrypted checkpoints made with `scripts/backup.py` on the developer's Mac (`.artifacts/backups/`, 2026-10-03
  to 2026-10-09) include these objects, encrypted. They are not on a server; deleting them is the owner's call.
- Mathpix processed these PDFs before 2026-10-13 under its own retention terms.
