# Agent handoff

## Working together: Astra and the Claude lead (owner, 2026-10-28)

Owner: "let me know how I should direct Astra to work synchronously from you" and, on the proposal, "I'll let you
decide". Two agent teams share this repo and this Mac: **Astra** (a Codex session) and the **Claude lead** (with its
own sub-agents). This section is the contract; read it before anything else in this file.

**Ownership**
- **Astra owns the on-device PDF model track:** training and evaluation (`training/device_pdf/`, its README is the
  single current log), `scripts/device-pdf-models/`, the Core ML runtime in ScienceReaderCore/DevicePDF, the converter
  (`supabase/functions/_shared/reader/device-pdf/`), model packaging and Core ML encryption. First tasks, in order:
  (1) the untranscribed-equation fallback shows raw `\(\text{Equation in PDF (transcription unavailable)}\)` markup to
  readers (`device-pdf` emit path, `reader-math-fallback`; about 90 of 600 test formulas take it) — show plain text or
  the PDF's own glyph text instead; (2) make the recogniser load encrypted (the "return only new cache entries"
  candidate), folding in the Claude team's speed work: branch `worktree-agent-a089fbf80d06665de` (continuous batching,
  length limit, text-first host, one ODR tag per model, tagger v5a evidence), summarised in the device-PDF README;
  (3) before the next tagger experiment, add a control arm (same fine-tune without the new labels) and state why the
  preservation gate is 0.01 pp when v5b was admitted at 0.3 pp.
- **The Claude lead owns** the app and its interface, the server and staging deploys, releases (TestFlight builds and
  their scripts), owner-feedback triage, and merging for each build.

**Rules for both**
1. Start of a session: read this file, `docs/JUDGMENT_LOG.md` and `git log` since your last session.
2. End of a session: add at most 10 lines here — what changed, what it means for the other team in plain
   consequences (e.g. "this blocks every TestFlight upload"), and what's blocked.
3. Ask the owner (or the lead) first before changing upload/release scripts or release requirements, shared app
   interface or navigation, the website or privacy page, or anything deployed. If you change one, say the effect on
   others in one sentence at the top of your handoff note.
4. Version numbers (reader revision, device port revision): take the next number only at merge time (main + 1).
   Judgment-log entries and migration numbers are handed out by the lead when work is dispatched; Astra asks the
   lead for one. Releases are tagged `tf-N`.
5. Machine: heavy work on the desktop (`192.168.1.32:/home/ben/science-reader-training`). On this Mac take
   `mkdir /Users/benbowlwes/gradstep-mac/.coreml-lock` for every Core ML run, keep at most 5 GB of new evidence under
   `.artifacts` (move the rest to the desktop), and at most one booted Simulator.
6. Quote the owner's words with a date for any approval; one change per commit with a short why in the body.
7. Judgment calls made for the owner go in `docs/JUDGMENT_LOG.md` (next number after the highest).

**From the lead to Astra, 2026-10-28 (review of a993d838..9a6dd366; owner asked for it).** The experiments and
fail-closed code are the strongest in the repo. Focus, in order:
1. Reader-visible bug: untranscribed equations show raw `\(\text{Equation in PDF (transcription unavailable)}\)`.
2. Recogniser encryption with the lean cache interface, folding in the speed branch (`worktree-agent-a089fbf80d06665de`,
   handoff in the device-PDF README "2026-10-28 — recogniser speed branch"): CPU prototype on the desktop first; gate on
   token parity, memory under 2× and a quiet-Mac timing A/B. This is the next model release (one download per model).
3. Measure what hiding rejected transcriptions costs (4,973 = 8.1 % of equations now give search, copy and AI context a
   placeholder): sample how many rejected guesses were right.
4. Next tagger experiment: a control arm (same replay fine-tune without the new labels), more than one seed, and a
   written reason for the 0.01 pp preservation gate (v5b was admitted at 0.3 pp).
Tie up:
- Re-check 9f150b94's MediaBox→CropBox glyph change on its own (it affects every device reading) and record it.
- Small bugs: the reference-tagger fixture has binary_sha256 == checkpoint_sha256; recovery counts never reach the app
  summary. (The PDF preview's stuck request id and pinch assertion are now the lead's: see below.)
