"""Systemd fixture action: existing paused child, explicitly no SQL grant."""
import hashlib
import os
from pathlib import Path
import re
import sys
import time
import uuid

import frozen_context
from common import canonical, decode, publish, read, require
from paused_child import PausedChild
from protocol import clock, clock_ns


def main():
    session = None
    try:
        root = Path(sys.argv[3])
        value = decode(read(root / 'input.json'))
        require(set(value) == {'schema_version', 'mode', 'attempt_id', 'request', 'fixture'}
                and value['schema_version'] == 1 and value['mode'] == 'loopback_lifecycle_fixture', 'invalid_fixture')
        attempt = str(uuid.UUID(value['attempt_id']))
        require(attempt == value['attempt_id'], 'invalid_attempt')
        invocation = os.environ.get('INVOCATION_ID', '')
        require(re.fullmatch(r'[0-9a-f]{32}', invocation) is not None, 'not_systemd_action')
        session = PausedChild(value['request'], value['fixture'])
        binding = {'schema_version': 1, 'mode': 'loopback_lifecycle_fixture', 'attempt_id': attempt,
                   'child_id': session.value['attempt_id'], 'identity': session.identity,
                   'controller_pid': os.getpid(), 'invocation_id': invocation,
                   'source_sha256': hashlib.sha256(canonical(value['request'])).hexdigest(),
                   'bundle_sha256': hashlib.sha256(canonical(frozen_context.manifest)).hexdigest(),
                   'source_network_enabled': False, 'hosted_admitted': False}
        publish(root / 'data', 'ready.json', binding)
        deadline = clock() + 5
        while clock() < deadline:
            if (root / 'stop.json').exists():
                break
            if (root / 'go.json').exists():
                command = decode(read(root / 'go.json', 4096))
                require(command == {'mode': 'loopback_lifecycle_fixture', 'attempt_id': attempt,
                                    'child_id': binding['child_id'], 'bundle_sha256': binding['bundle_sha256']},
                        'fixture_go_mismatch')
                # This is deliberately not a database grant or production permission.
                session.go(str(uuid.uuid4()), clock_ns() + 8_000_000_000)
                publish(root / 'data', 'sent-go.json', {'attempt_id': attempt, 'sent_go': True})
                report = session.finish(clock_ns() + 8_000_000_000)
                publish(root / 'data', 'witness.json', report)
                return 0
            time.sleep(.01)
        publish(root / 'data', 'witness.json', session.stop())
        return 0
    except (ValueError, KeyError, OSError):
        return 2
    finally:
        if session is not None:
            session.stop()


if __name__ == '__main__':
    raise SystemExit(main())
