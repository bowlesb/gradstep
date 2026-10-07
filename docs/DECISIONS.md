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
- **Keyboard and pointer** (iPad, Mac): ↑/↓ choose a row, Return opens it, Escape lets go; hovered rows get a quiet
  fill; the header stays pinned.
- **Stopped imports never just sit**: the status reads in plain words ("Download failed") and the row shows one action
  as a small button — **Retry** when the server can run it again (download, details, rate limit), **Get credits** when
  conversion waits for credits, otherwise **Remove** (too large, unreadable PDF…; nothing to retry). It sits in the
  Progress cell, or under the title when Progress isn't shown; the List shows the same button. The long-press menu
  and swipe say Retry / Remove (Cancel import while an import still runs). Tapping Retry shows the row
  **downloading again at once** (finding, if its details were never found), from the queued retry command, until the
  server's own state arrives. Automatic server-side retries are out of scope here.
