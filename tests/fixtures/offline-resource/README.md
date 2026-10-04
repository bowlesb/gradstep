# Native offline resource fixture

This is a synthetic, opt-in Simulator measurement fixture. It is not a source paper, a production artifact descriptor, a physical-device result or a beta admission. It uses the existing renderer, image verifier, encrypted store, offline coordinator, Library, reader and figure sheet.

The isolated optimized native target compiles and all three baseline journeys pass. The [acceptance record](../../../docs/architecture/NATIVE_RESOURCE_ACCEPTANCE.md) records raw limits and results, including the synchronous search problem; functional passage does not establish resource acceptance.

## Inputs and ownership

`generate.mjs` uses the pinned local renderer installation to generate one original equation and a 4,000 × 4,000 RGBA grid. Run from the repository root:

```sh
node tests/fixtures/offline-resource/generate.mjs
```

No dependencies or provider data are downloaded by this command. The existing renderer's process-group watchdog bounds this local authoring step. It validates the complete output and refuses to overwrite different bytes at an existing content address.

The compiled compact bundle is `4f8d21dd1ddb9ffc2be834bd824a3cef67a4619313dd58fa0b45471294a68006`, renderer build `5a7e0a6362962af49f559035b5a4d85cf8a9a2cd376cbabda648005098d8260f`. It has 190,067 member bytes, one equation and one 147,013-byte PNG containing 16,000,000 pixels. The ordinary decoded RGBA plane alone is 64,000,000 bytes; this is not a complete ImageIO/WebContent allocation estimate.

The seed app launch constructs a 4,000-row complete library through the real bounded wire decoder/reconciler. Every row has exactly 32,768 encoded metadata bytes, 512 distinct author strings, 64 categories, a 2,000-byte title and a 1,024-byte venue. The abstract fills the remaining legal metadata space. The author strings exceed Swift's short-string storage size and differ between rows. This avoids a misleading shared-array/small-string fixture. It is a maximum-byte/max-count case, not every field at its independent maximum simultaneously.

The seed launch adds two authenticated, unused `notice` members to the compact rendered bundle, reaching exactly 33,554,432 payload bytes while keeping each member at or below 16 MiB. Padding measures immutable byte ownership and storage. The actual 16M-pixel PNG independently exercises image admission and real figure rendering; padding is not a substitute for image decode. The seed-only compiled base plus fixed padding recipe supplies the final trusted fixture digest. Final manifest/member bytes are installed through `ReaderBundleCoordinator.install` and the ordinary native loader.

Seed preparation runs off the main actor. It may use substantially more memory than restoration; seeding runs in a separate app process, is never included in measured intervals and is terminated before measuring. Measured launches require the seeded database and never invoke the generator, seed builder or sample loader as fallback. They hydrate only the selected installed bundle.

## Root-owned integration

Use a separate optimized Simulator app/UI-test target, bundle-ID suffix `.resource-probe`, `OFFLINE_RESOURCE_MEASUREMENTS`, preserved `Resources/offline-resource` folder and no debugger, coverage or sanitizers. The ordinary shipping target must not package this fixture. Default `XCUIApplication()` follows the dedicated UI-test target's application binding. Set the UI-test runner environment `SCIENCE_READER_RESOURCE_TESTS=1` explicitly; ordinary test runs skip the harness.

`Config/OfflineResource.xctestplan` uses the Xcode 26.4 runtime-detection policy objects to disable main-thread and thread-performance checking. Verify the emitted `.xctestrun` policies are explicitly disabled; the older Boolean option was ignored for the UI target. Generate with `xcodegen generate --spec project.yml` in `apps/apple`, build the `ScienceReader-ResourceProbe` Release scheme for an explicit Simulator destination with `-enableCodeCoverage NO`, inspect the emitted test specification, then run `test-without-building` against the same derived data. Keep other builds/VM workloads stopped while measuring.

The new file is `Services/OfflineResourceFixture.swift`; all app-side types are Simulator-only under `DEBUG || OFFLINE_RESOURCE_MEASUREMENTS`. It supplies the account/deployment/directory/device, seed helper and numeric probe. Keep fixture routing before any Auth/network startup and return after handling it. Reject malformed fixture arguments without entering a production route.

Use these modes:

| Arguments | Behavior |
| --- | --- |
| `--offline-resource-fixture --offline-resource-mode seed` | Explicitly reset only `offline-resource-fixture-v1`, activate its synthetic encrypted store, create a normal coordinator and await `OfflineResourceFixture.seed(using:)`. Call `probe.didSeed(summary)` only after both durable commits. No need to publish/render all rows in this setup process. |
| `--offline-resource-fixture --offline-resource-mode restore` | `requireExistingSeed` before activation. Same synthetic keys/account/directory, ordinary `prepareOfflineLibrary`, no seed or fallback. |
| `--offline-resource-fixture --offline-resource-mode empty` | A separate `offline-resource-empty-v1` encrypted account directory, with no catalog rows or installation. Reuse it across control launches; never reset the maximum-case partition. |

Add `OfflineResourceStatusView` as a tiny noninteractive overlay in this target only. Its identifier is `offline.resource.status`. The visible label contains fixed numbers; its bounded accessibility value is numeric/categorical JSON. Never expose an entire catalog or private history to the runner.

