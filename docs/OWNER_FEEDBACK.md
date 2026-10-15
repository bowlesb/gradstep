# Owner feedback log

TestFlight screenshot feedback is read from App Store Connect (`betaFeedbackScreenshotSubmissions`; screenshots are
saved under `.artifacts/feedback/`, which is not committed). Each item gets a plan and is closed with the build that
fixes it. “In build 19/20” below means the reviewed change is included in both internal iOS/Mac TestFlight builds,
confirmed VALID / IN_BETA_TESTING on 2026-10-08 UTC; it does not claim the owner has installed or accepted it.
Sources `b4b7ad7` / `bd2e0f2`; release evidence `.artifacts/takeover-20261008/build-{19,20}-processing.json`.
Build **21** (`c10e54c`) now supersedes both and is VALID / IN_BETA_TESTING for iOS and Mac. It retains every
fix below and adds clearer reader download-limit, interrupted-download and update-required messages;
35 focused native tests pass. Evidence: `.artifacts/takeover-20261008/build-21-processing.json`.

## Chat report, 2026-10-15 (build 38): imports stuck at "Finding", podcast lifecycle, Contents for older PDFs, "do I have this paper on this device?"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The import of PDFs appears to be broken?" (screenshot: three arXiv imports at "Finding 15% · Under a minute", one "Waiting") | Library, imports added 2026-10-15 ~00:28 UTC | Every import failed at the metadata stage with `source_unavailable` and was retried on backoff (failures 1→5). Not the network and not the evening's worker deploy: the worker run locally failed the same way, and the new failure diagnostics named it: the OAI-PMH `GetRecord` request timed out (60 s) at `oaipmh.arxiv.org`, while the Atom API answered. The worker built the identifier with `URLSearchParams`, which percent-encodes the colons (`oai%3AarXiv.org%3A2610.15166`); arXiv's OAI server stopped answering that form today and answers the literal form in 0.25 s. The URL is now built with literal colons (`arxivURLs`); the metadata stage's failure log carries the endpoint and status or failure name from now on. The row copy already turns into "Waiting for arXiv · retrying" and "Taking longer than usual" after the first failures; "Under a minute" stays only for the first attempt. | Fixed; worker and `paper-worker` redeployed (recorded in IMPLEMENTATION_STATUS.md); the three imports complete on their next retry |
| 2 | "How does it work when you create a podcast? Is it handled asynchronously… Is the tracking managed even if you closed the app?" | Listen | Yes on both. Start reserves the credits and queues a job on the server; the pipeline worker writes, checks, voices and publishes it (one to three minutes) whether or not the app is open. The app polls while the Listen sheet is open; closing the app or the sheet changes nothing on the server. Reopening Listen on that paper finds the running job (the paper lookup returns it) and resumes progress; a finished episode is simply there. The browser also keeps the request identity so a Start whose reply was lost is reconciled. What is missing: a place that lists *your* episodes being made and ready across papers, and a notice when one finishes — proposed below. | Answered; "Your episodes" list and a completion notice proposed (not built) |
| 3 | "Table of contents still not rendering for me for older PDFs" | Paper read as a PDF kept on this device | The Contents sheet showed the HTML reader's headings, which a PDF never has, so it was empty (or stale). The PDF viewer now has its own Contents from the PDF's outline (bookmarks), tapping an entry goes to its page; a PDF without an outline says so and why. Papers with a converted server copy keep their Contents (every legacy bundle checked has 12–60 headings). | Built (build 39) |
| 4 | "synced devices might have different PDFs stored right, should we make it more obvious whether you do or do not have a pdf on a device? … we allow you to do things that require a paper and we haven't even told the user that there is no paper" | Library rows; Chat, Study, Listen | Yes. One model, written down (HTML_FIRST_READER.md "Paper availability on a device"): on this device (prepared HTML; reads offline; chat, Study and Listen have its text), PDF on this device (reads as a PDF; no structured text yet), not on this device yet (opens from arXiv when online), no readable copy. Library rows now show it as a small symbol before the byline (VoiceOver and Mac tooltip say the words); the browser says "Opens from arXiv; prepared in this browser when opened" or "Reads from the server's converted copy". Listen's refusal for a paper not prepared here says "Open this paper first so its text is ready on this device", and for a PDF that it has no structured text. | Built (build 39, browser); owner acceptance open |

