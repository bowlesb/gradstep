"""Parent-owned READY/GO session for an exact frozen loopback-only child."""
import os
import selectors
import subprocess
import uuid

import frozen_context
from frozen import command
from identity import process_identity
from protocol import MAX_INPUT, MAX_OUTPUT, MAX_STDERR, canonical, decode, digest, envelope, require, Refused, clock, clock_ns
from supervisor import checked_result, _stop, _joined, _close_pipes


class PausedChild:
    def __init__(self, request, fixture):
        self.value = decode(canonical({'mode': 'loopback_fixture_v1', 'attempt_id': str(uuid.uuid4()),
                                     'request': request, 'fixture': fixture, 'useful_ms': 30_000, 'close_ms': 0}))
        envelope(self.value)
        raw = canonical(self.value) + b'\n'
        require(len(raw) <= MAX_INPUT, 'input_limit')
        self.child = subprocess.Popen(command(frozen_context.root, 'child'), stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
                                      start_new_session=True, cwd=frozen_context.root, env={'LC_ALL': 'C'})
        self.identity = None
        self.sent_go = False
        self.execution_id = None
        self.report = None
        try:
            for pipe in (self.child.stdin, self.child.stdout, self.child.stderr):
                os.set_blocking(pipe.fileno(), False)
            deadline = clock() + 5
            self._write(raw, deadline)
            ready = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(self.child.stdout, selectors.EVENT_READ)
                while not ready.endswith(b'\n'):
                    require(clock() < deadline and len(ready) <= 1024, 'ready_deadline')
                    for _, _ in selector.select(min(.02, max(0, deadline - clock()))):
                        piece = os.read(self.child.stdout.fileno(), 1025 - len(ready))
                        require(piece, 'invalid_ready')
                        ready.extend(piece)
            expected = {'schema_version': 1, 'kind': 'ready', 'child_id': self.value['attempt_id'],
                        'source_sha256': digest(canonical(request)), 'bundle_sha256': digest(canonical(frozen_context.manifest)),
                        'process_id': self.child.pid}
            require(decode(bytes(ready)) == expected, 'invalid_ready')
            self.identity = process_identity(self.child.pid)
            require(self.child.poll() is None, 'child_unavailable')
        except BaseException:
            self.stop()
            raise

    def _write(self, raw, deadline):
        sent = 0
        with selectors.DefaultSelector() as selector:
            selector.register(self.child.stdin, selectors.EVENT_WRITE)
            while sent < len(raw):
                require(clock() < deadline, 'control_deadline')
                for _, _ in selector.select(min(.02, max(0, deadline - clock()))):
                    sent += os.write(self.child.stdin.fileno(), raw[sent:sent + 4096])

    def go(self, execution_id, deadline_ns, *, cancelled=None):
        require(not self.sent_go and self.report is None and self.child.poll() is None
                and process_identity(self.child.pid) == self.identity, 'child_identity_changed')
        require(type(deadline_ns) is int and deadline_ns > clock_ns(), 'deadline')
        require(cancelled is None or not cancelled.is_set(), 'cancelled')
        self.sent_go = True  # Mark uncertainty BEFORE the first possible write.
        self.execution_id = execution_id
        raw = canonical({'schema_version': 1, 'kind': 'go', 'child_id': self.value['attempt_id'],
                         'source_sha256': digest(canonical(self.value['request'])),
                         'execution_id': execution_id, 'deadline_ns': str(deadline_ns)}) + b'\n'
        self._write(raw, min(deadline_ns / 1e9, clock() + 1))
        self.child.stdin.close()

    def stop(self):
        _stop(self.child)
        return self.finish(clock_ns(), stopped=True)

    def finish(self, deadline_ns, *, cancelled=None, stopped=False):
        if self.report is not None and self.report['owned_process_retired']:
            return decode(canonical(self.report))
        output, error = bytearray(), bytearray()
        stop_deadline = clock() + .5 if stopped else None
        outcome = 'stopped' if stopped else 'completed'
        with selectors.DefaultSelector() as selector:
            for pipe, label in ((self.child.stdout, 'stdout'), (self.child.stderr, 'stderr')):
                if not pipe.closed:
                    selector.register(pipe, selectors.EVENT_READ, label)
            while selector.get_map() or self.child.poll() is None:
                now = clock()
                if stop_deadline is None and (clock_ns() >= deadline_ns or cancelled is not None and cancelled.is_set()):
                    outcome = 'stopped'
                    _stop(self.child)
                    stop_deadline = now + .5
                if stop_deadline is not None and now >= stop_deadline:
                    break
                limit = stop_deadline if stop_deadline is not None else deadline_ns / 1e9
                for key, _ in selector.select(min(.02, max(0, limit - now))):
                    part = os.read(key.fileobj.fileno(), 16384)
                    if not part:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    target, bound = (output, MAX_OUTPUT) if key.data == 'stdout' else (error, MAX_STDERR)
                    if len(target) + len(part) > bound:
                        if stop_deadline is None:
                            stop_deadline = clock() + .5
                        _stop(self.child)
                        outcome = 'output_limit'
                    elif outcome != 'output_limit':
                        target.extend(part)
        code = _joined(self.child)
        _close_pipes(self.child)
        result = None
        if code is None:
            outcome = 'unresolved'
        elif outcome == 'completed' and self.sent_go and code == 0 and not error:
            try:
                parsed = decode(bytes(output))
                require(set(parsed) == {'schema_version', 'execution_id', 'source_sha256', 'result'}
                        and parsed['schema_version'] == 1 and parsed['execution_id'] == self.execution_id
                        and parsed['source_sha256'] == digest(canonical(self.value['request'])), 'invalid_output')
                result = checked_result(canonical(parsed['result']), self.value)
            except (Refused, TypeError, ValueError, KeyError):
                outcome = 'invalid_output'
        elif outcome == 'completed':
            outcome = 'child_exit'
        self.report = {'schema_version': 1, 'outcome': outcome, 'identity': self.identity,
                       'child_id': self.value['attempt_id'], 'source_sha256': digest(canonical(self.value['request'])),
                       'execution_id': self.execution_id, 'sent_go': self.sent_go,
                       'returncode': code, 'owned_process_retired': code is not None,
                       'retirement_witness': 'parent_waitpid' if code is not None else None,
                       'disposition': 'exited' if code is not None and code >= 0 else 'killed', 'result': result}
        return decode(canonical(self.report))
