# Purchase verification diagnostic hotfix — 2026-10-07

Status: reviewed diagnostics deployed as **store-sync v36** at 2026-10-07 17:50 PDT, from main `834db5e`. Hosted certificate compatibility failure confirmed. The purchase path is not repaired or verified end to end yet.

## Observed failure

The owner’s TestFlight feedback for build 13 was submitted at 2026-10-07 15:09:05 UTC. Its screenshot shows 17 available credits and the old alert promising automatic retry after a purchase. Read-only staging logs for 15:06–15:10 UTC show eight `store-sync` completions with outcome `invalid`, each HTTP 200, in 537–752 ms. That is a server refusal, not evidence of a lost response or a delayed balance refresh. The old alert did not distinguish a refusal from a temporary outage.

The read-only transaction count at 2026-10-08 00:39 UTC was zero App Store receipts and zero App Store-granted credits. This says nothing about separately granted beta credits. The deployed function was ACTIVE `store-sync` version 35; hashes of its configuration matched the intended bundle, Sandbox environment and enabled online checks. The downloaded deployment bundle SHA-256 was `92100d8247b8fa0824eaa2decd33efb5af70f3165216885394cd4bb4c0639435`.

A separate 22:46:35–00:46:35 UTC log window contained nine completed requests, with nine `invalid` outcomes and one `environment_unavailable` outcome. These logs do not bind an outcome to an account or submitted receipt, so those newer calls cannot be attributed to the owner rather than another caller or a synthetic probe.

## Narrow change

This candidate uses the deployed migration 018 purchase RPCs and is compatible with the current 032 schema. It has no dependency on the unfinished cost controls or purchase-observation migration 038. It does not change signature checks, certificate validation, online revocation checks, environment selection, normalized transaction fields, credit grants, responses, retries or which StoreKit transactions finish.

An optional, nonfinancial callback records one allowlisted observation per attempted verification. It distinguishes certificate chain, revocation, signature/payload, app identity, input/environment, field normalization, and database recording. Apple status, transport category and SQL refusal are finite codes. Database outages still propagate so the caller retries. A logging failure cannot alter recording or the response. Observations contain no JWS, certificate, claims, transaction/account IDs, URLs, error messages, request body or key material.

One startup observation records a fixed release marker, fixed Apple SDK version, validated Deno version and boolean capability checks against the bundled public Apple root. The probe makes no network request and catches failures. A missing `infoAccess` value on the root is valid; an exception accessing the property means the primitive is unavailable.

The hosted v36 probe at **2026-10-08 00:51:19.447 UTC** returned `certificate_parse=true` and `public_key_export=true`, but `certificate_string`, `certificate_raw`, `certificate_verify` and `certificate_info_access` were all **false**. Its version string did not match the strict numeric allowlist and was recorded as `unknown`; do not infer an exact hosted Deno version. This proves the hosted runtime cannot perform the certificate operations required by Apple's SDK. The SDK calls `toString()` before reaching OCSP, and depends on all four missing primitives. The earlier standalone Deno probe therefore did not establish hosted compatibility. Fix the runtime placement or obtain a supported managed-runtime upgrade; keep signature, chain and online revocation checks intact.

The native wording is merged as main `64c0873` for the next build: temporary unavailability still says credits are pending with automatic retry; an invalid receipt offers Restore purchases or a report without promising automatic recovery. Restore does resubmit unfinished invalid transactions. Refused transactions remain unfinished. Five StorePurchaseTests passed with an isolated Simulator configuration whose compiled backend URL/key were empty. This wording is not in uploaded build 16.

## Evidence and rollout

Local backend suite: 230 tests passed. Thirteen focused purchase tests pass in Node 24 and Deno 2.9.6, including the actual Apple verifier against a loopback OCSP service returning HTTP 503, tampered signatures, wrong app/environment, normalization versus SQL refusal, throwing observers, malicious observation values, cyclic error causes and unavailable certificate primitives. The production `store-sync` entry point passes `deno check`. Tests make no real purchases or paid-provider calls.

The Deno test harness uses a local artifact import map for the existing transitive test dependency `jsrsasign` and `--no-check` for test-only Node type resolution; the production module is separately type-checked with the repository import map. No dependency or lockfile change is required.

Root and an independent agent reviewed the diagnostic-only deployment. Readback confirmed only `store-sync` changed, v36 is ACTIVE, and the migration ledger remains byte-for-byte unchanged through032. One unauthenticated GET returned405 before purchase processing and triggered the startup probe; no receipt, provider call or credit mutation was needed. Format-aware ESZIP extraction verified the four deployed application modules exactly match the reviewed source. The downloaded v36 body SHA-256 is `e5e0d795411854c3182d3316a4b5177fc70479c2036809a56c8652d26d5d697e` (the Management API's separate `ezbr_sha256` is not the downloaded-body hash).

Evidence: main `.artifacts/purchase-hotfix/deployment.json`; the `science-reader-purchase-hotfix` worktree's `.artifacts/purchase-hotfix/postdeployment-diagnostics.json` and `store-sync-v36.comparison.json`. Successful credit delivery still requires a real signed Sandbox transaction to verify and record once after the runtime repair. No new purchase is required merely to retry an existing unfinished transaction. Nothing in this diagnostic update authorizes a manual grant or weaker verification.

This adds bounded console records under the existing request and 25-transaction body limits, plus a small zero-network startup probe. It adds no table, worker, paid provider request, secret or change to the operating budget. Retention follows existing project logs; the durable owner investigation view remains the separate reviewed migration 038 rollout.
