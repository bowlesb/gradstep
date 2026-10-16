# Data handling and cost explanation

2026-10-13 verified staging direction: every PDF is downloaded/processed only on the device,
initial structured preparation uses arXiv HTML without an OCR charge, and a future local model has no Mathpix
fallback. Explicit paper chat still sends necessary text to cloud AI under the existing consent and metering.
[HTML-first reader](HTML_FIRST_READER.md) defines the exact boundary. Native/browser explainers now describe the enforced boundary; historical usage and outstanding OCR reservations remain accounted for.

Status: owner-requested product explanation, 2026-10-09. This document is the source for the short
**How Gradstep works** screen in the native and browser clients. It is explanatory product copy, not a
provider privacy guarantee or a substitute for the applicable privacy policy and paper licences.

## The data paths

Gradstep separates local paper storage, encrypted synchronization and requested AI processing:

- Library metadata, tags and encrypted chat events can sync through Supabase. Chat and note
  content is encrypted before synchronization; device-held keys or the recovery code are needed to read it.
- New PDF downloads, intake, viewing and processing happen only on the user's device. Exact official arXiv HTML
  is compiled locally into the structured reader. Historical server copies remain retained; no data migration or
  broad deletion occurred. Browser PDFs stay in the selected device file/tab and must be chosen again after reopening.
- A paper chat sends the question, selected passage, conversation context and verified reader text to the chosen
  cloud model under explicit consent. Stored-history encryption does not hide requested computation from that provider.
  Since 2026-10-16 the chosen model may be DeepSeek's (consent `cloud-ai-v4` names it): DeepSeek then receives the
  answer's request, including any figure image, while Anthropic's Claude Haiku still writes the chat's title and
  suggested follow-up questions from the question and a short excerpt.
- A future local PDF model is not installed yet. There is no Mathpix fallback or OCR charge for local HTML preparation.
- Optional web search sends search queries to the configured search provider. Provider retention and handling
  follow that provider's terms; Gradstep does not promise zero provider retention.

## The cost paths

A credit is a Gradstep usage unit, not cash or a provider's own credit. Before paid work begins, the server
quotes the expected and maximum usage and reserves a bounded amount. It settles the actual measured provider
usage afterward. Operation identities make retries and lost responses idempotent, so one request is not charged
twice because a network acknowledgement was lost.

**When work stops early (owner decision 2026-10-16).** The reader pays for work that finishes, or for the part of an
answer they chose to stop. If the provider fails or overloads partway, our server fails, an answer reaches our own time
limit (130 s) or length limit, the connection between our server and the reader drops, or the model refuses, the reader
is charged nothing: their hold is released and any text already shown stays theirs. Gradstep still pays the provider
for that work, and records it as absorbed cost in the month's provider spend and on the admin's Health tab; it counts
against the same budget and is never hidden. A title, suggested questions or a study-map update that could not be
delivered is Gradstep's cost too. Podcasts already charged only for a ready episode or the used part of one the reader
canceled. Definitions for each paid feature: [CHAT.md](CHAT.md#when-an-answer-stops-early--2026-10-16).

Chat, search and podcasts have separate provider attempts, limits and accounting. Ready-made catalog podcasts avoid repeating provider work. Historical OCR charges remain in the ledger. Customer credit accounting, provider
expense, platform budgets and unresolved provider liability remain separate records. Account and platform gates
stop a user, retry loop or provider outage from creating an unlimited bill.

The measured cost of a chat depends on paper and conversation size, cached context, model, effort, answer length,
tools/search and the tokens actually used. The user sees the profile's estimate and maximum before generation,
then the final credit charge afterward.

## Current model policy

The current chat profiles are server-enforced:

- **Haiku** is the fast, lower-cost choice for simpler work.
- **Sonnet** is the default balance of quality and cost.
- **Opus** is reserved for harder reasoning.
- **DeepSeek** (DeepSeek V4.1 Flash, `deepseek-flash`, since 2026-10-16 on staging): a low-cost model from another
  provider, offered only when the reader chooses it under consent `cloud-ai-v4`, priced at DeepSeek's peak list rates
  and admitted, recorded and circuit-broken as provider `deepseek` (docs/architecture/CHAT.md "DeepSeek in chat").
  It passed a recorded check on DPO (equations, citations, a figure question, visual tools) before it was offered. At
  list prices Claude Haiku 5.5 is still the cheapest per token; DeepSeek sits between Haiku and Sonnet.

Effort is chosen by the server for each question when the client asks for `auto` (new clients do): low for Brief,
medium for Standard questions that ask for reasoning or carry an equation or figure, high for Detailed reasoning
questions. The quote and the answer record the effort used.

The server records the model that actually answered, including an approved fallback. A cheaper provider is not a
drop-in replacement for scientific reading. Before adding DeepSeek or another provider, we must compare equation
and citation quality, long-paper grounding, privacy/retention terms, latency, structured tool behavior and actual
measured cost on representative journeys. Price alone is not a sufficient launch criterion.

## DeepSeek comparison (research only; not a routing decision)

The current official DeepSeek API page lists `deepseek-flash` (DeepSeek-V4.1-Flash) at **$0.15/M input,
$0.60/M output and $0.003/M cache-hit input off-peak**, rising to **$0.30/$1.20/$0.006** at peak. Its
`deepseek-v4-pro` rates are **$0.66/$1.98/$0.022** off-peak and **$1.32/$3.96/$0.044** peak. Peak windows,
model names and prices can change; these figures were read 2026-10-09 from the [official DeepSeek pricing page]
(https://api-docs.deepseek.com/quick_start/pricing/).

The deployed Gradstep tariff for Sonnet 5.5 is $2/M uncached input, $10/M output and $0.10/M cache-read input.
Against that card, Flash is approximately **13.3× cheaper on uncached input and 16.7× cheaper on output
off-peak** (about 6.7× and 8.3× at peak). V4 Pro is approximately **3× cheaper on input and 5× cheaper on
output off-peak**. These are token-rate comparisons, not a quality-adjusted product cost; a different tokenization,
longer answer, extra validation pass or fallback can erase part of the apparent saving. Anthropic's current
[official pricing documentation](https://platform.claude.com/docs/en/about-claude/pricing) describes the
Sonnet cache-read multipliers and the same token accounting principle.

**Update 2026-10-14:** DeepSeek is now enabled for one use only: writing podcast episode scripts, when the reader chooses it as the writer (docs/architecture/PAPER_PODCASTS.md; migrations 063–065). Chat does not use it.

**Update 2026-10-16:** chat may now use `deepseek-flash` too, when the reader chooses DeepSeek (owner request on
TestFlight build 57; migration 078). It is opt-in per chat, bounded by the same credit and provider-spend controls,
and was published only after the recorded check in docs/architecture/CHAT.md: on four DPO questions it typeset every
equation, cited only passages that exist, read a figure from its image and called the visual and figure-parts tools,
for $0.038 against $0.273 for the same questions on Sonnet. Its first text arrives later (8–23 s at medium effort). This comparison itself enabled no traffic. Any future trial must be opt-in at the server profile level,
bounded by the same credit and provider-spend controls, and accepted only after the quality and data-handling
review passes.
