# Local AI prototype


## Mac-only runtime and retirement — TestFlight 73; replacements not yet qualified

The owner's new direction supersedes the phone prototype below. Local answering models and their MLX runtime,
Metal resources and model catalogue are excluded from iPhone/iPad targets. The iOS stub only preserves historical
answer/cache identities and refuses explicit old local turns without a cloud fallback. It retires the app-owned
public weight cache. The separate on-device PDF extraction pipeline remains available.
Build 73 is available in internal TestFlight on both platforms; the signed iOS archive passes the runtime/resource
exclusion guard, and the signed Mac archive contains an empty answering-model catalogue. Replacement models below
remain evaluation inputs, not released choices.

The Mac candidates are pinned in `tests/local-ai/candidates.json`; they are evaluation inputs, not approved app
choices. Qwen 3.5 9B and Gemma 4 12B each completed 27 scientific cases from five pinned papers with network denied.
Neither is qualified: DPO gradient errors and unsupported numerical plot claims remain. Gemma's measured image
process footprint reached 17.2 GB, excluding it from the proposed 16 GB tier. Qwen 3.8 27B and Gemma 4 26B A4B
are larger candidates; no successful native inference is claimed for them yet. The four old small models are retired from the Mac catalogue; no unqualified replacement is downloadable.
Their app-owned weight folders are removed, while stable identities keep old encrypted answers readable. Do not substitute model-card scores for this acceptance.

The evaluation found and repaired application defects: retrieval omitted a specifically requested source
formula (explicit equation references now prioritize it and its neighbors), and Foundation hash buffers could
accumulate while verifying large weights (each chunk now has its own autorelease pool). Qwen 9B's repeated direct
checks after those fixes use about 7.0–7.6 GB process memory; its DPO answer still reverses the loss argument and
miscomputes the derivative, so the model remains unqualified. Reasoning-enabled trials also failed; bounded
thinking is experimental and disabled in the current candidate comparison.

Current execution: 6,144 input tokens, one bounded figure, tokenizer-verified selection, independent output cap,
one generation at a time, and no inference networking. Mac admission checks physical capacity, reclaimable
headroom, Metal's recommended working-set limit and normal memory pressure immediately before loading. An unknown
or insufficient reading refuses locally. Trial evidence includes exact executable/model/source hashes, real
latencies, process and MLX memory and retained failures under `.artifacts/local-ai/mac-eval*-20261018/`.

The pinned Qwen 3.8 27B download is verified (16,081,488,731 bytes). Two native admission checks on the 32 GB
M1 Max refused **before loading weights**: about 13.46 GB reclaimable versus 21 GB required for text or 23 GB for
an image. These are unavailable-memory results, not inference or quality failures. The owner has been asked
whether to free memory or use a roomier Mac. Other applications/containers were not closed, and admission limits
were not lowered to force a run. Exact evidence: `mac-eval-large-admission-20261018/`; the probe now reports a
bounded error instead of crashing on an expected memory refusal. The requested two accepted Mac models remain
**unfulfilled** pending quality and memory evidence; publishing two names would misrepresent the measurements.

Mac integration tests also exposed a routing defect: a selection action created a new conversation and applied
the scenario default, losing the explicitly chosen local engine. It now carries both cloud profile and local
identity into that action. The local-PDF oversized-selection regression now rejects locally and makes no cloud
request; the complete affected chat-generation unit class passes (32 tests). This is independent of candidate
model quality. Old default identities remain explicit/unavailable rather than silently becoming paid cloud calls.

## Historical phone prototype and acceptance (superseded scope)

Status: the prototype and model-management feedback are included in TestFlight **70** on iOS and Mac, 2026-10-18. Earlier build-68 acceptance remains below. Physical-phone inference remains unverified.
The [measured comparison](../reviews/LOCAL_AI_20261017.md) retains failures: no model passed all scientific checks.

Owner request: offer Cloud AI (credits) or Local AI (an explicit model download) for chat, equations and figures.
The follow-up asks to compare Qwen3.5 4B with Gemma 4 E2B on scientific figures and captions, keeping context and
iPhone memory in mind. Qwen3 0.6B remains a small text-only baseline; it cannot interpret a bitmap.

## Inputs and context

