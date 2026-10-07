# Browser reader

Status, 2026-10-07: **Phase 1 design; implementation in `apps/web/`.** Authorized by the owner (2026-10-03,
[implementation plan §6](../IMPLEMENTATION_PLAN.md#6-browser-reader)); home decided by the owner 2026-10-07:
**app.gradstep.ai**. Nothing below is a claim of E2EE, sync or deployment until the evidence section says so.

## Scope

Phase 1 (this design): sign in with an email code → this browser becomes a device (recovery code, or new keys for an
account that has none) → library table with live import progress → add an arXiv paper → read a converted paper with
the same verified bundles and `reader-bridge.js` behavior → sign out.

Phase 2 (not built; shown as "Not yet available in the browser" rather than faked): chat and its encrypted history,
selection actions, reference actions, tag editing, web search/Feed, Apple/Google web sign-in, approving a browser from
an existing device, device list and revocation, offline reading, credits and purchases.

## Where it lives

| Surface | Origin | Host |
|---|---|---|
| Info site (`web/site/`) | `https://gradstep.ai` | Cloudflare Pages `gradstep-site` |
| Browser reader (`apps/web/`) | `https://app.gradstep.ai` | Cloudflare Pages `gradstep-app` (custom domain, proxied CNAME to `gradstep-app.pages.dev`) |

`gradstep.ai/app` and `gradstep.ai/app/*` redirect (302) to `https://app.gradstep.ai/` (`web/site/_redirects`). A
separate origin isolates the reader's IndexedDB keys, session and storage quota from the info site, and lets the app
have a strict CSP without constraining the marketing pages. Both projects are on Cloudflare's free tier (static assets,
no Functions): $0/month.

Builds are local (`npm run build` in `apps/web`), deployed with `npx wrangler@4 pages deploy apps/web/dist
--project-name gradstep-app --branch main` using the dedicated Cloudflare token in the main checkout's `.env.staging`
(`scripts/deploy-web.mjs`). The build points at **staging** (`coxhjvqpflgxkleydati`); production stays unprovisioned.
The Supabase anon key is a public client identifier (as in the iOS binary and the admin site), embedded at build time;
no service key, provider key or token ever enters the bundle (the build fails if `.env` values other than the
URL/anon key are referenced).

## Stack

Vite 8 + React 19 + TypeScript (the admin site's house style) as a self-contained package (`apps/web/package.json`,
its own lockfile, so the deployable has reproducible dependencies independent of Edge/admin tooling). Vitest for
unit/interop tests, Playwright for end-to-end. **No `supabase-js`**: a ~250-line fetch client mirrors the native
`BackendClient` contracts (bounded bodies, `redirect: "error"`, a single refresh in flight, finite error mapping, no
provider bodies in messages), and keeps realtime/storage SDK code out of a page that holds keys.

## Security headers (`apps/web/public/_headers`, generated at build)

```
Content-Security-Policy: default-src 'none'; script-src 'self' 'sha256-<reader frame script>';
  style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self';
  connect-src https://coxhjvqpflgxkleydati.supabase.co; frame-src 'self'; manifest-src 'self';
  base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; worker-src 'none'
Strict-Transport-Security: max-age=31536000
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
X-Frame-Options: DENY
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
```

No third-party scripts, fonts, analytics or CDNs. `connect-src` is only the Supabase project (REST, Auth, Edge
functions and Storage signed URLs share that host). `style-src 'unsafe-inline'` is required by the reader bridge
(it inserts `<style>` elements, as in WebKit) and the bundles' inline MathML styles; scripts stay hash/`self`-only.
Hashed assets are cached immutably; `index.html` and `_headers` are `no-store`/revalidated.

## Reader frame

The native app loads a verified bundle into a `WKWebView` with content JavaScript disabled and injects
`reader-bridge.js` in a separate content world. The browser equivalent:

1. Fetch the descriptor from `functions/v1/reader-artifact` (unchanged) and each member from its signed Storage URL
   (same host only). Verify exactly what `VerifiedReaderBundle.verify` verifies: manifest SHA-256 equals the
   descriptor's trusted digest, manifest format/profile/paths/roles/media types/sizes/pixel bounds, each member's
   length and SHA-256, index structure and identifiers, and (for `mathpix-mmd`) the provenance record's canonical
   form and image bindings. Images are additionally decoded with `createImageBitmap` and must match the manifest
   dimensions (the native decoder admission).
2. Build a document from the verified HTML: remove every script, `<base>`, `<meta http-equiv>`, frames, objects,
   forms and event-handler/`javascript:` attributes; inline `reader.css`; replace image paths with `data:` URIs of the
   verified bytes; put the bundle's CSP back as a stricter meta policy (`default-src 'none'; img-src data:;
   style-src 'unsafe-inline'; script-src 'sha256-…'`).
3. Append one inline script: a 40-line web shim followed by **`reader-bridge.js` copied byte-for-byte at build time
   from `apps/apple/ScienceReader/Resources/reader-bridge.js`** (not forked). The shim supplies
   `window.webkit.messageHandlers.reader.postMessage` (→ `parent.postMessage`), reads the index config from a
   non-executing JSON block, and exposes the bridge's own `__scienceReader*` functions to a fixed set of parent
   commands. The build computes this script's SHA-256 for both CSPs, so any other script in the frame is refused.
4. Render it in `<iframe sandbox="allow-scripts" srcdoc=…>`: an opaque origin with no access to the app's
   storage, keys or session. The parent accepts messages only from that frame's window and validates each
   (`headings`, `position`, `citation`, `selection`, `reference`, `figure`, `tags`, `invalid`) with the native bounds.

Contents, citation jumps with Back, the paper's own contents lists, figures and math fitting therefore behave as in
the app. Selections and reference taps report "Not yet available in the browser".

## Keys in the browser

The wire formats are unchanged and implemented with WebCrypto: AES-256-GCM, HKDF-SHA256, X25519 (Chrome 133+,
Safari 17+, Firefox 130+; an unsupported browser gets an explanation, never a fallback).

- **Device identity.** A fresh device UUID, a 32-byte enrollment challenge and an X25519 key pair generated with
  `extractable: false` for the private key. Stored per environment and account in IndexedDB (`gradstep` database)
  as a `CryptoKey`, so page scripts (including any injected script) can *use* it while the page is open but can never
  read or export its bytes. The public key is raw bytes.
- **Key bundle.** Never persisted in the browser. On each start the app reads `v1_key_state`, unwraps this device's
  envelope with the non-extractable key, validates the bundle exactly as Swift does, imports content keys as
  non-extractable AES-GCM keys, and keeps only the management token as bytes in memory (the server requires it).
- **New account (no keyring).** Generate the bundle and a recovery code in memory, show the code (copy, browser
  password save under the account email, "I saved this code"), persist the device identity, then call
  `v1_bootstrap_keys` with the recovery package and this device's envelope. A lost reply is recovered through this
  device's envelope (`v1_key_state`), as in `DeviceKeys.confirmRecoverySaved`. The code is never stored.
- **Recovery (keyring exists, no envelope for this browser).** The same algorithm as `DeviceKeys.recover`: decrypt
  the recovery package with the code, create a candidate device, persist it as a pending enrollment *before*
  `v1_request_enrollment`, self-approve with `v1_approve_enrollment` (management token from the recovered bundle),
  then activate it only after its server envelope authenticates. A lost reply or reload resumes the pending
  candidate; only a positive revocation retires it.
- **Approval by an existing device.** The RPC contract supports it (`v1_enrollment_requests` +
  `v1_approve_enrollment` from any device holding the bundle), but no device has an approval UI yet; Phase 1 does not
  offer the action. Adding it is native work (Phase 2).
- **Password AutoFill.** The recovery field is `<input type="password" autocomplete="current-password">` in a form
  whose hidden username is the account email, so a code the iPhone saved for `gradstep.ai` can be offered on
  `app.gradstep.ai` (Safari and Chrome match the registrable domain; unverified until tried on real devices).
- **Serialization.** Key operations hold a Web Lock per account (`navigator.locks`), so two tabs cannot bootstrap
  or enroll the same browser twice.
- **What "trusted device" means here.** This browser profile on this computer, for as long as its site data
  survives. Anyone who can use the signed-in profile can read what the app shows; non-extractable keys stop the raw
  key from being copied out, not an attacker who controls the browser or injected code while the page is open (the
  CSP, sandboxed reader frame and absence of third-party code reduce that risk). Not E2EE evidence by itself.
- **Storage eviction.** The app requests persistent storage (`navigator.storage.persist()`). If the browser still
  clears site data (manual clearing, private windows, Safari's 7-day cap on script-writable storage for sites not
  used), the device identity is gone: the next sign-in shows the recovery step again and creates a new device. The
  old server registration stays until device revocation exists (Phase 2). Nothing is lost on the server.
- **Sign out.** Clears the session and visible state; keeps this browser's device keys (like the native app), so
  signing back in does not need the code. "Also remove this browser's keys" (for a shared computer) deletes the
  IndexedDB record as well.
- **Device-local reading data** (Opened, Progress, last position) is sealed with a separate non-extractable AES-GCM
  key in the same IndexedDB record (account bound into the authenticated data); never sent anywhere.

## Authentication

Phase 1 is the email code only: `POST /auth/v1/otp` (`create_user: false`; sign-up stays invite-only and testers are
created in the admin Accounts tab) then `POST /auth/v1/verify` (`type: "email"`), six ASCII digits with
`autocomplete="one-time-code"`. Refresh uses `grant_type=refresh_token` behind a Web Lock (one refresh across tabs);
sign-out calls `logout?scope=local`. The session lives in `localStorage` under the environment name; another tab's
sign-out signs this one out. No redirect URL is needed for the email code, so **no Supabase Auth setting changes**.

Apple and Google web sign-in are Phase 2: Google needs `https://app.gradstep.ai/auth/callback` in the staging
redirect allowlist (PKCE, code-only callback, validated as natively), Apple needs a reviewed Services ID
configuration separate from native Apple sign-in (see [native authentication](NATIVE_AUTHENTICATION.md)).

## Edge function origin

Edge functions answer browsers only from the origins in the `ADMIN_ORIGINS` function secret (source of truth:
`infra/staging.json` `admin_origins`). Phase 1 adds `https://app.gradstep.ai` there so `reader-artifact` can be
called from the app; REST/Auth/Storage already allow any origin with the anon key. This is a function-secret change,
not an Auth setting or schema change.

## Contracts reused unchanged

| Contract | Browser module |
|---|---|
| [Encrypted wire format 1](ENCRYPTED_WIRE_FORMAT.md): event, recovery, device envelope, enrollment fingerprint | `src/lib/wire.ts` (WebCrypto) |
| Key RPCs: `v1_key_state`, `v1_bootstrap_keys`, `v1_request_enrollment`, `v1_enrollment_requests`, `v1_approve_enrollment`, `v1_devices` | `src/lib/keys.ts` |
| Library protocol format 2, `v3_library_page` / `v3_library_changes` (baseline + fixed-boundary catch-up) | `src/lib/library.ts` |
| Library commands `v2_begin_import`, `v2_retry_import`, `v2_cancel_import` (operation-ID replay) | `src/lib/library.ts` |
| Import progress detail (migration 029) and wording | `src/lib/progress.ts` |
| `reader-artifact` descriptor, `reader-bundle-v1`, `reader-index-v1`, `mathpix-reader-provenance-v2` | `src/lib/bundle.ts` |
| `reader-bridge.js` | copied at build time |
| Tag vocabulary (`supabase/functions/_shared/tag-vocabulary.ts`) | imported at build time |

No migration, RPC or format change is required for Phase 1.

## Verification

- **Interop (Vitest, `apps/web/tests/interop.test.ts`).** WebCrypto reproduces the frozen Swift-tested fixture
  (`envelopes-v1.json`) byte for byte from its fixed nonces/ephemeral key and opens it; fresh WebCrypto envelopes are
  decrypted and validated by the Swift `ScienceReaderWireCheck` executable (CryptoKit), and Swift's fresh envelopes are
  decrypted by WebCrypto; fingerprints match; wrong account/device/epoch and tampering are rejected.
- **Unit (Vitest).** Library page validation and reconciliation, arXiv parsing, progress wording, bundle verification
  against the app's real DPO sample bundle, frame document sanitization.
- **End to end (Playwright, local fixture backend).** Sign-in, new keys and recovery, library table, add paper with
  progress, reader contents/citations/figures, sign-out; 390 px phone and desktop widths, light and dark.
- **Live (`scripts/web-live-journey.mjs`).** A synthetic invited account (created and deleted by the script, never
  the owner's), code from the Auth admin API (no email sent), against the deployed app.gradstep.ai.

## Evidence

Filled in as each item passes; see [Decisions](../DECISIONS.md#browser-reader-at-appgradstepai-owner-decided-2026-10-07-phase-1-by-agent).