- **The two-finger PDF preview and Show in PDF are now the lead's** (app interface; owner 2026-10-28: "It shouldn't
  matter if I click on a figure, text, equation or table"). The lead's agent is making one resolver for every element
  and both reading kinds, using the converter's provenance boxes for model readings. Keep provenance (`blocks`,
  equation boxes, figure/table boxes) stable in converter changes, and tell the lead before changing its shape.
- Docs: TESTING.md tells DeviceModelJourneyTests users to run plain `device-models.mjs`, which now needs keys; this
  file said 31 focused Swift checks where TESTING says 42; replace absolute /home/ben and /Users paths in scripts.
- Approvals: quote the owner's words with a date for the two-finger preview, the new Show in PDF toolbar button
  (it is new in 09e71c2f, not "existing") and the website publish.
- Privacy page: ARXIV_DEVICE_ONLY.md now says the page discloses Crossref/OpenAlex lookups; the live page mentions
  only DataCite while identify.ts/discover.ts do query Crossref and OpenAlex. Draft the missing sentence for the
  owner's approval (the lead deploys).
- Disk: move about 12 GB of new evidence (device-pdf-development 9.2 GB, mostly encryption attempts;
  papers-model-20261026 3.1 GB) to the desktop; keep under 5 GB here.
- Old Codex branches: 9 unmerged `codex/web-*`/`codex/mac-native` branches from 2026-10-08 and 12 worktrees in
  `/Users/benbowlwes/science-reader-*` (1.7 GB). Ask the owner whether to archive (tag) and remove them.
- The personal-library test split now also feeds the owner's on-device test catalog (36 held-out PDFs, selection
  recorded by the lead's agent): keep `splits.json` stable.