Exact phase hooks, guarded by the resource target and active fixture:

1. `probe.configure(mode)` and `begin(.restore)` immediately before ordinary encrypted activation/restore. In `prepareOfflineLibrary`, retain the actual returned installation count/charged ciphertext and cached entry count, then call `restored(rows:installations:ciphertextBytes:)` after ordinary model publication. A failure or unexpected count calls finite `fail(.unexpectedState)`; no raw error text. The measured restore case must have 4,000 rows and one eligible target installation; empty must have zero. Do not decrypt member bytes just to obtain a count.
2. Bracket the existing `presentLibraryEntries` function with `begin(.publication)` and `finish(.publication,count:)`. This includes the existing author joining, mapping and sorting; do not replace it with prejoined fixture values. The phases overlap deliberately: publication is part of restoration.
3. Record the current library search from submission to its accepted result with `beginSearch(query:)` / `searchCompleted(...)`. Only the exact fixed `noMatchQuery` records this phase. Keep real filtering/sorting and the UI search field. Probe format 2 separately records background worker time and main-actor source-snapshot/publication time. The format-1 baseline phase measured synchronous main-actor scanning; these are different meanings and must not be compared as the same stall. The accepted full no-match pass is recorded, not a synthetic cached result.
4. Call `begin(.open)` immediately before the normal `coordinator.open` request. After its normal session/artifact checks and publication, call `opened(memberBytes:imagePixels:)` using the verified result's manifest totals. This phase includes the existing synchronous `ReaderBundleInput` ownership copy, Core checks and native image admission; no special zero-copy path. It checks the observed 32 MiB and 16M-pixel sizes and begins `.readerReady`.
5. In the existing scoped **successful** WebKit readiness path, call `finish(.readerReady)`. This must follow the bridge's fonts/image decoding and layout readiness, not mere WebView creation or a failure callback. Preserve all session/document/manifest guards. An invalid navigation must never mark success.
6. Bracket the existing figure-sheet WebKit readiness with `begin(.figure)` / `finish(.figure)`; the figure interaction occurs outside the opening interval. It supplies a separate app memory snapshot/elapsed event, not a WebContent peak. The harness retrieves this completed report after dismissing the sheet because the modal may hide the root status element from accessibility.

Do not add a button that bypasses normal selection, a alternate library projection, a fixture-specific search or a verification injection. The fixture does not need an installation status UI or new production navigation.

## Measurements and interpretation

`OfflineResourcePerformanceTests` has three opt-in cases: empty encrypted restoration; 4,000-row restoration plus real no-match search; and selected 32 MiB bundle opening plus real Contents and figure-sheet actions. Each measurement uses five XCTest samples plus XCTest's discarded first interval. Raw app-probe JSON for every invocation is retained, including that first interval. Each invocation uses a fresh app process. Setup/seeding, search typing, Contents and figure-sheet gestures are outside the named XCTest intervals; app-side phase timings identify their narrower work where instrumented. Same-process repeated open/close retained-growth measurements are not part of this first harness and remain pending.

The runner passes `application: app` to `XCTMemoryMetric` and `XCTCPUMetric`, so measurements target the app, not the test runner. The restore clock extends from launch through normal readiness/visible Library row. The open clock begins before row tap and ends after successful verified reader readiness. XCTest/UI-automation observation overhead remains in these end-to-end clocks. Numeric app phase clocks use monotonic uptime, preserving elapsed work separately.

App probe snapshots are Mach physical footprint. Its nullable peak is the kernel-reported **app process lifetime** footprint peak, only when `task_info` returns the relevant field. It is not the phase peak. Zero/unsupported readings remain `null`. The probe's `appIntervalPeakBytes` stays `null`; use raw application-targeted XCTest measurements for an available interval peak. Do not derive one by taking the maximum of a few snapshots. `webContentPeakBytes` is explicitly `null`; WKWebView's separate process is not included merely because the app owns the WebView. No total app-plus-WebContent peak is asserted.

Record exact Xcode/Simulator OS, app build/optimization settings, model hardware and xcresult. Preserve XCTest's raw peak/growth/CPU/launch values, phase JSON and failures. Inspect whether memory results actually exist before interpreting them. Empty-control and full-case results may be compared, but subtracting peaks from different instants/processes is not a measured allocation count.

Initial review budgets are **provisional engineering triggers**, recorded with raw evidence: 5 s restore, 3 s open plus WebKit, 100 ms each for synchronous publication and full-library no-match search. A missed budget calls for analysis (for example paged local presentation or work off the main actor); it does not justify fewer accepted rows, truncated metadata or bypassing validation. There is no invented universal Simulator memory ceiling. Fail closed on missing readiness/data, crash, allocation failure, partial presentation, wrong limits or fallback. Before beta, choose device-appropriate peak/headroom and responsiveness budgets and measure supported physical devices when the user resumes them. Simulator success cannot establish those gates.

Primary measurement guidance: [XCTest memory regressions](https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions), [performance-test configuration](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests), and [WebKit process architecture](https://docs.webkit.org/Getting%20Started/Introduction.html). These describe measurement scope, not evidence that this app has met a resource budget.
