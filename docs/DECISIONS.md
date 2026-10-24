# Product and architecture decisions

Last updated: 2026-10-24 UTC. Requirements below come from the current user conversation, not from TextBrain's product specification.

## Library search over every paper's text: an encrypted on-device index (owner question 2026-10-24; agent decisions, reversible)

Owner: *"is our search engine good enough, ie is it searching full text from all papers instantly?"* It wasn't: a
substring filter over metadata plus at most 10,000 distinct words of at most 200 papers, rebuilt from the bundles at every
launch, with no phrases, ranking or snippets. Details and measurements:
[NATIVE_LIBRARY_SEARCH](architecture/NATIVE_LIBRARY_SEARCH.md) "Full-text index".

| Decision | Choice |
|---|---|
| Engine | A compact custom inverted index in ScienceReaderCore, not SQLite FTS5. FTS5 is in the system SQLite, but encrypting its pages needs SQLCipher or a custom VFS (a new dependency or a lot of C), and a plaintext FTS database would break "no plaintext index on disk". The custom index is ~1,800 lines of Swift, has no dependency and is sealed with CryptoKit like the bundles. |
| On disk | Immutable segments (sorted terms; postings with positions, delta/varint), a manifest, and each body's text in 16 KB LZFSE blocks for snippets: all AES-GCM sealed under the account's local-store key with account- and file-bound associated data, in `search-index/` with complete file protection, excluded from backup. Decrypted segments live in memory only. |
| Lifecycle | Incremental: each paper is a metadata document (title, authors, tags with keywords and source reference, abstract, its notes and snippets) and a body document (its saved reading's text). A change writes a new small segment; at most 8 segments, the smallest merged. A new format or tokenizer version, or a damaged file, empties the index and it is rebuilt from the encrypted bundles in the background at utility priority. A launch only compares fingerprints. |
| Matching | Every word and quoted phrase is required (AND, as before). Case, diacritics, width and ligatures folded; hyphenated words match joined, split or as written; light plural stemming; the word being typed (no space after it) matches as a prefix (64 most frequent expansions). Each clause may also match a metadata field by today's substring rule, so results are never fewer than before. |
| Ranking | BM25 per field, weighted title 6 > tags, authors, abstract 3 > notes 2 > body 1, × up to 1.1 for the newest papers. Applies to the default Recent order when there is a query; any other order (Title, Year, a table column) sorts as before. |
| Snippet | One line under the title, small and secondary, the matched words in the primary colour and semibold, when a match was in the paper's text: the densest cluster of matches (most query words within a dozen words). Computed for the first 100 results; later rows show none. |
| Opening a result | Opens the paper as before; if the row had a snippet, Find in paper opens with the matched words searched and the keyboard down. |
| Reuse | `FullTextSnapshot.documentFrequency`, `documentFrequencies()` and `termFrequencies(group:fields:)` give the interest index's TF-IDF its counts; not used yet. |

## Heading formulas as characters; bracketed addresses stay (fresh-paper sweep, 2026-10-24; agent decisions, reversible)

The sweep before TestFlight 90 failed VLA-Δ (2610.21306v1). Reader revision 24; details in
[HTML_FIRST_READER](architecture/HTML_FIRST_READER.md) "Heading formulas and bracketed addresses".

| Decision | Choice |
|---|---|
| Formula in a heading | Written as text when Unicode spells it exactly ("Δ", "τ²", "λ < 1"), a one-letter variable in italics; otherwise kept as math. The index format and validator are unchanged, so installed and synced bundles keep validating. |
| Address in an affiliation | A link in brackets stays in the affiliation's words; a link on its own keeps its own line, once. |

## List markers are the paper's own; diagram labels keep their lines (owner reports build 88, 2026-10-23; agent decisions, reversible)

Owner, TestFlight 88 on iPad: *"Authors list badly fmt"* (2610.28711v1) and *"Garbled figure text"* (2610.14162v1
Figure 3). Reader revision 23; details in [HTML_FIRST_READER](architecture/HTML_FIRST_READER.md) "List markers and
diagram labels".

| Decision | Choice |
|---|---|
| One marker per list item | The paper's own label ("•", "–", "(ii)", "a.", a reference's "[12]") is the marker and the list's CSS marker is off, as device-PDF lists already did; the label hangs in the indent. An item without a label keeps the list's marker. |
| Item spacing | No empty lines under an item; paragraphs inside one item stay apart. |
| Diagram labels | A label of several lines is drawn line by line (wrapped to its minipage); `\phantom` text is not drawn. Not a degrade case: arXiv's own page reads, so the reader draws it rather than replacing it with a note. |

## Show in PDF for on-device readings (owner request 2026-10-24; agent decisions, reversible)

Owner: *"it would be neat to somehow have a feature where, wherever you select, it can guess where in the pdf that is and
show it to you with a pop up that you can zoom around in"*.

| Decision | Choice |
|---|---|
| Data | The converter records every emitted block's page and box(es) in points (provenance `blocks`, port revision 11); equations already had theirs. The reading is unchanged. Older readings have no block rows and search the whole PDF. |
| Matching | On the device, in the PDF's own text layer, folded (ligatures, case, accents, spacing, punctuation and a hyphen at a line's break ignored); on the block's recorded pages, a repeated phrase told apart by the block's box and then by the text around the selection; an approximate match when the reading differs; else the block's recorded boxes, outlined dashed with a note; else "Not found in the PDF". |
| Entry | The last item of the text selection's menu and of the tapped equation's menu, "Show in PDF" (`doc.viewfinder`), only for an on-device reading whose PDF is on this device. No new chrome; arXiv HTML readings unchanged. Tables get no new tap entry (none exists for them in the paper). |
| Pop-up | Opens framed on the passage, lines highlighted, extent outlined; pinch to the whole page, double tap toggles; previous/next page and X in a slim top row. Full screen on iPhone and upright iPad, the paper's slot sideways on iPad, a sheet on the Mac. Only the visible part is drawn sharp; everything is let go on close. |

