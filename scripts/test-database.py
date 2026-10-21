#!/usr/bin/env python3
"""Fresh disposable local DB. Refuses remote hosts; never uses TextBrain's DB."""
import os
import pathlib
import subprocess
import uuid
import importlib.util
import argparse

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
BASE = ['-h', '127.0.0.1', '-p', '55431']
# Every operation targets the disposable loopback fixture. Inherited libpq
# services/options/users must not redirect or alter that authority.
for key in list(os.environ):
    if key.startswith('PG'):
        del os.environ[key]

def run(binary, args, **kwargs):
    return subprocess.run([str(BIN / binary), *BASE, *args], check=True, **kwargs)

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f'tests/database/{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def phase(sources, checks):
    db = 'science_reader_test_' + uuid.uuid4().hex[:12]
    run('createdb', [db])
    try:
        # Application receipts use UTC days. Persist the fixture setting so all
        # independent psql/race sessions share it, including around UTC midnight.
        run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', f'ALTER DATABASE "{db}" SET timezone TO \'UTC\''], capture_output=True)
        for source in [ROOT / 'tests/database/bootstrap.sql', *sources]:
            run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(source)], capture_output=True, text=True)
            print('PASS', source.relative_to(ROOT), flush=True)
        for name in checks:
            if name in ('upgrade', 'library_compact_upgrade', 'library_upload_visibility_upgrade', 'provider_accounting_upgrade'):
                module(name).verify(BIN, db, BASE, ROOT)
            else:
                module(name).verify(BIN, db, BASE)
    except subprocess.CalledProcessError as error:
        print(error.stdout or '')
        print(error.stderr or '')
        raise
    finally:
        run('dropdb', [db])


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reader-issuer-fence-candidate', action='store_true',
                    help='Also apply the reviewed pending 045 ACL to the disposable full-suite fixture; no hosted changes.')
parser.add_argument('--openrouter-only', action='store_true', help='Run the affected OpenRouter cutover fixture only.')
parser.add_argument('--auth-admission-only', action='store_true', help='Run the affected durable beta-admission fixture only.')
parser.add_argument('--testing-allowance-only', action='store_true', help='Run testing allowance, provider and account lifecycle checks.')
parser.add_argument('--note-assets-only', action='store_true', help='Run the encrypted note image inventory, quota and deletion checks (migration 095).')
args = parser.parse_args()
migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
fence = ROOT / 'supabase/migrations/202610080045_reader_issuer_fence.sql'
if args.reader_issuer_fence_candidate:
    pending = pathlib.Path(str(fence) + '.pending')
    if fence.exists() or not pending.is_file():
        parser.error('Candidate mode requires only the pending 045 file; promoted migrations are tested normally.')
    migrations = sorted([*migrations, pending])
all_migrations = migrations
if args.testing_allowance_only:
    phase([*all_migrations, ROOT / 'tests/database/testing_allowance.sql', ROOT / 'tests/database/openrouter_all_inference.sql', ROOT / 'tests/database/durable_beta_admission.sql'], ['testing_allowance_concurrency'])
    raise SystemExit(0)
if args.note_assets_only:
    phase([*all_migrations, ROOT / 'tests/database/note_assets.sql', ROOT / 'tests/database/account_deletion_episode_folders.sql'], ['note_assets_concurrency'])
    raise SystemExit(0)
if args.auth_admission_only:
    phase([*all_migrations, ROOT / 'tests/database/durable_beta_admission.sql'], [])
    raise SystemExit(0)
if args.openrouter_only:
    phase([*all_migrations, ROOT / 'tests/database/openrouter_all_inference.sql', ROOT / 'tests/database/idle_metadata_health.sql'], [])
    raise SystemExit(0)
# Historical provider fixtures run against their own contract, before the OpenRouter-only cutover.
cutover_migrations = [p for p in migrations if p.name < '202610180089']
migrations = [p for p in migrations if p.name < '202610130058']
tests = sorted((ROOT / 'tests/database').glob('test_*.sql'))
checks = ['concurrency', 'upgrade', 'library_compact_upgrade', 'library_upload_visibility_upgrade', 'library_query_concurrency', 'library_v5_command_concurrency', 'provider_accounting_upgrade', 'provider_accounting_concurrency', 'pipeline_retry_concurrency', 'asset_accounting_concurrency', 'pdf_upload_concurrency', 'sandbox_allowance_concurrency', 'store_purchase_lock_concurrency', 'store_verification_concurrency', 'deployment_readiness', 'store_verifier_concurrency', 'credit_resume_concurrency', 'feed_concurrency', 'podcast_concurrency', 'podcast_worker_journey']
phase([*migrations, *tests], checks)
# Natural expiry must cross committed transactions. Isolate those fixture rows
# from suites that intentionally assert exact global account/ledger counts.
phase([*migrations, ROOT / 'tests/database/subscription_upgrade_credits.sql'], ['subscription_upgrade_concurrency'])
# Server paper copies retired (migration 080): its own phase, after every migration; Listen on a legacy item from the
# device's text (081) needs that retirement too.
phase([*cutover_migrations, ROOT / 'tests/database/paper_copies_retired.sql', ROOT / 'tests/database/podcast_legacy_device_sources.sql'], [])
if fence.is_file() or args.reader_issuer_fence_candidate:
    # Its role, rollback and multi-session checks own another disposable DB so
    # committed lifecycle fixtures do not alter unrelated suites' global counts.
    module('reader_issuer_fence').verify()

# The search switches (migration 075) record themselves against the owner: one exists before they apply.
switch = ROOT / 'supabase/migrations/202610160075_device_search_on.sql'
phase([*[p for p in cutover_migrations if p.name < switch.name], ROOT / 'tests/database/feed_datacite_owner.sql',
       *[p for p in cutover_migrations if p.name >= switch.name], ROOT / 'tests/database/feed_datacite.sql'], [])

# Retained legacy accounting is verified before the explicit runtime cutover.
phase([*cutover_migrations, ROOT / 'tests/database/html_first_cutover.sql', ROOT / 'tests/database/chat_follow_up_quotes.sql', ROOT / 'tests/database/admin_health.sql', ROOT / 'tests/database/budget_period.sql', ROOT / 'tests/database/chat_study_quotes.sql', ROOT / 'tests/database/podcast_script_repair.sql', ROOT / 'tests/database/podcast_deepseek_profiles.sql', ROOT / 'tests/database/podcast_writer_choice.sql', ROOT / 'tests/database/podcast_device_sources.sql', ROOT / 'tests/database/account_deletion_episode_folders.sql', ROOT / 'tests/database/device_source_metadata.sql', ROOT / 'tests/database/device_search.sql', ROOT / 'tests/database/provider_resilience.sql', ROOT / 'tests/database/podcast_source_deletion.sql', ROOT / 'tests/database/arxiv_egress_off.sql', ROOT / 'tests/database/chat_deepseek.sql', ROOT / 'tests/database/contained_overruns.sql', ROOT / 'tests/database/figure_view_actions.sql', ROOT / 'tests/database/provider_billing_attention.sql', ROOT / 'tests/database/import_metadata.sql', ROOT / 'tests/database/chat_gemini.sql', ROOT / 'tests/database/chat_claude_openrouter.sql'], [])

phase([*all_migrations, ROOT / 'tests/database/openrouter_all_inference.sql', ROOT / 'tests/database/idle_metadata_health.sql', ROOT / 'tests/database/durable_beta_admission.sql', ROOT / 'tests/database/testing_allowance.sql', ROOT / 'tests/database/note_assets.sql'], ['testing_allowance_concurrency', 'note_assets_concurrency'])
