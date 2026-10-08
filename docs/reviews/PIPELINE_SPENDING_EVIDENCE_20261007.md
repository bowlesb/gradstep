# Pipeline infrastructure spending evidence — 2026-10-07

Read-only inspection of Google Cloud project `gradstep`, service `gradstep-pipeline`, region `us-west1`.
This is allocation evidence and a local implementation record, not an invoice or a deployed fix. No provider
generation, paid test, deployment, billing change, alert installation or BigQuery query was performed.

## Observed configuration and allocation

Window: **2026-10-06 22:12:54 through 2026-10-07 22:12:54 UTC**. The end is three minutes behind collection to
allow metric publication. All six reported revisions are included; deployments can overlap.

| Observation | Value |
|---|---:|
| Live revision, 100% traffic | `gradstep-pipeline-00006-g87` |
| Billing mode | Instance-based, `cpu-throttling=false` |
| Resource allocation | 1 vCPU, 2 GiB, one container |
| Service / revision maximum instances | 20 / 3 |
| Service / revision minimum instances | 0 / 0 |
| Concurrency / request timeout | 1 / 900 seconds |
| Aggregate billable instance time in window | 80,971.14 seconds, or **22.49 instance-hours** |
| CPU allocation | 81,017.45 vCPU-seconds |
| Memory allocation | 161,941.89 GiB-seconds |
| Reported requests | 1,246: 1,209 HTTP 200, 31 HTTP 401, 6 HTTP 429 |
| Dedicated-project Monitoring alert policies | None returned; complete listing |
| Dedicated-project BigQuery datasets | None returned; complete listing |
| Project billing | Enabled and linked to an account |

Instance-hours sum time across revisions/instances; they are not elapsed wall time. A per-revision peak must not
be added to another revision's peak and called simultaneous service concurrency. Request counts include checks,
wakeups and rejected traffic, not only successful paper imports. Missing metric series are reported as missing,
never as proof of zero usage. [Cloud Run metrics](https://docs.cloud.google.com/run/docs/monitoring).

At list prices of $0.000018/vCPU-second and $0.000002/GiB-second, that allocation would be approximately **$1.78
before credits and other charges**. It is not an observed charge. Discounts, available shared free allowances,
startup allocation, data transfer, registry, logs, secrets and taxes require invoice reconciliation. The previous
claim of a $0–2 monthly worker cost was unsupported. [Cloud Run pricing](https://cloud.google.com/run/pricing).

No invoice was retrieved. The absence of a dataset in `gradstep` does not rule out a billing export in another
project; the absence of Monitoring policies does not rule out billing-account budget alerts elsewhere. This
inspection deliberately did not enumerate unrelated projects, datasets or billing-account resources.

Reproduce with existing local gcloud authentication:

```sh
python3 scripts/inspect-pipeline-spending.py --hours 24 --output .artifacts/spending-controls-20261007/pipeline-spending-24h.json
```

The script reads only the dedicated service configuration, its regional Monitoring time series, project billing
link state, project dataset names and alert-policy counts. JSON contains numeric metrics, safe configuration and
checks, with pagination/response limits and explicit errors. It omits access tokens, environment variables,
provider payloads, account emails, request URLs, raw logs and billing account IDs. It does not query invoices or
automatically calculate an all-vendor bill. The raw local report remains under ignored `.artifacts/`.

## Implemented locally; cutover still required

The HTTP process now creates one worker thread for an authorized run, waits for the outcome, and terminates/joins
the thread before replying. The parent enforces an 840-second wall-clock limit outside the work's event loop,
including CPU-bound rendering, tagging and account-deletion sweeps. A timeout returns failure. Health, invalid
methods, unauthorized calls and overlapping wakeups create no additional work. This replaces the unsafe assumption
that several per-step deadlines sum to less than the 900-second service timeout.

The deploy script explicitly sets request-based CPU billing, minimum zero and maximum three at both service and
revision scope, then verifies billing mode, resources, concurrency, timeout and 100% traffic on the new revision.
It refuses to report verified success on mismatched readback. The image includes the dedicated thread entry point;
the HTTP process no longer loads renderer/SDK code for health or authorization checks.

Local validation: six Node lifecycle tests, including actual Node 24 TypeScript and SDK imports in a real thread
without provider calls; eleven Python deployment/inspection tests. Tests cover a blocked thread, join before
response, failure/invalid messages, no overlapping execution, configuration drift, safe output, paginated metrics,
unknown data and foreign-project refusal.

Rollout must first install the backend changes that retain unknown provider and upload liability. The hard stop
never performs an unrecorded retry or marks an unknown submission free; later queue/attempt reconciliation remains
necessary. After deployment, re-run the inspection, verify a fresh revision and billing policy, exercise an allowed
workflow, and compare the allocation trend over a representative interval. A billing flag does not establish the
new cost or workflow correctness by itself. See [pipeline lifecycle](../architecture/PIPELINE_RELIABILITY.md).

## Remaining infrastructure exposure and transparency work

The service remains publicly reachable with application-level authentication for pg_net wakeups. Unauthorized
requests can still consume some request/startup resources before rejection. The instance ceiling bounds concurrent
resources, not total monthly dollars. A future IAM-authenticated invocation design or deliberate edge rate control
needs to be assessed alongside scheduler credentials and hosting cost; it is not solved by customer credits.

The existing admin Usage page reports month-to-date provider/model call counts and estimated expense. Existing
immutable usage, operation, credit-ledger and reconciliation records support some investigation, but the page does
not expose a per-operation timeline, unknown attempt liability, per-account totals, invoice adjustments, fixed
commitments, infrastructure observations or cross-environment forecast. The spending-control backend/UI work must
make those distinctions visible without exposing paper text, prompts, signed URLs or provider secrets.

For infrastructure, retain dated allocation observations alongside the matching deployment policy, and record
invoice/credit adjustments separately. Until attribution is verified, label incremental Supabase and other fixed
allocations as unverified. The owner's **$100/month incremental Science Reader budget is unchanged**; existing
TextBrain costs remain excluded. Alerts and dashboard visibility are not substitutes for provider admission limits.
