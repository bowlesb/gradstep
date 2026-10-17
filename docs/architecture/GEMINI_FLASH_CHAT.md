# Gemini Flash chat

Status 2026-10-17 ~00:14 UTC (Oct 16 PDT): owner selected Gemini 3.8 Flash after the
[finalist comparison](../reviews/MODEL_COMPARISON_FINALISTS_20261016.md). Built and verified locally;
**not deployed or made the default yet**. This design was recorded before schema and runtime changes. The
existing $100/month operating budget stands. Public release and physical-phone testing remain paused.

## Route and request

Working choice: OpenRouter Standard, model `google/gemini-3.8-flash`, endpoint `google-ai-studio`, with fallback
disabled and required-parameter enforcement. The owner may instead choose direct Google; that needs a dedicated
paid Google credential. OpenRouter is an additional processor and billed vendor, Google the inference provider.
Use a dedicated Science Reader staging service key, separate from the capped research key. Never put either in
clients, source, diagnostics or logs. No new subscription or automatic credit purchase is authorized.

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
[Google prices](https://ai.google.dev/gemini-api/docs/pricing): through 2026-12-31, Flash input/output/cache-read
are $0.75/$3.75/$0.075 per million tokens; explicit storage $0.50/M token-hours. These double on 2027-01-01.

Pinning prevents silent provider switching but sacrifices alternate-provider failover. OpenRouter adds a network
hop and availability dependency. Content logging and data-use opt-ins must be checked on the service account;
the API route must disallow training endpoints. No zero-retention, location, SLA or measured-latency claim follows
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

- `npm test`: 645 backend tests and 469 browser units pass, compiler/operations/egress checks pass.
- Adapter has eight focused tests, including a complete admitted/quoted/settled chat using the actual translator
  and replayed real cache-storage usage counters (no paid inference).
  Deno checks the chat entry point; browser and admin production builds pass.
- Fresh local database applies every migration, including pending 085; affected DeepSeek, Gemini, overrun and
  billing-attention tests pass. No hosted migration was applied by this work.
- Core profile/stream tests: 26 pass. iPhone 17 Pro Simulator: two default/profile tests, three visual tests and
  five figure tests pass; the app and test targets compile. Browser desktop and phone journeys: 2/2 pass, screenshots reviewed for the model picker
  and named consent. Local logs: `.artifacts/gemini-chat-20261016/`.
- Current OpenRouter account/key usage reconciles to $9.686530368 (ledger $9.6865303832, rounding difference),
  $10 funded, about $0.31 left. No new inference, key-limit change, top-up or fixed commitment in this integration.
  `OPENROUTER_CHAT_API_KEY` is absent; funding and that app key were requested. No paid watcher is running.

Deployment remains gated by `infra/staging.json` `chat_gemini: "off"`. Once a funded dedicated key is present and
its content logging/data-use settings are checked, deploy pending migration 085 and `chat` with
`python3 scripts/deploy-staging.py staging --functions chat --chat-gemini hidden --skip-checks`.
Run the focused paid smoke under a declared remaining allocation: `scripts/chat-live-smoke.mjs` now selects
consent v5 for `--profile=gemini-medium-standard`, including `--figure-view`/figure-detail. Verify ordinary/cached
answers, equation and figure actions, failure accounting, and recorded Google route/cost; these live checks have
**not run**. Then persist `chat_gemini: "on"` and publish the updated browser and native clients. Build 63 does not
understand Flash and deliberately retains its old default. Hiding/off is the rollback; do not leave only a one-off
CLI override that a routine deployment would revert.
