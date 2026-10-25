# Judgment log

Owner, 2026-10-25: "Just make a good judgment and keep a log." Calls the lead or an agent made on the owner's behalf,
newest first. Each says what was decided, why, and how to undo it. Formal entries stay in [DECISIONS.md](DECISIONS.md);
this is the one place to skim and overrule. Say "undo N" (or describe the change) to reverse any of them.

## 2026-10-25

27. **A figure printed before the Introduction reads after the paragraph that first cites it** (owner, TestFlight 92,
    WorldCast 2610.20731v2: "Is the Figure displayed in the right place"; reader revision 27, model readings port 15).
    The paper, its HTML and its PDF put Figures 1 and 2 between the abstract and "1 Introduction" (the foot of page 1,
    the top of page 2), so the phone showed two large figures, then the keywords, then the Introduction, whose second
    paragraph cites Figure 1. Now a figure or table between the title and the first section that the first section
    cites moves to just after the whole paragraph citing it (its displays and closing words included). Floats keep
    their numbered order: a later one written before the first section follows, to its own first citation or right
    behind the one before (WorldCast's uncited Figure 2 follows Figure 1); none passes a float of the body or reaches
    the references. Kept as written: a teaser the Introduction doesn't cite (DDPM's samples, cited in §4) and every
    float in the body (614 of 1,509 cited figures sit before their first citation, half within 500 characters, usually
    at the top of the section discussing them). The **keywords row sits right after the abstract**, before any figure
    kept there. The move changes no id (ids follow source order), so links, explanations, snippets and Show in PDF
    address the same figures. 186 cached papers: 21 change, 35 floats move (ViewCraft had all 11 before its
    Introduction), none refused; 4 of 76 recorded model readings change (venue papers with Figure 1 above the abstract). *Why:* on paper a float at the top of a page is
    seen beside the text that cites it; a phone has no page, so the nearest place is right after that text; a figure
    the opening doesn't cite is a visual abstract and keeps its place. *Undo:* drop the `floatsNearCitations` call
    (arxiv-html.ts) and `floatsNearMentions` (device-pdf/emit.ts) and bump both revisions; the keywords row's place is
    `paperTagsPlace` in reader-bridge.js. *Wider option not taken:* the same rule for body floats (about 300 figures
    in another section than their first citation).

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
    owner's no-jumping-rows rule (builds 58–59). *Undo:* the status line goes back under the title.

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