Details: [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Show in PDF".

## Figures of on-device readings zoom out onto the PDF page (owner request 2026-10-24; agent decisions, reversible)

Owner: *"in the on device model, when I click on an AI explainers for a figure, I should be able to zoom out around it and
see the actual pdf, that would compensate for an inadequate crop"*.

| Decision | Choice |
|---|---|
| Data | The converter records each shown figure's page and crop in points, with the page's size (provenance `figures`, port revision 10). Readings made before have none and zoom as before; so do arXiv HTML readings. |
| Gesture | The figure opens full screen at the crop exactly as before. Pinching out past the whole figure shows the PDF page around it (from the PDF on this device, drawn then and released on close), the crop faintly outlined in the parts' outline colour. Zoom stops at the whole page; the page pans; a double tap returns to the crop. A pinch outwards on the explainer's card, or on the figure page, opens straight onto the page. |
| Discoverability | One small round control in the full-screen top row, next to the X ("Show the whole page" / "Back to the figure"), also VoiceOver actions. No new chrome on the card or the figure page. |
| Neighbouring page | Not built (optional in the request): the zoom stops at the page's edge. |

Details: [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Zoom out onto the page".

## Paper AI Explainer: one Key concepts card, the same cards in Chat (owner feedback build 82, 2026-10-22; agent decisions, reversible)

Owner, on TestFlight 82: *"Key ideas and concepts seems like two versions of the same thing and could be combined"*,
*"When I pressed the chat button , I expected Al above content to follow me, but some did some did not"*, *"Oh it looks
like thr cards were removed, confusing"* and *"Is it cut off ?"*.

| Decision | Choice |
|---|---|
| Background and Key ideas | One "Key concepts" card, background first, each entry marked "Background" / "This paper" with the diagram's colour. The wire format keeps two lists (older builds and kept explainers unchanged). |
| Open in Chat | The chat shows the explainer's own cards (summary, Key concepts with ¶ links, the drawn diagram) instead of flattened text; the model still reads the text. iPhone, iPad, Mac and browser share one view each. |
| Long summaries | Asked for under 450 characters; over the 600 limit, ended at a sentence (or a whole word with "…"), never inside a word or number. Limits unchanged for older builds. |
| Gemini speed | The explainer on Gemini asks for `minimal` reasoning: first words 2.1–3.3 s in every measured run vs 1.5–34 s at `low`, same output. |

Details and measurements: [CHAT.md](architecture/CHAT.md) "Build-82 feedback".

## Download your assets (owner, build 82; built, not released)

Owner, TestFlight build-82 feedback on Settings › Your assets: *"Need a download assets button"*. Interpreted as
**download = export your own content as a zip**: one action at the bottom of Your assets (apps) and the account menu's
Your assets (browser), not a per-row download and not a re-download of papers.

| Decision | Value |
|---|---|
| What is in it | Chats (Markdown per chat, the version whose last message is newest; diagrams as `.mmd` Mermaid or `.html` visuals), snippet collections (Markdown, images as captured PNG/JPEG), equation / figure / paper explanations kept on this device (Markdown), and a README listing everything and what was left out |
| Not in it | Downloaded papers and reader copies (publishers' content; the README says so, the ⓘ too). Figure breakdowns (cut from the paper itself; counted in the README). Explanations kept on other devices (they are per device) |
| Where it is made | On the device or in the browser, from what it holds or decrypts (E2EE content never leaves as plaintext). No new endpoint; only a snippet image not yet on this device is downloaded, encrypted, through the existing note-assets read |
| Format | `Gradstep export YYYY-MM-DD.zip`, one folder inside, stored (uncompressed) entries, UTF-8 names, dates UTC. Swift `AssetsExport.swift` and browser `lib/assets-export.ts` produce identical bytes for the shared fixture (`tests/fixtures/assets-export/assets-export-v1.json`) |
| Hand-off | iPhone/iPad: the share sheet (Save to Files, AirDrop…); Mac: a save panel; browser: an ordinary download. The apps' temporary zip (complete file protection) is removed when the sheet closes |
| Also | The Snippets row in Your assets gets the chevron the other rows have |

## Pricing accepted, with safeguards against spend outrunning income (owner, 2026-10-22; built, staging)

Owner, verbatim: *"I will take your defaults"* (on [PRICING_PROPOSAL_20261022](proposals/PRICING_PROPOSAL_20261022.md)),
then *"the complexity of the pricing system and what debug strategies I'll have if my spend somehow becomes very high
in relation to my incoming money."* The figures default moves to Gemini Flash (low), handled separately by another
agent. How it works in plain words: [PRICING_HOW_IT_WORKS](PRICING_HOW_IT_WORKS.md); what to do when spend is high:
[RUNBOOK_SPENDING](RUNBOOK_SPENDING.md).

**App Store Connect (owner approved, 2026-10-22: "I approve"):** `node scripts/asc-pricing-plan.mjs --apply
--owner-approved=2026-10-22` made all eight API changes and the read-back matched: Plus $7.99 with one introductory
offer, Plus yearly $79.99, Pro 2,000 credits, Pro yearly $199.99, packs 300 and 700. The new products show "Missing
metadata" until the owner adds review screenshots; removing `credits.400` from sale and submitting the products with
the next version are manual (OWNER_ACTIONS #13).

| Accepted | Value |
|---|---|
| Free | 50 credits a month (≈ 15 answers), fast models only (Gemini Flash, DeepSeek, Haiku), no web search, podcasts or premium models; at most 20 a day and $0.25 of provider cost per account a month |
| Free pool | **$15 a month** across every free account: the owner's whole subsidy, enforced before any model call. When it is used up: "This month's free AI has all been used. It comes back on November 1." Paying users are unaffected |
| Plus | $7.99/month or $79.99/year, 600 credits a month (`standard.*`; shown as "Plus") |
| Pro | $19.99/month or $199.99/year, 2,000 credits a month |
| Packs | $4.99 = 300, $9.99 = 700, never expire. `credits.400` is retired for new sales and still records for earlier buyers |
| First month of Plus | $3.99 introductory offer (pay up front, new subscribers); no free trial |
| Students | No student price at launch (Plus yearly is the student price) |
| Apple | Enroll in the Small Business Program (15%) before the first Production sale; the proceeds estimate assumes 15% |
| Tavily | Move to the free tier at the November 6 renewal (saves $30/month) |
| Dollar balance | The 2026-10-20 dollar-balance design ([DOLLAR_BALANCE](architecture/DOLLAR_BALANCE.md)) is **dropped**: credits, described as "about N answers" |
| Gemini, 2027-01-01 | Gemini 3.8 Flash list prices double (a default answer ≈ 3 → ≈ 5 credits). Before mid-December: switch the chat default to DeepSeek V4.1 Flash or Haiku 5.5, or keep Gemini and change the "about N answers" copy |

**Implementation choices (agent, reversible):**

- One extra rule in the existing reservation, no new money system: free credits are a `free` bucket; an operation they
  fund is marked, and its worst case is checked against the pool and the account's share under the same budget →
  account lock (migration 0150). Free spend therefore cannot pass the pool, even with concurrent requests (database
  test with 12 simultaneous readers).
- The pool's **growth rule** (max($15, 10% of last month's proceeds)) is shown in Admin as a suggestion; only the owner
  changes the pool, audited. Nothing raises a limit automatically; the $100/month budget is unchanged.
- Free answers don't offer web search (the chat function decides; prepaid search is kept for paying readers). An
  answer that falls back from free credits to plan or pack credits behaves as before.
- The App Store changes are a read-only plan until the owner approves:
  `node scripts/asc-pricing-plan.mjs` (see PRICING_HOW_IT_WORKS §App Store). No product, price or offer was changed.
- Annual plans grant one month of credits at a time (first at purchase, the rest at each monthly anniversary).
- Safeguards: Admin › **Spend vs income**; emailed alerts (50/80/100% of the provider limit, free pool used up, spend
  above 0.6× proceeds), each once a month; owner switches (pause free AI, pause podcasts / recommendations / figures /
  equations, cheaper models only, pause all AI) with a 7-day dry-run preview, audited and reversible. Recommended
  external backstop: a credit limit on the OpenRouter key itself (OWNER_ACTIONS).

## Figures default: Gemini Flash again (owner decision 2026-10-22; deployed to staging, clients local)

Owner, 2026-10-22, after the pricing proposal (docs/proposals/PRICING_PROPOSAL_20261022.md): "Let's try Gemini instead of
Sonnet for Figures then." Supersedes the morning's Sonnet default (below, under "Figure explainer: streamed, at low effort").
- The server publishes `default_figures` = `gemini-medium-standard` (Gemini's one published profile; the figure view runs
  it at low effort, `done.profile` `gemini-low-standard`), only where Gemini is offered. Chat function deployed to staging
  2026-10-22 05:58 UTC after backup `.artifacts/backups/20261022T055356Z-4a3671a898cc`, from the deployed study-mode build
  plus this change (so neither undoes the other); read back from `GET chat`.
- Apps and browser: the figures activity falls back to Gemini Flash when the table lacks `default_figures` but offers
  Gemini (apps also before the table loads), else the chat default. The morning's one-time migration is reversed: a saved
  figures choice equal to the Sonnet default (`sonnet-low-standard`) is let go once (`ai.figuresDefaultGemini.migrated`,
  browser `figuresDefaultV3`); any other saved choice (DeepSeek, Gemini, Opus, Haiku…) is kept, and an explicit Sonnet
  choice made after the migration sticks. The figures ⓘ text names Gemini Flash as the default and Sonnet as a little
  quicker at about three times the cost.
- Measured basis (FIGURE_VIEW.md "Speed"): Gemini at low read the same panels, values and boxes as Sonnet low; summary
  in ~3–7 s, whole walkthrough 8–15 s; ~$0.008–0.012 a walkthrough on a cached paper vs Sonnet's ~$0.022 (and $0.24 for
  Sonnet's first request on a paper).

## Equation explainer streamed; figure parts full screen on touch (owner request 2026-10-22; agent decisions with evidence, reversible)

Owner, 2026-10-22: "I like the changes. The one issue is when you try to click into a subfigure and zoom. The transition
needs to be improved. My suggestion is that whenever you try to interact with it, it becomes a full screen thing, with the
outline fading away … but you can easily navigate, using the entire full screen, the entire extent of the figure, with
not really any in-between … But overall, the equations AI explainer needs the same progress with the progress bar."

- **Figure parts: no in-card zoom; any touch opens full screen in one motion** from the card's place and framing, the
  outline fading over ~1 s while the whole figure is the reader's to pan and zoom (zoom limits sized to the whole figure;
  double tap toggles whole ↔ part). Choices made: a *sideways* drag opens (an up-or-down drag stays the page's scroll, so
  reading the walkthrough is unchanged); the **Whole figure / Show part** control stays in the full-screen top row (the
  one non-gesture way for VoiceOver, Switch Control and keyboard users), as does the **Full screen** button under a card
  (discoverable); the apps' whole-figure card at the top of the walkthrough behaves the same way; the Mac keeps its
  window-sized sheet, which fades in rather than moving from the card. The local framing record gains `opened` / `opens`.
  FIGURE_VIEW.md "Full screen on touch".
- **Equation symbols streamed** like the figure walkthrough (summary, then each symbol as written, checked exactly as the
  final `equation`, which is unchanged for older builds), under the same progress bar ("Explaining symbol k of N" only once
  the model has announced N). EQUATION_VIEW.md "Streamed explanation".
- **Equation symbols at low effort** for Gemini Flash and automatic effort (an effort chosen for a Claude model stays;
  background unchanged). Evidence (DPO's loss and gradient): Gemini low listed the same symbols and paragraphs as medium
  and reached its summary in 4.5–5.3 s against 2.7–9.0 s at medium (medium sometimes thought ~800 tokens first); live on
  staging the default went from 9.3–12.3 s with nothing shown to the summary in 2.9–5.6 s and everything in 6.5–8.8 s.
- **Equations default model unchanged** (the chat's default, Gemini Flash recommended). Sonnet 5.5 at low was a little
  faster to the summary (2.6–3.6 s) and as fast overall (7.2–8.4 s), with comparable symbols, but costs ~3× per
  explanation on a cached paper ($0.019–0.021 vs $0.006) and, unlike the chat's own model, writes the paper to its own
  cache the first time (~$0.23 on DPO); the equation view was designed to reuse the chat's cache. Not changed without the
  owner; reversible by publishing an equations default like `default_figures`.

## Your AI usage (owner request 2026-10-22; agent decisions, reversible)

Owner: "a table of my recent AI token spend for all the different activities … rows ordered by time, each row being an
activity, and the exact cost, so that a user can figure out where their credits are going." Built as Settings › AI
credits › Your AI usage (and from Get credits; the browser's account menu), on a new read-only RPC `v1_ai_usage`
(migration 0144) over the existing ledger. Decisions:

- **Credits and tokens, no dollars.** The app presents no credit-to-dollar conversion and dollar settlement is design
  only, so rows show the credits actually settled (or held while running) and the provider-reported tokens. Whether to
  add dollars is OWNER_ACTIONS #12. Provider dollar cost stays in Admin › Costs.
- **One row per metered request**, its extra calls (chat title, suggested questions, study map, searches, podcast
  script/check/audio) shown as parts of that row, because they are one charge.
- **Paper titles never reach the server.** The device remembers which conversation kind and library paper each of its
  own operations was for (ids only, on that device) and names the paper from its library; requests from another device
  show the activity only. The server's ledger is not extended with paper or mode.
- Stopped, failed (not charged), in-progress and free (paid by Gradstep) rows are labeled; free work that reached no
  provider is left out.
Details: [Operations](architecture/OPERATIONS_AND_BILLING.md#your-ai-usage--2026-10-22).

**Credits by activity (owner, build-82 feedback, 2026-10-22):** *"The very top before the list when on All a pie chart
summarizing the cost types and their cost."* Agent decisions, reversible:

- **A thin ring (donut) with a legend**, only in the All view, under the totals line; a filtered list has none. Slices
  are credits per activity over the chosen period, from the first page's per-activity totals (`v1_ai_usage`
  `activities`, the whole window), so no server change was needed.
- **At most five segments:** the four largest activities with at least 4% of the period's credits, the rest one
  **Other** listing what it holds (the server's own `other` is folded in). No chart when nothing has been charged or
  one activity holds it all (the totals line already says it).
- **Colour by size, not by activity:** slots 1–4 of the chart palette, largest first clockwise from the top, and a
  neutral Other. Neighbours are then always adjacent palette slots, which pass the colour-blind and normal-vision
  separation checks in light and dark (`dataviz` validator, adjacent pairs incl. the wrap to slot 1); fixed colours
  per activity cannot (any two of 16 activities can touch, and only three palette colours pass all pairs). The legend
  names every segment with its credits and share, so colour never carries meaning alone.
- **Credits only** (no dollars; OWNER_ACTIONS #12). Shares are whole percent, half up, with "<1%" for a sliver and
  ">99%" beside one, computed identically on every device (`tests/fixtures/ai-usage.json`).
- **A named segment or legend row chooses that activity's chip**; Other is not a filter.

## Study mode and the paper's AI Explainer (owner request 2026-10-22; agent decisions, reversible)

Owner: "'Study Mode' is too complex and not a polished enough UX for now… have 'Enter Study Mode – Quiz me and help me
learn' as an entry in the suggested questions… a mode that asks questions, and backs off a bit if concepts need to be
explained a bit first… [Knowledge Journey diagrams] should be part of a generic 'AI Explainer' feature for the entire
paper… in the Paper Settings… with background list, and a diagram… with the opening to a chat… in the questions that are
sometimes listed in the chat, have options like 'Create a mermaid diagram explaining the background of X'." Design and
the prompt evaluation: [proposals/LEARNING_GUIDE.md](proposals/LEARNING_GUIDE.md); contract:
[CHAT.md](architecture/CHAT.md#study-mode--reworked-2026-10-22-server-on-staging-apps-and-browser-local).

- **The knowledge map is removed, not redesigned.** No map, journey, concept list or state chips in Study mode; the
  conversation is the product, with one slim row above the message box (Study mode · Hint · Explain instead · Stop).
  The useful part of the old map (a diagram of how concepts connect) moved to the paper's AI Explainer, about the paper
  rather than about the reader.
- **The entry sends at once.** "Enter Study Mode – Quiz me and help me learn" is a command, not a question to edit, so
  one tap enters the mode and sends the opening turn; Hint and Explain instead send too. Every other suggestion still
  only fills the message box. Reversible if accidental taps cost readers credits.
- **The learner state is the tutor's own hidden notes in its reply** (one request per turn, instead of a second Haiku
  request that rebuilt a map without the paper). The server strips and checks them and the device sends them back; they
  live in memory with the open chat, are never stored or logged, and a lost copy is re-derived from the conversation.
  Open for the owner: keep them with the conversation (a sealed field) so Study mode resumes after relaunch.
- **Older builds keep working**: their `study` map is accepted and ignored; they get the new tutor and an empty map.
- **The tutor prompt was chosen by evaluation**, six iterations on simulated learners (strong, weak with hint and
  explain-instead, a persistent misconception) over Attention and PPO, Gemini 3.8 Flash and one Sonnet 5.5 check, $0.73
  of the $1 allowed. Changes it drove: no stock praise, one-thing questions, one idea per explanation, teach before asking
  at intro/core level, misconceptions kept in focus until dropped, look backs only to earlier ideas, no talk about the
  method.
- **The paper's AI Explainer is a chat action with a streamed JSON reply** like the figure walkthrough (same cache, same
  progress rules), its diagram drawn on the device from entries and links (deterministic Mermaid, so it cannot fail to
  parse the way a model-written diagram can). It is **settled as an ordinary answer** (`answer`) rather than adding a
  settlement action: a migration numbered after the parallel usage work's unapplied 0144 would have made that work's
  deploy fail the applied-prefix check. A dedicated settlement action can be added later in sequence.
- **Visual suggestions**: at most one of the model's follow-ups may ask for a diagram or visual of something concrete;
  the generic diagram/visual rows show only when it doesn't.

## Figure explainer: streamed, at low effort (owner request 2026-10-22; agent decision with evidence, reversible)

Owner: "On the Figure AI explainer, I like the experience, but it's very very slow. Can we make it much much faster?" and
"it's unusable at this speed. Also it needs a progress bar." The experience is kept (summary, then part cards as
confidence-framed viewports); what changed is how fast it arrives:

- **Streamed.** The walkthrough is asked for as JSON in the model's reply (Gemini Flash returns a tool call only whole,
  measured), read incrementally on the server and relayed part by part, each checked exactly as the final walkthrough is;
  the final `figure` event is unchanged for older builds. A real progress bar on both clients (stages, then "part k of
  N" from the model's announced count, else the figure's own sub-figures or caption letters).
- **Low effort for the figure view** (`figure`, `figure_simpler`) when the reader chose Gemini Flash (its profiles have no
  effort choice) or left the effort automatic; an effort chosen for a Claude model stays. The published chat default
  (Gemini Flash, medium) is unchanged for every other chat request. Evidence, four real figures (DPO 1 and 2, PRISM 5,
  Memory-efficient subspace optimization 1): Gemini at medium thought for up to 3,800 tokens and showed nothing for
  19–45 s; at low it read the same panels, values and legends with a box on every panel part, summary on screen in
  ~3–4.5 s and the whole walkthrough in 8–11 s, at about two thirds of the cost. Haiku 5.5 at low was fastest but drew no
  boxes on three of four figures and once wrote malformed JSON; Sonnet 5.5 at low matched Gemini's speed at 2–3× the cost
  (and once returned no usable part). Record: FIGURE_VIEW.md "Speed".
- *Superseded the same day by "Figures default: Gemini Flash again" (above).* **Figures default: Claude Sonnet 5.5 at low effort** (owner, 2026-10-22: "I think we should probably change the default
  to Sonnet for that one", after "I tried Sonnet, it was much faster than DeepSeek"). Published as `default_figures`
  (`sonnet-low-standard`); new readers, readers with no saved figures choice (the activity no longer inherits the general
  chat default) and readers whose saved choice was the old recommended `gemini-medium-standard` (migrated once) start
  there; any other explicit choice stays. Live: summary in 3.6–4.5 s, whole walkthrough 10–12 s. Cost: ~$0.022 a
  walkthrough when the paper is in Sonnet's cache, but the first Sonnet request on a paper writes it to the cache
  (~$0.24 on DPO, 49,000 tokens) — a reader whose paper chat uses another model pays that once per paper per hour. The
  ⓘ text for the activity says speed differs and DeepSeek is slower.
- **DeepSeek in the figure view at low effort writes without thinking** (its "low" still thought ~1,800 tokens: 24 s
  before the first word on DeepInfra). Live: 3.5–3.9 s to the summary, 15–19 s whole (was 19–97 s with medium).
- **DeepSeek route: proposal, not switched.** Together (OpenRouter ZDR) was 2–3.5× faster than the pinned DeepInfra FP8
  in every measurement at about three times the (still sub-cent) price; the maker's endpoint is still refused under ZDR.
  Switching needs a consent text naming Together AI (new consent version and client release) and a reviewed tariff
  card; the owner decides.

## PDFs without arXiv HTML: keep developing the on-device model; no Mathpix (owner, 2026-10-21)

Owner, verbatim: "Ok, well maybe we can just continue to develop the on device version then? The current version
feels too slow, and not accurate enough, but maybe we can improve it?" This follows the same day's "the local model
for entire PDFs is too ambitious" and the Mathpix research
([MATHPIX_FALLBACK_20261021](research/MATHPIX_FALLBACK_20261021.md)). Decided:

- **Mathpix is not built.** The research stays as a record; the device-only rule for PDFs (no server PDF
  acquisition, upload or processing, no Mathpix fallback) stands as written in the user constraints.
- **The on-device PDF route stays the PDF path** and remains experimental, behind Settings › Experimental, beside
  the arXiv HTML reader, which stays first-class. Work on it is now development of the app's own route (speed first,
  then accuracy), measured against the arXiv HTML of the same papers where it exists, with before/after numbers for
  every change ([DEVICE_PDF_ROUTE](architecture/DEVICE_PDF_ROUTE.md),
  [review 2026-10-21](reviews/DEVICE_PDF_ROUTE_20261021.md)).
- The desktop's port kit (converter 0.1.0) stops being a frozen reference the app must match: the app may diverge
  from it where measurement shows a gain. Agent decisions taken under this direction (reversible, each measured):
  the recogniser ships as one batched multifunction Core ML package (same weights; same tokens on its samples); the host overlaps
  the stages and shows a reading before its formulas are read; seven converter rules are on in the app (simple inline
  formulas from the text layer, font-found math, tidied LaTeX, title page by metadata, no duplicate headings, reference
  entries split, line ownership) and one tried rule is off (`extendSpans`); the display-formula gate is unchanged (a
  lower threshold would typeset more displays at lower precision: an owner choice, not taken). The desktop project (`/home/ben/mathpix`) stays read-only; new training or
  export work runs in `/home/ben/science-reader-device-pdf` on the desktop, and any new model reaches the app only
  through `scripts/device-models.mjs` and a lock update.
- 2026-10-23 (owner: "if it works it will be a big unlock for non arXiv papers"; agent decisions, reversible, each
  measured on two arXiv corpora and a new 31-paper corpus of venue PDFs, [review](reviews/DEVICE_PDF_ROUTE_20261023.md)):
  ten more converter rules are on in the app (equation numbers out of the recogniser's crop, overlapping displays as
  one, line bands, font aliases, caption math, word gaps, headless bibliographies, display punctuation, text accents,
  venue notices); a page with no usable text layer (a scan, or fonts without a Unicode mapping) is read with Apple's
  on-device text recogniser (Vision), on the device only; the display gate stays at 0.95 (0.9 loses typeset precision on
  every corpus); the recogniser's export gains a 512-token decoder cache (same weights; only formulas the old cache cut
  off read differently; lock updated). Venue PDFs used for evaluation are open-access local research copies on the Mac,
  never in the repo.


## Subfigures: rough zoom is the goal (owner, 2026-10-21)

After labelling test figures himself ("more awkward than I thought it would be"), the owner set the product goal: "if we
can just get a rough zoom in at the point where we think it is, that is already a huge win, and if it's not always
accurate that's ok, or we can back off in cases where the evidence or confidence is really awful." The success measure
for subfigures is therefore reader-facing: **right zoom** (the viewport centres on the correct panel and shows most of
it), **backed off** (a looser frame or the whole figure with the part outlined) and **wrong zoom** (the view lands on a
different panel or cuts the intended one misleadingly) — wrong zoom is the failure to keep very low. Pixel-exact panel
boxes (the earlier ≥95% recall / <2% wrong-crop gates) are a research target, not the release bar. Human test labels are
collected by tapping once inside each panel (the private labelling page, test-3 figures), with boxes optional.

## One figure result: "Extract the subfigure" removed (owner, 2026-10-21; implemented locally, not released)

Owner, verbatim: "Let's not do extract the subfigure, users can always go to the original feature and just zoom in if
they want. Let's simplify our life by trying to consistently create one good product experience in the AI result that
comes back." This supersedes "the extract/more-parts requests kept" in the viewports decision below.

- The walkthrough (summary + parts as viewports into the whole figure) is the single figure AI result on iPhone, iPad,
  Mac and the browser. Looking closer = zoom/expand the viewport or open the figure page.
- "Extract the subfigure and more context" (`figure_detail`) is removed from every client entry point, view and test.
- Follow-up rule (agent, under "prefer fewer options"): a part follow-up stays only if it returns words into the same
  walkthrough with no new crops or presentation. **Explain more simply** (`figure_simpler`) meets it and stays; there
  was no "more parts" request to remove. Show in the paper, Save snippet and Ask about this part are not AI results.
- Old kept detail answers are hidden (native: not looked up, not listed; browser: dropped on restore). No migration.
- Server keeps accepting `figure_detail` for installed builds 63–79, marked DEPRECATED in code and docs; remove it once
  no supported build sends it. Details: [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Extract the subfigure removed".

## Figure parts as viewports, framed by confidence (owner, 2026-10-21; implemented locally, not released)

Owner: "in different panels, when we present it, we present it in such a way that if it's inaccurate, the user can just
click and see the whole figure, so we present it as a crop of the whole thing, that they can expand, rather than an
actual crop", with framing chosen by confidence, the extract/more-parts requests kept (superseded the same day: Extract
removed, above), and nothing misleading shown.
Design and thresholds: [Parts as viewports](architecture/FIGURE_VIEW.md#parts-as-viewports--2026-10-21-local-source-not-released-not-deployed).
Agent choices (reversible): the confidence signals and their weights; a white veil (opaque on a tight frame so it looks as
the crop did, soft on a loose one, none on the whole figure); extras beyond the caption's panels shown as the whole figure
with the part outlined; chat's parts framed by the same rules but not pinchable in the transcript (as before).

**Proposal, not decided — a future opt-in training signal from framing interactions.** Owner, same day: "It can be a
good UX compensating and working together with limits of ML, while still pushing ML as far as possible. Ideally, we could
even log the data (later) from zoom behavior and build a training dataset." Nothing is collected or uploaded now: the apps
keep one geometry-only record per part card in memory (cleared on sign-out) behind one type
(`FigureFramingRecorder` / `figure-framing-record.ts`) so a later upload has one place to attach. Any collection would be:
**opt-in only** (its own consent, off by default, separate from chat consent); **geometry only** (the figure's identity,
the AI box, the completed region, the frame, the reader's final view, expanded or not — no text, no reading history, no
timestamps beyond what the layout needs); **public arXiv figures only** (never local PDFs, snippets or notes);
**no account linkage in the dataset** (no account, device or membership identifiers in what is stored); and the **data
layout, retention and deletion designed and reviewed before any collection**.

## AI recommendations (owner, 2026-10-21; decisions delegated; implemented on a branch, not deployed)

Owner, TestFlight 78: "I want two more features: an AI recommendations, it uses AI with our server to search for the
most similar papers and just adds them, users should have the option of requesting 1, 3 or 5." On the proposal's open
questions: "For your similar papers, just take your best judgement, and try to create a good experience out of it."
Decided by the agent under that delegation (reversible; reasons in [AI recommendations](architecture/AI_RECOMMENDATIONS.md)):

- **Adds at once** (as asked), then a sheet shows each paper as it is added with a one-line reason, a Remove on each and
  Undo for all. No review step.
- **1, 3 or 5**, a submenu directly under Find similar papers (Library row, Paper ⋯, Mac's Paper menu, browser ⋯), and
  **Recommend for this catalog** in the Library's ⋯ (up to 8 of the catalog's newest papers as seeds).
- **1 credit per request**, whatever the count, charged only when at least one paper was added; shown before and after.
  Undo does not refund. **20 requests per account per day** and 30 an hour, enforced in the database and at the request
  gate; the platform budget, holds and testing caps apply unchanged.
- **Claude Haiku 5.5 through OpenRouter** (Vertex US, already priced and admitted), one call that can only choose among
  candidates found without a model: DataCite searches from the paper's keywords plus the Feed pool's full-text index.
  Our servers still never contact arXiv. Everything the reader has or had, and Feed "Not interested" papers, is excluded.
- Added to **the catalog being viewed**; no separate "Recommended" catalog. No new consent: only public titles,
  authors and abstracts are sent, like catalog tags. Local PDFs never seed a request.
- "Chat about this paper" (the proposal's second part) is not covered by the answer and is not built.

## OpenRouter exclusively; cost per account (owner, 2026-10-21; implemented locally, not deployed)

Owner, verbatim: "I don't think Anthropic API should even be part of deploy check. I want to double down and
exclusively use open router for better breakdowns of user by cost."

This extends the 2026-10-18 decision (below): OpenRouter is the only inference provider in code, configuration and
checks, not only at runtime. Direct-provider rate cards, the Anthropic SDK client and its stream adapter, the
server-side-fallback beta, provider-native web search and the always-on routing switch are removed; the server keeps
its own Anthropic-Messages-shaped request type (`model-request.ts`), which `openrouter-chat.ts` translates into
OpenRouter's chat/completions body. `@anthropic-ai/sdk` is no longer a dependency. Web search in chat is only our
`search_web` function tool, called through OpenRouter and run by our server with Tavily (prepaid plan); no
provider-native search exists. The egress guard keeps refusing every direct model host (now with a host-only log line,
and Google's text-to-speech host added). Deploys no longer set `CHAT_CLAUDE_OPENROUTER` and remove any
`ANTHROPIC_API_KEY`/`DEEPSEEK_API_KEY` left on the project; the workflow check fails if one is present.

Budget and health checks reason only about OpenRouter attempts (migration 0140). Attempts of retired direct providers
stay in the ledger, in the month's spend and in its reservation; they are reported as **legacy**, by provider, with
the ceilings they still hold, until an owner reconciles each with the provider's evidence (the October 17 Anthropic
attempt is being settled separately). Tavily's prepaid searches are counted apart.

Per-user cost breakdowns come from our own ledger: every provider attempt carries the account UUID, route, model and
feature (089). Admin › Costs (migration 0141, owner with MFA) shows each account's AI cost this UTC month and over the
last 30 UTC days, by feature and by model, with totals, held liability, prepaid searches, credits charged and the
legacy share. Accounts are named by their pseudonymous UUID; the sign-in email appears only where Accounts shows it.
OpenRouter receives the same UUID as each request's `user` (never an email); OpenRouter documents that field as an
abuse-isolation identifier hashed upstream, and its documented Activity grouping is by model, key or org member, so
the ledger is the per-user source and OpenRouter's generation records are the per-request cross-check
([Operations](architecture/OPERATIONS_AND_BILLING.md#openrouter-exclusively-and-cost-per-account--2026-10-21)).
No budget, price, credit rate or consent text changes; the $100/month operating budget is unchanged.

## No import quota (owner, 2026-10-21; implemented locally, not deployed)

Owner, verbatim: "I'm not sure why import quota is even a thing? Users can import and download whenever they want if
it's free". Adding papers, importing, removing and downloading cost Gradstep no provider money since every PDF stays
on the device. The lifetime counts (2,000 imports and memberships per account, 12,000 library commands per account,
the service-wide 20,000/120,000 and the 10,000-record shared catalog) no longer refuse anything (migration 0142: a
NULL limit is no limit). Kept as abuse protection a reader adding papers by hand never meets: the request rates
(add-paper and add-reference 120 an hour, library-write 1,000 an hour), a backstop on imports in flight (100 per
account, 2,000 for the service; was 10/100) and the existing per-row and storage bounds. Paid AI work keeps its
credits, holds and budget. The apps' 4,000-entry local library bound and their quota messages are owned by the app
agents; where they appear is listed in [Library capacity](architecture/LIBRARY_CAPACITY.md#no-import-quota-2026-10-21).

## Builds 66–76 open screenshot feedback (owner requests; 2026-10-21, implemented on a branch, not released)

The owner's builds 73–76 requests are implemented as asked (see the triage report's §0). Decisions they settle:
the Library header is an explicit owner exception to the top-bar rule (catalog left of the search field; Add paper…
as the first row of the far-right menu, the browser's account menu); recently added unread papers keep their
build-42 signal as the word "New" instead of an accent dot; Chat about Figure/Table and AI Explainer are drawn alike;
an explainer continued in Chat stays (it is named for its item and Back to chat returns to it; a morph transition is
still open). Generic keywords (LLM, Large language models, Reasoning, Evaluation, …) are hidden from derived
keywords and catalog tags in the apps; catalog tagging and the vocabulary version are unchanged, and a tag the reader
types stays theirs. A screenshot inside Gradstep offers Report this screen (default on, Settings can turn it off);
in-app report snapshots cover the recovery code and other codes. The client refuses to add an arXiv paper already in
the library; server idempotency is separate server work.

## Notes and snippets (owner, October 20 local / October 21 UTC; design and prototype)

The owner requests personal encrypted notes synced through the existing Supabase/device-key machinery. A note
is a sequential collection of captured paper regions and optional editable writing; capture starts from a hold
action offering ordinary text selection or Draw snippet, and saves to an existing or new note with paper/date/time
recorded automatically. Notes supports create, rename, delete and commentary editing. The owner proposes replacing
Settings with Notes in the five-item bottom bar and making Settings available from every top-right menu; this is
explicit direction for those navigation changes.

The reviewed proposal is [Notes and snippets](architecture/NOTES_AND_SNIPPETS.md), with an interactive design
prototype. Recommended details preserve default text selection, paper/chat arrangement and reading position;
source-linked crops are encrypted on the device before sync, while whole PDFs stay device-only. Existing note events
include catalog metadata, so user notes need a separate payload namespace. Media requires a new bounded encrypted
blob service; the planned `encrypted_blobs` entry in DATA_MODEL.md is not an existing implementation. The design
records conflict/deletion semantics, old-client compatibility, capture feasibility, budget and release gates.
This is design work, not a deployed Notes feature, new infrastructure commitment or E2EE verification claim.
Update 2026-10-21 UTC: the reviewed implementation contract's server side is live on staging (migration 095 and
the `note-assets` function, quotas inside the existing budget, no new vendor commitment); clients are separate work.
That is a ciphertext transport, not evidence of client encryption or cross-device Notes sync.
Update 2026-10-21 UTC (browser, local, not deployed): desktop browser widths add Notes to the existing destinations;
at phone widths (≤640 px) the browser follows the apps' five destinations, Feed · Library · Paper · Chat · Notes,
with Settings in the top-right ⋯ (implementation direction for this delivery). Arbitrary-region capture in the browser
uses a local rasterizer inside the reader frame; it passed fidelity checks on real bundles in Playwright's Chromium,
Firefox and WebKit, and a runtime probe disables Draw snippet with a message where it can't work. Details and limits:
[browser client status](architecture/NOTES_AND_SNIPPETS.md#browser-client-status--implemented-locally-not-deployed-2026-10-21-utc).
Update 2026-10-21 UTC (iPhone, iPad and Mac, local, not in TestFlight): the iPhone tab bar is Feed · Library · Paper ·
Chat · Notes and every top-right ⋯ ends with Settings, shown over the screen; iPad and Mac add Notes to their view
switch and keep their own Settings control and ⌘,. Capture adds a Draw snippet entry to the selection menu beside Add
to note and a Paper menu pair on the Mac (no shortcuts); no persistent reader shortcut was added. The native and
browser codecs accept exactly each other's records (shared cross-client fixtures). Details and limits:
[native client status](architecture/NOTES_AND_SNIPPETS.md#native-client-status--iphone-ipad-and-mac-implemented-locally-not-released-2026-10-21-utc).

## Responsiveness, dollar balances and platform parity (October 20; parity released, dollars design only)

The owner wants faster response to navigation, a dollar balance with each user's OpenRouter spending and
category totals, and the same recent updates on iPad, browser and Mac. The owner explicitly confirms **no markup
for now**. Exact provider cost must replace per-answer credit rounding before the UI calls its balance dollars.
Keep provider expense, customer debits, unresolved receipts and the authorized unlimited testing allowance distinct.
Do not present the organization's OpenRouter funding as an individual reader's balance.

Navigation should acknowledge the selected destination without waiting for unrelated storage or network work.
Accepted drafts remain owned by the account controller while device persistence completes; storage failures stay
visible and recoverable, and sign-out/deletion retain their durable-write barriers. Do not retain unbounded decoded
papers or hide loading failures to make navigation appear faster. Preserve the native scrolling repair.
The platform audit records existing release evidence, missing behavior and new verification separately:
[October 20 parity review](reviews/PLATFORM_PARITY_20261020.md).
The native/browser responsiveness and parity changes are released: iPhone/iPad and Mac TestFlight **77** are
VALID / IN_BETA_TESTING, with notes read back at **15:55:20 UTC**; browser Pages **27c45ca0** has matching live
assets and app association. All three use source **562ba8b**. The import/session gate passes **15/15, zero skips**,
and both signed archives pass platform, symbol and test-probe exclusion checks.
Dollar settlement and its three client screens are still design only, specified in
[Dollar balance](architecture/DOLLAR_BALANCE.md); this parity release does not rename rounded credits as dollars.

## Native chat scrolling (owner, October 19 local / October 20 UTC)

The owner reports chat vibrating against a drag during both completed and streaming answers. Preserve the existing
arrangement, selection, keyboard and follow/scrollback behavior. The offline negative control reproduces changing
row heights at screen edges; streaming also exposes an unnecessary offscreen snapshot update. Contained hosting
rows, stable measured estimates and deferred presentation during gestures address these measured causes.
Motion/keyboard/selection checks and the fresh 15-case import gate pass. iPhone/iPad and Mac TestFlight **76** are
VALID / IN_BETA_TESTING with notes verified; both archives use the same **365aeaa** source.
This does not establish physical-phone acceptance or qualify browser/contextual-chat scrolling.
See [Chat](architecture/CHAT.md#native-transcript-sizing-audit--2026-10-20-utc).

## Owner testing allowance and $5 usage pricing (2026-10-19; testing allowance deployed)

Owner requests unlimited testing for the current account and pricing based on $5 of OpenRouter usage.
Unlimited means an explicitly authorized, automatically replenished **testing adjustment**, not an App Store
purchase or unlimited provider funding. Keep all existing provider attempts, account attribution, operation
ceilings, concurrency limits and the $100/month operating budget. It belongs to the current UUID and does not
transfer after deletion. [Accounting design](architecture/SPENDING_CONTROLS.md#unlimited-owner-testing).

Migration 094 is deployed and the freshly verified owner UUID has this allowance. One audited enable created
100,000 available testing credits and zero reserved. Installed clients work immediately with that real balance;
new native wording is in iPhone/iPad and Mac TestFlight 76. Browser wording is deployed.

The $5 purchase interval (nonexpiring top-up versus monthly allowance) is being clarified before changing
published purchase terms. Existing credits round per answer, so they must not be presented as an exact dollar
wallet without changing settlement as well.

## Returning beta testers and named catalogs (owner, October 19 UTC; implementation in progress)

Account deletion must not revoke a tester's invitation. The October 17 manual re-admission repaired one login but
left the cause intact; the owner reproduced it after another deletion on October 19. Separate durable beta
admission from the deletable Auth user. Permit creation only through an exact-email allowlist enforced by the
Auth before-user-created hook, retain explicit revocation, and preserve verified linked-provider addresses.
Returning users get a new UUID with no restored content, roles, keys or credits. Never infer identity from
TestFlight contact information. Configure and verify the deny-by-default hook before lifting the global signup
block; this does not authorize public signup. See NATIVE_AUTHENTICATION.md for the rollout and retention contract.

The owner also requests Library → top-right menu → Catalogs: rename the existing catalog, create/switch named
catalogs, select a default, and delete with an explicit choice to delete its papers or move them to an existing
or newly named catalog. Preserve the Library's layout and paper/chat identities. One catalog per paper; additions
belong to the currently selected catalog. Catalogs are merged into main after the authentication and queued-change
repairs, using bounded metadata in existing encrypted note events. No new schema is required. Core/native data
checks, iPhone/iPad catalog journeys, six browser journeys and the 15-case import gate pass. Browser Pages
`3f363fda` is deployed with live assets verified; iPhone/iPad and Mac TestFlight 75 are VALID / IN_BETA_TESTING
with release notes verified. Both archives use the same tested `0344e4d` source.
See [named catalogs](architecture/LIBRARY_CATALOGS.md).

## Existing Mathpix-replacement research collection (owner, October 18 local / October 19 UTC)

The owner asks us to locate the PDF-saving service in the `mathpix` project and use its existing papers to improve
subfigure training, explicitly without changing that folder. It is `/home/ben/mathpix` on the authorized GPU host;
the existing `gradstep-acquire.service` saves public papers under `data/arxiv/`. Read manifests and copy a bounded
sample out; do not edit its code/data, invoke its processing pipeline, inspect secrets, or manage its services.
This is an existing independent research collection, not permission to add server PDF processing to Science Reader.

Parse/render the copied PDFs on this Mac only. Transfer only reviewed public figure images/annotations into the
isolated training workspace. Verify hashes, exact PDF/label geometry, article license metadata and split/duplicate
boundaries. Its generated layout labels are candidates, not subfigure ground truth. Keep Codex visual annotation
distinct from independent human review, and preserve the reserved final test. No new paid service or release is
authorized by locating this dataset. Inventory, provenance and the first comparison are in the training review.

## Subfigure fine-tuning on the owner's GPU machine (2026-10-18; authorized, qualification pending)

The owner explicitly authorizes SSH to `192.168.1.32` for fine-tuning and iteration until the subfigure detector
performs strongly. Use an isolated `/home/ben/science-reader-subfigures` workspace on that machine; preserve the
earlier source checkout and unrelated workloads. The inspected GPU is an idle RTX 3090 (24 GB), with 87 GiB
available system memory and 1.4 TiB free disk. This authorizes research training on that existing machine, not a
GPU rental, production PDF processing, transfer of private reader content/credentials, or an app release.

Keep immutable source/license/hash manifests, paper/family-disjoint train/validation/test splits, separate run
directories and checkpoint/metric provenance. Iterate on validation errors; reserve an independent final test.
The seven previously examined FDE-Gym images are development regressions, not an untouched test. Synthetic
results alone cannot establish performance on scientific papers. Preserve the panel/context/coverage gates in
LOCAL_FIGURE_REGIONS.md; an unqualified model remains a research artifact. Mac-only deployment and the paused
physical-iPhone restriction remain unchanged.

## OpenRouter exclusively, Mac-only local AI, build 71 feedback (owner, 2026-10-18; rollout shipped, replacements qualifying)

Six further screenshots (20:45–20:56 UTC) request: all reference actions visible together; Contents opening at full
height; a touch double-tap in article text opening Contents with a persistent, first-use hint; instant section jumps;
separate Library Device and Authors columns; and removal of the visible keyword Edit label. These explicitly
authorize those interaction changes. Keep Copy, Open, Add and Discuss, long-press text selection, interactive paper
elements and Mac double-click selection. Save gesture discovery on this device only after it actually opens Contents;
opening Contents by its button does not mark discovery. Existing column choices gain Device/Authors once, then remain
customizable. The heading-jump bridge still requested `smooth` independently of the already repaired reference jump;
test with reduced motion disabled. Affected journeys and the fresh 13-case import gate pass; exact native release
state is recorded in IMPLEMENTATION_STATUS.md.

Additional feedback ALCJLruWVHFOYNzJoULIvSY (20:07 UTC) requires every pixel to remain represented when a figure
is divided into cards; grouping several panels in a card is acceptable. Cards distinguish panels, concepts and
related work, with consistent titles. Keep the existing figure/conversation/navigation arrangement. Extend the
bounded walkthrough additively with optional card kinds, retaining old encrypted answers. Verify crop-union
coverage deterministically; an incomplete split keeps the complete overview and explicitly explains why. Do not
claim this fallback is a successful extraction, or invent missing panel geometry. Related-work cards cite what
the supplied paper says and do not imply that an external paper was fetched. See FIGURE_VIEW.md.

All remote model inference must use OpenRouter, including DeepSeek chat, catalog classification, podcast writing,
review and speech. Remove direct-provider fallback. Preserve device-only PDF acquisition/processing, current
consent, durable admission, actual-cost reconciliation and the $100/month operating budget. Attribution is mandatory
before transport: account UUID for user work; a stable service identity for shared catalog/research work; operation,
attempt, route and timestamps. Keep the existing provider ledger authoritative, with generation IDs, model/endpoint,
rate snapshot, token/cache/audio counts, exact cost or unresolved liability. Do not log prompts, answers or paper text.
Design the ledger/API changes in PROVIDER_SPENDING.md before adding migrations; verify every paid call path.

Local answering-model downloads/inference become Mac-exclusive. iPhone and iPad builds must omit MLX and its model
catalog/resources, not merely hide the controls. Existing encrypted local explanations/history remain readable; an
old local answer never silently turns into a paid cloud request. Retire the small prototype choices. Evaluate two
strong Mac options on scientific questions with real native inference, measured memory, cancellation and offline
checks; a candidate is not accepted merely because it runs or has a good published benchmark. Target 16/32 GB Macs
pending the owner's optional memory-tier preference. PDF preparation remains on-device and is separate from chat.

Seven new screenshot reports are under `.artifacts/feedback/build71-20261018/`: stale equation pixels after switching;
excess equation/model spacing; initial Default (abbreviated model) / Choose model actions; full Figure/Table/Equation
reference phrases as links; “Gradstep Keywords”; a launch restored into an empty Machine learning filter; reopening a saved figure explanation without another model choice. Reproduce
and verify the affected behavior before another release. Continue subfigure detector/export/fine-tuning research,
using held-out papers and label/legend containment; no unqualified detector is included in the app.

## Build 70 feedback: navigation, discovery and figure regions (2026-10-18; implemented, release verification recorded)

The owner explicitly requests: a find occurrence list; direct reference jumps; Back to the exact figure/table
explainer after a citation; a Chat icon that opens the same contextual conversation in the main chat; fullscreen
figure/crop viewing; per-scenario AI defaults; optional field-based search; similar-paper discovery; two share
choices; and specific, attributed, editable keywords before Introduction. Existing encrypted histories and
per-chat explicit selections remain authoritative. No silent model/provider fallback or automatic paid calls.

Find becomes an app-owned row with bounded, non-mutating text ranges, match highlights, previous/next and an
occurrence table. This replaces the system find interaction whose keyboard/safe-area lifetime leaks across tabs.
The reader location survives close/tab changes, and finding never creates a selection or alters paper bytes.
Explainer citation return records paper, exact bundle/item and conversation independently of sheet dismissal;
promotion into Chat transfers that same composer, preserving the previous draft and explanation context.

Share has Source URL and Gradstep link. Public links carry only a normalized source identity/revision, never an
account ID, token or private text: `https://app.gradstep.ai/p/arxiv/{id}` or `/p/doi/{encoded-doi}`. Optional
future `figure`/`table` targets are reserved in a bounded fragment. Installed library membership opens the paper;
otherwise open a search for that identity, without automatically importing it. Universal links need the signed
Associated Domains entitlement and matching AASA plus a browser landing route before being claimed working.

Keywords exclude generic artificial intelligence/machine learning tags. Distinguish author/source keywords,
Gradstep-derived terms and user edits. Use a bounded, device-only in-memory inverted index over verified installed
bundle text for discriminative terms and local search; it is rebuilt from encrypted bundles, has no plaintext
persistent copy, and removes a paper synchronously on content removal/account retirement. No server upload.

Investigate a dedicated local panel detector, independent of the chat model. Region coordinates bind to the
original image digest/dimensions and normalized top-left coordinates. Preserve axes, labels and shared legends;
low confidence keeps the full figure with visible uncertainty. Both cloud/local explainers and ordinary chat
consume the same region artifact. No model ships until licensing, conversion, quality and resource checks pass;
Mac/simulator evidence never substitutes for the paused physical-iPhone acceptance.

Implementation and the Mac Core ML detector experiment are complete. Browser Pages 13724098 and the chat/search
backend changes are deployed; the source-matching import gate passes 13/13 without skips. Native release state,
the verified Mac figure correction and the remaining intermittent import-test limitation are recorded in
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).
The measured detector is not included in the app: high-confidence crops still omit interpretation-critical text,
and its AGPL research weights have not passed the distribution gate. See
[measured results](reviews/LOCAL_FIGURE_REGIONS_20261018.md).

## Build 69 feedback: contextual AI and model management (2026-10-18; TestFlight 70 and browser deployed)

The owner explicitly asks equation and figure explanations to share their view with conversational follow-ups,
without navigating to the main Chat tab. Keep the equation/image, structured explainer, citations and general
conversation together. Reuse the established encrypted chat event store, account fences, request routing and
credit admission; no separate plaintext transcript or backend schema. Opening a view must not spend credits.
A chosen AI Explainer or an explicitly sent question is the request. Context switches must not mix equations,
figures, papers or accounts. Saved explanations and conversations remain available under their existing semantics.

Replace the long inline model downloader with a concise default/cloud/local choice. Settings owns downloads,
compatibility and measured performance. Offer installed, usable local models at question time; explain unavailable
models before download. Never pretend Mac tests verify an iPhone. Model names replace redundant Cloud AI labels;
local model names end in “(local)”. Preserve the chosen/served-model distinction and no silent provider fallback.

Add the explicitly requested author search, editable keyword row before the introduction, equation menu cleanup,
automatic zoom/pan, crop zoom, Library metadata fixes and chat composer controls. Keywords are per-reader metadata,
not a mutation of the verified paper bundle. Dictation, if supported, writes a draft only, with explicit microphone
permission and on-device recognition; it never sends a question automatically. The complete checklist is in
[OWNER_FEEDBACK.md](OWNER_FEEDBACK.md#build-69-feedback--2026-10-18-testflight-70-on-ios-and-mac).

## Build 68 equation hang and cloud model failure (2026-10-17; repaired, TestFlight 69 on iOS and Mac)

The owner reports an indefinitely loading Equations tab and a default explainer that fails without explaining why,
and asks why Claude still bypasses the funded OpenRouter account. The actual feedback paper (1805.03662v2, 105
formulas) reproduces a local markup-scanning performance defect. Fix the scan and verify that exact Contents
screen. Name/select the cloud model in the existing AI chooser and offer recovery on the failed explainer itself.
Move Claude **chat-route** models and their title/suggestion/study helpers to the authorized OpenRouter connection;
Flash remains recommended, explicit saved choices remain respected, and separate catalog/podcast routes retain
their current adapters. Named v5 consent, a fixed reviewed ZDR-eligible endpoint, immutable provider pricing and
server spending admission remain mandatory. No operating-budget increase or new model comparison. Migration 087
and the funded route are deployed and verified; native build 69 is available on iOS and Mac, with both platforms
confirmed VALID / IN_BETA_TESTING at 23:46:40 UTC.
Details: [equations](architecture/EQUATION_VIEW.md), [routing](architecture/GEMINI_FLASH_CHAT.md).

## Owner test-account allowance (2026-10-17, verified)

The owner explicitly requested 100,000 starting credits for the fresh test account. One nonexpiring, audited
server-ledger adjustment was applied at 08:39 UTC; readback confirms 100,000 available and zero reserved.
This is a one-account testing allowance, not a subscription, purchase, automatic returning-account entitlement,
or provider-budget increase. The normal dashboard adjustment cap and all spending admission remain unchanged.
See [billing evidence](architecture/OPERATIONS_AND_BILLING.md#fresh-owner-test-account--2026-10-17).

## Optional local AI prototype (owner direction, 2026-10-17; implemented, experimental)

Prototype an explicit Cloud AI / Local AI choice for chat, equation explanations and figures, with an on-demand
MLX model download. The owner's initial Qwen3 0.6B idea is a text baseline; the scientific-image follow-up adds
Qwen3.5 4B versus Gemma 4 E2B, with 2B as a smaller candidate. Use selected figure crops, captions, existing LaTeX
and retrieved paragraphs within a measured token/memory budget. The crop-plus-text recommendation does not change
the device-only PDF/Mathpix decision. No cloud fallback or default-provider change is implied. Architecture and
acceptance: [Local AI](architecture/LOCAL_AI.md). Physical iPhone testing remains paused.

The native prototype now offers explicit Cloud/Local choices and verified, removable model downloads. The local
comparison favors Qwen3.5 4B for explanation quality, but both it and Gemma fail numeric-figure checks. Measured Mac
process footprint is about 6.7 GB for both larger models and 3.85 GB for Qwen2B; no phone readiness is inferred.
The owner subsequently requested a build to try the prototype (2026-10-17). Prepare an internal TestFlight release
with the experimental label and memory admission checks; this authorizes distribution, not physical-phone testing.
Phone acceptance remains outstanding under the existing pause. These results do not change the cloud default.
Evidence and limitations: [local comparison](reviews/LOCAL_AI_20261017.md).

## Import acceptance after build 65 feedback (owner direction, 2026-10-17 UTC)

Adding papers and PDFs must be a release gate, including the actual reported failures. `npm run test:imports`
exercises the native Library, device downloads, encrypted installation and offline reopen with release optimization.
It includes pinned responses for all six reported papers, local Files PDFs, missing HTML, cancellation, retry and
the Library's adding-row geometry. Upload scripts require a successful, unskipped run matching the current import
source and Xcode version. This is explicit Simulator acceptance, not physical-phone or hosted-account acceptance.
See [Testing](TESTING.md). Automatically opening a PDF when HTML is absent would change navigation; that proposal
awaits the owner's response. The existing explicit Open PDF flow remains.

Build 66 feedback also requires definitive remote session rejection to retire cached sign-in across every cloud
action. Offline reading remains available during transient outages; a rejected session clears presentation and
credentials but preserves encrypted local files and keys. Hosted two-session deletion reproduces the rejection.
The release gate now includes those account boundaries and the seventh reported paper, FDE-Gym.

Deleting a private-beta account also removes its pre-created Auth login. With signups disabled, returning through
OAuth requires a new invitation for the exact provider address. It creates a new account, not a restoration of
deleted data or credit. The owner reported this on 2026-10-17. At 08:30 UTC beta access was re-created for the exact
address established by the original account's hosted Auth deletion audit and prior successful refresh events.
Asking the owner to identify an OAuth provider was unnecessary: the existing admission API uses the verified address.
Do not infer identity from TestFlight contact information or open public signup to solve it. Hosted acceptance now
covers deletion, rejected old sessions, fresh admission and a successful email-code exchange/account RPC. See
[authentication](architecture/NATIVE_AUTHENTICATION.md#private-beta-return-after-account-deletion).

## Gemini Flash selected for chat (owner decision, 2026-10-16; active 2026-10-17 19:54 UTC)

After reviewing the measured comparison, the owner said **“lets move ahead with Flash”**: Gemini 3.8 Flash at
the tested medium effort is the published recommendation for updated clients. This supersedes the research-only hold below;
the compatibility default remains Sonnet for old clients. Migration 085 and the hidden Flash route passed the focused live checks;
client support is shipped (builds 64–68). The owner explicitly superseded the account-settings verification hold
on October 17: **“I am over riding the check, please make open router work again.”** Activate the verified route
and check the published default; do not ask for that confirmation again. The two account opt-ins remain unverified,
so no claim about their state or end-to-end provider retention follows. Keep request-level ZDR, data-collection
denial, no fallback, named consent and spending admission unchanged. On October 17 the pinned AI Studio endpoint
was reproduced as incompatible with the account's zero-data-retention policy (HTTP 404). Migration 086 fixes the
pin to Google Vertex US with explicit ZDR
enforcement; seven live checks pass. The 10% higher endpoint rates fit the unchanged budget and are recorded in
both quotes and immutable new-attempt snapshots. No automatic failover or weakening of privacy settings.
Activation is verified at 19:54 UTC: the live profile table offers Gemini and recommends `gemini-medium-standard`;
the ordinary published-default smoke completes in 4.5 seconds, actual provider cost $0.001296075. The account
settings hold is waived, not verified. Existing saved defaults and conversations retain their explicit model choice.
OpenRouter through Google's pinned endpoint is the authorized connection for this rollout; direct Google would
be a separate future change. No automatic provider switching, budget increase, or further broad
bake-off is implied. Existing explicit model choices remain respected. Implementation contract:
[Gemini Flash chat](architecture/GEMINI_FLASH_CHAT.md).

### Evaluation evidence before the decision

The owner prioritizes **intelligence per dollar**, including Chinese providers; integration and maintenance cost
must not exclude a contender. The recovered conversation explicitly approves OpenRouter access and **up to $25
for contestants plus grading**. Keep the default unchanged until a paper-specific comparison supplies evidence.
The local harness has an $18 maximum, currently reduced to $10 funded admission, plus the existing $20 provider key limit. No operating-budget
increase or customer-provider rollout follows from this research. Protocol, corrected assumptions and readiness:
[model comparison](reviews/MODEL_COMPARISON_20261016.md). At takeover OpenRouter had $0 credit; after the owner
said continue it reported $10 funded at 20:16 UTC. The matched 12-question screening and independent spot checks
are complete: [measured results](reviews/MODEL_COMPARISON_RESULTS_20261016.md). The [finalist extension](reviews/MODEL_COMPARISON_FINALISTS_20261016.md)
adds the same 15 questions for Haiku medium, Gemini Flash medium and Luna high: 27/27 written answers for the first
two and 24/27 for Luna, whose table-image tool requests sometimes leave no answer. Independent review covers only
four new questions; source checks also identify smaller unsupported claims and disputed completeness penalties.
Recorded spend is **$9.6865303832**, with **no unresolved holds**, within the existing $10 funding. The original
five interrupted calls were reconciled against exact generation metadata. Gemini Flash led the provisional comparison;
Haiku's high first-screen average did not prevent a confirmed algebra error. Further grading, repeated critical
cases and higher-end Chinese comparisons were not completed before the owner's selection. Deployed-adapter and
figure-explainer validation are rollout checks. Do not infer inferiority for untested Chinese flagships.

## Server paper copies deleted (owner decided 2026-10-16)

"Yes, we can even delete them now, so it's obvious we have zero on our system": every historical paper copy on the
server (the old pipeline's PDFs, Mathpix output and reader bundles in `paper-assets`, and any PDF upload chunk) is
deleted, and none may be written again. Rows are kept as history; podcast audio, episode text and report attachments
are out of scope. Design, inventory, client behaviour and evidence: [data handling](architecture/DATA_HANDLING_AND_COSTS.md#server-paper-copies-retired);
migration 080; guarded by the `storage.no-papers` workflow check.

## arXiv HTML first; every PDF stays on device (owner decided 2026-10-13)

The owner changed the acquisition/processing design: PDFs are downloaded and processed only on the user's device;
the initial structured-reader source is exclusively the official HTML version of an arXiv paper. A future local
model replaces Mathpix for challenging PDFs. Preserve the existing reader arrangement, navigation, selection
actions and paper/general-chat experience.

This supersedes all earlier permission to acquire/upload/process PDFs on our servers, including CC0/CC BY,
publisher and user-supplied PDFs, and the proposed Mathpix fallback. HTML absence must never start PDF OCR in the
cloud. The rights gate remains applicable to HTML and derived content; changing format does not authorize hosting.
Cloud chat remains an explicit metered request using necessary text; it is not a PDF processing fallback.

The [HTML-first reader architecture](architecture/HTML_FIRST_READER.md) specifies the local adapter, new honest
bundle provenance/profile, PDF-independent membership, local-context chat, browser acquisition gate, server-side
enforcement and rollout tests. The adapter/location/protocol choices are engineering decisions; no new local model,
deployment, legacy-data migration, deletion or budget increase is implied. **Implemented and deployed on staging on 2026-10-13:** migration 058, metadata-only worker, upload refusal and browser HTML reader. Native build 29 is VALID and IN_BETA_TESTING on iOS and Mac; exact evidence is in the release record. Historical server originals remain retained; this is not a data migration or deletion.

The same-day v2 adapter extension preserves grouped captions and inline vector legends in real arXiv HTML;
its new provenance accounts for inline images separately from fetched assets. Browser `16b9e4ce` is deployed,
with native build 30 VALID and IN_BETA_TESTING on both Apple platforms. The device-only PDF and budget decisions are unchanged.

The owner clarified the separate transfer request: copy the entire codebase, not a PDF, to `192.168.1.32` under
the SSH user's home directory. Include current source and design changes; omit local credentials, dependency
caches and generated build artifacts. This does not authorize a processing service or change NAS restrictions.

## Our servers never contact arXiv (owner principle 2026-10-15; built 2026-10-16, not yet deployed)

Owner principle: "each device calls arXiv only as its user's own agent; servers never; shared data from DataCite"
(approved). Rollout steps 5–7 (ARXIV_DEVICE_ONLY.md §6.0.3), built on top of the search and Feed switch below:
- The metadata stage names every arXiv paper from DataCite by its DOI, deciding shared reuse only from DataCite's record
  of the exact version (CC BY 4.0 or CC0); a paper DataCite doesn't list yet waits (about 9 hours) and then fails
  retryably. Devices send what they read (`source_metadata` on); their records stay on their own account's import.
- Ingest, Add by text or DOI and a reference's Add to library name arXiv papers through DataCite (by DOI or title);
  Crossref names other DOIs; arXiv's own DOI and arXiv links name the paper with no lookup.
- The Feed reads DataCite only (no switch back to RSS); server search reads DataCite whatever `openalex_enabled` says.
- Enforcement: the egress guard blocks by default, the static scan runs in block mode in `npm test` and before every
  deploy, provider health counts any server attempt as provider `arxiv` (Health tab Attention item), and the hosted
  check `egress.no-arxiv` requires zero attempts in 24 hours. The Edge `paper-worker` is removed from the code and is to
  be undeployed.
- Not built: filling an import from a device's record alone (today's clients read a paper only after it has catalog
  metadata; a client change, proposed in §6.0.3).

## Search and the Feed without our servers asking arXiv (owner decided 2026-10-16)

Owner answers: "5. Search: turn on device-only search, which drops OpenAlex — Sure"; "6. Shared Feed: take it from
DataCite on our servers, so our servers never contact arXiv. New papers show about 3 hours after announcement — Ok";
"10. The 'arXiv' search tab — Call it ML Paper search".

- Paper search runs on the person's device (apps: arXiv's API and DataCite; browser: DataCite). Builds that still ask
  the server get DataCite results; OpenAlex leaves search and DOI naming (Crossref names DOIs).
- The Feed's shared pool comes from DataCite's records of arXiv papers, read by our servers once for everyone; a chip
  outside the pool reads DataCite too. The `arxiv-ml` row stays for audit; the RSS code and the switch back are removed
  by migration 077 (above).
- The Library's search segment is "ML paper search" (sentence case like the app's other labels; it fits the narrowest
  iPhone at every text size). The field reads "Search ML papers"; the Mac menu item is "Search ML Papers".
- Migration 075 sets the three switches and records them in the admin audit log. Server arXiv calls that remain (the
  metadata stage, chat's find-paper and references) and the rest of the rollout: ARXIV_DEVICE_ONLY.md §6.0.2.

## Overruns and answers that stop early (owner decided 2026-10-16; on staging)

Owner answers: on containing overruns, "Yes, I agree with your suggestions"; on failed answers, "we need to better
define the situation. If we were charged by the provider, the onus is now on us to provide the value back to the
owner."

- **Overruns are contained.** An operation whose actual or uncertain provider cost exceeds its ceiling is recorded (a
  `budget_anomaly` row) and shown in the admin's Health › Attention; it no longer pauses the month. The month pauses
  only when spent + reserved + a new hold would pass the hard monthly limit (unchanged), when more than 5 operations
  overrun within a rolling hour (the tripwire; counted afresh after it pauses), or when an operator pauses it.
- **The reader pays for work that finishes, or for the part of an answer they chose to stop.** The provider failing or
  overloading, our server failing, our own time limit (130 s) or length limit (`max_tokens`), the connection between our
  server and the reader dropping, and a refusal cost the reader nothing; Gradstep pays the provider and the cost is
  recorded as absorbed, in the month's spend and on Health, never hidden. Partial text stays the reader's. Per-feature
  definitions: [CHAT.md](architecture/CHAT.md#when-an-answer-stops-early--2026-10-16); podcasts already worked this way.
- **Agent decisions (reversible):** a Stop is told apart from a dropped connection only when the app says so
  (`stop_signal` and `v1_chat_stop`); builds up to 60 keep today's rule (a closed stream is charged as a Stop). More
  than 20 unpaid early endings for one account in a UTC day raise an Attention line; the reader is never blocked. An
  undelivered title, suggestion or map update is Gradstep's. Built: migration 079 and the chat function (staging,
  2026-10-16); the clients' copy and Stop call are not built yet ([RESILIENCE.md](architecture/RESILIENCE.md#fix-1-and-early-endings-as-built--2026-10-16)).

## Agent v2 and framework stance (agent decisions, 2026-10-14; reversible)

The owner asked for a materially better chat agent ("new tools, new capabilities, better performance, more stable,
better design and UX") and for one answer per hard problem across surfaces. Decided and built, with the contract in
[CHAT.md](architecture/CHAT.md#agent-v2-2026-10-14-numbered-context-grounded-citations-follow-ups):

| Decision | Requirement |
|---|---|
| Grounded citations | Device-prepared papers are sent to the model numbered block by block (`reader-local-context-v2`); answers cite `[¶N]`, and a tap lands on that block in the reader with Back. One builder spec, two implementations (browser and Core), one shared golden fixture. |
| Follow-up questions | Every ordinary answer gets two or three one-tap questions from a small forced Haiku 5.5 request after the answer (the first design let the answering model call an optional tool; the live check showed it skipping the call, so one deterministic mechanism replaced it). Shown under the newest answer only, never saved, cleared by the next question. A tap fills the message box; sending stays explicit because answers cost credits. |
| Composer noise | The browser composer no longer repeats storage caveats on every keystroke; it reports only a stopped tab, a failed device save, a draft being saved, or a non-durable browser. The long wait before the first text shows its length after five seconds. |
| Web framework | Stay on React + TypeScript + Vite (owner's earlier "react it is then"). A Svelte rewrite would not address any current defect and would discard tested journeys; not revisited unless a concrete limitation appears. |
| Mathpix code | The server Mathpix client and PDF pipeline were deleted from the tree on 2026-10-13 (commit `dc040a9`); they remain in git history (`7233641`) for a possible future role. Nothing about them is tested or deployed now, and no credentials are kept in the server environment. |
| Legacy arXiv items read from arXiv HTML | Owner report 2026-10-14 ("papers already in my library don't work"). Every arXiv paper, membership or legacy item, opens through the on-device HTML reader; the server bundle is a fallback, never the first path; no data migration. Reversible by removing `Paper.legacyArxivSource`. |
| Compiler tolerance | A paper is refused only when its structure cannot be trusted (over 1,000 conversion markers, missing title, unresolvable references, unsafe math). Dropped markers, inline graphics and TikZ frames are counted in a closing note inside the paper; TikZ labels become SVG text. Previously any one of these refused the whole paper (five of the owner's nine new papers). |
| Learning guide (proposal only) | Owner request 2026-10-14 for a tailored ML learning extension (learner state, figure guide, optional quiz). Explored, not built: [docs/proposals/LEARNING_GUIDE.md](proposals/LEARNING_GUIDE.md) with a cheap prototype path and five open questions. No decision taken. |
| Not changed | Prompt cache TTL (5 minutes) and the credit rate card; a 1-hour cache for long reading sessions is a cost-policy choice left to the owner with the measurements in `IMPLEMENTATION_STATUS.md`. |

## Fast and slow tests (owner decided 2026-10-13)

Separate routine fast checks from slow integration/corpus work. Long checks can run once as a baseline and are
rerun selectively when related behavior changes or an issue warrants it, rather than becoming a mandatory loop
after every edit. Keep small regression cases fast, retain dated slow evidence, and distinguish a source's honest
unavailable outcome from a successfully prepared reader. [Testing commands and scope](TESTING.md).

## Web framework (owner decided 2026-10-07)

Owner: "react it is then", following the [React/Svelte evaluation](architecture/WEB_FRAMEWORK_EVALUATION.md).
Use React + TypeScript + Vite for both the browser reader and the admin. Share useful presentation components
and conventions; keep customer device-key/auth state separate from admin MFA and privileged operations.
SwiftUI/Catalyst remains the Apple application. Retain framework-neutral protocol, encryption and reader services.
Large-library work must address rendering, data loading and sync deliberately; the synthetic 50,000-row comparison
does not raise the current 4,000-entry protocol limit or establish product capacity.

## Library database foundation (owner authorized 2026-10-07)

The owner approved proceeding with the larger-library database direction and independent agent review, with a
reviewable branch for integration. The first stage separates compact replication, immutable metadata hydration
and indexed current-library queries. Independent review favored explicit query-generation invalidation over
version-history tables and snapshot leases until churn measurements justify that complexity. Preserve existing
command identities, grouped changes, old clients and capacity limits. No larger plan allowance, client rollout or
hosted deployment follows from local fixture tests. See [Library v4](architecture/LIBRARY_V4.md) and the remaining
[capacity acceptance gates](architecture/LIBRARY_CAPACITY.md).

## Agreed

| Decision | Requirement |
|---|---|
| Audience | Individual ML researchers and engineers |
| Native surfaces | iPhone and iPad; Mac through Catalyst (2026-10-07 addition) |
| Sign-in | Apple and Google following TextBrain's interaction pattern; email one-time code fallback selected under the user's delegated choice; no usernames/passwords in launch customer UX |
| Public name | Gradstep (owner decided 2026-10-06); gradstep.ai is the owned public domain; see the dated name decision below |
| Reader launch scope | iPhone/iPad first; admin website included; user additionally authorized building and deploying the browser reader after iOS, including while they are away |
| Key custody | Device-held keys; recovery requires an approved device or saved recovery code |
| Business model | Subscription with included AI/OCR allowance; tiers and credits supported |
| Price exploration | Benchmark $9.99/month and $19.99/month; final allowances follow measured workloads |
| Operating budget | $100/month incremental Science Reader private-beta costs, excluding existing TextBrain charges |
| Backend | Dedicated Supabase infrastructure with background processing as needed |
| Shared articles | Reuse only rights-eligible content; no shared server PDF acquisition or Mathpix conversion in the new design. Existing eligible bundles are historical assets, not a reason to resume PDF processing. |
| Equation-aware reader | Initially adapt the exact arXiv HTML version to the existing verified reader bundle; all PDF handling stays on device. Future local models handle challenging PDFs. PDF viewing alone is not structured-reader completion. |
| Private user data | Each person owns their library state, notes, highlights, and conversations |
| Admin | Private usage/cost dashboard with spending and account controls |
| Testing | Internal/admin app experience: screenshot, note, upload, replies, and fix-build tracking |
| UX | Preserve successful original screen arrangement and navigation; polish speed, reliability, spacing, metadata density, transitions, and accessibility using complete workflow simulations and independent reviews of complex designs |
| Existing NAS data | No migration needed |
| Initial delivery | Backend, admin dashboard, and TestFlight; public release after user review |
| Infrastructure discipline | Plan data ownership, failure behavior, evolution, and operations before choosing tables/deploying |
| Delivery quality | User explicitly prioritizes careful, maintainable implementation over speed; resolve structural issues and verify complete workflows before enabling them, without hacks or shortcuts |

## First usable journey direction — 2026-10-04

Historical checkpoint: its server PDF and paid OCR direction is superseded by the 2026-10-13 decision above.

The user transferred work to a new agent and chose, for the first overnight build:

| Decision | Requirement |
|---|---|
| Processing host | Build the add-paper → Mathpix → offline reader → paid answer journey on Supabase Edge Functions and database jobs. The Linux PDF-verifier work stays in the repository but is deferred until a real Linux host exists. |
| Paid OCR bound | Bound Mathpix cost with the provider's `page_ranges` cap and a credit hold for that maximum, settled on the provider-reported page count, instead of requiring a trusted local page count before submission. Single submission grant, holds/settlement and uncertain-outcome quarantine remain required. |
| Paid calls in staging | The Science Reader Mathpix and Anthropic keys retrieved from the authorized NAS project file (not shared with TextBrain) may be used in staging. Cap: **$10 for the 2026-10-04 overnight session**, counted against the $30/month provider allowance. Later caps are separate decisions. |
| Staging changes | New additive migrations, Edge Function deployments, synthetic test accounts and operator-recorded credit grants are authorized in staging. Production remains unprovisioned. |
| Paper-chat model | Claude Sonnet 5.5 (`claude-sonnet-5-5`). |
| Non-CC papers (superseded by the 2026-10-09 rights gate) | The first pipeline draft gave each account an `owner_private` conversion. That is retained only as legacy data for audit. New default, missing, or uncertain arXiv licenses use metadata plus a versioned source link and are retrieved/processed on the user's device; no new server PDF or derived bundle is created. CC BY 4.0 / CC0 conversions remain shared. A separately evidenced permission may opt an exact version into an owner-private server path. |
| PDF size and OCR page cap (agent decision, reversible) | Originals up to 64 MiB (image-heavy papers exceed 32 MiB); paid OCR capped at the first 80 pages via Mathpix `page_ranges`. |
| Placeholder credit rate (agent decision, reversible) | `beta-credits-v1`: 1 credit ≈ $0.01 at 2× provider cost — 1 credit per OCR page; chat = ceil(provider µ$ / 5000). Subscription allowances remain undecided. |

## Commercial arXiv content gate — 2026-10-09 (owner review required)

The rights restrictions below remain in force. The 2026-10-13 device-only PDF decision additionally removes server
PDF/Mathpix processing even for rights-eligible papers; the historical shared-conversion allowance is not an exception.

The official [arXiv API Terms of Use](https://info.arxiv.org/help/api/tou.html) prohibit storing and serving
arXiv e-prints from our servers unless the copyright holder has given permission or the e-print's submitted
license permits it. arXiv also says it is not the copyright holder. The earlier reversible decision to create an
`owner_private` conversion for a non-CC paper is implementation history, not launch clearance: encryption,
account-only access, payment, and a Mathpix transformation do not by themselves supply that permission.

Until the written arXiv/commercial response and counsel review recorded in
[ARXIV_CONTENT_HOSTING_20261009](research/ARXIV_CONTENT_HOSTING_20261009.md) are complete:

- server retention, cross-device sync, server-side Mathpix conversion, shared conversions, podcasts, and other
  derived media are enabled only when the exact version's rights permit the operation (currently CC0 and CC BY are
  the implemented shared-license set); and
- default, missing, or uncertain licenses use metadata plus a direct arXiv link/device retrieval path and are not
  retained or served from our server by default.

This is a public-paid-launch gate. The product must not claim that every arXiv paper syncs across devices until the
rights basis and arXiv's commercial/API expectations are confirmed.

## Data handling and model-cost explanation (owner requested 2026-10-09)

The native and browser clients expose a concise **How Gradstep works** screen from the account/about area. It
explains the separation between device-local papers, encrypted sync and requested AI processing; the rights-aware
paper paths; the fact that providers receive plaintext needed for a requested computation; credits, token estimates,
holds and settlement; shared OCR/podcast reuse; and the account/platform spending gates. It does not promise zero
provider retention or imply that a lower-priced model is automatically equivalent. See
[DATA_HANDLING_AND_COSTS](architecture/DATA_HANDLING_AND_COSTS.md). DeepSeek remains a research candidate only;
no routing or price policy changes follow from the rate comparison. Superseded by owner requests: podcast scripts may
use DeepSeek when chosen (2026-10-14), and chat may too (TestFlight build 57, 2026-10-16: "deep seek should be an
option. We need one that supports images"), opt-in per chat under consent `cloud-ai-v4`, at DeepSeek's peak list
prices, after a recorded quality check ([CHAT](architecture/CHAT.md#recorded-check-of-deepseek--2026-10-16-staging-before-it-was-published)).

## On-device paper processing (research, reversible) — 2026-10-09

Superseded in direction on 2026-10-13: start with arXiv HTML; challenging PDF conversion is future on-device work
with **no Mathpix fallback**. Previously captured Mathpix output may remain comparison evidence. The candidate local
path is PDFKit text and bounds, on-device OCR where needed, then a separately licensed and quality-gated model.
No open-source model is bundled or enabled from the initial investigation. A candidate must
pass held-out equation/rendering, reading-order, figure/table, device performance, failure-recovery and commercial
license checks. The full rationale and candidate inventory are in
[ON_DEVICE_PAPER_PROCESSING_20261009](research/ON_DEVICE_PAPER_PROCESSING_20261009.md).

## Product decision checkpoint

The user accepted both remaining recommendations on 2026-10-02. Account recovery does not recover encrypted history without an approved device or recovery code. No further product decision blocks foundation implementation.

## Recommended technical decisions to validate

- Shared publication metadata and reusable file conversions have separate identities. A DOI or title is not a file fingerprint.
- Users' personal content has no ownership relationship to the public conversion cache. Revoking one user never deletes another user's article.
- Private conversations, titles, selected-text anchors, notes, and generated chat artifacts use a versioned encrypted-content format with device-held keys.
- Cloud AI receives an explicit bounded plaintext request; encryption of stored history does not imply encrypted computation or provider zero retention.
- Supabase Realtime triggers catch-up, while a durable cursor protocol provides synchronization correctness.
- Billing events, credit grants, reservations, provider costs, and settlements are separate records with transactional invariants.
- Background jobs have durable state and fenced leases. Uncertain paid submissions are reconciled instead of blindly resubmitted.
- Internal app and customer app share one feature codebase. A testing build flag changes presentation; server roles authorize privileged operations.
- TextBrain's crypto/sync/billing code is reference material. Reuse requires a narrow dependency review and tests; its historical migration machinery is unnecessary for this clean start.

## Budget interpretation

Incremental means new costs attributable to Science Reader: new Supabase compute/projects, any plan increase necessary for them, admin/worker hosting, backups, storage/egress, and API consumption. Existing TextBrain costs are not silently reassigned to this budget. Shared-account invoices must be attributed before deciding which costs fit.

The $100 is an operating budget, not permission to purchase unrelated services or an estimate for the user's time. Reserve fixed costs and contingency before allocating the variable API allowance. In-app credits do not equal dollars or a provider's credits unless an explicit published conversion policy says so.

## Account deletion (owner decided 2026-10-05: keep billing records de-identified)

App Store review requires in-app account deletion for apps with account creation. Recommended, for owner review:

- **Settings → Account → Delete account** with a typed confirmation. Deletion is a server operation (requires a
  connection); the device then erases its local encrypted store and keys.
- **Deleted immediately**: encrypted history events and key envelopes (unreadable without device keys anyway),
  library items/imports, private (`owner_private`) documents and their Storage objects, support reports and
  screenshots, device registrations, the Auth user (and Apple token revocation when Sign in with Apple is live).
- **Kept, de-identified**: credit ledger, operations and provider-usage rows needed for accounting and the platform
  budget (account ID replaced by a deletion tombstone ID); shared CC BY/CC0 conversions other accounts rely on.
- **Purchases**: an active App Store subscription is managed by Apple; the app links to subscription management
  before deletion. Unused credits are forfeited (state this in the confirmation).
- Backups expire deleted data on the backup retention schedule (BACKUP_AND_RESTORE).

The owner chose the split above (2026-10-05). Implemented: personal content and login deleted; credit/usage/operation
rows kept under the account's random ID, which stops mapping to anyone once the login is deleted (replacing the ID
was not needed: the ledger is append-only and widely referenced). See PRIVACY_AND_SYNC → Account deletion.

## Library metadata view (owner decided 2026-10-05)

The List stays the default. The Library's "Sort and details" menu adds **Layout: List / Table**. Where the container
is at least 700 pt wide (iPad, iPhone landscape) Table is a sortable table; in narrower containers (iPhone portrait,
the iPad Browse column) and at accessibility text sizes it shows as **Detailed rows**. Columns: Title, Authors
(short form), Year, Topics (friendly arXiv names, at most two), Added, Opened, Read (bar + %), Chats; Pages hidden by
default; Status only when a row isn't simply ready. Sorts: Recent, Title, Year, Opened, Progress, Chats, and Authors
on the table; searching keeps only matches and honours the sort. Layout and column visibility/order persist;
the sort still resets to Recent at launch, as before.

Implementation choices (easy to change): on iPhone landscape the table is drawn by the app, because SwiftUI's `Table`
shows only its first column on iPhone; it carries authors and topics under the title and has no column
customization. Detailed rows leave abstracts out (they are the List's detail). Dates older than this year show
month and year ("Sep 2025"). Opened/Read use device-local encrypted reading activity, never synced or sent to the
server — see [privacy and sync](architecture/PRIVACY_AND_SYNC.md#device-local-reading-activity-2026-10-05).

**Superseded in part (owner request 2026-10-06, "a sane true table view of papers that we can re-use for the
feed").** "Table" is now one app-drawn table (`PaperTable`, `Views/PaperTable.swift`) on every size, used by the
Library and the Feed; SwiftUI's `Table` and the 700/980 pt thresholds are gone. "View as" offers List / Detailed rows
/ Table; Table shows detailed rows only at accessibility text sizes. Each column has a priority and a width; the
title keeps at least 160 pt (or a third of a wide row) and columns are added in priority order while they fit, so
there is never sideways scrolling. Library: Title (title and first author, "Vaswani et al."), then Progress, Year,
Added, Opened, Chats and, on wide iPads, Topics (Show › Topics hides it). iPhone portrait shows Title, Year,
Progress; iPhone landscape and iPad portrait add Added, Opened, Chats. Progress merges the old Read and Status
columns: reading progress for a paper, otherwise an icon and one word ("Converting", "Download failed"), the step
time on a second line, and the full status for VoiceOver; a paper merely not downloaded shows its progress, as the
List shows nothing for it. Headers sort (tap again to reverse); when the sorted column doesn't fit, "· Added ⌄"
beside Title shows the order. Tapping a paper opens it; tapping an import that needs credits opens Get credits;
long-press and swipe keep the List's actions. Column visibility is no longer customized per column (SwiftUI's
column customization went with `Table`). Feed: "View as" List (default; *the Table since 2026-10-24*) / Table in the Feed's "…" menu; columns Title
(and first author), Topic, Published (month from the arXiv identifier — the server sends only the year) and Add;
newest first; tapping a row shows its abstract under it; long-press offers Add to library and View on arXiv.

**Superseded again (owner request 2026-10-07):** the Table is the default, Detailed rows are gone, and columns are
chosen again (per device kind); see [Library as a proper table](#library-as-a-proper-table-owner-asked-2026-10-07).

## Web search in chat (owner decided 2026-10-05: turn it on)

Status 2026-10-21: web search is only our `search_web` tool (Tavily), called through OpenRouter; the Anthropic search
backup described below was gated off from 2026-10-14 and removed from the code with the OpenRouter-only decision above.

Owner approved enabling it with a consent line naming Anthropic's search provider and a tappable Sources list.
Implemented and **on in staging** since 2026-10-05 (server switch `CHAT_WEB_SEARCH`; see [chat](architecture/CHAT.md)). Restores the legacy
app's web search. Enabling needs: consent copy that names Anthropic's search provider as a recipient of search
queries, a tappable source list (Anthropic's display requirement for cited web results), and acceptance of the
larger per-question hold (108 → 245 credits for DPO, a 27-page paper; actual charges are far lower).

## Subscriptions and credits (owner approved 2026-10-05)

Approved draft: **Standard $9.99/month = 800 credits**, **Pro $19.99/month = 1,800 credits**, a **$4.99 pack = 400
credits that never expire**, TestFlight testers 1,000 credits by operator grant; 1 credit ≈ $0.01 to the customer,
about twice provider cost. Also approved: the per-question hold is capped at the balance from 50 credits.

Implementation choices (easy to change; see [purchases](architecture/PURCHASES.md)):

- Plan credits are granted per verified renewal and expire with that period (no rollover); pack credits never expire;
  holds spend plan credits first.
- An upgrade grants the new plan's credits at once and leaves the old period's credits until they expire.
- A refund removes unspent credits from that purchase (holds in flight are kept); a reversed refund restores them.
- A purchase belongs to the account that first reports it (the app sets `appAccountToken` to the account ID); a
  deleted account's purchase moves to the next account that restores it.
- App Store Connect (beta scope): app "Paperstep" free and offered in the United States only; products
  `com.sciencereader.ios.{standard.monthly, pro.monthly, credits.400}` in group "Plans", US prices, App Store market
  only; sandbox server notifications go to staging. Territories, final names and review screenshots are revisited
  before public release.

## Ingest adds papers from the web (owner asked 2026-10-05)

Owner: "the background agent, upon being asked to ingest, should be able to import papers it finds on internet, not
just archive". Implemented as **web imports** (migration 019; see [chat](architecture/CHAT.md#ingest-selection-action)).
Defaults chosen (easy to revisit, none hard to reverse):

- **Freely available PDFs only.** A cited paper without an arXiv copy is added from a PDF OpenAlex lists for it:
  its open-access locations (Unpaywall data: repositories, publisher OA copies) and PDFs on free ML venues (JMLR,
  PMLR, NeurIPS/ICML/ICLR, CVF, ECCV, BMVC, ACL Anthology, OpenReview, AAAI, IJCAI, JAIR, ISCA, RSS), which
  OpenAlex often labels closed (e.g. Dropout, JMLR 2014). A paper with neither is reported as "not openly
  available" with its DOI/landing link; nothing is fetched. A login page or paywall in place of a PDF is refused.
- **Always a private conversion** for the requesting account (like non-CC arXiv papers): never shared or reused by
  another account; the reader's attribution says so and links the landing page.
- **The server picks the PDF**, from OpenAlex's record of the work; clients only name an OpenAlex work
  (`openalex:W…`). Downloads are hardened (https on a public DNS name, every redirect re-checked, private addresses
  refused, PDF bytes required, size/page limits, credits required before downloading).
- **Installed builds keep working.** Builds before this change cannot show web papers, so their library reads (v2)
  leave web entries out; newer builds read v3. Ingest adds a web paper only for builds that declare
  `capabilities: ["web_import"]`; older builds are told to update.

## Library header and design audit (owner asked 2026-10-05)

After build 8 the owner approved replacing the system search bar (its navigation-bar drawer left a gap) and asked
for an independent design audit against these principles: well-considered margins; details and options tucked
away until needed; visual hierarchy (primary things larger, secondary smaller); as much open space as possible
("walking into a living room and seeing mostly open space"); and one uniform, consistent way to reach options
just below the surface across the app.

Library header: one row with the system search field, Add (+) and one options menu (…) that merges the former
"Library options" and "Sort and details" menus (layout, sort, show, then All chats, All diagrams, Refresh). While
searching, Cancel replaces + and …, and the Library/arXiv switch appears under the field; Cancel returns to the
library. The navigation bar is hidden on the Library root.

## Web search providers and pricing (owner decided 2026-10-06)

Status 2026-10-21: Tavily is the only search provider; there is no automatic Anthropic backup (OpenRouter-only decision
above). A paused or exhausted Tavily answers without search.

The owner bought Tavily's **Project plan ($30/month, 4,000 search credits; billing cycle from 2026-10-06)** and asked for
a recommendation and a well-designed fit with credits; on follow-up: "I dont feel strongly about tavily, what ever is
the best value" and "having two might be good, we can have a backup". The Science Reader Tavily key already in
`.env.providers` (from the authorized NAS project file; not shared with TextBrain) reports the Project plan (Tavily
`/usage`, no credits used), so it is the staging credential.

Decision (details in [chat](architecture/CHAT.md#web-search-on-in-staging)):

- **Tavily is the primary search; Anthropic's search is the automatic backup**, per answer and mid-answer. Value:
  Anthropic's search measured $0.06–$0.12 provider cost per searched answer on staging, two thirds of it result
  tokens (~10k per search); Tavily results are sized by us (5 × 1,500 characters ≈ 2.5k tokens) and a search inside
  the prepaid plan costs nothing extra. Tavily also restricts paper searches to scholarly sites (`academic`).
- **Readers pay the same rate card whichever provider ran** (`beta-credits-v1`, 2× list price): Tavily's
  pay-as-you-go $0.008/credit → 1.6 credits per search; Anthropic $0.01 → 2 credits per search; tokens as before.
  Searches are never free to readers, so the plan's allowance cannot be drained without spending credits.
- **The $30 is a fixed commitment**, not metered spend: Tavily searches inside the plan add nothing to the
  `platform_budgets` cap; Anthropic backup searches do. A server-side allowance (3,900 credits per 31 days) moves
  answers to the backup before the plan runs out, and **pay-as-you-go must stay off** in Tavily's dashboard (it is the
  provider-side hard limit; if it is ever turned on, overage would be unrecorded spend).
- **Privacy:** Tavily may keep queries and use them to improve its service, and may pass them to third-party
  indexes (its privacy policy, checked 2026-10-06); no zero-retention claim. Consent becomes `cloud-ai-v2` naming
  Tavily; builds that send v1 never use Tavily, and newer builds ask once more.
- **Measured on staging (2026-10-06, same requests, consent v1 → Anthropic, v2 → Tavily):**

  | Request | Provider | Searches | Provider spend | Reader credits | Time |
  |---|---|---:|---:|---:|---:|
  | Related (DPO passage) | Anthropic | 3 | $0.111 | 23 | 14.0 s |
  | Related (DPO passage) | Tavily | 3 | $0.047 (+3 prepaid credits) | 15 | 16.2 s |
  | 2026 SWE-bench question | Anthropic | 1 | $0.056 | 12 | 11.8 s |
  | 2026 SWE-bench question | Tavily | 2 | $0.041 (+2 prepaid credits) | 12 | 14.2 s |

  Answer quality was comparable; the Tavily Related answer linked all 7 papers to arXiv (Anthropic's: 4 of 8).
  Saving ≈ $0.015–0.02 of provider spend per search, so the $30 plan pays for itself only above ≈ 1,500–2,000
  searches a month.
- **Plan size (recommendation):** private-beta volume is far below 4,000 searches (four searched answers so far,
  each ≤ 5 searches). Tavily's free tier (1,000 credits/month, 100 requests/minute development keys) would likely
  cover the beta; if the counts by early November stay under ~800/month, downgrade before the next renewal. The code
  does not change with the plan: set `TAVILY_SEARCH_ALLOWANCE` to the new allowance less a margin. A paid plan is
  needed for production keys (1,000 requests/minute) before public launch.

## Product name: Gradstep (owner decided 2026-10-06)

Owner: "lets do gradstep then", after the [naming study](brand/naming-2026-10-06.md) (top pick) and a check of
Gradstack (rejected: gradstack.ai/.io belong to a live AI hiring startup since March 2026, and "stack" reads as
careers/developer tools rather than ML). Gradstep: a gradient step is the basic unit of ML training; each paper is a step.

- User-visible name is **Gradstep**: App Store Connect record renamed from "Paperstep" (2026-10-06), home-screen name
  (`CFBundleDisplayName`), consent and privacy copy, alerts, the iPad sidebar title, the admin site, sign-in emails
  ("Your Gradstep sign-in code", sender name Gradstep), session recordings (`gradstep-session-*.zip`; the review
  script still reads `paperstep-` files), and chat instructions and conversion attribution text.
- Internal identifiers stay: bundle `com.sciencereader.ios`, the `ScienceReader` code names, the Supabase
  organization/projects, and content-addressed sample bundles (their text still says Science Reader).
- Domains (checked 2026-10-06, registry data): gradstep.ai, .io, .co, .dev, .org, .net, getgradstep.com unregistered;
  gradstep.app registered (Porkbun, January 2026, dead Vercel page); gradstep.com for sale at $1,995. Recommended:
  **gradstep.ai** (≈ $70–90/year, often two years upfront) and optionally getgradstep.com. The owner buys it; it then
  becomes the verified Resend sending domain for sign-in codes. Not a trademark clearance: an attorney search is
  still advised before public launch.
- Logo: not yet chosen (concepts: Folio, Nabla, Ribbon were the favourites).

## Logo, domain and sign-in email (owner decided 2026-10-06)

- **Logo: 06 Nabla** ("The nabla looks good"): the gradient operator ∇ as a valley with an optimiser stepping down to
  the minimum (amber point) on an Ink tile. Installed as the app icon (light, dark and tinted variants), the
  gradstep.ai favicon and header, and the admin mark. Concept sheets: `.artifacts/brand/logo-concepts/06-nabla/`.
- **gradstep.ai** (owner bought it, with gradstep.shop): DNS on Cloudflare; the site (home, beta privacy notice,
  Apple `webcredentials` association for "Save to Passwords") is the Cloudflare Pages project `gradstep-site`.
  Namecheap's email-forwarding MX/SPF records are kept at the apex.
- **Sign-in codes are sent as `Gradstep <codes@gradstep.ai>`** through Resend, with the domain verified (DKIM and the
  `send.` subdomain's MX/SPF records in Cloudflare) and a sending-only key scoped to gradstep.ai as the Supabase SMTP
  password. Verified: a code to a non-owner address was delivered (Resend test inbox), 2026-10-06. Sign-up stays
  invite-only; testers need an account created for them.

## Add a reference without chat (owner asked 2026-10-06)

Owner: "if you click on a reference, and ask for Add the reference, no chat is needed, it should just get queued and
then start to get processed, and it needs to be extremely reliable … for regular pdfs maybe a chat makes sense."

- **Reference actions → Add to library** calls `functions/v1/add-reference` (no model, no credits): an arXiv id or DOI
  in the entry, else the entry's own title (quoted, or between the authors and the venue) through the shared strict
  search (OpenAlex, arXiv, Tavily), else Crossref's citation matcher, else OpenAlex search; a found paper is accepted
  only if its title appears in the entry. The reader shows the outcome in a banner ("Added …", "already in your
  library", "isn't openly available", "Couldn't identify this reference" with **Ask in chat**, which runs the
  existing Add paper chat). Outcomes are recorded as `reference` reliability events (migration 026).
- The selection action **Add paper** (on an in-text citation) still uses the chat.
- Live: seven real entries resolved correctly (1–16 s); the Simulator journey (DPO citation 11 → PaLM) passed.

## Workflow checks schedule (owner decided 2026-10-06)

October's staging provider cap raised to **$25** (from $9.80; within the $30/month AI/OCR allowance). Paid checks run
Mon/Wed/Fri plus a weekly heavy suite (~$6/month); free checks every 6 hours and after deploys. Failures email the
owner. See [workflow checks](architecture/WORKFLOW_CHECKS.md).


## Library as a proper table (owner asked 2026-10-07)

Owner: "I do not like the detailed rows right now, it should be a proper table, we need to have columns that can be
turned on or off, it needs to be something where people can navigate and find papers easily … I see some in my list
that say 'Download Failed'. They should never sit there like that, it should be a retry button at the very least."
Made overnight without check-ins (owner asleep); each choice below is easy to change.

- **The Table is the Library's main view** at every size; **List** stays the alternative ("View as"). **Detailed rows
  are removed**: a saved "Detailed rows" (and no saved choice) opens the Table; an explicit List choice is kept. At
  accessibility text sizes the Table shows the List's rows (as the Feed does) instead of detailed rows.
- **Columns** (Library options › Columns, a half-height sheet of toggles; changes show at once): Title with the first
  author (always), Year, Tags, Source (arXiv identifier or the web paper's host), Pages, Added, Opened, Chats,
  Progress, in that row order. Choices are kept on the device, separately for iPhone and for iPad/Mac (by device kind
  rather than size class, so rotating an iPhone never swaps sets). Defaults: iPhone Year, Added, Opened, Chats,
  Progress (portrait shows Title, Year, Progress; landscape adds the rest); iPad/Mac add Tags; Source and Pages start
  off. The width then decides which chosen columns fit (Progress, Year, Added, Opened, Chats, Tags, Pages, Source, in
  that priority); a chosen column that doesn't fit says "Shown when there's room", and a column turned off never
  shows. The title keeps at least 155 pt or 40 % of the row, so any one short column fits beside Progress on the
  smallest iPhone and a Pro Max in portrait keeps two columns. Every column sorts from its header (Tags A→Z by first
  tag, Pages longest first, Source A→Z); Tags, Pages and Source join Authors as table-only orders in Sort by.
- **Tags**: `Paper.tags` (first-class tags, filled by the tags work) as display names, else topic names derived from
  the arXiv categories (the Feed chips' names); imports use their categories. Shown as small chips (≤ 2 lines),
  searchable, and filterable. No tag storage or editing here.
- **Finding papers**: one row of chips above the table (and the List) that scrolls away with the rows: **Tags ⌄**
  (a menu, most used first, with counts), **All · Unread · Reading · Failed n · Archived**. "In progress" is named
  **Reading** so it isn't mistaken for imports in progress. Unread = never opened on this device; Reading = opened
  (or with progress) and under 100 %; Failed = stopped imports; Archived replaces Show › Archived papers (removed).
  Only filters that would change the list appear, and the row is hidden for a library with nothing to narrow. Filters
  aren't kept across launches (like the sort). Search still filters live, within the filter, and now matches tags.
- **Keyboard and pointer** (iPad, Mac): ↑/↓ choose a row and Return opens it (key commands, so no focus is needed; a click opens a row as a tap does); hovered rows get a quiet
  fill; the header stays pinned.
- **Stopped imports never just sit**: the status reads in plain words ("Download failed") and the row shows one action
  as a small button — **Retry** when the server can run it again (download, details, rate limit), **Get credits** when
  conversion waits for credits, otherwise **Remove** (too large, unreadable PDF…; nothing to retry). It sits in the
  Progress cell, or under the title when Progress isn't shown; the List shows the same button. The long-press menu
  and swipe say Retry / Remove (Cancel import while an import still runs). Tapping Retry shows the row
  **downloading again at once** (finding, if its details were never found), from the queued retry command, until the
  server's own state arrives. An import the server is retrying by itself (`download_retrying`, migration 027)
  counts as under way: no Retry, not under Failed. Imports in progress show `ImportProgressView` (compact) in the
  Progress cell. The Mac's View menu gets Filter Library in place of Show › Archived Papers.

## Recovery code in Apple Passwords (owner asked 2026-10-06)

Owner: "can we build an integration with Apple password manager so its easy for users to sync the retrieval password
into Apple". The recovery code is needed only on a device that has no approved device to approve it (an approved
device can approve a new one), not on every sign-in.

- The recovery screen offers **Save to Passwords**: the code is saved as a password for `gradstep.ai` (title
  "Gradstep recovery code", user name = the account email) through the system prompt
  (`ASCredentialDataManager.save` on iOS 26.2+, `SecAddSharedWebCredential` before). Saving also ticks "I saved this
  code". It is optional; copying the code still works.
- On a new device, **Use code saved in Passwords** asks the system to offer passwords saved for `gradstep.ai`
  (`ASAuthorizationPasswordProvider`) and fills the field; the field also accepts Password AutoFill.
- Requires the `webcredentials:gradstep.ai` associated domain (App ID capability enabled; `gradstep.ai/.well-known/
  apple-app-site-association` lists the app) and the "Gradstep App Store" profile.
- Apple documents iCloud Keychain (which Passwords uses) as end-to-end encrypted; Gradstep's server still never receives the code. Anyone who can
  open the person's Passwords can read the code, as with any password they store there.
- Evidence (2026-10-06, iPhone Simulator): **Use code saved in Passwords** runs and reports "No saved recovery code was
  filled" when none exists; **Save to Passwords** on a fresh staging account opens Apple's password-saving sheet, which
  the Simulator closes because it has no iCloud Keychain. Saving and filling on a real device is not yet verified
  (physical iPhone work is paused).

## Self-healing downloads (decided 2026-10-07)

Decided overnight under the owner's "don't stop to ask"; for review.

Owner: a "Download failed" must never just sit in a reader's library. Decided and recorded here; details in
[import reliability](architecture/PIPELINE_RELIABILITY.md#self-healing-downloads-migration-027).

- **Automatic retry, at most three times, 15 min / 2 h / 12 h**, for download failures that can change: host busy or
  unreachable (`source_unavailable`), a bot check (`source_blocked`), no PDF at the link (`not_pdf`), gone or refused
  (`download_failed`), a crash loop. **Not** for refusals that cannot change: a sign-in or paywall (`pdf_restricted`)
  or the size limit (`too_large`). Every failure keeps the reader's Retry, which runs at once and does not use up an
  automatic retry. A successful download resets the count.
- **While a retry is scheduled the import stays `failed`** (honest: it did fail) with the new code
  `download_retrying` ("Couldn’t download yet · Trying again automatically") and a new top-level entry key
  `auto_retry_at`, present only then, so every other entry's JSON is unchanged (older builds show "Couldn’t import
  this paper" and keep Retry). Rejected: keeping the import "Downloading…" for up to 12 h (the app would say
  "taking longer than usual" for hours).
- **A retry is a worker checkpoint, not a reader intent**: new `state_seq`, intent revision unchanged, so a reader's
  Cancel still applies and needs no new revision.
- **Healing**: a failed, retryable import whose paper has since moved on (another reader's retry or import) is put
  back in the pipeline automatically. Found on staging: three imports stuck `failed` beside a paper that was `done`.
- **After every pipeline worker deploy**, every failed paper that can resume without charge (metadata, download,
  render; not `too_large`) is retried once per deploy label — including sign-in/bot refusals, since a deploy is when
  our misclassification stops being one. Not counted as an automatic retry.
- **Reader messages** (app, `LibraryImportErrorCode`): `pdf_restricted` "This PDF needs a sign-in or subscription",
  `source_blocked` "The paper’s website blocked the download", `source_unavailable` "The paper’s website isn’t
  responding", `not_pdf` "The paper’s link doesn’t lead to a PDF", `download_retrying` as above.
- **We do not evade bot checks** (no browser user agent, no challenge solving). Copies on hosts that challenged every
  automated request in the survey (ACM, OUP, Wiley, T&F, Elsevier, Science, PNAS, ACS, SAGE, IOP, Cell, PeerJ,
  SSRN, eScholarship, OpenReview, IUCr, Lancet) are tried after every other copy; PubMed Central copies are fetched
  from NLM's official open data on S3 (`pmc-oa-opendata`), the documented programmatic route.
- **Ingest's notion of "openly available" is unchanged** (explicit PDF locations only). The pipeline additionally
  tries PMC open data and open repository records; widening Ingest to count those is a possible follow-up.

## Admin accounts (agent decisions, overnight 2026-10-07; owner asleep, all reversible)

The owner asked for an owner-only Accounts tab so testers can be managed without an engineer
([gap audit](LEGACY_GAP_AUDIT.md)). migration 028, Edge function `admin-accounts`, admin tab **Accounts**.

- **Who:** owners signed in with MFA only, through the existing `is_operator('owner')` gate (`v1_admin_actor` on the
  caller's own token); the service functions re-check that the acting account is an open owner. Support operators
  don't see the tab.
- **Add tester:** creates the Auth login with the email confirmed and no password through the Auth admin API;
  `disable_signup` stays on and nothing is emailed. The page shows instructions to send and reminds the owner to add
  the tester to TestFlight. The existing `auth.users` trigger creates the account row. Adding an existing email
  changes nothing. Starting credits default to 1,000 (the approved tester grant) and are granted once per account.
- **Grants:** `adjustment` credits that never expire, 1–2,000 per grant (server-side), a required one-line reason
  (3–500 characters, kept in the audit log; the ledger reason is "Admin grant: …"), once per request ID; the page
  asks for confirmation above 500.
- **Disable:** a Supabase Auth ban (100 years), recorded in the audit log *before* the ban is applied; owners can't
  be disabled here. An open session keeps working until its access token expires (up to an hour); making the
  database refuse banned logins immediately is a possible follow-up (it would change `app_private.actor()`, used by
  every RPC, so it was not done unreviewed). Deletion stays in the app.
- **Status shown:** active, disabled (banned), closing (deletion started, login not yet removed), closed (deleted).
  Synthetic `@example.invalid` logins are listed and marked "Test". Apple/Google sign-in for a pre-created tester
  relies on Supabase linking identities with the same verified email; not yet tried on staging.

## Admin hosting and cost evidence (owner authorized; deployed 2026-10-08)

- Keep the privileged admin on **https://admin.gradstep.ai**, separate from the customer reader's origin and
  device-key storage. Deployment **349d3859** uses the dedicated `gradstep-admin` direct-upload Pages project,
  production branch `main`, custom domain and proxied CNAME. Free static assets only; no Functions or paid tier.
- The reviewed deployment script builds only with the selected public staging configuration, scans for leaked
  server credentials, rejects production fixtures/server bundles and validates strict CSP/HSTS/no-transform.
  Route rules cannot remove inherited security headers; the pinned Pages mode prevents an implicit Worker
  deployment. Live sign-in-screen/CSP checks pass on desktop and phone; exact admin-origin CORS is verified for the
  privileged endpoints without replacing their owner/MFA gates. [Hosting evidence](architecture/ADMIN_HOSTING.md).
- Cost evidence is an append-only, auditable owner operation through the caller's normal MFA session and
  existing migration 037 service RPC. A reporting month is not a vendor service period; invoices/metrics remain
  separate from the latest component commitment/forecast and provider expense. Unknown-outcome retries retain
  the same request identity. This action never changes budgets or customer credit balances.
- The existing verified owner account received its role through an audited bootstrap; no password or MFA factor
  was changed and no owner session was impersonated. **Real owner password/TOTP acceptance and hosted owner
  actions are still untested; no invoice records were written.** Owner bootstrap is not proof of MFA completion.

## All chats as a table (owner asked 2026-10-07)

Owner: "the all chats UX is terrible, bad use of space, we also need a nice table, better more dense rows, not
overdoing it, thoughtful. But at the very least I should be able to see a table with my chats, sort them based on
last used, etc." Decided by the agent overnight (owner asked not to stop for feedback); all reversible.

- **Same place, same entry points.** "Chat history" (chat top bar) and "All chats" (Library, chat and Settings menus)
  still open one sheet titled All chats with Done; All diagrams is unchanged. The sheet now opens full height on
  iPhone and page-sized on iPad (iOS 18+), since a table needs the room.
- **A table in the `PaperTable` pattern** (`Views/ChatHistoryView.swift`): a pinned header of column titles (tap to
  sort, tap again to reverse; "· Started ⌄" beside Conversation when the sorted column doesn't fit), compact rows
  (~52 pt: 7 pt vertical padding, 16 pt sides), columns added by priority while they fit, never sideways scrolling.
  Columns: **Conversation** (the first question on one line; under it, muted, the paper's title, or the newest
  answer as one plain line when the Paper column is shown), **Paper** (title, "General", or "Paper chat" when the
  paper is no longer in the library), **Messages**, **Started**, **Last used** (always rightmost: "Just now",
  "5 min ago", "2 h ago", "Yesterday", "Mon", "Oct 3", "Sep 2025"). iPhone portrait: Conversation and Last used;
  iPhone landscape and iPad: all five. Default order **Last used, newest first**; it isn't remembered between
  openings. At accessibility text sizes rows replace the table (title, paper, "2 h ago · 6 messages").
  A separate table rather than `PaperTable` itself: chats aren't papers, and `PaperTable` was being changed by another
  session the same night; merging the two into one generic table is a later cleanup.
- **Search and a quick filter.** A search field ("Search chats": every word must match a question in the
  conversation or the paper's title, ignoring case and accents) and chips **All · Paper chats · General** with the
  count ("34 chats", "5 of 34 chats"). Both apply to drafts too. No date grouping (Today / This week / Earlier):
  it only makes sense for one sort, and the Last used column already says it.
- **Unsent drafts stay on top**, in their own section ("Unsent drafts"), with a pencil, "Draft · <paper or General
  chat>" and when they were edited; tap reopens, swipe or long-press discards, as before.
- **Row actions.** Tap opens the conversation (as before). Long-press: **Open paper** (paper chats whose paper is in
  the library) and **Delete conversation**; swipe: **Delete**. Both ask first ("… will be removed from your chats on
  all your devices"). There was no delete before: it appends the conversation tombstone the sync design already had
  (hidden on every device once synced, its diagrams too, continuing it blocked, an unsent follow-up kept as a draft).
  The encrypted records stay on the server until account deletion; the app doesn't claim otherwise. Delete needs
  this account's encrypted history on the device (not offered signed out).
- **Times in history.** Events carried no time, so "Last used" had nothing to read. New conversation, message and
  diagram events now carry `createdAt` (the author device's clock, Unix ms) **inside the encrypted payload**: the
  service learns nothing it didn't already (it sees when ciphertext arrives), older app builds ignore the field,
  and no migration or server change is involved. History saved before this has no times: those conversations show
  "—" and sort after dated ones, among themselves by the order they reached this device (`PrivateState` keeps that
  arrival order as an unsynced, uncompared hint). The original web app showed server `created_at`/`updated_at`.
- **What the original web view had** (`reference/web/components/AllChatsView.tsx`): a desktop table Paper · Chat ·
  Type (Paper/General badge) · Started · Last active · Msgs, newest activity first, no sorting, search or actions; a
  card list on phones (title, paper, badge, relative time); a "New chat" button and a count in the header. Kept: the
  columns (Type became the filter chips and the Paper column's "General"), newest-first, relative times, the count.
  Dropped: the badge styling, the New chat button (the chat's own compose button stays one tap away), the
  highlighted-passage quote of the in-panel history (not stored separately in the native history).

## Author–year citations link like numbered ones (owner asked 2026-10-07)

Owner: "when references are indicated like 'Stadter et al, 2021', I don't see an obvious way to use them as
hyperlinks, like if they are numbers (which seems to work)". Decided without waking the owner (reversible, reader-only):

- **Same interaction as numbers.** An author–year citation links to its bibliography entry only when exactly one entry
  fits; the tap, highlight, Back and reference actions are the numbered ones. Each name–year pair is its own link
  ("(Peters et al., 2017, 2018a)" is two). Ambiguous citations stay plain text rather than risk a wrong jump.
- **Discoverability (styling only).** Same link color as numbers; on touch screens every citation link (numbered too)
  gets a faint 1 px underline at 40% of the link color, so long author–year spans show their extent. No new controls.
- **Matching rules** (detail and measurements in [Reader renderer](architecture/READER_RENDERER.md)): diacritics
  folded, particles and multi-word surnames, "et al" with or without period, "and"/"&", groups, brackets, narrative and
  parenthetical forms, lists, suffix letters; ties broken by cited names' places, author count, initials, suffix
  letter or entry order. The bibliography now ends at an appendix paragraph, and lower-case-particle surnames start a
  new entry.
- **Measured, not assumed.** `scripts/citation-harness.mjs` runs the bridge in headless WebKit over 22 real bundles
  (12 retained, 10 downloaded read-only from staging storage): unambiguous author–year citations linked 89.5% → 99.8%
  (1,393 → 1,568 of 1,571), no wrong link against the oracle, 30/30 random links correct by hand, numbered papers
  unchanged, no block text changed. The owner's "Städter et al., 2021" paper went from 44.9% to 100%.

## Import progress (owner asked 2026-10-07)

Owner: "when items are processing, we should have a better UX, ideally, we have an estimate of the total time, and
have a percent done, with stages that make more sense to the user (What does 'Converting...' mean?) What is a reader
to the user?" Agent decisions overnight (owner asleep; all reversible); design in
[import progress](architecture/IMPORT_PROGRESS.md).

- **Steps in the reader's words:** Finding the paper → Downloading the PDF (40.8 MB) → Reading equations and figures
  (page 12 of 27) → Preparing it for reading; also "Waiting to start", "Waiting to continue" (budget pause) and
  "Couldn't download yet · Trying again automatically" (027's automatic retry, shown as under way, not as a failure).
  No user-facing "converting", "rendering", "reader" or "bundle" on import rows.
- **The readable result is "a readable version"** where a noun is needed (the explainer); rows avoid naming it.
  "Reader" stays an internal word. Failure messages ("Conversion failed", "…to convert this paper") were left for a
  separate pass.
- **Percent and time left are computed by the server** from measured stage times (30-day medians, defaults from the
  staging canary), scaled by pages, using Mathpix's page progress during OCR, and sent as `progress_detail` on the
  import entry (migration 029). The percent never goes backwards within an attempt; the time is shown only when
  trustworthy, rounded ("About 40 s left"), said loosely before the page count is known ("Usually under a minute"),
  and replaced by "Taking longer than usual" when the paper is backing off or well past its estimate.
- **Updates are throttled:** at most one progress entry per import per 5 s, only when the reader would see something
  new, within a per-account progress rate (720/hour) separate from library writes; the app moves the bar and counts
  down between updates.
- **Explained once:** an info button beside the progress opens "Getting a paper ready" (four steps, about a minute,
  carries on if you leave the app).
- **Look:** a slim neutral bar (the accent bar remains reading progress), "62% · About 40 s left" beside it.

## Mac app (agent decisions, overnight 2026-10-07; owner asleep, all reversible)

Owner: "build out the MacOS app … don't stop to ask for feedback". Details: [Mac app](architecture/MAC_APP.md).

- **Mac Catalyst with the Mac idiom on the existing target**, not a separate AppKit app: one code base, the
  same bundle ID and App Store record (universal purchase), iOS build settings unchanged (`[sdk=macosx*]`
  conditions only).
- **Window:** always the wide layout; the view switch and Settings move into the window toolbar (platform
  adaptation; the arrangement, modes and panes are the iPad's). Minimum 720 × 520 pt so it tiles on a
  13-inch screen; size remembered. No privacy cover when the app is inactive (a Mac window stays visible).
- **Menu bar mirrors on-screen controls** (no menu-only features). ⌘F finds in the paper while reading and
  searches the library elsewhere (⌥⌘F always searches the library, as in Mail/Notes) — a change from
  "⌘F = library search" because a reader pressing ⌘F in a paper expects to find text, not to leave it.
- **Chat sends with ⌘Return** (Return = new line, as on iPad).
- **Fixtures** compile for Debug builds on the Simulator or a Mac (`FIXTURE_HOST`), never for devices or
  distributed builds.
- **Distribution:** `scripts/upload-testflight-mac.sh`. Build 15 archived and signed for development; the
  upload waits for the owner: a Mac Installer Distribution identity in the keychain and a Mac Catalyst App
  Store profile ("Gradstep Mac App Store"). Not created by the agent: the existing installer certificate's
  key is held outside this project, and new signing certificates are the owner's to hold.

## Topic tags (owner asked 2026-10-07; agent decisions, reversible)

**Owner decided 2026-10-07:** personal tags stay server-visible (not end-to-end encrypted), as built; the owner wants
them for product analytics. Any analytics use stays within the privacy notice (gradstep.ai/privacy says the server
keeps the tags you give papers and that they are not end-to-end encrypted) and reports aggregates, not individuals.

Owner: "I thought we had a tagging system based on topics? … it was useful and we need to bring that back and make
it a first class citizen." Design: [Topic tags](architecture/TAGS.md).

- **Consistent catalog tags**: 3–7 names per paper version from a curated vocabulary (`gradstep-tags-v1`, 120 tags:
  23 areas, 97 topics, each defined), chosen once by Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) from title +
  abstract with the vocabulary as a structured-output enum; arXiv categories as the fallback when the model is
  unavailable. Not free keywords (the web app's drifted between papers).
- **Paid by the platform** under the platform budget (a 0-credit `metadata` hold per paper, $0.01 ceiling), never by
  readers: measured $0.0038 per paper (≈ $0.38 per 100 papers, once per version). Runs in the Cloud Run pipeline
  worker (needs `ANTHROPIC_API_KEY` there) after each paper and each minute; existing papers backfill the same way
  or with `scripts/tag-catalog.mjs run`.
- **Personal tags are service-visible**, synced like archive state (`v2_set_item_tags`, revision-checked,
  replayable), not end-to-end encrypted; the Edit tags sheet says so. This supersedes the earlier plan to keep
  personal labels in encrypted events for tags (server-side joins with catalog tags; no encrypted tag format
  exists). Removing a paper clears its personal tags.
- **What readers see** = catalog tags − tags they removed + their own. Feed chips use the vocabulary's names where
  an arXiv category means the same thing (cs.CL → Natural language processing); others keep their labels.
- Live check (13 calls, $0.049): good tags for Attention, DPO, Mamba, Switch Transformers, RAG, Chain-of-thought,
  NeRF, PPO (after adding "Policy optimization"); remaining errors are comparison/adjacent tags (DDPM → GANs,
  Whisper → Large language models), removable by readers.

## The paper's own contents and bracketed citations (owner feedback on build 14, 2026-10-07)

Owner: "What happened here" (a paper's printed contents as one run-on paragraph) and "The reference isn't working"
(`[Gelfond and Lifschitz 1991]`, `[Lobo et al. 1992; Eiter et al. 1997b]`). Decided without asking (reversible,
reader bridge only, no re-render); details and measurements in [Reader renderer](architecture/READER_RENDERER.md#the-papers-own-contents).

- **Contents as a list, in the paper where it is printed.** One entry per line, indented by section depth, the page
  right-aligned and muted, the dot leader as a faint dotted rule. Nothing moves or is added: the block's text and
  selections are unchanged, and the app's own Contents sheet stays as it is.
- **Conservative detection.** A paragraph is formatted only when all of it is entries (several leader entries, or —
  without leaders — numbered entries in order after a "Contents" caption). Any other text keeps the paragraph as it
  was. Across 48 real conversions only the 5 real lists changed.
- **Entries link like citations.** An entry that matches a heading (number and title) — or, with no heading, one
  numbered run-in head ("3.3.1 Exams Scheduling. …", ACM style; 13 of DLV's subsections exist only so) — jumps there
  with the citation's highlight and Back. Lists of figures and tables are formatted but not linked (they would land
  on a heading, not the figure). Unmatched entries stay plain rather than guess.
- **Bracketed author–year citations needed no new rule.** Build 14 predates the author–year links; with the current
  bridge the owner's paper links 210 of 210 measurable citations (build 14: 3). Small-capital spellings OCR can
  produce ("AND", "ET AL.", "And" in entries) were added; `[Cadoli et al. 1997]`, which fits two entries, stays plain.

## Chat answers: tables, papers named, progress (agent decisions 2026-10-07, overnight mandate)

Legacy audit gaps 4, 2 and 9, built without questions under the overnight mandate; all reversible, all additions under
or inside answers (no page arrangement or selection action changed).

- **Tables** render as a native grid; while streaming, rows at the end stay pipe text until complete, so the layout
  changes once. Tables over 12 columns or 120 rows stay pipe text. Details: [chat rendering](architecture/NATIVE_CHAT_RENDERING.md).
- **Papers in this answer** lists arXiv IDs and DOIs found in the answer's own text, on the device, without a model
  call (at most 8). A paper that appears only in the server's Sources list is not repeated (Sources already offers it).
  Open asks first, like Sources. arXiv adds use the Add sheet's library command (latest version, not the version a link
  names); DOIs use `add-reference` with the reader's outcome wording on the row. "Ask in chat" is not offered from
  chat. A DOI paper added earlier shows "In your library" only once this session's add matched it (the library has
  no DOI field).
- **Progress**: a backward-compatible `status` stream event (`searching` with the query, `reading`, `finding_paper`,
  `adding_paper`), shown as one line under the streaming answer. The query goes only to the reader's stream, never to
  logs. Needs a chat function deploy (not deployed by this work); older servers simply send none.
- **Owner feedback (build 14, items 3, 10, 11):** answer paragraphs, headings and list items are now read-only
  selectable text views (same look; formulas are image attachments) because SwiftUI `Text` cannot extend its selection
  menu. Selecting answer text offers **Ask about this** (puts `About “…”: ` before any draft in the composer and focuses
  it), **Explain** and **Define** (sent as a new question in this chat; with a draft in the composer they wait there
  instead of replacing it), then the system's Copy/Look Up/Share; Copy keeps formulas as `\( … \)`. A formula (long
  press, right-click on the Mac; display formulas through their context menu) offers Copy LaTeX, Copy as text (a
  Unicode approximation, `ChatMathText.plain`), Explain, Define, Ask about this. "Define" is a chat-only prompt
  ("Define the terms and symbols in: …"); the paper's Explain prompt is reused. Your own messages and streaming answers
  keep the system menu. A leading "Answer:" label is stripped on display (stored text unchanged) and the chat
  instructions say not to write one. Bold/italic spans around inline math (`**$n = 0$:**`) now render as emphasis.

## Settings and chat titles (owner feedback, build 14 #7–#9; agent decisions 2026-10-07, all reversible)

Owner: "The account option tells me nothing, sync? Sign out and delete feel like they should be hidden away? What does
appearance mean to the user?", of Acknowledgements in Settings "This doesn't look like it should be there", and chat
titles that showed prompt text and raw LaTeX ("Explain in plain terms, including any symbols: \[\begin{equation*}…").

- **One Account row** tops Settings: the email (or "Signed in with Apple" when the account has none) over "Signed in
  with Apple · Synced". It opens **Account**: Email, Signed in with, **Sync** in plain words ("Your chats and notes are
  synced · They're encrypted with keys held on your devices", "Waiting to sync 3 changes", "Syncing…", "Sync is
  paused" with the reason, "Not synced yet" before this session's first sync finishes) and **Sync now** (moved there from Your research, beside the state it acts on), then **Sign
  out** (with the pending-work note) and **Delete account…** (same sheet, flow and accessibility identifiers). Signing
  out closes the page. Signed out, Settings keeps "Sign in or create an account". Credits, Reading, Your research and
  Testing stay where they were.
- **Sync says "chats and notes", not "library"**: the encrypted sync carries conversations, notes, reading places and
  diagrams; the library list is the server's per account (its own pending changes show in the Library). "Encrypted
  with keys held on your devices" repeats the Privacy page's existing claim; no new claim is made.
- **Sign-in methods** are read from Auth's `app_metadata.providers` in the session Auth already returns (decoded
  tolerantly and bounded, kept with the cached session; no server change). A session cached by an older build shows
  none until the next sign-in.
- **Theme**: "Appearance: System" became **Theme** — Light / Dark / Match device as a segmented control (a menu at
  accessibility text sizes), the same stored setting.
- **About Gradstep** is the last row: name, Version, Edition (private beta · staging), Privacy & data,
  Acknowledgements. The Mathpix acknowledgement says "readable versions of papers" instead of "equation-aware readers".
- **Chat titles are shortened at display time only** (the saved title stays the first question's first 100
  characters; nothing saved or sent changes). In All chats (rows, search, the delete confirmation) and the chat's
  title, a selection action's conversation reads "‹action› · ‹passage›": Explain, Why it matters, Related, Add paper,
  and Define for the earlier "Define this in the context of the paper" wording. Every earlier prompt wording is
  recognized; the prompts now live in one place (`SelectionAction.promptPrefix`, `Services/ChatTitle.swift`) so a new
  wording keeps its short title. LaTeX in any title reads as symbols, building on the answer previews'
  `ChatPreview.readableMath` (environments dropped, a/b, √x, x̂, numeric scripts and ᵀ as Unicode, letter subscripts as
  `d_k` like the previews); a formula cut by the 100-character limit shows up to its last complete part, prose up to
  its last whole word, then "…". Search matches the saved question and the short title.

## Floating chrome and the app's own icons (owner asked 2026-10-07)

Owner, with two Gemini screenshots: "I like the way that they have something at the bottom, but things can kind of
flow past it, it provides an illusion of less wasted space … allow a kind of flow behind copying Gemini … I find our
icons to look overall a little generic, anything we can do to spruce them up?" Decided while the owner was asleep
(no questions); patterns in [DESIGN.md](DESIGN.md) (Floating chrome, Icons).

| Decision | Choice (agent, reversible) |
|---|---|
| Tab bar | Our own floating glass capsule over the screen, not the system `TabView`: iOS 26's `TabView` moves the tabs to the top on iPad, can't disable the Paper tab until a paper is open, keeps every tab alive (the reader's web view, the transcript) and flattens our two-color icons. Same five tabs, order, identifiers (`tab.*`) and keyboard behavior (hidden under a software keyboard). |
| Content behind the chrome | Every screen except the reader (below) runs to the bottom edge under the tab bar and keeps room for it (`tabBarSpace`, inside each NavigationStack — a `safeAreaInset` outside it doesn't reach the screen). Content fades into the background behind bars (94–100 % behind controls, a 22 pt fade past them), so text never sits under a control at full strength. |
| Minimize on scroll | Not done. Gemini keeps its bar still; a shrinking bar moves tap targets while reading, and our scroll views are partly UIKit (transcript, reader), so it would need per-screen hooks. Reduce Motion therefore has nothing extra to switch off. |
| Headers | Library and Feed header controls float on the top band; their search field is a glass capsule. Over the table the band stays solid (its column titles pin under it). Chat: the conversation runs under the title bar. Paper: the page stays between the title bar and the tab bar's room, and the reader's controls float over its last lines on the bottom band, so the page's viewport never changes size. Running the page under the tab bar (with a scroll inset, then with padding at the page's end) and shrinking it for the selection bar both broke reading-position return or citation landing in the UI tests: the reader measures positions in that viewport. |
| Message box | A glass pill above the tab bar with Send/Stop inside it; the transcript scrolls under it. Hide-keyboard stays (a glass circle beside the pill). |
| Reduce Transparency | Every chrome surface is solid (secondary background, hairline) and every band is the plain background. |
| Icons | **"Nabla line"**: the app's own SF Symbol templates (`Assets.xcassets/Symbols`, generated by `tools/icons`), rounded strokes like the logo, each with one amber point; selected tab = accent line + amber point. Chosen over (A) tuned system symbols (filled + hierarchical: clean but still the stock set the owner called generic) and (C) a mini app-icon tile behind the selected tab (strong but heavy, and the ink tile nearly vanishes in dark mode). Screenshots: `.artifacts/visual/chrome-2026-10-07/icon-directions/` in the main checkout. Universal actions keep system symbols (+, …, search). |

Owner feedback on build 14 (same day, [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md) items 4–6), folded into this work:

| Feedback | Change |
|---|---|
| "Ask a question is bad language, you can just have chat" | The message box's placeholder is "Chat". |
| "Space below chat box not well used … the paper vs general option needs to be in a menu … can't take away screen real estate for chatting" | The Paper chat / General chat row is gone; the switch is the chat title's menu (same two modes, Paper disabled without a paper), and the subtitle says which (the paper's title, or "General chat"). The message box sits 10 pt above the floating tab bar, with the conversation running under both. |
| "The icon choice is bad it looks like a refresh icon, it probably needs to have lines in it" | All chats (top bar and menus) is a list symbol: bullets and lines, the first bullet the amber point. |

## Adding any paper: identifiers, uploads, device downloads, sharing (owner asked 2026-10-07)

Owner: "adding a pdf needs to be absolutely bullet proof." About 17 publishers refuse downloads from our cloud
servers, so the reader's device and network must be able to supply the PDF. Agent decisions (reversible unless
noted); design in [PDF uploads](architecture/PDF_UPLOADS.md).

| Decision | Choice |
|---|---|
| Add accepts | An arXiv ID or link (queued on the device, as before), a DOI, any landing-page or PDF link, or a reference, identified without a model by `functions/v1/add-paper` (no credits; conversion metered as today). Arrangement kept: the same sheet, field and Add button, plus a "PDF file" section. |
| Outcomes | Queued → the sheet closes. "Isn't openly available" → **Upload the PDF…** (attached to that paper) and **Download on this device** when a landing link is known. "Blocked" (with its reason) and an unidentified PDF link → **Download on this device**, or Upload. |
| Upload design | The initial signed/upsert branch was superseded during spending review. Reviewed local implementation uses authenticated **4 MiB chunks** through Edge, one immutable Storage send per admitted attempt, and a separate private `paper-uploads` bucket (octet-stream, 4 MiB/object). No client receives Storage write credentials. Freeze binds exact verified chunks, a separate idempotent transaction attaches the import, and the Cloud Run worker verifies complete size, SHA-256, PDF structure and pages before conversion. [Reservation/recovery contract](architecture/ASSET_SPENDING.md#local-ingress-implementation-checkpoint--2026-10-07). |
| Limits | Common asset ledger reserves staging plus all future processing phases before upload; every issued/uncertain physical write remains charged until safe confirmed deletion. 1 GiB owner-private allowance, 5 GiB common beta capacity, 10 active sessions/account and 200/environment, credits ≥1, 40 begins/hour, separate chunk/status rates, 24-hour pending expiry. Seven-day cleanup retires only unused finalized intents; active wanted imports and unknown physical bytes remain protected. Lifetime receipts/read ceilings also bound retained evidence. |
| Privacy | Converted only for the uploading account (owner-private document, `owner-upload-v1` approval; never shared, never reused by another account, never tagged). Preserve the originally approved **encrypted private title** plan. A separately versioned AES-GCM descriptor carries title/optional filename with device-held epoch keys; no new strict history event type. Shared catalog metadata stays neutral and immutable. The original branch's server-visible-title proposal is not implemented or approved. |
| New source kind | `upload:<id>` and encrypted descriptor refs belong to additive **v5** full/compact/query/hydration capabilities. Installed v2/v3 full and v4 compact/query/metadata reads must consistently filter unsupported rows/tombstones and strip descriptor refs. V5 uses a distinct dataset epoch and cursor identity; switching capabilities requires a fresh baseline. The compatibility integration and updated client queues are enablement gates. |
| Closed web papers | Recorded and split privately; their private paper fails at download as `not_open` (no automatic retry) so a reader's PDF supplies the same paper. Before: failed at metadata with no title. |
| Device fallback | Same checks as the server (https, public addresses on every hop, 64 MiB, `%PDF-`, one landing page followed), the app's ordinary request — no bot evasion. Offered inline on `source_blocked`/`pdf_restricted` web imports and in every failed web import's menu; links from the server (PDF locations, landing page, DOI). When the device is refused too: Open in Safari and share the PDF, or upload it. |
| Share extension | Writes to an **app group inbox**; the app imports on launch/foreground (PDFs to the upload queue, a link opens Add). Rejected: the extension calling the backend with a token from a shared keychain group (two processes refreshing one rotating refresh token sign each other out; extensions are a poor host for 64 MB uploads with retries). Items go to whoever is signed in when the app opens. iOS only for now. **Needs provisioning** (lead): App Group `group.com.sciencereader.ios` on `com.sciencereader.ios` and the new App ID `com.sciencereader.ios.share`, App Store profiles "Gradstep App Store" (regenerated) and "Gradstep Share App Store". |
| Migration number | `202610070039`, replacing never-applied 033; it must follow accounting/diagnostic prerequisites 034–038. 033 remains unused, with no placeholder migration. |

## Chat quality: equations, diagrams, Why it matters, a paper's chats (owner asked 2026-10-07; agent decisions, reversible)

Owner asked for chat quality fixes from the legacy gap audit's next tier (rows on the equation prompt, diagrams, "Why
it matters" and a paper's own conversations). Details: [chat](architecture/CHAT.md#diagrams).

| Decision | Choice (agent, reversible) |
|---|---|
| Equation prompt | **Explain** on a single equation asks "Explain this equation: ‹formula›", then after a blank line "Briefly cover the background needed to read it, its overall message, what each symbol means, and how its notation compares with common ML conventions." (the legacy prompt's four parts, one line). The formula comes first so the saved title (first 100 characters) still holds it: "Explain · ‹formula›"; `ChatTitle` drops the instructions whole or cut. "Single equation" = one closed formula and nothing but punctuation, displayed (`\[…\]`, `$$…$$`, an environment) or inline with a relation (`=`, `<`, `\leq`, `\approx`, …). A lone symbol or expression (`\(\beta\)`) keeps "Explain in plain terms, including any symbols". Explain on a formula in an answer uses the same rule. |
| Why it matters | *Removed from the menus 2026-10-24 (owner: "just a special case of chat"); the server mode stays for older builds and old chats keep their titles.* `action: "relevance"`: no search tool and no search hold even with search on; the instructions say to use only the paper's own content (legacy: "Using ONLY the paper's content (do NOT search the web)"). The visible prompt is unchanged, so titles are too. Follow-ups in that chat may search. |
| Diagram rules | The legacy Mermaid label rules join the diagram instructions and the tool description (which said "plain Unicode" before; now ASCII). |
| Where diagrams are checked | **On device**, with the bundled Mermaid 12.1's `parse` in an off-screen web view, before the answer is saved. Server-side was checked and does not fit: Mermaid's parser alone bundles to 5.25 MB minified (esbuild, all diagram types; Mermaid loads them dynamically, so it can't be cut to one type without vendoring internals), over the 5 MB server-side bundling limit our deploys use (`--use-api`) before the chat function's own code; and its flowchart parser needs a DOM (`DOMPurify.addHook is not a function` under Node). |
| The retry and its cost | One retry per diagram, as a **separate metered request** (`action: "diagram_fix"`): one turn with the title, Mermaid's error (≤ 600 characters) and the source; no paper, conversation or search; only `create_diagram`; 2,000 output tokens. Held under the rate card and settled at actual metered cost. The deterministic test’s 1,400-input/600-output-token example costs 2 credits ($0.0088 provider spend); live repair cost has not been measured. Logged as `chat_answer` with `action: "diagram_fix"`. It cannot share the answer's own hold: the answer is settled before the device sees the diagram, and keeping it open would mean holding the stream for a device round trip. Never unmetered; a reader without credits (or an older server) keeps the original. |
| A diagram that still fails | Kept (the answer named it), and its view says "Couldn't draw this diagram" / "View the source below, or ask the chat to draw it again." with the source in a collapsed "Source" disclosure. The same fallback covers renderer unavailability, so it does not claim every failure proves a syntax error. |
| Chat title at narrow widths | Keep the same title menu and full saved/VoiceOver title; fit the visible label between the measured History/New chat touch targets. The shared-window measurement updates when the iPad column resizes. SwiftUI toolbar hosting roots do not share a global coordinate space, and a surrounding frame alone did not constrain the Menu's intrinsic label. |
| A paper's own chats | All chats gains a **This paper** chip, leading All · Paper chats · General (it is the one chosen; at the end it could scroll out of view at larger text sizes), with the count ("3 of 30 chats") under the chips when the four leave no room beside them. It is offered, and chosen, when All chats is opened from a paper chat (the chat's history button or its "…") or from the paper's "…" → **Chats about this paper** (shown when it has any); everywhere else (Library, Settings, general chat, Mac menu) opens on All as before. The chat title menu adds **Chats about this paper**: up to five of the paper's other chats (title, last used, messages) and "All N chats about this paper". |
| Not changed | The general answer length and style ("Lead with the answer… keep answers focused"): an open owner decision, since longer answers cost more credits. |

Deploy: the `chat` function must be deployed before a build with these changes ships (an older server rejects
`relevance` and `diagram_fix` as `invalid_request`, before any hold).

## Reader navigation: find, contents levels, figures, iPad chat column (owner asked 2026-10-07; agent decisions, reversible)

Owner: a reader navigation pass over [legacy gaps](LEGACY_GAP_AUDIT.md) 7, 10, 6 and 5. All additions: the page
arrangement, the Contents button, the figure sheet, the selection actions, Back and the default iPad arrangement are
unchanged. The Paper "…" menu gains Find in paper, Figures and (wide Reader only) Hide/Show chat.

| Decision | Choice |
|---|---|
| Find in paper (#7) | WebKit's own find bar (`UIFindInteraction`), from Paper › "…" › Find in paper and ⌘F with a hardware keyboard (iPad; the Mac keeps its Edit menu items). Only the paper's web view has it, not a figure's. WebKit highlights matches without touching the page or the selection, so no selection bar appears and blocks, quotes and positions are unchanged. The place find scrolls to is the reading position (it is where the reader is); on iPhone the page shrinks above the keyboard while the bar is up, and the found place survives closing the bar and leaving the paper (UI test). |
| Why find had been Mac-only | Not reproducible: with find on for every reader web view, `testFigureOpensFromTheSameVerifiedSnapshotWithLocalImages`, all of `PaperWebViewTests` and both figure UI journeys pass on the iOS 26.4 Simulator. The first Mac version set it to `Platform.isMac` (false on iOS), so no iOS run had used it before the `#if`; the failure seen was most likely the documented first-run page-load timeout on a freshly booted Simulator. |
| Contents levels (#10) | The bridge passes each heading's level and the Contents sheet indents by its distance from the shallowest level shown (18 pt per step, scaled with text size, at most three steps; top-level rows semibold when nested; VoiceOver hears "Level 2"). The title, "Abstract" and a printed "Contents"/"Table of Contents" heading are left out; References stays. Where Mathpix flattened levels — a section and its own subsection on one level, as DPO's "A" and "A. 1" — numbered headings take their depth from the number (port of the web app's `inferDepthFromNumbering`): "2.1.3" two below "2", "A.1" one below "A"; with Roman sections (two or more, one only Roman can be), capital letters one below and "1)" two below. Papers whose levels are consistent keep them (an "A Simple Baseline" subsection is not mistaken for an appendix). Pure section of `reader-bridge.js` (`CONTENTS OUTLINE`). |
| Figure gallery (#6) | Paper › "…" › Figures (shown when the paper has figures): a grid of the bundle's own verified images (first image of each, "+N" for more; drawn on white as in the paper), the number read from the caption ("Figure 3", "Fig. 2" → "Figure 2", "Table 1") and three lines of caption. A figure opens the existing figure view inside the gallery with previous/next and **Show in paper**, which closes the gallery and centers the figure in the paper with the citation highlight and Back; the saved reading position stays at the place left until Back or two screens' scroll away (one before build 21's feedback), as for citations. |
| iPad chat column (#5) | The wide Reader keeps today's default (chat 320–400 pt beside the paper). Paper › "…" › Hide chat gives the paper the full width; a chat button in the paper's bar (and Show chat in the menu) brings it back; a question asked from the paper (selection action, Ask about this paper, opening a paper chat or unsent draft, starting a new paper chat) shows it again. The divider can be dragged (a grabber on the hairline, 24 pt to grab; the panes change once when the drag ends, so a long paper isn't reflowed on every frame); double-tap restores the default; VoiceOver adjusts it in 40 pt steps. Chat 300 pt up to 60 % of the window, the paper at least 420 pt; clamped again on rotation. Hidden and width are kept per device (`UserDefaults`, like text size). Not `NavigationSplitView`: its columns can't be resized by touch on iPad and adopting it would change the panes' navigation stacks. Browse is unchanged (no chat column there). |
| Mac | The shared changes apply to the Mac window too (Find in paper and Figures in the Paper "…" menu, the hideable, draggable chat column). Mac menu-bar items for Figures and Hide/Show Chat are left to the Mac work (MAC_APP.md: every on-screen control has a menu item). |

## References, figure links and Back (owner feedback on build 21, 2026-10-08; agent decisions, reversible)

Owner: "Reference at the top of the message isn't needed"; "Needs to be a discuss in chat button … takes you to the
chat with the ref text in there and you can continue typing"; "Brafman ref missed"; "When figures are referenced you
should be able to link directly to them … And there should also be a 'return to reading location' option in a
sensible location". Reader bridge and native only, no re-render; measurements in
[Reader renderer](architecture/READER_RENDERER.md#figure-table-and-algorithm-references).

| Decision | Choice |
|---|---|
| Reference actions | No title row. Order: Open (arXiv/DOI/link), **Discuss in chat**, Add to library, Copy. |
| Discuss in chat | This paper's chat; the entry goes into the message box as Quote in Chat does (`About “…”: `), the cursor after it, nothing sent. A conversation already under way keeps its subject, so the entry starts a new conversation; an empty new chat is reused and its unsent words follow the quote. No passage anchor (as the reference's other chat action). |
| Hyphenated citations | Surname keys drop every hyphen and fold spacing accents and whole letters (ø, ł, æ …); a name broken by a hyphen and a space or line is one word. One more link in 55 papers, none changed or wrong. |
| Figure links | From labels the captions print (figure, table, algorithm code block, or a caption paragraph and its one unlabelled neighbour); a label two different elements carry, or none, stays plain. A tap shows the element with its caption in a half-height sheet with **Go to figure** (table, algorithm); a caption paragraph with nothing to show is jumped to. 1,236 of 1,291 references linked across 55 papers, 0 to an element whose caption doesn't print the label. |
| Back | One control for every jump, "Back to where you were", at the left of the A− / A+ row (never over it or the tab bar). Lasts until Back, two screens from the landing (was one), or a return by scrolling. The Contents sheet still ends it (deliberate navigation, as decided before). |
| Not done | In-text "Section 3" links; the browser reader's sheet and Discuss in chat (web hooks listed in the renderer doc, for the web owner). |

## Pipeline worker billing (owner approved 2026-10-07, audit F1)

The Cloud Run worker billed ~22.6 instance-hours on 2026-10-07 (instance-based billing, `--no-cpu-throttling`, woken
every minute): about $54/month for a mostly idle instance. It now uses request-based billing (`--cpu-throttling`,
revision gradstep-pipeline-00007): every handler awaits its work before responding, so nothing runs unbilled after a
response. Expected at current volume: ~$0–3/month, mostly within the free tier. Next (approved): wake the worker when
work is queued, with a 10–15 minute sweep, instead of every minute; its design is shown to the owner before deploy.

## Offline-save recovery across app upgrades (2026-10-07)

The owner's build-15 offline-save banner was caused by build 14 saving library entries without the later tags and
import-progress fields. Local checkpoint format 3 marks that decoder boundary, so the next complete server
observation replaces an older readable snapshot without treating those omitted fields as a changed server revision.
For current-format caches, repair is restricted to those four display fields; immutable pins, membership, artifact,
availability and sequence checks remain enforced. Quarantine survives local copy removal and a repaired checkpoint.

The untested handoff also proposed rebuilding unreadable policy and a Try again button that saved only the latest
observation. Review removed those paths: they could forget a failed quarantine before an ordinary outage. A real
persistence failure continues to preserve bytes/private content, halt ordered cache installs and ask for reopening.
This is a client-only compatibility fix; no database migration, cache deletion, server rewrite or deployment is needed.
Local verification and remaining limits are recorded in [Native offline bundles](architecture/NATIVE_OFFLINE_BUNDLES.md#build-14--15-cache-upgrade-2026-10-07-local-review).

## Passage-linked conversations (owner asked 2026-10-07; agent decisions, all reversible)

Owner: conversations linked to the passage they came from — the paper ↔ chat loop the original app was built around
([gap 1](LEGACY_GAP_AUDIT.md#1-conversations-linked-to-their-passage)). Built in `Views/PaperPassages.swift`,
`ScienceReaderCore/PassageAnchor.swift` and the end of `reader-bridge.js`.

| Decision | Choice |
|---|---|
| What is saved | A `TextAnchor` on the new conversation's root event: artifact ID, the first block the selection touches (`elementID`), the quote exactly as asked (formulas as their LaTeX), and up to 32 characters of the paper's text before and after it (whitespace collapsed, read by the bridge with the same text rules as selections). No `page`. |
| Wire format | Unchanged (format 1, no bump). `anchor` has been a `PrivateEvent` field since the first build (`34100c5`), every build decodes it, and the frozen Node ↔ Swift fixture already carries one; builds before this simply never read it. It is inside the encrypted payload, so the service learns nothing new. Older conversations have no anchor; nothing is migrated. |
| Which actions | Explain, Why it matters, Related and Add paper on a text selection or a tapped formula in the paper (*since 2026-10-24 Explain only; the others are in no menu*). Not: chat-answer quote actions (Ask about this, Explain, Define — the text is the answer's, not the paper's), Ask about this paper, or a reference's "Ask in chat". Selection actions always start a new conversation, so continuing one adds nothing. |
| Go to passage | In the chat's title menu and its "…" menu, and on an All chats row (long-press, and a VoiceOver action), for anchored chats whose paper is in the library. Opens the paper if needed, keeps the conversation as the chat's, waits for the reader like a contents jump, centers the passage and tints it for ~2.6 s, and offers the citation **Back** to where reading left off. Unlike a citation peek, the passage then becomes the remembered reading place (as a contents jump does). A request not applied within a minute is dropped. |
| Finding it | Same artifact: the exact quote, preferring its block. Otherwise, or if that fails, the legacy cascade: exact quote → collapsed whitespace → the quote's first line and its 80/60/40/25-character openings (≥ 20 characters) → the text between the saved prefix and suffix (each ≥ 8 characters, within max(400, 2 × quote) characters). Several matches: the one in the anchored block (same artifact only), then the one with matching context. Nothing: "Couldn't find the passage this chat came from. The paper may have changed since." A paper no longer in the library: "The paper this chat came from isn't in your library." |
| Marks | CSS custom highlights (no element added, so selection, citations, figures and reading positions are untouched): a 2 pt accent underline at 50 % (55 % lighter in dark mode). A formula, which is drawn rather than text, gets a line under it (inline) or a bar beside it (display). Marks use exact and collapsed-whitespace matches only, including anchors from an earlier conversion of the same paper. |
| Tapping a mark | Opens its conversation; several on that spot offer "Chats about this passage". Links, citations, contents rows, figures, references, tags and formulas keep their own taps, and nothing opens while text is selected. A marked formula therefore still selects on tap; its chat is reached from the chat or All chats. |
| Setting | Settings › Reading › **Underline passages with chats** (on by default; this device only). Cheap, so included. |
| All chats | With the Paper column shown (iPhone landscape, iPad), an anchored row's muted second line is the passage in quotes (math readable) instead of the newest answer; in iPhone portrait the second line stays the paper's title. The title still reads "Explain · ‹passage›". |
| Not done | Marks aren't announced by VoiceOver (Go to passage is reachable); the browser reader shows marks too (corrected 2026-10-21, B11: it has had them since the passage-link port; several chats on one passage are listed by title and Account › Underline passages with chats turns them off since the browser review fixes), and the Mac app shares this code but was only compiled, not run; passages are found again by text only, not by position within a re-rendered artifact. |

## Purchase verification runtime deployed (owner approved 2026-10-07 evening)

Supabase's hosted Edge runtime lacks certificate primitives Apple's verifier needs, so no Sandbox purchase had ever
been recorded. Apple verification now runs in a private Node 24 Cloud Run service `gradstep-store-verifier`
(revision 00002-qqz; IAM-only, one invoker `gradstep-store-caller`; request billing, max 1 instance, scale to zero;
design cap $6/month of the $100 budget). Supabase still authenticates, admits (migration 033, one-use attempts,
app 50/account-hour, 500/hour, 300/day, 3,000/month; notifications 60/200/1,000) and records credits. Apple
signature, chain, bundle/environment and online revocation checks stay on, with the reviewed OCSP-freshness patch.
Deploy-tool fixes made during rollout: readiness runs as service_role in a read-only transaction; secret readback uses
the API's digest field (`value`); function readback records `ezbr_sha256` (compressed) instead of comparing it to the
decompressed bundle (module sources are compared exactly); the health probe uses the project's `sb_secret_` key.
Rollback: `worker_set_store_verifier_enabled(channel, revision, false)`, then roll the service back; never skip checks.

## Spending controls deployed to staging (owner approved 2026-10-07 evening: "I approve it", "velocity first")

Migrations 034–038 applied after an encrypted backup (`.artifacts/backups/20261008T023921Z-…`). All Edge functions
redeployed from main; pipeline worker cut over through the evidence-checked path: paused revision 00008 → readiness
(blockers cleared: tagging and platform budget paused for the cutover, asset inventory enforced, operator drain
evidence verified) → activated revision **gradstep-pipeline-00009-ncq**, then budget, tagging and the pipeline re-enabled.
- Asset inventory: new `scripts/asset-inventory.py`; scan 48a97cd0… registered 100 manifests' members, 1,119
  objects, 0 discrepancies; enforcement on with **legacy** reader delivery (installed apps keep signed URLs).
- Tavily allowance period configured from the usage API (Project plan, 37/4,000, PAYGO off): Oct 1–Nov 1 UTC,
  limit 3,900, baseline 37. Native (Anthropic) search fallback stays off under the new accounting.
- Drain evidence: `.artifacts/rollout-evidence/20261008-spending/` (Cloud Run instance metrics, Edge deploy ages
  > 400 s, function readback, zero open liabilities), manifest is an operator attestation by the lead agent.
- Tooling fix: `scripts/pipeline_readiness.py` reads service-role-only readiness in an explicit read-only transaction.

## Uploads deployed to staging (owner: "integrate, velocity first", 2026-10-07)

Migration 039 applied (backup first); functions `add-paper` and `upload-pdf` deployed with the private
`paper-uploads` bucket (4 MiB authenticated chunks); worker revision gradstep-pipeline-00010 reads uploads. A
scope-2 asset inventory (both buckets, 0 discrepancies) satisfied 039's gate and the PDF upload policy is enabled.
Private upload titles use the encrypted library descriptors (Codex), so they are not server-visible.

## Browser reader and Mac TestFlight shipped (owner authorized; agent decisions 2026-10-07, reversible)

- Browser reader on its own origin `https://app.gradstep.ai` (Pages `gradstep-app`, staging backend);
  `gradstep.ai/app/*` 301-redirects there. Deploys go through `scripts/deploy-web.mjs`, which refuses a non-staging URL,
  a non-anon key, any `.env.staging` credential in the output or a weakened `_headers`.
- `Cache-Control: no-transform` on all reader responses so Cloudflare's zone-level Web Analytics does not inject its
  beacon (no third-party scripts in the reader; the CSP refused it anyway). The info site keeps the beacon.
- `https://app.gradstep.ai` is in `infra/staging.json` `admin_origins` (the Edge `ADMIN_ORIGINS` list), and staging
  Auth's redirect allowlist gained `https://app.gradstep.ai` and `/auth/callback` for later web OAuth (appended).
- Mac TestFlight uses its own build-number train (Mac build 17 alongside iOS build 17), internal testing only; no
  macOS App Store version was created because the upload did not require one.


## Personalized feed (owner asked 2026-10-07; For you accepted 2026-10-08)

**Owner decided 2026-10-08 (feedback on TestFlight build 21):** "Machine learning and artificial intelligence are too
generic it need to be specific to the individual tastes and their nuances"; "Why not topics? And can we put a
popularity score?" This answers the pending choice: **For you is the Feed's first chip and default**, and ranking may
use the **server-visible library metadata** — the papers added (including Adds from the Feed), their public arXiv
categories, authors and titles, their catalog tags, and the reader's personal tags (server-visible by the 2026-10-07
tags decision). Encrypted data (conversations, notes, passages, upload titles, reading activity) is never used on the
server. Enabling serving or refresh on staging remains the lead's step after review.

Agent decisions that follow (reversible; [design](architecture/PERSONALIZED_FEED.md#specific-topics-and-popularity-owner-feedback-on-build-21-2026-10-08)):

- **Specific topic chips instead of broad categories.** After For you, up to eight of the reader's own topics, chosen
  on the server from their library's tags and own tags plus 15 curated combinations ("RL for reasoning"), ordered by
  interest × specificity, never a broad category area and never a topic on more than 20 % of the pool. Broad arXiv
  categories stay reachable under **More topics**. No model call: the vocabulary, the keyword rules and the catalog
  tags readers already have. Without For you the header keeps the old category chips.
- **Topics per paper** from the same keyword rules (specific first) replace the single broad "Topic" column.
- **Popularity = Hugging Face Papers upvotes**, read only by the shared pool refresh (≤ 12 anonymous requests per run,
  1 s apart, 429 stops), stored on pool rows, shown as "▲ n" or "—" when unknown; never estimated. Semantic Scholar
  citations were measured and rejected for new papers (all 0; anonymous 429s). A separate switch,
  `worker_set_feed_popularity(false)`, stops only these requests.
- **Not run:** an optional one-time Haiku labeling pass over 500 pool papers (≈ $0.95, cap $1) to tune the keyword
  rules; the lead decides.
- The browser reader's Feed and Mac-only polish moved to Codex (owner, 2026-10-08); the discover response contract is
  documented for them.

Owner: "I think we need to also invest in a better feed, it should feel relevant to a users interests and be kept up
to date and changing but have cost under control". Design and cost table: [Personalized feed](architecture/PERSONALIZED_FEED.md).

- **Backend built locally, switched off (option A, no paid API; infrastructure capacity unmeasured):** a shared pool of new arXiv papers refreshed
  from one conditional RSS request every 2 hours (pg_cron waking an Edge function only when due), heuristic ranking
  from server-visible signals (library papers, their categories/authors/catalog tags, personal tags, imports in
  flight, Not interested / More like this), freshness decay, diversity, daily exploration, and a reason per paper.
  Migration 043 (renumbered from the never-applied 044, after 042). It was subsequently applied **disabled** on
  2026-10-08 as the ledger prerequisite to subscription fix 044. Serving and refresh stay off; no refresh function
  or native/web For you UI is deployed. Those product and privacy choices remain a proposal.
- **Still awaiting the owner:** More like this / Not interested actions; keeping Feed feedback on the server (like
  tags) with the proposed privacy text; later, option B (shared embeddings, $1/month cap). An LLM in the loop
  (option C) is not recommended ($25–68/month to tag the pool, or per-reader cost that scales to $330/month at 1,000
  readers). Serving category chips from the pool follows from accepting For you's use of the pool (it stops per-reader
  arXiv requests).

## Build 16 #1, #8, #10 and build 17 #2 (agent decisions 2026-10-08, reversible)

- **Credit resume is state-driven, not event-driven.** A sweep restarts an account's imports waiting on credits
  whenever its spendable balance covers them, so every way a balance grows counts (purchase, restore, reversal, owner
  grant, tester credits, a plan period that starts, a hold released); a balance increase only wakes the worker.
  Oldest first, **skipping** an import the balance cannot cover (a later, smaller one may start), with the needs of
  already restarted, unfunded imports counted against the balance. Download-stage waits need 1 credit (016's
  admission). Suspended/closed accounts are never restarted.
- **arXiv fallback is arXivRaw (OAI-PMH), not OpenAlex.** (Superseded 2026-10-16: the stage reads DataCite, never
  arXiv; see "Our servers never contact arXiv".) The stage already fetches arXivRaw for license evidence;
  its record matches the Atom API's (tested on a real fixture) and needs no extra request. OpenAlex cannot supply
  the arXiv license evidence shared reuse requires and lags new arXiv papers. Throttled metadata waits ~55 min
  (10 tries, Retry-After honored) before failing, shown as waiting.
- **Tavily results are no longer citable** (prompt cache, see CHAT.md); the server's fallback source list is the
  searched pages. Action instructions moved after the paper. Related's first status is sent before the model round.
- **Self-healing (041):** metadata and render failures retry 6 times over ~23 h (10 min … 12 h); downloads keep
  027's 15 min / 2 h / 12 h; paid stages and permanent refusals never retry automatically. A non-paid stage
  unchanged for 6 h while someone waits is failed with its reason (then retried). **Terminal failures stay in the
  library indefinitely** with their reason and actions (Retry when retryable, supply the PDF when not open, Remove);
  nothing is deleted on the reader's behalf. Budget pauses and a full store are deliberate waits, shown as waiting.
- **App follow-up (subsequently shipped in builds 19/20):** non-download failures with `auto_retry_at`
  now say "Trying again automatically". This is display-only; the backend's retry schedule and reasons remain
  authoritative.

## QR device approval (owner asked 2026-10-07: "a way to avoid the recovery code, maybe QR"; agent decisions, reversible)

A new browser is approved from the owner's phone instead of typing the recovery code. Design and limits:
[PRIVACY_AND_SYNC.md](architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr).

| Decision | Choice |
|---|---|
| Primary path | The browser's restore screen leads with **Approve from your phone** (QR + six-digit number); **Use recovery code instead** is one tap away and reuses the same pending request. |
| QR contents | `GSDA1.<request id>.<account tag>.<fingerprint>.<kind>` (97 ASCII characters): the existing 32-byte enrollment fingerprint (account, recipient device, public key, challenge), a 16-byte hash naming the account, and the device kind for display. No secret, no account ID, no URL. |
| What stops a key swap | The approving device recomputes the fingerprint from the server's request and refuses any mismatch before wrapping anything. The six-digit number (derived from the fingerprint) is for people; the QR carries the full 256 bits. |
| Without a camera | Banner "A new device is waiting · Review" on an approved device, comparing the six-digit number only. Documented as weaker (a server able to grind ~10⁶ keys could match six digits); scanning is preferred. |
| Backend | No migration: `v1_request_enrollment`, `v1_enrollment_requests`, `v1_approve_enrollment` and `v1_key_state` (002) already suffice. Expiry stays server-side (15 minutes); the browser renews for the same recipient, so the number never changes. |
| QR drawing | `uqr` 0.1.3 (MIT, a port of Nayuki's QR generator, zero dependencies), as an inline SVG; no network or CSP change. |
| Camera | AVFoundation (works on iPhone, iPad and Mac Catalyst); `NSCameraUsageDescription` and the Mac sandbox `com.apple.security.device.camera` entitlement added. No prompt on a device without a camera. |
| Not done | A new iPad showing its own QR; approving from the browser; a device name beyond its kind. The browser path needs an iPhone/iPad build with Add a device. (Corrected 2026-10-21, B11: a new **Mac** now shows its own QR, MacDeviceApproval.swift.) |

## Browser reader workspace (owner asked 2026-10-07: "copy the old web UX as a starting point"; agent decisions, reversible)

Milestone 1 of the web redesign ([Browser reader › Workspace](architecture/BROWSER_READER.md#workspace-legacy-large-screen-layout)); built on branch, not deployed (QR approval ships first, after build 18).

| Decision | Choice |
|---|---|
| Layout | The legacy desktop modes merged into one workspace: left rail, center, chat pane. Library and Feed open without chat, a paper with it (as Library vs Reader mode); each route remembers its own choice and the widths in this browser. |
| Rail content | Library: views and tags with counts (the chips return when the rail is hidden). Paper: Contents or the compact library (legacy Browse). Feed: topics. |
| Library table | Legacy density with today's data; an Authors column when the center is wide, otherwise the first author under the title. Tags filter on click. |
| Find, appearance | Implemented in the app-owned frame shim, not the shared bridge, so iOS/Mac behaviour is untouched. |
| Add | arXiv stays a library command; DOI/links use `add-paper` with `web_import` only; PDF upload stays out of the browser until its client is built. |
| Chat pane | A placeholder that says chat is not yet in the browser; milestone 2 builds paper/general chat, encrypted history and selection actions there. |

**Library table follow-up (owner requested chosen columns across surfaces; deployed 2026-10-08 UTC):** replaces the
M1 width-dependent column hiding above. Title is always pinned; Authors, Year, Tags, Added, Opened and Progress are
optional and remain reachable by horizontal scrolling inside the center pane. Choices are bounded, versioned
per-browser presentation preferences; initial/Reset defaults are Year/Progress below 760 px and all details on
wider windows. Resizing never removes a chosen column. Import states/actions remain beside Title. Native dialog
checkboxes, Reset, Escape/focus return, keyboard sorting and explicit overflow arrows preserve the existing
navigation/query model. No API/schema/private-data storage change. This follow-up is in hosted Pages `67f5547c`;
see [browser verification](architecture/BROWSER_READER.md#library-column-follow-up--local-verification-2026-10-08-utc).


## Browser chat milestone 2 (agent implementation, local verification 2026-10-07)

The existing right panel now implements encrypted paper/general chat and history, consent, bounded streaming/Stop,
credit feedback, selection actions, passage return/marks and isolated Mermaid diagrams. Native encrypted payloads
and backend contracts stay unchanged. Markdown/math and Mermaid load only when displayed. Browser drafts/outbox
remain tab-memory only and are described that way; durable offline chat requires a separate encrypted local-journal
review. No Safari fallback, plaintext persistence, provider call or hosted deployment accompanies this branch.
Detailed bounds, behavior and evidence: [Browser reader › Chat](architecture/BROWSER_READER.md#chat-milestone-2).

## Paper podcasts v1 (historical design record; current rollout is v2)

The table below records the pre-deployment v1 choices and implementation constraints. The current staging rollout
is documented in [Implementation status](IMPLEMENTATION_STATUS.md) and [Paper podcasts](architecture/PAPER_PODCASTS.md):
migrations 051–055 are applied, the active worker is `gradstep-pipeline-00027-9mv`, the four v2 profiles are enabled,
and the October curated allowance is `$3` / ten operator-seeded, review-gated episodes. Where the historical table
mentions the old `$2`/`$5` seed pilot or v1 profile ceilings, those values remain audit history and do not describe
the current catalog policy.

Owner: "build the notebook LM podcasts feature please". The lead read the request as accepting two of the three [pricing decisions](research/PRICING_RECOMMENDATION_20261008.md#historical-decisions-to-close-before-activation);
Decision 1 (public offers 500/1,200/250) is out of scope and unchanged. Design: [Paper podcasts](architecture/PAPER_PODCASTS.md).

| Decision | Choice |
|---|---|
| Decision 2 — shared catalog funding (accepted) | Platform-funded seed episodes: **at most $2 in total** (raised to **$5** by the owner on 2026-10-08, see *Seed pilot cap* below) for the first two five-minute curated episodes, each admitted at up to **$0.75**, inside the existing $25 provider cap (not on top of it). The operator's own account funds them with zero customer credits (`funding_kind=platform_seed`) under a dated seed period that is created **disabled**; no automatic replenishment or rollover. Browsing and playing ready shared episodes costs no generation credits. Public sponsorship and revenue sharing stay deferred. |
| Decision 3 — private generation (accepted) | Server-readable private source-derived audio/transcripts with the same access/deletion boundary as private PDFs; no private-chat input; an explicit quote ("Estimate … maximum 150 credits"); one funding operation; actual usage charged within that maximum; quality failures charge the customer zero; **no paid automatic retry**. |
| Listening history (agent decision, reversible) | Device-local in v1. The design requires a separately versioned encrypted podcast stream (own envelope domain, cursor, compaction and old-client tests) before any server copy; adding podcast kinds to the existing encrypted stream would stall older clients. No server table for positions exists. |
| Speech provider (agent decision, reversible) | Gemini 3.8 Flash TTS (`gemini-3.8-flash-tts`, Preview) through Vertex AI's global endpoint in GCP project `gradstep`, called with a short-lived token for a dedicated service account that the worker impersonates; no API key. Voices fixed: Sadaltager (explainer) and Erinome (skeptical reader). Reserved at the January 2027 list price ($1/M text in, $18/M audio out) even while the 50% promotional credit runs. |
| Script model | Claude Sonnet 5.5 (`claude-sonnet-5-5`), two passes (five minutes: 6,000 then 4,000 output tokens, ≤ 80,000 input tokens each; every length's caps are in its profile), no tools, no server-side fallback, no SDK retries, structured JSON output grounded only in the pinned converted text. |
| Activation | Nothing is enabled by migration 048. The lead reviews, applies it, certifies inventory scope 3, enables the seed period and runs the $2 seed pilot; private generation is a later explicit switch. The database enforces both the $2 allowance (now $5, migration 051) and a two-episode cap per seed period. |
| Ownership (2026-10-08, owner) | Web player and Mac-only polish moved to Codex; this branch keeps native iOS/iPad, server and generation, and documents the client API contract in PAPER_PODCASTS.md. |
| Lengths (2026-10-08, owner) | Four lengths in the first build: **Short (~2½ min, 110 credits max), 5 min (150), 10 min (220), 20 min (360)**, each an immutable profile with its own bounds, script caps, speech plan and ceiling by the five-minute method ($0.543092 / $0.723104 / $1.076576 / $1.752752 at list price). All four are allowlisted for private generation (customers' own credits, normal quote and hold); the seed pilot stays two five-minute episodes (and $2, raised to $5 on 2026-10-08). Each length is its own work key: a ready episode of another length is offered to play, never reused as the chosen one. |
| Seed episode count (2026-10-08, applying the owner's "$2 total for two curated five-minute episodes") | A seed episode counts against `max_episodes` while its job is in flight or once it produced a release awaiting review or published; failed, canceled and unknown-outcome jobs and releases rejected at review do not (migration 049). Their spend stays committed: the dollar cap ($2, now $5) remains the binding limit. 048 counted failed paid jobs and closed the pilot after two failures with $1.56 unspent. |
| Review as a correction set (agent decision, reversible, 2026-10-08) | After both staging seed jobs failed `script_incomplete` because the review had to re-emit a ~4,800-token draft under its 4,000-token cap, the review returns a bounded correction set (delete / replace text and math / correct claim type and evidence, then a verdict) that the worker applies deterministically to the draft; invalid corrections are a quality rejection. Worker only: profiles, routes, grants and ceilings unchanged; checker version `podcast-checker-v2`. See [Seed pilot fix](architecture/PAPER_PODCASTS.md#seed-pilot-fix-review-correction-set-and-seed-episode-count-2026-10-08). |
| Checker v3 (agent decision, reversible, 2026-10-08) | After both re-admitted seed jobs (worker 00014) failed `script_evidence_rejected` on the spoken-number rule (`unsupported_number:s9`; `number_not_in_evidence:s13`), quotes are matched through one canonical form applied to both sides and stored as the paper's own span; an unverifiable quote is dropped and a claim left without support is removed (never relabeled), rejecting only beyond 30% unverifiable quotes or 30% removed turns, or when a chapter loses its support; digits in names the paper uses and references to its existing sections/figures/tables are not claims; numbers compare by value. Five minutes asks for 16–28 segments and ≤ 4,900 spoken characters so its single speech call fits. Every checker outcome's text-free report is recorded with the job (migration 050). Worker only otherwise: profiles, routes, grants and ceilings unchanged. See [Seed pilot fix 2](architecture/PAPER_PODCASTS.md#seed-pilot-fix-2-checker-v3-and-checker-reports-2026-10-08). |
| Seed pilot cap (owner, 2026-10-08: "Raise to $5 total") | The seed pilot may spend **at most $5 in total** (was $2), still inside the existing $25 provider cap (not on top of it), still at most **$0.75 per admission** (the five-minute profile's hold) and at most **2 published episodes per period** (049's count). Migration 051 raises the `podcast_seed_periods` check and `worker_podcast_seed_period`'s bound to 5,000,000 micro-USD; `podcast-ops.py seed-period` allows up to $5. Existing periods keep their limit until the operator raises them (audited). Asked after three five-minute attempts failed on staging with $1.00 of the $2 committed. See [Seed pilot fix 3](architecture/PAPER_PODCASTS.md#seed-pilot-fix-3-review-reasons-checker-v4-and-the-5-cap-2026-10-08). |
| Review reasons, checker v4 (agent decision, reversible, 2026-10-08) | After a third seed job (worker 00015) failed only because the review returned "reject" with empty lists and no reason (11/11 quotes verified; the checker would have kept 20 of 22 turns), the review returns reason codes (`misrepresents_main_result`, `fabricated_detail`, `wrong_numbers`, `unsupported_claims`, `speculation_presented_as_finding`, `too_many_problems`, `other`, each with segment ids; required with a reject) and is told to repair before rejecting. A reject whose reasons are only `unsupported_claims` / `wrong_numbers` / `speculation_presented_as_finding` and name their segments becomes the removal of those segments, bounded by v3's limits counted against the whole draft (≤ 30% of turns removed, every chapter keeps its support); severe reasons, no reasons, or a reason naming no segment keep the reject. Reports record the verdict, action, codes and segment ids, never text (050 unchanged). Worker only: profiles, routes, grants and ceilings unchanged. See [Seed pilot fix 3](architecture/PAPER_PODCASTS.md#seed-pilot-fix-3-review-reasons-checker-v4-and-the-5-cap-2026-10-08). |
| Long lengths (agent decision, reversible) | Ten and twenty minutes run in stages (draft, review, speech — one worker request each) with the draft and approved script checkpointed in the database between stages, because a twenty-minute script cannot fit one 780 s request. Speech is chunked within Gemini TTS's per-call limits, all chunks granted together and sent concurrently, joined at a natural pause. See [Lengths](architecture/PAPER_PODCASTS.md#lengths-short-5-10-and-20-minutes). |

## Chat model, effort and length; topic titles (historical design record; current rollout is live)

Owner: "chats should have the ability to customize the length and effort and model right there in the chat in a clear
UX", and (TestFlight build 21) "Each chat should have a labeled title on the topic of the chat in the same way that
ChatGPT does … embedded everywhere in the app". The original implementation was built on branch
`chat-controls-titles`; that pre-rollout branch state is historical. Migration 047 and the chat function are now
deployed on staging, and native/browser controls and titles are merged to main for the current Build 24 candidate.
Details and contract: [chat](architecture/CHAT.md#models-effort-and-length-2026-10-08).

| Decision | Choice |
|---|---|
| Models | Haiku `claude-haiku-5-5` (exists: `GET /v1/models`, official price list; replaces Haiku 4.5 for chat), Sonnet `claude-sonnet-5-5` (default), Opus `claude-opus-5-5`. Haiku 5.5 should pass factual/equation checks before it is marketed as the cheap option. |
| Effort | Low / Medium / High = the API's `output_config.effort` with adaptive thinking on every model; Low is today's. Labels are the API's words, served by the server so they can change without a build. |
| Length | Brief / Standard / Detailed: output allowance (answer + effort's thinking allowance) and an instruction after the cached paper; Standard is today's 8,000 tokens and prompt. |
| Server enforcement | Versioned table `chat-profiles-v1` in the chat function; only its combinations accepted; holds at the chosen model's rates; quote frozen with the reservation (migration 047); settled once; requests without a choice are byte-for-byte today's. |
| Estimates | Published by `GET functions/v1/chat` for a 25-page reference paper ("Usually 4–24 credits · up to 37"); planning assumptions until measured. |
| Rate card | Corrected to the price list: Sonnet 5.5 cache reads $0.10/MTok (were charged at $0.20); unknown models at the Opus 5 card. |
| UX | iOS/iPad: a capsule in the message box under the text, beside Send (Gemini's arrangement), opening "Answers in this chat"; Settings › Chat defaults; a quiet "Sonnet · Low · Standard" under answers. A chat keeps its newest answer's choice; selection actions carry the visible choice. |
| Titles | Haiku 5.5 writes a 3–7 word topic title in parallel with the first answer, inside the same metered operation (≈ 0.02 credit), sent as an SSE `title` event, stored by the device as an encrypted conversation revision (`titleSource`). Untitled chats get one on their next question; no bulk generation. Rename everywhere; a generated title never replaces a renamed one. |
| Web | Contract documented for Codex (owner moved web and Mac-only work to Codex on 2026-10-08); the integrated browser implementation is now deployed and its current status is in `BROWSER_READER.md`. The earlier branch commits (`338e628`, `c286bdf`) remain historical. |


## Study: an adaptive tutor on one paper (owner asked 2026-10-14; agent decisions, experimental, reversible)

*Superseded 2026-10-22 by "Study mode and the paper's AI Explainer" above: the knowledge map and its Haiku update are removed.*

Owner: "an experimental feature that combines quizzes you and teaches you about a paper… adaptive… display [the
mental model] in some type of flow, html, or graph." Decisions taken to build a first slice to learn from
([CHAT.md](architecture/CHAT.md#study--2026-10-14-experimental-staging)):

- **A chat action, not a new product surface or storage.** `action: "study"` on an ordinary paper conversation; the
  knowledge map (concepts with a state, links, focus, journey, next step) is the only new state and it travels with
  each turn in memory. Nothing new is stored on the server, in encrypted history or in the browser, so the experiment
  can be removed or redesigned without a migration or a sync-format change. The cost: the map is lost when the chat
  is left or the app relaunches (the conversation itself stays). Open: whether a map should be kept with its
  conversation (a sealed event kind, format 2) once the shape settles.
- **Two requests per turn, like follow-ups.** The tutor answers; a forced Haiku 5.5 tool call updates the map from
  the exchange (never the paper). One mechanism already proven for follow-ups; the map update is testable and cheap.
  Open: a single-request design once the tutor's output format is stable.
- **The tutor's protocol is fixed in the prompt** (judge, then exactly one step and one question; teach with
  citations, verify, deeper, tangent, revisit) rather than learned; the next step is recorded on the map so the client
  can show it and a later design can override it.
- **Map rendering reuses the diagram renderer** (Mermaid flowchart, state classes, thick border for the focus) with a
  journey list and a concept list beside it, instead of a new graph component.
- **Not done:** persistence across sessions, a cross-paper model of the reader, quizzes with scoring, spaced
  repetition, and any admin or analytics view. The proposal in
  [proposals/LEARNING_GUIDE.md](proposals/LEARNING_GUIDE.md) remains the place for the product angle.

## Tall and Wide layouts, two slots (owner decided 2026-10-22 after the cross-surface UX audit)

Owner: the web "seems extremely cluttered with an inconsistent placement of buttons and styling"; the iPhone "feels
planned, controlled and well thought out". Decisions, in the owner's order of conversation:

- **Layout follows the window's shape, not the device.** Wide = at least as wide as tall and at least ~900 pt; otherwise
  Tall. Tall is the iPhone app exactly (iPhone, iPad upright, Split View halves, narrow windows). Wide is the laptop
  layout (browser, Mac, iPad sideways: "when an iPad flips over it becomes laptop oriented"). A foldable iPhone follows
  the same rule: folded is Tall, unfolded is Wide (owner, same day). The rule reads only the window size, never the
  device type.
- **One top row on Wide** ("having two rows is awkward at the top… just one row"), about 52 pt: the five places
  (Feed · Library · Paper · Chat · Snippets, with 🔍 last) and each slot's own where-to-go, create and ⋯. No brand
  row, no gear: Settings is the last row of every ⋯. Bottom: only the chat composer. Search, find, notices and sync
  status float over content; nothing inserts a row. New features must fit an existing bar or ⋯. *Superseded on the
  iPad, 2026-10-23 (below): the places are a menu in the top-right corner, and rows exist only where a slot needs one.*
- **Fewer visible controls** ("hiding more controls behind a menu… not feeling like a MS Word document"). Text size
  stays the iPhone's floating control ("works well").
- **Two slots, six views** (owner approved "let's start with it"): Read, Browse (Papers | Paper), Navigate
  (Contents | Paper), Explain (explainer in the paper's slot, iPhone look), Discuss (Paper | Chat), Chats (All chats |
  Chat). Actions move between them with content-preserving transitions (Explain → Continue in Chat → Discuss); never
  a third column. Tall shows the same views one slot at a time. *Partly superseded on the iPad, 2026-10-23 (below):
  Explain is a companion on the paper's right, not over its slot; Browse is the Library place itself.*
- **Search** lives at the top of the left list, like Mail; a result opens on the right and the list stays.
- **Selection actions** on Wide: a small capsule at the selection (Explain · Save snippet · ⋯) and right-click; the
  web's bottom-centre five-button bar "didn't work well". Tall keeps the iPhone bar.
- **Approved web changes:** Library and Feed get one ⋯ each (Add paper first in Library's); a Settings window replaces
  the long account menu; information dialogs close with ✕, task dialogs have Cancel + verb bottom right.
- **Order:** iPad first ("the most challenging… has to accommodate both usage patterns"), then web, then Mac.
- Proposal with drawings: https://claude.ai/artifact/7bkqfqkryuJM5VU7HganDj (private to the owner).

## iPad Wide: a places menu and each place's own two slots (owner direction 2026-10-23; agent's first pass)

Owner: the five places "use space at the top. Lets put them in a menu in the right hand side, which is conceptually
similar to the ... menu… they never cost vertical space"; "when one is selected, we have custom two panel behavior for
each of the 5 functionality areas"; Library with a paper on the right "is fine, but you should have the option to adjust
where exactly in the screen the divider is… you are still technically in 'Library' view"; "'Paper' can also be a left
primary item… When Paper is a left primary item, the AI explainer and equation explainer can go on the right"; Feed
presents "the abstract to the right… By default, we present it to the left half of the screen". Decided for the iPad's
Wide shape only (Tall, the Mac and the web unchanged); spec in DESIGN.md › Tall and Wide:

- **Philosophy:** each place owns one arrangement: its list on the left from the start, what was picked on the right;
  positions never jump; a draggable divider everywhere two slots show, remembered per place as a fraction of the width.
- **Places menu** in the window's top-right corner, always the same spot, showing the current place's symbol; the
  rightmost slot's ⋯ just left of it, a companion's ✕ left of that. ⌘1…⌘5 choose places. Replaces the capsule.
  *Superseded the same day (below): the places menu is in the top-left corner.*
- **Rows only where a slot has controls** (lists, a conversation, a collection, Contents); the paper floats its controls
  (list toggle, ☰, ⋯) and has 0 pt of chrome above its page.
- **Library** = list | paper (placeholder with none); **Paper** = promoted with the list toggle (or dragging the divider
  past the list's minimum), with Contents on its left or a companion on its right (AI Explainer, equation view, figure
  page, chat); opening a helper beside the Library or Feed promotes the paper first; never three columns. **Feed** = list
  (left half) | abstract and details, Read opening the paper there; picking never adds a paper. **Chat** and
  **Snippets** keep their list | detail with the divider. **Search** = the Library with its field focused.
- Owner, same day: "when going from anything with one panel to two, they should break apart in such a way that the
  divider is actually in the middle" — every arrangement's divider starts at 50% (a dragged one is kept; double-tap
  returns to the middle — *superseded below: a double tap lets the list cover the window; VoiceOver's Reset returns
  the divider to the middle*).
- Agent choices in this pass (reversible): minimums list 280, paper 420, companion 320 (Contents 420); a drag must end 40 pt past a
  minimum to close a slot; the explainers keep their own sheet bar (Snippet · Chat · AI Explainer, ✕) in the companion
  slot; Listen stays one slot; the collection's name moved from its stream's heading into its row; the Library ⋯ "Show
  library beside paper" toggle is Mac-only now (the iPad's Library always has the paper beside it), and the paper's ⋯
  keeps it as the list toggle's twin.
- **Supersedes (iPad Wide):** the places capsule in the one top row; "Explain in the paper's slot"; "the Library and Feed
  tables are not in the container"; Browse as Papers | Paper inside the Paper place.

## iPad Wide: owner corrections after TestFlight 88 (owner direction 2026-10-23)

Decided for the iPad's Wide shape (Tall, the Mac and the web unchanged except the turn below); spec in DESIGN.md › Tall
and Wide:

- **Places menu: top-left (owner correction, 2026-10-23).** "I thought I asked for an icon in the top left that says all
  the different options, Feed, Library, etc… I meant the top left." The places button sits in the window's top-left
  corner, the same spot in every Wide view, a list covering the window included; the leftmost slot's row or floating
  controls start after it (`placesLeadingReserve`): the Library and Feed search and chips, All chats' and Collections'
  search, Contents' tabs, and the paper's list toggle and ☰ when the paper is leftmost. Each slot's ⋯ stays at that
  slot's top-right; a companion's ✕ stays left of its ⋯. Reading mode is unchanged (no places button). *Supersedes the
  top-right corner above.*
- **A double tap on the divider covers the window, as on iPhone.** "When you double tap, have the list be right over the
  entire paper, the same way as the iphone, not in the middle of the left and right." The list (or a companion on the
  right) covers the whole window; the other slot stays loaded at its place beneath it. A small glass handle at the far
  edge brings the two slots back; picking from the list (the open row again included) splits the slots again with the
  picked thing on the right. *Supersedes "double-tap returns to the middle"* (VoiceOver's Reset still does).
- **A real divider drag.** "When I drag to the left or right, currently the line moves initially, and then the page
  updates only when I drop… that doesn't feel like a real drag." Both slots follow the finger on every frame; the
  preview line is gone. The position is kept and a slot closes only when the drag ends (past a minimum plus 40 pt);
  while the drag is that far, the closing slot stays at its minimum and dims to half.
- **Turning upright keeps the paper in sight.** "If I'm on Library, with a paper to the side, and I flip it, it's
  slightly confusing that the paper is no longer there. We should make sure that the paper we were just reading appears
  in the middle of the list, and it's initially highlighted"; then "And then it dims, similar to the way the Figure
  outline dims in the AI Figure Explainer when looking at subfigure." The Tall list centres that paper's row and tints
  it, the tint fading on its own with the figure outline's timing. The Feed does the same for its picked article; a row
  not in the list gets nothing.
- Agent choices in this pass (reversible): the covering is for this run only (a new launch starts split); the handle is
  a 20 × 56 pt glass capsule with a compact chevron in secondary colour, vertically centred at the far edge; the tint is
  the Feed's picked-row accent at 12%, full for 0.9 s (the turn's own animation, then the outline's 0.4 s wait) and then
  an ease-in fade over `FigureFullscreenStage.fadeDuration` (1 s); a covered slot is transparent and its covering slot
  is modal for VoiceOver; the paper reflows live while the divider is dragged (no coalescing) and the reader bridge keeps
  the paragraph at its top on every width change, enabled by the host on iPad only
  (`__scienceReaderKeepPlaceOnResize`), so the iPhone, the Mac and the browser keep their behaviour.

## Menus, explainers and prompts on iPad: owner feedback on TestFlight 88 (owner direction 2026-10-24)

Owner, from the iPad on TestFlight 88. Decided for every shape unless noted; spec in DESIGN.md › Tall and Wide (Selection
actions, Prompts as on iPhone), Contents discovery and Tables:

- **Upright, the explainers cover the page as on iPhone.** "I was just using the vertical view on iPad and I noticed the
  AI explainer doesn't cover the whole page. Please make it like iPhone no need for a UX difference there." In Tall on iPad
  the AI Explainer, the equation view and a figure page are the iPhone's sheet scaled up to the window (it was the small
  centred form sheet); sideways they stay beside the paper. A turn moves an open one between the two.
- **Why it matters goes.** "I think the why it matters button should go, it's just a special case of chat. Users may have
  their own phrasing etc." It is in no menu (the paper's edit menu, the Mac's right-click and Paper menu). Chats it began
  keep their titles ("Why it matters · …", `ChatTitle`), the stored raw value "Relevance" still decodes, and the server's
  `relevance` mode stays for older builds.
- **A text selection's menu is Copy · Explain in Chat · Save snippet.** "iPad for non reference hold with options, it's a
  long horizontal list, many of the options suck, it's a bad experience. translate, related papers on a random text
  selection? It needs to be better thought out." Earlier: "find related papers in response to an equation just doesn't
  really make sense." The system's Look Up, Translate, Search Web, Share, Speak, Writing Tools and any later system
  addition go (only the system's Copy is kept); Related papers and Add paper go from text selections and equations
  (adding a paper stays on a reference's menu; related papers are a question for the chat, in the reader's own words,
  as Why it matters). Draw snippet stays only where nothing is selected (the paper's ⋯; the Mac's right-click on the
  page). The equation menu is Chat about Equation · Focus · Copy as Text. Figure pages' selections get the same
  trimming. `SelectionAction.similar` and `.ingest` stay for stored chats only. The Mac's "Ask About Selection" submenu
  became one item, Explain Selection in Chat (⌥⌘1). *Supersedes "Why it matters" in the chat-quality table and "Which
  actions" in Passage-linked conversations; the browser reader (paused) still offers them.*
- **A reference's menu is the native one.** "the list of options when clicking on references doesn't follow the native
  iOS style." The action sheet (plain text rows, Cancel) is replaced by the system's pull-down menu at the entry with each
  action's symbol (Copy, Open on arXiv, Add to library, Discuss in chat), the Mac's way already; Copy stays first wherever
  the menu opens. Before iOS 17.4 (no programmatic menu) the action sheet remains.
- **The Feed opens as a table, like the Library.** "Why is the feed default view not a table like the library." Only an
  explicit List stays the List; accessibility text sizes show rows; Wide's picking (abstract on the right) works the same
  from the table. *Supersedes "View as List (default)" in Library and Feed table layouts.*
- **Prompts as on iPhone, never a centred card over two slots.** "In the ai explainer it again put the prompt in the
  middle of the screen over the two left and right underneath please fix that, make the UX same as iPhone find all
  instances where this guidance applies and fix it." In Wide, a prompt raised from a slot covers that slot only, rising
  from its bottom edge with the iPhone sheet's grabber, corners and detents; the other slot stays usable (`slotSheet`).
  App-level sheets, and every sheet upright, use the iPhone's sheet scaled up (`appSheet`): the window's width upright,
  a page sideways. System alerts and anchored confirmation dialogs and popovers stay the system's.
- Agent choices (reversible): the slot's sheet closes with its own Cancel/✕, a drag on its grabber (not the whole sheet,
  so its lists keep scrolling), a tap on the dimmed slot or VoiceOver's escape; it dims the slot 18%; its large detent
  leaves 10 pt above as on iPhone; a sheet that asks not to be swiped away (unsaved text, the chat's consent) ignores the
  drag and the tap. A slot's sheet becomes the system's on a turn to Tall (and back). The chat's consent and answer
  options cover the chat's slot whenever the chat is in one (RootView shows them otherwise). Full-screen covers (a
  figure image, a snippet at full size) and share sheets are unchanged. Fixture runs still reset the Feed to the List
  unless `--feed-layout=` names one, as the Library's do, so existing journeys keep their rows.

## Interest index server layer (agent design 2026-10-24; Phase B built on staging the same day)

Design: [architecture/INTEREST_INDEX.md](architecture/INTEREST_INDEX.md), under the approved
[proposal](proposals/INTEREST_INDEX.md). Nothing is built or deployed. Agent choices, reversible until Phase B ships:

- **Model and runtime.** gte-small fp32 ONNX in the existing Cloud Run worker (Node, `onnxruntime-node`), baked into
  the image and checked by SHA-256. It is identical to the step-1 vectors (min cos 1.0000); int8 was rejected (top-10
  neighbour agreement 0.92). The tokenizer's padding must be off.
- **Storage.** pgvector `halfvec(384)`; the migration enables the extension. No ANN index.
- **Public corpus.** The Feed pool, kept 180 days. Catalog papers are embedded but never shape any shared artifact,
  because the catalog is the union of readers' libraries.
- **Map rebuild.** Weekly and warm-started, with split at 2× and merge below ¼. An ID is kept at Jaccard ≥ 0.5 and
  cos ≥ 0.9, with a 0.05 drift cap; successors are recorded. Measured: cold rebuilds keep 10 % of leaf IDs, warm ones
  keep 98 % at steady-state turnover.
- **Delivery.** Term statistics, the map and pool fingerprint shards are database-held immutable artifacts served by
  the Edge function `interest-index`. Library fingerprints come only from the caller's own membership
  (`v1_interest_library_fingerprints`). Bulk download is used instead of a k-anonymous fetch.
- **Cost and AI.** No LLM calls until November's naming. Cost is $0 fixed and about $0.05–0.50 a month in usage.

**Interim decisions by the lead (coordinating agent), 2026-10-24; the owner can revisit them.** Recorded at the lead's
request when it gave the go-ahead for Phase B (staging only):

1. **Corpus window: 180 days.** Storage stays well within the plan (about 430 MB at steady state).
2. **Rebuild cadence: every two weeks until the corpus reaches about 50,000 papers, then weekly**, always warm-started.
   The successor map is kept so that topic IDs synced to devices migrate cleanly (`interest_policy.rebuild_days_growing`
   14, `rebuild_days` 7, `weekly_after_papers` 50,000).
3. **Privacy notice:** the wording in [architecture/INTEREST_INDEX.md](architecture/INTEREST_INDEX.md) §5 stays marked
   "owner approval needed before public release". It does not block staging.
4. **Local database tests:** PostgreSQL 17 with pgvector from Homebrew is acceptable (docs/TESTING.md). TextBrain's
   tool folder is untouched.
5. **Rebuilds are due-based, never one missable slot** (lead, prompted by an owner question): due once the map is
   rebuild_days old; started in the weekend 06:00–10:00 UTC window, or at the next 10-minute tick once 24 hours overdue;
   failed, blocked or killed builds retry after 10 minutes, 1 hour, then 6 hours; Health names a missing kick heartbeat
   (1 hour), a post no run claims (30 minutes) and a map older than rebuild_days + 2 days (migration 0153).