## TestFlight screenshots, 2026-10-14 (builds 33–36; submitted 15:43, 17:46–17:47 and 23:37–23:38 UTC)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Poor layout table contents" (15:43 UTC, PhysCodeGym 2610.17288) · "Still a gross author presentation" (23:37 UTC, PRISM 2610.14704) | Reader header of HTML papers | LaTeXML author blocks come in several shapes the first author-block renderer (same night) did not cover: one "Affiliation:" contact per author (the label was printed and the affiliations ran together with the names), e-mail inside an affiliation, a project page link glued to an institution, several "thanks:" daggers per author. The compiler now drops contact labels and e-mail, numbers per-author affiliations in order ("Chenghao Yue¹, Peiyan Li¹, Hao Wang² … ¹Tsinghua University · ²Dalian University of Technology"), puts a project page on its own line and each dagger note on its own line; verified on all four reported papers plus DPO (`.artifacts/back-repro/authors-check.mjs`). | Built 2026-10-14 night (commit `c2ad885`); compiler tests 17/17, browser compiler journey; browser Pages `fa19e107`; TestFlight build 37 iOS and Mac VALID (and 38). Owner acceptance open |
| 2 | "What is this Tram business and where is the correct info" (LoongSage 2610.16352: the header read "Team") | Reader header | The author is a team logo image followed by " Team"; the graphic is left out of running text, so only "Team" remained. Both apps now pass the library's author names into the device compiler, which uses them when a name was a graphic or no name was found ("LoongSage Team"); the same names on every device of a library give the same bundle. | Built (`c2ad885`); compiler test; Pages `fa19e107`, TestFlight 37 and 38. Owner acceptance open |
| 3 | "What's going on here?" on "Listening needs this paper in your synced library." and "This is dysfunctional on many levels: we should have stopped storing PDFs at all on the server is that not the case? And the message is also very off putting…" on "Episodes are made from a server copy of the paper…" | Listen on a paper read on this device | The server keeps no PDFs; it still has the text it converted for older papers, which is all Listen could use. The wording implied stored PDFs and gave no way forward. Interim copy: "Episodes can't be made for this paper yet. Listening still works from the text the server converted for older papers; making episodes from the paper on this device is being built." / "…it isn't in your synced library. Add it to your library, then try again." The real fix — private episodes written from the paper's own text on this device — is designed in PAPER_PODCASTS.md ("Episodes from the paper on this device") and built next (migration 066). | Copy in build 37; device-text episodes built and deployed the same night (migrations 066–067, `podcast` function, worker 00040, Pages `e7764deb`, both clients; PAPER_PODCASTS.md "Episodes from the paper on this device"); live proof on staging ready in 85 s for 31 credits; TestFlight **build 38** iOS and Mac VALID. Owner acceptance open |
| 4 | "Refresh episodes what does that mean ??" | Listen filter's ⋯ menu | Pull-to-refresh already reloads the catalog; the menu row now reads "Check for new episodes". | In builds 37 and 38 |
| 5 | "The scrolling experience is poor both when new text is coming and when the text is done" (15:36 UTC, build 31) | Chat transcript | "When new text is coming": 453d6ed slowed the flush cadence for long answers and the night's end-only following stops the snap-back (row 3 of the chat reports below). "When the text is done": the finished answer is re-rendered once (Markdown and math) and the transcript keeps the reader's place through it (anchors) when they are not at the end; no further change identified without a screen recording — the owner's "Report this screen" with a recording would pin it. | Partly addressed (builds 32, 36); recording requested |
| 6 | "The figure is tiny" · "The back to where you were feature is gone" (15:34 UTC, build 31) | Reader | Handled in 453d6ed (build 32) and the night's Back hardening (build 36); see the build-31 section and the chat reports below. | Builds 32 and 36 |

## Chat reports, 2026-10-14 (night): the authors list, "Back to where you were", scrolling while an answer streams

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "make sure that the authors list is presented nicely on all surfaces" | Reader header of HTML papers; library rows and columns, feed rows and cards, podcast cards and player, pending imports (native and browser) | The arXiv HTML compiler emitted LaTeXML's author block as it came: every affiliation mark twice with a "footnotemark:" label and its tag, "thanks:" notes inline, e-mail addresses. It now renders each name once with its marks ("Rafael Rafailov<sup>2,†</sup>, Archit Sharma<sup>1,2</sup>"), then the affiliations ("<sup>2</sup>Stanford University · <sup>3</sup>CZ Biohub") and the notes ("<sup>†</sup> Equal contribution…") on their own lines; links to those notes still resolve (verified on the DPO paper, arXiv 2305.18290, device-compiled). Rows and columns on both surfaces use one rule (one author: the full name; up to three family names; then "+N"; native had shown two names, the browser three surnames split on the last word), cards and the player's "Paper by" line show full names up to six then "+N" (native had listed twelve), bylines read "Vaswani et al." on both (the browser had shown the full first name). The native paper list and pending-import rows no longer print the raw joined string. | Built 2026-10-14 night; compiler tests 15/15, browser units, native `LibraryMetadataTests`; Browser Pages `943836e8` live 2026-10-14 16:29 PDT; TestFlight **build 36**: iOS VALID (uploaded 16:31 PDT), Mac uploaded 16:34 PDT (processing when written). Owner acceptance open. |
| 2 | "the 'Back to where you were' … no longer is there (all surfaces)" | Reader, after a citation, figure or section link | Not reproduced: the shared bridge still offers Back for every in-page link. New evidence: an iPhone Simulator journey on the HTML fixture (`ReaderNavigationTests/testHTMLPaperInPageLinksOfferBack`: the "[1]" citation and the "Figure 1" link both offer Back, Back returns) passes; the browser journey passes with the chat pane open (Back in view in the toolbar); a headless-WebKit harness on the real DPO paper (device-compiled) jumps with Back for bibliography, figure and section links by mouse and by touch. Two weaknesses that could hide Back on a real device were removed: the jump's landing place was fixed after 1.5 s even mid-scroll, so a long smooth scroll on a slow device then counted as "two screens away" and ended Back at once; and programmatic scrolls (a restore, a refit) could end it. Now the landing waits for the page to stop (up to 6 s), and Back outlives only the reader's own wheel, touch or key scrolling. If build 36 still shows no Back, the report needed is the paper (arXiv id) and the link tapped. | Built 2026-10-14 night; native journey, browser journey and harness as described; Browser Pages `943836e8` live 2026-10-14 16:29 PDT; TestFlight **build 36**: iOS VALID (uploaded 16:31 PDT), Mac uploaded 16:34 PDT (processing when written). Owner acceptance open. |
| 3 | "when the text is coming out (streaming) in chat, and I try to scroll up … it won't let me stay where I am (all surfaces)" | Chat transcript, both surfaces | Both clients re-followed the latest text whenever the reader was within 80 px/pt of the end, so a small scroll up (a trackpad tick, a short swipe) was snapped back by the next flush. The reader's own scroll now follows only at the end itself (2 px/pt): any scroll away stays put until they return to the end or tap "Latest message" / "Latest", and the transcript's own scrolls (following, "Latest") are never read as the reader's. | Built 2026-10-14 night; browser unit `chat-follow`, browser chat journeys, native `WorkflowJourneyTests/testChatKeepsLatestVisibleAsComposerGrowsAndKeyboardDismisses`; Browser Pages `943836e8` live 2026-10-14 16:29 PDT; TestFlight **build 36** (iOS VALID 16:31 PDT, Mac uploaded 16:34 PDT). Owner acceptance open. |

