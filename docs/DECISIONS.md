# Product and architecture decisions

Last updated: 2026-10-07. Requirements below come from the current user conversation, not from TextBrain's product specification.

## Web framework (owner decided 2026-10-07)

Owner: "react it is then", following the [React/Svelte evaluation](architecture/WEB_FRAMEWORK_EVALUATION.md).
Use React + TypeScript + Vite for both the browser reader and the admin. Share useful presentation components
and conventions; keep customer device-key/auth state separate from admin MFA and privileged operations.
SwiftUI/Catalyst remains the Apple application. Retain framework-neutral protocol, encryption and reader services.
Large-library work must address rendering, data loading and sync deliberately; the synthetic 50,000-row comparison
does not raise the current 4,000-entry protocol limit or establish product capacity.

## Library database foundation (owner authorized 2026-10-07)

The owner approved proceeding with the larger-library database direction and independent agent review, with a
reviewable branch for integration. The first stage separates compact replication, immutable metadata hydration
and indexed current-library queries. Independent review favored explicit query-generation invalidation over
version-history tables and snapshot leases until churn measurements justify that complexity. Preserve existing
command identities, grouped changes, old clients and capacity limits. No larger plan allowance, client rollout or
hosted deployment follows from local fixture tests. See [Library v4](architecture/LIBRARY_V4.md) and the remaining
[capacity acceptance gates](architecture/LIBRARY_CAPACITY.md).

## Agreed

| Decision | Requirement |
|---|---|
| Audience | Individual ML researchers and engineers |
| Native surfaces | iPhone and iPad; Mac through Catalyst (2026-10-07 addition) |
| Sign-in | Apple and Google following TextBrain's interaction pattern; email one-time code fallback selected under the user's delegated choice; no usernames/passwords in launch customer UX |
| Public name | Gradstep (owner decided 2026-10-06); gradstep.ai is the owned public domain; see the dated name decision below |
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

