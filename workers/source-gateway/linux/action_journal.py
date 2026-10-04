"""Fixed whole-action journal. Only the guardian owns authoritative checkpoints.

Paths/owners/units are trusted deployment inputs, never executor request fields.
The caller holds one publication lock across file operations and dependent RPCs.
"""
import os
from pathlib import Path
import re
import stat
import uuid

from common import canonical, decode, require
import witness_slots as slots

RECORDS = {name + '.json': ('records', 65_536) for name in
           ('intent', 'grant', 'grant-status', 'parser-input', 'parser-output', 'result', 'result-ack')}
RECORDS.update({name + '.json': ('records', 16_384) for name in
                ('capacity', 'capture', 'stop-fence', 'observation', 'executor', 'executor-ack',
                 'arxiv_connection', 'arxiv_connection-ack')})
RECORDS.update({'input.json': ('control', 65_536), 'go.json': ('control', 4096),
                'stop.json': ('control', 4096), 'ready.json': ('data', 4096),
                'privileges.json': ('data', 4096), 'go-intent.json': ('records', 4096),
                'terminal-witness.json': ('records', 4096)})
PENDING = '.pending-'


def _names(directory, maximum=32):
    result = set()
    with os.scandir(directory) as entries:
        for entry in entries:
            require(len(result) < maximum, 'action_name_limit')
            result.add(entry.name)
    return result


def paths(scope):
    require(type(scope) is str and str(uuid.UUID(scope)) == scope, 'invalid_scope')
    name = uuid.UUID(scope).hex
    base = Path('/var/lib/timestep-source')
    return {'records': base / 'attempts' / name, 'witness': base / 'witnesses' / name,
            **{leaf: base / 'transport' / name / leaf for leaf in ('control', 'data', 'ingress')}}


