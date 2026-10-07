# Product and architecture decisions

Last updated: 2026-10-03. Requirements below come from the current user conversation, not from TextBrain's product specification.

## Agreed

| Decision | Requirement |
|---|---|
| Audience | Individual ML researchers and engineers |
| Native surfaces | iPhone and iPad |
| Sign-in | Apple and Google following TextBrain's interaction pattern; email one-time code fallback selected under the user's delegated choice; no usernames/passwords in launch customer UX |
| Public name | Timestep is the user's first choice; review found existing App Store and AI/software uses, so qualified-title availability and clearance remain unresolved; no public rename yet |
| Reader launch scope | iPhone/iPad first; admin website included; user additionally authorized building and deploying the browser reader after iOS, including while they are away |
| Key custody | Device-held keys; recovery requires an approved device or saved recovery code |
| Business model | Subscription with included AI/OCR allowance; tiers and credits supported |
| Price exploration | Benchmark $9.99/month and $19.99/month; final allowances follow measured workloads |
| Operating budget | $100/month incremental Science Reader private-beta costs, excluding existing TextBrain charges |
| Backend | Dedicated Supabase infrastructure with background processing as needed |
| Shared articles | Reuse eligible article conversions across users to reduce Mathpix costs |
| Equation-aware reader | Mathpix PDF parsing is required for the final structured text/equation/figure experience; opening an original PDF is an intermediate development capability, not completion of the reader |
| Private user data | Each person owns their library state, notes, highlights, and conversations |
| Admin | Private usage/cost dashboard with spending and account controls |
| Testing | Internal/admin app experience: screenshot, note, upload, replies, and fix-build tracking |
| UX | Preserve successful original screen arrangement and navigation; polish speed, reliability, spacing, metadata density, transitions, and accessibility using complete workflow simulations and independent reviews of complex designs |
| Existing NAS data | No migration needed |
| Initial delivery | Backend, admin dashboard, and TestFlight; public release after user review |
| Infrastructure discipline | Plan data ownership, failure behavior, evolution, and operations before choosing tables/deploying |
| Delivery quality | User explicitly prioritizes careful, maintainable implementation over speed; resolve structural issues and verify complete workflows before enabling them, without hacks or shortcuts |

## First usable journey direction — 2026-10-04

The user transferred work to a new agent and chose, for the first overnight build:

| Decision | Requirement |
|---|---|
| Processing host | Build the add-paper → Mathpix → offline reader → paid answer journey on Supabase Edge Functions and database jobs. The Linux PDF-verifier work stays in the repository but is deferred until a real Linux host exists. |
| Paid OCR bound | Bound Mathpix cost with the provider's `page_ranges` cap and a credit hold for that maximum, settled on the provider-reported page count, instead of requiring a trusted local page count before submission. Single submission grant, holds/settlement and uncertain-outcome quarantine remain required. |
| Paid calls in staging | The Science Reader Mathpix and Anthropic keys retrieved from the authorized NAS project file (not shared with TextBrain) may be used in staging. Cap: **$10 for the 2026-10-04 overnight session**, counted against the $30/month provider allowance. Later caps are separate decisions. |
| Staging changes | New additive migrations, Edge Function deployments, synthetic test accounts and operator-recorded credit grants are authorized in staging. Production remains unprovisioned. |
| Paper-chat model | Claude Sonnet 5.5 (`claude-sonnet-5-5`). |
| Non-CC papers (agent decision, reversible) | Most ML papers use arXiv's default non-exclusive license (7 of 8 well-known papers checked). Instead of leaving them "available at source" only, each interested account gets its own private conversion (`owner_private` document, owner-funded OCR, never shared). CC BY 4.0 / CC0 conversions remain shared and reused across accounts. |
| PDF size and OCR page cap (agent decision, reversible) | Originals up to 64 MiB (image-heavy papers exceed 32 MiB); paid OCR capped at the first 80 pages via Mathpix `page_ranges`. |
| Placeholder credit rate (agent decision, reversible) | `beta-credits-v1`: 1 credit ≈ $0.01 at 2× provider cost — 1 credit per OCR page; chat = ceil(provider µ$ / 5000). Subscription allowances remain undecided. |

## Product decision checkpoint

The user accepted both remaining recommendations on 2026-10-02. Account recovery does not recover encrypted history without an approved device or recovery code. No further product decision blocks foundation implementation.

## Recommended technical decisions to validate

- Shared publication metadata and reusable file conversions have separate identities. A DOI or title is not a file fingerprint.
- Users' personal content has no ownership relationship to the public conversion cache. Revoking one user never deletes another user's article.
- Private conversations, titles, selected-text anchors, notes, and generated chat artifacts use a versioned encrypted-content format with device-held keys.
- Cloud AI receives an explicit bounded plaintext request; encryption of stored history does not imply encrypted computation or provider zero retention.
- Supabase Realtime triggers catch-up, while a durable cursor protocol provides synchronization correctness.
- Billing events, credit grants, reservations, provider costs, and settlements are separate records with transactional invariants.
- Background jobs have durable state and fenced leases. Uncertain paid submissions are reconciled instead of blindly resubmitted.
- Internal app and customer app share one feature codebase. A testing build flag changes presentation; server roles authorize privileged operations.
- TextBrain's crypto/sync/billing code is reference material. Reuse requires a narrow dependency review and tests; its historical migration machinery is unnecessary for this clean start.

