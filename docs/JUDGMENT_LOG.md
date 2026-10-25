# Judgment log

Owner, 2026-10-25: "Just make a good judgment and keep a log." Calls the lead or an agent made on the owner's behalf,
newest first. Each says what was decided, why, and how to undo it. Formal entries stay in [DECISIONS.md](DECISIONS.md);
this is the one place to skim and overrule. Say "undo N" (or describe the change) to reverse any of them.

## 2026-10-25

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
