#!/usr/bin/env python3
"""Fresh disposable local DB. Refuses remote hosts; never uses TextBrain's DB."""
import os
import pathlib
import subprocess
import uuid
import importlib.util
import argparse
from pg_tools import pg_bin  # SCIENCE_READER_PG_BIN, PATH, or the documented local tools

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pg_bin()
# The fixture modules (tests/database/*.py) read the same directory.
os.environ['SCIENCE_READER_PG_BIN'] = str(BIN)
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


# General suites against the current schema (review D5, 2026-10-21). The phase after this runs all 50 general suites in
# one database, in order, against migrations before 058 only: many test retired behavior (server PDF uploads, downloads
# and OCR, direct-provider routes) or read an earlier suite's rows and psql variables. These do neither and hold
# against every migration, so each runs alone in a copy of one migrated template; a suite that does not define the
# shared helpers itself gets tests/database/general_helpers.sql first. The rest are listed in docs/TESTING.md.
CURRENT_GENERAL = ['test_feed_topics_popularity', 'test_library_archive', 'test_library_compact', 'test_library_descriptors',
                   'test_library_query', 'test_library_query_edges', 'test_library_upload_visibility', 'test_library_v5_commands',
                   'test_owner_accounts', 'test_podcast_profile_v2', 'test_provider_allowance', 'test_reference_add',
                   'test_reserve_chat_quotes', 'test_sandbox_allowance', 'test_source_waits', 'test_store_account_transactions',
                   'test_store_purchases', 'test_store_verification_observations', 'test_store_verifier',
                   'test_store_zero_grant_reason', 'test_uploads', 'test_user_deletion', 'test_workflow_checks']


def current_schema_phase(sources, names):
    template = 'science_reader_test_tpl_' + uuid.uuid4().hex[:8]
    run('createdb', [template])
    try:
        run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', f'ALTER DATABASE "{template}" SET timezone TO \'UTC\''], capture_output=True)
        for source in [ROOT / 'tests/database/bootstrap.sql', *sources]:
            run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', template, '-f', str(source)], capture_output=True, text=True)
        for name in names:
            suite = ROOT / f'tests/database/{name}.sql'
            if not suite.is_file():
                raise SystemExit(f'Missing current-schema suite {suite.relative_to(ROOT)}')
            db = 'science_reader_test_' + uuid.uuid4().hex[:12]
            run('createdb', ['-T', template, db])
            try:
                if 'create schema test' not in suite.read_text():
                    run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(ROOT / 'tests/database/general_helpers.sql')],
                        capture_output=True, text=True)
                run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(suite)], capture_output=True, text=True)
                print('PASS', suite.relative_to(ROOT), '(current schema)', flush=True)
            finally:
                run('dropdb', [db])
    except subprocess.CalledProcessError as error:
        print(error.stdout or '')
        print(error.stderr or '')
        raise
    finally:
        run('dropdb', [template])


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reader-issuer-fence-candidate', action='store_true',
                    help='Also apply the reviewed pending 045 ACL to the disposable full-suite fixture; no hosted changes.')
parser.add_argument('--openrouter-only', action='store_true', help='Run the affected OpenRouter cutover fixture only.')
parser.add_argument('--auth-admission-only', action='store_true', help='Run the affected durable beta-admission fixture only.')
parser.add_argument('--testing-allowance-only', action='store_true', help='Run testing allowance, provider and account lifecycle checks.')
parser.add_argument('--note-assets-only', action='store_true', help='Run the encrypted note image inventory, quota and deletion checks (migration 095).')
parser.add_argument('--spending-fixes-only', action='store_true', help='Run the 2026-10-21 spending review fixtures (migrations 0100 and later).')
parser.add_argument('--server-add-only', action='store_true', help='Run the server add-once fixture (migration 120) only.')
args = parser.parse_args()
# Review 2026-10-21 (docs/reviews/WEB_SERVER_REVIEW_20261021.md): spending, budget and reconciliation fixes, in
# migration order. They run against every migration, in the final phase and alone with --spending-fixes-only.
# OpenRouter-only reporting (0140) and the owner's per-account costs (0141) follow them (owner, 2026-10-21).
SPENDING_FIXES = [ROOT / 'tests/database' / name for name in ['provider_attempt_windows.sql', 'openrouter_tariff_validity.sql', 'openrouter_auto_reconcile.sql', 'budget_pauses_persist.sql', 'owner_budget_limit.sql', 'testing_allowance_safeguards.sql', 'scoped_provider_breakers.sql', 'openrouter_admit_and_dispatch.sql', 'sql_hot_paths.sql', 'openrouter_only_reporting.sql', 'account_costs.sql']]
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
if args.spending_fixes_only:
    phase([*all_migrations, *SPENDING_FIXES], [])
    raise SystemExit(0)
if args.note_assets_only:
    phase([*all_migrations, ROOT / 'tests/database/note_assets.sql', ROOT / 'tests/database/account_deletion_episode_folders.sql'], ['note_assets_concurrency'])
    raise SystemExit(0)
if args.server_add_only:
    phase([*all_migrations, ROOT / 'tests/database/server_add_once.sql', ROOT / 'tests/database/no_import_quota.sql'], [])
    raise SystemExit(0)
if args.auth_admission_only:
    phase([*all_migrations, ROOT / 'tests/database/durable_beta_admission.sql', ROOT / 'tests/database/beta_admission_revocation.sql'], [])
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

# Grants as a hosted project sees them (bootstrap.sql emulates Supabase's defaults): migration 135 and every final
# function's anon/authenticated reach. First in its phase, before any fixture creates objects.
phase([*all_migrations, ROOT / 'tests/database/default_privileges.sql', ROOT / 'tests/database/openrouter_all_inference.sql', ROOT / 'tests/database/idle_metadata_health.sql', ROOT / 'tests/database/durable_beta_admission.sql', ROOT / 'tests/database/testing_allowance.sql', ROOT / 'tests/database/note_assets.sql', ROOT / 'tests/database/server_add_once.sql', ROOT / 'tests/database/no_import_quota.sql', *SPENDING_FIXES], ['testing_allowance_concurrency', 'note_assets_concurrency'])

# Review 2026-10-21 (A8/A16/A17/A21/A22): podcast device sources leave with the account, podcast source reservation,
# beta-admission revocation, and the account-deletion sweep's back-off and stall alert; after every migration.
phase([*all_migrations, ROOT / 'tests/database/podcast_device_source_deletion.sql', ROOT / 'tests/database/podcast_source_reservation.sql', ROOT / 'tests/database/beta_admission_revocation.sql', ROOT / 'tests/database/account_deletion_sweep.sql'], [])
current_schema_phase(all_migrations, CURRENT_GENERAL)
