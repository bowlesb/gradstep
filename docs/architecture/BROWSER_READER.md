# Browser reader

Status, 2026-10-08 UTC: **milestone 2 and Library columns/full abstracts deployed to https://app.gradstep.ai
against staging**, latest Pages `67f5547c` from `0fb60c7`. Encrypted browser chat first shipped in `68faefdb`
from `b4b7ad7`; the follow-up retains it. Latest deployment/smoke:
`.artifacts/takeover-20261008/{web-columns-deploy.log,web-columns-live-smoke.json}`; HTTP 200, CSP/HSTS and no browser
errors. A separate [hosted zero-credit journey](#hosted-milestone-2-zero-credit-journey--2026-10-08-utc) verifies
real key setup, reading and encrypted question/history recovery. A later [hosted diagram journey](#hosted-answer-and-diagram--2026-10-08-utc)
verified a paid answer, Mermaid rendering and recovery after reload. Auth was seeded; email/OAuth UI,
Safari support and a comprehensive E2EE claim remain outside those proofs. Key-storage/draft limits are below. Original reader/M1 deployment
history is retained in [deployment evidence](#deployment--2026-10-07).

## Scope

Phase 1 (this design): sign in with an email code → this browser becomes a device (approved from an iPhone/iPad by
QR code, the recovery code, or new keys for an account that has none) → library table with live import progress → add an arXiv paper → read a converted paper with
the same verified bundles and `reader-bridge.js` behavior → sign out.

Large-screen workspace, milestone 1 (**deployed 2026-10-07**, Pages deployment `a405d26c`, alongside native build 18; see
[Workspace](#workspace-legacy-large-screen-layout)): the legacy three-pane layout, a dense library table, contents tree,
find in paper, figure gallery, Feed, and Add by arXiv ID, DOI or link (`add-paper`).

Milestone 2 (**deployed 2026-10-08**, Pages `68faefdb`): encrypted paper/general chat, selection actions, passage links and diagrams in the existing right panel; see [Chat](#chat-milestone-2).

Remaining browser work (shown as unavailable where applicable): reference actions, tag editing, PDF upload,
Apple/Google web sign-in, device list and revocation, offline reading and purchases.

## Workspace (legacy large-screen layout)

Owner, 2026-10-07: the first browser build "needs a ton of polish… the old science reader web code… used all the space
and real estate much smarter… copy that as a starting point." Milestone 1 rebuilds the signed-in UI on
`reference/web/app/page.tsx`'s desktop modes (Library; Browse = library beside the paper; Reader = paper beside chat),
merged into one workspace. Sign-in, key setup/approval/recovery, library sync, commands, verified bundles, the reader
frame, CSP and headers are unchanged. Code: `src/ui/Shell.tsx` (panes), `App.tsx` (routes, top bar, shortcuts),
`Library.tsx`, `Reader.tsx`, `Figures.tsx`, `Feed.tsx`, `ChatPane.tsx`, `prefs.ts`.

| Area | Behaviour |
|---|---|
| Panes | Left rail · center · chat pane. Drag a divider (pointer captured, so the paper frame can't swallow it; arrow keys; double-click resets); dragging well past the minimum collapses it to the legacy edge handle (⋮⋮). Widths and per-route visibility are kept in this browser (`localStorage` `gradstep.layout.v1`; unavailable storage falls back to defaults). Defaults follow the legacy modes: Library and Feed without chat, a paper with chat. The center keeps ≥ 440 px: the chat narrows first, then becomes a drawer. Below 1,100 px the chat is a drawer; below 760 px the rail is too. |
| Top bar | Rail toggle, brand, Library · Feed · Chats, library search (centered), Add paper, appearance (light/dark; System in the account menu), chat-pane toggle, account. |
| Library | Rail: All papers, Unread, Reading, Failed, Archived and the tags, with counts (chips with a tag menu when the rail is hidden). Center: table Title (2 lines) · Authors · Year · Tags (click to filter) · Added · Opened · Progress. M1 dropped columns by container width; the [local column follow-up](#library-column-follow-up--local-verification-2026-10-08-utc) replaces that with explicit choices and horizontal scrolling. Live import progress and Retry / Remove / "Get credits in the app" stay inline. Search, filter and sort survive opening a paper; while reading, position reports don't re-sort the library. |
| Paper | Rail tabs: Contents (the bridge's outline depths; current section from reading-position reports) and Library (compact list, the legacy Browse; top-bar search switches to it). Toolbar: Contents, title, citation Back, Find, Figures (count), text size, Chat. |
| Find | App-owned code in `frame-shim.js` (the bridge is unchanged): case-insensitive matches across inline elements but never across blocks, CSS custom highlights, the current match in the upper third, starting from the reading place; Enter/Shift-Enter; ≤ 1,000 matches. |
| Figures | Gallery of the verified images (data URIs of verified bytes), one figure in its own sandboxed figure frame, ←/→, Escape back to the gallery, Show in paper (bridge `__scienceReaderShowFigure`, with citation Back). |
| Appearance | The frame's `prefers-color-scheme` follows the system (the iframe's `color-scheme` didn't change it in Chromium), so the shim rewrites the documents' own `prefers-color-scheme` conditions to the chosen scheme and restores them for System; tested by toggling both ways. |
| Feed | `discover?category=` for up to six topics from the library's arXiv categories (native rules and names); the legacy card grid; + Add to library through the library command. |
| Add paper | arXiv IDs stay `v2_begin_import`; anything else goes to `add-paper` with `capabilities: ["web_import"]` only. Outcomes use the native wording, adapted: no upload or device download is offered, and a blocked or closed paper's https link can be opened. |
| Shortcuts | `/` or ⌘K search, ⌘F find (paper), `[` rail, `]` chat, `?` help, Esc closes/clears, ↑/↓ between papers, ←/→ figures. The shim forwards these while the paper has focus (validated `key` messages). |

The frame script hash changes with the shim and is computed at build for both CSPs, as before. Local verification
(production CSP, Chromium): `e2e/layout.spec.ts` at 1440×900 and 1920×1080 in light and dark, plus a 390 px journey;
the existing journeys follow the new layout. Screenshots: `.artifacts/web-layout/`. Claude subsequently deployed milestone 1 as Pages `a405d26c`; these layout journeys remain local fixture evidence, not a hosted signed-in test. Milestone 2 was subsequently deployed as recorded above.

### Library column follow-up — local verification, 2026-10-08 UTC

**Deployed as Pages `67f5547c`; not part of the earlier `68faefdb`.** The owner's request to keep chosen columns available
now applies to the browser Library. Columns opens a native dialog with checkboxes for Authors, Year, Tags, Added,
Opened and Progress; Title is always shown. Reset restores defaults; Escape/Done returns to the table with focus
restored to Columns. A horizontal scroll region stays inside the center pane; the title and header row remain pinned. When
there is overflow, left/right buttons expose scrolling even when the OS hides its scrollbar. Arrow keys scroll
from the region, a title or a sortable header; focusing another header reveals it beside the pinned title.

The finite preference `gradstep.library.columns.v1` contains only column IDs, rejects malformed/duplicate/unknown
or oversized input, and falls back safely when site storage is unavailable. Initial/Reset defaults are Year and
Progress below 760 px, all details on wider windows. An explicit choice is kept across reloads and width changes;
resizing never hides a chosen column. Hidden Authors retains the first author under the title. Hidden Progress
does not remove import status or retry/credit actions. A hidden sort column is named above the table. Row memoization
and the active import's own timer remain; scroll affordances update in a separate component.

Verification: two preference unit cases, production TypeScript/build, and six Chromium production-CSP journeys
across desktop/390 px. These cover selection/Reset, persistence, unavailable storage, keyboard sorting/focus,
horizontal title pinning, sticky headers, resize, retry with Progress hidden, return from a paper, and the existing
4,000-entry live-update/search/tag journey with every column enabled. Local samples: library ready in 1,026/576 ms,
search 278/255 ms (desktop/390 px); 7.5/6.2 ms script time during each roughly 3.4-second import observation window.
These are local fixture measurements, not hosted capacity or Safari evidence. Light/dark screenshots:
`.artifacts/web-columns/`; capacity metrics: `.artifacts/web-library/chosen-columns-{desktop,phone}-metrics.json`.

The combined source also passes four desktop/390 px Library-column and full-abstract Feed workflows. Expanded
Feed cards span the content width and show the entire title and opted-in full abstract; a bounded excerpt is
labeled when necessary. Live discover v78 preserves old clients' preview payload and serves new clients the
additive `abstract=full` response. Three hosted zero-credit requests verified legacy compatibility, a complete
source-matched 1,604-character abstract, and 25 RSS results in 63,142 bytes, then deleted the test accounts:
`.artifacts/takeover-20261008/discover-full-hosted-smoke.json`. This metadata check does not exercise paid chat.

## Where it lives

| Surface | Origin | Host |
|---|---|---|
| Info site (`web/site/`) | `https://gradstep.ai` | Cloudflare Pages `gradstep-site` |
| Browser reader (`apps/web/`) | `https://app.gradstep.ai` | Cloudflare Pages `gradstep-app`, custom domain (proxied CNAME `app` → `gradstep-app.pages.dev`) |

`gradstep.ai/app`, `/app/` and `/app/*` redirect (301) to `https://app.gradstep.ai/` (path kept) via
`web/site/_redirects`. A
separate origin isolates the reader's IndexedDB keys, session and storage quota from the info site, and lets the app
have a strict CSP without constraining the marketing pages. Both projects are on Cloudflare's free tier (static assets,
no Functions): $0/month.

Deploy with `node scripts/deploy-web.mjs app` (reader) or `node scripts/deploy-web.mjs site` (info site): builds
locally and uploads with the repository's locked Wrangler 4 and the dedicated Cloudflare credential in `.env.staging`.
The build points at **staging** (`coxhjvqpflgxkleydati`); production stays unprovisioned.
The Supabase anon key is a public client identifier (as in the iOS binary and the admin site), embedded at build time.
The build restricts exposed environment-variable names to the URL/anon key, and the deploy script gates the values:
the URL must be the staging project, the key must be a JWT with role `anon` for that project, no other
`.env.staging` value may appear anywhere in the built output, and the generated `_headers` must carry the strict CSP
for exactly that backend plus HSTS. Local `apps/web/.env*` files are refused so the deploy cannot pick up stray values.

## Stack

The owner selected React for both the reader and admin on 2026-10-07 after the
[React/Svelte evaluation](WEB_FRAMEWORK_EVALUATION.md), which includes source audits and a reproducible
performance experiment. Keep the protocol/crypto services framework-neutral and share presentation components
where useful; customer and admin authentication remain separate.

Vite 8 + React 19 + TypeScript (the admin site's house style) as a self-contained package (`apps/web/package.json`,
its own lockfile, so the deployable has reproducible dependencies independent of Edge/admin tooling). Vitest for
unit/interop tests, Playwright for end-to-end. **No `supabase-js`**: a ~250-line fetch client mirrors the native
`BackendClient` contracts (bounded bodies, `redirect: "error"`, a single refresh in flight, finite error mapping, no
provider bodies in messages), and keeps realtime/storage SDK code out of a page that holds keys.

## Security headers (`apps/web/public/_headers`, generated at build)

```
Content-Security-Policy: default-src 'none'; script-src 'self' 'sha256-<reader frame script>' 'sha256-<diagram frame script>';
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
   The document stays mounted while publication details/tags change: those updates use the native bridge's
   `__scienceReaderSetPaperLine` / `__scienceReaderSetPaperTags`, preserving the reading place, selection and
   citation-return state. Updates received during download are applied when the bridge is ready, before restoring
   the saved reading place. Account/item/artifact/availability changes still retire the old reader.

Contents, citation jumps with Back, the paper's own contents lists, figures and math fitting therefore behave as in
the app. Selections offer Explain, Why it matters, Related and Add paper. Reference taps still report "Not yet available in the browser".

## Keys in the browser

The wire formats are unchanged and implemented with WebCrypto: AES-256-GCM, HKDF-SHA256, X25519. Browser versions
alone do not establish storage support. An unsupported browser gets an explanation, never a plaintext or
extractable-key fallback. **Safari/WebKit has a current key-persistence blocker**, below; X25519 generation
succeeding is insufficient.

- **Device identity.** A fresh device UUID, a 32-byte enrollment challenge and an X25519 key pair generated with
  `extractable: false` for the private key. Stored per environment and account in IndexedDB (`gradstep` database)
  as a `CryptoKey`, so page scripts (including any injected script) can *use* it while the page is open but can never
  read or export its bytes. The public key is raw bytes. After each device-record write commits, read it back and
  prove the restored private key can open a disposable envelope addressed to its public key and the restored local
  AES key decrypts a probe. Existing records undergo the same check on setup/retry/reload, so a failed write check
  cannot be bypassed by retrying. Only then may bootstrap/enrollment rely on the saved identity. Pending candidates
  are checked as well; failed validation preserves their material for recovery/investigation.
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
- **Approval by an existing device (QR), the default on the restore screen.** See
  [Approving this browser from another device](#approving-this-browser-from-another-device).
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
  device and activity records in one transaction under the key operation lock before returning to sign-in. A failed
  local removal stays visible and retryable. Late reading saves cannot recreate a forgotten/replaced device's data.
- **Device-local reading data** (Opened, Progress, last position) is sealed with a separate non-extractable AES-GCM
  key in the same IndexedDB record (account bound into the authenticated data); never sent anywhere. The reader
  waits for this local load before mounting, including on a direct paper URL, so a fast bundle cannot overwrite a
  saved place before it is restored. Missing/unreadable activity settles to an empty map and still permits reading.
  Every bounded bridge position report updates memory; encrypted writes are debounced and serialized separately.

## Approving this browser from another device

Deployed 2026-10-07 with native build 18 and Pages `a405d26c`. A full hosted camera/approval journey is still unverified. Native entry: Settings › Account › **Add a device**. Protocol and
limits: [PRIVACY_AND_SYNC.md](PRIVACY_AND_SYNC.md#approving-a-new-device-qr).

- **Restore screen** (`ui/Keys.tsx`, `ui/Approve.tsx`). "Restore your private library" leads with the QR code, the
  six-digit number ("Your phone should show 275 895") and "Waiting for approval…". **Use recovery code instead** switches
  to the existing form (Password AutoFill unchanged), which has **Approve from your phone instead**. Both paths share one
  pending recipient and request under the key lock, so switching never creates a second device.
- **QR** (`lib/approval.ts`): the 97-character `GSDA1` payload drawn locally as an inline SVG path by `uqr` 0.1.3 (MIT,
  zero dependencies, a port of Nayuki's generator; ECC M, version 6, white quiet zone in both themes). No network
  request, canvas, inline script or CSP change. Rendered screenshots decode with CoreImage's QR detector.
- **Polling** (`checkApproval`): `v1_key_state` for the pending device with bounded backoff (2 s, ×1.5, at most 10 s);
  about once a minute `requestApproval` re-checks the request and renews it for the same recipient if it expired. A
  connection failure shows "Can't reach Gradstep. Still trying…" and keeps waiting; after 30 minutes it stops with
  **Show a new code**. An envelope that doesn't open with this browser's key is an error and the pending recipient is
  kept.
- **Tests**: `tests/approval.test.ts` (fixture vectors, request/renew/approve/refuse flow), the Swift interop test (Swift
  approves a non-extractable WebCrypto key from its QR text), and `e2e/approval.spec.ts` (the fixture's "iPhone" reads the
  rendered QR text, checks the fingerprint independently in Node, and approves; reload resumes the same QR; switching to
  the recovery code approves the same request).

## Authentication

Phase 1 is the email code only: `POST /auth/v1/otp` (`create_user: false`; sign-up stays invite-only and testers are
created in the admin Accounts tab) then `POST /auth/v1/verify` (`type: "email"`), six ASCII digits with
`autocomplete="one-time-code"`. Refresh uses `grant_type=refresh_token` behind a Web Lock (one refresh across tabs);
sign-out calls `logout?scope=local`. The session lives in `localStorage` under the environment name; another tab's
sign-out signs this one out. No redirect URL is needed for the email code. For later web OAuth, staging's Auth redirect
allowlist was extended on 2026-10-07 (appended, existing `sciencereader://auth/callback` kept) with
`https://app.gradstep.ai` and `https://app.gradstep.ai/auth/callback`; `site_url` is unchanged.

Each successful login receives an opaque client lifetime ID, stored alongside the tokens; refresh preserves that
ID. This is local session metadata, not a server credential or backend format change. Legacy browser sessions
without it retain a legacy marker through refresh until their next login. A changed lifetime/account, logout or
cross-tab storage clear synchronously aborts the old auth scope. React's external-store snapshot includes a
generation so even a batched logout/same-account login remounts key setup and clears the session-owned reader
cache. Refresh preserves the UI and publishes its token before releasing the cross-tab lock; a shared in-flight
promise also serializes same-tab refresh when Web Locks are unavailable.

Key operations, library work and bundle downloads retain the auth scope they started in, in addition to their
view's cancellation. A stale refresh, abandoned email verification or delayed local sign-out cannot overwrite/end
a newer login. Caller cancellation and request deadlines both remain active through response-body reading.
Cancellation does not undo an already-sent mutation; existing operation-ID replay and pending enrollment recovery
still determine its outcome.

Apple and Google web sign-in are Phase 2: Google needs `https://app.gradstep.ai/auth/callback` in the staging
redirect allowlist (PKCE, code-only callback, validated as natively), Apple needs a reviewed Services ID
configuration separate from native Apple sign-in (see [native authentication](NATIVE_AUTHENTICATION.md)).

## Edge function origin

Edge functions use the `ADMIN_ORIGINS` secret, set from `infra/staging.json` `admin_origins` on every
`deploy-staging.py` run. A probe before the 2026-10-07 reader deployment showed later function deploys had reset it to
the local origins (preflight from `https://app.gradstep.ai` → 403), so the manifest now lists
`https://app.gradstep.ai` and the functions were redeployed from main with
`--skip-migrations --skip-checks --defer-activation` (pipeline worker untouched). Preflights from the reader origin now
return 204 with `Access-Control-Allow-Origin: https://app.gradstep.ai`; other origins still get 403. Origin
permission does not replace authentication or artifact authorization.

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

### Command acknowledgements and complete library views

The browser follows the publication rules in [native library commands](NATIVE_LIBRARY_COMMANDS.md): a command
response is a receipt, never a partial library update. Cancel can change both an import and its item while returning
only the import. Add freezes the cursor from the last rendered complete snapshot; partial background pages cannot
grant a newer observation. Before the first complete load, Add stays disabled.

Each receipt stays pending until a read begun after that response completes a fresh boundary through
`max(result.seq, entry.state_seq)`. A resumed older fixed boundary finishes first. The completed target must also
match the receipt's identity and cover its state/intent revision; a high account cursor alone is insufficient.
Baselines return current rows under a fixed creation boundary, so no view is complete while a row is ahead of its
cursor or a mapped item is missing. Command replies never advance the account cursor.

Concurrent commands retain separate pending owners. An older read may publish its own coherent complete view,
but cannot resolve a receipt received after it began. A failed follow-up read retains the last complete view and
pending receipt, displays a refresh message, and leaves the action disabled. A subsequent refresh resolves it
without resending the mutation. Recovered Add closes and clears its accepted form; its source stays read-only
while waiting. Revision conflicts show current state and an explanation, with no automatic new command.

This is still the online Phase 1 client: requests/receipts live only in the current login's memory. It is **not** the
native durable encrypted command queue, and reloading after two lost command replies cannot recover an exact
pending request. A persistent command outbox needs the account/deployment and atomic-cache design described in
[library capacity](LIBRARY_CAPACITY.md), before browser offline mutation support.

## Verification

- **Interop (Vitest, `apps/web/tests/interop.test.ts`).** WebCrypto reproduces the frozen Swift-tested fixture
  (`envelopes-v1.json`) byte for byte from its fixed nonces/ephemeral key and opens it; fresh WebCrypto envelopes are
  decrypted and validated by the Swift `ScienceReaderWireCheck` executable (CryptoKit), and Swift's fresh envelopes are
  decrypted by WebCrypto; fingerprints match; wrong account/device/epoch and tampering are rejected.
- **Unit (Vitest).** Library page validation and reconciliation, arXiv parsing, progress wording, bundle verification
  against the app's real DPO sample bundle, frame document sanitization.
- **End to end (Playwright, local fixture backend).** Sign-in, new keys and recovery, library table, add paper with
  progress, reader contents/citations/figures, sign-out; 390 px phone and desktop widths, light and dark.
- **Hosted zero-credit journey (2026-10-08).** Real staging-backed key setup, cached-paper reading, encrypted
  question persistence and recovery passed in Chromium with complete account cleanup; details below. Real Auth
  credentials were seeded through a synthetic-account password login. Email-code/OAuth UI and a paid answer
  remain separate acceptance, and no reusable `scripts/web-live-journey.mjs` command is claimed here.

## Evidence

### Deployment — 2026-10-07

Deployed 21:00 PDT from `worktree-agent-a382af5d587717432` (main `937ef34` + deploy script/config). Pages free tier,
$0/month. Checked live:

- `https://app.gradstep.ai/` → 200 over HTTPS (Cloudflare edge certificate, Pages custom domain `active`);
  `http://` → 301 to HTTPS. Response headers match the policy above: the CSP with the frame-script hash and
  `connect-src https://coxhjvqpflgxkleydati.supabase.co`, HSTS, `X-Frame-Options: DENY`, nosniff, `no-referrer`,
  COOP/CORP `same-origin`, the Permissions-Policy. `index.html`/`/` are `no-cache`; `/assets/*` are
  `public, max-age=31536000, immutable`. Deep links (e.g. `/paper/x`) fall back to the app shell (200).
- The zone has Cloudflare Web Analytics automatic injection enabled (gradstep.ai pages carry its beacon). On the
  reader the CSP refused it; `_headers` now adds `Cache-Control: no-transform` on every path, after which no beacon is
  injected and a Chromium load shows no console errors. The info site still has the beacon (unchanged).
- `gradstep.ai/app`, `/app/`, `/app/papers/x` → 301 to `https://app.gradstep.ai/…`; in Chromium, `gradstep.ai/app`
  lands on the reader's Sign in page.
- Hosted email-code step: a synthetic invited account (Auth admin API, address in Resend's `delivered+…@resend.dev`
  test inbox) entered on the live page; `POST /auth/v1/otp` returned 200 and the page reached "Enter your code" with
  the `one-time-code` field focused. The account row and Auth user were then deleted (admin `deleteUser` needs the
  `app_private.accounts` row removed first, as in `scripts/check-native-sync.mjs`); a follow-up query found no rows.
- At this first-deployment checkpoint, code verification, key setup/recovery, library, Add, reading and Safari
  had not been verified. The later milestone 2 proof below closes only its stated scope. A deep link's HTML response carried only `no-transform` (no
  `no-cache`), so browsers may revalidate it less eagerly than `/`.

The integration worktree recovered the browser implementation and hardened session lifetime/async ownership on
2026-10-07. Merging current `main` through `5f95c97` preserved these changes; the combined source passed a fresh
unit/interop, production-build and full production-CSP browser run. Local evidence is separate from deployment evidence:

- Production build and **71 unit/Swift–WebCrypto interop tests** pass. New tests cover stale refresh success/failure,
  same-account/cross-tab lifetimes, abandoned verification, a stale key operation finishing crypto, bounded response
  bodies with caller cancellation, ordered encrypted reading-place persistence, and non-null unusable/extractable
  stored keys that remain refused on retry without losing pending enrollment material. Frame contents accept the
  same maximum of 1,000 headings as the Mathpix bundle verifier; the boundary is regression-tested. Reconciliation
  tests cover interrupted fixed boundaries, incomplete baselines, receipt floors/targets, whole-page rejection,
  exact command replay and late cancelled reads.
- Production-CSP Playwright: **42 passed, 15 capability skips** (2026-10-07). All 38 desktop/narrow Chromium cases
  pass, including no-reload sign-out/recovery, reauthorization of a reopened reader, a late encrypted save after
  forgetting keys, a delayed sign-out after another tab logs in, live tag updates while reading/selected/at a
  citation, tags arriving during a fresh download with a persisted nonzero position, and reopening a direct paper
  URL while activity decryption is deliberately delayed. A 4,000-entry library also passes progress, search,
  live tag changes, filters, sorting and keyboard link activation. Seven command journeys per Chromium viewport
  verify stale in-flight reads, failed-refresh recovery, displayed-cursor capture, concurrent commands, Add form
  recovery and revision conflicts. WebKit passes sign-in cancellation, unsupported-key guidance, invite-only
  messaging and CSP checks. Its fifteen key-dependent journeys are blocked
  by the engine issue below; these are not Safari workflow passes.
- Seventeen desktop journeys also pass against the development server with React Strict Mode's effect cleanup/restart:
  returning reader, new keys/reload, abandoned verification, late reading save, delayed sign-out and enrollment
  persistence, live tags, tags arriving during download, delayed local activity loading, the 4,000-entry library and
  all seven command journeys. The final Add input/submission guard also passes all 14 desktop/narrow production
  command cases. Reproduce with
  `WEB_E2E_DEV=1 npm run e2e -- --project=desktop --grep-invert 'address without|security headers'`;
  the CSP-header test specifically requires the production preview server.
- The React/Svelte experiment's successful WebKit table tests do not exercise crypto/key storage and therefore
  do not imply that the complete browser app works there.
- No deployment, live Safari profile, real Google/Apple browser OAuth, browser offline reader or browser chat has
  been verified by these local checks.

### Safari/WebKit release gate

On this Mac, a standalone IndexedDB probe reproduced the problem in Playwright WebKit 26.6: ordinary objects and
non-extractable AES-GCM keys round-trip, but X25519 private and public keys read back as null (a whole device
record can read as undefined). Chromium 153.0.8010.12 reads and uses the private key successfully. The same
failure is reported in [WebKit bug 312279](https://bugs.webkit.org/show_bug.cgi?id=312279), still NEW when checked
2026-10-07. This is evidence from the test engine plus an upstream Safari report, not a run in the owner's Safari
profile.

The initial generation-only feature check allowed setup to appear successful, then asked for recovery after
reload and could not save reading places. Device writes now require successful read-back and actual key use
before bootstrap/enrollment; loading an existing device repeats validation before any enrollment RPC. The UI
explains unsupported storage instead of claiming success. The independent
`e2e/key-capability.ts` probe automatically enables full journeys on engines that pass; an explicit test checks
safe refusal without server enrollment on engines that fail.

**Full Safari support remains unfinished.** Any alternative such as locally wrapping an exportable X25519 key
would change the documented key-custody properties and requires a separate design/review; it is not silently used
to bypass this check. The current fix keeps non-extractable private keys and prevents unreliable enrollment.

### Reader integration and remaining capacity work

The cache is now owned by one auth lifetime and keyed by account/item/artifact/availability revision, with at most
three verified bundles. Metadata and tag updates use the existing reader bridge; an actual tag update no longer
recreates `srcDoc` or loses the current reading interaction. Large-library capacity and rendering work follow the
[framework evaluation](WEB_FRAMEWORK_EVALUATION.md#large-library-architecture-findings).

Immediate departure remains a separate reading-position edge: leaving before the iframe's next asynchronous
scroll report reaches the parent retains the last received position. Removing the extra two-second throttle fixes
dropped reports, but a guarantee for the final movement needs a bounded capture/ack before app-owned navigation,
with citation-return semantics preserved. Abrupt process termination cannot guarantee a final encrypted write.

### Library update isolation — 2026-10-07

Unchanged catch-up pages now retain the published entries and progress marks. Each Library view owns a weak
row-facts cache keyed by immutable reconciler entries; a changed entry invalidates its facts even when its ID is
unchanged. Memoized rows receive stable callbacks and primitive activity/pending values. The one-second display
clock belongs to active import rows, with cleanup on filtering, navigation and sign-out; ready papers and the
table's filters/sorts no longer run on every progress tick. Hidden documents do not advance the display clock.

`e2e/library.spec.ts` exercises the real client against 4,000 retained entries through the existing paged fixture
protocol, including an archived item and active import (3,999 displayed rows). It verifies that progress advances,
search keeps focus, a live same-ID tag update changes search membership, tag filters and Year sort work, and Enter
on a result opens the verified reader. Production and Strict Mode pass at the existing bound. Screenshots at
1,280 px and 390 px preserve the existing layout.

Local production observations on this Mac, each over approximately 3.4 seconds of progress and empty catch-up:

| Viewport | Before: script time | After: script time | Later production observations |
|---|---:|---:|---:|
| 1,280 px | 825 ms | 18 ms | 9–13 ms |
| 390 px | 1,097 ms | 9 ms | 10–11 ms |

These are a small set of local Chromium CDP measurements, not throughput guarantees. The test's
`recoveryToLibraryMs` includes recovery crypto, fixture pagination and rendering; `searchMs` includes Playwright
input/assertion overhead. Raw reports and before/after screenshots are under `.artifacts/web-library/` (the first
baseline reports call the recovery interval `loadMs`). Reproduce with
`WEB_LIBRARY_LABEL=<label> npm run e2e -- e2e/library.spec.ts --project=desktop --project=phone`.

The DOM still contains all 3,999 displayed rows; windowing, larger capacity and browser offline storage are not
implemented by this change. A separate review recommends evaluating React Aria's
[Table](https://react-aria.adobe.com/Table) with its measured-height
[Virtualizer](https://react-aria.adobe.com/Virtualizer), preserving page scrolling and managed keyboard focus.
Its [window-scrolling release](https://react-aria.adobe.com/releases/v1-17-0) supports this layout, but that adapter
has not been built or verified. The design must also preserve library query/filter/sort and a row anchor through
reader navigation, handle disappearing focused imports, and offer full results for browser Find/printing.
No new dependency or server contract has been adopted for windowing yet.

The [capacity proposal](LIBRARY_CAPACITY.md) separates these client rendering improvements from the durable cache,
compact sync and paged query changes needed for larger libraries. The present 4,000 bound counts retained entries,
including import intents and removed items; it is not a 4,000-visible-paper entitlement.


## Chat (milestone 2)

Recovered implementation `167d0a1` merged into main and deployed 2026-10-08 as Pages `68faefdb` from `b4b7ad7`.
The implementation review/tests used local fixtures without paid provider requests; hosted smoke is separate.
The existing right panel uses unchanged wire/RPC contracts in [Chat](CHAT.md) and
[Privacy and sync](PRIVACY_AND_SYNC.md). No schema, identity, key-custody or browser-library-command change.

- **Paper and General** keep separate composers, drafts and selected conversations. History opens a searchable
  table with All/This paper/Paper/General filters, title/date sort, message counts, drafts and encrypted deletion.
  Concurrent branches require an explicit branch choice; no history is silently merged into the prompt.
- **Encrypted history:** `v2_pull_events` checks contiguous cursors, ciphertext digests, decryption and native
  `PrivateEvent` validation before atomically publishing a page in memory. `v1_append_event` carries only sealed
  envelopes. IDs and ciphertext survive retries while the tab lives; a new epoch refreshes this device's envelope
  before re-sealing unacknowledged events. The pull cursor never advances from an append receipt.
- **Save before requesting:** a new conversation and question are sealed together locally, then acknowledged by
  the existing append RPC before any paid request. The server RPC appends one event at a time; losing the connection
  between the root and question can leave an empty root on the server. The tab retains the exact pending question
  for retry and never starts AI until it is acknowledged. This is not a new atomic server batch protocol.
- **Ownership:** a task captures its composer, question, document and login lifetime. New chat, mode switches,
  hiding the panel and reader navigation do not redirect an answer. Newer typing, including an identical
  replacement, survives an earlier save. Stop seals nonempty text as interrupted; refusal discards partial text;
  EOF, truncation and transport loss remain visibly interrupted. Failed answer saves retry the same encrypted
  events without another provider call. Explicit sign-out stops and drains active answers before retiring
  credentials; external logout/session replacement immediately aborts and cannot write into a new login.
- **Consent and costs:** the versioned `cloud-ai-v2` choice is account/environment scoped metadata in browser
  storage. The dialog names Anthropic, Tavily and backup search processing/possible retention. Only the saved
  question's bounded branch, passage and paper context go to the chat request. Credit balance/held credits come
  from `v1_credit_balance`; final charges come from SSE. Server admission remains authoritative. Purchasing stays
  in the Apple app; insufficient credits and paused/rate-limited answers have explicit wording.
- **Reading answers:** lazy-loaded Markdown-it 15.0.2 and Temml 0.14.0 render Markdown, tables and MathML with
  HTML/images disabled, math trust disabled and a DOM allowlist. Math tokens are parsed in Markdown context, not
  interpolated into already generated HTML. Code and incomplete formulas stay text. Typesetting is coalesced to
  80 ms while streaming; scrolling follows only near the bottom, with a Latest message control when reading above.
  HTTP(S)/mailto links reject credentials/control characters and preview the exact destination before navigation.
  Fonts are bundled/local. No CDN, provider script or remote image enters the account page.
- **Selection loop:** Explain, Why it matters, Related and Add paper use LaTeX from the verified equation index,
  never a frame-supplied formula. Native-format encrypted passage anchors support Go to passage and underlined
  passage marks via the existing reader bridge. The reader stays mounted; citation Back and selection behavior
  are preserved. The native 500-mark bound remains; missing passages report a clear message.
- **Diagrams:** the unchanged metered `create_diagram` tool produces a native-compatible encrypted diagram event.
  View diagram lazily loads the exact pinned native Mermaid 12.1.0 asset into `sandbox="allow-scripts"` without
  same-origin, navigation, storage or network authority. Both page and frame CSP name the reviewed script hash.
  Strict mode, 16 KB source, 100 edges, fixed theme/options, no config directives/frontmatter, no HTML labels;
  scripts/embedded HTML/images/link attributes are removed from rendered SVG. The parent accepts only a finite
  result with this frame's `contentWindow` and fresh request ID; SVG never enters the account DOM. A ten-second
  presentation timeout retires the frame, but is not a hard CPU/process-isolation guarantee. Broken/unsupported
  diagrams keep their source and show failure. No automatic metered repair request is made in this milestone.
  The viewport initially fits the whole graph; Fit and bounded 1–4× zoom preserve the visible center while
  enlarging text. Zoom resizes the opaque frame, without changing its permissions or reading its DOM.

### Bounds, durability and remaining gaps

History is **memory-only in this browser**: 20,000 retained events / 64 MiB ciphertext, failing visibly at the
bound instead of treating a partial pull as a complete history. Pending events are capped at 128 / 8 MiB.
Unsent drafts are limited to 128, 200 KB each / 2 MiB combined, kept only in this tab. Visible copy, sign-out
confirmation and a browser departure prompt warn about unsaved work. Reload/process loss before acknowledgement
can lose a pending edit or answer; there is no durable browser outbox, offline chat, or claim that the native local
journal's crash guarantees have been reproduced. Successfully acknowledged events can be decrypted after reload
or on another approved/recovered device. Abrupt logout elsewhere may prevent a partial answer from being saved.

At most three local streams run at once, each ≤2 MiB of SSE, ≤200 KB saved text, 45-second idle timeout and
210-second total client deadline. Formula parsing limits individual source to 12,000 characters, 500 formulas and
1,000 macro expansions; unsupported output remains readable source. These local bounds complement server controls.
The full native query/history cache capacity has not been benchmarked in this browser.

Still separate: durable encrypted browser drafts/outbox/offline history, broader provider-backed acceptance,
rendered-diagram automatic repair, answer-quote actions, richer reference actions and cross-device reading positions.
Safari's non-extractable X25519 persistence blocker is unchanged: the existing capability gate refuses enrollment;
Chromium fixture results do not establish Safari support or a new E2EE/provider-retention guarantee.

Local evidence: unit/controller tests cover acknowledgement-before-paid-send, stable retries, identical newer drafts,
stream ownership, Stop/sign-out, failed answer save, refusal/EOF, account retirement, atomic batch rollback and
WebCrypto ↔ Swift event interoperability. `e2e/chat.spec.ts` uses real WebCrypto with the production CSP and a
localhost-only fake backend: consent, encrypted reload/second browser profile, Markdown/math, links, paper/general
contexts, credit failure, selection/passage and real Mermaid rendering including malformed/directive refusal.
The external-link/media fixture renders with those affordances removed; a direct remote-CSS probe in that same
opaque frame raises a CSP violation without reaching the network interceptor. Continuous 15 ms single-character
chunks are visible before the stream ends, guarding against a reset-on-each-delta render debounce.

Final local checks for this change: **189 unit/interop tests pass**, production TypeScript/Vite build passes;
production-CSP chat journeys **8 pass / 6 intentionally desktop-only cases skip on the phone project**, then the
**2 additional focused diagram/network and continuous-stream journeys pass**. Three development StrictMode chat
journeys and the existing WebKit key-persistence refusal journey also pass. Earlier layout/reader coverage passed
apart from obsolete M1 chat-placeholder assertions, which were replaced and the affected reader journey rerun.
These are separate local runs, not a hosted acceptance run. The build reports its existing initial bundle above
500 KB plus the deliberately lazy Mermaid asset (about 1.6 MB gzip); neither Mermaid nor the math typesetter is
loaded on the sign-in/library path.

Screenshots: `.artifacts/web-chat/desktop-paper.png`, `phone-paper.png`, `diagram.png`, `credit-error.png` and
`dark-partial.png`; no customer data or paid requests.

### Combined release verification — 2026-10-08 UTC

After merging the native selection-menu changes to the shared `reader-bridge.js`, combined main `b4b7ad7`
passes 9 targeted production-CSP journeys with 7 intentional phone skips: paper/general encrypted reload and a
second browser profile at desktop/phone sizes; selection→chat→passage; streaming/navigation/Stop and credit error;
valid, malformed and directive-refused Mermaid; continuous 15 ms chunks; and blocked diagram links/media/remote
CSS. The two frame script hashes were rebuilt from that exact bridge and pinned Mermaid asset. Screenshots remain
under the recovered web worktree's `.artifacts/web-chat/`. Hosting is confirmed separately by Pages deployment
`68faefdb` and the live HTTP 200/header/no-error smoke. The later paid journey is recorded separately below.

### Hosted milestone 2 zero-credit journey — 2026-10-08 UTC

On Pages `68faefdb` / source `b4b7ad7`, a disposable staging account with zero credits exercised Chromium:
real key generation/persistence and server bootstrap through the UI; cached DPO Add ready in 4.9 s; verified
reader with 271 MathML nodes; passage actions; and two acknowledged ciphertext appends before the server's
insufficient-credit refusal. The unanswered question decrypted after reload and in a second isolated browser
recovering the real keys through the UI. Persistent browser storage did not contain the plaintext test question.
No successful AI answer was generated.

Server readback recorded zero provider attempts, usage events, charged micro-USD or credit holds, and two
encrypted events. Account deletion returned 200/complete; no page or console errors were observed. Evidence:
`.artifacts/takeover-20261008/hosted-browser-zero-credit-summary.json`. This used a real Auth session seeded by
an admin-created synthetic account's password login: it does **not** verify the email-code/OAuth interface,
email delivery, Safari key persistence, physical-device approval or a paid streamed answer.

### Hosted answer and diagram — 2026-10-08 UTC

On Pages `67f5547c` / source `0fb60c7`, a disposable staging account generated a real general-chat answer with
`create_diagram` in 4.9 seconds. Its five-node Mermaid graph rendered in the opaque frame, which could access
neither parent DOM nor storage. Four acknowledged ciphertext events recovered the answer and diagram after
reload. The completed request charged 2 test credits and recorded $0.006266 provider spend, with no outstanding
reservation. Account deletion completed. Auth was seeded by synthetic-account password login; this does not
verify email/OAuth UI, a physical camera, Safari, automatic diagram repair, or a comprehensive cryptographic audit.

Evidence: `.artifacts/takeover-20261008/hosted-browser-diagram-summary.json` and screenshots. Including two earlier
harness corrections (one stopped before the provider; one drew the graph but raced the reload-panel assertion),
the session made two paid requests totaling **$0.012572**, with zero remaining reservations, test Auth accounts
or private events (`hosted-browser-diagram-total-cost.json`). No recurring service, offer, or budget changed.

Visual inspection found that a tall graph's final node could be clipped. The fit/zoom follow-up has six passing
production-CSP journeys: tall seven-node graphs at desktop and 390 px, zoom/scroll/Fit/return to chat, normal and
malformed/directive-refused rendering, and remote media/link/CSS isolation. Four desktop-only repeats skip on
the phone project. Screenshots `.artifacts/web-chat/{desktop,phone}-tall-diagram{,-zoomed}.png` were visually
reviewed; all nodes fit initially and enlarged labels remain scrollable. These are local fixture checks, not
additional paid requests. Deployment of the follow-up is recorded in implementation status.
