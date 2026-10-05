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
