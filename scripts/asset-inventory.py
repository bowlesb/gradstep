#!/usr/bin/env python3
"""Whole-bucket paper-assets reconciliation for migration 035 (docs/architecture/ASSET_SPENDING.md).

  python3 scripts/asset-inventory.py staging              # plan: counts and discrepancies, no writes
  python3 scripts/asset-inventory.py staging --apply      # begin scan, register manifest members, finish
  python3 scripts/asset-inventory.py staging --apply --enforce   # also enable enforcement (legacy delivery)

Requires a drained pipeline (pipeline-ops.py disable; no claims, no unfinished writes). Compares
paths and byte sizes with Storage's own metadata; it does not re-hash object bytes. Untracked or
missing objects are reported, never deleted or invented. The report is saved under
.artifacts/asset-inventory/ and its SHA-256 is recorded with the scan.
"""
import argparse, hashlib, json, mimetypes, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUCKET = 'paper-assets'
# Migration 039 widens the reconciliation to the private upload bucket (inventory scope 2);
# migration 046 adds podcast audio (scope 3). Podcast objects are tracked directly (no manifest members).
BUCKETS = ('paper-assets', 'paper-uploads', 'podcast-assets')


def env_values():
    values = {}
    for line in (ROOT / '.env.staging').read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


ENV = env_values()
PROJECT = json.loads((ROOT / 'infra/account.json').read_text())['projects']['staging']['id']
assert ENV['SUPABASE_PROJECT_REF'] == PROJECT
KEY = ENV.get('SUPABASE_SECRET_KEY') or ENV['SUPABASE_SERVICE_ROLE_KEY']
BASE = ENV['SUPABASE_URL'].rstrip('/')


def request(url, body=None, method=None, headers=None, raw=False):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method or ('POST' if body is not None else 'GET'),
                                 headers={'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            payload = response.read()
            return payload if raw else (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as error:
        detail = error.read(400).decode(errors='replace')
        raise SystemExit(f'HTTP {error.code} {urllib.parse.urlsplit(url).path}: {detail}') from None


def rpc(name, params):
    return request(f'{BASE}/rest/v1/rpc/{name}', params)


def sql(query):
    token = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()
    req = urllib.request.Request(f'https://api.supabase.com/v1/projects/{PROJECT}/database/query',
        data=json.dumps({'query': 'begin transaction read only; ' + query + '; commit;', 'read_only': False}).encode(),
        method='POST', headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'User-Agent': 'gradstep-ops'})
    with urllib.request.urlopen(req, timeout=120) as response:
        return json.loads(response.read())


def storage_objects():
    names = ','.join(f"'{b}'" for b in BUCKETS)
    rows = sql(f"select bucket_id, name, (metadata->>'size')::bigint size, metadata->>'mimetype' mimetype from storage.objects where bucket_id in ({names})")
    return {row['bucket_id'] + '/' + row['name']: row for row in rows}


def tracked(scan_id):
    objects, after = [], None
    while True:
        page = rpc('worker_asset_inventory_page', {'p_scan_id': scan_id, 'p_after': after, 'p_limit': 500})
        objects += page['objects']
        if not page['has_more']:
            return objects
        after = page['next_after']


def tracked_now():
    names = ','.join(f"'{b}'" for b in BUCKETS)
    return sql(f"select o.id,o.bucket,o.path,o.state,o.byte_count bytes,o.media_type from app_private.stored_objects o "
               f"where o.bucket in ({names}) and o.state<>'deleted'")


def manifest_members(path, physical):
    manifest = json.loads(request(f'{BASE}/storage/v1/object/{BUCKET}/{urllib.parse.quote(path)}', raw=True))
    members = manifest.get('members')
    entries = members.items() if isinstance(members, dict) else ((m['path'], m) for m in members)
    folder = BUCKET + '/' + path.rsplit('/', 1)[0] + '/'
    result = []
    for relative, member in entries:
        stored = physical.get(folder + relative, {})
        media = member.get('media_type') or stored.get('mimetype') or mimetypes.guess_type(relative)[0] or 'application/octet-stream'
        result.append({'relative_path': relative, 'sha256': member['sha256'], 'bytes': int(member['bytes']), 'media_type': media})
    return result


def discrepancies(physical, objects):
    by_path = {o.get('bucket', BUCKET) + '/' + o['path']: o for o in objects}
    report = {'untracked': sorted(p for p in physical if p not in by_path),
              'missing_verified': sorted(p for p, o in by_path.items() if o['state'] == 'verified' and p not in physical),
              'mismatched': sorted(p for p, o in by_path.items() if p in physical and int(o['bytes']) != int(physical[p]['size'] or -1)),
              'incomplete': sorted(p for p, o in by_path.items() if o['state'] not in ('verified',)),
              'unowned': []}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('environment', choices=['staging'])
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--enforce', action='store_true')
    args = parser.parse_args()
    physical = storage_objects()
    if not args.apply:
        objects = tracked_now()
        manifests = [o['path'] for o in objects if o['bucket'] == BUCKET and o['path'].endswith('manifest.json') and o['state'] == 'verified']
        planned = {o['bucket'] + '/' + o['path'] for o in objects}
        for path in manifests:
            folder = BUCKET + '/' + path.rsplit('/', 1)[0] + '/'
            planned |= {folder + m['relative_path'] for m in manifest_members(path, physical)}
        missing = sorted(p for p in physical if p not in planned)
        print(json.dumps({'storage_objects': len(physical), 'tracked': len(objects), 'manifests': len(manifests),
                          'tracked_after_manifests': len(planned), 'untracked_after_manifests': len(missing),
                          'untracked_examples': missing[:10]}, indent=1))
        return
    scan_id = str(uuid.uuid4())
    print(json.dumps(rpc('worker_asset_inventory_begin', {'p_scan_id': scan_id})))
    objects = tracked(scan_id)
    for manifest in [o for o in objects if o.get('bucket', BUCKET) == BUCKET and o['path'].endswith('manifest.json') and o['state'] == 'verified']:
        rpc('worker_asset_inventory_manifest', {'p_scan_id': scan_id, 'p_manifest_id': manifest['id'],
                                                 'p_members': manifest_members(manifest['path'], physical)})
    objects = tracked(scan_id)
    found = discrepancies(physical, objects)
    report = {'scan_id': scan_id, 'buckets': list(BUCKETS), 'objects': len(objects), 'bytes': sum(int(o['bytes']) for o in objects),
              'storage_objects': len(physical), 'discrepancies': found, 'method': 'paths and Storage byte sizes; bytes not re-hashed'}
    out = ROOT / '.artifacts/asset-inventory'; out.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(report, indent=1, sort_keys=True).encode()
    (out / f'{scan_id}.json').write_bytes(raw)
    counts = {k: len(v) for k, v in found.items()}
    result = rpc('worker_asset_inventory_finish', {'p_scan_id': scan_id, 'p_object_count': report['objects'], 'p_byte_count': report['bytes'],
                                                    'p_discrepancies': counts, 'p_report_sha256': '\\x' + hashlib.sha256(raw).hexdigest()})
    print(json.dumps({'scan': result, 'discrepancies': counts, 'report': str(out / f'{scan_id}.json')}))
    if args.enforce:
        if not result.get('complete'):
            sys.exit('Inventory has discrepancies; enforcement not enabled.')
        status = rpc('worker_asset_enforcement', {'p_enabled': True, 'p_delivery_mode': 'legacy'})
        print(json.dumps({'enforced': status['storage_policy'].get('enforced'), 'delivery': status['delivery_policy'].get('mode')}))


if __name__ == '__main__':
    main()
