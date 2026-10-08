# Owner feedback log

TestFlight screenshot feedback is read from App Store Connect (`betaFeedbackScreenshotSubmissions`; screenshots are
saved under `.artifacts/feedback/`, which is not committed). Each item gets a plan and is closed with the build that
fixes it.

## Purchase credits, 2026-10-07 (TestFlight build 13; still reported failing)

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
The tester-facing allowance explanation still needs review. Receipt recording and credits granted remain distinct
states; this evidence does not verify production subscriptions, renewals or refunds.

## Build 14, 2026-10-07 (iPhone, 11 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "What happened here" | Reader: the paper's own table of contents renders as one run-on paragraph ("Contents 1 Introduction ..... 1 2 …") | Detect dot-leader contents blocks and show them as a list, one entry per line | In build 15 (2026-10-07). Done after build 14 (bridge, no re-render): one entry per line, indented by depth, pages right-aligned and muted; entries that match a heading or run-in head jump there with Back (DLV: 35 of 40). Only the 5 real lists in 48 conversions change; verified in the iPhone Simulator, light and dark ([details](architecture/READER_RENDERER.md#the-papers-own-contents)) |
| 2 | "The reference isn't working" | Reader: `[Gelfond and Lifschitz 1991]`, `[Lobo et al. 1992; Eiter et al. 1997b]` (bracketed, no comma before the year) | Check the new author–year linking against this paper; add the form if missing | In build 15 (2026-10-07). Done after build 14: build 14 predates the author–year links (3 of 209 in this paper linked); the current bridge links 210 of 210, no wrong link. Added small-capital spellings ("AND", "ET AL."); `[Cadoli et al. 1997]` fits two entries and stays plain. Verified in the iPhone Simulator |
| 3 | "Formulas should be selectable in chats the same way as papers … copy at least" | Chat answers: formulas are images | Long-press/right-click on a formula: Copy LaTeX, Copy as text, and the selection actions | In build 15 (2026-10-07) |
| 4 | "Ask a question is bad language, you can just have chat" | Chat composer placeholder | Placeholder "Chat" | Done (merged from floating chrome): placeholder "Chat" |
| 5 | "Space below chat box not well used … the paper vs general option needs to be in a menu … can't take away screen real estate for chatting" | Chat screen: the Paper chat / General chat segmented row; gap under the composer | Move the switch into the chat title menu; tighten the composer to the tab bar | Done (merged from floating chrome): the switch is the chat title's menu (subtitle shows the paper or "General chat"); message box 10 pt above the floating tab bar, the conversation under both |
| 6 | "The icon choice is bad it looks like a refresh icon, it probably needs to have lines in it" | Chat: the All chats button (clock-arrow) | A list icon with lines | Done (merged from floating chrome): a list icon (bullets and lines, the first bullet amber) for All chats in the top bar and menus |
| 7 | "A really good table view should be the default, sort by recently, added, length, paper or general, topics" | All chats | Table landed after build 14 (sort by last used / started / messages / paper, filter paper/general); topics come with tags. Also: chat titles show prompt prefixes and raw LaTeX ("Explain in plain terms…: \[\begin{equation*}") → shown as "Explain · Attention(Q, K, V)…", "Add paper · [3] T. D. Lee…" in All chats and the chat title (display only) | Titles in build 15 (2026-10-07); topics with tags remain planned |
| 8 | "The account option tells me nothing, sync? Sign out and delete … should be hidden away? What does appearance mean to the user?" | Settings | Account row opens an Account page (email, sign-in methods, sync state in words, Sign out, Delete account); "Appearance" becomes "Theme: Light / Dark / Match device" | In build 15 (2026-10-07); Sync now moved to the Account page |
| 9 | "This doesn't look like it should be there, seems cool" | Settings → Acknowledgements | Move under an About page with version and privacy | In build 15 (2026-10-07); "About Gradstep", last row, with "readable versions of papers" wording |
| 10 | "Trying to select some chat text to reference it … it just says copy" | Chat answers: text selection offers only Copy | Selection in answers offers Ask about this (quotes it into the composer), Explain, Define, Copy | In build 15 (2026-10-07) |
| 11 | "Why is it Answer: … seems not needed" | Chat answers start with a bold "Answer:" label | Tell the model not to label the answer; strip a leading "Answer:" label on display | Display cleanup in build 15 (2026-10-07); the model instruction still needs the chat function deployed |

