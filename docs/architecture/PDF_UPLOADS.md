# Adding any paper: identifiers, PDF uploads, device downloads, sharing

> **Status 2026-10-07:** built on branch, not deployed. Migration `202610070033_pdf_uploads.sql` (not applied),
> Edge functions `add-paper` and `upload-pdf` (not deployed), bucket `paper-uploads` (not created), pipeline
> worker changes (not deployed), app changes and the Share extension (Simulator only; needs provisioning).
> Decisions: [DECISIONS](../DECISIONS.md#adding-any-paper-identifiers-uploads-device-downloads-sharing-owner-asked-2026-10-07).

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

## 2. Upload sessions (migration 033, `upload-pdf`)

The upload session designed in [DATA_MODEL](DATA_MODEL.md#import-identity-and-membership), built:

1. **Begin** (`worker_begin_pdf_upload`, service role via the function for the authenticated account): upload ID
   (the client's operation ID), declared SHA-256 and size, target. Checks: ≤ 64 MiB (`pipeline_policy.max_pdf_bytes`);
   the owner's **private storage quota** (1 GiB: their private originals plus every upload object not yet deleted);
   at most 10 unfinished uploads per account and 200 per environment; 4 GiB of upload objects per environment;
   **credits ≥ 1** (conversion is metered later, exactly like other private conversions); rate route `pdf-upload`
   (40/h). Creates a pending `stored_objects` row in bucket `paper-uploads` at `<account>/<upload>.pdf` and the
   `pdf_uploads` row (expires in 24 h). Idempotent: the same ID and request returns the session; a different
   request is `upload_id_conflict`. The function returns a **signed upload token** (Storage `createSignedUploadUrl`,
   upsert) while the session is pending.
2. **Send**: the app PUTs the file straight to Storage (`/storage/v1/object/upload/sign/paper-uploads/<path>`);
   bytes never pass through a function. A failed PUT is retried by beginning again (a fresh token, same session).
3. **Finalize** (`worker_finalize_pdf_upload`): the function first reads the object's size from Storage; the
   database requires it to equal the declared size (`upload_incomplete` otherwise), then in one transaction creates
   or retries the import and marks the upload finalized. A repeated finalize returns the first answer (also after
   the object is gone). A newer upload for the same paper abandons an unused older one.
4. **Verify** (pipeline worker, download stage): the paper's supplied upload (`pipeline_entry.upload`) is read from
   the uploads bucket and must match the declared size and SHA-256, start `%PDF-`, parse, and have 1–250 pages;
   then it becomes the owner-private original (`worker_pipeline_upload_original` → 014's `worker_pipeline_original`)
   and the upload object is deleted. Bytes that fail spend the upload (`worker_pipeline_upload_rejected`) and the
   paper fails resumably (`upload_failed`, `pdf_invalid`, `too_large`); a Storage outage is retried.
5. **Sweep** (`worker_claim_stale_pdf_uploads` / `worker_confirm_pdf_uploads_deleted`, every worker run): spent or
   abandoned uploads, sessions expired unfinished (after a 10-minute grace), finalized uploads no import wants (cancelled, ready
   through another copy) or unused for 7 days.

**Targets.** `paper`: a paper of its own, source `upload:<upload id>`, created at download for the owner (no metadata
or private-split stage). `import`: a failed (or running) web or upload import of the same account — device fallback
and "Upload PDF" on a row; finalize retries it through the reader's own retry command. `source`: a closed web paper
named by Add (`openalex:W…`); finalize creates its web import. A supplied PDF is keyed by **(account, source)**: the
account's private paper for that source uses the newest finalized upload when it reaches download. Web papers are
always private, so a reader's bytes are never shared or reused by another account.

**Uploaded papers in the library.** A new source kind `upload` appears only in **v5** reads (`v5_library_page`,
`v5_library_changes`: v3's full entries, every source; the app reads v5 and falls back to v3 on a server without it)
and in the compact **v4** reads of migration 031 (every source already; `v4_library_metadata` returns `source: upload`
and the owner's title, and 032's query projection and `source: upload` filter use it too). v3 (installed builds) and v2
never return upload entries, and an import never resolves onto an item its read version can't see (`source_level`:
arXiv 2, web 3, upload 4; generalizes 019's rule). Entries carry
`source: "upload"`, `source_url: null`, revision 1. The **title is personal**: it lives on the upload row (from the
PDF's own title, else the file name; the reader's typed title when known) and replaces the catalog's neutral
"Uploaded PDF" placeholder in the owner's entries and the reader attribution ("… uploaded by its reader. Converted for
the personal use of one Gradstep account; not redistributed."). Upload rows are deleted with the account; their
objects are owner-scoped, so account deletion already returns them for removal (and the `paper-uploads/<account>/`
folder), and the v4 query projection of their titles goes back to the placeholder. Uploaded papers are not sent for
catalog tagging. Approval policy `owner-upload-v1`.

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
