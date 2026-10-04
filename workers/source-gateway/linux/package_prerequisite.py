"""Capture only the prerequisite's finite source graph; never starts anything."""
import os
from pathlib import Path
import ssl
import sys

from package import canonical, runtime_sha, sha

GATEWAY_FILES = ('protocol.py', 'transport.py', 'child_contract.py', 'identity.py',
                 'runtime_identity.py', 'child.py', 'paused_child.py')
LOCAL_FILES = {'prerequisite_bootstrap.py': 'bootstrap.py', 'common.py': 'common.py',
               'uid_policy.py': 'uid_policy.py', 'prerequisite_launcher.py': 'linux_launcher.py',
               'prerequisite_source.py': 'linux_source.py', 'witness_slots.py': 'witness_slots.py',
               'package.py': 'package.py',
               'package_prerequisite.py': 'package_prerequisite.py',
               'prerequisite.service.in': 'prerequisite.service.in',
               'prerequisite.slice.in': 'prerequisite.slice.in'}


def build(output):
    source = Path(__file__).resolve().parent
    captured = {name: (source.parent / name).read_bytes() for name in GATEWAY_FILES}
    captured.update({target: (source / name).read_bytes() for name, target in LOCAL_FILES.items()})
    if not all(0 < len(raw) <= 131_072 for raw in captured.values()) or sum(map(len, captured.values())) > 262_144:
        raise ValueError('source_limit')
    manifest = {'schema_version': 1, 'mode': 'linux_uid_ingress_fixture',
                'files': {name: sha(raw) for name, raw in captured.items()},
                'bootstrap_sha256': sha(captured['bootstrap.py']), 'python_sha256': runtime_sha(),
                'python_version': sys.version, 'tls_version': ssl.OPENSSL_VERSION,
                'source_network_enabled': False, 'hosted_admitted': False,
                'supervisor_uid': 62401, 'source_uid': 62402,
                'source_bytes': sum(map(len, captured.values()))}
    output = Path(output)
    output.mkdir(mode=0o755)
    for name, raw in {**captured, 'bundle.json': canonical(manifest)}.items():
        with (output / name).open('xb') as stream:
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        (output / name).chmod(0o444)
    descriptor = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    output.chmod(0o555)
    return manifest
