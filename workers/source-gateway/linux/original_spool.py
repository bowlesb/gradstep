"""Bounded original-PDF slots; no transport, SQL, parser or retirement authority.

The guardian owns one reservation lock across allocation and every handoff. The
required validators are the enclosing guardian's captured lifetime/journal
boundary, not untrusted flags. They must raise on uncertainty and return None on
success. In particular, a free flock does not retire a reader left by a crashed
guardian. The portable tests inject these validators and prove file mechanics
only. This module is not in the admitted metadata action bundle.
"""
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat
import uuid

from common import canonical, decode, require

MAX_PAYLOAD = 5_242_880
MAX_RECORD = 4096
CHUNK = 65_536
MAX_RETAINED = 2 * MAX_PAYLOAD + MAX_RECORD
LOCK = 'publication.lock'
IDENTITY_KEYS = {'reservation_id', 'claim_id', 'purpose'}
BINDING_KEYS = IDENTITY_KEYS | {'attempt_id', 'request_sha256', 'binding_sha256', 'capture_sha256'}
FRAMING = {'content-length', 'chunked', 'tls-close'}
PAIRS = {'payload': 'payload.pending', 'descriptor.json': 'descriptor.pending'}
FILE_NAMES = {'producer': {'payload', 'payload.pending'},
              'guardian': {'payload', 'payload.pending', 'descriptor.json', 'descriptor.pending'}}


def _digest(raw):
    return hashlib.sha256(raw).hexdigest()


def _hex(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'spool_digest')


def _uuid(value):
    require(type(value) is str and str(uuid.UUID(value)) == value, 'spool_uuid')


def _identity(value, *, binding=False):
    keys = BINDING_KEYS if binding else IDENTITY_KEYS
    require(type(value) is dict and set(value) == keys, 'spool_binding_shape')
    for key in ('reservation_id', 'claim_id') + (('attempt_id',) if binding else ()):
        _uuid(value[key])
    require(value['purpose'] in ('source_download', 'stored_readback'), 'spool_purpose')
    if binding:
        for key in ('request_sha256', 'binding_sha256', 'capture_sha256'):
            _hex(value[key])
    return dict(value)


def _inode(value):
    require(type(value) is dict and set(value) == {'device', 'inode'}, 'spool_inode_shape')
    for key in value:
        text = value[key]
        require(type(text) is str and re.fullmatch('0|[1-9][0-9]{0,19}', text)
                and int(text) <= 2**64 - 1 and (key != 'inode' or int(text) > 0), 'spool_inode')


def _id(info):
    return {'device': str(info.st_dev), 'inode': str(info.st_ino)}


def _body(value):
    require(type(value['bytes']) is int and 0 < value['bytes'] <= MAX_PAYLOAD, 'spool_body_limit')
    _hex(value['sha256'])


def _encoded(value):
    raw = canonical(value) + b'\n'
    require(0 < len(raw) <= MAX_RECORD, 'spool_record_limit')
    return raw


def _record(raw):
    require(type(raw) is bytes and 0 < len(raw) <= MAX_RECORD, 'spool_record_limit')
    value = decode(raw)
    require(type(value) is dict and _encoded(value) == raw, 'spool_noncanonical_record')
    return value


def _completion(raw):
    value = _record(raw)
    require(set(value) == BINDING_KEYS | {'format', 'bytes', 'sha256', 'producer', 'framing'}
            and value['format'] == 'original-transfer-complete-v1'
            and type(value['framing']) is str and value['framing'] in FRAMING, 'spool_completion_shape')
    _identity({k: value[k] for k in BINDING_KEYS}, binding=True)
    _body(value)
    _inode(value['producer'])
    return value


def descriptor(raw):
    """Validate the closed canonical descriptor; no filesystem or authority."""
    value = _record(raw)
    require(set(value) == BINDING_KEYS | {'format', 'bytes', 'sha256', 'producer', 'guardian'}
            and value['format'] == 'original-spool-v1', 'spool_descriptor_shape')
    _identity({k: value[k] for k in BINDING_KEYS}, binding=True)
    _body(value)
    _inode(value['producer'])
    _inode(value['guardian'])
    require(value['producer'] != value['guardian'], 'spool_shared_payload_inode')
    return value


