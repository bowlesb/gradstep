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
| `anthropic` | `podcast_script` | profile model (`claude-sonnet-5-5`) | `input_tokens: 80000`, `output_tokens: 6000` | token categories (migration 046, dark) |
| `anthropic` | `podcast_review` | profile model | `input_tokens: 80000`, `output_tokens: 4000` | token categories (046) |
| `google` | `podcast_speech` | `gemini-3.8-flash-tts` | `text_input_tokens: 8192`, `audio_output_tokens: 16384` | observed `text_input_tokens`, `audio_output_tokens`, `audio_ms` (046) |

Podcast routes (046) are granted only through `worker_podcast_attempt_begin`, which derives model, units and
ceiling ($0.22 / $0.20 / $0.303104) from the immutable profile inside a $0.75 operation; a direct call with a podcast
route is refused (`podcast_admission_required`). See [Paper podcasts](PAPER_PODCASTS.md#v1-implementation-branch-podcast-v1).

All micro-dollar amounts and unit counters are nonnegative integers. Token categories are
`input_tokens`, `cache_write_5m_tokens`, `cache_write_1h_tokens`, `cache_read_tokens` and
`output_tokens`. Provider message IDs and request IDs are retained where available, never prompts,
answers, search queries, titles, abstracts, raw error bodies or credentials. Request digests include
the operation identity and a domain separator. A digest supports replay binding, not analytics on
private content. The existing operation identity provides the account/feature trace for investigation.

## Compatibility and call paths

Chat reserves its existing customer/platform hold. Its adapter grants each model round separately;
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
