"""Finite, root-owned Linux metadata bundle loader; importing it starts nothing."""
import ast
import hashlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import ssl
import stat
import sys
import types

MAX_MEMBER = 131_072
MAX_MANIFEST = 32_768
MAX_INVENTORY = 16_384
MAX_SOURCE_BYTES = 327_680
MAX_EXECUTABLE = 268_435_456
GATEWAY = ('protocol', 'transport', 'child_contract', 'identity', 'runtime_identity', 'child',
           'paused_child', 'rpc_support', 'execution_contract')
LOCAL = ('common', 'uid_policy', 'linux_launcher', 'linux_source', 'witness_slots',
         'lifecycle', 'restricted_rpc', 'action_journal', 'metadata_scope',
         'metadata_settlement', 'metadata_bridge', 'metadata_host', 'owned_session')
MEMBERS = frozenset(name + '.py' for name in GATEWAY + LOCAL) | {
    'bootstrap.py', 'metadata.service.in', 'metadata.slice.in',
    'parser.mjs', 'parser-manifest.json'}
ENTRIES = {'metadata_launcher': ['linux_launcher', 'main'],
           'linux_source': ['linux_source', 'main'],
           'metadata_executor': ['metadata_bridge', 'executor_main'],
           'metadata_guardian': ['metadata_bridge', 'main']}
RUNTIME_NAMES = ('python', 'deno', 'psql')
INVENTORY_KEYS = {'schema_version', 'kind', 'platform', 'architecture', 'kernel_release',
                  'systemd_version', 'python_version', 'deno_version', 'psql_version',
                  'tls_version', 'packages'}
BASE_KEYS = {'schema_version', 'mode', 'files', 'file_bytes', 'bootstrap_sha256',
             'builder_sha256', 'runtime_inventory', 'runtime_inventory_sha256',
             'tls_version', 'source_network_enabled', 'hosted_admitted',
             'supervisor_uid', 'source_uid', 'executor_uid', 'entrypoints',
             'bundle_parent', 'payload_bytes', 'bundle_bytes', 'unit_bytes',
             'source_bytes', 'source_limit', 'journal_allocation'}
MANIFEST_KEYS = BASE_KEYS | {name + suffix for name in RUNTIME_NAMES
                            for suffix in ('_path', '_sha256', '_bytes', '_version')}


def require(value, code):
    if not value:
        raise ValueError(code)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf8')


def decode(raw, maximum):
    require(type(raw) is bytes and 0 < len(raw) <= maximum, 'json_capacity')

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate_json_key')
            result[key] = value
        return result

    def nonfinite(_):
        raise ValueError('nonfinite_json')

    try:
        return json.loads(raw.decode('utf8'), object_pairs_hook=pairs, parse_constant=nonfinite)
    except (UnicodeError, RecursionError, json.JSONDecodeError) as error:
        raise ValueError('invalid_json') from error


def digest(value):
    return type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def text(value, maximum=512):
    return (type(value) is str and 0 < len(value.encode('utf8')) <= maximum
            and not re.search(r'[\x00-\x08\x0b-\x1f\x7f]', value))


def absolute(value):
    require(type(value) is str and re.fullmatch(r'/[A-Za-z0-9_./-]{1,220}', value)
            and not value.startswith('//') and str(Path(value)) == value
            and '..' not in Path(value).parts,
            'invalid_absolute_path')
    return Path(value)


def inventory(value):
    require(type(value) is dict and set(value) == INVENTORY_KEYS
            and type(value['schema_version']) is int and value['schema_version'] == 1
            and value['kind'] == 'linux_metadata_runtime_inventory'
            and value['platform'] == 'linux' and value['architecture'] in ('aarch64', 'x86_64'),
            'invalid_runtime_inventory')
    require(all(text(value[key]) for key in INVENTORY_KEYS - {
        'schema_version', 'kind', 'platform', 'architecture', 'packages'}), 'invalid_runtime_version')
    packages = value['packages']
    require(type(packages) is list and 0 < len(packages) <= 128, 'runtime_inventory_capacity')
    names = []
    for row in packages:
        require(type(row) is dict and set(row) == {'name', 'version', 'architecture'}
                and type(row['name']) is str and re.fullmatch(r'[a-z0-9][a-z0-9+.-]{0,95}', row['name'])
                and text(row['version'], 128) and type(row['architecture']) is str
                and re.fullmatch(r'[a-z0-9_-]{1,24}', row['architecture']), 'invalid_runtime_package')
        names.append((row['name'], row['architecture']))
    require(names == sorted(set(names)) and len(canonical(value)) <= MAX_INVENTORY,
            'runtime_inventory_capacity')
    return value


def allocation(raw):
    """Check the captured allocation declarations without importing the module."""
    expected = {'LEGACY_MAX_SOURCE_BYTES': 262_144, 'MAX_SOURCE_BYTES': MAX_SOURCE_BYTES,
                'MAX_BYTES': 4_194_304, 'MAX_NAMES': 32,
                'RESERVED_BYTES': 4_153_344, 'RESERVED_NAMES': 30}
    found = {}
    for node in ast.parse(raw, filename='witness_slots.py').body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in expected:
                    require(target.id not in found and isinstance(node.value, ast.Constant)
                            and type(node.value.value) is int, 'invalid_source_allocation')
                    found[target.id] = node.value.value
    require(found == expected, 'source_allocation_changed')
    return MAX_SOURCE_BYTES


