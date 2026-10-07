# Mac app

Status (2026-10-07): the offline-save review passes a development-signed Catalyst `build-for-testing` for arm64
and x86_64 and **298 applicable unit tests** on this Mac (4 opt-in skips), using public local fixtures. The earlier
keyboard/UI runtime attempt reached no assertions and was interrupted, so those interaction checks remain open.
Mac sign-in, sync, purchases and distribution remain unverified. See the validation checkpoints below.

**Merge validation, 2026-10-07:** integration with `main` through `5f95c97` passed a fresh unsigned Catalyst
`build-for-testing` in 60.1 seconds. The app, unit-test bundle and UI-test bundle each contain arm64 and x86_64.
The newer chat-title code/tests and TestFlight feedback records are preserved. Logs and the result bundle remain
in the integration worktree under `.artifacts/merge-validation-20261007/` (`catalyst-build.log` and
`CatalystBuildForTesting.xcresult`). This is compilation evidence; no native runtime tests ran in this merge check.

**Offline-save review, 2026-10-07:** a development-signed Catalyst fixture build now launches on this Mac
(macOS 26.3.1) and passes all 298 applicable unit tests, with 4 opt-in skips and no failures. The test targets
explicitly support Catalyst and macOS 14; without those settings Xcode preflight required its macOS 26.4 SDK
version despite the app's macOS 14 floor. A citation test's touch-only underline expectation now follows actual
hover capability. Evidence: `.artifacts/offline-save-review/mac-verified.xcresult` in the offline-save worktree.
No Developer Mode or security setting changed. This verifies native model/reader unit behavior and launch,
not the keyboard/UI workflows or live services listed below.

## Spontaneous launch popup — 2026-10-07

The owner reported “ScienceReader cannot be opened because of a problem” without deliberately launching an app.
The newest matching crash at 14:13:39 was an **iOS Simulator** test app under `launchd_sim`, not the Catalyst build.
DYLD could not resolve `ScienceReaderCore.TextAnchor.passage(artifactID:selection:quote:)`. Its debug image had an
absolute runpath into another active test worktree's scratch build; that framework was replaced shortly after the
crash. The replacement exports the missing symbol and matches the embedded framework. This supports mixed/stale
Simulator build products as the cause; it is not evidence that macOS needs an update or the user app needs reinstalling.

Other agents' test processes and files were left untouched. The current Catalyst compile artifact's embedded and
external Core frameworks matched and its imports resolved for both architectures, but it remains an unsigned test
artifact. This triage does not establish successful Mac launch, authentication, purchases or distribution. Future
Simulator jobs should keep builds/installations and package products isolated for the full test lifetime.

## Shape

The Mac app is the iOS target built with **Mac Catalyst** and the Mac idiom ("Optimize for Mac"): one code
base, the same bundle ID (`com.sciencereader.ios`, `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`) and
the same App Store record "Gradstep", intended to support universal purchases. Purchase behavior still needs
Mac verification. The iOS build settings are unchanged; Mac settings are `[sdk=macosx*]` conditions in
`apps/apple/project.yml`:

| Setting | Mac value |
|---|---|
| Device family | 2,6 (Mac idiom) |
| Product name | Gradstep (menu bar, Finder); the Swift module stays `ScienceReader` |
| Entitlements | `Config/ScienceReader-macOS.entitlements`: App Sandbox, outgoing network, user-selected files read-only, Sign in with Apple, Associated Domains (`webcredentials:gradstep.ai`) |
| Icon | `AppIcon` mac sizes: the Nabla artwork in the macOS rounded-square shape with its shadow |
| Category | `LSApplicationCategoryType` education (ignored on iOS) |
| Fixtures | `FIXTURE_HOST` (Debug on the Simulator or this Mac) replaces `targetEnvironment(simulator)` in fixture code |
| Unit-test host | `ScienceReaderTests` alone sets `TEST_HOST[sdk=macosx*]` to `$(BUILT_PRODUCTS_DIR)/Gradstep.app/Contents/MacOS/Gradstep`, matching the Mac product name |

