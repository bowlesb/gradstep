"""Two-inode, no-overwrite witness publication. This module grants no SQL authority."""
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import stat

from common import require

MAX_OUTPUT = 1_572_864
MAX_BYTES = 4_194_304
MAX_NAMES = 32
RESERVED_BYTES = 4_153_344
RESERVED_NAMES = 30
FINAL = 'witness.json'
PENDING = '.witness.pending'
LOCK = 'publication.lock'


def reservation(source_bytes):
    require(type(source_bytes) is int and 0 < source_bytes <= 262_144, 'source_reservation_exceeded')
    return {'schema_version': 1, 'reserved_bytes': RESERVED_BYTES, 'maximum_bytes': MAX_BYTES,
            'reserved_names': RESERVED_NAMES, 'maximum_names': MAX_NAMES,
            'witness_slot_bytes': MAX_OUTPUT, 'witness_inode_count': 2,
            'captured_source_bytes': source_bytes, 'source_network_enabled': False}


def usage(directories, *, captured_source_bytes=0):
    """Count each name, but body/file bytes once per inode across trusted dirs."""
    require(type(captured_source_bytes) is int and 0 <= captured_source_bytes <= 262_144,
            'source_reservation_exceeded')
    count, inodes = 0, {}
    for path in directories:
        fd = _directory(path, None, private=False)
        try:
            with os.scandir(fd) as entries:
                for entry in entries:
                    count += 1
                    require(count <= MAX_NAMES, 'action_name_limit')
                    info = entry.stat(follow_symlinks=False)
                    require(stat.S_ISREG(info.st_mode), 'unexpected_action_entry')
                    key = (info.st_dev, info.st_ino)
                    require(key not in inodes or inodes[key] == info.st_size, 'changing_action_entry')
                    inodes[key] = info.st_size
        finally:
            os.close(fd)
    total = sum(inodes.values()) + captured_source_bytes
    require(total <= MAX_BYTES, 'action_byte_limit')
    return {'names': count, 'bytes': total, 'inodes': len(inodes)}


def _directory(path, owner, *, private=True):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        require((owner is None or info.st_uid == owner) and not info.st_mode & (0o077 if private else 0o022),
                'unowned_witness_directory')
        return fd
    except BaseException:
        os.close(fd)
        raise


def _info(directory, name, owner):
    try:
        value = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None
    require(stat.S_ISREG(value.st_mode) and value.st_uid == owner
            and not value.st_mode & 0o077 and value.st_size <= MAX_OUTPUT, 'invalid_witness_file')
    return value


def _slot(directory, owner):
    final, pending = _info(directory, FINAL, owner), _info(directory, PENDING, owner)
    if final is not None and pending is not None:
        require((final.st_dev, final.st_ino) == (pending.st_dev, pending.st_ino), 'conflicting_witness_inodes')
    for value in (final, pending):
        if value is not None:
            require(value.st_nlink == (2 if final is not None and pending is not None else 1),
                    'unexplained_witness_alias')
    return final, pending