## Budget interpretation

Incremental means new costs attributable to Science Reader: new Supabase compute/projects, any plan increase necessary for them, admin/worker hosting, backups, storage/egress, and API consumption. Existing TextBrain costs are not silently reassigned to this budget. Shared-account invoices must be attributed before deciding which costs fit.

The $100 is an operating budget, not permission to purchase unrelated services or an estimate for the user's time. Reserve fixed costs and contingency before allocating the variable API allowance. In-app credits do not equal dollars or a provider's credits unless an explicit published conversion policy says so.

## Account deletion (owner decided 2026-10-05: keep billing records de-identified)

App Store review requires in-app account deletion for apps with account creation. Recommended, for owner review:

- **Settings → Account → Delete account** with a typed confirmation. Deletion is a server operation (requires a
  connection); the device then erases its local encrypted store and keys.
- **Deleted immediately**: encrypted history events and key envelopes (unreadable without device keys anyway),
  library items/imports, private (`owner_private`) documents and their Storage objects, support reports and
  screenshots, device registrations, the Auth user (and Apple token revocation when Sign in with Apple is live).
- **Kept, de-identified**: credit ledger, operations and provider-usage rows needed for accounting and the platform
  budget (account ID replaced by a deletion tombstone ID); shared CC BY/CC0 conversions other accounts rely on.
- **Purchases**: an active App Store subscription is managed by Apple; the app links to subscription management
  before deletion. Unused credits are forfeited (state this in the confirmation).
- Backups expire deleted data on the backup retention schedule (BACKUP_AND_RESTORE).

The owner chose the split above (2026-10-05). Implemented: personal content and login deleted; credit/usage/operation
rows kept under the account's random ID, which stops mapping to anyone once the login is deleted (replacing the ID
was not needed: the ledger is append-only and widely referenced). See PRIVACY_AND_SYNC → Account deletion.

## Library metadata view (owner decided 2026-10-05)

The List stays the default. The Library's "Sort and details" menu adds **Layout: List / Table**. Where the container
is at least 700 pt wide (iPad, iPhone landscape) Table is a sortable table; in narrower containers (iPhone portrait,
the iPad Browse column) and at accessibility text sizes it shows as **Detailed rows**. Columns: Title, Authors
(short form), Year, Topics (friendly arXiv names, at most two), Added, Opened, Read (bar + %), Chats; Pages hidden by
default; Status only when a row isn't simply ready. Sorts: Recent, Title, Year, Opened, Progress, Chats, and Authors
on the table; searching keeps only matches and honours the sort. Layout and column visibility/order persist;
the sort still resets to Recent at launch, as before.

