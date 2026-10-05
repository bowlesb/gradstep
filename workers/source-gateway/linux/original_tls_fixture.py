"""Finite loopback original-PDF/Storage model, never a real Storage adapter.

One serial thread serves at most 16 connections. Request observations contain
only validated route/binding scalars; they are not client acknowledgement or
retirement evidence. ``objects`` models commit even when its ACK is lost.
"""
import hashlib
import json
import os
import pathlib
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import uuid


MAX_BODY = 5 * 1024 * 1024
MAX_HEADERS = 16 * 1024
MAX_CONNECTIONS = 16
CONNECTION_SECONDS = 5
CLOSE_SECONDS = .25
FAULTS = {None, 'commit_then_drop_ack', 'wrong_ack_hash',
          'truncated_readback', 'wrong_readback_bytes'}
HOSTS = {'arxiv.org', 'objects.timestep.invalid'}
HASH = re.compile(r'[0-9a-f]{64}')
OBJECT = re.compile(r'/objects/paper-assets/(originals/([0-9a-f-]{36})/original\.pdf)')
HEADER_NAME = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
COMMON_HEADERS = {'host', 'connection', 'accept', 'accept-encoding', 'user-agent',
                  'content-length', 'content-type', 'x-timestep-attempt',
                  'x-timestep-request-sha256', 'x-timestep-candidate-sha256', 'x-upsert'}


def certificate(root):
    """Create a synthetic one-day CA/server certificate in an owned subdir."""
    directory = pathlib.Path(tempfile.mkdtemp(prefix='original-tls-', dir=root))
    cert, key, config = (directory / name for name in ('fixture.pem', 'fixture.key', 'openssl.cnf'))
    try:
        fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='ascii') as output:
            output.write('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                         '[dn]\nCN=arxiv.org\n[ext]\n'
                         'subjectAltName=DNS:arxiv.org,DNS:objects.timestep.invalid\n'
                         'basicConstraints=critical,CA:TRUE\n'
                         'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n'
                         'extendedKeyUsage=serverAuth\n')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
                        '-keyout', str(key), '-out', str(cert), '-config', str(config)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=15, check=True)
        key.chmod(0o600)
        cert.chmod(0o600)
        return cert, key
    except BaseException:
        for path in (cert, key, config):
            path.unlink(missing_ok=True)
        directory.rmdir()
        raise


def _uuid(value):
    try:
        return type(value) is str and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _source_path(path):
    """The existing gateway's normalized arXiv grammar, with a fixed revision."""
    match = re.fullmatch(r'/pdf/(.{1,128})v([1-9][0-9]{0,9})', path)
    if not match or int(match[2]) > 2_147_483_647:
        return False
    modern = re.fullmatch(r'([0-9]{2})([0-9]{2})\.([0-9]{4,5})', match[1])
    historic = re.fullmatch(r'([a-z][a-z0-9-]*)/([0-9]{2})([0-9]{2})([0-9]{3})', match[1])
    if modern:
        year, month, serial = modern.groups()
        year, month = int(year), int(month)
        return (1 <= month <= 12 and year >= 7 and not (year == 7 and month < 4)
                and int(serial) > 0 and len(serial) == (4 if year < 15 else 5))
    if historic:
        _, year, month, serial = historic.groups()
        year, month = int(year), int(month)
        return (1 <= month <= 12 and int(serial) > 0 and not (7 < year < 91)
                and not (year == 91 and month < 7) and not (year == 7 and month > 3))
    return False


class _RequestError(Exception):
    def __init__(self, status=400):
        self.status = status


def _require(condition, status=400):
    if not condition:
        raise _RequestError(status)


