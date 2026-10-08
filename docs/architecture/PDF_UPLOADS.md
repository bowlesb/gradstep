# Adding any paper: identifiers, PDF uploads, device downloads, sharing

> **Status, 2026-10-08 UTC:** migration `202610070039_pdf_uploads.sql` is applied on staging; `add-paper`,
> `upload-pdf`, the private `paper-uploads` bucket and the bounded worker transport are deployed. Scope-2 inventory
> completed with zero discrepancies and upload admission was enabled. Native epoch/descriptor/chunk adoption
> is in the build-17/18 lineage; build 19 also carries 042's v5 ordinary library-write repair. Browser PDF upload
> remains unavailable. The Share extension's App Group/App ID/profiles and real system-share/device journeys
> remain separate acceptance gates; these are not claims that every upload path has been exercised on a device.

The signed/upsert candidate was replaced by the bounded authenticated protocol below before deployment.
Migration 033 is now the applied purchase-verifier transport, followed by safeguards 034–038 and uploads 039;
do not reuse the old “033 unused” plan. Applied migrations are immutable. Current rollout evidence and remaining
legacy reader-delivery exposure: [Asset spending](ASSET_SPENDING.md) and
[implementation status](../IMPLEMENTATION_STATUS.md). The detailed sections retain the original implementation
contract and local checks; historical wording there does not override this current deployment checkpoint.

