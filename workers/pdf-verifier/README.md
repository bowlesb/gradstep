# Local PDF verifier prototype

Status: local prototype only; `hosted_admitted` is **false**. No endpoint, storage credential, database write, OCR submission, or deployment is included. The original bytes remain unchanged. This worker measures the exact original hash, length and resolved page count before a future acquisition job may quote or submit it to Mathpix.

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
node_modules/@deno/darwin-arm64/deno test --no-config --allow-read=workers/pdf-verifier,.artifacts/pdf-verifier workers/pdf-verifier/tests/runtime.test.ts
python3 workers/pdf-verifier/tests/run-smoke.py
```

The Deno executions have no network, environment, subprocess or write permissions. They hash the generated glue before importing it and instantiate the already compiled WASM through an explicit factory callback. The unused Emscripten fetch fallback is never called. The local smoke runner starts a separate Deno process per case and kills it after five wall-clock seconds; a JavaScript timer is not presented as a way to interrupt synchronous WASM.

Use `build.py --clean-library` to recompile the qpdf library and compare output hashes; `--link-only` is only for iterating on the wrapper with the existing static library. `dist/build.json` records the binary/glue/profile/wrapper/runtime/inspector/build-recipe/dependency/static-library hashes, compiler and linker flags, and local build provenance. `dist/identity.json` contains the canonical deployment identity without local paths; its exact file SHA-256 equals `build_identity_sha256`. Approval must pin the full build identity, not merely the human-readable profile name. A changed parser, code, flags or profile requires a new reviewed identity.

Tests cover valid 1/25/50-page files, 51-page refusal, empty/broken syntax, corrupted and unsupported streams, each cumulative inspection limit, encrypted fixtures, parser nesting, a roughly 82 KiB compressed object stream expanding to 80 MiB, explicit memory-growth/OOM/stack failure, fresh-instance recovery, caller-buffer mutation, identity mismatch and overlapping requests. Synthetic fixtures are generated; two encrypted cases come from the pinned Apache-2.0 qpdf test archive and remain only in ignored artifacts. `smoke-results.json` records numeric outcomes, whole-child CPU/wall timing, and Deno's **post-run RSS snapshot**, not peak RSS. The simple page fixtures are not a representative research-paper benchmark.

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

1. Run this exact artifact in an isolated, authenticated hosted prototype and verify its actual WASM features, import behavior, cold compile time, hard termination, memory accounting, and restart/lease-expiry behavior. Supabase currently documents 256 MB memory and 2 s CPU per request; those are **host requirements**, not limits implemented by this TypeScript executor. Local Deno 2.9.6 does not prove compatibility with the hosted runtime.
2. Measure 20–30 licensed representative PDFs: equations, embedded fonts, scans, large figures, object/xref streams and linearized files, plus the existing rejection corpus. Target headroom is at most 1 s measured CPU and under 160 MiB measured peak whole-worker memory, not just the 64 MiB linear heap. Tighten admission rather than assuming every 5 MiB/50-page file fits.
3. Complete the narrow authenticated verifier-result authority and integrity-failure route, and verify failure-after-read/claim expiry/crash cases before enabling the profile. The verifier needs only its bounded input capability and fenced result authority, not a general service-role credential.

If the exact hosted runtime or representative workload cannot meet these gates, use a separately isolated compute worker with the same immutable profile and result contract. This local evidence does not yet require provisioning one.

## Primary references

- [Pinned qpdf C++ object/stream API](https://github.com/qpdf/qpdf/blob/v12.4.2/include/qpdf/QPDFObjectHandle.hh) and [pinned convenience C check implementation](https://github.com/qpdf/qpdf/blob/v12.4.2/libqpdf/qpdf-c.cc).
- [qpdf check/recovery and detection limits](https://qpdf.readthedocs.io/en/stable/cli.html#option-check).
- [Emscripten memory/stack and execution settings](https://emscripten.org/docs/tools_reference/settings_reference.html), with the exact SDK/source hashes in the lockfile.
- [Supabase Edge limits](https://supabase.com/docs/guides/functions/limits) and [WASM packaging guidance](https://supabase.com/docs/guides/functions/wasm).
