# Shared paper podcasts: implementation contract proposal

2026-10-08. **V1 implemented on branch `podcast-v1` and shipped dark.** Staging status (reported by the lead,
2026-10-08): migration 048 is applied and worker revision 00013 ran the first two seed jobs, which both failed
`script_incomplete` in the review; the [fix](#seed-pilot-fix-review-correction-set-and-seed-episode-count-2026-10-08)
(worker checker v2 and migration 049) is not yet deployed or applied. The design below was the reviewed input; the
[implementation section](#v1-implementation-branch-podcast-v1) records what was built, where it deviates and the
[seed pilot runbook](#seed-pilot-runbook-2-the-lead-runs-this). **Four lengths** (owner, 2026-10-08): Short (~2½ min),
5, 10 and 20 minutes, each its own immutable profile, work key and credit maximum — see [Lengths](#lengths-short-5-10-and-20-minutes).
The seed pilot stays five-minute; the other lengths are private generation only.
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
**dark**: migration 048 creates every switch disabled, and no paid provider call was made while building it.

### Client API (Edge `podcast`, bounded `podcast-member`)

All requests carry the customer's `Authorization: Bearer` token; responses are `application/json`, `no-store`, and
errors are `{ "code": "<finite_code>" }`. Absent or disabled capability means "unavailable": clients keep reading
and never fall back to unguarded generation. Times are ISO 8601; durations are integer milliseconds.

| Call | Request | Response |
|---|---|---|
| `GET ?action=catalog&after=&limit=` (≤ 50) | — | `{ episodes: [Episode], next: string\|null, capabilities: Capabilities }` |
| `GET ?action=episode&release_id=` | — | `{ episode: Episode & { chapters: [Chapter], transcript: Transcript } }` |
| `GET ?action=paper&item_id=` | — | `{ episode: Episode\|null, episodes: [Episode], job: Job\|null, capabilities }` (shared or own private release for that library item; `episodes`: every ready length) |
| `POST ?action=quote` | `{ item_id, request_id, profile? }` | `{ quote: Quote, options: [Length] }` or `{ reuse: { release_id } }` or `{ join: { request_id } }` |
| `POST ?action=start` | `{ quote_id, request_id, consent_version }` | `{ job: Job }`, or `{ reuse: { release_id } }` if an identical private release became ready |
| `GET ?action=status&request_id=` | — | `{ job: Job }` (or `{ reuse: { release_id } }` for a request that reused a release) |
| `POST ?action=cancel` | `{ request_id }` | `{ job: Job }` |
| `POST ?action=download` | `{ release_id }` | `{ grant: { expires_at, members: [Member] } }` |
| `POST ?action=states` | `{ release_ids: [uuid] }` (≤ 100) | `{ states: { [release_id]: { state, replacement_id } } }` |
| `GET podcast-member?grant=&member=` | bearer token | the member's exact bytes; single use; `Range` refused |

- **Episode** `{ release_id, scope: "shared"|"private", title, year, authors: [string], topic: string|null,
  duration_ms, language: "en", ai_audio: true, fixture: bool, document_id, published_at, state,
  source: { arxiv_id|null, version|null, url|null, license|null }, audio: { bytes, sha256, media_type },
  profile, label, target_seconds }` — `profile` is the length it was made at (`podcast-10min-v1`, label "10 min", 600).
  Absent on releases from a server before lengths: treat as `podcast-5min-v1`.
  `fixture: true` marks labeled synthetic fixture audio; clients show "Synthetic fixture" next to the AI-audio badge.
- **Chapter** `{ id, title, start_ms }`. **Transcript** `{ speakers: { explainer: string, skeptic: string },
  disclosure: string, timing: "approximate", segments: [{ id, speaker: "explainer"|"skeptic", text, start_ms,
  end_ms, chapter, claim_type: "paper_result"|"author_interpretation"|"explainer_analogy"|"context",
  evidence: [{ id, quote, section|null }], math: [{ latex, spoken }] }] }`. Evidence `quote` is verbatim text from the
  pinned converted paper; clients open the paper at that quote (the passage-anchor finder), or show the source
  link and an explicit Add action when the paper is not in the library.
- **Quote** `{ id, expires_at, max_credits, estimate: "Estimate — you're charged actual usage, maximum <max_credits> credits",
  providers: ["Anthropic (script)", "Google Vertex AI (speech)"], consent_version: "podcast-private-v1", target_seconds, profile, label }`
  for the requested length (110 / 150 / 220 / 360 credits for Short / 5 / 10 / 20 minutes).
- **Length** `{ profile, label, target_seconds, max_credits, estimate }`: one offered length. `capabilities.lengths` and the
  quote's `options` list every offered length, shortest first (`podcast-short-v1` "Short" 150 s 110 credits,
  `podcast-5min-v1` "5 min" 300 s 150, `podcast-10min-v1` "10 min" 600 s 220, `podcast-20min-v1` "20 min" 1200 s 360).
- **Job** `{ request_id, state, stage_entered_at, release_id|null, held_credits, charged_credits|null,
  released_credits|null, failure|null, cancel_requested: bool, profile }`; state is one of `queued, scripting, checking, synthesizing, verifying,
  publishing, ready, canceled, failed, capacity_wait, unknown_provider, quarantined`. Poll status; never infer
  completion or charges from elapsed time.
- **Member** `{ role: "audio", url, bytes, sha256, media_type }`. The client downloads into protected local storage,
  verifies length and SHA-256, and only then marks the episode downloaded. A failed download needs a new grant.
- **Capabilities** `{ catalog: bool, generation: bool, delivery: bool, max_credits: 150, target_seconds: 300, lengths: [Length],
  transfer: { remaining_bytes, limit_bytes } }`. `max_credits`/`target_seconds` describe the default (five-minute) length
  for older clients; `lengths` is what to offer.

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
| `podcast_outcome_pending` | 409 | An earlier private job of this account still has an unresolved provider outcome; no new generation until it is reconciled (say "waiting for the previous episode's charge to be confirmed") |
| `storage_full` | 507 | Store full; nothing was held |
| `platform_budget_exhausted` | 503 | Platform paused paid work |
| `podcast_request_conflict` | 409 | Same `request_id` reused for a different quote/item/length |
| `podcast_profile_unavailable` | 400 | That length isn't offered (unknown, or withdrawn by the operator): offer the listed lengths |
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
are `null`/empty because private titles are not server-visible — use the library item's own title. `topic` is the
paper's first catalog topic tag, or its first arXiv category code (for example `cs.LG`) when it has no tags: map codes
to names as the Feed does.

**Real response fixtures.** `tests/fixtures/podcast/*.json` are actual responses of the Edge handlers over the real
SQL functions (catalog, episode, paper for shared and private, quote, start, status, download, states), captured by
`PODCAST_FIXTURE_OUT=tests/fixtures/podcast` with `tests/database/podcast_worker_journey.py` (zero spend; ids and
hashes are random per capture). Client decoders should be tested against them.

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

**Private generation.** (1) `POST quote {item_id, request_id, profile}` with a fresh UUID per length → `quote` (show
`estimate`, `max_credits`, `providers` and ask for consent; `options` gives every length's maximum for the picker), or
`reuse.release_id` (an identical private episode of **this length** exists: play it, nothing is charged) or
`join.request_id` (this account is already generating this length on another device: poll that request). Omitting
`profile` means five minutes. **Each length is its own work key**: a ready episode at another length is never reused
for this one — offer to play it (from `paper.episodes`) or to generate the chosen length. One private job per account
runs at a time, whatever its length (`active_generation_limit`).
(2) `POST start {quote_id, request_id, consent_version: "podcast-private-v1"}` — use the **same** `request_id`; a
lost reply is safe to resend (same response, no second hold). Returns `job` with `held_credits` = the quote's maximum.
(3) Poll `GET status&request_id=` every 5 s for the first minute, then every 15 s; each poll of a queued, parked or stalled
job also wakes the worker (at most once a minute). Typical completion is a few minutes for Short and 5 minutes; 10 and 20
minutes run in stages (draft, review, speech — each its own worker request) and take roughly 10–35 minutes. Show `state`,
never a fake percentage. (4) On `ready`, `job.release_id` is playable; `charged_credits` and `released_credits` give the actual
charge (actual usage, ≤ the length's maximum). `failed` with a quality reason charges 0; `unknown_provider` charges 0 to
the customer (the platform keeps the provider liability). (5) `POST cancel {request_id}` releases the whole hold before the
job starts; once running it stops future paid calls and charges known usage (≤ the maximum); a staged job parked between
stages is canceled at once.

**Delivery (audio).** `POST download {release_id}` → `{ grant: { expires_at, members: [{ role: "audio", url, bytes,
sha256, media_type: "audio/mp4" }] } }`. `url` is `…/functions/v1/podcast-member?grant=<64 hex>&member=<uuid>` and must
be fetched **once**, as given, with the same `Authorization` and `apikey` headers, **without `Range`** (416) and
without query changes; it expires after 15 minutes. The body is the exact object (`Content-Length` = `bytes`,
`Accept-Ranges: none`, `Cache-Control: private, no-store`). Verify `bytes` and SHA-256 before use; on any failure
discard the bytes and request a new grant (each grant consumes transfer allowance). No progressive or range playback
in v1: download the whole file (≈ 2.4 MB for five minutes, ≈ 9.6 MB for twenty, at 64 kbit/s AAC in MP4/M4A; never more
than 20 MiB), then play from local storage. Never put the member URL or token in logs, analytics or shareable links; the token is account-bound.

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

## V1 implementation (branch `podcast-v1`)

### Schema: migration `202610080048_paper_podcasts.sql`

Everything is in `app_private` with RLS on and no table grants; customers reach only `v1_podcast_*`
(authenticated) and the worker/Edge only `worker_podcast_*` (service role). All functions are `security definer`
with `search_path=''`. Every switch starts **off**: `podcast_policy.catalog_enabled`, `delivery_enabled`,
`generation_enabled`, `seed_enabled`, `fixtures_enabled`. Enabling anything that writes or delivers (generation,
seed, fixtures, delivery) requires a **scope-3** certified asset inventory; scope-2 certification is refused.

| Area | What 048 adds |
|---|---|
| Finance (034 extension) | `metered_operations.kind` gains `podcast`; `provider_attempts` gains provider `google` and routes `podcast_script`, `podcast_review`, `podcast_speech`; `valid_provider_units` gains `text_input_tokens`, `audio_output_tokens`, `audio_ms`. `worker_provider_attempt_begin` is replaced with the 034 body plus those routes; a podcast route is granted only inside `worker_podcast_attempt_begin` (script passes, single-call speech) or `worker_podcast_speech_begin` (every speech chunk, all or nothing) through a transaction-local token; model, units and ceiling come from the immutable profile (a chunk's audio cap is bounded per call by the serving limit and in total by the profile), so no caller-supplied model or price can be granted. Pricing snapshots record the tariff and `profile` (`podcast-10min-v1:1`). |
| Identities | `podcast_profiles` (immutable spec + SHA-256; four lengths, see [Lengths](#lengths-short-5-10-and-20-minutes)), `podcast_policy.allowed_profiles`; `podcast_episode_keys` (domain-separated work key over ordered source pins, scope/owner, profile/version, language, target length, speech model, voices; partial unique indexes for shared/private); `podcast_sources` (approval, catalog version/metadata, document id + SHA-256, OCR run, raw manifest object + hash, the exact `standalone.mmd` object + hash + bytes, render artifact, normalization version — resolved server-side, immutable); `podcast_scripts` (approved script hash, draft hash, checker version); `podcast_releases` (identity JSON, manifest hash, duration, public metadata snapshot, lifecycle `pending_review/ready/superseded/quarantined/withdrawn`, publication sequence; identity columns immutable by trigger); `podcast_release_objects`. |
| Rights | `podcast_rights` (one row per shared episode: active/quarantined/withdrawn, `rights_revision`, CC BY 4.0/CC0 approval pinned, reviewer, evidence digest) + append-only events. Checked at admission, every provider grant, publication, catalog listing and every delivery redemption. |
| Jobs | `podcast_jobs` (origin `generated`/`fixture`; funding `platform_seed`/`customer`/`fixture`; FK to the metered operation; fenced claim id/generation/lease; captured policy epoch and rights revision; one active job per work key), `podcast_job_attempts` (one per route, and one per speech chunk by `ordinal`; `podcast_jobs.speech_calls` is the plan), `podcast_job_checkpoints` (staged jobs' draft/script, ≤ 1 MiB, deleted at settlement), `podcast_job_events` (append-only, bounded to 128). States as designed: `queued → scripting → checking → synthesizing → verifying → publishing → ready`, plus `canceled`, `failed`, `capacity_wait`, `unknown_provider`, `quarantined`. |
| Seed funding | `podcast_seed_periods` (dated, linked to `platform_budgets`, **≤ $2 and ≤ 2 episodes** by check constraint, created disabled; the cap is per calendar-month period, so any later month needs a new explicit, evidence-referenced period). `worker_podcast_seed_admit` reserves the profile's $0.75 on the **operator's own account with zero customer credits** through `worker_reserve_operation` (so the $25 platform budget is rechecked), after locking budget → account → provider policy → podcast policy → seed period. Committed seed spend = unsettled ceilings + settled known usage + unresolved attempt ceilings. |
| Private generation | `podcast_quotes` (ids/digests only, 15-minute expiry, epoch-bound, cleaned after a day) and `podcast_requests` (`(account, request_id)` idempotency; `started`/`joined`/`reused`). `v1_podcast_start` rechecks the quote, source pins and work key, reuses a ready private release (zero hold), joins the owner's active job, enforces 1 active private job/account, 2 active jobs/environment, 20 jobs/day, **no new job while the account has an unresolved unknown outcome** (`podcast_outcome_pending`) and the monthly platform-loss allocation ($0.75 default: every known cost of a customer job charged zero credits, plus held unknown ceilings), then makes **one** reservation at the quoted length's maximum (110 / 150 / 220 / 360 credits; $0.55 / $0.75 / $1.10 / $1.80). |
| Storage | `stored_objects` gains bucket `podcast-assets` (shared objects: document identity, `shared/<key>/…`; private objects: owner identity, `private/<owner>/<key>/…`, enforced by check constraint). `podcast_asset_holds` (the profile's storage: 8.3 / 20 / 16.3 / 24.3 MiB, 3 objects per job at admission), `podcast_asset_uploads/members/writes` (exact plan before write, one write grant, uncertain writes retain capacity, late writes reconcile but cannot publish). `paper_asset_check_capacity` now counts podcast objects and holds globally and per owner (1 GiB/owner). Inventory scope 3 (`worker_asset_inventory_*` replaced): begin/finish require drained podcast work, pages include `podcast-assets`; `v1_reader_capabilities` and `worker_pdf_upload_policy` accept scope ≥ 2. `worker_podcast_cleanup`/`_confirm` delete objects of terminal jobs that never became a release. The worker retries write confirmations (replay-safe); a write whose outcome stays uncertain keeps its capacity and blocks inventory and the owner's deletion until the owner records evidence with `worker_podcast_write_resolve` (`podcast-ops.py resolve-write`: exact bytes present → verified, definitive absence after the worker stopped → not_written). No claim is granted while an inventory scan runs. |
| Delivery | `podcast_delivery_grants/redemptions` (token hash only, account/release/rights-revision/epoch bound, 15-minute expiry, one redemption per object, charged before Storage is read). Transfer counters reuse `reader_transfer_months` with kind `podcast` (100 MiB/account, 512 MiB with an active subscription, 2 GiB/environment) **and** the shared reader environment counter. |
| Deletion | `account-delete` and the worker's deletion sweep first call `worker_podcast_account_closing` in its own transaction: queued jobs settle as canceled, running ones get `cancel_requested` and stop at their next fenced step (deletion answers `account_busy` until then). `worker_delete_account_begin` then deletes quotes/requests and delivery grants (releasing only environment transfer totals, since the account's own counters are erased), withdraws private releases and returns `blocked` while a podcast write is unresolved; private audio is deleted through the existing object list. Shared releases survive a listener's deletion. |
| Restore | `scripts/restore-local.py` turns every podcast switch off and rotates `podcast_policy.epoch`; every fenced call compares the job's captured epoch, so pre-restore jobs, quotes, grants and pending reviews cannot proceed or publish. |
| Rate limits | `podcast-read` 600/account/h, `podcast-generate` 20/account/h, `podcast-download` 60/account/h. |

### Generation (pipeline worker, `POST /podcast`)

`services/pipeline-worker/server.ts` routes `POST /podcast` to `podcast-run.ts` in its own worker thread, awaited
under the same 840 s hard limit as the paper pipeline (its own in-flight guard; maintenance mode refuses it).
Each request recovers up to three expired leases, then claims **one** job — or, for a staged ten/twenty-minute job, one
stage of it (see [Lengths](#lengths-short-5-10-and-20-minutes)). Wake-ups: `pg_net` at admission and after each checkpoint
(`science_reader_pipeline_url` + `/podcast`), and a customer's status poll re-kicks a queued, parked or stalled job at most
once a minute; `scripts/podcast-ops.py kick` does the same for the operator. There is no new schedule or loop.
The numbers below are the five-minute profile's; every length's are in its profile.
Without both `ANTHROPIC_API_KEY` and `PODCAST_SPEECH_SERVICE_ACCOUNT` the worker leaves generated jobs queued
(fixture jobs still run).

1. **Source:** download the pinned `standalone.mmd` (bounded), verify length and SHA-256; refuse > 400 KB.
2. **Script pass 1** (`podcast_script`): Claude Sonnet 5.5, ≤ 6,000 output tokens, no tools, no server-side
   fallback, no SDK retries, `thinking: between_tools` (no extended thinking; the whole output budget is script),
   structured JSON schema output. Input bound: the serialized request's UTF-8 bytes (one token never covers less
   than one byte) must be ≤ 80,000; if larger, the free `count_tokens` estimate × 1.05 + 512 must be ≤ 80,000;
   otherwise the job fails **before any paid call** (`source_too_large`, charge 0). The paper is untrusted data.
   Every paid call must also fit its full window (240 s) plus the time later stages need inside the request;
   otherwise the job stops at zero charge (`deadline_before_paid_call`) instead of creating an unknown liability.
3. **Script pass 2** (`podcast_review`): the same text plus the draft, ≤ 4,000 output tokens, a fact-check that
   returns a **bounded correction set**, never the script: `delete` (segment id), `replace` (segment id, new spoken
   text and its math notes), `claims` (segment id, corrected claim type and complete evidence list), then an explicit
   `accept`/`reject` verdict, under a strict JSON schema. At most ⌊review output cap / 400⌋ corrections (10 for five
   minutes). The worker applies them deterministically to the draft (chapters, order, speakers and styles never
   change); an empty set with `accept` approves the draft as written. A correction naming an unknown or duplicated
   segment id, two conflicting corrections of one segment, more corrections than the limit, or deletions that would
   empty a chapter fail the job as a quality rejection (`script_corrections_invalid`, customer charged 0), never a
   silent pass. See [Seed pilot fix](#seed-pilot-fix-review-correction-set-and-seed-episode-count-2026-10-08).
4. **Checker** (`podcast-checker-v2`, deterministic; v2 = checker v1's rules run on the corrected draft — the
   version is part of the approved-script identity): structure, ids, 3–8 chapters, 8–80 segments, 450–1,000 words,
   ≤ 6,000 spoken characters, no markup or speaker labels, every `paper_result`/`author_interpretation` segment has
   1–3 evidence quotes found verbatim (whitespace-normalized) in the pinned text, every number spoken in a segment
   appears in its evidence, segments without evidence contain no digits, math LaTeX comes from the paper, ≥ 5
   evidenced segments, verdict `accept`. Failure = quality rejection: customer charged 0, known cost recorded as
   platform quality loss (private generation pauses when the month's losses reach the $0.75 allocation).
5. **Speech** (`podcast_speech`): Gemini 3.8 Flash TTS multi-speaker requests (below), planned in chunks of at most
   8,192 request bytes (request text bytes + 256), at most the profile's calls — one for Short and five minutes.
   `finishReason` must be `STOP` for every chunk; each WAV must be 16-bit PCM 24 kHz mono, complete and audible; the
   joined take must be within the profile's bounds (120–660 s for five minutes), not silent, no dead air > 8 s.
6. **Timing and encoding:** approximate segment timing (proportional, snapped to pauses), chapters from segment
   starts; ffmpeg (Debian 5.1 in the worker image) encodes **mono AAC-LC 64 kbit/s, 24 kHz, MP4/M4A** with EBU R128
   loudness normalization (−16 LUFS) and chapter markers; ffprobe must show exactly one mono AAC stream plus the MP4
   chapter text track, the right chapter count and a duration within 1.5 s of the WAV.
   ffmpeg comes from Debian's package in our own worker container (LGPL/GPL components); it runs server-side only and
   is not distributed in any app.
7. **Publication:** release key = SHA-256 of the job id and the audio and transcript hashes (the manifest also names
   job, episode and scope, so identical bytes from two jobs stay distinct releases, and records the lineage
   `draft_sha256` and `review_sha256`, the digest of the applied correction set); exact 3-object plan (`audio.m4a`,
   `transcript.json`, `manifest.json`), one write grant each, upload without overwrite (a lost reply is accepted
   only after re-reading the exact bytes), then `worker_podcast_publish` settles: seed → `pending_review` (operator
   `review` publishes), private → `ready`. Customer charge = ⌈known µ$ / 5,000⌉ credits ≤ 150.

Every grant is recorded before its POST; results (succeeded/rejected/unknown with numeric units and the
provider request id) are finished with replay-safe retries. An unknown outcome (transport loss, 5xx, missing usage)
retains the attempt's whole ceiling, stops the job (`unknown_provider`, customer charged 0) and is never retried
automatically. A crash after any admitted paid call ends the job (`failed`/`unknown_provider`), except that a staged job resumes from
its last checkpoint when nothing paid was lost; only a job that never reached a paid call is requeued. Labeled fixture jobs (`--fixture`) run the same path with zero provider calls:
real verbatim evidence quotes, synthetic tone audio, the real encoder, Storage and delivery.

### Speech provider: Vertex AI feasibility and enablement

Checked 2026-10-08 13:42 UTC with free metadata calls only (owner's gcloud identity, project `gradstep`):
`aiplatform.googleapis.com` and `iamcredentials.googleapis.com` are **enabled**; the publisher model
`publishers/google/models/gemini-3.8-flash-tts` resolves (`versionId: default`); `voices.list` (v1beta1, global)
returns the prebuilt voices, including **Sadaltager** (male, "Knowledgeable and steady… recommended for scientific
explanations") and **Erinome** (female, "Clear, articulate, and precise… instruction"), which are the fixed v1 voices.
No generation request was sent. Official facts encoded in the profile and adapter:

- Model `gemini-3.8-flash-tts`, **Preview** launch stage (released 2026-09-28), **global location only**, endpoint
  `https://aiplatform.googleapis.com/v1/projects/gradstep/locations/global/publishers/google/models/gemini-3.8-flash-tts:generateContent`.
  Input limit **8,192** tokens, output limit **16,384** tokens.
  [Model page](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-8-flash-tts).
- Multi-speaker requests need **exactly two** speakers in `speechConfig.multiSpeakerVoiceConfig.speakerVoiceConfigs`;
  each part carries `speechMetadata.speaker`/`style`; the text is a verbatim transcript (inline "Speaker 1:" may be
  read aloud); system instructions unsupported; unary output is WAV, 16-bit PCM, 24 kHz, mono; MP3/Opus output is
  not offered. [Generate speech with Gemini TTS](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/text-to-speech/overview).
- Price: $0.50/M text input and $9/M audio output through 2026-12-31 (delivered as 50% credits back), **$1/M and
  $18/M from 2027-01-01**; audio is 25 tokens/second; requests failing with 400/500 errors are not charged.
  [Vertex pricing](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing),
  [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing). The adapter reserves and records at the
  January list price; promotional credits are reconciled later from invoices, never assumed.
- Data handling: no zero-retention or training claim is made for this configuration; review Vertex's data
  governance terms before private generation is enabled.

**Authentication: no keys.** The Cloud Run worker (`gradstep-pipeline@gradstep.iam.gserviceaccount.com`) mints a
300-second token for a **dedicated** speech account through the IAM Credentials API, using its own metadata-server
identity. The lead must, once:

```sh
gcloud iam service-accounts create gradstep-podcast-speech --project gradstep \
  --display-name "Gradstep podcast speech (Vertex TTS only)"
gcloud iam roles create gradstepSpeechInvoker --project gradstep --title "Gradstep speech invoker" \
  --permissions aiplatform.endpoints.predict --stage GA
gcloud projects add-iam-policy-binding gradstep \
  --member serviceAccount:gradstep-podcast-speech@gradstep.iam.gserviceaccount.com \
  --role projects/gradstep/roles/gradstepSpeechInvoker --condition None
gcloud iam service-accounts add-iam-policy-binding gradstep-podcast-speech@gradstep.iam.gserviceaccount.com \
  --project gradstep --member serviceAccount:gradstep-pipeline@gradstep.iam.gserviceaccount.com \
  --role roles/iam.serviceAccountTokenCreator
```

then add `"podcast_speech": {"service_account": "gradstep-podcast-speech@gradstep.iam.gserviceaccount.com",
"project": "gradstep"}` to `infra/staging.json`; `deploy-pipeline-worker.py` passes both as non-secret environment
variables. If `aiplatform.endpoints.predict` alone is refused for publisher models, use `roles/aiplatform.user` on
the speech account only (broader; record it). Quota for the preview model is the project default; one request per
episode is far below it.

### Cost ceilings per five-minute episode (calculated, not measured)

| Call | Ceiling (reserved) | Typical (20k-token paper, ~750 spoken words) |
|---|---:|---:|
| Script pass 1 | 80,000 in × $2/M + 6,000 out × $10/M = **$0.220000** | ~22k in + ~3k out ≈ $0.074 |
| Script pass 2 | 80,000 × $2/M + 4,000 × $10/M = **$0.200000** | ~26k in + ~0.3k out (a correction set) ≈ $0.055 |
| Speech | 8,192 × $1/M + 16,384 × $18/M = **$0.303104** | ~1.5k text + 7,500 audio tokens ≈ $0.137 list ($0.068 net of the 2026 credit) |
| **Total** | **$0.723104**, held as **$0.75 / 150 credits** | **≈ $0.27 list** (≈ $0.20 with the 2026 credit) |

Ceilings are hard: each grant must fit the operation's remaining reservation, and a recorded actual above an
attempt's ceiling freezes platform work. "Typical" values are planning estimates from the pricing model, not
measurements; the pilot measures them. Runtime: ~3–5 minutes of a 1 vCPU/2 GiB request-billed instance
(≈ $0.005–0.009 at list before the free tier); storage ~2.4 MB audio + ~20 KB transcript per episode.
**Seed pilot maximum:** 2 episodes × $0.75 = $1.50 admitted, inside the $2 seed allowance and the existing
$25 provider cap; the database refuses a third seed episode and any admission that would exceed $2.

### Lengths: Short, 5, 10 and 20 minutes

Owner request, 2026-10-08: offer Short (~2–3 min), 5, 10 and 20 minutes in the first build. Migration 048 (not applied
anywhere) carries four immutable profiles; `podcast-5min-v1` is unchanged (same spec and SHA-256). Every length is its
own work key (`target_seconds` and the profile id are in it), so a ready episode of another length is never reused:
clients offer to play it or to generate the chosen length. `podcast_policy.allowed_profiles` (`id:version`, audited
through `worker_podcast_policy_set` / `podcast-ops.py policy --set allowed_profiles=…`) lists the lengths offered for
private generation; it starts with all four. The seed pilot is unchanged: `worker_podcast_seed_admit` refuses anything
but a five-minute profile (`seed_profile_unavailable`), at most two episodes and $2.

| Profile | Target | Accepted audio | Script words (prompt / checker) | Chapters · segments (checker) | Draft out | Review in / out | Speech calls · audio budget | Ceiling | Credits |
|---|---:|---:|---|---|---:|---:|---|---:|---:|
| `podcast-short-v1` "Short" | 150 s | 60–330 s | 330–420 / 220–520 | 2–5 · 4–40 | 3,200 | 84,200 / 2,600 | 1 · 8,250 tokens | **$0.543092** | **110** |
| `podcast-5min-v1` "5 min" (unchanged) | 300 s | 120–660 s | 650–800 / 450–1,000 | 3–8 · 8–80 | 6,000 | 80,000 / 4,000 | 1 · 16,384 tokens | **$0.723104** | **150** |
| `podcast-10min-v1` "10 min" | 600 s | 300–1,080 s | 1,350–1,650 / 900–2,000 | 4–12 · 16–160 | 12,000 | 93,000 / 10,000 | ≤ 3 · 27,000 tokens | **$1.076576** | **220** |
| `podcast-20min-v1` "20 min" | 1,200 s | 600–2,040 s | 2,700–3,300 / 1,800–3,800 | 6–20 · 30–300 | 22,800 | 103,800 / 19,000 | ≤ 6 · 51,000 tokens | **$1.752752** | **360** |

**Ceilings use the five-minute method**: every paid call is reserved at its full input and output caps at list price, and
the total is rounded up to the next 10 credits ($0.05). Draft input is ≤ 80,000 tokens for every length (the paper is the
same); a review reads the paper plus the draft, so its input cap is the draft's input cap + the draft's output cap + 1,000.
Each speech call reserves 8,192 text tokens; the audio budget is `max_seconds × 25 tokens/s`.

| Profile | Script pass 1 | Script pass 2 (review) | Speech | Total |
|---|---|---|---|---:|
| Short | 80,000×$2/M + 3,200×$10/M = $0.192000 | 84,200×$2/M + 2,600×$10/M = $0.194400 | 1×8,192×$1/M + 8,250×$18/M = $0.156692 | $0.543092 → 110 |
| 5 min | 80,000×$2/M + 6,000×$10/M = $0.220000 | 80,000×$2/M + 4,000×$10/M = $0.200000 | 1×8,192×$1/M + 16,384×$18/M = $0.303104 | $0.723104 → 150 |
| 10 min | 80,000×$2/M + 12,000×$10/M = $0.280000 | 93,000×$2/M + 10,000×$10/M = $0.286000 | 3×8,192×$1/M + 27,000×$18/M = $0.510576 | $1.076576 → 220 |
| 20 min | 80,000×$2/M + 22,800×$10/M = $0.388000 | 103,800×$2/M + 19,000×$10/M = $0.397600 | 6×8,192×$1/M + 51,000×$18/M = $0.967152 | $1.752752 → 360 |

Prices (checked 2026-10-08): Claude Sonnet 5.5 $2/M input, $10/M output, 128K output with streaming
([Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)); Gemini 3.8 Flash TTS on Vertex AI $1/M text input and
$18/M audio output from 2027-01-01 ($0.50/$9 through 2026-12-31 as 50% credits back, not assumed), 25 audio tokens per
second, 8,192 input / 16,384 output tokens per request
([Vertex pricing](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing),
[model page](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-8-flash-tts)). The migration
recomputes every total from its parts and refuses to apply on a mismatch; `tests/database/test_podcast_lengths.sql`
re-derives each ceiling and credit maximum.

Typical cost (planning estimate, 20k-token paper, 150 words a minute, ~4 output tokens per spoken word): Short ≈ $0.19
(~38 credits), 5 min ≈ $0.29 (~59), 10 min ≈ $0.49 (~99), 20 min ≈ $0.90 (~180), at the January 2027 list price. These
were estimated with a review that re-emitted the script; since checker v2 a review outputs only a correction set (see
below), so each is a few cents lower.

**Review output (checker v2).** The review's output cap ("Review … out" above, unchanged) is a ceiling for a correction
set, never room for a rewrite: at most ⌊cap / 400⌋ corrections — Short 6, 5 min 10, 10 min 25, 20 min 47 — each of which
needs at most ~400 tokens, so even a maximal set fits. Under checker v1 the review had to re-emit the whole draft, and
every draft cap is larger than its review cap (3,200 vs 2,600, 6,000 vs 4,000, 12,000 vs 10,000, 22,800 vs 19,000).
Expected sizes are in [Seed pilot fix](#seed-pilot-fix-review-correction-set-and-seed-episode-count-2026-10-08).

**Chunked speech.** One TTS call holds at most 8,192 input tokens (bounded provably by request bytes) and 16,384 audio
tokens (655 s). `planSpeechChunks` splits a script between segments — preferring where a chapter starts, then where the
speaker changes, with chunks balanced by words — into the fewest calls that fit, at most the profile's `max_calls`. The
audio budget is shared out in proportion to each chunk's words (each chunk must still cover 12.5 tokens a word, a slow
120 words a minute); a script that cannot be planned fails before any speech is bought (`script_too_long_for_speech`,
customer charged 0). All chunks are granted in **one** call, `worker_podcast_speech_begin`, all or nothing: if any grant is
refused, the grants made before it in that transaction were never sent and close as rejected at zero cost. The chunks are
then sent together (concurrently; Vertex bills only successful requests) and every result is recorded before any is
judged; any unknown outcome keeps its ceiling and ends the job as `unknown_provider`, as before. `joinChunks` trims each
take's edge silence (keeping 120 ms), matches speech levels within ±6 dB, fades 12 ms at each seam and joins with a
450 ms pause; segment timing is aligned inside each chunk and placed at that chunk's exact offset, so chapters start at
their first segment. The encoder's EBU R128 normalization then runs over the whole take. Speech counts as succeeded only
when every planned chunk succeeded (`podcast_jobs.speech_calls`, fixed at the first speech grant).

**Staged generation (10 and 20 minutes).** A twenty-minute draft alone can take ~10 minutes at a conservative 35 output
tokens/s, so `"staged": true` profiles run one paid stage per worker request: (1) the draft, then `worker_podcast_checkpoint
('draft')`; (2) the review and the deterministic checker, then `checkpoint('script')`; (3) chunked speech, join, encode,
upload and publish. A checkpoint stores the stage's output in `podcast_job_checkpoints` (bounded to 1 MiB, never logged,
deleted when the job settles), releases the claim and wakes the worker; the job waits **parked** in `checking` or
`synthesizing` and the next claim resumes it with the stored document. Per-call windows come from the profile (draft
420/680 s, review 360/600 s, speech 420 s for 10/20 minutes) inside the 780 s request budget; a request without enough
time left yields (`worker_podcast_yield`) at its last safe point instead of failing. Recovery after a lease expiry resumes
a staged job from its checkpoint when every admitted call succeeded and its output is checkpointed; a paid result that was
never checkpointed ends the job (`worker_interrupted`, customer charged 0) and is never bought again. Cancel and account
closing settle a parked job at once; a restore's epoch rotation fails it closed. Short and 5 minutes keep the single-request
flow and its windows. The private paper-derived drafts in checkpoints are server-readable, like the private transcript
they become (not end-to-end encrypted).

**Also changed for every length.** Before the first paid call the worker refuses a paper whose review (paper + the
largest draft) could not fit the review's input cap (`source_too_large`, zero charge); previously a paper near the cap
could pay for a draft and then fail its review. Storage holds and delivery grants allow the twenty-minute audio cap
(20 MiB; ~16.3 MB at most at 64 kbit/s). The workflow check counts a job as stuck after 45 minutes (was 30).

**Operational notes.** The platform-loss allocation (`quality_allocation_microusd`, $0.75/month by default) counts every
known cost charged zero credits plus held unknown ceilings; one failed twenty-minute job after both script passes can use
most of it and pause private generation for the month — raise it deliberately (≤ $5) when longer lengths are enabled. The
customer's transfer allowance (100 MiB/month free) is about six twenty-minute downloads.

### Listening history

Device-local in v1 (see the canonical record in the client API reference). The design's encrypted podcast stream
(own envelope domain, independent cursor, compaction, key rotation and old-client tests) is the follow-up; the
record format and merge rule are already fixed so that stream can reuse them. No server table holds positions.

### Deviations from the design and remaining gates

- **One bounded request per job** for Short and five minutes keeps drafts in memory: a crash after a paid call ends the
  job (platform loss, customer charged 0) instead of resuming from a persisted draft. Ten and twenty minutes do persist
  their draft and approved script between stages (they could not fit one request). Upload failures after paid
  generation lose that episode the same way, and speech chunks are not checkpointed.
- **Speech chunks are sent concurrently** (≤ 6 for twenty minutes) rather than "one paid speech transport at a time":
  sequential chunks would not fit a request, and persisting raw chunk audio between requests was not worth its storage
  and inventory cost. Rejections are free; the concurrency is bounded by the profile and two active jobs.
- **Token bound:** bytes are a provable bound; above 80,000 bytes the free `count_tokens` estimate (+5% + 512) is
  used. Anthropic documents counts as estimates; an actual above the grant freezes paid work rather than overspending.
- **Timing is approximate** (one multi-speaker take); word-level alignment would need a separate, separately
  admitted transcription pass.
- **No admin dashboard page yet:** podcast routes appear in the existing Spending page by provider/route/model;
  operators use `scripts/podcast-ops.py status` and the `podcast.state` workflow check.
- **Not built:** progressive/range playback, private-to-shared sharing, sponsorship, encrypted listening stream,
  automatic revocation polling beyond the documented `states` call, optional QA transcription, OpenAI comparison.
- The design's required real-session races are covered locally for start/join, claim, cancel, seed-disable,
  grant redemption and the operator policy call against a start (`tests/database/podcast_concurrency.py`);
  account-deletion vs running-job and purchase-refund races are covered only by single-session SQL.
- **Independent review (2026-10-08, read-only agent):** ten findings, all fixed on this branch with tests —
  deletion with an unredeemed grant (re-created negative counter), operator policy vs start lock order (deadlock),
  uncertain writes with no resolution path, unknown/non-quality losses not bounding private generation, deletion's
  cancel request rolled back, a capacity denial hitting a foreign key, paid calls admitted with too little time left,
  claims during an inventory scan, unfenced publication review, and a status-poll lock cycle with deletion.

### Seed pilot runbook ($2, the lead runs this)

Prerequisites: review this branch; owner account id (`<OWNER>`, with the owner role) at hand; no other agent
deploying the worker. All `podcast-ops.py` mutations print a request id first; re-run with `--request-id` after a
lost reply.

1. **Back up** (`python3 scripts/backup.py staging`), then **apply 048** through the normal migration path
   (`python3 scripts/deploy-staging.py staging --defer-activation --functions podcast podcast-member` applies pending
   migrations, provisions the private `podcast-assets` bucket from `infra/staging.json` and deploys both functions;
   they answer but everything stays off).
2. **Speech identity:** run the four `gcloud` commands above and add `podcast_speech` to `infra/staging.json`.
3. **Worker:** `python3 scripts/check-podcast-encoder.py --amd64` (zero spend), then deploy the worker image
   through the usual paused → readiness → activate procedure (`deploy-pipeline-worker.py … --defer-activation`;
   the image now contains ffmpeg and `/podcast`).
4. **Inventory scope 3:** pause the pipeline (`pipeline-ops.py disable`), run `scripts/asset-inventory.py staging
   --apply` (now three buckets; requires no podcast claims/writes), confirm zero discrepancies and `inventory_scope=3`
   (`podcast-ops.py status` → `inventory_certified: true`), re-enable the pipeline.
5. **Zero-spend staged journey:** `podcast-ops.py policy --actor <OWNER> --set fixtures_enabled=true
   --set catalog_enabled=true --set delivery_enabled=true --reason "Staged fixture journey"`; pick an approval from
   `podcast-ops.py candidates`; `podcast-ops.py seed --actor <OWNER> --approval <id> --fixture --reason "Labeled
   synthetic fixture"`; `podcast-ops.py kick`; when `status` shows the job `ready`, `podcast-ops.py review … --publish`.
   Check the Listen filter, playback, transcript evidence jump and offline download in a TestFlight/Simulator build
   against staging; then withdraw it: `podcast-ops.py rights --episode <id> --state withdrawn --reason "Fixture done"`.
6. **Seed allowance:** `podcast-ops.py seed-period --actor <OWNER> --limit-usd 2 --max-episodes 2 --enable
   --evidence owner-decision-20261008` and `policy --set seed_enabled=true --reason "Seed pilot"`. Confirm current
   provider headroom ≥ $1.50 (`pipeline-ops.py status` / Spending page).
7. **Pick two papers** from `candidates` (CC BY 4.0/CC0, text ≤ 400 KB, ideally one equation-heavy and one
   empirical); check third-party material/exclusions in each; then for each: `seed --actor <OWNER> --approval <id>
   --reason "<rights check summary>"` and `kick`. Each admission reserves $0.75; `status` shows grants, actual
   micro-dollars per route, provider request ids and the seed `committed_microusd`.
8. **Review** each `pending_review` release by listening end to end against the paper and its evidence links
   (factual support, numbers, limitations, pronunciation, no cut-off speech) and record `review --publish` or
   `--reject` with a reason. Only then turn on the catalog for testers (`policy --set catalog_enabled=true
   --set delivery_enabled=true`).
9. **Record** actual cost per accepted minute, first-playable time, durations and any `unknown_provider` in the
   operations record; reconcile Vertex charges against the invoice later (`worker_provider_attempt_reconcile`).
   Private generation (`generation_enabled`) stays off until the pilot is reviewed. When it is enabled, decide which
   lengths to offer first (`policy --set allowed_profiles=podcast-short-v1:1,podcast-5min-v1:1` keeps the staged ten- and
   twenty-minute paths off until measured) and whether to raise `quality_allocation_microusd` above $0.75 for them.

Rollback at any point: `policy --set seed_enabled=false --set generation_enabled=false --set catalog_enabled=false
--set delivery_enabled=false`; settlement, deletion and already downloaded copies keep working.

### Seed pilot fix: review correction set and seed episode count (2026-10-08)

**What happened** (staging, worker revision 00013, reported by the lead). Both five-minute seed jobs failed
`script_incomplete` in `checking`:

| Pass | Job 1 output tokens | Job 1 cost | Job 2 output tokens | Job 2 cost |
|---|---:|---:|---:|---:|
| Draft (`podcast_script`, cap 6,000) | 4,785 | $0.107 | 4,497 | $0.109 |
| Review (`podcast_review`, cap 4,000) | 4,000 (the cap) | $0.109 | 4,000 (the cap) | $0.114 |

**Root cause (confirmed in the code).** Checker v1's review schema required the whole script (`title`, `chapters`,
`segments`, `limitations`) plus the verdict, and its task said "Return the corrected script". A five-minute draft is
~4,500–4,800 output tokens (verbatim evidence quotes and JSON are most of it; job 1's billed costs imply a ~29.6k-token
draft request and a ~34.5k-token review request), so re-emitting it cannot fit the 4,000-token review cap: the API stopped at
`max_tokens` and `scriptCall` failed the job `script_incomplete` after both passes were billed. The draft itself
finished (`end_turn`, well under 6,000) and the checker never ran. Every length has the same mismatch, because every
review cap is smaller than its draft cap. `tests/backend/podcast.test.ts` ("five-minute pilot") reproduces it with fakes
billed at the staging units ($0.107 draft, $0.109 truncated review).

**Fix 1 — worker only (checker v2).** The review returns a bounded correction set that the worker applies
deterministically (Generation step 3); profiles, routes, grants and ceilings are unchanged. `CHECKER_VERSION` is now
`podcast-checker-v2`, recorded in `podcast_scripts.checker_version`, the release identity and the approved-script
document. The manifest also records `review_sha256` (the applied correction set) next to `draft_sha256`. Staged jobs
checkpoint the corrected script with `review_sha256`; a `script` checkpoint written by the old worker still resumes (its
script already carries the verdict). Failure codes: invalid corrections `script_corrections_invalid`, a review output
that is not a correction set `script_invalid`, a `reject` verdict or a checker refusal `script_evidence_rejected`; all are
quality failures (customer charged 0, platform quality loss recorded). `script_rejected` keeps its existing meaning (the
provider refused the request) so the two stay distinguishable.

**Expected review output** (estimates at ~4 characters per token; a correction is ~20 tokens for a deletion and ~60–150
for a rewrite or a claim correction; a typical fact-check touches a small fraction of segments):

| Profile | Review cap (unchanged) | Correction limit | Approve as written | Typical review | Limit, typical entries | Hard bound | v1 rewrite needed (≈ draft) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Short | 2,600 | 6 | ~15 | ~100–300 | ~600 | ≤ 2,400 | ~2,100–2,700 + verdict/issues |
| 5 min | 4,000 | 10 | ~15 | ~150–500 | ~1,000 | ≤ 4,000 | 4,497–4,785 measured + verdict/issues |
| 10 min | 10,000 | 25 | ~15 | ~400–1,000 | ~2,500 | ≤ 10,000 | ~8,600–10,600 + verdict/issues |
| 20 min | 19,000 | 47 | ~15 | ~800–2,000 | ~4,700 | ≤ 18,800 | ~17,300–21,100 + verdict/issues |

The v1 column scales the measured five-minute draft (~6.4 output tokens per spoken word) to each prompt's word range.
The pilot test's three-correction set is 132 tokens. A five-minute review now costs ≈ $0.070–0.074 (its ~34.5k input
tokens are unchanged) instead of the measured $0.109–0.114.

**Residual risk, not changed here: five-minute speech request size.** The five-minute profile allows one speech call
of at most 8,192 request bytes, counted as spoken text + ~80 bytes of speaker/style metadata per segment + 258. The
checker allows 6,000 spoken characters in up to 80 segments, so a draft at the top of the prompt's range (about 800 words
in 40 segments, ~4,700 spoken characters) can exceed it and fail `script_too_long_for_speech` after both script passes
(≈ $0.18, charged to the seed allowance). The pilot drafts' segment counts were not recorded. A 30-segment draft fits up to
~5,500 spoken characters (~900 words). If it happens, the follow-up is a tighter speech input bound (for example Vertex's
free token count, as the script route already uses for Anthropic), not a profile change.

### Verification (local, 2026-10-08)

Final run on the merged tree (main through `a53c6f8`, with migration 047): no hosted service, provider, device or upload
was used.

- `python3 scripts/test-database.py`: exit 0, 234 PASS lines; 048 applies after 046 and 047. Includes
  `tests/database/test_podcasts.sql` (dark defaults, audited policy, $2/two-episode seed allowance, seed lifecycle,
  review, catalog metadata, bounded delivery, takedown, private quote/start/join/cancel, unknown outcomes, actual-usage
  charges, isolation, lease recovery, epoch fence, quality pause, capacity, fixtures, scope-3 inventory, deletion),
  `tests/database/test_podcast_lengths.sql` (each profile's ceiling and credit maximum re-derived, allowlist and its
  audited changes, quotes per length, seeds five-minute only, checkpoints, resumed claims, recovery to a checkpoint,
  yields, all-or-nothing chunk grants, parked cancel/closing, restore fence), `podcast_concurrency.py` (real sessions)
  and `podcast_worker_journey.py` (the real worker and Edge code on the real schema: fixture and seed episodes, a private
  five-minute episode and a **ten-minute episode staged over three worker requests with chunked speech**; its responses
  are the client fixtures in `tests/fixtures/podcast`).
- `npm test`: 461 passed (31 podcast: checker, profile-driven prompts and bounds, speech adapter, chunk planner and
  joiner, staged ten-minute flow, yields, refused/partial chunk batches, review-fit refusal, encoder, Edge API with
  `profile`, delivery, worker routing). Deno strict checks pass for `podcast` and `podcast-member`.
- Operations: 138 Python tests (restore quarantine, scope-3 inventory, worker deploy context and speech env,
  `podcast-ops.py` including `allowed_profiles`) and 7 Node tests.
- `scripts/check-podcast-encoder.py` (earlier, unchanged encoder): the real worker image (ffmpeg 5.1.9) encoded a
  labeled fixture to mono AAC M4A; AVFoundation read its chapter markers.

### Browser client (apps/web, 2026-10-08, local fixture verification only)

**Ownership:** the owner moved web (and Mac-only) work to Codex on 2026-10-08, after this first version was built and
tested on the `podcast-v1` branch (commits `72e04ff`, `947afe3`). Codex can adopt or replace it; the contract above is
the interface either way. **For lengths** the browser needs: `profile` on `quote`, the quote's `options` and
`capabilities.lengths` for the picker, `paper.episodes` for ready lengths, `podcast_profile_unavailable`, a 20 MiB audio
bound, and longer polling for staged ten/twenty-minute jobs (fixtures: `quote_10min`, `start_10min`, `status_10min`,
`episode_10min`, `paper_lengths`, `quote_reuse`). This branch's `apps/web` is identical to main's.

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

### Native client (apps/apple, 2026-10-08, local fixture verification only)

iPhone and iPad first; Mac Catalyst compiles the same code (no Mac-only work). Hooks into existing screens are a few
lines each; everything else is in `Services/Podcast*.swift`, `Views/Podcast*.swift` and Core `Podcast*.swift`.

- **Listen filter:** a chip before the Feed's own chips, shown once the server reports `catalog: true` (or in the
  fixture). While Listen is chosen the Feed's chips stay visible, none selected; choosing one returns to that feed.
  Cards: title, year, duration, topic (arXiv codes by name), AI-audio badge, "Synthetic fixture", private, downloaded,
  time left. **Listen** is also in the Paper "…" menu and a Library row's actions: plays the shared or own private
  episode, follows a running generation, or offers private generation (offer → explicit quote with providers,
  storage and maximum → consent → durable status polled 2/5/15 s → charged/released credits as the server states).
  `{reuse}` from quote/start/status plays the ready release with no new charge; `podcast_outcome_pending` and other
  finite codes are explained plainly. Private episodes take the library item's own title.
- **Lengths:** the Listen sheet lists Short · 5 min · 10 min · 20 min from `capabilities.lengths` (five minutes alone
  for an older server), each row with its own maximum (from the quote's `options` once quoted), five minutes chosen by
  default. A length already ready for the paper (`paper.episodes`) is marked "Ready · no credits" and plays instead of
  being made again; any other length is quoted on its own (one quote request per length, one start request per quote),
  and choosing another length after an estimate quotes that one at once. Listen on a paper with an episode still plays it
  directly; the player's "…" adds **Other lengths…** for a library paper. Cards and the player show each episode's
  duration.
- **Player:** sheet with play/pause, ±15 s, speed 0.75–2×, position slider (spoken values), chapters, transcript
  (tap seeks; follow-along respects Reduce Motion; LaTeX typeset, VoiceOver reads the spoken form), evidence that opens
  the paper at the quote through the Go to passage finder (Markdown marks removed) with Back, or the source plus an
  explicit Add when the paper isn't in the library. Done keeps playing; Stop is explicit. Space and ←/→ with a
  hardware keyboard. Mini-player above the tab bar takes part of the tab bar's reserve, so the chat message box and
  the reader's controls sit above it (hidden with the software keyboard); on the iPad's wide layout it docks below
  every pane. AVAudioSession playback/spokenAudio/longFormAudio, `UIBackgroundModes: audio` (Info.plist is now
  generated from project.yml), Now Playing and remote commands (play, pause, toggle, ±15, rate, scrub), interruptions,
  route changes and media-services resets.
- **Delivery and storage:** one single-use grant per transfer; the bearer goes only to this origin's
  `podcast-member`; no Range; length and SHA-256 checked before "downloaded". Files live in the account's folder
  (`<environment>/<account>/podcasts/`, erased with the account), protected until first unlock so locked
  background playback works, excluded from backup. A copy Play needed is kept (≤ 3, LRU) so Download reuses it; the
  downloads list (with transcripts) and listening history are AES-GCM sealed under subkeys of the device-held local
  key, account-bound. Takedowns/corrections are checked (`states`) when the catalog loads; blocked copies are removed.
- **History:** device-local, session/sequence ordered (backwards seeks kept, later session wins, tombstones);
  saved at pause, chapter change, seek, end, background and every 15 s while playing; cleared from view on sign-out
  and account switch.
- **Fixture (`--podcast-fixture`, Simulator/Mac Debug only):** two labeled shared episodes and a generated private
  one; audio is tones synthesized on the device with the transcript's timing; evidence quotes are verbatim sentences
  of the bundled offline sample. Zero spend, no network.
- **Evidence (final, merged tree):** `swift test` (Core) 277 passed, including 19 podcast tests that decode every
  captured server response in `tests/fixtures/podcast` (the ten-minute quote, job, episode and paper lengths too); iOS
  unit tests 411 run, 5 skipped, 0 failures; podcast UI journeys on an iPhone 17 Pro Simulator (`GS-Podcast-iPhone`):
  12 passed, 1 iPad-only skipped (Listen filter, play/±15 s/mini-player, mini-player clear of the chat message box,
  transcript evidence jump, evidence outside the library, verified offline download across relaunch, private quote →
  progress → charge, failed generation charges nothing, outcome pending, **choosing 10 minutes quotes its own 220-credit
  maximum**, **Other lengths offers the ready five-minute episode or a new length**, light/dark screenshots); on an
  iPad Pro 11-inch Simulator (`GS-Podcast-iPad`) the wide-layout docked player, Listen filter, mini-player and the
  ten-minute quote passed, with main's four tablet keyboard/split-chat tests. A universal (arm64 + x86_64) unsigned Mac
  Catalyst `build-for-testing` succeeds with `UIBackgroundModes: audio`. Screenshots (light and dark) are in
  `.artifacts/podcast-ui/lengths-20261008/` and were inspected.
- **Merge fix (2026-10-08):** with main's chat controls, tapping the chat message box on an iPhone while the mini-player
  showed never raised the keyboard (keyboard + tab-bar reserve briefly tipped the composer into its compact layout, which
  rebuilt the text field). The composer now changes shape through one `AnyLayout` with a stable text field, and the
  mini-player's share of the reserve no longer decides the layout; main's chat-controls (3), iPhone chat keyboard (4)
  and tablet keyboard (4) UI tests pass.
