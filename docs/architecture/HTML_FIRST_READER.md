# arXiv HTML reader and device-only PDFs

Status: implemented; staging backend and browser deployed 2026-10-13. Native build 30 is VALID and IN_BETA_TESTING for iOS and Mac, including the v2 figure compatibility extension; see IMPLEMENTATION_STATUS.md for evidence.
This document supersedes the PDF/Mathpix acquisition direction in earlier designs. Existing deployment evidence
remains historical evidence for that configuration, not evidence that PDFs now stay on devices.

Testing policy: [fast/slow commands and corpus](../TESTING.md). Real-source downloads and multi-engine/Simulator
checks are opt-in slow evidence, with cached exact bytes and checksums. PDF corpus work runs only on the user's
device. Reviewed unavailable sources remain separate from successful HTML preparations; no resource limit or
source-completeness rule is relaxed just to make the corpus green.

## Product contract

- Every PDF is downloaded, opened, stored and processed on the user's device. This includes CC-licensed arXiv
  papers, publisher PDFs, chosen files, drag/drop, Share intake and retry/recovery paths. No server PDF download,
  upload, proxy, Storage copy or Mathpix submission is part of the new flow.
- Initially, the structured reader uses **only the official HTML version of the exact arXiv paper revision**.
  Adapting existing HTML is a deterministic conversion, with no PDF OCR or paid model required.
- The Library, Feed, Paper, Contents, figures, selection actions, passage return and paper/general-chat arrangement
  stay the same. Change the content supplier beneath those surfaces; do not replace the reader with an arXiv iframe.
- A future on-device model will prepare challenging PDFs. It is a later implementation and quality milestone,
  with no automatic or optional Mathpix fallback under this decision.
- The $100/month incremental budget, device-held account keys, rights review and paused physical-iPhone work remain
  unchanged. The owner clarified that the SSH transfer request is for the codebase, not a PDF; copying the project
  does not authorize using that machine as the application's PDF processor.

The owner specified the source and PDF boundary. The device-side HTML adapter and protocol details below are
engineering choices to realize that boundary while preserving the existing rights and interaction constraints.

## Acquisition and availability

