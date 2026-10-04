"""Bounded fixture records. These records are not database retirement receipts."""
import json
import os
from pathlib import Path
import re
import stat
import uuid

LIMIT = 65_536


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf8')


def read(path, limit=LIMIT):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        status = os.fstat(stream.fileno())
        require(stat.S_ISREG(status.st_mode) and status.st_size <= limit, 'invalid_record')
        raw = stream.read(limit + 1)
        require(len(raw) <= limit, 'record_limit')
        return raw


def decode(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'duplicate_key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('invalid_json')))


def publish(parent, name, value):
    require(re.fullmatch(r'[a-z][a-z0-9_-]{0,40}\.json', name) is not None, 'invalid_record_name')
    raw = canonical(value)
    require(len(raw) <= LIMIT, 'record_limit')
    parent = Path(parent)
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    pending = '.pending-' + uuid.uuid4().hex
    try:
        status = os.fstat(directory)
        require(status.st_uid == os.getuid() and not status.st_mode & 0o022, 'unowned_record_directory')
        with os.scandir(directory) as entries:
            count = 0
            for _ in entries:
                count += 1
                require(count < 32, 'record_capacity')
        fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                     dir_fd=directory)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(pending, name, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
        os.unlink(pending, dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(pending, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)


def durable_read(path):
    """Establish a fresh file and directory barrier before dependent actions."""
    path = Path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        status = os.fstat(fd)
        require(stat.S_ISREG(status.st_mode) and status.st_size <= LIMIT
                and status.st_uid == os.getuid() and not status.st_mode & 0o077, 'invalid_checkpoint')
        raw = os.read(fd, LIMIT + 1)
        require(len(raw) <= LIMIT, 'record_limit')
        os.fsync(fd)
    finally:
        os.close(fd)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return decode(raw)
