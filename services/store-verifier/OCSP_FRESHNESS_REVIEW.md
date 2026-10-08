# OCSP freshness guard review

Status (2026-10-07): implemented locally with root design approval; independent review and deployment remain pending. No hosted service or payment rule was changed. The isolated verifier image applies the exact patch below; workspace dependencies and the shared Node adapter remain unmodified.

The new service's actual signed-DER loopback test found that Apple Node SDK 3.1.0 accepts an expired but correctly signed `good` OCSP response with an otherwise valid certificate chain. The corrected fixture has `thisUpdate` and `producedAt` two hours old and `nextUpdate` one hour old: its dates are ordered, so the failure is specifically freshness. Independent review reproduced the failure.

The SDK parser expects fourteen digits without the standard UTC `Z`. jsrsasign retains that suffix. Node returns a non-finite date, and both numeric freshness comparisons become false. This does not bypass the SDK's independent chain, responder, signature, certificate identity or status checks.

Apple's [open issue 447](https://github.com/apple/app-store-server-library-node/issues/447) reports the same parser issue. The [latest published Node release](https://github.com/apple/app-store-server-library-node/releases) and npm registry still identify 3.1.0; [current main](https://github.com/apple/app-store-server-library-node/blob/main/jws_verification.ts) retains the parser. [PR 451](https://github.com/apple/app-store-server-library-node/pull/451) proposes strict UTC parsing with missing-nextUpdate rejection, but is unmerged. [PR 470](https://github.com/apple/app-store-server-library-node/pull/470) is also unmerged and permits absent nextUpdate with no maximum age, which would relax the current policy and is not recommended here.

Reproduction used Node 24.18.0; the installed SDK verifier file SHA-256 is `2ab29caa890958dcfc6dc4789fd5a500e8249102e037045525d35e5c15541bf1`. The original focused stock-SDK run failed at `stale`; the isolated patched install now passes the same signed-DER case. The small DER/parser evidence is retained locally at `.artifacts/store-verifier/ocsp-upstream-reproduction.json`.

## Implementation boundary

The candidate applies a small deterministic **build-time** patch to the exact installed `dist/jws_verification.js` from SDK 3.1.0. Require both the package lock integrity and the original file SHA-256; a different source, partial patch, unexpected hunk or unknown already-patched hash stops the build. Keep the original SDK source attribution and license. The produced image digest and local test artifact must identify the patched file hash.

The patch changes only UTC date parsing and freshness validation at the existing OCSP response validation point, after the existing responder authorization and response signature checks and for the matching certificate identity. It does not replace chain building, signature algorithms, certificate matching, certificate expiry, status interpretation, HTTP transport or the SDK's cache. No runtime prototype modification, copied verifier implementation or fallback acceptance path is used.

The date parser accepts the OCSP UTC GeneralizedTime form `YYYYMMDDHHMMSSZ`, validates calendar components by UTC round-trip, and throws the existing SDK `FAILURE` on missing, malformed or non-finite values. It does not depend on host timezone. The check requires all of thisUpdate, nextUpdate and producedAt. Requiring nextUpdate preserves the stock SDK's effective policy (missing nextUpdate currently throws); it does not add an unbounded age fallback.

Retain the SDK's 60-second skew: thisUpdate and producedAt cannot exceed now + 60 seconds; nextUpdate cannot precede now - 60 seconds. Require nextUpdate >= thisUpdate and producedAt >= thisUpdate - 60 seconds. An otherwise correctly signed response defines its own validity interval; no arbitrary maximum interval or extra provider request is introduced. Invalid freshness is a deterministic `invalid` / `revocation` SDK failure, with no dates or response data in diagnostics. The outer plus inner notification still shares one worker, and a new thread ends its public-certificate cache after the request.

The isolated suite runs signed DER cases for current good status, expired ordered intervals, future thisUpdate and producedAt, reversed intervals, exact skew boundaries, absent fields, malformed/non-UTC times, invalid/leap-day calendars, bad signatures, revoked/unknown statuses, and provider outage. Test the parser under UTC and at least one non-UTC timezone. The accepted response path must still come from the real Apple SDK, with no mock acceptance of decoded payloads.

The service lifecycle and request-binding tests also pass locally. Remove the patch only after an upstream release is pinned and these same tests pass. This document records local verification, not permission to deploy or evidence of a real Sandbox purchase.


`strict-utc-v1` transforms stock SDK SHA-256 `2ab29caa890958dcfc6dc4789fd5a500e8249102e037045525d35e5c15541bf1` to `e2bbd098d9572596e6fa7572b69ee96fa4c34d5db5479672bc3a91a2c47241ad`. Health reports these fixed hashes and whether the installed module matches; both readiness and the worker fail closed without that exact match. The runtime lookup resolves the SDK from the shared Node adapter's importing path.

The format follows [RFC 6960 section 4.2.2.1](https://www.rfc-editor.org/rfc/rfc6960#section-4.2.2.1), which references RFC 5280's UTC GeneralizedTime profile; [RFC 5019 section 2.2.4](https://www.rfc-editor.org/rfc/rfc5019#section-2.2.4) also requires UTC, seconds and no fractional seconds. Missing nextUpdate remains a deliberate stricter acceptance policy despite being optional in general OCSP syntax.

Run `node services/store-verifier/tests/run-isolated.ts` from the repository root. It creates a named artifact context, installs only the service's pinned dependencies, proves the unpatched service is unready, saves the original SDK, applies and rechecks the patch, then runs all tests under UTC and the crypto/patch suites under Asia/Kolkata. It never patches another worktree's node_modules. Current evidence: 33 tests in UTC and 10 in Asia/Kolkata, including 32 signed DER freshness matrix cases.
