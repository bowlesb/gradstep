"""Kernel process identity for local fixtures; unsupported platforms refuse."""
import ctypes
import os
from pathlib import Path
import sys
import uuid

from protocol import require


def process_identity(pid):
    require(type(pid) is int and 0 < pid <= 2_147_483_647, 'invalid_process_identity')
    if sys.platform == 'darwin':
        # Xcode SDK sys/proc_info.h: PROC_PIDTBSDINFO=3, proc_bsdinfo.
        class BSDInfo(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in
                        ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid',
                         'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
            _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
            _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
            _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]
        require(ctypes.sizeof(BSDInfo) == 136, 'unsupported_process_identity')
        library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        info = BSDInfo()
        require(library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info)
                and info.pid == pid and info.ppid == os.getpid() and info.uid == os.getuid()
                and info.start_sec > 0 and info.start_usec < 1_000_000, 'unowned_process_identity')
        libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        libc.sysctlbyname.restype = ctypes.c_int
        raw, count = ctypes.create_string_buffer(128), ctypes.c_size_t(128)
        require(libc.sysctlbyname(b'kern.bootsessionuuid', raw, ctypes.byref(count), None, 0) == 0
                and 0 < count.value <= 128, 'unsupported_boot_identity')
        boot = str(uuid.UUID(raw.value.decode('ascii')))
        start = str(info.start_sec * 1_000_000 + info.start_usec)
    elif sys.platform == 'linux':
        boot = str(uuid.UUID(Path('/proc/sys/kernel/random/boot_id').read_text().strip()))
        raw = Path(f'/proc/{pid}/stat').read_text()
        require(len(raw) < 4096 and raw.startswith(str(pid) + ' ('), 'unowned_process_identity')
        fields = raw[raw.rfind(')') + 2:].split()
        require(len(fields) >= 20 and int(fields[1]) == os.getpid()
                and Path(f'/proc/{pid}').stat().st_uid == os.getuid(), 'unowned_process_identity')
        start = fields[19]
    else:
        raise ValueError('unsupported_process_identity')
    require(start.isdigit() and 0 < len(start) <= 20, 'invalid_process_identity')
    return {'boot_id': boot, 'process_id': pid, 'process_start_id': start}
