# Native authentication

Status, 2026-10-04: **implementation proposal, not provider acceptance evidence.** Replace the customer password form with native Apple, Google in the system authentication browser, and an email code. Keep the existing account sheet, Settings entry point, reader navigation and private-key recovery. This specifies the selected policy in [Decisions](../DECISIONS.md) and [Privacy and sync](PRIVACY_AND_SYNC.md#account-sign-in-and-identity-linking); it changes no provider configuration or hosted state. Configuration work remains within the user's existing deployment authorization and the dedicated-account/budget boundaries.

## Current foundation and gaps

[BackendClient](../../apps/apple/ScienceReader/Services/BackendClient.swift) already owns authentication generations, Keychain sessions, Google PKCE and Apple nonces. [OAuthFlow](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/OAuthFlow.swift) validates the callback destination, bounds its code and rejects token fragments. Existing [OAuth safety tests](../../apps/apple/ScienceReaderTests/OAuthSafetyTests.swift) cover deterministic exchanges, duplicate callbacks, cancellation before UI delivery and late results after sign-out. These are local protocol tests, not Apple/Google sign-in evidence.

The missing pieces are native presenters, email-code operations, one model handoff shared by all providers, and replacement of [AuthenticationView](../../apps/apple/ScienceReader/Views/RootView.swift). Also fix these source-level gaps in the same slice:

- Google currently requests `com.sciencereader.ios://auth-callback`, while [Info.plist](../../apps/apple/ScienceReader/Info.plist) registers `sciencereader` and [local Supabase configuration](../../supabase/config.toml) allows `sciencereader://auth/callback`.
- Library and Settings use optional `email` as the signed-in predicate. An authenticated UUID can legitimately have no display email.
- Auth HTTP calls currently use the unbounded, redirect-following branch of `raw`; the library transport already has a bounded, redirect-rejecting path to reuse.
- Recovery is nondismissable and has no Sign out action. It must offer an account escape without discarding keys, enrollment receipts or encrypted local work.

No private-event, draft, cache or key-envelope format change is required. Password helpers used by existing deterministic fixtures need not be removed in this slice, but the customer sheet must not expose them.

## One attempt owner and a finite presentation

Add a model-owned `@MainActor AuthenticationCoordinator`, retained outside the sheet. The sheet renders its state and sends intents; it does not own a second network task or independently save sessions. The coordinator owns one presentation ID, one active local attempt ID, its captured reader-session ID, the backend attempt ID when allocated, and one retained native presenter. `BackendClient` remains the sole credential/session authority and keeps its existing generation checks. View cancellation always carries the captured presentation ID, so an old sheet cannot cancel a newer one.

Use these finite phases rather than independent loading/error/provider booleans:

| Phase | Allowed progress and exit |
|---|---|
| `closed` | Open a new presentation; no provider or code state survives. |
| `choices(issue?)` | Apple, Google, Continue with email, or Close. |
| `emailEntry(email, issue?)` | Send code, Back to choices, or Close. |
| `preparing(attempt, provider)` | Allocate the backend attempt; then present Apple/Google or send email. Close or replacement invalidates this attempt immediately. |
| `external(attempt, apple/google)` | Exactly one native authorization result, provider cancellation, failed presentation, or Close. A valid result enters `exchanging`. |
| `sendingCode(attempt, email)` | One send/resend request. Success or uncertain transport returns `codeEntry` with distinct delivery status; a definite failure shows a finite inline issue. |
| `codeEntry(attempt, email, delivery, resendAfter, issue?)` | Verify, explicitly resend after the cooldown, use another email, change method, or Close. |
| `exchanging(attempt, provider)` | One token/code exchange. Accept, return to code entry for a rejected email code, show a retryable method error, or cancel. |
| `cancelling(attempt, destination)` | Retire the presenter and backend attempt, then enter the requested choices/email/closed destination or the latest replacement intent. |
| `accepted(attempt, accountUUID)` | The model has taken ownership. Dismiss this presentation without cancelling its credentials; subsequent account work belongs to the reader session. |

Errors are a closed set of local categories attached to the relevant phase: configuration, presentation unavailable, delivery unconfirmed, invalid/expired code, rate limited, connection, invalid response and local credential storage. Provider cancellation is a normal return to choices, not an alert. Never display raw provider messages or callback URLs.

Starting or cancelling an attempt must be ordered. A close can occur while `await backend.begin…()` is still returning; a delayed begin must not erase a newer provider's backend state. Serialize the short backend preparation/cancellation operations, retain at most one latest replacement intent, and cancel any backend attempt returned after its local owner was invalidated before preparing the replacement. Do not hold this lifecycle lane across browser interaction or HTTP exchange. Separate email attempt preparation from its network send for the same reason. Old network work is cancelled and generation-fenced, rather than blocking a new provider until a timeout.

## Accept before dismissing

Extract the existing bounded guest-draft preservation from `ReaderModel.authenticate` into a shared model entry point. Preserve only the unauthenticated sample/general draft and navigation intent already permitted by [Privacy and sync](PRIVACY_AND_SYNC.md#local-encrypted-event-journal). Never carry a previous signed-in account's composer, selection or reader bytes to another UUID. Provider switches within the same presentation do not repeatedly recapture or clear this guest intent.

The success handoff runs synchronously on MainActor, with **no await between validation and acceptance**:

1. Require the current presentation, local/backend attempt, expected exchange phase and captured reader-session ID. The backend must already have persisted the session under its current authentication generation.
2. Mark the coordinator `accepted`, set the model's authenticated account UUID and optional display email, and register the pending account-preparation work under that reader session.
3. Request sheet dismissal. An `onDismiss` or late Cancel callback for this accepted attempt does not call `cancelSignIn`.
4. Begin the existing scoped `signedIn`/key-preparation path. Present recovery only after the sign-in sheet has dismissed; the pending recovery state still belongs to that account/session. Do not use a timed delay to sequence sheets.

This preserves the existing useful distinction: cancellation may invalidate a backend exchange that completed before the model accepted it, but successful sheet dismissal cannot sign the user straight back out. If Close wins first, invalidate the MainActor owner immediately, cancel the presenter/task, and call `backend.cancelSignIn` for that exact backend ID. Any later success is discarded. If acceptance wins first, account Sign out is the subsequent cancellation path. An old error cannot replace a newer method's issue or recovery state.

During cancellation/sign-out, invalidate in-memory backend generations and discard attempt secrets before fallible Keychain cleanup. If deletion fails, show a local credential-storage failure and block a new attempt until cleanup succeeds; do not continue with the old in-memory session or claim durable sign-out. Do not delete account-partitioned device keys or encrypted databases. Process termination discards unfinished PKCE/nonces/code state; a legitimately persisted Auth session resumes through ordinary startup and key checks.

## Minimal interfaces and file ownership

Names below are proposed; preserve the existing backend attempt UUID and generation invariants.

| Owner | Small interface/change |
|---|---|
| `AuthenticationCoordinator` | `open(scope:)`, `startApple(anchor:)`, `startGoogle(anchor:)`, `showEmail()`, `sendCode(email:)`, `verifyCode(_:)`, `resendCode()`, `useAnotherEmail()`, `close(presentationID:)`; injectable presenters, transport outcome and clock for tests. |
| `BackendClient` | Keep `begin/finishGoogleSignIn`, `begin/finishAppleSignIn`, `cancelSignIn`; add `prepareEmailSignIn(email:)`, `sendEmailCode(id:)`, `finishEmailSignIn(id:code:)`. Email and provider completion share bounded session validation/persistence. |
| `ReaderModel` | Shared begin/accept-authentication helpers; read-only `isSignedIn`/account identity; scoped key-preparation retry; recovery Sign out. Acceptance returns whether this exact delivery was claimed. |
| Native presenter file | Retained `ASWebAuthenticationSession` and Apple authorization controller/delegates, active scene/window anchor, exactly-once completion, synchronous local cancellation fence. No backend/key ownership. |
| Configuration/views/tests | One callback configuration; replace the password sheet; use account UUID predicates; keep recovery and navigation in their existing destinations. No new auth SDK is required for these existing REST contracts. |

## Apple and Google

For Apple, use the standard `ASAuthorizationAppleIDButton` with a retained `ASAuthorizationController` presenter. Its action can await backend nonce preparation before constructing and performing the request; do not attempt asynchronous nonce setup inside a synchronous request-configuration closure. Put the returned SHA-256 nonce on the request and request email only; the raw nonce remains inside `BackendClient`. Accept only the matching controller/attempt, a bounded UTF-8 identity token, and the expected credential type. Missing optional profile email does not invalidate a successful Supabase user UUID. Cancellation clears the local owner before cancelling the controller; the resulting delegate cancellation cannot complete twice. Native Apple and its nonce exchange are documented separately from Apple's web OAuth setup. [Supabase Apple guide](https://supabase.com/docs/guides/auth/social-login/auth-apple), [Apple controller cancellation](https://developer.apple.com/documentation/authenticationservices/asauthorizationcontroller/cancel()).

For Google, retain one `ASWebAuthenticationSession` and its presentation-context provider until completion/cancellation. Use the configured callback scheme, the existing full URI validator and S256 verifier. Prefer an ephemeral browser session for this first account-selection flow; do not treat that setting as account revocation. A failed `start()` is a terminal presentation failure that releases the continuation and backend attempt. Hop the sendable completion to MainActor, then check the captured owner before exchange. Cancel and callback races complete once. No global URL handler may import arbitrary tokens or bypass this owner. The system browser may follow the provider's OAuth redirects; the backend credential HTTP transport below may not. [Apple authentication session](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession), [Supabase Google configuration](https://supabase.com/docs/guides/auth/social-login/auth-google).

Configure `ScienceReaderAuthCallbackURL` in app Info/configuration as the canonical `sciencereader://auth/callback` for this slice, matching the already registered scheme and local allowlist. Feed this same value into PKCE and the presenter, and validate its scheme registration at startup. Require the exact URI in the dedicated hosted Supabase redirect allowlist. Google's registered provider return URI is the Supabase project's `/auth/v1/callback`, a different hop from the app URI. No permissive fallback to both old spellings, wildcard callback admission, or bearer-token fragments. Probe targets must not start provider flows under the production callback identity. [Supabase redirect configuration](https://supabase.com/docs/guides/auth/redirect-urls).

## Email code and compact UI

Keep one sheet with three full-width choices: native Apple, Continue with Google, Continue with email. Use normal body-sized text, at least 44-point targets, 12-point inter-control spacing and 16-point content margins; cap the form width on iPad. Allow vertical scrolling at large Dynamic Type. Do not add a create-account toggle: the email operation explicitly permits account creation under the selected unified sign-in policy.

The email step has an email field and **Send code**. Trim surrounding whitespace, bound the UTF-8 input to 320 bytes, reject control characters, and preserve the submitted address for verification; do not invent identity matching by lowercasing or parsing provider aliases. The second step shows that address, one editable code field with `.oneTimeCode`/numeric keyboard, **Continue**, **Resend code**, and **Use another email**. A single field supports paste, AutoFill, selection and VoiceOver; do not create six individually focused boxes.

Use `POST /auth/v1/otp` with the captured email and `create_user: true`, then `POST /auth/v1/verify` with that email, the code and `type: "email"`. A successful send establishes no local session. The dedicated email template must emit `{{ .Token }}` rather than a magic-link-only email. The initial UI contract is six ASCII digits, with the project OTP length verified before enabling it. [Passwordless email flow](https://supabase.com/docs/guides/auth/auth-email-passwordless), [Swift OTP verification](https://supabase.com/docs/reference/swift/auth-verifyotp).

Only one send or verify is active. Resend is an explicit fresh attempt for the same address; switching email/method or closing clears entered codes and invalidates callbacks. The backend owns captured email, so a view cannot verify a code against an edited address. Use an injected monotonic clock for a proposed 60-second resend affordance; honor bounded server retry information, and treat server rates/expiry as authoritative. A proposed 10-minute server OTP expiry is a configuration gate, not an existing guarantee. Client cancellation does not revoke an email already sent or prove which previously delivered codes the server will still accept.

A send transport timeout is ambiguous delivery: keep code entry available with **“Couldn’t confirm delivery. You can still enter a code.”** Do not send again automatically. Wrong/expired codes return to code entry with a bounded inline issue; keep the owned challenge for an explicit correction or resend instead of permanently consuming it on every HTTP error. Verification with a lost response does not establish local success or automatically repeat a consumed credential. Closing and reopening starts a fresh presentation; no email/code/nonce is stored in preferences or diagnostics. Session persistence stays in the existing protected Keychain entry.

## Account UUID, recovery and enrollment

`isSignedIn` means an accepted/current Auth user UUID exists, independent of email. Use the email only as optional display text, otherwise **Signed in**. Library sign-in affordances, Settings, Sign out and Sync gating use account and key readiness; `needsRecovery` is an authenticated, key-locked state. Do not make a new-account decision from absent email or a failed key-state request.

After acceptance, account preparation has four outcomes: `preparing`, `ready`, `saveRecoveryCode`, or `recoveryRequired`, with a scoped retryable issue on failure. Reuse `DeviceKeys` and the existing activation/retirement barrier:

- Cached device keys may restore encrypted local reading before network recovery; cloud operations still refresh authority. A network error never authorizes fresh bootstrap keys.
- Confirming a saved recovery code uses the existing bootstrap receipt/envelope reconciliation. Recovering another device retains its durable pending enrollment recipient and request identity; timeout/cancellation never substitutes new keys merely to clear UI state.
- Recovery stays in the existing sheet, with an explicit **Sign out** escape. It clears presentation immediately, retires accepted writes/sync/bundle work, and retains encrypted local files and account-scoped pending key material. Returning to that UUID reconciles the original enrollment; a different UUID cannot use it.
- Trusted-device approval remains part of the selected custody model, but this slice does not claim an approval UI exists. Do not show a functional “Approve on another device” action until its request/approval journey is implemented. Account sign-in/email recovery does not recover private-content keys.

Pending recovery presentation is account/session-fenced and cannot reopen after Sign out. Keep account-identity linking separate: these sign-in entry points clear old authentication authority and must not be reused as a link operation. Do not merge users or transfer library/purchase ownership by email. See [key custody and enrollment](PRIVACY_AND_SYNC.md#device-held-key-design).

## Bounded backend transport

Apply an explicit auth response cap before materializing full bodies, including errors, refresh and logout: proposed 256 KiB per response, 64 KiB per request, existing 32 KiB Apple-token input cap, and bounded nonempty decoded session tokens. Require the configured HTTPS origin and exact auth route, reject HTTP redirects before credentials reach another destination, reject non-HTTP/wrong-status/truncated responses, and cancel the underlying task on every abort/overflow. Use a 30-second request and 60-second resource deadline as initial client bounds. These are client resource limits, not promises about remote provider work.

Keep unknown provider bodies out of errors, logs and test attachments. Map only allowlisted codes to finite local issues. No automatic retries of send/code/token-exchange POSTs; each retry is explicit intent with the appropriate fresh or still-owned challenge. Preserve the existing single refresh task and generation/UUID checks on both success and failure. Library/support body limits remain independent; do not shrink unrelated payload routes while sharing the redirect policy.

## Focused local acceptance and hosted gates

Before replacing the customer form, add a small fake-presenter/held-transport matrix to the existing auth and retirement tests:

1. Apple/Google start succeeds, fails to present, is denied or is cancelled; double callback and Close-during-begin complete once. Switching providers cannot let delayed preparation invalidate the newer attempt. Validate wrong destination, duplicate code, token fragment, wrong provider, missing token and each size boundary.
2. Exchange completes before dismissal: accepted model handoff survives `onDismiss`. Close or Sign out before handoff rejects the same late success and late failure, including persisted-before-delivery sessions. Include an accepted UUID with `email: nil`.
3. Email send → code → accepted account; wrong code → correction; explicit resend; use another email; close during send/verify; delayed old success/error; uncertain delivery without automatic resend. Test cooldown with an injected clock and assert captured email/request counts.
4. Redirect/truncated/oversized/unknown error replies, task cancellation and Keychain write/delete failures cannot establish or resurrect a session. Tokens, nonce, code and raw URLs never reach public diagnostics.
5. Ready device, save-new-recovery-code, recovery-required and interrupted enrollment retain existing keys/drafts. Recovery Sign out and immediate same-account return join the existing writer retirement; stale completion cannot reopen the sheet or erase a newer account.
6. Simulator UI with fake providers: ordinary and Accessibility Extra Large/dark sheet layout, keyboard/AutoFill field behavior, close/resend/switch email, no-email account Settings, recovery escape, and return to the originating paper/general draft. Label this UI/ownership evidence, not provider authentication.

Live enablement remains blocked on dedicated Apple capability/provisioning and audience configuration; Google consent audience/client configuration and both redirect hops; and verified SMTP sender, code template, OTP length/expiry/rate settings and actual delivery. The default Supabase sender is restricted and is not a beta email-delivery solution. Native-only Apple token sign-in should not inherit web Services-ID secret-rotation requirements; any later web Apple flow needs its own reviewed configuration. [Custom SMTP guidance](https://supabase.com/docs/guides/auth/auth-smtp), [Apple configuration](https://supabase.com/docs/guides/auth/social-login/auth-apple).

Finally verify one real first sign-in, returning sign-in, cancellation, sign-out/restart and new-device recovery per enabled method on the dedicated configuration, with redacted evidence. Identity linking/removal, Apple revocation during account deletion, and administrator MFA remain separate release gates. This draft makes no provider, email-delivery, physical-device or hosted-configuration claim.
