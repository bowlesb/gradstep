# Shared paper podcasts: implementation contract proposal

2026-10-08. **Design for independent schema/cost/identity review. Not implemented or deployed.**
The owner asked for browsable reusable episodes, not just an on-demand button. This proposal builds on
the exact source/reuse rules and deployed financial safeguards; it does not delay the library-write
bug release. [Economics and three owner decisions](../research/PRICING_RECOMMENDATION_20261008.md).
Migration labels A/B/C below are ordering labels, not assigned migration numbers.

## Product boundary

V1: one already-converted paper, English, a five-minute target, two fixed synthetic voices, a concise
source-linked transcript, chapters, playback speed, background audio and offline playback. The hosts are
an explainer and a skeptical reader: result, method, assumptions, evidence, limitations and why it matters.
No invented personal anecdotes, claims of author endorsement, voice imitation or added web facts.

Add a **Listen filter within the existing Feed** for ready shared releases, and a Listen action on eligible
paper details. Do not replace Library/Feed navigation. An episode card shows paper title, year, duration,
topic and an AI-audio badge; language/source revision and credits live in its details. Tapping Play never
adds a paper or buys a generation. Empty results offer ordinary paper discovery or an explicitly quoted
private generation. Existing paper-to-chat navigation remains; transcript evidence opens the pinned paper
passage, or shows the source link and explicit Add action when it is not in the library.

The playback sheet has play/pause, ±15 seconds, speed, chapters, transcript and download. A compact player
stays above the existing navigation; it cannot cover the chat composer or selection menu. Dismiss the sheet
without stopping playback; Stop is explicit. Keep reading position and chat draft intact across transitions.
Keyboard, VoiceOver, large text, reduced motion and interruptions are part of the journey, not optional polish.

Start with **zero generation spend**: an empty catalog plus explicitly labeled local synthetic fixtures can
exercise browsing/playback/offline behavior. The operator can import an existing, rights-approved real pilot
audio/transcript with all the same provenance, verification, inventory and publication checks. An imported
record states external origin and unknown external generation cost; it must not claim a zero-cost provider
attempt or reviewed factuality merely because a file exists. Generating a new pilot elsewhere still costs
money and is not a way around authorization. Once a bounded paid run is accepted, propose $2 total for two
curated episodes and explicit QA inside the existing $25 provider cap; no new subscription or recurring seed
budget. Admit from current headroom again at execution, not the historical $11.32 observation.

## Funding and fairness

| Action | Funding and privacy rule |
|---|---|
| Browse/play an eligible ready shared release | No generation credits; authenticated bounded delivery and rate limits |
| Suggest a public paper for the catalog | Deduplicated, capped wish signal; no job or reservation; no requester identities in the catalog |
| Curated canonical episode | Operator approves it from a separate seed sub-budget inside platform budget; customer credits zero |
| Private episode for one's own accessible paper | Explicit quote and consent; one funding operation for that account; no public reuse |
| Concurrent identical private requests on two devices | Join the same job within that owner scope; no duplicate generation charge |
| Same private bytes uploaded by two accounts | Separate authorization and work keys; no cross-account existence oracle or dedup |
| Custom language, length or voice | New profile/variant and quote after v1; not a free mutation of cached audio |
| Customer sponsors a public canonical episode | Defer. Needs explicit “you fund it, everyone can listen”, refund and attribution policy |

Do not bill the first accidental listener, transfer funding to another waiter after cancellation, promise
future royalties, or issue credit rebates based on predicted reuse. Platform seeds and private generation
are sufficient for v1. If sponsorship is added, recheck ready/shared work before reserving; losing concurrent
sponsors release their holds. “Saved generation cost” is a counterfactual estimate, not revenue or money refunded.

Platform seed operations can use the **real authorizing operator's existing financial account** with zero
customer credits, `funding_kind=platform_seed`, an audited actor/reason, and a seed allocation row. Do not
invent an Auth user, credit bucket or alternate ledger. Closing the operator account stops its unsubmitted
work; an already-published eligible shared release is platform catalog content, not personal account data.

## Exact identities and rights

There are three different immutable identities; one hash cannot safely stand in for all three:

1. **Episode work key**, known before generation: a canonical, domain-separated digest of ordered source
   pins, scope (`shared` or exact private owner), editorial profile/version, language, target length and
   requested provider/voice profile. V1 accepts exactly one source; the source child relation permits a
   future bounded ordered set without changing identities. Do not dedup by DOI, title or bare arXiv ID.
2. **Approved script identity**: exact normalized transcript/evidence/notation/pronunciation document hash,
   plus checker version and editorial decision. Store the draft lineage separately. A probabilistic rerun
   with the same prompt need not reproduce the same script.
3. **Immutable release identity**: script hash, exact audio provider/model revision, voices, pronunciation
   profile, encoder version/settings, measured duration, member hashes and manifest hash. Codec-only
   derivatives reuse a script but have distinct bytes. A correction creates a new release, never overwrites.

A source pin contains `catalog_asset_approvals.id`, catalog version/metadata IDs, `documents.id` and SHA-256,
original object/hash, OCR run/options/raw-manifest hash, render artifact/manifest hash, and the selected text
normalization version. Resolve and verify these relationships server-side; no caller-supplied combination
of individually valid IDs is enough. Evidence locators bind the pinned normalized text and rendered anchor,
with bounded offsets/quote digest and page/section/equation identifiers. A new paper revision gets a new pin.