Also seen in the screenshots: `**$n = 0$:**` shows literal asterisks (bold around math isn't parsed) — chat
renderer fix, with #3/#10.

## Build 15, 2026-10-07 (handoff follow-up)

| Owner feedback | Plan | Status |
|---|---|---|
| Offline library save fails on every launch, and downloads stop until relaunch | Version the decoded cache fields; repair only display metadata while preserving availability history | Verified locally, not shipped: format 3 and retained quarantine/identity checks; 211 Core tests, 321 iOS unit tests (5 opt-in skips), both encrypted relaunch journeys, and 298 Catalyst unit tests (4 opt-in skips) pass. See [Native offline bundles](architecture/NATIVE_OFFLINE_BUNDLES.md#build-14--15-cache-upgrade-2026-10-07-local-review) |
| Topic tags feel generic | Review feed-chip priority and tag vocabulary/prompt; estimate any re-tagging cost before running it | Pending; no paid re-tagging in this fix |
| Chat top is too cluttered | Recheck main's chat title-menu change on the current build before proposing another layout change | Pending owner-current-build comparison |
| More All chats columns / horizontal scrolling | Coordinate with the chat-quality workstream and its existing table changes | Pending integration review |
| Model / effort selection | Prepare UX and cost proposal before changing provider routing or prices | Proposal only; owner approval still needed |

## Build 16, 2026-10-07 evening (iPhone, 10 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "If I have credits now after adding new credits, ones should just start downloading if they were explicitly added before" | Library rows stuck on "Needs credits" | When credits arrive (purchase, restore, grant), resume the account's imports waiting on credits automatically, oldest first, within balance | On staging 2026-10-08 (migration 040 + worker): a sweep before each claim and a wakeup when a balance grows |
| 2 | "Recent articles should be shown first" | Library search › arXiv scope | Order arXiv results newest first (keep relevance as a tie-breaker or an option) | Open |
| 3 | "So many criteria we could be adding as columns … choose which columns to show and also allow horizontal scrolling" | All chats table (and library table) | Column chooser + horizontal scrolling with the title column pinned | Open |
| 4 | "Make it more clear that we have the option to copy and reference in the chat box. When you click on equations in the paper itself we should see the same type of pop options" | Chat text/formula menu; paper equations | Same native menu for paper equations; clearer "Ask about this" | Open |
| 5 | "The options are at the bottom, that's awkward; use the regular menu with Copy … with the extra options, make the options clear, 'Explain in Chat'" | Paper selection bar | Replace the bottom selection bar with the system edit menu: Copy + Explain in Chat / Why it matters / Related / Add paper | Open |
| 6 | "Little options in the bottom right that make the text a little bigger and smaller" | Feed / reader | Small A− / A+ controls | Open |
| 7 | "As a PDF is downloading, very briefly something appears for 5 ms right below Unread … the text flashes and all items move" | Library during a download | Remove the transient row/banner that shifts the list | Open |
| 8 | "Is text streamed as it comes? It's too long before text starts coming" | Chat time-to-first-text (Related with web search) | Measure; show progress immediately; reduce latency before first token | Server part on staging 2026-10-08 (chat function): policy lookup overlaps the body read; action instructions after the paper's cache breakpoint; search results without citations so the prompt cache survives the search round |
| 9 | "Please remove Open and just put arXiv and it can link out" | Papers in this answer | Replace Open with the arXiv ID as a link; keep Add to library | Open |
| 10 | "Ingestion failure" (arXiv 2207.00729 at "Finding 99% · Taking longer than usual") | Import metadata | Completed after 7 min: arXiv rate-limited the metadata lookup (`rate_limited`, backoff). Add a metadata fallback when arXiv throttles; don't show 99% while waiting | On staging 2026-10-08: arXivRaw (OAI-PMH) fallback when the Atom API throttles; a throttled source shows "waiting", not 99 % (migration 040 + worker) |

## Build 17, 2026-10-08 (iPhone, 3 items)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The Add is all greyed out?" | Feed Add buttons (also Retry, tags, archive) | Regression: when uploads went live (039, upload policy on) the app adopted the full-v5 library, and library writes were deliberately disabled in v5 until an epoch-checked write path existed. Fix: v5 command RPCs that check the dataset epoch in the same transaction (migration 042) and the app sending them; needs a new build. The disabled capsule is also too similar to the enabled one in dark mode | 042 applied on staging after backup; native fix merged b993c23 and verified on iPhone/iPad fixtures. Build 18 stays disabled; next TestFlight build pending combined UX checks |
| 2 | "I still have these stray items that weren't properly ingested … self cleaning or fixing but never just sitting there" | Library: "arXiv 2610.07426 · Details unavailable · Retry", "Needs credits" rows, Failed 5 | Needs-credits rows now resume by themselves (040). Next: a server sweep that re-attempts transient failures with backoff and requeues stale claims; permanent failures show a plain reason and one action (migration 041). Retry itself was blocked by #1 | 040 and 041 on staging (see below) |
| 3 | "Table still sucks why are they're so few options" | Feed table (Title, Published, Add on phone) | Column chooser (topic, authors, updated, arXiv ID, abstract, in library, relevance), horizontal scroll with pinned title, more sorts and filters, as for the library and chats tables | In progress (UX batch) |

Also requested with this batch: a personalized feed ("relevant to a users interests … kept up to date and
changing but have cost under control"). Design and a zero-paid-API first version are in progress; any paid
ranking option comes back for approval with a cost table ([plan](architecture/PERSONALIZED_FEED.md) when written).
