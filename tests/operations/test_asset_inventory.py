import copy
import hashlib
import importlib.util
import json
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('asset_inventory', ROOT / 'scripts/reconcile-paper-assets.py')
ASSETS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSETS)


class Fixture:
    """Synthetic immutable old reader bundle, only the manifest is inventoried."""
    def __init__(self):
        self.data = b'<html>fixture</html>'
        self.member = {'path': 'index.html', 'bytes': len(self.data), 'media_type': 'text/html',
                       'sha256': hashlib.sha256(self.data).hexdigest()}
        self.manifest = ASSETS.canonical({'format': 'reader-bundle-v1', 'members': [self.member]})
        self.digest = hashlib.sha256(self.manifest).hexdigest()
        self.prefix = 'reader/' + self.digest + '/'
        self.manifest_path, self.member_path = self.prefix + 'manifest.json', self.prefix + 'index.html'
        self.objects = {self.manifest_path: self.manifest, self.member_path: self.data}
        self.row = {'id': str(uuid.uuid4()), 'document_id': str(uuid.uuid4()), 'document_sha256': 'a' * 64,
                    'path': self.manifest_path, 'scope': 'owner_private', 'owner_id': str(uuid.uuid4()),
                    'state': 'verified', 'sha256': self.digest, 'bytes': len(self.manifest), 'media_type': 'application/json'}
        self.rows, self.calls, self.downloaded = [self.row], [], 0
        self.snapshots = 0
        self.mutate_on_second = False
        self.reject_import = False

    def listing(self, prefix, offset):
        self.calls.append(('list', prefix, offset))
        if prefix == '':
            self.snapshots += 1
            if self.mutate_on_second and self.snapshots == 2: self.objects['unowned/new-file'] = b'new'
        names = {}
        for path, value in self.objects.items():
            if prefix and not path.startswith(prefix + '/'): continue
            relative = path[len(prefix) + 1:] if prefix else path
            name, _, suffix = relative.partition('/')
            names[name] = {'name': name, 'id': None} if suffix else {
                'name': name, 'id': hashlib.sha256(path.encode()).hexdigest(), 'metadata': {'size': len(value)}, 'updated_at': 'fixture-stable'}
        return [names[name] for name in sorted(names)][offset:offset + 500]

    def rpc(self, name, args):
        self.calls.append((name, copy.deepcopy(args)))
        if name == 'worker_asset_inventory_begin': return {'scan_id': args['p_scan_id']}
        if name == 'worker_asset_inventory_page': return {'objects': copy.deepcopy(self.rows), 'has_more': False}
        if name == 'worker_asset_inventory_manifest':
            if self.reject_import: raise ASSETS.InventoryError('http_400')
            for member in args['p_members']:
                path = self.prefix + member['relative_path']
                if not any(row['path'] == path for row in self.rows):
                    self.rows.append(dict(self.row, id=str(uuid.uuid4()), path=path, bytes=member['bytes'],
                                          sha256=member['sha256'], media_type=member['media_type']))
            return None
        if name == 'worker_asset_inventory_finish': return {'complete': not any(args['p_discrepancies'].values())}
        raise AssertionError(name)

    def blob(self, path, size, retain=False):
        self.calls.append(('blob', path, size))
        data = self.objects[path]
        self.downloaded += len(data)
        if len(data) > size: raise ASSETS.InventoryError('response_limit')
        return data if retain else (len(data), hashlib.sha256(data).hexdigest())


