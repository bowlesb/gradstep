# Agent handoff

**Current takeover checkpoint, 2026-10-16:** Codex recovered the active Claude session after its weekly quota
ran out. The build-62 feedback branches are merged and verified on main (`505d661` client source). Browser
Pages **`836089d4`** is live and its assets verified. **TestFlight 63 iOS and Mac are VALID / IN_BETA_TESTING**,
confirmed at **20:05 UTC**. See the
latest [implementation status](IMPLEMENTATION_STATUS.md#claude-takeover-and-build-63-release--2026-10-16-2000-utc)
for final processing evidence. The merged iPhone Simulator run is 22 pass / 2 tablet-only skips / 0 failures;
fast suite and browser UX captures pass. Physical phone remains paused.

The owner's active research request is **intelligence per dollar**, including Chinese providers; maintenance
cost is not an exclusion criterion. OpenRouter and up to **$25 including grading** were explicitly approved in
the recovered conversation. All 27 questions and five exact-source hashes are now in `tests/model-bakeoff/`.
The harness was corrected and passes dry construction, but **OpenRouter still has $0 credit and no inference
has run**. Keep the default unchanged. Read the [comparison protocol](reviews/MODEL_COMPARISON_20261016.md)
before any paid run: $18 local admission cap, existing $20 provider key limit, durable holds, no silent retries,
start with the small smoke matrix. The two old Claude credit watchers were stopped. No automatic work remains
running on their behalf. Staging Anthropic's pending figure-detail live check is separate from OpenRouter funding.

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
