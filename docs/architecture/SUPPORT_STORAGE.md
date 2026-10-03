# Support attachment contract

Status: implementation contract for additive migration 008 and the `support-assets` function. Migrations 001–007 remain immutable.

Support notes and screenshots are intentionally disclosed to the reporter and authorized support operators. They have no access relationship with encrypted chat keys. The native app flattens image edits and re-encodes the selected pixels before presenting its final upload preview, removing source metadata and undoable redactions.

Use a private `support` bucket with no customer Storage policies. All writes pass through an authenticated Edge Function, which bounds the request body to 5 MiB, checks PNG/JPEG structure and dimensions, and computes the actual digest and size. The service never accepts a client-supplied storage path, owner, MIME type, or checksum as authority. No SVG, HTML, or arbitrary files are accepted. Server structure checks do not substitute for the native decoder or prove that an image is meaningful; the user must see the final preview.

Each attachment has a stable UUID scoped to an owned report. A database reservation fixes its report, owner, checksum, size, media type, and immutable object path. At most five pending or completed images belong to one report. A dedicated capacity row serializes reservations and bounds retained pending/verified/deleting bytes to 512 MiB per environment and 50 MiB per reporter for the beta. The limits are operational guardrails, not paid-plan entitlements. Fixed-window request gates additionally limit each account and the environment.

Publication is a three-step protocol: reserve the database identity and capacity; upload bytes without overwriting an existing object; verify the stored object's digest and length, then atomically mark it verified and link it to the report. A retry with the same identity and bytes finishes the existing operation. A different payload under that identity fails. An upload timeout retains the reservation; a retry downloads and verifies the existing object before publishing it. Readers see only linked, verified objects.

Physical deletion is also staged. An expired, unlinked reservation moves to `deleting`; a trusted janitor removes its exact immutable path, then marks it `deleted`. Capacity is released only after storage confirms removal. A janitor cannot delete a completed report attachment merely because its initial upload deadline passed. Completed report retention/account deletion is a separate explicit lifecycle, not this orphan collector.

Downloads require a fresh user session and an RPC that authorizes the reporter or an operator with MFA. The Edge Function proxies the bytes with `no-store`, `nosniff`, and the validated image type. It does not issue reusable public links. Browser previews use short-lived in-memory blob URLs, revoked when the view closes. Requests, responses, screenshots, session tokens, and notes are never logged by application code.

Migration 008 also adds a stable `(created_at, id)` report-list cursor, serializes reply rate limits across different reports, and denies client schema creation. Existing report/list APIs remain available during client transition. Tests must cover pending quota races, exact upload retries, cross-account access, non-MFA operator denial, and janitor fencing before hosted deployment.
