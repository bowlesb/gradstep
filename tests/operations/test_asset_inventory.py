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

    def listing(self, prefix, offset, bucket='paper-assets'):
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

    def blob(self, path, size, retain=False, bucket='paper-assets'):
        self.calls.append(('blob', path, size))
        data = self.objects[path]
        self.downloaded += len(data)
        if len(data) > size: raise ASSETS.InventoryError('response_limit')
        return data if retain else (len(data), hashlib.sha256(data).hexdigest())


class TwoBuckets(Fixture):
    def __init__(self):
        super().__init__()
        self.row['bucket'] = 'paper-assets'
        self.staging = b'chunk fixture'
        self.staging_path = f"{self.row['owner_id']}/{uuid.uuid4()}/0/{uuid.uuid4()}.chunk"
        self.upload_objects = {self.staging_path: self.staging}
        self.rows.append({'id': str(uuid.uuid4()), 'bucket': 'paper-uploads', 'path': self.staging_path,
                          'document_id': None, 'document_sha256': None, 'scope': None, 'owner_id': self.row['owner_id'],
                          'state': 'verified', 'sha256': hashlib.sha256(self.staging).hexdigest(),
                          'bytes': len(self.staging), 'media_type': 'application/octet-stream'})
        self.upload_snapshots = 0

    def rpc(self, name, args):
        result = super().rpc(name, args)
        if name == 'worker_asset_inventory_begin': result.update(scope=2, buckets=['paper-assets', 'paper-uploads'])
        return result

    def listing(self, prefix, offset, bucket='paper-assets'):
        if bucket == 'paper-assets': return super().listing(prefix, offset, bucket)
        # Reuse the exact folder/paging fixture with isolated bucket contents.
        original, snapshots = self.objects, self.snapshots
        self.objects, self.snapshots = self.upload_objects, self.upload_snapshots
        try: return super().listing(prefix, offset, bucket)
        finally:
            self.upload_objects, self.upload_snapshots = self.objects, self.snapshots
            self.objects, self.snapshots = original, snapshots

    def blob(self, path, size, retain=False, bucket='paper-assets'):
        if bucket == 'paper-assets': return super().blob(path, size, retain, bucket)
        original = self.objects; self.objects = self.upload_objects
        try: return super().blob(path, size, retain, bucket)
        finally: self.objects = original


