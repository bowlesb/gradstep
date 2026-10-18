# Topic tags

## Device keywords, build 70 feedback (2026-10-18; release candidate 71)

The owner prohibits generic AI/Machine learning keywords and asks for more discriminative paper terms.
Clients derive up to six specific vocabulary topics and named methods/datasets from title/abstract, excluding
those generic labels. The reader shows a Keywords heading before Introduction, provenance and Edit. Custom
and deliberately cleared keywords remain authoritative; legacy own/hidden tag edits are retained. This is
local deterministic derivation, not a paid model classification or a claimed TF-IDF quality result. Server
catalog tagging below remains historical/current compatibility data, not the new default display.

Native local search additionally indexes bounded terms from verified encrypted installed reading copies,
rebuilds off the UI thread, and clears a paper's terms when its contents/account are removed. No plaintext
persistent index or server paper upload is introduced. See NATIVE_LIBRARY_SEARCH.md and the regression evidence
in IMPLEMENTATION_STATUS.md. Browser keyword presentation follows the metadata derivation; the native body index
is not claimed implemented in the browser.


Status, 2026-10-07: **implemented and tested locally; not yet applied or deployed.** Migration
`202610070030_tags.sql` (after 027–029), the pipeline worker change and the app need the main session to apply/deploy.
Owner request: "I thought we had a tagging system based on topics? … it was useful and we need to bring that back
and make it a first class citizen." The archival web app asked an LLM for 5–10 free keywords per paper and showed
them as chips (`reference/web/lib/metadata.ts`, `PaperTable.tsx`); free keywords drifted between papers. Gradstep
keeps the chips and makes the tags consistent.

## Source-only keywords (build 69 feedback; migration 088 planned)

New device-only papers have category-derived keywords until the reader edits them. The per-account
`import_requests.source_tags_customized` flag distinguishes an explicitly empty list from no customization.
The existing revision-fenced, idempotent `v5_set_source_details` marks a successful edit customized; the import
projection adds `tags_customized` without changing catalog metadata. Nonempty existing source tags count as
customized. Clearing all keywords must stay empty after sync and restart. The reader presents the editable row
immediately before the first body section, with an Add keywords action when empty. No model call is involved.

## Two kinds of tags

| | Catalog tags | Personal tags |
|---|---|---|
| What | 3–7 names from Gradstep's vocabulary, per paper version | The reader's own tags (free text) and catalog tags they removed |
| Who sets them | Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) from title + abstract; arXiv categories as a fallback | The reader (Edit tags) |
| Stored | `app_private.catalog_tags` (shared, one row per `publication_versions` row) | `library_items.user_tags`, `hidden_tags` |
| Synced | Projected onto each library item (`library_items.catalog_tags`) with a new `state_seq` | `v2_set_item_tags` (durable library command) |
| Paid by | Platform budget, never reader credits | — |

What a reader sees (`Paper.tags`): catalog tags minus hidden ones, then their own (`PaperTags.effective`).
Removing a paper clears its personal tags; re-adding starts from the catalog's.

## Vocabulary

`supabase/functions/_shared/tag-vocabulary.ts` (`gradstep-tags-v1`): 120 tags, 23 **areas** (Natural language
processing, Computer vision, Reinforcement learning, Robotics, AI safety, …) and 97 **topics** (Diffusion models,
Mixture of experts, Preference optimization, Retrieval-augmented generation, Mechanistic interpretability, …), each
with a one-line definition. The app's copy is `ScienceReaderCore/TagVocabulary.swift`; a backend test fails if the
two differ. Thirteen tags name the arXiv categories that mean the same thing (cs.LG/stat.ML → Machine learning,
cs.CL → Natural language processing, cs.CV/eess.IV → Computer vision, cs.RO → Robotics, …). Those give the fallback
tags and the Feed's chip names; broader categories (cs.DC, cs.HC, stat.TH, …) keep their own Feed labels and give no
fallback tag. Renaming or removing a tag bumps the version; the worker then re-tags papers recorded under the old one.

## Assigning catalog tags

The Cloud Run pipeline worker runs a tagging sweep after each paper and at the end of each run (pg_cron calls it
every minute), so a new paper is tagged while it converts and existing papers are backfilled without a separate
job. `scripts/tag-catalog.mjs run` runs the same loop on demand (`status` shows counts).

1. `worker_tags_claim` picks versions that readers have (visible items) or are adding (imports with metadata) and
   that are untagged, have only fallback tags, or were tagged under another vocabulary. With a model available it
   reserves a **platform-funded hold** through `worker_reserve_operation` (kind `metadata`, 0 reader credits,
   $0.01 ceiling, attributed to the first reader who wanted the paper), so `platform_budgets` caps every call. A
   refused hold (budget exhausted or paused) returns the version without one; a funder with three open holds
   leaves it for the next claim. Claims have a 5-minute lease; an expired one is released and its hold spent at
   the ceiling (the call may have been billed).
2. The worker sends the title, abstract (≤ 4,000 characters) and arXiv categories (as a hint) with the vocabulary
   as a structured-output enum (`output_config.format`), `max_tokens` 256, no thinking. Answers are mapped to
   vocabulary spellings, deduplicated, at most seven.
