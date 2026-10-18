# Mac app

## Build 71 figure fullscreen correction — 2026-10-18 (TestFlight 71 available)

Mac build **71**, source `927cbe9`, is **VALID / IN_BETA_TESTING** at **2026-10-18T18:02:37.560Z**
(build `867811b7-ec6b-41c5-aa4e-dfeab31932e9`), with release notes read back. The replacement universal archive
passes signature, arm64/x86_64 dSYM UUID, entitlement and resource checks. The final import/session gate passes
13/13, followed by 21/21 reported-paper replays; earlier intermittent failures remain documented in
[Testing](../TESTING.md), without claiming a diagnosed fix.

Visual review caught a gap in the first passing figure journey: SwiftUI's `fullScreenCover` opened a second
small centered sheet inside the explainer on Catalyst. The old test asserted only that the close button existed.
The Mac image viewer now receives its owning window's geometry through a SwiftUI environment value set in
`RootView`, and uses a sheet with that size and fitted presentation sizing. `fullScreenCover` ignored the native
container sizing: forcing a larger content frame only clipped the content and Close button. The existing SwiftUI
dismissal, Escape and File → Close paths remain in charge; no custom UIKit presenter or global key-window
selection is needed. iOS retains its SwiftUI fullscreen sizing. Older Catalyst versions without presentation
sizing keep the native expanded-image sheet, without forcing content outside its visible bounds.
The journey now requires at least 90% of the app-window width and 75% of its height for the image viewport and
checks both keyboard dismissal paths without losing the explanation. It also requires the image to fit its
containing window and Close to be hittable, then actually closes/reopens before continuing. The full journey
passes on macOS 26.3.1 at 17:40 UTC (`mac-fullwindow-sheet.xcresult`); fullscreen and Chat-transfer screenshots
were inspected. The four Mac keyboard journeys pass separately. No model request is made by these fixtures.

## Build 70 feedback release — 2026-10-18

TestFlight **70** is VALID / IN_BETA_TESTING. The equation/reference menu uses a public menu-button action
because Catalyst’s Mac idiom does not support presenting `UIEditMenuInteraction`; macOS 14.0–14.3 uses an
anchored action sheet. The current-Mac equation journey passes: click, AI Explainer, answer, close. The
figure-chat journey also passes. Signed archive checks cover the shared compiler/catalog, MLX Metal resource,
speech purpose strings and microphone/audio entitlements. Actual microphone recognition and signed-in owner
acceptance remain unverified. Earlier platform checkpoints below retain their original scope.

## Mac-specific review — 2026-10-08

Worktree `science-reader-mac-native-20261008`, branch `codex/mac-native-20261008`, based on `44bf3c2`.
The current distributed checkpoint is **TestFlight 25** (`fccdf2f`), VALID / IN_BETA_TESTING for Mac and iOS;
the build-17/22/24 distribution details below are historical. The build-25 upload evidence is recorded in
`docs/IMPLEMENTATION_STATUS.md`; no hosted
or paid request was made as part of the Mac review.

- The Mac toolbar now clears its workspace selection while Settings is shown, so the previously selected pane can
  be chosen again. View adds **Hide/Show Chat Beside Paper** (⌃⌘H), using the existing remembered chat visibility.
  `PaperMenuActions` has a figure-gallery callback ready for the shared paper view to publish.
- The Mac approval section now connects to the shared `RecoveryView` and `DeviceKeys` path. When an existing account
  has an approved device, the Mac creates a durable pending recipient, shows the GSDA1 QR payload and six-digit
  comparison code, and polls the existing enrollment RPCs. Approval is then activated through the same encrypted
  account key bundle used by recovery; there is no second key store. The poller backs off from 2 to 10 seconds,
  checks request state each minute, stops after 30 minutes or while the scene is inactive, and fences older/cancelled
  results. A first device with no key authority receives an actionable recovery-code message instead.
- Five development-signed Catalyst unit tests pass on macOS 26.3.1: the rendered QR is independently decoded by
  Vision back to its exact GSDA1 text; polling limits, cancellation, older-result fencing and error copy pass.
  The enrollment safety suite adds five more signed tests covering pending-recipient renewal, epoch changes,
  revocation and recovery races; all **10 focused tests passed** in the current signed Catalyst run. Evidence:
  `/private/tmp/gradstep-mac-approval-signed-focused-20261008b.xcresult` and the earlier
  `.artifacts/mac-native-20261008/MacApprovalUnits.xcresult` in the worktree. Later toolbar/UI assertions compile
  but do not yet have runtime evidence.
