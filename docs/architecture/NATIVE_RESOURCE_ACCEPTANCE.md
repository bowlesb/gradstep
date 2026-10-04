# Native offline resource acceptance

Status, 2026-10-04: the isolated optimized Simulator fixture, three original performance journeys and two subsequent post-restore sampling journeys pass, with independently reviewed measurement boundaries. Background search removes the large synchronous scan; the maximum library still requires a memory/restore investigation. This is not resource acceptance. Offline functional evidence is in [Native offline bundles](NATIVE_OFFLINE_BUNDLES.md).

## Measurement boundaries

Keep the normal encrypted store, model publication, coordinator, native image admission and WebKit reader paths. Generate and install the synthetic dataset in an unmeasured process, terminate it, then measure fresh processes reading only persisted encrypted rows. Measurement launches must neither generate metadata/padding nor fall back to compiled sample bytes.

Use a separate `ScienceReaderResourceProbe` application and UI-test target. It shares the application source and Core package, but has a separate bundle identifier/container, no backend or OAuth URL configuration, Simulator-only supported platforms, an explicit fixture compilation flag and a preserved fixture resource folder. The shipping application excludes the resource folder. Use the optimized Release configuration with debugger, coverage, GPU validation and checkers disabled; verify generated build settings and scheme before measuring. No physical-device testing is authorized while the user's pause remains in effect.

The native `Config/OfflineResource.xctestplan` disables Xcode 26.4's `threadPerformanceCheckerRuntimeIssueDetection` and `mainThreadCheckerDetectionPolicy` using explicit `enabled: false` policies. The old `performanceAntipatternCheckerEnabled` option alone did not disable the UI target checker. The emitted `.xctestrun` must contain both corresponding `RuntimeDiagnosticsPolicy` entries with `detectionEnabled: false`; inspect this before running. The app and Core compile with `-O` without coverage or sanitizer instrumentation. The initial run is functional evidence only; a superseded checker-enabled rerun was interrupted and is not acceptance evidence.

## Dataset

- 4,000 distinct valid library entries, each with 512 authors, 64 categories and exactly 32,768 bytes of metadata under the wire encoder. Distinct short collection values plus a bounded abstract exercise both byte and object-count limits. Retain the complete catalog and its actual cursor.
- One installed, independently verified synthetic reader bundle. The compact base fixture is produced by the existing renderer; it contains an equation and a valid 4,000 × 4,000 PNG referenced by HTML and the figure index. The seed phase adds bounded notice members to make total member payload exactly 32 MiB.
- An empty-cache control under the identical application build and runtime.

The existing Core capacity fixture maximizes metadata bytes but not collection counts. Its input dictionaries, live observation and returned values coexist within one test process, so its timing is useful but its process memory would not isolate restoration. Likewise, notice padding alone does not exercise decoded-image demand. The 16-million-pixel fixture adds roughly 61 MiB of raw RGBA pixels before other native/WebKit allocations.

## Recorded phases

| Interval | Required completion evidence |
| --- | --- |
| Account store activation through restoration | Exact complete cursor, 4,000 entries and one installed-copy summary. |
| Restoration through model publication | Normal Library view with its first row visible; avoid enumerating thousands of accessibility nodes. |
| Full-library no-match search | Normal search scans the entire metadata set and shows its empty result. |
| Selection through native verification | Normal decryption, hash verification, owned input copies and PNG/ImageIO checks. |
| Verified handle through readable paper | Normal bridge readiness, visible figure and working Contents. |

Use numeric-only phase/signpost diagnostics. Keep XCTest memory and elapsed metrics, the exact metric names, individual iterations and raw result bundles. Measure five serial fresh-process repetitions after the framework's discarded warm-up; report that behavior explicitly. These are process-cold runs, not disk-cold runs.

Retain the synchronous owned `ReaderBundleInput` copy and the model's author joining, publication and search inside their measured intervals. Moving fixture setup outside the interval must not move real application work outside it. Use normal action paths for repeated open/close cycles; record that returning to Library can intentionally retain one selected bundle.

## Provisional engineering gates

These budgets identify design problems; they are not iOS termination thresholds or proof of supported-device headroom.