def _read(directory, name, owner, *, sync=False):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == owner and not info.st_mode & 0o077
                and info.st_size <= MAX_OUTPUT, 'invalid_witness_file')
        raw = bytearray()
        while len(raw) <= MAX_OUTPUT:
            part = os.read(fd, min(65_536, MAX_OUTPUT + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(fd)
        require(len(raw) <= MAX_OUTPUT and len(raw) == info.st_size
                and (info.st_size, info.st_mtime_ns, info.st_ctime_ns) ==
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'changing_witness')
        if sync:
            os.fsync(fd)
        return bytes(raw)
    finally:
        os.close(fd)


def _step(hook, event):
    if hook is not None:
        hook(event)


def _write_pending(directory, owner, raw, *, existing=False, hook=None):
    flags = os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    flags |= 0 if existing else os.O_CREAT | os.O_EXCL
    fd = os.open(PENDING, flags, 0o600, dir_fd=directory)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == owner and info.st_nlink == 1
                and not info.st_mode & 0o077 and info.st_size <= MAX_OUTPUT, 'invalid_pending_witness')
        if existing:
            os.ftruncate(fd, 0)
        offset = 0
        while offset < len(raw):
            count = os.write(fd, raw[offset:offset + 65_536])
            require(count > 0, 'witness_write_failed')
            offset += count
            _step(hook, 'copy_chunk')
        os.fsync(fd)
        _step(hook, 'file_fsynced')
    finally:
        os.close(fd)


def _publish_pending(directory, *, hook=None):
    os.link(PENDING, FINAL, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
    _step(hook, 'final_linked')
    os.fsync(directory)
    _step(hook, 'directory_fsynced')
    os.unlink(PENDING, dir_fd=directory)
    os.fsync(directory)


def publish_ingress(path, raw, *, hook=None):
    """One producer call. Partial slots are retained; the producer never retries."""
    require(type(raw) is bytes and 0 < len(raw) <= MAX_OUTPUT, 'witness_limit')
    directory = _directory(path, os.getuid())
    try:
        require(_slot(directory, os.getuid()) == (None, None), 'witness_already_started')
        _write_pending(directory, os.getuid(), raw, hook=hook)
        _publish_pending(directory, hook=hook)
    finally:
        os.close(directory)


@contextlib.contextmanager
def _exclusive(directory, owner):
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == owner and info.st_nlink == 1
                and info.st_size == 0 and not info.st_mode & 0o077, 'invalid_publication_lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fsync(fd)
        os.fsync(directory)
        yield
    finally:
        os.close(fd)


def recover(ingress, guardian, validate, *, producer_uid=62401, guardian_uid=0, hook=None):
    """Publish/reopen a validated witness, never creating a third body inode.

    `validate` is the captured guardian's strict action/wait/result validator.
    It may raise and must have no dependent side effects. The returned bytes
    have a successful file+directory barrier; no receipt is issued here.
    """
    source = _directory(ingress, producer_uid)
    target = None
    try:
        target = _directory(guardian, guardian_uid)
        with _exclusive(target, guardian_uid):
            # These dedicated directories contain only body slots/the lock.
            for directory, allowed in ((source, {FINAL, PENDING}), (target, {FINAL, PENDING, LOCK})):
                with os.scandir(directory) as entries:
                    for count, entry in enumerate(entries, 1):
                        require(count <= 3 and entry.name in allowed, 'unexpected_witness_name')
            source_final, source_pending = _slot(source, producer_uid)
            final, pending = _slot(target, guardian_uid)
            if final is not None:
                raw = _read(target, FINAL, guardian_uid, sync=True)
                validate(raw)
                if source_final is not None:
                    original = _read(source, FINAL, producer_uid)
                    require(raw == original, 'witness_replay_conflict')
                else:
                    require(source_pending is None, 'incomplete_ingress')
                os.fsync(target)
                _step(hook, 'final_reused')
            else:
                require(source_final is not None, 'incomplete_ingress')
                raw = _read(source, FINAL, producer_uid)
                validate(raw)
                if pending is not None and _read(target, PENDING, guardian_uid) == raw:
                    _read(target, PENDING, guardian_uid, sync=True)
                else:
                    _write_pending(target, guardian_uid, raw, existing=pending is not None, hook=hook)
                try:
                    _publish_pending(target, hook=hook)
                except FileExistsError:
                    # No new body allocation; the same final must validate.
                    _slot(target, guardian_uid)
                    require(_read(target, FINAL, guardian_uid, sync=True) == raw, 'witness_replay_conflict')
                    os.fsync(target)
            # Re-check inode aliases after the barrier, before exact cleanup.
            _, pending = _slot(target, guardian_uid)
            if pending is not None:
                os.unlink(PENDING, dir_fd=target)
                os.fsync(target)
            _step(hook, 'before_ingress_unlink')
            source_final, source_pending = _slot(source, producer_uid)
            if source_pending is not None:
                os.unlink(PENDING, dir_fd=source)
            if source_final is not None:
                os.unlink(FINAL, dir_fd=source)
            os.fsync(source)
            _step(hook, 'ingress_unlinked')
            return raw
    finally:
        if target is not None:
            os.close(target)
        os.close(source)