Implementation choices (easy to change): on iPhone landscape the table is drawn by the app, because SwiftUI's `Table`
shows only its first column on iPhone; it carries authors and topics under the title and has no column
customization. Detailed rows leave abstracts out (they are the List's detail). Dates older than this year show
month and year ("Sep 2025"). Opened/Read use device-local encrypted reading activity, never synced or sent to the
server — see [privacy and sync](architecture/PRIVACY_AND_SYNC.md#device-local-reading-activity-2026-10-05).

**Superseded in part (owner request 2026-10-06, "a sane true table view of papers that we can re-use for the
feed").** "Table" is now one app-drawn table (`PaperTable`, `Views/PaperTable.swift`) on every size, used by the
Library and the Feed; SwiftUI's `Table` and the 700/980 pt thresholds are gone. "View as" offers List / Detailed rows
/ Table; Table shows detailed rows only at accessibility text sizes. Each column has a priority and a width; the
title keeps at least 160 pt (or a third of a wide row) and columns are added in priority order while they fit, so
there is never sideways scrolling. Library: Title (title and first author, "Vaswani et al."), then Progress, Year,
Added, Opened, Chats and, on wide iPads, Topics (Show › Topics hides it). iPhone portrait shows Title, Year,
Progress; iPhone landscape and iPad portrait add Added, Opened, Chats. Progress merges the old Read and Status
columns: reading progress for a paper, otherwise an icon and one word ("Converting", "Download failed"), the step
time on a second line, and the full status for VoiceOver; a paper merely not downloaded shows its progress, as the
List shows nothing for it. Headers sort (tap again to reverse); when the sorted column doesn't fit, "· Added ⌄"
beside Title shows the order. Tapping a paper opens it; tapping an import that needs credits opens Get credits;
long-press and swipe keep the List's actions. Column visibility is no longer customized per column (SwiftUI's
column customization went with `Table`). Feed: "View as" List (default) / Table in the Feed's "…" menu; columns Title
(and first author), Topic, Published (month from the arXiv identifier — the server sends only the year) and Add;
newest first; tapping a row shows its abstract under it; long-press offers Add to library and View on arXiv.

## Web search in chat (owner decided 2026-10-05: turn it on)

Owner approved enabling it with a consent line naming Anthropic's search provider and a tappable Sources list.
Implemented and **on in staging** since 2026-10-05 (server switch `CHAT_WEB_SEARCH`; see [chat](architecture/CHAT.md)). Restores the legacy
app's web search. Enabling needs: consent copy that names Anthropic's search provider as a recipient of search
queries, a tappable source list (Anthropic's display requirement for cited web results), and acceptance of the
larger per-question hold (108 → 245 credits for DPO, a 27-page paper; actual charges are far lower).

## Subscriptions and credits (owner approved 2026-10-05)

Approved draft: **Standard $9.99/month = 800 credits**, **Pro $19.99/month = 1,800 credits**, a **$4.99 pack = 400
credits that never expire**, TestFlight testers 1,000 credits by operator grant; 1 credit ≈ $0.01 to the customer,
about twice provider cost. Also approved: the per-question hold is capped at the balance from 50 credits.

Implementation choices (easy to change; see [purchases](architecture/PURCHASES.md)):

- Plan credits are granted per verified renewal and expire with that period (no rollover); pack credits never expire;
  holds spend plan credits first.
- An upgrade grants the new plan's credits at once and leaves the old period's credits until they expire.
- A refund removes unspent credits from that purchase (holds in flight are kept); a reversed refund restores them.
- A purchase belongs to the account that first reports it (the app sets `appAccountToken` to the account ID); a
  deleted account's purchase moves to the next account that restores it.
- App Store Connect (beta scope): app "Paperstep" free and offered in the United States only; products
  `com.sciencereader.ios.{standard.monthly, pro.monthly, credits.400}` in group "Plans", US prices, App Store market
  only; sandbox server notifications go to staging. Territories, final names and review screenshots are revisited
  before public release.

## Ingest adds papers from the web (owner asked 2026-10-05)

Owner: "the background agent, upon being asked to ingest, should be able to import papers it finds on internet, not
just archive". Implemented as **web imports** (migration 019; see [chat](architecture/CHAT.md#ingest-selection-action)).
Defaults chosen (easy to revisit, none hard to reverse):

- **Freely available PDFs only.** A cited paper without an arXiv copy is added from a PDF OpenAlex lists for it:
  its open-access locations (Unpaywall data: repositories, publisher OA copies) and PDFs on free ML venues (JMLR,
  PMLR, NeurIPS/ICML/ICLR, CVF, ECCV, BMVC, ACL Anthology, OpenReview, AAAI, IJCAI, JAIR, ISCA, RSS), which
  OpenAlex often labels closed (e.g. Dropout, JMLR 2014). A paper with neither is reported as "not openly
  available" with its DOI/landing link; nothing is fetched. A login page or paywall in place of a PDF is refused.
- **Always a private conversion** for the requesting account (like non-CC arXiv papers): never shared or reused by
  another account; the reader's attribution says so and links the landing page.
- **The server picks the PDF**, from OpenAlex's record of the work; clients only name an OpenAlex work
  (`openalex:W…`). Downloads are hardened (https on a public DNS name, every redirect re-checked, private addresses
  refused, PDF bytes required, size/page limits, credits required before downloading).
- **Installed builds keep working.** Builds before this change cannot show web papers, so their library reads (v2)
  leave web entries out; newer builds read v3. Ingest adds a web paper only for builds that declare
  `capabilities: ["web_import"]`; older builds are told to update.

## Library header and design audit (owner asked 2026-10-05)

After build 8 the owner approved replacing the system search bar (its navigation-bar drawer left a gap) and asked
for an independent design audit against these principles: well-considered margins; details and options tucked
away until needed; visual hierarchy (primary things larger, secondary smaller); as much open space as possible
("walking into a living room and seeing mostly open space"); and one uniform, consistent way to reach options
just below the surface across the app.

Library header: one row with the system search field, Add (+) and one options menu (…) that merges the former
"Library options" and "Sort and details" menus (layout, sort, show, then All chats, All diagrams, Refresh). While
searching, Cancel replaces + and …, and the Library/arXiv switch appears under the field; Cancel returns to the
library. The navigation bar is hidden on the Library root.

## Web search providers and pricing (owner decided 2026-10-06)

The owner bought Tavily's **Project plan ($30/month, 4,000 search credits; billing cycle from 2026-10-06)** and asked for
a recommendation and a well-designed fit with credits; on follow-up: "I dont feel strongly about tavily, what ever is
the best value" and "having two might be good, we can have a backup". The Science Reader Tavily key already in
`.env.providers` (from the authorized NAS project file; not shared with TextBrain) reports the Project plan (Tavily
`/usage`, no credits used), so it is the staging credential.

Decision (details in [chat](architecture/CHAT.md#web-search-on-in-staging)):

- **Tavily is the primary search; Anthropic's search is the automatic backup**, per answer and mid-answer. Value:
  Anthropic's search measured $0.06–$0.12 provider cost per searched answer on staging, two thirds of it result
  tokens (~10k per search); Tavily results are sized by us (5 × 1,500 characters ≈ 2.5k tokens) and a search inside
  the prepaid plan costs nothing extra. Tavily also restricts paper searches to scholarly sites (`academic`).
- **Readers pay the same rate card whichever provider ran** (`beta-credits-v1`, 2× list price): Tavily's
  pay-as-you-go $0.008/credit → 1.6 credits per search; Anthropic $0.01 → 2 credits per search; tokens as before.
  Searches are never free to readers, so the plan's allowance cannot be drained without spending credits.
- **The $30 is a fixed commitment**, not metered spend: Tavily searches inside the plan add nothing to the
  `platform_budgets` cap; Anthropic backup searches do. A server-side allowance (3,900 credits per 31 days) moves
  answers to the backup before the plan runs out, and **pay-as-you-go must stay off** in Tavily's dashboard (it is the
  provider-side hard limit; if it is ever turned on, overage would be unrecorded spend).
- **Privacy:** Tavily may keep queries and use them to improve its service, and may pass them to third-party
  indexes (its privacy policy, checked 2026-10-06); no zero-retention claim. Consent becomes `cloud-ai-v2` naming
  Tavily; builds that send v1 never use Tavily, and newer builds ask once more.
- **Measured on staging (2026-10-06, same requests, consent v1 → Anthropic, v2 → Tavily):**

  | Request | Provider | Searches | Provider spend | Reader credits | Time |
  |---|---|---:|---:|---:|---:|
  | Related (DPO passage) | Anthropic | 3 | $0.111 | 23 | 14.0 s |
  | Related (DPO passage) | Tavily | 3 | $0.047 (+3 prepaid credits) | 15 | 16.2 s |
  | 2026 SWE-bench question | Anthropic | 1 | $0.056 | 12 | 11.8 s |
  | 2026 SWE-bench question | Tavily | 2 | $0.041 (+2 prepaid credits) | 12 | 14.2 s |

  Answer quality was comparable; the Tavily Related answer linked all 7 papers to arXiv (Anthropic's: 4 of 8).
  Saving ≈ $0.015–0.02 of provider spend per search, so the $30 plan pays for itself only above ≈ 1,500–2,000
  searches a month.
- **Plan size (recommendation):** private-beta volume is far below 4,000 searches (four searched answers so far,
  each ≤ 5 searches). Tavily's free tier (1,000 credits/month, 100 requests/minute development keys) would likely
  cover the beta; if the counts by early November stay under ~800/month, downgrade before the next renewal. The code
  does not change with the plan: set `TAVILY_SEARCH_ALLOWANCE` to the new allowance less a margin. A paid plan is
  needed for production keys (1,000 requests/minute) before public launch.

## Product name: Gradstep (owner decided 2026-10-06)

Owner: "lets do gradstep then", after the [naming study](brand/naming-2026-10-06.md) (top pick) and a check of
Gradstack (rejected: gradstack.ai/.io belong to a live AI hiring startup since March 2026, and "stack" reads as
careers/developer tools rather than ML). Gradstep: a gradient step is the basic unit of ML training; each paper is a step.

- User-visible name is **Gradstep**: App Store Connect record renamed from "Paperstep" (2026-10-06), home-screen name
  (`CFBundleDisplayName`), consent and privacy copy, alerts, the iPad sidebar title, the admin site, sign-in emails
  ("Your Gradstep sign-in code", sender name Gradstep), session recordings (`gradstep-session-*.zip`; the review
  script still reads `paperstep-` files), and chat instructions and conversion attribution text.
- Internal identifiers stay: bundle `com.sciencereader.ios`, the `ScienceReader` code names, the Supabase
  organization/projects, and content-addressed sample bundles (their text still says Science Reader).
- Domains (checked 2026-10-06, registry data): gradstep.ai, .io, .co, .dev, .org, .net, getgradstep.com unregistered;
  gradstep.app registered (Porkbun, January 2026, dead Vercel page); gradstep.com for sale at $1,995. Recommended:
  **gradstep.ai** (≈ $70–90/year, often two years upfront) and optionally getgradstep.com. The owner buys it; it then
  becomes the verified Resend sending domain for sign-in codes. Not a trademark clearance: an attorney search is
  still advised before public launch.
- Logo: not yet chosen (concepts: Folio, Nabla, Ribbon were the favourites).

## Logo, domain and sign-in email (owner decided 2026-10-06)

- **Logo: 06 Nabla** ("The nabla looks good"): the gradient operator ∇ as a valley with an optimiser stepping down to
  the minimum (amber point) on an Ink tile. Installed as the app icon (light, dark and tinted variants), the
  gradstep.ai favicon and header, and the admin mark. Concept sheets: `.artifacts/brand/logo-concepts/06-nabla/`.
- **gradstep.ai** (owner bought it, with gradstep.shop): DNS on Cloudflare; the site (home, beta privacy notice,
  Apple `webcredentials` association for "Save to Passwords") is the Cloudflare Pages project `gradstep-site`.
  Namecheap's email-forwarding MX/SPF records are kept at the apex.
- **Sign-in codes are sent as `Gradstep <codes@gradstep.ai>`** through Resend, with the domain verified (DKIM and the
  `send.` subdomain's MX/SPF records in Cloudflare) and a sending-only key scoped to gradstep.ai as the Supabase SMTP
  password. Verified: a code to a non-owner address was delivered (Resend test inbox), 2026-10-06. Sign-up stays
  invite-only; testers need an account created for them.

## Add a reference without chat (owner asked 2026-10-06)

Owner: "if you click on a reference, and ask for Add the reference, no chat is needed, it should just get queued and
then start to get processed, and it needs to be extremely reliable … for regular pdfs maybe a chat makes sense."

- **Reference actions → Add to library** calls `functions/v1/add-reference` (no model, no credits): an arXiv id or DOI
  in the entry, else the entry's own title (quoted, or between the authors and the venue) through the shared strict
  search (OpenAlex, arXiv, Tavily), else Crossref's citation matcher, else OpenAlex search; a found paper is accepted
  only if its title appears in the entry. The reader shows the outcome in a banner ("Added …", "already in your
  library", "isn't openly available", "Couldn't identify this reference" with **Ask in chat**, which runs the
  existing Add paper chat). Outcomes are recorded as `reference` reliability events (migration 026).
- The selection action **Add paper** (on an in-text citation) still uses the chat.
- Live: seven real entries resolved correctly (1–16 s); the Simulator journey (DPO citation 11 → PaLM) passed.

## Workflow checks schedule (owner decided 2026-10-06)

October's staging provider cap raised to **$25** (from $9.80; within the $30/month AI/OCR allowance). Paid checks run
Mon/Wed/Fri plus a weekly heavy suite (~$6/month); free checks every 6 hours and after deploys. Failures email the
owner. See [workflow checks](architecture/WORKFLOW_CHECKS.md).


## Recovery code in Apple Passwords (owner asked 2026-10-06)

Owner: "can we build an integration with Apple password manager so its easy for users to sync the retrieval password
into Apple". The recovery code is needed only on a device that has no approved device to approve it (an approved
device can approve a new one), not on every sign-in.

- The recovery screen offers **Save to Passwords**: the code is saved as a password for `gradstep.ai` (title
  "Gradstep recovery code", user name = the account email) through the system prompt
  (`ASCredentialDataManager.save` on iOS 26.2+, `SecAddSharedWebCredential` before). Saving also ticks "I saved this
  code". It is optional; copying the code still works.
- On a new device, **Use code saved in Passwords** asks the system to offer passwords saved for `gradstep.ai`
  (`ASAuthorizationPasswordProvider`) and fills the field; the field also accepts Password AutoFill.
- Requires the `webcredentials:gradstep.ai` associated domain (App ID capability enabled; `gradstep.ai/.well-known/
  apple-app-site-association` lists the app) and the "Gradstep App Store" profile.
- Apple documents iCloud Keychain (which Passwords uses) as end-to-end encrypted; Gradstep's server still never receives the code. Anyone who can
  open the person's Passwords can read the code, as with any password they store there.
- Evidence (2026-10-06, iPhone Simulator): **Use code saved in Passwords** runs and reports "No saved recovery code was
  filled" when none exists; **Save to Passwords** on a fresh staging account opens Apple's password-saving sheet, which
  the Simulator closes because it has no iCloud Keychain. Saving and filling on a real device is not yet verified
  (physical iPhone work is paused).

## Self-healing downloads (decided 2026-10-07)

Decided overnight under the owner's "don't stop to ask"; for review.

Owner: a "Download failed" must never just sit in a reader's library. Decided and recorded here; details in
[import reliability](architecture/PIPELINE_RELIABILITY.md#self-healing-downloads-migration-027).

- **Automatic retry, at most three times, 15 min / 2 h / 12 h**, for download failures that can change: host busy or
  unreachable (`source_unavailable`), a bot check (`source_blocked`), no PDF at the link (`not_pdf`), gone or refused
  (`download_failed`), a crash loop. **Not** for refusals that cannot change: a sign-in or paywall (`pdf_restricted`)
  or the size limit (`too_large`). Every failure keeps the reader's Retry, which runs at once and does not use up an
  automatic retry. A successful download resets the count.
- **While a retry is scheduled the import stays `failed`** (honest: it did fail) with the new code
  `download_retrying` ("Couldn’t download yet · Trying again automatically") and a new top-level entry key
  `auto_retry_at`, present only then, so every other entry's JSON is unchanged (older builds show "Couldn’t import
  this paper" and keep Retry). Rejected: keeping the import "Downloading…" for up to 12 h (the app would say
  "taking longer than usual" for hours).
- **A retry is a worker checkpoint, not a reader intent**: new `state_seq`, intent revision unchanged, so a reader's
  Cancel still applies and needs no new revision.
- **Healing**: a failed, retryable import whose paper has since moved on (another reader's retry or import) is put
  back in the pipeline automatically. Found on staging: three imports stuck `failed` beside a paper that was `done`.
- **After every pipeline worker deploy**, every failed paper that can resume without charge (metadata, download,
  render; not `too_large`) is retried once per deploy label — including sign-in/bot refusals, since a deploy is when
  our misclassification stops being one. Not counted as an automatic retry.
- **Reader messages** (app, `LibraryImportErrorCode`): `pdf_restricted` "This PDF needs a sign-in or subscription",
  `source_blocked` "The paper’s website blocked the download", `source_unavailable` "The paper’s website isn’t
  responding", `not_pdf` "The paper’s link doesn’t lead to a PDF", `download_retrying` as above.
- **We do not evade bot checks** (no browser user agent, no challenge solving). Copies on hosts that challenged every
  automated request in the survey (ACM, OUP, Wiley, T&F, Elsevier, Science, PNAS, ACS, SAGE, IOP, Cell, PeerJ,
  SSRN, eScholarship, OpenReview, IUCr, Lancet) are tried after every other copy; PubMed Central copies are fetched
  from NLM's official open data on S3 (`pmc-oa-opendata`), the documented programmatic route.
- **Ingest's notion of "openly available" is unchanged** (explicit PDF locations only). The pipeline additionally
  tries PMC open data and open repository records; widening Ingest to count those is a possible follow-up.

## Admin accounts (agent decisions, overnight 2026-10-07; owner asleep, all reversible)

The owner asked for an owner-only Accounts tab so testers can be managed without an engineer
([gap audit](LEGACY_GAP_AUDIT.md)). migration 028, Edge function `admin-accounts`, admin tab **Accounts**.

- **Who:** owners signed in with MFA only, through the existing `is_operator('owner')` gate (`v1_admin_actor` on the
  caller's own token); the service functions re-check that the acting account is an open owner. Support operators
  don't see the tab.
- **Add tester:** creates the Auth login with the email confirmed and no password through the Auth admin API;
  `disable_signup` stays on and nothing is emailed. The page shows instructions to send and reminds the owner to add
  the tester to TestFlight. The existing `auth.users` trigger creates the account row. Adding an existing email
  changes nothing. Starting credits default to 1,000 (the approved tester grant) and are granted once per account.
- **Grants:** `adjustment` credits that never expire, 1–2,000 per grant (server-side), a required one-line reason
  (3–500 characters, kept in the audit log; the ledger reason is "Admin grant: …"), once per request ID; the page
  asks for confirmation above 500.
- **Disable:** a Supabase Auth ban (100 years), recorded in the audit log *before* the ban is applied; owners can't
  be disabled here. An open session keeps working until its access token expires (up to an hour); making the
  database refuse banned logins immediately is a possible follow-up (it would change `app_private.actor()`, used by
  every RPC, so it was not done unreviewed). Deletion stays in the app.
- **Status shown:** active, disabled (banned), closing (deletion started, login not yet removed), closed (deleted).
  Synthetic `@example.invalid` logins are listed and marked "Test". Apple/Google sign-in for a pre-created tester
  relies on Supabase linking identities with the same verified email; not yet tried on staging.

## All chats as a table (owner asked 2026-10-07)

Owner: "the all chats UX is terrible, bad use of space, we also need a nice table, better more dense rows, not
overdoing it, thoughtful. But at the very least I should be able to see a table with my chats, sort them based on
last used, etc." Decided by the agent overnight (owner asked not to stop for feedback); all reversible.

- **Same place, same entry points.** "Chat history" (chat top bar) and "All chats" (Library, chat and Settings menus)
  still open one sheet titled All chats with Done; All diagrams is unchanged. The sheet now opens full height on
  iPhone and page-sized on iPad (iOS 18+), since a table needs the room.
- **A table in the `PaperTable` pattern** (`Views/ChatHistoryView.swift`): a pinned header of column titles (tap to
  sort, tap again to reverse; "· Started ⌄" beside Conversation when the sorted column doesn't fit), compact rows
  (~52 pt: 7 pt vertical padding, 16 pt sides), columns added by priority while they fit, never sideways scrolling.
  Columns: **Conversation** (the first question on one line; under it, muted, the paper's title, or the newest
  answer as one plain line when the Paper column is shown), **Paper** (title, "General", or "Paper chat" when the
  paper is no longer in the library), **Messages**, **Started**, **Last used** (always rightmost: "Just now",
  "5 min ago", "2 h ago", "Yesterday", "Mon", "Oct 3", "Sep 2025"). iPhone portrait: Conversation and Last used;
  iPhone landscape and iPad: all five. Default order **Last used, newest first**; it isn't remembered between
  openings. At accessibility text sizes rows replace the table (title, paper, "2 h ago · 6 messages").
  A separate table rather than `PaperTable` itself: chats aren't papers, and `PaperTable` was being changed by another
  session the same night; merging the two into one generic table is a later cleanup.
- **Search and a quick filter.** A search field ("Search chats": every word must match a question in the
  conversation or the paper's title, ignoring case and accents) and chips **All · Paper chats · General** with the
  count ("34 chats", "5 of 34 chats"). Both apply to drafts too. No date grouping (Today / This week / Earlier):
  it only makes sense for one sort, and the Last used column already says it.
- **Unsent drafts stay on top**, in their own section ("Unsent drafts"), with a pencil, "Draft · <paper or General
  chat>" and when they were edited; tap reopens, swipe or long-press discards, as before.
- **Row actions.** Tap opens the conversation (as before). Long-press: **Open paper** (paper chats whose paper is in
  the library) and **Delete conversation**; swipe: **Delete**. Both ask first ("… will be removed from your chats on
  all your devices"). There was no delete before: it appends the conversation tombstone the sync design already had
  (hidden on every device once synced, its diagrams too, continuing it blocked, an unsent follow-up kept as a draft).
  The encrypted records stay on the server until account deletion; the app doesn't claim otherwise. Delete needs
  this account's encrypted history on the device (not offered signed out).
- **Times in history.** Events carried no time, so "Last used" had nothing to read. New conversation, message and
  diagram events now carry `createdAt` (the author device's clock, Unix ms) **inside the encrypted payload**: the
  service learns nothing it didn't already (it sees when ciphertext arrives), older app builds ignore the field,
  and no migration or server change is involved. History saved before this has no times: those conversations show
  "—" and sort after dated ones, among themselves by the order they reached this device (`PrivateState` keeps that
  arrival order as an unsynced, uncompared hint). The original web app showed server `created_at`/`updated_at`.
- **What the original web view had** (`reference/web/components/AllChatsView.tsx`): a desktop table Paper · Chat ·
  Type (Paper/General badge) · Started · Last active · Msgs, newest activity first, no sorting, search or actions; a
  card list on phones (title, paper, badge, relative time); a "New chat" button and a count in the header. Kept: the
  columns (Type became the filter chips and the Paper column's "General"), newest-first, relative times, the count.
  Dropped: the badge styling, the New chat button (the chat's own compose button stays one tap away), the
  highlighted-passage quote of the in-panel history (not stored separately in the native history).

## Author–year citations link like numbered ones (owner asked 2026-10-07)

Owner: "when references are indicated like 'Stadter et al, 2021', I don't see an obvious way to use them as
hyperlinks, like if they are numbers (which seems to work)". Decided without waking the owner (reversible, reader-only):

- **Same interaction as numbers.** An author–year citation links to its bibliography entry only when exactly one entry
  fits; the tap, highlight, Back and reference actions are the numbered ones. Each name–year pair is its own link
  ("(Peters et al., 2017, 2018a)" is two). Ambiguous citations stay plain text rather than risk a wrong jump.
- **Discoverability (styling only).** Same link color as numbers; on touch screens every citation link (numbered too)
  gets a faint 1 px underline at 40% of the link color, so long author–year spans show their extent. No new controls.
- **Matching rules** (detail and measurements in [Reader renderer](architecture/READER_RENDERER.md)): diacritics
  folded, particles and multi-word surnames, "et al" with or without period, "and"/"&", groups, brackets, narrative and
  parenthetical forms, lists, suffix letters; ties broken by cited names' places, author count, initials, suffix
  letter or entry order. The bibliography now ends at an appendix paragraph, and lower-case-particle surnames start a
  new entry.
- **Measured, not assumed.** `scripts/citation-harness.mjs` runs the bridge in headless WebKit over 22 real bundles
  (12 retained, 10 downloaded read-only from staging storage): unambiguous author–year citations linked 89.5% → 99.8%
  (1,393 → 1,568 of 1,571), no wrong link against the oracle, 30/30 random links correct by hand, numbered papers
  unchanged, no block text changed. The owner's "Städter et al., 2021" paper went from 44.9% to 100%.

## Import progress (owner asked 2026-10-07)

Owner: "when items are processing, we should have a better UX, ideally, we have an estimate of the total time, and
have a percent done, with stages that make more sense to the user (What does 'Converting...' mean?) What is a reader
to the user?" Agent decisions overnight (owner asleep; all reversible); design in
[import progress](architecture/IMPORT_PROGRESS.md).

- **Steps in the reader's words:** Finding the paper → Downloading the PDF (40.8 MB) → Reading equations and figures
  (page 12 of 27) → Preparing it for reading; also "Waiting to start", "Waiting to continue" (budget pause) and
  "Couldn't download yet · Trying again automatically" (027's automatic retry, shown as under way, not as a failure).
  No user-facing "converting", "rendering", "reader" or "bundle" on import rows.
- **The readable result is "a readable version"** where a noun is needed (the explainer); rows avoid naming it.
  "Reader" stays an internal word. Failure messages ("Conversion failed", "…to convert this paper") were left for a
  separate pass.
- **Percent and time left are computed by the server** from measured stage times (30-day medians, defaults from the
  staging canary), scaled by pages, using Mathpix's page progress during OCR, and sent as `progress_detail` on the
  import entry (migration 029). The percent never goes backwards within an attempt; the time is shown only when
  trustworthy, rounded ("About 40 s left"), said loosely before the page count is known ("Usually under a minute"),
  and replaced by "Taking longer than usual" when the paper is backing off or well past its estimate.
- **Updates are throttled:** at most one progress entry per import per 5 s, only when the reader would see something
  new, within a per-account progress rate (720/hour) separate from library writes; the app moves the bar and counts
  down between updates.
- **Explained once:** an info button beside the progress opens "Getting a paper ready" (four steps, about a minute,
  carries on if you leave the app).
- **Look:** a slim neutral bar (the accent bar remains reading progress), "62% · About 40 s left" beside it.

## Mac app (agent decisions, overnight 2026-10-07; owner asleep, all reversible)

Owner: "build out the MacOS app … don't stop to ask for feedback". Details: [Mac app](architecture/MAC_APP.md).

- **Mac Catalyst with the Mac idiom on the existing target**, not a separate AppKit app: one code base, the
  same bundle ID and App Store record (universal purchase), iOS build settings unchanged (`[sdk=macosx*]`
  conditions only).
- **Window:** always the wide layout; the view switch and Settings move into the window toolbar (platform
  adaptation; the arrangement, modes and panes are the iPad's). Minimum 720 × 520 pt so it tiles on a
  13-inch screen; size remembered. No privacy cover when the app is inactive (a Mac window stays visible).
- **Menu bar mirrors on-screen controls** (no menu-only features). ⌘F finds in the paper while reading and
  searches the library elsewhere (⌥⌘F always searches the library, as in Mail/Notes) — a change from
  "⌘F = library search" because a reader pressing ⌘F in a paper expects to find text, not to leave it.
- **Chat sends with ⌘Return** (Return = new line, as on iPad).
- **Fixtures** compile for Debug builds on the Simulator or a Mac (`FIXTURE_HOST`), never for devices or
  distributed builds.
- **Distribution:** `scripts/upload-testflight-mac.sh`. Build 15 archived and signed for development; the
  upload waits for the owner: a Mac Installer Distribution identity in the keychain and a Mac Catalyst App
  Store profile ("Gradstep Mac App Store"). Not created by the agent: the existing installer certificate's
  key is held outside this project, and new signing certificates are the owner's to hold.

## Chat answers: tables, papers named, progress (agent decisions 2026-10-07, overnight mandate)

Legacy audit gaps 4, 2 and 9, built without questions under the overnight mandate; all reversible, all additions under
or inside answers (no page arrangement or selection action changed).

- **Tables** render as a native grid; while streaming, rows at the end stay pipe text until complete, so the layout
  changes once. Tables over 12 columns or 120 rows stay pipe text. Details: [chat rendering](architecture/NATIVE_CHAT_RENDERING.md).
- **Papers in this answer** lists arXiv IDs and DOIs found in the answer's own text, on the device, without a model
  call (at most 8). A paper that appears only in the server's Sources list is not repeated (Sources already offers it).
  Open asks first, like Sources. arXiv adds use the Add sheet's library command (latest version, not the version a link
  names); DOIs use `add-reference` with the reader's outcome wording on the row. "Ask in chat" is not offered from
  chat. A DOI paper added earlier shows "In your library" only once this session's add matched it (the library has
  no DOI field).
- **Progress**: a backward-compatible `status` stream event (`searching` with the query, `reading`, `finding_paper`,
  `adding_paper`), shown as one line under the streaming answer. The query goes only to the reader's stream, never to
  logs. Needs a chat function deploy (not deployed by this work); older servers simply send none.
- **Owner feedback (build 14, items 3, 10, 11):** answer paragraphs, headings and list items are now read-only
  selectable text views (same look; formulas are image attachments) because SwiftUI `Text` cannot extend its selection
  menu. Selecting answer text offers **Ask about this** (puts `About “…”: ` before any draft in the composer and focuses
  it), **Explain** and **Define** (sent as a new question in this chat; with a draft in the composer they wait there
  instead of replacing it), then the system's Copy/Look Up/Share; Copy keeps formulas as `\( … \)`. A formula (long
  press, right-click on the Mac; display formulas through their context menu) offers Copy LaTeX, Copy as text (a
  Unicode approximation, `ChatMathText.plain`), Explain, Define, Ask about this. "Define" is a chat-only prompt
  ("Define the terms and symbols in: …"); the paper's Explain prompt is reused. Your own messages and streaming answers
  keep the system menu. A leading "Answer:" label is stripped on display (stored text unchanged) and the chat
  instructions say not to write one. Bold/italic spans around inline math (`**$n = 0$:**`) now render as emphasis.
