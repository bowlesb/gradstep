"""Capture an immutable fixture bundle; never installs or starts a service."""
import hashlib
import json
import os
from pathlib import Path
import ssl
import sys

GATEWAY_FILES = ('protocol.py', 'transport.py', 'child_contract.py', 'identity.py',
                 'runtime_identity.py', 'child.py', 'paused_child.py', 'journal.py')
LOCAL_FILES = {'bootstrap.py': 'bootstrap.py', 'common.py': 'common.py',
               'controller.py': 'linux_controller.py', 'lifecycle.py': 'linux_lifecycle.py',
               'package.py': 'package.py',
               'attempt.service.in': 'attempt.service.in', 'attempt.slice.in': 'attempt.slice.in',
               'fixture-vm.yaml': 'fixture-vm.yaml'}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def runtime_sha():
    digest = hashlib.sha256()
    total = 0
    with open(sys.executable, 'rb') as stream:
        for raw in iter(lambda: stream.read(65536), b''):
            total += len(raw)
            if total > 268_435_456:
                raise ValueError('runtime_limit')
            digest.update(raw)
    return digest.hexdigest()


def build(output):
    source = Path(__file__).resolve().parent
    # Capture every input before generating output. No compiler or source import
    # runs from the mutable parent checkout during action execution.
    captured = {name: (source.parent / name).read_bytes() for name in GATEWAY_FILES}
    captured.update({target: (source / name).read_bytes() for name, target in LOCAL_FILES.items()})
    if not all(0 < len(raw) <= 131_072 for raw in captured.values()):
        raise ValueError('source_limit')
    manifest = {'schema_version': 1, 'mode': 'linux_loopback_lifecycle_fixture',
                'files': {name: sha(raw) for name, raw in captured.items()},
                'bootstrap_sha256': sha(captured['bootstrap.py']),
                'python_sha256': runtime_sha(), 'python_version': sys.version,
                'tls_version': ssl.OPENSSL_VERSION, 'source_network_enabled': False,
                'hosted_admitted': False, 'source_bytes': sum(map(len, captured.values()))}
    output = Path(output)
    output.mkdir(mode=0o755)
    for name, raw in {**captured, 'bundle.json': canonical(manifest)}.items():
        with (output / name).open('xb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        (output / name).chmod(0o444)
    fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    output.chmod(0o555)
    return manifest


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: package.py NEW_OUTPUT_DIRECTORY')
    print(json.dumps({'bundle_sha256': sha(canonical(build(sys.argv[1]))), 'hosted_admitted': False}))
