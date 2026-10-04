# Native offline resource acceptance

Status, 2026-10-04: the isolated optimized Simulator fixture and three performance journeys pass, with an independently reviewed measurement boundary. The baseline identifies unacceptable synchronous search and a memory/restore investigation; it is not resource acceptance. The independently reviewed offline functional checkpoint is `cd1b724`; its evidence is in [Native offline bundles](NATIVE_OFFLINE_BUNDLES.md).

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

The large metadata scan must leave the UI thread, and view renders must not repeat it. The visible-row clock exceeds the provisional restore trigger, with measurable automation overhead (empty control 3.431–3.490 s); both app and XCTest clocks are reported rather than subtracting that overhead as if measured independently. Some opening-clock iterations also exceed 3 s. Library memory is large enough to require review, including paged presentation if necessary. The app's restore-end probe still holds the returned presentation, and neither it nor one XCTest endpoint establishes settled retention. Same-process repeated cycles, total WebContent memory and supported physical-device headroom remain pending. No memory gate is declared passed from these snapshots.

References: [Apple memory-performance testing](https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions), [Apple performance-test configuration](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests), [WebKit process architecture](https://docs.webkit.org/Getting%20Started/Introduction.html), [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md).