Owner, 2026-10-07: "adding a pdf needs to be absolutely bullet proof." About 17 publishers refuse downloads from
cloud servers (our worker runs on Google Cloud; [self-healing downloads](PIPELINE_RELIABILITY.md#self-healing-downloads-migration-027)),
so for some papers the reader's own device and network must supply the PDF. Four ways in, one path through the
pipeline:

| Way in | Server path | When our servers can't fetch it |
|---|---|---|
| Add › arXiv ID or link | unchanged (`v2_begin_import`, queued on the device) | — |
| Add › DOI, landing page, PDF link, reference | `functions/v1/add-paper` → arXiv or web import | `closed` → Upload the PDF; `blocked`/`link_only` → Download on this device |
| Add › Choose a PDF; drop a PDF (iPad, Mac) | upload session → `upload:<id>` paper | — |
| Failed web import (`source_blocked`, `pdf_restricted`, …) | — | Download on this device / Upload PDF → same import |
| Share › Gradstep (Safari, Files, Mail) | app inbox → upload queue or Add | as above |

## 1. Add by any identifier or link (`add-paper`)

`_shared/identify.ts` + `_shared/add-paper.ts`, no model, no credits, ~25 s budget, rate route `add-paper`
(120/h per account). Outcomes are recorded as `reference` reliability events with route `add_<route>`.

- **arXiv** ID or link: imported as today (the app queues it locally; the server accepts it too).
- **DOI** (`10.…`, `doi:`, doi.org links, percent-encoded): OpenAlex's work → its arXiv copy, else an open PDF
  (web import), else a preprint found by title (shared finder), else **closed** with the work's identity
  (`openalex:W…`) and landing link. A DOI OpenAlex doesn't know is named by Crossref and searched by title.
- **Link**: the DOI in the path (ACM, Wiley, T&F, SAGE, Springer, Science, Nature `articles/…`); known proceedings
  PDFs mapped to their landing pages (NeurIPS, PMLR, ACL Anthology, CVF, JMLR, OpenReview, AAAI); otherwise the
  page is probed with the web import's checks (https, public names, every hop re-resolved, private addresses
  refused, 12 s per request) and read for `citation_doi`, `citation_arxiv_id`, `citation_title`, Dublin Core and
  `citation_pdf_url`. A PDF link or a page declaring one that identifies nothing is **`link_only`** (the device
  downloads it and uploads it as a paper of its own, titled from the page); a refusal is **`blocked`** with the
  reason (`source_blocked`, `pdf_restricted`, `source_unavailable`).
- **Other text**: add-reference's resolution (arXiv id, DOI, title, Crossref, OpenAlex search).

App: `AddInput` (arXiv stays local), `AddOutcome.from` (the reader's words and next steps), `ImportPaperView` in
`Views/AddPaperView.swift`. A queued paper closes the sheet; anything else stays with its message and buttons.

## 2. Upload sessions (migration 039, `upload-pdf`)

The session keeps the import identity from [DATA_MODEL](DATA_MODEL.md#import-identity-and-membership), with
storage admission shared by migration035. The 64 MiB PDF is transported in fixed 4 MiB chunks; the final chunk
has its exact remaining length. The private `paper-uploads` bucket accepts only octet-stream objects up to4 MiB.

1. **Begin** admits the complete SHA-256, byte count, each chunk hash and exact target identity. It reserves both
   staging and future original/raw/reader capacity under the common ledger. No physical object or Storage token
   is returned. The same ID and request replay; changing the request under that ID conflicts.
2. **Send** uses authenticated Edge PUT requests. Preflight precedes body reading; exact bounded size and hash
   precede a durable one-send grant. Each attempt writes one immutable path without retry, redirect or upsert.
   A lost acknowledgment remains uncertain and separately charged. A replacement needs a new admitted attempt.
3. **Freeze then attach** are two durable transactions. Freeze binds exact positively verified selected objects,
   session generation and original target revision. Attachment creates/retries the exact import without holding
   the capacity mutex. A stale target fails; retries recover the same receipt. A download already admitted by a
   worker defers attachment while preserving the frozen session. No newest-upload lookup substitutes identity.
4. **Verify** begins only after the worker atomically transfers future holds to its paper and receives the exact
   committed source descriptor. Every assembly GET is admitted/accounted before transfer. Ordered part hashes,
   total hash/length, PDF structure and pages must all match before the inventoried private original is published.
   Invalid bytes abandon that selection; a replacement binds a new wanted intent and leaves old bytes charged.
5. **Recover and sweep** retain unknown writes, even after expiry/cancellation. Paced positive GET evidence can
   settle a lost write receipt; absence never proves that a delayed write cannot land. Exact deletion batches are
   issued only after all sends terminate. Future-unused holds may be removed, but physical capacity releases only
   after confirmed deletion. Already-clean or unknown-only terminal receipts cannot starve later cleanup work.

Admission also enforces owner/environment byte and object capacity, 10 active sessions per account/200 per
environment, at least one available credit, separate begin/chunk/status rates, and lifetime evidence/read ceilings.
Receiving/frozen sessions expire after24 hours. A checking session becomes stale after7 days only when no active
claim or exact wanted bound intent still uses it. These database ceilings bound application admission; they do not
claim that rejected platform invocations or every possible infrastructure charge are free.

**Targets.** `paper` creates an owner-private `upload:<id>` at download. `import` supplies an exact revision of an
existing web/upload import for device fallback; a failed import is retried through the existing library command.
`source` creates the known closed web paper's import. Only one checking selection exists per owner/source, and the
worker pins an exact session/generation/intent. Web papers and reader-supplied PDFs remain owner-private.

**Uploaded papers in the library.** Uploaded sources and descriptor refs require additive v5 full and compact/query
capabilities. Existing v2/v3/v4 views must consistently hide unsupported entries and tombstones, including query
counts/hydration, while preserving installed cursor semantics. V5 has its own dataset epoch/cursor binding and
requires a fresh baseline on capability transition. This compatibility integration is still an enablement gate.

Custom title and optional original filename live only in an authenticated, versioned encrypted descriptor derived
from the account's device-held epoch keys. Catalog metadata remains the immutable neutral “Uploaded PDF” record;
server-side title search never sees the personal title. Clients resolve descriptor refs, retain opaque ciphertext
when keys are unavailable/corrupt, and display a neutral placeholder without breaking library sync. Accurate custom
title search/sort requires the complete decrypted local descriptor index. Descriptor bytes share the encrypted
storage allowance and are included in additive usage totals. Session cleanup keeps the descriptor; account deletion
erases it. Uploaded papers are not sent for catalog tagging; the approval policy remains `owner-upload-v1`.

**Closed web papers.** A work with no open PDF now records its metadata and splits privately; its private paper
fails at download as **`not_open`** (resumable, no automatic retry), so the reader can supply the PDF to the same paper.

## 3. Download on this device

`Services/DevicePDFFetcher.swift` mirrors `web-source.ts`: https on the default port to a public DNS name, the host
resolved before every hop (`getaddrinfo`) and every address public, redirects never followed by the session but
checked one by one (at most 7), 64 MiB streamed to a temporary file, `%PDF-` required, a landing page followed once
to the PDF it declares (`citation_pdf_url`, PDF alternate links, PDF iframes, a prompt meta refresh), refusals told
apart (bot check, sign-in, no PDF). No bot evasion: the app's ordinary request. Links come from
`v1_import_pdf_sources` (owner only: the paper's PDF locations, landing page, DOI link; at most five). The fetched
PDF goes through the upload queue to the same import. When this device is refused too, the Library says so and
offers **Open in Safari** (download it there, then share it to Gradstep) and **Upload PDF**.

Row actions: inline **Download on this device** for `source_blocked`/`pdf_restricted`, **Upload PDF** for `not_open`
and `upload_failed`; the long-press menu offers both wherever they apply, beside Retry.

## 4. Share extension

`ShareExtension/` (`com.sciencereader.ios.share`, iOS only). It saves the shared item into the app group's inbox
(`group.com.sciencereader.ios`, `ShareInbox/<id>/{item.json,paper.pdf}`, written to a staging folder and renamed):
a PDF copied whole (`%PDF-`, ≤ 64 MiB) or an http(s) link. It never touches the network or credentials. The app reads
the inbox when the upload queue starts and on every foreground: PDFs go to the upload queue (banner in the Library),
one link at a time opens Add and is looked up there. At most 20 items wait; items older than 14 days and half-written
ones are cleared. Items are added for whoever is signed in when the app opens.

**Why not the extension calling the backend:** a token shared through a keychain group would let two processes refresh
the same rotating refresh token (one would sign the other out), and an extension's ~120 MB memory and short lifetime
are a poor place for a 64 MB upload with retries. The inbox keeps credentials in the app and reuses every check above.

## The app's upload queue

`Services/PDFUploadQueue.swift`: per deployment and account (`Application Support/PDFUploads/<deployment>/<account>/`),
a job (JSON) beside a copy of the PDF. Checks before sending match the server's (`PDFFileCheck`). States: waiting,
uploading (progress), finishing, failed (the reader acts: storage full, credits, target gone, …). Transient errors
back off 5 s, 30 s, 2 min, 10 min, 30 min and resume on foreground; an expired session restarts under a new upload ID;
a finalize keeps the library cursor it first sent. Sign-out stops the queue; a different account never sends another
account's files. Library: banners above the rows (progress, waiting reason, stopped with Try again / Remove / Get
credits, and "Added …").

## Tests

- Database `tests/database/test_pdf_uploads.sql`: owner-only access, validation, size, credits, quota, limits,
  idempotent begin and finalize (also after the object is gone), stored size, v2/v3/v5 visibility, compact v4 metadata and queries, worker
  verification and provenance, conversion metered and resolved, the read-level rule (arXiv bytes never adopt an
  upload item), device fallback on a `not_open` import, closed paper by source, supersession, janitor, account deletion.
- Backend `tests/backend/add-paper.test.ts`, `pdf-uploads.test.ts`, `web-source.test.ts` (closed works), account deletion prefixes.
- App: `PaperAddingTests`, `PDFUploadTests`, `DevicePDFFetcherTests`, `ShareInboxTests`, `LibraryTransportTests`
  (v5 with v3 fallback), Core `LibraryReconcilerTests` (upload entries). UI: `AddPaperFlowTests` (`--add-paper-fixture`,
  `--share-inbox-fixture`): DOI, link, upload, closed paper, device fallback, device refused, shared items.

## Not done

- A resumable (TUS) upload; a failed PUT re-sends the whole file (at most 64 MiB). Background `URLSession` uploads.
- Identifying an uploaded PDF (an arXiv ID or DOI on its first page) to add the shared copy instead.
- "Checking the PDF" instead of "Downloading the PDF" while the worker verifies an upload.
- The Share extension on Mac (needs a Mac app group); exercising it through the system share sheet in UI tests.