def unit_size(raw, bundle):
    # UUID and digest lengths are fixed. This renders no file and starts no unit.
    attempt = '00000000-0000-0000-0000-000000000000'
    identifier = '0' * 32
    replacements = {'@ATTEMPT@': attempt, '@SLICE@': 'tsmetadata' + identifier + '.slice',
                    '@ROOT@': '/var/lib/timestep-source/transport/' + identifier,
                    '@JOURNAL@': '/var/lib/timestep-source/attempts/' + identifier,
                    '@BUNDLE@': str(bundle)}
    total = 0
    for name in ('metadata.service.in', 'metadata.slice.in'):
        require(0 < len(raw[name]) <= 16_384, 'invalid_unit_template')
        value = raw[name].decode('utf8')
        for old, new in replacements.items():
            value = value.replace(old, new)
        require('@' not in value, 'unexpanded_unit_template')
        total += len(value.encode('utf8'))
    return total


def validate_material(raw, manifest_raw, bundle):
    """Pure byte/schema verification; never imports or executes bundle members."""
    bundle = absolute(str(bundle))
    manifest = decode(manifest_raw, MAX_MANIFEST)
    require(type(manifest) is dict and set(manifest) == MANIFEST_KEYS
            and canonical(manifest) == manifest_raw and bundle.name == sha(manifest_raw),
            'invalid_bundle_identity')
    require(type(manifest['schema_version']) is int and manifest['schema_version'] == 1
            and manifest['mode'] == 'linux_metadata_fixture'
            and manifest['source_network_enabled'] is False and manifest['hosted_admitted'] is False
            and manifest['journal_allocation'] == 'fixed-record-inodes-v2'
            and manifest['entrypoints'] == ENTRIES and manifest['bundle_parent'] == str(bundle.parent)
            and all(type(manifest[key]) is int and manifest[key] == number for key, number in
                    (('supervisor_uid', 62401), ('source_uid', 62402), ('executor_uid', 62403))),
            'invalid_bundle_profile')
    require(type(raw) is dict and set(raw) == MEMBERS and type(manifest['files']) is dict
            and set(manifest['files']) == MEMBERS and type(manifest['file_bytes']) is dict
            and set(manifest['file_bytes']) == MEMBERS, 'invalid_bundle_members')
    for name, data in raw.items():
        require(type(data) is bytes and 0 < len(data) <= MAX_MEMBER
                and digest(manifest['files'][name]) and sha(data) == manifest['files'][name]
                and type(manifest['file_bytes'][name]) is int
                and len(data) == manifest['file_bytes'][name], 'bundle_member_mismatch')
    require(manifest['bootstrap_sha256'] == sha(raw['bootstrap.py'])
            and digest(manifest['builder_sha256']), 'invalid_bundle_recipe')
    observed = inventory(manifest['runtime_inventory'])
    require(manifest['runtime_inventory_sha256'] == sha(canonical(observed))
            and manifest['tls_version'] == observed['tls_version'], 'runtime_inventory_mismatch')
    for name in RUNTIME_NAMES:
        absolute(manifest[name + '_path'])
        require(digest(manifest[name + '_sha256']) and type(manifest[name + '_bytes']) is int
                and 64 <= manifest[name + '_bytes'] <= MAX_EXECUTABLE
                and manifest[name + '_version'] == observed[name + '_version'], 'invalid_runtime_binding')
    require(manifest['psql_path'] == '/usr/lib/postgresql/17/bin/psql', 'invalid_psql_path')
    sizes = {'payload_bytes': sum(map(len, raw.values())),
             'bundle_bytes': sum(map(len, raw.values())) + len(manifest_raw),
             'unit_bytes': unit_size(raw, bundle), 'source_limit': allocation(raw['witness_slots.py'])}
    sizes['source_bytes'] = sizes['bundle_bytes'] + sizes['unit_bytes']
    require(all(type(manifest[key]) is int and manifest[key] == value for key, value in sizes.items())
            and sizes['source_bytes'] <= sizes['source_limit'], 'bundle_source_capacity')
    parser = decode(raw['parser-manifest.json'], MAX_MANIFEST)
    require(type(parser) is dict and type(parser.get('schema_version')) is int
            and parser.get('schema_version') == 1
            and parser.get('kind') == 'local_metadata_parser_bundle'
            and parser.get('source_network_enabled') is False and parser.get('hosted_admitted') is False
            and parser.get('runtime_sha256') == manifest['deno_sha256']
            and parser.get('runtime_version') == manifest['deno_version']
            and 'linux' in manifest['deno_version'].split('\n')[0]
            and type(parser.get('output')) is dict and type(parser['output'].get('bytes')) is int
            and parser.get('output') == {'file': 'parser.mjs', 'bytes': len(raw['parser.mjs']),
                                          'sha256': sha(raw['parser.mjs'])}, 'parser_binding_changed')
    return manifest


