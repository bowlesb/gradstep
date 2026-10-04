"""Small captured runtime identity/launch helpers shared by worker entrypoints."""
import hashlib
from pathlib import Path
import sys

from protocol import decode, digest, require


def executable_sha(path):
    executable = hashlib.sha256()
    size = 0
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            size += len(block)
            require(size <= 268_435_456, 'runtime_capacity')
            executable.update(block)
    return executable.hexdigest()


def command(root, entry):
    require(entry in ('child', 'integrate'), 'invalid_entry')
    # Every launch uses the exact captured loader bytes, even if this module
    # was edited between the caller's import and bundle capture.
    raw = (Path(root) / 'bootstrap.py').read_bytes()
    manifest = decode((Path(root) / 'bundle.json').read_bytes())
    require(len(raw) <= 16_384 and digest(raw) == manifest['bootstrap_sha256']
            and executable_sha(sys.executable) == manifest['python_sha256'], 'bootstrap_changed')
    return [sys.executable, '-I', '-S', '-B', '-c', raw.decode('utf8'), str(root), entry]
