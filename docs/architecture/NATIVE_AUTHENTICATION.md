# Native authentication

Status, 2026-10-04: **native implementation, independent source reviews and five Simulator UI journeys pass; real provider acceptance remains unverified.** The customer password form is replaced with native Apple, Google in the system authentication browser, and an email code. The existing account sheet, Settings entry point, reader navigation and private-key recovery remain. The signed Simulator native suite has 211 cases: 208 pass and three expected live/device checks skip, including 36 passing new backend/coordinator/model cases. The unsigned Internal iOS build also passes. This implements the selected policy in [Decisions](../DECISIONS.md) and [Privacy and sync](PRIVACY_AND_SYNC.md#account-sign-in-and-identity-linking). Dedicated account configuration is tracked separately in the [deployment manifest](DEPLOYMENT_MANIFEST.md#native-authentication-readiness--2026-10-04), within the user's existing deployment authorization and budget boundaries.

## Private-beta return after account deletion

### Durable admission correction — October 19, designed before migration 091

The owner reproduced the lockout after deleting the October 17 replacement UUID at 04:17 UTC. Readback confirms
`disable_signup=true` and no before-user-created hook. The previous one-time re-admission is not a lifecycle fix.

Add `app_private.beta_admissions`, keyed by SHA-256 of the lowercased, trimmed exact email, with allowed/revoked
state, timestamps, an authority account UUID and a bounded reason. Do not retain the address in this table or
expose it to client roles. Hashes remain personal access-control metadata, not anonymous data. Invitations survive
account deletion until the beta ends or an operator revokes them; deletion still erases private account data,
credentials and provider identities. No membership/content/role/credit restoration or legacy-data migration.

Seed only existing confirmed Auth addresses and verified linked identity addresses. An Auth BEFORE DELETE trigger
retains those same verified addresses before identity cascades, preserving a prior revocation. The owner/admin
admission path records permission before creating the login. Disabling sign-in also revokes future admission;
re-enabling restores it. Never derive admission from editable user metadata, callback parameters or an unverified
email. Linked provider addresses are admitted separately; this does not link or merge separate accounts.

Admin command replays must derive admission from the returned **current** disabled state, not the historical
request's boolean. Migration 093 corrects that wrapper after 091: replaying an old enable after a later disable
cannot reopen admission, and an old disable cannot undo a later enable. Both orderings require SQL regressions.

`public.hook_beta_before_user_created(jsonb)` executes only as `supabase_auth_admin`, returns success solely for
an allowed exact-email hash and denies malformed/missing/unknown/revoked addresses. Clients cannot query the table,
invoke the hook or grant admission. The existing service-role admin RPC checks the owner before granting. New
users still undergo Supabase's provider verification/email confirmation. Auth creates a fresh account UUID with
zero carried-over entitlements. No automatic invitation email or paid request.

Rollout: test SQL ACLs/admission/deletion/revocation; encrypted backup; immutable migration 091; verify hook under
the Auth role; enable the hook while signups remain blocked; confirm readback, then allow signup with that hook
mandatory. Unknown signups must be rejected live. If verification fails, restore the global signup block before
any further action. Exercise repeated synthetic deletion → self-creation → verified account RPC, not Admin
`createUser` as a substitute for returning-user acceptance. Interactive Apple/Google completion is a separate
acceptance boundary; do not claim the paused physical phone was tested.

The pre-091 restore drill also exposed two existing recovery gaps: schema-filtered dumps omit `pg_trgm` in
`extensions`, and four private tables lack the RLS flag required by the restore verifier. Install only that known
extension in the disposable restore target. Add migration 092 enabling RLS on `arxiv_categories`, `arxiv_licenses`,
`catalog_metadata_provenance` and `podcast_device_sources`; add no customer policies or grants. Existing security-
definer/service-role paths retain access. This enforces the existing private-table boundary, not a data migration.

Native Google must recognize bounded provider-error callbacks in the query or fragment after validating the
exact destination, without accepting token fragments, ambiguous mixed code/error parameters or untrusted copy.
The known invitation refusal becomes an actionable inline error; cancellation remains distinct. Old clients can
benefit from server admission independently of a later native release.

### Revocation and transfer gaps — review A21, October 21, designed before migration 127

The review found three gaps in 091. (1) There was no way to withdraw an invitation retained for a deleted account or
a mistyped address except hand-written SQL. (2) The deletion trigger admitted every verified address on the login at
that moment, so a tester could hand their invitation to someone else by changing the login's email (the new owner
confirms the change) and then deleting the account; linking another person's Apple or Google identity did the same.
(3) `worker_admin_admit_email` refused only an Auth ban, but disabling sign-in commits `accounts.spending_suspended`
and the revocation in the database before the Edge function bans the login in Auth; an admit in that window allowed a
disabled tester again.

