"""Retire a trusted, non-detaching Linux helper session without reusing its PID.

The caller owns all of this process's children and enables subreaping before
launch. This is process cleanup, never a transport or database receipt.
"""
import ctypes
import os
import re
import signal
import sys
import time


def require(value, code):
    if not value:
        raise ValueError(code)


def clock_ns():
    require(sys.platform == 'linux' and hasattr(time, 'CLOCK_BOOTTIME'), 'linux_clock_required')
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def controller_children():
    with open('/proc/self/task/' + str(os.getpid()) + '/children', 'rb') as stream:
        raw = stream.read(4097)
    require(len(raw) <= 4096, 'controller_children_unresolved')
    values = raw.split()
    require(len(values) <= 64 and all(re.fullmatch(rb'[1-9][0-9]{0,9}', value) for value in values),
            'controller_children_unresolved')
    return list(map(int, values))


def subreaper(enabled):
    require(type(enabled) is bool and sys.platform == 'linux', 'linux_subreaper_required')
    library = ctypes.CDLL(None, use_errno=True)
    library.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    library.prctl.restype = ctypes.c_int
    observed = ctypes.c_int()
    for option, argument in ((36, int(enabled)), (37, ctypes.addressof(observed))):
        if library.prctl(option, argument, 0, 0, 0) < 0:
            raise OSError(ctypes.get_errno(), 'controller_subreaper_unavailable')
    require(observed.value == int(enabled), 'controller_subreaper_unavailable')


def retire_controller(child, *, grace=2):
    """Keep the original leader unreaped until the sole group signal.

    Adopted descendants outside this session, failed observations or unfinished
    waits are unresolved. A leader wait alone never proves descendant retirement.
    """
    require(child.returncode is None, 'controller_anchor_already_reaped')
    deadline = clock_ns() + grace * 1_000_000_000
    while os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None and clock_ns() < deadline:
        time.sleep(.01)
    require(os.getpgid(child.pid) == child.pid and os.getsid(child.pid) == child.pid,
            'controller_session_changed')
    # The unreaped original leader (alive or zombie) prevents PGID reuse here.
    os.killpg(child.pid, signal.SIGKILL)
    deadline = clock_ns() + 2_000_000_000
    while True:
        for pid in controller_children():
            require(os.getpgid(pid) == child.pid and os.getsid(pid) == child.pid,
                    'controller_descendant_escaped')
        try:
            pid, status = os.waitpid(-child.pid, os.WNOHANG)
        except ChildProcessError:
            require(child.returncode is not None and not controller_children(), 'controller_children_unresolved')
            return child.returncode
        if pid == child.pid:
            child.returncode = os.waitstatus_to_exitcode(status)
        require(clock_ns() < deadline, 'controller_children_unresolved')
        if pid == 0:
            time.sleep(.01)
