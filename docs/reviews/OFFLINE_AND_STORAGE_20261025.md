# No network, bad connections and a full disk — review, 2026-10-25

Owner request (2026-10-25): "Can you have an agent that looks at situations where internet is not present, or space is
full, and ensures that reasonable behavior results in varying situations?"

Scope: the Apple apps (iPhone, iPad, Mac; `apps/apple`). The browser app and the server were not changed. Earlier work
this builds on: [RESILIENCE.md](../architecture/RESILIENCE.md) (bounded timeouts, back-off, last-good caches, server
outages) and [NATIVE_OFFLINE_BUNDLES.md](../architecture/NATIVE_OFFLINE_BUNDLES.md) (offline reading).

**Expected everywhere:** what is on the device keeps working; one short line says what happened (no banners of text),
with a way on where one exists; no endless spinner; nothing lost, written half-way or asked (and paid for) twice.

## What was found

An inventory of every network call (8 URL sessions, about 30 call paths) and every disk write (SQLite, 15 file writers)
came first. The app was already sound in most places: offline reading needs no network, every write is atomic, every
request has a total time limit, chat answers end after 100 s of silence, a failed answer save keeps the answer and
saves it again on Try again without asking twice. The gaps:

1. **A full disk at launch closed the whole private library.** SQLite deletes its `-wal`/`-shm` files when the store
   closes cleanly (sign-out, a Mac quit, an earlier session). On a full disk it can't make them again, and opening
   failed (`SQLITE_IOERR_SHMOPEN`); with room for them, the open's own bookkeeping write then failed (`SQLITE_FULL`).
   Library, chats and notes would all have been unavailable. Reproduced on a real 20 MB APFS disk image.
2. **A full disk was never named.** No code recognised `ENOSPC`, `SQLITE_FULL` or `NSFileWriteOutOfSpaceError`
   (except one model-download line). Sending a chat said "This operation could not finish. Your existing saved data has
   been preserved."; a PDF said "could not be saved securely"; a paper preparation printed an enum name
   (`(storageUnavailable)`) and offered its PDF.
3. **Offline looked like a broken paper.** Opening a paper that isn't downloaded, offline, raised a raw `URLError`
   that the reader screen took for an HTML problem: "Read this paper as its PDF" with an Open PDF button that needs
   the network too.
