"""Local fixture supervisor. There is intentionally no live or database adapter."""
import base64
import binascii
import math
import os
from pathlib import Path
import queue
import selectors
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from protocol import (MAX_BODY, MAX_INPUT, MAX_OUTPUT, MAX_STDERR, MAX_PROTOCOL,
                      MAX_USEFUL_MS, MAX_CLOSE_MS, CLEANUP_MS, STOP_GRACE_MS, Refused, require,
                      canonical, decode, digest, envelope, target)

from child_contract import _close_pipes, _stop, _joined, checked_result

_ACTIVE = threading.Lock()
_RECONCILE = threading.Lock()
_UNRESOLVED = None
_SOURCE = Path(__file__).resolve().parent
def reconcile_fixture():
    """Boundedly stop/join only the exact retained fixture child, never start I/O.

    This process-local handle is not durable across supervisor failure and is
    not a database observer credential or a production reconciliation protocol.
    """
    global _UNRESOLVED
    require(_RECONCILE.acquire(blocking=False), 'fixture_busy')
    try:
        pending = _UNRESOLVED
        if pending is None:
            return {'schema_version': 1, 'outcome': 'nothing_pending', 'child': None,
                    'owned_process_retired': False, 'source_network_enabled': False,
                    'hosted_admitted': False}
        child = pending['child']
        _stop(child)
        returncode = _joined(child, min(STOP_GRACE_MS, CLEANUP_MS) / 1000)
        _close_pipes(child)
        retired = returncode is not None
        report = dict(pending['report'], outcome='retired_after_reconciliation' if retired else 'unresolved',
                      child={'pid': child.pid, 'returncode': returncode}, result=None,
                      owned_process_retired=retired,
                      retirement_witness='parent_waitpid' if retired else None)
        if retired:
            _UNRESOLVED = None
            _ACTIVE.release()
        return report
    finally:
        _RECONCILE.release()


