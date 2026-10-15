# Admin hosting

**Live on 2026-10-08:** the static admin is at `https://admin.gradstep.ai`, Pages deployment **349d3859** in
the dedicated **gradstep-admin** direct-upload project, separate from the browser reader at `https://app.gradstep.ai`.
It uses the existing staging Supabase project. Owner/support roles, real MFA and per-action server authorization
remain the boundary; a public sign-in page is not privileged access. It uses free static Pages with no Functions
and no new paid subscription. This does not establish the costs of other infrastructure.

## Deployment evidence and remaining owner check

The operator created the project with production branch `main`, associated `admin.gradstep.ai`, then created
its proxied CNAME to `gradstep-admin.pages.dev`. The initial provisioning readback showed domain initialization;
the later **08:31:23 UTC** live smoke received HTTPS 200 at the custom domain with the reviewed CSP,
`Strict-Transport-Security: max-age=31536000` and `Cache-Control: no-transform, no-cache`. The sign-in button
was enabled, the phone layout had no overflow, and there were no console errors or unexpected requests.
The desktop and phone-dark public sign-in screenshots were also inspected locally.

The exact admin origin was added to `ADMIN_ORIGINS` while preserving the existing app origins. Live preflights
for `admin-spending`, `admin-accounts` and `support-assets` returned 204 with that exact origin. The deployed
spending endpoint's source matches reviewed `31bcf1b`; anonymous and customer deny checks pass without adding
an observation or spending provider credits. Hosting/tooling source is reviewed `afa7294`.

An audited bootstrap granted the owner role to the existing verified account. It did not change the password
or MFA factors and did not create an authenticated owner session. **Real owner password/TOTP sign-in and hosted
owner actions remain untested. No invoice evidence has been entered.** Normal owner MFA is required before doing so.

Evidence in the main checkout's `.artifacts/takeover-20261008/`: `admin-hosting-provision.json`,
`admin-live-smoke.json`, `admin-owner-bootstrap.json`, `admin-spending-source-proof.json` and
`admin-spending-postdeploy-verified.log`. These records distinguish infrastructure and denied-caller checks
from the remaining owner-session acceptance test.

## Before provisioning — historical read-only observation

At 2026-10-08 08:13:26 UTC the configured Cloudflare account returned the existing `gradstep-app` project, but
`gradstep-admin` returned HTTP 404. The `gradstep.ai` zone was active on the Free Website plan, and its exact
`admin.gradstep.ai` DNS query returned no records. This was the pre-deployment state, superseded by the live
evidence above. Evidence: `.artifacts/admin-hosting/cloudflare-readonly.json` in the spending-observations
worktree. No project, domain, DNS, account plan or Auth configuration was changed by this inspection.

## Deployment path

`node scripts/deploy-web.mjs admin --build-only` runs the repository's `npm run build:admin`, validates the output
and makes no Cloudflare call. `node scripts/deploy-web.mjs admin` then uploads only `apps/admin/dist` to Pages
project **gradstep-admin**, production branch **main**, with the repository's locked Wrangler. It does not create a
project, add a custom domain, modify DNS or deploy Supabase functions. Reader/info-site targets remain `app` and
`site` with their existing projects; changing an argument cannot overwrite their target with admin output.
The locked Wrangler's explicit Pages `--force` mode disables its agent-specific fallback to creating a Worker
when a Pages project is missing. Noninteractive stdin then makes a missing project fail instead of prompting to
create one. This flag selects the hosting product; it does not bypass the build or security gates.

The client build receives only the selected staging URL, its public anon JWT and `staging` as Vite variables.
Inherited Vite overrides and known server/Cloudflare credentials are removed from the build environment, and
`NODE_ENV=production` prevents development fixture entrypoints. Local admin `.env` overrides are refused. Gates
validate the configured project/anon role, exact backend CSP, HSTS, no-transform and self-only executable assets;
scan built files for protected `.env.staging` values; and reject development fixtures, source maps, symlinks,
environment files and Pages Functions. Route-specific headers are restricted to the three exact cache-only rules;
header detachment is forbidden so a later rule cannot remove inherited security headers. Admin scripts/styles
remain self-only. Its required data/blob images serve
the TOTP QR and authenticated support screenshot previews. No remote script or arbitrary iframe is permitted.

