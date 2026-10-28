# gradstep.ai landing page (proposal, 2026-10-15)

Owner: "prepare a nicely designed landing page for Gradstep Ai … well defined, not over done, not Ai generated,
minimal but with useful info and a light marketing pitch and some impressive visuals. Take into account industry
trends. Make sure every word is strategized around in terms of the narrative and marketing message. At the same time
we should not pretend to be further along on the company journey than we actually are. You are free to leave certain
things open to discuss … And the importance of augmenting human understanding in the age of agents."

## Current revision — founder copy, 2026-10-27

**Status:** the existing complete landing draft in `web/site-next/` now incorporates the founder's motivation and
five requested themes. This revision is local and unpublished; the live placeholder in `web/site/` is unchanged.
The existing layout, real product screenshots, calls to action, links and light/dark behavior are retained.
The page remains static HTML/CSS with no scripts, web fonts or third-party requests.

| Requested theme | Where it appears | Concrete message |
|---|---|---|
| On-device AI, cloud AI and your “I” | Founder section | AI should expand human understanding; local models help prepare PDFs, requested cloud explanations help with difficult ideas, and the reader's questions guide learning. |
| A new way to understand research | Hero and reading introduction | Ask about a passage, unpack an equation, check the source and return to the paper. Starts with AI/ML research. |
| Privacy and encryption | How it works and privacy note | PDF conversion stays local; notes/conversations are encrypted before storage or sync; library metadata and provider-visible AI requests are explained separately. |
| Explanations at your fingertips | Existing figure, equation and study screenshots | Figure crops beside explanations, equation symbols with source/background distinctions, and questions that help the reader test understanding. |
| A personal library and interests | Expanded library section | Save papers, organize labels, keep notes, discover related work and request recommendations. Library/notes/conversations can sync; PDFs and prepared reading copies stay local. |

Claims were checked against the HTML-first, device-PDF, chat, figure/equation, notes and privacy/sync designs and
current implementation. The page names arXiv HTML as the strongest support and Apple PDF models as experimental.
It does not promise local AI chat, universal PDF accuracy, guaranteed citations, reading-position sync, a fully
rolled-out interest map, provider zero retention or encrypted shipping model weights.

**Validation:** `npm test` passes, including 80 browser test files / 734 tests. Ten Chromium/WebKit checks cover
1440 px desktop, 390 px phone and 320 px narrow phone, light/dark themes, image loading, local anchors, keyboard
access to the skip link and horizontal overflow. All pass with no page errors, missing assets or third-party
requests. Desktop/mobile screenshots were visually reviewed. Evidence is in
`.artifacts/landing-founder-20261027/` in the main checkout; no public preview was published for this revision.

Publishing remains a separate task. The copy does not change the beta-access mechanism or claim a new release.
For deployment, use the existing site workflow after reconciling the final draft and privacy policy; this revision
does not copy files into the live site or invoke that workflow.

The original proposal below is retained as historical design rationale. Its headlines, provider details, open
questions and privacy audit describe the October 15 draft, not the current copy or deployment status.

## Original narrative — 2026-10-15 (historical)

One idea, carried through every section: **AI should help you understand the paper, not stand in for reading it.**

The current wave of research tools is agentic: deep-research agents search a field and return reports, and paper tools
attach a summary or a podcast to every paper. That's useful for coverage. The cost, which the research on cognitive
offloading keeps pointing at, is that a fluent summary is easy to mistake for understanding. Gradstep's honest edge is
that everything it does keeps the reader in the source and makes the source checkable: answers cite paragraphs,
figures and equations come apart in place, and study mode makes the reader do the explaining. The page says that in
plain words and then shows it, with real screens, on a real paper.

