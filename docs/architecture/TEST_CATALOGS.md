# Test catalogs: a folder of PDFs read by the on-device model

Owner, 2026-10-28: "One other task I'd like is to create a catalog on my account for me that has maybe 30-40 random
neuroscience pdf papers preloaded into the library with the on device model. Then, I can experiment with testing the
current on device model for those papers, without worrying about the process of converting and getting them into the
library." The same day the lead redirected it from arXiv q-bio.NC papers to the owner's own journal PDFs (the Papers
library corpus): drop the bundled arXiv list; the app imports a folder instead. Built 2026-10-28, local, not released.

## Why the app does it, not the server

Private library content is end-to-end encrypted and PDFs are processed only on the user's device
([HTML_FIRST_READER](HTML_FIRST_READER.md), [ARXIV_DEVICE_ONLY](ARXIV_DEVICE_ONLY.md)). Nothing can be inserted into the
owner's account from a server, and nobody signs in as the owner. The owner's own app adds the PDFs (the ordinary
local-PDF path: checked, kept encrypted on the device, never uploaded), files them in a catalog through the encrypted
catalog journal ([LIBRARY_CATALOGS](LIBRARY_CATALOGS.md)) and reads each with the on-device model
([DEVICE_PDF_ROUTE](DEVICE_PDF_ROUTE.md)).

## The action

**Settings › Experimental › Import a folder as a test catalog…** (grey like the Admin rows, with an ⓘ). Staff only: an
account with an operator role (`owner` or `support`, the same roles that show the Admin section's Operations dashboard;
`TestCatalogQueue.isAvailable`). Readers without a role never see the row; the section itself appears only in builds
that carry the on-device model.

1. **The model first.** Without the model on the device (or with the reader switched off) the button asks the usual
   "Download the on-device PDF reader?"; tap the button again once it is in. A queue that reaches a reading without
   the model waits ("Waiting for the on-device model") and carries on when the download finishes.
2. **Pick a folder** (Files on iPhone/iPad, the open panel on the Mac). Its own visible `.pdf` files are listed (not
   subfolders) and fingerprinted (SHA-256).
3. **The catalog** is named after the folder: the queue's own catalog, else an existing catalog with that name, else a
   new one. The Library switches to it.
4. **Adding.** Every new file goes through the local-PDF checks (`%PDF-`, at most 64 MiB and 250 pages, unlocked) and
   is kept encrypted on the device as a library paper filed in that catalog. A file named like a title (three words or
   more, e.g. "Alvarez 1994 - Memory consolidation….pdf") names the paper; otherwise the PDF's own title does. A file
   already added from this folder on another device (the catalog syncs; the PDF never does) is matched by title and page
   count, and this device keeps that same paper's PDF instead of adding it twice.
5. **Reading.** Then each paper is read by the on-device model, one at a time, in file-name order, through the same run
   as the paper's own "Read with the on-device model" (`startDeviceModelRun`), so its progress bar shows if that paper is
   open, and the screen stays awake while a reading runs. Each reading is kept on the device, so the paper's "Read with
   the on-device model" opens it at once, also while the queue reads another paper. A new reading of some other paper
   waits for the queue (one model run at a time): Pause it first.
6. **One progress line** under the button: "Adding 3 of 36 to the library", "Reading 7 of 36 with the on-device model",
   "Paused · 6 of 36 read", "Done · 34 of 36 read". **Pause** stops the reading under way (that paper is read again on
   **Resume**); a reading the reader started themselves is never stopped by it, and the queue waits for it to finish.
7. **What wasn't read** is listed under "Not read · N" with the reason (a damaged PDF, the model's failure message, the
   paper moved to another catalog or removed). A failure never stops the rest.

**Idempotent.** Importing the same folder again adds nothing twice: files are matched by content. A file already in
this catalog is only read if it has no kept reading; a file whose bytes are already in the library in **another**
catalog is skipped and left alone (never moved or read); failed and skipped files are looked at again, which is how to
retry. Other catalogs and papers are never touched. One test catalog runs at a time; importing a different folder
takes the queue over (the earlier catalog and its papers stay).

