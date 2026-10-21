# Deployment manifest

Prepared 2026-10-02. Product scope and $100/month incremental budget approved by the user. The table records the intended configuration; verified native-auth deployment evidence is recorded below.

| Component | Selection | Cost / constraint |
|---|---|---|
| Supabase organization | Separate `Science Reader` organization | Existing TextBrain organization remains on its current Free plan |
| Supabase subscription | Pro | $25/month, includes $10 compute credit |
| Database environments | `science-reader-staging`, `science-reader-production` | Micro each: approximately $10/month each, first offset by included compute credit |
| Region | US West (Oregon), `us-west-2` | Management API currently recommends it; both environments use the same region |
| Expected Supabase base | Pro + two Micro projects | Approximately $35/month total, before excess metered usage/tax |
| Paid add-ons | None | No PITR, custom domain, IPv4, log drains, or larger compute |
| Supabase spend cap | Enabled where available | Does not replace application budgets or cap compute charges |
| Provider work | Disabled until dedicated keys, rate cards, and reservation tests are configured | At most $30/month aggregate staging + production, not $30 in each project |
| Static admin hosting | Initially pending; **2026-10-08 update:** dedicated `gradstep-admin` Pages at `https://admin.gradstep.ai`, deployment `349d3859` | $0 static Pages, no Functions; no server secrets in browser bundle. Hosting/denied-caller checks pass; real owner MFA/actions remain untested. [Evidence](ADMIN_HOSTING.md) |
| Independent backups | Destination pending account access | Must include Storage bytes and verified restores before real beta data |
| Apple distribution | Internal TestFlight first | Separate bundle/app identity; sandbox purchases; public release needs user review |

The Supabase Management API can create the organization and projects, but the documented API does not expose a payment-method/plan-upgrade operation. Prepare the new organization before asking the owner to complete its billing setup. Do not upgrade TextBrain's organization to work around that step.

Account evidence: Supabase PAT authenticated; existing organization `zofdgjhyrxcikkwclbyr` reported `plan: free`, with two TextBrain projects. The separate Science Reader organization `mhiweqpcwyqtyorgqhla` reported `plan: pro` after the owner completed its upgrade. Apple apps and bundle-ID queries returned HTTP 200 after the owner accepted two outstanding agreements. Science Reader's dedicated bundle and native Apple capability were registered on 2026-10-04 as recorded below. No Science Reader App Store app record has been created; final public naming remains separate.

