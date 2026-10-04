# PDF verifier prototype

Status: disabled prototype; `hosted_admitted` is **false**. The original bytes remain unchanged. This worker measures the exact original hash, length and resolved page count before a future acquisition job may quote or submit it to Mathpix. The separate [hosted experiment](hosted/README.md) deploys only a short-lived, authenticated, fixed-fixture compatibility test; it has no acquisition, Storage or verification-result authority.

## Admission profile

`profile.json` is the canonical policy input. The current pilot accepts at most 5 MiB and 50 resolved pages. It uses qpdf 12.4.2 compiled with Emscripten 6.0.11 into one unshared memory32 module with an explicit **64 MiB minimum and maximum**, a **2 MiB stack**, no memory/table growth, no filesystem, no pthreads and no dynamic JavaScript execution. Runtime tests inspect the actual WASM memory section and numeric ABI, then force memory growth and instrumented heap/stack failures. Each document gets a fresh instance; only compiled code is reused.

The numeric wrapper rejects encryption (including files readable with an empty password), qpdf warnings, xref recovery, unsupported stream filters, malformed detected structures and exceeded limits. The header must start at byte zero and a final `%%EOF` must be followed only by PDF whitespace. The page count comes from resolved page-tree leaves, not the untrusted `/Count` entry.

Every indirect stream is explicitly decoded into a discard pipeline with a **32 MiB cumulative output cap**. The modern qpdf `pipeStreamData` success flag and filtering-attempt flag are both checked; failed decoding is never retried as raw data. Page content parsing separately caps cumulative content size at 32 MiB and top-level parsed objects/operators at 1,000,000. Nesting is limited to 64, containers to 50,000 entries, filter chains to eight, and indirect objects/highest object number to 50,000. The highest-number limit also rejects sparse PDFs with a large object number. Internal object-stream decoding and intermediate allocations remain subject to the fixed WASM heap; the explicit output counters are **not** a measurement of every internal decompression allocation.

This deliberately uses public C++ APIs behind a numeric C ABI. In pinned qpdf 12.4.2, the convenience `qpdf_check_pdf()` writes through a default writer that can skip existing Flate streams. Our corrupt-Flate regression reproduced that gap. Direct decoding avoids that shortcut and avoids retaining a rewritten PDF. qpdf's native random provider expects `/dev/urandom`; the wrapper instead uses Emscripten `getentropy`/Web Crypto where qpdf needs random bytes while inspecting encryption dictionaries. No input-derived filename or parser message leaves the wrapper.

This is a structural admission check, not a rendering, sanitization or full PDF conformance claim. For example, a wrong `/Count` can be accepted while the returned count correctly reflects the actual leaves. Unsupported codecs such as those qpdf cannot decode are rejected under this conservative profile. It does not establish that PDFKit or Mathpix will render every admitted file identically.

## Reproduce locally

Run from the repository root on macOS arm64 with the existing Node v24.18.0 and system Python 3.9 or later. The script pins the qpdf source, Emscripten SDK, portable Python and CMake downloads in `dependencies.lock.json`; the pinned SDK recipes verify zlib/libjpeg port hashes. It makes no global installation. All fetched source, caches, compiler temporaries and generated files stay under the ignored `.artifacts/pdf-verifier/` tree. The first build downloads about 430 MiB and needs several GiB of local disk space. Docker is not required; the local daemon was unavailable during development.

```sh
python3 workers/pdf-verifier/build.py
node --max-old-space-size=512 workers/pdf-verifier/tests/generate-fixtures.mjs
node_modules/@deno/darwin-arm64/deno test --no-config --allow-read=workers/pdf-verifier,.artifacts/pdf-verifier --allow-run=node_modules/@deno/darwin-arm64/deno workers/pdf-verifier/tests/runtime.test.ts workers/pdf-verifier/tests/runtime-abi.test.ts workers/pdf-verifier/tests/memory-constructor.test.ts
python3 workers/pdf-verifier/tests/run-smoke.py
```

Verifier children have no network, environment, subprocess or write permissions. Only the constructor-regression parent may spawn the local Deno binary. The verifier hashes the generated glue before importing it and instantiates the already compiled WASM through an explicit factory callback. The unused Emscripten fetch fallback is never called. The local smoke runner starts a separate Deno process per case and kills it after five wall-clock seconds; a JavaScript timer is not presented as a way to interrupt synchronous WASM.

Use `build.py --clean-library` to recompile the qpdf library and compare output hashes; `--link-only` reuses the already-built static library. Each new build captures its source inputs and links an owned library copy in a unique working directory. The checked result is published under `.artifacts/pdf-verifier/builds/<full-identity>/`, with exact executable, source, profile and library bytes. Existing bundles are never overwritten. `build.json` records hashes, compiler/linker settings and informational local provenance; its commands are not an execution API. The raw SHA-256 of canonical `identity.json` is the full build identity. The atomic `current-build.json` pointer selects only local tests; hosted packaging pins an explicitly reviewed identity. A changed parser, runtime, code, flags or profile requires a new reviewed identity.

The original `2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0` build and its complete source/library bundle are preserved. The legacy `dist/` evidence remains unchanged. Before modifying a previously measured build that has not yet been archived, run `python3 workers/pdf-verifier/build_store.py --expected-identity <full-identity>` while its matching sources remain available. Historical corpus runs and hosted packaging must load the selected bundle's runtime and inspector, never the current workspace implementation.

