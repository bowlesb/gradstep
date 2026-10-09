# Owner feedback log

TestFlight screenshot feedback is read from App Store Connect (`betaFeedbackScreenshotSubmissions`; screenshots are
saved under `.artifacts/feedback/`, which is not committed). Each item gets a plan and is closed with the build that
fixes it. “In build 19/20” below means the reviewed change is included in both internal iOS/Mac TestFlight builds,
confirmed VALID / IN_BETA_TESTING on 2026-10-08 UTC; it does not claim the owner has installed or accepted it.
Sources `b4b7ad7` / `bd2e0f2`; release evidence `.artifacts/takeover-20261008/build-{19,20}-processing.json`.
Build **21** (`c10e54c`) now supersedes both and is VALID / IN_BETA_TESTING for iOS and Mac. It retains every
fix below and adds clearer reader download-limit, interrupted-download and update-required messages;
35 focused native tests pass. Evidence: `.artifacts/takeover-20261008/build-21-processing.json`.

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
| — | Podcasts ("build the notebook LM podcasts feature") | Feed "Listen", paper "Listen", player | Per [PAPER_PODCASTS.md](architecture/PAPER_PODCASTS.md); owner approved the v2 profile rollout, review-gated catalog and private generation | Live on staging in revision `gradstep-pipeline-00027-9mv`: two reviewed shared episodes are published; Short / 5 / 10 / 20-minute profiles are enabled with revised server caps; the October catalog period is `$3` / 10 episodes and operator-seeded, review-gated. Two post-rollout candidates were stopped before speech by the evidence/quality gate. Owner-device acceptance and a clean post-cutover scheduler check remain. |
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
