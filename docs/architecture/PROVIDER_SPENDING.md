# Provider spending admission and investigation

Status, 2026-10-08 UTC: **migration 034 and the admitted Edge/Cloud Run call paths are deployed on staging**.
Takeover readback records provider admission enabled, coverage starting **2026-10-08 02:40:51.785121 UTC**, and
native Anthropic search disabled (`.artifacts/takeover-20261008/spending-policies.json`). Coverage before that
cutoff remains historical/legacy; this observation is not proof of every vendor invoice. This design addresses the provider-call gaps in the
[independent cost audit](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md). It is additive to the
credit ledger: customer charges, provider expense and unresolved provider liability remain distinct.

Every potentially paid transport request receives a durable grant before it is sent. A lost grant
acknowledgement cannot be retried into permission to send: an exact replay returns `granted: false`.
Provider SDK and search transport retries are disabled. A new explicit request, including a chat
continuation, needs a new grant and must fit the operation's remaining ceiling. The database records
admission, final usage and reconciliation; application logs contain identifiers and counts only.

## OpenRouter consolidation — 2026-10-18 (staging deployed; TestFlight 73 iPhone/iPad/Mac)

Migration 089, the chat function and Cloud Run worker revision `gradstep-pipeline-00049-ghn` are deployed.
Admin Pages `2506e98b` introduced transport and receipt metadata in account-filtered attempt details; current Pages
`a0540bb2` also corrects billing guidance to use the recorded gateway rather than the logical model maker. Browser
Pages `8d2514ec` retains the current consent/profile contract. Migration 090 corrects a health false positive:
unclaimed metadata without an interested import is resting work, not a stuck job. Interested/claimed work
continues to alert. No paper row was reset or retried to hide that alert.

Live wire checks passed Claude and both DeepSeek structured calls, plus real PCM speech with delayed receipt
reconciliation ($0.00921739 including the Sonnet schema check). Hosted paper chat passed with citations and auxiliaries. Full podcast
acceptance remains under investigation: a new reasoning default first exhausted the script output allowance
($0.054099); explicit reasoning-disabled translation repairs that transport regression. The next Short script
was rejected by the unchanged quality checker ($0.023931; zero customer charge). It exceeded the word/character
bounds and a chapter lost supported claims. The five-minute DeepSeek run also failed correction validation ($0.067877). These are quality failures, not
missing accounting. A Sonnet contract probe identified that Vertex requires reasoning: low effort now preserves
that requirement inside the original output cap, while DeepSeek/Haiku retain reasoning disabled. The synthetic
Sonnet schema request passed; its deliberately small output limit is not a successful full episode. Neither
rejection is recorded as a successful podcast. Evidence:
`.artifacts/openrouter-unification-20261018/`. The subsequent hosted Sonnet script/review cost $0.246520 and was
rejected by review (zero customer charge). A separate public-DPO diagnostic used the production adapters and
checker successfully: 450-word accepted script, followed by 180.240 seconds of PCM speech, $0.314683 total. This
isolates working draft/review/speech contracts from the still-unproven hosted episode completion. Full accounting,
the pre-cutover owner call distinction and final allocation readback are in OPERATIONS_AND_BILLING.md.

One historical direct-Anthropic attempt from 2026-10-17 remains unknown with $0.000138 reserved. It has no
provider receipt; elapsed time is not proof of zero cost. Do not release or invent a settlement for that hold.

The owner requires one model gateway and investigation by user. All remote model POSTs will go through one
OpenRouter transport; search/catalog metadata services are not model inference. Disable direct Anthropic,
DeepSeek and Vertex model egress in deployed entrypoints. There is no direct-provider fallback.

Keep `provider_attempts` and its append-only events as the financial authority. Its account UUID, operation UUID,
attempt UUID, UTC admission/completion timestamps, route/model, tariff snapshot, usage, generation ID, actual cost
and unresolved ceiling already provide the core record. Add a one-shot dispatch RPC and transport metadata to this
same attempt, rather than another competing cost ledger: dispatched_at, exact transport model, endpoint policy,
feature and caller. It locks/checks the existing admitted attempt and records the metadata before transport; a
missing identity, failed acknowledgement or replay sends nothing. Metadata is a closed, bounded schema with no
prompts, answers, captions, titles, URLs or error bodies. Existing account-deletion de-identification remains in force.