| Measure | Initial gate |
| --- | --- |
| Complete restoration | At most 5 seconds in each measured optimized Simulator iteration. |
| Selected bundle opening | At most 3 seconds in each measured iteration. |
| Main-thread publication/search stall | Investigate any interval above 100 ms. |
| Library incremental application peak | Investigate above 300 MiB relative to empty control. |
| Library retained application growth | Investigate above 180 MiB relative to empty control. |
| Bundle-opening incremental application peak | Investigate above 192 MiB relative to the restored library. |
| Five repeated open/close cycles | No continuing retained growth attributable to payloads, tasks or web views after the first warm cycle. |

Report application memory and WebContent memory separately. Missing peak metrics remain unknown; a final RSS snapshot is not a peak measurement. Application-only memory does not establish the reader's total footprint. Any crash, incomplete catalog, fallback data, or missing/unattributed metric prevents claiming its corresponding gate passed.

If whole-library hydration exceeds the budget, review paged local presentation and bounded search as an architectural change. Do not truncate a valid server catalog or silently narrow its metadata contract. Lowest-supported-device profiling, actual disk-full/process-kill behavior and physical-device locked-state tests remain separate acceptance gates when device work resumes.

## Baseline results

`.artifacts/offline-resource-baseline.xcresult` contains all three passing journeys (zero skips/failures, 361.830 seconds of test-case time), each with five measured fresh processes after one discarded warm-up. The device is iPhone 17 Pro Simulator/iOS 26.4 on an Apple M1 Max MacBook Pro with 32 GiB RAM, macOS 26.3.1(a), Xcode 26.4 (17E192). The separate seed process installs all 4,000 complete rows and exactly 32 MiB of bundle members through the normal verifier/store. Counts, verified opening, no-match search, Contents and the 16M-pixel figure sheet pass.

| Baseline measure | Five measured iterations |
| --- | --- |
| Empty-account activation/restore, app phase | 217–239 ms |
| Maximum-library activation/restore plus model publication, app phase | 4,125–4,209 ms |
| Synchronous model publication | 76–80 ms |
| Maximum-library launch through visible row, XCTest clock | 7.302–7.377 s |
| Full no-match scan on main actor | **812–828 ms** |
| Selected bundle decrypt/verify/publish, app phase | 576–592 ms |
| Subsequent successful reader WebKit readiness, app phase | 1,019–1,035 ms |
| Selected row tap through reader readiness, XCTest clock | 2.851–3.825 s |
| Figure sheet successful readiness, app phase | 698–732 ms |

XCTest's application-targeted `Memory Peak Physical` is 57,088–57,317 kB for the empty control, 351,804–385,080 kB during maximum restoration and 353,000–387,423 kB during selected-bundle opening. Raw `Absolute Memory Physical` at the end of the restoration interval is 345,988–379,116 kB. These are the tool's decimal kB units. Raw per-iteration metrics and their names are preserved under `.artifacts/offline-resource-baseline-metrics/`; app phase JSON and the figure screenshot are under `.artifacts/offline-resource-baseline-attachments/`. Source, binary and test-plan hashes are in `.artifacts/offline-resource-baseline-source.json`.

The baseline required the large metadata scan to leave the UI thread and stop repeating during view renders; the asynchronous search checkpoint below implements that change. The visible-row clock exceeds the provisional restore trigger, with measurable automation overhead (empty control 3.431–3.490 s); both app and XCTest clocks are reported rather than subtracting that overhead as if measured independently. Some opening-clock iterations also exceed 3 s. Library memory is large enough to require review, including paged presentation if necessary. The app's restore-end probe still holds the returned presentation, and neither it nor one XCTest endpoint establishes settled retention. Same-process repeated cycles, total WebContent memory and supported physical-device headroom remain pending. No memory gate is declared passed from these snapshots.

## Asynchronous search checkpoint

The same three journeys pass after [native search scheduling](NATIVE_LIBRARY_SEARCH.md) changes, with the same optimized target, dataset, device and disabled runtime checkers. `.artifacts/offline-resource-search.xcresult` retains five measured iterations after warm-up. The full no-match scan takes 789–808 ms on its detached worker, with 795–814 ms request-to-result latency. The one-time main-actor metadata preparation takes 10.5–12.9 ms; final no-match publication takes 0.046–0.058 ms. Neither library getters nor body evaluation rescan the catalog.

