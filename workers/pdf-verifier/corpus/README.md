# Public ML paper verifier corpus

This local corpus contains **24 unchanged PMLR PDFs, 59,822,402 bytes (57.05 MiB)**. It tests the frozen verifier's compatibility with ordinary digital ML papers. No paper was uploaded, passed to a paid provider, or made eligible for application redistribution.

The frozen build accepted **12/24 papers**. Its other outcomes were four `input_limit`, three `parser_resource_limit`, and five `malformed`. The last label is the current runtime's mapping of a strict warning refusal: **it does not establish that those papers are unreadable or corrupt**. The numeric investigation below distinguishes their causes. No profile or production verifier change was made to obtain these results.

## Attribution, license evidence, and coverage

[manifest.json](manifest.json) records each paper's exact title, complete author list, proceedings, publication date, source page, exact HTTPS PDF URL, byte count and SHA-256. It also binds each publisher page and the saved license-policy evidence by SHA-256. [selection.json](selection.json) records selection topics. Attribution is retained in the original PDFs and the manifest.

The [PMLR publication agreement](https://proceedings.mlr.press/pmlr-license-agreement.html) specifies CC BY 4.0 publication; the [publisher FAQ](https://proceedings.mlr.press/faq.html) describes the required permission-to-publish forms. The [CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en) is saved as additional evidence. **License basis: publisher-policy inference; individual signed forms were not inspected.** This basis is used only for this offline benchmark. Extracted text from all 24 PDFs contained none of the conflicting-license markers checked by `benchmark.py`; this is a bounded screening step, not proof about every third-party element. Every manifest entry has `production_eligible:false`. A changed/conflicting source must be reviewed instead of silently updating the manifest.

The corpus spans attention/transformers, CNNs, contrastive learning, RL, optimization, flows, Monte Carlo, Gaussian processes, diffusion, time series, protein models and attribution. It includes equation-heavy, table-heavy and image-heavy layouts, with diagnostic page counts from 10 to 40. Every paper has extractable digital text. Six have linearization confirmed by auxiliary Poppler inspection: Perceiver, Improved DDPM, Fractal Learning Rates, Private Adaptive Gradients, GP Marginal Likelihood, and Layer Normalization.

There are **no scanned papers** and no encrypted papers in this sample. It is a purposeful 2020–2023 publisher sample, not a random estimate of all ML PDFs. Raw image/font/object-stream markers are lexical coverage hints only. Separate synthetic hostile-PDF tests remain necessary; public-paper compatibility does not replace them.

| Paper (publisher source) | MiB | Diagnostic pages | Frozen outcome |
|---|---:|---:|---|
| [CLIP](https://proceedings.mlr.press/v139/radford21a.html) | 3.36 | 16 | verified |
| [SimCLR](https://proceedings.mlr.press/v119/chen20j.html) | 3.17 | 11 | verified |
| [Transformers are RNNs](https://proceedings.mlr.press/v119/katharopoulos20a.html) | 0.42 | 10 | verified |
| [Perceiver](https://proceedings.mlr.press/v139/jaegle21a.html) | 2.46 | 14 | parser_resource_limit |
| [Improved DDPM](https://proceedings.mlr.press/v139/nichol21a.html) | 1.11 | 10 | verified |
| [Zero-Shot Text-to-Image Generation](https://proceedings.mlr.press/v139/ramesh21a.html) | 5.77 | 11 | input_limit |
| [CURL](https://proceedings.mlr.press/v119/laskin20a.html) | 2.05 | 12 | malformed (warning refusal) |
| [Normalizing Flows on Tori and Spheres](https://proceedings.mlr.press/v119/rezende20a.html) | 1.66 | 10 | parser_resource_limit |
| [Contrastive Learning for Likelihood-free Inference](https://proceedings.mlr.press/v119/durkan20a.html) | 0.64 | 11 | verified |
| [Fractal Learning Rate Schedules](https://proceedings.mlr.press/v139/agarwal21a.html) | 0.61 | 13 | verified |
| [Deep kernel processes](https://proceedings.mlr.press/v139/aitchison21a.html) | 0.21 | 11 | malformed (warning refusal) |
| [Annealed Flow Transport Monte Carlo](https://proceedings.mlr.press/v139/arbel21a.html) | 0.41 | 13 | verified |
| [Private Adaptive Gradient Methods](https://proceedings.mlr.press/v139/asi21a.html) | 2.19 | 10 | verified |
| [GP Marginal Likelihood via Conjugate Gradients](https://proceedings.mlr.press/v139/artemev21a.html) | 0.73 | 11 | verified |
| [Safe Reinforcement Learning](https://proceedings.mlr.press/v139/amani21a.html) | 0.65 | 11 | verified |
| [EfficientNetV2](https://proceedings.mlr.press/v139/tan21a.html) | 0.61 | 11 | verified |
| [Data-efficient image transformers (DeiT)](https://proceedings.mlr.press/v139/touvron21a.html) | 0.34 | 11 | malformed (warning refusal) |
| [TRAK](https://proceedings.mlr.press/v202/park23c.html) | 8.24 | 40 | input_limit |
| [Monarch](https://proceedings.mlr.press/v162/dao22a.html) | 4.80 | 32 | parser_resource_limit |
| [Autoregressive Denoising Diffusion](https://proceedings.mlr.press/v139/rasul21a.html) | 5.49 | 12 | input_limit |
| [MSA Transformer](https://proceedings.mlr.press/v139/rao21a.html) | 3.28 | 13 | malformed (warning refusal) |
| [Layer Normalization in Transformers](https://proceedings.mlr.press/v119/xiong20b.html) | 0.37 | 10 | malformed (warning refusal) |
| [Offline RL with Fisher Divergence](https://proceedings.mlr.press/v139/kostrikov21a.html) | 1.56 | 10 | verified |
| [Preferential Temporal Difference Learning](https://proceedings.mlr.press/v139/anand21a.html) | 6.93 | 11 | input_limit |

Page counts in this table come from auxiliary `pdfinfo`, **not successful verification attestations** for rejected inputs. Full titles and authors are in the manifest.

## Reproduce

Run from the repository root with the verified immutable build bundles available. Select full identities explicitly; no command follows the mutable `dist/` directory or current verifier source:

```sh
python3 workers/pdf-verifier/corpus/test_fetch.py
python3 workers/pdf-verifier/corpus/test_research.py
python3 workers/pdf-verifier/corpus/test_corpus_store.py
python3 workers/pdf-verifier/corpus/fetch.py
python3 workers/pdf-verifier/corpus/benchmark.py \
  --build-identity 2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0 --repeats 3
python3 workers/pdf-verifier/corpus/research_build.py \
  --verify-existing a525543bde71a0b92dd3ad396571037ae14877b7f35b253f10bfa8b98f311f42
python3 workers/pdf-verifier/corpus/research.py \
  --research-identity a525543bde71a0b92dd3ad396571037ae14877b7f35b253f10bfa8b98f311f42 \
  --baseline .artifacts/pdf-verifier/corpus/benchmark.json \
  --baseline-sha256 8c2a1df54987dadfe2438acdd58686f0081ee5f7addf2ee3644bac63c6c8b4d2
```

Verifier bundles live at `.artifacts/pdf-verifier/builds/<full identity>/`. The loader verifies the complete bundle and imports its archived runtime/inspector only after verification. Diagnostic bundles live at `.artifacts/pdf-verifier/corpus/research-builds/<full identity>/`, including the exact instrumentation recipe, generated wrapper, WASM, glue, identity and provenance. Their original runtime comes from the referenced verifier bundle. Editing current verifier or research source does not invalidate these historical execution inputs.

New benchmark/research results go to `.artifacts/pdf-verifier/corpus/runs/<kind>/<identity>/<run ID>/report.json`. A generated run ID is the default; `--run-id` accepts an explicit fresh key and refuses reuse. Each run saves its input manifest; research runs also save the exact baseline report. Partial progress is separate from the exclusively published final report. Legacy `benchmark.json`, `research/report.json`, and their original logs remain preserved. No diagnostic rebuild was needed for this migration.

An optional `research_build.py --rebuild --build-identity <full identity>` creates a new isolated work directory and diagnostic identity. It requires the matching existing local SDK/headers/cache, uses the base bundle's exact wrapper and static library, and captures the recipe/wrapper before compilation. It never executes archived `build.json` commands. This rebuild branch was not exercised during the consumer migration; historical replay uses the already verified diagnostic bundle. Archived recipes/provenance are evidence, not automatic commands to execute.

`fetch.py` verifies cached files without network. Missing files are restored from the pinned exact HTTPS publisher URLs, with redirects refused, no proxies, one connection at a time, a one-second pause after closure, 32 MiB/file and 160 MiB cumulative received-byte limits. The persistent transfer receipt includes failed partial bytes; restart does not reset the budget. HTTP compression is refused. Each socket has a ten-second timeout; a thirty-second elapsed check runs between bounded reads. An exact-cap unknown-length response may be refused rather than reading a detection byte beyond the limit. Older publisher links using HTTP are recorded unchanged as evidence and fetched using only a scheme change to HTTPS. Arbitrary existing files are not adopted.

The initial `--capture` path creates a manifest only when none exists. Ordinary reproduction never repins changed publisher bytes. The 15 offline tests exercise redirect refusal, file/aggregate caps, restart accounting, truncation, changed bytes, encoding, URL/path restrictions, and hash-bound cache reuse without opening sockets.

Each benchmark invocation uses a fresh local Deno child, a parent-enforced five-second timeout, and no Deno network/environment/subprocess/write permissions. Current read grants cover the corpus and immutable build store, excluding live verifier source and `dist/`. Build, source, profile and PDF hashes are checked before verification. The original baseline used 72 cold processes, three per paper, with consistent outcomes for every paper. Optional local `pdfinfo`/`pdftotext` commands provide separately labelled descriptive facts; extracted article text is not saved in the report.

Auxiliary Poppler commands have a five-second process timeout, but their output-size checks occur **after capture**. Those checks are not hard output or memory enforcement and do not make Poppler an admitted verification host. The diagnostic comparison separately rejects stale baseline manifests/builds, same-ID changed PDF bytes, duplicate/missing records and inconsistent outcomes; its imported runtime/inspector sources are also bound to the frozen identity.

## Frozen benchmark evidence

Original build identity: `2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0`.

Profile SHA-256: `c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962`.

The profile remains qpdf 12.4.2 / Emscripten 6.0.11, 5 MiB input, 50 pages, fixed 64 MiB WASM memory, 2 MiB stack, 32 MiB cumulative decoded streams, 32 MiB cumulative page content, 1M content objects and 50k indirect/highest objects. Recovery, encryption and warnings remain refused. `hosted_admitted` remains false.

Maximum **whole-child CPU** was **270.674 ms**; median was **139.557 ms**. This includes startup, hash/build checks, WASM compilation, input read/hash and parsing. Maximum **post-run Deno RSS snapshot** was **98,254,848 bytes (93.70 MiB)**. It is **not peak RSS**; `peak_host_bytes` is null. These local measurements do not establish a peak-memory ceiling, Edge resource compliance, or hosted admission. Rejected inputs stop early, so their times do not predict the cost of finishing under a different policy.

Ignored evidence is under `.artifacts/pdf-verifier/corpus/`: `benchmark.json` (all 72 runs), `benchmark.log`, `fetch.log`, `download-receipts.json`, `fetch-tests.log`, plus unchanged `pdf/` and hashed `evidence/` files. A restored artifact must match the tracked manifest before it can be benchmarked.

## Immutable-consumer comparison

The corrected runtime build `39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610` was tested separately using one cold process per paper. All **24 exact input hashes, byte counts and outcomes match** the original 72-run baseline. Its wrapper, profile, WASM, glue and qpdf library hashes are identical to the baseline; runtime/build-provenance identity differs.

The new report is `runs/benchmark/39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610/immutable-consumer-comparison/report.json` (SHA-256 `58dd3519991e04179946db8ac21460ee5ebb8aa9b4215df8e52b5b092ee9a2af`). The exact comparison is under the same corpus root at `runs/validation/39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610/legacy-comparison-v1/report.json`.

Observed maximum whole-child CPU was 247.675 ms and maximum post-run RSS snapshot was 115,179,520 bytes (109.84 MiB), **not peak memory**. The new observer verifies the complete bundle, including archived source/library hashes, so its overhead differs from the original runner. These are local execution measurements, not evidence of hosted admission or a performance improvement/regression.

Migration checks include nine Python archive/run tests, six Deno loader tests and the eight existing stale-baseline tests. They cover changed live source, tampering, rewritten manifests, symlinks, duplicate output keys, racing run creation and immutable final reports. Deno loader fixtures write only under ignored corpus artifacts; the symlink-creation test requires Deno's unscoped read/write test grants. Benchmark children retain their separate read-only permissions. Evidence is in `runs/validation/2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0/bundle-migration-v1/` and `bundle-migration-v2/` (the latter resolves initial type-check/test-permission failures). A historical CLIP case passes with live-source/`dist` read access absent.

## Numeric rejection investigation

No native qpdf executable was installed. `research_build.py` therefore creates a **separate wrapper-only diagnostic build**, linked to the original hash-pinned qpdf static library. It adds numeric observations, keeps every bound and result branch, and uses a copied frozen compiler cache with no dependency-download path. Original source, runtime, profile, library and distribution remain unchanged. The research build has no admission authority.

Research identity: `a525543bde71a0b92dd3ad396571037ae14877b7f35b253f10bfa8b98f311f42`.

All 24 research outcomes match the original outcomes. Diagnostic fields report attempted bytes at the refusal boundary, not bytes successfully admitted beyond the cap:

| Rejection | Numeric cause |
|---|---|
| Perceiver | Cumulative decoded-stream cap, 33,558,756 attempted bytes; current stream DCTDecode |
| Normalizing Flows | Cumulative decoded-stream cap, 33,607,957 attempted bytes; current stream FlateDecode |
| Monarch | Cumulative decoded-stream cap, 33,581,984 attempted bytes; current stream FlateDecode |
| CURL | Three zero-offset xref-object warnings after resolving all objects |
| MSA Transformer | Two zero-offset xref-object warnings after resolving all objects |
| Deep kernel processes | 25 expected-object-header warnings (`expected n n obj`) after resolving all objects |
| DeiT | Three expected-object-ID header warnings after resolving all objects |
| Layer Normalization | Eleven linearization-hint warnings: six shared-object warnings, four per-page object-count mismatches, one page-zero shared-identifier entry |

All five warning refusals return wrapper code `-5`, which the frozen runtime maps to `malformed`. None reaches a caught parse exception or failed stream decode before that refusal. The four xref/header cases differ materially from the hint-only case; accepting one class does not justify accepting the others. qpdf explicitly recognizes zero-offset live xref entries as a common writer error and substitutes null. This investigation does **not** prove those entries are unreachable or that all later structural checks would pass.

Original research evidence remains `research/identity.json`, `research/provenance.json`, `research/verifier-research.cpp`, `research/report.json`, and `research.log` under the ignored corpus directory. Its exact executable/recipe inputs are now also in the immutable diagnostic bundle. A separate 24-case archived replay is recorded at `runs/research/a525543bde71a0b92dd3ad396571037ae14877b7f35b253f10bfa8b98f311f42/immutable-bundle-replay/report.json`. Numeric categories are fixed in the captured recipe; no parser message or document text crosses the diagnostic WASM boundary. See [POLICY_REVIEW.md](POLICY_REVIEW.md) for an unimplemented review proposal and required regressions.