class OriginalServer:
    """Context-owned loopback fixture; snapshots never expose mutable storage.

    ``requests[].status`` is the selected server status, not proof it reached
    the caller. Faults affect only their named POST/readback operation. There
    are no retries, redirects, DNS lookups, proxies, or outbound connections.
    """

    def __init__(self, cert, key, *, body, fault=None):
        if type(body) is not bytes or len(body) > MAX_BODY:
            raise ValueError('fixture_body_limit')
        if fault is not None and (type(fault) is not str or fault not in FAULTS):
            raise ValueError('fixture_fault')
        with open(cert, 'rb') as source:
            pem = source.read(MAX_HEADERS + 1)
        if not 0 < len(pem) <= MAX_HEADERS:
            raise ValueError('fixture_certificate_limit')
        self._body, self._fault = body, fault
        self._lock, self._stop = threading.Lock(), threading.Event()
        self._requests, self._objects, self._attempts = [], {}, set()
        self._connections, self._active, self._started, self.error = 0, None, False, None
        self.committed = threading.Event()
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.set_alpn_protocols(['http/1.1'])
        self.context.load_cert_chain(cert, key)
        self.context.set_servername_callback(
            lambda _socket, name, _context: None if name in HOSTS else ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.listener.bind(('127.0.0.1', 0))
            self.listener.listen(1)
            self.listener.settimeout(.1)
            self.fixture = {'address': '127.0.0.1', 'port': self.listener.getsockname()[1],
                            'ca_pem': pem.decode('ascii')}
        except BaseException:
            self.listener.close()
            raise
        self.thread = threading.Thread(target=self._serve, name='original-loopback-tls', daemon=False)

    @property
    def connections(self):
        with self._lock:
            return self._connections

    @property
    def requests(self):
        with self._lock:
            return [dict(item) for item in self._requests]

    @property
    def objects(self):
        with self._lock:
            return dict(self._objects)

    def __enter__(self):
        if self._started or self._stop.is_set():
            raise ValueError('fixture_already_started')
        self._started = True
        try:
            self.thread.start()
        except BaseException:
            self.listener.close()
            raise
        return self

    def _update(self, observation, **values):
        with self._lock:
            observation.update(values)

    def _arm(self, connection, deadline):
        remaining = deadline - time.monotonic()
        if self._stop.is_set() or remaining <= 0:
            raise TimeoutError('fixture_deadline')
        connection.settimeout(remaining)

    def _read_request(self, tls, deadline):
        data = bytearray()
        while True:
            marker = data.find(b'\r\n\r\n')
            if marker >= 0:
                _require(marker + 4 <= MAX_HEADERS, 413)
                break
            _require(len(data) < MAX_HEADERS, 413)
            self._arm(tls, deadline)
            part = tls.recv(min(4096, MAX_HEADERS - len(data)))
            _require(bool(part))
            data.extend(part)
        try:
            lines = bytes(data[:marker]).decode('ascii').split('\r\n')
        except UnicodeError:
            raise _RequestError() from None
        _require(len(lines) <= 65 and all(len(line) <= 8192 for line in lines))
        start = lines[0].split(' ')
        _require(len(start) == 3 and start[2] == 'HTTP/1.1')
        method, path, _ = start
        _require(method in ('GET', 'POST'), 405)
        headers = {}
        for line in lines[1:]:
            name, separator, value = line.partition(':')
            _require(separator and HEADER_NAME.fullmatch(name) and name.lower() not in headers)
            _require(all(character == '\t' or ' ' <= character <= '~' for character in value))
            headers[name.lower()] = value.strip(' \t')
        _require(set(headers) <= COMMON_HEADERS)
        _require(headers.get('connection', 'close').lower() == 'close')
        _require(headers.get('accept-encoding', 'identity').lower() == 'identity')
        length = headers.get('content-length', '0')
        _require(re.fullmatch(r'0|[1-9][0-9]{0,6}', length))
        length = int(length)
        _require(length <= MAX_BODY, 413)
        _require(method == 'POST' or length == 0)
        for name in ('x-timestep-request-sha256', 'x-timestep-candidate-sha256'):
            _require(name not in headers or HASH.fullmatch(headers[name]))
        _require('x-timestep-attempt' not in headers or _uuid(headers['x-timestep-attempt']))
        pending = bytes(data[marker + 4:])
        _require(len(pending) <= length)
        return method, path, headers, length, pending

    def _send(self, tls, deadline, observation, status, body, *, declared=None, media='application/json'):
        reason = {200: 'OK', 201: 'Created', 400: 'Bad Request', 404: 'Not Found',
                  405: 'Method Not Allowed', 409: 'Conflict', 413: 'Payload Too Large',
                  422: 'Unprocessable Content'}[status]
        self._update(observation, status=status)
        header = (f'HTTP/1.1 {status} {reason}\r\nContent-Length: {len(body) if declared is None else declared}'
                  f'\r\nContent-Type: {media}\r\nConnection: close\r\n\r\n').encode('ascii')
        self._arm(tls, deadline)
        tls.sendall(header)
        view = memoryview(body)
        for offset in range(0, len(view), 65536):
            self._arm(tls, deadline)
            tls.sendall(view[offset:offset + 65536])

    def _handle(self, tls, deadline, observation):
        method, path, headers, length, pending = self._read_request(tls, deadline)
        stored = OBJECT.fullmatch(path)
        if stored:
            _require(_uuid(stored[2]) and headers.get('host') == 'objects.timestep.invalid', 404)
            route, object_path = 'object', stored[1]
        else:
            _require(method == 'GET' and _source_path(path) and headers.get('host') == 'arxiv.org', 404)
            route, object_path = 'source', None
        self._update(observation, method=method, route=route, path=path,
                     attempt_id=headers.get('x-timestep-attempt'),
                     request_sha256=headers.get('x-timestep-request-sha256'),
                     candidate_sha256=headers.get('x-timestep-candidate-sha256'), declared_bytes=length)
        if method == 'GET':
            if route == 'source':
                body = self._body
            else:
                with self._lock:
                    body = self._objects.get(object_path)
                _require(body is not None, 404)
                if self._fault == 'truncated_readback':
                    self._send(tls, deadline, observation, 200, body[:-1], declared=max(1, len(body)), media='application/pdf')
                    return False
                if self._fault == 'wrong_readback_bytes':
                    body = bytes([body[0] ^ 1]) + body[1:] if body else b'\x00'
            self._send(tls, deadline, observation, 200, body, media='application/pdf')
            return True
        _require(route == 'object' and 'content-length' in headers and headers.get('x-upsert') == 'false')
        _require(headers.get('content-type', 'application/pdf') == 'application/pdf')
        _require(all(name in headers for name in ('x-timestep-attempt', 'x-timestep-request-sha256', 'x-timestep-candidate-sha256')))
        # Even an interrupted body consumes this fixture attempt identity. A
        # later POST cannot turn a missing ACK into permission to send again.
        with self._lock:
            repeated = headers['x-timestep-attempt'] in self._attempts
            self._attempts.add(headers['x-timestep-attempt'])
            occupied = bool(self._objects)
        body = bytearray(pending)
        digest = hashlib.sha256(pending)
        self._update(observation, received_bytes=len(body))
        while len(body) < length:
            self._arm(tls, deadline)
            part = tls.recv(min(65536, length - len(body)))
            _require(bool(part))
            body.extend(part)
            digest.update(part)
            self._update(observation, received_bytes=len(body))
        actual = digest.hexdigest()
        self._update(observation, body_sha256=actual)
        _require(not repeated and not occupied, 409)
        _require(actual == headers['x-timestep-candidate-sha256'], 422)
        with self._lock:
            self._objects[object_path] = bytes(body)
            observation['committed'] = True
        self.committed.set()  # Stored bytes exist before any ACK write.
        if self._fault == 'commit_then_drop_ack':
            return False
        acknowledgement = {'format': 'original-upload-ack-v1', 'attempt_id': headers['x-timestep-attempt'],
                           'request_sha256': headers['x-timestep-request-sha256'], 'bucket': 'paper-assets',
                           'path': object_path, 'sha256': actual, 'byte_count': len(body), 'committed': True}
        if self._fault == 'wrong_ack_hash':
            acknowledgement['sha256'] = ('0' if actual[0] != '0' else '1') + actual[1:]
        encoded = json.dumps(acknowledgement, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')
        if len(encoded) > 1024:
            raise AssertionError('fixture_ack_limit')
        self._send(tls, deadline, observation, 201, encoded)
        return True

    def _close(self, connection):
        if connection is not None:
            try:
                connection.close()
            except OSError:
                self.error = 'fixture_close_failed'

    def _serve(self):
        try:
            while not self._stop.is_set() and self.connections < MAX_CONNECTIONS:
                try:
                    raw, peer = self.listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self._stop.is_set():
                        break
                    raise
                tls = unwrapped = None
                deadline = time.monotonic() + CONNECTION_SECONDS
                try:
                    with self._lock:
                        self._connections += 1
                        self._active = raw
                    if peer[0] != '127.0.0.1':
                        raise AssertionError('fixture_nonloopback_peer')
                    with self._lock:
                        tls = self.context.wrap_socket(raw, server_side=True, suppress_ragged_eofs=False,
                                                       do_handshake_on_connect=False)
                        self._active = tls
                    self._arm(tls, deadline)
                    tls.do_handshake()
                    observation = {'method': None, 'route': None, 'path': None, 'attempt_id': None,
                                   'request_sha256': None, 'candidate_sha256': None, 'declared_bytes': None,
                                   'received_bytes': 0, 'body_sha256': None, 'status': None, 'committed': False}
                    with self._lock:
                        self._requests.append(observation)
                    try:
                        clean = self._handle(tls, deadline, observation)
                    except _RequestError as error:
                        self._send(tls, deadline, observation, error.status, b'{"error":"fixture_request_refused"}')
                        clean = True
                    if clean and not self._stop.is_set():
                        tls.settimeout(CLOSE_SECONDS)
                        try:
                            unwrapped = tls.unwrap()
                        except (OSError, ssl.SSLError):
                            pass  # Peer-close observation is the client's job.
                except (OSError, ssl.SSLError):
                    pass  # Deliberate client cancellation/partial TLS is finite.
                except ValueError:
                    if not self._stop.is_set():
                        self.error = 'fixture_internal_error'
                        self._stop.set()
                finally:
                    with self._lock:
                        self._active = None
                    for connection in (unwrapped, tls, raw):
                        self._close(connection)
        except BaseException:
            self.error = 'fixture_internal_error'
        finally:
            self._close(self.listener)

    def __exit__(self, *_):
        self._stop.set()
        with self._lock:
            active = self._active
        if active is not None:
            try:
                active.shutdown(socket.SHUT_RDWR)
            except (OSError, ValueError):
                pass
        self._close(active)
        self._close(self.listener)
        if self._started:
            self.thread.join(CONNECTION_SECONDS + CLOSE_SECONDS + 1)
        if self.thread.is_alive() or self.error is not None:
            raise AssertionError('original TLS fixture did not finish cleanly')
