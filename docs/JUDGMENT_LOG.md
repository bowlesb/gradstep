# Judgment log

Owner, 2026-10-25: "Just make a good judgment and keep a log." Calls the lead or an agent made on the owner's behalf,
newest first. Each says what was decided, why, and how to undo it. Formal entries stay in [DECISIONS.md](DECISIONS.md);
this is the one place to skim and overrule. Say "undo N" (or describe the change) to reverse any of them.

## 2026-10-25

27. **Paper AI Explainer: "Go deeper" on each key concept** (owner, TestFlight 93: "an option … to request more
    elaboration on each concept, and then another screen in front. Then when we swipe away we get the entire overview
    behind"). Each Key concept gets a "Go deeper ›" that opens a card in front: the concept explained in this paper's
    context (what it is, why the paper needs it, an intuition or small example, where it appears with ¶ links), one AI
    call at the explainer's usual price, kept with the explanation so reopening is free; swipe down returns to the
    overview. The header becomes compact (title, paper and model on two short lines) so the overview starts higher.
    *Undo:* remove the button; the overview is unchanged.
31. **The For you List has no group headings** (owner, TestFlight 92: "Like papers you added not needed"): the papers
    keep the order by why (each tag's papers, papers like yours, authors, popular, category, something different: the
    Why sort's order) and each card's why line is now the server's whole sentence ("In your tag: RLHF", "Because you
    added “…”"), since no heading says it. What the headings' ⓘs said moved to **Feed ⋯ › About For you** (the ⓘ
    bubble, at the ⋯ button; offered where papers say why, not for a category). *Why ⋯ rather than an ⓘ beside the
    For you chip:* nothing on screen moves or is added; on an iPhone the chip row has no room for an ⓘ without pushing
    "More topics" under the edge fade. The Table keeps its Why column and its ⓘ. *Undo:* the headings (and their ⓘs)
    from the commit before this one, or an ⓘ beside the chip instead of the menu row.

28. **A failed import without the Progress column puts its problem in that column's words and a mini Retry in its
    title's second line** ("⚠ Download failed · Retry"; VoiceOver reads the full sentence), so it keeps a ready row's
    height too, as 17 does for an adding paper (whose line keeps its "Why does this take a minute?" ⓘ). *Why:* one line
    on an iPhone fits the short words and the mini capsule; the sentence truncated after "Couldn't downlo…" and the
    small capsule would touch the title. *Undo:* the sentence and the small capsule.
29. **The List layout keeps its content-sized rows** (checked, not changed). With the same details an adding row is
    128 pt and the ready row 108 pt on an iPhone: its "Adding…" line goes when it's ready. A List row shows the whole
    title, the authors and the abstract, so it can't reserve one height as the table does. *Alternative (not built):*
    the step at the start of the details line ("◌ Adding… · 2024 · arXiv v1"), so becoming ready removes no line.
30. **The double-tap journey was out of date, not the app** (`PaperToolsTests/testDoubleTapOpensContentsDeepInThePaper…`,
    failing since TestFlight 91): its "dismissing" tap landed on the selected word itself, which on iOS only hides the
    word's menu (the word stays selected; a second tap brings the menu back), and two taps on or beside a selection
    adjust it rather than open Contents (the build-78 rule). The step now dismisses with a tap on the paragraph's first
    words and double-taps there; Contents opens on iPhone and iPad. Why it passed on 2026-10-21 wasn't established.
    *Undo:* nothing to undo in the app (test-only).

22. **Global search keeps its sealed index on the device after sign-out** (cleared from memory and screen; removed
    with the account), like the encrypted chat store and the Library's index. The ML paper search cache is deleted at
    sign-out. *Undo:* delete the index at sign-out (a full rebuild, a few seconds, at the next sign-in).
23. **Search typo correction** picks the closest word, then the most common; words under 4 letters are never
    corrected; "No exact matches · showing attention" says so.
24. **Search results show the "100% · full text" strength only on papers**; other kinds show just the excerpt.
25. **A chat is found once**, by its first question, unless it has a generated or renamed title; snippets collapse to
    one row per collection with "+N more", like chats per conversation.
26. **Paper excerpts read LaTeX as math in the Library's own search too** (shared tokenizer), so Library excerpts change
    slightly.

18. **When Gemini Flash fails before writing anything, Claude Haiku 5.5 answers instead, labelled** ("by Claude Haiku
    5.5", and "Switching to Claude Haiku 5.5…" while it happens). Same zero-retention Google endpoint and terms, same
    consent; the reader pays only for the answer they got, never above the hold. *Why:* Gemini on that endpoint
    answered 81 % of calls in the last day (Haiku 37/37, p90 2.7 s). It relaxes the 2026-10-18 "no silent fallback" rule
    only in being automatic; it is never silent. *Undo:* `chat_fallback: "off"` in infra and redeploy `chat`.
19. **Flash stays on the US zero-retention endpoint for a week, watched by the new model-health check.** If it is still
    under 90 % by 2026-11-01, move it to Google's global zero-retention endpoint (88.5 % up, 9 % cheaper, may process
    outside the US; the privacy page doesn't promise US processing), and consider the priority endpoint (99.9 %, 1.64×
    price) only if that degrades too. *Undo / change:* the route in `chat-profiles.ts`.
20. **Figure explainers keep Gemini Flash as the default** (it cites about three times as many paragraphs as Haiku);
    the fallback covers its failures. *Undo:* make Haiku the figures default (faster, about one-sixth the cost).
21. **Built (migration 0162 and the pipeline worker; local, not applied or deployed):** an attempt that received no
    output and still has no OpenRouter record after its 12 reconciliation tries settles at zero automatically, counted
    in Health, `budget.health` and Spending so an unexpected bill would stand out. Only a clean 404 counts as "no
    record" (a lapsed key or an outage never does); an attempt with output, a record ever read, another caller or an
    open operation stays manual; a late record corrects it. Three such attempts hold $0.39 today (they settle at their
    12th try, 10-28/29, once deployed). One caveat: they predate first-output recording, so "no output" for them means
    none was recorded; the 10-24 one is a stream that broke after 38.5 s. *Why:* they need manual work otherwise and
    OpenRouter can't bill a generation it has no record of. *Undo:* stop the worker calling
    `worker_openrouter_reconcile_absent` ([PROVIDER_SPENDING.md](architecture/PROVIDER_SPENDING.md#assumed-zero-no-output-and-no-openrouter-record-migration-0162-2026-10-25-local-not-applied)).

13. **Global search: the bar is Library · Paper · Chat · More, with 🔍 beside it** (iPhone, and iPad windows too narrow
    for six). Feed, Snippets and Settings move under More. *Why:* the app opens to the Library, Paper ↔ Chat is the
    reading loop (about 25 code routes land there against 2 for Feed), and those three get the most owner feedback.
    *Cost:* Feed (For you) becomes two taps. *Undo:* swap Feed for Chat in the bar
    ([proposal](proposals/GLOBAL_SEARCH_AND_MORE.md) A.2 alternative).
14. **iPad upright keeps all six places plus 🔍 when they fit** (730 pt and wider); narrower windows use the iPhone bar.
    *Why:* honours the owner's 2026-10-24 iPad bar decision; there is room. *Undo:* use the four-item bar everywhere.
15. **Settings lives only under More on iPhone** (out of the ⋯ menus). *Why:* one place for it, as on iPad.
    *Undo:* put the ⋯ entries back.
16. **Tapping 🔍 brings the keyboard up at once.** *Why:* the search screen's only job is typing; Slack and Apple's
    apps do the same. *Undo:* wait for a tap in the field.
17. **A paper being added keeps its row height even with the Progress column hidden:** the spinner and one-word status
    sit in the title's reserved second line, so an adding paper's title shows on one line until it's ready. *Why:* the
    owner's no-jumping-rows rule (builds 58–59). *Undo:* the status line goes back under the title. Built after
    TestFlight 93: 64 pt adding and ready with Tags alone (was 82 and 64), a 20 pt spinner (was 14).

Earlier today (agent or lead calls, already in DECISIONS.md; listed here so they can be overruled in one place):

1. **Flash answers ordinary questions at low effort** (medium for reasoning questions or Detailed). Faster first words
   (about 2–12 s against a 9.5 s median). Not yet compared for answer quality. *Undo:* `geminiEffort` in
   `chat-profiles.ts`.
2. **Gemini stays pinned to Google's zero-retention US route** although it is the slow part. Moving off it is a privacy
   trade-off for the owner; the reliability agent is measuring alternatives.
3. **A silent model is cut off after 60 s** (was over 2 minutes) and the reader sees "Still waiting for the model…"
   after 12 s.
4. **Google sign-in failures show a one-line reference** under the error so a screenshot is enough to diagnose.
5. **Usage rows from before build 93 find their chat by time** (a message within 30 s, same paper preferred).
6. **AI usage ranges are Day · Week · Month · Year**; Day is the last 24 hours; the 90-day option is gone.
7. **Download your assets leaves out breakdowns whose paper isn't on this device** (rather than notes without
   pictures), and says so in the ⓘ.
8. **"Filter + related" is strict:** a paper joins when it uses the tag's words, or is very close to two tagged papers.
9. **List rows show the same tags as the table** (instead of arXiv areas).
10. **Rows numbered separately inside one aligned block are separate centred equations** (their = signs don't line up
    across numbers).
11. **The Feed's kept page also shows at once when a chip is tapped online**, and a Feed that failed offline asks again
    by itself when the network returns (free).
12. **Interest-index download limits raised** to 10,000 / 5,000 an hour for the environment (expected cost $0) so 1,000
    readers opening the app in the same hour aren't refused.