The corrected build is `39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610`. It identifies the sole exported memory through the compiled module descriptor, retaining exact heap ownership/size and numeric ABI checks when a host replaces the global memory constructor. Parser library, wrapper, WASM, glue, profile and limits are byte-for-byte unchanged. Twelve runtime tests and 24 smoke cases pass for this build; eight build-store tests verify archive identity, preservation, tamper refusal and interrupted publication. Hosted compatibility is tracked separately below.

Tests cover valid 1/25/50-page files, 51-page refusal, empty/broken syntax, corrupted and unsupported streams, each cumulative inspection limit, encrypted fixtures, parser nesting, a roughly 82 KiB compressed object stream expanding to 80 MiB, explicit memory-growth/OOM/stack failure, fresh-instance recovery, caller-buffer mutation, identity mismatch and overlapping requests. Synthetic fixtures are generated; two encrypted cases come from the pinned Apache-2.0 qpdf test archive and remain only in ignored artifacts. New smoke evidence is written once under `evidence/<full-identity>/smoke/<run-id>/results.json`; the original `smoke-results.json` is preserved. Reports record numeric outcomes, whole-child CPU/wall timing, and Deno's **post-run RSS snapshot**, not peak RSS. The simple page fixtures are not a representative research-paper benchmark.

## Result and durable-job boundary

`runtime.ts` returns a measurement, not an authenticated attestation. A trusted future host must add reservation ID, verification claim/generation, operation ID, object identity, authenticated verifier identity and the approved profile/build digest. It must read the authorized stored original, compare its complete observed SHA-256 and length to the acquisition reservation, and accept only a successful generation-fenced result before creating approval or quoting Mathpix. Never return or publish a page count for failure.

| Numeric result | Executor outcome | Durable handling |
| --- | --- | --- |
| `1…50` | `verified`, resolved page count | Eligible only after full identity and lease checks |
| `-1`, `-5` | `malformed` (including warnings) | Permanent rejection for this profile |
| `-2` | `encrypted` | Permanent rejection |
| `-3` | `unsupported` | Permanent rejection for this profile |
| `-4` | `parser_resource_limit` | No automatic same-bytes retry |
| `-7` | `input_limit` | Rejection; oversized/partial reads have no whole-object hash claim |
| `-8` | `page_limit` | Permanent rejection for this profile |
| `-6` or unexpected trap | `internal_error` | Failed attempt for investigation; no verification success |
| Known WASM OOM/stack abort | `resource_limit` | Discard instance; no automatic same-bytes retry |
| Complete input differs from expected identity | `binding_mismatch` | Separate fenced integrity-failure/quarantine handling |

`binding_mismatch` may include the observed full hash/length of a complete bounded read; these intentionally differ from expected identity and must not go through a success-only equality check. A read interrupted before the entire object arrives has no verified whole-object hash. Transient storage/network failures must finish only the attempt/status, with no structural receipt. A trusted host's CPU/wall termination is separately `time_limit`; a killed worker cannot self-report a successful result. Replays or late results never bypass the reservation's current fence.

## Remaining gates

1. Hosted fixed-fixture compatibility now passes all 15 requests for corrected build `39980de…`, including valid, malformed, encrypted and resource-refusal cases. The [run evidence](hosted/README.md) records runtime identity and cold initialization. Still establish hard termination, memory-accounting scope and restart/lease-expiry behavior. Supabase's published memory/CPU limits are **host requirements**, not limits implemented by this TypeScript executor or measured peak/per-call CPU evidence. The installed acquisition lease and cleanup horizon also need resolution before enabling authority; see [the acquisition review](../../docs/architecture/ACQUISITION.md).
2. Resolve compatibility and headroom against representative PDFs. The [24-paper corpus](corpus/README.md) measured 72 isolated runs: twelve verified, four input-limit refusals, three stream-budget refusals and five warning refusals. It contains no scans. Warning diagnostics distinguish optional linearization hints from inconsistent object records; the [policy proposal](corpus/POLICY_REVIEW.md) is unimplemented. Target headroom is at most 1 s measured CPU and under 160 MiB measured peak whole-worker memory, not just the 64 MiB linear heap. The recorded post-run RSS snapshots are not peak evidence, and early refusal costs do not establish the cost of completing a looser profile.
3. Complete the narrow authenticated verifier-result authority and integrity-failure route, and verify failure-after-read/claim expiry/crash cases before enabling the profile. The verifier needs only its bounded input capability and fenced result authority, not a general service-role credential.

If the exact hosted runtime or representative workload cannot meet these gates, use a separately isolated compute worker with the same immutable profile and result contract. This local evidence does not yet require provisioning one.

## Primary references

- [Pinned qpdf C++ object/stream API](https://github.com/qpdf/qpdf/blob/v12.4.2/include/qpdf/QPDFObjectHandle.hh) and [pinned convenience C check implementation](https://github.com/qpdf/qpdf/blob/v12.4.2/libqpdf/qpdf-c.cc).
- [qpdf check/recovery and detection limits](https://qpdf.readthedocs.io/en/stable/cli.html#option-check).
- [Emscripten memory/stack and execution settings](https://emscripten.org/docs/tools_reference/settings_reference.html), with the exact SDK/source hashes in the lockfile.
- [Supabase Edge limits](https://supabase.com/docs/guides/functions/limits) and [WASM packaging guidance](https://supabase.com/docs/guides/functions/wasm).
