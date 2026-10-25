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
18. **The six-place bar is chosen by the window's size alone: at least 730 pt wide and 600 pt tall** (`TallBar` in
    ScienceReaderCore). Every iPad upright gets six; Split View, Slide Over and a phone sideways (up to 956 pt wide, but
    at most 440 tall) get Library · Paper · Chat · More. *Why:* the shape rule already reads only the window (owner,
    2026-10-22), and a phone sideways must keep its bar (proposal A.6). *Undo:* change `TallBar.of(window:)`.
19. **A window that grows to six places, or turns sideways, while the More list shows goes to the Library.** Feed and
    Snippets opened from More stay where they are. *Why:* the list exists only beside More; the Library is the app's first
    place. *Undo:* `tallBarChanged` in `ReaderModel+Places.swift`.
20. **Sideways, while Search is the place, the places button shows ≡ and no row is checked** (VoiceOver: "Places,
    Search"); 🔍 is lit. *Why:* the proposal's drawing "(≡)(🔍)"; a place's symbol would claim a place you aren't in.
    *Undo:* `PlacesMenuButton`'s label.
21. **The Mac's search field is a 220 pt field at the toolbar's right, "Search everything" (the Library's own field
    says "Search"); a click or ⌘K opens Search, and its words stay when you leave** (as Mail's). Catalyst has no
    `NSSearchToolbarItem`, so it is a `UISearchTextField` in the toolbar. *Undo:* drop `gradstep.search` from the
    toolbar's items.
22. **🔍 from the Paper place starts with that paper in scope** ("In this paper", proposal B.5), from the bar, sideways,
    ⌘K and the Mac's field alike. *Undo:* `searchScopePaperID` returns nil.
23. **⌘1…⌘5, ⌘, and ⌘K also work on an iPhone with a hardware keyboard**, as on iPad (they are on the root now), and
    stay off in reading mode as before. A bar word that doesn't fit at the largest text sizes shrinks to 80 % rather than
    being cut. *Undo:* gate `PlaceShortcuts` with `Platform.isPad`; remove `minimumScaleFactor` in `TabBarItem`.
24. **Search's Cancel (and Escape) go back to the place Search was opened from, keeping the words** for the next 🔍.
    *Why:* the search screen behaved so before it became a place, and the proposal's Escape "clears the field and then
    leaves Search". *Undo:* `closeGlobalSearch` in `ReaderModel+GlobalSearch.swift` (e.g. clear the words, or stay).
25. **Sideways and on the Mac, a paper, chat or collection picked from the results shows beside them and Search stays the
    place** (its 🔍 lit); other results go to their place. A Setting opens over Search, so Done returns to the results.
    *Why:* "Search lives at the top of the left list, like Mail" (2026-10-22). *Undo:* `openSearchResult`'s last lines.
26. **On the Mac you type in the toolbar's field; the Search place's own row keeps only "In this paper", ⓘ and Cancel**
    (one field, not two). ↓/↑, Return and Escape work in the toolbar field. *Undo:* show the place's own field on the Mac
    (`GlobalSearchView.header`) and make the toolbar field a button that opens Search.
27. **↓/↑ with a hardware keyboard choose a result (highlighted), Return opens it; ↑ from the first goes back to the
    field.** *Why:* the proposal's keyboard rule (A.6); cheap once Search was a place. *Undo:* the two `onKeyPress` lines.
28. **🔍 brings the results back scrolled to the result opened last** (centred), not to the exact offset. *Why:* the place
    is rebuilt on every visit, and the opened row is what you were looking at. *Undo:* `returnRowID` in GlobalSearchView.

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