class ThreeBuckets(TwoBuckets):
    """Scope 3 (migration 048): shared and private podcast audio, tracked directly."""
    def __init__(self):
        super().__init__()
        self.audio, self.private_audio = b'm4a shared fixture', b'm4a private fixture'
        self.podcast_objects = {f"shared/{'c' * 64}/audio.m4a": self.audio, f"private/{self.row['owner_id']}/{'d' * 64}/audio.m4a": self.private_audio}
        self.rows.append({'id': str(uuid.uuid4()), 'bucket': 'podcast-assets', 'path': f"shared/{'c' * 64}/audio.m4a",
                          'document_id': str(uuid.uuid4()), 'document_sha256': 'b' * 64, 'scope': 'shared_catalog', 'owner_id': None,
                          'state': 'verified', 'sha256': hashlib.sha256(self.audio).hexdigest(), 'bytes': len(self.audio), 'media_type': 'audio/mp4'})
        self.rows.append({'id': str(uuid.uuid4()), 'bucket': 'podcast-assets', 'path': f"private/{self.row['owner_id']}/{'d' * 64}/audio.m4a",
                          'document_id': None, 'document_sha256': None, 'scope': None, 'owner_id': self.row['owner_id'],
                          'state': 'verified', 'sha256': hashlib.sha256(self.private_audio).hexdigest(), 'bytes': len(self.private_audio), 'media_type': 'audio/mp4'})
        self.podcast_snapshots = 0

    def rpc(self, name, args):
        result = super().rpc(name, args)
        if name == 'worker_asset_inventory_begin': result.update(scope=3, buckets=['paper-assets', 'paper-uploads', 'podcast-assets'])
        return result

    def listing(self, prefix, offset, bucket='paper-assets'):
        if bucket != 'podcast-assets': return super().listing(prefix, offset, bucket)
        original, snapshots = self.objects, self.snapshots
        self.objects, self.snapshots = self.podcast_objects, self.podcast_snapshots
        try: return Fixture.listing(self, prefix, offset, bucket)
        finally:
            self.podcast_objects, self.podcast_snapshots = self.objects, self.snapshots
            self.objects, self.snapshots = original, snapshots

    def blob(self, path, size, retain=False, bucket='paper-assets'):
        if bucket != 'podcast-assets': return super().blob(path, size, retain, bucket)
        original = self.objects; self.objects = self.podcast_objects
        try: return Fixture.blob(self, path, size, retain, bucket)
        finally: self.objects = original


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

    def test_two_bucket_scope_hashes_staging_and_checks_both_complete_snapshots(self):
        client = TwoBuckets()
        result = self.run_scan(client)
        self.assertTrue(result['recorded']); self.assertTrue(result['report']['complete'])
        self.assertEqual(result['report']['scope'], 2)
        self.assertEqual(result['report']['object_count'], 3)
        self.assertEqual((client.snapshots, client.upload_snapshots), (2, 2))
        self.assertEqual(client.downloaded, len(client.data) + len(client.manifest) + len(client.staging))
        self.assertNotIn(client.staging_path, json.dumps(result))

    def test_scope_three_hashes_shared_and_private_podcast_audio(self):
        client = ThreeBuckets()
        result = self.run_scan(client)
        self.assertTrue(result['recorded']); self.assertTrue(result['report']['complete'])
        self.assertEqual(result['report']['scope'], 3)
        self.assertEqual(result['report']['object_count'], 5)
        self.assertEqual(client.podcast_snapshots, 2)
        self.assertNotIn('audio.m4a', json.dumps(result))
        stray = ThreeBuckets(); stray.podcast_objects['shared/' + 'e' * 64 + '/audio.m4a'] = b'untracked'
        self.assertEqual(self.run_scan(stray)['report']['discrepancies']['untracked'], 1)
        mismatched = ThreeBuckets(); mismatched.scope_buckets = None
        mismatched.rpc = lambda name, args, inner=mismatched.rpc: (dict(inner(name, args), buckets=['paper-assets', 'paper-uploads'])
                                                                  if name == 'worker_asset_inventory_begin' else inner(name, args))
        refused = ASSETS.reconcile(mismatched, str(uuid.uuid4()), 10 * ASSETS.MiB)['report']
        self.assertFalse(refused['complete'], 'scope 3 with a missing podcast bucket is never certified')
        self.assertIn({'kind': 'incomplete', 'code': 'invalid_inventory_scope'}, refused['issues'])

    def test_staging_unknown_objects_and_ownerless_rows_cannot_be_backfilled(self):
        client = TwoBuckets(); client.upload_objects['unknown'] = b'unknown'
        self.assertEqual(self.run_scan(client)['report']['discrepancies']['untracked'], 1)
        client = TwoBuckets(); client.rows[-1]['owner_id'] = None
        result = self.run_scan(client)
        self.assertEqual(result['report']['discrepancies']['unowned'], 1)
        self.assertFalse(any(call[0] == 'blob' and call[1] == client.staging_path for call in client.calls))
        client = TwoBuckets(); client.rows[-1]['state'] = 'pending'
        self.assertFalse(self.run_scan(client)['report']['complete'])

    def test_same_path_in_different_buckets_never_shadows_inventory_or_ownership(self):
        client = TwoBuckets()
        client.upload_objects = {client.manifest_path: client.staging}
        client.rows[-1]['path'] = client.manifest_path
        result = self.run_scan(client)
        self.assertTrue(result['report']['complete'])
        self.assertEqual(result['report']['object_count'], 3)
        self.assertEqual(result['report']['imported_manifests'], 1)

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
            def listing(self, prefix, offset, bucket='paper-assets'):
                return [{'name': f'folder{n:03}', 'id': None} for n in range(5)] if prefix == '' else []
        with mock.patch.object(ASSETS, 'MAX_OBJECTS', 4):
            with self.assertRaisesRegex(ASSETS.InventoryError, 'listing_incomplete'): ASSETS.bucket_snapshot(Fanout(), 100)
        with self.assertRaisesRegex(ASSETS.InventoryError, 'listing_incomplete'): ASSETS.bucket_snapshot(Fixture(), 1)
        class Repeats:
            def listing(self, prefix, offset, bucket='paper-assets'):
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
