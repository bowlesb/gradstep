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
