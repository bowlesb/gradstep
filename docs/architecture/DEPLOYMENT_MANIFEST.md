# Deployment manifest

Prepared 2026-10-02. Product scope and $100/month incremental budget approved by the user. This is the intended configuration; deployment evidence is recorded separately.

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
| Static admin hosting | Selection pending account access | Must fit remaining fixed-cost allocation; no secrets in browser bundle |
| Independent backups | Destination pending account access | Must include Storage bytes and verified restores before real beta data |
| Apple distribution | Internal TestFlight first | Separate bundle/app identity; sandbox purchases; public release needs user review |

The Supabase Management API can create the organization and projects, but the documented API does not expose a payment-method/plan-upgrade operation. Prepare the new organization before asking the owner to complete its billing setup. Do not upgrade TextBrain's organization to work around that step.

Current account evidence: Supabase PAT authenticated; existing organization `zofdgjhyrxcikkwclbyr` reports `plan: free`, with two TextBrain projects. The separate Science Reader organization `mhiweqpcwyqtyorgqhla` now reports `plan: pro` after the owner completed its upgrade. Apple apps and bundle-ID queries now return HTTP 200 after the owner accepted two outstanding agreements. TextBrain is the only app record currently visible. Science Reader's final public name is still being discussed; no new App Store app record or bundle identity has been registered.

Sources: [Supabase pricing](https://supabase.com/pricing), [organization billing](https://supabase.com/docs/guides/platform/billing-on-supabase), [Management API](https://supabase.com/docs/reference/api/introduction), [Apple app record creation](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).
