"""Validate a deployed/archived migration prefix without claiming pending files."""
import hashlib
from pathlib import Path
import re


def source_ledger(directory: Path) -> dict[str, str]:
    result = {}
    for path in sorted(directory.glob('*.sql')):
        version = path.name.split('_', 1)[0]
        if not re.fullmatch(r'[0-9]{12}', version) or '_' not in path.name:
            raise RuntimeError('Invalid migration filename')
        if version in result:
            raise RuntimeError('Duplicate migration version')
        result[version] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not result:
        raise RuntimeError('Migration source is empty')
    return result


def verify_applied_prefix(applied: dict[str, str], sources: dict[str, str]) -> None:
    # Newer source files are expected during a pre-migration backup or an older
    # checkpoint restore. An inserted earlier file, gap, or edited applied file
    # is drift, and must never be hidden by a simple subset/hash check.
    if not isinstance(applied, dict) or not applied:
        raise RuntimeError('Migration ledger is empty or malformed')
    if any(not isinstance(version, str) or not isinstance(digest, str)
           or not re.fullmatch(r'[0-9]{12}', version)
           or not re.fullmatch(r'[0-9a-f]{64}', digest)
           for version, digest in applied.items()):
        raise RuntimeError('Migration ledger is malformed')
    if sorted(applied) != sorted(sources)[:len(applied)]:
        raise RuntimeError('Migration ledger is not a prefix of local source')
    if any(sources.get(version) != digest for version, digest in applied.items()):
        raise RuntimeError('Applied migration differs from local source')
