"""Private, bounded immutable fixture checkpoints. No restart authority."""
import os
from pathlib import Path
import re
import stat
import uuid

from protocol import canonical, decode, digest, require

MAX_FILES = 32
MAX_BYTES = 4 * 1024 * 1024
MAX_FILE = 1_572_864


class Journal:
    def __init__(self, parent):
        parent = Path(parent)
        status = parent.lstat()
        require(stat.S_ISDIR(status.st_mode) and status.st_uid == os.getuid()
                and not status.st_mode & 0o077, 'journal_parent_not_private')
        self.path = parent / str(uuid.uuid4())
        self.path.mkdir(mode=0o700)
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        owner = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(owner)
        finally:
            os.close(owner)
        self._count, self._bytes = 0, 0
        self._records = {}

    @classmethod
    def existing(cls, path):
        """Read retained private checkpoints; this cannot recreate a witness."""
        instance = cls.__new__(cls)
        instance.path = Path(path)
        status = instance.path.lstat()
        require(stat.S_ISDIR(status.st_mode) and status.st_uid == os.getuid()
                and not status.st_mode & 0o077, 'journal_parent_not_private')
        instance.fd = os.open(instance.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        instance._records = {}
        instance._count = instance._bytes = 0
        try:
            names = []
            with os.scandir(instance.fd) as entries:
                for entry in entries:
                    names.append(entry.name)
                    require(len(names) <= MAX_FILES, 'journal_capacity')
            for name in names:
                require(re.fullmatch(r'[a-z][a-z0-9_-]{0,63}\.json', name) is not None, 'incomplete_checkpoint')
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=instance.fd)
                with os.fdopen(fd, 'rb') as stream:
                    status = os.fstat(stream.fileno())
                    require(stat.S_ISREG(status.st_mode) and status.st_uid == os.getuid()
                            and not status.st_mode & 0o077 and status.st_size <= MAX_FILE, 'invalid_checkpoint')
                    raw = stream.read(MAX_FILE + 1)
                    require(len(raw) <= MAX_FILE, 'journal_capacity')
                    # A previous writer may have linked the final name, then
                    # failed its durability barrier. Reopening must establish
                    # its own successful barrier before any dependent RPC.
                    os.fsync(stream.fileno())
                instance._records[name] = digest(raw)
                instance._bytes += len(raw); instance._count += 1
            require(instance._bytes <= MAX_BYTES, 'journal_capacity')
            os.fsync(instance.fd)
            return instance
        except BaseException:
            instance.close()
            raise

    def put(self, name, value):
        return self.raw(name, canonical(value))

    def raw(self, name, raw):
        require(re.fullmatch(r'[a-z][a-z0-9_-]{0,63}\.(?:json|py)', name) is not None,
                'invalid_checkpoint_name')
        require(type(raw) is bytes and len(raw) <= MAX_FILE, 'journal_capacity')
        if name in self._records:
            require(self._records[name] == digest(raw) and self.read_raw(name) == raw, 'immutable_checkpoint')
            return
        require(self._count < MAX_FILES and self._bytes + len(raw) <= MAX_BYTES, 'journal_capacity')
        temporary = '.pending-' + uuid.uuid4().hex
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            # Atomic no-overwrite publish. link/unlink preserves the same
            # filesystem semantics while refusing an existing frozen name.
            os.link(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False)
            os.unlink(temporary, dir_fd=self.fd)
            os.fsync(self.fd)
        except BaseException:
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass
            raise
        self._count += 1
        self._bytes += len(raw)
        self._records[name] = digest(raw)

    def read_raw(self, name):
        require(name in self._records, 'unknown_checkpoint')
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
        with os.fdopen(fd, 'rb') as stream:
            status = os.fstat(stream.fileno())
            require(stat.S_ISREG(status.st_mode) and status.st_size <= MAX_FILE
                    and status.st_uid == os.getuid() and not status.st_mode & 0o077, 'invalid_checkpoint')
            raw = stream.read(MAX_FILE + 1)
        require(digest(raw) == self._records[name], 'checkpoint_changed')
        return raw

    def read(self, name):
        return decode(self.read_raw(name))

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
