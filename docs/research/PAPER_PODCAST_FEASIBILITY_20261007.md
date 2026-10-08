# Paper podcasts: feasibility and economics

Research date: **2026-10-07**. Research only: no implementation, provider generation, account purchase, credential access, or deployment. Prices are USD list prices checked against the linked official sources; calculated costs are assumptions, not observed bills or measured audio quality. This report does not authorize spending or expand the owner's $100/month incremental beta budget.

**Follow-up, 2026-10-08:** The owner now requests implementation planning for shared browsable episodes.
The current recommendation, reproducible pricing model and detailed schema/lifecycle proposal are in
[pricing](PRICING_RECOMMENDATION_20261008.md) and [podcast architecture](../architecture/PAPER_PODCASTS.md).
Those proposals supersede this report's tentative rollout/experiment choices: a zero-spend fixture/import
path first, then an optional $2 bounded seed run inside the existing $25 provider allocation, pending owner
acceptance. Migrations034–038 are deployed and the worker is request-billed; legacy reader delivery still
needs its bounded transition. No podcasts or revised offers are deployed by either document.

## Recommendation

**Practical and worth a small, metered experiment after the new audio paths integrate the cost controls.** Build an academically grounded script from the exact verified Mathpix artifact, review its factual claims, then synthesize speech. Compare Gemini 3.8 Flash TTS with OpenAI's GPT-4o mini TTS only after each adapter has an enforceable spend bound; optionally audition ElevenLabs later. Keep the provider behind an adapter and preserve the script independently of the audio.

Start with one paper, English, a five- or ten-minute explanation, a fixed pair of synthetic hosts, chapters, and a transcript whose citations open the relevant paper passage. One host is a useful lower-complexity comparison. A good two-host script can use an explainer and a skeptical reader, with substantive questions rather than filler. Exact quality parity with NotebookLM has **not** been demonstrated.

A clean ten-minute episode is approximately **$0.27** using the existing Sonnet model for script and review plus current Gemini Flash TTS pricing. A planning allowance for retries, audio transcription checks, and compute raises that to roughly **$0.38**, excluding fresh OCR, fixed platform allocations, taxes, and human review. Google's announced January 2027 speech rates raise those estimates to **$0.40 / $0.55**. The calculations below distinguish those assumptions from vendor tariffs.

Do not add automatic podcasts to every imported paper, unlimited regeneration, or bulk library conversion. Playback of a retained result does not require another model call.

## What is actually available

