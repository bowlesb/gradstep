#!/usr/bin/env python3
"""Inspect paper inventory; --apply performs a quiesced, hash-verified reconciliation.

Reads SCIENCE_READER_SERVICE_ROLE_KEY from the environment. The project is fixed
by infra/account.json. Never deletes, enables enforcement, pauses workers, or
prints private object paths. An applied scan reads existing Storage bytes and
therefore incurs ordinary transfer usage; review the byte ceiling before use.
"""
import argparse
from collections import deque
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
# Inventory scope 3 (migration 048) adds private podcast audio to the two paper buckets.
BUCKETS = ('paper-assets', 'paper-uploads', 'podcast-assets')
MAX_OBJECTS = 50000
MAX_JSON = 2 * 1024 * 1024
MAX_METADATA = 128 * 1024 * 1024
FINALIZATION_RESERVE = 65536
MiB = 1024 * 1024
SHA = re.compile(r'^[0-9a-f]{64}$')
MEMBER = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,239}$')
MANIFEST = re.compile(r'^(raw|reader)/([0-9a-f]{64})/manifest\.json$')
KINDS = ('incomplete', 'mismatched', 'missing_verified', 'unowned', 'untracked')
RAW_MEMBERS = {'standalone.mmd': (8 * MiB, 'text/plain'), 'output.mmd.zip': (32 * MiB, 'application/zip'),
               'lines.json': (16 * MiB, 'application/json')}


