# Judgment log

Owner, 2026-10-25: "Just make a good judgment and keep a log." Calls the lead or an agent made on the owner's behalf,
newest first. Each says what was decided, why, and how to undo it. Formal entries stay in [DECISIONS.md](DECISIONS.md);
this is the one place to skim and overrule. Say "undo N" (or describe the change) to reverse any of them.

## 2026-10-28

71. **The next model pack may mix encrypted and plaintext models: every model is encrypted except a recogniser whose
    weights are byte-identical to an already-shipped plaintext recogniser** (TexTeller-v4, public in builds up to 93).
    *Why:* Astra's lean-cache recogniser reached 2.02× memory loading encrypted (limit 2×), and the stateful recogniser
    can't load encrypted at all; the weights are already public, so nothing new is exposed, and the encrypted tagger
    v5b-journal and the speed work can ship. Recogniser encryption stays a research goal. *Undo:* require encryption for
    every model again (the 0eb82b00 gate).

60. **Deleted the retired 27B local-AI model (15 GB) and stale build folders (4 GB)** from `.artifacts` after the repo
    review found the disk 96 % full. The model was never qualified and is pinned in `tests/local-ai/candidates.json`, so
    it can be downloaded again; nothing else referenced the folders. *Undo:* re-download via `scripts/local-model-eval.mjs`.
61. **Numbers are handed out by the lead when dispatching work** (judgment-log entries and migration numbers; Astra asks
    the lead), reader/device revisions stay "claim at merge", and `docs/JUDGMENT_LOG.md` merges with `merge=union`.
    *Why:* 3 judgment-number collisions and repeated migration renumbering in 10 days. *Undo:* drop the rule.