## Chat report, 2026-10-14 (evening): the podcast starts with "So the motivation is computational, but…"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "thats not a sane start to a podcast" | The owner's first DeepSeek episode (job `4ce016b9`) | The checker had removed seven of 28 turns: four for Markdown and inline-math wrappers in the spoken text (the voices cannot read them) and three as unanswered questions, among them the opening turn, so the episode began on the reply. Three fixes in the worker: readable markup is stripped and the turn kept; the writer must open with a plain welcome that names the paper and never ends on a question, and close the same way; a check that passes but leaves the opener removed or a reply orphaned runs the repair pass, and refuses the episode where no repair call exists. The word band was then widened once more (80%–125% of the writer's range) after a 930-word draft failed a 920 ceiling by ten words. | Deployed (worker 00039); verified on seed `8dd7ac8f` (release `9e90fb77`, 5 min 55 s, 24 turns, none removed): opens "Welcome to Gradstep. Today we are looking at…" |

## Chat request, 2026-10-14 (evening): "expose an option when creating a podcast to use anthropic or sonnet"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | A writer choice at podcast creation: Anthropic (Sonnet) or DeepSeek | Listen sheet (native), podcast dialog (browser) | Migration 065: a length may be offered under more than one allowed profile version, one per writer; `podcast_lengths()` lists each length's writers (default first, each with its own maximum, estimate and consent version); the quote takes a `writer` and resolves the matching version, so the providers and consent named in the quote follow the choice. Native: a "Written by" segmented control above the lengths (DeepSeek V4 Pro · lower cost, scripts vary more / Claude Sonnet 5.5 · steadier scripts), the lengths' maxima follow it and the length is quoted again. Browser: the same choice as radio buttons before the estimate. The policy offers both writers for all four lengths (revision 9; DeepSeek stays the default). | Server and browser live 2026-10-14 ~19:40 UTC (migration 065, podcast function, Pages `c4737d77`); native in TestFlight build 35 |

## Chat request, 2026-10-14 (afternoon): "Lets setup deep seek, prove it works with podcasts"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Set up DeepSeek and prove it with podcasts; hopefully more cost-effective | Podcast script writing (draft, review, repair) | A DeepSeek adapter beside the Anthropic one, chosen by the profile spec; migration 063 (provider, consent v2, version-4 profiles on DeepSeek V4 Pro at peak list prices); the worker and functions deployed; the browser quote handling unpinned. Script-stage ceilings fall from about $0.75 to about $0.40 per 5-minute episode; the maxima shown to readers fall from 180/200/360/610 to 140/150/280/500 credits. | Deployed 2026-10-14 (worker 00037, policy revision 8 on profiles v5, Pages `9b227fa2`); proven on the fourth seed `fe9e26d4` (5 min 35 s episode, release `c7a9a3e4` pending seed review) at $0.111 of script cost against about $0.35 on Sonnet; three earlier seeds failed and each taught a fix (trim repair, word-range tolerance, larger output caps with compact JSON) |

## Chat report, 2026-10-14 (afternoon): "I was not able to create a podcast at all"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Could not create a podcast | Listen, any paper added since the HTML-first cutover | Episodes are written from the server's converted (Mathpix) text, found through the legacy library item, its render artifact and its OCR run. Papers prepared on the device have none of those rows, so the app finds no podcast item and said "Listening needs this paper in your synced library", which was misleading. Staging confirms nothing reached the quote in 36 hours. Copy now says episodes are made from a server copy that device-read papers don't have yet. Making episodes from the device's numbered text is a design change (quote, pin and worker), written up before building. | Copy fixed in the working tree; the device-text design is open |
| 2 | Same, for papers that were in the library before the cutover | Generation | The last three jobs on staging (2026-10-09, two customer, one seed) all failed `script_evidence_rejected`: the reviewer accepted the script, the checker removed turns whose numbers were not in the evidence, and the rest fell under the length's word floor. Nothing was charged; about $0.35 of platform loss each. A bounded second draft (a `podcast_script_repair` route in profile v3) rewrites the removed turns from quoted evidence; migration 062 and the podcast functions are deployed and the policy points at the v3 profiles (maxima 180/200/360/610 credits). | Deployed 2026-10-14 18:11 UTC; a live replay waits for the owner (October's seed allowance has $0.58 of $3 left, which fits no ceiling) or for the owner to try a pre-cutover paper |

## Build 31, 2026-10-14 (iPhone, 3 items, TestFlight screenshots 15:34–15:36 UTC)

