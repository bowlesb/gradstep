# Store verifier

A private, verify-only Node 24 service for the staging App Store purchase path. It has no Supabase credential, purchase recorder, entitlement grant, paper worker or AI provider access. The authenticated Edge caller owns transport admission and SQL recording. No real Sandbox purchase has been demonstrated by these local tests.

The production worker fixes Apple SDK 3.1.0, bundled Apple Root CA G3, bundle `com.sciencereader.ios`, Sandbox and online revocation checks. A narrow, source-hash-checked OCSP timestamp fix is required in the isolated image; see [its review and evidence](OCSP_FRESHNESS_REVIEW.md). No request or environment variable can choose a root, disable checks, change environments or supply a worker URL.

The shared portable [protocol](../../supabase/functions/_shared/store-verifier-protocol.ts) binds every reply to version, attempt UUID, kind, policy and exact JWS digest. JSON bodies and replies are at most 72 KiB; compact ASCII JWS is 20–64,000 bytes. Only normalized verified records leave the worker. Raw receipt, certificate, identity, hash, auth and error content are never logged. The service has no application logging; child stdout/stderr is drained and discarded.

Only `STORE_VERIFIER_POLICY_ID=app-store-sandbox-v1` and `STORE_VERIFIER_MAINTENANCE=false` can make a correctly patched service ready. Maintenance defaults on. `PORT` is the platform listener port; strict `K_REVISION` contributes only a bounded revision to `/health`. The health response proves public certificate primitives and the exact installed SDK patch, and remains HTTP200 for liveness in maintenance. Cloud Run IAM and the Edge caller credential are managed separately; the container is not a public authentication gateway.

`POST /verify` holds one of two slots starting at body receipt. Header/body reads have 3-second bounds each, 8 KiB header and 72 KiB body ceilings; no verification queue is created. Transactions have 40-second worker deadlines, notifications 70 seconds for outer plus inner together. Each path—including success, exception, timeout, shutdown and client disconnect—terminates and joins its worker before a response/capacity release. Workers receive no inherited environment or preload arguments and have 128 MiB old-generation heaps. Host memory/timeout/instance limits remain independent deployment requirements.

Run local verification with:

```sh
node services/store-verifier/tests/run-isolated.ts
```

This deliberately uses a new minimal installation and never patches the repository's dependencies. Tests create temporary certificate keys and loopback OCSP responses; they send no actual receipt or Apple request. An ordinary unpatched `npm test` in this service directory is not an activation test.

The Dockerfile expects an explicitly allowlisted repository-shaped context: its service runtime files plus the three named shared modules. It installs the service lockfile, applies the checked patch and runs as the unprivileged `node` user. Infrastructure tooling must build the Linux/amd64 image, pin its resulting digest, set private IAM, request billing, concurrency 2, 1 CPU/512 MiB, minimum 0/maximum 1 and an 80-second timeout, and verify the exact maintenance health response before any separate activation approval. This README records implementation, not a deployment.
