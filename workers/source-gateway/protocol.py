"""Finite fixture protocol. Nothing in this module authorizes source traffic."""
import hashlib
import json
import re
import sys
import time
from urllib.parse import urlencode

MAX_BODY = 1_048_576
MAX_PROTOCOL = 2_097_152
MAX_HEADERS = 16_384
MAX_FIELDS = 64
MAX_HEADER_LINE = 8_192
MAX_CHUNK_LINE = 1_024
MAX_CHUNK_LINES = 65_536
MAX_INPUT = 24_576
MAX_OUTPUT = 1_572_864
MAX_STDERR = 4_096
MAX_USEFUL_MS = 30_000
MAX_CLOSE_MS = 250
CLEANUP_MS = 1_000
# The total supervision allowance above includes startup/result reporting as
# well as post-stop drain/join. Never append a second cleanup grace window.
STOP_GRACE_MS = 500


class Refused(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise Refused(code)


def clock_name():
    # Apple CLOCK_MONOTONIC includes sleep; Linux requires CLOCK_BOOTTIME.
    name = 'CLOCK_MONOTONIC' if sys.platform == 'darwin' else 'CLOCK_BOOTTIME' if sys.platform == 'linux' else None
    require(name is not None and hasattr(time, 'clock_gettime_ns') and hasattr(time, name), 'shared_clock_unavailable')
    return name


def clock_ns():
    """One kernel clock domain across this boot's parent and child processes.

    Python 3.9's macOS time.monotonic() subtracts a process-local origin. Never
    put that value in a cross-process permission. Supported fixture platforms
    must expose the selected sleep-inclusive clock_gettime interface explicitly.
    """
    return time.clock_gettime_ns(getattr(time, clock_name()))


def clock():
    return clock_ns() / 1_000_000_000


def canonical(value):
    # SQL/catalog/parser limits count actual UTF-8 bytes. ASCII escaping can
    # triple valid non-ASCII metadata and reject an otherwise bounded result.
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf8')


def digest(value):
    return hashlib.sha256(value).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'invalid_input')
        result[key] = value
    return result


def decode(raw):
    try:
        return json.loads(raw, object_pairs_hook=unique_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refused('invalid_input')))
    except (ValueError, UnicodeError, RecursionError):
        raise Refused('invalid_input') from None


def target(request):
    """Normalized DTO only; URL parsing remains the shared application's job."""
    require(type(request) is dict and set(request) == {'source_id', 'revision', 'stage', 'byte_ceiling'}, 'invalid_request')
    source = request['source_id']
    require(type(source) is str and 0 < len(source) <= 128, 'invalid_request')
    modern = re.fullmatch(r'([0-9]{2})([0-9]{2})\.([0-9]{4,5})', source)
    historic = re.fullmatch(r'([a-z][a-z0-9-]*)/([0-9]{2})([0-9]{2})([0-9]{3})', source)
    if modern:
        year, month, serial = modern.groups()
        year, month = int(year), int(month)
        require(1 <= month <= 12 and year >= 7 and not (year == 7 and month < 4)
                and int(serial) > 0 and len(serial) == (4 if year < 15 else 5), 'invalid_request')
    elif historic:
        _, year, month, serial = historic.groups()
        year, month = int(year), int(month)
        require(1 <= month <= 12 and int(serial) > 0 and not (7 < year < 91)
                and not (year == 91 and month < 7) and not (year == 7 and month > 3), 'invalid_request')
    else:
        raise Refused('invalid_request')
    revision = request['revision']
    require(revision is None or type(revision) is int and 1 <= revision <= 2_147_483_647, 'invalid_request')
    require(request['stage'] in ('atom', 'license'), 'invalid_request')
    require(type(request['byte_ceiling']) is int and 1 <= request['byte_ceiling'] <= MAX_BODY, 'invalid_request')
    if request['stage'] == 'atom':
        host = 'export.arxiv.org'
        path = '/api/query?' + urlencode({'id_list': source + ('' if revision is None else 'v' + str(revision)), 'max_results': '1'})
    else:
        host = 'oaipmh.arxiv.org'
        path = '/oai?' + urlencode({'verb': 'GetRecord', 'identifier': 'oai:arXiv.org:' + source, 'metadataPrefix': 'arXivRaw'})
    return {'host': host, 'path': path, 'url': 'https://' + host + path}


def envelope(value):
    require(type(value) is dict and set(value) == {'mode', 'attempt_id', 'request', 'fixture', 'useful_ms', 'close_ms'}, 'invalid_input')
    require(value['mode'] == 'loopback_fixture_v1', 'source_network_disabled')
    require(type(value['attempt_id']) is str and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value['attempt_id']), 'invalid_input')
    destination = target(value['request'])
    fixture = value['fixture']
    require(type(fixture) is dict and set(fixture) == {'address', 'port', 'ca_pem'}, 'invalid_fixture')
    require(fixture['address'] == '127.0.0.1' and type(fixture['port']) is int and 1 <= fixture['port'] <= 65535, 'source_network_disabled')
    require(type(fixture['ca_pem']) is str and 1 <= len(fixture['ca_pem']) <= 16_384
            and fixture['ca_pem'].startswith('-----BEGIN CERTIFICATE-----'), 'invalid_fixture')
    require(type(value['useful_ms']) is int and 1 <= value['useful_ms'] <= MAX_USEFUL_MS, 'invalid_input')
    require(type(value['close_ms']) is int and 0 <= value['close_ms'] <= MAX_CLOSE_MS, 'invalid_input')
    return destination


def live_transport(*_args, **_kwargs):
    raise Refused('source_network_disabled')