Migration 127 (supersedes "Linked provider addresses are admitted separately" above):
- **Revoke.** `worker_admin_revoke_email(p_actor_id, p_email, p_reason)` (service role, after the Edge function's
  owner/MFA gate; it rechecks the owner) records `allowed=false` for the exact address hash, with the owner as
  authority, and writes a `beta_revocation` audit row with the owner's reason (validated like every admin reason),
  whether the address had an invitation and whether a current login uses it. It refuses an address that an open
  owner account signs in with (`owner_cannot_be_disabled`), so the owner cannot lock themselves out. A revocation only
  stops a future account being created with that address; an existing login is stopped with Disable sign-in, and the
  response says when one exists. Admin › Accounts gains "Withdraw an invitation" (`revoke_admission` action of
  `admin-accounts`). A later admit of the same address re-allows it (an explicit owner decision).
- **Only admitted addresses return.** The deletion trigger no longer creates admissions. Every address that could
  create a login already has a row (the 091 seed of existing verified addresses, the owner's admits, the recorded
  owner recovery), and those rows already survive deletion, so dropping the trigger changes nothing for them. An
  address that only reached the login later (an email change, or a linked Apple/Google identity) is not invited by
  deleting the account; a person who signed up with an admitted address returns with that address.
- **A disabled tester stays disabled.** Admitting refuses (`account_disabled`) when any open account whose login has
  a verified address with that hash is `spending_suspended`, as well as on an Auth ban.

Verified rollout, October 19: migrations **091–093** are applied with matching hashes; the hook is enabled and
email confirmation remains required. A live unknown public signup returns **403 `beta_invitation_required`**.
`scripts/configure-beta-admission.py` waits for Auth configuration propagation only on the previous
`signup_disabled` response; any other verification failure restores the global block. No public admission is enabled.
The owner's prior verified sign-in address has durable admission, recovered from recorded Auth evidence, without
creating a login or restoring their deleted account. No owner sign-in was impersonated.

`scripts/smoke-beta-return.mjs` passes **two** actual account-delete → public `/signup` → code verification →
authenticated `v1_key_state` cycles, each with a fresh UUID and rejected old token. Only initial fixture setup
uses Admin `createUser`; returning-user creation does not. The final synthetic login is deleted. Signup may attempt
SMTP to the fixture's reserved `.invalid` address; this does not test real mail delivery. Evidence:
`.artifacts/auth-lifecycle/2026-10-19T04-30-38-750Z-beta-return.json`.

The local SQL lifecycle/ACL/revocation tests pass; both stale admin replay orderings are covered. Native auth
backend/coordinator/safety tests pass **45/45** under release optimization, Core callback checks pass **5/5**,
and browser callback journeys pass **8/8** across desktop and phone. Browser Pages **e8aa027f** is deployed
and its served assets verified (`1c3e3716` was the assets-only phase). iOS/iPadOS TestFlight 74 is VALID / IN_BETA_TESTING, with release notes read back.
Mac 74 uploaded at 05:20:40 UTC and is VALID / IN_BETA_TESTING (read back 05:24 UTC), with release notes verified. Source 028a7f6, required native gate 15/15 (no skips).
Evidence: `.artifacts/feedback/catalogs-20261019/`. Actual Apple/Google provider completion and physical-phone
acceptance remain unverified; the hosted test proves admission and account lifecycle, not those provider UIs.

