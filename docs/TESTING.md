# Fast and slow tests

Local AI is an explicit native/Metal tier, never part of routine `npm test`: `swift test --package-path apps/apple/LocalAI --filter ModelStoreTests` checks local model integrity; Core's `LocalAIContextTests` checks
bounded context and cloud-serialization rejection. `LocalAIJourneyTests` exercises the Cloud/Local choices and
encrypted explanation reopen using a deterministic inference fixture. Actual MLX quality and memory are measured
with the opt-in `LocalAIProbe` on Mac, including a network-denied run. Protocol and failed cases are retained in
[Local AI comparison](reviews/LOCAL_AI_20261017.md). Simulator success is not phone inference acceptance.

Owner direction, 2026-10-13: run fast checks routinely; run slow checks once for a baseline, then selectively for
related changes or a reported problem. A slow run is not a prerequisite for an unrelated edit. Save failures and
turn a discovered bug into a small fast regression where possible.

## Commands

Install root and browser dependencies with `npm ci` and `npm ci --prefix apps/web` (Node 24+).

| Tier | Command | Scope |
|---|---|---|
| Fast, default | `npm test` or `npm run test:fast` | Backend contracts, browser units, authored bundle/crypto fixtures, compiled device-reader freshness, web deploy gates and the arXiv acknowledgement/User-Agent check (`tests/operations/`). No browsers, downloads, databases, Simulator, credentials or paid calls. |
| Fast, targeted | `node --test tests/backend/arxiv-html.test.ts` or `npm run test:fast --prefix apps/web -- tests/bundle.test.ts` | Exactly the selected files. `test:backend` alone runs all backend contracts. |
| Paid, chat visual | `node scripts/chat-live-smoke.mjs --question="…as a visual I can read on my phone"` | The live chat on staging with a question that invites a visual answer; prints the `visual` event's title, size and elements (about $0.25). Run after a change to the visual tool, its sanitizer or the chat prompt. |
| Paid, explicit: figure view | `node scripts/chat-live-smoke.mjs --figure-view=1 --warm`, or `--paper=2610.16784v1 --index=<bundle>/reader.json --figure-view=4 --table-view=1` | The figure view's two requests (FIGURE_VIEW.md) on staging from a `figure_view` device: the image prepared as the browser prepares it, the walkthrough's sections and boxes (drawn on the image under `.artifacts/figure-view/`), one part again more simply, credits, seconds and cache use in a JSON record. `--warm` asks a chat question first to show the shared cache; `--table-view` renders a table from the bundle as an image. About $0.25 the first time a paper is cached, $0.05 per figure after. Run after a change to `chat-figure-view.ts` or its instructions. |
| Paid, chat figure | `node scripts/chat-live-smoke.mjs --figure=1 --question="What does Figure 1 show? Walk me through each part of it."` | The live chat on staging with DPO's Figure 1 attached under consent v3; prints the attachment, the `figure_parts` boxes and the answer (about $0.25 uncached). Run after a change to figures, the parts tool or the consent. |
| Slow, device compile | `node scripts/reader-device-compile.mjs --ids=2610.15542v1,…` | The whole device path for cached papers in headless Chromium: the shipped compiler plans the assets, the script fetches them once (cached under `.artifacts/reader-sweep/assets/`), the compiler admits or rasterizes them under the pixel budget and composes the bundle. Prints ok (bundle size, images, and how many figures the device couldn't prepare: "N not shown", each a note in the paper since revision 15) or the reason code. Run on every paper the owner reports, and on the sweep's corpus before a reader build: the sweep converts the HTML only and cannot see an image refusal (Apertus 1.5, build 42). |
| Slow, reported-paper native replay | Set `TEST_RUNNER_SCIENCE_READER_HTML_CASES` to an absolute JSON file path, then run `xcodebuild test … -only-testing:ScienceReaderTests/ArxivHTMLReaderTests` on a Simulator | JSON entries contain `source_id`, `source_revision`, `title`, `authors`. Replays the sweep's cached HTML and device-compile assets through native WebKit and independent Swift admission; missing cached files fail without making a network request. Opt-in only; no paid AI or physical-device access. |
| Slow, reported-paper Library acquisition | Set `TEST_RUNNER_SCIENCE_READER_LIVE_LIBRARY_CASES` to the same JSON format (1–3 papers), then run `xcodebuild test … -only-testing:ScienceReaderTests/LibraryModelTests/testReportedPapersDownloadInstallAndOpenThroughTheLibrary` on a Simulator | Real native URLSession downloads started together through Library preparation, encrypted installation and opening the saved copies. Account backend is a local fixture. This makes direct arXiv requests from the Simulator, never from a server; opt-in only. A pass does not reproduce a physical phone's network, OS, memory or prior local state. |
| Slow, reader sweep | `node scripts/reader-sweep.mjs --recent=25 --from-staging=40` | Fresh real papers (newest listings in cs.LG/cs.CL/cs.CV/cs.AI and the staging library) compiled with the shipped device compiler; header and structure invariants and refusals, with a JSON report under `.artifacts/reader-sweep/`. Paced like the app (3 s per document); sources cached. Run before every build that changes the reader or compiler; a refusal or a `fail` finding is triaged into a fixture before shipping. `--replay=<report.json>` reruns a report's papers from the cached sources (the same corpus before and after a change); `--ids=…` picks papers. |
| Slow, paid, podcast device source | `node scripts/podcast-device-smoke.mjs [--profile=podcast-5min-v1]` | One private episode from the DPO text as a device sends it, on staging, with a disposable account (deleted after): source, quote, start, status, paper lookup, transcript. About $0.20 of provider spend. Run after changes to the podcast quote, claim, publish or worker source handling. |
| Hosted, fault drill | `node scripts/fault-drill.mjs --provider=anthropic --mode=throttle --route=chat --minutes=5` | Staging only, with the functions deployed with `FAULT_INJECTION=on` (infra `fault_injection`). A disposable `@example.invalid` account gets a 5-minute Anthropic throttle on chat; the script checks the reader sees `provider_unavailable` with `retry_after`, is charged nothing, the library still loads, two `drill` rows reach the provider-health telemetry, and chat answers again once the fault is cleared (one real answer, about $0.005); deletes the account. Report under `.artifacts/fault-drills/`. Rerun after a change to `provider-health.ts`, the chat retry or migration 073's fault rules ([RESILIENCE.md](architecture/RESILIENCE.md#fault-drills)). Since 2026-10-16 also `--mode=midstream` (the provider fails after the first text: nothing charged, the text kept), `--mode=stop` (Stop recorded → charged for what was written; dropped connection → nothing; a build without `stop_signal` → charged as a Stop) and `--mode=overrun` (an anomaly row, `work_enabled` stays true, chat still answers); each reconciles its synthetic attempts to zero; about $0.0003 each. Rerun them after a change to how answers are charged ([CHAT.md](architecture/CHAT.md#when-an-answer-stops-early--2026-10-16)) or to migration 079's rules. |
| Slow, on-device PDF route | `node scripts/device-route-eval.mjs --fixtures <dir> --conformance <bundle_conformance.py>` | The experimental on-device model (docs/architecture/DEVICE_PDF_ROUTE.md) on this Mac: builds `DevicePDFRouteTool` (the app's text layer, Core ML models and converter), converts each fixture PDF and runs the desktop's `bundle_conformance.py` on the trace; one row per paper and `.artifacts/device-route/summary.json`. Needs `node scripts/device-models.mjs` (the models, checked against `apps/apple/device-models.lock.json`) and the desktop's fixture set copied locally (read-only). Run after a change to the text layer, the host, the converter or the models. In the Simulator: `TEST_RUNNER_DEVICE_PDF_FIXTURE=<paper.pdf>` with `ScienceReaderTests/DeviceModelRouteTests`, and the journey `DeviceModelJourneyTests`. |
| Slow, reader journeys | `npm run test:slow` | Production-CSP browser compiler, complete HTML reader/chat admission, local PDF worker and membership/reselection cases. Local fixture backend only. |
| Slow, real corpus | `npm run test:slow:corpus` | Offline replay of eight exact arXiv revisions through Chromium, Firefox and WebKit; independent bundle verification, math/images/fragments, device-only PDF intake/reload. |
| Slow, native | `npm run test:slow:native` | iPad Simulator with release optimization (`-O`, whole-module): WKWebView compiler, concurrent multi-image acquisition, PDF admission, locked/over-limit PDF rejection, real-PDF PDFKit rendering and encrypted store reopen. Never selects a physical device. |
| Pre-build UX review | `node scripts/ux-review.mjs` | Browser sign-in, library, reader and every chat state on the fixture backend, desktop and phone, light and dark; contact sheet at `.artifacts/ux/web/index.html`. Native screens: `scripts/visual-check.mjs`. Process and findings: [UX_REVIEW.md](UX_REVIEW.md). |
| Paid, explicit: live study | `node scripts/chat-live-smoke.mjs --study` | The same disposable account and numbered DPO context, tutored: the opening turn, a partly right answer and a "don't know"; prints each turn's reply and the knowledge map after it (concept states, focus, next step, journey). About three Sonnet answers and three Haiku map updates (about $0.30). Rerun after `chat-study.ts` or tutor-prompt changes. |
| Paid, explicit: model check | `node scripts/chat-live-smoke.mjs --profile=deepseek-auto-standard --eval` | The recorded check a chat model passes before it is offered (CHAT.md "Recorded check of DeepSeek"): four DPO questions in new conversations with that profile (`auto` effort allowed); every math segment typeset with the browser's temml, `[¶N]` citations resolvable, a visual or diagram, Figure 1 attached and read from the image with parts, streaming; then each quote and provider attempt from the database. Writes `.artifacts/chat-eval/<time>-<profile>.json`. About $0.04 on DeepSeek, $0.30 on Sonnet. Rerun for a new model or a prompt/tool change that could affect it. |
| Paid, explicit: live chat | `node scripts/chat-live-smoke.mjs --questions=2` | One disposable staging account, the DPO v3 metadata membership, one or two real questions with a numbered local context; prints citations (and whether each resolves), follow-ups, credits and the answer; deletes the account. About $0.25 of provider spend per run; needs `.env.staging` and a compiled `reader.json` for 2305.18290 (`--index`). Rerun after chat function or prompt changes, never routinely. |
| Saved evidence | `npm run test:status` | Shows last result, duration and whether tested source has changed. Does not rerun anything or turn stale evidence into a pass. |

`test:slow` accepts Playwright selectors, e.g. `npm run test:slow -- --project=desktop --grep reselection`.
The corpus command accepts the same flags. `READER_CORPUS_SET=<name>` runs an ad-hoc list instead of the pinned
corpus: `tests/corpus/<name>.json` with its `<name>-lock.json` (fetch with the same variable and `--update-lock`;
`owner-20261014` is the owner's nine October papers from the 2026-10-14 report, kept as an audit set, not evidence
for the pinned corpus). Selection flags are recorded in the run report; a selected run is not
evidence for the whole suite. Native flags may override the default iPad Simulator destination.

For native paper-acquisition regressions, also pass `SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule`
to direct `xcodebuild test` commands (the native tier already does). Build 64's `invalid` failure reproduced only
with optimization: a successful async image result lost its index in a returned tuple inside `do/catch`, so
multi-image papers failed while the old one-image fixtures passed. The new
`ArxivHTMLReaderTests.concurrentImagesKeepTheirSlotsAndOnlyTheMissingFigureIsOmitted` is a no-network regression
for that exact failure; it was verified failing before the fix and passing after. The fixture host still uses
Debug-only account fixtures, but the Swift optimization and compilation mode match TestFlight. A debug-only
pass is insufficient evidence for a reported failure in a distributed build.

The existing full browser `npm run e2e --prefix apps/web`, standalone podcast E2E, Swift Core, complete Xcode,
database (`test:database`), operations and hosted checks are also **slow / explicit**. They keep their existing
commands and prerequisites. There is deliberately no default command that launches all infrastructure checks.
Hosted or metered checks retain their existing authorization and budget rules; these new suites never call providers.

Live chat acceptance requires a successful terminal event and text or a validated usable tool result. HTTP 200
with an SSE error, missing `done`, or an empty result fails `chat-live-smoke.mjs`. Its `--no-auxiliaries` flag isolates
the chosen model from title/follow-up calls when diagnosing a provider; that isolation is not evidence that those
extras work. The scheduled `chat.smoke` reads the published profile recommendation and consent, then requires the
answer to name that model. A hidden-route check does not establish that ordinary clients can select it. After a
provider-policy or endpoint change, rerun the affected hosted actions and reconcile actual costs/unknown holds;
earlier green checks for another endpoint do not establish current availability.

The database suite (`npm run test:database`) expects a disposable PostgreSQL 18 server on `127.0.0.1:55431` (binaries
at `SCIENCE_READER_PG_BIN`). Create the cluster with `initdb -A trust -E UTF8 --locale=C` (a `--no-locale` cluster is
SQL_ASCII and migration 032's collation fails) and start it with a short socket directory, e.g. `-k /tmp/srpg` (a long
path exceeds the macOS socket limit). Post-cutover tests such as `tests/database/chat_follow_up_quotes.sql` run in the
final phase with migration 058 and later.

## Corpus setup and boundaries

### Import acceptance before TestFlight (2026-10-17)

`npm run test:imports` is an explicit, unpaid iPhone Simulator gate with `-O` and whole-module compilation.
It runs the actual Library model, native URLSession response handling, WKWebView compiler, independent bundle
validation, encrypted installation, and reopen from a fresh store. Only the account backend and HTTP responses
are fixtures. Unmatched source requests fail offline. Cases cover repeated taps, out-of-order assets and a missing
image, failed open without sync retry loops, explicit retry, cancellation, and absent HTML followed by PDF
download/presentation and encrypted offline reopen. A real local PDF goes through the Files import controller,
becomes a Library item and reopens; a damaged PDF is rejected without creating an item. It also replays all seven reported papers in
`tests/corpus/import-regressions.json`, including DocPilot's algorithm/math badges, More Methods' absent HTML and
FDE-Gym's leaked font preamble (including assertions that the unwanted text is absent).
The Library row-height check renders the actual Library view.

Build 66 feedback adds six session-boundary checks to the seven import methods (13 required, none skipped):
deleted-session refresh, exact rejection of an unexpired token, transient offline identity retention, model retirement
without erasing encrypted files, rejected chat admission, and the native sign-in/restart screen journey. Backend
authentication code and these tests are included in the gate fingerprint. A local import pass alone cannot certify
that cloud actions still work after account deletion. The separate unpaid `node scripts/smoke-session-revocation.mjs`
creates two hosted synthetic sessions, deletes their account through the deployed function, verifies the other
session's refresh/RPC rejection and the login's removal. It sends no mail and makes no paper/provider requests.
It then re-admits the exact same synthetic address as a fresh UUID, generates an unsent code, performs the app's
email-code exchange and an account RPC, and deletes that fresh fixture. Evidence is timestamped under
`.artifacts/auth-lifecycle/`. This acceptance covers re-admission; it does not test SMTP delivery or impersonate a reader.

Both TestFlight upload scripts require a successful report for the current import code, fixtures and Xcode version,
before archiving and again before uploading.
Zero selected tests, skipped cases, missing corpus bytes, a failed run, or source changes during a run all fail the
gate. Matching covered files reuse their evidence; changes outside those files do not require this slow suite.
The shared `RootView.swift` is covered because it contains the Library view. Results and
screenshots live under `.artifacts/import-acceptance/`. This does not certify a physical phone or an untested OS.

The public papers' source responses are cached only on this development device, under `.artifacts/import-corpus/`.
To populate a missing cache, run `node scripts/fetch-import-regressions.mjs --on-this-device`. Every response has a
pinned byte count and SHA-256; changed source needs review rather than silently replacing a regression. No server
acquires or processes PDFs, and no model call is involved. The exact response body of a historical 404 may change;
retain the recorded cache rather than treating a newly downloaded error page as equivalent evidence.

On the user's local development computer, run **once**:

```sh
npm run test:slow:fetch
npm run test:slow:corpus
npm run test:slow:native
```

Fetch is explicit and refuses CI/Cloud Run environments. It uses only official exact-revision URLs, no redirects,
bounded downloads, a single request at a time, and at least three seconds between requests. HTML, images and PDFs
stay in gitignored `.artifacts/reader-corpus/`; they are never uploaded, committed, copied to SSH or served by the
fixture backend. No source scripts execute. Tests use the cached bytes, make no live arXiv calls, and validate
SHA-256/lengths against `tests/corpus/reader-lock.json`. Missing cache is an actionable failure in browser tests;
the optional native corpus case explicitly skips when absent. A future device PDF model is not tested or claimed.

`tests/corpus/reader.json` records identities, coverage, expected counts and reviewed unavailable outcomes. Six
sources are expected to render; KAN v1 exceeds the existing cumulative image-pixel limit, and DeepSeek-V2 v1 has
an official `ltx_ERROR` conversion node. Those cases must return their exact finite failure category with no partial
bundle. They are **unavailable-source checks**, not successful reader conversions. Their original PDFs remain part
of the local PDF corpus. Source changes fail checksum checks; refresh only after review with
`node scripts/fetch-reader-corpus.mjs --on-this-device --update-lock`, then review the lock diff and outcomes.

The PDF corpus covers 278 pages across eight documents, including a 36.2 MB image-heavy original. Authored worker
cases cover text, image-only scans, rotated pages, object streams, 250/251-page boundaries, zero pages and damaged
input. Native checks additionally cover a genuinely password-encrypted PDF. Browser membership tests check
encrypted metadata sync, no PDF/Storage/OCR requests, reload requiring file reselection, wrong-page-count rejection
and no duplicate membership after reattachment. Safari/WebKit account tests retain the explicit durable-X25519-key
capability gate; standalone compiler/worker tests do not depend on that gate.

## When to rerun slow checks

- HTML adapter, SVG rasterizer, MathML, bundle validators, CSP or reader bridge: affected authored journeys plus
  the relevant real sources/engines. Run the whole corpus when a shared contract changes. A Back/jump change also
  reruns the iPhone Simulator journeys `ReaderNavigationTests` (the HTML fixture's in-page links in
  `testHTMLPaperInPageLinksOfferBack`, the Mathpix citation and figure journeys) with
  `xcodebuild … -only-testing:ScienceReaderUITests/ReaderNavigationTests test` (see `scripts/simulator-session.mjs`
  for the destination and derived-data arguments).
- PDF intake, worker, encrypted store, account lifecycle or membership: PDF journeys and relevant native cases.
- Database/migrations, deployment configuration or hosted behavior: the corresponding database/operations/hosted
  checks, with no server PDF corpus or Mathpix fallback.
- New source failure: reproduce locally, retain its exact revision/checksums, add an authored regression, rerun
  affected checks and record the outcome. No automatic download loop.

Reports and logs are in `.artifacts/test-tiers/`, browser failure traces in `.artifacts/web-e2e/results/`, corpus
results in `.artifacts/reader-corpus-results/`, and native evidence under `.artifacts/reader-integration-build/`.
Source fingerprints are conservative signals, not a requirement to repeat slow checks after every change.
Current measured evidence and limitations are recorded in [implementation status](IMPLEMENTATION_STATUS.md).
