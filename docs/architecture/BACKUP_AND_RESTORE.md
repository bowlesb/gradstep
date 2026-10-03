# Encrypted backup and restore contract

Status: implementation and local restore drill in progress. No independent destination or scheduled backup is active yet. This is not a recovery guarantee.

## Checkpoint contents

A backup contains one PostgreSQL repeatable-read snapshot of `app_private`, `public`, `auth`, `storage`, and `science_reader_migrations`, plus the bytes of every application object marked `verified` in that same snapshot. The applied migration ledger must be a nonempty, hash-matching prefix of the source files before a checkpoint is accepted. Newer pending files are allowed, so a pre-deployment checkpoint remains possible; duplicates, gaps, missing files and changes to applied files fail. The manifest records only the snapshot's applied versions. Restore validates the same prefix and compares the restored ledger against the signed manifest. Finish the backup before starting a migration; concurrent schema deployment is outside this manual procedure. Platform-managed schema definitions are retained for investigation and a quarantined local drill; they must not be applied indiscriminately over a new hosted Supabase project's managed schemas.

Database dumps and objects stream directly into `age` recipient encryption. Plaintext exports are not written to disk. An encrypted manifest records the project/environment, database version, migration hashes, table row counts, object identities, lengths, content hashes, and archive hashes. The exporter signs the encrypted manifest with a separate Ed25519 identity. Restore verifies the signature using the public key recorded in source before accepting SQL; recipient encryption by itself does not prove who created an archive. Only a fully completed directory is published as a checkpoint. The scheduled backup worker needs the public encryption recipient and its signing identity, not the decryption identity.

The initial staging decryption identity is a protected, ignored local file. The owner must retain a separate offline copy before this becomes a recovery mechanism. Keeping the only key beside the only backup does not provide disaster recovery. Production receives a separate identity and credentials.

## Consistency and deletion

Verified storage paths are immutable. New uploads remain pending until byte length and SHA-256 are verified. A PostgreSQL snapshot selects the exact versions to copy; later additions do not belong to that checkpoint. Objects deleted or corrupted during export cause the entire checkpoint to fail, leaving the previous completed backup intact. A missing object is never silently omitted.

Before automated retention of verified objects is enabled, its physical-deletion grace must exceed the backup interval and maximum run time. The existing orphan janitor only removes unlinked pending uploads, which are not part of a restorable checkpoint. Future account deletion and retention must preserve deletion records and make their backup expiry explicit.

Do not restore pending/deleting objects as usable files. Resume their reconciliation only after quarantine checks. Database/object consistency does not mean a provider's external state was rolled back with the database.

## Recovery procedure

1. Decrypt and verify the manifest, the database dump, and every object in a local, access-restricted quarantine. Reject unknown formats, unsafe paths, missing/truncated files, or checksum mismatches.
2. Restore into an isolated target with no provider keys, job schedules, outbound integrations, or customer traffic. Never restore over the source project. A local PostgreSQL drill proves data, schema, and file integrity; it does not prove hosted Auth, Storage, or encryption-root portability.
3. For a hosted replacement, create compatible managed Auth/Storage schemas through Supabase, replay application migrations, then restore compatible data and immutable objects. Restore the Auth account mapping; invalidate old sessions. Reapply the versioned Auth trigger and any custom managed-schema policies.
4. Reconcile provider job IDs, outstanding reservations, subscription events, deletions, and storage states before enabling work. Keep all platform budgets paused until this is complete. Replaying a queued row must not submit another paid request automatically.
5. Verify account isolation, device envelopes and encrypted history with retained test keys, private image/paper retrieval, credit conservation, and report threads. Record duration and recovered checkpoint age before claiming the proposed 24-hour recovery-point/one-working-day recovery-time targets.

Supabase's database backup excludes Storage object bytes. Manual logical restoration of Vault or column-encrypted data also requires the project encryption root key; Supabase's managed restore-to-new-project flow copies that key automatically. Auth MFA/provider configuration and secrets require their own hosted recovery verification. Do not describe the local drill as complete cloud disaster recovery.

## Connection and credentials

Database exports use the session pooler on port 5432 with `sslmode=verify-full`. `infra/supabase-ca-2021.crt` is the certificate published by Supabase's Studio configuration, retrieved over HTTPS; file SHA-256 is `700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7`. A pooler backend's `pg_stat_ssl` does not describe the client's TLS connection; `psql` connection information verifies the client leg.

The manual staging drill uses existing protected staging credentials. A scheduled backup deployment requires a dedicated read-only database identity, read-only object access, a separate write-only backup destination credential, retention, and failure alerts. It must not receive management or provider credentials.

Sources: [Supabase backup scope](https://supabase.com/docs/guides/platform/backups), [logical restore guidance](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore), [official CA URL configuration](https://github.com/supabase/supabase/blob/master/apps/studio/hooks/custom-content/custom-content.json), [age encryption](https://github.com/FiloSottile/age).
