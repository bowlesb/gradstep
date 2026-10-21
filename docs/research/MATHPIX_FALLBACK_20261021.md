# Mathpix as the PDF route: research, 2026-10-21

Status: research only. No decision is recorded, no code changed, no account touched, no paid call made. Sources
were read on 2026-10-21. Mathpix and Apple pages were read through a summarizing fetch tool; check any quote
before it goes into a contract or customer copy. Items marked **[UNVERIFIED]** come from my own reading, from
secondary sources, or could not be found on an official page. **This is not legal advice.** Counsel needs to
review the rights framing and the draft clauses.

## The owner's question

> "Can we research using Mathpix as a fallback? We would not store the PDFs on the server. What about launching
> with it, having users agree to our terms of service that users are required to check the status of photos they
> willingly choose to send to Mathpix, with us simply enabling their request?"

The owner added later the same day: "I think the local model for entire PDFs is too ambitious." This report
therefore treats Mathpix as the **primary** route for any PDF without a usable arXiv HTML version. That covers
non-arXiv papers, arXiv papers with no HTML, and HTML that cannot be represented. It is not a fallback behind a
local whole-PDF model.

I read "check the status of photos" as: users check the rights status of the documents, or images of their pages,
that they choose to send. The page-image reading turns out to matter (see §3).

## Short answer

1. **Yes, it is feasible and customary,** with two corrections to the premise:
   - **A device cannot send a PDF to Mathpix with a server-minted token.** Mathpix app tokens work only for
     `v3/text`, `v3/latex` and `v3/strokes`. They "cannot access PDF functionality" and cannot make batch or async
     requests. The feature is labelled beta.
   - Two routes remain if our server is never to touch the PDF:
     - **(a)** the device renders each page to an image and sends the pages to `v3/text` with an app token. This
       needs a new adapter and quality is unproven.
     - **(b)** our server streams the PDF through to `v3/pdf` without storing it. This reuses the proven
       `mmd.zip` → `timestep-mathpix-mathml-v1` renderer, but the PDF crosses our server.
2. **The bigger legal problem is Mathpix's own terms, not our users.** Mathpix's public terms take a "perpetual,
   irrevocable, … worldwide license … to reproduce, distribute, … prepare derivative works of … and to grant
   sublicenses" of anything submitted. The account holder warrants it has the right to grant that licence. We
   would be that account holder, and we cannot truthfully give that warranty for default-licence arXiv papers or
   publisher PDFs.
   - A user clause in our ToS does not fix this.
   - **A written Mathpix agreement or DPA that limits its use of submissions to processing is a hard
     precondition for launch.**
3. **A clause making users responsible for their rights is customary and worth having, but it is not a shield.**
   - It allocates risk between us and the user and shows good faith.
   - It does not license anything, does not bind rights holders, and does not stop secondary-liability claims.
   - DMCA safe harbors do not fit a service that hosts nothing. §512(c) covers storage. §512(a) requires
     transmission "without modification", and Mathpix converts the content.
   - The real protections are product design:
     - each conversion is user-initiated, for that user's own reading;
     - nothing is shared;
     - results are kept only on the user's devices;
     - the feature is not marketed as a way around licences;
     - there is a takedown and abuse contact.
4. **Cost is small per paper and scales linearly.** At $0.005/page, a 25-page paper costs about $0.125 and the
   80-page cap costs $0.40.
   - At 10 users it is a few dollars a month.
   - At 1,000 users it is $125 to $2,250 a month, depending on how many of their papers lack HTML.
   - Mathpix has **no hard spending cap** ("Alerts warn, they do not block"). Cost control has to come from our
     server holds plus Mathpix's per-app monthly page/image quota.
   - Under the owner's "no app markup" direction, Apple's 15–30% commission on the dollars users buy is an
     unfunded cost to us. Price Mathpix pages to cover it.
