# arXiv terms audit and device-only access design

**Status:** rollout steps 1–3 and the search part of step 4 are implemented and switched off (§6.0); the rest is a
proposal. Nothing here is deployed, applied to staging or switched on. **Date: 2026-10-15.**
Owner request (2026-10-15): audit the app against arXiv's current terms; ensure user devices exclusively interact
with arXiv servers and ours do not; stop server metadata calls to arXiv and have devices fetch what they need and
pass it to our server; examine the related sites.

This is a product and engineering review, **not legal advice**. arXiv support said explicitly that it gives no legal
guidance (ticket AH-211376). Items marked for counsel need a lawyer, not another engineering pass.

## Summary

- **Yes, our servers call arXiv for metadata today.** The audit found 8 call sites to 3 arXiv hosts
  (`export.arxiv.org`, `oaipmh.arxiv.org`, `rss.arxiv.org`). They run behind 7 deployed server entry points: the
  Cloud Run pipeline worker, the retired-but-deployed Edge `paper-worker`, `feed-refresh`, `discover`, `add-paper`,
  `add-reference` and `chat`. No server code fetches arXiv HTML, PDFs or source, and no migration makes a `pg_net`
  call to arXiv.
- **The terms allow server metadata use.** arXiv's API terms say "Retrieve, store, transform, and share descriptive
  metadata", and metadata is CC0. The binding constraints on that use are the rate limit and caching. What the terms
  forbid is storing and serving e-print *content* without a licence. Who opens the network connection does not
  change that.
- **The device-only move is still sound policy**, but it does not fix the actual red items:
  1. arXiv-derived content our servers still hold. This covers legacy server conversions of default-licence papers,
     still served as a fallback, and the full paper text that devices upload for private podcast episodes.
  2. The missing required acknowledgement statement on every surface.
- **Moving API calls onto devices carries its own risk.** The rate limit applies to "all of the machines under your
  control as a whole", and "You should not attempt to overcome these limits by increasing the number of machines".
  Device calls must be user-initiated, cached and paced, and we should ask arXiv to confirm the arrangement.
- **CORS limits what the browser can do.** Measured from `https://app.gradstep.ai`, the browser can read only
  `arxiv.org/html` and `arxiv.org/pdf`; the API, RSS, OAI-PMH, abstract and listing pages send no CORS header.
  DataCite and OpenAlex do send CORS headers.
- **Recommendation.**
  - Content stays device-only, as today.
  - Per-paper metadata is extracted on the device from the arXiv HTML it already downloads, at zero extra arXiv
    requests. For a paper without HTML, a native device makes one paced export API request when the person opens
    it; the browser sends nothing until the owner confirms DataCite.
  - Device metadata is account-scoped and never promoted to shared data unverified.
  - **Governing rule (owner, 2026-10-15):** each device calls arXiv only as that user's own independent agent:
    user-triggered, kept to that user, paced per device, honestly identified, never harvesting (§5.1).
  - Shared data (the Feed pool, search enrichment, licence corroboration) comes from **DataCite**
    (`provider-id=arxiv`). arXiv support itself named DataCite, and it is not an arXiv host.
  - A deploy-time and runtime egress guard enforces "no server request to `*.arxiv.org`".

## 1. Sources reviewed and quoted clauses

All pages were retrieved on **2026-10-15** and their contents treated as data. Every `info.arxiv.org` page returns
`Last-Modified: Mon, 05 Oct 2026` because the whole site was rebuilt then; that date is not evidence that a page changed.
Per-page change dates below come from the public source repository `github.com/arXiv/arxiv-docs`.

| Page | URL | Last textual change (git) |
|---|---|---|
| Terms of Use for arXiv APIs | https://info.arxiv.org/help/api/tou.html | 2025-08-12 (a link update); substantive edits 2023 |
| arXiv API Access (commercial, acknowledgement) | https://info.arxiv.org/help/api/index.html | 2023-05-09 |
| API User Manual | https://info.arxiv.org/help/api/user-manual.html | 2025-02-25 (query syntax) |
| Brand use (redirects to Name and Logo Use) | https://info.arxiv.org/about/brand_use → https://info.arxiv.org/brand/brand-guidelines.html | **2026-06-30** (Cornell removed; trademark now "the legal property of arXiv") |
| Licence information | https://info.arxiv.org/help/license/index.html | 2024-10-29 |
| Reuse requests FAQ | https://info.arxiv.org/help/license/reuse.html | — |
| Bulk data access | https://info.arxiv.org/help/bulk_data.html | 2026-07-06 (page clean-up) |
| Bulk data on S3 | https://info.arxiv.org/help/bulk_data_s3.html | 2026-01-10 |
| Robots Beware; robots.txt | https://info.arxiv.org/help/robots.html, https://arxiv.org/robots.txt, https://export.arxiv.org/robots.txt | 2026-01-11 (typo fixes) |
| OAI-PMH | https://info.arxiv.org/help/oa/index.html | 2026-08-11 (links); March 2025 system rewrite |
| RSS | https://info.arxiv.org/help/rss.html | — |
| HTML papers | https://info.arxiv.org/about/accessible_HTML.html | 2024-05-03 |
| arXiv is an independent nonprofit | https://info.arxiv.org/about/spinout_faq.html | 2026 |
| arXiv blog, "Updated Rate Limit Policy" | https://blog.arxiv.org/2026/10/01/updated-rate-limit-policy/ | 2026-10-01 |
| DataCite REST API, rate limits, data use policy | https://support.datacite.org/docs/api, /docs/rate-limit, /docs/datacite-data-file-use-policy | — |

### 1.1 What changed recently

- **The API terms did not change substantively in 2026.** The source file's last edit is a 2025-08-12 link
  update. The 2023 edits removed references to an "API Gateway" and an outdated document.
- **arXiv's own "rate limit policy" of 1 October 2026 concerns submissions, not the API.** It limits each submitter
  to "up to two submissions per calendar month, with a limit of three total active submissions". Third-party blogs
  describe it as an API or download tightening; the primary source does not say that.
- **arXiv became an independent nonprofit on 1 July 2026.** The June 2026 brand-page edit made the marks "the legal
  property of arXiv" rather than of "arXiv and Cornell University".
- **OAI-PMH moved to `https://oaipmh.arxiv.org/oai` in March 2025.** Separately, on 2026-10-14 the server stopped
  answering percent-encoded identifiers. Our worker adapted (`arxiv.ts:89-93`).

### 1.2 Terms of Use for arXiv APIs (https://info.arxiv.org/help/api/tou.html)

**Scope.** "Our APIs include our OAI-PMH interface, RSS feeds, the legacy arXiv API, bulk data downloads, and SWORD
bulk deposit API." "By using arXiv APIs, you are agreeing to the terms and conditions outlined on this page."

**Copyright.** "You understand that e-prints from arXiv are subject to all applicable copyright protections. The
redistribution of e-prints requires permission from the copyright holder, which may be the author(s) or publisher.
arXiv is not the copyright holder on any of the e-prints available through the API. In some cases, submitters have
provided permission in advance by submitting their e-print under a permissive Creative Commons license. The vast
majority of e-prints are submitted under the arXiv.org non-exclusive right to distribute."

**Metadata.** "You are free to use descriptive metadata about arXiv e-prints under the terms of the Creative Commons
Universal (CC0 1.0) Public Domain Declaration." The footnote defines it: "Descriptive metadata includes information
for discovery and identification purposes, and includes fields such as title, abstract, authors, identifiers, and
classification terms."

**Limits and enforcement.** "You agree to respect limitations on use of arXiv APIs, including rate limits and
authorization mechanisms. If we think that you are attempting to circumvent those limitations, that your use of
arXiv APIs threatens normal operation or availability of the arXiv platform, or that you are doing something illegal
or unethical, we may further limit or block your access."

**Changes and contact.** "It is up to you to keep track of changes that might affect your use of arXiv APIs and to
make any required changes." "…we will collect certain private information about you, such as your name and email
address."

**Rate limits.** "Please note that the following rate limits apply to all of the machines under your control as a
whole. You should not attempt to overcome these limits by increasing the number of machines used to make requests. If
your use-case requires a higher request rate, please contact our support team." "When using the legacy APIs
(including OAI-PMH, RSS, and the arXiv API), make no more than one request every three seconds, and limit requests to
a single connection at a time." "These limits may change in the future."

**Things that you can (and should!) do:**
- "Retrieve, store, transform, and share descriptive metadata about arXiv e-prints."
- "Retrieve, store, and use the content of arXiv e-prints for your own personal use, or for research purposes."
- "Provide tools and services to users that helps them to discover or be notified about arXiv e-prints." Among the
  examples: "A better search interface" and "A mobile app that notifies users about e-prints that might be of
  interest to them".
- "Build other kinds of interfaces that help users to interact with arXiv in new and useful ways, leveraging our APIs."
- "Direct users to arXiv.org to retrieve e-print content (PDF, source files, etc). We encourage you to link to the
  abstract page."

**Things that you must not do:**
- "Store and serve arXiv e-prints (PDFs, source files, or other content) from your servers, unless you have the
  permission of the copyright holder or are permitted to do so by the license with which the e-print was submitted.
  Note that a very small subset of arXiv e-prints are submitted with licenses that permit redistribution."
- "Represent your project as endorsed or supported by arXiv.org without our permission."
- "Attempt to circumvent rate limits."
- "Use someone else's credentials to access arXiv APIs."

### 1.3 Commercial use, acknowledgement and branding