59. **Unavailable device-PDF equations show plain words when their source crop cannot be shown** (Astra source
    fix on `codex/device-pdf-focus-20261028`; awaiting the lead's compiler rebuild and integration). The label is
    `Equation in PDF (transcription unavailable)`. Keep the exact old sentinel in equation metadata and admit only
    its exact device-PDF label in the shared validator; older bundles remain valid. *Why:* the reader currently sees
    raw LaTeX for this fallback (93 cases in the 600-formula budget fixture), while restoring a rejected guess would
    reintroduce unverified text. No model, acceptance rule or PDF location changes. *Undo:* revert the source change
    and rebuild both reader compilers with new revisions. Existing readings are not rewritten automatically.

57. **The neuroscience test catalog is a folder of the owner's own journal PDFs that the app imports, not a bundled arXiv
    list** (owner, 2026-10-28: "a catalog … with maybe 30-40 random neuroscience pdf papers preloaded into the library
    with the on device model"; the lead redirected it the same day to the Papers corpus). Staff only (operator roles),
    Settings › Experimental › **Import a folder as a test catalog…**: every PDF in a picked folder is added through the
    local-PDF path (never uploaded) into a catalog named after the folder, then read by the on-device model one at a time
    while the app is open, with one progress line, Pause/Resume, a "Not read" list with reasons, and a sealed on-device
    queue that resumes after a relaunch. Re-importing matches files by content (never twice; papers in other catalogs
    are left alone); a file added on another device is matched by title and page count and gets this device's PDF.
    The folder (`~/Desktop/Gradstep neuroscience test PDFs/`) holds 36 PDFs / 540 pages drawn with seed 20261028 from
    the **test** split only, outside the reserved span cohort, spread over year eras, at most two per journal; slides
    and posters skipped. *Why:* nothing private can be put into an account from a server, and the owner's own PDFs are
    what the model is being tuned for; the test split keeps training and dev families out. *Cost:* each device imports
    and reads the folder itself (readings and PDFs don't sync); a paper's kept reading opens from its "Read with the
    on-device model". *Undo:* remove `TestCatalogSettingsRow` from Settings (the catalog and papers stay ordinary
    library items) ([TEST_CATALOGS](architecture/TEST_CATALOGS.md)).
56. **How 94 reships 93's pack (implements 53), and 93's pack keeps 93's tagger tolerance.** The upload scripts take
    `RESHIP_DEVICE_PACK=<full version>`. Only a pack pinned in `apps/apple/device-models-shipped.json` qualifies: today
    that is 93's `28f6fd14e8be…` from 1c87b2af. It is copied byte for byte from 93's archive (or `RESHIP_DEVICE_PACK_FROM`),
    and only then is the signed encryption check skipped. Anything else fails: an unrecorded pack, one byte changed, an
    abbreviated version or mixed modes. The archive scan still refuses keys, source models, raw recovery weights and any
    other plaintext model. A rebuild can't stand in: the compiler writes model metadata in a different order each run.
    *Compatibility change:* today's app reads 93's pack. Its v4 tagger has ten features and its own 0.7 threshold, and
    without the reference the recovery stays off. But today's host failed **2 of 6 papers** on it ("tagger:
    invalid_output"). v4 sometimes returns all-zero buffers: 93's own host got 0, 8 and 16 such lines of 969 in three
    runs of one paper, and 6 of 577 on a scan. 93 read those lines as prose, unnoticed; today's host retried once, then
    failed the whole reading. Now a pack **without the reference** reads a line that is still invalid after the retry as
    prose, as 93 did, and counts it (`tagger_unread_lines`). Result: 7 of 7 papers read, with 0–7 such lines each, fewer
    than 93. Packs with the reference (every pack the builder makes now) keep the strict rule. *Why:* it is what 93
    shipped, and the owner wants a first open to degrade rather than refuse. *Undo:* `readLegacyTaggerOutput`
    (DevicePDFModels.swift) to fail the reading again; the reship branch in both upload scripts.

58. **What refused a paper on the fresh-paper sweep degrades instead, and the author block's readings that go with it**
    (reader revision 29; lead's rule: "a refusal is a first-open failure — degrade, don't refuse; never show leaked
    markup"). Calls beyond the direct fixes: (a) **any formula the reader can't draw shows its LaTeX** (the validators'
    existing `reader-math-fallback` text form), including a picture in a formula that isn't a DocPilot text badge, which
    refused the paper since build 65; nothing of the picture reaches the page either way. A TeX annotation that disagrees
    with the alttext still refuses (a damaged source). (b) **A link to an id the HTML lacks goes to the element LaTeXML
    named it after** ("S6.F5.2" → Figure 5, LaTeXML ids name their container) rather than only becoming words; words only
    when nothing holds it. (c) **In a `\thanks`, a contact line its left-out e-mail addresses emptied goes** ("E-mail:",
    "Correspondence to:"), "Corresponding author: …" stays; numbered lines join the affiliations; a link stays in the
    note's words; a note left with nothing marks no name (an empty `\footnotemark` still does). E-mails stay left out of
    LaTeXML's author block as before, and the contact paragraph after an abstract stays whole in the affiliation lines
    (revisions 20/22), so (d) **the sweep's e-mail check now applies to the names only**, and new checks fail on marks run
    together, TeX typed as text and address pieces anywhere in the header. Of 229 cached papers 31 change, none newly
    refused; 28 author headers reviewed one by one (mostly catalog headers that had garbled marks or names read as
    affiliations). *Why:* each is the most faithful reading of what LaTeXML wrote; a refusal costs the reader the paper.
    *Undo:* (a) `drawnMath` returning null back to throwing in `arxiv/math.ts`; (b) drop the two fallbacks in
    `arxiv/finish.ts` `linkTarget`; (c) `noteLines` in `arxiv/authors.ts`; (d) the checks in `scripts/reader-sweep.mjs`;
    then bump the revision. *Not taken:* 2610.37633v1's 48 MB of images still exceed the hosts' 40 MiB per-paper budget;
    letting such a paper open with its last images as notes changes both hosts and needs the Simulator (proposal in
    HTML_FIRST_READER.md).

55. **After a silent model, the fallback's admission moves the silent attempt's ceiling out of the reader's hold into
    Gradstep's own room** (migration 0163; local, not applied or deployed). Staging, 14:12 and 14:14 UTC: a paper
    explainer on Flash was silent 25 s, "Switching to Claude Haiku 5.5…" showed, then Haiku was `denied`
    (`operation_ceiling`: 132,872 µ$ unresolved + Haiku's 149,531 > the 149,531 hold) and the reader got "couldn't
    finish". Every action without a search allowance (all explainers, Go deeper, Study, answers without search) had this,
    so after a silent model the fallback never ran. Now `worker_openrouter_admit_fallback` admits the fallback's first
    request and, when the attempt it follows was silent (no output, no receipt), raises the operation's *provider* ceiling
    by exactly that attempt's ceiling and reserves it in the month, recorded as a `carried` event on the silent attempt.
    The reader's credit hold and quote never change; they pay only the answer they got. Nothing is carried for a refusal
    that cost nothing (429, 503), output that arrived, a replay, a settled operation, or when the month, the free AI pool
    or a testing cap can't take it (then the fallback is refused as before and `chat_fallback` logs `carry_refused`).
    Settlement, reconciliation, Your AI usage and assumed zero (0162) are unchanged: the silent ceiling is the
    operation's unresolved liability until reconciled or assumed zero. *Why this and not sizing every hold for both
    attempts up front:* that would reserve the second ceiling on every Flash answer, against the month, the free pool
    and testing caps (near the pool's end a free answer would have been paid from bought credits) to cover the ~6 % that
    fall back; carrying at the moment of the fallback reserves it only then, keeps the operation's ceiling a true bound
    on its spend (no overrun alerts), and leaves the reader's side untouched. *Cost:* one migration (a new admission
    function, a `carried` event state, a replay-tolerant `worker_reserve_chat`) that must be applied before `chat` is
    deployed. *Undo:* deploy `chat` without the `afterAttemptID` line in `generateAnswer` (the fallback is admitted as
    before); the function can stay. Turning the fallback off (`chat_fallback: off`) also removes it.

54. **Pictures set apart from their captions or labels read as panels, each picture above its own caption** (reader
    revision 28; agent report on 2610.20608v1, whose Figure 2 showed only "(a)", "(b)", "(c)" and its caption while the
    closing note counted its three plots as left-out graphics). LaTeXML wrote the plots as one paragraph and the
    sub-figures as captions alone; the flow read that paragraph as text, where a graphic is left out. Now such a figure
    is one figure and the i-th picture joins the i-th caption (after it when the captions come first; page order when
    the counts differ). The same reading for the tabular form, a row of pictures with a row of labels under or over it
    (Batch Normalization's Figure 1 had read as a table of "(a) | (b) Without BN | (c) With BN"). Of 243 cached sources
    4 papers change (61 pictures in 7 figures now show), none newly refused; left-out graphics in the closing notes of
    the 219 papers that compile, 2,730 → 2,669.
    *Why:* the panels' own captions, under their pictures, are how every other sub-figure reads (revision 12) and how
    the figure viewer finds parts. *Cost:* 2610.09823v1's three galleries now carry 48 more photos (bundle 9.2 → 26.1
    MiB; preparing it took 25 s instead of 1.7 s in WebKit on a Mac, since 71 images exceed the per-image pixel share and
    are redrawn as PNG), and past the 16-picture figure limit a label stays as words without its picture. *Undo:* drop
    the `panelsApart`/`labelledPanels` branch in `arxiv/flow.ts` and bump the revision. *Not taken:* grids with row or
    column headings (18 figures, 588 pictures in 5 cached papers, and 28 table floats with 613 pictures in cells) still
    read as tables without their pictures; showing them needs pictures inside reader tables in all three validators, a
    separate proposal.

Building 27 (Go deeper on a key concept; CHAT.md "Go deeper on a key concept"; local, not deployed):

44. **The deeper card has fixed parts**: What it is · Why this paper needs it · An intuition *or* A small example · How
    the paper uses it · **Where it appears** (2–6 places, each the overview's ¶ capsule with what happens there), then
    **Ask about this**. Sections stream in one by one under the explainers' bar. *Why:* the four questions 27 named, in
    the order a reader needs them; places as ¶ capsules behave exactly like the overview's. *Undo:* the instructions in
    `chat-paper-concept.ts` (the device shows any titled section).
45. **Go deeper asks the explainer's AI without a model chooser**, and the card names the model (or "by Claude Haiku
    5.5" when the fallback wrote it). A card closed while it is being written keeps being written while the explainer
    is open and shows when reopened; closing the explainer stops it (not charged). Reopening a kept one asks nothing.
    *Why:* one tap per concept; the AI was chosen for this explainer a moment ago. *Undo:* show `AIChoiceView` before the
    first concept, as the explainer does.
46. **The explainer's header is one row in the sheet's bar**: "AI Explainer · <model>" over the paper's title (one line
    each) on the left, the chat symbol on the right (and the X on the Mac or in Wide's slot). It had to be one view: as
    a separate leading item, iOS 26 moved both it and the chat symbol into a ⋯ overflow menu. On an iPhone the first
    card now starts ~90 pt higher. The idle state's "AI Explainer" capsule in the bar went (the page's own "Explain this
    paper" does the same). The figure and equation explainers keep their headings: theirs is a ⌄ menu of the paper's
    other figures or equations, a different component. *Undo:* `PaperExplainerHeader` and `topRow` in
    PaperExplainView.swift (the old heading was a `title2` VStack at the top of the page).
47. **A concept is metered and settled as chat, like the paper's explainer** (no migration; the attempt's feature is
    `paper_concept`, which the usage and admin functions count as chat); the apps name it **Concept explainer** in Your
    AI usage from what the device recorded, with **Open concept** (the explainer with that card in front). *Why:* the
    same design as the explainer it deepens, nothing to apply on the database. *Undo / wider:* an activity of its own
    needs a migration of `usage_activity`, `v1_ai_usage` and both clients' lists.
48. **Gemini writes concepts at `minimal` reasoning, as the explainer** (Claude keeps a chosen effort; automatic is
    `low`). DPO probe: five sections each, the same quality as Haiku; Flash's start was 3 s once and 25 s twice (its known
    tail; Haiku is asked at 25 s). The prompt asks for "in general" rather than remarks about what can be verified
    (Haiku hedged before), and 200–700 characters a section. *Undo:* the `conceptOnly` clause beside the explainer's in
    chat.ts.
49. **The card says "Still waiting for the model…" in its bar** (the server relays `waiting` to concepts, not to the
    other explainers, which keep "Reading…"). *Why:* the probe's 25 s Flash starts; a card with a still bar for 25 s
    reads as stuck. *Undo:* drop `conceptOnly` from the `onStatus` filter.
50. **Ask about this closes the card and starts the explainer's question "About “<concept>”: " with the keyboard up**,
    the concept's words going with the question before the overview's (as a figure part's Ask about this part). A ¶ in
    the card closes the explainer and the card in one dismissal; Back to AI Explainer brings both back.
51. **Not built:** the browser (it sends no `paper_concept`; its explainer is unchanged) and deepened concepts in
    Download your assets (the shared export fixture is unchanged). Both are follow-ups.

## 2026-10-28

52. **Astra owns the on-device model track; the Claude lead owns the app, server and releases** (owner: "I'll let
    you decide"). Working rules are at the top of [AGENT_HANDOFF.md](AGENT_HANDOFF.md). The Claude team's recogniser
    speed branch goes to Astra as input instead of merging separately. *Why:* both teams were changing the same
    recogniser cache, which is also what blocks encryption. *Undo:* reassign in the handoff.
53. **TestFlight 94 reships TestFlight 93's model pack unchanged, in plaintext; any new pack still needs the
    encryption qualification.** *Why:* since 0eb82b00 every upload required a passing encrypted-pack check, which fails
    until the recogniser encrypts, so no app fix could ship; 93's pack is already public, so nothing new is exposed.
    *Undo:* remove the reship mode from the upload scripts.

## 2026-10-25

43. **A figure printed before the Introduction reads after the paragraph that first cites it** (owner, TestFlight 92,
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

32. **The six-place bar is chosen by the window's size alone: at least 730 pt wide and 600 pt tall** (`TallBar` in
    ScienceReaderCore). Every iPad upright gets six; Split View, Slide Over and a phone sideways (up to 956 pt wide, but
    at most 440 tall) get Library · Paper · Chat · More. *Why:* the shape rule already reads only the window (owner,
    2026-10-22), and a phone sideways must keep its bar (proposal A.6). *Undo:* change `TallBar.of(window:)`.
33. **A window that grows to six places, or turns sideways, while the More list shows goes to the Library.** Feed and
    Snippets opened from More stay where they are. *Why:* the list exists only beside More; the Library is the app's first
    place. *Undo:* `tallBarChanged` in `ReaderModel+Places.swift`.
34. **Sideways, while Search is the place, the places button shows ≡ and no row is checked** (VoiceOver: "Places,
    Search"); 🔍 is lit. *Why:* the proposal's drawing "(≡)(🔍)"; a place's symbol would claim a place you aren't in.
    *Undo:* `PlacesMenuButton`'s label.
35. **The Mac's search field is a 220 pt field at the toolbar's right, "Search everything" (the Library's own field
    says "Search"); a click or ⌘K opens Search, and its words stay when you leave** (as Mail's). Catalyst has no
    `NSSearchToolbarItem`, so it is a `UISearchTextField` in the toolbar. *Undo:* drop `gradstep.search` from the
    toolbar's items.
36. **🔍 from the Paper place starts with that paper in scope** ("In this paper", proposal B.5), from the bar, sideways,
    ⌘K and the Mac's field alike. *Undo:* `searchScopePaperID` returns nil.
37. **⌘1…⌘5, ⌘, and ⌘K also work on an iPhone with a hardware keyboard**, as on iPad (they are on the root now), and
    stay off in reading mode as before. A bar word that doesn't fit at the largest text sizes shrinks to 80 % rather than
    being cut. *Undo:* gate `PlaceShortcuts` with `Platform.isPad`; remove `minimumScaleFactor` in `TabBarItem`.
38. **Search's Cancel (and Escape) go back to the place Search was opened from, keeping the words** for the next 🔍.
    *Why:* the search screen behaved so before it became a place, and the proposal's Escape "clears the field and then
    leaves Search". *Undo:* `closeGlobalSearch` in `ReaderModel+GlobalSearch.swift` (e.g. clear the words, or stay).
39. **Sideways and on the Mac, a paper, chat or collection picked from the results shows beside them and Search stays the
    place** (its 🔍 lit); other results go to their place. A Setting opens over Search, so Done returns to the results.
    *Why:* "Search lives at the top of the left list, like Mail" (2026-10-22). *Undo:* `openSearchResult`'s last lines.
40. **On the Mac you type in the toolbar's field; the Search place's own row keeps only "In this paper", ⓘ and Cancel**
    (one field, not two). ↓/↑, Return and Escape work in the toolbar field. *Undo:* show the place's own field on the Mac
    (`GlobalSearchView.header`) and make the toolbar field a button that opens Search.
41. **↓/↑ with a hardware keyboard choose a result (highlighted), Return opens it; ↑ from the first goes back to the
    field.** *Why:* the proposal's keyboard rule (A.6); cheap once Search was a place. *Undo:* the two `onKeyPress` lines.
42. **🔍 brings the results back scrolled to the result opened last** (centred), not to the exact offset. *Why:* the place
    is rebuilt on every visit, and the opened row is what you were looking at. *Undo:* `returnRowID` in GlobalSearchView.

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