**Astra to the lead, 2026-10-28 — source ready; encrypted candidate rejected.** Both readers need rebuilding when the fallback fix is integrated.
- Source: `codex/device-pdf-focus-20261028` (`414f85fa` fallback; series through `54389882`); 908 backend tests pass on base `a1dd1a0e`.
- At merge assign device-port **and arXiv-renderer** revisions from current main + 1, rebuild both compilers/identities, then run `npm test`; its freshness guard currently stops this source-only branch. Provenance is byte-identical.
- Plain fallback removes 93 raw-LaTeX labels in the 600-formula fixture; old bundles and accepted equations remain valid.
- Lean cache passes CPU 20 crops / 741 tokens across three schedules and stateless export, but encrypted decoder loading hit **≥1,543,913,472 / 762,544,128 bytes = 2.0247× RSS**; stopped before candidate predictions or timing. No new model pack qualifies.
- Next encryption work must address decoder loading memory. Selected weights, production runtime/exporter and release requirements are unchanged by this work.
- Isolated CropBox negative control: current **13/13**, old **1/13**; the ordinary 98-glyph fixture is identical in both. Reports/source are under `geometry/` in the canonical evidence tree.
- Archived 9.32 GB to the desktop with exact hash verification; local evidence is about 4.41 GB. This session's extra Mac worktree is retired; unrelated older branches remain untouched.
- Rejected-text inventory is exact (4,973/61,166); correctness still needs source review. The single [training log](../training/device_pdf/README.md#2026-10-28--lead-focus-list) records paths, limits, the stratified audit plan and the missing 0.01-vs-0.3-point rationale; next training needs a paired no-new-label control and multiple seeds.

**Release state, 2026-10-28:** TestFlight 94 reships the exact model pack that TestFlight 93 shipped (already public,
plaintext); any new pack still requires the encryption qualification (JUDGMENT_LOG). New models ship together once the
recogniser qualifies encrypted.

**For Astra — the reship mode and one host change in your area (lead's agent, 2026-10-28; JUDGMENT_LOG 56).** Upload
scripts changed: they now have a second mode beside the encryption gate.
- `RESHIP_DEVICE_PACK=<full version>` (→ `device-models.mjs --reship-pack`, `check-device-model-pack.mjs --reship-pack`)
  copies a pack from `apps/apple/device-models-shipped.json`, byte for byte, from that build's archive, and skips the
  signed encryption check. Only 93's `28f6fd14e8be` is recorded.
- **Every new pack still needs `--require-encryption` plus a passing `verify-coreml-encryption.mjs` report.** Your
  encrypted pack ships through the normal path. Don't add packs to the record: an entry means "already public".
- `rejectUnprotectedModelCopies` takes an optional `allowPlaintext` that accepts only those recorded trees.

`DevicePDFModels.tag` changed for packs **without** the tagger reference only (`readLegacyTaggerOutput`): after the
retry, a still-invalid line reads as prose and is counted (`tagger_unread_lines` in the summary), instead of failing
the reading. The reason: on 93's v4 pack, today's strict host failed 2 of 6 papers, where 93 had silently read zero
buffers as prose. Packs with the reference keep your recovery-or-fail policy, and the recovery code is untouched.
Evidence: `.artifacts/reship94/evidence.json`; DEVICE_PDF_ROUTE.md "Reshipping TestFlight 93's pack".

**Test catalogs (lead's agent, 2026-10-28; JUDGMENT_LOG 57; [TEST_CATALOGS](architecture/TEST_CATALOGS.md)).** Staff
see Settings › Experimental › Import a folder as a test catalog: the folder's PDFs are added on the device into a
catalog named after it and read by the on-device model one at a time (sealed queue, resumes after relaunch). The
paper's own reading and the queue now share `startDeviceModelRun` (DeviceModelReading.swift); a queue run holds
`deviceModelRun`, so a reader's new reading waits for Pause. UI journeys use `--device-model-fake-reading` (no Core ML).
The owner's folder is `~/Desktop/Gradstep neuroscience test PDFs/` (36 test-split PDFs, seed 20261028,
`scripts/select-test-pdfs.py`): **Astra, keep these 36 files out of any training or tuning** (listed by SHA-256 in its
`selection.json`). Not yet in a TestFlight build; the real model has not read them on a device.

**Landing page, 2026-10-27:** published at `https://gradstep.ai` as Pages deployment `e631ca58`.
Use `web/site/`; the duplicate redesign folder is retired. [Landing record](proposals/LANDING_PAGE.md) contains
verification and privacy corrections. Both reading PDFs are under `output/pdf/`. Website publication does not
resolve the native model-encryption blocker below.

**Current on-device PDF work, 2026-10-26/27:** start with
[training/device_pdf/README.md](../training/device_pdf/README.md), the single current progress log and ranked backlog.
It summarizes the older experiments so they need not be rediscovered. Core training is in this repo; GPU work uses
`192.168.1.32:/home/ben/science-reader-training`, separate from the older dirty checkout. Port 20 removes 4,973 rejected
transcription exposures; port 21 reduces confirmed neighboring-line intrusions **25→6** in 61 journal crops, with
zero own-ink changes and all 60 cleaner controls passing. Both preserve recognition and source locations across
101 recorded PDFs. Native reliability now adds one independent CPU evaluation of the same tagger weights after
two invalid Core ML buffers; valid outputs and thrown-model-error behavior are unchanged. The paired quiet/load
experiment recorded six retry exhaustions, three each for FP16/FP32; FP32 showed no reliability gain. All 2,029
real inputs recover under injected persistent failure with zero 0.65-threshold changes versus frozen PyTorch.
The 31 focused Swift checks, `npm test` and two fresh native imports / 22 pages pass. Those imports needed zero
recoveries and preserve text, equation decisions and PDF places; they are not a whole-import reliability estimate.
The earlier opaque read-stage error remains unattributed. Model weights remain v5b-journal / layout-v5 / TexTeller-v4;
the pack adds the hash-bound reference implementation. No native app/model-pack release or physical-phone verification occurred.
The subsequent span study is complete and merged as `acd565ce`: expanded labels and a whole-expression objective
improved completeness on the 468-expression development benchmark, but both failed original-corpus recall preservation.
Production weights remain unchanged and the final reserved cohort is unscored. Next, diagnose those retention losses;
do not repeat or widen the rejected experiment. Apple model-encryption setup is merged as `0eb82b00`, but complete
encrypted-pack qualification remains blocked; website publication is separate. The current log links the exact gates.
Evidence is in `.artifacts/device-pdf-development`; use `crops/scored` and `protection/final`,
not superseded attempts; `reliability/native-check.json` and `reliability/reference/policy-check.json` are the current
runtime gates. Do not repeat the known-negative FP32, layout or recognizer runs summarized in the log.
Earlier dated reviews below remain historical evidence; do not create another competing current PDF handoff.

**Earlier checkpoint, 2026-10-26: PDF preview merged as a standalone commit.** At the owner's request the two
feature commits from `codex/pdf-peek-fullscreen-20261025` are squashed into one commit on `main`, including these
status updates. Application/test code is unchanged from the audited work; routine `npm test` is the merge check.
The completed worktree and branch are retired, with compact evidence preserved in `.artifacts/pdf-peek-complete/`
and reachable through `.artifacts/pdf-peek-evidence`. The main desktop handoff remains in `.artifacts/pdf-peek-handoff/`.
No deployment or TestFlight release occurred. Other tasks' worktrees and branches are outside this cleanup.

**Follow-up quality task merged into local main as a separate commit:** converter port 16 prevents missing mathematical operators from
being overlooked by low-confidence glyph verification. Two real dropped-integral cases now use the original
PDF crop; the incomplete spans themselves remain a model/layout gap. The new check is a separate commit from
`09e71c2f`. Across 93 recorded PDFs it retains 98.90–99.64% of previously typeset equations in each corpus,
with 333 new crops and no new typeset promotions. Text, identities and PDF regions are unchanged.
`npm test`, 28 focused tests and Apple JavaScriptCore replay (including JIT disabled) pass. No model weights or
release changed. [Review and next concrete model experiment](reviews/DEVICE_PDF_MATH_INTEGRITY_20261026.md).
Inputs, reports and visual evidence are preserved under the main checkout's `.artifacts/device-pdf-quality-20261026/`.
The completed quality worktree and branch are retired after preserving that evidence.

The PDF preview request is implemented: one simultaneous two-finger single tap opens a full-screen PDF at the
passage under the fingers, zooming for 350 ms with the figure explainer's violet outline immediately fading over
one second. X or a top-row swipe returns to the unchanged reader. Native PDF pan/pinch remains; the existing
one-finger double tap still opens Contents. The toolbar uses selection/viewport, which can differ from the last
finger tap. Existing converter-provenance selection/equation menu actions remain unchanged.

**All 18 distinct native checks are verified per iPhone/iPad Simulator.** The phone full matrix passed 18/18;
the tablet passed 17/18 before a test expectation was corrected (its toolbar correctly addressed page 3 rather
than the earlier finger tap's page 2). That affected journey then passed on both devices, including header swipe.
No application code changed for that rerun. `npm test` passes all ten steps; browser snapshot checks pass at
390/1024 px. [Exact runs, screenshots and limits](reviews/PDF_PEEK_NATIVE_20261025.md).

The matcher remains on-device lexical retrieval, with encrypted originals and exact-version device acquisition.
Its broad desktop corpus has automatic labels, not human gold. Physical iPhone work remains paused; no NAS, paid
service, GPU training or deployment occurred. The HTML-first cutover is already verified. The discarded old
multi-destination Xcode job was terminated and confirmed gone. Native runners have exited; no corpus/download
job is intended to remain running. Use the sequential Simulator runner in TESTING, not multiple destinations in
one Xcode invocation. Mac Catalyst and physical-device interaction remain unverified here.

**Earlier checkpoint, 2026-10-17 ~04:36 UTC (Oct 16 PDT):** The owner's new build-64 screenshot shows VLA-Δ
2610.21306v1 with **Code: invalid**. **Cause now reproduced:** Swift 6.3 `-O` loses `index` when returning
`(index, try await acquire(...))` from a task inside `do/catch`; successful downloads all overwrite slot zero.
The final guard finds empty slots. Debug passes. Standalone no-network reproduction confirms it. The native
host now awaits bytes before constructing the tuple; new ten-image regression fails before and passes after.
Cached native replay of Rubric/ManiFusion/MetaShare passes with `-O` too. Complete native Library verification
with `-O` and whole-module compilation passes for all four papers: VLA-Δ 8.71 s; the original three together
21.74 s, including encrypted installation and reopening. Native reader suite five passes / one live-DPO skip;
`npm test` passes. Build 65 from **940e574** uploaded for iOS at 04:30:19 UTC and Mac at 04:33:15 UTC;
**Both are VALID / IN_BETA_TESTING as of 04:35:57 UTC.** No physical phone access or
paid AI. Reader repair is shipped with the reproduced before/after evidence; owner acceptance is still open.
Flash remains hidden pending the existing account-privacy confirmation. Full cause/evidence in
[owner feedback](OWNER_FEEDBACK.md) and `.artifacts/feedback/20261017-invalid/`.

**Earlier investigation, ~04:00 UTC, superseded above:** The owner installed **64 and reports the same failure** for
MetaShare, ManiFusion and Rubric Judgments. They are rightly upset that a new build was shipped before the root
cause was established. Prioritize this investigation. No reader fix or root cause has been established. Do not
ship another proposed fix based on a passing Simulator replay or speculative memory/timeout explanation.
The follow-up `LibraryModelTests.testReportedPapersDownloadInstallAndOpenThroughTheLibrary` covers real URLSession
downloads started together, encrypted installation and reopening: all three pass in 22.6 seconds. Uploaded build
64 and the Simulator carry identical compiler bytes. Test log: `library-live-investigation.log` in the feedback
artifact directory. This still does not reproduce the phone's environment/state. The existing ⓘ code is requested
asynchronously and unanswered. No newer ASC screenshot or in-app report was available. Build 64's new logging is
only active in a manually started local test session, not automatic remote diagnostics. No product change/release
in this follow-up; physical-phone access remains paused. See [feedback](OWNER_FEEDBACK.md) and
`.artifacts/feedback/20261017-current/`.

The owner funded another $10 for the selected **Gemini Flash** rollout. Migration 085 and `chat` are now deployed
**hidden**, with the former research key reassigned to `OPENROUTER_CHAT_API_KEY` only and its $20 lifetime limit
unchanged. Focused live checks cost **$0.108185933**, leave **$10.205283699**, and have **zero unknown holds**.
Do not restart broad research or paid watchers. The symbol-explanation check found and fixed a 2,000-token cap
that left no room for Flash reasoning: 6,000 now, 11 symbols delivered; malformed JSON is neither shown nor charged.
Titles/suggestions still fail against Anthropic's empty balance, without failing Flash answers.

**Not the default yet.** Chrome access was denied by Computer Use. An asynchronous question asks the owner to
confirm OpenRouter **Private Input & Output Logging** and **OpenRouter Use of Inputs/Outputs** are off. Keep hidden
until checked; routing already denies training endpoints and response caching. Browser Pages `d3b06988`, admin `04ecd963` and privacy site `ace695d9` are deployed and verified. TestFlight 64
iPhone/iPad and Mac are both VALID / IN_BETA_TESTING, confirmed at 03:39 UTC.
Source `428a608` (plus the preceding `345d35b` integration); see `.artifacts/flash-rollout-20261017/`. Then enable
`chat_gemini: "on"`, deploy chat and read back the published recommendation. [Contract and exact evidence](architecture/GEMINI_FLASH_CHAT.md).

The research balances and deployment states below are historical checkpoints, superseded by the current entry.

**Release checkpoint, 2026-10-16:** Codex recovered the active Claude session after its weekly quota
ran out. The build-62 feedback branches are merged and verified on main (`505d661` client source). Browser
Pages **`836089d4`** is live and its assets verified. **TestFlight 63 iOS and Mac are VALID / IN_BETA_TESTING**,
confirmed at **20:05 UTC**. See the
latest [implementation status](IMPLEMENTATION_STATUS.md#claude-takeover-and-build-63-release--2026-10-16-2000-utc)
for final processing evidence. The merged iPhone Simulator run is 22 pass / 2 tablet-only skips / 0 failures;
fast suite and browser UX captures pass. Physical phone remains paused.

The owner's active research request is **intelligence per dollar**, including Chinese providers; maintenance
cost is not an exclusion criterion. OpenRouter and up to **$25 including grading** were explicitly approved in
the recovered conversation. All 27 questions and five exact-source hashes are now in `tests/model-bakeoff/`.
**Funded screening completed, ~21:25 UTC:** the same 12 questions ran on 13 usable settings (plus 12 policy
refusals from DeepSeek's own endpoint). Argon high graded all 151 completed responses; Sol high independently
checked 21 answers across three questions. Read the [measured results](reviews/MODEL_COMPARISON_RESULTS_20261016.md)
and [protocol](reviews/MODEL_COMPARISON_20261016.md). **Gemini Flash is the provisional next-validation lead;
the default remains Sonnet.** Haiku high scored well, but the second judge and a direct check found a real
algebra error missed by the primary judge. DeepSeek/Qwen misread a plotted series; MiMo added false mathematical
and resource-accounting claims. Scores alone are not the decision.

**Finalist continuation, ~23:15 UTC:** Haiku medium, Gemini Flash medium and Luna high each ran the remaining
15 questions, giving 27 attempts each. Haiku/Gemini have 27 written answers; Luna has 24, with three unanswered
native-table image requests. The new claim-review rubric is separate from the original grader. Only four new
questions received independent grading; two graders passed six short calibration checks each, and Codex checked
central source claims and disagreements. These are agent checks, not exhaustive human labels. Read the
[finalist report](reviews/MODEL_COMPARISON_FINALISTS_20261016.md) before making a default decision.

Recorded charges are **$9.6865303832**, **$0 unresolved**, leaving **$0.3134696168** of the $10 funded credit.
All five old interrupted calls now have authoritative generation costs ($0.03395231 in total). The first-screen
ledger reconciled to account/key usage at 22:50 UTC. The aggregate is again delayed after the extension; use the
larger local ledger, not the lower account reading, for admission. The existing $25 approval and $20 key limit
are unchanged. The request to fund the remaining $15 is pending; no automatic top-up or watcher is running.
Further planned paid spend is $0 until funding is confirmed. Remaining work: 11 independent question reviews,
second-judge disagreements, repeated critical cases, higher-end Chinese candidates and deployed-adapter/
figure-explainer validation. The local harness retains an $18 maximum and a current $10 funded cap.

The original archive `docs/reviews/model-comparison-20261016/` is immutable. Updated non-secret evidence is in
`docs/reviews/model-comparison-finalists-20261016/`; the comparison viewer rebuilds from it without credentials.
Do not alter questions or references after paid answers; record corrections as source-review annotations.
The local spend ledger retains unknown charges across restarts. Check
`.artifacts/bakeoff/paid-run.lock` before any paid continuation. The two old Claude credit watchers were stopped.
Staging Anthropic's pending figure-detail live check is separate from OpenRouter funding. Physical phone remains paused.

The checkpoints below are historical; do not use their release numbers or balances as current.

**Historical checkpoint, 2026-10-14 PDT:** HTML-first reader and **Agent v2** are deployed on staging. Read
[Implementation status](IMPLEMENTATION_STATUS.md#agent-v2-on-staging--2026-10-14-deployed), the
[chat contract](architecture/CHAT.md#agent-v2-2026-10-14-numbered-context-grounded-citations-follow-ups) and
[HTML-first architecture](architecture/HTML_FIRST_READER.md). Migration **059** (follow-up ceiling in the chat quote)
is applied (additive; the pre-migration backup attempt exceeded its time limit, so the newest complete checkpoint
is still 2026-10-09); the `chat` function carries numbered local context v2, grounded `[¶N]` citations and forced Haiku
follow-up suggestions; browser Pages `6cb0d781` and admin `91c1eb33` are deployed; native **build 31 is VALID for iOS and Mac**
(owner acceptance open; build 30 remains IN_BETA_TESTING). Three paid live smokes on staging
verified citations that resolve and three follow-ups per answer ($0.28 of provider spend; disposable accounts
deleted). The repository review of 2026-10-13 (arXiv pacing, shared preparation, Go to passage across renderer
revisions, deleted PDF/Mathpix code) shipped in the same release. Commits: `7233641` (cutover), `dc040a9` (review),
and the Agent v2 commit that follows this checkpoint.

**Later that night (owner's TestFlight screenshots on builds 33–36):** the author block now covers every LaTeXML shape seen
and takes the library's names for logo-only authors (commit `c2ad885`, build 37), and **private episodes are made from
the paper's own text on the device** (migrations 066–067, `podcast?action=source` + `device_source` on the quote,
worker 00040, both clients; live proof ready in 85 s; commits `f508315` and the records commit after it; build 38 iOS
and Mac VALID; Pages `e7764deb`). Private generation paused once at the $0.75 quality allocation during the proofs;
the allocation is $2.00 (policy revision 10). See `docs/OWNER_FEEDBACK.md` "TestFlight screenshots, 2026-10-14".

**Night, 2026-10-14 (owner testing build 35):** three chat reports — the authors list on all surfaces, "Back to where
you were" missing after a reference or figure, and the chat snapping down while an answer streams — are handled in
commit `beba14c` (browser Pages `943836e8`, TestFlight build 36 iOS VALID and Mac uploaded, 16:31–16:34 PDT): the arXiv compiler's `authorsBlock` and shared author rules on both surfaces, bridge
hardening for Back's lifetime (the regression itself did not reproduce: see `docs/OWNER_FEEDBACK.md` row 2 and the new
native journey `testHTMLPaperInPageLinksOfferBack`), and end-only transcript following on both clients. Deployment
(browser Pages, TestFlight build 36) is recorded in `docs/IMPLEMENTATION_STATUS.md` ("Owner reports … night"). If the
owner still reports a missing Back on build 36, ask for the paper's arXiv id and the exact link tapped.

**Later on 2026-10-14 (owner awake and testing build 31):** the owner reported legacy library papers not opening and
new papers failing with "Couldn't open this paper". Commit `c615af3` opens legacy arXiv items through the on-device
HTML reader on every surface (server bundle as fallback, reasons and actions instead of a silent dead end, "Opens
from arXiv" in the library) and makes the compiler tolerate LaTeXML markers, inline graphics, TikZ pictures and
tables in list items with a closing note (the owner's nine papers replay 18/18; pinned corpus 16/16; DeepSeek-V2 is
now supported). Commit `ffbdcac` adds the Mac self-capture path and the
[iPad/Mac audit](reviews/IPAD_MAC_AUDIT_20261014.md). Browser Pages **`4fdd4675`** carries both; TestFlight **build 32**
(iOS and Mac) carries the native side: both uploads succeeded at 08:21 and 08:2x PDT; the first was VALID on App Store
Connect when this was written, the second still processing. Owner acceptance of builds 31 and 32 is open. Reproduce a compile problem with
`READER_CORPUS_SET=<set> node scripts/fetch-reader-corpus.mjs --on-this-device --update-lock` then
`READER_CORPUS_SET=<set> npm run test:slow:corpus -- --project=chromium` ([TESTING.md](TESTING.md)).

**Midday 2026-10-14 (commit `bafae2d` and the commits after it):** the Study tutor (experimental; server, browser,
native), the cost-audit fixes with migration **060** (budget periods, health check, zero-cost failed answers, the
stale sweep at zero, the sync fence code), the native sync scheduler and sync copy by code, the podcast UX pass and
the offline fixture. Status and evidence in
[Implementation status](IMPLEMENTATION_STATUS.md#study-tutor-audit-fixes-native-sync-scheduler--2026-10-14-midday-commit-bafae2d-and-after-deployment-noted-below);
migrations **060 and 061** are applied, chat function **123** and Pages **`0a4c0f85`** are live, the podcast pass
(`78e1ba4`) is merged, and **TestFlight build 34** (iOS and Mac) is uploaded (iOS VALID at 10:23 PDT; Mac processing
when this was written). Owner acceptance of builds 31 to 34 is open. One incident to know: function 118's smaller hold estimate paused all paid
work on staging for eleven minutes (a per-attempt ceiling overrun); 121 restored the margin and the switch was set
back on at the same limit ([SPENDING_CONTROLS.md](architecture/SPENDING_CONTROLS.md#budget-periods-failed-answers-and-the-stale-hold-sweep--2026-10-14-migration-060-staging)).
Exercise the tutor on staging with `node scripts/chat-live-smoke.mjs --study` (paid, about $0.30; verified 17:05 UTC).
Podcasts (owner report, afternoon): migration **062** and the podcast functions are deployed with the script-repair
route and the version-3 profiles (policy revision 6); a device-read paper now says why it has no episode source. No
generation has run through the repair yet: October's seed allowance ($0.58 of $3.00 left) fits no profile ceiling,
so the first live check is either the owner trying a pre-cutover paper from the app or an owner-approved allowance
increase followed by `podcast-ops.py seed --actor <OWNER> --approval c6c381f5-2b9e-445c-af03-045e7810a245` (the
CoTrace paper whose seed failed on 2026-10-09) and `kick`.
**DeepSeek (owner: "set up DeepSeek, prove it works with podcasts", afternoon):** migration **063** applied, the
`podcast` and `podcast-member` functions redeployed, pipeline worker revision **00034** (with `DEEPSEEK_API_KEY`
pinned; **00037** is current), migration **064** (version-5 profiles with larger output caps), the policy on the
version-5 profiles (revision 8: DeepSeek V4 Pro writes the script; maxima 140/150/300/520 credits), browser Pages
**`9b227fa2`** (quote handling no longer pinned to the Anthropic label and 150 credits). October's seed allowance was
raised from $3 to $4 for the proof seeds; the fourth (`fe9e26d4`) published release `c7a9a3e4`, pending the owner's
seed review (`podcast-ops.py review --release c7a9a3e4 --publish|--reject`). Then the owner asked for a **writer
choice**: migration **065**, the podcast function, Pages **`c4737d77`** and policy revision 9 (both writers for every
length, DeepSeek default) are live; the native picker is in **TestFlight build 35** (iOS and Mac, uploaded 12:53 and
12:57 PDT). Owner acceptance of builds 31 to 35 is open. Details in
[Implementation status](IMPLEMENTATION_STATUS.md). Flip back with `podcast-ops.py policy --set
profile_version=3 --set allowed_profiles=<the :3 list>` if DeepSeek disappoints.

**Build 31 screenshots (2026-10-14 15:34 UTC):** tiny figure, missing Back after in-page citation links, poor streaming
scroll; fixed in the compiler, the shared bridge and the native flush cadence (the scroll fix needs the owner's eye),
shipped as Pages **`7bbf4a45`** and TestFlight build 33 (uploading when this was written). The credit-system and
sync-reliability audits are in [docs/reviews/COST_CREDITS_AND_SYNC_AUDIT_20261014.md](reviews/COST_CREDITS_AND_SYNC_AUDIT_20261014.md)
(17 ranked gaps with sizes; none acted on yet; suggested order at the end).

**Before the next build:** run `node scripts/ux-review.mjs` and the native visual capture and read the sheets
([UX_REVIEW.md](UX_REVIEW.md)); after chat prompt or function changes, one `node scripts/chat-live-smoke.mjs
--questions=2` run (paid, about $0.25). The owner's next request is an exploration, not code: a learning-guide
product extension (tailored ML concept teaching with a persistent learner state, a figure "guide" mode and an
optional quiz); the proposal lives in `docs/proposals/LEARNING_GUIDE.md`.

**Test policy and new baseline:** `npm test` is fast (~10 s); slow browser/corpus/Simulator/database/hosted checks
are explicit and reused until relevant changes or a problem warrant rerunning. Read [TESTING.md](TESTING.md).
Eight local PDFs / 278 pages pass browser intake and native encrypted reopen/render. Six of eight HTML sources
render on all three engines; KAN v1 hits the pixel limit and DeepSeek-V2 v1 has a source conversion error, both
recorded as unavailable, not ready. Firefox sign-in previously waited indefinitely for optional storage permission;
the nonblocking fix is deployed in `a3127547`, with 4 new fast regressions and all 8 Firefox PDF journeys passing.
Full baseline: fast 848 tests; authored browser 13 pass / 3 skips; corpus 40 pass / 8 skips; native 8 pass.
All skips are the existing WebKit account-key capability gate; compiler and authored PDF worker still run there.

**Figure fix:** screenshot paper `2610.10478v1` reproduced and fixed (multiple captions plus MuPDF SVG glyph
metadata). Sidebar paper `2610.12978v1` also fixed (inline SVG legends and MathML backgrounds). V2
renderer/provenance retains v1 reading support. Both plus the original corpus pass all three browser engines;
both papers also pass hosted reader/selection checks, with figures and legends visually inspected and zero broken
images, PDF/artifact requests or provider spending. TestFlight build 30 is VALID and IN_BETA_TESTING on both platforms.

Do not revive old PDF downloads, upload sessions, OCR, conversion retries or PDF workflow corpora. Historical
records remain; no legacy migration/deletion was requested. The future local PDF model is not implemented.
Browser PDF bytes remain in the selected device file/tab and must be chosen again after reopening; encrypted
membership/history persist. Durable browser offline bundles remain a later gate. Native stores are encrypted
and excluded from backup. Physical iPhone work remains paused.

Provider spending is $20.744201 / $25, reserved/liability zero; the $100 total budget is unchanged and October
overhead evidence is missing. No NAS or TextBrain changes were made. The complete checkout is verified at `192.168.1.32:/home/ben/science-reader-html-20261013` (1,172 source files plus Git history, refreshed after the integration-test and Firefox permission fix). The earlier checkout is preserved; no credentials, dependencies, build artifacts or processing service were transferred.

The last deployment handoff is [HANDOFF_20261007.md](HANDOFF_20261007.md), beginning with its
**Current takeover checkpoint — 2026-10-08 UTC** section. Read that section, the
[implementation status](IMPLEMENTATION_STATUS.md), [owner feedback](OWNER_FEEDBACK.md)
and [project instructions](../AGENTS.md) before continuing.

The October 5 handoff previously stored here is historical and remains in git history.
Its deployment instructions, old budget, next-build number and open purchase diagnosis
must not be used as current state. The longer current handoff also labels its retained
historical sections explicitly.
