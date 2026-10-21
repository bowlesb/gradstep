# Native app code review — 2026-10-21

Owner request: review the native app (ScienceReader app target, ScienceReaderCore, Mac Catalyst support, share
extension, tests), with emphasis on the ~21 commits touching `apps/apple` since 2026-10-16 (1d5f7aa … 562ba8b), for
bugs, anti-patterns, structure, duplication, debt, performance, extensibility and iPhone/iPad/Mac parity.

**Method.** Read-only. Five parallel review passes (ReaderModel; views and idiom parity; chat stack; services, sync
and Core; reader feature views, bridge, tests and config), then a second pass that re-read the cited lines for every
High/Medium finding and most Lows. One `swift build` of ScienceReaderCore (separate scratch path) for compiler
warnings, and one micro-benchmark of keyword derivation compiled with `-O` in the scratchpad. No app build, install,
Simulator, UI test or device was used. Nothing in the repository was changed except this file.

**Conventions.** Paths are relative to `apps/apple/`. Line numbers are at HEAD `82c8656`. Severity: **High** (user
data, money or sign-in at risk in ordinary use), **Medium** (visible wrong behaviour or measurable cost in plausible
use), **Low** (edge case, latent, or hygiene). "Uncertain" marks findings that are reasoned from code and need a
runtime check before acting.

## Status — fixes of 2026-10-21

Each finding was re-read against the code at `82c8656` before it was changed; all the ones below were real. "Fixed"
names the commit (its message lists the tests). Evidence and limits are in
[implementation status](../IMPLEMENTATION_STATUS.md). Rows not listed (remaining Lows, E refactors) are unchanged.
Nothing was released or deployed; the browser part of A5/A6 is source only.

