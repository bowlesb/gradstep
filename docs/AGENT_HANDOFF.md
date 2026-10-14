# Agent handoff

**Current checkpoint, 2026-10-14 PDT:** HTML-first reader and **Agent v2** are deployed on staging. Read
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
