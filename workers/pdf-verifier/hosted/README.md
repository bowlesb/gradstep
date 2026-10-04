# Hosted compatibility experiment

Status: preparation only. This is a short-lived staging experiment, not an
original-acquisition endpoint or an admitted verification profile.

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

The execution tool must journal the tagged synthetic user and uniquely named
function before mutations, remove both with identity checks afterward, and
verify their absence. Never deploy with a reusable bypass password or leave
an unexpired test endpoint as a substitute for cleanup.

References: [Supabase WASM packaging](https://supabase.com/docs/guides/functions/wasm),
[runtime limits](https://supabase.com/docs/guides/functions/limits), and
[shutdown accounting](https://supabase.com/docs/guides/troubleshooting/edge-function-shutdown-reasons-explained).
