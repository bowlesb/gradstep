"""Shared child join helpers and strict bounded transport-response validation."""
import base64
import binascii
import math
import subprocess

from protocol import (MAX_BODY, MAX_OUTPUT, MAX_PROTOCOL, MAX_USEFUL_MS, MAX_CLOSE_MS,
                      CLEANUP_MS, Refused, require, canonical, decode, digest, target)

_REASONS = frozenset(('transport', 'deadline', 'tls_identity', 'http_truncated', 'protocol_error',
                     'body_limit', 'header_limit', 'protocol_limit', 'unsupported_status',
                     'unsupported_encoding', 'ambiguous_framing', 'redirect', 'unsupported_chunk_syntax',
                     'tls_truncated', 'extra_protocol_data', 'socket_ownership', 'invalid_request'))
_KEYS = frozenset(('schema_version', 'mode', 'attempt_id', 'request_sha256', 'target', 'kind', 'reason',
                   'status', 'framing', 'framing_complete', 'tls_peer_close', 'body_base64', 'body_sha256',
                   'body_bytes', 'protocol_bytes_received', 'retry_after_seconds', 'retry_after_kind', 'local_cleanup',
                   'elapsed_ms', 'source_network_enabled'))


def _close_pipes(child):
    for pipe in (child.stdin, child.stdout, child.stderr):
        if pipe is not None and not pipe.closed:
            try:
                pipe.close()
            except OSError:
                pass  # The exact child exit, not pipe cleanup, is the witness.


def _stop(child):
    if child.poll() is None:
        try:
            child.kill()
        except OSError:
            pass  # A rejected kill is not evidence of retirement.


def _joined(child, timeout=0):
    try:
        return child.wait(timeout=max(0, timeout))
    except subprocess.TimeoutExpired:
        return None


def checked_result(raw, value):
    require(type(raw) is bytes and len(raw) <= MAX_OUTPUT, 'invalid_output')
    result = decode(raw)
    require(type(result) is dict and set(result) == _KEYS, 'invalid_output')
    require(result['schema_version'] == 1 and type(result['schema_version']) is int
            and result['mode'] == 'loopback_fixture_v1' and result['source_network_enabled'] is False,
            'invalid_output')
    require(result['attempt_id'] == value['attempt_id']
            and result['request_sha256'] == digest(canonical(value['request']))
            and result['target'] == target(value['request']), 'invalid_output')
    require(result['status'] is None or type(result['status']) is int and 200 <= result['status'] <= 599, 'invalid_output')
    require(result['framing'] in (None, 'content_length', 'chunked', 'close_delimited', 'no_body'), 'invalid_output')
    require(type(result['framing_complete']) is bool and result['tls_peer_close'] in ('not_observed', 'abrupt', 'clean_tls'), 'invalid_output')
    require(type(result['protocol_bytes_received']) is int and 0 <= result['protocol_bytes_received'] <= MAX_PROTOCOL + 1, 'invalid_output')
    require(type(result['retry_after_seconds']) is int and 0 <= result['retry_after_seconds'] <= 86_400, 'invalid_output')
    require(result['retry_after_kind'] in ('absent', 'delta_seconds', 'unsupported')
            and (result['retry_after_kind'] != 'absent' or result['retry_after_seconds'] == 0), 'invalid_output')
    cleanup = result['local_cleanup']
    require(type(cleanup) is dict and set(cleanup) == {'http_file_closed', 'socket_closed'}
            and all(type(item) is bool for item in cleanup.values()), 'invalid_output')
    require(type(result['elapsed_ms']) in (float, int) and math.isfinite(result['elapsed_ms'])
            and 0 <= result['elapsed_ms'] <= MAX_USEFUL_MS + MAX_CLOSE_MS + CLEANUP_MS, 'invalid_output')
    if result['kind'] == 'complete':
        require(result['reason'] is None and result['framing_complete'] and result['framing'] is not None
                and result['status'] is not None and not 300 <= result['status'] <= 399, 'invalid_output')
        require(result['framing'] != 'close_delimited' or result['tls_peer_close'] == 'clean_tls', 'invalid_output')
        require(type(result['body_base64']) is str and len(result['body_base64']) <= 4 * ((MAX_BODY + 2) // 3), 'invalid_output')
        try:
            body = base64.b64decode(result['body_base64'], validate=True)
        except (binascii.Error, ValueError):
            raise Refused('invalid_output') from None
        require(type(result['body_bytes']) is int and result['body_bytes'] == len(body)
                and len(body) <= value['request']['byte_ceiling']
                and result['body_sha256'] == digest(body)
                and result['protocol_bytes_received'] >= len(body), 'invalid_output')
    else:
        require(result['kind'] == 'uncertain' and result['reason'] in _REASONS
                and all(result[key] is None for key in ('body_base64', 'body_bytes', 'body_sha256')), 'invalid_output')
    return result