def run_fixture(request, fixture, *, useful_ms=MAX_USEFUL_MS, close_ms=MAX_CLOSE_MS,
                cancelled=None, started=None):
    """Run one fixed child. `started` is an optional bounded diagnostic Queue.

    No value supplied here is a production grant. Cancellation retires the child
    through a real waitpid witness; a caller losing this parent has no witness.
    """
    global _UNRESOLVED
    value = {'mode': 'loopback_fixture_v1', 'attempt_id': str(uuid.uuid4()), 'request': request,
             'fixture': fixture, 'useful_ms': useful_ms, 'close_ms': close_ms}
    envelope(value)
    encoded = canonical(value)
    require(len(encoded) <= MAX_INPUT, 'input_limit')
    # Own all values before waiting; caller mutation cannot change a launched
    # request's identity, limits or expected result binding.
    value = decode(encoded)
    envelope(value)
    request = value['request']
    require(cancelled is None or isinstance(cancelled, threading.Event), 'invalid_input')
    require(started is None or isinstance(started, queue.Queue) and started.maxsize == 1, 'invalid_input')
    require(_ACTIVE.acquire(blocking=False), 'fixture_busy')
    child = None
    launched = time.monotonic()
    stop_grace = min(STOP_GRACE_MS, CLEANUP_MS) / 1000
    # Bound startup/reporting and post-stop cleanup inside one allowance.
    # This fixture protocol has no pre-grant READY/GO deadline exchange yet.
    total_deadline = launched + (useful_ms + close_ms + CLEANUP_MS) / 1000
    work_deadline = total_deadline - stop_grace
    retained = False
    recipe = None
    stdout, stderr = bytearray(), bytearray()
    outcome = None
    try:
        if cancelled is not None and cancelled.is_set():
            return {'schema_version': 1, 'outcome': 'cancelled_before_start', 'result': None,
                    'child': None, 'owned_process_retired': False, 'source_network_enabled': False,
                    'hosted_admitted': False}
        # Capture the exact child recipe before execution; neither imports nor
        # working directory consult mutable application code or user site paths.
        captured = {name: (_SOURCE / name).read_bytes() for name in ('protocol.py', 'transport.py')}
        require(all(0 < len(raw) <= 65_536 for raw in captured.values()), 'invalid_child_recipe')
        recipe = digest(canonical({name: digest(raw) for name, raw in captured.items()}))
        with tempfile.TemporaryDirectory(prefix='science-reader-source-fixture-') as directory:
            snapshot = Path(directory)
            for name, raw in captured.items():
                (snapshot / name).write_bytes(raw)
                (snapshot / name).chmod(0o400)
            # -I excludes user/env/current-dir imports; -S also skips system
            # site/.pth hooks. The only added path is the captured recipe.
            bootstrap = 'import runpy,sys;sys.path.insert(0,sys.argv[1]);runpy.run_path(sys.argv[1]+"/transport.py",run_name="__main__")'
            child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c', bootstrap, directory],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     close_fds=True, start_new_session=True, cwd=directory,
                                     env={'LC_ALL': 'C'})
            if started is not None:
                try:
                    started.put_nowait({'pid': child.pid, 'attempt_id': value['attempt_id']})
                except queue.Full:
                    pass
            sent = 0
            stop_deadline = None
            with selectors.DefaultSelector() as selector:
                for pipe, mode, label in ((child.stdin, selectors.EVENT_WRITE, 'stdin'),
                                          (child.stdout, selectors.EVENT_READ, 'stdout'),
                                          (child.stderr, selectors.EVENT_READ, 'stderr')):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, mode, label)
                while selector.get_map() or child.poll() is None:
                    now = time.monotonic()
                    if outcome is None and cancelled is not None and cancelled.is_set():
                        outcome = 'cancelled'
                    if outcome is None and now >= work_deadline:
                        outcome = 'watchdog'
                    if outcome is not None and stop_deadline is None:
                        stop_deadline = min(total_deadline, now + stop_grace)
                        _stop(child)
                    if stop_deadline is not None and now >= stop_deadline:
                        break
                    phase_deadline = stop_deadline if stop_deadline is not None else work_deadline
                    for key, _ in selector.select(min(0.02, max(0, phase_deadline - now))):
                        pipe = key.fileobj
                        if key.data == 'stdin':
                            try:
                                sent += os.write(pipe.fileno(), encoded[sent:sent + 4096])
                            except BrokenPipeError:
                                sent = len(encoded)
                            if sent == len(encoded):
                                selector.unregister(pipe)
                                pipe.close()
                        else:
                            chunk = os.read(pipe.fileno(), 16_384)
                            if not chunk:
                                selector.unregister(pipe)
                                pipe.close()
                                continue
                            output, cap = (stdout, MAX_OUTPUT) if key.data == 'stdout' else (stderr, MAX_STDERR)
                            if len(output) + len(chunk) > cap:
                                outcome = 'output_limit'
                                # Continue draining bounded chunks while the
                                # killed child exits, without retaining excess.
                            elif outcome != 'output_limit':
                                output.extend(chunk)
            # This exact Popen object owns the child identity. A JSON closed
            # field, elapsed deadline or server EOF never substitutes for wait.
            returncode = _joined(child)
            result = None
            if returncode is None:
                outcome = 'unresolved'
            elif outcome is None:
                if returncode != 0 or stderr:
                    outcome = 'child_exit'
                else:
                    try:
                        result = checked_result(bytes(stdout), value)
                        outcome = 'completed'
                    except (Refused, TypeError, ValueError):
                        outcome = 'invalid_output'
            report = {'schema_version': 1, 'mode': 'loopback_fixture_v1',
                    'attempt_id': value['attempt_id'], 'request_sha256': digest(canonical(request)),
                    'child_recipe_sha256': recipe, 'outcome': outcome, 'result': result,
                    'child': {'pid': child.pid, 'returncode': returncode},
                    'owned_process_retired': returncode is not None,
                    'retirement_witness': 'parent_waitpid' if returncode is not None else None,
                    'elapsed_ms': round((time.monotonic() - launched) * 1000, 3),
                    'source_network_enabled': False, 'hosted_admitted': False}
            if returncode is None:
                # Returned diagnostics are caller-owned. Never let a caller
                # rewrite the retained identity used by later reconciliation.
                _UNRESOLVED = {'child': child, 'report': decode(canonical(report))}
                retained = True
            return report
    finally:
        if child is not None:
            if not retained:
                _stop(child)
                returncode = _joined(child, min(stop_grace,
                                               max(0, total_deadline - time.monotonic())))
                if returncode is None:
                    # Unexpected caller/runtime errors also keep the lane held
                    # when the exact child cannot yet be joined.
                    _UNRESOLVED = {'child': child, 'report': {
                        'schema_version': 1, 'mode': 'loopback_fixture_v1',
                        'attempt_id': value['attempt_id'], 'request_sha256': digest(canonical(request)),
                        'child_recipe_sha256': recipe, 'outcome': 'unresolved', 'result': None,
                        'child': {'pid': child.pid, 'returncode': None},
                        'owned_process_retired': False, 'retirement_witness': None,
                        'elapsed_ms': round((time.monotonic() - launched) * 1000, 3),
                        'source_network_enabled': False, 'hosted_admitted': False}}
                    retained = True
            _close_pipes(child)
        if not retained:
            _ACTIVE.release()
