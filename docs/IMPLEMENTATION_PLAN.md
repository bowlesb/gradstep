# Implementation sequence

Status: direction revised 2026-10-13. No delivery milestone below is complete merely because its design exists.

## Current next sequence — arXiv HTML and device-only PDFs

The [HTML-first architecture](architecture/HTML_FIRST_READER.md#cutover-and-verification-sequence) supersedes the
server PDF/OCR steps in the historical plan below. Steps 1–4 are implemented and deployed on staging; the browser path is deployed with its existing RAM-bundle policy, and the native clients passed internal release verification. The remaining work is durable browser offline bundles, wider device/HTML quality coverage, the future local PDF model and later public-release review. Original dependency order:

1. Deterministic arXiv HTML adapter, honest bundle/profile provenance, source/asset validation and golden fixtures.
2. PDF-independent membership/read protocol and native local storage/intake; existing reader and selection parity.
3. Versioned local-context paper chat with unchanged encrypted history and server-enforced spending.
4. Server-side PDF/upload/Mathpix admission stops and stale-worker fencing, including old-client requests and
   outstanding provider-liability reconciliation; no bulk data migration or unrequested cleanup.
5. Browser acquisition feasibility, profile/local-storage support and offline/chat parity.
6. Coordinated rollout with zero-server-PDF network/storage evidence, privacy-copy updates and owner acceptance.

Physical iPhone work remains paused. A local model for challenging PDFs follows as a separate quality/license/
device-performance milestone. Initial missing-HTML cases retain a local original/source action without cloud OCR.

## Immediate usable-app checkpoint — 2026-10-04

Historical plan; it does not authorize new server PDF or Mathpix work after the 2026-10-13 decision.

The owner asked whether the project will reach a working app. Completion must be
measured by one real journey, not the count of isolated proofs. Close the current
authored chat-rendering proof, then prioritize the following dependency order.
The existing source-text display remains usable while rich native chat adoption
has its separate lifecycle/layout work; it must not block connecting an answer.

1. Connect one bounded arXiv import action: existing Linux supervisor, reviewed
   012 grants/receipts, captured metadata parser and 011 library projection.
   Follow with original acquisition, Storage and verified PDF publication.
   Initial execution may be serialized to one active paper, while ownership,
   fencing, quotas and retry semantics remain the final contracts.
2. Implement the additive paid OCR protocol already designed in
   [MATHPIX_PIPELINE](architecture/MATHPIX_PIPELINE.md): immutable quote/consent,
   ledger holds, one-time submission grant, uncertain-outcome reconciliation,
   durable raw output/asset collection, exact-byte sharing and publication.
   Provider transport alone is not this workflow; do not enable its paid switch
   before its transaction and failure schedules pass.
3. Publish actual Mathpix provenance and a complete reader artifact, expose an
   authenticated bounded download and connect it to the native verified
   encrypted installer. The Edge renderer `timestep-mathpix-mathml-v1` and its
   native profile exist ([READER_RENDERER](architecture/READER_RENDERER.md));
   no Edge Function calls them yet.
4. Connect one metered paper-question route with captured consent/context,
   server reservation, provider usage settlement and encrypted assistant-event
   storage. The current Send path saves/syncs the user event but calls no AI.
5. Verify one real sign-in path and the complete journey on Simulator, then on
   the phone only after the owner resumes physical-device work. Google and email
   remain launch requirements, but both need not precede the first owner journey.

Acceptance: **Add an eligible equation-heavy paper → one charged conversion →
authenticated download → offline equations/figures → one charged answer →
terminate/reopen with the answer intact.** Re-adding identical eligible bytes
must reuse the conversion without another OCR charge. Preserve the approved
privacy, budget, identity and data-layout rules throughout. StoreKit products,
broader search, admin hosting and browser delivery remain committed work after
this first usable journey, rather than prerequisites to testing it.

Known external readiness gaps are an owned Linux deployment destination,
dedicated Mathpix/AI-provider access with verified rate/retention settings, and
actual provider sign-in acceptance. The stopped local VM, fixture providers and
auth configuration readbacks do not satisfy those gaps. Local implementation of
the adapter and OCR protocol can continue before these account inputs arrive.
The separate [deployment manifest](architecture/DEPLOYMENT_MANIFEST.md) records
Google console, SMTP/domain and Apple provisioning requirements.

## 0. Architecture checkpoint

Record key-custody and browser launch decisions. Review the data model, tenancy rules, sync semantics, monetary invariants, provider privacy constraints, compatibility strategy, and backup destination. Confirm live billing/account capabilities and a costed deployment manifest before provisioning. The user emphasized that infrastructure decisions must not be deferred into temporary schema/hosting shortcuts.

Deliverables: updated architecture documents; reviewed initial migration proposal and RLS/access matrix; versioned API/crypto format contracts; dependency/hosting choices with cost; no production customer data used as a test fixture.

## 1. Representative technical prototypes

Build the native paper rendering/selection prototype while preserving the UX map. Process a bounded fixture set covering equations, wide tables, references, figures, scanned pages, and long appendices. Measure CPU, memory, conversion latency, bytes, and provider costs. Persist complete bundles and render with the network off.

Prototype the selected encryption/recovery and two-device sync behavior before building the full UI on top of it. Use provider stubs for retry/timeout/credit cases. Prototype app screenshots of WKWebView content and the report preview.

Exit: decisions about local storage, bounded worker stages, image handling, anchors, and key workflows are supported by running evidence. If a core proposal fails, update its design before broad implementation.

## 2. Backend foundation

Implement reviewed migrations, grants/RLS, access RPCs, buckets, durable jobs, credit/spend ledger, verified entitlement storage, support API, and operator roles. Deploy to dedicated staging after local tests. Make the full environment reproducible from versioned configuration and secrets supplied separately.

Exit: two-account isolation, concurrent shared imports, worker lease fencing, uncertain-provider reconciliation, concurrent near-limit spending, billing-event replay, and support access tests pass. No production service depends on the NAS or TextBrain tables.

## 3. Native end-to-end reading

Implement library, feed, reader/browse modes, figures, chat/history/diagrams, settings, import, downloads, and annotation workflows in the existing arrangement. Connect the encrypted store and outbox to Supabase. Public catalog processing and private conversation persistence stay on their respective paths.

Exit: import → ready article → read → selected passage → conversation → offline annotation → second-device recovery/sync works with real fixtures; visual/interaction parity checks pass.

## 4. Metered AI, subscriptions, and administration

Connect paid operations through the budget gate; add cited answers and private generated artifacts. Benchmark the two provisional subscription tiers and set explicit rate/allowance versions. Verify StoreKit sandbox purchase, renewal, restore, refund, and out-of-order notification paths. Build admin usage, expenses, subscriptions, processing-health, shared-cache, and audit views.

Exit: dashboard totals reconcile with the ledger/provider measurements; client requests cannot raise their own credit limit; duplicate charges and grants are prevented; interrupted work is reconciled.

## 5. Internal feedback and TestFlight

Complete capture/note/upload, report/reply/status, scoped developer CLI, and build links. Run physical-device checks, restore drill, offline/reconnect tests, privacy/log inspection, accessibility checks, and limited live-provider smoke tests. Establish actual beta cost monitoring.

Create/sign the Science Reader app identity and internal build using the user's Apple account where available. Credential presence does not prove permission to create the new app or submit it; verify that capability before relying on the release lane. Prepare any required account-side actions concretely.

Exit: installed TestFlight app points to the intended backend, shows correct environment/build, completes the core workflow, and can send a report that the developer reads/replies to and the tester sees in-app. Backend/admin deployments and restore instructions are documented.

## 6. Browser reader

The user authorized building and deploying the browser reader after the iOS delivery, including if they are away (2026-10-03). Reuse the reviewed catalog/import, metering, encrypted-event, and recovery contracts, plus the same workflow fixtures. Build against the dedicated backend; the archived NAS application is reference material, not a deployable shortcut. Test WebCrypto interoperability, OAuth redirects, browser key storage/recovery, two-surface sync, accessibility, offline assets, and deployment before claiming delivery. Hosting credentials/destination and costs remain to be verified within the agreed budget.

## 7. Public release preparation

Resolve beta reports, finalize subscription allowances/copy, validate privacy disclosures and provider terms for the exact deployment, prepare listing/screenshots/support URLs, and present the release candidate for the agreed user review. Browser deployment authorization does not replace the agreed review before public App Store release.

## Work intentionally absent

No NAS database migration or ongoing NAS dependence. No borrowed TextBrain user store, automatic schema creation on requests, plaintext fallback chat table, unlimited admin API key path, provider URL used as permanent asset storage, or claim that realtime notifications alone implement offline sync.