5. **Recommendation:**
   - Yes, plan to launch with Mathpix as the explicit, per-paper, user-confirmed route for papers without usable
     arXiv HTML. Conditions:
     - written Mathpix terms (§8.2);
     - counsel review of the ToS clause, the publisher-PDF stance and the privacy policy;
     - a Gradstep ToS and privacy policy (the app currently links only Apple's standard EULA);
     - updated App Privacy details;
     - server-enforced holds and quotas.
   - Build route **(b)** first only if the owner accepts PDFs in transit through our server. Otherwise build
     **(a)**, gated on a small paid quality comparison (§8.4).
   - Retire the on-device whole-PDF route from shipping builds when Mathpix ships, and keep its useful parts (§4.2).
   - This reverses recorded owner decisions (2026-10-13 device-only processing with "no Mathpix fallback", and
     `DEVICE_LOCAL_PAPERS.md`'s "No credential/token arrangement for Mathpix creates an exception"). The owner
     needs to record it in `docs/DECISIONS.md` before any implementation.

## 1. Where the repository stands today

- **Direction.** Every PDF is downloaded and processed only on the device. The structured reader comes only from
  the official arXiv HTML. "No server PDF download, upload, proxy, Storage copy or Mathpix submission is part of
  the new flow" (`docs/architecture/HTML_FIRST_READER.md` lines 14–22). `DEVICE_LOCAL_PAPERS.md` line 12 rules out
  a token arrangement explicitly.
- **Server paper copies were deleted on 2026-10-16** at the owner's request, "so it's obvious we have zero on our
  system". The `storage.no-papers` workflow check guards this (`DECISIONS.md`). Route (b) keeps *storage* at zero
  but not *transit*, so customer copy must not say PDFs never reach our servers if (b) is chosen.
- **Code that still exists:**
  - `supabase/functions/_shared/mathpix.ts`: the historical OCR profile `science-reader-mmd-v1`, including
    `improve_mathpix:false` and the `page_ranges` cap. There is no provider client; it was deleted in `dc040a9`
    and remains in history at `7233641`.
  - `mathpix-result.ts`: the raw-capture manifest.
  - The renderer `supabase/functions/_shared/reader/` (`renderMathpixReader`, profile
    `timestep-mathpix-mathml-v1`). It takes an `mmd.zip`, has no network or filesystem dependencies, and is
    Edge-compatible. Native and browser clients already admit its bundles.
  - The device-PDF converter already runs in JavaScriptCore on the device, so this renderer could run on the
    device too [UNVERIFIED: not bundled or measured there].
- **History.** 75 Mathpix runs were made and rendered before 2026-10-13. Staging measured about 5 s + 0.8 s/page
  for OCR (`IMPORT_PROGRESS.md`). Holds were sized `page_limit × $0.005` with an 80-page `page_ranges` cap and
  settled on provider-reported pages (`PAPER_PIPELINE.md`). The renderer's real-paper polish (contents depth,
  rejoining text across page breaks, caption kinds) was built against Mathpix output.
- **The on-device PDF route.** It is experimental and has been in TestFlight since build 50 or so
  (`DEVICE_PDF_ROUTE.md`).
  - About 350–365 MB of models in the app.
  - Formulas take about 3 minutes per typical paper on an M1 Max.
  - The stateful formula recogniser does not load on the Neural Engine or in the iOS Simulator.
  - 3 of 8 fixtures meet every conformance gate.
  - It has never been run on an iPhone; physical-phone work is paused.
- **How many papers lack HTML.**
  - The internal 58-paper fresh-paper sweep found 3 papers without HTML and, after the compiler-tolerance work,
    0 refusals (`IMPLEMENTATION_STATUS.md`).
  - arXiv staff report that about 75% of submissions convert to HTML without LaTeXML errors, with a target of 90%
    ([arXiv:2605.16562](https://arxiv.org/abs/2605.16562)). Our compiler tolerates many of those errors.
  - Spot checks show official HTML for older papers too (1512.03385v1, 1706.03762v7) [UNVERIFIED as a general
    rule].
  - Most papers that need Mathpix will therefore be **non-arXiv PDFs**: publisher, proceedings, OpenReview, or the
    user's own files. Their share depends on the user.
- **Budget.** The ceiling is $100/month: $50 fixed, **$30 metered (AI/OCR/search)**, $20 contingency
  (`OPERATIONS_AND_BILLING.md`). On 2026-10-20 the owner directed dollar balances with "No app markup for now"
  (`DOLLAR_BALANCE.md`, design only).
- **Legal pages.** No Gradstep ToS or privacy policy was found in the repository. The credits store links Apple's
  standard EULA (`CreditsStoreView.swift`). The App Store privacy label draft lists email, user ID, other user
  content and customer support (`IMPLEMENTATION_STATUS.md` ~3450).

## 2. Mathpix API facts

All read 2026-10-21. "DMC" means docs.mathpix.com.

| Topic | Finding | Source |
|---|---|---|
| PDF endpoint | `POST /v3/pdf`, by `url` or multipart upload with `options_json`; returns `pdf_id`. Auth `app_id` + `app_key` only. Options include `page_ranges`, `streaming`, `metadata` (`improve_mathpix`), `conversion_formats`, `callback_url` | [post-v3-pdf](https://docs.mathpix.com/reference/post-v3-pdf) |
| Status and results | `GET /v3/pdf/{id}`: `status` is `received` / `loaded` / `split` / `completed` / `error`, plus `num_pages`, `num_pages_completed`, `percent_done`. Only `status` means ready; `percent_done` can reach 100 before outputs exist. Results via `GET /v3/pdf/{id}.mmd`, `.mmd.zip`, `.lines.json`, `.docx`, `.tex.zip`, `.html`, etc.; 404 if not ready, 202 + `Retry-After` while a conversion runs. `/stream` gives per-page server-sent events | same; [supported formats](https://docs.mathpix.com/reference/supported-formats) |
| Formats | `conversion_formats`: docx, html, html.zip, jpg, latex, latex.pdf, md, md.zip, mmd.overlay.pdf, mmd.zip, pdf, png, pptx, tex.zip, xlsx. `mmd` and `lines.json` are always produced. Extra formats do not multiply cost | [supported formats](https://docs.mathpix.com/reference/supported-formats), [billing](https://mathpix.com/docs/convert/billing) |
| Delete | `DELETE /v3/pdf/{id}` removes source, page images, MMD and line data immediately ("CDN may serve cached copies for up to 10 minutes"). Minimal metadata is kept for billing | [data retention](https://docs.mathpix.com/concepts/data-retention) |
| Image endpoint | `POST /v3/text`: `src` (URL or base64) or multipart; `formats` (text, data, html, latex_styled), `include_line_data`, `enable_document_layout` ("full-page document layout recognition for images"; `lines_json` returns one page object). Figures are **not** cropped: line data gives `diagram` / `chart` types with `cnt` pixel contours | [post-v3-text](https://docs.mathpix.com/reference/post-v3-text) |
| Size limits | v3/pdf: 1 GB upload. v3/text: 5 MB JSON body, 2 MB base64 image, 10 MB by URL. **Max PDF pages: not stated [UNVERIFIED]** | [limits](https://docs.mathpix.com/reference/limits-and-quotas) |
| Rate limits | DMC: per app and per IP, "vary by plan". Older page: 200 requests/min for synchronous v3/text; v3/pdf default **20,000 pages/month** quota; 429 when exceeded. v3/pdf per-minute limit [UNVERIFIED] | [limits](https://docs.mathpix.com/reference/limits-and-quotas), [old limits](https://mathpix.com/docs/ocr/limits) |
| Pricing | v3/pdf **$0.005/page** to 1M pages/month, then $0.0035. v3/text **$0.002/image** to 1M, then $0.0015, but "Images containing more than 12 rows of text may be billed at the `v3/pdf` per-page rate". Tiers reset monthly. **$19.99 one-time setup fee**, $29 test credit. Billed monthly in arrears. No hard cap ("Alerts warn, they do not block"); only per-app `page_monthly_limit` / `image_monthly_limit` quotas (429) | [API pricing](https://mathpix.com/pricing/api), [billing](https://mathpix.com/docs/convert/billing) |
| App tokens | `POST /v3/app-tokens` with `app_key`; free. Returns `app_token`, `app_token_expires_at`. `expires` 30–43,200 s, default 300. "App token to be used in headers of v3/text, v3/latex, or v3/strokes requests." "We have designed app tokens for individual image and digital ink requests (strokes) only": they "cannot access PDF functionality", "cannot access historical data", "cannot make batch / async requests". "The app tokens feature is in beta". No per-token page limit, scope, or per-token usage report found [UNVERIFIED]; usage presumably bills to the parent key | [authentication](https://docs.mathpix.com/reference/authentication) |
| Usage records | `GET /v3/pdf-results` (per-PDF `num_pages`, request args). `GET /v3/ocr-usage` (counts by `usage_type` / `request_args_hash` / `app_id`; "reconcile billing"; counts, not dollars). Image requests with `improve_mathpix:false` do **not** appear in `/v3/ocr-results` | [pdf-results](https://docs.mathpix.com/reference/pdf-results), [ocr-usage](https://docs.mathpix.com/reference/ocr-usage), [image-results](https://docs.mathpix.com/reference/image-results) |
| Retention, v3/pdf | Default: source up to 30 days, page images up to 30, MMD and line data up to 90. With `improve_mathpix:false` the source is "deleted immediately after processing completes", but page images (30 d) and text (90 d) remain until `DELETE` | [data retention](https://docs.mathpix.com/concepts/data-retention) |
| Retention, images | With `improve_mathpix:false`: "the image is not saved to disk, the OCR result is not cached, and the request is not queryable". With `true`: image up to 90 d, cache 30 d, and accessible to Mathpix's QA team | [data retention](https://docs.mathpix.com/concepts/data-retention), [privacy](https://docs.mathpix.com/concepts/privacy) |
| Account override | An account-level privacy setting overrides the per-request flag. Ask Mathpix to set it off at account level | [privacy](https://docs.mathpix.com/concepts/privacy) |
| Processor role and location | Privacy policy (updated 2026-08-06): for API customers Mathpix acts "as a service provider (processor)" under "the applicable services agreement and data processing agreement". "Mathpix is a U.S. company and processes data in the United States." Sub-processor list "available upon request". EU residency endpoint `eu.api.mathpix.com` (document content stays in the EU) | [privacy policy](https://mathpix.com/privacy), [EU residency](https://docs.mathpix.com/concepts/eu-data-residency) |
| Security | "SOC 2 Type 2 certification"; AWS US; encryption at rest; annual penetration test. GDPR and HIPAA claims not found on official pages [UNVERIFIED] | [security](https://mathpix.com/security) |
| Training use | No statement that customer content trains models. QA access only when `improve_mathpix` is true. Terms allow use of anonymous "Statistics" to improve the service | [privacy](https://docs.mathpix.com/concepts/privacy), [terms](https://mathpix.com/terms) |
| Terms (last updated 2024-03-01) | **User Content licence:** "a perpetual, irrevocable, non-exclusive, royalty-free and fully-paid-up, worldwide license to reproduce, distribute, publicly display and perform, prepare derivative works of, incorporate into other works and otherwise use and exploit such User Content, and to grant sublicenses", with the submitter warranting the right to grant it. Licence to us is "limited, nonexclusive … (without the right to sublicense)", excluding "any resale of the Services". **"You may not under any circumstance use output to develop models that compete with Mathpix."** Nothing explicit on embedding the API in a consumer app [UNVERIFIED]. Liability capped at $100; Massachusetts law. Repeat infringers terminated | [terms](https://mathpix.com/terms) |
| Private cloud | $25,000/year (25M pages), runs on our infrastructure. Out of budget; noted for completeness | [private cloud](https://mathpix.com/pricing/private-cloud-ocr) |
| Competing product | Mathpix Snip advertises a PDF reader: Free 10 PDF pages/month; Pro $4.99/month for 1,000 pages | [Snip pricing](https://mathpix.com/pricing/snip) |

**Renderer fit:**

- `v3/pdf` `mmd.zip` (MMD plus figure crops) is exactly what `renderMathpixReader` consumes. 75 historical
  bundles prove the path.
- `v3/text` returns per-page MMD and line data with contours, but no crops. The device would need to:
  - join pages (`flow.ts` already rejoins text split at a `\pagebreak`);
  - crop figures from its own page renders using `cnt`;
  - assemble an `mmd.zip`-shaped archive.
- That needs a new, honestly named provenance, e.g. `mathpix-text-pages-v1`. It must never be labelled `v3/pdf`
  output.

## 3. Architecture options

All three options keep three things:

- arXiv HTML stays first.
- Our servers never contact arXiv; the device supplies the bytes.
- The finished reader bundle is stored encrypted on the device like other bundles, and synced only under the
  existing rights rules.

Each Mathpix conversion is **user-initiated with a per-paper confirmation** and is never automatic on HTML
absence.

| | (a) Device → Mathpix `v3/text`, page images, app token | (b) Server pass-through to `v3/pdf`, no storage | (c) No Mathpix (status quo + local model) |
|---|---|---|---|
| What crosses our servers | Request metadata only: token mint, page count, hold, settlement. Never PDF bytes or results | PDF bytes in memory, streamed to Mathpix. Results pass back through (or the device fetches them via our proxy). Store only `pdf_id` and accounting | Nothing |
| What Mathpix keeps | With `improve_mathpix:false` on image endpoints: nothing saved or cached (per docs). Strongest privacy | Source deleted at once with the flag. Page images and text kept 30/90 days **until we `DELETE`**. We must delete after collection, plus a backstop sweep | — |
| Fits "server never sees the PDF" | Yes | **No** (transit only, zero storage). Copy must say so | Yes |
| Reader quality evidence | **None.** Per-page `v3/text` with `enable_document_layout` is untested on papers. Cross-page structure, references, tables and figures need a new adapter | **Proven:** 75 historical runs and the existing renderer | On-device route: experimental, 3/8 fixtures fully conformant, never run on a phone |
| Build effort | High: new page renderer (exists in DevicePDF), per-page client, stitcher, figure cropping, new provenance and profile. Must be done twice (native and browser via pdf.js) | Medium: restore the transport from `7233641`, a streaming endpoint (Cloud Run; Edge body limit about 10 MB [UNVERIFIED]), device-side rendering of the returned `mmd.zip` | None |
| Cost metering | Weak. Tokens are not page-scoped, and per-token usage is not reported. The server holds funds per token for worst-case exposure (expiry × rate), settles to device-reported pages (client data, capped by the hold), and reconciles aggregate `ocr-usage` for a dedicated Mathpix app daily. Drift suspends minting | Exact. Hold for `min(pages, 80) × $0.005` with `page_ranges`, settle on Mathpix `num_pages`. The historical protocol already covers single-submission grants, uncertainty and settlement |
| Server-side limits (no client-only limits) | Holds before minting; tokens of 60–120 s minted per batch of about 10 pages; per-account daily token and page limits; a dedicated Mathpix app with `image_monthly_limit` as a provider-side ceiling; platform budget gate | Holds; per-account daily page limits; global concurrency; Mathpix `page_monthly_limit`; platform budget gate | n/a |
| Abuse | A leaked or malicious token can call `v3/text` freely until expiry, and on a per-app rate limit, starve other users. Bounded per token by expiry and rate (about 200/min [UNVERIFIED for our plan]): at most about 120–240 pages, $0.60–$1.20 at the page rate | A user can upload any file, but only to our endpoint, with page caps and holds. A size cap (64 MiB as before) and a check that it is a PDF before forwarding | — |
| Failure modes | Token expiry mid-paper (mint again for the next batch); 429s; partial papers (resume by page); app-token beta changes; billing at image vs page rate is ambiguous | Lost POST response leaves an uncertain attempt (existing quarantine and reconciliation design); Mathpix outage; long papers within the Cloud Run 900 s timeout; device disconnect (collect later by `pdf_id`; Mathpix holds results until `DELETE`) | Most non-arXiv papers stay PDF-only |
| Browser | Works if Mathpix CORS allows app tokens from browsers [UNVERIFIED] | Works (upload to our endpoint) | — |
| Rights and contract posture | Mathpix copy only; our account still warrants rights under its terms | The same, plus a transient copy on our server | None |

**Not viable as documented:**

- A device calling `v3/pdf` with an app token.
- The device uploading to temporary storage of ours and Mathpix fetching by `url`. That is storage, which the
  owner's own premise excludes.
- Mathpix private cloud ($25k/year).

**My reading:**

- (a) is the only route that fully matches the owner's premise, and it has the best retention properties. It is
  also the least proven, and the hardest to meter on the server.
- (b) is the fastest to good readers and meters exactly, but it changes the privacy promise from "PDFs never
  reach our servers" to "PDFs pass through our servers and are never stored".
- Ask Mathpix first (§8.2) whether a scoped PDF token or a direct-upload mechanism exists for enterprise
  customers. That would give (b)'s quality with (a)'s boundary.

## 4. Fit with the HTML-first reader and the on-device PDF route

### 4.1 Where Mathpix sits

- Order of preference:
  1. official arXiv HTML for that version, prepared on the device (unchanged);
  2. the Mathpix route, offered (never started automatically) when:
     - arXiv has no HTML for the version;
     - the compiler refuses or degrades badly;
     - the paper is a non-arXiv PDF;
  3. the local PDF viewer, always available.
- The existing single failure screen "Read this paper as its PDF" (Open PDF / Read with the on-device model) gains
  **Convert with Mathpix (~$0.13)**. A PDF added from elsewhere shows the same action in its view.
- Results:
  - the result is a `reader-bundle-v1` with Mathpix provenance, installed in the device's encrypted store;
  - Reader version details names the source ("Converted by Mathpix from the PDF, 2026-10-21");
  - it never replaces a valid HTML reader silently;
  - an arXiv paper that later gains HTML can offer the HTML version.
- Chat keeps using local context built from the bundle on the device. Mathpix does not change the cloud-chat
  consent or flow.

### 4.2 The on-device whole-PDF route: retire it from shipping builds; keep its parts

Given the owner's view that a whole-PDF local model is too ambitious, and the evidence:

- 350–365 MB of models;
- about 3 minutes per paper;
- the recogniser fails on the Neural Engine and in the Simulator;
- partial fixture conformance;
- no phone run;

I recommend:

- **Remove "Read with the on-device model" and its bundled models from the release that ships the Mathpix
  route.** This cuts about 350 MB from the app and a support surface. Until then, leave it under Settings ›
  Experimental, with no further investment. Keep the code in git history; it was built carefully and may be
  revisited.
- **Keep the parts that do small things well and that route (a) needs anyway:**
  - the PDFKit text layer: page count for quotes and holds, title and metadata, search and local context for
    PDF-only papers;
  - the page rasterizer: page images for `v3/text`, figure crops from `cnt` boxes;
  - the crop-cleaning helpers;
  - the reader vocabulary for formula images.
- **The figure-region / subfigure detector is a separate program** (`LOCAL_FIGURE_REGIONS.md`). It works on
  already-verified figure images, not whole PDFs, and stays on its own quality gates. Keep it.
- **Contract hazard:** Mathpix's terms say "You may not under any circumstance use output to develop models that
  compete with Mathpix." Once Mathpix is a vendor, do not use Mathpix outputs (ours or users') as training targets
  or labels for any local PDF model.
  - The owner should check whether earlier desktop work on the GPU host (`/home/ben/mathpix`) used Mathpix
    captures obtained under a Mathpix account as training targets, and raise it with counsel if so. I did not
    inspect that host.
  - `DECISIONS.md` describes earlier captures only as "comparison evidence".

## 5. Rights framing (not legal advice)

- **Device conversion vs. a copy service.** Converting a paper the user already lawfully holds, at the user's
  request, for the user's own reading, with no redistribution, is the strongest fact pattern. It is the same shape
  as scanner/OCR apps (Adobe Scan, Mathpix Snip itself).
  - US: fair-use reasoning in format-shifting and intermediate-copy cases supports it:
    - *Authors Guild v. HathiTrust*, 755 F.3d 87 (2d Cir. 2014)
      ([USCO summary](https://www.copyright.gov/fair-use/summaries/authorsguild-hathitrust-2dcir2014.pdf));
    - *Authors Guild v. Google*, 804 F.3d 202 (2d Cir. 2015);
    - *Sega v. Accolade*, 977 F.2d 1510 (9th Cir. 1992);
    - *Bartz v. Anthropic* (N.D. Cal. 2025): scanning lawfully bought books as a format change
      ([secondary](https://www.akingump.com/en/insights/ai-law-and-regulation-tracker/district-court-rules-ai-training-can-be-fair-use-in-bartz-v-anthropic)).
  - *Cablevision* (2d Cir. 2008) protects automated copying at the user's command, but distinguishes "a copy
    service that makes copies at the customer's request". A paid conversion service may sit nearer that side
    [UNVERIFIED].
  - Mathpix keeping page images for 30–90 days, and its broad licence grant, weaken the "transient, personal"
    framing. Route (a) with `improve_mathpix:false` is the cleanest.
- **arXiv.**
  - The default licence grants arXiv alone "a perpetual, non-exclusive license to distribute"
    ([licence](https://arxiv.org/licenses/nonexclusive-distrib/1.0/license.html)), and arXiv "is not the
    copyright holder" ([reuse](https://info.arxiv.org/help/license/reuse.html)).
  - The API Terms permit retrieving and using e-prints "for your own personal use, or for research purposes" and
    prohibit storing and serving e-prints "from your servers" without permission
    ([API ToU](https://info.arxiv.org/help/api/tou.html)).
  - I found nothing that expressly forbids a user's device sending one downloaded paper to a processor at the
    user's request [UNVERIFIED].
  - By licence:
    - CC0, CC BY and CC BY-SA: low risk; keep attribution and a "converted" notice.
    - NC and ND licences: the user's personal reading is fine, but our *paid* conversion may count as commercial
      or an adaptation [UNVERIFIED]. Show the licence in the confirmation.
  - The existing rights gate still governs server storage, sync and sharing. A Mathpix conversion creates no new
    server or sharing rights (`ARXIV_CONTENT_HOSTING_20261009.md`).
- **Publisher PDFs.**
  - Elsevier's website terms: "You may not use Content from the Services in combination with an artificial
    intelligence tool, (including to … process, analyse, generate output …)"
    ([terms](https://www.elsevier.com/legal/elsevier-website-terms-and-conditions)). A user sending a
    ScienceDirect PDF to an OCR/AI service is likely in breach of *their* contract. Our exposure (inducing breach)
    is [UNVERIFIED].
  - Springer Nature says third-party AI access is "not allowed unless explicitly licensed"
    ([guidance](https://group.springernature.com/gp/group/ai/ai-guidance-for-our-communities-and-partners)).
  - The product should say plainly that some publishers forbid this. It should not market conversion as a way
    around publisher terms. *Grokster*: liability follows "clear expression or other affirmative steps taken to
    foster infringement" ([opinion](https://www.law.cornell.edu/supct/html/04-480.ZO.html)).
- **EU and UK.**
  - The DSM Directive's TDM exceptions (Arts. 3–4) concern analysis for patterns and trends, not producing a
    reading copy, so they are a poor fit [UNVERIFIED]
    ([Art. 4](https://www.legislation.gov.uk/eudr/2019/790/article/4)).
  - InfoSoc Art. 5(1) temporary copies require "transient or incidental" copies, which multi-day retention
    undercuts.
  - UK CDPA s29A is non-commercial research only
    ([s29A](https://www.legislation.gov.uk/ukpga/1988/48/section/29A)). The 2026 UK government report made no
    legislative change ([secondary](https://www.osborneclarke.com/insights/opted-out-uk-government-moves-away-preferred-position-ai-and-copyright-following-report)).
  - Rely on the user-initiated, personal-use structure, not on a TDM exception.
- **What a user-responsibility clause does and doesn't do.**
  - It is customary, and it allocates risk and supports account termination.
  - It does not license content, bind rights holders, defeat a contributory or inducement claim, or replace
    Mathpix's warranty problem. Consumer indemnities are rarely collectable.
  - DMCA §512(a) needs transmission "without modification". §512(c) needs storage
    ([§512](https://www.law.cornell.edu/uscode/text/17/512)). Neither fits.
  - Still publish a copyright contact and a repeat-infringer and abuse policy. A DMCA agent designation costs $6
    for three years ([FAQ](https://www.copyright.gov/dmca-directory/faq.html)) and is worth having for anything
    we do host (podcasts, shared CC conversions).
- **Mathpix's terms are the crux.** Under its public terms, *we* would grant Mathpix a perpetual, sublicensable
  licence to every submitted paper and warrant that we may.
  - Mathpix's privacy policy says customer contracts and DPAs control for API customers' end-user content.
  - So a negotiated agreement limiting use to processing on our instructions, with no licence beyond that, is
    required before launch.
  - Their licence to us is "without the right to sublicense" and excludes resale. Get written confirmation that
    offering conversions to our users, priced per page, is permitted.

## 6. Privacy, consent and the App Store

- **New processor.** Mathpix (US; EU endpoint available) receives the PDF pages, which may include author names
  and, in a user's own files, personal data.
  - Needed: a DPA (GDPR Art. 28(3)); the sub-processor list; a transfer basis (Data Privacy Framework or the EU
    endpoint); records of processing; and privacy-policy entries naming Mathpix, its purpose, what is sent,
    retention, location, and that our server never stores the PDF (or, under (b), never stores it but passes it
    through).
  - The lawful basis is plausibly Art. 6(1)(b), processing at the user's request [UNVERIFIED].
- **Apple 5.1.2(i):** "You must clearly disclose where personal data will be shared with third parties, including
  with third-party AI, and obtain explicit permission before doing so." **5.1.1(ii):** provide a way to withdraw
  consent. **5.2.2:** use third-party services only as their terms permit (Mathpix and arXiv)
  ([guidelines](https://developer.apple.com/app-store/review/guidelines/)).
  - So: a per-paper confirmation naming Mathpix; a versioned consent, e.g. `pdf-conversion-v1`, separate from
    `cloud-ai-v5`; and a Settings switch to turn the feature off.
- **App Privacy details.**
  - Because Mathpix may retain data longer than needed to serve the request in real time (route (b), or any
    route without account-level `improve_mathpix` off), declare **User Content → Other User Content** for **App
    Functionality**.
  - Mark it linked to the user if requests are tied to the account ([App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)).
  - The current draft already lists "other user content". Add Mathpix in the privacy policy and the How Gradstep
    works screen (`DATA_HANDLING_AND_COSTS.md`).
- **Gradstep needs its own ToS and privacy policy before launch.** The app currently links only Apple's standard
  EULA. The clause below belongs in that ToS.

## 7. Cost model

Assumptions:

- Mathpix $0.005/page (route (a) assumes page-rate billing for dense pages).
- Average 25 pages per converted paper, capped at 80; ML papers with appendices often run 30–50.
- Papers added per active user per month: 10 for a typical user, 30 for a heavy one.
- Share of those papers converted with Mathpix (no usable HTML, and the user chose to convert):
  - 10% for an arXiv-centric reader;
  - 30% for mixed sources;
  - 60% for a publisher-heavy reader.

These shares are assumptions, not measurements. The only measured input is about 5% of fresh arXiv papers having
no HTML.

Per paper: 10 pages = $0.05; 20 = $0.10; 25 = $0.125; 30 = $0.15; 80-page cap = $0.40.

Monthly Mathpix cost:

| Active users | Typical, 10% | Typical, 30% | Typical, 60% | Heavy, 10% | Heavy, 30% | Heavy, 60% |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | $1.25 | $3.75 | $7.50 | $3.75 | $11.25 | $22.50 |
| 100 | $12.50 | $37.50 | $75 | $37.50 | $112.50 | $225 |
| 1,000 | $125 | $375 | $750 | $375 | $1,125 | $2,250 |

Plus a one-time $19.99 setup fee if a new Mathpix account is needed. An earlier Science Reader Mathpix key existed,
but whether that account is still usable is [UNVERIFIED]. Add roughly $5 for the quality comparison (§8.4).

**Against the $100/month budget:**

- In private beta (10–100 testers), Mathpix fits inside the **$30 metered allocation** only if free testing usage
  is capped. Set a server-enforced free allowance, e.g. 200 pages ($1) per tester per month, and a Mathpix
  `page_monthly_limit` (or `image_monthly_limit` for route (a)) of about 4,000 pages ($20) as the provider-side
  ceiling.
- Mathpix bills in arrears with no hard cap, so the quota is the real ceiling.

**Passing cost through:**

- Charge per page from the user's balance, with holds before submission and settlement after.
- The owner's "no app markup" makes Apple's commission our loss. Break-even per page:
  - $0.005 / (1 − 0.30) = **$0.0072** at the 30% commission;
  - $0.0059 at 15% (requires approved Small Business Program enrollment; `PRICING_RECOMMENDATION_20261008.md`).
- I recommend **$0.01/page** shown as dollars (about $0.25 for a 25-page paper), which also covers failed or
  uncertain pages. The alternative is the exact break-even, labelled as cost plus Apple's fee.
- Either is an owner pricing decision; record it.
- At launch, paid conversions are self-funding apart from the commission gap and failures. The $100 budget is then
  exposed only to free allowances, failed or uncharged pages, abuse within token bounds, and arrears timing.

## 8. Recommendation

### 8.1 Decision

- Launch with Mathpix as the user-initiated, per-paper, confirmed route for papers without usable arXiv HTML. Do
  not offer it as an automatic fallback.
- Retire the on-device whole-PDF route as in §4.2.
- The owner must first record a new decision that supersedes the 2026-10-13 "no Mathpix fallback" direction. That
  decision should choose between:
  - **(b)**, accepting PDFs in transit through our server;
  - **(a)**, keeping the device-only boundary at the cost of a new adapter and weaker metering.
- Until Mathpix answers §8.2, I lean to **(b) for the first release, if the owner accepts transit**, because its
  quality and metering are already proven. Otherwise (a).

### 8.2 Confirm with Mathpix in writing

1. A services agreement and DPA that replace the public User Content licence. Mathpix processes only to provide
   the service on our instructions, with no licence to reproduce, distribute or sublicense, no training or QA use,
   and no warranty from us beyond our users' representations.
2. Permission to offer the API to our end users in a paid consumer app, priced per page. This is not "resale" of
   the Services.
3. Account-level `improve_mathpix` off. Retention for `v3/pdf` after `DELETE`, and for `v3/text` with the flag
   off. Sub-processor list. EU endpoint terms.
4. Whether any **PDF-capable client-side credential** exists (a scoped app token or a direct-upload URL), and
   whether app tokens are supported in production at our scale (the docs say beta).
5. Route (a) specifics:
   - billing for full-page images (image or page rate);
   - per-app rate limits and whether we can set our own;
   - per-token usage visibility, e.g. tags in `ocr-usage`;
   - CORS for browser use.
6. The maximum PDF page count. The `v3/pdf` rate limit. Quotas we can set (`page_monthly_limit`) and whether
   they hard-stop.
7. How "use output to develop models that compete with Mathpix" applies to our separate on-device work, and to
   any earlier captures.

### 8.3 Confirm with counsel

- The ToS clause and indemnity scope.
- The stance on default-licence arXiv, NC/ND and publisher PDFs, especially Elsevier's AI/processing clause.
- Whether to block or warn on known-restricted sources.
- The privacy policy and DPA terms.
- Whether a DMCA agent and repeat-infringer policy are needed for our hosted parts.
- Copy claims ("never stored on our servers" vs "passes through").

### 8.4 Build order (after the decision and written answers)

1. **Quality comparison.** About 20 openly licensed (CC BY/CC0) papers, including ones without arXiv HTML; about
   $5 at 25 pages each across both routes. Run `v3/pdf` and per-page `v3/text` with `enable_document_layout`, and
   compare them in the actual reader against the reader-sweep checks. This needs owner approval for the paid
   spend and key handling. Use a dedicated Science Reader Mathpix app with quotas set.
2. **Server.**
   - a versioned consent (`pdf-conversion-v1`);
   - hold, settlement and uncertainty records reusing the historical protocol;
   - per-account daily limits;
   - platform budget gate;
   - admin view of Mathpix spend, quotas and drift;
   - for (b), the streaming endpoint and the post-collection `DELETE` with a backstop sweep;
   - for (a), token minting per page batch and daily `ocr-usage` reconciliation.
3. **Device.**
   - the confirmation sheet;
   - progress;
   - rendering the result on the device into an encrypted `reader-bundle-v1` with honest provenance;
   - Reader version details;
   - a Settings switch to turn the feature off;
   - browser parity.
4. Remove the on-device whole-PDF route and models (§4.2). Update How Gradstep works, Acknowledgements (currently
   stale), the privacy policy, the ToS and the App Privacy details.
5. **Tests.**
   - fast-tier units for holds, settlement and consent;
   - a recorded-response fixture for the adapter;
   - one opt-in hosted canary within a recorded spend cap.

### 8.5 Confirmation UI (one sheet, per paper)

- It appears only on an explicit "Convert with Mathpix" tap.
- It shows: page count (from PDFKit, with "first 80 pages" when capped), the price, the paper's licence when
  known, and one rights checkbox.
- On first use it shows the full disclosure. Later uses show the short form, with ⓘ opening the full text,
  following the minimal-screen preference.
- The checkbox is required every time for publisher or unknown sources. It is pre-satisfied for CC0/CC BY arXiv
  versions, and the sheet shows the licence there.

## 9. Drafts for counsel review

### 9.1 Consent sheet (first use; `pdf-conversion-v1`)

> **Convert with Mathpix?**
> This paper has no readable arXiv HTML version, so Gradstep can't prepare it on your device. Mathpix, an
> outside OCR service, can convert it into a reader with equations and figures.
>
> - Your device sends this PDF's pages (24 pages) **directly to Mathpix** *[route (b): "through Gradstep's
>   server, which doesn't keep them"]*. Mathpix is in the United States.
> - Mathpix is asked not to keep them *[exact retention per the Mathpix agreement]*. Gradstep never stores the
>   PDF.
> - The converted paper is saved only on your devices, encrypted like your other papers.
> - Cost: **$0.24** from your balance. You aren't charged if conversion fails.
>
> ☐ I have the right to use this file this way. For example, it's openly licensed, it's my own work, or I'm
> converting a copy I may use for my own reading. Some publishers don't allow this. Gradstep doesn't check it for
> you.
>
> [Convert] [Not now] · You can turn conversions off in Settings.

Short form for later uses: "Convert with Mathpix: 24 pages, $0.24. Pages go to Mathpix; the result stays on
your devices. ☐ I have the right to use this file this way. ⓘ"

### 9.2 Terms of Service clause

> **Documents you choose to convert.** Gradstep lets you send a document, or images of its pages, to a
> third-party conversion provider (currently Mathpix, Inc.) to create a readable version for your own use. Each
> conversion happens only when you request it. You are responsible for making sure you have the rights and
> permissions needed to send that document for processing and to use the result, including under any license or
> terms that apply to it (for example, an arXiv license or a publisher's terms of use). Do not use conversion for
> documents you are not permitted to process this way, or to share or redistribute content. Gradstep does not
> review the documents you convert and does not store them on its servers *[route (b): "they pass through our
> servers only to reach the provider and are not stored"]*. Converted results are kept on your devices. We may
> limit or suspend conversion for accounts that we reasonably believe are misusing it, and we respond to notices
> from rights holders at *[copyright@gradstep.ai]*. *[Indemnity, limitation of liability and governing law: for
> counsel.]*

## 10. Unverified or open items

- The maximum page count for `v3/pdf`, its per-minute rate limit, and the rate limits for our plan.
- App-token billing and usage attribution, production readiness (beta), and browser CORS.
- Whether full-page `v3/text` is billed at the image or page rate, and its quality on papers.
- Whether Mathpix offers an enterprise agreement that narrows the User Content licence, and its terms.
- GDPR and HIPAA statements and the sub-processor list (available on request only).
- The status of the earlier Science Reader Mathpix account and setup fee.
- Supabase Edge request-size limit (about 10 MB, secondary sources) vs. Cloud Run for route (b).
- Whether arXiv's official HTML now covers older papers generally (two spot checks only).
- All legal characterizations above, which are for counsel.