3. `worker_tags_record` settles the hold at the actual cost (input $1, output $5 per million tokens), records
   `provider_usage_events` (`anthropic`, message ID), and stores tags, method (`model` / `categories`), model,
   vocabulary, metadata ID and input digest. Without a model (no key, refused hold, failed call) the arXiv-category
   tags are recorded; a fallback never replaces model tags. Failed model calls back off (10 min × 4ⁿ, at most a day,
   six attempts); a lost call is charged its upper bound and recorded as an estimate.
4. `worker_tags_project` gives each affected visible item the new tags with a new `state_seq` and journal entry
   (account → document → library state, as `worker_project_library_availability`). Insert, re-add and re-pin copy
   the current tags in the same transaction (trigger), so entries never change without a new `state_seq`.
   `worker_tags_pending_projection` finishes projections an interrupted run left.

Operator switch: `worker_set_tagging_enabled(false)`. The Cloud Run worker needs `ANTHROPIC_API_KEY` (added to
`scripts/deploy-pipeline-worker.py`'s secrets); without it only fallback tags are recorded.

**Cost.** ~3,600 input + ~30 output tokens: **$0.0038 per paper**, once per paper version (measured on 13 calls,
2026-10-07). 100 papers ≈ $0.38. Prompt caching does not apply (Haiku 4.5's minimum is 4,096 tokens).

## Wire and sync

Item entries gain top-level `tags`, `user_tags` and `hidden_tags`, each only while the item is visible and the list
non-empty, so all other entries stay byte-identical (older builds ignore top-level keys; `metadata` is untouched).
`v2_set_item_tags(operation, document, tags, hidden_tags, expected_revision)` mirrors `v2_set_item_archived`:
replayable receipt, membership-revision precondition, bumps the revision (a concurrent Remove/Archive from an older
revision conflicts). Lists are validated on both sides: trimmed, single spaces, 1–40 characters (≤ 120 bytes), no
control characters, distinct ignoring case; at most 12 own and 8 hidden.

In the app, `LibraryMutation.setTags` replaces both lists. Editing again before an edit has synced is resolved in
one queue transaction (`editLibraryTags`): an unsent edit is replaced; a sent one is followed by the new lists,
frozen at its receipt's revision; another pending change to the same paper must finish first. A sent edit has no
Undo (edit again). Pending edits show at once in `Paper.tags`.

**Privacy.** Personal tags are service-visible like membership and archive state, not end-to-end encrypted; the
Edit tags sheet says so. The earlier design note that personal labels would be encrypted events
([data model](DATA_MODEL.md#topics-and-private-labels)) is superseded for tags: tags need server-side joins with
catalog tags, and the encrypted event format has no tag representation. Collections and notes remain encrypted
plans. Title and abstract go to Anthropic for catalog tagging; both are public catalog metadata (owner-private
conversions use the same arXiv metadata).

## App

- **Reader**: the paper's tags as small quiet chips under the publication line; tapping them opens
  Edit tags. Paper options (`…`) → Edit tags.
- **Library**: row long-press → Edit tags; List rows show the first three tags in their details line (arXiv topics
  when a paper has none). `Paper.tags` feeds the Library table's Tags column and filter (built separately) and
  library search.
- **Edit tags sheet**: chips with ×, an "Add a tag" field, suggestions (vocabulary matches with their definitions,
  the reader's own tags, removed catalog tags), Cancel / Save, medium height.
- **Feed**: topic chips use the vocabulary's names; categories with the same name show once. With For you
  (build 21 feedback), the chips are the reader's own specific topics from these tags and their own tags, plus curated
  combinations of vocabulary tags; broad areas named after arXiv categories are left to More topics
  ([personalized feed](PERSONALIZED_FEED.md#specific-topics-and-popularity-owner-feedback-on-build-21-2026-10-08)).

## Tests

`tests/database/test_tags.sql` (claims, holds, settlement, fallback, no downgrade, expiry, projection with a new
`state_seq`, unchanged untagged entries, personal tags, replay/conflict, removal), `tests/backend/tags.test.ts`
(vocabulary parity, request, parsing, pricing, failure billing, the run loop), Core `PaperTagsTests`, app
`LibraryModelTests.testTagEditsShowAtOnceAndSyncAsOwnAndHiddenLists`, visual scenarios `paper-top`,
`paper-tags-edit`, `paper-tags-suggest`. Screens without UI automation: launch the reader fixture with
`--offline-reader-fixture --reset-offline-reader-fixture --mathpix-reader-fixture --visual-open-paper` (add
`--visual-edit-tags` for the sheet); 2026-10-07 captures in `.artifacts/visual/tags/` (iPhone and iPad, light and dark).

## Known limits

- The model still sometimes tags what a paper compares against (DDPM → "Generative adversarial networks") or an
  adjacent field (Whisper → "Large language models"). Readers can remove a tag; a later vocabulary version can
  re-tag.
- Pending imports show no tags until they become library items.
- Web (OpenAlex) papers often have no abstract and no arXiv categories: tags come from the title alone, or none.