### Historical October 17 one-time repair (superseded by durable admission)

2026-10-17 UTC: the owner deleted their account and OAuth then said they were not invited. Hosted evidence shows
the account closed at 04:48:45 UTC and its Auth user removed. Apple and Google remain enabled, but
`disable_signup` is true. Beta admission currently pre-creates a confirmed Auth login; it is not a separate durable
email allowlist. Deleting that login therefore removes the admission that a returning OAuth flow needs.

The recovery is a fresh beta admission for the account's verified address (including Apple's relay address when
used), creating a new UUID. Do not infer that address from TestFlight feedback, resurrect the deleted UUID,
restore old content/keys/credits, or enable public signups.
Native and browser copy now explains this before deletion and in the not-invited error. The old error's suggestion
to use Apple was misleading: signup restrictions apply there too. Browser copy is deployed in Pages `91c7d07f`;
the native copy is in TestFlight 66 (iOS and Mac VALID / IN_BETA_TESTING). This does not itself create a new invitation.

### Actual access repair, 2026-10-17 08:30 UTC

The owner's new attempts at 08:16–08:23 UTC failed with HTTP 422 `signup_disabled` on both `/otp` and
`/token` with `grant_type=id_token`. Asking the owner for an “OAuth provider” did not address the lockout.
The hosted Auth audit stream (not the empty Postgres audit table) retains the original UUID's deletion event and
successful refreshes with the same exact address. That is direct account evidence, not a TestFlight-email guess.

