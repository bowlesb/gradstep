"""One finite loopback TLS listener, outside the group whose death is tested."""
import socket
import ssl
import subprocess
import threading
import time


def certificate(root):
    cert, key = root / 'fixture.pem', root / 'fixture.key'
    config = root / 'openssl.cnf'
    config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                      '[dn]\nCN=export.arxiv.org\n[ext]\n'
                      'subjectAltName=DNS:export.arxiv.org,DNS:oaipmh.arxiv.org\n'
                      'basicConstraints=critical,CA:TRUE\n')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-keyout', str(key), '-out', str(cert), '-config', str(config)],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=15, check=True)
    return cert, key


class Server:
    def __init__(self, cert, key, *, slow=False):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(.1)
        self.fixture = {'address': '127.0.0.1', 'port': self.listener.getsockname()[1],
                        'ca_pem': cert.read_text()}
        self.slow, self.connections = slow, 0
        self.requested, self.ended, self.stop = threading.Event(), threading.Event(), threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def serve(self):
        connection = tls = None
        deadline = time.monotonic() + 15
        try:
            while not self.stop.is_set() and time.monotonic() < deadline:
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
            if connection is None:
                return
            self.connections += 1
            connection.settimeout(2)
            tls = self.context.wrap_socket(connection, server_side=True, suppress_ragged_eofs=False)
            request = bytearray()
            while not request.endswith(b'\r\n\r\n'):
                part = tls.recv(1)
                if not part:
                    return
                request.extend(part)
                if len(request) > 4096:
                    raise ValueError('fixture_request_limit')
            self.requested.set()
            tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n' + (b'' if self.slow else b'ok'))
            if self.slow:
                tls.settimeout(.1)
                while not self.stop.is_set() and time.monotonic() < deadline:
                    try:
                        if not tls.recv(1):
                            break
                    except socket.timeout:
                        continue
                self.ended.set()
            else:
                try:
                    tls.unwrap().close()
                except (OSError, ssl.SSLError):
                    pass
                self.ended.set()
        except (OSError, ssl.SSLError):
            self.ended.set()
        except BaseException as error:
            self.error = error
        finally:
            if tls is not None:
                tls.close()
            if connection is not None:
                connection.close()

    def __exit__(self, *_):
        self.stop.set()
        self.listener.close()
        self.thread.join(3)
        if self.thread.is_alive() or self.error is not None:
            raise AssertionError('TLS fixture did not finish cleanly')
