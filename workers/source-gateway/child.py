"""One paused loopback transport child. No database or source-network authority."""
import os
import re
import select
import sys

import frozen_context
from protocol import MAX_INPUT, MAX_OUTPUT, canonical, decode, digest, envelope, require, Refused, clock, clock_ns
from transport import perform


def line(deadline, maximum):
    result = bytearray()
    while not result.endswith(b'\n'):
        remaining = deadline - clock()
        require(remaining > 0 and select.select([sys.stdin.fileno()], [], [], remaining)[0], 'control_deadline')
        part = os.read(sys.stdin.fileno(), 1)
        require(part and len(result) < maximum, 'invalid_control')
        result.extend(part)
    return decode(bytes(result))


def emit(value):
    raw = canonical(value) + b'\n'
    require(len(raw) <= MAX_OUTPUT, 'output_limit')
    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()


def main():
    try:
        deadline = clock() + 15
        value = line(deadline, MAX_INPUT)
        envelope(value)
        source = digest(canonical(value['request']))
        recipe = digest(canonical(frozen_context.manifest))
        emit({'schema_version': 1, 'kind': 'ready', 'child_id': value['attempt_id'],
              'source_sha256': source, 'bundle_sha256': recipe, 'process_id': os.getpid()})
        message = line(deadline, 2048)
        require(type(message) is dict, 'invalid_control')
        if message == {'schema_version': 1, 'kind': 'stop', 'child_id': value['attempt_id']}:
            return 0
        require(set(message) == {'schema_version', 'kind', 'child_id', 'execution_id', 'source_sha256', 'deadline_ns'}
                and message['schema_version'] == 1 and message['kind'] == 'go'
                and message['child_id'] == value['attempt_id'] and message['source_sha256'] == source
                and type(message['execution_id']) is str and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', message['execution_id'])
                and type(message['deadline_ns']) is str and re.fullmatch(r'[0-9]{1,20}', message['deadline_ns']), 'invalid_control')
        # GO is one complete frame followed by EOF. Duplicate/trailing control
        # bytes cannot be left unread while the socket is opened.
        remaining = deadline - clock()
        require(remaining > 0 and select.select([sys.stdin.fileno()], [], [], remaining)[0]
                and os.read(sys.stdin.fileno(), 1) == b'', 'invalid_control')
        limit = int(message['deadline_ns'])
        require(clock_ns() < limit <= clock_ns() + 30_000_000_000, 'deadline')
        result = perform(value, absolute_deadline_ns=limit)
        emit({'schema_version': 1, 'execution_id': message['execution_id'],
              'source_sha256': source, 'result': result})
        return 0
    except (Refused, ValueError, TypeError, KeyError):
        return 2
    except BrokenPipeError:
        return 3


if __name__ == '__main__':
    raise SystemExit(main())