| Section | Job | Why it is there |
|---|---|---|
| Hero: *Understand the paper, not a summary of it.* | Position against the default (summaries) in seven words | The contrast is the product. "Summary" is the word every competitor's homepage leads with. |
| Lede | Say what it is and the one mechanism that earns trust | "Every answer points to the paragraph it relies on" is concrete, true and checkable in the screenshot below it. |
| Hero screen | Prove it immediately | The real reader with DPO open and a real answer full of ¶ markers. No mock-up. |
| Why Gradstep: *Agents can read for you. Understanding is still yours to build.* | The "age of agents" argument, in two short paragraphs | Concedes what agents do well (coverage), then names what they don't replace. Not anti-AI: "The AI explains. You stay with the source." |
| The summary / the reasons | The one crafted visual: makes the argument in content, not adjectives | A one-line summary of DPO next to the four-step reason chain, each step cited (¶27, ¶29, ¶30, ¶33, taken from real Gradstep answers). The caption lands the point: only the second lets you judge whether the method fits your problem. |
| What it does: three features | Show, don't list | Figures taken apart, equations one symbol at a time, a tutor that asks back: the three things that most directly build understanding, each with a real screen on the same paper. |
| Also in the beta | Mention the rest without overselling | Episodes, diagrams, library and feed in one line each. |
| How it works: *What happens where.* | Honest data path, three facts | arXiv HTML on the device; PDFs never uploaded; questions go to Anthropic. Builds trust by being specific, and states the cloud part plainly. |
| Where we are: *Early, and changing every week.* | Set expectations; invite | Private beta, platforms, ML/arXiv focus, and an invitation addressed to people who read ML papers. No numbers, logos or quotes. |
| Footer credit | Licence and provenance | The paper's CC BY credit, and that screens are from the beta and answers were written by Claude during testing. |

## Words worth a human look

- **"Understand the paper, not a summary of it."** Lightly combative toward summary tools without naming anyone. If it
  feels too sharp, the softer form is "Understand the paper you're reading."
- **"Agents can read for you."** True of today's deep-research agents. "Read" is generous; "skim" would be pointed.
- **"The part you can't delegate."** The page's thesis in five words. Worth keeping wherever the page is quoted.
- **"The AI explains. You stay with the source."** Deliberately says "the AI": hiding it would read as evasive.
- **"Equations stay real math."** Accurate for arXiv's HTML (MathML). Avoid "always": papers without HTML exist.
- **"It is never uploaded to our servers."** True of the current design and the staging cutover. Please confirm it is
  true of the production configuration before launch (AGENTS.md: no claims without evidence for that exact setup).
- **"Nothing is sent until you agree the first time."** The chat consent dialog. Episodes and Add paper's metadata
  lookups also reach providers; see the privacy item below.
- **"It gets better by reading real papers with it and fixing whatever gets in the way."** Chosen over "beta readers
  tell us…", which would imply more testers than there are.
- **Calls to action:** "Join the private beta" (mailto) and "Already in? Open it in your browser". The second avoids
  implying the browser version is open to everyone.

## Alternative headlines

1. Understand the paper, not a summary of it. (used)
2. Stay in the paper. (shortest; a stance more than a promise)
3. Read machine-learning papers with an assistant that shows its work. (most literal; strongest for search)
4. AI that helps you understand, not just summarize.

## Visuals and how they were made

All screens are the real product. Nothing was drawn or edited beyond cropping.

- **Browser screens** (hero, figure parts, equation, study): the current browser app, built locally against the e2e
  fixture backend on separate ports. The paper is DPO, loaded from **arXiv's own HTML** (2305.18290v3) through the
  app's device path. The chat answers are **replayed verbatim from staging runs on 2026-10-14/15** (Claude Sonnet 5.5
  through `scripts/chat-live-smoke.mjs`): the reference-model answer, the Figure 1 parts answer with the model's own
  boxes, the Eq. 7 symbols and background, and the first study turn. Two notes for full honesty:
  - The figure-part notes in the replay are the parts' labels (the log kept labels and boxes, not notes). Notes only
    show in the whole-figure dialog, which is not pictured.
  - The study map shows the logged concepts and states. The log did not keep the map's links, so none are drawn
    (the real turn had three).
  - The transient "Latest message" button was hidden for the captures.
- **iPhone screen:** from the native app's Simulator journey (`testFigurePartsAreInlineWhereTheAnswerDiscussesThem`),
  with the project's own authored test figure. It is captioned "with a test figure".
