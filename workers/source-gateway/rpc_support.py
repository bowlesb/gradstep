"""Finite RPC vocabulary and pipe transport, independent of database credentials."""
import os
import selectors
import subprocess
import time

from protocol import require, Refused

EXECUTOR = 'science_reader_metadata_executor'
OBSERVER = 'science_reader_execution_observer'
ADMITTER = 'science_reader_executor_admitter'
RPCS = {
    'worker_metadata_authority_state': (EXECUTOR, ()),
    'worker_metadata_execution_state': (EXECUTOR, ('p_job_id', 'p_claim_id')),
    'worker_claim_metadata_stage_v2': (EXECUTOR, ('p_job_id', 'p_claim_id', 'p_environment', 'p_executor_binding')),
    'worker_record_metadata_quiescence': (OBSERVER, ('p_attempt_id', 'p_receipt_id', 'p_resource', 'p_evidence_kind', 'p_facts')),
    'worker_finish_metadata_stage_v2': (EXECUTOR, ('p_job_id', 'p_claim_id', 'p_generation', 'p_attempt_id', 'p_body_sha256', 'p_result')),
    'worker_fail_metadata_stage_v2': (EXECUTOR, ('p_job_id', 'p_claim_id', 'p_generation', 'p_attempt_id', 'p_error_code', 'p_retryable')),
}


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def bounded(command, raw, *, timeout=5, maximum=65536, environment, cwd=None):
    """Bound actual pipe bytes; expose output only after exact subprocess exit."""
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             close_fds=True, env=environment, cwd=cwd)
    sent = 0
    output, errors = bytearray(), bytearray()
    failed = False
    deadline = time.monotonic() + timeout
    stop_deadline = None
    try:
        with selectors.DefaultSelector() as selector:
            for pipe, mode, label in ((child.stdin, selectors.EVENT_WRITE, 'in'),
                                      (child.stdout, selectors.EVENT_READ, 'out'),
                                      (child.stderr, selectors.EVENT_READ, 'err')):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, mode, label)
            while selector.get_map() or child.poll() is None:
                now = time.monotonic()
                if stop_deadline is None and (now >= deadline or failed):
                    failed = True
                    if child.poll() is None:
                        child.kill()
                    stop_deadline = now + .5
                if stop_deadline is not None and now >= stop_deadline:
                    break
                for key, _ in selector.select(.02):
                    if key.data == 'in':
                        try:
                            sent += os.write(key.fileobj.fileno(), raw[sent:sent + 4096])
                        except BrokenPipeError:
                            sent = len(raw)
                        if sent == len(raw):
                            selector.unregister(key.fileobj); key.fileobj.close()
                    else:
                        part = os.read(key.fileobj.fileno(), 16384)
                        if not part:
                            selector.unregister(key.fileobj); key.fileobj.close(); continue
                        target, limit = (output, maximum) if key.data == 'out' else (errors, 4096)
                        if len(target) + len(part) > limit:
                            failed = True
                        elif not failed:
                            target.extend(part)
        code = child.wait(timeout=0)
        require(not failed and code == 0, 'subprocess_ack_unknown')
        return bytes(output)
    except (subprocess.TimeoutExpired, OSError):
        raise Refused('subprocess_ack_unknown') from None
    finally:
        if child.poll() is None:
            child.kill()
        try:
            child.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            # No subprocess result/commit acknowledgement is exposed.
            pass
        for pipe in (child.stdin, child.stdout, child.stderr):
            if not pipe.closed:
                pipe.close()