Full restore/model publication is 4.134–4.249 seconds, including 81–83 ms of model publication; XCTest launch-to-visible-row is 6.996–7.137 seconds. Native opening is 564–581 ms, followed by 995–1,037 ms to WebKit readiness; XCTest row-tap-to-ready is 2.819–3.868 seconds. The figure sheet completes in 652–717 ms. These results do not resolve the existing startup/opening triggers.

Application-targeted XCTest peaks are 351,952–362,060 kB during full restoration and 337,321–378,199 kB during opening. Restore-end absolute memory is 345,316–355,310 kB. These remain decimal kB, process/interval-specific observations, not proof of settled retention or memory savings. The raw metrics, app phase attachments and source/binary hashes are under `.artifacts/offline-resource-search-*`.

The initial empty-control journey overlapped a short local filename scan, so its values are not used for comparison. The isolated repeat in `.artifacts/offline-resource-search-control.xcresult` passes with five measured iterations: 212–247 ms app restoration, 3.499–3.552 seconds XCTest clock and 58,038–58,120 kB peak application memory. No build, VM or filename scan overlapped the maximum-library/opening journeys or this repeat. The original run and its note remain intact.

The ownership review identified two separate paths: completed native cache-save tasks retained an unnecessary presentation result, and the model retained previously opened paper bundles after selection changes. The [retention follow-up](NATIVE_OFFLINE_BUNDLES.md) fixes both and passes model/UI regressions; it does not establish measured savings. Measure a settled checkpoint after restore/search/write completion and then passive footprint samples; include different-paper open/close cycles, since reopening one fixture cannot reveal per-paper accumulation. Preserve the complete encrypted catalog/cursor and full search coverage.

## Post-restore footprint observations

The independently reviewed format-3 probe starts sampling only after the restoration function has returned and the actual search, bundle-coordinator work and accepted local writes have joined. It retains scalar validation state and existing owners, not the decoded restoration result. Before each reading and completion it requires the same account/session, search and library ownership, complete row counts, Library destination and unopened selection. Requested offsets use absolute monotonic deadlines; actual elapsed times are recorded, and a missing current-footprint metric fails the test. No allocator purge, forced collection or intermediate probe-publication work is inserted between readings.

Both journeys pass in `.artifacts/offline-resource-settled.xcresult`, using the same optimized target, runtime and maximum dataset. All six invocation attachments are retained; invocation 0 is the framework-discarded warm-up and the following five are reported below. No build, VM, database test or source acquisition overlapped the measurement. Source/binary/test-policy hashes and the exact source delta against `4a7d412` are in `.artifacts/offline-resource-settled-source.json` and `offline-resource-settled-source.patch`; raw attachments, XCTest CSV metrics and a derived numeric summary are in the matching `-attachments/`, `-metrics/` and `-summary.json` artifacts.

| Current application footprint | Empty library, five runs | Maximum library, five runs |
| --- | --- | --- |
| Initial reading after the joins | 38.3–39.7 MiB | 250.9–365.6 MiB |
| Requested 250 ms reading | 45.8–47.9 MiB | 339.6–365.1 MiB |
| Requested 500 ms reading | 43.6–51.8 MiB | 339.6–365.1 MiB |
| Requested 1,000 ms reading | 44.4–44.9 MiB | **339.4–365.1 MiB** |

The maximum-library 250 ms readings actually occur at 261–652 ms, and the 500 ms readings at 506–652 ms; deadlines do not manufacture regularly spaced observations when the main actor is occupied. Final readings occur at 1,005–1,036 ms. The initial low observation does not persist into later readings. These snapshots are not stable-heap measurements, and the probe does not identify which allocations or UI work explain the growth.

The unchanged app restore phase takes 214–265 ms for the control and 4.180–4.241 seconds for the maximum case. XCTest launch-through-samples clocks are 3.509–3.566 and 6.491–7.509 seconds respectively; they include the intentional one-second sampling window. Application-targeted XCTest interval peaks are 57,547–58,104 kB and 363,060–390,683 kB respectively, in the tool's decimal units. The app's lifetime peak and XCTest's interval peak remain distinct from the current footprints in the table.