Screenshots: `.artifacts/feedback/build31/` (private, not committed). All three on the PhysCodeGym paper (2610.17288).

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The figure is tiny" | Reader, Figure 1 | LaTeXML wraps a centred graphic as `figure > p > span > img`; the adapter treated any graphic inside a figure paragraph as a legend symbol (`reader-inline-image`, 0.65 em tall). A paragraph that only wraps the graphic is now the figure's full-size image; a caption-only figure after an unwrapped graphic reads as that figure's caption. Regression test in `tests/backend/arxiv-html.test.ts`. | Shipped: Pages `7bbf4a45` and TestFlight build 33 (VALID for iOS and Mac at 08:57 PDT) |
| 2 | "The back to where you were feature is gone" | Reader, after following "[55]" to the bibliography | The reader bridge offered Back only for citations it parsed itself (Mathpix-era text marks); the arXiv HTML reader's own `<a href="#…">` links (citations, "Fig. 1", "Cited by: §1") navigated natively with no Back. The bridge now jumps and offers Back for every in-page link on both surfaces (browser journey asserts it). | Same |
| 3 | "The scrolling experience is poor both when new text is coming and when the text is done" | Chat, streaming answer | Each flush re-renders the whole answer so far (Markdown and math) every 50 ms; long answers churn the row and the scroll pin. Flushes now stretch from 50 ms to 400 ms as the answer grows. Not verified on a device: the remaining jump when the sealed answer, footer and follow-up chips replace the streaming row needs your eye on build 33; a tail-only streaming renderer is the next step if it still feels poor. | Partly built, in build 33; the end-of-answer jump needs the owner's eye on a device |

## Chat report, 2026-10-14 (build 31): library papers and new papers not opening