Sources: [Supabase pricing](https://supabase.com/pricing), [organization billing](https://supabase.com/docs/guides/platform/billing-on-supabase), [Management API](https://supabase.com/docs/reference/api/introduction), [Apple app record creation](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).

## Native authentication readiness — 2026-10-04

### Pre-change inventory — 2026-10-04

Read-only inventory verified the dedicated staging project `coxhjvqpflgxkleydati`, its organization and its name before reading Auth configuration. Before the changes below, Apple and Google were disabled and their audience/client credentials were absent. The redirect allowlist was empty. Email authentication was enabled and new signups were disabled; email OTPs had **8 digits** and expired after **3,600 seconds**. Both returned confirmation/magic-link templates lacked `{{ .Token }}`. Custom SMTP host, port, credentials and sender fields were absent. No sign-in or email was attempted, and no complete configuration or credentials were saved or printed.

App Store Connect GETs returned HTTP 200; exact-identifier checks found neither the dedicated `com.sciencereader.ios` bundle nor its app record at that point. The existing team API credential was available through the three `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` locators in the known read-only TextBrain `.env`. Its `scripts/push-to-testflight.sh` documents this credential path, but that script is specific to TextBrain and was not run for Science Reader. Registration below subsequently established write authority for the dedicated identity; TextBrain's identity and app-specific credentials were not modified or reused.

### Applied configuration and verification — 2026-10-04

The reviewed operator registered bundle `com.sciencereader.ios`, resource ID `33Q7BMJ45Z`, description `Science Reader`, platform `IOS`, team/seed `3BJ33TT599`. It enabled `APPLE_ID_AUTH`, resource ID `33Q7BMJ45Z_APPLE_ID_AUTH`, with the standalone `PRIMARY_APP_CONSENT` selection. These are bundle/capability records, not an App Store app record or proof of a successful sign-in.

Two earlier apply attempts completed their respective Apple create operation before a readback check stopped the run. The first encountered the capability endpoint's rejection of `limit=200`; the second encountered the read representation's underscore-containing capability ID and omitted `enabled` field. Both failed reports remain preserved as `native-auth-configuration-applied.json` and `native-auth-configuration-applied-v2.json` under `.artifacts/`. The corrected operator reuses the exact existing records and does not rename or recreate them.

The reviewed [`plan-v4`](../../.artifacts/native-auth-configuration-plan-v4.json) confirmed both Apple records were present. [`applied-v3`](../../.artifacts/native-auth-configuration-applied-v3.json) then changed **seven Supabase Auth fields only**. The fresh [`verification report`](../../.artifacts/native-auth-configuration-verified.json) reports no remaining changes. All saved reports contain public configuration values only. The eight guarded final fields are:

| Auth field | Verified value |
|---|---|
| `external_apple_enabled` | `true` |
| `external_apple_client_id` | `com.sciencereader.ios` |
| `site_url` | `https://app.gradstep.ai` — hosted browser default; native flow still uses its explicit callback |
| `uri_allow_list` | `sciencereader://auth/callback`, `https://app.gradstep.ai`, `https://app.gradstep.ai/auth/callback` |
| `mailer_otp_length` | `6` |
| `mailer_otp_exp` | `600` seconds |
| `mailer_templates_confirmation_content` | Exact code template below |
| `mailer_templates_magic_link_content` | Exact same code template below |
| `disable_signup` | `true`, already set and preserved |

```html
<h2>Your Science Reader sign-in code</h2>
<p>Enter this code in the app:</p>
<p><strong>{{ .Token }}</strong></p>
<p>This code expires in 10 minutes. If you did not request it, ignore this email.</p>
```

Google, custom SMTP, Apple web secrets and unrelated Auth settings were unchanged. The hosted OAuth repair changed the
Auth `site_url` to `https://app.gradstep.ai` on 2026-10-09 while preserving the native callback in the allowlist.
Native Apple remains configured, but **web Apple sign-in is a separate account gate**: staging has no Apple OAuth secret and still uses the
native bundle audience. A dedicated Services ID, its domain/return URL association and a Science Reader client-secret
JWT must be created before enabling the browser button against staging. A secret from TextBrain must not be reused.
Email authentication remains enabled, but **new signups remain disabled** pending sender readiness and beta admission.
No provider sign-in, email delivery, purchase, app record, provisioning profile or physical-device operation was
performed by this configuration step.

### Operator scope and local evidence

[`scripts/configure-native-auth.py`](../../scripts/configure-native-auth.py) is a staging-only configuration operator. The default remains a read-only dry run:

```sh
python3 scripts/configure-native-auth.py --project-ref coxhjvqpflgxkleydati
```

`--apply` supports only these fixed, independently reviewed operations:

1. Register `com.sciencereader.ios`, description `Science Reader`, platform `IOS`, seed/team `3BJ33TT599`, if absent. An existing matching `IOS`/`UNIVERSAL` bundle is reused. A read-only lookup of the known `com.textbrain.ios` reference verifies the credential's team before any write; it is never modified.
2. Enable the dedicated bundle's `APPLE_ID_AUTH` capability with `APPLE_ID_AUTH_APP_CONSENT` / `PRIMARY_APP_CONSENT` enabled if absent. An existing capability whose primary consent cannot be verified is left for review rather than regrouped.
3. Patch changed values among the eight public Auth fields above. Existing additional Apple audiences, web secrets, other callbacks, missing guard fields or already-enabled signups stop this bootstrap operator.

Readback handles Apple's prefix-inclusive bundle filter by selecting the exact identifier locally, rejects duplicate exact matches and incomplete paginated collections, and uses the queryless capability endpoint. Capability resource IDs have a separate bounded underscore-compatible validator; request-path bundle IDs retain their stricter validator. For the stored capability, exactly one consent setting and one `PRIMARY_APP_CONSENT` option are required. Apple's read schema makes `enabled` optional: its absence is accepted only for that exact observed selection, while explicit false/null/nonboolean values, alternate/grouped choices and duplicate or multiple options/settings are refused. This is not a general assumption that absent booleans are enabled. [Apple capability read model](https://developer.apple.com/documentation/appstoreconnectapi/bundleidcapability), [option schema](https://developer.apple.com/documentation/appstoreconnectapi/capabilityoption), [primary/grouped identities](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple).

The isolated fake-HTTP suite passes **23 tests** in [the saved local log](../../.artifacts/native-auth-configuration-tests.log), including lost acknowledgements, scope/credential guards, truncated responses, exact/prefix bundle results, actual capability read shapes and a resume that performs no Apple writes. These tests never load real credentials or call hosted services. The final operator SHA-256 is `a02ce8f05d8f15b5f8b0c87e8fb5eb63677953afa4d6eb669c1922d40d9e84f6`; its test source is `bee6929697b8ffb72cb3edacdc77c3f596aa143e6b7a9c18419056a07174fef6`.

Since 2026-10-21 (review D7) its App Store Connect credential is Science Reader's dedicated key, located exactly as
`scripts/asc.mjs` locates it: `.env.appstore` names `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`, and the key file
must be under this repository's `secrets/`. It no longer reads another project's `.env` or key. The read-only team
reference lookup above is unchanged. The operator SHA-256 recorded above predates this change.

The operator uses only the fixed project, organization, hosts and paths; credentials remain in process memory. HTTP redirects are refused, request/response bodies are bounded, each write is attempted once, and fresh GET readback checks the desired state even after a lost acknowledgement. A missing/inconclusive readback stops the invocation without repeating the mutation. A later invocation starts with GETs; bundle/capability uniqueness and exact state checks make completed changes reusable. No rollback, deletion, app record creation, paid service purchase or credential rotation is exposed.

Supabase's configuration API has no documented compare-and-swap operation. The operator refuses observed changes to its owned fields before PATCH and sends only the changed allowlisted fields; it must run without another operator concurrently editing those same Auth fields. No distributed lock or atomic Apple-plus-Supabase transaction is claimed. Native-only Apple uses the bundle audience; a web Services ID and rotating client secret are a separate later configuration. If the API refuses the documented native-only settings, stop for diagnosis rather than inserting a borrowed or dummy secret. [Apple bundle request schema](https://developer.apple.com/documentation/appstoreconnectapi/bundleidcreaterequest/data-data.dictionary/attributes-data.dictionary), [Apple capability schema](https://developer.apple.com/documentation/appstoreconnectapi/capabilitysetting), [capability option schema](https://developer.apple.com/documentation/appstoreconnectapi/capabilityoption), [Supabase native Apple guide](https://supabase.com/docs/guides/auth/social-login/auth-apple).

The app-only `Config/ScienceReader.entitlements` and `CODE_SIGN_ENTITLEMENTS` setting specify Apple's `Default` entitlement; the resource-probe target does not inherit it. The internal generic iOS build passes **unsigned**; the fixture host/flag are absent from its binary and required fonts/reader resources are present. Native tests report **208 passed and three expected live/device skips**, with **five UI journeys passed**. These are build, simulated workflow and ownership checks. Provisioning/profile generation, a signed device installation with the enabled capability, and actual Apple/Google/email authentication remain unverified.

### Remaining account access and product inputs

| Area | Existing evidence | Remaining work or input |
|---|---|---|
| Apple native identity | Dedicated bundle/capability and staging native audience verified; app entitlement prepared; unsigned generic iOS build passes | Generate/refresh dedicated provisioning and test real native authentication. Create the dedicated App Store app record for TestFlight after its required app metadata is settled; public naming remains separate. Physical iPhone work is still paused. |
| Google | TextBrain's known config references an existing app-specific Google secret; its runbook describes Google Cloud Console / Google Auth Platform setup under project `TextBrain` | Obtain authenticated Google management access and create a separate Science Reader OAuth web client with the dedicated Supabase callback. Do not reuse or modify TextBrain's client. `gcloud` is not available on PATH; no reusable Google management credential was found among the known reference locators. CLI installation alone would not establish account authorization or create the consent configuration. |
| Google consent / branding | Reference runbook uses `textbrain.app` and Namecheap DNS for TextBrain | Decide the Science Reader support identity and owned homepage/privacy domain before publishing its consent branding. A restricted testing audience can be configured first once console access exists. No permission to repurpose TextBrain's app/domain configuration is inferred. |
| Email delivery | Six-digit/600-second code settings and both code templates verified; new signups remain disabled. No SMTP management credential or dedicated sender was found | Select/obtain a dedicated SMTP account and verified sender/domain within the agreed budget, configure DNS and sender credentials, verify actual code delivery, and only then review enabling beta signups. |

These are deployment/account gates, not missing password-form code. The default Supabase sender is limited to preauthorized team addresses and is unsuitable for ordinary beta recipients. The native six-digit contract now matches the deployed settings; sender readiness and actual delivery/provider acceptance remain separate gates. [Google provider setup](https://supabase.com/docs/guides/auth/social-login/auth-google), [email OTP templates](https://supabase.com/docs/guides/auth/auth-email-passwordless), [custom SMTP requirements](https://supabase.com/docs/guides/auth/auth-smtp).
