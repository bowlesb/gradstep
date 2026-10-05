# Paid AI chat

Status 2026-10-05: deployed to staging and verified live (API smoke and the Simulator journey: consent, streamed paid answer with typeset math, relaunch). Ingest verified live through the API (DPO passage citing PPO → arXiv 1707.06347 queued, 26 credits); its Simulator path is covered by unit tests only.

## Contract: `POST functions/v1/chat`

- Auth: user JWT verified in the handler (`verify_jwt = false`, `userClient`); RPCs run as service role. Origin/method/auth failures are HTTP JSON `{code}`; after authentication every outcome is `200 text/event-stream`.
- Body (strict, unknown keys rejected, ≤ 512 KiB raw): `{operation_id: uuid, consent_version: "cloud-ai-v1", mode: "paper"|"general", document_id?: uuid (paper only), messages: [{role: "user"|"assistant", text}] (1–60, first and last user, non-empty, ≤ 200,000 UTF-8 bytes total), selection?: {quote ≤ 4,000 Unicode scalars}, action?: "ingest" (requires selection)}`.
- Events: `delta {text}`, `done {stop_reason, credits, usage}`, `error {code}` with codes `insufficient_credits`, `platform_budget_exhausted`, `rate_limited` (route limit or 3 active operations), `document_unavailable`, `provider_unavailable`, `refused`, `invalid_request`, `operation_replayed`, `service_unavailable`. Comment lines (`: ping`) every 15 s keep idle connections open.
- Order: `worker_consume_request(account,'chat')` → validate → paper context (`worker_chat_context` → Storage `standalone.mmd`, ≤ 2 MiB, strict UTF-8) → hold → `worker_reserve_operation` → stream → `worker_settle_operation` → `worker_record_provider_usage` → final event.

## Provider request

`@anthropic-ai/sdk` 0.131.0 (`npm:` import map entry and root `package.json`). Model `claude-sonnet-5-5`, `max_tokens` 8,000, adaptive thinking at effort `low` (the model guidance for chat; it skips thinking on simple turns and keeps time-to-first-token and cost low), thinking display omitted. Server-side refusal fallback `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`); for this model it retries `cyber`/`frontier_llm` declines on Claude Sonnet 5, which matters for an ML-paper reader. Final `stop_reason: "refusal"` becomes `error refused`. System prompt = short instructions (cite sections/equations, LaTeX with `\( \)`/`\[ \]`) + `<paper title>` MMD block with `cache_control: ephemeral` (cached prefix). The selected passage is a separate text block before the last question. One SDK retry; a 130 s generation deadline leaves time to settle inside the Edge wall-clock limit.

## Ingest (selection action)