def _validate(callback, *values):
    require(callable(callback), 'spool_validator_required')
    # Pass owned values: a validator cannot mutate the pending operation.
    require(callback(*(decode(canonical(v)) for v in values)) is None, 'spool_validator_result')


def _event(hook, name):
    if hook is not None:
        hook(name)


def _close_all(fds):
    """A failed close may already have consumed the number. Never retry it."""
    first = None
    for fd in fds:
        if fd is not None:
            try:
                os.close(fd)
            except OSError as error:
                if first is None:
                    first = error
    if first is not None:
        raise first


def _names(directory, maximum):
    names = set()
    with os.scandir(directory) as entries:
        for entry in entries:
            require(len(names) < maximum, 'spool_name_limit')
            names.add(entry.name)
    return names


def _directory(fd, uid, gid, device=None):
    info = os.fstat(fd)
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == uid and info.st_gid == gid
            and stat.S_IMODE(info.st_mode) == 0o700
            and (device is None or info.st_dev == device), 'spool_directory_identity')
    return info


def _root(path, uid, gid):
    # Walk using directory descriptors, refusing a symlink at every component.
    # The trusted deployment owns the base and its ancestry; it is not a request.
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts, 'spool_root')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in path.parts[1:]:
            ancestor = os.fstat(fd)
            require(ancestor.st_uid in (0, uid) and not ancestor.st_mode & 0o022, 'spool_untrusted_ancestor')
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            previous, fd = fd, child
            os.close(previous)
        _directory(fd, uid, gid)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _child(parent, name, uid, gid, *, create=False):
    if create:
        os.mkdir(name, 0o700, dir_fd=parent)
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    try:
        if create:
            info = os.fstat(fd)
            if (info.st_uid, info.st_gid) != (uid, gid):
                os.fchown(fd, uid, gid)
            os.fchmod(fd, 0o700)
            os.fsync(fd)
            os.fsync(parent)
        _directory(fd, uid, gid, os.fstat(parent).st_dev)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _files(directory, role, uid, gid):
    names = _names(directory, len(FILE_NAMES[role]))
    require(names <= FILE_NAMES[role], 'spool_unexpected_file')
    values = {name: os.stat(name, dir_fd=directory, follow_symlinks=False) for name in names}
    device = os.fstat(directory).st_dev
    for name, info in values.items():
        maximum = MAX_RECORD if name.startswith('descriptor') else MAX_PAYLOAD
        other = PAIRS.get(name) or next(k for k, v in PAIRS.items() if v == name)
        aliases = 1 + int(other in names)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == uid and info.st_gid == gid
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_dev == device
                and 0 <= info.st_size <= maximum and info.st_nlink == aliases, 'spool_file_identity')
        if other in names:
            require(_id(info) == _id(values[other]), 'spool_alias_conflict')
    return values