- **Share image** (`img/og.png`, 1200×630): a crop of the hero screen.
- Capture scripts: `landing/capture.mjs` and `landing/shoot-page.mjs` in the session scratchpad (not committed).

Product issues noticed while capturing (for the app owner, not the page): the equation view shows symbols as raw text
("L_DPO(π_θ; π_ref)", "E_{(x,y_w,y_l)∼D}") rather than typeset, though the model also returns LaTeX for each. Its
background also showed only its first paragraph a few seconds after streaming finished.

## Licences

- **DPO:** Rafailov et al., "Direct Preference Optimization: Your Language Model is Secretly a Reward Model",
  arXiv:2305.18290, **CC BY 4.0** (checked on the abstract page). Its text, equations and Figure 1 appear in the
  screens and are credited in the footer.
- **iPhone test figure:** authored project fixture (`ReaderSamples/4851d817…`, "original pixel-letter and diagram
  artwork; no external fonts or images").
- **Brand assets:** copied from `web/site/brand/`.

## Industry trends (for positioning; nothing here is quoted on the page)

- **Deep-research agents** are now a recognised category: multi-step agents that plan, browse and write structured
  reports ([Deep Research Agents: A Systematic Examination and Roadmap, arXiv:2506.18096](https://arxiv.org/abs/2506.18096);
  [Deep Research: A Survey of Autonomous Research Agents, arXiv:2508.12752](https://arxiv.org/pdf/2508.12752)). 2026
  work focuses on verification and long workflows ([Analytics Vidhya roundup, Aug 2026](https://www.analyticsvidhya.com/blog/2026/08/top-agentic-ai-research-papers/)).
- **Paper tools** converge on summary-first features: AI overviews, blog-style summaries and ask-AI side panels
  ([alphaXiv on the App Store](https://apps.apple.com/us/app/alphaxiv/id6782411985);
  [alphaXiv review 2026](https://www.toolcenter.ai/en/articles/alphaxiv-review-2026)). Generated podcasts became
  mainstream with NotebookLM's Audio Overviews, with mixed views on their depth for research
  ([arXiv:2511.08654](https://arxiv.org/pdf/2511.08654); [Aaron Tay](https://aarontay.substack.com/p/audio-overviews-in-google-notebook-lm)).
  Elicit is positioned for systematic review and extraction ([comparison](https://aicomparison.ai/notebooklm-vs-elicit/)).
- **The offloading critique:** frequent AI use correlates with lower critical-thinking scores, mediated by cognitive
  offloading (Gerlich 2025, *Societies*, n=666, cross-sectional,
  [doi:10.3390/soc15010006](https://doi.org/10.3390/soc15010006)). Knowledge workers with more confidence in GenAI
  report less critical thinking (Lee et al., CHI 2025). An MIT Media Lab EEG preprint (small n) is often cited. All
  are correlational or preliminary, so the page makes the argument without citing numbers.
- **arXiv HTML:** about 97 % of submissions produce some HTML, roughly 75 % without conversion errors
  ([arXiv:2605.16562](https://arxiv.org/pdf/2605.16562); [arXiv accessible HTML](https://info.arxiv.org/about/accessible_HTML.html)).
  This is why the page says "the official HTML version" and does not claim every paper works.

**Positioning by contrast** (no competitor named on the page): they make papers faster to skip; Gradstep makes them
easier to understand. Every answer is anchored to the source; the reader does the understanding.

## Open for the owner

1. **Privacy page (blocking).** `web/site/privacy/` still describes the old design: servers fetching papers and
   converting them with Mathpix, uploads converted privately, iPhone and iPad only. It doesn't mention episode
   providers (DeepSeek for scripts, Google for voices) or the browser and Mac. The landing page's "never uploaded"
   contradicts it. Update it before this page goes live.
2. **Tagline.** Keep "Understand the paper, not a summary of it.", or pick an alternative above.
3. **Founder note.** A two-line "who's building this and why" in "Where we are" would do more for trust than any
   feature. It needs your voice and your call on how personal to be.
4. **Beta access.** Is email the mechanism (mailto today), or a TestFlight public link, or a waitlist? The browser
   link says "Already in?" because it is unclear whether new accounts can use it unassisted.
5. **Pricing stance.** The page says nothing about price or credits. Say "free during the beta" only if that is true
   for new testers.
6. **Episodes.** "Listen to a paper…" is listed under "Also in the beta". Staging shows many failed episodes this
   month (16 of 22 per the Health tab), so you may prefer to drop it until it is reliable.
7. **Which paper to feature.** DPO is CC BY, well known and shows equations, figures and theory. An alternative is a
   newer paper your readers will recognise. It must be CC BY (or similar) for the screens.
8. **Claims to confirm for production:** PDFs never uploaded; consent before any cloud request; Anthropic as the
   answering provider (web search goes to Tavily/Anthropic search when used — fine to leave to the privacy page).
9. **Company footer.** No legal name, address or © line is shown. Add whatever the company entity requires.

## Privacy page draft

**Draft:** `web/site-next/privacy/index.html`, in the new site's style; not deployed. Every statement on it is
checked below against code, migrations, staging configuration or current docs. Anything that couldn't be verified is
left off the page and listed under "Owner to confirm". The statements describe the staging configuration the beta uses
today (`infra/staging.json`); a production environment needs the same check before this page applies to it.

### What changed (live page → draft)

| Topic | Live page (6 Oct) | Draft (15 Oct) |
|---|---|---|
| Platforms | "an iPhone and iPad app" | iPhone, iPad and Mac, and a web browser |
| Papers | Servers fetch papers and convert them with Mathpix; uploads converted privately | The device fetches arXiv's HTML and prepares it; servers don't fetch, store or convert it. Servers look up catalog details only (arXiv, OpenAlex, Crossref). Conversions made before 13 Oct remain and may still be used |
| PDFs | "anything you upload" is converted on our servers | PDFs (added, chosen, dropped, downloaded) stay on the device and are never uploaded; in a browser they stay in the chosen file and tab; an experimental on-device model |
| Library | "not end-to-end encrypted like your conversations" | "not encrypted with your device keys the way your conversations are" (no E2EE wording) |
| Service records | not mentioned | Devices, days of use and which parts, usage and credits; daily activity kept up to 400 days |
| Conversations | Conversations and notes encrypted on devices; servers "cannot read them" | Conversations, titles, notes, reading positions, diagrams and figure breakdowns encrypted on the device before storage or sync; servers store only the encrypted form; browser keys kept by that browser |
| AI answers | Question, passage, earlier messages, paper text → Anthropic; Tavily or Anthropic search | Same, plus figure and table images (consent v3), the equation view, the study record and its update, and Claude-written titles and follow-up suggestions |
| Episodes | not mentioned | Paper text uploaded and stored privately; writer is Claude or DeepSeek; voices from Google Vertex AI; private audio and transcript only for your account; links expire within 15 minutes; kept until account deletion; catalog only from CC BY / CC0 papers |
| Account | Apple, Google or email code via Resend | Same, plus "new accounts are by invitation" |
| Support | Text and screenshots stored privately | Same, plus visible to support staff who sign in with two-factor authentication |
| Where | Supabase US West; "Paper processing runs on Google Cloud"; Cloudflare website | Supabase US West (Oregon); Google Cloud US West (Oregon) for paper lookups, tags and episodes; Google Vertex AI global for voices; Cloudflare for the website and browser app; Anthropic, DeepSeek and Tavily on their own infrastructure |
| Deletion | "Settings → Account"; library, encrypted history, private papers, reports, sign-in; accounting records "without your account identity"; backups expire | Delete in the iPhone, iPad or Mac app; adds devices and keys, private episodes and their text, activity records; paid-work records kept "linked only to an internal number"; backup sentence removed pending confirmation |

### Verification

| Claim on the draft | Evidence |
|---|---|
| The device fetches arXiv HTML and prepares it; servers don't fetch, store or convert it | `docs/architecture/HTML_FIRST_READER.md:17`, `:38`; `supabase/functions/_shared/metadata-pipeline.ts:1-2` (server is metadata only); `docs/IMPLEMENTATION_STATUS.md:802-806` (hosted check: zero PDF or server reader-artifact requests) |
| PDFs are never uploaded (apps) | `supabase/functions/upload-pdf/index.ts:1,10-12` (refuses with 410 `pdf_device_only` before reading the body); `apps/apple/ScienceReader/Services/PDFUploadQueue.swift:6-8` (device-only intake, no upload session); no `upload-pdf` or `paper-uploads` reference in `apps/apple` or `apps/web/src`; Share extension not embedded (`apps/apple/project.yml:81-84`) and has no network access (`:115-116`) |
| A PDF you add, choose, drop or download stays on the device | `HTML_FIRST_READER.md:14`; `apps/apple/ScienceReader/Views/PDFUploadViews.swift:8-13` (Files or a drop → `model.uploads.add`, local); `docs/IMPLEMENTATION_STATUS.md:913` (encrypted `DevicePaperStore`, source-only download) |
| In a browser, a PDF stays in the chosen file and tab | `docs/IMPLEMENTATION_STATUS.md:811`; browser CSP connects only to arXiv and the backend (`scripts/deploy-web.mjs:64`) |
| Experimental on-device model | `apps/apple/ScienceReader/Views/RootView.swift:1346-1347` ("nothing sent anywhere") |
| Mathpix no longer used (not stated on the page, which no longer mentions it) | `metadata-pipeline.ts:1-2`; no deployed function or worker imports `_shared/mathpix.ts` (the result parser `mathpix-result.ts` only verifies stored bundles); no `MATHPIX` key in deploys; `IMPLEMENTATION_STATUS.md:806` (zero Mathpix attempts since migration 058) |
| Catalog lookups from arXiv, OpenAlex and Crossref | `metadata-pipeline.ts:3-5`; hosts `export.arxiv.org`, `api.openalex.org`, `api.crossref.org` in `_shared` |
| A reference's text goes to Crossref, OpenAlex and arXiv | `supabase/functions/add-reference/index.ts:1-3`; `_shared/reference.ts:77-78` |
| Feed searches go to arXiv and OpenAlex | `supabase/functions/discover/index.ts:86-92` |
| Older server conversions remain and may be used | `PRIVACY_AND_SYNC.md:7` (retained copies not deleted); `_shared/chat.ts:568-573` (paper text loaded from storage when no device context); `_shared/podcast-worker.ts:158` (episodes from converted text) |
| Open-licence conversions shared | `docs/architecture/HTML_FIRST_READER.md:4-5` with the live page's existing statement; `PRIVACY_AND_SYNC.md:43` ("Eligible shared papers … reuse according to access/license policy") |
| Library service-readable, not device-key encrypted | `PRIVACY_AND_SYNC.md:46-47` (library membership, devices, usage; archive state and tags) |
| Tag suggestions: title and abstract to Anthropic | `PRIVACY_AND_SYNC.md:48`; `_shared/tags.ts:3,15,62-67` (Claude Haiku, title and abstract only) |
| "For you" ranked on our servers, no AI model | `discover/index.ts:6-10` ("keyword rules, no model"); `_shared/feed-rank.ts` imported at `:17` |
| Service records; daily activity up to 400 days | `supabase/migrations/202610150069_admin_health.sql:6-17` (table, 400-day retention); devices `202610020002_encrypted_sync.sql` (`app_private.devices`) |
| Conversations etc. encrypted on the device before storage or sync | `PRIVACY_AND_SYNC.md:45`; `apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/Crypto.swift:100` (AES-GCM seal); `apps/web/src/lib/events.ts:8` (event kinds: conversation, message, note, position, diagram); `apps/web/src/lib/journal.ts:10`; `apps/web/src/lib/keys.ts:158` (non-extractable browser key) |
| Servers store only the encrypted form | `supabase/migrations/202610020002_encrypted_sync.sql:45` (`sync_events.ciphertext bytea`, the only payload column); `PRIVACY_AND_SYNC.md:19` |
| New device via approval or recovery code; lost all → unrecoverable | `PRIVACY_AND_SYNC.md:19,23`; `apps/apple/ScienceReader/Views/SettingsPages.swift:141` (Add a device) |
| Question, passage, earlier messages, paper text → Anthropic | `apps/apple/ScienceReader/Views/ChatConsentView.swift:25-27`; `apps/web/src/ui/ChatPane.tsx:224`; `_shared/anthropic.ts:279` (paper block) |
| Figure and table images | `ChatConsentView.swift:28`; `_shared/chat.ts:24,209` (consent v3 only) |
| Equation view sends the equation and paper text | `docs/architecture/EQUATION_VIEW.md` (request table); `_shared/chat.ts:170` (equation actions need the numbered device paper and a selection); `_shared/chat-equation.ts` |
| Study record sent; updated by a Claude model from reply and tutor answer | `_shared/chat.ts:325` (map in instructions), `:676` (update from map, answer, reply); `_shared/chat-study.ts:10` (Claude Haiku) |
| Titles from the question; follow-ups from question and answer start | `_shared/chat.ts:632`; `_shared/chat-title.ts:9`; `_shared/chat.ts:666`; `_shared/chat-follow-ups.ts:11` |
| Web searches to Tavily or Anthropic's search | `ChatConsentView.swift:29`; `_shared/chat.ts:511-521,547` |
| Servers don't store chat text | `ChatPane.tsx:226` ("passes the request through without storing the text"); `_shared/chat.ts:214` (only a request digest), `:699` (logs counts, never text) |
| Episodes: paper text uploaded, kept privately only until the episode is made (migration 076, 2026-10-16) | `supabase/functions/_shared/podcast-api.ts:71-80` (`private-content/podcast-sources/<account>/<sha256>.txt`); `supabase/migrations/202610140066_podcast_device_sources.sql:30-38`; infra bucket `private-content` `public: false` (`infra/staging.json`) |
| Writer Claude or DeepSeek writes and checks the script | `_shared/podcast-worker.ts:518-529` (same provider for script, review and repair); `_shared/deepseek.ts:8`; `migrations/202610140065_podcast_writer_choice.sql` |
| Google Vertex AI voices | `_shared/podcast-speech.ts:7-8,231` (gemini-3.8-flash-tts, location `global`) |
| Private audio and transcript, only your account can play | `migrations/202610080048_paper_podcasts.sql:1022-1025` (`podcast_release_visible`: private → owner only), `:1951` (`private/<owner>/…` paths); bucket `podcast-assets` `public: false` |
| Audio links expire within 15 minutes | `202610080048_paper_podcasts.sql:2157` (`worker_podcast_delivery_create`: `interval '15 minutes'`) |
| Kept until account deletion | No expiry for released episodes or source text in code (cleanup only for jobs that never became a release: `PAPER_PODCASTS.md:673`); account deletion removes owned objects (`202610050017_account_deletion.sql:74-77`) |
| Catalog only from CC BY or CC0 papers | `202610080048_paper_podcasts.sql:233,822,869`; `PAPER_PODCASTS.md:669` |
| Sign-in with Apple, Google or email code; Resend; invitation only | Staging Auth config read 2026-10-15: `external_apple_enabled`, `external_google_enabled`, `external_email_enabled` true, `disable_signup` true, SMTP `smtp.resend.com`; `scripts/configure-email.py:2` |
| Purchases through the App Store | functions `store-sync`, `app-store-notifications` (`infra/staging.json` functions); live page wording unchanged |
| Support staff use two-factor authentication | `apps/admin/src/main.tsx:104` (MFA gate), `v1_account_context.operator_verified` (`202610020001_catalog.sql:154-157`) |
| No advertising or third-party analytics code | No analytics or ads SDK in `apps/web/package.json`, `apps/apple/project.yml` or `Package.resolved`; browser CSP `connect-src` limits the app to arXiv and the backend (`deploy-web.mjs:64`) |
| Supabase US West (Oregon) | Management API project region `us-west-2` (read 2026-10-15); `infra/staging.json` pooler `aws-0-us-west-2` |
| Google Cloud US West (Oregon) for lookups, tags, episodes | `infra/staging.json` `pipeline_worker_url` (`…us-west1.run.app`); `services/pipeline-worker/run.ts:8-11` (metadata, deletion sweep, tags); `services/pipeline-worker/server.ts:55-61` (podcast entry point) |
| Cloudflare serves the website and the browser app | `scripts/deploy-web.mjs:14-16` (Pages targets) |
| Delete in the app or in the browser | `SettingsPages.swift:147`; browser account menu › Delete account… (`apps/web/src/ui/App.tsx` `deleteAccount`, `lib/account-deletion.ts`; `e2e/account-delete.spec.ts`, fixture only — the browser must be deployed before the page goes live) |
| What deletion removes | `202610050017_account_deletion.sql:93-128` (library, sync events, envelopes, devices, keyrings, reports, rate windows, roles); `:74-77` (owned objects); `_shared/account-deletion.ts:104` (Auth user deleted); `202610150069_admin_health.sql:40-47` (activity records) |
| Paid-work records kept, linked only to an internal number | `202610020001_catalog.sql:10-16` (`accounts`: id, `auth_user_id … on delete set null`, timestamps only) |

### Owner to confirm (not on the page)

1. **Backups.** The live page says deleted data "leaves our backups as they expire". Staging has manual encrypted
   checkpoints (`.artifacts/backups/…`) with no stated expiry, plus whatever Supabase keeps. State a real retention
   period, or keep the sentence out.
2. **Provider locations and terms.** Where DeepSeek, Anthropic and Tavily process data isn't visible in code.
   DeepSeek in particular (`api.deepseek.com`) deserves a plain statement of its jurisdiction and terms before the page
   names it. `DATA_HANDLING_AND_COSTS.md` still says "No DeepSeek traffic is enabled", which is stale since migration 065.
3. **Episode retention.** Episodes and their source text have no expiry, and users can't delete a single episode. Is
   "kept until you delete your account" the intended policy?
4. **Support reports.** There's no retention period for resolved reports (`SUPPORT_STORAGE.md:13` calls it "a
   separate explicit lifecycle").
5. **Policy commitments** carried over from the live page: "We don't sell your data…", "We don't train AI models on
   your data". Code can't prove these; please reconfirm them.
6. **`privacy@gradstep.ai`** is carried over from the live page; confirm the mailbox exists.
7. **Browser account deletion.** Answered 2026-10-16 ("Use sensible default please"): added to the browser's account
   menu, mirroring the apps (BROWSER_READER.md › Keys in the browser › Delete account); the page now says "in the app
   or in the browser". Deploy the browser release that has it before publishing the page.
8. **Production.** Re-run this check against the production project before the page applies there.

### Engineering follow-ups found while verifying

- **Deletion of episode text and audio relies on registration.** `_shared/account-deletion.ts:25-29` empties whole
  folders only in `paper-assets`, `support` and `paper-uploads`. Paper text uploaded for episodes
  (`private-content/podcast-sources/<account>/`) and private audio (`podcast-assets/private/<account>/`) are deleted
  only through their `stored_objects` rows. An upload whose registration failed would survive account deletion.
  `PAPER_PODCASTS.md:1494` says the prefix was "added to the deletion plan for safety", but no code does it.
- **Episode records outlive the account.** `podcast_device_sources` (paper title, authors, arXiv id) is protected
  against deletion (`202610140066_podcast_device_sources.sql:26`). After deletion it stays linked to the closed account's
  internal id. That's consistent with "records of paid work … linked only to an internal number", but worth an explicit
  decision.
- **Prompt wording.** `PAPER_INSTRUCTIONS` still describes the paper as "Mathpix Markdown of the full text"
  (`_shared/chat.ts:262`). That's harmless to privacy but stale for HTML-first papers.
