# Fast and slow tests

## Aligned equations and accents (reader revision 26, device port 14) — October 25

Fast (in `npm test`): `tests/backend/arxiv-equations.test.ts` (LaTeXML align with two column pairs, separately numbered
rows, continued lines, eqnarray with a text cell, the fallback, gather's numbers, accents; Temml's aligned/cases and
accents on the on-device route; both stylesheets). Slow, opt-in: the fresh-paper sweep and a replay of cached sources;
compile `node scripts/reader-device-compile.mjs --ids=2610.27450v1 --out=<dir>`, then on an iPhone and an iPad Simulator
`-only-testing:ScienceReaderUITests/ReaderNavigationTests/testTestFlight92AlignedEquationAndBar` with
`TEST_RUNNER_READER_SHOT_BUNDLES=<dir>`, `TEST_RUNNER_READER_SHOT_NAME=<prefix>` and `TEST_RUNNER_GS_SCREENSHOT_DIR`
(skipped without the bundle). Screenshots under `.artifacts/tf92-equations/`.

## TestFlight 92 feedback: usage ranges and links, breakdown pictures, Acknowledgements, recommendations card — October 25

Fast: Core `swift test --filter "AIUsageRangeTests|AIUsageTests|AssetsExportTests"` (the day window's totals and
activities, days newest first, a request's conversation and kept explanation, links never encoded, older records decode,
unfinished rows show no tokens; the export's breakdowns against the shared fixture); browser `tests/ai-usage.test.ts`,
`tests/assets-export.test.ts` (`UPDATE_EXPORT_FIXTURE=1` rewrites the breakdown expectations). App:
`ScienceReaderTests/AssetsExportAppTests` (parts cut from the fixture paper's figure as PNG). Slow, opt-in, one iPhone
Simulator: `ScienceReaderUITests/AIUsageJourneyTests` (`testRangeDrivesTotalsRingAndDays`, `testARowOpensItsConversation`;
the usage journeys are iPhone-only, the range one also passes on an iPad), `AssetsExportJourneyTests/testFigureBreakdownsComeWithTheirPictures`,
`RecommendationJourneyTests/testTheCardSitsUnderTheTitleAndStaysPut`, `SettingsTests/testAboutHoldsVersionPrivacyAndAcknowledgements`.
`--reset-draft-fixture` now also clears the fixture account's usage records. Notices: `node scripts/app-notices.mjs`
(`--root=<checkout with node_modules>` from a worktree). Screenshots under `.artifacts/tf92-feedback/`.

## No network, bad connections, a full disk — October 25

Fast: Core `swift test --filter StorageFullTests` (real ENOSPC on a 20 MB APFS disk image that `hdiutil` makes, attaches
privately and deletes; about 20 s; skips where `hdiutil` can't run): the encrypted store fails cleanly and recovers
without a relaunch, opens on a completely full disk (three cases), drafts, PDFs, crash leftovers and the model install.
App-hosted `-only-testing:ScienceReaderTests/OfflineAndStorageTests` (wording, the reader's offline and full-disk
screens, dropped and short PDFs, a captive Wi‑Fi page, the model's space check). Slow, opt-in, iPhone Simulator:
`-only-testing:ScienceReaderUITests/OfflineAndStorageJourneyTests` (six journeys, about 2½ minutes;
`TEST_RUNNER_GS_SCREENSHOT_DIR` for screenshots). Launch arguments (Debug, fixture host): `--network-offline[=<s>]`,
`--storage-full-fixture[=<s>]`, `--backend-fault=<prefix>:offline|dns|tls|lost|html` (any session; `*` or a host prefix),
`--chat-fixture-mode=offline`, `--device-model-download-fixture=fail_once|full`, `--offline-reader-unprepared`. Review:
[OFFLINE_AND_STORAGE_20261025.md](reviews/OFFLINE_AND_STORAGE_20261025.md).

## The on-device PDF model as a download — October 24

Fast: Core `swift test --filter DevicePDFModelPackTests` (the pack description and its version, refused descriptions,
verified install, tampered and missing files, a model update, removal, on-device compilation, the locator's order).
Before an upload: `node scripts/check-device-model-pack.mjs <archive or products dir>` (`upload-testflight.sh` runs it;
`--mac` for the Mac archive). Slow, opt-in: `-only-testing:ScienceReaderUITests/DeviceModelJourneyTests` on an iPhone
Simulator downloads the pack through the Simulator's On-Demand Resources service from the build folder (needs `node
scripts/device-models.mjs` before the build), reads the fixture paper, then removes the model in Settings, so each run
starts without it. Tests that need the models from a folder instead of a download: `GRADSTEP_DEVICE_MODELS=<dir>`
(`TEST_RUNNER_GRADSTEP_DEVICE_MODELS` for app-hosted tests, e.g. `ScienceReaderTests/DeviceModelRouteTests`); the Mac
tool and `scripts/device-route-*.mjs` keep taking `--models apps/apple/DeviceModels`.

## Heading formulas and affiliation addresses (reader revision 24) — October 24

Fast (in `npm test`): `tests/backend/arxiv-html.test.ts` ("a formula in a title or heading that Unicode spells", "an
affiliation keeps its bracketed web address"; both fail on revision 23). Slow, opt-in: the fresh-paper sweep and its
cached replay (`node scripts/reader-sweep.mjs --replay=<report>`), which flagged 2610.21306v1.

## List markers and diagram labels (reader revision 23) — October 23

Fast (in `npm test`): `tests/backend/arxiv-html.test.ts` ("one marker, the paper's own label", "drawn line by line").
Slow, opt-in: compile `node scripts/reader-device-compile.mjs --ids=2610.28711v1,2610.14162v1 --out=<dir>`, then the iPad
journey `-only-testing:ScienceReaderUITests/ReaderNavigationTests/testBuild88ListsAndPictureLabelsDark` with
`TEST_RUNNER_READER_SHOT_BUNDLES=<dir>`, `TEST_RUNNER_READER_SHOT_NAME=<prefix>` and `TEST_RUNNER_GS_SCREENSHOT_DIR`
(skipped without the bundles). Screenshots under `.artifacts/reader-fixes-90/`.

## Download your assets — October 22

Fast (in `npm test`): browser `tests/assets-export.test.ts` (writes `tests/fixtures/assets-export/assets-export-v1.json`
expectations with `UPDATE_EXPORT_FIXTURE=1`; `EXPORT_ZIP_OUT=<path>` also writes the zip to open with `unzip -t`). Core
`swift test --filter AssetsExportTests` (same fixture: same files, same zip SHA-256). Slow, opt-in: Playwright
`npx playwright test assets-export.spec.ts --project=desktop --project=phone` (screenshots under
`.artifacts/web-e2e/assets-export/`); native, on an iPhone Simulator,
`-only-testing:ScienceReaderUITests/AssetsExportJourneyTests` (`TEST_RUNNER_GS_SCREENSHOT_DIR` for screenshots).

## Full screen on touch; streamed equation explanation — October 22

Fast: backend `tests/backend/chat.test.ts` (the symbols stream in any chunking, count, cut-off and malformed symbols;
events to the device, final `equation` unchanged; symbols at low effort; `default_figures` Gemini), browser
`tests/equation-progress.test.ts` (writes `tests/fixtures/equation-progress.json` with `UPDATE_PROGRESS_FIXTURE=1`),
`equation-stream.test.ts`, `figure-framing-record.test.ts`, `figures-default.test.ts`; Core `swift test --filter
"EquationViewTests|FigureProgressTests|FigureFramingTests|ChatProfilesTests"`; app `FiguresDefaultTests`,
`FigureViewAppTests`. Slow, opt-in: Playwright `e2e/figure-view.spec.ts` (full-screen transition, gestures, reduced
motion; the mid-transition check is Chromium-only) and `e2e/equation-view.spec.ts` (fixture `equationStream`
fast/slow/step/old/error/cut); native `FigureViewJourneyTests/testTouchingAPartOpensFullScreenFromItsCard` (+`Dark`;
`TEST_RUNNER_FIGURE_FULLSCREEN_SLOW=<n>` slows the motion, default 8; photograph it from outside with `xcrun simctl io
<sim> screenshot` in a loop, since XCUITest waits for animations to end before its own screenshots) and
`WorkflowJourneyTests/testEquationSymbolsStreamWithAProgressBar` (+`Dark`, `testAnOlderServersEquationSymbolsStillShow`;
`--equation-fixture-step-ms`, `--equation-fixture-old-server`). Paid, explicit: `node scripts/equation-speed.mjs
--equation=6 --configs=gemini-medium,gemini-low,sonnet-low` (model alone, straight to OpenRouter, durable ledger) and
`node scripts/chat-live-smoke.mjs --equation=symbols --equation-runs=2 --profile=…` (staging, disposable account; prints
the stream's timings and the published defaults; without `--profile` it asks with Sonnet, which writes its own cache).
Screenshots under `.artifacts/figure-fullscreen/` and `.artifacts/equation-progress/`.

## Credits by activity (Your AI usage › All) — October 22

Fast (in `npm test`): browser `ai-usage.test.ts` renders the ring's slices and words for the page's activities and the
fixture's `slice_cases` (Other, ties, a sliver, one activity, nothing charged) into `tests/fixtures/ai-usage.json`
(`UPDATE_USAGE_FIXTURE=1`); Core `swift test --filter AIUsageTests` (`theRingIsTheBrowsers`) checks the same expectations.
Slow, opt-in: Playwright `npx playwright test ai-usage.spec.ts --project=desktop --project=phone` (the ring's words,
legend chooses a chip, none when filtered or empty; screenshots `.artifacts/ai-usage-20261022/*-ring.png`); native
`-only-testing:ScienceReaderUITests/AIUsageJourneyTests` on an iPhone Simulator (`TEST_RUNNER_GS_SCREENSHOT_DIR` for
`usage-iphone-light-ring.png`).

## Your AI usage and collapsible snippet cards — October 22

Fast (in `npm test`): backend `tests/backend/ai-usage.test.ts` (every chat action, provider route and operation kind has a
reader-facing name; server, browser and Swift names identical; no dollar or private fields); browser `ai-usage.test.ts`
(writes `tests/fixtures/ai-usage.json` expectations with `UPDATE_USAGE_FIXTURE=1`) and `note-collapse.test.ts`. Core
`swift test --filter "AIUsageTests|NoteCollapseTests"` (same fixtures). Database: `npm run test:database`, or alone
`python3 scripts/test-database.py --account-usage-only` (`tests/database/account_usage.sql`, and
`ai_usage_reported_tokens.sql` for migration 0160: only provider-reported tokens counted). Slow, opt-in: Playwright
`npx playwright test ai-usage.spec.ts notes.spec.ts --project=desktop --project=phone` (screenshots under
`.artifacts/ai-usage-20261022/` and `.artifacts/snippets-20261022/`); native, one at a time on an iPhone Simulator,
`-only-testing:ScienceReaderUITests/AIUsageJourneyTests/<test>` and `NotesJourneyTests/testSnippetCardsCollapseAndRemember`,
`testSnippetCardsDarkAndLargeText` (`TEST_RUNNER_GS_SCREENSHOT_DIR` for screenshots). Paid, explicit:
`node scripts/ai-usage-live-check.mjs` (staging, two disposable accounts, one Haiku question ≈ $0.001; reads the row back
and checks a second account sees nothing; deletes both).

## Streamed figure walkthrough and progress bar — October 22

Fast: backend `tests/backend/chat.test.ts` (the stream scanner in any chunking, malformed and cut-off parts, the
announced count; JSON-reply and tool-call streaming with the final `figure` unchanged; low effort, DeepSeek without
thinking, `default_figures`), browser `tests/figure-progress.test.ts` (writes `tests/fixtures/figure-progress.json` with
`UPDATE_PROGRESS_FIXTURE=1`), `figure-view.test.ts`, `figures-default.test.ts`; Core `swift test --filter
"FigureProgressTests|FigureViewTests|FigureFramingTests|ChatProfilesTests"`; app `FigureViewAppTests`. Slow, opt-in:
Playwright `e2e/figure-view.spec.ts` (fixture `figureStream` fast/slow/step/old) and native `FigureViewJourneyTests`
streaming journeys (`--figure-fixture-step-ms=…`, `--figure-fixture-old-server`). Paid, explicit:
`node scripts/figure-speed.mjs --paper=dpo --figure=2 --configs=gemini-low,sonnet-low,deepseek-low-nothink@together`
(model alone, straight to OpenRouter, durable ledger) and `node scripts/chat-live-smoke.mjs --figure-view=2,1
--figure-walkthrough-only --profile=…` (staging, disposable account; prints the stream's timings and the server stages
read back from the database).

## Structure first and the count check — October 21

Fast: browser `tests/figure-structure.test.ts` and `tests/figure-framing.test.ts` (in `npm test`); Core
`swift test --filter "FigureStructureTests|FigureFramingTests"` (same `tests/fixtures/figure-crops/structure.json` and
`framing.json`; `UPDATE_STRUCTURE_FIXTURE=1` / `UPDATE_FRAMING_FIXTURE=1` rewrite them from the browser implementation;
`python3 scripts/figure-structure-fixture.py` remakes `stacked-subfigures.png`). Opt-in, a real paper: compile
`node scripts/reader-device-compile.mjs --ids=2610.22353v1 --out=.artifacts/figure-structure/bundles` (needs the sweep's
cached source and assets), then `FIGURE_STRUCTURE_BUNDLE=<abs>/.artifacts/figure-structure/bundles/2610.22353v1 npx vitest
run tests/figure-structure.test.ts` prints every multi-image figure's structure. Slow, opt-in: Playwright
`e2e/figure-view.spec.ts -g "real multi-image"` (compiles 2610.22353v1 in the page from `.artifacts/reader-sweep/`;
skipped without it; fixture modes `figure_subfigures`, `figure_subfigures_grouped`) and native
`FigureViewJourneyTests/testARealMultiImageFiguresPartsAreItsOwnSubfigures` (`…Dark`,
`testGroupedPartsOfARealMultiImageFigureShowTheWholeFigure`) with `TEST_RUNNER_FIGURE_STRUCTURE_BUNDLE=<that bundle dir>`
(launch arguments `--figure-fixture-bundle=… --figure-fixture-subfigures [--figure-fixture-grouped]`; skipped without it).
Screenshots under `.artifacts/figure-structure/`.

## Extract the subfigure removed — October 21

Fast: browser `tests/figure-view.test.ts` (the request is no figure action, its event is ignored, kept detail answers
are dropped on restore), backend `tests/backend/chat.test.ts` (the server still accepts the deprecated `figure_detail`
from builds 63–79), Core `swift test --filter FigureViewTests` (old sealed answers decode, are not shown or listed).
Slow, opt-in: Playwright `e2e/figure-view.spec.ts` (part menus without Extract) and native `FigureViewJourneyTests`
(the walkthrough journey asserts the menu has no Extract). Screenshots under `.artifacts/figure-detail-removal/`.

## Figure parts as viewports — October 21

Fast: browser `tests/figure-framing.test.ts` and `tests/figure-framing-record.test.ts` (in `npm test`); Core
`swift test --filter FigureFramingTests` (same `tests/fixtures/figure-crops/framing.json`). Slow, opt-in: Playwright
`e2e/figure-view.spec.ts -g "framed by confidence"` (fixture mode `figure_panels_loose`; `FIGURE_FRAMING_STAGE=before`
only takes screenshots) and native `FigureViewJourneyTests/testPartsAreFramedByConfidenceAndExpandToTheWholeFigure`
(and `…Dark`; launch arguments `--figure-fixture-panels --figure-fixture-loose`; `TEST_RUNNER_FIGURE_FRAMING_STAGE=before`).
Screenshots under `.artifacts/figure-framing/`.

## Pricing, free AI pool and spending safeguards — October 22 UTC

Fast (in `npm test`): `tests/backend/chat.test.ts` (switch refusals, no search on free answers, cheaper defaults), browser
`tests/free-ai.test.ts` and `tests/account-assets.test.ts`, native Core `FreeAITextTests`. Database:
`python3 scripts/test-database.py --pricing-only` (`free_ai_and_spend.sql` and the 12-reader pool concurrency check; also in
the final phase). Slow, opt-in: Playwright `e2e/pricing.spec.ts`; admin loopback journey
`npm run dev:admin -- --port <free port>` then `SPEND_INCOME_PREVIEW=http://127.0.0.1:<port> node scripts/check-spend-income.mjs`
(screenshots `.artifacts/spend-income/`); native Settings/chat journeys (see the pricing entry in IMPLEMENTATION_STATUS).

## AI recommendations — October 21 UTC

Fast: `node --test tests/backend/recommend.test.ts` (in `npm test`), browser `tests/recommend.test.ts`. Database:
`python3 scripts/test-database.py --recommendations-only` (also in the final phase). Slow, opt-in: Playwright
`e2e/recommend.spec.ts` (fixture route `recommend` with `/__recommend-fixture` modes); native UI
`RecommendationJourneyTests` with `--recommend-fixture[ --recommend-fixture-mode=none|daily_limit|insufficient_credits|error]`.
Paid, explicit, after deploying: `node scripts/workflow-checks.mjs --only=recommend.smoke --record` (one Haiku call).

## October 20 platform parity

The focused record is [the platform parity review](reviews/PLATFORM_PARITY_20261020.md). Browser catalog, draft
navigation/persistence and figure-promotion journeys now run at both tablet sizes as well as desktop and phone.
`chat-motion.spec.ts` adds actual touch injection during streaming, wheel scrollback, stopped-content stability
and Latest message on paper and contextual figure chats. The old ChatPane fails with 1,541 px movement under a
held finger; the current implementation passes with at most 1 px. This measures the displayed DOM, not just a
mock follow state. A separate blocked-encryption negative control reproduces navigation waiting for storage.
The final eight motion cases also move the touch enough to trigger the browser's `pointercancel`, require that
event, then verify that incoming text still cannot take ownership before `touchend`. This reproduced a second
1,541 px jump in the intermediate implementation; touch release now follows the touch lifecycle.

Mac verification uses actual Catalyst wheel events plus a DEBUG/FIXTURE_HOST-only geometry readout, checking
paragraph position and height during streaming, both wheel directions, and idle after Stop. The probe adds no
release code. Catalog tests use Catalyst menus and scroll its compact deletion form to the final action.
The complete Mac and iPad figure journeys type into the promoted composer without tapping it first. iPad's
full-height Contents/discovery/relaunch and equation-tile journeys pass with explicit page presentation sizing;
the prior short centered form failed the height assertion. A wider synthetic crop pinch reaches 170% from 100%;
the earlier gesture moved each finger only 11.1 pt and did not recognize. The zoom implementation is unchanged.
Existing slow evidence is reused for unchanged behavior. Playwright WebKit's durable-key skips remain explicit
and do not count as Safari acceptance. No physical iPhone or paid provider request is needed for these checks.

The final shared Contents height/discovery/relaunch journey also passes on iPhone 17 Pro Simulator
(`phone-contents-final.xcresult`), with its screenshot reviewed. The build-77 optimized import/session gate passes
**15/15, zero skips**, at **2026-10-20T15:23:10.082Z**; fingerprint
`c11f9fd489f5722f64f4755379b0ebec7d19a2739422735250e5533c6e49761a`.
Result: `.artifacts/import-acceptance/2026-10-20T15-15-12-188Z.xcresult`. Both signed build-77 archives from
**562ba8b** pass signature and executable/dSYM identity checks at **15:50:20 UTC**. iOS includes iPhone/iPad and
excludes local answering runtimes/models; Mac is arm64/x86_64 with an empty model catalog. Both binaries exclude
the fixture motion probe and old-renderer control. Exact identities are in
`.artifacts/releases/77/release-77-provenance.json`. The first Mac packaging failure and clean unchanged-source
retry remain documented in the platform review; a diagnosed cause is not claimed.

## Native chat motion audit — October 20 UTC

`WorkflowJourneyTests/testChatScrollAuditAtRest`, `testChatScrollAuditWhileStreaming`, and
`testChatScrollAuditWithinGrowingAnswer` exercise real touch drags and flicks over 24 synthetic questions/answers,
both with completed content and with a long response arriving through the fixture transport. The growing-answer
variant requires samples from an idle passage inside the current answer, in addition to the older-message case.
The fixture uses the real encrypted store and native renderer, with no provider call.

The opt-in DEBUG + FIXTURE_HOST probe measures visible paragraph geometry after layout, at the end of the sampled
run-loop pass. It requires >150 drag frames and >150 direct finger-tracking comparisons, ≤3 pt tracking error,
≤1 pt completed-row height variation, and ≤3 pt idle passage displacement. The fixture-only legacy-row switch
must detect the old defect: the completed-layout negative control records **116 pt** height variation in unchanged
messages and **113.67 pt** tracking error. The repaired static test records zero height/idle change and tracking
error below 0.001 pt. These two cases pass in `chat-scroll-phone-final.xcresult`; that run also retains the
streaming failure (213.67 pt idle shift) that exposed needless offscreen snapshot updates. After that repair,
`chat-scroll-offscreen-update.xcresult` passes the streaming journey with no idle shift and tracking error below
0.001 pt. Final iPhone verification in `chat-scroll-stream-final.xcresult` passes **3/3, no skips**: offscreen
streaming, reading within the growing answer, and keyboard/composer scrollback. The two motion cases contain
4,871 and 5,183 direct tracking comparisons respectively, each with error below 0.001 pt and zero sampled idle
shift; 2,412 idle comparisons are inside the growing answer. The iPad motion test in
`chat-scroll-ipad-serial.xcresult` also passes: 9,370 tracking comparisons, zero height drift and zero idle shift.

Five functional iPhone regressions pass in `chat-scroll-phone-regressions.xcresult`: latest-answer visibility,
keyboard/composer scrollback, interactive keyboard dismissal, text selection/Copy, and text/formula chat actions.
Its earlier streaming failure is retained. The iPad keyboard helpers previously looked for the iPhone-only
composer dismiss button. They now use iPad's system Hide keyboard key; all viewport and passage-position
assertions remain. The latest-answer journey passes in `chat-scroll-ipad-keyboard.xcresult`; the complete
scrollback/return-to-latest journey passes in `chat-scroll-ipad-scrollback.xcresult`. The earlier failures remain
in their result bundles, including the second obsolete dismiss-button query at the end of the latter helper.
Diagnostic trials also retain the ineffective `.ignoresSafeArea()`
change and stale reused-cell sizing failure. Early display-link samples were taken before layout; the accepted
probe samples after layout and is checked against the old renderer, so intermediate compensation is not treated
as proof of displayed jitter. Numeric traces, final source hashes, screenshots and summaries are under
`.artifacts/chat-scroll-audit/`. The light iPhone growing-answer and keyboard/composer screenshots, iPad transcript,
and an app-rendered dark iPhone conversation capture were inspected. No colors or page arrangement were changed.

`npm test` passes in `chat-scroll-fast-final.log`. The first fast run hit the existing pathological-line timing
limit while native builds/Simulators were busy; its isolated rerun and the complete quiet rerun pass unchanged.
Simulator startup stalls occurred before any app test, with launch stack samples retained; they are not app
acceptance. These checks do not measure physical-phone frame rate, qualify figure/equation contextual chat or
browser scrolling, or replace the mandatory fresh import gate before a native upload. No physical phone was accessed.

The subsequent build-76 release gate passes **15/15, zero failures/skips**, with `-O` and whole-module compilation
at **2026-10-20T05:26:18.203Z**, fingerprint `5c9d61c47f393104f3588632ac12bf65e304beaaaca19ff1cce059118dc70b1f`.
Result: `.artifacts/import-acceptance/2026-10-20T05-19-44-822Z.xcresult`. The focused Mac
`MacKeyboardTests/testChatColumnShortcutAndSettingsReturnKeepThePaper` passes **1/1**, with its screenshot reviewed;
this verifies window/navigation behavior, not Mac scroll-wheel motion. Its result and the signed-archive/source
provenance are under `.artifacts/releases/76/`. Both released binaries contain no scroll probe or legacy row switch
and pass signature/dSYM checks. The iPhone/iPad binary passes local-answering-model exclusion; the Mac catalog
remains empty. Both platforms are VALID / IN_BETA_TESTING, with notes read back at **05:51:31 UTC**.

## Named catalogs and repeated account return — October 19 UTC

Catalog verification covers causal encrypted-note reduction (seven Core and seven browser cases), eleven native
model/PDF cases, iPhone/iPad screen journeys and six desktop/phone browser journeys. It checks relaunch, selection
at import start, existing/new deletion destinations, actual record removal, refusal/replay, and a new paper added
after deletion was confirmed. Saved membership and pending intent can share a logical paper key; deletion must
handle both records. The first native UI attempt exposed the fixture's missing JSON `fragmentsAllowed` for numeric
RPC receipts; the corrected fixture passes both device layouts. A separate iPad startup stall happened before any
app test ran; its CoreSimulator stack/log are retained, and restarting the Simulator completes the same journey.

The release-optimized import gate passes **15/15, zero skips**, at **2026-10-19T05:49:03.355Z**, including real-paper
imports, stale/deleted-session retirement, visible Apple/Google invitation refusals and persisted source-keyword
edits through the real native transport. Hosted auth separately passes two synthetic delete → self-create →
verified-login cycles. Interactive Apple/Google provider acceptance on a physical phone remains unverified.
Evidence: `.artifacts/feedback/catalogs-20261019/`, including `catalog-release-verification.json` and the failed
attempts. No paid model call or physical-phone access was needed.

## Later October 18 navigation and column acceptance

Tests separately cover heading and citation jumps with Reduce Motion disabled, including immediate position and
subsequent animation frames. Touch discovery is exercised by real Simulator double-tap, with preference survival
across relaunch; bridge cases exclude mouse, links, drag and long press. Native reference journeys require all four
actions to be visible without opening More, then verify Copy/Back and an unsent Discuss draft. Library column
preferences gain Device/Authors once and preserve later explicit choices; browser journeys cover horizontal
scrolling, keyboard focus, persistence and resizing. The fresh import gate remains mandatory for changed row geometry.

The iOS equation navigation assertion now uses the complete “Equation (1)” link plus Back. Its old standalone “(1)”
query became stale when build-71 feedback made the whole reference clickable. Catalyst reports the visible link
as not hittable and exposes the rendered formula as a single accessibility text element; its assertion checks
that complete formula and following reference are inside the reader viewport, with Back available. Saved failure
hierarchies and screenshots informed this platform-specific query; the corrected Mac journey passes in
`release-73-mac-contents-geometry.xcresult`. No production navigation change was needed for these assertion failures.
Old broad-category tag and hidden-zero-chat assertions
were aligned to the already approved build-69/70 behavior, with specific-keyword filtering retained. Table floating
point comparisons allow 0.001 pt numerical noise, not visible layout overflow.

## Build 70 feedback acceptance (2026-10-18)

The Find regressions assert occurrence selection, non-mutating paper DOM/text, retained reading position and
normal tab layout after dismissal. Native `PaperToolsTests` exercises the actual app-owned Find row and tab
switches; `PaperWebViewTests` covers matches across inline elements. Browser `figure-view.spec.ts` checks
highlight ranges and the same logical reading position after closing Find (raw scrollY can clamp when the
viewport grows). Source-only papers must save/restore location without a legacy artifact ID.

Figure journeys cover fullscreen/close, crop pinch, simpler/detail requests, citation return to the saved
walkthrough, and promotion into the same main-chat composer with its unsent draft. Browser assertions check no
extra request during navigation. `UnsentDraftTests` covers engine restoration, scenario defaults and preservation
of an explicit profile after promotion. `ChatControlsTests/testDefaultOptionsInSettings` changes figure and paper defaults independently and verifies a new paper chat uses the paper setting. Core/browser crop tests replay the FDE-Gym live box that clipped a label.
The actual seven-figure FDE-Gym bundle also renders offline at phone width in both themes: 25 headings, 63 equations,
seven decoded images, preserved selection and no horizontal overflow. The actual padded live crop was viewed.

Search tests inspect field-constrained requests (AND semantics), installed/missing public-link destinations and
no automatic import. Device index tests cover bounded terms and per-paper removal; native Library tests cover
customized/cleared keyword metadata and account retirement. `npm test` remains the routine tier. Run the exact
15-case `npm run test:imports` gate with current source before every native upload; these UI/figure checks do not
replace import acceptance. Simulator/local fixtures do not verify physical-phone resource behavior or live model
quality. The one paid FDE-Gym Flash check is separately recorded; the local panel detector used no paid API.

Initial iOS build-71 release evidence: `.artifacts/import-acceptance/2026-10-18T16-48-10-757Z.xcresult` passes 13/13 with
zero failures/skips, matching source at 16:57:23 UTC. Final iPhone figure/local-figure/ownership/metadata retests
are in `native-feedback-final.xcresult`, and activity defaults in `activity-defaults.xcresult`, under
`.artifacts/feedback/build70-20261018/`. The resumed Mac figure journey passes, but visual review caught its
fullscreen being another small sheet. The final journey therefore requires an image viewport spanning at least
90% of the window width and 75% of its height, plus Escape/⌘W dismissal preserving the explainer. The Mac archive
was rebuilt after the full corrected journey passed in `mac-fullwindow-sheet.xcresult` (17:40 UTC).
The screenshot review confirms a visible window-sized image, usable Close and the retained Chat draft; checking
an accessibility frame alone had missed clipping by the native presentation. The shared wrapper also passes the
complete iPhone figure journey in `import-corpus-diagnostic.xcresult` (17:49 UTC), with its fullscreen and
transferred-draft screenshots inspected.

The fresh import gate in `2026-10-18T17-49-34-442Z.xcresult` passes 13/13 with no skips at 17:53:29 UTC. Earlier
attempts are retained: `2026-10-18T17-39-15-921Z.xcresult` timed out preparing Rubric Judgments, and the corpus
method in `import-corpus-diagnostic.xcresult` prepared that paper but refused DocPilot. Their exact cause was not
captured, so no production import fix is claimed from a later pass. The fixture now retains its existing reader
event timeline, prints source identifiers at case start, reports progress/request count on timeout, and stops
at the original failure instead of denying responses while preparation is still running. The 60-second timeout,
seven pinned papers, validators and offline-reopen assertions are unchanged. Three additional bounded corpus
replays configured to stop on the first failure pass all 21 paper imports/reopens in
`import-repeat-diagnostics.xcresult` (40.1, 38.8 and 38.3 seconds, completed 17:56 UTC). These establish repeated
acceptance on this Simulator, not a diagnosed fix for the two earlier intermittent failures.

Hosted AASA verification now rejects HTML, redirects, or an incorrect
application identity, in addition to checking entry-asset content types.

Local AI is an explicit native/Metal tier, never part of routine `npm test`: `swift test --package-path apps/apple/LocalAI --filter ModelStoreTests` checks local model integrity; Core's `LocalAIContextTests` checks
bounded context and cloud-serialization rejection. `LocalAIJourneyTests` exercises the Cloud/Local choices and
encrypted explanation reopen using a deterministic inference fixture. Actual MLX quality and memory are measured
with the opt-in `LocalAIProbe` on Mac, including a network-denied run. Protocol and failed cases are retained in
[Local AI comparison](reviews/LOCAL_AI_20261017.md). Simulator success is not phone inference acceptance.

Owner direction, 2026-10-13: run fast checks routinely; run slow checks once for a baseline, then selectively for
related changes or a reported problem. A slow run is not a prerequisite for an unrelated edit. Save failures and
turn a discovered bug into a small fast regression where possible.

## Build 69 feedback acceptance

`LocalAIJourneyTests` now exercises Settings model management/defaults, dictation into an unsent draft, local
chat/equation/figure choices, saved explanations after restart, inline billing recovery, and two follow-ups in the
equation view. The latest answer must actually be visible above the composer, not merely present offscreen.
`FigureViewJourneyTests` exercises the real UIKit crop pinch and in-place question draft; its two-plot cases
(`--figure-fixture-panels`, a real DPO figure built by `scripts/figure-panels-fixture.py`) check completed crops and
their margins light and dark, as browser `figure-view.spec.ts` does with `figure_panels`. The completeness step itself
is pinned by the shared fixtures in `tests/fixtures/figure-crops/` (Core `FigureCropCompletionTests`, browser
`figure-crops.test.ts`; regenerate with `scripts/subfigure-detector/export_crop_fixtures.py`). `UnsentDraftTests` checks
context ownership/draft restoration, real equation overflow and actual typesetting of the reported cases/ket LaTeX;
`LibraryModelTests/testSourceAddedDateClearedKeywordsAndContextualSignOut` covers the authenticated account boundary.
These are release-optimized Simulator checks, not on-device model-quality or microphone-recognition measurements.

Browser `equation-view.spec.ts` and `figure-view.spec.ts` cover inline conversations, preserved explanation,
model/consent changes, reload, automatic equation overflow, crop zoom, nested-dialog isolation and author search
on desktop and phone layouts. The author journey checks an actual search request: setting a field alone is not
acceptance. Shared search tests verify author-only provider queries and recent ordering.

The exact reported 2610.22353v1 source is compiled before/after revision 19, including bundle admission, all 22
images and unchanged non-whitespace paragraph text; screenshots show the affiliation/contact block. The authored
regression uses full bundle validation, which catches a missing sanitizer class admission. Migration 088 has
`tests/database/import_metadata.sql` for date/delta delivery, explicit empty keywords, archive-only preservation,
account isolation and idempotency. Evidence is retained under `.artifacts/feedback/all-20261018/`.

The subsequent 123-paper replay caught indexed affiliation marks being flattened (revision 20 repair). Full
image compilation in WebKit also caught 2610.20592v1 crossing the encoded bundle limit while Chromium passed
(revision 21 repair). Keep the four cases in `tests/corpus/reader-feedback-20261018.json`; pass its absolute
path as `TEST_RUNNER_SCIENCE_READER_HTML_CASES` to `ArxivHTMLReaderTests` with release optimization. The
existing replay uses cached official bytes only and fails when they are missing. The final native replay passes
all four, including all seven figures and 347 equations of the large paper, without increasing existing admission
limits. This replay does not measure peak memory on a physical phone.

## Build 68 Equations regression

`swift test --package-path apps/apple/ScienceReaderCore --filter 'EquationViewTests|ChatStreamTests'` covers complete
MathML extraction with 105 equations and a long Unicode tail, bounded runtime, reordered/missing IDs and explanatory
billing-error copy. The opt-in Simulator journey
`PaperToolsTests/testReportedQuantumPaperEquationsFinishAndCanReopen` uses the exact reported 1805.03662v2 bundle,
whose manifest identity is pinned in the test-only `OfflineReaderFixture`. Prepare it locally with
`node scripts/reader-sweep.mjs --ids=1805.03662v2`, then
`node scripts/reader-device-compile.mjs --ids=1805.03662v2 --out=.artifacts/equations-feedback-20261017/bundles`.
Missing/mismatched fixtures fail rather than skip. The test does no network or AI work. It checks the list, tab
revisit, jump to the equation and reopen; extraction timing is measured separately from XCTest accessibility work.
`LocalAIJourneyTests/testCloudFailureExplainsBillingAndLetsTheReaderChangeModelHere` injects the actual billing
failure category, checks the cause/zero-reader-charge copy and changes the model in place to obtain a structured
answer. Structured cloud answers use `equation.summary`; local prose uses `equation.description`.

## Commands

Install root and browser dependencies with `npm ci` and `npm ci --prefix apps/web` (Node 24+).

| Tier | Command | Scope |
|---|---|---|
| Fast, default | `npm test` or `npm run test:fast` | Backend contracts, browser units, authored bundle/crypto fixtures, compiled device-reader freshness, every Node operations test in `tests/operations/` (web deploy gates, arXiv acknowledgement/User-Agent, egress scan, packaged workflow runner, account-deletion guard), the Python operations tests that need no database (deploy, readiness, spending, migration ledger/transport, native auth, podcast operators), strict `deno check --frozen` of every Edge entry point and the admin site's `tsc`. No browsers, downloads, databases, Simulator, credentials or paid calls. A step that exits 0 but ran no tests or skipped any fails the tier. |
| Operations | `npm run test:ops` | Every Python operations test (`scripts/test-ops.py`), including the restore quarantine against the local PostgreSQL server below, and every Node operations test. Fails on zero tests or any skip. Run after a change to a deploy, backup/restore, readiness or operator script. |
| Fast, targeted | `node --test tests/backend/arxiv-html.test.ts` or `npm run test:fast --prefix apps/web -- tests/bundle.test.ts` | Exactly the selected files. `test:backend` alone runs all backend contracts. |
| Paid, chat visual | `node scripts/chat-live-smoke.mjs --question="…as a visual I can read on my phone"` | The live chat on staging with a question that invites a visual answer; prints the `visual` event's title, size and elements (about $0.25). Run after a change to the visual tool, its sanitizer or the chat prompt. |
| Paid, explicit: figure view | `node scripts/chat-live-smoke.mjs --figure-view=1 --warm`, or `--paper=2610.16784v1 --index=<bundle>/reader.json --figure-view=4 --table-view=1` | The figure view's two requests (FIGURE_VIEW.md) on staging from a `figure_view` device: the image prepared as the browser prepares it, the walkthrough's sections and boxes (drawn on the image under `.artifacts/figure-view/`), one part again more simply, credits, seconds and cache use in a JSON record. `--warm` asks a chat question first to show the shared cache; `--table-view` renders a table from the bundle as an image. About $0.25 the first time a paper is cached, $0.05 per figure after. Run after a change to `chat-figure-view.ts` or its instructions. |
| Paid, chat figure | `node scripts/chat-live-smoke.mjs --figure=1 --question="What does Figure 1 show? Walk me through each part of it."` | The live chat on staging with DPO's Figure 1 attached under consent v3; prints the attachment, the `figure_parts` boxes and the answer (about $0.25 uncached). Run after a change to figures, the parts tool or the consent. |
| Slow, device compile | `node scripts/reader-device-compile.mjs --ids=2610.15542v1,…` | The whole device path for cached papers in headless Chromium: the shipped compiler plans the assets, the script fetches them once (cached under `.artifacts/reader-sweep/assets/`), the compiler admits or rasterizes them under the pixel budget and composes the bundle. Prints ok (bundle size, images, and how many figures the device couldn't prepare: "N not shown", each a note in the paper since revision 15) or the reason code. Run on every paper the owner reports, and on the sweep's corpus before a reader build: the sweep converts the HTML only and cannot see an image refusal (Apertus 1.5, build 42). |
| Slow, reported-paper native replay | Set `TEST_RUNNER_SCIENCE_READER_HTML_CASES` to an absolute JSON file path, then run `xcodebuild test … -only-testing:ScienceReaderTests/ArxivHTMLReaderTests` on a Simulator | JSON entries contain `source_id`, `source_revision`, `title`, `authors`. Replays the sweep's cached HTML and device-compile assets through native WebKit and independent Swift admission; missing cached files fail without making a network request. Opt-in only; no paid AI or physical-device access. |
| Slow, reported-paper Library acquisition | Set `TEST_RUNNER_SCIENCE_READER_LIVE_LIBRARY_CASES` to the same JSON format (1–3 papers), then run `xcodebuild test … -only-testing:ScienceReaderTests/LibraryModelTests/testReportedPapersDownloadInstallAndOpenThroughTheLibrary` on a Simulator | Real native URLSession downloads started together through Library preparation, encrypted installation and opening the saved copies. Account backend is a local fixture. This makes direct arXiv requests from the Simulator, never from a server; opt-in only. A pass does not reproduce a physical phone's network, OS, memory or prior local state. |
| Slow, reader sweep | `node scripts/reader-sweep.mjs --recent=25 --from-staging=40` | Fresh real papers (newest listings in cs.LG/cs.CL/cs.CV/cs.AI and the staging library) compiled with the shipped device compiler; header and structure invariants and refusals, with a JSON report under `.artifacts/reader-sweep/`. Paced like the app (3 s per document); sources cached. Run before every build that changes the reader or compiler; a refusal or a `fail` finding is triaged into a fixture before shipping. `--replay=<report.json>` reruns a report's papers from the cached sources (the same corpus before and after a change); `--ids=…` picks papers. |
| Slow, paid, podcast device source | `node scripts/podcast-device-smoke.mjs [--profile=podcast-5min-v1]` | One private episode from the DPO text as a device sends it, on staging, with a disposable account (deleted after): source, quote, start, status, paper lookup, transcript. About $0.20 of provider spend. Run after changes to the podcast quote, claim, publish or worker source handling. |
| Hosted, fault drill | `node scripts/fault-drill.mjs --provider=openrouter --mode=throttle --route=chat --minutes=5` | Staging only, with the functions deployed with `FAULT_INJECTION=on` (infra `fault_injection`). A disposable `@example.invalid` account gets a 5-minute OpenRouter throttle on chat (the only model gateway since 2026-10-18; the default provider); the script checks the reader sees `provider_unavailable` with `retry_after`, is charged nothing, the library still loads, two `drill` rows reach the provider-health telemetry, and chat answers again once the fault is cleared (one real answer, about $0.005); deletes the account. Report under `.artifacts/fault-drills/`. Rerun after a change to `provider-health.ts`, the chat retry or migration 073's fault rules ([RESILIENCE.md](architecture/RESILIENCE.md#fault-drills)). Since 2026-10-16 also (in OpenRouter's stream format) `--mode=midstream` (the provider fails after the first text: nothing charged, the text kept), `--mode=stop` (Stop recorded → charged for what was written; dropped connection → nothing; a build without `stop_signal` → charged as a Stop) and `--mode=overrun` (an anomaly row, `work_enabled` stays true, chat still answers); each reconciles its synthetic attempts to zero; about $0.0003 each. Rerun them after a change to how answers are charged ([CHAT.md](architecture/CHAT.md#when-an-answer-stops-early--2026-10-16)) or to migration 079's rules. |
| Slow, on-device PDF route | `node scripts/device-route-eval.mjs --fixtures <dir> --conformance <bundle_conformance.py>` | The experimental on-device model (docs/architecture/DEVICE_PDF_ROUTE.md) on this Mac: builds `DevicePDFRouteTool` (the app's text layer, Core ML models and converter), converts each fixture PDF and runs the desktop's `bundle_conformance.py` on the trace; one row per paper and `.artifacts/device-route/summary.json`. Needs `node scripts/device-models.mjs` (the models, checked against `apps/apple/device-models.lock.json`) and the desktop's fixture set copied locally (read-only). Run after a change to the text layer, the host, the converter or the models. In the Simulator: `TEST_RUNNER_DEVICE_PDF_FIXTURE=<paper.pdf>` with `ScienceReaderTests/DeviceModelRouteTests`, and the journey `DeviceModelJourneyTests`. |
| Slow, on-device PDF route weaknesses | `node scripts/device-route-weaknesses.mjs --runs <variant>@test,<variant>@dev[,<variant>@venue] --name <name> [--baseline <earlier name>]` | Reads runs of `device-route-accuracy.mjs run … -- --record --trace` (or replays) against the arXiv HTML reading and writes `.artifacts/device-route-weaknesses/<name>/index.html`: an error taxonomy with rates per paper and per 10 pages, each incident's likely stage, impact (severity-weighted incidents per 10 pages), the worst examples as page crops beside both readings, time per stage per page, and changes from `--baseline`. Needs the runs' records (gzipped is fine), PyMuPDF for the figure check, and builds `DevicePDFRouteTool` for the crops unless `--tool` or `--no-crops`. Review: docs/reviews/DEVICE_PDF_WEAKNESSES_20261024.md. |
| Slow, reader journeys | `npm run test:slow` | Production-CSP browser compiler, complete HTML reader/chat admission, local PDF worker and membership/reselection cases. Local fixture backend only. |
| Slow, real corpus | `npm run test:slow:corpus` | Offline replay of eight exact arXiv revisions through Chromium, Firefox and WebKit; independent bundle verification, math/images/fragments, device-only PDF intake/reload. |
| Slow, native | `npm run test:slow:native` | iPad Simulator with release optimization (`-O`, whole-module): WKWebView compiler, concurrent multi-image acquisition, PDF admission, locked/over-limit PDF rejection, real-PDF PDFKit rendering and encrypted store reopen. Never selects a physical device. |
| Pre-build UX review | `node scripts/ux-review.mjs` | Browser sign-in, library, reader and every chat state on the fixture backend, desktop and phone, light and dark; contact sheet at `.artifacts/ux/web/index.html`. Native screens: `scripts/visual-check.mjs`. Process and findings: [UX_REVIEW.md](UX_REVIEW.md). |
| Paid, explicit: live study | `node scripts/chat-live-smoke.mjs --study --profile=gemini-medium-standard` | The same disposable account and numbered DPO context, tutored (Study mode, 2026-10-22): the opening turn, a partly right answer, "Give me a hint." and a "not sure"; prints each reply and the hidden notes (`study_state`) after it, fails if the notes reach the text. Four answers, 2 credits each on Gemini (about $0.03; about $0.10 on Sonnet). Rerun after `chat-study.ts` or tutor-prompt changes. |
| Paid, explicit: tutor evaluation | `node scripts/study-eval.mjs --papers=attention,ppo --personas=strong,weak,wrong --turns=5 --label=<name> [--instructions=<candidate.txt>] [--profile=sonnet-auto]` | The tutor's prompt on simulated learners (LEARNING_GUIDE.md "Evaluation"): the server's own request straight to OpenRouter, a Haiku learner per persona, transcripts and notes under `.artifacts/study-eval/`, a ledger capped at $1 (`--cap`). About $0.005 a Gemini turn, $0.02 on Sonnet. Run before changing `STUDY_INSTRUCTIONS`; `--explainer` evaluates the paper explainer the same way. |
| Paid, explicit: paper explainer | `node scripts/chat-live-smoke.mjs --paper-explainer [--profile=sonnet-auto-standard]` | The paper's AI Explainer on staging (DPO): stream timings (reading, count, summary, each entry, final), entries and links, streamed = final. 2–5 credits. Rerun after `chat-paper-explainer.ts` changes. |
| Paid, explicit: paper explainer speed | `node scripts/paper-explainer-speed.mjs --configs=gemini-low-asis,gemini-minimal --runs=3` | The model alone (the server's own request straight to OpenRouter, DPO): first chunk, count, summary, each entry, end, tokens, cost, streamed = final; `.artifacts/paper-explainer-speed/`. ≈ $0.007 a Gemini run; local ledger cap `--cap` (default $0.30). |
| Paid, explicit: model check | `node scripts/chat-live-smoke.mjs --profile=deepseek-auto-standard --eval` | The recorded check a chat model passes before it is offered (CHAT.md "Recorded check of DeepSeek"): four DPO questions in new conversations with that profile (`auto` effort allowed); every math segment typeset with the browser's temml, `[¶N]` citations resolvable, a visual or diagram, Figure 1 attached and read from the image with parts, streaming; then each quote and provider attempt from the database. Writes `.artifacts/chat-eval/<time>-<profile>.json`. About $0.04 on DeepSeek (through OpenRouter), $0.30 on Sonnet (through OpenRouter). Rerun for a new model or a prompt/tool change that could affect it. |
| Paid, explicit: live chat | `node scripts/chat-live-smoke.mjs --questions=2` | One disposable staging account, the DPO v3 metadata membership, one or two real questions with a numbered local context; prints citations (and whether each resolves), follow-ups, credits and the answer; deletes the account. About $0.25 of provider spend per run; needs `.env.staging` and a compiled `reader.json` for 2305.18290 (`--index`). Rerun after chat function or prompt changes, never routinely. |
| Hosted, note images | `node scripts/smoke-note-assets.mjs` | Staging only, unpaid: two disposable `@example.invalid` accounts; an AES-256-GCM blob made as the Notes contract says is PUT, repeated, read back and decrypted; a different digest (409), wrong digest header (400), 2 MiB + 29 B (413) and the 2 MiB + 28 B maximum; another account's GET is 404 and its same-ID object stays separate; both accounts are deleted through `account-delete` and their folders listed empty. Evidence under `.artifacts/note-assets/`. Rerun after a change to `note-assets`, migration 095's functions or account deletion. Locally: `python3 scripts/test-database.py --note-assets-only` (SQL and concurrent sessions) and `node --test tests/backend/note-assets.test.ts`. |
| Slow, browser Notes capture | `cd apps/web && READER_CORPUS_DIR=<checkout>/.artifacts/reader-corpus npx playwright test -c notes-capture.playwright.config.ts` | The browser's local snippet rasterizer (NOTES_AND_SNIPPETS.md "Browser client") in the real reader frame (bundle CSP, sandbox, shim, bridge) through a Vite-dev harness, in Chromium 1×/2×, Firefox and WebKit 2×, light and dark: text, display MathML, a figure, a mixed region and an off-screen equation, each capture compared with the browser's own screenshot of the same pixels (fails above 0.5% of pixels with no match within one device pixel, or a mean difference above 2.5). Uses the DPO Mathpix sample and, when its pinned source is present (`npm run test:slow:fetch`), 2305.18290v3 compiled by the shipped device compiler; no network. Images and metrics under `.artifacts/notes-capture/`. Rerun after a change to `frame-shim.js` capture, the reader bridge's styles or `frameDocument`. Notes journeys: `npx playwright test e2e/notes.spec.ts --project=desktop --project=phone` (fixture backend with the note-assets contract; screenshots under `.artifacts/web-e2e/notes/`). |
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
database (`test:database`), operations (`test:ops`) and hosted checks are also **slow / explicit**. They keep their existing
commands and prerequisites. `test:ops` and `test:database` record their evidence like the other tiers; each tier's
fingerprint covers what it tests (fast: the browser and admin apps, every Edge function and migration, services, scripts,
infra and the backend/operations tests; database: migrations, `tests/database/` and its runner), so `npm run test:status`
reports "source changed" after an edit anywhere that tier reads. The corpus tier also runs the device's source-metadata
reader over the cached corpus (`tests/corpus/source-metadata.test.ts`; it used to skip silently in the backend suite). There is deliberately no default command that launches all infrastructure checks.
Hosted or metered checks retain their existing authorization and budget rules; these new suites never call providers.

Live chat acceptance requires a successful terminal event and text or a validated usable tool result. HTTP 200
with an SSE error, missing `done`, or an empty result fails `chat-live-smoke.mjs`. Its `--no-auxiliaries` flag isolates
the chosen model from title/follow-up calls when diagnosing a provider; that isolation is not evidence that those
extras work. The scheduled `chat.smoke` reads the published profile recommendation and consent, then requires the
answer to name that model. A hidden-route check does not establish that ordinary clients can select it. After a
provider-policy or endpoint change, rerun the affected hosted actions and reconcile actual costs/unknown holds;
earlier green checks for another endpoint do not establish current availability.

The database suite (`npm run test:database`, or `python3 scripts/test-database.py` with its selection flags) expects a
disposable PostgreSQL 18 server on `127.0.0.1:55431`. Its binaries come from `SCIENCE_READER_PG_BIN`, else a PostgreSQL 18
`psql` on `PATH`, else this Mac's portable PostgreSQL 18.4 tools directory (`scripts/pg_tools.py`; binaries only, never
another project's files or database); otherwise the scripts stop with that instruction. Create the cluster with `initdb -A trust -E UTF8 --locale=C` (a `--no-locale` cluster is
SQL_ASCII and migration 032's collation fails) and start it with a short socket directory, e.g. `-k /tmp/srpg` (a long
path exceeds the macOS socket limit). Post-cutover tests such as `tests/database/chat_follow_up_quotes.sql` run in the
final phase with migration 058 and later.

**pgvector (migration 0152, interest index).** The migration enables `vector`, so the database suite needs a server that
offers pgvector; the portable PostgreSQL 18.4 build has none and the harness now stops with that instruction. Use
Homebrew's `postgresql@17` and `pgvector` (staging runs PostgreSQL 17 with pgvector 0.8.2):
`initdb -A trust -E UTF8 --locale=C -D <dir>`, start it on another loopback port with `-c unix_socket_directories=''`,
then `SCIENCE_READER_PG_BIN=/opt/homebrew/opt/postgresql@17/bin SCIENCE_READER_PG_PORT=<port> python3
scripts/test-database.py --interest-only` (or the full suite). The Python concurrency modules keep their own 55431 guard.
The account-deletion sweep (migrations 128 and 0159): `--deletion-sweep-only` runs `account_deletion_sweep.sql`,
`account_deletion_sweep_speed.sql` (same lists as the 032/095/128 bodies, each layer once per call, 1,500 closed
accounts inside 3 s, the listing reports) and the deletion suites that share its functions; both are in the final phase.
Model health and the answer fallback (migration 0161): `tests/database/model_health.sql` (calls answered and failed per
model, p90 first output, attention thresholds, `first_data_ms` accepted, Your AI usage naming the fallback) runs in the
final phase, with `--account-usage-only`, and with `--model-health-only` (plus the usage, OpenRouter and spending fixtures).
Assumed zero (migration 0162, JUDGMENT_LOG 21): `tests/database/openrouter_assumed_zero.sql` (only a chat attempt with no
first output, no receipt, no record ever read and a settled operation settles at 0 on or after its 12th try, or without a
generation id; its audit trail, the released hold, unchanged credits, unreported usage, the failure kept for model health;
Health and Spending figures; daily reads with a capped back-off; a late record's correction; a contradiction cleared by an
owner's reconciliation) is one of the spending fixtures (final phase, `--spending-fixes-only`, `--model-health-only`);
`--assumed-zero-only` runs it with the reconciler, OpenRouter-only reporting, costs, usage and model health fixtures.
Fast: `tests/backend/openrouter-reconcile.test.ts` (only a clean 404 on a final try, or no generation id, asks the database;
a lapsed key, a 5xx or a record for another account never does) and `openrouter-generation.test.ts` (`readGeneration`).
For you on the v4 library (migration 0154): `tests/database/feed_v4_library.sql` runs in the final phase and alone with
`--feed-only` (HTML-first imports in the profile, exclusions, the readers count, own-tag topics). Library similarity
(migration 0155): `tests/database/feed_similarity.sql`, in the same places (the similar tier and its bound, exact
nearest library paper, serving off/staff/all, no map, author counts); ranking v3: `tests/backend/feed-similarity.test.ts`.
The same fixture covers 0156 (the similar tier's distances computed before grouping; same results). The rate rules
0157 sets for serving the interest index to `all` are asserted in `tests/database/interest_index.sql`.

**Interest index, slow and opt-in.** `INTEREST_MODEL_PATH=<Xenova/gte-small@5927d17 onnx/model.onnx> node --test
tests/interest/embed-parity.test.ts` (after `npm ci` in `services/pipeline-worker`) checks the worker's embedder against
the step-1 reference vectors (cos ≥ 0.9999) and that padding never changes a fingerprint. The fast tier covers the
tokenizer (exact Hugging Face ids, padding off), n-gram counts (exactly scikit-learn), the codecs, the map build and the
delivery handler (`tests/backend/interest-*.test.ts`).

Since 2026-10-21 (review D5) `tests/database/bootstrap.sql` reproduces Supabase's project defaults (every new `public`
table, sequence and function granted to `anon`, `authenticated` and `service_role`), and `default_privileges.sql` runs
first in the final phase: no public function executable by `anon`, `authenticated` only on `v<n>_…` RPCs and
`admin_catalog_promote`, and migration 135's defaults. A last **current-schema phase** runs 23 of the 50 general
`test_*.sql` suites against every migration, each alone in a copy of one migrated template (with
`general_helpers.sql` when it does not define the shared `test.assert`/`test.reject` itself): feed popularity, library
archive/compact/descriptors/query/query edges/upload visibility/v5 commands, owner accounts, podcast profile v2, provider
allowance, reference add, reserve-chat quotes, sandbox allowance, source waits, store account transactions/purchases/
verification observations/verifier/zero-grant reason, support uploads, user deletion and workflow checks. The other 27
run only in the pre-058 phase: asset accounting, download retry, invariants, library import, pipeline, pipeline
reliability, PDF uploads and recovery, podcasts, podcast lengths/seed cap/seed episodes/checker reports, provider
accounting, reader capabilities, resume credits, rights mode, self healing, spending investigation, tags, web import and
worker acquisition exercise retired server PDF/download/OCR or direct-provider paths (refused since migrations 058, 077
and 089); feed, progress, rotation, support and sync limits read an earlier suite's rows, psql variables or policy
values. `acquisition_concurrency.py` (the 010→011 upgrade and retired server-acquisition races) and
`library_concurrency.py` (the 009→010 library upgrade and v2 import races) stay unregistered historical proofs; run
them directly with `python3 tests/database/<name>.py` if those migrations' behavior is ever in question.

OpenRouter only and costs (2026-10-21): `openrouter_only_reporting.sql` (0140: the budget check counts OpenRouter
attempts only, legacy direct-provider attempts named and still held, Health's OpenRouter cache figure) and
`account_costs.sql` (0141: per-account cost by window, feature and model, owner/MFA gate, bounded page) run with the
spending fixtures (`--spending-fixes-only`); `no_import_quota.sql` (0142) runs in the final phase and with
`--server-add-only`. The chat suite's fakes now return OpenRouter models and reported costs and send consent v6, as
production requires; the profile fixtures the server checks are `tests/fixtures/chat-profiles-v1.json` and
`chat-profiles-gemini.json` (the Swift and browser copies belong to those apps).

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
The Library row-height check renders the actual Library view. The test host is the app, so it names the default
table (layout, columns, All) rather than inheriting the choices the last UI launch saved on that Simulator: TestFlight
93's gate failed (rows 82/64 pt, a 14 pt spinner under the title) after LibraryTopicsTests left the iPhone with Tags
alone, which moves an import's status under its title.

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

October 19 expands this gate to **15 required checks**: both Apple/Google invitation refusals must remain visible
after returning to the app, and a previously failed source-paper keyword edit must reopen and complete through
the real native transport. The earlier 13-case gate missed that transport's absent `v5_set_source_details` entry.
Hosted returning-user acceptance is now `node scripts/smoke-beta-return.mjs`: two deletion/public-self-creation
cycles through the durable admission hook, verified login/account RPC and rejection of old tokens. It never
re-admits the returning fixture through Admin `createUser`. It may attempt mail to a reserved `.invalid` address;
it makes no paid AI calls and does not exercise interactive Apple/Google or the physical phone.

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

For focused Catalyst UI acceptance on this Xcode installation, pass `-enableCodeCoverage NO`. A successful UI
run otherwise stalled while Xcode downloaded runtime profiles (sample: `XCTHRuntimeProfileGenerationCoordinator`
→ `downloadRuntimeProfilesFromDirectories`), after the test had finished. This disables instrumentation only;
keep every interaction/assertion and the release optimization flags. `-collect-test-diagnostics never` avoids
large repeated system-log archives; normal test attachments still provide screenshots and failure evidence.
