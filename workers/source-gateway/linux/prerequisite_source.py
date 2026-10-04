"""Captured source entry; every path checks the permanent unprivileged identity."""
import ctypes
import errno
import os
from pathlib import Path
import socket
import sys

import child
from common import require
import uid_policy


def main():
    uid_policy.child_check()
    return child.main()


def probe_main():
    """Finite kernel-negative fixture. No GO, socket connection or credential."""
    identity = uid_policy.child_check()
    require(os.uname().machine == 'aarch64', 'unreviewed_probe_abi')
    root = Path(sys.argv[3])
    checks = {}

    def denied(name, action, allowed=(errno.EPERM, errno.EACCES, errno.EROFS)):
        try:
            value = action()
            if hasattr(value, 'close'):
                value.close()
            raise ValueError('negative_probe_allowed_' + name)
        except OSError as error:
            require(error.errno in allowed, 'unexpected_probe_errno_' + name)
            checks[name] = error.errno

    denied('setresuid_root', lambda: os.setresuid(0, 0, 0), (errno.EPERM,))
    denied('setresgid_root', lambda: os.setresgid(0, 0, 0), (errno.EPERM,))
    denied('supplementary_groups', lambda: os.setgroups([0]), (errno.EPERM,))
    denied('securebits_unlock', lambda: uid_policy.prctl(28, 0), (errno.EPERM,))
    denied('ambient_raise', lambda: uid_policy.prctl(47, 2), (errno.EPERM,))
    denied('guardian_path', lambda: open(root / 'observer' / 'private.json', 'rb'))
    denied('supervisor_control', lambda: open(root / 'control' / 'input.json', 'rb'))
    denied('supervisor_fd', lambda: open('/proc/' + str(os.getppid()) + '/fd/0', 'rb'))
    group = Path('/proc/self/cgroup').read_text().strip()[3:]
    denied('cgroup_write', lambda: open('/sys/fs/cgroup' + group + '/cgroup.procs', 'w'))
    denied('unix_socket', lambda: socket.socket(socket.AF_UNIX), (errno.EPERM, errno.EAFNOSUPPORT))
    denied('socketpair', lambda: socket.socketpair(), (errno.EPERM,))
    library = ctypes.CDLL(None, use_errno=True)
    library.syscall.restype = ctypes.c_long
    # Exact Linux aarch64 syscall numbers; deliberately invalid arguments make
    # absent filtering return a different error, never issue useful work.
    for name, number in (('io_uring_setup', 425), ('io_uring_enter', 426), ('io_uring_register', 427),
                         ('ptrace', 117), ('process_vm_readv', 270), ('process_vm_writev', 271),
                         ('pidfd_getfd', 438)):
        ctypes.set_errno(0)
        result = library.syscall(ctypes.c_long(number), ctypes.c_long(-1), ctypes.c_long(0),
                                 ctypes.c_long(0), ctypes.c_long(0), ctypes.c_long(0), ctypes.c_long(0))
        require(result == -1 and ctypes.get_errno() == errno.EPERM, 'syscall_filter_missing_' + name)
        checks[name] = ctypes.get_errno()
    try:
        pid = os.fork()
    except OSError as error:
        require(error.errno == errno.EAGAIN, 'unexpected_task_limit_errno')
        checks['extra_task'] = error.errno
    else:
        if pid == 0:
            os._exit(99)
        os.waitpid(pid, 0)
        raise ValueError('extra_task_was_allowed')
    child.emit({'schema_version': 1, 'kind': 'linux_negative_probe', 'identity': identity,
                'checks': checks, 'source_network_enabled': False, 'hosted_admitted': False})
    return 0