The large catalog remains above the provisional retained-growth investigation trigger across the final readings, even allowing for the control's variation. Review bounded local presentation and search before accepting the whole-library hydration design; preserve every authenticated row, the complete cursor, full-field search semantics and encrypted persistence. Do not simply reduce the valid catalog or metadata contract to meet a benchmark. This offline-only journey does not exercise live cache-save publication or different-paper accumulation, so it establishes neither savings from those fixes nor WebContent/physical-device headroom. Repeated open/close cycles, live refresh, allocation attribution and total reader memory remain open.

## Allocation diagnostic boundary

A separate diagnostic build adds `--offline-resource-attribution`, accepted only
by the explicit Simulator resource target and only with the existing post-restore
sampling mode. It emits one bounded numeric JSON checkpoint after the unchanged
four readings and final ownership guard. It adds no accessibility polling,
catalog text, allocator purge or forced collection. Normal Debug and shipping
builds cannot enable this diagnostic. Independent source review is clear, and
the optimized build passes in `.artifacts/offline-attribution-counters-build.log`.
The original benchmark binary and evidence remain intact.

Three `xctrace` launch attempts stalled before recording or checkpoint emission,
including a minimal Allocations-only launch. Their owned processes were stopped;
there is no valid allocation trace. A separate launch with stack logging reached
the empty checkpoint, but `vmmap`, `heap` and `malloc_history` all failed to obtain
the target's DYLD information. These failures establish neither allocation
ownership nor their own underlying cause. Logs are retained under
`.artifacts/offline-attribution-*`; no global debugging permission, Xcode version
or device setting was changed.

The fallback diagnostic reads `malloc_zone_statistics(nil, ...)` inside its own
process after sampling. It reports blocks in use, current allocator bytes in use
and allocator bytes reserved. These are not physical-memory or peak counters.
The allocator query and Mach footprint are separate readings: subtracting them
does not establish fragmentation or exact ownership. A valid run must contain
exactly one complete checkpoint with the launched PID, correct complete dataset,
four successful footprint readings and no opened bundle. Missing, duplicate,
truncated or failed reports are not measurements. Plain launches must disable
stack logging and avoid concurrent builds, VM activity and XCTest/AX inspection.
Such a launch remains a single-process diagnostic, not a replacement for the
repeated baseline or whole-reader resource acceptance.

Both plain launches produced valid checkpoints from the same optimized binary,
SHA-256 `59055d6af930c8876c2bb821e891976c76c31528e367b6bb2fb463aef11abe5c`.
The exact installed binary and all 81 captured source inputs matched the manifest.
The isolated task VM was stopped; no build, profiler or automated UI inspection
overlapped either run. Both applications were explicitly terminated afterward.

| Single-process diagnostic | Empty library | Maximum library |
| --- | --- | --- |
| Allocator blocks in use | 76,268 | 957,502 |
| Allocator bytes in use | 12.3 MiB | 244.8 MiB |
| Allocator bytes reserved | 28.0 MiB | 431.3 MiB |
| Final current application footprint | 36.1 MiB | 313.5 MiB |
| Actual final sample offset | 1,032 ms | 1,030 ms |
| Restore/model publication phase | 126.8 ms | 5,288.8 ms |

The maximum run restored all 4,000 rows and one installation without opening its
bundle. The live allocator count warrants further investigation even without
XCTest inspecting the view hierarchy. It does not identify particular retainers,
prove a leak, establish fragmentation or demonstrate savings against the earlier
benchmark. The changed observation method and single run also do not establish
a timing regression; the measured restore remains above the provisional trigger.
Validated raw checkpoints are
`.artifacts/offline-attribution-{empty,restore}-counters-evidence.json`, with the
source/binary manifest and exact diagnostic delta in
`offline-attribution-counters-source.{json,patch}`. The bounded launch/validation
recipe is `.artifacts/run-offline-attribution-counters.py`.

References: [Apple memory-performance testing](https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions), [Apple performance-test configuration](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests), [WebKit process architecture](https://docs.webkit.org/Getting%20Started/Introduction.html), [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md).