From the API Access page (https://info.arxiv.org/help/api/index.html):

- "Commercial projects that utilize arXiv's APIs should review relevant documentation first. Read about our public
  APIs or other bulk data pipelines, review arXiv's brand use guidelines, and consider becoming an arXiv affiliate
  before embarking on the project. This includes any project created as a product for sale."
- "For all API users, … Acknowledge arXiv data usage with this statement on your product: 'Thank you to arXiv for use
  of its open access interoperability.'"
- "Do not brand your project with arXiv's names ('arXiv', 'arXiv.org', 'arXiv Labs', 'arXivLabs') or use associated
  logos, web addresses, and colors in a manner that implies arXiv's endorsement of the project."

From the brand guidelines (https://info.arxiv.org/brand/brand-guidelines.html):

- "The arXiv® name and logo are registered trademarks and the legal property of arXiv. Unauthorized use of our logo
  or name is prohibited."
- "Use of the name arXiv and associated logos, web addresses, and colors are only allowed for the purpose of
  acknowledging use of arXiv's API or data from the arXiv corpus."
- "The use of the name 'arXiv' or 'arXiv.org,' in non-arXiv organization names or projects that imply or tend to
  imply some official connection with arXiv, is prohibited."
- "Except as specifically authorized in writing, use of arXiv's name and marks in advertising and other promotional
  vehicles is prohibited when such use is likely to be perceived as an endorsement, even if such an endorsement is not
  the intention of the person or organization seeking to use arXiv's name or marks."
- **For products that use the arXiv API:** "Acknowledge arXiv data usage with this statement on your product: 'Thank
  you to arXiv for use of its open access interoperability. This [service/ product] was not reviewed or approved by,
  nor does it necessarily express or reflect the policies or opinions of, arXiv.'" And: "Logo use is limited to
  acknowledgement of the user of arXiv's API or data from the arXiv corpus."

### 1.4 API manual, licences, bulk data, robots, OAI-PMH, RSS and HTML

**API User Manual:**
- "In cases where the API needs to be called multiple times in a row, we encourage you to play nice and incorporate
  a 3 second delay in your code."
- "…there is no need to call the API more than once in a day for the same query. Please cache your results. This
  primarily applies to production systems…"

**Licences (https://info.arxiv.org/help/license/index.html):**
- "All articles on arXiv.org can be viewed and downloaded freely by anyone."
- "For all licenses here, with the exception of CC Zero, the original copyright holder retains ownership after
  posting on arXiv."
- "Please note that different versions of the work can have different licenses."
- On the arXiv licence: "This license gives limited rights to arXiv to distribute the article, and also limits
  re-use of any type from other entities or individuals."
- "A Creative Commons CC0 1.0 Universal Public Domain Dedication will apply to all metadata."
- CC BY 4.0 "allows for commercial use". CC BY-SA adds "you must license the modified material under identical
  terms". The NC licences are "for noncommercial purposes only".

**Reuse FAQ:**
- "The overwhelming majority of e-prints are submitted using the arXiv perpetual non-exclusive license, which does
  not grant further reuse permissions directly. In these cases you will need to contact the author directly."
- "…the license for the full text is not a part of the current search API schema. The license is, however, provided
  within arXiv's output from the OAI-PMH in either arXiv or arXivRaw formats."
- The HTML page also shows it. Measured: the `#license-tr` box reads "License: CC BY 4.0" (2305.18290v3) and
  "License: arXiv.org perpetual non-exclusive license" (2610.20611v1).

**Bulk data:**
- OAI-PMH "is the preferred way to bulk-download or keep an up-to-date copy of arXiv metadata."
- "We are thus unable to grant others the right to distribute arXiv articles. If you build indexes or tools based on
  the full-text, you must link back to arXiv for downloads."
- "We ask that users intent on harvesting use the dedicated site export.arxiv.org", and "we suggest that a reasonable
  rate to be bursts at 4 requests per second with a 1 second sleep, per burst."
- "Please do not attempt to download the complete corpus programmatically. The Amazon S3 buckets are the accepted
  mechanism". The S3 buckets are requester-pays.
- RSS is "intended primarily for human consumption".

**Robots:**
- "Indiscriminate automated downloads from this site are not permitted." "…our first priority is to support
  interactive use by human users."
- "arXiv monitors activity and will deny access to sites that violate these guidelines. Continued rapid-fire requests
  from any site after access has been denied (i.e. with 403: Access denied HTTP response) will be interpreted as an
  attack".
- `arxiv.org/robots.txt` sets `Crawl-delay: 15`. It allows `/abs`, `/pdf`, `/html` and `/list`, and disallows
  `/api`, `/search`, `/oai2`, `/e-print` and `/src`. `export.arxiv.org/robots.txt` is `Disallow: /`.
- These rules govern crawlers. A user-initiated page load is interactive use.

**OAI-PMH:**
- "Metadata for arXiv articles may be reused in non-commercial and commercial systems."
- "Only the most recent version of each article is exposed via this interface (some metadata formats include the
  version history)."
- Metadata appears "typically around 10:30pm ET Sunday through Thursday".

**RSS:**
- Feeds live at `https://rss.arxiv.org/rss/<categories>`, and "Feeds are updated daily at midnight Eastern Standard
  Time."
- "Please review the Terms of Use for arXiv APIs before using the arXiv RSS feeds."

**HTML papers:**
- "We are gradually backfilling HTML … a small percentage of papers will not have an HTML version." The page sets no
  separate HTML use terms. HTML is website content, so the licence, copyright and robots rules apply to it.

**Independent nonprofit (spin-out FAQ):**
- "On July 1, 2026, arXiv established itself as an independent nonprofit organization." It plans to "expand its
  member, affiliate, and sponsor programs".

**DataCite:**
- Public API: "Accessed without authentication: used for retrieving metadata".
- Rate limits are per IP address over a 5-minute window: "500 requests per 5 minutes" unidentified, 1000 identified
  (a User-Agent with an email, or `mailto=`), and 3000 authenticated. "…the API will return a 429 response code."
- Data use: "DataCite e.V. has waived all copyright and related or neighboring rights to DataCite Data File. The
  DataCite Data File includes all DOIs and deposited metadata". "…the CC0 waiver does not apply to use of the DataCite
  e.V. name, and other DataCite marks and logos."

### 1.5 arXiv support reply (AH-211376, 15 Oct 2026, as relayed by the owner)

The reply said:
- Follow the API Terms of Use, the brand guidelines and the content licences.
- Metadata options are the arXiv API, the **DataCite API (provider-id=arxiv)** and Kaggle.
- Full text is available via AWS bulk, Kaggle, or crawling the export service for new content or subsets.
- **No MOU is required** for commercial projects; becoming an affiliate or sponsor is encouraged but optional.
- arXiv gives no legal guidance.

### 1.6 Endpoint behaviour measured from the app's origin (2026-10-15)

Each endpoint was requested with `curl -I` and `Origin: https://app.gradstep.ai`, 3 seconds apart.

| Endpoint | Status | `Access-Control-Allow-Origin` | Usable from the browser app |
|---|---|---|---|
| `https://export.arxiv.org/api/query?id_list=…` | 200 Atom | none (OPTIONS answers 200 with no CORS headers) | **No** |
| `https://arxiv.org/api/query…` | 302 to `http://export.arxiv.org/…` | none | No |
| `https://rss.arxiv.org/atom/cs.CL` | 200, `Cache-Control: max-age≈86,345` | none | **No** |
| `https://oaipmh.arxiv.org/oai?verb=Identify` | 200 | none | **No** |
| `https://arxiv.org/abs/<id>`, `/list/<cat>/new`, `export.arxiv.org/abs`, `export.arxiv.org/list` | 200 HTML | none | No |
| `https://arxiv.org/html/<id>v<n>` and `/html/<id>` | 200 | `*` | **Yes** (already used) |
| `https://arxiv.org/pdf/<id>v<n>` | 200 | `*` | **Yes** |
| `https://api.datacite.org/dois/10.48550/arXiv.<id>` | 200 JSON | the origin is echoed | **Yes** |
| `https://api.openalex.org/works?...` | 200 JSON | `*` | **Yes** |

An arXiv HTML page carries enough metadata for a library entry:
- `<title>` and `h1.ltx_title_document`;
- the authors (`.ltx_personname`);
- the abstract (`.ltx_abstract`);
- the exact version's licence (`#license-tr`);
- a watermark of the form `arXiv:2305.18290v3 [cs.LG] 29 Jul 2024`, giving id, version, primary category and the
  version date.

A DataCite record (`10.48550/arXiv.<id>`) carries:
- title, creators, abstract and arXiv subjects;
- `rightsList` (licence URI) and `version`;
- per-version submitted dates.

DataCite's `version` and `rightsList` describe the latest version, which matches OAI-PMH. New DOIs appeared about
3 hours after the 00:00 UTC announcement (observed: 2610.206xx created 03:05 UTC on 15 Oct). Batch lookup works with
`/dois?ids=doi1,doi2`. A category window such as
`query=subjects.subject:("(cs.LG)" OR …) AND created:[T TO *]` works; it returned 2,541 records for four categories
since 14 Oct 00:00 UTC.

## 2. Server-side inventory

### 2.1 Requests from our servers to arXiv-operated hosts

The global pacing gate is `worker_pipeline_arxiv_slot`, migration `202610050014_paper_pipeline.sql:275-286`. It
reserves 3-second slots, spaces request *starts* across every server caller, and returns `reserved:false` when the
queue is too long.

| # | Call site | Host and request | Reached from (deployed?) | When it runs | Volume estimate | What is stored |
|---|---|---|---|---|---|---|
| S1 | `_shared/metadata-pipeline.ts:136` via `arxiv.ts:87-88` | `export.arxiv.org/api/query?id_list=<id>[v<n>]&max_results=1` (Atom) | Cloud Run pipeline worker (`services/pipeline-worker/run.ts:8,23`); also the Edge `paper-worker` (`paper-worker/index.ts:36`, retired from the scheduler but redeployed 2026-10-15) | Metadata stage of every new shared pipeline paper (`source_id`, requested revision). Woken by the import trigger (`pipeline_kick`, migration 014:126-139, `pg_net` to our worker) and by `pg_cron` every minute (`deploy-staging.py:191`) | 1 per distinct paper and revision across all accounts, plus up to 9 retries; 2 reserved slots per paper | `catalog_metadata` (title, authors, abstract, categories, dates, venue), shared across accounts |
| S2 | `metadata-pipeline.ts:144` via `arxiv.ts:92-93` | `oaipmh.arxiv.org/oai?verb=GetRecord&identifier=oai:arXiv.org:<id>&metadataPrefix=arXivRaw` | Same as S1 | Same as S1; this is the licence evidence and the fallback record | 1 per distinct paper and revision, plus retries | `rights_mode`, `license_uri`, reuse evidence (SHA-256 of the response), `catalog_asset_approvals` for CC BY/CC0 |
| S3 | `_shared/feed-pool.ts:174` (URL `:29-32`, UA `:26`) | `rss.arxiv.org/rss/cs.LG+cs.CL+…` (12 categories), conditional on ETag and Last-Modified | `feed-refresh` (deployed 2026-10-08), woken by `pg_cron` `*/30` (migration 043:500) when `refresh_enabled` and due every 120 min. **Live:** refresh on, serving `staff` since 2026-10-09 | Scheduled | At most 12 per day, mostly 304 | Feed pool rows (id, revision, title, up to 12 authors, abstract up to 2,000 characters, categories, topics, announce day). Served to every staff account |
| S4 | `discover/index.ts:120` with `arxivRecentURL` (`discover.ts:256-259`) | `rss.arxiv.org/rss/<category>` | `discover` | A Feed category chip for a reader the pool does not serve: every non-staff account, or a category outside the pool such as "More topics" | **1 per chip load per reader, uncached** | Nothing; passed through to the client |
| S5 | `discover/index.ts:120` with `arxivSearchURLs` and `arxivIDListURL` (`discover.ts:33-60`, `:224-229`) | `export.arxiv.org/api/query`: exact-title phrase (oldest first), plus either all-words search or `id_list` of up to 25 OpenAlex-ranked IDs; or a single `id_list` for a typed ID | `discover` (Library "arXiv" search, both native and browser) | Every search | 1–2 per search | Nothing; passed through |
| S6 | `_shared/find-paper.ts:57,63,73` via `arxivTitleURLs` (`discover.ts:332-341`) and `searchArxiv` (`discover.ts:395-418`, fetch `:410`) | `export.arxiv.org/api/query`: `id_list`, `ti:"phrase"`, `ti:w AND …` | `chat` (Ingest, `chat/index.ts:57,88`); `add-paper` (DOI, link and text paths through `identify.ts:255-282` and `add-paper.ts:50`); `add-reference` (`add-reference/index.ts:47-54`) | Ingest, Add by DOI, link or reference, or a reference's Add to library | Up to 3 per lookup | Nothing; the found ID is queued as an import, which then triggers S1/S2 |
| S7 | `find-paper.ts:83` | `export.arxiv.org/api/query?id_list=<up to 5 IDs from Tavily results>` | `chat` Ingest; `add-reference` with Tavily consent | When the Tavily fallback runs | 0–1 per lookup | Nothing |
| S8 | `_shared/reference.ts:144` | `export.arxiv.org/api/query?id_list=<IDs written in a reference>` | `add-reference`; `add-paper` text path | When a reference contains arXiv IDs | 1 per reference with IDs | Nothing |

User-Agent strings sent to arXiv:
- `'ScienceReader/0.1 (research paper reader; mailto:support@sciencereader.invalid)'` (`metadata-pipeline.ts:54`).
  The `.invalid` domain is an undeliverable contact address.
- `'ScienceReader/0.1 (research paper reader)'` (`feed-pool.ts:26`, `discover.ts:411`, `discover/index.ts:121`),
  with no contact and the old product name.

Checked and **not** found:
- No server request to `arxiv.org/html`, `/pdf`, `/e-print` or `/abs`. `fetchArxiv` (`metadata-pipeline.ts:45-50`)
  refuses anything but the two metadata endpoints. `identify.ts:155` (`arxivInURL`) short-circuits arXiv links on
  every redirect hop before fetching, and `find-paper.ts:38-41` and `identify.ts:239-242` refuse arXiv as an
  "open PDF" host.
- No `pg_net` call to arXiv. Every `net.http_post` in migrations 014, 043, 048 and 054 targets our own worker or
  function.
- No `workers/reader-renderer` or `services/workflow-checks` code calls arXiv directly. The hosted daily check
  `html.membership` (`scripts/workflow-checks.mjs:625`) imports 2305.18290v3. Its metadata is normally cached
  already; when it is not, the check triggers S1/S2 once.

### 2.2 Other scholarly and search sources our servers contact

| Source | Call sites | Use | Stored |
|---|---|---|---|
| OpenAlex (`api.openalex.org`) | `discover.ts:78-88` and `discover/index.ts:92-101` (two ranking queries per search); `discover/index.ts:141` (ID fallback); `find-paper.ts:28-31`; `reference.ts:122,184-187`; `identify.ts:257`; `web-source.ts:188-205` (metadata for `openalex:` web papers) | Search ranking, finding papers, DOI resolution, web-paper metadata | Web-paper metadata (`worker_pipeline_web_metadata`) |
| Crossref (`api.crossref.org`) | `reference.ts:77-81,170`; `identify.ts:270` | Citation matching and DOI titles | Nothing |
| Hugging Face Papers (`huggingface.co/api/daily_papers`) | `feed-signals.ts:20-25,81` | Feed popularity, inside the pool refresh (at most 12 per run) | Upvotes on pool rows |
| Tavily (`api.tavily.com`) | `tavily.ts:94` (`ACADEMIC_DOMAINS` includes `arxiv.org`, `:13-18`) | Chat web search and the reference fallback | Snippets of up to 1,500 characters per result go to the model. Tavily, not our server, crawled arXiv |
| Anthropic web search | `anthropic.ts:210-219` | Chat search (backup) | Run by Anthropic |
| Publisher landing pages and PDFs (only the first bytes) | `identify.ts:152-163` (`probeLink`, with arXiv short-circuited at `:155`) | Identify a pasted link | Nothing |
| DataCite, Semantic Scholar, Unpaywall, Kaggle | — | **Not used** | — |

### 2.3 arXiv-derived content held by our servers

This is the part of the terms that "devices only" does not address.

| Holding | Where | Licence scope | Served? |
|---|---|---|---|
| Historical server originals (PDFs) and Mathpix reader bundles made before 2026-10-13 | `paper-assets` Storage; `pipeline_papers.rights_mode` is `shared` (CC BY/CC0) or **`legacy_private`** (pre-051 arXiv conversions of default or unknown licences, migration 051:13-37) | Includes **default-licence** papers | **Yes.** `reader-artifact` and `reader-member` deliver a legacy server bundle as the fallback when arXiv has no usable HTML (`HTML_FIRST_READER.md:371-375`). Chat for such an item uses the server document |
| Private podcast device sources: the full numbered paper text a device uploads | `private-content/podcast-sources/<account>/<sha256>/<upload>.txt` (migration 076; `<sha256>.txt` before it), up to 400 KB each (migration 066; `PAPER_PODCASTS.md:1477-`) | **Any licence**, including default | Used by the worker (Anthropic or DeepSeek writes the script, Vertex voices it). Deleted once the episode is ready, fails or is canceled; unused uploads after a day (migration 076, 2026-10-16; privacy page) |
| Private podcast audio and transcripts, which quote verbatim evidence | `podcast-assets` | Any licence | Yes, to the owning account (links expire in 15 minutes) |
| Shared podcast catalog audio | `podcast-assets`, `podcast_rights` (CC BY 4.0/CC0 approval pinned) | CC BY 4.0 and CC0 only | Yes, to every listener, with attribution and licence fields |
| Chat paper context | Not stored; relayed per request to Anthropic (`CHAT.md`; privacy page) | Any | No (transient relay; the provider may retain under its terms) |
| Metadata: `catalog_metadata`, Feed pool, tags, upvotes | Database | CC0 metadata | Yes, to other accounts |

### 2.4 Machines under our control that are not servers

These run on the developer's Mac, not production servers. They still count toward "all of the machines under your
control" for rate limits.

| Script | arXiv requests |
|---|---|
| `scripts/reader-sweep.mjs:47` | Export API listing and HTML; paced like the app |
| `scripts/fetch-reader-corpus.mjs:45,54` | HTML and PDF for pinned revisions; one at a time, at least 3 seconds apart; refuses CI and Cloud Run |
| `scripts/reader-device-compile.mjs` | Asset fetches, cached |
| `scripts/tag-catalog.mjs:32` | Export API `id_list` in `sample` mode |

## 3. Client-side inventory

| Client | What it fetches from arXiv | Identification | Pacing and backoff | Caching | Versions |
|---|---|---|---|---|---|
| iPhone, iPad and Mac (shared Swift): `ScienceReader/Services/ArxivHTMLReader.swift:84-153`; URL from `ScienceReaderCore/ArxivReaderProvenance.swift:13` | `https://arxiv.org/html/<id>v<n>` plus the declared images from that page; the asset allow-list comes from a dry compile | **No custom User-Agent** (the default CFNetwork UA). Ephemeral session: no cookies, no redirects | 3 s between HTML documents per device, at most 4 assets in flight, 429 or 503 with `Retry-After` pauses the whole device (minimum 3 s, maximum 24 h), more than 60 s reported as busy. 403 is not distinguished | No HTTP cache; the verified bundle persists on the device (`DeviceReaderStore`), so a paper is fetched once | Exact versioned URLs only |
| Same, automatic download | `ReaderModel.swift:149,203,767`: "Download new papers automatically" (on by default) prepares each paper this device saw finish importing | — | Same queue | — | — |
| Same, links | "Open on arXiv" on versioned abstract pages (`PaperView.swift:100`); Feed and search abstract links (unversioned, `FeedTableView.swift:222,279`, `RootView.swift:1649`) | — | User navigation | — | — |
| Same, via our server | Search and Feed through `discover` (`BackendClient.swift:530-533,606`); Add through library commands, which trigger S1/S2 | — | — | — | — |
| Same, PDFs | `DevicePDFFetcher.swift` downloads **publisher and web** PDFs (never arXiv). The experimental on-device PDF route reads PDFs the reader supplied | — | — | — | — |
| Browser `app.gradstep.ai`: `apps/web/src/lib/arxiv-reader.ts:11,29,36-60` | `arxiv.org/html/<id>v<n>` and assets | Browsers cannot set User-Agent; requests carry `Origin: https://app.gradstep.ai`, `credentials:'omit'`, `referrerPolicy:'no-referrer'` | Same policy per tab (3 s, 4 assets, `Retry-After`) | `cache:'no-store'`, and **bundles are held in memory per tab** (`reader-paper.ts:30`), so a reload or new tab fetches the paper again | Exact versions |
| Browser, links and PDF | "Open PDF" opens `arxiv.org/pdf/<id>v<n>` in a new tab (`LibraryActions.tsx:118`); abstract links (`FeedResults.tsx:19`, `reader/frame.ts:169`) | — | User navigation | — | — |
| Browser via our server | Feed and search through `discover` (`lib/feed.ts:111`) | — | — | — | — |
| CSP | `connect-src https://arxiv.org <backend> <auth>` (`scripts/deploy-web.mjs:64`); no DataCite or OpenAlex | — | — | — | — |

## 4. Compliance assessment

Ratings: **Green** = consistent with the terms as written. **Amber** = defensible but needs a change or confirmation.
**Red** = conflicts with a clause as written, or a required item is missing.

| # | Clause and topic | Rating | Reasoning |
|---|---|---|---|
| C1 | Retrieve, store, transform and share descriptive metadata (catalog, Feed pool, tags, podcast catalog metadata shown to other users) | **Green** | Explicitly allowed and CC0; abstracts are listed as metadata. Applies equally to metadata obtained from DataCite (CC0) |
| C2 | Legacy API rate limit: 1 request per 3 s and a single connection, across all machines | **Amber** | The server gate spaces request starts by 3 s, but with 15–60 s timeouts **connections can overlap**, which is not "a single connection at a time". Developer scripts sit outside the gate. Search bursts fall back to OpenAlex instead of waiting (good) |
| C3 | Cache results; the same query no more than once a day | **Amber** | The pool uses conditional GET (good). Live RSS chips (S4) and searches (S5) are uncached per user. Metadata is fetched once per paper (good) |
| C4 | Identify yourself; support may need a name and email | **Amber** | Server User-Agents carry the old name and an `.invalid` or missing contact. Native requests use the default UA |
| C5 | Track API changes | **Amber** | No monitoring of the arXiv API group or News. The 2026-10-14 OAI behaviour change was found by failing imports |
| C6 | Store and serve e-prints only with permission or licence: the **current device reader** | **Green** | HTML is fetched and kept on the user's device for their own reading; our servers neither fetch nor hold it |
| C7 | Same clause: **legacy server bundles and originals for default-licence papers (`legacy_private`)** | **Red** | Our servers store the converted content and serve it to the account as a fallback. Encryption or per-account access is not a licence (see the 2026-10-09 rights review) |
| C8 | Same clause: **private podcast device sources** (full paper text stored until account deletion) **and private episodes** (derived audio and verbatim transcript quotes served from our storage) | **Red, pending counsel** | Same clause; the device-only fetch does not change it. This is content storage on our servers for default-licence papers, and the derived audio is "other content" served from them. Counsel may find the per-user, user-requested transformation acceptable, but the terms as written do not cover it |
| C9 | Same clause: shared CC BY/CC0 conversions and the **shared podcast catalog** | **Green (conditional)** | The licence permits it. Attribution, licence link, change and AI-adaptation notice and the exact version must be visible on every surface (designed in `PAPER_PODCASTS.md`; verify the UI). CC BY-SA and NC are correctly excluded. The licence must be the exact version's: OAI and DataCite describe the latest version only |
| C10 | Chat sends the full paper text and figures per request; relayed, not stored | **Amber (low)** | Not "store and serve"; it is processing at the user's request for personal use. But a third party (Anthropic, DeepSeek for episodes) processes and may retain the content. Keep it transient and disclosed; counsel can confirm |
| C11 | Direct users to arXiv; link to the abstract page | **Green** | Versioned abstract links on catalog rows and the paper header; Feed and search use the unversioned abstract page. The reader does not show the version's licence (minor; add it) |
| C12 | Required acknowledgement: "Thank you to arXiv for use of its open access interoperability." For products, add the disclaimer sentence | **Red** | Missing in the native app (the Acknowledgements entry `RootView.swift:1686` is a description, not the statement), the browser and the landing page drafts |
| C13 | No endorsement; arXiv name, logo, colours and web addresses only to acknowledge API or data use | **Amber** | No logo and no arXiv-like product name (good). The UI and copy use "arXiv" as a feature label ("arXiv" search segment, "Searching arXiv…", "Available on arXiv"); these are factual source references but sit near the guideline's limit. The landing page is factual. The App Store listing does not exist in the repository yet. Add the disclaimer, avoid "arXiv" in feature names, headlines or keywords, and never use arXiv colours or marks |
| C14 | Commercial projects: review the documentation, brand guide, and consider affiliate | **Amber** | This document is the review. Affiliate or sponsor is optional (support). Decide and record |
| C15 | Rate limits "apply to all machines under your control"; do not add machines to overcome them | **Amber, ambiguous** | Today the servers are the aggregate. After a device move, each install calls arXiv. Whether an app's installed base counts as "machines under your control" is not defined. A design that moves calls to devices to escape the 3 s gate could be read as the prohibited pattern; one where every call is user-initiated, cached and paced per device is the ordinary mobile-client pattern. **Ask arXiv** (open question 2) |
| C16 | Robots and automated downloads (HTML and PDF on devices) | **Green / Amber** | User-opened papers are interactive use. Automatic download of every newly imported paper is prefetching. It is limited to the user's own additions and paced, but 403 should stop it for the day and it should never run as a background batch |
| C17 | Versions and licences per version | **Green** | Exact versioned HTML. The current server evidence refuses to reuse the latest version's licence for older revisions (`arxiv.ts:277-281`) |
| C18 | No full-text index or redistribution of e-prints | **Green** | No server full-text index; Tavily and Anthropic search are third parties |
| C19 | Someone else's credentials | **Green** | None used |
| C20 | Product copy accuracy (privacy page "servers look up … from arXiv"; How it works) | **Amber** | Accurate today; it must change with this design. The Acknowledgements copy is stale: "Mathpix … used on the server", "converted privately for you" |
| C21 | App Store Review 5.2.2 (permission for third-party content) | **Amber** | Not an arXiv clause, but App Review may ask. Keep the arXiv support reply (AH-211376) and this audit as the record that the terms allow a reader and discovery client that sends users to arXiv |

### 4.1 Does "devices only" fix the terms issue?

1. **Server metadata use was never the problem the terms prohibit.** It is an explicitly allowed use, subject to rate
   limits, caching and acknowledgement. Removing it is a reasonable risk-reduction and positioning choice. It also
   makes the boundary easy to state and to verify.
2. **Content storage is the prohibited thing, wherever the bytes came from.** C7 and C8 stay red after the device
   move unless the content stops being stored or served on our servers, or a licence or counsel covers it.
3. **The device move has its own risk (C15).** It must not look like routing around the aggregate rate limit. Each
   device should act like a person using arXiv: user-initiated, paced, cached, and never polling in the background
   at scale. Where shared data is needed, it should come from a non-arXiv source arXiv itself recommends (DataCite)
   rather than from N devices hitting the legacy API.

## 5. Device-only architecture

### 5.1 Boundary

**Governing rule (owner, 2026-10-15): each device calls arXiv only as that user's own independent agent.**

1. **User-triggered.** Every arXiv request is triggered by that user's action on that device: opening or downloading
   a paper, adding one, or searching. The server never assigns fetches, crawl lists or work to devices. A server flag
   says only whether a device should *send* what it already read, never what to fetch.
2. **What a device fetches stays that user's.** No arXiv content goes to our server for others. Device-submitted
   metadata is for that user's library only, and becomes shared data only through a DataCite match or operator review
   (§5.4, step 5).
3. **Per-device pacing.** One request at a time, about 3 s apart, cached, backing off on 429 and 503, and stopping
   for 24 h after a 403 (§5.9).
4. **Honest identification.** Native requests carry a Gradstep User-Agent (§5.9). The browser cannot set one.
5. **No background harvesting.** Nothing fetches papers the user didn't choose. Automatic download covers only papers
   the user added (on this or another of their devices), and requests nothing beyond the paper itself.

How the clients honour it (rollout steps 1–3, §6.0):
- **Rule 1.** Metadata is read from the page the device already downloaded for a paper the person opened or
  downloaded. The export API lookup for a paper without HTML runs only when the person opens or downloads that paper
  on this device (`ReaderModel.prepareOnDevice(_:automatic:)`), never from an automatic download. The `source_metadata`
  capability carries no paper list.
- **Rule 2.** `v1_submit_source_metadata` writes only the submitting account's import row. `worker_catalog_promote`
  (DataCite evidence must match) and `admin_catalog_promote` (owner with MFA, a reason, audited) are the only ways
  into `catalog_metadata`.
- **Rule 3.** Native: `ArxivRequestPacer` for the export API (serial, 3 s apart, the longer of Retry-After and a
  back-off doubling from 60 s to 24 h, persisted; answers cached per version) and `ArxivDeviceRefusal`: a 403 from
  any arXiv host stops the reader's page and image requests and the export API for 24 h, across relaunches. Browser:
  the reader's existing pacing plus the same 24 h stop after a 403, kept in `localStorage`
  (`gradstep.arxiv.refused-until`). A paper's page keeps the reader's existing policy: documents 3 s apart, then that
  page's figures at most 4 at a time, as a browser loads one page (open question 10).
- **Rule 4.** Every native arXiv request, the reader's pages and images and the export API alike, sends
  `Gradstep/<version> (<platform>; +https://gradstep.ai; mailto:hello@gradstep.ai)` (`ArxivAcquisitionPolicy.userAgent`).
- **Rule 5.** Apart from the automatic download of papers the user added, no client code fetches anything in the
  background. The browser makes no arXiv request for metadata at all.

- **Invariant:** no Gradstep production server, function, worker, scheduled job or database extension sends a request
  to any `*.arxiv.org` host. This includes `arxiv.org`, `www`, `export`, `oaipmh`, `rss` and `static`.
- **Devices** (native apps and the browser) are the only Gradstep software that contacts arXiv. Every request is
  initiated by the person's action on that device: opening or downloading a paper, adding one, or searching.
  Requests are paced per device, cached, and send a descriptive identification where the platform allows it.
- **Server inputs from devices are untrusted.** A device can send identifiers and metadata it read. The server
  validates their form and bounds, keeps them account-scoped, and never promotes them into shared or global data or
  rights decisions without independent verification (DataCite, if approved) or operator review.
- **Shared data that needs metadata** comes from DataCite (if approved) or from operator-reviewed promotion. This
  covers the Feed pool, search enrichment and licence corroboration for shared podcasts. It never comes from arXiv
  via the server, and never from unverified device input.
- Content rules are unchanged: PDFs and HTML stay on the device. The server-held content items C7 and C8 are handled
  separately in §5.11.

### 5.2 Replacement for each server call

| Current | Replacement | Client(s) | Endpoint used by the device | Payload to our server | Server checks |
|---|---|---|---|---|---|
| **S1 and S2**: metadata stage (Atom API and OAI-PMH) on every import | (a) **Extract metadata from the arXiv HTML the device already downloads** when it prepares the paper; zero extra requests. (b) Paper with no HTML: native calls the export API `id_list` once (serial, paced, cached forever per version) when the person opens or downloads it on that device. The browser sends nothing; its DataCite lookup (`/dois/10.48550/arXiv.<id>`, CORS) waits for the owner's DataCite decision. (c) Optional: a server-side DataCite lookup verifies the record and fills it for old builds | Native and browser | `arxiv.org/html/<id>v<n>` (already fetched); `export.arxiv.org/api/query?id_list=` (native only); `api.datacite.org` (browser, or server) | `source_metadata` (§5.3) submitted afterwards with `v1_submit_source_metadata` | §5.4. Stored per account; `rights_mode` is decided only from verified evidence |
| **S3**: Feed pool from arXiv RSS | **Recommended:** repoint the pool refresh to DataCite (`provider-id=arxiv`, the 12 pool categories, `created` since the last watermark, `page[size]=1000`, a UA with `mailto`), about 3–10 requests per run, every 2–6 h. Owner direction (2026-10-15): the shared pool uses DataCite server-side, once for everyone. The strict alternative (every native device fetching `rss.arxiv.org` daily) is excluded by §5.1 rules 1 and 5 | Server (DataCite) or devices | DataCite; or RSS (native only, no CORS) | Strict alternative only: nothing, or the IDs shown and interacted with | Recommended path: the same strict parse and bounds as `parsePoolRSS`, on DataCite JSON |
| **S4**: live RSS per Feed chip | Serve every chip from the pool. A category outside the pool ("More topics") uses one DataCite query per category, cached on the server for 1 h; strict alternative: native RSS | Server or native | DataCite or RSS | — | Category against a fixed taxonomy table |
| **S5**: search via the export API | **Recommended:** the server keeps OpenAlex ranking (not arXiv) and enriches the ranked IDs with one batch DataCite request (`/dois?ids=10.48550/arXiv.a,…`) for version, subjects and abstract. The response contract is unchanged, so old builds keep working. **Owner direction (2026-10-15), behind a flag:** search on the device, one query per search the person submits: native asks arXiv's API (paced, cached), the browser asks DataCite (CORS); §5.6. The server path stays for older builds | Devices (flagged); server for older builds | DataCite and OpenAlex | — | — |
| **S6**: arXiv title search in find-paper (Ingest, add-paper, add-reference) | OpenAlex (as today) then a DataCite title query (`provider-id=arxiv`, `titles.title`) under the same strict `matchPaper` rules; Tavily stays the last fallback | Server | DataCite | — | — |
| **S7**: `id_list` for IDs from Tavily | DataCite batch `ids=` lookup for the arXiv DOIs | Server | DataCite | — | — |
| **S8**: `id_list` for IDs written in a reference | DataCite batch `ids=` lookup, with title-in-reference matching as now | Server | DataCite | — | — |
| Licence evidence (S2's second role) for shared reuse and podcast seeds | DataCite `rightsList` for the latest version, plus the device's HTML `#license-tr` for the exact version, plus **operator review** before anything is shared (seeds are already review-gated) | Server and operator | DataCite; abstract page viewed by the operator | — | Shared reuse requires DataCite or operator evidence that matches the exact version |
| Edge `paper-worker` | Undeploy; Cloud Run is the worker of record | — | — | — | — |

If DataCite is **not** approved for servers (open question 1), the server-side rows above fall back as follows:
- Search moves to devices (browser: OpenAlex plus DataCite; native: OpenAlex plus the arXiv API).
- Ingest and reference lookups return OpenAlex-only matches.
- The Feed uses the strict device alternative.
- Shared licence evidence comes from operator review only.

### 5.3 Device metadata contract

Submitted for an existing source membership with `v1_submit_source_metadata` (there is no `v6_begin_import`; the Add
paths are unchanged):

```
source_metadata: {
  format: "arxiv-source-metadata-v1",
  source_id: "2305.18290", revision: 3,
  origin: "arxiv_html" | "arxiv_api" | "datacite",   // where the device read it
  title: string (1–2000), authors: string[] (1–512, each ≤ 256),
  abstract: string | null (≤ 24,000),
  categories: string[] (primary first; ≤ 64),          // HTML gives the primary only; API and DataCite give all
  license_uri: string | null,                          // mapped from "License: …" or the API/DataCite URI
  version_date: "YYYY-MM-DD" | null,                   // from the HTML watermark, API <updated>, or DataCite Submitted vN
  html_available: boolean,
  observed_at: ISO-8601
}
```

- **As implemented (step 3):** one extractor, `supabase/functions/_shared/reader/arxiv/source-metadata.ts`, reads the
  HTML and the export API's Atom answer. It is built as its own bundle for JavaScriptCore
  (`apps/apple/ScienceReader/Resources/arxiv-source-metadata.js`, with a `TextEncoder` polyfill) and loads as a lazy
  chunk in the browser, so the reader compiler, its digest and `ARXIV_RENDERER_REVISION` are unchanged. It returns
  `null` rather than a guess when the watermark names another version or there is no title or author.
- Original proposal, superseded by the bundle above: the extractor would have lived in the shared compiler
  (`_shared/reader/arxiv/front-matter.ts`, `authors.ts`), adding the title, authors, abstract and the `#license-tr`
  and `#watermark-tr` text to `ArxivHTMLReader.prepare`.
- Licence text is mapped through a fixed table. Example: "CC BY 4.0" maps to
  `https://creativecommons.org/licenses/by/4.0/`, and "arXiv.org perpetual non-exclusive license" maps to
  `http://arxiv.org/licenses/nonexclusive-distrib/1.0/`. Unknown text maps to `null`, never a guess.
- When a device later re-prepares a newer revision, it submits a new record for that revision.

### 5.4 Server validation and trust boundary (no arXiv call possible)

1. **Form.**
   - `arxivReference` grammar; revision 1–9999, matching the import's requested revision when pinned.
   - NFC normalization; control characters refused; the existing catalog bounds (≤ 30 KB JSON).
   - Categories from a fixed taxonomy table (about 155 codes).
   - Licence URI from a fixed table of arXiv's licence URIs, including historical ones.
   - Dates are valid and not in the future.
2. **Internal consistency.** A modern ID's `YYMM` must not be after the version date. The v1 date month should equal
   `YYMM`; a mismatch is flagged, not refused. The revision may not go backwards for this account.
3. **Scope.**
   - As implemented: rate rule `source-metadata` at 120 per account and 2,000 for the environment per hour;
     promotion provenance in a companion table, `catalog_metadata_provenance`, because catalog rows are immutable
     records; showing device records in the library is step 5 (older builds' metadata decoders are strict).
   - Store in account-scoped columns on the membership (`import_requests`), never in shared `catalog_metadata`, the
     Feed pool or podcast catalog rows.
   - Only the submitting account sees it; other accounts with the same paper see their own record or the verified
     shared one.
4. **Abuse limits.**
   - A `worker_consume_request` route, `source-metadata` (e.g. 120 per hour and 1,000 per day per account).
   - Payload size bounds; at most one current record per membership and revision (last write wins, with bounded
     history).
5. **Promotion to shared.** Only through:
   - (a) a server DataCite match: normalized title equal, first-author family names equal, DataCite version at least
     the revision; or
   - (b) operator approval.

   A promoted row records `origin`, verifier and an evidence digest.
6. **Rights.** Device-supplied licence values are display-only. Shared reuse (podcast seeds, any shared asset)
   requires server-side DataCite evidence for the exact version or operator review. It is never decided by a device
   value.
7. **Rendering.** Device text is treated as untrusted on every surface (already the case for metadata), including
   the admin site.

### 5.5 Feed

- **Owner direction (2026-10-15): the DataCite pool, server-side, once for everyone.** `feed-refresh` gains a
  DataCite source (step 4). **Built (owner, 2026-10-16: "Ok"); migration 075 switches it on, see §6.0.2:** the
  `feed_source` switch and the `datacite-ml` source row.
  - Mapping from DataCite: `doi` suffix → `source_id`; `version` → revision; `creators` → authors (given name plus
    family name); `descriptions[Abstract]` → abstract (first 2,000 characters); `subjects` with scheme `arXiv` →
    codes, via the trailing `(cs.LG)`.
  - `created` → announcement day: the UTC date. (Built that way, not in ET: arXiv registers an announcement's DOIs
    at about 03:05 UTC, three hours after the 20:00 ET announcement, and the RSS dates that announcement by the
    next day, which is the UTC date; converting to ET would date it a day early.)
  - `new` or `cross`: `new` when the first subject (the primary) is in the pool's categories, otherwise `cross`.
  - The lag is about 3 h after arXiv's announcement, versus about 2.5 h today with the 2-hourly RSS check.
  - Ranking, topics, Hugging Face popularity and serving are unchanged. The browser Feed needs no change.
- **Strict device alternative (excluded).** Scheduled fetches by every device break §5.1 rules 1 and 5; kept for the
  record.
  - Native devices fetch the combined RSS for the reader's categories once per daily update. Each device adds a
    random 0–60 min delay after 00:00 ET and sends `If-None-Match`; the response is cached to its
    `Cache-Control: max-age`.
  - Ranking happens on the device using the For you features. The server already computes these from server-visible
    library metadata, and could send the interest profile (topics, authors, categories) instead of ranked rows.
  - The browser reads DataCite directly. This adds about one RSS request per device per day; at 1,000 devices that is
    roughly 1,000 requests a day, concentrated after the update.
  - It does not work for the browser without DataCite, and it removes the shared pool's ranking quality signals.
    Not recommended now.

### 5.6 Search, Add, references and Ingest

- **Add by arXiv ID or link:** unchanged on the server: no lookup and a placeholder title. The device prepares the
  paper (automatic download is on by default) and submits `source_metadata`; the library shows the device record.
- **Add by DOI, link or text; Add to library on a reference; Ingest:** the server uses OpenAlex, Crossref and
  DataCite, never arXiv. The found arXiv ID is queued as today.
- **Search without OpenAlex (owner decision, 2026-10-15: V1 without OpenAlex if the experience is roughly the same;
  built in step 4, switched off; §5.6.1 has the evaluation).** The device searches for the person.
  - Switches (migration 072): `pipeline_policy.device_search_enabled` (default `false`), returned as
    `v1_reader_capabilities.device_search: {enabled, format: "device-search-v1"}`; off, or an unknown format, keeps
    the server search. `pipeline_policy.openalex_enabled` (default `true`) keeps OpenAlex in the server's own search
    (older builds) and its DOI lookups; off, the server searches DataCite with the same code and names a DOI through
    Crossref alone (`identify.ts`).
  - One shared module, `_shared/paper-search.ts`, builds the requests, decodes both answers into today's result rows
    (the native and browser decoders are unchanged) and orders them. Native runs it in JavaScriptCore (the
    `arxiv-source-metadata.js` bundle), the browser and the server import it.
  - Native (`DeviceSearch`): only when the person submits a search. Requests, in order: arXiv's relevance over all the
    words (`max_results` 50), DataCite's ten most cited matches, then arXiv's three oldest titles with the phrase
    (2–8 words); DataCite's near spellings (`~1`) only when arXiv's first answer lists fewer than 5 (arXiv's API has
    no near-spelling search; tuning 1, §5.6.1). arXiv requests go through the device's single export API queue
    (`ArxivRequestPacer`, `ArxivDeviceRefusal`, the Gradstep User-Agent); DataCite requests carry the same User-Agent
    and are not arXiv's to pace. Each query's results are kept on the device for 24 h (Caches, never synced). An arXiv
    ID or link is one `id_list` request.
  - Browser (`lib/device-search.ts`): DataCite (`provider-id=arxiv`, sparse fields, `mailto`, no credentials): the same
    relevance, most cited and phrase requests together, near spellings when the first is short; one search at a time;
    each query kept in the tab for 24 h. `connect-src` lists `https://api.datacite.org`.
  - Browser page (owner, 2026-10-15: "If no downside shoot for parity"; `ui/PaperSearch.tsx`): the native Library
    search. While searching, the Library / arXiv switch sits under the top-bar field with Cancel (native's label kept;
    the "arXiv" label question stays open for both, §8 question 9). The arXiv side searches on Enter, or on switching
    with a query not yet searched; its states are native's (Find papers, Searching arXiv…, Couldn't search with Try
    again, No papers found); results are the Feed's rows with Newest (the default) or Relevance order, Add, the
    Downloading…/Preparing… percent after Add, and In library, which opens the paper. `/` focuses the field, Escape
    clears it and then leaves the search. With `device_search` off the browser asks the server's `discover?q=`, as the
    native app does.
  - The order, every factor a plain multiplier (`explainSearch` names them): the index's relevance order
    (1 / (1 + rank / 10)); title words (+0.5 × the share of the query's words in the title, +0.5 for the phrase);
    machine-learning categories ×1.15, outside computing and statistics ×0.7; an exact title or main title ×3; the
    earliest paper titled with the phrase ×2 when its main title is the phrase, ×1.5 when the phrase has 3+ words and
    the paper is in an ML category; well known (tuning 2): DataCite's `citationCount` (other DataCite records citing
    the paper; most arXiv papers have none, landmarks a few to dozens). A paper cited at least twice and about the
    query (its title has all the query's distinctive words, or half of them and its abstract has the query's phrase)
    gains 1 + log2(1 + citations) / 4, and one the word matching missed joins from the most cited list at its place
    there.
  - The query never reaches our server. Adding a result is today's Add. Nothing is prefetched for results the person
    has not opened.

### 5.6.1 Search evaluation (2026-10-15)

`node scripts/search-eval.mjs` ran 32 queries (16 topic phrases, a 2-word and two long queries, 3 authors, 5 exact
titles, an ID and an arXiv link, 3 misspellings) through today's server search (OpenAlex ranking, arXiv metadata, the
same functions), the native device search and the browser search, with live requests from a developer machine
(226 cached answers, arXiv paced at 3.2 s, plus nine one-off probes of query syntax). Results, the HTML side by side and the cache are in `.artifacts/search-eval/`. Claude
judged each engine's top 5 (relevant 1, partly 0.5, not 0; `scripts/search-eval-judgments.json`); "expected" is a canonical paper named
before the run for 20 of the queries.

| | Today (OpenAlex + arXiv) | Native (arXiv API) | Browser (DataCite) |
|---|---|---|---|
| Relevance of the top 5 | 0.48 | 0.69 | 0.79 |
| A relevant paper in the top 3 | 24/32 | 29/32 | 32/32 |
| Expected paper in the top 10 / first | 12/20 / 8/20 | 13/20 / 12/20 | 13/20 / 13/20 |
| Overlap with today's top 10 (mean) | — | 1.1 | 1.3 |
| Median time to results | 4.3 s | 3.3 s | 1.6 s |
| By kind (relevance of the top 5): topic / author / misspelling | 0.67 / 0.17 / 0 | 0.83 / 1.0 / 0.10 | 0.94 / 0.97 / 0.57 |

- **Better without OpenAlex:** authors (OpenAlex returned unrelated famous papers for "Tri Dao", "Percy Liang", "Yann
  LeCun"); arXiv links (today's server sends "https://arxiv.org/abs/1706.03762" to OpenAlex as words and replaces the
  ID lookup with unrelated papers); specific topics where OpenAlex's "most cited" list pulls in off-topic classics
  ("test time compute scaling" → PLINK and YOLOv4; "in-context learning" → DeepLab; "state space models" → word2vec);
  the originals of named methods (chain of thought, NeRF, RAG, DPO, LoRA) through the earliest-title rule; and
  latency.
- **Worse without OpenAlex:** broad two-word topics whose landmark paper isn't titled with the phrase: "contrastive
  learning" (SimCLR and MoCo only through OpenAlex), "mamba ssm" (Mamba itself), "reinforcement learning from human
  feedback" (InstructGPT, Christiano et al.), "speculative decoding" (Leviathan et al.; Xia et al. leads everywhere).
  The device lists are newer and on-topic; today's lean to cited classics. Overlap is low (about 1 in 10) because
  of that, not because either list is off-topic.
- **Misspellings:** arXiv's API has no near-spelling search (a measured `~` query returns nothing), so the native
  broad (`OR`) answer is poor (0.10); DataCite's `~1` finds the right papers (0.57; "atention is all you ned" →
  Attention Is All You Need first). Today's search returns nothing or unrelated papers.
- **Exact titles and IDs:** first on every engine.
- **Verdict (first run):** roughly the same experience, better for authors, links, specific topics and speed, worse
  for the landmark paper of a broad two-word topic.

**Tuning (same day, same queries and judgments; papers the tunings newly surfaced were judged by the same rules).**
(1) Native: when arXiv finds fewer than 5, ask DataCite's near spellings instead of arXiv's any-word search.
(2) Well known: DataCite's `citationCount`, through a most-cited request and rule 6 above. `--without-known` gives the
ordering with (1) alone.

| Relevance of the top 5, by kind | topic | short | long | author | title | id | misspelling | all | expected top 10 / first | time |
|---|---|---|---|---|---|---|---|---|---|---|
| Today (OpenAlex) | 0.67 | 0.70 | 0.45 | 0.17 | 0.28 | 0.50 | 0.00 | 0.48 | 12/20 / 8/20 | 4.3 s |
| Native, before | 0.83 | 0.70 | 0.85 | 1.00 | 0.26 | 1.00 | 0.10 | 0.69 | 13/20 / 12/20 | 3.3 s |
| Native, near spellings | 0.83 | 0.70 | 0.85 | 1.00 | 0.36 | 1.00 | 0.57 | 0.75 | 14/20 / 13/20 | 3.3 s |
| Native, both | 0.84 | 0.70 | 0.85 | 1.00 | 0.36 | 1.00 | 0.57 | 0.76 | 17/20 / 13/20 | 3.3 s |
| Browser, before | 0.94 | 0.60 | 0.65 | 0.97 | 0.38 | 1.00 | 0.57 | 0.79 | 13/20 / 13/20 | 1.6 s |
| Browser, both | 0.93 | 0.60 | 0.65 | 0.97 | 0.38 | 1.00 | 0.57 | 0.79 | 16/20 / 13/20 | 0.7 s |

- Near spellings lift native misspellings from 0.10 to 0.57. The title score rises because, for the long FlashAttention
  title, they replace arXiv's any-word results with the paper alone (the score counts the papers shown).
- Well known brings the landmark into the top 10 for "vision transformer" (ViT, second on both), "state space models"
  (Mamba) and "reinforcement learning from human feedback" (InstructGPT; Christiano et al. stays out: its title lacks
  "feedback" and its abstract the phrase), and 3D Gaussian Splatting for "neural radiance fields". Other kinds are
  unchanged; topic relevance moves by 0.01 either way. One query got worse: "contrastive learning" (0.80 → 0.70 on
  both engines; moderately cited, partly relevant papers rise above it in the browser's top 3).
- The browser's time fell to 0.7 s because its requests now go together; native's stays 3.3 s (two arXiv requests
  3 s apart). Kept: both tunings. Not done: showing native results before the phrase answer.

### 5.7 Tags

- Tagging (`tags.ts`, Haiku over title and abstract) keeps working for shared, promoted metadata.
- For unverified device metadata, tag from the categories only (no model), or run per-account classification
  counted against that account's allowance. Re-tag on promotion.
- No change for papers whose metadata already came from S1 before the cutover.

### 5.8 Podcasts

- **Shared catalog:** keeps CC BY 4.0 and CC0 only. Existing approvals and pins stay.
- **New seeds:** the operator's own device prepares the paper and uploads the device-source text, as private
  episodes already do. Licence evidence is DataCite `rightsList` plus the operator viewing the versioned abstract
  page. Publication stays review-gated.
- `worker_podcast_seed_candidates` needs a candidate source other than `catalog_asset_approvals` from arXivRaw. It
  can use DataCite-verified CC BY and CC0 rows from the Feed pool.
- **Private episodes:** see §5.11; their content storage is a separate decision.

### 5.9 Device pacing, identification, caching and offline use

- **Legacy APIs (export API, RSS, OAI) from a device:**
  - One serial queue per device with at least 3 s between request starts and one connection at a time.
  - Only on the person's own action on that device (§5.1); never background polling.
- **HTML and PDF:** keep the current policy: 3 s between documents and at most 4 concurrent assets of one page, like
  a browser loading one page.
- **Errors:** **403 handling** (built in step 3 on both clients, §5.1 rule 3): stop all arXiv requests from this
  device for 24 h, say so plainly, and never retry in rapid succession (the robots page treats that as an attack). On
  429 or 503, honour `Retry-After`, with a 60 s minimum and exponential backoff to 24 h.
- **Automatic download:** requests nothing beyond the paper itself (no export API lookup; implemented). Only papers
  this account added, one paper at a time, and paused while the device is backing off.
- **Identification:**
  - Native: set `User-Agent: Gradstep/<version> (<platform>; +https://gradstep.ai; mailto:hello@gradstep.ai)` on
    arXiv and DataCite requests. It identifies the app and carries no user identifier, and DataCite moves identified
    requests to the 1,000 per 5 min tier.
  - Browser: the User-Agent cannot be set (a forbidden header). The `Origin` identifies the app. DataCite and
    OpenAlex accept a `mailto=` query parameter.
- **Caching:**
  - API `id_list` results are immutable per version: cache indefinitely.
  - Search results: 24 h per normalized query, as the API manual asks.
  - RSS: honour `Cache-Control` and `ETag`.
  - Native already persists verified bundles. **The browser should persist verified bundles keyed by exact version**
    (IndexedDB or the Cache API, under the browser storage designs). Today every reload re-fetches the HTML and
    images. This belongs to the `readerCopies` store of `BROWSER_OFFLINE_STORAGE.md`, not to steps 1–3.
- **Offline:** library metadata syncs from our server, so device-submitted records reach the user's other devices
  without new arXiv requests. Prepared papers stay readable offline as today.
- **Aggregate estimate at 1,000 active readers**, recommended design: about 2 legacy API calls per native search
  (only if search moves to devices) and about 1 for each Add of a paper without HTML. That is a few thousand a day,
  about 0.05 per second on average and below one per 3 s even in aggregate, with no RSS fan-out. This figure helps
  when writing to arXiv about C15.

### 5.10 DataCite evaluation

- **For it:**
  - Named by arXiv support as a metadata source.
  - Not arXiv-operated, so the owner's invariant holds.
  - The records are deposited by arXiv: title, authors, abstract, subjects, licence URI (SPDX-tagged), version and
    per-version dates.
  - CC0 data with no authentication.
  - CORS-enabled, so the browser can use it.
  - Batch lookups and category and date windows are available.
  - Generous per-IP limits, with 429 and backoff.
- **Against it:**
  - About a 3 h lag behind arXiv announcements.
  - Licence and version describe the latest version only, as with OAI-PMH, so the exact older version's licence
    still comes from the HTML or a person.
  - Relevance search is weaker than OpenAlex; keep OpenAlex for ranking.
  - Another dependency with its own outage risk.
  - DataCite's own name and marks are excluded from its CC0 waiver; we would not use them.
- **Owner position (2026-10-15):** devices make every arXiv request. The shared Feed pool uses DataCite server-side,
  once for everyone, and browser search uses DataCite directly. Later the same day the owner accepted server and
  third-party calls that fit terms and scale, and asked for V1 without OpenAlex if the experience is roughly the same.
  Built and switched off: browser search and the server's search for older builds use DataCite through
  `_shared/datacite.ts` and `paper-search.ts` (§5.6); the browser's `connect-src` lists DataCite. The Feed pool's
  DataCite source and server-side verification for promotion are not built yet.
- **Recommendation:**
  - Use DataCite **server-side** for shared, global data: the Feed pool, out-of-pool categories, search enrichment,
    reference and Ingest lookups, licence corroboration and verification for promotion.
  - Use **devices** for everything per-user that touches arXiv: content, and the metadata of papers the user adds,
    read from the HTML they already fetched.
  - This honours the owner's preference that devices fetch what they need, keeps old builds working, and avoids N
    devices polling arXiv's legacy APIs.
  - Kaggle (weekly CC0 metadata snapshot) is a possible bulk backfill for verification; it was not evaluated in this
    audit (it needs an account and has its own terms).

### 5.11 What this design does not fix (owner decisions)

- **C7, legacy server content.** Recommended:
  - Stop serving `legacy_private` arXiv bundles; the device HTML reader or the user's own PDF replaces them.
  - Keep `shared` (CC BY/CC0) and web or upload-private delivery.
  - Decide separately on deleting the stored originals and bundles. AGENTS.md says no deletion or data migration is
    implied, so this needs the owner.
- **C8, private podcast sources.** Options:
  - (a) Delete the uploaded text once the episode settles, i.e. ephemeral processing; the privacy page must change
    from "kept until you delete your account".
  - (b) Also keep the audio only until it is downloaded to the device.
  - (c) Restrict private episodes to CC BY and CC0.
  - (d) Keep the current behaviour on counsel's advice.

  Recommend (a) now plus counsel on (b), (c) or (d).

## 6. Rollout plan

Ordered so that every shipped build keeps working at each step. Each step is reversible by its flag.

### 6.0 Implemented so far (steps 1–3, switched off)

Step 0 (copy, server User-Agents, the AH-211376 reply) is separate work. Nothing below is deployed, applied to
staging or switched on.

- **Step 1, guardrails in report mode.** `_shared/egress.ts` (`EGRESS_ARXIV=report|block`, default `report`; logs
  `{event:'arxiv_egress', mode, host, caller, blocked}`, never the path or query; block mode checks every redirect hop)
  is installed in all 18 Edge functions, the Cloud Run pipeline worker (server, run, podcast run), the store verifier
  and the workflow checks job. `scripts/check-arxiv-egress.mjs` scans `supabase/functions`, `services`, `workers`,
  `supabase/migrations`, `infra` and the two workflow job scripts. Allowed markers: `egress-ok: link`, `parse`,
  `namespace` (XML namespaces), `prompt` (model instructions), `tavily-filter` and `device` (URLs only clients
  request). SQL is flagged only inside statements that call `net.http_*` or the `http` extension. Report mode fails
  only on call sites beyond the ratchet `scripts/arxiv-egress-baseline.json`; `--block` fails on any. The baseline
  is 12 lines covering S1–S8: `arxiv.ts` 87 (S1) and 92 (S2); `feed-pool.ts` 31 (S3); `discover.ts` 258 (S4), 36,
  57 and 226 (S5), and 334 and 339 twice (S6); `find-paper.ts` 83 (S7); `reference.ts` 144 (S8). It runs in the fast
  tier.
- **Step 2, server, additive.** Migration `202610150071_device_source_metadata.sql`: `arxiv_categories` (178 codes)
  and `arxiv_licenses` (10 URIs); `pipeline_policy.arxiv_egress` (default `true`) and `source_metadata_enabled`
  (default `false`); the `import_requests.device_metadata*` columns; `catalog_metadata_provenance`; the
  `source-metadata` rate rule; `v1_submit_source_metadata` (refuses `source_metadata_disabled` while the flag is off);
  `worker_catalog_promote` and `admin_catalog_promote`; `v1_reader_capabilities` adds
  `source_metadata: {enabled, format: "arxiv-source-metadata-v1"}`. `_shared/source-metadata.ts` (contract and
  validator) and `_shared/datacite.ts` (present and unused, §5.10).
- **Step 3, clients behind `capabilities.source_metadata`.** The shared extractor (§5.3). Native: the reader hands the
  page it downloaded to `SourceMetadataReporter`; a paper without HTML gets one export API lookup when the person
  opens or downloads it; `ArxivRequestPacer` and `ArxivDeviceRefusal` (§5.1 rule 3). Browser: `observeArxivSources`
  hands each downloaded page to `sourceMetadataReporter`, which loads the extractor only while the capability is on;
  the 24 h stop after a 403. Not in this step: the browser's DataCite lookup (waits for the owner) and browser bundle
  persistence (`readerCopies`).
- **Step 4, search (switched off).** Migration `202610150072_device_search.sql` (`device_search_enabled` false,
  `openalex_enabled` true, `worker_search_policy()` for the functions, `v1_reader_capabilities.device_search`);
  `_shared/paper-search.ts`; native `DeviceSearch` behind `ReaderCapabilities.searchesOnDevice` in
  `ReaderModel.runDiscovery`; browser `lib/device-search.ts` and its page (`ui/PaperSearch.tsx`, the Library / arXiv
  switch, native parity; renamed "ML paper search", owner 2026-10-16); the two tunings of §5.6.1; `discover?q=` searches DataCite and
  `identify.resolveDOI` skips OpenAlex when `openalex_enabled` is false; the browser CSP and the deploy gate list
  `https://api.datacite.org`. Evaluation: §5.6.1 and `scripts/search-eval.mjs`.
- **Active with every flag off** (owner's rules 3 and 4): the 24 h stop after arXiv answers 403, on both clients, and
  the Gradstep User-Agent on the native reader's own requests. Everything else is inert until `source_metadata_enabled`
  is set, apart from the capability check itself: a browser preparing papers asks our server's
  `v1_reader_capabilities` at most once every 10 minutes. The browser's paper search (native parity) is visible with
  every flag off and then searches through the server's `discover?q=`, as the native app does; its CSP lists DataCite,
  which it calls only once `device_search` is on.
- **Design changes from the proposal below.**
  - Provenance is a companion table, not `origin` and `evidence_sha256` columns: `catalog_metadata` rows are immutable.
  - No `v6_begin_import`; devices submit afterwards, and the Add paths are unchanged.
  - The library shows device records from step 5, not step 2.
  - A separate metadata bundle keeps the compiler byte for byte unchanged: the equivalence proof against `d05c813`
    gave 114 sources and 212 runs identical, including 7 identical refusals.
  - The browser has no DataCite fallback yet, and its CSP is unchanged.
  - The egress scan also covers the workflow job scripts and has three more marker reasons.
- **Known issue.** The compiler bundle's build resolves `fflate` through the untracked
  `supabase/functions/node_modules/.deno`, so its freshness check depends on that directory being present.

### 6.0.1 OpenAlex after step 4

With both switches on, search and DOI naming no longer use OpenAlex. What still does, by area:
- **Server code (no switch yet):** `find-paper.ts` (title lookups for Ingest, Add by text and chat's find-paper),
  `reference.ts` (`byDOI` and the title route of Add to library on a reference), `web-source.ts` and
  `metadata-pipeline.ts` (papers without an arXiv copy: `openalex:W…` works, their open-access PDF and metadata),
  `discover.ts` (the switched-off search functions and `openAlexCandidates`, which `identify.ts` and `find-paper.ts`
  share), and comments in `chat.ts`, `anthropic.ts` and `add-reference/index.ts`.
- **Data model:** `openalex:W…` source IDs for web papers in migrations 019, 039 and later, the browser's
  `library.ts` and `paper.ts`, native `PaperAdding.swift`, `LibraryMetadata.swift` and `AddPaperFixture.swift`, the admin
  fixtures, and their tests. These identify stored papers and stay.
- **Copy:** changed with the switch (§6.0.2): native Settings › Acknowledgements names DataCite instead of OpenAlex,
  and the privacy draft says where paper search goes and that the Feed comes from DataCite. Its catalog-details
  sentence still names arXiv, OpenAlex and Crossref, which remains true until steps 5 and 7.
- **Documents:** `PRIVACY_AND_SYNC.md`, `PAPER_PIPELINE.md`, `DECISIONS.md`, `CHAT.md`, `PDF_UPLOADS.md`,
  `LANDING_PAGE.md`, `LEGACY_GAP_AUDIT.md`, `IMPLEMENTATION_STATUS.md`, `TAGS.md`, `PROVIDER_SPENDING.md`,
  `PIPELINE_RELIABILITY.md`, `PERSONALIZED_FEED.md`, `WORKFLOW_CHECKS.md`, the 2026-10-07 credit audit; tooling:
  `scripts/workflow-checks.mjs` (`ingest.jmlr`), `scripts/smoke-web-import.mjs`, `scripts/search-eval.mjs`.

### 6.0.2 Step 4 switched: search on the device, the Feed from DataCite (owner, 2026-10-16)

Owner answers: "5. Search: turn on device-only search, which drops OpenAlex — Sure"; "6. Shared Feed: take it from
DataCite on our servers, so our servers never contact arXiv. New papers show about 3 hours after announcement — Ok";
"10. The 'arXiv' search tab — Call it ML Paper search".

Status when written: built and tested locally (backend, database, browser and Simulator); deploying the functions and
applying 074 and 075 to staging, then the client releases, follow.

- **Migration `202610160074_feed_datacite.sql`** (additive): `pipeline_policy.feed_source` (`arxiv_rss` default,
  `datacite`); `app_private.feed_active_source()` (`datacite-ml` or `arxiv-ml`); `worker_feed_refresh_claim` and the
  cron's `feed_refresh_kick` use the active source's row, and the claim says which (`kind`);
  `worker_search_policy()` adds `feed_source`. The `arxiv-ml` row stays for audit and for switching back.
- **`_shared/feed-datacite.ts`** and `feed-refresh`: one DataCite query for the pool's 12 categories
  (`subjects.subject:"cs.LG" OR …`, `provider-id=arxiv`, newest first), 100 records a page, a second apart, at most
  40 pages and `max_items`; the same pool rows as the RSS (id, revision, title, authors ≤ 12, abstract ≤ 2,000,
  categories ≤ 12, topics, announcement day; `new` when the primary category is in the pool, else `cross`). DataCite
  has no conditional GET for searches, so the source row's `last_modified` holds a mark: a refresh reads records
  created since the last mark (never more than three days back) and moves it to three hours before it ran; nothing
  there is `not_modified`. A live run (2026-10-16 01:36 UTC, 300 items, 3 requests, all to `api.datacite.org`)
  wrote 278 `new` and 22 `cross`, all dated 2026-10-15. Fixtures: `tests/backend/fixtures/feed/` (recorded once).
- **`discover?category=`** for a chip the pool doesn't answer reads the category's newest week from DataCite when
  `feed_source` is `datacite` (arXiv's RSS before).
- **Migration `202610160075_device_search_on.sql`** sets `device_search_enabled = true`, `openalex_enabled = false` and
  `feed_source = 'datacite'`, recorded in `admin_audit_events` (action `search_sources`) against the owner account.
  Apply it after deploying `feed-refresh` and `discover`.
- **Copy:** the Library segment is "ML paper search" (field "Search ML papers"; Mac menu "Search ML Papers"; "Searching
  ML papers…"); Acknowledgements name DataCite ("ML paper search and the shared Feed", CC0) instead of OpenAlex; the
  privacy draft says where paper search goes and where the Feed comes from. How Gradstep works names no paper-search
  provider and is unchanged.

Server arXiv call sites once both migrations are applied (the scan's 12 code sites are unchanged; the baseline is a
code ratchet and these stay as switch-guarded code until step 7):

| # | Site | With the switches set |
|---|---|---|
| S1, S2 | `arxiv.ts:87`, `:92` (metadata stage) | **Still called** for every new pipeline paper; step 5 (`arxiv_egress`) |
| S3 | `feed-pool.ts:31` (pool RSS) | Not called: `feed_source = 'datacite'` (rollback: the switch) |
| S4 | `discover.ts:258` (chip RSS) | Not called: chips read DataCite (the function still uses it to validate the category) |
| S5 | `discover.ts:36`, `:57`, `:226` (server search) | Not called: `openalex_enabled = false` searches DataCite; `scripts/search-eval.mjs` still uses them |
| S6 | `discover.ts:334`, `:339` ×2 (`arxivTitleURLs`) | **Still called** by `find-paper.ts`: chat Ingest, Add by text, a reference's Add to library |
| S7 | `find-paper.ts:83` | **Still called** when the Tavily fallback finds arXiv IDs |
| S8 | `reference.ts:144` | **Still called** for a reference that names arXiv IDs |

DOI naming (`identify.resolveDOI`) uses Crossref alone with `openalex_enabled` off; `find-paper.ts` and
`reference.ts` still use OpenAlex for titles (§6.0.1). The egress guard stays in report mode until S1, S2 and S6–S8
are gone.

### 6.1 Steps and tests

0. **Copy and contact (no backend change).**
   - Add the acknowledgement and disclaimer (§7) to the native Settings › Acknowledgements and How Gradstep works,
     the browser's How Gradstep works, the landing-page footer and the privacy page. Fix the stale Acknowledgements
     copy.
   - Fix the server User-Agents: `Gradstep/<version> (+https://gradstep.ai; mailto:hello@gradstep.ai)`.
   - Reply on AH-211376 with the questions in §8.
   - *Tests:* a fast test that the statement string appears in both clients' about surfaces and on the site; a unit
     test of the UA constant. Native UI snapshot is opt-in.
1. **Guardrails in report mode.**
   - `scripts/check-arxiv-egress.mjs` is a static scan of `supabase/functions/**`, `services/**`, `workers/**`,
     `supabase/migrations/**` and `infra/**` for arXiv hostnames. Allowed only: link-building string literals marked
     `// egress-ok: link`, input-parsing host allow-lists, and the Tavily domain filter. It runs in `npm test` and
     prints today's eight call sites as the expected baseline.
   - `_shared/egress.ts` wraps `globalThis.fetch` in every server entry point (Edge `Deno.serve` modules, the Cloud
     Run worker thread and server, the workflow job).
     - It refuses `*.arxiv.org` on the first request and on every manual redirect hop.
     - It logs `{event:'arxiv_egress', mode, host, caller}` and increments a counter.
     - Mode comes from the `EGRESS_ARXIV=report|block` env var; it starts at `report`.
   - *Tests:* fast unit tests for the scanner (fixtures with allowed and forbidden literals) and for the guard (direct
     host, uppercase, trailing dot, IDN, redirect to `export.arxiv.org`, `http:`).
2. **Server, additive** (new migration; flags off).
   - The `source_metadata` columns and RPCs (§6.4), the `source-metadata` rate rule, and the taxonomy and licence
     tables.
   - A DataCite client in `_shared/datacite.ts` with bounded JSON, 429 backoff, `mailto`, and a fixture parser.
   - `pipeline_policy.arxiv_egress` (default `true`).
   - *Tests:*
     - Fast backend: the validator against good and hostile payloads, and the DataCite parser on recorded fixtures
       (2305.18290 CC BY v3; 2610.20611 default licence; a no-abstract record).
     - Database suite (slow, opt-in): account scoping, no write to `catalog_metadata`, promotion only through the
       verifier or operator RPC, rate limit.
3. **Clients** (native build N and a browser deploy, behind the `capabilities.source_metadata` flag the server
   returns).
   - Extract metadata in the shared compiler during prepare and submit it.
   - Native: export API fallback for papers without HTML (serial queue, UA, cache); 403 back-off.
   - Browser: metadata from the page it downloaded. As built, the DataCite fallback for a paper without HTML (CSP
     `connect-src` would add `https://api.datacite.org`) waits for the owner, and persisting verified bundles by
     version moves to the `readerCopies` work.
   - *Tests:* fast compiler tests (the extractor on the pinned corpus HTML: title, authors, abstract, licence,
     watermark; missing infobox → `null`); browser units for the DataCite fallback and pacing; one Simulator journey
     (Add → prepared → device title shown) and one browser fixture journey. Slow and opt-in per `TESTING.md`.
4. **Server read paths off arXiv** (each behind its own flag, staging first).
   - `discover`: search through DataCite alone when `openalex_enabled` is off (built, §5.6; the proposal was OpenAlex
     plus DataCite); chips from the pool, with DataCite for out-of-pool categories (cached 1 h; not built).
   - `find-paper`, `reference` and `identify`: DataCite instead of the export API.
   - Device search (§5.6), flag `device_search_enabled`, off: native export API per submitted search, browser
     DataCite, both through the clients' pacing (built, §6.0). `identify` names DOIs through Crossref alone when
     `openalex_enabled` is off (built).
   - `feed-refresh`: switch to the DataCite source. Keep the RSS source row for audit; `refresh_enabled` stays on.
   - *Tests:* fast contract tests showing `discover` responses are byte-compatible with the current decoder (native
     `Discovery.swift`, browser `feed.ts`). Workflow checks: the deploy suite plus a new `egress.no-arxiv` check that
     calls search, a chip, add-paper (DOI), add-reference and a pool refresh, then reads the egress counter and
     requires zero.
5. **Metadata stage off arXiv.**
   - With `arxiv_egress=false`, the metadata stage never calls S1 or S2.
   - An import with device metadata becomes `source_only` at once.
   - Without it (old builds), the server fills from DataCite if approved; otherwise the import shows the placeholder
     until any of the account's newer devices submits a record.
   - `worker_pipeline_arxiv_slot` returns `reserved:false, code:'arxiv_egress_disabled'` so any forgotten caller
     fails closed.
   - *Tests:* database tests for both paths; the hosted `html.membership` check is updated to submit device metadata.
6. **Enforce.**
   - `EGRESS_ARXIV=block` everywhere; the static scan switches to fail mode in `npm test`, `deploy-staging.py`,
     `deploy-pipeline-worker.py` and `schedule-workflow-checks.py`.
   - The daily hosted `egress.no-arxiv` check is added.
   - Undeploy the Edge `paper-worker`.
7. **Remove dead code and update documents.**
   - Delete `fetchArxiv`, the Atom and OAI parsers, `arxivReuseEvidence`, the RSS parsers, `searchArxiv`,
     `arxivTitleURLs`, `arxivSearchURL(s)`, `arxivIDListURL` and `arxivRecentURL`. Keep `arxivReference` (identity
     parsing).
   - Update DECISIONS, `HTML_FIRST_READER.md` "Acquisition and availability", `PERSONALIZED_FEED.md`,
     `PIPELINE_RELIABILITY.md`, the privacy page ("servers look up catalog details from DataCite, OpenAlex and
     Crossref; your device reads arXiv"), `LANDING_PAGE.md` claims and How Gradstep works.
8. **Separate owner decisions** (§5.11): legacy content serving and retention, and podcast source retention.

### 6.2 Older builds

| Older build behaviour | What happens after the cutover |
|---|---|
| Search and Feed through `discover` | The same response contract, now fed by OpenAlex, DataCite and the pool |
| Add by arXiv ID (library command, no metadata) | Placeholder title, filled by DataCite (if approved) or by the account's newer device. The old build still prepares and reads the paper from arXiv HTML as today |
| Ingest and Add to library on references | Server-side, unchanged contract |
| Podcasts | Unchanged |

Nothing needs a forced update, but builds before the metadata extractor never submit device metadata.

### 6.3 Server code and endpoints to retire

**Functions:** the Edge `paper-worker` deployment (step 6).

**Code paths:**
- `metadata-pipeline.ts`: the arXiv stage (`fetchArxiv`, `arxivWait`, `stageMetadata`'s arXiv branch).
- `arxiv.ts`: `arxivURLs`' atom and raw URLs, `arxivAtomRecord`, `arxivRawRecord`, `arxivReuseEvidence`.
- `feed-pool.ts`: `poolFeedURL` and `parsePoolRSS`, replaced by the DataCite parser.
- `discover.ts`: the arXiv URL builders, `parseArxivRSS`, `parseArxivSearch` and `searchArxiv`.
- `discover/index.ts`: the live RSS and export API branches.
- `find-paper.ts` and `reference.ts`: the arXiv branches.

**Database (kept for history, unused):**
- `worker_pipeline_arxiv_slot`, which fails closed.
- The `arxiv-ml` RSS row in `feed_sources`.
- Existing `catalog_asset_approvals` evidence of format `arXivRaw`.

### 6.4 Migrations and columns (additive; numbers assigned at implementation)

Step 2 shipped as `202610150071_device_source_metadata.sql` with the changes listed in §6.0. Still to come: the
`feed_sources` DataCite row, `catalog_asset_approvals` evidence formats, `device_search_enabled` and the library
projection.


- `app_private.import_requests`:
  - `device_metadata jsonb` (bounded like the catalog);
  - `device_metadata_origin text check in ('arxiv_html','arxiv_api','datacite')`;
  - `device_metadata_sha256 bytea`, `device_metadata_revision int`, `device_metadata_at timestamptz`.
- `library_import_entry` projects `device_metadata` when no verified shared record exists, marked `metadata_origin`.
- RPCs:
  - `v6_begin_import(…, p_metadata jsonb default null)`;
  - `v1_submit_source_metadata(p_import_id, p_metadata, p_expected_revision)`;
  - `worker_catalog_promote(p_import_id, p_datacite_evidence)`;
  - `admin_catalog_promote(…)`.
- `app_private.catalog_metadata`: add `origin text` (`arxiv_atom`, `arxiv_oai` for historical rows; `datacite`,
  `device_verified` and `operator` from now on) and `evidence_sha256`.
- `app_private.pipeline_policy`: add `arxiv_egress boolean not null default true`.
- `app_private.feed_sources`: add the `datacite-arxiv-ml` source; pool rows gain `origin`.
- `app_private.api_rate_rules`: add a `source-metadata` route.
- Two reference tables: `arxiv_categories(code)` and `arxiv_licenses(label, uri)`.
- `catalog_asset_approvals`: allow evidence formats `datacite` and `operator`.

### 6.5 Continuous verification of "no server call to arXiv"

1. **Static:** `check-arxiv-egress.mjs` in `npm test` and in every deploy script (fails the deploy).
2. **Runtime:** the guarded `fetch` in block mode on every server runtime. A blocked attempt is a logged error that
   operators see on the admin Health tab and in Cloud Logging.
3. **Hosted:** the daily `egress.no-arxiv` workflow check exercises every former caller and requires a zero counter.
4. **Review:** any new outbound host in `_shared` needs an entry in the server egress allow-list (OpenAlex, Crossref,
   DataCite, Hugging Face, Tavily, Anthropic, DeepSeek, Google, Apple, Cloudflare DNS, publisher probes), checked by
   the same scanner.
5. **Optional:** route Cloud Run egress through a VPC connector with a deny rule. arXiv's hosting addresses can
   change, so this backs up (2) and does not replace it.

## 7. Product copy and listing changes

- **Required statement on every product surface:** native Settings › Acknowledgements and How Gradstep works; the
  browser's How Gradstep works; the landing-page footer and privacy page. Use the brand guide's product wording:
  > Thank you to arXiv for use of its open access interoperability. This product was not reviewed or approved by, nor
  > does it necessarily express or reflect the policies or opinions of, arXiv.
- **No arXiv logo, colours or lockups** anywhere, including the App Store screenshots and the landing page. Today's
  drafts comply.
- **Name use.** Keep factual references: "arXiv:2305.18290", "View on arXiv", "papers from arXiv". Avoid "arXiv" in
  feature names, headlines, App Store title, subtitle or keywords, and avoid phrasing that implies partnership or
  official status ("the arXiv app", "arXiv reader", "powered by arXiv").
  - The App Store description may say Gradstep "reads papers from arXiv" and must carry the disclaimer sentence or
    link to it.
  - Consider renaming the Library search segment from "arXiv" to "Search papers" (an interaction-preserving label
    change; owner's call).
- **Licence display.** Show the exact version's licence and a versioned abstract link in the reader header for every
  arXiv paper. Shared podcast episodes keep authors, licence link, version and the AI-adaptation notice.
- **Accuracy.**
  - Update the privacy page and How Gradstep works once the servers stop contacting arXiv.
  - Remove "Mathpix … on the server" and "converted privately for you" from Acknowledgements.
  - Do not claim "our servers never store paper text" while podcast device sources are retained (§5.11).

## 8. Open questions for the owner

1. **DataCite on our servers?** It is not arXiv, and arXiv support suggested it. The recommended design uses it for
   the Feed pool, search enrichment, reference lookups and licence corroboration. If no, the strict device-only
   variants apply: device search, device RSS Feed with no browser parity unless the browser uses DataCite, and
   operator-only licence evidence.
2. **Ask arXiv (AH-211376 follow-up):**
   - Do user-initiated requests from installed apps count toward "all of the machines under your control"?
   - Is a per-device 3 s serial queue with caching acceptable?
   - Should the native app's User-Agent identify Gradstep?
   - Is DataCite the preferred source for a commercial reader's shared feed?
3. **Legacy server content (C7).**
   - Stop serving `legacy_private` arXiv bundles now?
   - Delete the stored originals and bundles of default-licence papers? AGENTS.md treats deletion as an owner
     decision.
4. **Private podcast sources (C8).** Ephemeral source text (delete on settlement)? Audio kept only until delivered?
   Restrict to CC BY and CC0? Or counsel review first?
5. **Counsel.** C8 and C10: transient relay of full text to Anthropic or DeepSeek, and derived private audio. Also
   whether factual "arXiv" labels in the UI are within the brand guideline's "acknowledging use of … data" allowance.
6. **Affiliate or sponsor.** Optional per support; decide whether to join, which would also allow "Proud supporter of
   arXiv" and logo use while the affiliation lasts.
7. **Feed lag.** Accept about 3 h after the announcement (DataCite), versus about 2.5 h today?
8. **Developer tooling.** The reader sweep and corpus fetch on the owner's Mac contact arXiv, paced. Keep them, with
   the claim scoped to "production servers", or route sweeps through DataCite plus device-equivalent fetches only?
9. **Label change.** Rename the "arXiv" search segment, per §7?
10. **Reader page loads and rule 3.** The reader requests a paper's page 3 s after the previous one, then that page's
    figures at most 4 at a time, as a browser does. Strictly one request every 3 s would make a 20-figure paper take
    about a minute to open. Keep the page-visit policy for the reader, with rule 3 applied to the APIs?
11. **Browser paper search:** built for parity on the owner's "If no downside shoot for parity" (§5.6); it shows with
    every flag off, through the server's `discover?q=`, as the native app's search does.
12. **Search tuning (§5.6.1).** Done: native near spellings through DataCite, and DataCite citations as the "well known"
    signal. Open: native results before the phrase answer (about 3 s sooner), and whether the "contrastive learning"
    trade is acceptable.

## References in this repository

- [HTML-first reader](HTML_FIRST_READER.md)
- [Paper pipeline](PAPER_PIPELINE.md) and [pipeline reliability](PIPELINE_RELIABILITY.md)
- [Personalized feed](PERSONALIZED_FEED.md)
- [Paper podcasts](PAPER_PODCASTS.md)
- [Chat](CHAT.md)
- [Content hosting review, 2026-10-09](../research/ARXIV_CONTENT_HOSTING_20261009.md)
- [Decisions: commercial arXiv content gate](../DECISIONS.md#commercial-arxiv-content-gate--2026-10-09-owner-review-required)
