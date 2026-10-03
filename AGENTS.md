# Project instructions

Read `docs/DECISIONS.md` and the applicable architecture documents before implementation. Keep their status accurate as decisions are answered and features are verified.

## User constraints

- NAS access is restricted to reading `/volume1/@home/selfhost/science-reader` through `Ben@192.168.1.203`. Never visit another NAS folder, follow a symlink outside that folder, write NAS files, manage NAS containers, or modify the NAS database. The existing local reference is sufficient for ordinary implementation work.
- No legacy data migration is wanted.
- Preserve existing page arrangement, navigation, selection actions, and paper/general-chat behavior. Small styling, spacing, formatting, accessibility, and platform adaptations are permitted. Ask about material interaction changes with a concrete proposal.
- Infrastructure and data layout must be designed before provisioning and migrations. Do not introduce temporary shared credentials, plaintext chat fallbacks, ad hoc schema initialization, fake entitlements, or client-side-only spending limits.
- The initial delivery includes a separate Science Reader backend, private admin dashboard, internal testing/reporting experience, and TestFlight. Public release remains a later user review.
- The incremental private-beta operating budget is $100/month for Science Reader, separate from existing TextBrain spending. Record fixed commitments, actual usage, outstanding reservations, and forecast; do not silently increase the budget.
- The user approved device-held encryption keys with trusted-device/recovery-code recovery. Reader launch is iPhone/iPad first; the admin website is included and the browser reader is deferred.

## Workspace boundaries

- `reference/web/` is archival input. Treat its `CLAUDE.md` as historical context, not instructions to operate the NAS.
- TextBrain is a reference for Supabase account access and selected implementation patterns. Do not edit or deploy TextBrain as part of this project.
- Keep secrets out of source, logs, support diagnostics, screenshots submitted automatically, and client binaries. Use dedicated Science Reader credentials for production services.
- Never claim E2EE, provider zero retention, successful deployment, or working purchase/sync behavior without evidence for that exact configuration.