Use the existing verified reader bundle: exact source LaTeX, numbered paragraphs, captions and one relevant figure
bitmap. This adopts the owner's crop-plus-text recommendation without reintroducing Mathpix or server PDF processing.
The arXiv HTML and device-PDF acquisition decisions remain. No whole-PDF images, cloud OCR, new service or migration.

Build each local request afresh. Keep the current question and selected equation/caption first, then nearby and
lexically relevant numbered paragraphs and a bounded recent conversation. Preserve original paragraph numbers.
Do not silently clip an equation or a question. Count with the selected model's actual tokenizer, reserve output
tokens, and reject oversized mandatory input. Start at a 4,096-token total budget, at most 1,024 answer tokens and
one image resized within 1,600² and at most 1,024² pixels. Reserve 1,100 input tokens for the image. Check the processor's final token count, including image tokens,
before generation. Omitted context is disclosed; the model must say when the supplied evidence cannot answer.

## Execution and UI

The native Apple prototype uses MLX Swift, pinned package versions and pinned 4-bit model revisions. Models are
downloaded only on request, with byte progress, cancellation, disk checks, SHA-256 verification, atomic completion
and removal. Model weights are shared public resources excluded from backup; prompts and answers are never placed
in that directory. Tokenizers load only from the verified local directory. No inference-time network fallback.

Cloud keeps its existing consent, account admission and credit accounting. Local invokes no cloud transport,
credit balance request, search, remote title/suggestion generator or billing operation. Retain encrypted local chat
storage and the current account/session fences. Existing encrypted synchronization is separate from inference;
local means no AI provider receives the question. A stopped or superseded local generation cannot write to a new
account or paper. No KV cache is shared across requests. Run one inference at a time and release its model/cache
afterward; cancel when the owning action is closed, the account retires or iOS leaves the foreground. A 120-second
deadline emits a visible failure and cancels the job. A registration epoch fences cancellation before a task is
registered. On iOS, check `os_proc_available_memory()` before offering use and again before loading. Downloads
are independent of transient free memory and are managed in Settings → Local models:
conservative additional headroom is 1.8 GB (0.6B), 4.8 GB (2B), 8.0 GB (4B), 8.5 GB (Gemma). These are admission
bounds informed by Mac process footprint, not a guarantee against jetsam. Build-69 feedback exposed that the old
picker disabled downloads using these execution limits, with no useful explanation. Downloads are now separate;
the picker shows the actual available/required app memory when a downloaded model cannot run. The current distribution profile does not grant
`com.apple.developer.kernel.increased-memory-limit`, and the app retains its existing signed configuration. The
public ASC API does not expose this additional capability; developer-portal access was unavailable. Enabling it
requires a portal/profile update and still would not promise a particular limit or establish safe 4B phone inference.
Apple documents it as a request on supported devices, not a fixed RAM guarantee:
[entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit),
[DTS provisioning explanation](https://developer.apple.com/forums/thread/685084).

The picker names the selected model and its modality. The text-only baseline refuses image questions instead of
pretending it saw a figure. Initial local explainers can return ordinary formatted prose in the existing fallback
view; structured symbols and model-proposed crop boxes are not promised. Study's structured tutoring map and cloud search/ingest tools are outside the
local prototype. No automatic escalation from local to cloud. Browser MLX support is not implied.

Capture the chosen engine/model with a submitted turn, so changing the next question's choice cannot reroute a
retry or Stop. Local requests carry a non-encodable marker, including general chat with no paper. Local explanation
cache keys include the model revision and cannot be mistaken for cloud answers. A saved asset remembers its local
model choice and opens its encrypted cached answer without needing the model download again.

## Comparison and acceptance

Qwen's official 2B card reports thinking/non-thinking results: MathVista 76.7/73.9, AI2D 83.3/81.5 (84.9 belongs
to the Qwen3-VL-4B comparison column), OmniDocBench 79.8/80.9, MMMU 64.2/64.2. The 4B card reports MathVista 85.1,
AI2D 89.6, OmniDocBench 86.2 and CharXiv reasoning 70.8. These are lab results, not our 4-bit mobile measurements.
Google reports Gemma E2B as 2.3B effective / 5.1B including embeddings; its OmniDocBench metric is edit distance,
so do not compare it numerically with Qwen's higher-is-better score.