Resolve bibliographic metadata on the existing metadata service and pin `(arxiv_id, revision)` before content work.
Follow the official abstract page's HTML link for that revision, verifying the final version after redirects.
Do not substitute a newer revision, a third-party HTML mirror, TeX source or an OCR service when HTML is absent.
arXiv reports that HTML coverage is incomplete and conversions may have errors, so absence and invalid content are
normal, distinct outcomes. [arXiv HTML documentation](https://info.arxiv.org/about/accessible_HTML.html)

The default content path is direct device retrieval of HTML and its required assets, followed by local conversion
and encrypted installation. Source licenses remain recorded; HTML does not create permission for server hosting
or redistribution. Any future server HTML cache needs the existing exact-version rights approval and a separate
implementation review. [arXiv API terms](https://info.arxiv.org/help/api/tou.html)

PDF acquisition is independent of HTML readiness. The device may retain the exact revision's original alongside
the bundle; a PDF failure must not discard a valid HTML reader, and a valid PDF must not be labelled a prepared
reader. A PDF can be absent without inventing a page count or blocking the HTML reader.

| Source outcome | Existing reader surface | Recovery |
|---|---|---|
| HTML and all required assets validate | Normal structured reader, including offline reopen | Reuse the installed immutable bundle |
| HTML is absent for that revision | Metadata plus “HTML reader unavailable for this version” | Existing source/PDF action downloads or opens only on this device |
| HTML/asset retrieval interrupted or throttled | Preparation state and a retryable explanation | Bounded retry, cancellation, respect Retry-After |
| HTML math, content or an asset cannot be represented safely | Preparation failure; retain the previous verified bundle if present | Open local PDF/source; never publish a silently incomplete reader |
| PDF file or non-arXiv source added | Local PDF viewing and normal metadata membership | Structured preparation awaits the future local PDF engine |

Native URLSession and browser fetch are separate feasibility gates. Ordinary browser JavaScript cannot assume
that arXiv permits cross-origin response reads. Verify CORS on HTML and every asset type before promising direct
web preparation. Where unavailable, keep the source/PDF action and use a separately verified approved-device import
when available; do not deploy a general content proxy or claim that opening a new tab imports the file. Manual local
file intake remains local and does not justify sending PDFs to the existing upload endpoint. A broader browser
intake interaction, such as a required extension, needs a concrete owner proposal.

## HTML-to-bundle adapter

### Figure compatibility extension (2026-10-13, implemented; browser deployed)

The reported `2610.10478v1` groups multiple numbered image/caption pairs in a single LaTeXML figure. Split
those pairs into ordered reader figures. `2610.12978v1` embeds SVG legend symbols and their text inside figure
containers. Preserve those symbols by the same bounded, network-disabled SVG rasterizer used for external SVG.
Do not drop legend text or draw guessed substitutes.

Use renderer `gradstep-arxiv-html-mathml-v2` and provenance `arxiv-html-reader-provenance-v2` for this extension;
keep v1 admission for installed bundles. V2 additionally records `inline_image_inputs`, keyed by unique source SVG
IDs, with the hash of the parser's canonical SVG serialization and the admitted PNG identity/dimensions. These
bytes derive from the already hashed HTML and never become fetch URLs. External `image_inputs` keep their exact
revision URL constraints. All referenced PNGs must belong to a declared figure and be accounted for by provenance.
Only the v2 HTML validator admits bounded inline raster images and legend paragraphs inside a figure; no inline
SVG, source CSS, scripts or new remote resources enter the reader. Every client must recognize v2 independently.

Retain `reader-bundle-v1` and `reader-index-v1`. Introduce a real source/profile pair:
`source.kind = arxiv-html`, `renderer.id = gradstep-arxiv-html-mathml-v1`, and
`arxiv-html-reader-provenance-v1`. Never label HTML as `mathpix-mmd` or manufacture an OCR job/PDF digest to pass
today's validators. The Node/backend, native Core, native WebView and browser verifiers must all recognize the
profile independently before a client accepts it. A source-profile addition must not weaken existing profiles.

The adapter accepts bounded UTF-8 source bytes, a verified versioned source URL and an explicitly supplied asset
map. Parsing and rendering perform no network operations. A separate acquisition layer owns redirects, host rules,
timeouts, byte limits, rate limits and cancellation. It validates every final URL, rejects credentials/non-HTTPS
URLs, and admits only official arXiv content origins verified for this source. An asset fetched from another paper
or arbitrary URL is not trusted merely because the HTML referenced it.

1. Parse without executing source scripts or loading resources. Select the paper's article content, excluding
   navigation, feedback widgets and site chrome. Validate identity against the pinned source revision.
2. Convert the article tree to a source-neutral intermediate structure. Preserve paragraph/list order, headings,
   abstract/authors, bibliography, footnotes, equation numbers, figures/captions, tables, algorithms and internal
   references. Unsupported substantive content is an explicit conversion error, not dropped text.
3. Preserve sanitized MathML for display and original TeX from source annotations/attributes for equation Copy and
   selection. Normalize only known delimiter forms, recording `source_form` correctly; do not reconstruct TeX
   from visual text. Missing or inconsistent math representation fails the relevant readiness gate. Remove active
   attributes, foreign namespaces, external resources and unsafe annotation markup.
4. Map source IDs deterministically to safe bundle block/equation IDs. Rewrite section, equation, citation and
   footnote fragments through the same mapping; preserve an explicit reference destination when it exists instead
   of relying solely on citation heuristics. Duplicate IDs, unresolved required destinations and nested reader
   blocks fail validation. IDs bind the source digest and adapter revision so changed content never inherits old
   anchors accidentally.
5. Admit images using the existing bounded image checker, rewrite to content-addressed member paths and emit
   dimensions, caption, alt text and figure ownership. Account for all figures and table cells. Source SVG, WebP
   or other unsupported assets need a separately bounded device rasterizer before admission; they cannot be
   passed through, fetched at reading time or silently omitted. V1 may reject these inputs until supported.
6. Emit generator-owned HTML/CSS, the existing index, provenance, notices and image members. Include no remote
   styles, scripts, fonts, frames or runtime resource fetches. Use the existing restrictive CSP and reader bridge.
7. Independently validate DOM/index correspondence, math/figure ownership, fragments, member hashes, paths, limits
   and provenance, then atomically install into the account's encrypted store. A digest received alongside an
   untrusted package is not an authentication proof. Direct builds trust their local validated acquisition;
   transferred builds additionally require the approved-device package authentication.

Provenance binds the canonical source URL, arXiv ID and exact revision, raw HTML byte count/SHA-256, each source
asset's URL/input digest and published member digest, adapter revision/build digest. Observed license evidence remains in the metadata catalog, bound to the same source ID and exact revision; the device bundle makes no separate licensing or redistribution claim.
It contains no provider job, PDF hash or claimed page count. Notices retain applicable adapter dependencies and
source attribution. Keep fetched-at time in the local acquisition record, outside deterministic output identity.

Initial limits reuse the MathML profile: 2 MiB source, 8 MiB output HTML, 4 MiB index, 256 KiB manifest and provenance,
32 MiB bundle, 512 members, 20,000 blocks, 1,000 headings, 4,000 equations, 256 figures and 64 million total image
pixels. Acquisition also bounds cumulative input asset bytes and decoded pixels; final bundle limits alone are
insufficient. Real-paper measurements can motivate a versioned limit change, not an unbounded fallback.

## Identity, persistence and synchronization

Library membership must name a logical paper/version without requiring a server `document_id`,
`original_object_id`, PDF approval or OCR run. The existing model and `canRead`/native presentation checks require
some of these today. Design an additive, capability-versioned membership/read contract before a schema change;
do not fill required columns with fake objects, bypass integrity checks or reinterpret an old protocol field.

Use independent records for:

| Record | Identity and content |
|---|---|
| Synced membership | Account, stable membership ID, source kind/ID, exact revision, metadata, tags and removal state |
| Local original | Account, source/version or local-file identity, PDF digest, encrypted blob, local availability |
| Local prepared reader | Account, membership/source version, HTML digest, renderer revision, manifest digest and encrypted members |
| Encrypted conversation/anchor | Existing encrypted event plus a versioned logical-paper binding and exact bundle/block identity |

A chosen PDF without an arXiv match gets an account-scoped random identity and an encrypted filename/title
descriptor; a guessed DOI or title is not byte identity. No PDF digest needs to be sent as a substitute cloud asset.
The existing `DevicePaperStore` is the starting point, but its arXiv-only PDF record is not yet the general
local-document/bundle store. Preserve account retirement fences, quotas, atomic publication, crash recovery,
corruption detection, key recovery semantics and explicit local removal. Exclude local originals and bundles from
automatic OS/cloud backup so device-only paper storage is not undone by platform backup defaults.

Other approved devices synchronize membership and encrypted user state, then independently acquire the same exact
source version or use approved-device transfer after that mechanism is implemented. Local availability belongs to
the device and is never synchronized as “ready everywhere.” Browser eviction, lost devices and cleared storage can
remove the only local PDF; a recovery code recovers keys, not absent files. Reading activity remains device-local
under its current contract; this design does not silently add reading-position sync.

Do not remap notes, selection anchors or chats to another rendering using ordinal position or title matching.
Keep their original bundle identity, retain the old local bundle while referenced when feasible, and offer a clear
source-version mismatch if the exact content cannot be reopened. New binding formats require explicit old-client
compatibility handling. No bulk migration/reprocessing of old papers or encrypted history is requested.

## Paper chat and other derived work

General chat, model/effort/length controls, encrypted history, consent, streaming, Stop and selection actions remain
as they are. New paper chat must not require `worker_chat_context` to read server `standalone.mmd`.

Define a versioned local-context request: logical membership/source revision, exact bundle digest, bounded plain
text/TeX snapshot derived from the verified reader index, selected block IDs/text and normal conversation inputs.
Do not include PDF bytes, source HTML, figure images or an arbitrary fetch URL. Preserve the current 2 MiB paper
context ceiling and token/output budgets; never silently truncate a full-paper question.

The server authenticates the account and membership, treats the supplied context as untrusted user content,
validates its shape and size, freezes its digest with the operation, and reserves/settles credits from server-side
token/cost bounds. A client digest proves neither publication authenticity nor entitlement and must not authorize
shared-cache publication. Replaying the same operation with different context conflicts. No raw local context in
logs, queues, support diagnostics, Storage or durable job records; use request memory for synchronous chat and
retain only bounded operational identifiers/digests. A timeout follows existing uncertain-spend accounting.

The existing cloud-AI consent still applies: asking a paper question sends the necessary paper text and passage to
the service and model provider in plaintext for that computation. PDF-local processing does not mean cloud chat
is on-device, and does not promise provider zero retention. Future PDF-engine text needs this same explicit
request boundary; there is no background upload of extracted content.

Podcasts keep their existing rights, quotation and spending controls. Existing permitted catalog playback is
separate from acquisition. New HTML-based generation must bind script evidence to the HTML bundle. The durable
podcast job design cannot silently persist device-only text; a local-source podcast route needs its own reviewed
context/retention contract before activation and cannot fall back to uploading a PDF.

## Cutover and verification sequence

### Implementation contract (2026-10-13, work in progress)

- Source-only import records are the genuine metadata membership for locally prepared papers. Their stable import
  UUID is explicitly a **membership** identity, never a `documents.id`. Add a `source-membership-v1` capability
  and typed source reference; leave existing document-backed records and their historical bundles intact.
  Source membership archive/tag changes use their own replayable, revision-checked commands. No fake PDF,
  catalog approval, page count, OCR run or artifact is inserted to make a local reader appear ready.
- New encrypted paper events carry `paperReference` (format, membership ID, source kind/ID and exact revision).
  They omit the legacy `documentID` field. Local passage anchors carry the exact manifest digest and omit the
  legacy artifact UUID. An explicit encrypted-envelope version and compatible pull API prevent old clients from
  misreading these events as general chat; an old pull that encounters this format returns an upgrade error.
  Existing events retain their original identities and encoding; there is no history migration.
- Native HTML bundles use a separate `device-readers` encrypted directory, manifest and AES-GCM AAD domain beside
  the existing PDF store. Publication is atomic and account retirement drains accepted writes. Bundle/source
  identity and member integrity are verified on every reopen; compilation independently validates inert HTML
  against the reader index and native admission fully decodes each image. Both directories are excluded from
  OS backup. The device compiler runs in an ephemeral WebKit context with no network access.
- Direct HTML/asset acquisition uses only exact `https://arxiv.org/html/<id>v<revision>` identities and the
  corresponding asset path. Cross-version/host redirects are refused. Pacing (revised 2026-10-13, late): a paper's
  HTML document request is spaced three seconds from the previous document request on that client, like a new
  page visit; the declared assets of that one paper then load with at most four in flight and no artificial
  spacing, the way a browser loads one page's images. A `Retry-After` pauses every request on the client, and a
  pause longer than a minute is reported as "busy" immediately. Source and cumulative asset bytes are bounded
  (2 MiB source, 16 MiB per asset, 32 MiB in total), and failures leave any previously installed copy intact.
  Source SVGs are admitted as bounded, external-resource-free vectors and rasterized on the device; source SVG
  is never installed in a reader bundle. PDF acquisition remains independent.

These contracts are implemented in migration 058 and native/browser clients. Deployment and measured checks are recorded below; the following sequence also remains the regression checklist.

1. **Adapter proof:** authored hostile-input fixtures and a representative, rights-cleared arXiv HTML corpus,
   pinned to exact revisions. Measure equation/TeX equivalence, figures/tables, bibliography, fragment links and
   deterministic output. Include missing HTML, unsupported assets, malformed MathML and changed same-version bytes.
2. **Native path:** new profile admission, metadata-only paper identity, local acquisition/install and encrypted
   offline reopen. Route choose/drop/Share/download/retry into the local store. Verify iPhone/iPad Simulators and
   Mac Catalyst, cancellation, termination, disk full, account switching and deletion. Physical iPhone remains
   paused until the owner resumes it.
3. **Chat parity:** implement the versioned local context/binding protocol and prove paper/general chat, Copy,
   Explain, Quote, Ingest, passage return, encrypted sync, two-account isolation, replay and server spending limits.
4. **Server enforcement:** reject new PDF upload sessions/chunks/freeze/attach and server PDF acquisition/OCR
   admission, including requests from old clients. Fence already leased workers so stale jobs cannot start a PDF
   download, parse, re-render or paid submission. Stop accepting additional PDF bytes before reading request bodies.
   Existing provider attempts still need metadata/status-only reconciliation; do not collect/process their PDF
   outputs or release uncertain holds without evidence. Do not repurpose rights_mode as a processing-location flag.
5. **Browser path:** independently prove CORS/intake, encrypted browser quota/eviction handling, new profile
   validation and offline reading with local context chat. Reuse the same golden bundle/index corpus across clients.
6. **Coordinated rollout:** additive contracts and compatible clients first, explicit switch/fencing plan,
   then enabled HTML acquisition. Verify network/storage/provider traces show zero new server PDF bytes or Mathpix
   submissions across all intake and retry paths. Old clients receive a bounded upgrade/local-only response, not an
   infinite retry. Rollback may pause imports; it must never restore a prohibited PDF/Mathpix path.

Inventory retained server originals and PDF-derived artifacts separately. No automatic data migration, broad
deletion or rerender follows from this design change. Stop new PDF processing at cutover; removal of existing
copies requires an explicit retention/cleanup operation with backup and spending consequences recorded. Do not
advertise “no PDFs on our servers” while historical copies remain.

## Costs and future local model

New HTML adaptation and local PDF work incur no Mathpix/OCR credit charge. Cloud chat/search/podcast charges remain
metered as before. Fixed commitments, actual usage, outstanding reservations and forecast remain separate; past
Mathpix spend and unresolved attempts remain in the ledger. Any projected savings start after verified cutover and
do not increase the $100/month cap or change subscription allowances. No hosting/model-download commitment is made.

The future PDF engine is a local producer of the same reader/index contract with its own honest PDF/model
provenance. Evaluate text/layout extraction, on-device OCR and a scientific-document model against a held-out
corpus, commercial model/weight rights, memory, battery, thermal behavior, cancellation and recovery. Ship only
after equations, reading order, tables and figures pass. Until then, difficult PDFs remain viewable originals;
Mathpix is retained only as historical comparison evidence, not an executable fallback.

## Implementation boundary at adoption

Present code has the strict MathML renderer/verifiers, encrypted bundle stores, a native arXiv source-only PDF
store/viewer and the existing reader bridge. It does **not** have this HTML adapter/profile, general local-PDF
intake, paper membership independent of server PDFs, local-context chat, complete browser intake or the universal
server PDF stop. No schema, worker, provider switch or deployed client changed when this design was recorded.

### Local verification update (2026-10-13, before deployment)

The native adapter, exact-revision transport, independent bundle admission,
encrypted device reader/PDF stores, explicit source membership and format-2
private events are implemented locally. All 286 Core tests pass, including the
shared HTML fixture, encrypted reopen and new envelope checks. The compiler also
passes its WebKit integration test on an iPhone Simulator. The database suite
checks legacy accounting before cutover and the new metadata-only contract after
058; both pass. This is local evidence, not deployment evidence.

Chosen local PDFs use encrypted `local_paper` events containing a bounded title,
page count, creation time, archive state and tags. File bytes and digests never
enter cloud sync. Other devices can see the membership and request a local file.
A PDF chosen for an existing source membership is associated locally with that
membership. It cannot provide structured context until local parsing is available.

Browser reading initially retains its existing session-memory bundle policy.
This cutover does not claim the separately gated browser offline-cache work is
complete. The source metadata service retains observed arXiv license evidence;
HTML preparation does not infer a distribution license or authorize a shared cache.


## Staging cutover evidence — 2026-10-13 PDT

- Migration `202610130058` applied and ledger hash verified. It blocks PDF upload/read/admission, original writes,
  OCR funding/submission, legacy processing-job claims and reader asset publication. Historical accounting and
  stored originals remain; no bulk migration, rerender or deletion occurred.
- Cloud Run `gradstep-pipeline-00033-2jw`, 100% traffic, metadata-only code, no Mathpix environment secrets.
  Admission was paused after observing zero pipeline claims, unresolved provider attempts/liability and asset writes,
  then resumed after the migration and worker cutover. Edge `upload-pdf`, `chat` and `paper-worker` deployed.
- The scheduled workflow job no longer contains the PDF-download corpus. Its image-only refresh preserved IAM,
  schedule configuration and secrets; schedules were paused for the replacement and restored. New zero-credit
  checks prove HTTP 410 upload refusal, exact DPO v3 metadata with no document/artifact identity, source archive/tags,
  and idempotent command replay. The first live probe exposed the `/oai` allowlist mismatch; the fix and regression
  test passed before the final live check. Reports retain both observations.
- Browser Pages `50ecbc01` (help-copy follow-up to `a95696d2`): direct official HTML/assets, isolated deterministic compiler, existing verified reader
  and local-context paper chat. Browser PDF bytes remain in the selected device file/tab; encrypted membership
  persists, and reopening the tab asks the user to choose the file again. Browser bundles retain the existing
  bounded RAM cache; this release does not claim durable browser offline bundles.
- Local evidence: backend 497 tests; Core 286 tests; app 410 tests
  (5 optional skips); targeted iPad reader/PDF/library tests; browser 343 unit tests and four desktop/phone
  production-CSP journeys for HTML/math/figures/chat and local PDF membership/reload. Real DPO, Mamba and
  MatMul-free HTML corpus conversion independently validated. No physical iPhone was queried or tested.
- No future local PDF model is installed. Missing or unsupported official HTML remains an explicit unavailable
  reader outcome with device-local PDF access. Existing historical document-backed readers keep their identities.

Evidence lives under `.artifacts/html-*` (not source-controlled and not transferred to SSH). The hosted real-source
browser check and final Apple processing states are summarized in `docs/IMPLEMENTATION_STATUS.md`.

The screenshot identified `2610.10478v1`; its grouped captions and SVG glyph metadata reproduced the reported
failure. The sidebar's `2610.12978v1` additionally requires inline SVG legends and MathML background colors.
The v2 extension above is deployed in browser `16b9e4ce`, with all five real corpus papers passing Chromium,
Firefox and WebKit. Specific finite error messages from `e9d6522a` remain; raw exceptions/source content are
never sent as diagnostics. See the current implementation-status entry for hosted and native release evidence.

### Maintenance after cutover — 2026-10-13, late (local, not deployed)

- **Acquisition pacing.** The first cutover spaced *every* request three seconds apart, so a paper with sixty
  figures took about three minutes to open in the browser on each reload and once per device natively. Both
  clients now pace only document requests and load one paper's assets with bounded concurrency (above).
- **One preparation per paper.** In the browser the reader and a paper question asked before the reader was
  ready each started their own acquisition and compilation; `prepareArxivReader` now shares one in-flight
  preparation per exact source revision, forwards progress to every waiter and stops only when all have left.
- **Go to passage across compiles.** Both clients refused a saved passage whose anchor named a different bundle
  digest, and the browser did so silently. The digest changes with every renderer/CSS revision (v1 → v2 happened
  the same day) and a browser recompiles on every reload, so saved chats stopped navigating. The digest now only
  decides whether the block hint applies; the existing quote cascade finds the passage, and "Couldn't find the
  passage" appears only when the quote is genuinely absent.
- **Code removal.** The server-side PDF pipeline (`pipeline.ts`), Mathpix HTTP client, upload-session module,
  asset uploader, web PDF downloader and their tests are deleted; the metadata pipeline owns its own types, and
  the historical OCR identity remains only so retained `mathpix-mmd` bundles stay verifiable. The browser's
  chunked upload transport and the native `PaperAddingService` upload methods, `BackendClient` upload calls and
  queue back-off are deleted. A native queue record written by a pre-cutover build is now offered **Save on this
  device** (installs the queued file locally, then clears the record) instead of a retry that could never succeed.
- Evidence: fast suite 443 backend + 356 browser unit tests and compiler freshness pass; Swift Core 287 tests
  pass. Slow reader journeys and the iPad Simulator checks for the touched areas are recorded in
  `IMPLEMENTATION_STATUS.md`. Nothing was deployed; native build 30 and browser Pages `a3127547` remain live.

### Compiler tolerance and legacy items — 2026-10-14 (owner report: "quite a few 'couldn't open this paper'")

The owner's nine papers added on 2026-10-13/14 were replayed offline (`READER_CORPUS_SET=owner-20261014`): five of
nine refused to compile, for three structural reasons, none of which should cost a reader the paper. The adapter
now reads them all, and says in the paper what it left out:

- **LaTeXML conversion markers** (`ltx_ERROR`, an undefined preamble macro such as `\pdfauthor`; one paper carried
  288) no longer refuse the paper: the markers are dropped and counted; over 1,000 still refuses (`arxiv_conversion_error`).
- **Graphics in running text** (an affiliation logo in the author line, a TikZ mark in a sentence) were refused as
  `arxiv_nested_content`. Outside a figure the reader has no inline-image vocabulary, so they are left out and
  counted; a paragraph whose only content is one graphic (an unwrapped `\includegraphics`) is a figure.
- **TikZ pictures** (`svg.ltx_picture`) draw their labels as `foreignObject` HTML, which the device SVG admission
  refuses. A lone picture whose labels hold text (a framed "Finding" box) reads as paragraphs with the frame left
  out and counted; a picture inside a figure keeps its labels as centred SVG `<text>` (best-effort placement). Math
  inside a picture counts as carried by it, not as a missing equation.
- When anything was left out the paper ends with one paragraph: "Note: arXiv's HTML conversion of this version
  left out N unsupported commands and M inline graphics. The PDF is complete."
- **Asset planning is the compile.** `arxivHTMLAssets` and `arxivInlineImages` now come from a dry compile, so what
  is fetched, what is published and what provenance lists are the same set by construction (a left-out graphic is
  never downloaded), and a structural refusal surfaces before any image is fetched.

**Legacy arXiv items** (library items from before the cutover, with a server-processed bundle and no source
membership) open through the same on-device HTML reader by their exact revision; an installed server copy still
opens offline, and the server bundle is the fallback when arXiv has no usable HTML for that revision. Chat for
such an item keeps its server document (no numbered local context). The library says "Opens from arXiv" for an
arXiv paper not yet prepared on this device, and the reader never dead-ends on "download needed" without a reason
and an action. Both clients (`ReaderModel.openLocalPaperIfNeeded`, `Reader.tsx` with `readingSource`).

### Authors block — 2026-10-14 (owner request: "the authors list presented nicely on all surfaces")

LaTeXML's `div.ltx_authors` prints every affiliation mark twice (`ltx_note_mark` in the text and again inside the
note's content with a "footnotemark:" label and its tag), inlines "thanks:" notes and lists e-mail contacts; emitted
as one paragraph it read "Rafael Rafailov 22footnotemark: 2 ††thanks: Equal contribution…". The compiler's
`authorsBlock` now writes the one `p.reader-authors` block (same vocabulary, same block count, same index text
position) as: each `ltx_creator`'s `ltx_personname` once with its marks as one superscript ("Rafailov<sup>2,†</sup>";
a note beside the name, such as an equal-contribution dagger, marks the name); then, after a `<br>`, the affiliations
("<sup>2</sup>Stanford University · <sup>3</sup>CZ Biohub"): a creator that starts with a mark, the lines after a
`<br>` in a name, and `ltx_author_notes` contacts other than e-mail, de-duplicated; then each note with content
("<sup>†</sup> Equal contribution…") on its own line. `ltx_role_email` contacts and `mailto:` links are left out.
Math inside is converted as everywhere (the coverage check holds); every source id inside the block is bound to it,
so `href="#id1"` to a note resolves. Without any `ltx_creator` the block is emitted as before. Test: `tests/backend/
arxiv-html.test.ts` ("the authors block reads as names with single marks…"). Rows and cards on the surfaces use the
shared author rules (`apps/web/src/lib/authors.ts`, native `LibraryFormat.shortAuthors` / `authorLine` /
`firstAuthor`): compact "Family, Family, Family +N", full names up to six, "Family et al." bylines.

Later the same night (four more owner screenshots): `ltx_contact_name` labels ("Affiliation:") and `ltx_role_email`
contacts are dropped, e-mail addresses inside affiliation text are removed, a project page (`a[href^=http]` in the
block) goes on its own line, and when no name carries a numeric mark but authors have their own affiliations, the
distinct affiliations are numbered in order of first appearance and each author gets the numbers of theirs
("Chenghao Yue<sup>1</sup>, Hao Wang<sup>2</sup> … <sup>1</sup>Tsinghua University · <sup>2</sup>Dalian
University of Technology"). A name that was a graphic (a team logo followed by " Team") or no name at all is replaced
by the **library's author metadata**, which both apps now pass to the device compiler (`prepare(…, inputs,
{authors})`; native `ArxivHTMLReader.prepare(_:authors:)`, web `prepareArxivReader(…, {authors})`): the names are part
of the bundle, so every device of one library compiles the same bundle, and a library whose metadata differs compiles
a different one (its own manifest digest). Empty emphasis wrappers left by a dropped logo are removed. Checked on
2305.18290, 2610.16334, 2610.14704, 2610.16352 and 2610.17288 (`.artifacts/back-repro/authors-check.mjs`, local).

### Paper availability on a device — 2026-10-15 (owner question: "should we make it more obvious whether you do or do not have a pdf on a device?")

One model, said once. A library paper is in one of four states **on this device**, and every feature that needs the
paper's text reads from the same place:

| State | Means | Reading | Chat, Study, Listen |
|---|---|---|---|
| **On this device** (`PaperDeviceCopy.reader`) | Its official arXiv HTML was prepared here (the verified bundle is installed) | Offline | Have its numbered text |
| **PDF on this device** (`.pdf`) | A PDF file kept here (device-only PDFs; no server processing) | As a PDF, with the PDF's own outline as Contents | Nothing structured yet (the local model is future work); Listen says so |
| **Not on this device yet** (`.cloud`) | In the synced library (a membership, or an older server-processed item) but not prepared here | Opens from arXiv (or the server's copy) when online, then becomes *On this device* | Need the paper opened here first; Listen says "Open this paper first so its text is ready on this device" |
| **No readable copy** (`.unavailable`) | Not converted, quarantined, or source unavailable | — | — |

The Library rows show the state as a small symbol before the byline (native `PaperTableTitleCell`: ✓ on this
device, a document for a PDF, a cloud for not yet here, ⚠ for no readable copy; VoiceOver and the Mac tooltip read the
words). The browser keeps nothing between visits yet, so its rows say "Opens from arXiv; prepared in this browser when
opened" or "Reads from the server's converted copy". Sync carries memberships, not files: two devices of one library
can and do hold different papers, and the row is where that shows. What each feature says when the text isn't here
is in `PodcastCenter.noEpisodeSource(for:)` and the chat's paper-context copy; nothing silently pretends the paper is
present.

### Budget at cutover

The incremental ceiling remains $100/month and the metered provider cap remains $25. The live October ledger
before cutover showed $20.744201 spent, $0 reserved and $0 unresolved provider liability. The zero-credit cutover
checks spent $0. This deployment adds no recurring service or subscription; Cloud Run, registry and hosting retain
existing service limits. All eight fixed/overhead components currently lack October observations in the spending
ledger (Tavily, domains, Supabase, Cloud Run, storage/egress, builds/registry, backups and web hosting). Their amounts
are unknown, not zero, and the total-month forecast remains incomplete. No budget was increased.
