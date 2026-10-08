"""Execute the operator's exact aggregate readiness query against the real schema."""
import importlib.util
import json
from pathlib import Path
import subprocess


def verify(binary, database, base):
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location('real_schema_readiness', root / 'scripts/pipeline_readiness.py')
    readiness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(readiness)
    result = subprocess.run([str(binary / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database,
                             '-c', 'begin read only; ' + readiness.STATE_SQL + '; rollback;'],
                            check=True, capture_output=True, text=True)
    state = json.loads(result.stdout)
    for key in ('pipeline_enabled', 'tags_enabled', 'provider_enabled', 'native_search_enabled',
                'asset_enforced', 'inventory_scan_active'):
        assert type(state[key]) is bool, key
    for key in ('pipeline_claims', 'tag_claims', 'legacy_open_chat', 'provider_unresolved',
                'provider_liability_microusd', 'asset_writes_unresolved', 'inventory_discrepancies'):
        assert type(state[key]) is int and state[key] >= 0, key
    assert state['reader_mode'] in ('legacy', 'dual', 'bounded')
    assert set(state['purchase_cleanup']) == {'active', 'schedule', 'expected_command'}
    assert type(state['purchase_cleanup']['active']) is bool
    # Fixtures do not run hosted cron. Missing cron must block rather than be
    # accepted as a green default; the query itself must remain read-only.
    assert 'purchase_cleanup_not_ready' in readiness.database_blockers({'migration_prefix_verified': True, 'state': state})
    print('PASS deployment_readiness (real schema, read-only query, missing cron blocks)', flush=True)