**Resumes after a relaunch.** The queue (catalog id and name, each file's name, SHA-256 and status, paused, and a bookmark
to the folder) is one small file sealed with the account's local-store key in the account's folder
(`test-catalogs/queue.sealed`; `TestCatalogQueueStore`), never synced or uploaded, removed with the account's data. On the
next activation it carries on unless paused or finished (after the operator roles are confirmed); a reading cut short
starts again. Files not yet added are found through the folder bookmark; if the folder is gone, they are listed as
failed ("Import it again").

Readings run only while the app is open (iOS stops GPU work in the background). Model readings and PDFs are per device:
another device shows the same catalog and papers, and reads them again when the folder is imported there.

## The neuroscience test folder (2026-10-28)

`scripts/select-test-pdfs.py`, seed **20261028**, run on the Mac against `~/gradstep-mac/corpora/papers-library-20261026`
(read only; copies, never moves). It draws only from the **test** split of the family-grouped split
(`.artifacts/papers-model-20261026/splits.json`: 2,494 train / 297 dev / 312 test files), never train or dev, and
excludes any family in the span study's reserved final cohort
(`.artifacts/device-pdf-development/spans/training-confirmation/selection.json`, 48 dev families, which stay unscored and
unseen), files in `needs-review.jsonl`, files without a PDF header, files the app cannot add (6: over 64 MiB or 250
pages), and slides or posters drawn (2: under 3 pages or made by Keynote/PowerPoint). Eligible pool: 286 files. Light
stratification: the sample is spread over publication-year eras in proportion to the pool (6 before 2000, 7 in
2000–2004, 12 in 2005–2009, 11 in 2010–2014), at most two per journal and one per family. Copies are verified by SHA-256.

Result: **36 PDFs, 540 pages** (3–47, median 13), in `~/Desktop/Gradstep neuroscience test PDFs/` with a
`selection.json` (seed, method, split, counts, each file's SHA-256). The PDFs and their titles are private and are not
in this repository; only this method and the counts are.

**Getting the folder onto a device.** On the Mac app, pick the Desktop folder directly. For iPhone/iPad, AirDrop the folder
(or a zip of it, unzipped in Files) to the device and pick it in Files under On My iPhone/iPad › Downloads. iCloud Drive
also works but puts the owner's private PDFs in iCloud; use it only if the owner chooses to.

## Verification (2026-10-28)

- Core: `TestCatalogQueueTests` (6): staff gating; add-then-read order by file name; importing again is idempotent,
  skips papers elsewhere and duplicate files; a failure never stops the rest and importing again retries it;
  pause/resume; resume after a relaunch from the sealed file (a reading cut short starts again; another account's key
  opens nothing).
- App: `TestCatalogImportTests` (2): a folder contributes only its own visible PDFs with their hashes; a reader without
  an operator role never gets the action.
- iPhone Simulator journey `TestCatalogJourneyTests` (fixture account, generated folder of three papers and one damaged
  file, a stand-in model so the real models never run on the Mac): not shown to non-staff; staff import → "Reading…" →
  Pause/Resume → "Done · 3 of 4 read" with the damaged file listed; importing again changes nothing; the Library shows
  the catalog with the three papers, labelled "Your PDF". iPhone 17 and (staff journey) iPad Pro 11-inch; the Mac
  Catalyst app compiles. Screenshots: `.artifacts/neuro-test-catalog/`.
- Not verified: the real on-device model reading these PDFs (Astra's track owns Core ML runs on this Mac), a kept
  reading opening while the queue reads another paper (the stand-in keeps none), a real Files or Mac folder pick, the
  Mac's folder bookmark after a relaunch (the sandbox may refuse it: the files not yet added then ask for the folder
  again), the same folder imported on a second device, and the physical iPhone (paused).
