# Owner feedback log

TestFlight screenshot feedback is read from App Store Connect (`betaFeedbackScreenshotSubmissions`; screenshots are
saved under `.artifacts/feedback/`, which is not committed). Each item gets a plan and is closed with the build that
fixes it.

## Build 14, 2026-10-07 (iPhone, 11 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "What happened here" | Reader: the paper's own table of contents renders as one run-on paragraph ("Contents 1 Introduction ..... 1 2 …") | Detect dot-leader contents blocks and show them as a list, one entry per line | Done after build 14 (bridge, no re-render): one entry per line, indented by depth, pages right-aligned and muted; entries that match a heading or run-in head jump there with Back (DLV: 35 of 40). Only the 5 real lists in 48 conversions change; verified in the iPhone Simulator, light and dark ([details](architecture/READER_RENDERER.md#the-papers-own-contents)) |
| 2 | "The reference isn't working" | Reader: `[Gelfond and Lifschitz 1991]`, `[Lobo et al. 1992; Eiter et al. 1997b]` (bracketed, no comma before the year) | Check the new author–year linking against this paper; add the form if missing | Done after build 14: build 14 predates the author–year links (3 of 209 in this paper linked); the current bridge links 210 of 210, no wrong link. Added small-capital spellings ("AND", "ET AL."); `[Cadoli et al. 1997]` fits two entries and stays plain. Verified in the iPhone Simulator |
| 3 | "Formulas should be selectable in chats the same way as papers … copy at least" | Chat answers: formulas are images | Long-press/right-click on a formula: Copy LaTeX, Copy as text, and the selection actions | Fixed on branch (next build; chat answers) |
| 4 | "Ask a question is bad language, you can just have chat" | Chat composer placeholder | Placeholder "Chat" | Open |
| 5 | "Space below chat box not well used … the paper vs general option needs to be in a menu … can't take away screen real estate for chatting" | Chat screen: the Paper chat / General chat segmented row; gap under the composer | Move the switch into the chat title menu; tighten the composer to the tab bar | Open |
| 6 | "The icon choice is bad it looks like a refresh icon, it probably needs to have lines in it" | Chat: the All chats button (clock-arrow) | A list icon with lines | Open |
| 7 | "A really good table view should be the default, sort by recently, added, length, paper or general, topics" | All chats | Table landed after build 14 (sort by last used / started / messages / paper, filter paper/general); topics come with tags. Also: chat titles show prompt prefixes and raw LaTeX ("Explain in plain terms…: \[\begin{equation*}") → shown as "Explain · Attention(Q, K, V)…", "Add paper · [3] T. D. Lee…" in All chats and the chat title (display only) | Titles done, pending next build; topics with tags |
| 8 | "The account option tells me nothing, sync? Sign out and delete … should be hidden away? What does appearance mean to the user?" | Settings | Account row opens an Account page (email, sign-in methods, sync state in words, Sign out, Delete account); "Appearance" becomes "Theme: Light / Dark / Match device" | Done, pending next build (Sync now moved to the Account page) |
| 9 | "This doesn't look like it should be there, seems cool" | Settings → Acknowledgements | Move under an About page with version and privacy | Done, pending next build ("About Gradstep", last row; "readable versions of papers", not "readers") |
| 10 | "Trying to select some chat text to reference it … it just says copy" | Chat answers: text selection offers only Copy | Selection in answers offers Ask about this (quotes it into the composer), Explain, Define, Copy | Fixed on branch (next build; chat answers) |
| 11 | "Why is it Answer: … seems not needed" | Chat answers start with a bold "Answer:" label | Tell the model not to label the answer; strip a leading "Answer:" label on display | Fixed on branch (next build; needs chat deploy for the instruction) |

Also seen in the screenshots: `**$n = 0$:**` shows literal asterisks (bold around math isn't parsed) — chat
renderer fix, with #3/#10.