- A fresh signed **universal** Catalyst build-for-testing succeeds for arm64 and x86_64, using only `fixture.invalid`
  and a public fixture key, with its own DerivedData and package checkout. The final build explicitly overrides
  `SCIENCE_READER_ENVIRONMENT=mac-native-fixture-20261008` (the project otherwise overrides the xcconfig's
  environment label) and uses `ENABLE_DEBUG_DYLIB=NO` only for the local test harness. No provisioning or security settings changed. Xcode 26.4's
  missing local Metal-toolchain search-path warning and pre-existing test-concurrency warnings remain.
- **UI runtime blocked before assertions:** the local MacKeyboardTests runner exited after 73.735 seconds with
  “Timed out while enabling automation mode.” Computer Use separately reports pending **Accessibility and Screen
  Recording permissions in the ChatGPT Computer Use window**. No menu/pointer/drag/drop, live sign-in or camera
  workflow is claimed from this run. `BaselineKeyboard.xcresult` and `baseline-keyboard.log` preserve the failure.
  Earlier unit-host starts also stalled before assertions; those logs are historical. The current merged-main
  development-signed run is recorded below and passes the full native unit suite. No Mac UI automation or live
  account workflow is claimed until the local permissions are available.
- Shared PDF intake findings are handed to the shared-native owner: account/session fencing must begin before
  provider loading, temporary drop copies need cleanup, and the Add sheet currently ignores PDFs after the first.
  See [focused review and deterministic reproductions](../reviews/NATIVE_PDF_DROP_INTAKE_20261008.md).

Native table UX validation (2026-10-09): the combined column-picker, scrolling-table, v5 library-command and Mac
enrollment code passes a fresh Catalyst `build-for-testing` and the development-signed Mac unit suite: **385 tests,
4 expected skips, no failures**. The Settings toolbar regression is fixed in `beff20c`; its focused test and the
complete signed suite pass. Column sheets also use the existing Mac ⌘W dismissal. Evidence for the current full run
is `/private/tmp/gradstep-codex-mac-20261009-devsigned/Logs/Test/Test-ScienceReader-2026.10.09_09-35-43--0700.xcresult`; earlier evidence is local at
`/Users/benbowlwes/science-reader/.artifacts/mac-main-20261008/signed-unit-after-fix.log` and the result bundle at
`/private/tmp/gradstep-mac-main-20261008-signed-v3/Logs/Test/Test-ScienceReader-2026.10.08_15-47-25--0700.xcresult`;
this is unit/runtime and compilation evidence, not a new manual keyboard/pointer or live-account verification.

Mac copy polish (2026-10-08, `fe0dd2b`): the purchase footer now says **System Settings › Apple Account ›
Subscriptions** on Catalyst while retaining the iOS wording on iPhone/iPad. A fresh universal Catalyst
`build-for-testing` succeeded after the change, and focused Mac execution passed **11/11** (Mac approval 5/5 and
StoreKit purchase behavior 6/6). The same pre-existing Xcode warnings remain; no new warning was introduced.
The resulting source was archived and uploaded as **Mac TestFlight build 22**, which App Store Connect reports
as **VALID / IN_BETA_TESTING** (build `3544c167-c447-4a33-a537-60988240afc5`). Build 25 is the current
internal distribution and includes the podcast client, later shared reader fixes, and the deployed authenticated
chunked PDF-upload client with encrypted descriptor admission.

