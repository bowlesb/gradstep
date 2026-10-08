#!/usr/bin/env python3
"""Freeze synthetic SQL responses; does not connect to any database or service."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sql_output', type=Path, help='Unaligned psql output from test_library_upload_visibility.sql')
    parser.add_argument('--ingress-snapshot', required=True, type=Path, help='The exact pending039 ingress SQL used for this run')
    parser.add_argument('--visibility-fragment', type=Path, help='Optional historical fragment; omit for composed039')
    args = parser.parse_args()
    markers = {}
    for line in args.sql_output.read_text().splitlines():
        name, separator, value = line.partition(' ')
        if name in ('LEGACY_DECODER_FIXTURE', 'LEGACY_MIXED_FIXTURE'):
            if not separator or name in markers:
                raise ValueError('Duplicate or incomplete SQL fixture marker')
            markers[name] = json.loads(value)
    captured = markers['LEGACY_DECODER_FIXTURE']
    if set(captured) != {'baselines', 'changes'} or len(captured['baselines']) != 2 or len(captured['changes']) != 4:
        raise ValueError('Unexpected SQL capture shape')
    captured['changes'].append(markers['LEGACY_MIXED_FIXTURE'])
    encoded = (json.dumps(captured, indent=2) + '\n').encode()
    source = ROOT / 'tests/database/test_library_upload_visibility.sql'
    lineage = {
        'format': 1,
        'fixture': 'legacy-v3.json',
        'fixture_sha256': hashlib.sha256(encoded).hexdigest(),
        'sql_test': str(source.relative_to(ROOT)),
        'sql_test_sha256': sha(source),
        'ingress_snapshot_sha256': sha(args.ingress_snapshot),
        'sql_output_sha256': sha(args.sql_output),
        'scope': 'Synthetic localhost SQL responses; no production records, provider calls or codec transformations',
    }
    if args.visibility_fragment:
        lineage['visibility_fragment_sha256'] = sha(args.visibility_fragment)
    destination = Path(__file__).resolve().parent
    (destination / 'legacy-v3.json').write_bytes(encoded)
    (destination / 'lineage.json').write_text(json.dumps(lineage, indent=2) + '\n')
    print('Frozen two baselines and five delta pages:', lineage['fixture_sha256'])


if __name__ == '__main__':
    main()