| ID | Status | Commit | Notes |
|---|---|---|---|
| A1 | Fixed | `1d0ed71` | A 401 refreshes once (forced, unless a concurrent request already replaced the token) and replays once, for RPCs and the chat stream. Only the refresh's session-ended codes, or a fresh token refused too, end the session; a refresh that can't reach the server keeps it. Expiry stored as min(`expires_at`, now + `expires_in`). The unreachable `libraryCommandErrors` 401 branch is removed. |
| A2 | Fixed | `61f67e9` | The consumed selection is restored when the question's commit fails. |
| A3 | Fixed | `61f67e9` | The unsaved complete answer is kept (memory, per composer) and shown; its Try again re-runs only the seal. Transport/provider failures still ask again. |
| A4 | Fixed | `be82cd2` | All listed fields are cancelled/cleared in `clearAccountView`; `refreshChatProfiles` checks the session. The new test also exposed sign-out starting a download of the old account's paper (the `libraryImports` observer took the cleared rows for finished imports): fenced on the account. `SessionState` (E1/E7) not done. |
| A5 | Fixed | `8d3407d` | The outcome is the server's; the catalog assignment is a best-effort step of its own, skipped when already there; refresh on every "added". The arXiv Add path keeps its documented order (LIBRARY_CATALOGS.md: assignment persisted before the import begins). The browser's Add sheet had the same failure mode; fixed too. |
| A6 | Fixed | `8d3407d` | `source:openalex:W…` key in Core and the browser; a web paper moved earlier under `paper:<document>` keeps that until moved again. Readers before this change ignore a batch with the new key kind (each assignment is written alone), so they show that paper in Default. |
| A7 | Fixed | `be82cd2` | Opening joins the running background preparation and shows its progress. E7's registry is not built. |
| A8 | Fixed | `044e8d3` | A placeholder generation ("Preparing the paper on this device…", Stop withdraws it with Get answer) waits for that paper's own preparation, never another paper's. No dedicated test: it needs a combined chat + import-network fixture. |
| A9 | Fixed | `044e8d3` | CHAT.md: only the reader's chosen Stop is charged. Closing the sheet leaves the answer running under its own composer (as Chat does on a conversation change); it is saved there. |
| A10 | Fixed | `044e8d3` | Reasoned from `.task(id:)` re-running on reappearance (the existing `expandedImage` guard shows the cover causes a disappearance); the re-run now keeps the same figure's session. Not reproduced with a mid-stream journey. |
| A11 | Fixed | `be82cd2` | Run IDs; a cancelled run only clears itself and restores the idle timer only when no newer run is active; a new run awaits the cancelled one. |
| A12 | Fixed | `e70cd8e` | One `pendingArchiveOverrides()` for all three sites. |
| A13 | Fixed (part) | `e70cd8e` | Archive sends the stored `source_tags` (or a pending edit's); the server then leaves `tags_customized` unchanged, as for the browser, which already did this. No server or command-format change. Broad own tags hidden since c4d15d9 are still dropped by the next save: left as intended (the editor never shows them). |
| A14 | Fixed (part) | `044e8d3` | Retired IDs are dropped from both keys at start, `localDefault` returns only offered models, and the session starts from the general default. The engine carried by `askAboutEquation`/`askAboutFigure` (D2) is unchanged. |
| A15 | Not done | — | Latent while the share extension isn't embedded; moving the sheet is RootView restructuring (E4) that would conflict with the parallel Notes work. |
| A21 | Not done | — | The server charges usage up to the recorded Stop, so dropping deltas in the 3 s window would hide text the reader pays for; a server decision first. Other bullets unchanged. |
| A25 | Not done | — | Uncertain; needs an audio check on a device (physical phone paused). |
| B1 | Fixed | `da164d5` | `GradstepCommands` serve iPad too (Settings… and Help Mac-only); Find in Paper goes through the paper's own checks (`PaperMenuActions.find`); ⌘Return/Escape use `keyboardShortcut`; the iPad-only ⌘F and ⇧⌘R view shortcuts are removed (they would compete). |
| B2 | Partly | `da164d5` | Equation/figure/promoted threads render with Chat's `TranscriptMessage` (sources, papers named, follow-ups, interruption notes, figure-part crops, quote actions, diagrams by entity), keeping their identifiers and citation handling. Their scroll policy is unchanged (hosting the table transcript there is E6). |
| B3 | Partly | `da164d5` | ⌘Return and the Mac end-editing order in the equation/figure composer. One shared composer (with `AISelectionButton`/Answer options) is a visible change to propose first. |
| B4 | Fixed | `da164d5` | `searchAuthor` shows the Library on every layout; the chat beside the paper (split and reading mode) learns it from its placement (`chatBesidePaper`). E3 not done. |
| B5 | Partly | `da164d5` | Added Find Similar Papers, Reader Version Details…, a Catalog picker, Manage Catalogs…, Sort Feed By, Hide Papers in Your Library; Sort Library By offers List fields only in List. Share paper and the Columns sheets (view-owned presentation) remain (E5). |
| C1 | Fixed | `1600765` | An equal generation replaces nothing; local-PDF rows reassigned only when they changed. E2 not done. |
| C2 | Fixed | `c8ebcd2` | Word-index matching plus a bounded memo; 15.2–46.7 → 0.37 ms/paper uncached, ~0.002 ms repeated (`-O`, 500 papers, busy machine), identical output. |
| C6 | Fixed | `38b2bcb` | Draft text is observed apart from the rest of the workspace (`ChatWorkspace.Shape`), and the message box is its own view, so a keystroke re-renders only it. `activeBranchID` per keystroke (C5) remains. |
| C7 | Fixed | `38b2bcb` | Progress/operation writes only on change; `chatIsEmpty` reads no streaming text. |
| C8 | Fixed (part) | `38b2bcb` | A 96 MB `NSCache` of composed figure images (cleared on account change); figure parts computed once per row render. A first-render decode stays synchronous: decoding later would change a row's height after layout, which the transcript's scroll-stability work avoids (E6). |
| C9 | Fixed (part) | `38b2bcb` | The figure view decodes once, off the main actor, and derives the sent image from the same composite (test: identical to chat's). Send-time figure preparation in `startGeneration` is unchanged. |
| C3–C5, C10–C16 | Not done | — | Need E2's indexed state or E6's render cache, or touch files under parallel edit. |
| D7 | Partly | `1525782` | Removed `UploadProgress`, `putLibraryDescriptor`, `ReaderWebView.plainText`, `SelectionAction.equationActions`, `ignoresKeyboardFrame`, `macKeyboardShortcut`; fixed the misplaced doc comment. PaperView's old reference dialog and PDFUploadQueue leftovers remain (files under parallel edit). |
| D10 | Partly | `1525782` | The resource probe links SwiftMath; DevicePDFRoute's two warnings are gone (frozen crop list; progress called under the lock, in order). UI-test helper duplication and the timing benchmark remain. |

## Fix first (top 12)

| # | Finding | Why first |
|---|---|---|
| A1 | Any HTTP 401 signs the user out with no token refresh | Sign-out on clock skew or key rotation; introduced 10-16 |
| A2 | Selection quote and action dropped when the question fails to save | Silent loss of the passage and the requested action |
| A3 | "Try again" after a local save failure buys the answer again | Double charge, answer text discarded |
| A4 | Sign-out/session expiry leaves preparation, model-reading and profile state running | Stuck rows, leaked downloads, stale profiles |
| A5 | Paper added on the server is reported as a failed add | Wrong status; skips refresh |
| A6 | Non-arXiv adds ignore the catalog being viewed | Contradicts LIBRARY_CATALOGS.md and the sheet's own text |
| A7 | Opening a paper restarts its background download from zero | Doubles arXiv requests against device pacing |
| C1 | Every publish (each 60 s sync, each write) re-projects all history and re-renders the library | Main-thread cost that grows with the account |
| C2 | Keyword derivation (~6.5 ms/paper, measured) runs inside view bodies | ~0.65 s main-thread per table body at 100 papers |
| B1 | iPad hardware keyboard gets almost none of the Mac's commands | Largest idiom gap |
| B2 | Equation/figure/promoted chats use a second transcript that missed the jitter fix | Drift on every idiom |
| E1 | Split ReaderModel (5,444 lines; one class body 135–5000) | Root cause of A4, A12, A17, C1, C5 |

---

## A. Correctness bugs

### A1 — High — Any 401 ends the session without a refresh attempt
- **Where:** `ScienceReader/Services/BackendClient.swift:1108` (`raw()` maps every 401 to
  `AuthenticationError.sessionExpired`), `:859-861` (`authorized()` then calls `expireSession`), `:548` (chat stream:
  401 → `expireSession`), `:231-241` (`expireSession` deletes the stored session and fires the invalidation handler).
  Introduced in 1d5f7aa (2026-10-16).
- **Problem:** `accessToken()` (`:866-868`) trusts the locally stored absolute `expires_at`. Nothing retries with a
  forced refresh when the server says the token is not valid.
- **Scenario:** a device clock that runs a few minutes slow sends an already-expired JWT for the last minutes of every
  token lifetime; scheduled sync runs every 60 s, so it hits that window and the account is signed out
  (`clearAccountView`), although the refresh token was still valid. A Supabase JWT-secret rotation does the same to
  every device at once.
- **Side effect:** the `libraryCommandErrors` branch `if response.statusCode == 401 { throw BackendError.signInRequired }`
  (`:1123`) is now unreachable, so the queue's "Sign in again to send your saved library changes" message never shows.
- **Fix:** on 401 (not the 403 closed-account codes), refresh once with `accessToken(force: true)` and replay the
  request once; expire only when the refresh itself returns the session-ended codes already listed at `:1048-1052`.
  Store expiry as `min(expires_at, now + expires_in)` when both are present to tolerate skew. Delete the dead branch.
  ```swift
  } catch AuthenticationError.sessionExpired where !retried {
      _ = try await accessToken(force: true)     // throws .sessionExpired only for refresh_token_not_found etc.
      return try await authorized(..., retried: true)
  }
  ```

### A2 — High — The selection quote and action are lost when the question fails to save
- **Where:** `ScienceReader/ReaderModel.swift:3689` clears `pendingSelection` before the encrypted commit;
  the `catch` at `:3744-3748` calls `chatWorkspace.fail(submission)` but never restores it. Same pattern in
  `sendContextualMessage` (`:5440-5442`).
- **Scenario:** a selection action (Explain, Related, Ingest) auto-sends (`:3636-3647`). The save fails (capacity,
  activation, I/O). The prompt text stays in the composer (`beginSubmission` doesn't clear the draft), so the reader
  presses Send again — and the request goes without `selection`, without `action` (Ingest becomes a plain question) and
  without the passage anchor.
- **Fix:** `let consumed = pendingSelection` and clear only after `try await committing.value` succeeds; or in the
  `catch`, `if pendingSelection == nil { pendingSelection = consumed }`.

### A3 — High — "Try again" after a local storage failure re-requests (and re-charges) a complete answer
- **Where:** `ReaderModel.swift:4425-4438` (`sealAnswer` throws → issue `"storage"`, then `chatStreamingText`,
  `chatStreamBuffer` are cleared), `ScienceReader/Services/ChatGeneration.swift:188-190` (`"storage"` is retryable),
  `ReaderModel.swift:4145-4149` (`retryAnswer` → `requestAnswer`, a new metered cloud call).
- **Scenario:** the device's encrypted store hiccups after a complete paid answer. The text disappears and the banner
  offers "Try again", which buys the same answer a second time.
- **Fix:** keep the unsealed result (`unsavedAnswers[composer] = (generation, text, drawn, title)`) and keep showing it;
  for `"storage"`, Try again re-runs `sealAnswer` only. Reserve `requestAnswer` for transport/provider failures.

### A4 — Medium-High — Sign-out / session expiry leaves per-paper and per-account work running
- **Where:** `ReaderModel.swift:2090-2147` (`clearAccountView`) never cancels or clears `devicePreparationTasks`,
  `devicePreparations`, `devicePreparationIssues`, `readerUpdates`, `failedHTMLOpens`, `legacyBundleFallback`,
  `finishedImportSources`, `deviceModelTask`/`deviceModelRun`/`deviceModelHTMLBundles`/`deviceModelSummaries`,
  `chatProfileTable`/`pendingChatProfiles`, `chatStudyMaps`, `chatFollowUps`. Their cleanup `defer`s are guarded by
  `sessionID == scope` (`:2974`, `DeviceModelReading.swift:216`), so after the session changes they never run.
  `refreshChatProfiles` checks only `chatProfileFetch == fetch`, not the session.
- **Scenario:** the session expires (A1 makes this more likely) during an automatic download; the user signs back in.
  The old task keeps fetching from arXiv after sign-out; the row shows "Downloading… 42%" for the rest of the process;
  `prepareOnDevice` refuses that paper because its task entry still exists; with a model reading in flight,
  `deviceModelRun` is never cleared, so "Read with on-device model" stays unavailable and the screen stays awake.
- **Fix now:** cancel and clear all of the above in `clearAccountView` (call `cancelDeviceModelReading()`, reset
  `chatProfileFetch`), and add a session check to `refreshChatProfiles`. **Structural fix (E1/E7):** keep session-scoped
  fields in one `SessionState` value that is replaced wholesale, so a new field cannot be forgotten.

### A5 — Medium — A paper the server already added is reported as "Couldn't add it right now"
- **Where:** `ReaderModel.swift:3412-3435` (`referenceOutcome`), `:3544-3558` (`addPaperOutcome`).
- **Problem:** `writeCatalog` runs inside the same `do` as the add. It throws `.unavailable` while recovery is pending,
  during activation, or on a local write failure; the `catch` then returns `.unavailable` and skips
  `refreshLibrary()`, although the server returned `"added"`. Both paths also append an `assign` event even when the key
  already resolves to the destination (unlike `importPaper`, `:2443-2445`), adding an encrypted event and a sync per add.
- **Scenario:** a device in recovery or key activation adds a paper from chat; it sees a failure, retries, and is told
  "already in your library".
- **Fix:** derive the outcome from the server result; run a best-effort
  `assignToCatalogIfNeeded(key:destination:)` in its own `do/catch` (note on failure only); always refresh on "added".
  Share the helper with `importPaper`.

### A6 — Medium — Non-arXiv adds ignore the current catalog, and a pending import's catalog key changes when it resolves
- **Where:** `ReaderModel.swift:3418-3420`, `:3550-3552` (assignment written only when
  `LibraryCatalogBatch.arxivKey(source)` succeeds); `:338-343` (`catalogKey` falls back to `paper:<importID>` and later
  `paper:<documentID>`); `ScienceReaderCore/Sources/ScienceReaderCore/LibraryCatalog.swift:76-84`.
- **Scenario:** a DOI/OpenAlex paper added while viewing catalog "Thesis" lands in the default catalog, contradicting the
  sheet footer and `docs/architecture/LIBRARY_CATALOGS.md` ("a new import joins the catalog selected when Add was
  pressed"). A move made while an import is pending is lost when the key changes from the import ID to the document ID.
- **Fix:** add a stable `source:<sourceID>` key kind (native and `apps/web/src/lib/library-catalogs.ts`) for non-arXiv
  sources; use it in both `catalogKey` overloads and the add flows. Update `validPaperKey`.

### A7 — Medium — Opening a paper cancels its background preparation and restarts it
- **Where:** `ReaderModel.swift:3136-3138` (`devicePreparationTasks[paper.id]?.cancel()`), then a fresh
  `ArxivHTMLReader().prepare` at `:3167`.
- **Scenario:** the automatic download after an import is at 80%; the reader taps the paper; the download restarts from
  zero — twice the arXiv requests, against the device pacing policy (owner: devices only, paced).
- **Fix:** one `preparations: [UUID: Task<VerifiedReaderBundle, Error>]` that open, background and chat paths all join;
  opening adopts the running task and mirrors its progress into `openingProgress` (see E7).

### A8 — Medium — A question sent while the paper's reader is being prepared has no in-flight state
- **Where:** `ReaderModel.swift:4114-4123` (`requestAnswer` awaits `localReaderTask` without registering in
  `chatGenerations`).
- **Scenario:** `isAnswering` stays false and no "thinking" row appears, so the reader sends Q2. When preparation ends,
  Q1's waiter answers Q1 (whose child is now Q2, so a branch picker appears); Q2's waiter finds
  `chatGenerations[composer] != nil` and returns silently — no answer, no issue. If the chat's paper is not the selected
  paper, `localReaderTask` belongs to a different paper (or is nil), and the turn fails `local_reader_unavailable`.
- **Fix:** register a placeholder generation (or `pendingAnswers[composer]`) covered by `isAnswering`, show "Preparing
  the paper…", await the preparation keyed by *that* paper (E7), and on wake answer only the newest turn that is still the
  branch head; otherwise set an issue.

### A9 — Medium — Closing an equation/figure sheet records a paid Stop
- **Where:** `ReaderModel.swift:5416-5425` (`endContextualChat` → `stopAnswer()`), `:4152-4168` (`recordStop`:
  "charged for the part written"), `Views/EquationView.swift:247` and `Views/FigureExplainView.swift:137`
  (`onDisappear`).
- **Scenario:** swiping the sheet away mid-answer is billed as an explicit Stop; per the transport comment, other early
  ends cost nothing. **Uncertain whether intended** — check against CHAT.md.
- **Fix:** `stopAnswer(explicit: Bool)`; on dismissal either let the generation finish in the background (generations
  are already keyed by composer, as the main chat does on conversation switch) or cancel without `recordStop`.

### A10 — Medium (likely; confirm in Simulator) — Opening a figure full screen on iPhone/iPad cancels an explanation in flight
- **Where:** `Views/FigureExplainView.swift:127-137` (`.task(id: context.figureID)` stops the session and makes a new
  one), `:484-490` (`fullScreenCover` on iOS; Mac uses a sheet).
- **Problem:** the cover makes the explainer disappear and reappear. The `if expandedImage == nil` guard on
  `onDisappear` (`:137`) shows this was observed, but `.task` is still cancelled on disappear and re-run on appear, and
  the re-run calls `session?.stop()`.
- **Scenario:** tapping full screen while the walkthrough, "More simply" or "Extract" is arriving cancels it; nothing is
  kept; it may still be charged (A9). The UI test covers only a finished walkthrough.
- **Fix:** in the task, `guard session?.context.figureID != context.figureID else { return }`, or own the session in
  the model rather than in the view's appearance cycle.

### A11 — Medium — Cancelling an on-device model reading and starting again breaks the new run
- **Where:** `ScienceReader/DeviceModelReading.swift:262-266` (`cancelDeviceModelReading` clears `deviceModelRun` at
  once), `:209-216` (the old task's `defer` clears `deviceModelRun` when only the *paper ID* matches, and always
  re-enables the idle timer).
- **Scenario:** Cancel then Read again on the same paper: when the old task finishes cancelling, its `defer` clears the
  new run and task handle (progress and Cancel vanish), re-enables auto-lock mid-run on iOS (the GPU work then stops),
  and two model loads can overlap in memory.
- **Fix:** `DeviceModelRun.id = UUID()`; clear and restore the idle timer only when `deviceModelRun?.id == myID`.

### A12 — Medium — Archiving an arXiv (source-membership) paper doesn't hide or recount the row until the server confirms
- **Where:** `ReaderModel.swift:1194-1197` (`libraryFilterSummary`) and `:1228-1231` (search candidates) only read
  `.setArchived`; `isArchived` (`:315-321`) handles both `.setArchived` and `.setSourceDetails`. `setArchived` routes
  source papers through `.setSourceDetails` (`:2475`, `:2566`).
- **Scenario:** the row says Archived but stays in All with wrong chip counts; offline or behind a queued command, that
  lasts indefinitely. The comment at `:1227` promises "a swipe hides the row at once".
- **Fix:** one `pendingArchiveOverrides() -> [UUID: Bool]` covering both mutations, used by all three call sites.

### A13 — Low-Medium — Archiving freezes auto-derived keywords as the reader's own tags; old AI/ML own tags are silently dropped
- **Where:** `ReaderModel.swift:2796` (since 10228c5, `ownTags: LibraryTags.tags(for: item)`, which returns *derived*
  keywords when tags aren't customized), `:2475` (archive sends `tags: paper.ownTags`),
  `Services/LibraryMetadata.swift:92-94`; `Views/TagEditorView.swift:20`.
- **Scenario:** one archive tap sets `tagsCustomized` server-side with the derived list, so later keyword-derivation
  improvements never apply to that paper. Separately, own tags such as "AI" saved before c4d15d9 are filtered out of the
  editor's starting list, and the next unrelated tag save deletes them without notice (possibly intended — confirm).
- **Fix:** keep `ownTags = item.userTags ?? []`; make the `setSourceDetails` tags optional (nil = unchanged) and have
  archive send nil. Keep filtered own tags in the editor's saved set unless the reader removes them.

### A14 — Medium (Mac only) — Retired local-model choices leave chats pointing at a model that cannot exist
- **Where:** `ReaderModel.swift:655-657` and `:695-699` (`ai.localDefault` / `ai.scenarioLocals` read without
  validation), `Views/AIScenarioDefaults.swift:22-28`, `Views/AIChoiceView.swift:95-100`,
  `Services/LocalAIController.swift:88-99`; `LocalAI/Sources/LocalAI/Resources/models.json` is `[]` since 2dcfd16.
- **Scenario:** a Mac that chose Qwen in builds 69–71 starts every chat and explainer with the retired ID;
  `currentAIName` shows "Qwen3.5 4B (local)"; sending fails with `local_model_missing` ("Download a model…") but nothing
  can be downloaded; the scenario picker has no matching tag. Also, the initial `localAIModelID` comes from the global
  key and ignores `localDefault(for: .general)`, and `askAboutEquation`/`askAboutFigure` don't carry the explicit engine
  choice the way `selectionAction` does (`:3892-3908`, `:4042-4055` vs `:3624-3631`).
- **Fix:** after `localAI.refresh()`, drop IDs not in `localAI.models` from both keys; make `localDefault(for:)` return
  nil for unknown IDs; initialise `localAIModelID` in `start()` from `localDefault(for: currentAIUseCase)`.

### A15 — Low-Medium (latent) — A link shared to the app is deleted from the inbox before it is shown
- **Where:** `Services/SharedItemsImport.swift:37-41` (removes the item, keeps the link only in memory, sets
  `showImport`); `Views/RootView.swift:345` (the `ImportPaperView` sheet hangs off `LibraryView`, not the root);
  `Views/AddPaperView.swift:94-99`.
- **Scenario:** the app resumes on Feed/Paper/Chat (iPhone) or Reader/Feed/Chat (iPad/Mac): nothing appears; if the app
  is then killed, the shared link is gone. Visiting Library hours later pops the sheet and starts an import at once. The
  Mac menu's Add Paper works around it by switching to Library first (`Mac/MacCommands.swift:198-200`).
  **Latent:** the share extension is not embedded until the App Group exists (`project.yml:87-89`), so `ShareInbox.shared()`
  returns nil in shipped builds today.
- **Fix:** move `.sheet(isPresented: $model.showImport)` to `RootView`; remove the inbox item only after the sheet's
  `.task` consumes the link.

### A16 — Low — The model carried into a new paper chat is compared against the wrong default
- **Where:** `ReaderModel.swift:3632`, `:3898`, `:4049` (`if carried != chatDefaultProfile { setChatProfile(carried) }`);
  the new chat's actual default is `profileDefault(for: .paper)` (`:690-692`).
- **Scenario:** paper default X, global default Y; the reader explicitly picks Y — not carried, the new chat silently
  uses X. From a general chat whose scenario default Z differs, Z is pinned and labelled "Selected for this conversation".
- **Fix:** carry only an explicit choice (`pendingChatProfiles[composer]`) and compare against
  `profileDefault(for: .paper)`; share this logic (D2).

### A17 — Low — The quote of a signed-out selection action is lost across sign-in
- **Where:** `ReaderModel.swift:3636-3638` (sets `pendingSelection`, opens sign-in); sign-in runs `clearAccountView`,
  which replaces `chatWorkspace` (new composer IDs), so `pendingSelection.composerID` never matches again, while the
  guest draft text is carried over.
- **Fix:** carry `pendingSelection` with the guest draft in `beginAuthenticationContext`, re-keyed to the new composer.

### A18 — Low — Model-reading installs bypass the account write fence
- **Where:** `DeviceModelReading.swift:241-242` (`modelStore.remove`/`install` called directly, errors `try?`-swallowed).
- **Scenario:** deleting the account while a model reading installs can recreate files in the folder just erased;
  `ReaderRetirementQueue` and `deleteAccount` (`ReaderModel.swift:2068-2075`) don't wait for these writes.
- **Fix:** `ReaderLocalPersistence.acceptModelReaderWrite { … }` and route both writes through it.

### A19 — Low — Reader version › Update deletes the old offline copy before installing the new one
- **Where:** `ReaderModel.swift:2898-2902`.
- **Scenario:** install fails (`tooLarge`, write failure): the offline copy is gone while the UI still shows the old
  bundle from memory and says "couldn't be stored".
- **Fix:** check the encoded size first, or add a store-level `replace(old:with:)` that writes the new blob before
  swapping the manifest.

### A20 — Low — Two quick creates with the same catalog name both succeed
- **Where:** `ReaderModel.swift:384-388` (`catalogName()` validated at call time), `:402-413` (`writeCatalog` serialises
  on `catalogWriteTail` later).
- **Fix:** validate the name inside the serialized write against the state after the previous write.

### A21 — Low — Smaller chat-state slips
- `ReaderModel.swift:5375`: `promotedChatContexts.keys.first!` evicts an arbitrary Dictionary entry, possibly the chat
  in use. Use insertion-ordered storage.
- `ReaderModel.swift:4152-4168` with the consume loop at `:4283-4291`: a cloud Stop waits up to 3 s before cancelling,
  and deltas that arrive in that window are still appended, sealed and charged as part of the interrupted answer. Stop
  appending once `stopping` is set.
- `Views/FigureExplainView.swift:359`: "Ask about this part" replaces any unsent draft (`model.chatInput = …`), and if
  the token isn't owned, writes into whichever composer is current. Guard `ownsContextualChat` and prepend.
- `Services/ChatHistory.swift:32` vs `:187-194`: the All chats column is "Last read" but VoiceOver says "last used".

### A22 — Low — PaperView state that is never reset, and a view body that mutates the model
- `Views/PaperView.swift:175`, `:761`: `crashReloads` is never reset (not on paper change, not on Try again, not on
  load). iPad/Mac keep `PaperView` alive across papers, so after one silent reload every later web-content crash on any
  paper goes straight to "Couldn't open". Reset it in the `readerDocumentScope` `onChange` and in `onReady`.
- `Views/PaperView.swift:271` calls `model.passageJump(for:)` while building the body; it can call `finishPassage`
  (`Views/PaperPassages.swift:142`, `:164-176`), which writes `passageRequest` and `referenceNotice` that the same body
  reads, and checks a 60-second cutoff against `Date()` during rendering. Resolve the request in `goToCitedBlock` or an
  `onChange(of: model.passageRequest?.id)` and make `passageJump` side-effect free.

### A23 — Low (mostly Mac) — The figure explainer checks for a saved answer under the wrong model
- **Where:** `Views/FigureExplainView.swift:62-66` and `Services/FigureViewSession.swift:85-88` build the key from
  `model.equationProfile`/`localAIModelID` *before* `beginContextualChat` switches `localAIModelID` to the figures
  default (`ReaderModel.swift:5388`); `equationProfile` also changes between `chatDefaultProfile` and `chatProfile`
  (`:3811-3814`).
- **Scenario:** with a local figures default on the Mac, the button opens the model chooser though an explanation is
  saved, or opens with `requesting: false` and shows nothing.
- **Fix:** `ReaderModel.explainerKey(for:scenario:)` applying the same `pendingLocalAIChoice ?? localDefault(...)` rule,
  used in both places.

### A24 — Low (likely) — Double-tapping an underlined (chatted) passage fires two actions
- **Where:** `ScienceReader/Resources/reader-bridge.js:1903-1928` (double-tap → `contentsGesture`) and `:1949-1956`
  (click on a mark → `marks`). Marks are CSS highlights, so the gesture's exclusion selector cannot skip them.
- **Fix:** in the gesture's `pointerup`, ignore taps where `marksAt(x, y).length > 0` (move `marksAt` above it).
  Shared with the web app, so fix once.

### A25 — Low-Medium (uncertain) — Dictation fights the podcast player's audio session
- **Where:** `Services/ChatDictation.swift:46-49` (switches the shared session to `.record` while a podcast may be
  playing; the mini-player is visible in Chat), `:84-91` (restores only category/mode/options, `try?` on
  `setActive(false)`); `Services/PodcastPlayer.swift:96` uses `policy: .longFormAudio`.
- **Scenario:** changing the app's own category posts no interruption, so `PodcastPlayer.isPlaying` stays true while
  silent; on stop, deactivation likely fails busy (swallowed) and the restore drops `.longFormAudio`.
- **Fix:** pause the podcast before dictation and resume after; save/restore the route-sharing policy too.

### A26 — Low — QR scanner start/stop can run out of order
- **Where:** `Views/DeviceApprovalViews.swift:339`, `:350`, `:359` dispatch `startRunning`/`stopRunning` to the global
  *concurrent* queue.
- **Scenario:** a quick dismiss can execute `stopRunning` before `startRunning`, leaving the camera running (indicator
  on) after the sheet closes.
- **Fix:** a private serial `DispatchQueue` for all session calls (Apple's documented pattern).

---

## B. Parity gaps (iPhone / iPad / Mac)

### B1 — Medium — iPad with a hardware keyboard gets almost none of the Mac's commands
- **Where:** `ScienceReader/ScienceReaderApp.swift:29-31` (`.commands { GradstepCommands }` only under
  `macCatalyst`); `ScienceReader/Mac/MacSupport.swift:98-104` (`macKeyboardShortcut` is a no-op off Mac), used for
  ⌘Return send (`Views/RootView.swift:1074`) and Esc on the fullscreen figure (`Views/FigureExplainView.swift:509`).
- **iPad has:** ⌘F (find in paper, `Views/PaperView.swift:649-653`), table ↑/↓, J/K, ⇧⌘R (enter reading mode only).
- **iPad lacks:** ⌘1–5 views, ⌘N/⇧⌘N, library search, ⌘[ Back, ⌥⌘↑/↓ sections, ⌘+/− text size, ⌥⌘1–4 selection
  actions, ⌘Return send, ⌘G/⇧⌘G find next/previous, Esc for the fullscreen figure and the find bar. The reading bar
  still advertises "Ask in chat (⌃⌘H)" on iPad hover (`ScienceReader/ReadingMode.swift:299`).
- **Fix:** compile `GradstepCommands` for iOS too (iPadOS shows them in the ⌘-hold overlay and the iPadOS 26 menu
  bar); keep only `.appSettings` and Help Mac-only. Replace `macKeyboardShortcut` with `keyboardShortcut` for send and
  Esc. Use `focusedSceneValue` for the paper menu on all platforms.

### B2 — Medium — Equation, figure and promoted chats use a second, drifted transcript
- **Where:** `Views/EquationView.swift:612-689` (`ContextualConversationScroll`, `ContextualChatThread`), used inside the
  sheets and by the main Chat tab for promoted chats (`Views/ChatTranscript.swift:23-34`) on all idioms.
- **Missing vs `TranscriptMessage`:** the 365aeaa jitter fix (it still scrolls to the bottom on every height change,
  twice: `:627`, `:633`); Sources (`ChatSourcesView` is only re-added by `TranscriptMessage`); "Papers in this answer";
  follow-ups; per-message interruption notes; inline figure-part crops; quote actions (no `onQuote`); the Latest button.
  Diagrams are keyed by `message.id` (`:679`) rather than `payload.entityID`.
- **Fix:** extract `ChatMessageRow(message:context:)` from `TranscriptMessage` and use it in both; host the table-based
  transcript (or share its scroll policy) in the sheets. Key diagrams by `entityID` everywhere.

### B3 — Medium — The equation/figure composer is a separate implementation
- **Where:** `ContextualChatComposer` (`Views/EquationView.swift:691-748`, also used by `FigureExplainView`) vs the
  main composer (`Views/RootView.swift:1029-1100`).
- **Drift:** no ⌘Return on Mac; no Mac end-editing-before-send handling (`RootView.swift:1079-1093`), so the sent text
  may be written back on Mac (uncertain); a text-button model picker instead of `AISelectionButton`; no Answer options;
  different error UI.
- **Fix:** one `ChatComposerField(text:canSend:onSend:onStop:accessory:)` in its own file, used by both.

### B4 — Medium — "Find papers by <author>" does nothing visible on iPad and Mac; `tab` and `wideMode` disagree
- **Where:** `Views/PaperView.swift:480-484` sets `model.tab = .library` but not `wideMode`; the wide layout picks its
  pane from `wideMode` (`Views/RootView.swift:229`). Compare `findSimilarPapers` (`ReaderModel.swift:2296-2300`) and
  `showLibrary()` (`:3014-3017`), which set both.
- **Scenario:** in iPad/Mac Reader mode, tapping an author → Find papers runs discovery off-screen; the Mac toolbar stays
  on Reader. The same two-source-of-truth problem makes `ChatView` show a redundant "Return to paper" beside the visible
  paper after Ask about this paper (`tab == .chat` makes `besidePaper` false, `RootView.swift:1137`).
- **Fix now:** `model.searchAuthor(name)` that calls `showLibrary()`; an environment value set by `ReaderSplit` for
  "beside the paper". **Later:** E3.

### B5 — Low-Medium — The Mac menu bar no longer mirrors the on-screen "…" menus
- **Where:** comment at `Mac/MacCommands.swift:38-39`, `:167` claims parity. Missing from the Paper menu: Share paper,
  Find similar papers, Reader version details (`Views/PaperView.swift:457-475`). Missing elsewhere: Catalogs/switch
  catalog and Columns (`RootView.swift:427-479`); Feed Sort/Columns/Hide papers in your library (`RootView.swift:865-882`).
  "Sort Library By" offers table-only fields in List layout (`MacCommands.swift:111-114` vs filtered
  `RootView.swift:506-509`).
- **Fix:** E5 (one action model rendered as `Menu`, context menu and `Commands`).

### B6 — Low-Medium — The same import action is enabled under three different rules
- **Where:** List row `Views/RootView.swift:555-559` (enabled for `.sourceOnly` + `hasLocalPaperStore` even when
  `!canChangeImports`); table `Views/LibraryTableView.swift:160`, `:174`, `:311`, `:392` (`canChangeImports` only);
  context menu `:493-497` (`hasLocalPaperStore || uploads.isActive`).
- **Scenario:** a source-only arXiv import's Download/Open PDF is disabled in the default Table layout but enabled in
  List (which accessibility text sizes force).
- **Fix:** `LibraryImportAction.isEnabled(_:for:model:)` used by all three.

### B7 — Low — "Is the wide layout showing?" is computed three different ways
- **Where:** width ≥ 850 or Mac, copied in `Views/RootView.swift:13`, `Views/DeviceApprovalViews.swift:219`,
  `Views/PodcastPlayerViews.swift:563`; device idiom (`Platform.isLargeScreen`) in `Views/LibraryTableView.swift:133`,
  `:187`, `Views/RootView.swift:402`, `:1137`; and `wideMode`.
- **Scenario:** iPad in narrow Split View uses the compact tab layout but the wide column set, and highlights a "selected"
  row whenever `wideMode` is stale at `.browse`.
- **Fix:** `RootView` publishes `\.layoutMode` (`.compact` / `.wide(width)`); Browse sets `\.besidePaper`; delete the
  copies.

### B8 — Low — Smaller idiom gaps
- Feed List and ML-search rows have no long-press menu (`Views/RootView.swift:1708-1760`); the Feed table has Add to
  library / View on arXiv (`Views/FeedTableView.swift:216`, `:275-282`). The Feed defaults to List. Share a
  `FeedRowActions` context menu.
- iPadOS 17 and macOS 14 don't get the Contents full-height fix: `presentationSizing(.page)` is iOS 18+ only
  (`Views/PaperContentsSheet.swift:195-204`; same gate in `Views/ChatHistoryView.swift:603`); the deployment target is
  iOS 17 (`project.yml:4`). Add a `.presentationDetents([.large])` + `frame(minHeight:)` fallback or raise the floor.
- The equation view opened via "Back to explainer"/Your assets lacks `.macSheetKeys()` (`Views/PaperView.swift:506-509`)
  while the direct route has it (`:572-574`), so ⌘W may skip SwiftUI dismissal and leave `presentedExplainer` set.
- Mac Find in Paper uses the static `ReaderWebView.paper` (`Mac/MacCommands.swift:65-67`, `Mac/MacSupport.swift:212`)
  and skips `PaperView.showFind()`'s `canFind` guard and selection clearing (`Views/PaperView.swift:641-653`). Route
  find/next/previous through `PaperMenuActions` and drop the static.
- Catalogs: Move to catalog exists only for `.paper` rows (`Views/LibraryTableView.swift:460-471`); no Mac menu command;
  the switcher's visibility depends on the literal `"Default"` (`Views/RootView.swift:427`).

### B9 — Low (uncertain) — Idiom behaviour to verify on a device
- iPad reading mode may exit when a fullscreen figure opens: `wideLayout.onDisappear { exitReadingMode() }`
  (`Views/RootView.swift:248`) vs the iOS `fullScreenCover` (`Views/FigureExplainView.swift:488`). Drive the exit from a
  layout change (`onChange(of: isWide)`), not `onDisappear`.
- Bare ↑/↓/Return table shortcuts (`Views/PaperTable.swift:372-383`) may take arrow scrolling and Return from the paper's
  web view in Browse. Scope them to table focus (`.focusable()` + `.onKeyPress`).
- Mac Catalyst reports the scene inactive whenever another app is frontmost, so every ⌘-Tab back likely runs
  `synchronize()`, `refreshLibrary()` and `syncStoreTransactions()` plus `flushDrafts` (`Views/RootView.swift:121-133`).
  Throttle activation sync (e.g. once per 60 s or only after real backgrounding). Check with `SessionTimeline`.

---

## C. Performance

### C1 — High — Every publish re-runs whole-history projections on the main actor and re-renders the library
- **Where:** `ReaderModel.swift:4947-4953` (`publish` accepts `snapshot.generation >= publishedGeneration`, so an
  unchanged snapshot is republished after every 60 s scheduled sync and every write); `:790-811` (`privateState.didSet`
  rebuilds `LibraryCatalogState` — filter all events, JSON-decode every catalog batch; a tombstone pass;
  `diagramsByMessage()`, O(diagrams × events) via `entities`/`isDeleted`/`revisions` plus a JSON decode per diagram,
  `ScienceReaderCore/.../ChatDiagram.swift:63-80`; `conversationCounts`; `conversationSummaries`); `:3519-3531`
  (`presentLocalPDFMemberships` calls O(N) `isDeleted`/`revisions` per local PDF and **always** assigns `papers`, which
  fires `libraryPapersChanged` → row lookup rebuild, `libraryRows` reassignment, `warmTextIndex()`).
- **Cost:** every view that reads `papers` or `privateState` is invalidated at least once a minute even when nothing
  changed; the diagram pass is quadratic in history size.
- **Fix now:** use `>` for state replacement (on equality update only `publishedPendingCount`); assign `papers` only
  when the local-PDF rows differ. **Then E2:** indexes in `PrivateState` and one projection computed in the store actor.

### C2 — High — Keyword derivation runs inside view bodies (~6.5 ms per paper, measured)
- **Where:** `ScienceReaderCore/.../PaperKeywords.swift:8-19` via `LibraryTags.tags(for:)`
  (`Services/LibraryMetadata.swift:85-94`), called from `LibraryPaperTable.body` through `libraryFacts`
  (`Views/LibraryTableView.swift:145`, `ReaderModel.swift:1322`), `LibraryFilterBar.body` through
  `libraryFilterSummary()` (twice per paper; `Views/LibraryTableView.swift:559`, `ReaderModel.swift:1199`),
  `PaperView.body` (`Views/PaperView.swift:250`), `TagEditorView` every body (`Views/TagEditorView.swift:23`) and
  `prepareLibrarySearchSource` (`ReaderModel.swift:1237`).
- **Measured:** 500 papers in 3.24 s with `-O` on this Mac; ~5.2 ms of each 6.5 ms is the 194 `String.contains` calls
  (97 vocabulary terms × title and abstract). Normalising text costs 0.09 ms.
- **Cost:** a 100-paper library pays ~650 ms of main-thread work per table-body evaluation, and about that again for the
  filter bar.
- **Fix:** precompute normalised vocabulary as `static let`; match against a token set or UTF-8 bytes; derive once when
  `Paper`/rows are built (memoise by id + content hash, invalidated on `papers` publish); compute
  `libraryFilterSummary` and row facts when inputs change, not in `body`.

### C3 — Medium — The library table recomputes every row's facts on unrelated changes
- **Where:** `Views/LibraryTableView.swift:144-146` (`items = model.libraryRows.map { … libraryFacts … }`);
  `LibraryPaperTable` stores a `top` view of closures, so it compares as changed on every `LibraryView.body` (which reads
  the search query — every keystroke, `Views/RootView.swift:314-318`); it also reads `readingActivity` (every whole
  percent of reading progress), `devicePreparations` and `openingProgress`. `libraryFacts` (`ReaderModel.swift:1316-1346`)
  calls `libraryStatus`/`deviceCopy` → `offlineStatus` (linear over `localReaderRecords`, `:2858-2872`);
  `librarySourceIDs` builds a Set of the whole library per call (`:2427-2429`), called per row
  (`Views/FeedTableView.swift:245`, `:276`; `Views/RootView.swift:1744`; per mention in
  `Views/ChatRichTextView.swift:638-656`, `:739-741`).
- **Scenario:** iPad/Mac Browse (library beside the paper): scrolling the paper recomputes facts for every row per
  percent; with C2, visible hitches.
- **Fix:** pass `top` separately (or move the banners out of `PaperTable`); per-row `LibraryTableRow(entryID:)` views
  that read their own facts, or a model-cached `[id: LibraryRowFacts]`; maintain `librarySourceIDs`, an installed
  `(sourceID, revision)` set and `papersBySourceID` in the `didSet`s; throttle progress writes (≥1% or ≥100 ms).

### C4 — Medium — Catalog keys compile regexes per paper; catalog counts are quadratic
- **Where:** `ScienceReaderCore/.../ArxivReference.swift:69-73` compiles an `NSRegularExpression` per call (≈4–5 per
  parse); `catalogKey` → `arxivKey` → `ArxivReference` runs per paper in `libraryFilterSummary` and candidate building
  (`ReaderModel.swift:1199-1262`) and per `.assign` validation on every rebuild (`LibraryCatalog.swift:93-169`);
  `catalogCount` (`ReaderModel.swift:345-351`) rebuilds every key per catalog row, and the deletion sheet calls it up to
  three more times (`Views/LibraryCatalogsView.swift:33-34`, `:110`, `:124`, `:135`, `:155`, `:165`).
- **Cost:** the ~11 ms main-actor preparation for 4,000 rows recorded in `NATIVE_LIBRARY_SEARCH.md` predates this and
  is stale.
- **Fix:** `static let` regexes; store a precomputed `catalogKey` on `Paper`/`LibraryImportRecord`; cache decoded
  batches by event ID; compute all catalog counts in one pass.

### C5 — Medium — Chat projections rescan the whole account history many times per body
- **Where:** `ScienceReaderCore/.../PrivateState.swift:201-251` (`isDeleted` is a linear scan;
  `conversationBranches` filters all events several times); `ReaderModel.swift:1514-1547` (`chatBranches` and
  `activeBranchID` call each other; `chatMessages`, `visibleGeneration`, `chatFollowUpQuestions`,
  `chatHasRemovedMessages`, `chatContextComplete` each recompute); `Services/ConversationBranchSelections.swift:29-49`
  (`reconcile` is O(conversations visited × E), run in `privateState.didSet`).
- **Cost:** one `ChatTranscript.body` makes roughly 20–35 full passes over all events; it runs per token (C7), per
  keystroke (C6) and per sync (C1).
- **Fix:** E2 (indexes) plus a memoised `ChatProjection` (branches, active head, messages, complete) keyed by state
  generation, conversation and branch selection.

### C6 — Medium — Every composer keystroke invalidates the whole chat UI
- **Where:** `ReaderModel.swift:600-613` (`chatInput` setter mutates the single observed `chatWorkspace` struct and calls
  `recordCurrentDraftBranch` → `activeBranchID`, O(E)); `Views/ChatTranscript.swift:20-21`; `Views/RootView.swift:1094-1097`
  (`sendDisabled` reads `chatInput` in `ChatView.body`), `:962-966`, `:1115`, `:1154-1166` (title menu runs
  `conversations(about:)` filter+sort; `visibleTitle` binary search makes ~7 `NSString.size` measurements). In an empty
  paper chat, `ChatStarters.paper(index)` compiles an `NSRegularExpression` and scans every block per render.
- **Fix:** extract `ChatComposer(model:)` so only it reads `chatInput`; keep draft text in an `@ObservationIgnored`
  store with a separately observed `composerText`; memoise starters per manifest; `static let` regexes.

### C7 — Medium — Streaming re-renders per token despite the 50–400 ms flush throttle
- **Where:** `ReaderModel.swift:4290` (`chatStreamProgress[generation.id] = nil` on every non-whitespace delta —
  `@Observable` reports every write, including nil→nil), `:4311` (same for `operationID`); `Views/RootView.swift:1019`
  (`chatTranscriptMessages.isEmpty` builds the full message array including streaming text just to test emptiness, so the
  composer band re-evaluates on every flush).
- **Fix:** `if chatStreamProgress[id] != nil { chatStreamProgress[id] = nil }`; same guard for `operationID`;
  `var chatIsEmpty: Bool { chatMessages.isEmpty && visibleGeneration == nil }` that doesn't read the stream.

### C8 — Medium — Figure images in chat answers are decoded and composited, uncached, inside view bodies
- **Where:** `ReaderModel.swift:3045-3050` (`figureImage` decodes every full-resolution panel and composites up to
  40 MP on the main thread); `Views/ChatTranscript.swift:183`, `:222`, `:226-229`, `:289-294` (`inlineParts` is a
  computed property evaluated twice per body, each calling `model.diagram(id)` — O(E) `revisions` + JSON decode — and
  `figureImage`); `Views/FigurePartsView.swift:22`.
- **Cost:** every sync or library change re-decodes every visible figure-parts answer.
- **Fix:** `let inline = inlineParts` once per body; an `NSCache` (with `totalCostLimit`) keyed by manifest + paths;
  pass decoded diagrams into the row from the coordinator.

### C9 — Medium — Figure preparation decodes twice at full size on the main actor, at open and at Send
- **Where:** `Services/FigureViewSession.swift:150-168` (decode + composite for `image`, then
  `ChatFigureFinder.image(for:)` decodes, composites — up to a 40 MP `CGContext` — and JPEG-encodes again,
  `Services/ChatFigureFinder.swift:60-71`); `ReaderModel.swift:4198-4222` → `ChatFigureFinder.swift:45-129` (Send with
  "Figure N" decodes up to 2 figures × 4 panels, downsizes, JPEG- and base64-encodes, and builds up to 2 MB of
  `LocalPaperChatContext`, all synchronously).
- **Cost:** a main-thread stall on every figure open and on Send; ~160 MB transient on iPhone for a 40 MP composite.
- **Fix:** one detached task that decodes once, sets `image = composite` (downsampled to screen size) and derives the
  sent JPEG from that composite; make Send's preparation `nonisolated static … async` inside the generation task after
  registering the generation (show `.lookingAtFigure`).

### C10 — Medium — Explainers rebuild paper context and decrypt saved answers on the main thread
- **Where:** `ReaderModel.swift:3796-3807`, `:3915-3939` (`equationContext`/`figureContext` decode the whole entrypoint
  HTML — up to 8 MB — and rebuild `LocalPaperChatContext`, on every open, heading switch, gallery previous/next and inside
  a sheet body at `Views/PaperView.swift:509`); `:3824-3851`, `:3942-3974` (`equationAnswer`/`figureAnswer` read and
  AES-open synchronously; the first miss runs `keptFileName`, which decrypts up to 400 kept answers per store; `keep*`
  writes and prunes with a directory listing on the main actor).
- **Fix:** cache the decoded HTML and `LocalPaperChatContext` per `manifestSHA256` (cleared with the bundle); make
  `EquationResultStore` an actor or call it from detached tasks; build the kept index off-main once (reuse
  `refreshKeptExplanations`, already detached).

### C11 — Medium — Each figure view loads the entire paper in a web view
- **Where:** `Views/PaperView.swift:1343-1356` (`FigureWebView` is a full `PaperWebView`: up to 8 MB HTML, the 130 KB
  bridge and the index JSON, then hides everything but the figure); `Views/FigureGallery.swift:184` (`.id(current)`
  tears it down on every previous/next).
- **Fix:** keep one web view and switch with a bridge call (`__scienceReaderShowFigure(id)`), or render only the figure
  markup as `EquationWebView` does.

### C12 — Medium — Finished answers are re-parsed, with regex compilation, on every render
- **Where:** `Views/ChatTranscript.swift:182`, `:205`; `Views/ChatRichTextView.swift:41-52`, `:332`;
  `ScienceReaderCore/.../ChatRichText.swift:223-229`, `:356-366`, `:400` (`trailingSources` runs 4× per row, each
  compiling an `NSRegularExpression`; `inertLinks` and `withCitations` compile per paragraph; the spoken label re-parses
  the whole answer as Markdown). GFM tables build every cell three times through `ViewThatFits`
  (`Views/ChatRichTextView.swift:457-460`, `:508-511`).
- **Fix:** hoist patterns to `static let`; build a `RenderedMessage` (blocks, sources, mentions, spoken label) once per
  (message ID, text, streaming) and cache it; skip the spoken label while streaming; precompute table cell texts once.

### C13 — Low-Medium — Text-index warming rebuilds the search source once per installed paper
- **Where:** `ReaderModel.swift:161-185` (`store.read` decrypts the whole package, images included, off-main, to extract
  text; then `librarySearchSourceChanged()` per insert on the main actor), `:1141` (re-triggered on every `papers`
  assignment — every publish, C1).
- **Cost:** up to ~128 full-bundle decrypts at launch plus 128 main-actor rebuilds of Σterms.
- **Fix:** `DeviceReaderStore.readIndex(identity)` that opens only the index member (or a sealed term sidecar); coalesce
  `librarySearchSourceChanged()` once after the loop or every N inserts.

### C14 — Low-Medium — Other main-actor I/O and long serial work
- `Services/PodcastCenter.swift:653`, `:658`: a tens-of-MB episode is SHA-256-verified and written on the main actor
  (the cached path already detaches at `:633`). One detached verify+write+exclude task.
- `ReaderModel.swift:453-492`, `Views/LibraryCatalogsView.swift:143-159`: deleting a catalog's papers runs enqueue →
  `waitUntilIdle` → POST → full refresh per paper, ~100 sequential round trips for 100 papers, while the sheet blocks
  dismissal. Enqueue all, wait once, offer Stop.
- `Services/BackendClient.swift:1153-1174`, `:774-781`, `:563-581`: responses and the SSE stream are read byte by byte
  with `Data.append(byte)` on the actor (the SSE task inherits isolation). Impact uncertain; use `nonisolated` 64 KB
  chunked readers and download-to-file for audio.
- `Services/DeviceKeys.swift:338-349`: sync pushes one request per pending event (catalogs add one per add/move); hex
  decoding of pulled ciphertext runs on the `@MainActor` `CloudSync` (`:371-378`).

### C15 — Low — Unbounded or account-crossing caches
- `ReaderModel.swift:276`, `DeviceModelReading.swift:271`: `deviceModelHTMLBundles` keeps whole bundles (images
  included) for every paper the model read, never cleared on paper switch or sign-out — contrary to
  `releaseUnselectedReaderBundles` (`ReaderModel.swift:2845`). Keep an identity and reopen from the store.
- `Views/DiagramView.swift:297-357`: static `[String: UIImage]` preview cache (up to 2400 px wide), no limit, survives
  sign-out (keeps the previous account's private diagrams in memory); no in-flight dedupe; `failed` is permanent for the
  session. Use `NSCache` with a cost limit, an in-flight task map, clear both in `clearAccountView`, expire failures.
  `ChatMathCache` (`Views/ChatRichTextView.swift:548`) has a count limit but no cost limit.
- `Services/DeviceSearch.swift:44-66`: one cache file per query in Caches, never pruned after the 24 h lifetime.

### C16 — Low — Smaller per-render costs
- `Views/PaperTable.swift:307`, `:351`, `:389`: table-level `hovered` `@State` re-runs the whole table body for every
  row the pointer crosses on iPad/Mac. Per-row hover (as `MacRowHover` already does).
- `Views/PaperView.swift:1374`, `:1396`, `:1468`: the local-PDF Contents builds a new `PDFDocument(data:)` per body
  and parses it again elsewhere. Compute the outline once in a `.task`.
- `Views/FigureExplainView.swift:205-216`, `:283`, `:322`; `Views/PaperContentsSheet.swift:32-34`;
  `Views/FigureGallery.swift:63`: figure/table lists (regex per caption + sort) and crops are recomputed per render,
  including per streamed token; new `CGImage`s defeat `FigureZoomScroll.setImage`'s identity check (`:431-436`).
- `ScienceReader/Resources/reader-bridge.js:2024-2031`, `Views/PaperFind.swift:31-49`: each find step rebuilds up to
  1,000 snippets and JSON-decodes them on the main thread. Return `{count, index}` for steps; snippets only on query change.
- `ScienceReaderCore/.../ReaderBundle.swift:145-152`: `resource(for:)` builds a URL string per member until a match
  (≤512 × ≤512 per page load). Precompute `[path: Member]` at verification.
- Progress callbacks spawn one main-actor `Task` per tick with no ordering guarantee (`ReaderModel.swift:2976`,
  `:3152`; `DeviceModelReading.swift:227`; `Services/LocalAIController.swift:71`). Use an
  `AsyncStream(bufferingPolicy: .bufferingNewest(1))`.

---

## D. Structure, duplication and debt worth fixing now

### D1 — Medium — Fixture and launch-argument code inside ReaderModel
- `ReaderModel.swift:1549-1633` (`start()` is mostly fixture branches), `:4835-4945`, `:4999-5168` (fixture
  configuration and resets). Compile-gated correctly (`DEBUG && FIXTURE_HOST`), but it is ~350 lines of the god file and
  every new preference must be added to the reset by hand (`:5004-5037` already misses `showAbstracts`, `showTopics`,
  `appearance`, `paperLineWidth`, `visualAnswers`, `showsPassageMarks`, the font sizes and `deviceModelReader`).
- Unguarded or DEBUG-only (not `FIXTURE_HOST`) hooks: `--reader-fixture` (`:1633`, no guard; it only opens the sample);
  `--operator-fixture` (`:4757`) and `--chat-idle-deadline` (`:3761`) are `#if DEBUG` only, so they work in Debug builds
  on a device; `fixtureProtocolClasses` in `Services/SourceMetadataReporter.swift:80`, `Services/DeviceSearch.swift:81`,
  `Services/ArxivHTMLReader.swift:285-287`. `Views/ChatRichTextView.swift:642-645` gates a fixture on
  `DEBUG && targetEnvironment(simulator)` instead of `FIXTURE_HOST`, so Mac fixture journeys miss it.
- **Fix:** move fixture configuration into the existing `*Fixture.swift` files as `extension ReaderModel` under one
  guard; move `ReaderLocalPersistence`, `ReaderRetirementQueue`, `ReaderWorkOwnership`, `Paper`, `LibraryListEntry` to
  their own files; put all launch hooks under `DEBUG && FIXTURE_HOST`.

### D2 — Medium — Parallel implementations of "start a paper chat with a quote" and "show the paper's chat"
- Start with quote: `selectionAction` (`ReaderModel.swift:3620`), `askAboutEquation` (`:3892`), `askAboutFigure`
  (`:4042`), `discussReference` (`:3588`) — the source of A14's and A16's drift.
- Show chat: `askAboutSelectedPaper` (`:3296`), `openConversation` (`:3301`), `openUnsentDraft` (`:3336`),
  `.continueChat` (`:3886`), `returnToChat` (`:3027`). `openConversation`/`openUnsentDraft` assign `selectedPaper`
  directly, skipping `select()`'s `recordOpened` and membership checks, and can set `wideMode = .reader` with no paper.
- Pending archive is computed three ways (`:315`, `:1194`, `:1228`) — the cause of A12.
- **Fix:** `startPaperChat(prompt:quote:origin:prefix:scenario:)`, `showPaperChat(paperID:)`, `pendingArchiveOverrides()`.

### D3 — Medium — EquationSession and FigureExplainSession are near copies
- `Views/EquationView.swift:46-185` vs `Services/FigureViewSession.swift:43-262`: state enum, consent handling, `run`
  guards, stream loop, `failure(code)` mapping, result key, credit refresh. Views duplicate `cloudLabel`, the status view,
  `rememberReturn`/`cite`, the consent-sheet binding and the model chooser (`EquationView.swift:305-309`, `:444-472` vs
  `FigureExplainView.swift:169-173`, `:363-397`). A23 is one consequence.
- **Fix:** a generic `ExplainerRequestRunner<Result>` (action, key, decoder) and one `ExplainerStatus` view.

### D4 — Low-Medium — Duplicated helpers that must stay identical
- Reading-location key written three times: `ReaderModel.swift:2921-2923` (returns an Optional that is never nil),
  `ScienceReader/ReadingMode.swift:83-93`, `Views/PaperView.swift:202-205`. `applyJump` silently drops a request whose key
  differs (`PaperView.swift:1171`) and `updateReaderCopy` carries the reading place by it (`ReaderModel.swift:2907`).
  One `Paper.readingLocationKey`.
- Five no-redirect public fetch helpers, each with its own delegate, bounded byte loop and a `URLSession` per request (a
  new TLS handshake per arXiv figure): `Services/ArxivHTMLReader.swift:212`, `Services/SourceMetadataReporter.swift:141`,
  `Services/DeviceSearch.swift:95`, `Services/DevicePDFFetcher.swift:210`, BackendClient's `LibraryRedirectPolicy`. One
  `PublicFetch` with a long-lived session per policy and a shared chunked reader.
- Three hand-built "bundle fragment" pages (`EquationWebView.page`, `EquationTilesView.page`, `TableDrawing.page`) and
  two box-to-pixel crops with different rounding (`Views/FigurePartsView.swift:28-34` vs `FigureWalkthrough.Box.pixels`
  + `FigureExplainView.crop`); two copies of the outline overlay.
- Consent version strings: `Services/BackendClient.swift:592` hard-codes `cloud-ai-v6` while `ChatStream.consentVersion`
  exists; the Gemini gate checks `"cloud-ai-v5"` (`ScienceReaderCore/.../ChatProfiles.swift:131`); the comment at
  `ChatStream.swift:37-38` still says v3. A server bump would silently hide Gemini. Named constants.
- "Unlimited testing" label re-implemented in `Views/CreditsStoreView.swift:93` (vs `CreditBalance.availableLabel`,
  `Services/ChatGeneration.swift:84`).
- Use case inferred from `label.hasPrefix("Equation")` (`ReaderModel.swift:691-692`, `:5388`). Store an explicit
  `AIUseCase` on `ContextualChatBinding`/`PromotedChatContext`.

### D5 — Low-Medium — ~30 preferences hand-written as UserDefaults properties on the observable model
- `ReaderModel.swift:266-268`, `:301`, `:313`, `:524-594`, `:655-713` (34 `UserDefaults.standard` uses).
- **Fix:** a separate `@Observable ReaderPreferences` with an injectable `UserDefaults` suite and a small
  stored-property helper; fixtures then reset one suite.

### D6 — Low-Medium — The MLX runtime ships in the Mac app with zero models; the PDF models ship in every archive
- `project.yml:84-85` links `LocalAI` on macOS; `LocalAI/Sources/LocalAI/Resources/models.json` is `[]`. The build-77
  Mac executable is 75 MB (the iOS executable ~14 MB per the services pass; Mac build 53 was ~25 MB). Attribution of the
  jump to MLX is likely, not proven. Dormant costs: every local answer re-hashes all weights (`LocalAI/.../ModelStore.swift:115-123`);
  `admitsCurrentMemory` (Metal device, sysctl) runs inside view bodies.
- `DeviceModels` (the on-device PDF experiment, intentionally in TestFlight) is 348 MB of the 442 MB Mac app in
  `.artifacts/releases/77/Gradstep-mac-77-first.xcarchive` and is in the iOS archive too.
- **Fix:** put LocalAI behind a `LOCAL_AI` build flag until a model qualifies (keep `RetiredLocalModels` for names).
  Consider Background Assets / On-Demand Resources for `DeviceModels` before any public release.

### D7 — Low — Dead code and stale flags
- `Views/PaperView.swift:176`, `:254-256`, `:283`, `:807-827`, `:903`, `:1144-1146`: the old reference confirmation
  dialog never runs (`readerHooks` always sets `onReferenceAction`, `:755`) but still costs a `GeometryReader` overlay.
- `Mac/MacSupport.swift:387-394` `ReaderWebView.plainText` (no callers); `ReaderModel.swift:28`
  `SelectionAction.equationActions` (unused; `MacSupport.swift:330-332` hard-codes); `Views/Chrome.swift:103-134`
  `ignoresKeyboardFrame` (never set; comment points at removed code); unused `@Environment(\.horizontalSizeClass)`
  (`Views/PaperView.swift:193`); the `reduced` argument to `__scienceReaderJumpToHeading` is ignored
  (`reader-bridge.js:1274-1278`).
- `Services/BackendClient.swift:645-664` `putLibraryDescriptor` (no callers; leaves descriptor sealing test-only),
  `:1180-1191` `UploadProgress` (never constructed), misplaced doc comment `:1175-1177`.
- `Services/PDFUploadQueue.swift:182`, `:186` (`Context.service`/`cursor` never read), `:199` (`progress` never written),
  `:345-353` (`persist`/`update` unused), `:304` (throwaway `PDFUploadJob`); three installer routes.
- `ScienceReaderCore/.../ChatFigures.swift:91`: `attaching(_:)` drops `onDevicePaperText`, `onDeviceFocus` and
  `isLocalInference` — harmless only while local transports never emit `figureRequest`. `citeHandler` passed to user
  messages that never render links (`Views/ChatTranscript.swift:302-305`). A `private static var marker: Regex` computed
  property in the figure finder rebuilds the regex per call.

### D8 — Low — Fixed-delay sequencing
- `Views/RootView.swift:1079-1093` (Mac send: 60 ms then send, 300 ms then refocus), `Views/PaperView.swift:603`
  (350 ms after a sheet), `Mac/MacSupport.swift:529` (`asyncAfter(0.3)` to size the window). Each is a race on a slow
  machine. Use end-editing/`onDismiss`/scene-geometry callbacks.

### D9 — Low — Stale comments and misplaced code
- `Views/EquationView.swift:476-477` (describes a removed "Scroll sideways" toggle); `Views/PaperView.swift:186`,
  `:638-639` (describe WebKit's find bar; the custom JS find is used); `ReaderModel.swift:3150-3155` (two near-identical
  comment paragraphs); `equationProfile` is also used for figures.
- `ReaderWebView` (the paper's web view on every platform) and `ReaderModel.showWideMode` (used by iPad) live in
  `Mac/MacSupport.swift`. Move to shared files.
- The abstract-list layout fix sits inside `installPaperTags` (`reader-bridge.js:1155-1157`), so it is skipped when there
  is no tags payload and rescans every `<p>` per tags update.
- Two "sheet top row" components with the same `sheet.close` identifier (`Views/SheetChrome.swift:34-77`, `:186-206`);
  the modifier hard-codes "Chat about Figure". Several sheets still use "Done" (`Views/FigureGallery.swift:69`,
  `Views/ReportsView.swift:29`, `Views/PaperView.swift:1413`, `:1420`) and `ReaderVersionSheet` has its own xmark,
  against the owner's "X, not Done" direction.

### D10 — Low — Build and test hygiene
- `project.yml:172-187`: the `ScienceReaderResourceProbe` target compiles all of `ScienceReader/` (including
  `Views/ChatRichTextView.swift`, which imports SwiftMath) but depends only on ScienceReaderCore and LocalAI; the
  pbxproj confirms SwiftMath is linked only into the app (`project.pbxproj:1051-1055` vs `:1111-1114`). The opt-in
  resource probe likely no longer builds (not run here). Add `- package: SwiftMath`.
- `ScienceReaderCore/Sources/ScienceReaderCore/DevicePDF/DevicePDFRoute.swift:145`, `:149`: the only Core warnings under
  Swift 6 — a captured `var images` read in `concurrentPerform`, and the non-`Sendable` `progress` closure called
  concurrently from worker threads (so `.formulas(done:of:)` can arrive out of order). `let images = images`; make the
  Core API take `@Sendable` progress (the app already passes one, `DeviceModelReading.swift:75`). Also
  `cancelled: { Task.isCancelled }` is always false on the `concurrentPerform` worker threads.
- UI tests carry 14 private copies of `launch`, 13 of `capture`, 4 of `waitFor`, 3 of `openSample`; move them to
  `ScienceReaderUITests/ReaderMenuSupport.swift`. `ScienceReaderTests/PaperWebViewTests.swift:10-35` runs an
  80-iteration timing benchmark in the routine suite and asserts nothing.

---

## E. Larger refactors (propose; not for an overnight change)

### E1 — Split ReaderModel
5,444 lines; one class body (lines 135–5000) with ~190 stored properties (~125 observed), ~236 methods and 13
extension files. Keep `ReaderModel` as a thin coordinator holding a `SessionContext` (sessionID, accountID, backend,
persistence, device) passed to children; children get no back-pointer and own their own reset.

| New type | Moves in (current lines) |
|---|---|
| `ReaderPreferences` | D5 |
| `PurchaseController` | 4524–4539, 4580–4771 |
| `FeedController` | 519–560, 2294–2424 |
| `ExplanationStore` | 3792–4055 |
| `CatalogController` | 322–501 (+ key cache, write queue, deletion plan) |
| `LibraryStore` | papers, imports, `completeLibrary`, 2635–2820, commands/tags/archive 2431–2633 |
| `LibrarySearchController` | 1016–1030, 1092–1313 |
| `PaperPreparation` | 228–261, 2822–3294, `DeviceModelReading` (with E7) |
| `ChatController` | workspace, drafts, branches, send, generation, streaming (597–650, 899–925, 1514–1547, 3296–3375, 3560–3790, 4058–4522) |
| `ChatProfileSettings` | 651–770 |
| `ContextualChatController` | 5340–5444 |
| `ReadingActivityTracker` | 818–829, 1402–1504 |
| `AccountSession` | start/auth 1549–1874, activate 1917–2001, sign-out/delete/clear 2051–2147, recovery 1876–1914 |
| `SyncScheduler` | `synchronize` (2003), 4612–4652 |

Order: preferences, purchases, feed and explanations first (fewest cross-dependencies), then catalogs, then chat. Each
child owning its own `reset()` fixes the class of bug in A4.

### E2 — Indexed PrivateState and one projection computed in the store actor
Give `PrivateState` indexes maintained in `apply` (tombstone set, events by entity, heads, messages by conversation,
children by parent) and compute a `PrivateStateProjection` (catalogs, chat counts, summaries, diagram links, local-PDF
memberships, branch tables) inside the `EncryptedStore` actor next to `snapshot()`. Publish one value. Fixes C1 and C5
at the root.

### E3 — One navigation destination instead of `tab` + `wideMode`
`.onChange(of: model.wideMode) { model.showWideMode($0) }` (`Views/RootView.swift:246`) and the compact layout's
opposite sync (`:39-41`) reconcile two sources of truth that ~30 call sites set by hand. A single `Destination` enum
with `tab`/`wideMode` derived per layout removes B4 and the stale-`.browse` cases in B7.

### E4 — Split RootView.swift and PaperView.swift
- `Views/RootView.swift` (1,911 lines) holds the shell plus `LibraryView`, `PaperRow`, `ImportRow`, `FeedView`,
  `DiscoveryList`, `ChatView`, `SettingsView`, `PrivacyView`, `DeleteAccountView`, `RecoveryView`,
  `LibrarySearchField`. Split into `LibraryView.swift`, `FeedView.swift`, `ChatView.swift`, `SettingsView.swift` (merged
  with `SettingsPages.swift`); keep RootView to the shell, tab bar and root sheets (which also fixes A15).
- `Views/PaperView.swift` (1,480 lines) mixes the screen, `PaperWebView` with a ~45-parameter initialiser (the
  "set after construction so the initializer still type-checks" workaround at `:742` shows it has outgrown itself), the
  bridge message models and the local PDF viewer. Split into `PaperWebView.swift` (a `ReaderPageConfiguration` struct
  + a `ReaderPageEvents` protocol), `ReaderBridgeMessages.swift` (pure, unit-testable parsing),
  `LocalPDFReaderView.swift`.

### E5 — One action model for menus, context menus and Mac/iPad Commands
`PaperActions`, `LibraryActions`, `FeedRowActions` values (title, symbol, shortcut, enabled, perform) rendered by the
"…" `Menu`, the context menus and `Commands`. Removes B5, B6, B8 (Feed) and the copy-paste between
`Views/PaperView.swift:457-475`, `Views/RootView.swift:427-509`, `:865-882` and `Mac/MacCommands.swift`.

### E6 — Unify the "explain an item" stack and chat transcript
One explainer runner (D3), one shared transcript row and scroll policy for the main chat and the sheets (B2), one
composer (B3), and one figure-image service with a cost-limited cache and background decode used by the transcript,
the explainer, Send and the gallery (C8, C9, C11). Replace `TranscriptTable.Coordinator`'s ~15 interacting booleans
(`Views/ChatTranscript.swift:356-666`: `applying`, `updating`, `restoring`, `animating`, `userScrolling`,
`settleAfterApply`, `needsRestore`, `realizingAnchor`…) with an explicit state enum (idle/following/anchored/gesture/
applying) and one transition function; whether applying snapshots from `layoutSubviews` (`:540`) is safe is uncertain.

### E7 — A preparation registry keyed by paper
`preparations: [UUID: Task<VerifiedReaderBundle, Error>]` joined by open, background download, chat and model paths,
with progress fan-out. Fixes A7 and A8, and gives `clearAccountView` one thing to cancel.

### E8 — Modularise reader-bridge.js
`ScienceReader/Resources/reader-bridge.js` is one 2,038-line, ~130 KB function shared byte-for-byte with the web app
(citations, references, find, underlines, the Contents gesture, tags, authors, layout). Build it from modules, generate
the native resource and the web copy (with its CSP hash in `apps/web/vite.config.ts`), keep a byte-identity check.

---

## Checked and found clean

- Every fixture file, `VisualCapture`, `WorkflowFixture`, `BackendFaultProtocol`, `LocalAIController.fixtureStream`
  and `ShareInbox` fixture paths are behind `DEBUG && FIXTURE_HOST`; `SessionCapture` is behind `INTERNAL`. Exceptions
  are listed in D1.
- Entitlement and Info.plist changes since 10-16 (`applinks:app.gradstep.ai`, Mac microphone/audio-input sandbox keys,
  `NSSpeechRecognitionUsageDescription`) match their use; "does not upload dictation audio" is backed by
  `requiresOnDeviceRecognition = true` (`Services/ChatDictation.swift:52`).
- LocalAI is limited to macOS by `platformFilter`, and the app imports it only under `targetEnvironment(macCatalyst)`.
- No multi-window hazard today: there is no `UIApplicationSceneManifest`, so the single shared `ReaderModel` and its
  `start()` cannot be entered by a second scene. Enabling multiple scenes later would need a per-scene model or a guarded
  start.
- `swift build` of ScienceReaderCore: clean apart from the two DevicePDFRoute warnings in D10.

## Suggested order of work

1. A1, A2, A3 (sign-in and money) — small, local changes with unit tests in `AuthenticationBackendTests` and
   `ChatGenerationTests`.
2. A4, A11, A7 (state that outlives its owner) — then E7.
3. A5, A6, A12, A13 (library/catalog correctness), with the web counterpart for A6's key kind.
4. C1 quick fixes (`>` in `publish`, conditional `papers` assignment), C2 (memoised keywords), C7 (nil-write guard) —
   each a few lines with an `OfflineResourceProbe` before/after.
5. B1 (iPad commands) and B2/B3 (shared transcript row and composer).
6. D1, D7 (move fixtures out of ReaderModel; delete dead code) to shrink the surface before E1.
7. E1/E2 incrementally, starting with preferences, purchases, feed and explanations.

Per the test policy, items 1–4 need only `npm test`/`test:fast` plus the affected unit suites; B1–B3 and A10 need their
Simulator journeys rerun; nothing here needs the physical phone.
