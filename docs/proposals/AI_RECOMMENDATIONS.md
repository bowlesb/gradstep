# AI recommendations and "Chat about this paper" — proposal (2026-10-21, for owner approval)

Owner, TestFlight 78 (`ALsQuX0_-_YLhsw7YkcwwYM`, 15:14, on the Library's paper menu): "I want two more features: an AI
recommendations, it uses AI with our server to search for the most similar papers and just adds them, users should have
the option of requesting 1, 3 or 5. Additionally a Chat option where they [go] to a general chat about this paper."

Nothing here is built. It needs your yes on the decisions in the last section.

## What exists today (and why it isn't enough)

- **Find similar papers** (Library row menu, Paper ⋯) joins the paper's top three keywords into an ordinary ML paper
  search (`ReaderModel.findSimilarPapers`). There is no notion of similarity beyond the words; you then pick and Add.
- **ML paper search** ranks DataCite's arXiv records by keyword relevance (`supabase/functions/_shared/paper-search.ts`;
  devices run the same ranking on arXiv's API). No embeddings or similarity index exist anywhere in the backend.
- The personalized **Feed** keeps a shared server pool of ~25k recent papers with abstracts (`app_private.feed_papers`,
  PERSONALIZED_FEED.md) ranked by hand-set weights; embeddings were costed there and not built.
- **Add** goes through the existing import (`v2_begin_import` via library commands, duplicates refused on the client;
  the server's `v2_add_paper_once` for server-side adds). Servers never contact arXiv (ARXIV_DEVICE_ONLY.md): a paper the
  server proposes must come from DataCite or the feed pool, and its reader is still prepared on your devices.

## 1. AI recommendations

### Where it lives

- Library row menu and Paper ⋯, directly under **Find similar papers**: **Recommend similar papers ›** with three rows,
  **Add 1**, **Add 3**, **Add 5** (a submenu, so the choice is one tap and no new screen). Browser: the same entry in the
  paper's ⋯ menu.
- Nothing else is asked: no review sheet (you said "just adds them"). The added papers appear at the top of the Library
  sorted by Added, each with a quiet **Recommended** in its details line ("Recommended from *Evolving Semantic
  Indexes…*"), and a one-line status banner while it runs: "Finding 3 papers like *Evolving Semantic Indexes…*" →
  "Added 3 papers · Undo". Undo removes exactly those additions.
- They go into the catalog you are viewing, like any Add.

### Server flow (one request, one model call)

1. Device → `POST recommend` with `{library item id, count: 1|3|5, operation id}`. The server already knows the paper's
   title, abstract, authors and keywords (library membership is server-visible metadata, PRIVACY_AND_SYNC.md); no paper
   text or chat leaves the device.
2. **Candidates without a model**: up to 40 papers from (a) the existing DataCite search run with three queries built
   from the paper (its title's key phrase, its top keywords, its first author) and (b) the feed pool by shared
   topic/category. Papers already in your library (any catalog, archived included) and papers you removed are excluded.
3. **One model call through OpenRouter** (Haiku 5.5 on Vertex, the model already used for catalog tags): the seed's title
   and abstract plus the 40 candidates' titles and 700-character abstracts; the model returns the best N ids with a
   12-word reason each, as JSON validated against the candidate list (it can only choose, never invent a paper).
4. The server adds them with `v2_add_paper_once` (idempotent per operation id; library capacity and add-rate limits
   unchanged) and returns them; the devices prepare each reader from arXiv's HTML as for any Add.
5. The reasons are shown under each added paper's title for the first day ("Same benchmark; extends its retrieval
   index"), then only in the paper's ⋯ › Why recommended.

### Cost and credits

- Measured analogue: catalog tagging with Haiku costs about $0.004 per paper at ~3.6k input tokens (TAGS.md).
- One run: ~13k input tokens + ~400 output ≈ **$0.002** with Haiku 5.5 at OpenRouter's $0.11 / $0.55 per million
  (DeepSeek V4.1 Flash ≈ $0.003; Gemini Flash ≈ $0.011). DataCite searches are free (rate-limited, 60/h per account).
- Proposed price: **1 credit per run** (1 credit = $0.005), whether you ask for 1, 3 or 5 — the model call costs the
  same. Charged only when at least one paper was added; a run that finds nothing, fails or is undone within the banner's
  life is free. It uses the existing reserve/settle path (`worker_reserve_operation` → `worker_openrouter_admit` →
  `worker_settle_operation`), so the platform budget and per-account limits apply unchanged.
- Budget: 1,000 runs/month ≈ $2, inside the $25 metered-provider cap within the $100/month private-beta budget. Add a
  per-account limit of 20 runs/day.
- Build needs: a migration adding `recommend` to `metered_operations.kind`, the tariff row for the chosen model, the
  `recommend` edge function, and admin dashboard counts.

### Privacy

- Sent to the model provider: the seed paper's public title/abstract and public candidate abstracts — the same class of
  data already sent for catalog tags. Not sent: your other papers, chats, notes or reading history.
- Provider retention: Haiku via OpenRouter on Google Vertex; no zero-retention claim is made (DATA_HANDLING_AND_COSTS.md).
- The recommendation (seed → added papers, reasons) is stored as ordinary library metadata, server-visible like the rest
  of library membership, not end-to-end encrypted. Settings › Privacy says so in one line.

### Later (not in the first version)

- Embedding similarity over the feed pool (PERSONALIZED_FEED.md "option B", ~$0.10/month) to pick better candidates
  before the model call.
- "Recommend from my whole library" in the Library's ⋯.

## 2. "Chat about this paper" (general chat)

- Library row menu and Paper ⋯ gain **Chat about this paper**: it opens Chat in **General chat** with a new conversation
  whose first, unsent message box holds `About “<title>” (<first author>, <year>): ` and the paper attached as a small
  chip above the box (title + abstract only). Nothing is sent until you press Send.
- Difference from Paper chat: Paper chat answers from the paper's full text prepared on your device; this general chat
  sends only the title and abstract (public metadata) with your question, so it works for a paper whose reader isn't on
  this device and is for wider questions ("how does this compare to…", "what should I read first").
- No new server work: general chat already accepts a question carrying text; the chip is part of the message
  (`mode: "general"`, CHAT.md). Cost is that of any general-chat answer.
- If you prefer, the same entry could instead open the existing **Paper chat** (full text, prepared on the device
  first): say which.

## Decisions for you

1. Recommendations add without review (as asked), with Undo in the banner — or show the N picks first with Add all?
2. Price: 1 credit per run, free when nothing is added? Daily limit 20?
3. Model: Haiku 5.5 (cheapest, already used for tags) — or DeepSeek Flash?
4. "Chat about this paper": General chat with title + abstract (proposed), or Paper chat with the full text?
5. Names: "Recommend similar papers" › "Add 1 / 3 / 5", and "Chat about this paper".
