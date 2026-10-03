# Implementation sequence

Status: product decisions approved; foundation implementation underway. No delivery milestone below is complete merely because its design exists.

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

## 6. Public release preparation

Resolve beta reports, finalize subscription allowances/copy, validate privacy disclosures and provider terms for the exact deployment, prepare listing/screenshots/support URLs, and present the release candidate for the agreed user review. A browser reader is included here only if selected for launch; otherwise preserve protocol compatibility without promising a delivered web reader.

## Work intentionally absent

No NAS database migration or ongoing NAS dependence. No borrowed TextBrain user store, automatic schema creation on requests, plaintext fallback chat table, unlimited admin API key path, provider URL used as permanent asset storage, or claim that realtime notifications alone implement offline sync.
