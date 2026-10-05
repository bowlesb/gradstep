"""One paused original-transfer child; portable loopback fixture authority only.

The frozen loader supplies one binary pipe OR one read-only regular input FD.
Neither payload input nor a socket is touched until one exact GO followed by EOF.
There is no spool path, database, parser, retry or child-process capability here.
"""
import fcntl
import os
import re
import select
import stat
import sys

import frozen_context
from protocol import Refused, canonical, clock, clock_ns, decode, digest, require
from original_transport import checked_result, perform, validate_input

MAX_INPUT = 24_576
MAX_CONTROL = 1_024
MAX_RESULT = 4_096


def read_line(deadline, maximum):
    raw = bytearray()
    while not raw.endswith(b'\n'):
        remaining = deadline - clock()
        require(remaining > 0 and select.select([0], [], [], remaining)[0], 'control_deadline')
        part = os.read(0, 1)
        require(part and len(raw) < maximum, 'invalid_control')
        raw.extend(part)
    return decode(bytes(raw))


def emit(value, maximum):
    raw = canonical(value) + b'\n'
    require(len(raw) <= maximum, 'output_limit')
    offset = 0
    while offset < len(raw):
        sent = os.write(1, raw[offset:])
        require(sent > 0, 'control_failed')
        offset += sent


def check_descriptor(value):
    """Inspect modes only. In particular, do not hash/read an upload before GO."""
    fd, mode = frozen_context.data_fd, frozen_context.data_mode
    require(type(fd) is int and fd > 2, 'invalid_descriptor')
    info, flags = os.fstat(fd), fcntl.fcntl(fd, fcntl.F_GETFL)
    if value['request']['kind'] == 'original_upload':
        require(mode == 'input' and stat.S_ISREG(info.st_mode)
                and flags & os.O_ACCMODE == os.O_RDONLY
                and info.st_size == value['request']['candidate_bytes'], 'invalid_descriptor')
    else:
        require(mode == 'output' and stat.S_ISFIFO(info.st_mode)
                and flags & os.O_ACCMODE == os.O_WRONLY
                and flags & os.O_NONBLOCK, 'invalid_descriptor')
    return fd


def main():
    fd = None
    try:
        startup_deadline = clock() + 10
        value = validate_input(read_line(startup_deadline, MAX_INPUT))
        fd = check_descriptor(value)
        input_sha = digest(canonical(value))
        ready = {'format': 'original-transfer-ready-v1', 'attempt_id': value['attempt_id'],
                 'input_sha256': input_sha, 'bundle_sha256': frozen_context.bundle_sha256,
                 'process_id': os.getpid()}
        emit(ready, MAX_CONTROL)
        go = read_line(startup_deadline, MAX_CONTROL)
        require(type(go) is dict and set(go) == {'format', 'execution_id', 'input_sha256',
                'bundle_sha256', 'deadline_ns'} and go['format'] == 'original-transfer-go-v1'
                and go['execution_id'] == value['attempt_id'] and go['input_sha256'] == input_sha
                and go['bundle_sha256'] == frozen_context.bundle_sha256
                and type(go['deadline_ns']) is str
                and re.fullmatch(r'[0-9]{1,20}', go['deadline_ns']), 'invalid_control')
        # A second command, a partial trailing byte or an open control writer
        # is never permission to begin a network request or an input-FD read.
        remaining = startup_deadline - clock()
        require(remaining > 0 and select.select([0], [], [], remaining)[0]
                and os.read(0, 1) == b'', 'invalid_control')
        now, deadline = clock_ns(), int(go['deadline_ns'])
        require(now < deadline <= now + value['useful_ms'] * 1_000_000, 'deadline')
        result = perform(value, input_fd=fd if frozen_context.data_mode == 'input' else None,
                         output_fd=fd if frozen_context.data_mode == 'output' else None,
                         absolute_deadline_ns=deadline)
        # Binary EOF is a framing fact only. The parent also waits for this
        # exact process before it can accept even a valid completion result.
        closing, fd = fd, None
        os.close(closing)
        result = checked_result(canonical(result), value)
        emit(result, MAX_RESULT + 1)
        return 0
    except (Refused, ValueError, TypeError, KeyError, OSError):
        return 2
    except Exception:
        # No provider/raw exception, source text or binary bytes enter stderr.
        return 3
    finally:
        if fd is not None:
            closing, fd = fd, None
            try:
                os.close(closing)
            except OSError:
                pass


if __name__ == '__main__':
    raise SystemExit(main())