class InventoryError(Exception):
    """Only constant safe error codes; response bodies and paths never escape."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def integer(value, maximum, minimum=0):
    if type(value) is not int or not minimum <= value <= maximum:
        raise InventoryError('invalid_inventory_number')
    return value


def member_path(value):
    if not isinstance(value, str) or not MEMBER.fullmatch(value) or any(p in ('', '.', '..') for p in value.split('/')):
        raise InventoryError('invalid_manifest_member')
    return value


def digest(value):
    if not isinstance(value, str) or not SHA.fullmatch(value): raise InventoryError('invalid_inventory_digest')
    return value


def media_type(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 120: raise InventoryError('invalid_media_type')
    value = value.split(';')[0].strip().lower()
    if not re.fullmatch(r'[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+', value): raise InventoryError('invalid_media_type')
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): raise InventoryError('redirect_refused')


class Client:
    def __init__(self, project, key, max_download_bytes, max_metadata_bytes=MAX_METADATA):
        if not re.fullmatch('[a-z]{20}', project) or not key: raise InventoryError('invalid_project_or_credentials')
        self.origin = f'https://{project}.supabase.co'
        self.key, self.maximum, self.downloaded = key, max_download_bytes, 0
        self.metadata_maximum, self.metadata_downloaded = max_metadata_bytes, 0
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, path, payload=None, maximum=MAX_JSON, storage=False, retain=True):
        # All paths are constructed here; no manifest or redirect can choose a host.
        if not path.startswith(('/rest/v1/rpc/worker_asset_', '/storage/v1/object/list/paper-assets',
                                '/storage/v1/object/authenticated/paper-assets/', '/storage/v1/object/list/paper-uploads',
                                '/storage/v1/object/authenticated/paper-uploads/', '/storage/v1/object/list/podcast-assets',
                                '/storage/v1/object/authenticated/podcast-assets/')):
            raise InventoryError('request_scope_refused')
        headers = {'Authorization': 'Bearer ' + self.key, 'apikey': self.key, 'Accept-Encoding': 'identity'}
        body = None if payload is None else canonical(payload)
        if body is not None: headers['Content-Type'] = 'application/json'
        if storage:
            # An unknown-length response needs a one-byte overrun probe. Admit
            # that byte too; never cross the aggregate ceiling to discover it.
            if self.downloaded + maximum + 1 > self.maximum: raise InventoryError('download_budget_exhausted')
        else:
            reserve = 0 if path == '/rest/v1/rpc/worker_asset_inventory_finish' else FINALIZATION_RESERVE
            remaining = self.metadata_maximum - self.metadata_downloaded - reserve
            if remaining < 2: raise InventoryError('metadata_budget_exhausted')
            maximum = min(maximum, remaining - 1)
        request = urllib.request.Request(self.origin + path, data=body, headers=headers)
        try:
            with self.opener.open(request, timeout=60) as response:
                declared = response.headers.get('Content-Length')
                if declared is not None and (not declared.isdigit() or int(declared) > maximum):
                    raise InventoryError('response_limit')
                chunks, size, hasher = [], 0, hashlib.sha256()
                while chunk := response.read(min(65536, maximum - size + 1)):
                    size += len(chunk)
                    if storage: self.downloaded += len(chunk)
                    else: self.metadata_downloaded += len(chunk)
                    if size > maximum: raise InventoryError('response_limit')
                    hasher.update(chunk)
                    if retain: chunks.append(chunk)
                return b''.join(chunks) if retain else (size, hasher.hexdigest())
        except urllib.error.HTTPError as error: raise InventoryError(f'http_{error.code}') from None
        except (urllib.error.URLError, TimeoutError, ValueError, OSError): raise InventoryError('request_failed') from None

    def json(self, path, payload):
        try: return json.loads(self.request(path, payload))
        except (ValueError, TypeError): raise InventoryError('invalid_json_response') from None

    def rpc(self, name, payload): return self.json('/rest/v1/rpc/' + name, payload)

    def listing(self, prefix, offset, bucket='paper-assets'):
        if bucket not in BUCKETS: raise InventoryError('invalid_inventory_bucket')
        return self.json('/storage/v1/object/list/' + bucket,
                         {'prefix': prefix, 'limit': 500, 'offset': offset, 'sortBy': {'column': 'name', 'order': 'asc'}})

    def blob(self, path, size, retain=False, bucket='paper-assets'):
        if bucket not in BUCKETS: raise InventoryError('invalid_inventory_bucket')
        return self.request('/storage/v1/object/authenticated/' + bucket + '/' + urllib.parse.quote(path, safe='/'),
                            maximum=size, storage=True, retain=retain)


def bucket_snapshot(client, max_bytes, bucket='paper-assets'):
    """A short final page is required in every folder, including the root."""
    pending, visited, objects, calls, total = deque(['']), set(), {}, 0, 0
    while pending:
        prefix = pending.popleft()
        if prefix in visited or len(visited) >= MAX_OBJECTS or prefix.count('/') > 16:
            raise InventoryError('listing_incomplete')
        visited.add(prefix)
        offset, last_name = 0, None
        while True:
            calls += 1
            if calls > 100000: raise InventoryError('listing_incomplete')
            rows = client.listing(prefix, offset, bucket=bucket)
            if not isinstance(rows, list) or len(rows) > 500: raise InventoryError('invalid_listing')
            for row in rows:
                if not isinstance(row, dict): raise InventoryError('invalid_listing')
                name = row.get('name')
                if not isinstance(name, str) or not name or '/' in name or name in ('.', '..') or len(name) > 1024:
                    raise InventoryError('invalid_listing')
                if last_name is not None and name <= last_name: raise InventoryError('unstable_listing')
                last_name = name
                path = prefix + '/' + name if prefix else name
                if row.get('id') is None:
                    pending.append(path)
                    if len(pending) + len(visited) > MAX_OBJECTS: raise InventoryError('listing_incomplete')
                    continue
                metadata = row.get('metadata')
                if not isinstance(metadata, dict): raise InventoryError('invalid_listing')
                size = integer(metadata.get('size'), 64 * MiB, 1)
                total += size
                if len(objects) >= MAX_OBJECTS or total > max_bytes: raise InventoryError('listing_incomplete')
                # Compare the complete provider metadata plus id/timestamps. No
                # response field becomes an ownership or content-hash authority.
                objects[path] = {'id': row['id'], 'bytes': size, 'created_at': row.get('created_at'),
                                 'updated_at': row.get('updated_at'), 'metadata': metadata}
            if len(rows) < 500: break
            offset += len(rows)
    return objects


def inventory(client, scan):
    cursor, records, ids = None, {}, set()
    for _ in range(MAX_OBJECTS // 500 + 1):
        result = client.rpc('worker_asset_inventory_page', {'p_scan_id': scan, 'p_after': cursor, 'p_limit': 500})
        if not isinstance(result, dict) or not isinstance(result.get('objects'), list): raise InventoryError('invalid_inventory_page')
        rows = result['objects']
        if len(rows) > 500: raise InventoryError('invalid_inventory_page')
        for row in rows:
            if not isinstance(row, dict): raise InventoryError('invalid_inventory_page')
            bucket = row.setdefault('bucket', 'paper-assets')
            if bucket not in BUCKETS: raise InventoryError('invalid_inventory_bucket')
            key = bucket + '/' + str(row.get('path'))
            if row.get('id') in ids or key in records: raise InventoryError('duplicate_inventory')
            try:
                uuid.UUID(row['id'])
                if bucket == 'paper-assets': uuid.UUID(row['document_id'])
                elif bucket == 'podcast-assets':
                    # 048: shared audio carries its source document; private audio carries only its owner.
                    if row.get('document_id') is not None: uuid.UUID(row['document_id'])
                elif row.get('document_id') is not None: raise ValueError('staging_document')
            except (ValueError, TypeError, KeyError): raise InventoryError('invalid_inventory_identity') from None
            if not isinstance(row.get('path'), str) or len(row['path']) > 1024: raise InventoryError('invalid_inventory_path')
            digest(row.get('sha256'))
            if bucket == 'paper-assets' or (bucket == 'podcast-assets' and row.get('document_id') is not None): digest(row.get('document_sha256'))
            integer(row.get('bytes'), 64 * MiB, 1); media_type(row.get('media_type'))
            if row.get('state') not in ('pending', 'verified', 'deleting'): raise InventoryError('invalid_inventory_state')
            if row.get('owner_id') is not None:
                try: uuid.UUID(row['owner_id'])
                except (ValueError, TypeError): raise InventoryError('invalid_inventory_owner') from None
            ids.add(row['id']); records[key] = row
        if len(records) > MAX_OBJECTS: raise InventoryError('inventory_incomplete')
        if result.get('has_more') is False: return records
        next_cursor = result.get('next_after')
        if result.get('has_more') is not True or len(rows) != 500 or next_cursor != rows[-1]['id'] or next_cursor == cursor:
            raise InventoryError('invalid_inventory_page')
        cursor = next_cursor
    raise InventoryError('inventory_incomplete')


def manifest_members(row, body):
    matched = MANIFEST.fullmatch(row['path'])
    if not matched or matched[2] != row['sha256']: raise InventoryError('manifest_identity_mismatch')
    try: value = json.loads(body)
    except (ValueError, TypeError): raise InventoryError('invalid_manifest') from None
    if not isinstance(value, dict): raise InventoryError('invalid_manifest')
    members = value.get('members')
    if matched[1] == 'raw':
        if value.get('format') != 'science-reader-mathpix-raw-v1' or value.get('document_sha256') != row['document_sha256']:
            raise InventoryError('invalid_raw_identity')
        if not isinstance(members, dict) or set(members) != set(RAW_MEMBERS): raise InventoryError('invalid_raw_members')
        if any(not isinstance(member, dict) for member in members.values()): raise InventoryError('invalid_raw_members')
        members = [dict(member, path=name, media_type=RAW_MEMBERS[name][1]) for name, member in members.items()]
    elif value.get('format') != 'reader-bundle-v1' or not isinstance(members, list) or not 1 <= len(members) <= 512:
        raise InventoryError('invalid_reader_manifest')
    result, paths = [], set()
    for member in members:
        if not isinstance(member, dict): raise InventoryError('invalid_manifest_member')
        path = member_path(member.get('path'))
        if path == 'manifest.json' or path in paths: raise InventoryError('duplicate_manifest_member')
        paths.add(path)
        limit = RAW_MEMBERS[path][0] if matched[1] == 'raw' else 16 * MiB
        result.append({'relative_path': path, 'bytes': integer(member.get('bytes'), limit, 1),
                       'sha256': digest(member.get('sha256')), 'media_type': media_type(member.get('media_type'))})
    if sum(member['bytes'] for member in result) > (56 if matched[1] == 'raw' else 32) * MiB:
        raise InventoryError('manifest_byte_limit')
    return result


def reconcile(client, scan, max_bytes, save_proof=None):
    """Only manifests already bound to an owned, verified DB identity may add rows."""
    report = {'format': 1, 'scan_id': scan, 'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(),
              'complete': False, 'object_count': 0, 'byte_count': 0, 'discrepancies': dict.fromkeys(KINDS, 0),
              'issues': [], 'imported_manifests': 0, 'downloaded_bytes': 0, 'metadata_bytes_before_finalization': 0}
    begun = False
    def issue(kind, path=None, code=None):
        report['discrepancies'][kind] = min(MAX_OBJECTS, report['discrepancies'][kind] + 1)
        entry = {'kind': kind}
        if path is not None: entry['path_sha256'] = hashlib.sha256(path.encode()).hexdigest()
        if code is not None: entry['code'] = code
        if len(report['issues']) < 1000: report['issues'].append(entry)

    try:
        admission = client.rpc('worker_asset_inventory_begin', {'p_scan_id': scan}); begun = True
        buckets = admission.get('buckets', ['paper-assets'])
        scopes = {1: ['paper-assets'], 2: ['paper-assets', 'paper-uploads'], 3: ['paper-assets', 'paper-uploads', 'podcast-assets']}
        if buckets != scopes.get(admission.get('scope', 1)): raise InventoryError('invalid_inventory_scope')
        report['scope'] = admission.get('scope', 1)
        def snapshot():
            complete, size = {}, 0
            for bucket in buckets:
                rows = bucket_snapshot(client, max_bytes - size, bucket=bucket)
                complete.update({bucket + '/' + path: value for path,value in rows.items()})
                size += sum(row['bytes'] for row in rows.values())
                if len(complete) > MAX_OBJECTS or size > max_bytes: raise InventoryError('listing_incomplete')
            return complete
        first = snapshot()
        report['object_count'], report['byte_count'] = len(first), sum(o['bytes'] for o in first.values())
        before = inventory(client, scan)
        verified = {}
        # Parse every tracked manifest first; that identifies legitimate old
        # members without inferring a private owner from an uploaded pathname.
        ordered = sorted(before.values(), key=lambda row: (not bool(MANIFEST.fullmatch(row['path'])), row['path']))
        for row in ordered:
            path, bucket = row['path'], row['bucket']
            key = bucket + '/' + path
            if bucket not in buckets: raise InventoryError('inventory_scope_mismatch')
            private_owned = row.get('scope') is None and row.get('owner_id') is not None and row.get('document_id') is None
            if bucket == 'paper-assets':
                owned = row.get('scope') in ('shared_catalog','owner_private') and (row['scope']=='owner_private') == (row.get('owner_id') is not None)
            elif bucket == 'podcast-assets':
                owned = private_owned or (row.get('scope') == 'shared_catalog' and row.get('owner_id') is None and row.get('document_id') is not None)
            else:
                owned = private_owned
            if not owned:
                issue('unowned', path); continue
            if row['state'] != 'verified': issue('incomplete', path, 'unresolved_object'); continue
            if key not in first: issue('missing_verified', path); continue
            if first[key]['bytes'] != row['bytes']: issue('mismatched', path, 'size_mismatch'); continue
            try:
                is_manifest = MANIFEST.fullmatch(path) if bucket=='paper-assets' else None
                if is_manifest and row['bytes'] > 262144: raise InventoryError('manifest_byte_limit')
                body = None
                if key in verified:
                    actual = verified[key]
                elif is_manifest:
                    body = client.blob(path, row['bytes'], retain=True, bucket=bucket)
                    actual = (len(body), hashlib.sha256(body).hexdigest())
                else: actual = client.blob(path, row['bytes'], bucket=bucket)
                if actual != (row['bytes'], row['sha256']): raise InventoryError('content_mismatch')
                verified[key] = actual
                if is_manifest:
                    members = manifest_members(row, body)
                    prefix = path.removesuffix('manifest.json')
                    for member in members:
                        member_path = prefix + member['relative_path']
                        member_key = bucket + '/' + member_path
                        if member_key not in first or first[member_key]['bytes'] != member['bytes']:
                            raise InventoryError('manifest_member_missing_or_size')
                        actual = verified.get(member_key) or client.blob(member_path, member['bytes'], bucket=bucket)
                        if actual != (member['bytes'], member['sha256']): raise InventoryError('manifest_member_content')
                        verified[member_key] = actual
                    client.rpc('worker_asset_inventory_manifest', {'p_scan_id': scan, 'p_manifest_id': row['id'], 'p_members': members})
                    report['imported_manifests'] += 1
            except InventoryError as error:
                if str(error) == 'download_budget_exhausted': raise
                issue('mismatched', path, str(error))
        after = inventory(client, scan)
        # All new records must be exactly one of the hash-checked owned members;
        # concurrent identity changes are an incomplete snapshot, not repairable.
        for path, row in before.items():
            if after.get(path) != row: issue('incomplete', path, 'inventory_changed')
        for path, row in after.items():
            if path not in before and verified.get(path) != (row['bytes'], row['sha256']):
                issue('incomplete', path, 'unverified_inventory_change')
        for path in first.keys() - after.keys(): issue('untracked', path)
        second = snapshot()
        if second != first: issue('incomplete', code='storage_snapshot_changed')
    except InventoryError as error: issue('incomplete', code=str(error))
    except Exception: issue('incomplete', code='inventory_consistency_error')
    report['downloaded_bytes'] = client.downloaded
    report['metadata_bytes_before_finalization'] = getattr(client, 'metadata_downloaded', 0)
    report['complete'] = begun and not any(report['discrepancies'].values())
    # Hash of this exact proof payload is stored; finalization status is an
    # external wrapper so it cannot change the proof after it was committed.
    proof = hashlib.sha256(canonical(report)).hexdigest()
    if save_proof is not None:
        try: save_proof({'report': report, 'report_sha256': proof})
        except Exception:
            return {'report': report, 'report_sha256': proof, 'recorded': False,
                    'scan_may_remain_active': begun, 'proof_persistence_failed': True}
    recorded = False
    if begun:
        try:
            result = client.rpc('worker_asset_inventory_finish', {'p_scan_id': scan, 'p_object_count': report['object_count'],
                'p_byte_count': report['byte_count'], 'p_discrepancies': report['discrepancies'], 'p_report_sha256': '\\x' + proof})
            recorded = isinstance(result, dict) and result.get('complete') is report['complete']
        except InventoryError: pass
    return {'report': report, 'report_sha256': proof, 'recorded': recorded,
            'scan_may_remain_active': begun and not recorded}


def write_report(path, result):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Local diagnostics contain hashes and opaque IDs only, but still keep the
    # operational report private. Refuse symlink overwrite.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(canonical(result) + b'\n')
        output.flush()
        os.fsync(output.fileno())
    # A closed file can still live only in the directory cache after a crash.
    directory = os.open(path.parent, os.O_RDONLY)
    try: os.fsync(directory)
    finally: os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', default='staging')
    parser.add_argument('--apply', action='store_true', help='record a scan and verified manifest members; never enables enforcement')
    parser.add_argument('--scan-id', type=uuid.UUID, help='resume the exact active scan after an interrupted local process')
    parser.add_argument('--max-download-bytes', type=int, default=5 * 1024 ** 3)
    parser.add_argument('--max-metadata-bytes', type=int, default=MAX_METADATA)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        config = json.loads((ROOT / 'infra/account.json').read_text())
        project = config['projects'][args.environment]['id']
        integer(args.max_download_bytes, 64 * 1024 ** 3, 1)
        integer(args.max_metadata_bytes, 1024 ** 3, MAX_JSON + FINALIZATION_RESERVE)
        if args.output.exists(): raise InventoryError('report_already_exists')
        proof_file = args.output.with_name(args.output.name + '.proof.json')
        if args.apply and proof_file.exists(): raise InventoryError('report_already_exists')
        client = Client(project, os.environ.get('SCIENCE_READER_SERVICE_ROLE_KEY'), args.max_download_bytes, args.max_metadata_bytes)
        if args.apply:
            result = reconcile(client, str(args.scan_id or uuid.uuid4()), args.max_download_bytes,
                               save_proof=lambda proof: write_report(proof_file, proof))
        else:
            result = {'applied': False, 'status': client.rpc('worker_asset_spending_status', {}),
                      'proposed_download_ceiling_bytes': args.max_download_bytes,
                      'proposed_metadata_ceiling_bytes': args.max_metadata_bytes,
                      'requires': ['pipeline_disabled_and_drained', 'reviewed_storage_transfer_allowance', 'apply_flag']}
        write_report(args.output, result)
        ok = not args.apply or result['recorded'] and result['report']['complete']
        print(json.dumps({'saved': str(args.output), 'applied': args.apply, 'complete': bool(ok),
                          'scan_id': result.get('report', {}).get('scan_id')}))
        return 0 if ok else 1
    except Exception:
        print(json.dumps({'error': 'asset_reconciliation_failed'}))
        return 1


if __name__ == '__main__': raise SystemExit(main())