Mac-only code lives in `ScienceReader/Mac/`: `MacSupport.swift` (window, toolbar, platform checks, row hover,
sheet keys, the reader's web view) and `MacCommands.swift` (menu bar). Shared views ask `Platform.isMac` /
`Platform.isLargeScreen`; the Mac is treated as a large iPad unless a Mac path is better.

## Window

- Always the wide layout (Feed · Library · Reader · Browse · General Chat). Minimum 720 × 520 pt, so it tiles
  beside another app on a 13-inch screen; first launch 1280 × 820; the last size is remembered.
- The view switch and Settings move from the app's header row into the window's unified toolbar (centred
  segmented control, gear at the right); the header row is not drawn on the Mac. Each pane keeps its own
  bar (contents, title, "…"), so the one-"…"-per-screen rule is unchanged.
- The privacy cover shown when the iOS app leaves the foreground is off: a Mac window stays visible.
- App-drawn header controls are 34 pt (44 pt touch targets on iOS); leading text bar buttons keep their width
  (Mac Catalyst otherwise draws "Cancel" in a circle as "C…").

## Menu bar

Each item mirrors an on-screen control (header buttons and the "…" menus); nothing is menu-only.

| Menu | Items |
|---|---|
| Gradstep | Settings… ⌘, |
| File | Add Paper… ⌘N (sign-in first when signed out), New Chat ⇧⌘N, Close ⌘W |
| Edit | Find in Paper… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G (paper present in Reader or Browse); Search Library ⌘F elsewhere, ⌥⌘F beside the paper; Search arXiv ⇧⌘F |
| View | Feed ⌘1, Library ⌘2, Reader ⌘3, Browse ⌘4, General Chat ⌘5; Show/Hide Library Beside Paper ⌃⌘S (Browse ↔ Reader); Library As, Sort Library By, Show in Library, Feed As; paper text ⌘+ / ⌘− / ⌘0; chat text ⌥⌘+ / ⌥⌘−; Refresh ⌘R; All Chats ⇧⌘Y; All Diagrams |
| Paper | Table of Contents ⌥⌘T, Back to Reading Position ⌘[ (after a citation jump), Ask About Selection › Explain / Why it matters / Related / Add paper (⌥⌘1–4), Ask About This Paper ⇧⌘A |
| Help | Report This Screen…, My Reports, Privacy & Data (gradstep.ai/privacy) |

Catalyst's document items (Duplicate, Move, Rename, Export) and the text Find/Format menus are removed
(`MacAppDelegate.buildMenu`); SwiftUI's `.textEditing`/`.saveItem` placements have no effect on Catalyst.
`findsInPaper` now includes Browse when the paper publishes its menu actions; Settings still uses library
search. Previously Browse offered library search for ⌘F despite showing the paper beside it.

## Keyboard, pointer, reader

- Sheets use Catalyst's Cancel/Done handling for Escape. `macSheetKeys` adds ⌘W to participating sheets;
  recovery and consent sheets are excluded. Its hidden shortcut button stays registered and enabled, with
  dismissal guarded inside the action, so a busy sheet retains ownership of ⌘W. Apply the modifier outside
  disabled content. Actual shortcut routing still needs the runtime checks below.
- `TagEditorView` owns its close guard: saving, changed tags, or an unsubmitted nonblank tag draft prevents
  both interactive dismissal and ⌘W dismissal. Explicit Cancel can discard edits when no save is running.
- `ReportComposer` prevents interactive dismissal and ⌘W while queueing a report. While the screenshot
  editor is presented, the parent also refuses ⌘W dismissal; `ScreenshotEditor` owns its own close handler.
- Chat: ⌘Return sends (the composer ends editing first, then takes the focus back); Return is a new line,
  as on iPad. Plain Return could not be intercepted reliably in the multi-line field.
- Right-click opens every existing long-press menu (SwiftUI context menus). List rows highlight under the
  pointer (`macRowHover`).
- `PaperTable` already implements ↑/↓ row selection, Return activation, and pointer hover backgrounds
  through its own `onHover`/`rowBackground`, shared by Library and Feed. A single click performs the row's
  primary action; there is no separate double-click handler. `LibraryTableView` uses `Platform.isLargeScreen`
  for the regular column preferences and the open-paper highlight in Browse, including Mac. These source
  paths still need Mac keyboard, focus, and pointer verification.
- Reader: mouse selection shows the same selection bar; the context menu of selected text starts with the
  four selection actions, then Copy (⌘C), Share, Speech. Find in Paper uses WebKit's find bar.

## Validation checkpoint — 2026-10-07

The current integration was compiled with Xcode 26.4 (17E192), Debug, destination
`generic/platform=macOS,variant=Mac Catalyst`, and `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`,
`CODE_SIGN_IDENTITY=`. A temporary ignored staging xcconfig supplied only `https://fixture.invalid` and a
public fixture key; it was removed afterwards. Fresh DerivedData and a separate copy of the package cache
were used under `.artifacts/mac-integration-final/`.

- **Compilation passed:** `build-for-testing` exited 0 in 49.1 seconds with `TEST BUILD SUCCEEDED`.
  The app, `ScienceReaderTests`, and `ScienceReaderUITests` binaries each contain arm64 and x86_64.
  This includes the final tag-draft guard and Catalyst-only `MacKeyboardTests`.
- **Evidence:** [build log](../../.artifacts/mac-integration-final/catalyst-final-test-build.log) and
  [result bundle](../../.artifacts/mac-integration-final/CatalystFinalBuildForTesting.xcresult).
  Existing service/test concurrency warnings and the local Metal-toolchain search-path warning remain.
- **Test configuration:** the scoped unit-test host above fixes the generated host path, which otherwise
  points to `ScienceReader.app` instead of `Gradstep.app`. The UI runner retains Xcode's generated host
  configuration. Xcode's Catalyst XCTest API supports `typeKey(_:modifierFlags:)`.
- **Runtime pending:** a separate keyboard test attempt reached no assertions and was interrupted after
  roughly five minutes. Developer mode was reported disabled, and CUA Accessibility/Screen Recording
  permissions were pending; the cause of the stalled run is unproven. The owner has a pending permissions
  question. No permission or security settings were changed, and no further runtime attempt was made.
  The fresh build above did not launch the app or test runner.

`MacKeyboardTests` covers closing a clean tag sheet, preserving an unsubmitted draft and changed tags under
⌘W, preserving the app window, explicit Cancel, and Browse's Find in Paper / Search Library menu entries.
These are compiled assertions, with no runtime pass yet. Busy-report and nested screenshot-editor routing,
actual ⌘F navigation, table keys while editing search text, and pointer behavior need additional Mac checks.
No current signing, provisioning, live-account, sync, purchase, or distribution result follows from this build.

## Not yet done or verified

- **TestFlight upload** — the inherited build-15 checkpoint recorded a development-signed archive, with no
  Mac TestFlight upload. Current changes have only the unsigned compile validation above; signing and
  provisioning have not been revalidated. The recorded prerequisites for `scripts/upload-testflight-mac.sh`
  are (1) a "3rd Party Mac Developer Installer" identity in the login keychain (the prior checkpoint identified
  team certificate RBR2V4DM5C but did not have its private key in this project), and (2) a
  MAC_CATALYST_APP_STORE profile named "Gradstep Mac App Store" for com.sciencereader.ios with the Apple
  Distribution certificate. App Store Connect may also ask to add the macOS platform to the Gradstep record.
- Sign in with Apple/Google, email codes, Keychain device keys, sync and StoreKit purchases are the iOS code
  paths unchanged; none has been run on a Mac yet (a signed-in staging test is next).
- Library list rows have hover but no arrow-key selection. The table implementation is described above;
  its existing keyboard and hover behavior needs runtime verification rather than reimplementation.
- Session recording (Settings › Testing) is untested on the Mac (ReplayKit and microphone permission).
- Copy that names iOS settings (“Settings › Apple Account › Subscriptions”) is not yet adapted for the Mac.
