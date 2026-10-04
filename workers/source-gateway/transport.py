"""Exclusive socket owner; executable only with a loopback fixture envelope."""
import base64
import email.utils
import hashlib
import http.client
import re
import socket
import ssl
import sys
import time

from protocol import (MAX_INPUT, MAX_OUTPUT, MAX_PROTOCOL, MAX_HEADERS, MAX_FIELDS,
                      MAX_HEADER_LINE, MAX_CHUNK_LINE, MAX_CHUNK_LINES,
                      Refused, require, canonical, decode, envelope, digest)


class BoundedFile:
    """Unbuffered SocketIO ownership, with exact reads for HTTPResponse.

    No plaintext is prefetched past HTTP framing into a buffer that would be
    discarded when HTTPResponse automatically closes its file at message EOF.
    """
    def __init__(self, tls, deadline, body_limit):
        self.tls = tls
        self.raw = tls.makefile('rb', buffering=0)
        self.deadline = deadline
        self.body_limit = body_limit
        self.closed = False
        self.received = 0
        self.header_bytes = 0
        self.header_fields = 0
        self.chunk_line_bytes = 0
        self.headers = True
        self.first_line = True
        self.peer_close = 'not_observed'

    def _read(self, amount):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, 'deadline')
        require(amount > 0, 'protocol_error')
        self.tls.settimeout(remaining)
        try:
            data = self.raw.read(min(amount, 16_384, MAX_PROTOCOL - self.received + 1))
        except ssl.SSLEOFError:
            self.peer_close = 'abrupt'
            raise Refused('tls_truncated') from None
        except (ConnectionResetError, ConnectionAbortedError):
            self.peer_close = 'abrupt'
            raise Refused('transport') from None
        self.received += len(data)
        require(self.received <= MAX_PROTOCOL, 'protocol_limit')
        if not data:
            self.peer_close = 'clean_tls'
        return data

    def read(self, amount=-1):
        result = bytearray()
        if amount == 0:
            return b''
        require(amount == -1 or 0 < amount <= MAX_PROTOCOL, 'protocol_limit')
        while amount < 0 or len(result) < amount:
            # Unbounded HTTPResponse.read is used only for a close-delimited
            # body. Its body cap is enforced before another receive.
            count = min(16_384, self.body_limit - len(result) + 1) if amount < 0 else amount - len(result)
            require(count > 0, 'body_limit')
            data = self._read(count)
            if not data:
                break
            result.extend(data)
            if amount < 0:
                require(len(result) <= self.body_limit, 'body_limit')
        return bytes(result)

    def readinto(self, buffer):
        value = self.read(len(buffer))
        buffer[:len(value)] = value
        return len(value)

    def readline(self, amount=-1):
        limit = MAX_HEADER_LINE if self.headers else MAX_CHUNK_LINE
        if amount >= 0:
            limit = min(limit, amount)
        result = bytearray()
        while not result.endswith(b'\n'):
            require(len(result) < limit, 'header_limit' if self.headers else 'protocol_limit')
            data = self._read(1)
            if not data:
                break
            result.extend(data)
        value = bytes(result)
        require(value.endswith(b'\r\n'), 'protocol_error')
        if self.headers:
            self.header_bytes += len(value)
            require(self.header_bytes <= MAX_HEADERS, 'header_limit')
            if self.first_line:
                require(re.fullmatch(rb'HTTP/1\.[01] [2-5][0-9]{2}(?: [\x20-\x7e]*)?\r\n', value), 'unsupported_status')
                self.first_line = False
            elif value == b'\r\n':
                self.headers = False
            else:
                self.header_fields += 1
                require(self.header_fields <= MAX_FIELDS, 'header_limit')
                require(re.fullmatch(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+:[\x09\x20-\x7e\x80-\xff]*\r\n", value), 'protocol_error')
        else:
            self.chunk_line_bytes += len(value)
            require(self.chunk_line_bytes <= MAX_CHUNK_LINES, 'protocol_limit')
            # Deliberately unsupported in this pilot: extensions and trailers.
            require(value == b'\r\n' or re.fullmatch(rb'[0-9a-fA-F]{1,8}\r\n', value), 'unsupported_chunk_syntax')
        return value

    def close(self):
        if not self.closed:
            self.raw.close()
            self.closed = True

    def flush(self):
        # HTTPResponse.close calls flush on its input-only file wrapper.
        if not self.closed:
            self.raw.flush()


class FileOwner:
    def __init__(self, file):
        self.file = file
        self.used = False

    def makefile(self, mode):
        require(mode == 'rb' and not self.used, 'protocol_error')
        self.used = True
        return self.file


class StrictResponse(http.client.HTTPResponse):
    """Keep stdlib framing; reject its permissive delimiters/trailers."""
    def __init__(self, owner, body_limit):
        self.body_limit = body_limit
        self.declared_chunks = 0
        super().__init__(owner, method='GET')

    def _read_next_chunk_size(self):
        size = super()._read_next_chunk_size()
        self.declared_chunks += size
        require(self.declared_chunks <= self.body_limit, 'body_limit')
        return size

    def _safe_read(self, amount):
        data = super()._safe_read(amount)
        if self.chunked and self.chunk_left == 0 and amount == 2:
            require(data == b'\r\n', 'protocol_error')
        return data

    def _read_and_discard_trailer(self):
        require(self.fp.readline(MAX_CHUNK_LINE + 1) == b'\r\n', 'unsupported_chunk_syntax')


def header_policy(response, ceiling):
    require(response.version in (10, 11), 'protocol_error')
    lengths = response.headers.get_all('Content-Length', [])
    transfer = response.headers.get_all('Transfer-Encoding', [])
    encoding = response.headers.get_all('Content-Encoding', [])
    require(len(lengths) <= 1 and len(transfer) <= 1 and not (lengths and transfer), 'ambiguous_framing')
    require(not encoding or len(encoding) == 1 and encoding[0].strip().lower() == 'identity', 'unsupported_encoding')
    if lengths:
        require(re.fullmatch(r'[0-9]{1,10}', lengths[0].strip()), 'ambiguous_framing')
        require(int(lengths[0]) <= ceiling, 'body_limit')
    if transfer:
        require(transfer[0].strip().lower() == 'chunked' and response.version == 11, 'unsupported_encoding')
    require(not 300 <= response.status <= 399, 'redirect')
    if response.status in (204, 304):
        require(not transfer and (not lengths or int(lengths[0]) == 0), 'ambiguous_framing')
    return 'chunked' if transfer else 'content_length' if lengths else 'no_body' if response.status == 204 else 'close_delimited'


def retry_after(response):
    values = response.headers.get_all('Retry-After', [])
    if len(values) != 1 or len(values[0]) > 128:
        return 0
    value = values[0].strip()
    try:
        if re.fullmatch(r'[0-9]{1,10}', value):
            return min(86_400, int(value))
        parsed = email.utils.parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            return 0
        return min(86_400, max(0, int(parsed.timestamp() - time.time() + 0.999)))
    except (ValueError, TypeError, OverflowError):
        return 0


def perform(value):
    destination = envelope(value)
    started = time.monotonic()
    deadline = started + value['useful_ms'] / 1000
    result = {'schema_version': 1, 'mode': 'loopback_fixture_v1', 'attempt_id': value['attempt_id'],
              'request_sha256': digest(canonical(value['request'])), 'target': destination,
              'kind': 'uncertain', 'reason': 'transport', 'status': None, 'framing': None,
              'framing_complete': False, 'tls_peer_close': 'not_observed',
              'body_base64': None, 'body_sha256': None, 'body_bytes': None,
              'protocol_bytes_received': 0, 'retry_after_seconds': 0,
              'local_cleanup': {'http_file_closed': True, 'socket_closed': True},
              'elapsed_ms': 0, 'source_network_enabled': False}
    raw = tls = file = response = None
    def arm(connection):
        remaining = deadline - time.monotonic()
        require(remaining > 0, 'deadline')
        connection.settimeout(remaining)

    def fail(reason):
        # A later close-observation/cleanup error must not leave success bytes
        # paired with a failure reason. Preserve only the framing facts already
        # observed, not a complete payload suitable for downstream accounting.
        result.update(kind='uncertain', reason=reason, body_base64=None,
                      body_sha256=None, body_bytes=None)

    def close_owned(resource):
        if resource is not None:
            try:
                resource.close()
            except (OSError, ValueError):
                # Try every owned reference even if an earlier close failed.
                # Actual process retirement remains the parent's waitpid fact.
                fail('transport')
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_verify_locations(cadata=value['fixture']['ca_pem'])
        context.set_alpn_protocols(['http/1.1'])
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        require(not raw.get_inheritable(), 'socket_ownership')
        arm(raw)
        # No resolver, proxy discovery, address fallback, reconnect or retry.
        raw.connect((value['fixture']['address'], value['fixture']['port']))
        tls = context.wrap_socket(raw, server_hostname=destination['host'],
                                  suppress_ragged_eofs=False, do_handshake_on_connect=False)
        arm(tls)
        tls.do_handshake()
        require(tls.selected_alpn_protocol() in (None, 'http/1.1'), 'protocol_error')
        require(not tls.get_inheritable() and time.monotonic() < deadline, 'deadline')
        request = ('GET ' + destination['path'] + ' HTTP/1.1\r\nHost: ' + destination['host'] +
                   '\r\nAccept: application/atom+xml, application/xml, text/xml\r\nAccept-Encoding: identity' +
                   '\r\nConnection: close\r\nUser-Agent: science-reader-loopback-fixture/1\r\n\r\n').encode('ascii')
        require(len(request) <= 2048, 'invalid_request')
        arm(tls)
        tls.sendall(request)
        file = BoundedFile(tls, deadline, value['request']['byte_ceiling'])
        response = StrictResponse(FileOwner(file), value['request']['byte_ceiling'])
        response.begin()
        result['status'] = response.status
        result['retry_after_seconds'] = retry_after(response)
        result['framing'] = header_policy(response, value['request']['byte_ceiling'])
        body = response.read()
        require(len(body) <= value['request']['byte_ceiling'], 'body_limit')
        require(time.monotonic() < deadline, 'deadline')
        result['framing_complete'] = True
        result['kind'] = 'complete'
        result['reason'] = None
        result['body_base64'] = base64.b64encode(body).decode('ascii')
        result['body_sha256'] = hashlib.sha256(body).hexdigest()
        result['body_bytes'] = len(body)
        # Parser EOF is not TLS EOF. Framed responses can be complete without
        # a clean peer close; this bounded observation never changes that fact.
        if file.peer_close == 'not_observed' and value['close_ms']:
            tls.settimeout(value['close_ms'] / 1000)
            try:
                extra = tls.recv(1)
                if extra:
                    file.received += len(extra)
                    raise Refused('extra_protocol_data')
                file.peer_close = 'clean_tls'
            except ssl.SSLEOFError:
                file.peer_close = 'abrupt'
            except (ConnectionResetError, ConnectionAbortedError):
                file.peer_close = 'abrupt'
            except socket.timeout:
                pass
    except Refused as error:
        fail(error.code)
    except socket.timeout:
        fail('deadline')
    except ssl.SSLCertVerificationError:
        fail('tls_identity')
    except http.client.IncompleteRead:
        fail('http_truncated')
    except (ssl.SSLError, OSError):
        fail('transport')
    except (http.client.HTTPException, ValueError):
        fail('protocol_error')
    finally:
        close_owned(response)
        if file is not None:
            close_owned(file)
            result['tls_peer_close'] = file.peer_close
            result['protocol_bytes_received'] = file.received
            result['local_cleanup']['http_file_closed'] = file.closed
        if tls is not None:
            # Never reuse the raw socket. We do not call unwrap: our resource
            # fact is explicit local reference retirement, not a TLS/TCP claim.
            close_owned(tls)
            result['local_cleanup']['socket_closed'] = tls.fileno() == -1
        if raw is not None:
            close_owned(raw)
            result['local_cleanup']['socket_closed'] = result['local_cleanup']['socket_closed'] and raw.fileno() == -1
        result['elapsed_ms'] = round((time.monotonic() - started) * 1000, 3)
    return result


def main():
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        require(len(raw) <= MAX_INPUT, 'input_limit')
        result = perform(decode(raw))
        encoded = canonical(result)
        require(len(encoded) <= MAX_OUTPUT, 'output_limit')
        sys.stdout.buffer.write(encoded + b'\n')
        sys.stdout.buffer.flush()
        return 0
    except (Refused, ValueError, TypeError):
        # Input/setup failure has no trusted result and prints no input/keys.
        return 2
    except BrokenPipeError:
        return 3  # Parent disappeared; no surviving retirement witness.


if __name__ == '__main__':
    raise SystemExit(main())
