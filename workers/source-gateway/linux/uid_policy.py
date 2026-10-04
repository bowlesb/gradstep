"""Fixed Linux bootstrap and kernel identity checks. No request parsing or I/O."""
import ctypes
import os
from pathlib import Path
import re
import sys
import uuid

from common import require

SUPERVISOR_UID = 62401
SOURCE_UID = 62402
INITIAL_CAPS = (1 << 6) | (1 << 7) | (1 << 8)  # SETGID, SETUID, SETPCAP
DROP_CAPS = (1 << 6) | (1 << 7)
SECURE_BITS = (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7)
CAP_FIELDS = ('CapInh', 'CapPrm', 'CapEff', 'CapBnd', 'CapAmb')


def _libc():
    require(sys.platform == 'linux', 'linux_required')
    library = ctypes.CDLL(None, use_errno=True)
    library.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    library.prctl.restype = ctypes.c_int
    return library


def prctl(option, argument=0):
    result = _libc().prctl(option, argument, 0, 0, 0)
    if result < 0:
        raise OSError(ctypes.get_errno(), 'privilege_operation_failed')
    return result


def _read(path, maximum=16_384):
    with open(path, 'rb') as stream:
        raw = stream.read(maximum + 1)
    require(len(raw) <= maximum, 'kernel_record_limit')
    return raw.decode('ascii')


def status(pid):
    require(type(pid) is int and 1 < pid < 2_147_483_647, 'invalid_process_id')
    fields = {}
    for line in _read('/proc/' + str(pid) + '/status').splitlines():
        name, separator, value = line.partition(':')
        require(separator and name not in fields, 'invalid_process_status')
        fields[name] = value.strip()
    require(all(name in fields for name in ('Uid', 'Gid', 'Groups', 'Pid', 'PPid', 'Threads',
                                           'NoNewPrivs', 'Seccomp') + CAP_FIELDS), 'missing_process_status')
    ids = {}
    for name in ('Uid', 'Gid'):
        parts = fields[name].split()
        require(len(parts) == 4 and all(re.fullmatch(r'[0-9]{1,10}', x) for x in parts), 'invalid_process_ids')
        ids[name] = list(map(int, parts))
    require(all(re.fullmatch(r'[0-9a-f]{16}', fields[name]) for name in CAP_FIELDS), 'invalid_process_caps')
    return {'pid': int(fields['Pid']), 'parent_pid': int(fields['PPid']),
            'uids': ids['Uid'], 'gids': ids['Gid'], 'groups': list(map(int, fields['Groups'].split())),
            'caps': {name: int(fields[name], 16) for name in CAP_FIELDS},
            'no_new_privs': int(fields['NoNewPrivs']), 'threads': int(fields['Threads']),
            'seccomp': int(fields['Seccomp'])}


def checked_status(pid, uid, *, parent=None):
    value = status(pid)
    require(value['pid'] == pid and value['uids'] == [uid] * 4 and value['gids'] == [uid] * 4
            and value['groups'] == [] and all(x == 0 for x in value['caps'].values())
            and value['no_new_privs'] == 1 and value['threads'] == 1 and value['seccomp'] == 2
            and (parent is None or value['parent_pid'] == parent), 'privilege_boundary_mismatch')
    return value


def self_check(uid):
    value = checked_status(os.getpid(), uid)
    require(prctl(27) == SECURE_BITS and prctl(3) == 0 and prctl(7) == 0 and prctl(39) == 1,
            'securebits_or_dumpable_mismatch')
    return dict(value, securebits=SECURE_BITS, dumpable=0)


def begin_drop():
    """Called only by the captured launcher before it consumes application data."""
    current = status(os.getpid())
    require(current['uids'] == [0] * 4 and current['gids'] == [0] * 4
            and current['threads'] == 1 and current['no_new_privs'] == 1 and current['seccomp'] == 2
            and current['caps'] == {'CapInh': 0, 'CapPrm': INITIAL_CAPS, 'CapEff': INITIAL_CAPS,
                                    'CapBnd': INITIAL_CAPS, 'CapAmb': 0}
            and prctl(27) == 0, 'unexpected_bootstrap_privileges')
    os.setgroups([])
    prctl(28, SECURE_BITS)
    prctl(4, 0)
    maximum = int(_read('/proc/sys/kernel/cap_last_cap', 32).strip())
    require(8 <= maximum <= 63, 'unsupported_capability_range')
    for bit in range(maximum + 1):
        prctl(24, bit)
    require(status(os.getpid())['caps']['CapBnd'] == 0, 'bounding_drop_failed')

    class Header(ctypes.Structure):
        _fields_ = [('version', ctypes.c_uint32), ('pid', ctypes.c_int)]
    class Data(ctypes.Structure):
        _fields_ = [('effective', ctypes.c_uint32), ('permitted', ctypes.c_uint32), ('inheritable', ctypes.c_uint32)]
    library = _libc()
    library.capset.argtypes = [ctypes.POINTER(Header), ctypes.POINTER(Data)]
    library.capset.restype = ctypes.c_int
    header, data = Header(0x20080522, 0), (Data * 2)()
    data[0].effective = data[0].permitted = DROP_CAPS
    if library.capset(ctypes.byref(header), data) != 0:
        raise OSError(ctypes.get_errno(), 'capset_failed')
    require(status(os.getpid())['caps'] == {'CapInh': 0, 'CapPrm': DROP_CAPS, 'CapEff': DROP_CAPS,
                                           'CapBnd': 0, 'CapAmb': 0}, 'active_drop_failed')


def finish_drop():
    os.setgroups([])
    os.setresgid(SUPERVISOR_UID, SUPERVISOR_UID, SUPERVISOR_UID)
    os.setresuid(SUPERVISOR_UID, SUPERVISOR_UID, SUPERVISOR_UID)
    prctl(4, 0)
    return self_check(SUPERVISOR_UID)


def child_check():
    # exec and set-ID transitions may reset dumpability, even with NNP.
    prctl(4, 0)
    return self_check(SOURCE_UID)


def process_identity(pid):
    """Supervisor's actual child, all IDs checked independently of inode owner."""
    raw = _read('/proc/' + str(pid) + '/stat', 4096)
    require(raw.startswith(str(pid) + ' ('), 'invalid_process_stat')
    fields = raw[raw.rfind(')') + 2:].split()
    require(len(fields) >= 20 and re.fullmatch(r'[0-9]{1,20}', fields[19]), 'invalid_process_stat')
    checked_status(pid, SOURCE_UID, parent=os.getpid())
    own_group = _read('/proc/self/cgroup', 4096)
    require(_read('/proc/' + str(pid) + '/cgroup', 4096) == own_group
            and re.fullmatch(r'0::/tsfixture[0-9a-f]{32}\.slice/tsfixture[0-9a-f]{32}\.service\n', own_group),
            'process_scope_mismatch')
    again = _read('/proc/' + str(pid) + '/stat', 4096)
    require(again[again.rfind(')') + 2:].split()[19] == fields[19], 'process_replaced')
    return {'boot_id': str(uuid.UUID(_read('/proc/sys/kernel/random/boot_id', 128).strip())),
            'process_id': pid, 'process_start_id': fields[19]}


def cooperative_stop(child):
    """No cross-UID signal. Unjoined work belongs to the outside scope guardian."""
    if child.stdin is not None and not child.stdin.closed:
        try:
            child.stdin.close()
        except OSError:
            pass