4. **No error spoke of being offline.** A `URLError` has no words of its own in the app, so offline, a timeout, a
   failed DNS lookup and a captive Wi‑Fi all fell to generic lines ("The connection was interrupted before the answer
   finished" for a question that was never sent).
5. **A captive Wi‑Fi page** (HTML in place of JSON) became a decoding error ("This operation could not finish"), a
   malformed chat stream, or "Sign-in returned an invalid response".
6. **Coming back online waited.** Sync backs off to 5 minutes and nothing watched the network, so after a long outage
   sync, unsent library changes and a stalled first-device setup could wait up to ~6 minutes.
7. **Smaller:** paid AI explanations were saved with `try?` (lost silently on a full disk, yet listed as kept); a
   connection that dropped mid-PDF said "open it in Safari"; a PDF body shorter than its declared length could be
   kept; temporary files from a crash during a paper or PDF write (up to 64 MB each) were never removed; an offline
   token refresh on a new device took the recovery-sheet path; a failed Save to Files of the assets zip looked like
   success; a dropped PDF that couldn't be copied vanished silently; the internal session recorder could list a
   half-copied zip.

## What changed

- **`StorageSpace` (Core):** tells a full disk apart from every other write failure (`ENOSPC`/`EDQUOT`, `SQLITE_FULL`,
  Cocoa 640, On-Demand Resources 4992, a download that couldn't write), reads free space
  (`volumeAvailableCapacityForImportantUsage`), and words it: **"This device is out of space. Free up 120 MB and try
  again."** (the amount when known).
- **The encrypted store opens on a full disk:** its `-wal`/`-shm` files are now kept between launches
  (`SQLITE_FCNTL_PERSIST_WAL`); a store last closed by an earlier build opens with SQLite's index in memory
  (`locking_mode=EXCLUSIVE`) or, with no room for even an empty file, as a read-only snapshot that becomes writable at
  the first save after space is freed. The open's clean-up write (pruning empty drafts, retiring a dead process's
  library attempts) is skipped on a full disk and done at the next launch; the first save still fences older writers.
- **Paper and PDF stores** keep "out of space" (with the shortfall) instead of collapsing it, and sweep temporary files
  left by a crash when they open. The model install keeps "out of space" through its on-device compile.
- **`ConnectionText` and `Connectivity` (app):** one line per connection failure — offline, timed out, lost,
  can't reach, secure connection failed ("If this Wi‑Fi asks you to sign in, open Safari…"). `show(_:)`, sync, the
  reader, PDFs, podcasts, notes and snippets use it. `Connectivity` watches the network path; on reconnect, sync,
  unsent library changes, a stalled first-device setup and a failed library refresh go at once.
- **Reader:** offline → "Couldn’t reach arXiv · You’re offline. This paper downloads from arXiv when you’re back online;
  papers on this device still open." with Try again (no PDF offered); a connection failure is never a figure's quiet
  loss; a full disk → "Not enough space" with the amount and Try again.
- **Chat:** a question that never reached Gradstep says "You’re offline. Your question is saved; try again when you’re
  connected." (or "Couldn’t reach Gradstep…"); "interrupted" is kept for answers that had started. A full disk on the
  answer's save adds the amount to the existing "Try again saves it; it isn’t asked for again".
- **Captive Wi‑Fi:** a web page where Gradstep's JSON or stream should be is `network_sign_in` ("This Wi‑Fi needs you
  to sign in. Open Safari to sign in, then try again."), retried with back-off like any transient failure; in sign-in
  it is a connection failure.
- **Sync:** "Offline · Saved on this device" (Account row: "Offline"); "Can’t reach Gradstep · Saved on this device".
- **Downloads:** the 365 MB model is refused before downloading when the device lacks twice its size plus 50 MB
  ("Free up 583 MB" with 200 MB free); a PDF of known size needs twice its size (plaintext and its encrypted copy);
  a dropped connection is "Couldn’t reach the paper’s website…"; a short body is never kept.
- **Explanations** (equation, figure, paper) that can't be saved say so and stay open for the session instead of
  vanishing; the dropped-PDF copy, the Files export and the session recorder no longer fail silently or half-way.
- **Test seams (Debug + fixture host only):** `--backend-fault=<prefix>:offline|dns|tls|lost|html` (plus the existing
  status/timeout/malformed; `*` and host prefixes such as `arxiv.org/html`), now on every session the app makes
  (backend, arXiv, PDF downloads, search); `--network-offline[=<s>]`; `--storage-full-fixture[=<s>]`;
  `--chat-fixture-mode=offline`; `--device-model-download-fixture=fail_once|full`; `--offline-reader-unprepared`.

## Results

"Before" is the shipped behaviour (TestFlight 92 source); tests marked *Core* run in `swift test`, *app* in
`ScienceReaderTests`, *UI* in `ScienceReaderUITests/OfflineAndStorageJourneyTests` (iPhone Simulator).

| Situation | Before | After | Test |
|---|---|---|---|
| Cold launch offline, paper downloaded | Library and paper open | Unchanged | UI `testOfflineLaunchOpensADownloadedPaper` |
| Launch with the disk completely full | Private library failed to open (SQLITE_IOERR_SHMOPEN / SQLITE_FULL) | Opens and reads; a save says out of space; saves again once space is freed, no relaunch | Core `StorageFullTests.aStoreSavedEarlierOpensOnAFullDisk` (3 cases) |
| Open a paper not downloaded, offline | "Read this paper as its PDF" + Open PDF (fails too) | "Couldn’t reach arXiv · You’re offline…" + Try again; Try again ends again | app `testOpeningAPaperOfflineOffersTryAgainNotItsPDF`; UI `testOpeningAPaperThatIsntDownloadedOfflineSaysSoWithTryAgain` |
| arXiv times out / drops mid-download | Same PDF screen; a dropped image connection was a raw error | "Couldn’t retrieve this paper from arXiv…" + Try again; a short body is a failure | app (same test) |
| PDF download drops partway | "Couldn’t download the PDF… open it in Safari" | "Couldn’t reach the paper’s website from this device. Check your connection…" | app `testAPDFWhoseConnectionDropsPartwayIsUnreachableNotRefused` |
| PDF body shorter than its length | Could be kept as the paper | Refused, nothing kept | app `testAPDFShorterThanItsDeclaredLengthIsNeverKept` |
| Chat sent offline (before any text) | "The connection was interrupted before the answer finished." | "You’re offline. Your question is saved…"; Try again answers it; the question appears once | UI `testAChatSentOfflineIsKeptAndAnsweredOnceBackOnline` |
| Chat stream stalls | Ends after 100 s silence as interrupted | Unchanged | existing `ResilienceJourneyTests.testASilentAnswerEndsAsInterrupted` |
| Sync offline | "Sync could not finish…", next try after up to 5 min | "Offline · Saved on this device"; resumes when the network returns | app `testSyncSaysOfflineAndResumesByItself` (wording); reconnect: built, see "Not verified" |
| New device, offline, expired token | Recovery sheet path | Retried as a connection failure | app `testATokenRefreshThatCantConnectIsTheConnection` |
| Captive Wi‑Fi page instead of JSON | "This operation could not finish…" / malformed stream / invalid sign-in response | "This Wi‑Fi needs you to sign in. Open Safari…", retried with back-off | app `testACaptiveWiFiPageInPlaceOfGradstepSaysSignInToTheWiFi` |
| TLS failure, DNS failure, timeout | Generic lines | One specific line each | app `testEachFailureHasOneShortSpecificLine` |
| Server 5xx / 429 / stalled stream | Specific lines, back-off (RESILIENCE.md) | Unchanged | existing `ResilienceTests`, `ResilienceJourneyTests` |
| Model download interrupted | "The download stopped…"; retry restarts | Unchanged; retry verified to restart cleanly | UI `testAnInterruptedModelDownloadRestartsCleanly` |
| Model download, disk nearly full | Fails after downloading: "Not enough free space on this device for the model." | Refused before downloading: "…Free up 583 MB and try again." | UI `testAFullDiskIsSaidBeforeTheModelDownloads`; app `testTheModelDownloadSaysHowMuchToFreeBeforeDownloading` |
| Model install fills the disk | Raw error or "couldn’t be prepared" | Out of space; nothing half-installed; installs once space is freed | Core `theModelInstalledOnAFullDiskLeavesNothingHalfDone` |
| Chat question on a full disk | "This operation could not finish. Your existing saved data has been preserved." | "This device is out of space. Free up 120 MB…"; the question stays in the box; sends once later | UI `testAChatOnAFullDiskKeepsTheQuestionAndSendsOnceThereIsRoom`; Core `theEncryptedStoreFailsCleanlyWhenFullAndRecoversWhenSpaceIsFreed` |
| Draft typed on a full disk | "Draft not saved on this device…" | Unchanged; the last saved draft is what reopens | Core `aDraftSavedOnAFullDiskKeepsTheLastSavedText` |
| PDF or paper saved on a full disk | "could not be saved securely" / "(storageUnavailable)" + PDF offer | Out of space with the amount; others still read; nothing half-written | Core `aPDFSavedOnAFullDiskSaysHowMuchToFreeAndKeepsTheOthers`; app (fallback `.space`) |
| Crash during a paper/PDF write | Hidden temp file (≤ 64 MB) kept forever | Removed when the store next opens | Core `aCrashedWritesTemporaryFileIsSweptAtOpen` |
| AI explanation saved on a full disk | Lost silently, still listed | Says so; stays open for the session; not listed | Not automated (one `do/catch`) |
| Note or snippet on a full disk | "Couldn’t save on this device. Your text is still here." | "This device is out of space… Your text is still here." | Not automated (wording) |
| Podcast offline / audio on a full disk | "The connection was interrupted…" / generic | "You’re offline. Downloaded episodes still play." / out of space | Not automated (wording) |
| Feed, For you, ML search offline | Last page kept with "Couldn’t refresh…"; search says unavailable; Library search works (local) | Unchanged | existing `ResilienceJourneyTests.testAFailedFeedRefreshKeepsTheLastPage` |
| Reports, purchases, credits offline | Outbox; StoreKit retries; balance "as of" | Unchanged | existing |

## Defaults chosen (the owner may want different)

- **Room kept free:** 50 MB beyond any write the app checks in advance. The model download needs twice the pack
  plus 50 MB (≈ 782 MB for 365 MB: the system's download and the checked copy coexist briefly); a PDF of known size
  needs twice its size (plaintext and encrypted copy). A paper preparation isn't checked in advance (its size isn't
  known); its write fails cleanly and says the shortfall.
- **Nothing paid retries by itself:** a chat question that failed offline waits for Try again, even after the network
  returns, so no credit is spent without the reader asking. Sync, unsent library changes, the first-device setup and a
  failed library refresh resume on reconnect (free).
- **Timeouts unchanged** (RPCs 60 s idle/180 s total; streams and downloads 60 s/15 min with a 100 s silence limit for
  answers; arXiv 30 s/90 s; PDFs 60 s/5 min).
- **No app-wide offline banner** (owner preference for minimal UI): the sync line ("Offline · Saved on this device")
  and each feature's own line say it.
- **Full disk at launch:** the store's open-time clean-up is skipped until the next launch with room; a store from an
  earlier build opens exclusively or read-only until relaunch/space returns.

Possible owner decisions: keep the Feed's last page across launches for offline cold starts (today memory only); retry
a failed offline question automatically once the network returns (spends credits without a tap).

## Not verified here (needs a device or isn't reproducible in the Simulator)

- Real network transitions (Airplane Mode, Wi‑Fi off, cellular data off for the app) and `NWPathMonitor`'s timing:
  the Simulator shares the Mac's network, which stayed on; journeys use `--network-offline`.
- A real captive portal (TLS interception and the system's sign-in sheet).
- A real full iPhone: iOS frees purgeable space for "important" writes, and On-Demand Resources reports its own
  out-of-space error; the disk-image tests use real `ENOSPC` on macOS APFS.
- The reconnect hook end to end with a signed-in account (the fixtures that run offline have no sync).
- The physical iPhone is paused at the owner's request; nothing was run on it.

## Evidence

Screenshots under `.artifacts/offline-storage-20261025/`. Commands: `swift test --filter StorageFullTests` in
`apps/apple/ScienceReaderCore`; `xcodebuild test … -only-testing:ScienceReaderTests/OfflineAndStorageTests` and
`-only-testing:ScienceReaderUITests/OfflineAndStorageJourneyTests` on an iPhone Simulator
(`TEST_RUNNER_GS_SCREENSHOT_DIR` for screenshots).