The existing Ingest action ("Find and add the paper referenced in this passage") sends `action: "ingest"`. Only then
does the request carry one client tool, `add_paper {title, year?, arxiv_id?}`, plus instructions to identify the
referenced paper (using the paper's bibliography for in-text citations) and call the tool once. It stays a single
provider call, so the hold and settlement are unchanged (the tool schema counts toward the hold).

After settlement the server validates the tool input strictly, searches arXiv by title through the shared arXiv
pacing (optional id lookup, oldest-first title phrase, then all title words; stops at the first clear match) and
accepts only a strict title match (token F1 ≥ 0.9, or an exact main title of 3+ words before a colon). It then calls
`v2_begin_import` **as the user** (their JWT, current library head as the observed cursor) — exactly the app's Add,
so the normal conversion, credit holds and quotas apply. At most one paper per request; the result is appended to
the answer as inert text (`Added “…” (arXiv:…)`, not found, or could not be added). A `tool_use` stop is reported
as `end_turn`. The app refreshes the library when an Ingest answer completes. Paper text could steer the model to a
different title (prompt injection); the bound is one title-matched arXiv paper per explicit Ingest, which the reader
can cancel in the Library.

## Money

Rate version `beta-credits-v1`: credits = ⌈micro-USD / 5,000⌉ (1 credit ≈ $0.01 at 2× provider cost).

| Model | Input | Cache write 5 m / 1 h | Cache read | Output ($/MTok) |
|---|---|---|---|---|
| `claude-sonnet-5-5`, `claude-sonnet-5` | 2 | 2.50 / 4 | 0.20 | 10 |
| Any other serving model | 4 | 5 / 8 | 0.40 | 20 |

- Hold = ⌈prompt characters / 3⌉ tokens at the 5-minute cache-write rate + 8,000 output tokens. Request digest = SHA-256 of a fixed-key-order canonical body (`\x<hex>`).
- A replay (`replayed: true`, any state) never calls the provider or settles; it returns `operation_replayed`. Reserve errors never settle. An ambiguous reserve transport failure is logged by operation ID for reconciliation.
- After a hold, settlement happens exactly once on every path (success, refusal, provider error, deadline, client disconnect). It retries only ambiguous transport failures, with identical amounts (the RPC is idempotent for equal amounts). Settled amounts never exceed the hold; overruns settle at the hold and log `chat_usage_exceeded_hold`. Recorded provider usage keeps the true estimate.
- Usage: final `usage.iterations` (per serving model, fallback included) or top-level usage. Without final usage: input from `message_start` and output = max(visible chars / 3, 100 tokens per elapsed second), capped at `max_tokens`. A typed HTTP rejection before `message_start` is unbilled. A lost connection before `message_start` charges the input estimate at the uncached rate. Estimates are marked `estimated: true` in `worker_record_provider_usage` units (event ID = message ID, else `operation:<id>`).

## Privacy

- Plaintext leaving the device per answer: the question, earlier turns of that branch (bounded as above), an optional selected passage and, for paper chat, the paper MMD that the server already holds. Prompts are built on the device from decrypted history; nothing else (notes, other chats, keys) is sent.
- The function stores no chat text: no tables, queues or logs. Logs carry only event names, operation IDs, counts and codes. The answer returns to the device, which seals it with the existing encrypted append path.
- Anthropic processes and may retain request content under its API terms; no zero-retention claim is made. Consent copy says so.
- First-use consent is per environment/account in the device Keychain (`<env>.<account>.cloud-ai-consent` = `cloud-ai-v1`), not in chat history. The question is saved locally first; consent then binds the request to that saved turn. Declining keeps the question and offers “Get answer”.

## Native behavior and failures

- After the user message commits, `ReaderModel` captures the turn (session, account, device, composer, conversation, document, message ID, selection quote) and streams via `BackendClient.chatStream` (configured host only, bounded 2 MiB stream, bounded SSE parser in ScienceReaderCore). The streaming row uses the pre-allocated assistant ID, so sealing replaces it without a row change. A thinking placeholder shows only before the first token.
- Seal: `.complete` for `end_turn`/`stop_sequence`; `.interrupted` for `max_tokens`, Stop, transport loss, provider error or EOF without `done`; nothing for empty output or refusals (partial refusal text is discarded). Errors are inline per composer with Try again; controls are restored.
- Ownership: generations are keyed by composer and checked against the account session. New chat, history or paper switches leave the answer fenced to its own conversation (it is sealed there; it never renders elsewhere). Sign-out/account change cancels all answers and keeps non-empty partials as interrupted turns in the old store before it retires. Releasing the stream cancels the HTTP request; the server then aborts the provider and settles.
- Settings shows `v1_credit_balance()` (available, held).
- `--chat-fixture` (Debug Simulator only, implies the durable draft fixture) replaces the transport with scripted answers; `--chat-fixture-mode=answer|slow|interrupt|insufficient_credits|refusal`; `--chat-fixture-consented` pre-accepts in-memory consent.

## Open items

UI journeys for Stop and Ingest; formulas SwiftMath cannot typeset fall back to LaTeX source; long papers raise the per-question hold (context is the whole MMD). The stale-hold sweep exists (migration 015).