class AssetInventoryTests(unittest.TestCase):
    def run_scan(self, client): return ASSETS.reconcile(client, str(uuid.uuid4()), 10 * ASSETS.MiB)

    def test_complete_double_snapshot_verifies_then_imports_exact_members(self):
        client = Fixture()
        result = self.run_scan(client)
        self.assertTrue(result['recorded'])
        self.assertTrue(result['report']['complete'])
        self.assertEqual(client.snapshots, 2)
        self.assertEqual(result['report']['object_count'], 2)
        self.assertEqual(result['report']['byte_count'], len(client.data) + len(client.manifest))
        self.assertEqual(client.downloaded, len(client.data) + len(client.manifest))
        names = [call[0] for call in client.calls]
        self.assertLess(names.index('blob'), names.index('worker_asset_inventory_manifest'))
        self.assertEqual(result['report_sha256'], hashlib.sha256(ASSETS.canonical(result['report'])).hexdigest())
        encoded = json.dumps(result)
        for private in (client.manifest_path, client.member_path, client.row['owner_id']): self.assertNotIn(private, encoded)

    def test_manifest_is_not_authority_until_its_trusted_digest_matches(self):
        client = Fixture()
        client.objects[client.manifest_path] = client.manifest.replace(b'index.html', b'other.html')
        result = self.run_scan(client)
        self.assertFalse(result['report']['complete'])
        self.assertGreater(result['report']['discrepancies']['mismatched'], 0)
        self.assertFalse(any(call[0] == 'worker_asset_inventory_manifest' for call in client.calls))
        self.assertFalse(any(call[0] == 'blob' and call[1] == client.member_path for call in client.calls))

    def test_changed_same_size_member_or_storage_snapshot_never_certifies(self):
        client = Fixture(); client.objects[client.member_path] = b'x' * len(client.data)
        result = self.run_scan(client)
        self.assertFalse(result['report']['complete'])
        self.assertFalse(any(call[0] == 'worker_asset_inventory_manifest' for call in client.calls))
        client = Fixture(); client.mutate_on_second = True
        result = self.run_scan(client)
        self.assertFalse(result['report']['complete'])
        self.assertIn('storage_snapshot_changed', [r.get('code') for r in result['report']['issues']])

    def test_unknown_files_and_missing_pending_objects_remain_unresolved(self):
        client = Fixture(); client.objects['private/untrusted-owner/temporary'] = b'unknown'
        result = self.run_scan(client)
        self.assertEqual(result['report']['discrepancies']['untracked'], 1)
        self.assertNotIn('untrusted-owner', json.dumps(result))
        client = Fixture(); client.row['state'] = 'pending'
        result = self.run_scan(client)
        self.assertFalse(result['report']['complete'])
        self.assertEqual(result['report']['discrepancies']['incomplete'], 1)
        self.assertFalse(any(call[0] == 'blob' for call in client.calls))
        client = Fixture(); del client.objects[client.manifest_path]
        self.assertEqual(self.run_scan(client)['report']['discrepancies']['missing_verified'], 1)

    def test_failed_membership_import_and_inconsistent_ownership_fail_closed(self):
        client = Fixture(); client.reject_import = True
        self.assertFalse(self.run_scan(client)['report']['complete'])
        client = Fixture(); client.row['owner_id'] = None
        result = self.run_scan(client)
        self.assertEqual(result['report']['discrepancies']['unowned'], 1)
        self.assertFalse(any(call[0] == 'blob' for call in client.calls))

    def test_nested_folder_and_byte_limits_are_explicit_incomplete_scans(self):
        class Fanout:
            def listing(self, prefix, offset):
                return [{'name': f'folder{n:03}', 'id': None} for n in range(5)] if prefix == '' else []
        with mock.patch.object(ASSETS, 'MAX_OBJECTS', 4):
            with self.assertRaisesRegex(ASSETS.InventoryError, 'listing_incomplete'): ASSETS.bucket_snapshot(Fanout(), 100)
        with self.assertRaisesRegex(ASSETS.InventoryError, 'listing_incomplete'): ASSETS.bucket_snapshot(Fixture(), 1)
        class Repeats:
            def listing(self, prefix, offset):
                return [{'name': f'object{n:03}', 'id': str(n), 'metadata': {'size': 1}} for n in range(500)]
        with self.assertRaisesRegex(ASSETS.InventoryError, 'unstable_listing'): ASSETS.bucket_snapshot(Repeats(), 1000)

    def test_reader_members_reject_traversal_duplicates_and_oversize(self):
        client = Fixture()
        for members in ([dict(client.member, path='../outside')], [client.member, client.member],
                        [dict(client.member, bytes=17 * ASSETS.MiB)], [dict(client.member, sha256=None)]):
            with self.subTest(members=members):
                body = ASSETS.canonical({'format': 'reader-bundle-v1', 'members': members})
                digest = hashlib.sha256(body).hexdigest()
                row = dict(client.row, path='reader/' + digest + '/manifest.json', sha256=digest)
                with self.assertRaises(ASSETS.InventoryError): ASSETS.manifest_members(row, body)

    def test_request_scoping_budget_and_redirect_refusal_before_read(self):
        client = ASSETS.Client('a' * 20, 'fixture-secret', 10)
        with mock.patch.object(client.opener, 'open') as opening:
            with self.assertRaisesRegex(ASSETS.InventoryError, 'scope_refused'):
                client.request('https://other.invalid/private')
            with self.assertRaisesRegex(ASSETS.InventoryError, 'download_budget_exhausted'):
                client.blob('originals/fixture.pdf', 11)
            opening.assert_not_called()
        with self.assertRaisesRegex(ASSETS.InventoryError, 'redirect_refused'): ASSETS.NoRedirect().redirect_request()

    def test_body_probes_and_metadata_have_separate_aggregate_limits(self):
        client = ASSETS.Client('a' * 20, 'fixture-secret', 10, 10 + ASSETS.FINALIZATION_RESERVE)
        with mock.patch.object(client.opener, 'open') as opening:
            # Ten bytes plus the required overrun probe cannot fit ten bytes.
            with self.assertRaisesRegex(ASSETS.InventoryError, 'download_budget_exhausted'):
                client.blob('reader/fixture/index.html', 10)
            opening.assert_not_called()
        class Reply(io.BytesIO):
            headers = {}
        with mock.patch.object(client.opener, 'open', return_value=Reply(b'0123456789')):
            with self.assertRaisesRegex(ASSETS.InventoryError, 'response_limit'):
                client.request('/storage/v1/object/list/paper-assets', {})
        self.assertEqual(client.metadata_downloaded, 10)
        self.assertEqual(client.downloaded, 0)
        with mock.patch.object(client.opener, 'open') as opening:
            with self.assertRaisesRegex(ASSETS.InventoryError, 'metadata_budget_exhausted'):
                client.request('/storage/v1/object/list/paper-assets', {})
            opening.assert_not_called()
        # Metadata exhaustion leaves room for the bounded failure certificate.
        with mock.patch.object(client.opener, 'open', return_value=Reply(b'{}')):
            self.assertEqual(client.rpc('worker_asset_inventory_finish', {}), {})

    def test_report_is_private_and_file_and_directory_are_synced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'proof.json'
            with mock.patch.object(ASSETS.os, 'fsync', wraps=os.fsync) as sync:
                ASSETS.write_report(path, {'fixture': True})
                self.assertEqual(sync.call_count, 2)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): ASSETS.write_report(path, {'fixture': False})

    def test_failed_record_keeps_its_active_scan_and_immutable_report(self):
        client = Fixture(); original = client.rpc
        def rpc(name, args):
            if name == 'worker_asset_inventory_finish': raise ASSETS.InventoryError('http_503')
            return original(name, args)
        client.rpc = rpc
        result = self.run_scan(client)
        self.assertFalse(result['recorded'])
        self.assertTrue(result['scan_may_remain_active'])
        self.assertEqual(result['report_sha256'], hashlib.sha256(ASSETS.canonical(result['report'])).hexdigest())

    def test_proof_is_saved_before_certification_and_failed_save_never_certifies(self):
        client = Fixture()
        saved = []
        def save(proof):
            self.assertFalse(any(call[0] == 'worker_asset_inventory_finish' for call in client.calls))
            saved.append(proof)
        result = ASSETS.reconcile(client, str(uuid.uuid4()), 10 * ASSETS.MiB, save)
        self.assertTrue(result['recorded'])
        self.assertEqual(saved, [{'report': result['report'], 'report_sha256': result['report_sha256']}])
        client = Fixture()
        def failed(_): raise OSError('fixture-disk-full')
        result = ASSETS.reconcile(client, str(uuid.uuid4()), 10 * ASSETS.MiB, failed)
        self.assertFalse(result['recorded'])
        self.assertTrue(result['scan_may_remain_active'])
        self.assertFalse(any(call[0] == 'worker_asset_inventory_finish' for call in client.calls))


if __name__ == '__main__': unittest.main()