Sources checked 2026-10-17: [Qwen 2B](https://huggingface.co/Qwen/Qwen3.5-2B),
[Qwen 4B](https://huggingface.co/Qwen/Qwen3.5-4B),
[Gemma 4](https://ai.google.dev/gemma/docs/core/model_card_4),
[MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm).

Compare the same figure crops, captions and paragraphs: axes/units, legend/panel association, numeric trends,
mechanism diagrams, and an unanswerable question. Separate visual evidence from caption paraphrasing. Record exact
model revision/quantization, prompt and image budget, time to first text, total latency and peak process/MLX memory.
Mac measurements do not establish iPhone performance. Physical iPhone testing remains paused. Simulator checks
cover choice/download/cancellation and routing using deterministic inference; actual Metal inference runs on Mac.

Required regressions: mandatory-input overflow, paragraph relevance/numbering, image-token bounds, corrupt and
interrupted downloads, no cloud calls on local paths, account switch and cancellation, local/cloud cache separation.
Run affected native journeys and routine fast checks before claiming the prototype usable. Publish only evidence
for the tested configuration; phone acceptance remains separate.

## Recorded acceptance, 2026-10-17

- `npm test`: passed (routine fast tier; no paid provider calls).
- ScienceReaderCore: 340 Swift Testing + 23 XCTest cases passed. Final focused context suite: 7/7, including
  oversized mandatory input, bounded tokenizer work, original paragraph IDs, local/cloud cache identities and
  non-encodable local requests. Unsupported search/ingest/repair/structured-study actions explicitly fail locally.
- Model store: 4/4 tests passed. An unfinished download cannot install; same-size corruption fails hashing;
  removal is scoped to the selected model; the catalog pins each file. The real Qwen2B download through the same
  store also completed and verified. A real mid-download cancellation journey on a phone is not claimed.
- Native regression: 35 chat/lifecycle tests + 8 affected UI journeys passed (`native-final.xcresult`). This includes
  cloud behavior and local explanation persistence. Final local acceptance: 7 unit cases + 3 UI journeys passed
  (`native-acceptance.xcresult`), including a local-PDF item with a verified bundle, one figure, no arXiv/cloud
  context, no cloud call and an encoding refusal. The fixture exercises routing; it does not rerun PDF extraction.
- Final error-path regression passed (`local-errors.xcresult`): an oversized local selection is rejected as
  `local_context_large`, non-retryable, without a cloud request. Review found the shared request-builder catch
  had been collapsing this specific rejection into `invalid_request`; it now preserves the actual rejection code.
- iOS Release and Mac Catalyst compile with the MLX Metal resource in the actual app bundle. Actual inference
  used the optimized Mac probe; the Simulator uses a deterministic inference seam compiled only into `FIXTURE_HOST`.
- All four local models produced real answers on Mac. Network-denied Qwen4B/Gemma/2B/0.6B checks completed.
  No phone inference, thermals, battery or jetsam acceptance. The qualitative failures are retained in the review.

All inference logs, result bundles and raw model outputs are under `.artifacts/local-ai/`. The prototype is in
TestFlight 68 on iOS and Mac, both VALID / IN_BETA_TESTING as of 2026-10-17 15:08 UTC. Release source `12d5552`;
the source-matching import/session gate passed 13/13 with no skips before upload. Both signed archives contain
the pinned model catalog and MLX Metal resource, with no downloaded weights. Release evidence is under
`.artifacts/release-68/`. This is internal beta availability; physical-phone inference remains unverified.

## Build-69 feedback implementation, 2026-10-18 (TestFlight 70)

The choice starts with Use default, Cloud, Local. Cloud shows actual model names; Local shows downloaded models
compatible with the action, with an explicit reason when current memory prevents use. Settings → Local models
allows downloads/removal in advance, publishes measured Mac performance and license links, and says physical
iPhone inference is unverified. Settings also selects the default cloud/local engine. A local default missing its
weights or memory does not silently run a cloud request. Names end in “(local)”; no redundant Cloud AI strip.

Equation and figure follow-ups now use the same encrypted chat implementation underneath the explanation. They
retain the equation/caption and bounded previous explanation, preserve the main chat's unsent draft, and continue
using the engine selected in that view. The deterministic Simulator fixture verifies routing/persistence; it does
not establish phone speed or memory acceptance.