def read_regular(path, maximum, *, owner=None, readonly=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and (owner is None or before.st_uid == owner)
                and not before.st_mode & (0o222 if readonly else 0o022)
                and 0 < before.st_size <= maximum, 'invalid_input_file')
        data = bytearray()
        while len(data) <= maximum:
            part = os.read(fd, min(65_536, maximum + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)
        require(len(data) == before.st_size and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'input_changed')
        return bytes(data)
    finally:
        os.close(fd)


def trusted_directory(path, *, readonly=False):
    path = absolute(str(path))
    for current in (*reversed(path.parents), path):
        info = current.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'untrusted_directory')
    require(not readonly or not path.stat().st_mode & 0o222, 'writable_bundle')
    return path


def executable(path, architecture):
    """Hash a pinned ELF without running it. OS package files are separate storage."""
    path = absolute(str(path))
    trusted_directory(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == 0
                and not before.st_mode & 0o022 and before.st_mode & 0o111
                and 64 <= before.st_size <= MAX_EXECUTABLE, 'invalid_runtime_executable')
        header = os.read(fd, 64)
        machine = 183 if architecture == 'aarch64' else 62
        require(len(header) == 64 and header[:7] == b'\x7fELF\x02\x01\x01'
                and int.from_bytes(header[16:18], 'little') in (2, 3)
                and int.from_bytes(header[18:20], 'little') == machine, 'non_linux_runtime')
        result, count = hashlib.sha256(header), len(header)
        while count <= MAX_EXECUTABLE:
            block = os.read(fd, min(65_536, MAX_EXECUTABLE + 1 - count))
            if not block:
                break
            count += len(block)
            result.update(block)
        after = os.fstat(fd)
        require(count == before.st_size and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'runtime_changed')
        return {'path': str(path), 'sha256': result.hexdigest(), 'bytes': count}
    finally:
        os.close(fd)


def check_runtime(manifest):
    observed = manifest['runtime_inventory']
    require(sys.platform == 'linux' and platform.machine() == observed['architecture']
            and platform.release() == observed['kernel_release'] and sys.version == manifest['python_version']
            and ssl.OPENSSL_VERSION == manifest['tls_version'], 'runtime_platform_changed')
    require(str(Path(sys.executable).resolve(strict=True)) == manifest['python_path'], 'python_path_changed')
    for name in RUNTIME_NAMES:
        actual = executable(manifest[name + '_path'], observed['architecture'])
        require(all(actual[key] == manifest[name + '_' + key] for key in ('path', 'sha256', 'bytes')),
                'runtime_executable_changed')


def load_bundle(root):
    root = trusted_directory(root, readonly=True)
    require(digest(root.name), 'invalid_bundle_name')
    names = set()
    with os.scandir(root) as entries:
        for entry in entries:
            require(len(names) < len(MEMBERS) + 1 and entry.name in MEMBERS | {'bundle.json'},
                    'unexpected_bundle_member')
            names.add(entry.name)
    require(names == MEMBERS | {'bundle.json'}, 'missing_bundle_member')
    manifest_raw = read_regular(root / 'bundle.json', MAX_MANIFEST, owner=0, readonly=True)
    raw, total = {}, len(manifest_raw)
    for name in sorted(MEMBERS):
        raw[name] = read_regular(root / name, min(MAX_MEMBER, MAX_SOURCE_BYTES - total), owner=0, readonly=True)
        total += len(raw[name])
    manifest = validate_material(raw, manifest_raw, root)
    check_runtime(manifest)
    return manifest, raw


class CapturedModules(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def __init__(self, root, raw, context):
        self.root, self.raw, self.context = root, raw, context

    def find_spec(self, name, path=None, target=None):
        return importlib.util.spec_from_loader(name, self) if name + '.py' in self.raw and name != 'bootstrap' else None

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        name = module.__name__ + '.py'
        module.__file__ = str(self.root / name)
        self.context.loaded[name] = sha(self.raw[name])
        exec(compile(self.raw[name], module.__file__, 'exec'), module.__dict__)


def main():
    require(len(sys.argv) in (3, 4) and sys.argv[2] in ENTRIES, 'invalid_entrypoint')
    entry = sys.argv[2]
    require(len(sys.argv) == (4 if entry in ('metadata_launcher', 'linux_source') else 3),
            'invalid_entry_arguments')
    require(sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode, 'isolated_python_required')
    root = Path(sys.argv[1])
    manifest, raw = load_bundle(root)
    require(str(Path(__file__)) == str(root / 'bootstrap.py'), 'bootstrap_path_changed')
    require(not any(name in sys.modules for name in GATEWAY + LOCAL + ('frozen_context',)),
            'preloaded_bundle_module')
    context = types.ModuleType('frozen_context')
    context.root, context.manifest, context.loaded = root, manifest, {}
    sys.modules['frozen_context'] = context
    sys.meta_path.insert(0, CapturedModules(root, raw, context))
    module, function = ENTRIES[entry]
    return getattr(__import__(module), function)()


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        # No config, request, exception body or credentials in launcher output.
        raise SystemExit('metadata_bundle_refused')