Using the existing beta-admission mechanism, Auth Admin `createUser({email,email_confirm:true})` created a fresh
login for that recorded address at **08:30:31 UTC**. Readback confirms the email is verified, the new account is open,
and the old deleted UUID remains separate. No password, email message, credit grant, owner-role assignment, restored
content or public-signup change. Auth subsequently records a successful owner sign-in at **08:34:48 UTC** on
the fresh account. The agent did not authenticate as that account. The later explicitly requested test-credit
grant is a separate audited action ([billing](OPERATIONS_AND_BILLING.md#fresh-owner-test-account--2026-10-17)).
Private operator evidence: `.artifacts/feedback/login-access-20261017/access-repair.json`; email is hashed there.

`scripts/smoke-session-revocation.mjs` now continues past deletion: re-admit the same synthetic address, generate
a code without sending mail, exchange it using the app's `/verify` email-code format, and call `v1_key_state` with
the resulting token. Both return **HTTP 200** on the fresh UUID; both disposable accounts are deleted. The owner's
account is never impersonated by this test. Evidence: `.artifacts/auth-lifecycle/2026-10-17T08-31-42-852Z.json`.
This proves hosted admission/code exchange, not SMTP delivery, interactive Apple/Google sign-in or phone acceptance.

## Remote session rejection (build 66 feedback, 2026-10-17; browser / TestFlight 67 released)

The reported phone kept cached account identity after remote deletion. Hosted reproduction with two synthetic
sessions confirms HTTP 400 `refresh_token_not_found` on refresh, and HTTP 403 / SQL `28000` /
`authentication_required` for an otherwise unexpired token. The old client classified the refresh as generic
sign-in rejection, retained its Keychain session and repeatedly failed cloud actions while showing local papers.

Definitive session rejection must retire backend authority and the matching model session, clear visible account
state, and offer normal sign-in again. Retain encrypted account files and keys: a rejected session alone does not
prove deletion and does not authorize erasure. A timeout, 429, 5xx, malformed reply or ordinary permission failure
must preserve offline access. Notify the model once across concurrent requests; late responses may not end a
new sign-in. Test both expired refresh and unexpired-token rejection, restart, transient recovery, and local-data
retention. `scripts/smoke-session-revocation.mjs` exercises hosted deletion without mail, papers, credits or AI.

Verification: the old native code fails all three assertions of the deleted-session regression. The fix passes
44 focused native checks under `-O`, including the actual sign-in/restart screen journey. The browser already
retired rejected refreshes; its unexpired-token RPC/stream path now also retires the matching session, while
unknown/transient refresh failures preserve identity. Browser unit checks plus desktop/phone remote-rejection
journeys pass and verify encrypted records remain. Captured screenshots reviewed. The deletion sheet also closes
when its owning account session changes. The expanded release gate then caught a disappearing startup alert
(12 passed, one failed); the explanation now stays beside Sign in and in Settings instead of relying on an alert.
The screen journey requires that message before proceeding. The final gate passes all 13 checks, none skipped,
under release optimization; final message/sign-in screenshots reviewed (`2026-10-17T06-38-58-152Z.xcresult`).
Evidence: `.artifacts/feedback/followup-20261017/`. At that client-release checkpoint no owner login had been
recreated; the subsequent access repair above completes that operator step. No physical-phone access or paid AI calls.
Browser `103582dd` is deployed; TestFlight 67 iOS and Mac are VALID / IN_BETA_TESTING (06:57:42 UTC).

## Native Google never exchanged its code (iPad build 86 report, 2026-10-23)

Owner report: Google on the iPad finished with no error, but the sheet stayed on its choices. Apple then worked.
Hosted evidence, read-only. Auth and gateway logs at 19:43 UTC show two `GET /authorize` requests from the iPad, both
with `redirect_to=sciencereader://auth/callback` and S256. Both `/callback` requests returned 302 and logged a login
for the owner's single Auth user. That user has Apple and Google identities with the same verified address, and the
Google identity was linked through the admin site on 10-22. Both `auth.flow_state` rows have an issued code and the
app referrer. The 94-byte 302 body matches exactly `sciencereader://auth/callback?code=<uuid>`. No
`POST /token?grant_type=pkce` follows either one. At 19:43:54, `grant_type=id_token` from `ScienceReader/86` succeeds
for the same user. Gateway logs from 10-04 to 10-23 contain no native PKCE exchange at all. Every native Google attempt
(iPhone 10-07, 10-17 and 10-19; Mac 10-08; iPad today) stopped after the callback. In the same period the browser
exchanged its codes. Staging configuration and identities need no change.

The code never reached the app's exchange. The coordinator turned a closed Google page (`canceledLogin`) into the
choices with no issue, as for Apple's own Cancel. In the iPad 26.4 Simulator, against a local HTTPS fake of the
provider, the real `ASWebAuthenticationSession` returns the callback and the app exchanges it, both portrait and
landscape. The device-only step that loses it (iPadOS/iOS 18.7) is not proven. The return is the app's registered
scheme, so the system can hand it to the app's URL handler while the session never answers. That handler sent it to
paper links, which dropped it.

Fix (branch `fix/google-signin-silent`):
- `ScienceReaderApp.onOpenURL` offers every URL to `NativeAuthenticationPresenter.handleOpenedURL` first. A
  `sciencereader://auth/callback` URL goes to the one open Google presentation, exactly as if the session had
  answered, and that session is closed. The coordinator's owner check, full-URI validation and this attempt's PKCE
  verifier still apply. A return with no open Google page is dropped and never treated as a paper link. Simulator
  check: a callback delivered by `simctl openurl` while the Google page was open was exchanged.
- A closed Google page now says "Google sign-in didn't finish, so you're still signed out…". So does leaving an
  unanswered Google page through "Other sign-in methods". Apple's Cancel stays quiet. A cancellation the sheet did not
  request, while the attempt is still its own, shows the existing "Sign-in wasn't completed" issue.

Still unverified: a real Google sign-in on a device with a build that includes this change.

## Current foundation and gaps

[BackendClient](../../apps/apple/ScienceReader/Services/BackendClient.swift) already owns authentication generations, Keychain sessions, Google PKCE and Apple nonces. [OAuthFlow](../../apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/OAuthFlow.swift) validates the callback destination, bounds its code and rejects token fragments. Existing [OAuth safety tests](../../apps/apple/ScienceReaderTests/OAuthSafetyTests.swift) cover deterministic exchanges, duplicate callbacks, cancellation before UI delivery and late results after sign-out. These are local protocol tests, not Apple/Google sign-in evidence.

The implementation adds native presenters, email-code operations, one model handoff shared by all providers, and the new [AuthenticationView](../../apps/apple/ScienceReader/Views/AuthenticationView.swift). It also corrects these previous source-level gaps:

- Google previously requested `com.sciencereader.ios://auth-callback`, while [Info.plist](../../apps/apple/ScienceReader/Info.plist) registered `sciencereader` and [local Supabase configuration](../../supabase/config.toml) allowed `sciencereader://auth/callback`. One canonical callback now drives configuration and PKCE.
- Library and Settings previously used optional `email` as the signed-in predicate. They now use the authenticated UUID; no display email is required.
- Auth HTTP calls previously used the unbounded, redirect-following branch of `raw`. The separate auth session now bounds bodies and deadlines and refuses redirects without changing unrelated library/support limits.
- Recovery previously had no Sign out escape. It now offers that action and a scoped account-preparation retry without discarding keys, enrollment receipts or encrypted local work.

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

The implementation follows these ownership boundaries and preserves the existing backend attempt UUID and generation invariants.

| Owner | Small interface/change |
|---|---|
| `AuthenticationCoordinator` | `open(scope:)`, `startApple(anchor:)`, `startGoogle(anchor:)`, `showEmail()`, `sendCode(email:)`, `verifyCode(_:)`, `resendCode()`, `useAnotherEmail()`, `close(presentationID:)`; injectable presenters, transport outcome and clock for tests. |
| `BackendClient` | Keep `begin/finishGoogleSignIn`, `begin/finishAppleSignIn`, `cancelSignIn`; add `prepareEmailSignIn(email:)`, `sendEmailCode(id:)`, `finishEmailSignIn(id:code:)`. Email and provider completion share bounded session validation/persistence. |
| `ReaderModel` | Shared begin/accept-authentication helpers; read-only `isSignedIn`/account identity; scoped key-preparation retry; recovery Sign out. Acceptance returns whether this exact delivery was claimed. |
| Native presenter file | Retained `ASWebAuthenticationSession` and Apple authorization controller/delegates, active scene/window anchor, exactly-once completion, synchronous local cancellation fence. No backend/key ownership. |
| Configuration/views/tests | One callback configuration; replace the password sheet; use account UUID predicates; keep recovery and navigation in their existing destinations. No new auth SDK is required for these existing REST contracts. |

The model retains a presentation identity through the actual sheet dismissal, so another sheet cannot inherit its `onDismiss`. Replacing the coordinator also joins the old coordinator's short preparation/cancellation lane; fencing only within one coordinator would leave a delayed old begin able to erase a newer backend attempt. These retirement tasks return `Void` and never join a provider interaction or HTTP exchange. Local sign-out joins that same lane, invalidates memory and completes Keychain cleanup, then schedules a separately owned best-effort logout using only the captured old token. A later preparation cancels that obsolete logout; its result cannot change the new session.

## Apple and Google

For Apple, use the standard `ASAuthorizationAppleIDButton` with a retained `ASAuthorizationController` presenter. Its action can await backend nonce preparation before constructing and performing the request; do not attempt asynchronous nonce setup inside a synchronous request-configuration closure. Put the returned SHA-256 nonce on the request and request email only; the raw nonce remains inside `BackendClient`. Accept only the matching controller/attempt, a bounded UTF-8 identity token, and the expected credential type. Missing optional profile email does not invalidate a successful Supabase user UUID. Cancellation clears the local owner before cancelling the controller; the resulting delegate cancellation cannot complete twice. Native Apple and its nonce exchange are documented separately from Apple's web OAuth setup. [Supabase Apple guide](https://supabase.com/docs/guides/auth/social-login/auth-apple), [Apple controller cancellation](https://developer.apple.com/documentation/authenticationservices/asauthorizationcontroller/cancel()).

For Google, retain one `ASWebAuthenticationSession` and its presentation-context provider until completion/cancellation. Use the configured callback scheme, the existing full URI validator and S256 verifier. Prefer an ephemeral browser session for this first account-selection flow; do not treat that setting as account revocation. A failed `start()` is a terminal presentation failure that releases the continuation and backend attempt. Hop the sendable completion to MainActor, then check the captured owner before exchange. Cancel and callback races complete once. No global URL handler may import arbitrary tokens or bypass this owner. The system browser may follow the provider's OAuth redirects; the backend credential HTTP transport below may not. [Apple authentication session](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession), [Supabase Google configuration](https://supabase.com/docs/guides/auth/social-login/auth-google).

Configure `ScienceReaderAuthCallbackURL` in app Info/configuration as the canonical `sciencereader://auth/callback` for this slice, matching the already registered scheme and local allowlist. Feed this same value into PKCE and the presenter, and validate its scheme registration at startup. Require the exact URI in the dedicated hosted Supabase redirect allowlist. Google's registered provider return URI is the Supabase project's `/auth/v1/callback`, a different hop from the app URI. No permissive fallback to both old spellings, wildcard callback admission, or bearer-token fragments. Probe targets must not start provider flows under the production callback identity. [Supabase redirect configuration](https://supabase.com/docs/guides/auth/redirect-urls).

## Email code and compact UI

Keep one sheet with three full-width choices: native Apple, Continue with Google, Continue with email. Use normal body-sized text, at least 44-point targets, 12-point inter-control spacing and 16-point content margins; cap the form width on iPad. Allow vertical scrolling at large Dynamic Type. Do not add a create-account toggle: the email operation explicitly permits account creation under the selected unified sign-in policy.

The implemented Apple control is the standard native button. Google's native control uses the current official gradient mark and Google Sans Medium, with a 20-point mark, approved spacing, a minimum 50-point height and Dynamic Type wrapping. The unmodified assets, SIL font license and hashes are recorded in [asset provenance](../../apps/apple/ScienceReader/Resources/GoogleSignIn-PROVENANCE.md); no Google authentication SDK is added. The app now uses its adaptive accent color, and the email primary button uses black text on the lighter dark-mode fill. Actual normal, Accessibility Extra Large/dark and iPad landscape captures were inspected. [Google branding requirements](https://developers.google.com/identity/branding-guidelines).

The email step has an email field and **Send code**. Trim surrounding whitespace, bound the UTF-8 input to 320 bytes, reject control characters, and preserve the submitted address for verification; do not invent identity matching by lowercasing or parsing provider aliases. The second step shows that address, one editable code field with `.oneTimeCode`/numeric keyboard, **Continue**, **Resend code**, and **Use another email**. A single field supports paste, AutoFill, selection and VoiceOver; do not create six individually focused boxes.

Use `POST /auth/v1/otp` with the captured email and `create_user: true`, then `POST /auth/v1/verify` with that email, the code and `type: "email"`. A successful send establishes no local session. The dedicated email template must emit `{{ .Token }}` rather than a magic-link-only email. The initial UI contract is six ASCII digits, with the project OTP length verified before enabling it. [Passwordless email flow](https://supabase.com/docs/guides/auth/auth-email-passwordless), [Swift OTP verification](https://supabase.com/docs/reference/swift/auth-verifyotp).

Only one send or verify is active. Resend is an explicit fresh attempt for the same address; switching email/method or closing clears entered codes and invalidates callbacks. The backend owns captured email, so a view cannot verify a code against an edited address. An injected monotonic clock drives the 60-second resend affordance and bounded server retry information. Verification has a separate deadline after a verification rate limit; the initial code can be entered immediately, while repeated verification cannot bypass a returned delay. A rate-limited send may still leave a previously delivered code usable. Server rates/expiry remain authoritative. The dedicated staging configuration now reads back six digits and a 10-minute expiry; actual delivery and enforcement still need live verification. Client cancellation does not revoke an email already sent or prove which previously delivered codes the server will still accept.

A send transport timeout or malformed, truncated or oversized send reply is ambiguous delivery: keep code entry available with **“Couldn’t confirm delivery. You can still enter a code.”** Do not send again automatically. Wrong/expired codes return to code entry with a bounded inline issue; keep the owned challenge for an explicit correction or resend instead of permanently consuming it on every HTTP error. Verification with a lost response does not establish local success or automatically repeat a consumed credential. Closing and reopening starts a fresh presentation; no email/code/nonce is stored in preferences or diagnostics. Session persistence stays in the existing protected Keychain entry.

## Account UUID, recovery and enrollment

`isSignedIn` means an accepted/current Auth user UUID exists, independent of email. Use the email only as optional display text, otherwise **Signed in**. Library sign-in affordances, Settings, Sign out and Sync gating use account and key readiness; `needsRecovery` is an authenticated, key-locked state. Do not make a new-account decision from absent email or a failed key-state request.

After acceptance, account preparation has four outcomes: `preparing`, `ready`, `saveRecoveryCode`, or `recoveryRequired`, with a scoped retryable issue on failure. Reuse `DeviceKeys` and the existing activation/retirement barrier:

- Cached device keys may restore encrypted local reading before network recovery; cloud operations still refresh authority. A network error never authorizes fresh bootstrap keys.
- Confirming a saved recovery code uses the existing bootstrap receipt/envelope reconciliation. Recovering another device retains its durable pending enrollment recipient and request identity; timeout/cancellation never substitutes new keys merely to clear UI state.
- Recovery stays in the existing sheet, with an explicit **Sign out** escape. It clears presentation immediately, retires accepted writes/sync/bundle work, and retains encrypted local files and account-scoped pending key material. Returning to that UUID reconciles the original enrollment; a different UUID cannot use it.
- Trusted-device approval remains part of the selected custody model, but this slice does not claim an approval UI exists. Do not show a functional “Approve on another device” action until its request/approval journey is implemented. Account sign-in/email recovery does not recover private-content keys.

Pending recovery presentation is account/session-fenced and cannot reopen after Sign out. Keep account-identity linking separate: these sign-in entry points clear old authentication authority and must not be reused as a link operation. Do not merge users or transfer library/purchase ownership by email. See [key custody and enrollment](PRIVACY_AND_SYNC.md#device-held-key-design).

## Bounded backend transport

Auth applies an explicit response cap before materializing full bodies, including errors, refresh and logout: 256 KiB per response, 64 KiB per request, a 32 KiB Apple-token input cap, and bounded nonempty decoded session tokens. It requires the configured HTTPS origin and exact auth route, rejects HTTP redirects before credentials reach another destination, rejects non-HTTP/wrong-status/truncated responses, and cancels the underlying task on every abort/overflow. The separate session has a 30-second request and 60-second resource deadline. These are client resource limits, not promises about remote provider work.

Keep unknown provider bodies out of errors, logs and test attachments. Map only allowlisted codes to finite local issues. No automatic retries of send/code/token-exchange POSTs; each retry is explicit intent with the appropriate fresh or still-owned challenge. Preserve the existing single refresh task and generation/UUID checks on both success and failure. Library/support body limits remain independent; do not shrink unrelated payload routes while sharing the redirect policy.

## Focused local acceptance and hosted gates

Maintain this fake-presenter/held-transport matrix alongside the existing auth and retirement tests:

1. Apple/Google start succeeds, fails to present, is denied or is cancelled; double callback and Close-during-begin complete once. Switching providers cannot let delayed preparation invalidate the newer attempt. Validate wrong destination, duplicate code, token fragment, wrong provider, missing token and each size boundary.
2. Exchange completes before dismissal: accepted model handoff survives `onDismiss`. Close or Sign out before handoff rejects the same late success and late failure, including persisted-before-delivery sessions. Include an accepted UUID with `email: nil`.
3. Email send → code → accepted account; wrong code → correction; explicit resend; use another email; close during send/verify; delayed old success/error; uncertain delivery without automatic resend. Test cooldown with an injected clock and assert captured email/request counts.
4. Redirect/truncated/oversized/unknown error replies, task cancellation and Keychain write/delete failures cannot establish or resurrect a session. Tokens, nonce, code and raw URLs never reach public diagnostics.
5. Ready device, save-new-recovery-code, recovery-required and interrupted enrollment retain existing keys/drafts. Recovery Sign out and immediate same-account return join the existing writer retirement; stale completion cannot reopen the sheet or erase a newer account.
6. Simulator UI with fake providers: ordinary and Accessibility Extra Large/dark sheet layout, keyboard/AutoFill field behavior, close/resend/switch email, no-email account Settings, recovery escape, and return to the originating paper/general draft. Label this UI/ownership evidence, not provider authentication.

The dedicated Apple bundle/capability, native audience, app callback and six-digit/600-second code templates are now configured and read back as recorded in the deployment manifest. Live enablement still requires dedicated provisioning and actual Apple sign-in; Google consent audience/client configuration and both redirect hops; and a verified SMTP sender, rate-setting review and actual code delivery. New signups remain disabled. The default Supabase sender is restricted and is not a beta email-delivery solution. Native-only Apple token sign-in should not inherit web Services-ID secret-rotation requirements; any later web Apple flow needs its own reviewed configuration. [Custom SMTP guidance](https://supabase.com/docs/guides/auth/auth-smtp), [Apple configuration](https://supabase.com/docs/guides/auth/social-login/auth-apple).

The native component checkpoint is `.artifacts/native-authentication-final.xcresult`: 208 passing cases and three expected live/device skips, with no native failures. The 36 new cases include bounded/error transport, exact provider/email challenges, Keychain failure and late logout handling, cancellation-ignoring old work, separate-coordinator retirement, synchronous acceptance, no-email accounts, deferred recovery, guest navigation/drafts, late key preparation and unchanged pending recovery material after same-account return. Malformed, truncated and oversized send replies preserve explicit verification without sending twice. Independent review found and corrected a dead email challenge after Keychain failure, a send-rate-limit/backend-state mismatch, missing verification cooldown, and a guest-navigation reset.

That combined result bundle retains two initial UI failures caused by an unscoped, immediate recovery-button assertion. The corrected tests scope the actual navigation bar and wait for the transition; recovery production logic did not change for that correction. Final `.artifacts/native-authentication-phone-ui.xcresult` passes all four phone journeys, and `native-authentication-ipad-ui.xcresult` passes the fifth landscape-tablet journey. They cover provider cancellation/failure, email changes and invalid-code correction, a nil-email account, real Keychain session persistence through app relaunch, recovery Sign out, and return to the originating paper draft. The large-type test now uses UIKit's actual Accessibility Extra Large constant and verifies rendered growth (introduction height 20.33 → 144 points), rather than relying on an ineffective launch argument. Its capture exposed the primary-button contrast issue corrected above.

These UI journeys use a bounded, fail-closed synthetic backend and fake presenters under `DEBUG && targetEnvironment(simulator) && !OFFLINE_RESOURCE_MEASUREMENTS`; unexpected requests never fall through to real networking. No real provider or email was used. The final source manifest and evidence are `native-authentication-phone-ui-source.json` and `native-authentication-evidence.json`; critical auth logic is unchanged from the native run. The generic-device Internal build passes with signing disabled, includes the exact licensed font, and contains neither the fixture host nor fixture launch flag. Evidence is `native-authentication-internal-build-evidence.json`. This is build evidence, not provisioning, installation or TestFlight verification.

Finally verify one real first sign-in, returning sign-in, cancellation, sign-out/restart and new-device recovery per enabled method on the dedicated configuration, with redacted evidence. Identity linking/removal, Apple revocation during account deletion, and administrator MFA remain separate release gates. The local checkpoint makes no real-provider, email-delivery or physical-device claim; hosted configuration evidence is separate in the deployment manifest.