| Route | Evidence and limits | Suitability |
|---|---|---|
| Google's standalone Podcast API | Official documentation says **deprecated; no new customer allowlisting**. Previously accepted up to 100,000 context tokens, returned MP3 through an asynchronous operation, and offered approximately 4–5 or 10 minutes. | Exclude from a new product dependency. [Podcast API](https://docs.cloud.google.com/gemini/enterprise/notebooklm-enterprise/docs/podcast-api), [deprecation record](https://docs.cloud.google.com/gemini/enterprise/docs/release-notes) |
| Notebook-linked Audio Overview API | Still documented as **Preview**. Requires a notebook and its sources; only one overview per notebook at a time. Generation takes minutes. | An existing enterprise notebook integration could use it, but this is not a verified customer-app embedding/resale contract. [Audio Overview API](https://docs.cloud.google.com/gemini/enterprise/notebooklm-enterprise/docs/api-audio-overview) |
| Gemini 3.8 Flash / Flash-Lite TTS | Publicly documented speech APIs; text input, audio output. Two prebuilt voices can participate in one request. Streaming is supported; unary output defaults to WAV. Custom voices require separate turns for multi-character dialogue. | Best initial dialogue candidate. Availability in our exact billing project has not been checked. [Speech guide](https://ai.google.dev/gemini-api/docs/speech-generation) |
| OpenAI GPT-4o mini TTS | Speech API with controllable delivery, streaming, built-in voices, and multiple languages; voices optimized for English. A request selects one voice. Model page gives a 2,000-input-token ceiling. | Good narration and cost comparison. Two hosts require separate turns and audio assembly, with more continuity work. [Speech guide](https://developers.openai.com/api/docs/guides/text-to-speech), [model limits](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts) |
| ElevenLabs Text to Dialogue | Current guide supports Eleven v4 and v3. Recommends at most 2,000 combined text characters per request for reliability; longer material is assembled from chunks. API regenerations are billable; dashboard-only free regenerations do not apply. | A useful expressive-dialogue comparison, at a higher ordinary rate. [Dialogue guide](https://elevenlabs.io/docs/overview/capabilities/text-to-dialogue) |

Notebook Enterprise is advertised at $9/license/month with at least 15 licenses: **$135/month before other charges**. Its sharing model is project-internal and does not permit separately sharing an audio overview through its normal sharing feature. This exceeds the entire beta budget and is not evidence of permission to sublicense the product to arbitrary Gradstep subscribers. Consumer NotebookLM subscriptions should not be treated as an application backend API. [Enterprise price](https://cloud.google.com/gemini-enterprise/gemini-notebook), [licensing](https://docs.cloud.google.com/gemini/enterprise/notebooklm-enterprise/docs/set-up-licensing), [sharing boundary](https://docs.cloud.google.com/gemini/enterprise/notebooklm-enterprise/docs/overview)

Gemini's current model pages specify 8,192 input and 16,384 output tokens for both TTS models. At Google's documented 25 audio tokens/second, the output ceiling represents approximately **10.9 minutes**, not an unlimited episode. A twenty-minute episode needs multiple calls; even ten minutes should use chapters to leave room for pauses and repair. Flash lists 130 languages; Lite lists 101. These are vendor-supported languages and advertised capabilities, not tested academic pronunciation quality. [Flash model](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts), [Lite model](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-lite-tts), [audio token rate](https://ai.google.dev/gemini-api/docs/pricing)

No source reviewed supplies a dependable end-to-end latency for our ten-minute paper workload. Measure script time, review time, first playable chapter, and complete validated episode separately. Streaming improves time to first audio; it does not establish completion time or factual accuracy. Provider concurrency/quotas must be checked on the actual accounts. Google's quotas are project-scoped, can change with billing tier, and are not a substitute for our own budget. [Gemini limits](https://ai.google.dev/gemini-api/docs/rate-limits)

## Cost model

Assume an already-converted paper with **20,000 source tokens**, 150 spoken words/minute, approximately 900 text characters or 200 text tokens/minute, and normal speech without music. These are planning assumptions. Equations, pronunciation expansions, languages, and pauses change them. One or two hosts cost approximately the same at the **same total generated duration**; alternating hosts does not inherently double duration.

Use two script passes initially: draft and factual review, each reading the paper. For an episode with `S = 200 × minutes` spoken-text tokens, assume `44,000 + S` total input tokens and `S + 2,000` total output tokens across both passes. The extra output includes planning, review, and limited reasoning; actual thinking must remain explicitly bounded. At the project's current Sonnet 5.5 prices, $2/M input and $10/M output, this is **$0.120 / $0.132 / $0.156** for 5/10/20 minutes. No prompt-cache discount, web search, separate multimodal figure pass, or full rewrite is assumed. [Sonnet pricing](https://platform.claude.com/docs/en/models/sonnet-5-5/overview)

| Speech engine | Ordinary input tariff | Audio/output tariff used here |
|---|---:|---:|
| Gemini 3.8 Flash TTS, through Dec 31, 2026 | $0.50/M text tokens | $9/M audio tokens = $0.0135/audio minute |
| Same, from Jan 1, 2027 | $1/M text tokens | $18/M audio tokens = $0.027/audio minute |
| Gemini 3.8 Flash-Lite TTS, current / Jan 2027 | $0.50 / $1 per M text tokens | $6 / $12 per M audio tokens = $0.009 / $0.018 per minute |
| GPT-4o mini TTS | $0.60/M text tokens | $12/M audio tokens; minute conversion below is provisional |
| ElevenLabs v4 or v3, ordinary published API rate | Billed by text characters | $0.08/1,000 characters = $0.072/minute under the text-density assumption |

[Google tariffs and dated promotional expiry](https://ai.google.dev/gemini-api/docs/pricing), [OpenAI tariffs](https://developers.openai.com/api/docs/pricing), [ElevenLabs API tariffs](https://elevenlabs.io/pricing/api). ElevenLabs currently advertises a v4 promotion ending October 12; do not design lasting allowances around it. Its pricing page offers pay-as-you-go and subscriptions. Commercial entitlement on the exact chosen plan must be confirmed; do not substitute the free plan or older subscription-overage prices for the current API tariff.

The OpenAI row below assumes **1,250 output audio tokens/minute**, giving an illustrative $0.015/minute before input. The official page retrieved establishes token rates, **not a guaranteed per-minute price or this token density**. This row is a sensitivity estimate to validate with usage/billing; it must not become a fixed quote. At 2,000 audio tokens/minute instead, its ten-minute clean total would be approximately $0.37. OpenAI `tts-1` provides a character-priced fallback benchmark at $15/M characters, approximately $0.135 speech/$0.267 total for ten minutes here, but it is not a proven substitute in dialogue quality. [OpenAI pricing](https://developers.openai.com/api/docs/pricing)

**Calculated clean generation cost: script + review + speech.** Add 500 text tokens of speech directions per episode to token-priced speech engines. Chunk-specific duplicated context could increase that amount.

| Route | 5 minutes | 10 minutes | 20 minutes |
|---|---:|---:|---:|
| Gemini Flash, current | **$0.188** | **$0.268** | **$0.428** |
| Gemini Flash, Jan 2027 tariff | $0.257 | $0.405 | $0.701 |
| Gemini Flash-Lite, current | $0.166 | $0.223 | $0.338 |
| OpenAI mini TTS, provisional token-density assumption | ~$0.196 | ~$0.284 | ~$0.459 |
| ElevenLabs v4/v3, ordinary tariff | $0.480 | $0.852 | $1.596 |

These are calculated comparisons, not observed workloads. For three 20,000-token papers, the two script passes add 80,000 input tokens, or approximately **$0.16**, at the same episode length. A visual reasoning pass, extensive mathematical checking, or several repairs adds more. A cheaper script model may lower cost, but its factuality needs the same evaluation before switching.

Fresh Mathpix processing remains separate. Under the current pipeline tariff, a previously unconverted twenty-page paper adds roughly $0.10; three such papers add $0.30. Already-retained conversion means no new OCR charge. Owner-private conversions cannot borrow another account's retained OCR. The current tariff and reuse boundaries are documented in [paper pipeline](../architecture/PAPER_PIPELINE.md) and the [cost audit](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md); the provider's [Mathpix pricing](https://mathpix.com/pricing/api) should be rechecked when activating the feature.

## Full operating cost and heavy users

For a ten-minute episode, allow **25% of clean generation cost** for paid retries/repairs, approximately $0.01 for bounded runtime/handling, and $0.03 for an optional transcription comparison. The 25% is an expected-cost scenario, **not a sufficient worst-case money hold**. OpenAI's listed mini transcription estimate is $0.003/minute; transcription itself can misrecognize scientific terms and is not the factual judge. [Transcription pricing](https://developers.openai.com/api/docs/pricing)

This yields roughly **$0.38 Gemini Flash now, $0.55 at the announced January tariff, $0.40 OpenAI under its provisional assumption, or $1.11 ElevenLabs at its ordinary rate**, excluding new OCR, allocated fixed costs, tax, and human review. A complete remake costs nearly another clean generation; repairing one chapter is cheaper. Failed, rejected, or disconnected requests may still incur provider expense.

For infrastructure, consider these calculations rather than assuming it is free:

| Item | Calculated example |
|---|---|
| Compressed delivery | Mono 64 kbit/s is approximately 0.48 MB/minute: 2.4 / 4.8 / 9.6 MB for 5/10/20 minutes. 128 kbit/s doubles this. Quality at the chosen bitrate needs listening tests. |
| Retained catalog | 10,000 ten-minute files at 64 kbit/s occupy ~48 GB, approximately $1.02/month marginal Storage cost after included capacity. Originals, transcripts, temporary chunks, old versions, and backups are additional. |
| Playback transfer | One full ten-minute download costs ~ $0.00014 cached or $0.00043 uncached at marginal Supabase rates. 100,000 such downloads transfer ~480 GB, or $14.40 / $43.20 before included allowances. Replayed signed URLs can multiply traffic. |
| Worker execution | Request-based Cloud Run at 1 vCPU/2 GiB for 60–300 billed seconds is roughly $0.0017–$0.0087 before free allowance, network, logs, builds, and registry. Request billing is now deployed; this duration/resource scenario is not a benchmark of its actual costs. |

Supabase Pro lists 100 GB Storage, and separate 250 GB cached/uncached egress pools; marginal rates are $0.0213/GB-month and $0.03/$0.09 per GB. These are organization resources, not fresh allowances for every feature. [Supabase pricing](https://supabase.com/pricing), [storage accounting](https://supabase.com/docs/guides/platform/manage-your-usage/storage-size). Cloud Run request-based active rates used above are $0.000024/vCPU-second and $0.0000025/GiB-second. [Cloud Run pricing](https://cloud.google.com/run/pricing)

The audit found instance billing at its original observation; that finding was subsequently repaired with
request billing. Keep configuration evidence, actual runtime observations and invoices separate. Do not add
an always-on worker, subscription or GPU. On October 8 the recorded provider budget was $25 with $13.677389
spent and $0 reserved; its $11.322611 remaining was an instantaneous provider allocation, **not whole-system
headroom** or authorization for new audio spending. See the [updated economics](PRICING_RECOMMENDATION_20261008.md)
and the historical [audit F1](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md).

Thirty new ten-minute episodes/month would cost roughly **$11.40 now / $16.50 after the January tariff** under the planning scenario. Sixty would cost **$22.80 / $33.00**. Add the audit's illustrative heavy reading/chat workload ($7.88) and that becomes **$30.68 / $40.88 before fixed infrastructure and other overhead**. This is not sustainable as unlimited use in a $19.99 plan.

Under the existing provisional conversion of one customer credit per $0.005 of provider-equivalent cost, a clean current Flash episode uses approximately **38 / 54 / 86 credits** for 5/10/20 minutes; January tariffs make these approximately **52 / 81 / 141**. This is not a final published rate card. Sixty ten-minute episodes would use ~3,240 credits even before normal reading/chat. Current Standard/Pro allowances are 800/1,800 credits; a podcast must consume that shared allowance or a deliberately priced additional allowance. Do not treat credit face value as cash revenue or ignore store commission, refunds, free repairs, retained storage, or support. [Current decisions](../DECISIONS.md), [credit economics](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md)

## Proposed implementation boundary

No schema change is proposed for execution in this report. Before implementation, review a small additive job/artifact design with ownership, retries, deletion, and reconciliation together:

1. **Source selection and quote.** Authorize access to exact document/artifact versions. Check whether this precise approved episode already exists. Bind a quote to sources, language, duration ceiling, voices, model/profile versions, credit ceiling, platform-dollar ceiling, retry allowance, and expiry.
2. **Reserve and enqueue atomically.** Reserve customer credits and platform liability before paid work. One durable operation represents the customer request; separate admitted attempts represent every actual provider POST, including script review, transcription, and repair. SDK retries must not create invisible paid calls.
3. **Create and validate a script.** Produce a structured script with stable chapters, speaker turns, and claim-to-source anchors. Review before synthesizing. Keep figures and equations linked to the reader. Fail usefully when the available conversion does not cover the relevant pages.
4. **Generate bounded chapters.** Use a fenced worker with a small concurrency limit, stable attempt IDs, persisted checkpoints, and explicit uncertain outcomes. A lost response is not proof of zero cost or permission to regenerate. Admission must reserve the enforceable provider maximum; a ten-minute prompt or stopping local playback is not a billing cap.
5. **Validate and publish.** Check expected chapters, format, duration, clipping/silence, source/script version, and hashes. Publish a manifest and compressed assets only after validation, then settle known usage and retain unresolved liability. A failed quality check and a customer refund do not erase provider expense.
6. **Deliver and recover.** The app can leave the screen and later retrieve durable job state. Realtime is a refresh hint; polling/catch-up recovers missed notifications. Downloaded episodes support offline playback and normal position persistence. Playback does not enqueue generation.

Supabase remains the authority for authentication, job state, spend reservations, ownership, and artifact authorization. Edge Functions suit short admission/status requests and network calls. Audio assembly/transcoding can run in the existing Cloud Run processing architecture with explicit lifetime/billing limits; a whole podcast must not rely on one fire-and-forget Edge invocation. Hosted Edge presently has 256 MB memory, two CPU seconds per request, 400 seconds paid-plan wall time, and a 150-second idle-response timeout. [Edge limits](https://supabase.com/docs/guides/functions/limits)

Initial product bounds could be one paper, five or ten minutes, one active episode per account, and two active speech calls across the beta. These are proposed limits, not provider quotas or deployed settings. Twenty-minute and collection episodes should follow successful measurements.

The hidden retry and unknown-provider-liability fixes are now deployed through034, and035–038 add asset,
identity, admin and purchase records. These do not automatically cover a new speech provider, route or bucket.
Current reader delivery retains replayable legacy URLs for compatibility; audio must start with bounded
delivery. A feature cap also consumes the systemwide budget; independent caps permit overspending. Count
variants, regenerations, failed generations, temporary storage and downloads. Admin must show actual versus
reserved cost, cost per accepted minute, quality losses, reuse, orphaned objects, byte transfer and rate version.

## Scientific quality and UX

Mathpix is a valuable source because the script can preserve section structure, equation identifiers, and references. It does not prove correct interpretation. A fluent explanation can be confidently wrong, and a second model review is only another check.

- Extract a compact evidence record for each important statement: paper/version, passage or equation/table anchor, reported numbers, experimental conditions, and the author's limitations. Review quantitative claims and comparisons against that record.
- Explain what an equation does and its assumptions; do not read raw LaTeX or silently replace a conditional theorem with a general assertion. Keep a pronunciation glossary for symbols, acronyms, author names, and model names.
- Describe figure findings only when supported by captions/data or a separately reviewed visual pass. A caption alone may not establish the trend the script wants to claim. Mark absent/unreadable evidence explicitly.
- Separate results, author interpretation, and the hosts' explanatory analogy. Avoid invented biographies, quotations, citations, dialogue with the actual authors, or implications that the authors endorsed the episode.
- Treat PDF text as untrusted source material, not instructions to change tools, safety, billing, or the script's evidence requirements.
- Preserve speaker identity, volume, pronunciation, and room tone across chapters. Crossfades must not remove phonemes; chapter repair should not remake unrelated audio. Numerical transcript comparison and listening are both needed.

In the app, one unobtrusive Listen action can offer a duration, a clear maximum credit cost, and an existing cached edition where available. During generation, show understandable stages and allow navigation away. The player should support speed, a sleep timer, chapters, offline download, and a transcript with citations into the paper. Prototype first; material navigation changes still need the user's review. The first version should offer explicit generation and error reporting, not autoplay or automatic background conversion of a library.

## Privacy, licenses, and reuse

Our current `owner_private` PDFs and their OCR are server-readable under account authorization; that is different from device-key-encrypted chats and notes. Start with paper-only episodes, without personal chats, notes, or reading history in the source. A private derivative stays inside the same account boundary and is deleted with it. Storage encryption and an authenticated URL do not make server-generated audio end-to-end encrypted. [Current privacy design](../architecture/PRIVACY_AND_SYNC.md)

If personal encrypted material is later included, design a separate bounded background-processing envelope and encrypted result delivery first. The device must explicitly select/decrypt the context; workers must not receive long-lived account decryption keys. Returning encrypted audio to a recipient key still leaves plaintext at the AI provider during processing. That future design must cover recipient changes, recovery, cancellation, logs, and deletion rather than quietly adding plaintext scripts to a queue.

Provider-specific facts and launch checks:

- **Google paid Gemini API:** Google does not claim ownership of generated content and does not use paid prompts/responses to improve products, but retains limited safety-related logs. The API has age/audience and region restrictions, including paid-service requirements for EEA/UK/Swiss clients. Confirm the exact route and audience before launch; no zero-retention or EU-only processing promise follows from using it. [Gemini terms](https://ai.google.dev/gemini-api/terms)
- **OpenAI:** the speech guide requires clear disclosure that the voice is AI generated; use built-in voices initially. The data-controls page lists speech requests as not used for training, with ordinary abuse-monitoring retention up to 30 days and eligibility—not automatic activation—for Zero Data Retention. Custom voices have separate eligibility/consent requirements. [Speech disclosure and voices](https://developers.openai.com/api/docs/guides/text-to-speech), [data controls](https://developers.openai.com/api/docs/guides/your-data)
- **ElevenLabs:** the dialogue guide ties commercial output use to a paid plan and rights in the input. Default retention is enabled; Zero Retention Mode is limited to eligible enterprise arrangements and configured API requests. Confirm voice-specific rights and the chosen pay-as-you-go commercial entitlement before using community voices. [Commercial use](https://elevenlabs.io/docs/overview/capabilities/text-to-dialogue), [retention](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode)

Provider permission to synthesize speech does **not** supply rights to redistribute a paper or its derived audio. CC BY 4.0 permits commercial adaptation with attribution, license information, identification of changes, and no implied endorsement; other rights and separately licensed material may remain. CC0 also permits commercial reuse but does not dispose of others' privacy/publicity or trademark rights. Preserve source provenance and check the exact approved material. Do not extend sharing to non-CC/private conversions or a mixed private collection simply because the output is a summary. [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), [CC0](https://creativecommons.org/publicdomain/zero/1.0/)

A reusable episode work key should bind the exact ordered source/version set, verified source-artifact hashes, legal approval scope, script/profile version, approved script hash, speech model/version, voice IDs, language, pronunciation profile, and codec settings. Separate the generation request identity from the final audio hash: probabilistic generation does not reproduce identical bytes on demand. Persist one winning result for identical authorized requests.

Sharing is allowed only for an approved, non-personalized shared derivative whose inputs all satisfy the sharing policy. Include the owner in private work identity; authorize before revealing even a cache hit. A title, DOI, arXiv ID, or coincidentally identical private PDF hash is insufficient authorization. Shared generation can follow the existing explicit first-funder rule, with waiters and no duplicate charge, or an independently budgeted platform-funded catalog. Decide which before publishing prices. Removing one membership must not erase a shared result others use; an account deletion must fence private generation and remove its private outputs, including late arrivals.

## Owner direction: browse prepared episodes (2026-10-07)

The owner especially values finding an episode that is already ready, without planning generation in advance.
Treat a shared, browsable episode catalog as a first-class product design requirement. This expands planning,
not authorization for new paid generation, public publishing, or a new subscription. Detailed schema and UX
review precede implementation; the current spending-control work remains first.

Separate three identities: an eligible source/version and approved episode profile; an immutable generated
episode release with its transcript, evidence and audio; and each listener's private membership, download and
playback position. Generation jobs and first-funder receipts belong to the accounting workflow, not the public
catalog. Shared reuse must not disclose who requested an episode, their library membership, private notes,
questions or listening history. Private and personalized results never become public through a cache hit.

Browse should show ready, eligible releases with paper title/authors, topic, duration, language, source version
and a clear generated-audio label. Open the transcript/citations or play immediately; an empty search should
not silently enqueue generation. Keep the existing app navigation until a concrete catalog/listening proposal
is reviewed. Download, playback resume, background audio, interruption handling and removal must work across
iPhone, iPad, Mac and web, with offline playback of retained downloads. Define the privacy/sync contract for
listening position explicitly instead of copying server-visible activity analytics.

Admission deduplicates a requested episode profile before reserving generation cost. Concurrent requests join
one durable job; only one provider execution gets a grant, and waiters receive no duplicate generation charge.
Publishing requires a complete, reviewed transcript/audio pair, exact source provenance and sharing approval.
An updated paper or corrected explanation creates a new release; old links remain attributable and listeners
see which version they have. Retraction, rights withdrawal, factual-error reports, correction and removal need
an explicit lifecycle, including search visibility and offline-cache freshness limits.

Decide first-funder fairness and playback access together: generating a reusable episode, listening to it,
downloading it, and requesting a personalized variant are distinct actions with distinct costs. A platform-
funded seed catalog needs its own allocation inside the existing operating budget. Demand signals can guide
that allocation only after their privacy and abuse controls are designed. Playback must use bounded delivery
and record transfer cost; sharing eliminates repeated generation, not storage or distribution expense.

Before activation, review schema evolution, exact deduplication keys, eligibility, moderation/corrections,
retention/deletion, library integration, discovery pagination, cross-device playback, credits and aggregate
reuse analytics as one end-to-end design. No catalog migration or audio provider call is part of this update.

## Small proof of concept, if separately activated

Propose a **$5 maximum experiment**, only after confirmed budget headroom and reliable per-attempt admission. Nothing was generated during this research.

Use six already-converted, confirmed shareable papers: at least two equation-heavy papers, one figure/table-heavy result, one survey, and one with important limitations or negative results. Draft one five-minute script per paper with its evidence map. Compare the same script as Gemini two-host audio and OpenAI assembled two-host audio; include a single-host sample and one twenty-minute continuity test. ElevenLabs can be a later comparison once its commercial account conditions fit the budget. This avoids a new recurring commitment for the first experiment.

Record actual tokens/characters, provider attempts, billable usage evidence, duration, script/review time, first-playable and completion latency, encoded size, rejection/repair reasons, and total cost. Run duplicate submission, lost response, disconnect/reload, quota exhaustion, account switching/deletion, and private-cache isolation cases with mocked transports before any real paid exercise.

Have a person familiar with each paper check the key claims, numbers, equations, unsupported extrapolations, and citations. Listen on phone-size speakers and headphones for pronunciation and chapter seams. Require zero unsupported material claims in the reviewed sample and accurate source links; treat that as a release gate, not a claim of universal correctness. An automated transcript pass can flag dropped or changed numbers, but it cannot replace that review.

Choose the speech provider only after these measurements. Before broader release, remaining gates are commercial terms for the exact account, source rights, provider retention/consent text, enforceable output/spend bounds, complete usage reconciliation, durable cancellation/deletion, download-abuse controls, and demonstrated scientific/audio quality. The main engineering work is in those boundaries and the listening experience, not in making the first TTS request.