**Superseded again (owner request 2026-10-07):** the Table is the default, Detailed rows are gone, and columns are
chosen again (per device kind); see [Library as a proper table](#library-as-a-proper-table-owner-asked-2026-10-07).

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


## Library as a proper table (owner asked 2026-10-07)

Owner: "I do not like the detailed rows right now, it should be a proper table, we need to have columns that can be
turned on or off, it needs to be something where people can navigate and find papers easily … I see some in my list
that say 'Download Failed'. They should never sit there like that, it should be a retry button at the very least."
Made overnight without check-ins (owner asleep); each choice below is easy to change.

- **The Table is the Library's main view** at every size; **List** stays the alternative ("View as"). **Detailed rows
  are removed**: a saved "Detailed rows" (and no saved choice) opens the Table; an explicit List choice is kept. At
  accessibility text sizes the Table shows the List's rows (as the Feed does) instead of detailed rows.
- **Columns** (Library options › Columns, a half-height sheet of toggles; changes show at once): Title with the first
  author (always), Year, Tags, Source (arXiv identifier or the web paper's host), Pages, Added, Opened, Chats,
  Progress, in that row order. Choices are kept on the device, separately for iPhone and for iPad/Mac (by device kind
  rather than size class, so rotating an iPhone never swaps sets). Defaults: iPhone Year, Added, Opened, Chats,
  Progress (portrait shows Title, Year, Progress; landscape adds the rest); iPad/Mac add Tags; Source and Pages start
  off. The width then decides which chosen columns fit (Progress, Year, Added, Opened, Chats, Tags, Pages, Source, in
  that priority); a chosen column that doesn't fit says "Shown when there's room", and a column turned off never
  shows. The title keeps at least 155 pt or 40 % of the row, so any one short column fits beside Progress on the
  smallest iPhone and a Pro Max in portrait keeps two columns. Every column sorts from its header (Tags A→Z by first
  tag, Pages longest first, Source A→Z); Tags, Pages and Source join Authors as table-only orders in Sort by.
- **Tags**: `Paper.tags` (first-class tags, filled by the tags work) as display names, else topic names derived from
  the arXiv categories (the Feed chips' names); imports use their categories. Shown as small chips (≤ 2 lines),
  searchable, and filterable. No tag storage or editing here.
- **Finding papers**: one row of chips above the table (and the List) that scrolls away with the rows: **Tags ⌄**
  (a menu, most used first, with counts), **All · Unread · Reading · Failed n · Archived**. "In progress" is named
  **Reading** so it isn't mistaken for imports in progress. Unread = never opened on this device; Reading = opened
  (or with progress) and under 100 %; Failed = stopped imports; Archived replaces Show › Archived papers (removed).
  Only filters that would change the list appear, and the row is hidden for a library with nothing to narrow. Filters
  aren't kept across launches (like the sort). Search still filters live, within the filter, and now matches tags.
- **Keyboard and pointer** (iPad, Mac): ↑/↓ choose a row and Return opens it (key commands, so no focus is needed; a click opens a row as a tap does); hovered rows get a quiet
  fill; the header stays pinned.
- **Stopped imports never just sit**: the status reads in plain words ("Download failed") and the row shows one action
  as a small button — **Retry** when the server can run it again (download, details, rate limit), **Get credits** when
  conversion waits for credits, otherwise **Remove** (too large, unreadable PDF…; nothing to retry). It sits in the
  Progress cell, or under the title when Progress isn't shown; the List shows the same button. The long-press menu
  and swipe say Retry / Remove (Cancel import while an import still runs). Tapping Retry shows the row
  **downloading again at once** (finding, if its details were never found), from the queued retry command, until the
  server's own state arrives. An import the server is retrying by itself (`download_retrying`, migration 027)
  counts as under way: no Retry, not under Failed. Imports in progress show `ImportProgressView` (compact) in the
  Progress cell. The Mac's View menu gets Filter Library in place of Show › Archived Papers.

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

## Topic tags (owner asked 2026-10-07; agent decisions, reversible)

**Owner decided 2026-10-07:** personal tags stay server-visible (not end-to-end encrypted), as built; the owner wants
them for product analytics. Any analytics use stays within the privacy notice (gradstep.ai/privacy says the server
keeps the tags you give papers and that they are not end-to-end encrypted) and reports aggregates, not individuals.

Owner: "I thought we had a tagging system based on topics? … it was useful and we need to bring that back and make
it a first class citizen." Design: [Topic tags](architecture/TAGS.md).

- **Consistent catalog tags**: 3–7 names per paper version from a curated vocabulary (`gradstep-tags-v1`, 120 tags:
  23 areas, 97 topics, each defined), chosen once by Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) from title +
  abstract with the vocabulary as a structured-output enum; arXiv categories as the fallback when the model is
  unavailable. Not free keywords (the web app's drifted between papers).
- **Paid by the platform** under the platform budget (a 0-credit `metadata` hold per paper, $0.01 ceiling), never by
  readers: measured $0.0038 per paper (≈ $0.38 per 100 papers, once per version). Runs in the Cloud Run pipeline
  worker (needs `ANTHROPIC_API_KEY` there) after each paper and each minute; existing papers backfill the same way
  or with `scripts/tag-catalog.mjs run`.
- **Personal tags are service-visible**, synced like archive state (`v2_set_item_tags`, revision-checked,
  replayable), not end-to-end encrypted; the Edit tags sheet says so. This supersedes the earlier plan to keep
  personal labels in encrypted events for tags (server-side joins with catalog tags; no encrypted tag format
  exists). Removing a paper clears its personal tags.
- **What readers see** = catalog tags − tags they removed + their own. Feed chips use the vocabulary's names where
  an arXiv category means the same thing (cs.CL → Natural language processing); others keep their labels.
- Live check (13 calls, $0.049): good tags for Attention, DPO, Mamba, Switch Transformers, RAG, Chain-of-thought,
  NeRF, PPO (after adding "Policy optimization"); remaining errors are comparison/adjacent tags (DDPM → GANs,
  Whisper → Large language models), removable by readers.

## The paper's own contents and bracketed citations (owner feedback on build 14, 2026-10-07)

Owner: "What happened here" (a paper's printed contents as one run-on paragraph) and "The reference isn't working"
(`[Gelfond and Lifschitz 1991]`, `[Lobo et al. 1992; Eiter et al. 1997b]`). Decided without asking (reversible,
reader bridge only, no re-render); details and measurements in [Reader renderer](architecture/READER_RENDERER.md#the-papers-own-contents).

- **Contents as a list, in the paper where it is printed.** One entry per line, indented by section depth, the page
  right-aligned and muted, the dot leader as a faint dotted rule. Nothing moves or is added: the block's text and
  selections are unchanged, and the app's own Contents sheet stays as it is.
- **Conservative detection.** A paragraph is formatted only when all of it is entries (several leader entries, or —
  without leaders — numbered entries in order after a "Contents" caption). Any other text keeps the paragraph as it
  was. Across 48 real conversions only the 5 real lists changed.
- **Entries link like citations.** An entry that matches a heading (number and title) — or, with no heading, one
  numbered run-in head ("3.3.1 Exams Scheduling. …", ACM style; 13 of DLV's subsections exist only so) — jumps there
  with the citation's highlight and Back. Lists of figures and tables are formatted but not linked (they would land
  on a heading, not the figure). Unmatched entries stay plain rather than guess.
- **Bracketed author–year citations needed no new rule.** Build 14 predates the author–year links; with the current
  bridge the owner's paper links 210 of 210 measurable citations (build 14: 3). Small-capital spellings OCR can
  produce ("AND", "ET AL.", "And" in entries) were added; `[Cadoli et al. 1997]`, which fits two entries, stays plain.

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

## Settings and chat titles (owner feedback, build 14 #7–#9; agent decisions 2026-10-07, all reversible)

Owner: "The account option tells me nothing, sync? Sign out and delete feel like they should be hidden away? What does
appearance mean to the user?", of Acknowledgements in Settings "This doesn't look like it should be there", and chat
titles that showed prompt text and raw LaTeX ("Explain in plain terms, including any symbols: \[\begin{equation*}…").

- **One Account row** tops Settings: the email (or "Signed in with Apple" when the account has none) over "Signed in
  with Apple · Synced". It opens **Account**: Email, Signed in with, **Sync** in plain words ("Your chats and notes are
  synced · They're encrypted with keys held on your devices", "Waiting to sync 3 changes", "Syncing…", "Sync is
  paused" with the reason, "Not synced yet" before this session's first sync finishes) and **Sync now** (moved there from Your research, beside the state it acts on), then **Sign
  out** (with the pending-work note) and **Delete account…** (same sheet, flow and accessibility identifiers). Signing
  out closes the page. Signed out, Settings keeps "Sign in or create an account". Credits, Reading, Your research and
  Testing stay where they were.
- **Sync says "chats and notes", not "library"**: the encrypted sync carries conversations, notes, reading places and
  diagrams; the library list is the server's per account (its own pending changes show in the Library). "Encrypted
  with keys held on your devices" repeats the Privacy page's existing claim; no new claim is made.
- **Sign-in methods** are read from Auth's `app_metadata.providers` in the session Auth already returns (decoded
  tolerantly and bounded, kept with the cached session; no server change). A session cached by an older build shows
  none until the next sign-in.
- **Theme**: "Appearance: System" became **Theme** — Light / Dark / Match device as a segmented control (a menu at
  accessibility text sizes), the same stored setting.
- **About Gradstep** is the last row: name, Version, Edition (private beta · staging), Privacy & data,
  Acknowledgements. The Mathpix acknowledgement says "readable versions of papers" instead of "equation-aware readers".
- **Chat titles are shortened at display time only** (the saved title stays the first question's first 100
  characters; nothing saved or sent changes). In All chats (rows, search, the delete confirmation) and the chat's
  title, a selection action's conversation reads "‹action› · ‹passage›": Explain, Why it matters, Related, Add paper,
  and Define for the earlier "Define this in the context of the paper" wording. Every earlier prompt wording is
  recognized; the prompts now live in one place (`SelectionAction.promptPrefix`, `Services/ChatTitle.swift`) so a new
  wording keeps its short title. LaTeX in any title reads as symbols, building on the answer previews'
  `ChatPreview.readableMath` (environments dropped, a/b, √x, x̂, numeric scripts and ᵀ as Unicode, letter subscripts as
  `d_k` like the previews); a formula cut by the 100-character limit shows up to its last complete part, prose up to
  its last whole word, then "…". Search matches the saved question and the short title.

## Floating chrome and the app's own icons (owner asked 2026-10-07)

Owner, with two Gemini screenshots: "I like the way that they have something at the bottom, but things can kind of
flow past it, it provides an illusion of less wasted space … allow a kind of flow behind copying Gemini … I find our
icons to look overall a little generic, anything we can do to spruce them up?" Decided while the owner was asleep
(no questions); patterns in [DESIGN.md](DESIGN.md) (Floating chrome, Icons).

| Decision | Choice (agent, reversible) |
|---|---|
| Tab bar | Our own floating glass capsule over the screen, not the system `TabView`: iOS 26's `TabView` moves the tabs to the top on iPad, can't disable the Paper tab until a paper is open, keeps every tab alive (the reader's web view, the transcript) and flattens our two-color icons. Same five tabs, order, identifiers (`tab.*`) and keyboard behavior (hidden under a software keyboard). |
| Content behind the chrome | Every screen except the reader (below) runs to the bottom edge under the tab bar and keeps room for it (`tabBarSpace`, inside each NavigationStack — a `safeAreaInset` outside it doesn't reach the screen). Content fades into the background behind bars (94–100 % behind controls, a 22 pt fade past them), so text never sits under a control at full strength. |
| Minimize on scroll | Not done. Gemini keeps its bar still; a shrinking bar moves tap targets while reading, and our scroll views are partly UIKit (transcript, reader), so it would need per-screen hooks. Reduce Motion therefore has nothing extra to switch off. |
| Headers | Library and Feed header controls float on the top band; their search field is a glass capsule. Over the table the band stays solid (its column titles pin under it). Chat: the conversation runs under the title bar. Paper: the page stays between the title bar and the tab bar's room, and the reader's controls float over its last lines on the bottom band, so the page's viewport never changes size. Running the page under the tab bar (with a scroll inset, then with padding at the page's end) and shrinking it for the selection bar both broke reading-position return or citation landing in the UI tests: the reader measures positions in that viewport. |
| Message box | A glass pill above the tab bar with Send/Stop inside it; the transcript scrolls under it. Hide-keyboard stays (a glass circle beside the pill). |
| Reduce Transparency | Every chrome surface is solid (secondary background, hairline) and every band is the plain background. |
| Icons | **"Nabla line"**: the app's own SF Symbol templates (`Assets.xcassets/Symbols`, generated by `tools/icons`), rounded strokes like the logo, each with one amber point; selected tab = accent line + amber point. Chosen over (A) tuned system symbols (filled + hierarchical: clean but still the stock set the owner called generic) and (C) a mini app-icon tile behind the selected tab (strong but heavy, and the ink tile nearly vanishes in dark mode). Screenshots: `.artifacts/visual/chrome-2026-10-07/icon-directions/` in the main checkout. Universal actions keep system symbols (+, …, search). |

Owner feedback on build 14 (same day, [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md) items 4–6), folded into this work:

| Feedback | Change |
|---|---|
| "Ask a question is bad language, you can just have chat" | The message box's placeholder is "Chat". |
| "Space below chat box not well used … the paper vs general option needs to be in a menu … can't take away screen real estate for chatting" | The Paper chat / General chat row is gone; the switch is the chat title's menu (same two modes, Paper disabled without a paper), and the subtitle says which (the paper's title, or "General chat"). The message box sits 10 pt above the floating tab bar, with the conversation running under both. |
| "The icon choice is bad it looks like a refresh icon, it probably needs to have lines in it" | All chats (top bar and menus) is a list symbol: bullets and lines, the first bullet the amber point. |

## Adding any paper: identifiers, uploads, device downloads, sharing (owner asked 2026-10-07)

Owner: "adding a pdf needs to be absolutely bullet proof." About 17 publishers refuse downloads from our cloud
servers, so the reader's device and network must be able to supply the PDF. Agent decisions (reversible unless
noted); design in [PDF uploads](architecture/PDF_UPLOADS.md).

| Decision | Choice |
|---|---|
| Add accepts | An arXiv ID or link (queued on the device, as before), a DOI, any landing-page or PDF link, or a reference, identified without a model by `functions/v1/add-paper` (no credits; conversion metered as today). Arrangement kept: the same sheet, field and Add button, plus a "PDF file" section. |
| Outcomes | Queued → the sheet closes. "Isn't openly available" → **Upload the PDF…** (attached to that paper) and **Download on this device** when a landing link is known. "Blocked" (with its reason) and an unidentified PDF link → **Download on this device**, or Upload. |
| Upload design | The initial signed/upsert branch was superseded during spending review. Reviewed local implementation uses authenticated **4 MiB chunks** through Edge, one immutable Storage send per admitted attempt, and a separate private `paper-uploads` bucket (octet-stream, 4 MiB/object). No client receives Storage write credentials. Freeze binds exact verified chunks, a separate idempotent transaction attaches the import, and the Cloud Run worker verifies complete size, SHA-256, PDF structure and pages before conversion. [Reservation/recovery contract](architecture/ASSET_SPENDING.md#local-ingress-implementation-checkpoint--2026-10-07). |
| Limits | Common asset ledger reserves staging plus all future processing phases before upload; every issued/uncertain physical write remains charged until safe confirmed deletion. 1 GiB owner-private allowance, 5 GiB common beta capacity, 10 active sessions/account and 200/environment, credits ≥1, 40 begins/hour, separate chunk/status rates, 24-hour pending expiry. Seven-day cleanup retires only unused finalized intents; active wanted imports and unknown physical bytes remain protected. Lifetime receipts/read ceilings also bound retained evidence. |
| Privacy | Converted only for the uploading account (owner-private document, `owner-upload-v1` approval; never shared, never reused by another account, never tagged). Preserve the originally approved **encrypted private title** plan. A separately versioned AES-GCM descriptor carries title/optional filename with device-held epoch keys; no new strict history event type. Shared catalog metadata stays neutral and immutable. The original branch's server-visible-title proposal is not implemented or approved. |
| New source kind | `upload:<id>` and encrypted descriptor refs belong to additive **v5** full/compact/query/hydration capabilities. Installed v2/v3 full and v4 compact/query/metadata reads must consistently filter unsupported rows/tombstones and strip descriptor refs. V5 uses a distinct dataset epoch and cursor identity; switching capabilities requires a fresh baseline. The compatibility integration and updated client queues are enablement gates. |
| Closed web papers | Recorded and split privately; their private paper fails at download as `not_open` (no automatic retry) so a reader's PDF supplies the same paper. Before: failed at metadata with no title. |
| Device fallback | Same checks as the server (https, public addresses on every hop, 64 MiB, `%PDF-`, one landing page followed), the app's ordinary request — no bot evasion. Offered inline on `source_blocked`/`pdf_restricted` web imports and in every failed web import's menu; links from the server (PDF locations, landing page, DOI). When the device is refused too: Open in Safari and share the PDF, or upload it. |
| Share extension | Writes to an **app group inbox**; the app imports on launch/foreground (PDFs to the upload queue, a link opens Add). Rejected: the extension calling the backend with a token from a shared keychain group (two processes refreshing one rotating refresh token sign each other out; extensions are a poor host for 64 MB uploads with retries). Items go to whoever is signed in when the app opens. iOS only for now. **Needs provisioning** (lead): App Group `group.com.sciencereader.ios` on `com.sciencereader.ios` and the new App ID `com.sciencereader.ios.share`, App Store profiles "Gradstep App Store" (regenerated) and "Gradstep Share App Store". |
| Migration number | `202610070039`, replacing never-applied 033; it must follow accounting/diagnostic prerequisites 034–038. 033 remains unused, with no placeholder migration. |

## Chat quality: equations, diagrams, Why it matters, a paper's chats (owner asked 2026-10-07; agent decisions, reversible)

Owner asked for chat quality fixes from the legacy gap audit's next tier (rows on the equation prompt, diagrams, "Why
it matters" and a paper's own conversations). Details: [chat](architecture/CHAT.md#diagrams).

| Decision | Choice (agent, reversible) |
|---|---|
| Equation prompt | **Explain** on a single equation asks "Explain this equation: ‹formula›", then after a blank line "Briefly cover the background needed to read it, its overall message, what each symbol means, and how its notation compares with common ML conventions." (the legacy prompt's four parts, one line). The formula comes first so the saved title (first 100 characters) still holds it: "Explain · ‹formula›"; `ChatTitle` drops the instructions whole or cut. "Single equation" = one closed formula and nothing but punctuation, displayed (`\[…\]`, `$$…$$`, an environment) or inline with a relation (`=`, `<`, `\leq`, `\approx`, …). A lone symbol or expression (`\(\beta\)`) keeps "Explain in plain terms, including any symbols". Explain on a formula in an answer uses the same rule. |
| Why it matters | `action: "relevance"`: no search tool and no search hold even with search on; the instructions say to use only the paper's own content (legacy: "Using ONLY the paper's content (do NOT search the web)"). The visible prompt is unchanged, so titles are too. Follow-ups in that chat may search. |
| Diagram rules | The legacy Mermaid label rules join the diagram instructions and the tool description (which said "plain Unicode" before; now ASCII). |
| Where diagrams are checked | **On device**, with the bundled Mermaid 12.1's `parse` in an off-screen web view, before the answer is saved. Server-side was checked and does not fit: Mermaid's parser alone bundles to 5.25 MB minified (esbuild, all diagram types; Mermaid loads them dynamically, so it can't be cut to one type without vendoring internals), over the 5 MB server-side bundling limit our deploys use (`--use-api`) before the chat function's own code; and its flowchart parser needs a DOM (`DOMPurify.addHook is not a function` under Node). |
| The retry and its cost | One retry per diagram, as a **separate metered request** (`action: "diagram_fix"`): one turn with the title, Mermaid's error (≤ 600 characters) and the source; no paper, conversation or search; only `create_diagram`; 2,000 output tokens. Held under the rate card and settled at actual metered cost. The deterministic test’s 1,400-input/600-output-token example costs 2 credits ($0.0088 provider spend); live repair cost has not been measured. Logged as `chat_answer` with `action: "diagram_fix"`. It cannot share the answer's own hold: the answer is settled before the device sees the diagram, and keeping it open would mean holding the stream for a device round trip. Never unmetered; a reader without credits (or an older server) keeps the original. |
| A diagram that still fails | Kept (the answer named it), and its view says "Couldn't draw this diagram" / "View the source below, or ask the chat to draw it again." with the source in a collapsed "Source" disclosure. The same fallback covers renderer unavailability, so it does not claim every failure proves a syntax error. |
| Chat title at narrow widths | Keep the same title menu and full saved/VoiceOver title; fit the visible label between the measured History/New chat touch targets. The shared-window measurement updates when the iPad column resizes. SwiftUI toolbar hosting roots do not share a global coordinate space, and a surrounding frame alone did not constrain the Menu's intrinsic label. |
| A paper's own chats | All chats gains a **This paper** chip, leading All · Paper chats · General (it is the one chosen; at the end it could scroll out of view at larger text sizes), with the count ("3 of 30 chats") under the chips when the four leave no room beside them. It is offered, and chosen, when All chats is opened from a paper chat (the chat's history button or its "…") or from the paper's "…" → **Chats about this paper** (shown when it has any); everywhere else (Library, Settings, general chat, Mac menu) opens on All as before. The chat title menu adds **Chats about this paper**: up to five of the paper's other chats (title, last used, messages) and "All N chats about this paper". |
| Not changed | The general answer length and style ("Lead with the answer… keep answers focused"): an open owner decision, since longer answers cost more credits. |

Deploy: the `chat` function must be deployed before a build with these changes ships (an older server rejects
`relevance` and `diagram_fix` as `invalid_request`, before any hold).

## Reader navigation: find, contents levels, figures, iPad chat column (owner asked 2026-10-07; agent decisions, reversible)

Owner: a reader navigation pass over [legacy gaps](LEGACY_GAP_AUDIT.md) 7, 10, 6 and 5. All additions: the page
arrangement, the Contents button, the figure sheet, the selection actions, Back and the default iPad arrangement are
unchanged. The Paper "…" menu gains Find in paper, Figures and (wide Reader only) Hide/Show chat.

| Decision | Choice |
|---|---|
| Find in paper (#7) | WebKit's own find bar (`UIFindInteraction`), from Paper › "…" › Find in paper and ⌘F with a hardware keyboard (iPad; the Mac keeps its Edit menu items). Only the paper's web view has it, not a figure's. WebKit highlights matches without touching the page or the selection, so no selection bar appears and blocks, quotes and positions are unchanged. The place find scrolls to is the reading position (it is where the reader is); on iPhone the page shrinks above the keyboard while the bar is up, and the found place survives closing the bar and leaving the paper (UI test). |
| Why find had been Mac-only | Not reproducible: with find on for every reader web view, `testFigureOpensFromTheSameVerifiedSnapshotWithLocalImages`, all of `PaperWebViewTests` and both figure UI journeys pass on the iOS 26.4 Simulator. The first Mac version set it to `Platform.isMac` (false on iOS), so no iOS run had used it before the `#if`; the failure seen was most likely the documented first-run page-load timeout on a freshly booted Simulator. |
| Contents levels (#10) | The bridge passes each heading's level and the Contents sheet indents by its distance from the shallowest level shown (18 pt per step, scaled with text size, at most three steps; top-level rows semibold when nested; VoiceOver hears "Level 2"). The title, "Abstract" and a printed "Contents"/"Table of Contents" heading are left out; References stays. Where Mathpix flattened levels — a section and its own subsection on one level, as DPO's "A" and "A. 1" — numbered headings take their depth from the number (port of the web app's `inferDepthFromNumbering`): "2.1.3" two below "2", "A.1" one below "A"; with Roman sections (two or more, one only Roman can be), capital letters one below and "1)" two below. Papers whose levels are consistent keep them (an "A Simple Baseline" subsection is not mistaken for an appendix). Pure section of `reader-bridge.js` (`CONTENTS OUTLINE`). |
| Figure gallery (#6) | Paper › "…" › Figures (shown when the paper has figures): a grid of the bundle's own verified images (first image of each, "+N" for more; drawn on white as in the paper), the number read from the caption ("Figure 3", "Fig. 2" → "Figure 2", "Table 1") and three lines of caption. A figure opens the existing figure view inside the gallery with previous/next and **Show in paper**, which closes the gallery and centers the figure in the paper with the citation highlight and Back; the saved reading position stays at the place left until Back or a screen's scroll away, as for citations. |
| iPad chat column (#5) | The wide Reader keeps today's default (chat 320–400 pt beside the paper). Paper › "…" › Hide chat gives the paper the full width; a chat button in the paper's bar (and Show chat in the menu) brings it back; a question asked from the paper (selection action, Ask about this paper, opening a paper chat or unsent draft, starting a new paper chat) shows it again. The divider can be dragged (a grabber on the hairline, 24 pt to grab; the panes change once when the drag ends, so a long paper isn't reflowed on every frame); double-tap restores the default; VoiceOver adjusts it in 40 pt steps. Chat 300 pt up to 60 % of the window, the paper at least 420 pt; clamped again on rotation. Hidden and width are kept per device (`UserDefaults`, like text size). Not `NavigationSplitView`: its columns can't be resized by touch on iPad and adopting it would change the panes' navigation stacks. Browse is unchanged (no chat column there). |
| Mac | The shared changes apply to the Mac window too (Find in paper and Figures in the Paper "…" menu, the hideable, draggable chat column). Mac menu-bar items for Figures and Hide/Show Chat are left to the Mac work (MAC_APP.md: every on-screen control has a menu item). |

## Pipeline worker billing (owner approved 2026-10-07, audit F1)

The Cloud Run worker billed ~22.6 instance-hours on 2026-10-07 (instance-based billing, `--no-cpu-throttling`, woken
every minute): about $54/month for a mostly idle instance. It now uses request-based billing (`--cpu-throttling`,
revision gradstep-pipeline-00007): every handler awaits its work before responding, so nothing runs unbilled after a
response. Expected at current volume: ~$0–3/month, mostly within the free tier. Next (approved): wake the worker when
work is queued, with a 10–15 minute sweep, instead of every minute; its design is shown to the owner before deploy.

## Offline-save recovery across app upgrades (2026-10-07)

The owner's build-15 offline-save banner was caused by build 14 saving library entries without the later tags and
import-progress fields. Local checkpoint format 3 marks that decoder boundary, so the next complete server
observation replaces an older readable snapshot without treating those omitted fields as a changed server revision.
For current-format caches, repair is restricted to those four display fields; immutable pins, membership, artifact,
availability and sequence checks remain enforced. Quarantine survives local copy removal and a repaired checkpoint.

The untested handoff also proposed rebuilding unreadable policy and a Try again button that saved only the latest
observation. Review removed those paths: they could forget a failed quarantine before an ordinary outage. A real
persistence failure continues to preserve bytes/private content, halt ordered cache installs and ask for reopening.
This is a client-only compatibility fix; no database migration, cache deletion, server rewrite or deployment is needed.
Local verification and remaining limits are recorded in [Native offline bundles](architecture/NATIVE_OFFLINE_BUNDLES.md#build-14--15-cache-upgrade-2026-10-07-local-review).

## Passage-linked conversations (owner asked 2026-10-07; agent decisions, all reversible)

Owner: conversations linked to the passage they came from — the paper ↔ chat loop the original app was built around
([gap 1](LEGACY_GAP_AUDIT.md#1-conversations-linked-to-their-passage)). Built in `Views/PaperPassages.swift`,
`ScienceReaderCore/PassageAnchor.swift` and the end of `reader-bridge.js`.

| Decision | Choice |
|---|---|
| What is saved | A `TextAnchor` on the new conversation's root event: artifact ID, the first block the selection touches (`elementID`), the quote exactly as asked (formulas as their LaTeX), and up to 32 characters of the paper's text before and after it (whitespace collapsed, read by the bridge with the same text rules as selections). No `page`. |
| Wire format | Unchanged (format 1, no bump). `anchor` has been a `PrivateEvent` field since the first build (`34100c5`), every build decodes it, and the frozen Node ↔ Swift fixture already carries one; builds before this simply never read it. It is inside the encrypted payload, so the service learns nothing new. Older conversations have no anchor; nothing is migrated. |
| Which actions | Explain, Why it matters, Related and Add paper on a text selection or a tapped formula in the paper. Not: chat-answer quote actions (Ask about this, Explain, Define — the text is the answer's, not the paper's), Ask about this paper, or a reference's "Ask in chat". Selection actions always start a new conversation, so continuing one adds nothing. |
| Go to passage | In the chat's title menu and its "…" menu, and on an All chats row (long-press, and a VoiceOver action), for anchored chats whose paper is in the library. Opens the paper if needed, keeps the conversation as the chat's, waits for the reader like a contents jump, centers the passage and tints it for ~2.6 s, and offers the citation **Back** to where reading left off. Unlike a citation peek, the passage then becomes the remembered reading place (as a contents jump does). A request not applied within a minute is dropped. |
| Finding it | Same artifact: the exact quote, preferring its block. Otherwise, or if that fails, the legacy cascade: exact quote → collapsed whitespace → the quote's first line and its 80/60/40/25-character openings (≥ 20 characters) → the text between the saved prefix and suffix (each ≥ 8 characters, within max(400, 2 × quote) characters). Several matches: the one in the anchored block (same artifact only), then the one with matching context. Nothing: "Couldn't find the passage this chat came from. The paper may have changed since." A paper no longer in the library: "The paper this chat came from isn't in your library." |
| Marks | CSS custom highlights (no element added, so selection, citations, figures and reading positions are untouched): a 2 pt accent underline at 50 % (55 % lighter in dark mode). A formula, which is drawn rather than text, gets a line under it (inline) or a bar beside it (display). Marks use exact and collapsed-whitespace matches only, including anchors from an earlier conversion of the same paper. |
| Tapping a mark | Opens its conversation; several on that spot offer "Chats about this passage". Links, citations, contents rows, figures, references, tags and formulas keep their own taps, and nothing opens while text is selected. A marked formula therefore still selects on tap; its chat is reached from the chat or All chats. |
| Setting | Settings › Reading › **Underline passages with chats** (on by default; this device only). Cheap, so included. |
| All chats | With the Paper column shown (iPhone landscape, iPad), an anchored row's muted second line is the passage in quotes (math readable) instead of the newest answer; in iPhone portrait the second line stays the paper's title. The title still reads "Explain · ‹passage›". |
| Not done | Marks aren't announced by VoiceOver (Go to passage is reachable); the browser reader doesn't show marks yet, and the Mac app shares this code but was only compiled, not run; passages are found again by text only, not by position within a re-rendered artifact. |

## Purchase verification runtime deployed (owner approved 2026-10-07 evening)

Supabase's hosted Edge runtime lacks certificate primitives Apple's verifier needs, so no Sandbox purchase had ever
been recorded. Apple verification now runs in a private Node 24 Cloud Run service `gradstep-store-verifier`
(revision 00002-qqz; IAM-only, one invoker `gradstep-store-caller`; request billing, max 1 instance, scale to zero;
design cap $6/month of the $100 budget). Supabase still authenticates, admits (migration 033, one-use attempts,
app 50/account-hour, 500/hour, 300/day, 3,000/month; notifications 60/200/1,000) and records credits. Apple
signature, chain, bundle/environment and online revocation checks stay on, with the reviewed OCSP-freshness patch.
Deploy-tool fixes made during rollout: readiness runs as service_role in a read-only transaction; secret readback uses
the API's digest field (`value`); function readback records `ezbr_sha256` (compressed) instead of comparing it to the
decompressed bundle (module sources are compared exactly); the health probe uses the project's `sb_secret_` key.
Rollback: `worker_set_store_verifier_enabled(channel, revision, false)`, then roll the service back; never skip checks.

## Spending controls deployed to staging (owner approved 2026-10-07 evening: "I approve it", "velocity first")

Migrations 034–038 applied after an encrypted backup (`.artifacts/backups/20261008T023921Z-…`). All Edge functions
redeployed from main; pipeline worker cut over through the evidence-checked path: paused revision 00008 → readiness
(blockers cleared: tagging and platform budget paused for the cutover, asset inventory enforced, operator drain
evidence verified) → activated revision **gradstep-pipeline-00009-ncq**, then budget, tagging and the pipeline re-enabled.
- Asset inventory: new `scripts/asset-inventory.py`; scan 48a97cd0… registered 100 manifests' members, 1,119
  objects, 0 discrepancies; enforcement on with **legacy** reader delivery (installed apps keep signed URLs).
- Tavily allowance period configured from the usage API (Project plan, 37/4,000, PAYGO off): Oct 1–Nov 1 UTC,
  limit 3,900, baseline 37. Native (Anthropic) search fallback stays off under the new accounting.
- Drain evidence: `.artifacts/rollout-evidence/20261008-spending/` (Cloud Run instance metrics, Edge deploy ages
  > 400 s, function readback, zero open liabilities), manifest is an operator attestation by the lead agent.
- Tooling fix: `scripts/pipeline_readiness.py` reads service-role-only readiness in an explicit read-only transaction.

## Uploads deployed to staging (owner: "integrate, velocity first", 2026-10-07)

Migration 039 applied (backup first); functions `add-paper` and `upload-pdf` deployed with the private
`paper-uploads` bucket (4 MiB authenticated chunks); worker revision gradstep-pipeline-00010 reads uploads. A
scope-2 asset inventory (both buckets, 0 discrepancies) satisfied 039's gate and the PDF upload policy is enabled.
Private upload titles use the encrypted library descriptors (Codex), so they are not server-visible.

## Browser reader and Mac TestFlight shipped (owner authorized; agent decisions 2026-10-07, reversible)

- Browser reader on its own origin `https://app.gradstep.ai` (Pages `gradstep-app`, staging backend);
  `gradstep.ai/app/*` 301-redirects there. Deploys go through `scripts/deploy-web.mjs`, which refuses a non-staging URL,
  a non-anon key, any `.env.staging` credential in the output or a weakened `_headers`.
- `Cache-Control: no-transform` on all reader responses so Cloudflare's zone-level Web Analytics does not inject its
  beacon (no third-party scripts in the reader; the CSP refused it anyway). The info site keeps the beacon.
- `https://app.gradstep.ai` is in `infra/staging.json` `admin_origins` (the Edge `ADMIN_ORIGINS` list), and staging
  Auth's redirect allowlist gained `https://app.gradstep.ai` and `/auth/callback` for later web OAuth (appended).
- Mac TestFlight uses its own build-number train (Mac build 17 alongside iOS build 17), internal testing only; no
  macOS App Store version was created because the upload did not require one.

## Build 16 #1, #8, #10 and build 17 #2 (agent decisions 2026-10-08, reversible)

- **Credit resume is state-driven, not event-driven.** A sweep restarts an account's imports waiting on credits
  whenever its spendable balance covers them, so every way a balance grows counts (purchase, restore, reversal, owner
  grant, tester credits, a plan period that starts, a hold released); a balance increase only wakes the worker.
  Oldest first, **skipping** an import the balance cannot cover (a later, smaller one may start), with the needs of
  already restarted, unfunded imports counted against the balance. Download-stage waits need 1 credit (016's
  admission). Suspended/closed accounts are never restarted.
- **arXiv fallback is arXivRaw (OAI-PMH), not OpenAlex.** The stage already fetches arXivRaw for license evidence;
  its record matches the Atom API's (tested on a real fixture) and needs no extra request. OpenAlex cannot supply
  the arXiv license evidence shared reuse requires and lags new arXiv papers. Throttled metadata waits ~55 min
  (10 tries, Retry-After honored) before failing, shown as waiting.
- **Tavily results are no longer citable** (prompt cache, see CHAT.md); the server's fallback source list is the
  searched pages. Action instructions moved after the paper. Related's first status is sent before the model round.
- **Self-healing (041):** metadata and render failures retry 6 times over ~23 h (10 min … 12 h); downloads keep
  027's 15 min / 2 h / 12 h; paid stages and permanent refusals never retry automatically. A non-paid stage
  unchanged for 6 h while someone waits is failed with its reason (then retried). **Terminal failures stay in the
  library indefinitely** with their reason and actions (Retry when retryable, supply the PDF when not open, Remove);
  nothing is deleted on the reader's behalf. Budget pauses and a full store are deliberate waits, shown as waiting.
- **App follow-up (not done here):** the app ignores `auto_retry_at` on non-download failures, so a metadata
  failure being retried reads "Details unavailable · Retry" until it succeeds; showing "Trying again automatically"
  for any failed import with `auto_retry_at` is display-only app work.

## QR device approval (owner asked 2026-10-07: "a way to avoid the recovery code, maybe QR"; agent decisions, reversible)

A new browser is approved from the owner's phone instead of typing the recovery code. Design and limits:
[PRIVACY_AND_SYNC.md](architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr).

| Decision | Choice |
|---|---|
| Primary path | The browser's restore screen leads with **Approve from your phone** (QR + six-digit number); **Use recovery code instead** is one tap away and reuses the same pending request. |
| QR contents | `GSDA1.<request id>.<account tag>.<fingerprint>.<kind>` (97 ASCII characters): the existing 32-byte enrollment fingerprint (account, recipient device, public key, challenge), a 16-byte hash naming the account, and the device kind for display. No secret, no account ID, no URL. |
| What stops a key swap | The approving device recomputes the fingerprint from the server's request and refuses any mismatch before wrapping anything. The six-digit number (derived from the fingerprint) is for people; the QR carries the full 256 bits. |
| Without a camera | Banner "A new device is waiting · Review" on an approved device, comparing the six-digit number only. Documented as weaker (a server able to grind ~10⁶ keys could match six digits); scanning is preferred. |
| Backend | No migration: `v1_request_enrollment`, `v1_enrollment_requests`, `v1_approve_enrollment` and `v1_key_state` (002) already suffice. Expiry stays server-side (15 minutes); the browser renews for the same recipient, so the number never changes. |
| QR drawing | `uqr` 0.1.3 (MIT, a port of Nayuki's QR generator, zero dependencies), as an inline SVG; no network or CSP change. |
| Camera | AVFoundation (works on iPhone, iPad and Mac Catalyst); `NSCameraUsageDescription` and the Mac sandbox `com.apple.security.device.camera` entitlement added. No prompt on a device without a camera. |
| Not done | A new **Mac or iPad** showing its own QR (the native restore screen still uses the recovery code); approving from the browser; a device name beyond its kind. The browser path needs an iPhone/iPad build with Add a device. |