**Shared eligibility is deliberately narrow:** current verified CC BY 4.0 or CC0 approval plus an active
podcast publication approval, both pinned to the exact source bytes. A public PDF URL, arXiv default license,
private upload or an owner's unchecked assertion is not permission for cross-user audio redistribution.
Maintain full source attribution, license link, changes/AI adaptation disclosure, paper revision and authors;
separately check third-party material/exclusions. Do not imply author participation. CC BY permits commercial
adaptation with conditions and valid grants are generally irrevocable; a product takedown is not a claim to
retroactively revoke that license or erase lawful exported copies.
[CC BY 4.0 terms](https://creativecommons.org/licenses/by/4.0/),
[CC0](https://creativecommons.org/publicdomain/zero/1.0/).

Existing asset approvals are immutable evidence, not the current takedown switch. Add revocable publication
state with `rights_revision`; check current source availability, owner scope and this revision at admission,
every next provider grant, publication and delivery. Shared release queries return public metadata only.
Private work keys, scripts, source titles, funders, wish signals and listening history never enter public indexes.

## Proposed additive schema

All operational tables live in `app_private`, with RLS enabled and no direct authenticated grants. Expose
bounded security-definer RPCs with empty `search_path`, an open actor account and explicit role checks;
operator mutation additionally requires existing MFA/admin authorization. Immutable identities/events need
database enforcement, not conventions in the worker. Use integer micro-USD, milliseconds, bytes and tokens.

| Proposed relation | Important fields, keys and invariants |
|---|---|
| `podcast_policy` | Disabled by default; profile allowlist, seed/quality allocation, row/byte/job/transfer limits, storage inventory scope, kill switches; audited changes |
| `podcast_profiles` | Immutable `id, version, spec_sha256`, bounded typed editorial/voice/model/rate/codec settings; active pointer separate from immutable spec |
| `podcast_episode_keys` | `id, scope, owner_id?, work_sha256, profile_id/version`; shared owner null/private owner required; two unique partial indexes prevent null-scope duplicates |
| `podcast_sources` | `(episode_id, ordinal)` PK; exact source/approval/document/artifact pins above; exactly one row in v1; immutable after admission |
| `podcast_publication_approvals` | Episode/source pins, approval evidence digest, reviewer, `rights_revision`, active/quarantined/withdrawn; append-only decision events; no private-to-shared update |
| `podcast_quotes` | Actor, client request UUID/digest, episode key, dataset epoch, consent/profile/rate versions, max credits/USD/calls/bytes, expiry; immutable; short bounded retention; no raw prompts |
| `podcast_requests` | `(account_id, request_id)` PK, exact quote/digest, `intent_revision`, desired-present, job reference; same ID/different digest fails; removal/replay fence |
| `podcast_jobs` | Episode, generation number, state/stage, claim UUID/generation/deadline, attempts policy, funding kind, `(operation_account_id, operation_id)` FK, rights revision, timestamps; one active job per episode key |
| `podcast_scripts` | Immutable ID/job/source/spec digest, transcript/evidence object references and checksums, review result/schema version; bounded 4 MiB total documents; metadata has no private transcript |
| `podcast_releases` | Immutable episode/script/model/voice/codec/duration/manifest identity; lifecycle projection ready/superseded/quarantined/withdrawn; optional replacement release FK; publication sequence |
| `podcast_release_objects` | `(release_id, role, ordinal)` unique; exact `stored_objects` FK/hash/size/MIME; required manifest/transcript/evidence/audio set before ready |
| `podcast_job_events` | Append-only bounded stage, claim, attempt and finite failure-code records; provider IDs are in existing attempts; no plaintext source/audio transcript/error blobs |
| `podcast_asset_holds/uploads/writes` | Job-fenced equivalent of035's paper adapters; shared physical capacity counters, immutable exact object plans, one transport grant, ambiguous writes retain capacity |
| `podcast_delivery_grants/redemptions` | Account/release/rights revision/object IDs, token hash, expiry, reserved bytes, one redemption per object; shared transfer capacity, not independent unlimited counters |
| `podcast_seed_periods` | Dated limit/spent/reserved cents or micro-USD, linked to platform budget period; seeded zero/disabled until approved; no unverified automatic rollover |

Before SQL, prefer reusing a demonstrated generic shared capacity/delivery primitive over copying035 bodies.
The paper-specific035 adapters cannot simply be pointed at an audio bucket: their source membership,
inventory, manifest schema, cleanup and transfer checks assume papers. A reviewed extraction must preserve
their old contracts and grants. Cross-table source/owner checks need composite foreign keys where possible,
with transactionally enforced residual predicates and adversarial tests. Count quotes/events/attempts and
private object inventory against capacity; do not build an unlimited ancillary table behind a bounded audio table.

No new cleartext server table for listening positions/bookmarks. Use a **separately versioned encrypted
podcast stream** with the existing account/device key custody, account-bound opaque entity IDs and payloads
containing release, position, play session/sequence, completed state and saved status. Independent review
confirmed that current Swift `PrivateEvent.Kind` is a closed Codable enum and web `decodeEvent` rejects
unknown kinds: adding podcast events to the existing stream would stall older clients' chat/history replay.
Keep that stream and its cursor unchanged. Before SQL, specify a domain-separated authenticated envelope,
independent cursor, bounded event retention/compaction, key-rotation/recovery behavior and old-client tests.
Sharing key custody does not mean reusing an encryption nonce or its associated-data domain.

### Exact integration points and migration order

**A — identity, finance and disabled APIs.** Extend003's `metered_operations.kind` and all reserve/settle
whitelists with `podcast`; keep the existing credit ledger/bucket allocation. Extend034's
`provider_attempts` provider/route constraints and `valid_provider_units` with reviewed Google speech routes
and numeric `text_input_tokens`, `audio_output_tokens`, `audio_ms` (only observed values, not inferred final
usage). Add `podcast_script`, `podcast_review`, `podcast_speech` routes and optional QA only when selected.
Do not use `metadata` or `chat` as a disguise. The actual pricing snapshot records rate and model version.
Wire `_shared/provider-spending.ts` through a dedicated podcast adapter; it currently only types chat/search
routes and assumes Anthropic token accounting. No arbitrary model/provider string selects a cheaper quote.

**B — storage and delivery.** Add a **private** `podcast-assets` Storage bucket and explicit object-family
constraints in `stored_objects` (001, extended039). Shared objects use document identity with no owner;
private objects use owner identity, with ownership bound through their release/source. Update capacity,
`worker_delete_account_begin/finish`, cleanup and `worker_asset_inventory_*` to a new inventory scope that
includes audio and temporary objects. Do not declare existing scope2 certification sufficient. All Storage
policies reject client writes and public reads; only admitted worker uploads and authenticated bounded
delivery operate. Extend037's spend/storage admin views and `scripts/workflow-checks.mjs`.

**C — worker and clients, then activation.** A separate bounded audio execution entry point in the existing
Cloud Run worker architecture handles script verification/audio validation/transcoding; IAM-only ingress,
minimum instances zero, request billing, awaited subprocess, hard deadline and concurrency. The paper queue
must not starve while audio is generated. Short Edge ingress handles quote/start/status/list/delivery; the
database transaction enqueues through an outbox/queue atomically with reservation. Poll durable status;
Realtime is a hint to refetch, not evidence that publication or credit settlement happened. Update native
`ReaderModel`/Feed/reader actions, Core encrypted state/cache/player contracts and web equivalents together.

Proposed API shapes: `v1_podcast_capabilities`, `v1_podcast_catalog(after, filters, limit<=50)`,
`v1_podcast_quote(source_item, epoch, profile, request_id)`, `v1_podcast_start(quote_id, request_id, digest)`,
`v1_podcast_status(request_id)`, `v1_podcast_cancel(request_id, expected_revision)`,
`v1_podcast_release(release_id)` and bounded `podcast-member`. Clients must treat absent/disabled capability
as unavailable and continue reading; no fallback to unguarded generation. Native v5 library writes use
042's epoch-checked commands when the user explicitly adds/removes a source. Audio does not become a
special pseudo-paper or alter the existing library synchronization table layout.

Assign actual migration numbers only after merging current branches. Back up and restore-test, review
grants/locks/limits, deploy dark with zero paid allowance, certify all buckets, then run mock journeys. Each
activation is explicit. Rollback disables admission and catalog publication while allowing settlement,
deletion and safe reads of already-verified downloads; applied migrations remain immutable.

**Restore quarantine is an implementation gate.** `scripts/restore-local.py` explicitly enumerates policies;
it will not disable a new `podcast_policy` automatically. Extend restore quarantine and its tests to disable
podcast admission, worker grants, uploads, publication and delivery, rotate execution/dataset epochs, and
retain outstanding provider and object liabilities. Every quote/start/claim/provider-grant/write-grant/
publication/delivery mutation must transactionally check the current epoch, not merely copy an epoch into
the quote. A restored backup may predate an already-consumed grant; neither the restored row nor its absence
can authorize another paid call or upload. Reconcile post-checkpoint provider attempts and physical objects
before re-enabling the affected work. Require real-session restore/claim/cancellation races and stale-worker
tests, including an upload authorized before quarantine that completes afterward.

## Financial and job lifecycle

`quoted -> queued -> scripting -> checking -> synthesizing -> verifying -> publishing -> ready`.
Explicit terminal or holding states: canceled, failed, needs_credits, capacity_wait, unknown_provider,
quarantined. Store stage-entered time and next permitted non-paid retry; no generic “99%” for waits.

Start rechecks actor/account, dataset epoch, source membership/rights, consent, profile, exact ready/active
work, row/storage capacity, customer balance, seed/quality sub-budget and platform headroom in one admitted
transaction. A ready matching private release returns reuse with zero generation reservation. A matching
active same-owner job joins it. The quote never authorizes arbitrary later edits to its source or options.

Lock order must compose with existing financial paths: budget period(s), accounts in UUID order, financial
policy/operation locks, podcast work/job rows, then shared storage/transfer capacity in its documented order.
Never hold a job/source row and then call a helper that acquires an account/budget row. Cancellation,
deletion, publish, refund and maintenance use the same captured identities; late identity discovery aborts
for retry. Public-ready lookup is read-only and must not turn into a lock inversion when reserving a miss.
True concurrent-session tests, including account deletion/purchase refund, are required before this order
is accepted as implemented.

Each script, review, speech or permitted repair POST consumes its own **one-shot durable attempt grant**
under the existing034 protocol. Disable SDK retries and hidden server fallback; record all usage and
returned model identities. New rounds may use only the unspent parent envelope. An unknown outcome retains
its full provider ceiling and pauses paid continuation; a lease expiry does not mean the vendor did no work.
Finishing the same attempt is replay-safe; retrying a finish never sends speech again. Recovery with no
provider query API may require audited vendor evidence/manual reconciliation, and never automatically costs
another generation. Stale workers cannot obtain a new upload grant or publish after a new claim, restored
epoch or canceled request. An already-issued Storage PUT cannot be retracted by changing a database row;
retain its planned bytes and uncertain liability until terminal-writer evidence permits reconciliation or
reclamation. Lease expiry and cancellation alone never prove the object cannot still arrive.

Before submission, cancel releases the customer's unused hold and detaches interest. During a provider
call, mark cancel requested, stop future calls, collect/settle confirmed usage where possible; no promised
instant provider cancellation. A normal canceled private job charges known incurred usage within its
disclosed maximum. A rejected/unsafe quality result charges the customer zero under the proposed policy;
record that loss separately against a bounded platform quality allocation. Ambiguous usage can release a
customer hold under an explicit service policy without erasing provider liability; do not use a timeout to
claim zero provider expense. Public seed cancellation is an operator action independent of listener interest.

V1 has no automatic paid retry. An explicit new generation uses a new quote/operation and `retry_of`; prior
unknown liabilities still count globally and any overlapping unknown work blocks a fresh submission.
Metadata/status/transcode/publication retries are bounded, idempotent and resume verified inputs only.
Financial results are immutable even if the user later deletes the episode; retain existing de-identified
financial records, not transcript contents. Refunds never manufacture provider refunds or reuse savings.

Initial numerical envelope proposal: one active private job/account, two active jobs/environment, one paid
speech transport at a time, 20 new jobs/day/environment, at most 64 provider attempts/operation under the
existing policy and the profile's much smaller count. Five-minute v1 permits **two script calls + one speech
call, no repair**; provider reserve up to $0.75/150 credits as derived in the economics model. Use the full
documented speech serving cap until smaller bounds are proved; reject an oversized source, do not summarize
only its beginning invisibly. Limits are ceilings, not a plan entitlement or permission to spend $15/day.

## Scientific transcript and audio quality

The script schema includes stable segment/claim IDs, speaker, spoken text, evidence locators, claim type
(`paper_result`, `author_interpretation`, `explainer_analogy`), limitations, original math and a separate
spoken expansion. Every material quantitative/comparative/scientific claim must have evidence; no valid
locator means remove the claim or fail review. Treat PDFs/metadata as untrusted source data, never provider
instructions. No browsing or model-driven tools in the script route. Model review is evidence to inspect,
not proof of correctness.

Retain exact LaTeX/MathML from the paper for display; do not replace it with TTS phonetics. A notation map
ties spoken “theta at step t plus one” to the original equation/anchor. Explain a formula's role and
assumptions in audio rather than reading every symbol. Check signs, inequalities, exponents, denominators,
dimensions, units, table numbers and baselines against the evidence map. If a graph cannot be understood
from verified text/caption, say what is supported or omit the interpretation; no invented trend.

The speech adapter uses structured speaker/style metadata, fixed licensed synthetic voices, and no user
voice uploads. Gemini's current generation schema separates that metadata from verbatim speech; do not
send older inline “Speaker 1:” instructions that may be read aloud. Validate MIME/container, sample rate,
channels, decoded duration, size, non-silent audio and complete ending; pin encoder/normalization settings.
The provider's model limit is a billing bound, not evidence of a natural ending or scientific fidelity.
[Google model/schema guidance](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts).

Evaluation set before public activation: equation-heavy derivation, survey, figure/table-heavy empirical
paper, negative/limited result, long notation-heavy methods paper and adversarial PDF instructions. A reader
familiar with each paper scores factual support, correct comparisons/numbers, limitations, equation
pronunciation and usefulness. Gate: zero material unsupported/incorrect claims in the reviewed release,
every evidence link correct, no cut-off speech, and acceptable listening quality on headphones and phone
speakers. This is per-release review, not a universal guarantee. Curated episodes require an operator's
review record; private v1 generation remains beta and visibly labeled with easy report/specific-time action.

Track draft/review/audio acceptance separately, reviewer disagreements, cost per **accepted** minute,
first-playable time, audio duration, failure/repair/unknown rates and transcript/source revision. Optional
transcription can detect missing/changed words and numbers but can itself mishear equations; it is a
separately admitted QA expense, not an infallible judge. Compare OpenAI using the same approved script only
after its hard output-cost bound is established; no silent fallback or indefinite blind model retries.

## Storage, bounded delivery and offline sync

Proposed per-active-job capacity: 64 MiB temporary source audio, 16 MiB encoded audio and 4 MiB
transcript/evidence/manifest, with bounded object counts. These reservations count within global capacity;
they are not new independent storage allowances. Register exact hashes/lengths/MIMEs before writes, retain
uncertain writes/temporary objects until confirmed cleanup, and only publish a fully verified manifest.
An expired claim never frees capacity by assumption. Prefer transient encrypted scratch; any durable raw
audio is inventoried and deleted after verified encoding/publication according to an explicit TTL.

V1 deliberately uses a **small complete verified audio file**: Play obtains a single-use, short-lived,
account/release/object-bound grant, downloads into encrypted/protected local storage, verifies hash/length,
then uses AVPlayer or the browser audio element. Target size is about 2.4 MB for five minutes; show progress
and cancel on slow networks. No silent prefetch of whole catalog cards, Range requests or public reusable
Storage URLs. The manifest/transcript also consume delivery authorization. A failed transfer consumes its
authorized-byte allowance conservatively; a retry needs new admission. Keep local replay free of new transfer.

This choice costs initial download latency; measure it explicitly. Progressive/range playback can be a
subsequent reviewed transport: immutable bounded segments or bounded range grants must charge every
upstream read and repeated range request before fetching, support player seeks/retries, and cap the session's
total bytes. A token expiry alone is not a replay/egress limit. Do not quietly add public HLS playlists while
claiming035's one-shot delivery still covers it.

Suggested initial separate audio transfer ceilings, all also charged to shared environment capacity:
free account 100 MiB/month, paid account 512 MiB/month, environment 2 GiB/month. Expose remaining download
capacity where it affects the action; ordinary local playback continues when transfer stops. Confirm these
ceilings fit current global caps and measured demand before activation; they are not a reason to grow the
global cap or count the same transfer as free cached egress. Retained private audio counts toward the existing
1 GiB/account; shared catalog/audio within the common inventory cap. At exhaustion, new generation/delivery
pauses plainly rather than evicting a user's library automatically.

Offline cache owns verified files, manifests, transcript and release status/version. “Downloaded” is true
only after durable commit and every required hash check. Account switch/sign-out separates or clears
decrypted handles; private audio inherits protected/encrypted local storage, never unprotected browser
CacheStorage with a global key. Handle browser persistence eviction honestly. Download/remove is device-local;
saved episodes, playback position, completion and settings sync encrypted across surfaces.

Playback state uses an explicit play-session/sequence with a deterministic concurrent-merge rule, not
`max(position)`: seeking backwards and replaying are intentional. A remote sync update never moves the
currently playing device; it offers resume on the next open. Persist at pause/background/chapter changes
and at a bounded interval, not every second; interrupted offline devices must not reset a newer session.
Client tests must cover backwards seeks, two devices offline, duplicates, session ordering, account change
and deleted saved entries. The server inevitably sees authenticated content delivery/generation metadata;
do not claim that E2EE positions hide all listening activity.

## Privacy, corrections and deletion

Shared releases contain approved public source-derived material only. Proposed private releases contain
paper-derived audio/transcripts in access-controlled server storage, with platform-managed at-rest encryption,
**not E2EE**. This is a product/privacy decision requiring acceptance; personal chats, annotations and
custom private instructions stay excluded. An E2EE background personalized podcast would require a separate
bounded job-envelope, recipient-key and recovery design rather than durable plaintext prompts in a queue.
Provider retention and consent must name each activated provider; do not use a free provider tier that
trains on inputs as an assumed cost saving for private PDFs.

Quarantine removes catalog/search visibility and new grants immediately, without rewriting financial
history. Corrected releases link both ways and keep their exact old provenance. Source retraction is
distinct from a confirmed factual audio error or rights dispute, and the UI says which. Fetch a bounded
revocation/correction status list on reconnect and before a new download; remove blocked cached playback
when learned, and surface a replacement for correctable releases. Offline devices cannot learn a new
takedown immediately, and exported lawful copies cannot be remotely erased. Do not promise that they can.

Removing a saved public episode deletes only private membership/progress according to the user's choice;
it never deletes shared catalog content for others. Deleting a private release revokes access, cancels
future work, tombstones its intent against late workers, and schedules every staged/final object for
confirmed deletion. Account deletion includes quotes, requests, private scripts/audio, saved encrypted
events, temporary uploads and cached-auth revocation; legal financial records stay de-identified under
existing policy. Public seed releases survive operator-account deletion only if their rights/quality
approval is independent and active. A private-to-public “share” action is not in v1.

## Acceptance and operator visibility

Read-only admin views add provider costs/reservations/unknowns by route and release, customer charged versus
refunded credits, platform seed/quality spend, admitted/accepted minutes, attempt lineage, serving model/rate,
asset inventory/deletion discrepancies and authorized/observed transfer bytes. Aggregate reuse distinguishes
unique accounts, new downloads and local replays; listening positions need not be decrypted for analytics.
New routes appear in037 dashboards and alert/check thresholds before they are enabled. Cost telemetry uses
IDs and numeric units; reports only include a transcript/excerpt with the user's explicit attachment.

Required independent review/testing before real generation:

- Schema/RLS: wrong owner/source/artifact combinations, private-work existence oracle, shared rights changes,
  older clients, denied/granted capability negotiation and dataset-epoch changes.
- Money: concurrent quote/start, two-device duplicates, last-moment ready reuse, canceled first funder,
  account deletion/refund races, missing grant acknowledgement, paid response without usage, price/model
  drift, exhausted sub-budget/global budget, and actual cost above a bound freezing new work.
- Worker: lease theft after admission, crash after provider acceptance, crash after upload before publish,
  late callback after cancellation/deletion, publication replay, no hidden SDK/fallback retry, partial files,
  malformed audio and no paid automatic re-execution during restore/reconciliation.
- Delivery/storage: one-shot replay, malformed/full/Range requests, concurrent redeems, aborted transfer,
  quota races, orphaned temporary audio, wrong object hashes, incomplete inventory and deletion failure.
- Human workflow: browse/play/return to paper/chat, evidence jump, offline download, background interruption,
  seek/speed, account switch, slow-network cancellation, correction banner and two-device resume on native
  and browser. Verify sound and source fidelity, not merely that a player has a Play button.

Sequence: schema and identity/cost review; zero-spend fixtures/import path; local and staged mock journeys;
owner-approved bounded provider/quality pilot; two reviewed seed releases; then private beta with visible
quote, status and diagnostics. No public promises of podcast parity, unlimited generation, or unmeasured
factual reliability. Expand length/language/voices and sponsorship only after the measured v1 contract holds.

## V1 implementation contract (2026-10-08, branch `podcast-v1`)

Owner request 2026-10-08: "build the notebook LM podcasts feature please". Read as accepting Decision 2
(platform seeds, at most $2 for the first two five-minute curated episodes, each admitted at up to $0.75, inside
the existing $25 provider cap) and Decision 3 (the bounded private-generation contract); Decision 1 (public offers)
is out of scope. See [DECISIONS.md](../DECISIONS.md#paper-podcasts-v1-owner-asked-2026-10-08). Everything below ships
**dark**: migration 046 creates every switch disabled, and no paid provider call was made while building it.

### Client API (Edge `podcast`, bounded `podcast-member`)

All requests carry the customer's `Authorization: Bearer` token; responses are `application/json`, `no-store`, and
errors are `{ "code": "<finite_code>" }`. Absent or disabled capability means "unavailable": clients keep reading
and never fall back to unguarded generation. Times are ISO 8601; durations are integer milliseconds.

| Call | Request | Response |
|---|---|---|
| `GET ?action=catalog&after=&limit=` (≤ 50) | — | `{ episodes: [Episode], next: string\|null, capabilities: Capabilities }` |
| `GET ?action=episode&release_id=` | — | `{ episode: Episode & { chapters: [Chapter], transcript: Transcript } }` |
| `GET ?action=paper&item_id=` | — | `{ episode: Episode\|null, job: Job\|null, capabilities }` (shared or own private release for that library item) |
| `POST ?action=quote` | `{ item_id, request_id }` | `{ quote: Quote }` or `{ reuse: { release_id } }` or `{ join: { request_id } }` |
| `POST ?action=start` | `{ quote_id, request_id, consent_version }` | `{ job: Job }`, or `{ reuse: { release_id } }` if an identical private release became ready |
| `GET ?action=status&request_id=` | — | `{ job: Job }` (or `{ reuse: { release_id } }` for a request that reused a release) |
| `POST ?action=cancel` | `{ request_id }` | `{ job: Job }` |
| `POST ?action=download` | `{ release_id }` | `{ grant: { expires_at, members: [Member] } }` |
| `POST ?action=states` | `{ release_ids: [uuid] }` (≤ 100) | `{ states: { [release_id]: { state, replacement_id } } }` |
| `GET podcast-member?grant=&member=` | bearer token | the member's exact bytes; single use; `Range` refused |

- **Episode** `{ release_id, scope: "shared"|"private", title, year, authors: [string], topic: string|null,
  duration_ms, language: "en", ai_audio: true, fixture: bool, document_id, published_at, state,
  source: { arxiv_id|null, version|null, url|null, license|null }, audio: { bytes, sha256, media_type } }`.
  `fixture: true` marks labeled synthetic fixture audio; clients show "Synthetic fixture" next to the AI-audio badge.
- **Chapter** `{ id, title, start_ms }`. **Transcript** `{ speakers: { explainer: string, skeptic: string },
  disclosure: string, timing: "approximate", segments: [{ id, speaker: "explainer"|"skeptic", text, start_ms,
  end_ms, chapter, claim_type: "paper_result"|"author_interpretation"|"explainer_analogy"|"context",
  evidence: [{ id, quote, section|null }], math: [{ latex, spoken }] }] }`. Evidence `quote` is verbatim text from the
  pinned converted paper; clients open the paper at that quote (the passage-anchor finder), or show the source
  link and an explicit Add action when the paper is not in the library.
- **Quote** `{ id, expires_at, max_credits: 150, estimate: "Estimate — you're charged actual usage, maximum 150 credits",
  providers: ["Anthropic (script)", "Google Vertex AI (speech)"], consent_version: "podcast-private-v1", target_seconds: 300 }`.
- **Job** `{ request_id, state, stage_entered_at, release_id|null, held_credits, charged_credits|null,
  released_credits|null, failure|null, cancel_requested: bool }`; state is one of `queued, scripting, checking, synthesizing, verifying,
  publishing, ready, canceled, failed, capacity_wait, unknown_provider, quarantined`. Poll status; never infer
  completion or charges from elapsed time.
- **Member** `{ role: "audio", url, bytes, sha256, media_type }`. The client downloads into protected local storage,
  verifies length and SHA-256, and only then marks the episode downloaded. A failed download needs a new grant.
- **Capabilities** `{ catalog: bool, generation: bool, delivery: bool, max_credits: 150, target_seconds: 300,
  transfer: { remaining_bytes, limit_bytes } }`.

Listening position and history are **device-local in v1** (see "Listening history" below): no podcast events enter
the encrypted history stream, so older clients' chat/history replay is unaffected.

### Client API reference (for any client, including the Codex web player)

**Transport.** Base URL `${SUPABASE_URL}/functions/v1/podcast?action=<name>` (staging `https://coxhjvqpflgxkleydati.supabase.co`).
Every call sends `Authorization: Bearer <the signed-in user's access token>` and `apikey: <anon key>` (the Supabase
gateway), `Content-Type: application/json` on POST. Browser origins must be in the Edge `ADMIN_ORIGINS` list (staging:
`https://app.gradstep.ai`, `http://127.0.0.1:5173`, `http://localhost:5173`); methods `GET, POST, OPTIONS`. POST bodies
are JSON objects ≤ 8 KiB. Every response is `Cache-Control: no-store`. The same functions are callable as PostgREST
RPCs (`v1_podcast_catalog`, `v1_podcast_paper`, `v1_podcast_quote`, `v1_podcast_start`, `v1_podcast_status`,
`v1_podcast_cancel`, `v1_podcast_states`, `v1_podcast_capabilities`), but `episode` and `download` exist only in
the Edge function because they read Storage with the service role after verifying the caller.

**Rate and transfer limits.** `podcast-read` (catalog, paper, episode, status, states, capabilities): 600/account/hour,
6,000/environment/hour. `podcast-generate` (quote, start, cancel): 20/account/hour. `podcast-download`: 60/account/hour.
Audio transfer: 100 MiB/account/month (512 MiB with an active subscription), 2 GiB/environment, also counted against
the reader's shared environment transfer. `episode` charges the transcript bytes before reading Storage; `download`
reserves the audio bytes; redemption converts the reservation into authorized bytes. `capabilities.transfer` reports
the caller's remaining bytes. Exhaustion is `podcast_transfer_limit` (429); already downloaded audio keeps playing.

**Errors.** `{ "code": … }` with these statuses; any other database text becomes `service_unavailable` (503).

| Code | HTTP | Meaning / client behaviour |
|---|---|---|
| `authentication_required` | 401 | Sign in again |
| `account_unavailable`, `spending_suspended` | 403 | Account closed or paid work suspended |
| `request_rate_limit`, `podcast_transfer_limit` | 429 | Wait; say which limit |
| `podcast_unavailable`, `podcast_paused` | 503 | Feature (or private generation after quality losses) switched off: hide/disable, keep reading |
| `podcast_release_unavailable`, `podcast_request_unavailable` | 404 | Not visible to this account (no existence oracle) |
| `source_unavailable` / `source_too_large` | 404 / 413 | Paper not converted (or its text over the profile bound): no generation offered |
| `quote_unavailable` / `quote_expired` | 404 / 410 | Ask for a new quote (expires after 15 minutes or when the source changes) |
| `consent_required` | 400 | `consent_version` must be exactly `podcast-private-v1` |
| `insufficient_credits` | 402 | Show the credit store; nothing was held |
| `active_generation_limit`, `podcast_busy`, `podcast_daily_limit`, `too_many_active_operations` | 429 | One private job per account, two in the environment, twenty per day |
| `storage_full` | 507 | Store full; nothing was held |
| `platform_budget_exhausted` | 503 | Platform paused paid work |
| `podcast_request_conflict` | 409 | Same `request_id` reused for a different quote/item |
| `podcast_grant_unavailable` / `podcast_grant_consumed` | 403 / 409 | Grant expired, revoked or already used: request a new `download` |
| `podcast_range_unavailable` | 416 | `Range` headers are refused |
| `podcast_integrity_failed` | 503 | Server-side digest mismatch; do not cache anything |
| `invalid_podcast_request`, `invalid_podcast_cursor`, `invalid_podcast_grant`, `invalid_id` | 400 | Client bug |

**Catalog** `GET ?action=catalog&limit=20[&after=<next>]` → ready shared episodes, newest publication first; `next`
is an opaque decimal string (pass it back unchanged) or `null`. A disabled catalog returns `episodes: []` with
`capabilities.catalog=false`. Private episodes never appear here.

```json
{ "episodes": [{ "release_id": "6c1e…", "scope": "shared", "state": "ready", "fixture": false, "ai_audio": true,
    "language": "en", "title": "Sparse Mixture Routing", "year": 2024, "authors": ["Ada Example"], "topic": "Mixture of experts",
    "duration_ms": 301000, "published_at": "2026-10-09T18:02:11Z", "document_id": "0f2a…",
    "source": { "arxiv_id": "2410.04601", "version": 1, "url": "https://arxiv.org/abs/2410.04601v1",
      "license": "https://creativecommons.org/licenses/by/4.0/" },
    "audio": { "bytes": 2412044, "sha256": "9b1f…", "media_type": "audio/mp4" }, "replacement_id": null }],
  "next": null,
  "capabilities": { "catalog": true, "delivery": true, "generation": false, "max_credits": 150, "target_seconds": 300,
    "transfer": { "limit_bytes": 104857600, "remaining_bytes": 101245000 } } }
```

`title`, `year`, `authors`, `topic` and `source` are always present for shared episodes; for **private** episodes they
are `null`/empty because private titles are not server-visible — use the library item's own title.

**Episode** `GET ?action=episode&release_id=…` returns the Episode plus `chapters` and `transcript`. Use it as the
pre-download state check: play only if `state` is `ready` and `audio.sha256`/`audio.bytes` equal what you will verify.

```json
{ "episode": { "release_id": "6c1e…", "…": "Episode fields as above",
  "chapters": [{ "id": "c1", "title": "The question", "start_ms": 0 }, { "id": "c2", "title": "The method", "start_ms": 61240 }],
  "transcript": { "speakers": { "explainer": "Host 1 · explainer", "skeptic": "Host 2 · skeptical reader" },
    "disclosure": "AI-generated audio made from the paper’s converted text by Gradstep. …", "timing": "approximate",
    "segments": [{ "id": "s4", "speaker": "explainer", "chapter": "c2", "start_ms": 61240, "end_ms": 74980,
      "text": "Each token goes to the top 2 of 64 experts, chosen by a learned gate.", "claim_type": "paper_result",
      "evidence": [{ "id": "e2", "quote": "Each token is routed to the top 2 of 64 experts by a learned gate", "section": "3 Method" }],
      "math": [{ "latex": "g(x)=\\operatorname{softmax}(W x)", "spoken": "a softmax gate" }] }] } } }
```

Chapters are ordered by `start_ms` (the first is 0); every segment names one chapter; segments are ordered and
`end_ms ≥ start_ms`. Timing is **approximate** (one multi-speaker take, boundaries snapped to pauses): use it to seek
and highlight, not as word alignment. `evidence[].quote` is whitespace-normalized verbatim text of the pinned
converted paper (`document_id`): find it with the passage finder (exact, then collapsed whitespace). Segments with
`claim_type` `context` or `explainer_analogy` may have no evidence. Unknown future `claim_type` values should render
as `context`. `math[].latex` is display-only; never feed it to speech.

**Paper detail** `GET ?action=paper&item_id=<library item id>` → `{ episode, job, capabilities }`: the account's own
ready private release for that paper, otherwise the newest ready shared release of the exact same document bytes,
and the account's unfinished private job (with its `request_id`) if any.

**Private generation.** (1) `POST quote {item_id, request_id}` with a fresh UUID → `quote` (show `estimate`,
`max_credits`, `providers` and ask for consent), or `reuse.release_id` (an identical private episode exists: play it,
nothing is charged) or `join.request_id` (this account is already generating it on another device: poll that request).
(2) `POST start {quote_id, request_id, consent_version: "podcast-private-v1"}` — use the **same** `request_id`; a
lost reply is safe to resend (same response, no second hold). Returns `job` with `held_credits: 150`.
(3) Poll `GET status&request_id=` every 5 s for the first minute, then every 15 s; each poll of a queued or stalled job
also wakes the worker (at most once a minute). Typical completion is a few minutes; show `state`, never a fake
percentage. (4) On `ready`, `job.release_id` is playable; `charged_credits` and `released_credits` give the actual
charge (actual usage, ≤ 150). `failed` with a quality reason charges 0; `unknown_provider` charges 0 to the customer
(the platform keeps the provider liability). (5) `POST cancel {request_id}` releases the whole hold before the job
starts; once running it stops future paid calls and charges known usage (≤ 150).

**Delivery (audio).** `POST download {release_id}` → `{ grant: { expires_at, members: [{ role: "audio", url, bytes,
sha256, media_type: "audio/mp4" }] } }`. `url` is `…/functions/v1/podcast-member?grant=<64 hex>&member=<uuid>` and must
be fetched **once**, as given, with the same `Authorization` and `apikey` headers, **without `Range`** (416) and
without query changes; it expires after 15 minutes. The body is the exact object (`Content-Length` = `bytes`,
`Accept-Ranges: none`, `Cache-Control: private, no-store`). Verify `bytes` and SHA-256 before use; on any failure
discard the bytes and request a new grant (each grant consumes transfer allowance). No progressive or range playback
in v1: download the whole file (≈ 2.4 MB for five minutes at 64 kbit/s AAC in MP4/M4A), then play from local
storage. Never put the member URL or token in logs, analytics or shareable links; the token is account-bound.

**Revocation.** Before a new download and on reconnect, `POST states {release_ids: [≤ 100]}` →
`states[id].state` ∈ `ready | quarantined | withdrawn | superseded | unavailable` (+ `replacement_id`). Remove local
audio and positions for anything not `ready`; offer the replacement when present. Offline devices learn this only
when they reconnect.

**Listening history (v1, device-local; canonical record for a later encrypted stream).** One record per release:
`{ release_id, position_ms, duration_ms, completed, session_id, session_started_at, sequence, device_id, updated_at,
removed }`. A session starts when playback of a release starts on a device; each saved update takes the next
`sequence`. Merge: the record whose session started later wins; equal starts order by `session_id`; within a session
the higher `sequence` wins; on an exact duplicate a `removed` tombstone wins. Never `max(position)`: a backwards seek
is a real update. Save at pause, background/page hide, chapter change, Stop and at most every 15 s while playing.
Another device's or tab's record never moves an already playing player; it is offered as "resume" on next open.
Scope storage per account and clear it at sign-out/account switch. Native seals it with the device-held local key;
the browser keeps it in per-account `localStorage`. Nothing is sent to the server in v1.

### Browser client (apps/web, 2026-10-08, local fixture verification only)

**Ownership:** the owner moved web (and Mac-only) work to Codex on 2026-10-08, after this first version was built and
tested on the `podcast-v1` branch (commits `72e04ff`, `947afe3`). Codex can adopt or replace it; the contract above is
the interface either way.

- **Listen filter:** an additive chip (or rail item when the topic rail is shown) before the Feed's topics
  (`ui/Feed.tsx` `ListenFilter`); episode cards show title, authors, year, duration, topic, the AI-audio badge and
  "Synthetic fixture" for labeled fixtures. The catalog is requested only when Listen is opened. Absent or disabled
  capability shows "Listening isn't available yet"; the Feed and reading continue.
- **Docked player:** `ui/Podcast.tsx` renders in its own row of the app column under the workspace, so the reader,
  chat composer and selection bar shrink above it rather than being overlaid (the journey asserts the composer and
  reader end above the dock). Play/pause, ±15 s, speed (0.75–2×), position slider with spoken time, chapters, an
  approximate-timing transcript (segments seek; the active one follows playback unless the listener scrolls), and
  evidence chips. Evidence opens the cited passage through the existing passage finder (text-only anchor) when the
  paper is in the library and folds the dock to its bar; otherwise it shows the arXiv source link. Stop is explicit;
  navigation keeps playing. Media Session handlers where the browser supports them; reduced motion disables
  transcript animation.
- **Delivery:** `podcast?action=episode` (state must be `ready`, audio identity must match the catalog) →
  `action=download` → one authorized GET of the exact `functions/v1/podcast-member` URL (no Range, two-minute bound)
  → length and SHA-256 → in-memory Blob URL, revoked at Stop, episode change, sign-out and account change.
  **No offline browser downloads in v1:** nothing is written to CacheStorage or IndexedDB; playing again uses a new
  single-use grant. CSP adds only `media-src blob:` (default stays `'none'`; connect-src unchanged; deploy-web's
  output validation passes).
- **Listening places:** per-account `localStorage` (`gradstep.<env>.podcast-positions.<account>`, ≤ 200 episodes),
  saved at pause, chapter change, every 15 s while playing, page hide and Stop. Merge rule: within a play session the
  higher sequence wins (seeking back is kept); across sessions the later session start wins; never max(position).
  Another tab's write never moves the playing tab. Cleared at sign-out.
- **Not done in the browser:** the paper-detail Listen action, private generation (quote/start/status) and
  revocation polling of an already open episode beyond the pre-download state check.
- **Evidence (local only):** `npm test` in apps/web 205 passed (14 podcast); `npx playwright test` 73 passed /
  53 skipped (existing WebKit key-persistence skips; podcast journey on desktop and 390 px phone); production build
  passes. Light/dark desktop and phone screenshots in `.artifacts/podcast-web/` were inspected. No hosted backend,
  provider or deployment was used.