Send OpenRouter `user` as the account UUID, `session_id` as the operation UUID, and an allowlisted `trace` carrying
attempt/feature/caller/timestamp. Shared catalog classification retains the actual funding account and is marked
`catalog_tags`, never confused with a reader chat. Research calls use an explicit service identity and durable
run/attempt journal; they cannot borrow a production key without that audit contract. Do not enable content logging
or external trace broadcasting. Owner + MFA gets paginated account/date/route filtering, exact costs separately from
unresolved liability, generation IDs and exportable records in the private admin dashboard.

Chat and podcast text use pinned routes: Claude/Gemini on the existing Google Vertex US route; DeepSeek's revisions (Flash 1017 / Pro 0813) on DeepInfra FP8. The maker is absent from OpenRouter's ZDR endpoint
inventory, so pinning it would fail; consent v6 explicitly names DeepInfra. Retain actual final OpenRouter cost rather than recreating its bill
from the list card. Every tool continuation, retry, title, suggestion, tag, script/review/repair and speech chunk
has its own durable attempt. OpenRouter speech currently ignores `only`/`order` provider pins: request ZDR and no
data collection, name OpenRouter/Google in podcast consent, and record the returned provider. Do not claim regional
pinning for speech. Audio's binary response needs its generation receipt fetched before settlement; missing receipt
keeps the original reservation unresolved. Price/admission bounds and account/platform limits still apply.

