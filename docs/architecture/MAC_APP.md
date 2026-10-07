# Mac app

Status (2026-10-07): built, signed for development and exercised locally with the Debug fixtures; archived
as build 15. Not yet uploaded to TestFlight (the Mac installer signing identity and a Mac App Store profile
are needed, below). Sign-in, sync and purchases have not been exercised on a Mac.

## Shape

The Mac app is the iOS target built with **Mac Catalyst** and the Mac idiom ("Optimize for Mac"): one code
base, the same bundle ID (`com.sciencereader.ios`, `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`) and
the same App Store record "Gradstep", so purchases are universal. The iOS build settings are unchanged; Mac
settings are `[sdk=macosx*]` conditions in `apps/apple/project.yml`:

| Setting | Mac value |
|---|---|
| Device family | 2,6 (Mac idiom) |
| Product name | Gradstep (menu bar, Finder); the Swift module stays `ScienceReader` |
| Entitlements | `Config/ScienceReader-macOS.entitlements`: App Sandbox, outgoing network, user-selected files read-only, Sign in with Apple, Associated Domains (`webcredentials:gradstep.ai`) |
| Icon | `AppIcon` mac sizes: the Nabla artwork in the macOS rounded-square shape with its shadow |
| Category | `LSApplicationCategoryType` education (ignored on iOS) |
| Fixtures | `FIXTURE_HOST` (Debug on the Simulator or this Mac) replaces `targetEnvironment(simulator)` in fixture code |

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
| Edit | Find in Paper… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G (while reading); Search Library ⌘F elsewhere, ⌥⌘F while reading; Search arXiv ⇧⌘F |
| View | Feed ⌘1, Library ⌘2, Reader ⌘3, Browse ⌘4, General Chat ⌘5; Show/Hide Library Beside Paper ⌃⌘S (Browse ↔ Reader); Library As, Sort Library By, Show in Library, Feed As; paper text ⌘+ / ⌘− / ⌘0; chat text ⌥⌘+ / ⌥⌘−; Refresh ⌘R; All Chats ⇧⌘Y; All Diagrams |
| Paper | Table of Contents ⌥⌘T, Back to Reading Position ⌘[ (after a citation jump), Ask About Selection › Explain / Why it matters / Related / Add paper (⌥⌘1–4), Ask About This Paper ⇧⌘A |
| Help | Report This Screen…, My Reports, Privacy & Data (gradstep.ai/privacy) |

Catalyst's document items (Duplicate, Move, Rename, Export) and the text Find/Format menus are removed
(`MacAppDelegate.buildMenu`); SwiftUI's `.textEditing`/`.saveItem` placements have no effect on Catalyst.

## Keyboard, pointer, reader

- Escape closes sheets (Catalyst does this for sheets with Cancel/Done); ⌘W also closes them
  (`macSheetKeys`, disabled while work is in progress; the recovery and consent sheets are excluded).
- Chat: ⌘Return sends (the composer ends editing first, then takes the focus back); Return is a new line,
  as on iPad. Plain Return could not be intercepted reliably in the multi-line field.
- Right-click opens every existing long-press menu (SwiftUI context menus). List rows highlight under the
  pointer (`macRowHover`).
- Reader: mouse selection shows the same selection bar; the context menu of selected text starts with the
  four selection actions, then Copy (⌘C), Share, Speech. Find in Paper uses WebKit's find bar.

## Not yet done or verified

- **TestFlight upload** — `scripts/upload-testflight-mac.sh` archives (build 15 archived and signed for
  development) and then needs, from the owner: (1) a "3rd Party Mac Developer Installer" identity in the
  login keychain (the team certificate RBR2V4DM5C exists, but its private key is held outside this project;
  either import that key or create a new Mac Installer Distribution certificate), and (2) a
  MAC_CATALYST_APP_STORE profile named "Gradstep Mac App Store" for com.sciencereader.ios with the Apple
  Distribution certificate. App Store Connect may also ask to add the macOS platform to the Gradstep record.
- Sign in with Apple/Google, email codes, Keychain device keys, sync and StoreKit purchases are the iOS code
  paths unchanged; none has been run on a Mac yet (a signed-in staging test is next).
- Library table (`PaperTable`, owned by the table work): needs keyboard selection (arrow keys, Return opens),
  double-click to open, `macRowHover()` on rows, and `Platform.isLargeScreen` instead of the `.pad` check in
  `LibraryTableView.swift` (Browse highlight). Library list rows have hover but not arrow-key selection.
- Session recording (Settings › Testing) is untested on the Mac (ReplayKit and microphone permission).
- Copy that names iOS settings (“Settings › Apple Account › Subscriptions”) is not yet adapted for the Mac.
