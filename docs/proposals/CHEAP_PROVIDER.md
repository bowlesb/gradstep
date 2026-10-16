# A cheaper chat provider (DeepSeek or similar) — proposal, 2026-10-14

> Historical proposal, superseded: DeepSeek integration and the owner's later intelligence-per-dollar research
> direction are recorded in [CHAT.md](../architecture/CHAT.md) and the
> [2026-10-16 model comparison](../reviews/MODEL_COMPARISON_20261016.md). The implementation status, prices and
> recommendation below describe the earlier checkpoint, not the current product.

Owner question (2026-10-14): "do we have a cheap high-value AI provider like DeepSeek as an option?" Answer today:
no. Every answer, title, follow-up and study-map update goes to Anthropic; the cheap tier is Claude Haiku 5.5, which
the model picker already offers. This note says what adding a second provider would take, so the decision can be
made on facts. Nothing here is built.

## What exists

- One provider adapter (`supabase/functions/_shared/anthropic.ts`): streaming, the price card, holds and per-attempt
  ceilings, fallbacks, usage pricing. The chat profiles (`chat-profiles.ts`) name Anthropic models only.
- The reader's consent text (both clients, `cloud-ai-v2`) names Anthropic and Tavily. The privacy architecture
  ([PRIVACY_AND_SYNC.md](../architecture/PRIVACY_AND_SYNC.md), [DATA_HANDLING_AND_COSTS.md](../architecture/DATA_HANDLING_AND_COSTS.md))
  records what each provider receives: the paper's text, the selected passage, the question and earlier turns.
- Provider accounting (`provider_attempts`, migration 034) admits attempts per provider and route with a ceiling, and
  the platform budget pauses on any overrun. Providers are an enum (`anthropic`, `tavily`, `mathpix`, `google`).

## What it would take

1. **Adapter.** DeepSeek serves an OpenAI-compatible chat API (streaming, tool calls, prompt caching with its own
   accounting). A second adapter behind the same `generate`/`streamChat` contract: SSE parsing, tool-call forcing
   for the title, follow-up and study-map requests, usage extraction, request ids for reconciliation. About a day.
2. **Pricing and holds.** A price card and rate version for the new models; holds sized with the same
   one-token-per-byte estimate (DeepSeek's tokenizer differs from Anthropic's; the margin must be checked against
   real usage before the ceiling can be trusted, because an underestimate pauses the platform, as happened on
   2026-10-14). Half a day plus a measured run.
3. **Accounting.** The provider enum and route validation in SQL (`worker_provider_attempt_begin`), the pricing
   snapshot, the dashboard's provider breakdown. A migration. Half a day.
4. **Profiles and the picker.** A fourth model entry (for example "DeepSeek · fast") with effort and length
   estimates in the published profile table, so both clients show it without a build. Half a day.
5. **Consent and privacy.** A new consent version naming the provider; the consent sheet copy on both clients; the
   data-handling doc. DeepSeek's API terms, retention period, training use and server location differ from
   Anthropic's and must be read and recorded before the first request. This is the part that needs the owner's
   decision, not an agent's. One day including the copy and tests.
6. **Quality evidence.** The live smoke (citations resolvable, follow-ups, the study tutor's protocol) and the
   corpus questions run against the new model, with the results beside Haiku's and Sonnet's. The tutor and the
   `[¶N]` citation discipline depend on instruction following; this is unmeasured for DeepSeek here.

Total: roughly two to three days plus the privacy review, if the answer is yes.

## Cost, order of magnitude

Anthropic list prices in the price card today: Haiku 5.5 $1 / $5 per million input / output tokens, Sonnet 5.5
$3 / $15. DeepSeek's published chat prices have been roughly an order of magnitude below Haiku per token, with cache
hits cheaper still. Verify the current card before quoting it to readers; this note deliberately gives no figure.
For a 27-page paper, today's Haiku answer costs about one credit and a Sonnet answer three to thirty; a provider
ten times cheaper than Haiku saves a fraction of a credit per answer, so the gain is in platform spend and headroom,
not in what readers pay (credits are already rounded to whole units).

## Alternatives worth weighing first

- **Haiku 5.5 as the default for Study and follow-ups** is already the cheap path; the tutor's answers run on the
  reader's chosen profile and could default to Haiku for study turns. No new provider, no consent change.
- **An aggregator (OpenRouter) with provider pinning** gives one adapter for many models, at the cost of a third
  party seeing every request. Same consent work, more models.
- **A local model** is the owner's direction for PDFs; for chat it is a later question.

## Recommendation

Do not add a provider for cost alone this month: the platform spends about $0.13 per Sonnet answer on a 47k-token
paper and the Study tutor's whole three-turn run cost 31 credits. If the owner wants a cheaper tier for readers,
make Haiku 5.5 the default profile for Study and compare quality with the live smoke first. Add DeepSeek only after
the privacy terms are read and accepted, as a profile the reader chooses, never the default.