Owner (chat, not TestFlight): "papers that were already in my library don't work. Probably we need a better framing
of papers that are in library that have pdf downloaded vs not. Also I still see quite a few failures even for new
papers 'couldn't open this paper'."

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Papers already in the library don't work | Reader, legacy items (42 visible, all with a server bundle; the server said every one was available) | The device opened them only through the server bundle path, which could end silently on "Paper download needed" with no action. Legacy arXiv items now open through the on-device HTML reader like every other arXiv paper; the server bundle is the fallback; every refusal has a reason and an action. | Built 2026-10-14, native and browser; ships in build 32 and the next Pages deploy |
| 2 | Better framing of what is downloaded | Library rows and table | Rows say "Opens from arXiv" until a paper is prepared on this device, "Unavailable offline" for a blocked copy, "PDF on this device" for a PDF; "Reader unavailable" only for non-arXiv items without a server bundle | Same |
| 3 | "Couldn't open this paper" on new papers | Reader, nine papers added 2026-10-13/14 | Replayed offline: five of nine refused (conversion markers, inline graphics, TikZ pictures). The compiler now tolerates all three and notes what it left out; nine of nine compile ([HTML_FIRST_READER.md](architecture/HTML_FIRST_READER.md#compiler-tolerance-and-legacy-items--2026-10-14-owner-report-quite-a-few-couldnt-open-this-paper)) | Same; browser replay evidence in IMPLEMENTATION_STATUS.md |

## Purchase credits, 2026-10-07 (TestFlight build 13; observed Sandbox path repaired)

Report `APgSDbWf0gMbTamRckWVdHs`, submitted 08:09 PDT, says:
“We should never be in a situation where credits were added but they can’t use them”.
The screenshot shows **17 credits available** and the purchase alert:
“Your purchase went through, but we couldn’t add the credits yet. The app will try again automatically.”
The owner reported the same failed-credit experience again during the Codex takeover.

**Resolved on staging for the observed Sandbox credit-pack purchases; production remains unverified.** This is TestFlight feedback, not an in-app
support report. The screenshot was downloaded and inspected; its private local copy is
`.artifacts/feedback/credits-APgSDbWf0gMbTamRckWVdHs.png`. The generic alert does not identify
which verification/recording step failed. Eight `invalid` server outcomes surround that attempt;
staging had recorded no App Store transactions. A separately reviewed diagnostic-only deployment
(`store-sync` v36,17:50 PDT) proved the hosted runtime lacks certificate operations required by
Apple's library. [Evidence and repair boundary](reviews/PURCHASE_DIAGNOSTICS_HOTFIX_20261007.md).
The private Node verifier and migrations 033–038 were subsequently deployed with signature/revocation checks intact.
Read-only takeover verification on 2026-10-08 05:14 UTC found three Sandbox credit-pack transactions with actual
grants totaling 1,000 credits: 400 + 400 + 200. The last is a partial grant under the 1,000-credit monthly Sandbox
allowance, not a verification failure. Replayed reports returned `already_recorded`; six app verifier attempts
succeeded. Evidence: `.artifacts/takeover-20261008/{purchase_grants,purchase_observations,sandbox_decisions}.json`.
Build 19 adds actual-granted-credit and Sandbox allowance wording; a real tester review of that new copy remains.
Receipt recording and credits granted remain distinct states; this evidence does not verify production subscriptions, renewals or refunds.

The owner reproduced the same symptom after those three grants. Read-only staging ledger evidence on 2026-10-09 shows
the later Sandbox pack and Standard subscription receipts were recorded, but each received **0 credits because the
account's October Sandbox allowance was already exhausted**; no receipt was lost. Migration `056` and the deployed
`store-sync` now add the finite `sandbox_monthly_cap` reason to that final response, so the purchase sheet explains
the TestFlight limit and does not imply that a paid transaction disappeared. The allowance remains bounded;
production purchases have no Sandbox cap once the Production verification path is enabled. Build 26 is `VALID` for
iOS and Mac and also reports the reason when Restore Purchases returns an already-recorded receipt. A bounded owner-
only 400-credit tester top-up was recorded on staging under request
`cd4aac8a-3144-481f-abbe-b7844c0b7030` (490 available / 0 held after the grant); it does not change the Sandbox cap
or production purchase rules.

## Build 14, 2026-10-07 (iPhone, 11 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "What happened here" | Reader: the paper's own table of contents renders as one run-on paragraph ("Contents 1 Introduction ..... 1 2 …") | Detect dot-leader contents blocks and show them as a list, one entry per line | In build 15 (2026-10-07). Done after build 14 (bridge, no re-render): one entry per line, indented by depth, pages right-aligned and muted; entries that match a heading or run-in head jump there with Back (DLV: 35 of 40). Only the 5 real lists in 48 conversions change; verified in the iPhone Simulator, light and dark ([details](architecture/READER_RENDERER.md#the-papers-own-contents)) |
| 2 | "The reference isn't working" | Reader: `[Gelfond and Lifschitz 1991]`, `[Lobo et al. 1992; Eiter et al. 1997b]` (bracketed, no comma before the year) | Check the new author–year linking against this paper; add the form if missing | In build 15 (2026-10-07). Done after build 14: build 14 predates the author–year links (3 of 209 in this paper linked); the current bridge links 210 of 210, no wrong link. Added small-capital spellings ("AND", "ET AL."); `[Cadoli et al. 1997]` fits two entries and stays plain. Verified in the iPhone Simulator |
| 3 | "Formulas should be selectable in chats the same way as papers … copy at least" | Chat answers: formulas are images | Long-press/right-click on a formula: Copy LaTeX, Copy as text, and the selection actions | In build 15 (2026-10-07) |
| 4 | "Ask a question is bad language, you can just have chat" | Chat composer placeholder | Placeholder "Chat" | Done (merged from floating chrome): placeholder "Chat" |
| 5 | "Space below chat box not well used … the paper vs general option needs to be in a menu … can't take away screen real estate for chatting" | Chat screen: the Paper chat / General chat segmented row; gap under the composer | Move the switch into the chat title menu; tighten the composer to the tab bar | Done (merged from floating chrome): the switch is the chat title's menu (subtitle shows the paper or "General chat"); message box 10 pt above the floating tab bar, the conversation under both |
| 6 | "The icon choice is bad it looks like a refresh icon, it probably needs to have lines in it" | Chat: the All chats button (clock-arrow) | A list icon with lines | Done (merged from floating chrome): a list icon (bullets and lines, the first bullet amber) for All chats in the top bar and menus |
| 7 | "A really good table view should be the default, sort by recently, added, length, paper or general, topics" | All chats | Table landed after build 14 (sort by last used / started / messages / paper, filter paper/general); topics come with tags. Also: chat titles show prompt prefixes and raw LaTeX ("Explain in plain terms…: \[\begin{equation*}") → shown as "Explain · Attention(Q, K, V)…", "Add paper · [3] T. D. Lee…" in All chats and the chat title (display only) | Titles in build 15; configurable Topics, Kind and Answer length columns plus horizontal scrolling in build 19 |
| 8 | "The account option tells me nothing, sync? Sign out and delete … should be hidden away? What does appearance mean to the user?" | Settings | Account row opens an Account page (email, sign-in methods, sync state in words, Sign out, Delete account); "Appearance" becomes "Theme: Light / Dark / Match device" | In build 15 (2026-10-07); Sync now moved to the Account page |
| 9 | "This doesn't look like it should be there, seems cool" | Settings → Acknowledgements | Move under an About page with version and privacy | In build 15 (2026-10-07); "About Gradstep", last row, with "readable versions of papers" wording |
| 10 | "Trying to select some chat text to reference it … it just says copy" | Chat answers: text selection offers only Copy | Selection in answers offers Ask about this (quotes it into the composer), Explain, Define, Copy | In build 15 (2026-10-07) |
| 11 | "Why is it Answer: … seems not needed" | Chat answers start with a bold "Answer:" label | Tell the model not to label the answer; strip a leading "Answer:" label on display | Display cleanup in build 15; the chat function/model instruction was subsequently deployed |

Also seen in the screenshots: `**$n = 0$:**` shows literal asterisks (bold around math isn't parsed) — chat
renderer fix, with #3/#10.

## Build 15, 2026-10-07 (handoff follow-up)

| Owner feedback | Plan | Status |
|---|---|---|
| Offline library save fails on every launch, and downloads stop until relaunch | Version the decoded cache fields; repair only display metadata while preserving availability history | Shipped in build 16: format 3 and retained quarantine/identity checks; 211 Core tests, 321 iOS unit tests (5 opt-in skips), both encrypted relaunch journeys, and 298 Catalyst unit tests (4 opt-in skips) pass. See [Native offline bundles](architecture/NATIVE_OFFLINE_BUNDLES.md#build-14--15-cache-upgrade-2026-10-07-local-review) |
| Topic tags feel generic | Review feed-chip priority and tag vocabulary/prompt; estimate any re-tagging cost before running it | Pending; no paid re-tagging in this fix |
| Chat top is too cluttered | Recheck main's chat title-menu change on the current build before proposing another layout change | Pending owner-current-build comparison |
| More All chats columns / horizontal scrolling | Coordinate with the chat-quality workstream and its existing table changes | In build 19: chooser, pinned title/Last used, horizontal scrolling and retained per-device choices |
| Model / effort selection | Prepare UX and cost proposal before changing provider routing or prices | [Economics/profile proposal](research/PRICING_RECOMMENDATION_20261008.md) merged; no live model, allowance or price change |

## Build 16, 2026-10-07 evening (iPhone, 10 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "If I have credits now after adding new credits, ones should just start downloading if they were explicitly added before" | Library rows stuck on "Needs credits" | When credits arrive (purchase, restore, grant), resume the account's imports waiting on credits automatically, oldest first, within balance | On staging 2026-10-08 (migration 040 + worker): a sweep before each claim and a wakeup when a balance grows |
| 2 | "Recent articles should be shown first" | Library search › arXiv scope | Order arXiv results newest first (keep relevance as a tie-breaker or an option) | In build 19: Newest is the default; Relevance remains available |
| 3 | "So many criteria we could be adding as columns … choose which columns to show and also allow horizontal scrolling" | All chats table (and library table) | Column chooser + horizontal scrolling with the title column pinned | In build 19 across Library, Feed and All chats; chosen columns remain reachable, with per-device settings |
| 4 | "Make it more clear that we have the option to copy and reference in the chat box. When you click on equations in the paper itself we should see the same type of pop options" | Chat text/formula menu; paper equations | Same native menu for paper equations; clearer "Ask about this" | In build 19: paper equation/text edit menus and Quote in Chat wording; current selection is captured at action time |
| 5 | "The options are at the bottom, that's awkward; use the regular menu with Copy … with the extra options, make the options clear, 'Explain in Chat'" | Paper selection bar | Replace the bottom selection bar with the system edit menu: Copy + Explain in Chat / Why it matters / Related / Add paper | In build 19; equation menu dismissal clears only the matching selection |
| 6 | "Little options in the bottom right that make the text a little bigger and smaller" | Feed / reader | Small A− / A+ controls | In build 19 for Feed and reader; expanded-abstract-specific feedback below remains separate |
| 7 | "As a PDF is downloading, very briefly something appears for 5 ms right below Unread … the text flashes and all items move" | Library during a download | Remove the transient row/banner that shifts the list | In build 19: delayed overlay for background updates, preserving table geometry |
| 8 | "Is text streamed as it comes? It's too long before text starts coming" | Chat time-to-first-text (Related with web search) | Measure; show progress immediately; reduce latency before first token | Server part on staging 2026-10-08 (chat function): policy lookup overlaps the body read; action instructions after the paper's cache breakpoint; search results without citations so the prompt cache survives the search round |
| 9 | "Please remove Open and just put arXiv and it can link out" | Papers in this answer | Replace Open with the arXiv ID as a link; keep Add to library | In build 19; separate Library and website destinations follow in build 20 (see below) |
| 10 | "Ingestion failure" (arXiv 2207.00729 at "Finding 99% · Taking longer than usual") | Import metadata | Completed after 7 min: arXiv rate-limited the metadata lookup (`rate_limited`, backoff). Add a metadata fallback when arXiv throttles; don't show 99% while waiting | On staging 2026-10-08: arXivRaw (OAI-PMH) fallback when the Atom API throttles; a throttled source shows "waiting", not 99 % (migration 040 + worker) |

## Build 17, 2026-10-08 (iPhone, 3 items)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The Add is all greyed out?" | Feed Add buttons (also Retry, tags, archive) | Regression: when uploads went live (039, upload policy on) the app adopted the full-v5 library, and library writes were deliberately disabled in v5 until an epoch-checked write path existed. Fix: v5 command RPCs that check the dataset epoch in the same transaction (migration 042) and the app sending them; needs a new build. The disabled capsule is also too similar to the enabled one in dark mode | 042 applied and hosted zero-credit command journey passed; build 19 carries the native fix and darker enabled Add styling. iPhone/iPad Feed Add journeys pass; build 18 remains affected |
| 2 | "I still have these stray items that weren't properly ingested … self cleaning or fixing but never just sitting there" | Library: "arXiv 2610.07426 · Details unavailable · Retry", "Needs credits" rows, Failed 5 | Needs-credits rows now resume by themselves (040). Next: a server sweep that re-attempts transient failures with backoff and requeues stale claims; permanent failures show a plain reason and one action (migration 041). Retry itself was blocked by #1 | 040 and 041 on staging (see below) |
| 3 | "Table still sucks why are they're so few options" | Feed table (Title, Published, Add on phone) | Column chooser (topic, authors, updated, arXiv ID, abstract, in library, relevance), horizontal scroll with pinned title, more sorts and filters, as for the library and chats tables | In build 19: chooser, pinned title/Add, horizontal scrolling, additional supported fields, and Hide papers in my library. Expanded-title/abstract feedback below is not covered by this claim |

Also requested with this batch: a personalized feed ("relevant to a users interests … kept up to date and
changing but have cost under control"). Design and the reviewed zero-paid-API implementation are merged. Migration 043 is **applied with serving and refresh off**,
with For You as default and server-visible metadata use awaiting the owner's answer. No paid ranking is enabled.
[Feed plan](architecture/PERSONALIZED_FEED.md).

## Build 18, new screenshot feedback reviewed 2026-10-08 UTC

Root downloaded and inspected the five TestFlight screenshots. Metadata:
`.artifacts/takeover-20261008/latest-owner-feedback.json`; private local images:
`.artifacts/feedback/build18/<report-id>.png`. These reports arrived from build 18; distinguish a fix already
in 19 from the follow-up work started afterward.

| Report | Owner feedback / observed issue | Status and next action |
|---|---|---|
| `AGd2CKOBGtQ2_DixxpXTxxg` | “No if there’s room. Find a way to make horizontal scrolling a good UX pls” | Covered by build 19's chosen-column horizontal scrolling and pinned columns; owner acceptance remains. |
| `ALdL2H9qgXauIAihHJQz8J8` | Expanded Feed row should show the entire title and abstract, with abstract text-size control | In build 20: full expanded table title/abstract, A−/A+ retained, list expansion also available; long ending verified in light/dark and accessibility XL. |
| `AAWbg6g4dUfzp4mwU1x5u14` | “It looks like this is a bad UX please fix”; screenshot shows truncated expanded abstract | In build 20 + discover v78. The server's 700-character preview was the root cause; new clients opt into a bounded full abstract, preserve mathematical Unicode and label any actual excerpt. Hosted full source/Feed smoke passes. |
| `ABHWnLf34Hf5ty2J-F3Blv4` | Reference popover repeats the visible bibliography text; buttons/options are liked | In build 20: reference title and existing actions retained, duplicate body removed. Reference → actions → Copy → Back journey passes. |
| `AH_QWMX10xPbqz3-10h1WGk` | Ingested-paper links need explicit Library and arXiv website destinations; “Open” is vague | In build 20: visibly labeled Library button beside the external identifier link. Opens the current saved paper or pending import, including wide layout, and preserves the previous chat draft/history; model and UI regressions pass. |

## Build 21, 2026-10-08 (iPhone, 7 items) and today's goals

Screenshots: `.artifacts/feedback/2026-10-08T11-*.png`, `2026-10-08T13-19-34-487Z-0.png` (private, not committed).
Owner's goals for 2026-10-08, verbatim: "respond to new feedback, and build the notebook LM podcasts feature
please. One more thing, chats should have the abiltity to customize the length and effort nad model right there
in the chat in a cleer UX".

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "Each chat should have a labeled [title] on the topic of the chat in the same way that chat GPT does … embedded everywhere in the app" | All chats (titles like "Explain · L_task(θ) = -…") | A short topic title generated with the first answer, stored in the encrypted history and shown everywhere; renamable | Merged to main; native and browser journeys cover generated/displayed titles and encrypted history. Included in the current Build 24 candidate; owner-device acceptance remains. |
| 2 | "Machine learning and artificial intelligence are too generic it need to be specific to the individual tastes and their nuances" | Feed chips | "For you" first, then specific topics drawn from the reader's library and tags; broad categories under "More topics". Taken as the owner's yes to the pending For you / server-visible metadata decision | Merged; server (046) live on staging with serving off; the app side ships in the next build, then serving goes to staff |
| 3 | "Why not topics? And can we put a popularity score?" | Feed Columns sheet | Topics column (several specific tags) and a Popularity column and sort from free signals cached in the shared pool; "—" when unknown | Merged; Hugging Face upvotes filling the pool (27 of 825 on the first run); ships in the next build |
| 4 | "Reference at the top of the message isn't needed" | Reference popup ("Reference 84" header) | Remove the header | Merged to main 2026-10-08 (details below); ships in the next build |
| 5 | "Needs to be a discuss in chat button … takes you to the chat with the ref text in there and you can continue typing" | Reference popup | "Discuss in chat": opens the paper's chat with the reference quoted in the composer, unsent | Merged to main 2026-10-08 (details below); ships in the next build |
| 6 | "Brafman ref missed" | Citation links ("Brafman and Ten-nenholtz 2002", hyphenated across a line) | Citation matcher handles hyphenation and diacritics; regression fixture; link rate measured before/after | Merged to main 2026-10-08 (details below); ships in the next build |
| 7 | "When figures are referenced you should be able to link directly to them … and … a 'return to reading location' option in a sensible location" | Reader ("Fig. 1") | "Fig./Table/Algorithm N" become links that show the figure with "Go to figure"; one Back-to-where-you-were control for every jump | Merged to main 2026-10-08 (details below); ships in the next build |
| — | Podcasts ("build the notebook LM podcasts feature") | Feed "Listen", paper "Listen", player | Per [PAPER_PODCASTS.md](architecture/PAPER_PODCASTS.md); owner approved the v2 profile rollout, review-gated catalog and private generation | Live on staging in revision `gradstep-pipeline-00031-l5v`: two reviewed shared episodes are published; Short / 5 / 10 / 20-minute profiles are enabled with revised server caps; the October catalog period is `$3` / 10 episodes and operator-seeded, review-gated. Two post-rollout candidates were stopped before speech by the evidence/quality gate. The dialogue-completeness and substantive-repair prompt hardening is live; post-activation scheduler samples at 15:41 and 16:02 UTC recorded 16/16 and 15/15 HTTP 200 calls with zero provider cost. Owner-device acceptance remains. |
| — | Chat model / effort / length "right there in the chat" | Chat composer | A control showing the current choice with a live credit estimate and maximum; server-enforced, versioned profiles | Merged to main; native and browser controls, profile persistence and credit estimates are covered by unit/UI journeys. Included in the current Build 24 candidate; owner-device acceptance remains. |

| 8 | "Somehow I ended up with this please fix it bug report" (16:54 UTC) | Reader: tab bar and A−/A+ float ~170 pt up, page cut off, black below (keyboard-sized inset left behind) | Reproduce, fix the leftover keyboard inset at the root, regression UI test | Fixed 2026-10-08, verified in the Simulator only; ships in the next build once merged. Cause: Search in the find bar hides the keyboard and leaves the bar docked; UIKit reports the keyboard hidden with its frame still on screen, SwiftUI keeps that frame as a keyboard inset, and the tab bar was padded for the home indicator on top of it. The owner's page was not dimmed for find, so on the device the frame stayed after the bar had gone. Now the tab bar sits just above a docked find bar, and a frame left with nothing there is ignored. Covered by `PaperToolsTests` |

### Build 21 reader items in detail

Screenshots `.artifacts/feedback/small-2026-10-08T11-47-20-18Z-0.png`, `…T11-50-01-745Z-0.png`, `…T11-51-56-283Z-0.png` and
`…T13-19-34-487Z-0.png` (local, not committed). Reader bridge and native iOS/iPad only; no re-render, no deployment.
Decisions: [References, figure links and Back](DECISIONS.md#references-figure-links-and-back-owner-feedback-on-build-21-2026-10-08-agent-decisions-reversible);
measurements: [Reader renderer](architecture/READER_RENDERER.md#figure-table-and-algorithm-references).

| # | Owner said | Change | Status |
|---|---|---|---|
| 1 | "Reference at the top of the message isn't needed" | The reference actions have no title row | Merged to main; native and browser reference journeys pass. Included in the current Build 24 candidate; owner-device acceptance remains. |
| 2 | "Needs to be a discuss in chat button … you can continue typing" | **Discuss in chat**: this paper's chat, the entry quoted in the message box (`About “…”: `), keyboard up, nothing sent; a new conversation unless the paper's chat is still empty | Merged to main; native and browser journeys cover the quoted, unsent composer state. Included in Build 24; owner-device acceptance remains. |
| 3 | "Brafman ref missed" ("Brafman and Ten-nenholtz 2002" in a semicolon group) | Hyphenated (line-break, soft, Unicode) and accented surnames match on both sides | Merged to main with the measured matcher regression (2,579/2,603 links on the staging/local sample, 0 wrong links). Included in Build 24; owner-device acceptance remains. |
| 4 | "When figures are referenced you should be able to link directly to them … a 'return to reading location' option" | "Fig. 1", "Figure 3(b)", "Figs. 2 and 3", "Table 2", "Algorithm 1" link to the element whose caption prints the label; a tap shows it with its caption in a half-height sheet with Go to figure; **Back to where you were** after every jump, left of A− / A+, until Back, two screens away or a return by scrolling | Merged to main; native and browser figure/reference journeys pass, including the KWIK fixture and Back-to-reading state. Included in Build 24; owner-device acceptance remains. |

The browser reader gets the figure links through the shared bridge; its sheet, Discuss in chat and Back wording are
listed for the web owner in the renderer doc.

## Screenshot feedback audit, 2026-10-08

All 44 TestFlight screenshot reports (builds 13–21) were checked against this file and the code. Every report
is fixed, in a build, in progress, or listed here as a follow-up for the owner:

- **Build 15, "We need to improve the tags they can't be this generic …"**:
  - Feed chips and per-paper Topics are now specific (046).
  - Library tags themselves still come from the existing vocabulary.
  - Options: tune the keyword rules with a one-time Haiku labeling pass over the shared pool (≈$0.95, $1 cap; owner approval needed), or wait for the first real For you pool and judge.
- **Build 15, "The top looks too cluttered"** (chat screen):
  - The Paper/General switch moved into the chat title's menu after that build.
  - The composer is gaining a model/effort/length control.
  - Owner check: is the chat top acceptable on the current build?
- **Build 15, "What other good customizations will help?"**: proposals for the owner after the chat controls ship. Candidates:
  - answer style (intuitive / technical / step-by-step math);
  - web search on/off per chat;
  - citations of paper passages on/off;
  - default chat settings per paper type.
- **Builds 16–20:** the items shipped in 19/20 still await the owner's acceptance on device.

## Podcast seed pilot budget, 2026-10-08

After three failed attempts ($1.00 of $2 spent, no episode published), the owner approved **"Raise to $5 total"**. This historical pilot section is superseded by the v2 rollout recorded above.
- **Where:** inside the existing $25 provider cap.
- **Unchanged:** at most $0.75 per attempt and at most two published episodes.
- **Needs:** migration 051, because 048's check constraint caps a seed period at $2.
- **Status:** superseded and deployed through migrations `051`–`055`; the current catalog allowance is `$3` / 10 episodes and is operator-seeded and review-gated. The historical fix details remain in [Seed pilot fix 3](architecture/PAPER_PODCASTS.md#seed-pilot-fix-3-review-reasons-checker-v4-and-the-5-cap-2026-10-08).

## Podcasts, after the first two episodes (2026-10-09)

The owner liked the episodes ("I like it … lets keep going with this") and approved three next steps:
1. **Re-enable Short, 10 and 20 min** with revised maxima: Short ~140 credits, 10 min ~300, 20 min ~520. Google's
   speech service takes no output cap, so each call reserves the serving limit. Typical costs are unchanged.
2. **Smoother, fuller episodes:** no unanswered questions after the checker removes a turn, and 5-minute episodes
   that actually run about 5 minutes.
3. **A weekly curated catalog** on a **$3/month** allowance (about 10 episodes), inside the $25 provider cap.
   Episodes wait for the owner's review by default.