The admin has its own origin and `science-reader.admin.staging` Auth storage key; it does not use the reader's
device-key storage. Its current password/TOTP sign-in needs no change to customer OAuth redirects or Auth's
site URL. The deployed Edge CORS allowlist includes the exact `https://admin.gradstep.ai` origin and preserves
customer app origins. CORS does not replace the owner/MFA gate. Do not add preview URLs or
wildcards to privileged-origin configuration merely to make a preview convenient.

## Provisioning and verification procedure

First provisioning is complete. Ordinary updates reuse the existing project/domain and start at step 3;
steps 1–2 describe a fresh or recovery setup, not resources to recreate on each release.

1. Create the dedicated direct-upload Pages project `gradstep-admin` with production branch `main` in the same
   verified Cloudflare account as the existing reader. Do not enable Pages Functions or purchase a service tier.
2. Associate `admin.gradstep.ai` with that project through Pages custom domains, then create/verify its proxied
   CNAME to `gradstep-admin.pages.dev`. Check existing records before writing; never overwrite a conflicting
   hostname. [Cloudflare's custom-domain instructions](https://developers.cloudflare.com/pages/configuration/custom-domains/)
   require Pages association before a manually added CNAME; DNS alone is not a working deployment.
3. Run the local build gate, review the exact bundle and deploy the `admin` target. Wait for the custom domain and
   certificate to become active. Verify the domain is assigned to this project, rather than inferring this from DNS.
4. Verify HTTPS 200, the exact CSP/HSTS/no-transform headers, no injected analytics script, and the sign-in screen.
   Querying `?fixture=spending` must still show sign-in in the production bundle. Confirm anonymous/customer
   callers cannot invoke owner mutations. Separately exercise a real owner MFA session before claiming that
   hosted owner actions work or entering invoice evidence.

Cloudflare applies the static `_headers` file to Pages assets; matching Cache-Control values are combined, so
the global `no-transform` remains alongside document `no-cache` and hashed-asset `immutable` rules.
See [Pages headers](https://developers.cloudflare.com/pages/configuration/headers/). Record the actual deployment
and custom-domain evidence for each release; a successful build alone does not establish either.

## Local checks

`node --test tests/operations/web-deployment.test.mjs` verifies target/build separation, production-only public
environment values, build-only behavior, auth-key/credential gates, CSP/cache requirements and fixture/server-asset
rejection with synthetic temporary files. All six cases pass, including independent review of header-detachment
and route-override refusal. No test provisions infrastructure or sends an owner action.

The real configured production build passed `node scripts/deploy-web.mjs admin --build-only`. The reusable
`node scripts/check-admin-build.mjs` smoke served that bundle with its actual CSP, verified the sign-in screen
and rejection of all four development-fixture query routes, and checked desktop and 390-pixel dark layouts.
There were no off-origin requests, JavaScript/CSP errors, owner actions or hosted writes. Evidence and screenshots
are in `.artifacts/admin-hosting/production-build-check.json`, `production-sign-in.png` and
`production-sign-in-phone-dark.png`. These local checks are separate from the live-domain proof above and do not
establish hosted owner MFA.

## A missing asset is a 404, and every deploy is checked live (2026-10-15)

During the Health deploy the admin's new script was requested while Cloudflare was still switching deployments; the
old deployment answered with its single-page fallback (index.html, 200), the `/assets/*` rule marked it immutable, and
an edge kept it for requests carrying an `Origin` header (every module script). The live admin was blank. Two changes:
the admin ships `404.html` (it routes by `#hash` only), so a missing asset is a 404 instead of a page cached for a
year; and `scripts/deploy-web.mjs` now waits until the domain serves the new index, then fetches each script and
stylesheet with an `Origin` header and fails the deploy if one comes back as anything else (`verifyLive`, tested in
`tests/operations/web-deployment.test.mjs`, part of `npm test`). The browser reader keeps its fallback (it routes by
path: `/feed`, `/paper/…`), so the live check is its guard; recovery is a new deploy whose changed files get new names.
