# Admin hosting

Local deployment path prepared on 2026-10-08; **not a deployment record**. The intended admin is a static Pages
application at `https://admin.gradstep.ai`, separate from the browser reader at `https://app.gradstep.ai`.
It uses the existing staging Supabase project. Owner/support roles, real MFA and per-action server authorization
remain the boundary; a public sign-in page is not privileged access. This work creates no paid subscription.

## Read-only observation

At 2026-10-08 08:13:26 UTC the configured Cloudflare account returned the existing `gradstep-app` project, but
`gradstep-admin` returned HTTP 404. The `gradstep.ai` zone was active on the Free Website plan, and its exact
`admin.gradstep.ai` DNS query returned no records. This does not reserve the proposed Pages name or prove a future
custom domain is active. Evidence: `.artifacts/admin-hosting/cloudflare-readonly.json` in the spending-observations
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
header detachment is forbidden so a later rule cannot remove inherited security headers. Admin scripts/styles remain self-only. Its required data/blob images serve
the TOTP QR and authenticated support screenshot previews. No remote script or arbitrary iframe is permitted.

The admin has its own origin and `science-reader.admin.staging` Auth storage key; it does not use the reader's
device-key storage. Its current password/TOTP sign-in needs no change to customer OAuth redirects or Auth's
site URL. Before deployment, add the exact `https://admin.gradstep.ai` origin to the existing Edge CORS allowlist
while preserving customer app origins. CORS does not replace the owner/MFA gate. Do not add preview URLs or
wildcards to privileged-origin configuration merely to make a preview convenient.

## Required first provisioning and verification

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
See [Pages headers](https://developers.cloudflare.com/pages/configuration/headers/). No hosting status in other
documents should be changed to deployed until the operator records the actual deployment/domain evidence.

## Local checks

`node --test tests/operations/web-deployment.test.mjs` verifies target/build separation, production-only public
environment values, build-only behavior, auth-key/credential gates, CSP/cache requirements and fixture/server-asset
rejection with synthetic temporary files. No test provisions infrastructure or sends an owner action.

The real configured production build passed `node scripts/deploy-web.mjs admin --build-only`. The reusable
`node scripts/check-admin-build.mjs` smoke served that bundle with its actual CSP, verified the sign-in screen
and rejection of all four development-fixture query routes, and checked desktop and 390-pixel dark layouts.
There were no off-origin requests, JavaScript/CSP errors, owner actions or hosted writes. Evidence and screenshots
are in `.artifacts/admin-hosting/production-build-check.json`, `production-sign-in.png` and
`production-sign-in-phone-dark.png`. This local check does not establish hosted owner MFA or a working custom domain.
