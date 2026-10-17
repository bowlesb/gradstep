# Gemini Flash chat

## Build 68 follow-up: Claude on the funded router (2026-10-17; deployed and live-verified)

Owner reports an unhelpful provider failure in AI Explainer and asks why Claude still uses direct Anthropic while
Flash uses OpenRouter. The original Claude adapter remained in place; titles, suggestions and study-map updates
also name Haiku directly. Move these **chat-route** requests to the existing funded OpenRouter service, with a
static Google Vertex US pin (eligible for the account's ZDR setting), no alternate endpoints/models, named consent
v5, and the existing server admission. Flash remains the recommendation. DeepSeek's working direct route and the
separate catalog/podcast routes are unchanged by this repair.

Preserve the client choices `haiku`/`sonnet`/`opus`; route their server API model IDs to
`anthropic/claude-{haiku,sonnet,opus}-5.5` only when the new deployment switch is enabled. Freeze OpenRouter as the
billed vendor, the endpoint/model/tariff and rates in each new attempt. Historical attempts remain unchanged. Prices
verified from the endpoint inventory: Haiku US input/output $0.11/$0.55 per million (5x above 100k prompt tokens),
Sonnet $2.20/$11, Opus $4.40/$22; cache writes 1.25x for 5m, 2x for 1h; cache reads Haiku 0.1x and Sonnet/Opus 0.05x.
Cap request prices at the reviewed tier; preserve TTL, tool continuations and effort. Final OpenRouter usage cost is
authoritative; unknown final usage keeps its liability. Reject old consent before any operation, including when a
DeepSeek answer requests a Claude auxiliary. Additive migration 087 admits only these exact new chat model IDs.

Activation requires offline adapter/quote/consent/database regressions and bounded deployed checks of Claude answer,
tools and auxiliaries, and the unchanged Flash route. Keep all costs within the existing $1 rollout allocation;
no budget increase or further bake-off. Google Vertex's inventory explicitly rejects `tool_choice` function/required.
Forced auxiliaries (suggestions and study updates) therefore use that tool's JSON schema as a structured response;
the adapter validates/parses the completed object and relays the existing tool contract without streaming JSON to
the reader. Auto tool calling for chat and figures stays unchanged. A live named-tool refusal reproduced HTTP 404;
the structured replacement succeeds on the same pinned endpoint. The owner's earlier override of the manual account-settings check persists.

Verified at 23:19 UTC: migration 087 and `CHAT_CLAUDE_OPENROUTER=on` are deployed. The authenticated model table
names OpenRouter for Haiku/Sonnet/Opus and retains Flash as the recommendation. The owner's 22:39 and 22:45 UTC
Sonnet failures are confirmed `provider_billing`, zero cost; the following Flash requests succeeded. Live repair
checks now cover Haiku equation symbols, figure walkthrough/simpler/detail, three study exchanges and their maps,
Sonnet chat with title and suggestions, and unchanged Flash chat. Provider generation receipts match the ledger;
all 17 successful hosted generations used the pinned Google endpoint. The earlier forced-tool 404 was exact zero.
Opus admission/rates/adapter are covered offline; its proposed live request was stopped by the unchanged $1 repair
cap before inference (search headroom made its hold too large). No Opus quality claim follows.

The wire answer keeps the familiar Claude model ID for older clients; quotes and attempts retain the distinct
OpenRouter API ID and tariff. Direct Anthropic rates stay intact for separate catalog/podcast work. Native chooser
and failure recovery changes are available in TestFlight 69 on iOS and Mac (both VALID / IN_BETA_TESTING); browser
`f1494d2a` is live. Evidence:
`.artifacts/equations-feedback-20261017/` (`provider-evidence.json`, live logs, database, adapter and fast checks).

Historical activation checkpoint — Current status, 2026-10-17 19:55 UTC: **Flash is enabled and published as the recommendation**. `infra/staging.json`
persists `chat_gemini: "on"`; chat was deployed and the authenticated profile GET confirms Gemini is offered and
`default_recommended` is `gemini-medium-standard`. The scheduled `chat.smoke` reads that table, selects its
recommendation and completes a real answer in **4.506 seconds**, with the expected returned model profile. Actual
provider cost **$0.001296075**, rounded server cost $0.001297; one reader credit, no new unresolved hold. The
unfunded consent gate still rejects v4 before an operation or provider attempt; both synthetic accounts were deleted.
Fast checks pass. Evidence: `.artifacts/flash-activation-20261017/` (deployment, table, smoke, generation and budget).

Owner override: **“I am over riding the check, please make open router work again.”** This supersedes the account
logging/data-use verification hold below. The account opt-ins remain unverified; request-level ZDR, data-collection
denial, response-cache denial, no fallback, consent v5 and all spending limits remain unchanged. No new app build
is required: TestFlight 68 and the deployed browser support it. Restart the native app / reload the browser to
refresh the cached profile table. Existing conversations and saved defaults retain their chosen model; select
Gemini Flash in Answer options or Settings → AI chat options when one still names Sonnet. No physical-phone
acceptance or account-wide zero-retention claim follows from this activation. The earlier $0.000138 unknown
Anthropic title liability remains held.

Historical checkpoint, 2026-10-17 15:08 UTC: migration 086 and the fixed Google Vertex US route were deployed **hidden**.
Seven new public-fixture generations pass (paper chat, figure/walkthrough/detail, reference add, equation symbols
and background). Flash activation still requires the account logging/data-use check. The native rollout is already
available in TestFlight 68 on iOS and Mac (VALID / IN_BETA_TESTING). Earlier checkpoints below are historical.

## Build 68 follow-up, 2026-10-17

The owner's 14:32 UTC request is a confirmed Anthropic `provider_billing` rejection. The fresh account's allowance
does not fund upstream inference. At 14:42 UTC OpenRouter still has $10.205283699 available, but Flash is hidden.
Computer Use again denied Chrome access; the account logging/data-use check has been requested with exact setting
names. A new public DPO smoke also received an OpenRouter rejection at 14:43 UTC, with zero cost and no remaining
hold. Diagnose this before activation; earlier successful smokes are not evidence for the current configuration.

Provider balance refusals now emit `model_unavailable` after normal zero-credit settlement. Updated clients direct
the reader to another model in Answer options, without offering an ineffective same-model retry. Operator health
retains the billing cause. OpenRouter rejection diagnostics inspect at most 8 KiB in memory and record only HTTP
status plus a closed category, never the provider's raw body, prompt or credentials. The paid smoke must fail on
an SSE error, missing `done`, or an empty answer without a usable tool result; HTTP 200 alone is not a pass.

At 14:53 UTC the isolated main-provider request confirms HTTP 404 specifically for **zero data retention**.
The account-filtered model list still offers Flash, but the pinned AI Studio route cannot satisfy that policy.
The [OpenRouter ZDR endpoint inventory](https://openrouter.ai/api/v1/endpoints/zdr), read 14:50 UTC, lists
`google-vertex/us` for this exact model. The [policy documentation](https://openrouter.ai/docs/guides/features/zdr)
also states that Google's ZDR setting removes AI Studio endpoints. Do not weaken the account setting to recover.

Reviewed route change: pin `google-vertex/us`, explicitly require `zdr: true`, retain data-collection denial,
fallback denial, response-cache denial and consent v5. Google/OpenRouter remain the named processors. The endpoint
inventory quotes $0.825/M input, $4.125/M output and $0.0825/M cache read (10% above the previous route), with the
same $0.50/M token-hour storage. Update both request caps and operation quotes; migration 086 replaces only the
new-attempt pricing snapshot (route, tariff and rates). Existing attempts and their frozen evidence are unchanged;
admission, locking, settlement and replay rules are unchanged. No budget increase, new key or automatic failover.
Focused live acceptance must prove this route before publishing it. The separate OpenRouter logging/data-use
account check still applies.

The corrected route passes the seven checks above. OpenVLA (2406.09246) is queued through the actual reference-add
path; the figure boxes/crop were visually reviewed; the equation returns 15 validated symbols. Generation metadata
names Google and the expected Flash revision. Exact provider cost: **$0.063910955**, rounded ledger cost $0.063915.
One cancelled Anthropic title during the failed diagnostic retains **$0.000138** unknown liability; it was not
declared free. The other rejected diagnostic calls cost zero. Public fixtures were deleted, with no reader charge
for failures. Evidence: `.artifacts/release-68/` (provider audit, logs, database/fast/Core checks, archive checks).
The $1 rollout cap remains, including the original $0.108191 and the retained liability. No further bake-off.

The routine `chat.smoke` now follows the published recommendation and its named consent, checking the returned
profile. This avoids testing only the compatibility Sonnet default after a new default is activated. The actual
published default still omits Flash until activation; this check has not been claimed green on the hidden rollout.

Status 2026-10-17 ~03:39 UTC (Oct 16 PDT): migration 085 and chat are deployed to staging with Flash **hidden**.
The focused live checks pass after fixing the equation-symbol output budget; **Flash is not the app default yet**.
TestFlight 64 is VALID / IN_BETA_TESTING on iOS and Mac; browser `d3b06988`, admin `04ecd963` and privacy site
`ace695d9` are deployed and verified.
The existing $100/month budget stands. Public release and physical-phone testing remain paused.

## Route and request

Working choice: OpenRouter Standard, model `google/gemini-3.8-flash`, endpoint `google-vertex/us`, with fallback
disabled and required-parameter enforcement. The owner may instead choose direct Google; that needs a dedicated
paid Google credential. OpenRouter is an additional processor and billed vendor, Google the inference provider.
Use a dedicated Science Reader staging service key. On 2026-10-17 the owner funded another $10 and asked to use it
for this rollout. The existing key's entire $9.686530368 usage reconciles to Science Reader's comparison, so it is
reassigned to app use as `OPENROUTER_CHAT_API_KEY`; `OPENROUTER_API_KEY` has been removed from the research harness's
environment rather than sharing an active key between app and comparison runs. Its existing $20 lifetime limit
stays unchanged. This supersedes the earlier plan to ask for another key. Never put the key in clients, source,
diagnostics or logs. No new subscription or automatic credit purchase is authorized.

The adapter translates the existing server-built prompt, client tools, figures and tool results. It keeps the
immutable instructions/paper prefix cacheable, moves action-specific instructions after the prefix, and preserves
provider reasoning signatures in memory for tool continuations. It offers only our existing client tools: no
Google search, response caching, PDF upload, OpenRouter plugins, alternative model or provider. Use the tested
medium effort for Flash, including automatic profiles; short answers still use the existing length instructions.
All text/figure requests are transient on our server. Unknown finish reasons or malformed tools fail visibly.

## Compatibility and consent

Keep the `chat-profiles-v1` legacy `default` and `default_auto` intact. Add a validated `default_recommended`
choice that only updated clients understand; it names Flash only while Flash is enabled. The additive model and
profiles follow the original Claude profiles. Requests always send the selected Flash profile explicitly;
requests without a profile preserve Sonnet behavior. Saved explicit choices are not rewritten.

Consent `cloud-ai-v5` names Google through OpenRouter as well as Anthropic and DeepSeek. Before any hold, the server
rejects Flash under older consent. Consent v5 retains the earlier text/figure/search permissions. The client asks
again before sending to a newly named processor. Ordinary answers, equation explanations and figure explanations
all use the selected profile. Titles and follow-up suggestions remain Anthropic calls and are disclosed as such;
their failure must not invalidate a delivered Flash answer.

## Accounting and operational limits

Every request requires the existing durable, one-shot provider-attempt grant; use provider `openrouter`, route
`chat`, internal model `gemini-3.8-flash` (transport ID `google/gemini-3.8-flash`). Do not relabel the expense as direct Google. Extend the existing provider
constraints, health reporting and operation-summary deduplication. Preserve lock order, replay protection,
unknown liabilities, customer refunds for provider failures, and monthly admission. Do not weaken native-search
denial. Capture the generation ID, numeric usage and exact reported cost for reconciliation; no content.

OpenRouter's billed `usage.cost` is authoritative for inference, including cache costs; use it only when valid
final usage is present. A disconnected/aborted/unreadable stream retains unknown liability, even if some text
was delivered. Never assume a timeout is free. Holds conservatively cover uncached input, reasoning/output,
bounded cache storage and request overhead. Provider price caps prevent a changed tariff from silently bypassing
the bound. A price/date mismatch fails closed until the card is reviewed, rather than charging the old quote.

Google's reported cache-write/storage tokens may overlap its cache-read tokens (confirmed in the saved Muon
comparison bill: 47,092 in each, out of 47,118 prompt tokens). Record `cache_storage_tokens` separately in durable
usage, preserving the existing disjoint input/read/write counters. Migration 085 adds that numeric unit to the
existing validator; no other validation or limit changes. Final `usage.cost` includes the storage charge once.

[OpenRouter pricing](https://openrouter.ai/pricing), read 2026-10-16: Standard buys inference credit with a **5.5%**
platform fee; [minimum fee](https://openrouter.ai/blog/tutorials/any-coding-agent/) **$0.80**. $25 credit therefore
costs $26.375 before rounding/tax. Inference uses provider list prices. Top-up fees are platform overhead, recorded
separately from inference and not added again to `usage.cost`. No top-up has been made by this integration.
[Google prices](https://ai.google.dev/gemini-api/docs/pricing): the earlier global card through 2026-12-31 is
$0.75/$3.75/$0.075 per million input/output/cache-read tokens. The current US Vertex endpoint is 10% higher:
$0.825/$4.125/$0.0825; explicit storage remains $0.50/M token-hours. The card expires on 2027-01-01 and fails closed
pending review; it never silently adopts the scheduled increase.

Pinning prevents silent provider switching but sacrifices alternate-provider failover. OpenRouter adds a network
hop and availability dependency. The owner waived the account logging/data-use check as an activation prerequisite
on 2026-10-17; those opt-ins remain unverified. The API route must disallow training endpoints. No account-wide
zero-retention, location, SLA or measured-latency claim follows
from defaults. [Data collection](https://openrouter.ai/docs/guides/privacy/data-collection),
[provider policies](https://openrouter.ai/docs/guides/privacy/provider-logging).

OpenRouter response caching is explicitly disabled with `X-OpenRouter-Cache: false`; Google's prompt cache is
separate. [Response cache contract](https://openrouter.ai/docs/guides/features/response-caching).

## Verification and rollout

Fast checks cover streamed text/tools/signatures, figures, cache translation, refusal/429/402/abort/missing usage,
reported-cost settlement, price caps, old-client decoding, saved choices and consent. Affected database checks
prove exact provider/model admission, no native search, replay denial, one cost record and retained unknown holds.
Updated browser/native checks cover the option, default and consent without changing page layout. Then a bounded
staging smoke covers a normal question, cached follow-up, figure explanation/extraction and equation explanation,
with provider IDs and ledger readback. Publish only after these checks and a funded dedicated service key. Existing
research evidence does not prove this deployed adapter works. Rollback hides Flash and stops new admissions;
already admitted attempts still settle, and older clients continue with their existing models.

## Local evidence and activation

2026-10-17 ~03:10 UTC: the additional owner-funded $10 is confirmed ($20 total; $10.313469632 remaining).
Reserve **at most $1** for focused live rollout checks, with durable local reservations sized from the server's
own operation quote before sending; keep unknown costs held and reconcile actual provider attempts before the
next request. No new broad comparison. Chrome access was refused by Computer Use, so account privacy switches
were not inspected; keep this limitation explicit and use only public paper/synthetic fixtures while hidden.

- `npm test`: 645 backend tests and 469 browser units pass, compiler/operations/egress checks pass.
- Adapter has eight focused tests, including a complete admitted/quoted/settled chat using the actual translator
  and replayed real cache-storage usage counters (no paid inference).
  Deno checks the chat entry point; browser and admin production builds pass.
- Fresh local database applies every migration, including 085; affected DeepSeek, Gemini, overrun and
  billing-attention tests pass. Migration 085 was subsequently applied to staging during the hidden rollout.
- Core profile/stream tests: 26 pass. iPhone 17 Pro Simulator: two default/profile tests, three visual tests and
  five figure tests pass; the app and test targets compile. Browser desktop and phone journeys: 2/2 pass, screenshots reviewed for the model picker
  and named consent. Local logs: `.artifacts/gemini-chat-20261016/`.

## Hidden staging evidence, 2026-10-17 03:12–03:23 UTC

- Two DPO chat turns, a figure walkthrough, simpler section, extracted section, equation background and the repaired
  equation-symbol request complete. The symbol request initially hit the old 2,000-token cap; now 6,000 includes
  medium reasoning. It returns 11 symbols. Malformed JSON is neither displayed nor charged. See
  [equation evidence](EQUATION_VIEW.md). The two regression tests plus chat/adapter checks pass (142); the final
  fast tier passes (647 backend, 469 browser units), and Deno checks the deployed entry point.
- Eight billed OpenRouter generations total **$0.108185933**; server operation accounting rounds each to whole
  micro-USD, **$0.108191**. The failed symbol request is included, with zero customer credits. No holds remain.
  The unchanged $20 lifetime key limit and account agree: $20 funded, $9.794716301 used, **$10.205283699 remaining**.
  Google generation metadata confirms **Google AI Studio**, model `google/gemini-3.8-flash-20260902`, for all eight.
- Cache reads work across chat/figure actions (35,082 tokens) and equation actions (34,391); storage counters and
  exact bills reconcile. Three auxiliary Anthropic title/suggestion attempts were billing refusals at zero cost;
  those extras remain unavailable while Anthropic has no credit, without breaking Flash answers.
- The figure boxes and extraction were checked against the actual image. Paragraph references resolve. These are
  functional checks, not a claim of perfect answers: the first chat answer over-attributed degeneration to the lack
  of a reference model; its follow-up corrected the distinction from dynamic weighting.
- Four paid-check accounts and two unfunded gate fixtures were deleted. The hosted profile table omits Flash;
  a Flash request under consent v4 returns `consent_required` before any operation or provider attempt is created
  (`gates.json`). Local evidence: `.artifacts/flash-rollout-20261017/` (logs, durable $1
  budget ledger, generation metadata and exact costs); figure images/JSON under `.artifacts/figure-view/`.
  Browser equation, figure and HTML journeys pass on desktop and phone (6/6), with consent v5.
  No further paid test or watcher is running. The comparison harness no longer has its key variable.

At the 03:23 checkpoint `infra/staging.json` persisted `chat_gemini: "hidden"`: synthetic checks could use Flash,
while the published profile table omitted it. Computer Use denied Chrome access; **Private Input & Output Logging**
and **OpenRouter Use of Inputs/Outputs** remained unverified. The owner later explicitly waived that activation
hold; the 19:55 checkpoint above records the enabled route and live acceptance. TestFlight 64 and later plus the
current browser include consent v5 and Flash support; build 63 cannot choose Flash. Hiding/off is rollback;
already admitted attempts still settle.