def _open_directory(path, owner, group, mode):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'redirected_action_directory')
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        value = os.fstat(fd)
        require(value.st_uid == owner and value.st_gid == group
                and stat.S_IMODE(value.st_mode) == mode, 'action_directory_identity')
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read(directory, name, owner, group, mode, maximum, *, sync=False):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == owner and before.st_gid == group
                and stat.S_IMODE(before.st_mode) == mode and 0 <= before.st_size <= maximum,
                'invalid_action_record')
        raw = bytearray()
        while len(raw) <= maximum:
            part = os.read(fd, min(65_536, maximum + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(fd)
        require(len(raw) == before.st_size and (before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'action_record_changed')
        if sync:
            os.fsync(fd)
        return bytes(raw)
    finally:
        os.close(fd)


def _publish(directory, name, raw, owner, group, mode, maximum, hook=None):
    pending = PENDING + name
    names = _names(directory)
    if name in names:
        require(_read(directory, name, owner, group, mode, maximum, sync=True) == raw,
                'immutable_action_record')
        os.fsync(directory)
    else:
        if pending in names:
            # A partial/conflicting record has no saved digest to justify
            # rewriting it. Keep the same inode unresolved for explicit recovery.
            require(_read(directory, pending, owner, group, mode, maximum, sync=True) == raw,
                    'unfinished_action_record')
        else:
            fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=directory)
            try:
                if os.fstat(fd).st_gid != group:
                    os.fchown(fd, -1, group)
                os.fchmod(fd, mode)
                offset = 0
                while offset < len(raw):
                    written = os.write(fd, raw[offset:offset + 4096])
                    require(written > 0, 'checkpoint_write_failed')
                    offset += written
                    slots._step(hook, 'checkpoint_chunk')
                os.fsync(fd)
                slots._step(hook, 'checkpoint_fsynced')
            finally:
                os.close(fd)
        os.link(pending, name, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
        slots._step(hook, 'checkpoint_linked')
        os.fsync(directory)
        slots._step(hook, 'checkpoint_directory_fsynced')
    if pending in _names(directory):
        a = os.stat(name, dir_fd=directory, follow_symlinks=False)
        b = os.stat(pending, dir_fd=directory, follow_symlinks=False)
        require((a.st_dev, a.st_ino) == (b.st_dev, b.st_ino), 'checkpoint_alias_conflict')
        os.unlink(pending, dir_fd=directory)
        os.fsync(directory)


def publish_producer(path, name, value, *, hook=None):
    """Privileges first, READY last. No producer small writes after READY."""
    require(name in ('privileges.json', 'ready.json'), 'invalid_producer_checkpoint')
    raw = canonical(value)
    require(0 < len(raw) <= 4096, 'checkpoint_limit')
    directory = _open_directory(path, os.getuid(), os.getgid(), 0o700)
    try:
        names = _names(directory, 3)
        allowed = {'privileges.json', 'ready.json', PENDING + name}
        require(names <= allowed and name not in names and 'ready.json' not in names,
                'producer_already_published')
        require(name != 'ready.json' or 'privileges.json' in names, 'producer_order')
        # Producer never recovers/restarts this method after an interruption.
        require(not any(x.startswith(PENDING) for x in names), 'producer_publication_uncertain')
        _publish(directory, name, raw, os.getuid(), os.getgid(), 0o600, 4096, hook)
    finally:
        os.close(directory)


class ActionJournal:
    def __init__(self, layout, captured_source_bytes, units, *, owner_uid=0, producer_uid=62401,
                 owner_gid=None, producer_gid=None):
        require(os.geteuid() == owner_uid and set(layout) == {'records', 'witness', 'control', 'data', 'ingress'},
                'guardian_required')
        self.layout = {key: Path(value) for key, value in layout.items()}
        require(len(set(self.layout.values())) == 5, 'duplicate_action_directory')
        self.owner, self.producer = owner_uid, producer_uid
        self.owner_group = owner_uid if owner_gid is None else owner_gid
        self.producer_group = producer_uid if producer_gid is None else producer_gid
        self.source_bytes = captured_source_bytes
        self.reservation = slots.reservation(captured_source_bytes, fixed_records=True)
        require(type(units) is dict and len(units) == 2
                and all(type(raw) is bytes and 0 < len(raw) <= 16_384 for raw in units.values())
                and sum(map(len, units.values())) < captured_source_bytes, 'invalid_unit_reservation')
        self.units = {Path(path): raw for path, raw in units.items()}
        require(len(self.units) == 2 and len({path.stem for path in self.units}) == 1
                and {path.suffix for path in self.units} == {'.service', '.slice'}
                and all(re.fullmatch(r'tsmetadata[0-9a-f]{32}', path.stem) for path in self.units),
                'invalid_action_units')
        self.directories, self.lock = {}, None

    def identity(self, leaf):
        owner = self.producer if leaf in ('data', 'ingress') else self.owner
        group = self.producer_group if leaf in ('data', 'ingress', 'control') else self.owner_group
        return owner, group, 0o750 if leaf == 'control' else 0o700

    def __enter__(self):
        try:
            for leaf, path in self.layout.items():
                self.directories[leaf] = _open_directory(path, *self.identity(leaf))
            self.lock = slots._exclusive(self.directories['witness'], self.owner)
            self.lock.__enter__()
            self.inventory()
            return self
        except BaseException:
            self.__exit__(*__import__('sys').exc_info())
            raise

    def __exit__(self, *error):
        if self.lock is not None:
            self.lock.__exit__(*error)
            self.lock = None
        for fd in self.directories.values():
            os.close(fd)
        self.directories = {}

    def inventory(self):
        require(self.directories and self.lock is not None, 'action_lock_required')
        names, inodes, ordinary = 2, {}, []  # two rendered unit names
        for path, expected in self.units.items():
            require(path.is_absolute() and path.resolve() == path, 'redirected_unit')
            directory = _open_directory(path.parent, self.owner, self.owner_group, 0o755)
            try:
                require(os.stat(path.name, dir_fd=directory, follow_symlinks=False).st_nlink == 1,
                        'unexplained_unit_alias')
                require(_read(directory, path.name, self.owner, self.owner_group, 0o644, 16_384) == expected,
                        'unit_source_changed')
            finally:
                os.close(directory)
        for leaf, fd in self.directories.items():
            owner, group, _ = self.identity(leaf)
            entries = {}
            with os.scandir(fd) as files:
                for entry in files:
                    require(len(entries) < slots.MAX_NAMES, 'action_name_limit')
                    entries[entry.name] = entry.stat(follow_symlinks=False)
            if leaf in ('witness', 'ingress'):
                slots._slot(fd, owner)
            for name, value in entries.items():
                names += 1
                mode = 0o640 if leaf == 'control' else 0o600
                if leaf in ('witness', 'ingress'):
                    require(name in ({slots.FINAL, slots.PENDING, slots.LOCK} if leaf == 'witness'
                                      else {slots.FINAL, slots.PENDING}), 'unexpected_action_name')
                    maximum = 0 if name == slots.LOCK else slots.MAX_OUTPUT
                    aliases = sum((x.st_dev, x.st_ino) == (value.st_dev, value.st_ino) for x in entries.values())
                else:
                    record = name[len(PENDING):] if name.startswith(PENDING) else name
                    require(record in RECORDS and RECORDS[record][0] == leaf, 'unexpected_action_name')
                    maximum = RECORDS[record][1]
                    if name.startswith(PENDING):
                        ordinary.append((leaf, record))
                    aliases = 1 + int((PENDING + record if name == record else record) in entries)
                    if aliases == 2:
                        other = entries[PENDING + record if name == record else record]
                        require((value.st_dev, value.st_ino) == (other.st_dev, other.st_ino), 'checkpoint_alias_conflict')
                require(stat.S_ISREG(value.st_mode) and value.st_uid == owner and value.st_gid == group
                        and stat.S_IMODE(value.st_mode) == mode and value.st_nlink == aliases
                        and value.st_size <= maximum, 'invalid_action_entry')
                key = (value.st_dev, value.st_ino)
                require(key not in inodes or inodes[key] == value.st_size, 'changing_action_entry')
                inodes[key] = value.st_size
        require(len(ordinary) <= 1, 'multiple_checkpoint_temporaries')
        total = sum(inodes.values()) + self.source_bytes
        require(names <= slots.MAX_NAMES and total <= slots.MAX_BYTES, 'action_capacity')
        return {'names': names, 'bytes': total, 'ordinary_pending': ordinary}

    def exists(self, name):
        require(name in RECORDS, 'unknown_checkpoint')
        self.inventory()
        return name in _names(self.directories[RECORDS[name][0]])

    def read(self, name):
        require(name in RECORDS, 'unknown_checkpoint')
        self.inventory()
        leaf, maximum = RECORDS[name]
        owner, group, _ = self.identity(leaf)
        directory = self.directories[leaf]
        raw = _read(directory, name, owner, group, 0o640 if leaf == 'control' else 0o600, maximum, sync=True)
        os.fsync(directory)
        return decode(raw)

    def recover(self, name, validate):
        """Validate and finish the exact saved publication, including pre-link.

        A complete canonical pending record may retain a receipt UUID or first
        acknowledgement unavailable from a later database snapshot. Never
        regenerate that value, or repair a partial/conflicting publication.
        """
        require(name in RECORDS and RECORDS[name][0] != 'data', 'guardian_checkpoint_required')
        self.inventory()
        leaf, maximum = RECORDS[name]
        directory = self.directories[leaf]
        names = _names(directory)
        pending = PENDING + name
        if name not in names and pending not in names:
            return None
        owner, group, _ = self.identity(leaf)
        raw = _read(directory, name if name in names else pending, owner, group,
                    0o640 if leaf == 'control' else 0o600, maximum, sync=True)
        value = decode(raw)
        require(canonical(value) == raw, 'noncanonical_checkpoint')
        validate(value)
        os.fsync(directory)
        if pending in names:
            self.put(name, value)
        return value

    def put(self, name, value, *, hook=None):
        require(name in RECORDS and RECORDS[name][0] != 'data', 'guardian_checkpoint_required')
        leaf, maximum = RECORDS[name]
        raw = canonical(value)
        require(0 < len(raw) <= maximum, 'checkpoint_limit')
        state = self.inventory()
        require(state['ordinary_pending'] in ([], [(leaf, name)]), 'unfinished_action_record')
        owner, group, _ = self.identity(leaf)
        _publish(self.directories[leaf], name, raw, owner, group,
                 0o640 if leaf == 'control' else 0o600, maximum, hook)
        self.inventory()

    def producer_ready(self):
        require(not self.inventory()['ordinary_pending'], 'producer_publication_uncertain')
        value = self.read('ready.json')
        self.read('privileges.json')
        require(not self.inventory()['ordinary_pending'], 'producer_publication_uncertain')
        return value

    def witness(self, validate, *, hook=None):
        self.inventory()

        def checked(step):
            self.inventory()
            slots._step(hook, step)

        raw = slots._recover_locked(self.directories['ingress'], self.directories['witness'], validate,
                                    producer_uid=self.producer, guardian_uid=self.owner, hook=checked)
        self.inventory()
        return raw
