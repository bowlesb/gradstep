# Hosted compatibility experiment

Status: corrected build
`39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610`
passed all 15 staging requests in run
`c42149f5-3375-4692-a3d5-3ca325f6d9e2`: three authentication/input denials,
eleven fixed PDF cases and a valid document after the OOM case. Removal of the
temporary function, tagged Auth user and pristine account was verified.
No hosted profile has been admitted.

The two earlier executions stopped on the smallest valid PDF, after all three
denial cases passed. Their resources were also removed and absence verified;
neither failed execution was retried. Evidence for all three runs is preserved
separately under `.artifacts/pdf-verifier/hosted/`, keyed by run ID. The earlier
runs are `3f27f3ac-40ee-4c44-94fe-43814447ddc3` and
`e049de65-0e89-4fff-b2b0-66bb13a93f21`.

The second run identified `verifier_abi_mismatch` after successful compilation
on `supabase-edge-runtime-1.77.0 (compatible with Deno v2.1.4)`, V8
`11.6.189.12`. The [tagged runtime source](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/ext/runtime/js/bootstrap.js#L650)
replaces the global WebAssembly memory constructor without preserving its
prototype. An isolated local reproduction proves the original verifier fails
its `instanceof` check under that replacement while memory size, heap, ABI,
parser version and stack size remain correct. The descriptor-based correction
passes locally and on that hosted runtime without changing the parser policy
or limits. All twelve verification requests in the successful run reported
distinct isolate IDs, ordinal one and cold initialization. This demonstrates
successful later invocation after the OOM case, not recovery within the same
hosted isolate. Maximum initialization wall time was 119.475 ms and maximum
verification wall time 99.086 ms. CPU and peak-memory values remain null;
the runtime reported zero for its RSS snapshot, which is not a usable RSS
measurement. The 64 MiB WASM memory size was checked on every case.

The deployed source-manifest SHA-256 is
`3e44450889268168c9e90718809cf9e1a7ee1be3c7a572828b2aa9c4805ce0cb`;
the recorded server bundle hash is
`63fd29bbae2d78b3ef70411642740682dda2d629f80e4fc70568b519f16bdb6f`.
These identify different artifacts and are not interchangeable with the build
identity. The run's evidence records the exact deployment and request IDs.

This is a short-lived staging experiment, not an original-acquisition
endpoint or an admitted verification profile.

The experiment runs the existing, hash-pinned qpdf/WASM artifact against a
closed list of generated fixtures. Requests contain only a probe run UUID and
fixture name. PDF bytes, URLs, Storage paths, reservation IDs and database
callbacks are not accepted. The handler calls only the same project's Auth
user endpoint to authenticate; it never reads a service key. Supabase injects
ambient project credentials into its runtime, so this is not a claim of a
credential-free or separately isolated host.

A generated deployment binds one tagged synthetic Auth user, project, run and
absolute expiry, at most 20 minutes after package creation. Auth must return
that exact user and server-owned run marker before WASM compilation. A bearer
token alone is not authority. The operator uses at most 40 serial requests and
does not retry ambiguous execution. A per-isolate counter and concurrency
guard provide additional local bounds, not a global quota. No real account,
acquisition switch, verification profile, paid provider, or NAS operation is
part of this experiment.

Packaging preserves the exact generated JavaScript glue as a statically
imported module. The binary and fixtures become generated base64 constants;
they are decoded only after authorization. The builder verifies each original
hash and writes a manifest of every deployed source file. This uses the
documented source-bundle deployment path, without evaluating JavaScript
strings or fetching executable assets. The deployed bundle is a different
artifact from the local build; its source manifest and Supabase deployment ID
must be recorded alongside the original build identity. Server bundling may
transform JavaScript, so a checked input-glue hash is not described as a hash
of emitted server code.

Evidence separates cold initialization, per-document wall time, result, WASM
linear memory and any available runtime memory snapshot. A memory snapshot is
not peak RSS, and elapsed time is not CPU time. Record runtime version,
deployment/execution ID, a fresh-isolate UUID and invocation ordinal. An OOM
fixture must be followed by a valid fixture using a fresh WASM instance.

Passing these fixtures establishes hosted compatibility only. Admission still
requires representative papers, enforceable CPU/memory/wall/concurrency
bounds, independently observed termination and reconciliation after a killed
worker. Platform shutdown events can help establish termination, but their
CPU/memory fields must be interpreted at their documented worker scope. No
probe result may write a structural-verification receipt or enable live work.

Failure diagnostics contain fixed stage/code/error-class enums and bounded
synthetic-result values only. They never retain raw errors, stacks or private
content. The operator validates this shape, records runtime/deployment identity,
then stops on failure. Fifteen handler tests and twenty-one operator tests pass,
alongside the generated-entry check and pinned-package fixture test.

The execution tool must journal the tagged synthetic user and uniquely named
function before mutations, remove both with identity checks afterward, and
verify their absence. Never deploy with a reusable bypass password or leave
an unexpired test endpoint as a substitute for cleanup.

References: [Supabase WASM packaging](https://supabase.com/docs/guides/functions/wasm),
[runtime limits](https://supabase.com/docs/guides/functions/limits), and
[shutdown accounting](https://supabase.com/docs/guides/troubleshooting/edge-function-shutdown-reasons-explained).
