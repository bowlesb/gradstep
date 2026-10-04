"""Short root bootstrap, then distinct credential-free supervisor. Loopback only."""
import errno
import os
from pathlib import Path
import re
import selectors
import sys
import time
import uuid

import frozen_context
from common import canonical, decode, publish, read, require
from paused_child import PausedChild
from protocol import clock, clock_ns, digest
import uid_policy
from witness_slots import publish_ingress


def _probe_result(session):
    output = bytearray()
    deadline = clock() + 2
    session.child.stdin.close()
    with selectors.DefaultSelector() as selector:
        selector.register(session.child.stdout, selectors.EVENT_READ)
        while selector.get_map():
            require(clock() < deadline and len(output) < 8192, 'probe_limit')
            for key, _ in selector.select(min(.02, max(0, deadline - clock()))):
                part = os.read(key.fileobj.fileno(), 8193 - len(output))
                if not part:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(part)
    require(session.child.wait(timeout=max(.01, deadline - clock())) == 0, 'probe_child_failed')
    result = decode(bytes(output))
    require(result['kind'] == 'linux_negative_probe' and result['source_network_enabled'] is False,
            'invalid_probe_result')
    return result


def main():
    session = None
    phase = 20
    try:
        require(len(sys.argv) == 4, 'invalid_arguments')
        root = Path(sys.argv[3])
        require(re.fullmatch(r'/run/timestep-source-fixture/[0-9a-f]{32}', str(root)), 'invalid_scope_path')
        probe = sys.argv[2] == 'linux_probe_launcher'
        phase = 21
        uid_policy.begin_drop()
        argv = [sys.executable, '-I', '-S', '-B', str(frozen_context.root / 'bootstrap.py'),
                str(frozen_context.root), 'linux_source_probe' if probe else 'linux_source', str(root)]
        phase = 22
        session = PausedChild.spawn_only(argv=argv, user=uid_policy.SOURCE_UID, group=uid_policy.SOURCE_UID,
                                        identity_reader=uid_policy.process_identity,
                                        stop_child=uid_policy.cooperative_stop)
        phase = 23
        identity = uid_policy.finish_drop()
        # The first application read/write follows the verified permanent drop.
        if probe:
            phase = 24
            value = _probe_result(session)
            publish(root / 'data', 'probe.json', {'supervisor': identity, 'source': value})
            return 0
        phase = 25
        value = decode(read(root / 'control' / 'input.json'))
        require(set(value) == {'schema_version', 'mode', 'attempt_id', 'request', 'fixture'}
                and value['schema_version'] == 1 and value['mode'] == 'linux_uid_ingress_fixture', 'invalid_fixture')
        attempt = str(uuid.UUID(value['attempt_id']))
        require(attempt == value['attempt_id'] and uuid.UUID(attempt).hex == root.name, 'invalid_attempt')
        invocation = os.environ.get('INVOCATION_ID', '')
        require(re.fullmatch(r'[0-9a-f]{32}', invocation), 'not_systemd_action')
        phase = 26
        session.handshake(value['request'], value['fixture'])
        try:
            os.kill(session.child.pid, 0)
            raise ValueError('unexpected_cross_uid_signal_authority')
        except OSError as error:
            require(error.errno == errno.EPERM, 'unexpected_signal_errno')
        phase = 27
        publish(root / 'data', 'privileges.json', {'supervisor': identity, 'cross_uid_signal_errno': errno.EPERM})
        binding = {'schema_version': 1, 'mode': 'linux_uid_ingress_fixture', 'attempt_id': attempt,
                   'child_id': session.value['attempt_id'], 'identity': session.identity,
                   'controller_pid': os.getpid(), 'invocation_id': invocation,
                   'source_sha256': digest(canonical(value['request'])),
                   'bundle_sha256': digest(canonical(frozen_context.manifest)),
                   'source_network_enabled': False, 'hosted_admitted': False}
        publish(root / 'data', 'ready.json', binding)

        class StopFlag:
            def is_set(self):
                return (root / 'control' / 'stop.json').exists()

        cancellation = StopFlag()
        deadline = clock() + 5
        while clock() < deadline:
            if cancellation.is_set():
                break
            if (root / 'control' / 'go.json').exists():
                command = decode(read(root / 'control' / 'go.json', 4096))
                require(command == {'mode': 'linux_uid_ingress_fixture', 'attempt_id': attempt,
                                    'child_id': binding['child_id'], 'bundle_sha256': binding['bundle_sha256']},
                        'fixture_go_mismatch')
                session.go(str(uuid.uuid4()), clock_ns() + 8_000_000_000, cancelled=cancellation)
                report = session.finish(clock_ns() + 8_000_000_000, cancelled=cancellation)
                publish_ingress(root / 'ingress', canonical(report))
                return 0
            time.sleep(.01)
        publish_ingress(root / 'ingress', canonical(session.stop()))
        return 0
    except (ValueError, KeyError, OSError) as error:
        # Fixed, secret-free diagnostic for the local prerequisite's operator.
        # Never print exception text or application/transport input.
        report = {'schema_version': 1, 'kind': 'prerequisite_failure', 'phase': phase,
                  'errno': error.errno if isinstance(error, OSError) else None}
        if phase == 21:
            report['bootstrap_status'] = uid_policy.status(os.getpid())
            report['securebits'] = uid_policy.prctl(27)
        os.write(2, canonical(report) + b'\n')
        return phase  # Finite phase diagnostics, never application data or credentials.
    finally:
        # A failed cross-UID wait never authorizes this process to signal/restart.
        if session is not None:
            uid_policy.cooperative_stop(session.child)