def _stable(before, after):
    fields = ('st_dev', 'st_ino', 'st_uid', 'st_gid', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
    require(all(getattr(before, key) == getattr(after, key) for key in fields), 'spool_changed')


def _open_file(directory, name, expected):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    try:
        _stable(expected, os.fstat(fd))
        return fd
    except BaseException:
        os.close(fd)
        raise


def _hash(fd, maximum):
    before, count, digest = os.fstat(fd), 0, hashlib.sha256()
    require(before.st_size <= maximum, 'spool_body_limit')
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        part = os.read(fd, min(CHUNK, maximum + 1 - count))
        if not part:
            break
        count += len(part)
        require(count <= maximum, 'spool_body_limit')
        digest.update(part)
    _stable(before, os.fstat(fd))
    require(count == before.st_size, 'spool_changed')
    os.lseek(fd, 0, os.SEEK_SET)
    return {'bytes': count, 'sha256': digest.hexdigest()}


def _read_small(directory, name, info):
    fd = _open_file(directory, name, info)
    try:
        raw = b''
        while len(raw) <= MAX_RECORD:
            part = os.read(fd, MAX_RECORD + 1 - len(raw))
            if not part:
                break
            raw += part
        _stable(info, os.fstat(fd))
        require(len(raw) == info.st_size and len(raw) <= MAX_RECORD, 'spool_record_limit')
        os.fsync(fd)
        return raw
    finally:
        os.close(fd)


def _write(fd, raw, hook=None, event='copy_chunk'):
    offset = 0
    while offset < len(raw):
        count = os.write(fd, raw[offset:offset + CHUNK])
        require(0 < count <= len(raw) - offset, 'spool_write_failed')
        offset += count
        _event(hook, event)


def _publish(directory, final, hook=None):
    pending = PAIRS[final]
    if final not in _names(directory, 4):
        os.link(pending, final, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
        _event(hook, final + '_linked')
    os.fsync(directory)
    _event(hook, final + '_directory_fsynced')
    if pending in _names(directory, 4):
        require(_id(os.stat(final, dir_fd=directory, follow_symlinks=False)) ==
                _id(os.stat(pending, dir_fd=directory, follow_symlinks=False)), 'spool_alias_conflict')
        os.unlink(pending, dir_fd=directory)
        os.fsync(directory)


class Producer:
    """One supervisor-owned sequential writer. Any error poisons this handle.

    The guardian preopens the directory before dropping privileges. Full binding
    arrives only with the committed grant, after paused execution capture. No
    producer restart or append-to-existing operation is provided.
    """
    def __init__(self, preopened_directory, binding):
        self.binding = _identity(binding, binding=True)
        self.directory, self.fd = None, None
        self.failed, self.finished, self.count = False, False, 0
        self.digest = hashlib.sha256()
        try:
            self.directory = os.dup(preopened_directory)
            _directory(self.directory, os.geteuid(), os.getegid())
            require(not _files(self.directory, 'producer', os.geteuid(), os.getegid()), 'spool_producer_started')
            self.fd = os.open('payload.pending', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                              0o600, dir_fd=self.directory)
            os.fchmod(self.fd, 0o600)
            os.fsync(self.directory)
        except BaseException:
            self.close()
            raise

    def append(self, raw):
        require(self.fd is not None and not self.failed and not self.finished, 'spool_producer_closed')
        try:
            require(type(raw) is bytes and 0 < len(raw) <= CHUNK
                    and self.count + len(raw) <= MAX_PAYLOAD, 'spool_body_limit')
            offset = 0
            while offset < len(raw):
                count = os.write(self.fd, raw[offset:])
                require(0 < count <= len(raw) - offset, 'spool_write_failed')
                self.digest.update(raw[offset:offset + count])
                self.count += count
                offset += count
        except BaseException:
            self.failed = True
            raise

    def finish(self, facts, *, hook=None):
        require(self.fd is not None and not self.failed and not self.finished, 'spool_producer_closed')
        try:
            require(type(facts) is dict, 'spool_incomplete_transfer')
            facts = dict(facts)
            require(type(facts) is dict and set(facts) == {'status', 'framing', 'framing_complete', 'bytes', 'sha256'}
                    and type(facts['status']) is int and facts['status'] == 200
                    and type(facts['framing']) is str and facts['framing'] in FRAMING
                    and facts['framing_complete'] is True,
                    'spool_incomplete_transfer')
            _body(facts)
            require(facts['bytes'] == self.count and facts['sha256'] == self.digest.hexdigest(), 'spool_transfer_mismatch')
            info = os.fstat(self.fd)
            require(info.st_size == self.count and info.st_nlink == 1, 'spool_changed')
            os.fsync(self.fd)
            _event(hook, 'producer_fsynced')
            _publish(self.directory, 'payload', hook)
            result = _encoded(dict(self.binding, format='original-transfer-complete-v1',
                                   bytes=self.count, sha256=self.digest.hexdigest(),
                                   producer=_id(info), framing=facts['framing']))
            self.finished = True
            self.close()
            return result
        except BaseException:
            self.failed = True
            raise

    def close(self):
        fds = [self.fd, self.directory]
        self.fd = self.directory = None
        _close_all(fds)

    def __enter__(self):
        return self

    def __exit__(self, *error):
        self.close()


class OriginalSpool:
    def __init__(self, root, slot_identity, *, guardian_uid=0, guardian_gid=0,
                 producer_uid=62401, producer_gid=62401):
        self.root = Path(root)
        self.identity = _identity(slot_identity)
        self.name = uuid.UUID(self.identity['reservation_id']).hex
        self.leaf_name = self.identity['purpose'] + '-' + uuid.UUID(self.identity['claim_id']).hex
        self.guardian = guardian_uid, guardian_gid
        self.producer = producer_uid, producer_gid
        self.base = self.reservation = self.lock = None
        self.dirs = {}
        self.readers = 0

    def __enter__(self):
        require(os.geteuid() == self.guardian[0] and self.base is None, 'spool_guardian_required')
        try:
            self.base = _root(self.root, *self.guardian)
            try:
                self.reservation = _child(self.base, self.name, *self.guardian, create=True)
            except FileExistsError:
                self.reservation = _child(self.base, self.name, *self.guardian)
            self.lock = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                0o600, dir_fd=self.reservation)
            info = os.fstat(self.lock)
            require(stat.S_ISREG(info.st_mode) and (info.st_uid, info.st_gid) == self.guardian
                    and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1 and info.st_size == 0,
                    'spool_lock_identity')
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.fsync(self.lock)
            os.fsync(self.reservation)
            self._current()
            return self
        except BaseException:
            self.__exit__(*__import__('sys').exc_info())
            raise

    def __exit__(self, *error):
        # Nested open_sealed contexts must end first. Child-FD retirement is the
        # enclosing guardian's responsibility; closing our lock is not evidence.
        require(self.readers == 0, 'spool_reader_open')
        fds = list(self.dirs.values()) + [self.lock, self.reservation, self.base]
        self.dirs = {}
        self.lock = self.reservation = self.base = None
        _close_all(fds)

    def _current(self):
        require(self.lock is not None, 'spool_lock_required')
        base = _root(self.root, *self.guardian)
        try:
            require(_id(os.fstat(base)) == _id(os.fstat(self.base)), 'spool_root_changed')
        finally:
            os.close(base)
        require(_id(os.stat(self.name, dir_fd=self.base, follow_symlinks=False)) ==
                _id(os.fstat(self.reservation)), 'spool_reservation_changed')
        _directory(self.reservation, *self.guardian, os.fstat(self.base).st_dev)
        require(_id(os.stat(LOCK, dir_fd=self.reservation, follow_symlinks=False)) ==
                _id(os.fstat(self.lock)), 'spool_lock_changed')
        lock = os.fstat(self.lock)
        require(stat.S_ISREG(lock.st_mode) and (lock.st_uid, lock.st_gid) == self.guardian
                and stat.S_IMODE(lock.st_mode) == 0o600 and lock.st_nlink == 1 and lock.st_size == 0,
                'spool_lock_identity')
        names = _names(self.reservation, 2)
        require(names <= {LOCK, self.leaf_name}, 'spool_reservation_occupied')
        if self.dirs:
            require(self.leaf_name in names and _id(os.stat(self.leaf_name, dir_fd=self.reservation,
                    follow_symlinks=False)) == _id(os.fstat(self.dirs['leaf'])), 'spool_leaf_changed')
            _directory(self.dirs['leaf'], *self.guardian, os.fstat(self.reservation).st_dev)
            require(_names(self.dirs['leaf'], 2) == {'producer', 'guardian'}, 'spool_leaf_shape')
            for role in ('producer', 'guardian'):
                require(_id(os.stat(role, dir_fd=self.dirs['leaf'], follow_symlinks=False)) ==
                        _id(os.fstat(self.dirs[role])), 'spool_directory_changed')
                _directory(self.dirs[role], *getattr(self, role), os.fstat(self.reservation).st_dev)
        return names

    def _open_leaf(self, *, create=False):
        names = self._current()
        if self.dirs:
            return
        creating = self.leaf_name not in names
        require(not creating or create, 'spool_missing_leaf')
        opened = {}
        try:
            opened['leaf'] = _child(self.reservation, self.leaf_name, *self.guardian, create=creating)
            for role in ('producer', 'guardian'):
                opened[role] = _child(opened['leaf'], role, *getattr(self, role), create=creating)
            require(_names(opened['leaf'], 2) == {'producer', 'guardian'}, 'spool_leaf_shape')
            self.dirs = opened
        except BaseException:
            _close_all(opened.values())
            raise

    def _binding(self, value):
        value = _identity(value, binding=True)
        require(all(value[k] == v for k, v in self.identity.items()), 'spool_binding_mismatch')
        return value

    def inventory(self):
        self._open_leaf()
        files = {role: _files(self.dirs[role], role, *getattr(self, role)) for role in ('producer', 'guardian')}
        inodes, count = {}, 1
        for role, entries in files.items():
            for name, info in entries.items():
                count += 1
                key = (info.st_dev, info.st_ino)
                category = role, 'descriptor' if name.startswith('descriptor') else 'payload'
                require(key not in inodes or inodes[key] == (category, info.st_size), 'spool_shared_inode')
                inodes[key] = category, info.st_size
        total = sum(size for _, size in inodes.values())
        require(count <= 7 and len(inodes) <= 3 and total <= MAX_RETAINED, 'spool_capacity')
        return files, {'names': count, 'bytes': total, 'payload_inodes': sum(k[1] == 'payload' for k, _ in inodes.values())}

    def prepare(self, validate_allocation):
        self._current()
        _validate(validate_allocation, self.identity)
        self._open_leaf(create=True)
        self.inventory()
        return os.dup(self.dirs['producer'])

    def _payload(self, role, name, info, expected):
        fd = _open_file(self.dirs[role], name, info)
        try:
            require(_id(info) == expected[role] and _hash(fd, MAX_PAYLOAD) ==
                    {k: expected[k] for k in ('bytes', 'sha256')}, 'spool_payload_mismatch')
            os.fsync(fd)
            return fd
        except BaseException:
            os.close(fd)
            raise

    def _checked_descriptor(self, expected, files):
        name = 'descriptor.json' if 'descriptor.json' in files['guardian'] else 'descriptor.pending'
        raw = _read_small(self.dirs['guardian'], name, files['guardian'][name])
        value = descriptor(raw)
        require(all(value.get(k) == v for k, v in expected.items() if k != 'framing'
                    and k != 'format'), 'spool_descriptor_conflict')
        require('payload' in files['guardian'], 'spool_descriptor_without_payload')
        fd = self._payload('guardian', 'payload', files['guardian']['payload'], value)
        os.close(fd)
        if files['producer']:
            name = 'payload' if 'payload' in files['producer'] else 'payload.pending'
            fd = self._payload('producer', name, files['producer'][name], value)
            os.close(fd)
        return raw

    def seal(self, binding, completion, validate_retirement, *, hook=None):
        binding = self._binding(binding)
        witness = _completion(completion)
        require(all(witness[k] == v for k, v in binding.items()), 'spool_binding_mismatch')
        _validate(validate_retirement, binding, witness)
        files, _ = self.inventory()
        target = self.dirs['guardian']
        if any(name.startswith('descriptor') for name in files['guardian']):
            raw = self._checked_descriptor(witness, files)
            _publish(target, 'descriptor.json', hook)
            return raw
        require('payload' in files['producer'], 'spool_incomplete_producer')
        source = self._payload('producer', 'payload', files['producer']['payload'], witness)
        try:
            if 'payload' in files['guardian']:
                expected = dict(witness, guardian=_id(files['guardian']['payload']))
                fd = self._payload('guardian', 'payload', files['guardian']['payload'], expected)
                os.close(fd)
            else:
                pending = files['guardian'].get('payload.pending')
                flags = os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
                fd = os.open('payload.pending', flags | (0 if pending else os.O_CREAT | os.O_EXCL),
                             0o600, dir_fd=target)
                try:
                    if pending:
                        _stable(pending, os.fstat(fd))
                    else:
                        os.fchmod(fd, 0o600)
                    os.ftruncate(fd, 0)
                    copied, digest = 0, hashlib.sha256()
                    while True:
                        part = os.read(source, CHUNK)
                        if not part:
                            break
                        copied += len(part)
                        require(copied <= witness['bytes'], 'spool_changed')
                        digest.update(part)
                        _write(fd, part, hook)
                    require(copied == witness['bytes'] and digest.hexdigest() == witness['sha256'], 'spool_changed')
                    _stable(files['producer']['payload'], os.fstat(source))
                    os.fsync(fd)
                    _event(hook, 'guardian_fsynced')
                finally:
                    os.close(fd)
            _publish(target, 'payload', hook)
            files, _ = self.inventory()
            value = dict(binding, format='original-spool-v1', bytes=witness['bytes'], sha256=witness['sha256'],
                         producer=witness['producer'], guardian=_id(files['guardian']['payload']))
            raw = _encoded(value)
            descriptor(raw)
            fd = os.open('descriptor.pending', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=target)
            try:
                os.fchmod(fd, 0o600)
                _write(fd, raw, hook, 'descriptor_chunk')
                os.fsync(fd)
                _event(hook, 'descriptor_fsynced')
            finally:
                os.close(fd)
            _publish(target, 'descriptor.json', hook)
            return raw
        finally:
            os.close(source)

    @contextlib.contextmanager
    def open_sealed(self, expected_descriptor, validate_reader):
        value = descriptor(expected_descriptor)
        self._binding({k: value[k] for k in BINDING_KEYS})
        # Must durably bind the exact reader intent before any FD is exported.
        _validate(validate_reader, value)
        files, _ = self.inventory()
        require('descriptor.json' in files['guardian'], 'spool_unsealed')
        require(self._checked_descriptor(value, files) == expected_descriptor, 'spool_descriptor_conflict')
        fd = self._payload('guardian', 'payload', files['guardian']['payload'], value)
        try:
            os.fsync(self.dirs['guardian'])
            self.readers += 1
            try:
                yield fd
            finally:
                self.readers -= 1
        finally:
            os.close(fd)

    def capture_cleanup(self, binding, validate_retirement):
        """Capture exact stopped slots. Caller must save this before any unlink.

        This also handles a failed transfer's partial payload or descriptor. It
        does not make a candidate out of either. Partial directory initialization
        remains quarantined; it is not a reason to infer another allocation.
        """
        binding = self._binding(binding)
        require(self.readers == 0, 'spool_reader_open')
        _validate(validate_retirement, binding)
        files, _ = self.inventory()
        captured = {}
        for role, entries in files.items():
            for name, info in entries.items():
                fd = _open_file(self.dirs[role], name, info)
                try:
                    maximum = MAX_RECORD if name.startswith('descriptor') else MAX_PAYLOAD
                    captured[role + '/' + name] = dict(_id(info), **_hash(fd, maximum))
                finally:
                    os.close(fd)
        return _encoded(dict(binding, format='original-spool-cleanup-v1',
                             directories={name: _id(os.fstat(fd)) for name, fd in
                                          dict(self.dirs, reservation=self.reservation).items()}, files=captured))

    def retire_slots(self, captured, validate_settlement, *, hook=None):
        """Unlink only the saved exact inventory, replaying an interrupted cleanup.

        The validator establishes durable cleanup intent, all writer/reader
        retirement and positive downstream settlement. Unknown uploads cannot
        reach this method through a valid guardian. The returned small record is
        a local durability observation, not a SQL receipt or permission to retry.
        """
        value = _record(captured)
        require(set(value) == BINDING_KEYS | {'format', 'directories', 'files'}
                and value['format'] == 'original-spool-cleanup-v1', 'spool_cleanup_shape')
        self._binding({k: value[k] for k in BINDING_KEYS})
        directories, files = value['directories'], value['files']
        require(type(directories) is dict and set(directories) == {'reservation', 'leaf', 'producer', 'guardian'}
                and type(files) is dict and set(files) <= {role + '/' + name for role in FILE_NAMES
                                                         for name in FILE_NAMES[role]}, 'spool_cleanup_shape')
        for info in directories.values():
            _inode(info)
        for name, info in files.items():
            require(type(info) is dict and set(info) == {'device', 'inode', 'bytes', 'sha256'}, 'spool_cleanup_shape')
            _inode({k: info[k] for k in ('device', 'inode')})
            maximum = MAX_RECORD if name.split('/')[1].startswith('descriptor') else MAX_PAYLOAD
            require(type(info['bytes']) is int and 0 <= info['bytes'] <= maximum, 'spool_cleanup_limit')
            _hex(info['sha256'])
        require(self.readers == 0, 'spool_reader_open')
        _validate(validate_settlement, value)
        # A previous cleanup may have removed one child directory before dying.
        # Reopen that partial layout directly, against saved directory identities.
        previous = list(self.dirs.values())
        self.dirs = {}
        _close_all(previous)
        names = self._current()
        require(_id(os.fstat(self.reservation)) == directories['reservation'], 'spool_cleanup_conflict')
        opened, current = {}, {}
        try:
            if self.leaf_name in names:
                opened['leaf'] = _child(self.reservation, self.leaf_name, *self.guardian)
                require(_id(os.fstat(opened['leaf'])) == directories['leaf'], 'spool_cleanup_conflict')
                roles = _names(opened['leaf'], 2)
                require(roles <= {'producer', 'guardian'}, 'spool_leaf_shape')
                for role in sorted(roles):
                    opened[role] = _child(opened['leaf'], role, *getattr(self, role))
                    require(_id(os.fstat(opened[role])) == directories[role], 'spool_cleanup_conflict')
                    current[role] = _files(opened[role], role, *getattr(self, role))
                    for name, info in current[role].items():
                        key = role + '/' + name
                        require(key in files and _id(info) == {k: files[key][k] for k in ('device', 'inode')},
                                'spool_cleanup_conflict')
                        fd = _open_file(opened[role], name, info)
                        try:
                            maximum = MAX_RECORD if name.startswith('descriptor') else MAX_PAYLOAD
                            require(_hash(fd, maximum) == {k: files[key][k] for k in ('bytes', 'sha256')},
                                    'spool_cleanup_conflict')
                        finally:
                            os.close(fd)
                # No mutation until every remaining name, identity and byte
                # sequence is checked. Missing names mean only replay progress.
                for role in ('producer', 'guardian'):
                    if role not in opened:
                        continue
                    for name in sorted(current[role]):
                        require(_id(os.stat(name, dir_fd=opened[role], follow_symlinks=False)) ==
                                _id(current[role][name]), 'spool_cleanup_conflict')
                        os.unlink(name, dir_fd=opened[role])
                        _event(hook, 'cleanup_unlinked')
                    os.fsync(opened[role])
                    os.rmdir(role, dir_fd=opened['leaf'])
                    os.fsync(opened['leaf'])
                    _event(hook, role + '_removed')
                os.rmdir(self.leaf_name, dir_fd=self.reservation)
                _event(hook, 'leaf_removed')
            os.fsync(self.reservation)
            _event(hook, 'cleanup_fsynced')
            return _encoded(dict(self.identity, format='original-spool-cleaned-v1',
                                 cleanup_sha256=_digest(captured)))
        finally:
            _close_all(opened.values())