Earlier status (2026-10-07): the offline-save review passes a development-signed Catalyst `build-for-testing` for arm64
and x86_64 and **298 applicable unit tests** on this Mac (4 opt-in skips), using public local fixtures. The earlier
keyboard/UI runtime attempt reached no assertions and was interrupted, so those interaction checks remain open.
Mac sign-in, sync and purchases remain unverified. **TestFlight: Mac build 22 uploaded 2026-10-08 and processed VALID,
available to the internal "Owner" group** (see [TestFlight](#testflight--2026-10-08)). See the validation checkpoints below.

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

**Reader navigation review, 2026-10-07:** a new isolated unsigned Catalyst `build-for-testing` passes after
merging the verified offline-save and passage changes (`1aeaea2`) into the navigation branch. The app and both
test bundles contain arm64 and x86_64; the built configuration was checked against public fixture values.
Evidence: `.artifacts/reader-navigation-review-20261007-4f918777ed/catalyst-build.xcresult` and
`catalyst-build-evidence.json` in the navigation worktree. No Mac runtime assertions ran in this check.

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
`Platform.isLargeScreen`; the Mac uses the browser's wide-workspace structure (persistent Library/Feed, Reader
and Chat panes) while reusing the iPad SwiftUI surfaces and shared model for behavioral parity. Mac-only controls
and conventions live in the Mac target.

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

## TestFlight — 2026-10-08

`BUILD_NUMBER=22 scripts/upload-testflight.sh` and `BUILD_NUMBER=22 scripts/upload-testflight-mac.sh` from main
`298e66b` both completed successfully. App Store Connect reports the iOS build
`352fb5c3-3d10-44a5-884f-ac0eeb7dad3d` and Mac build `3544c167-c447-4a33-a537-60988240afc5` as version 0.1.0
build 22, **VALID**, `INTERNAL_ONLY`, and `IN_BETA_TESTING`. The iOS upload completed at 16:41 PDT and the Mac
upload at 16:46 PDT. The existing internal group receives both platforms; nothing was submitted for external
review. Logs are `.artifacts/archive-22.log`, `.artifacts/export-22.log`, `.artifacts/archive-mac-22.log` and
`.artifacts/export-mac-22.log`.

## TestFlight — 2026-10-07

`BUILD_NUMBER=17 scripts/upload-testflight-mac.sh` from main `937ef34` (App Group removed from the iOS entitlements,
Share extension not embedded): Internal configuration (staging), archived with automatic signing, exported with the
Apple Distribution identity, the "Gradstep Mac App Store" profile (OSX, expires 2027-07-08; carries Sign in with
Apple and Associated Domains, which with sandbox/network/user-selected files are all the Mac entitlements need) and the
"3rd Party Mac Developer Installer" identity. Upload succeeded 20:55 PDT; App Store Connect build
`679e44e7-da2b-4e4d-85bb-0270fd560bab`: platform MAC_OS, version 0.1.0 (17), minimum macOS 14.0, processing
**VALID**, `INTERNAL_ONLY`, internal state `IN_BETA_TESTING`, no export-compliance question. The internal group
"Owner" has access to all builds, so no extra step was needed. No macOS App Store version was required or created
for TestFlight (the upload created the MAC_OS pre-release train itself); nothing was submitted for review. Mac
builds have their own build-number train, separate from iOS. Logs: `.artifacts/archive-mac-17.log`,
`.artifacts/export-mac-17.log` in the deploying worktree.

## Not yet done or verified

- **Running the TestFlight build** — installing build 22 from TestFlight on a Mac and signing in against staging
  has not been done.
- Sign in with Apple/Google, email codes, Keychain device keys, sync and StoreKit purchases are the iOS code
  paths unchanged; none has been run on a Mac yet (a signed-in staging test is next).
- Library list rows have hover but no arrow-key selection. The table implementation is described above;
  its existing keyboard and hover behavior needs runtime verification rather than reimplementation.
- Session recording (Settings › Testing) is untested on the Mac (ReplayKit and microphone permission).

## Known issues (2026-10-16, found once Mac UI automation could run)

- **⌘W while typing a tag closed the tag sheet** (fixed 2026-10-16). The menu bar's own Close took ⌘W before the
  sheet's hidden ⌘W button. File › Close is now the app's: MacAppDelegate swaps the system's `performClose:` command in
  place (its menu anchors SwiftUI's File items; a second ⌘W command is dropped) for one every responder answers with
  `MacClose` (MacSupport.swift). It asks the frontmost sheet's guard (`macSheetKeys(enabled:)`), dismisses an unguarded
  sheet unless it asks not to be dismissed, leaves alerts for their choice, and closes the window only when nothing is
  presented. Sheets the reader must answer (recovery, chat consent) pass `enabled: false`.
- **⌘N did nothing** (fixed 2026-10-16): `CommandGroup(replacing: .newItem)` never reached the Mac's File menu, so Add
  Paper… and New Chat were missing; the group is now `after: .newItem`. `MacKeyboardTests` (4 journeys) cover both.
- The iPhone/iPad journeys assume touch and the iPad's segmented mode control; on the Mac the mode control is the
  toolbar's (check boxes to automation), menus are pop-up buttons and there is no swipe. `show()`, `wideMode()` and
  `portraitWhereSupported()` (ReaderMenuSupport.swift) cover the first two; Mac-specific journeys live in
  `MacKeyboardTests` and `MacChatRedesignTests`.