Rollout requires migration + adapter tests (no grant/replay/transport loss/missing cost/account isolation), affected
podcast/database checks, live bounded calls for changed wire contracts, private-admin readback and request provenance.
Pause/drain old worker work during cutover. No historical charge is rewritten and no new fixed cost is provisioned.
Official API references checked: [attribution](https://openrouter.ai/docs/guides/features/broadcast/overview),
[speech](https://openrouter.ai/docs/guides/overview/multimodal/tts).

## Review fixes — 2026-10-21 (design and local evidence; not deployed)

Findings from [the 2026-10-21 review](../reviews/WEB_SERVER_REVIEW_20261021.md). Nothing here raises the $100/month
operating budget, a platform limit or a per-account limit; every change keeps the ledger authoritative and additive.

### Stopped answers and unresolved attempts (A1, A6)

OpenRouter reports usage only in the final stream chunk, so a stream the reader stops (or that breaks) ends without a
bill. Before the switch, the direct Anthropic adapter charged a Stop from `message_start`'s exact input plus the output
seen so far (max(visible characters / 3, 100 tokens per second since the start), capped at `max_tokens`). The OpenRouter
adapter replaced that with a whole-ceiling estimate (every input byte as a token plus the whole output allowance),
which chat then charged to the reader: a Stop a few sentences into a 150 KB paper cost ≈89 credits for 1–3 credits of
work.

- **Platform liability and the reader's bill are separate numbers.** An attempt cut short carries `readerMicrousd`:
  the part that was written. Chat charges only that (`readerPriceAttempts`), never an estimate. An estimate with no
  observation of what was written charges the reader nothing; it is the platform's liability only.
- **OpenRouter's generation record is the bill.** After a stream is cut short, the adapter reads
  `GET /api/v1/generation?id=` (the same record speech already uses; a GET cannot buy another generation), at most six
  reads within 7 s, while the reader is already gone. The record must name the same generation, account (`user`) and
  operation (`session_id`), and the requested model (a dated suffix allowed). With it, the attempt settles **exact**
  (`succeeded`, actual = the record's `total_cost`), the receipt is recorded, and nothing is left to reconcile.
- **The reader's part of a recorded bill:** its input cost (at the route's card, at most the whole bill) plus its
  output cost in proportion to the output observed before the Stop (characters of text, tool arguments and reasoning
  / 3, or 100 tokens per second since the first chunk — the pre-switch rule). OpenRouter stops billing on cancel only
  for some upstreams; Google Vertex keeps generating, so the record may bill the whole answer. That remainder is
  Gradstep's and is recorded as absorbed, never hidden.
- **Without a record** (not written in time, unreadable, or failing a check): the reader pays the observed output at
  the route's output rate and no input; the attempt stays `unknown` with its whole ceiling reserved, for the
  reconciler below.
- **Nothing reached us:** a Stop before any text or tool call costs the reader nothing, with or without a record.

Automatic reconciliation (A6) is described with its migration below.

### Attempt capacity in a rolling window (A2, migration 0100)

`worker_provider_attempt_begin` refused once `count(*)` over every `provider_attempts` row ever stored (refused rows
included, nothing pruned) reached 100,000 for the platform or 20,000 for one account, and the check constraints
forbade raising either without a migration. A chat answer with a title and suggestions uses about three attempts, so
the owner's testing account would have been refused permanently after about 6,600 answers; each admission also counted
the whole table under the global locks. The 80% warning was computed but never shown.

- **Counter rows, not table scans.** `app_private.provider_attempt_hours(scope_id, hour, attempts)`: one row per
  account and UTC hour, plus the platform (the nil UUID). A granted attempt increments both inside the admission
  transaction (which already holds the policy lock, so counts are serial). Refused attempts never count.
- **Window.** `attempt_window_hours` (default 24, at most 168). `attempt_limit` and `account_attempt_limit` now mean
  "granted attempts per window": 50,000 for the platform and 10,000 for one account, raisable by a policy update up to
  1,000,000 / 200,000 (no migration). The per-operation bound (64) is unchanged.
- **Retention.** Counter rows older than 8 days are deleted when the account's or platform's next hour begins; the
  migration backfills the last 8 days from `provider_attempts`.
- **Visibility.** `v1_admin_spending.attempt_capacity` (platform and busiest-account use against their limits) and
  `anomalies.attempt_capacity_eighty_percent`, computed from the window; Admin › Spending shows a warning at 80%;
  `worker_budget_health.attempt_capacity_eighty_percent` lets the scheduled budget check alert.
- Money is unaffected: the monthly budget, operation holds and per-account limits still decide what may be spent. The
  OpenRouter tariff date moved behind `app_private.openrouter_tariff_expires(model)` in the same migration so the
  next one (A4) can make it renewable without another copy of the admission function.

### Tariff validity (A4, migration 0101)

Every reviewed OpenRouter price card was valid until 2027-01-01, a literal in nine copies of the admission function and
four TypeScript constants (`openrouter-chat.ts` even checked DeepSeek against Gemini's). At that instant every chat,
tag and podcast call would be refused as `tariff_expired` while chat kept publishing the models, so readers' holds were
placed, refused as `service_unavailable` with `retry_after: 10` and retried in a loop. Nothing warned beforehand.

- **One table** `app_private.openrouter_tariffs(model, tariff, valid_until, evidence_reference)`: one row per admitted
  model, seeded with the same date (no price changes). Admission and every pricing snapshot read it through
  `openrouter_tariff_expires(model)`; a model without a row fails closed. The TypeScript constants are removed; the
  per-request `max_price` caps still reject a provider price increase.
- **Renewal without an emergency.** `worker_openrouter_tariff_renew(actor, request, model, valid_until, evidence,
  reason)` — owner only, at most 183 days ahead, evidence and reason required, audited in `admin_audit_events`
  (`openrouter_tariff`), replay-safe. It confirms that the reviewed card still holds; a changed price or a new model is
  a migration and code change. Operator command: `scripts/pipeline-ops.py tariff-renew MODEL --until DATE --actor OWNER
  --evidence REF --reason TEXT` (`tariffs` lists them).
- **Stop offering before, not failing after.** The chat function reads the table with its existing policy read
  (`worker_provider_spending_policy.openrouter_tariffs`): the profile table drops a model whose card lapses within 24
  hours (and stops recommending Gemini then); a request whose model lapses within 10 minutes is `model_unavailable`
  before any hold (no `retry_after`); a lapsed side-request model (Haiku) skips the title, suggestions and map. A card
  that lapses between that check and admission is reported as `model_unavailable` too. Podcast quotes are refused
  (`podcast_unavailable`) when the script or speech card lapses within a day; reuse of a made episode is unaffected.
- **Warning six weeks ahead.** `v1_admin_health.tariffs` (Health › Attention names each card, the date and the
  command) and `worker_budget_health.tariffs_expiring_within_42d` / `soonest_tariff_expiry` for the scheduled check.

## Service RPC contract

`worker_provider_attempt_begin` takes `p_account_id`, `p_operation_id`, `p_attempt_id` (UUIDs),
`p_provider`, `p_route`, `p_model`, `p_request_sha256` (32-byte digest), `p_ceiling_microusd` and
`p_reserved_units` (JSON object). It returns `{granted, state}`. Granting requires an open account,
enabled platform work, sufficient operation headroom, and applicable provider-unit allowance.
An operation's exact known usage plus all admitted or unknown ceilings must fit its reservation.

`worker_provider_attempt_finish` takes the same three identities, `p_state` (`succeeded`,
`rejected` or `unknown`), `p_provider_request_id` (nullable), `p_actual_microusd` (nullable),
`p_actual_units` (JSON object), and `p_failure_code` (nullable sanitized code). Exact replay is
idempotent. Success records usage atomically. Only an explicit pre-processing rejection can release
the allowance with zero charge. Transport loss, ambiguous server failure, missing final usage and
unrecorded results retain the whole attempt ceiling and reserved units. The customer can be refunded
while that liability remains reserved. Later operator reconciliation is a separate audited event.

| Provider | Route | Model | Reserved units | Final units |
|---|---|---|---|---|
| `anthropic` | `chat` | requested model identifier | `output_tokens`, `web_searches` | token categories, `web_searches`, numeric `attempts` |
| `tavily` | `chat_search` | `search-basic` | `credits: 1` | `credits`, `searches` |
| `tavily` | `ingest_lookup` | `search-basic` | `credits: 1` | `credits`, `searches` |
| `tavily` | `reference_lookup` | `search-basic` | `credits: 1` | `credits`, `searches` |
| `anthropic` | `catalog_tags` | requested Haiku identifier | `output_tokens: 256` | input/output tokens |
| `mathpix` | `paper_ocr` | `v3/pdf` | `pages` | `pages` |
| `anthropic` | `podcast_script` | profile model (`claude-sonnet-5-5`) | `input_tokens: 80000`, `output_tokens: 6000` | token categories (migration 048, dark) |
| `anthropic` | `podcast_review` | profile model | `input_tokens: 80000`, `output_tokens: 4000` | token categories (048) |
| `google` | `podcast_speech` | `gemini-3.8-flash-tts` | `text_input_tokens: 8192`, `audio_output_tokens: 16384` | observed `text_input_tokens`, `audio_output_tokens`, `audio_ms` (048) |

Podcast routes (048) are granted only through `worker_podcast_attempt_begin`, which derives model, units and
ceiling ($0.22 / $0.20 / $0.303104) from the immutable profile inside a $0.75 operation; a direct call with a podcast
route is refused (`podcast_admission_required`). See [Paper podcasts](PAPER_PODCASTS.md#v1-implementation-branch-podcast-v1).

All micro-dollar amounts and unit counters are nonnegative integers. Token categories are
`input_tokens`, `cache_write_5m_tokens`, `cache_write_1h_tokens`, `cache_read_tokens` and
`output_tokens`. Provider message IDs and request IDs are retained where available, never prompts,
answers, search queries, titles, abstracts, raw error bodies or credentials. Request digests include
the operation identity and a domain separator. A digest supports replay binding, not analytics on
private content. The existing operation identity provides the account/feature trace for investigation.

## Compatibility and call paths

Chat reserves its existing customer/platform hold (since migration 047 through `worker_reserve_chat`, which also
freezes the chat quote: profile, model, effort, length, output allowance, rate version and tariff; see
[chat](CHAT.md#holds-quotes-and-settlement)). Each attempt's ceiling follows its own model's hold rule (Sonnet 5.5
×3 at its card, unchanged; Opus 5.5 ×2 at its fallbacks' Opus 5 card; Haiku 5.5 once at its prompt tier), and a topic
title is one more admitted `chat` attempt in the same operation. Its adapter grants each model round separately;
the SDK makes one transport attempt. Tavily uses one shared admitted adapter for chat, Ingest and
reference lookup. Its prepaid units are reserved globally and per account before the HTTP call;
the old snapshot readiness check is no longer an admission decision. A prepaid-only call may be
attached to an already-settled chat operation so Ingest's free lookup phase remains compatible.
The migration starts Tavily disabled until an operator records the actual allowance period, existing usage and
disabled-overage setting from dated provider evidence. The staging rollout configured October 1–November 1 UTC,
limit 3,900, baseline 37 against the 4,000-credit plan; the owner confirmed PAYGO off. This is rollout evidence,
not a fresh usage reading. No new allowance is invented at deployment.

Model input admission uses the complete serialized UTF-8 input as a conservative token bound,
including nested tool results. Output is bounded by `max_tokens`. Every later round must fit the
remaining operation ceiling before it is sent. The tag grant is raised to a **$0.04 reservation**
within the unchanged platform budget; the prior $0.01 grant did not cover the conservative input
bound. A tag request that still cannot fit uses category tags without calling the model.

Standalone reference lookup creates a zero-credit, zero-dollar metadata operation, bound to the
request UUID and digest, before any paid search. Replaying the UUID cannot create another paid
lookup. Existing clients without explicit `cloud-ai-v2` consent continue through free OpenAlex,
Crossref and arXiv discovery; they do not send their reference to Tavily. Ingest requires the same
consent and the server search switch. A configured key is never sufficient authorization.

The existing tag claim and one-shot Mathpix submission grant are mirrored into the same attempt
ledger inside their SQL transactions. They retain their existing fencing and do not acquire a second
independent permission to send. Stale tag claims and uncertain OCR submissions keep conservative
liability. A Mathpix job still running after the local timeout is quarantined with its provider job ID;
the timeout does not prove cancellation, final usage or permission for another submission.

Anthropic's search allowance applies across the whole answer: each request receives only the
remaining searches, including continuations after `pause_turn`. Output and round bounds are checked
before each request. Exhausting the continuation allowance produces an interrupted/error outcome,
never a successful completion with `pause_turn`.

**Native Anthropic search remains gated.** Its server tool does not expose a result-token limit,
so the old 30,000-token estimate is not a strict bound on internal model passes. Both SQL policy and
the provider adapter refuse it pending a verified quote based on its context limit. Tavily is the
bounded search path; unavailable Tavily yields a normal answer with search unavailable. Legacy v1
consent does not silently opt into Tavily. Changing a policy flag alone cannot enable the missing
native-search bound. See the official [search-tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
and [fallback](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback) contracts.

## Validation contract and local evidence

Use fake transports with the locked production SDK defaults: no grant means no POST; lost grant
acknowledgement and replay never resend; a lost response produces one attempt with full unresolved
liability; failure to record completion does not release the reserve; concurrent last-unit searches
cannot both be admitted. Exercise all three Tavily entry points, absent/v1 consent, server search
disabled, operation replay, account closure, platform pause and fallback. Bound repeated
`pause_turn`, mixed Tavily/Anthropic search, output exhaustion and failed admission between rounds.
Test Mathpix processing with zero completed pages after six hours, lost status, and incomplete error
usage without releasing the hold or starting an overlapping replacement. Database fixtures must
also prove settlement/refund and later reconciliation preserve the platform liability and audit trail.

Local evidence: backend fixtures exercise the locked SDK with fake transports, all three Tavily
routes, operation replay, consent, uncertain billing, lost result recording, conservative tag
quotes, continuation limits and Mathpix timeouts. Strict Deno checking passes for both changed Edge
entrypoints and the shared provider/pipeline/tag code. `provider_accounting_concurrency.py` uses
independent PostgreSQL sessions with observed lock barriers: only one account obtains the last
prepaid unit; the same attempt grants once; and settlement racing a late result in either order
leaves one recorded expense and no duplicate or lost liability. No paid provider requests were
made by these checks.

### Funding, retries and populated upgrade (2026-10-07)

Pipeline funding captures eligible account identities before locking its paper, acquires those account locks in
UUID order, and rechecks closure, suspension and stage after waiting. A newly committed importer outside that
snapshot causes a short deferral before any credit reservation or provider grant. Retry sweeps use the same
account-before-paper order, then take the short policy lock; they only process captured accounts. Hitting the
200-candidate batch limit preserves the unfinished deploy label so the next sweep can finish the same deployment.

Independent PostgreSQL sessions verify the first funder closing or becoming suspended, a late importer, retry
versus funding/closure, and the policy/paper lock interaction. The 201-candidate fixture verifies bounded progress.
The populated-upgrade test applies 034 to historical submitted OCR and tag operations: both become unknown
attempts without changing their existing platform holds; a customer refund retains the liability; late usage
records expense exactly once. The integrated database suite, 253 backend checks and 214 Swift Core tests pass.
These are local fixtures and concurrency checks. The later staging rollout applied 034; the hosted policy and
coverage evidence is above. Local passes do not establish final vendor billing or a whole-system spend ceiling.
The observed October provider budget was $13.677389 spent / $0 reserved / $25 limit at 05:14 UTC on October 8;
see [spending controls](SPENDING_CONTROLS.md#current-evidence-and-remaining-limits--2026-10-08-utc).
