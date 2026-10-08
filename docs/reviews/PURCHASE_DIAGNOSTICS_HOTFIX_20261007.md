# Purchase verification diagnostic hotfix — 2026-10-07

Status: local, reviewed-scope diagnostic candidate; not deployed. The observed purchase failure is not repaired or verified end to end yet.

## Observed failure

The owner’s TestFlight feedback for build 13 was submitted at 2026-10-07 15:09:05 UTC. Its screenshot shows 17 available credits and the old alert promising automatic retry after a purchase. Read-only staging logs for 15:06–15:10 UTC show eight `store-sync` completions with outcome `invalid`, each HTTP 200, in 537–752 ms. That is a server refusal, not evidence of a lost response or a delayed balance refresh. The old alert did not distinguish a refusal from a temporary outage.

The read-only transaction count at 2026-10-08 00:39 UTC was zero App Store receipts and zero App Store-granted credits. This says nothing about separately granted beta credits. The deployed function was ACTIVE `store-sync` version 35; hashes of its configuration matched the intended bundle, Sandbox environment and enabled online checks. The downloaded deployment bundle SHA-256 was `92100d8247b8fa0824eaa2decd33efb5af70f3165216885394cd4bb4c0639435`.

A separate 22:46:35–00:46:35 UTC log window contained nine completed requests, with nine `invalid` outcomes and one `environment_unavailable` outcome. These logs do not bind an outcome to an account or submitted receipt, so those newer calls cannot be attributed to the owner rather than another caller or a synthetic probe.

## Narrow change

This candidate uses the deployed migration 018 purchase RPCs and is compatible with the current 032 schema. It has no dependency on the unfinished cost controls or purchase-observation migration 038. It does not change signature checks, certificate validation, online revocation checks, environment selection, normalized transaction fields, credit grants, responses, retries or which StoreKit transactions finish.

An optional, nonfinancial callback records one allowlisted observation per attempted verification. It distinguishes certificate chain, revocation, signature/payload, app identity, input/environment, field normalization, and database recording. Apple status, transport category and SQL refusal are finite codes. Database outages still propagate so the caller retries. A logging failure cannot alter recording or the response. Observations contain no JWS, certificate, claims, transaction/account IDs, URLs, error messages, request body or key material.

One startup observation records a fixed release marker, fixed Apple SDK version, validated Deno version and boolean capability checks against the bundled public Apple root. The probe makes no network request and catches failures. A missing `infoAccess` value on the root is valid; an exception accessing the property means the primitive is unavailable. Supabase’s hosted Edge runtime can differ from standalone Deno, and older Deno implementations lacked certificate methods used before OCSP. This is a hypothesis to test, not an established cause of the owner’s failure.

The native wording is a separate candidate: temporary unavailability still says credits are pending with automatic retry; an invalid receipt offers Restore purchases or a report without promising automatic recovery. Restore does resubmit unfinished invalid transactions. Refused transactions remain unfinished.

## Evidence and rollout

Local backend suite: 230 tests passed. Thirteen focused purchase tests pass in Node 24 and Deno 2.9.6, including the actual Apple verifier against a loopback OCSP service returning HTTP 503, tampered signatures, wrong app/environment, normalization versus SQL refusal, throwing observers, malicious observation values, cyclic error causes and unavailable certificate primitives. The production `store-sync` entry point passes `deno check`. Tests make no real purchases or paid-provider calls.

The Deno test harness uses a local artifact import map for the existing transitive test dependency `jsrsasign` and `--no-check` for test-only Node type resolution; the production module is separately type-checked with the repository import map. No dependency or lockfile change is required.

Root coordinates review and any live deployment. After a diagnostic-only deployment, a method-rejected request can collect the public startup probe without a purchase. An existing unfinished transaction can then provide the precise failed verification stage when the app syncs or the owner restores; no new purchase is needed for that evidence. Successful credit delivery still requires a real signed Sandbox transaction to verify and record once. Nothing in this candidate authorizes a manual grant or weaker verification.

This adds bounded console records under the existing request and 25-transaction body limits, plus a small zero-network startup probe. It adds no table, worker, paid provider request, secret or change to the operating budget. Retention follows existing project logs; the durable owner investigation view remains the separate reviewed migration 038 rollout.
