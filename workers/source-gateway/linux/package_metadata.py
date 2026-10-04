"""Capture the combined local Linux metadata graph; never launches any role/tool."""
import argparse
import ast
import os
from pathlib import Path
import platform
import re
import ssl
import stat
import sys

GATEWAY_FILES = ('protocol.py', 'transport.py', 'child_contract.py', 'identity.py',
                 'runtime_identity.py', 'child.py', 'paused_child.py', 'rpc_support.py', 'execution_contract.py')
LOCAL_FILES = {name + '.py': name + '.py' for name in (
    'common', 'uid_policy', 'witness_slots', 'lifecycle', 'restricted_rpc', 'action_journal',
    'metadata_scope', 'metadata_settlement', 'metadata_bridge', 'metadata_host', 'owned_session')}
LOCAL_FILES.update({'metadata_bootstrap.py': 'bootstrap.py',
                    'prerequisite_launcher.py': 'linux_launcher.py',
                    'prerequisite_source.py': 'linux_source.py',
                    'metadata.service.in': 'metadata.service.in', 'metadata.slice.in': 'metadata.slice.in'})


def read_recipe(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not (stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and 0 < before.st_size <= 32_768 and not before.st_mode & 0o022):
            raise ValueError('invalid_build_recipe')
        raw = stream.read(32_769)
        after = os.fstat(stream.fileno())
        if len(raw) != before.st_size or (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('build_recipe_changed')
        return raw


def source_limit(codec, raw):
    return codec['allocation'](raw)


def validate_parser(codec, raw, manifest):
    decode, require, digest, sha = (codec[name] for name in ('decode', 'require', 'digest', 'sha'))
    MAX_MANIFEST, MAX_MEMBER = codec['MAX_MANIFEST'], codec['MAX_MEMBER']
    value = decode(raw['parser-manifest.json'], MAX_MANIFEST)
    keys = {'schema_version', 'kind', 'sources', 'build_options', 'builder_sha256',
            'compiler_version', 'compiler_sha256', 'runtime_version', 'runtime_sha256',
            'output', 'hosted_admitted', 'source_network_enabled'}
    require(type(value) is dict and set(value) == keys and type(value['schema_version']) is int
            and value['schema_version'] == 1 and value['kind'] == 'local_metadata_parser_bundle'
            and value['hosted_admitted'] is False and value['source_network_enabled'] is False,
            'invalid_parser_manifest')
    require(value['runtime_sha256'] == manifest['deno_sha256']
            and value['runtime_version'] == manifest['deno_version']
            and 'linux' in value['runtime_version'].split('\n')[0]
            and value['compiler_version'] == '0.28.2'
            and digest(value['compiler_sha256']) and digest(value['builder_sha256']),
            'parser_runtime_mismatch')
    require(type(value['output']) is dict and type(value['output'].get('bytes')) is int
            and value['output'] == {'file': 'parser.mjs', 'bytes': len(raw['parser.mjs']),
                                   'sha256': sha(raw['parser.mjs'])}, 'parser_output_mismatch')
    options = ['workers/source-gateway/parse-metadata.ts', '--bundle', '--platform=neutral',
               '--format=esm', '--target=es2022', '--main-fields=main', '--conditions=default',
               '--charset=utf8', '--legal-comments=inline', '--outfile=parser.mjs', '--metafile=graph.json']
    require(value['build_options'] == options, 'parser_build_options_changed')
    sources = value['sources']
    required = {'workers/source-gateway/parse-metadata.ts', 'supabase/functions/_shared/arxiv.ts',
                'supabase/functions/_shared/http.ts', 'supabase/functions/_shared/source-xml.ts'}
    require(type(sources) is dict and required <= set(sources) and len(sources) <= 32,
            'parser_sources_changed')
    total = 0
    for name, row in sources.items():
        require(type(name) is str and (name in required or re.fullmatch(
            r'node_modules/(saxes|xmlchars)/[A-Za-z0-9_./-]+\.(js|json)', name))
            and '..' not in Path(name).parts and type(row) is dict
            and set(row) == {'bytes', 'sha256'} and type(row['bytes']) is int
            and 0 < row['bytes'] <= MAX_MEMBER and digest(row['sha256']), 'invalid_parser_source')
        total += row['bytes']
    require(total <= 524_288, 'parser_sources_capacity')
    return value


def validate_python_graph(codec, captured):
    # Isolated Python supplies only its standard library. These are static
    # import checks, not a claim that Python itself is a capability sandbox.
    portable_stdlib = set(('argparse ast base64 binascii contextlib copy ctypes datetime email errno '
        'fcntl hashlib http importlib json math os pathlib platform re select selectors signal '
        'socket ssl stat struct subprocess sys tempfile threading time types urllib uuid').split())
    standard = set(getattr(sys, 'stdlib_module_names', portable_stdlib)) | set(sys.builtin_module_names)
    local = {name[:-3] for name in captured if name.endswith('.py') and name != 'bootstrap.py'} | {'frozen_context'}
    for name, raw in captured.items():
        if not name.endswith('.py'):
            continue
        for node in ast.walk(ast.parse(raw, filename=name)):
            if isinstance(node, ast.Import):
                imports = [item.name.split('.')[0] for item in node.names]
            elif isinstance(node, ast.ImportFrom):
                codec['require'](node.level == 0 and node.module is not None, 'relative_bundle_import')
                imports = [node.module.split('.')[0]]
            else:
                continue
            codec['require'](all(item in local or item in standard for item in imports), 'unclosed_python_graph')


def assemble(codec, captured, runtime_inventory, runtimes, parent, recipe):
    """Pure assembly over owned bytes. The builder module is provenance, not runtime."""
    require, sha, canonical = codec['require'], codec['sha'], codec['canonical']
    require(set(captured) == codec['MEMBERS'] and all(type(raw) is bytes and 0 < len(raw) <=
            codec['MAX_MEMBER'] for raw in captured.values()), 'invalid_capture')
    validate_python_graph(codec, captured)
    runtime_inventory = codec['inventory'](runtime_inventory)
    parent = codec['absolute'](str(parent))
    require(type(recipe) is bytes and 0 < len(recipe) <= 32_768, 'invalid_builder_recipe')
    require(set(runtimes) == set(codec['RUNTIME_NAMES']), 'invalid_runtime_set')
    result = {'schema_version': 1, 'mode': 'linux_metadata_fixture',
              'files': {name: sha(raw) for name, raw in captured.items()},
              'file_bytes': {name: len(raw) for name, raw in captured.items()},
              'bootstrap_sha256': sha(captured['bootstrap.py']), 'builder_sha256': sha(recipe),
              'runtime_inventory': runtime_inventory, 'runtime_inventory_sha256': sha(canonical(runtime_inventory)),
              'tls_version': runtime_inventory['tls_version'], 'source_network_enabled': False,
              'hosted_admitted': False, 'supervisor_uid': 62401, 'source_uid': 62402,
              'executor_uid': 62403, 'entrypoints': codec['ENTRIES'], 'bundle_parent': str(parent),
              'journal_allocation': 'fixed-record-inodes-v2',
              'payload_bytes': sum(map(len, captured.values())), 'bundle_bytes': 0,
              'unit_bytes': codec['unit_size'](captured, parent / ('0' * 64)),
              'source_bytes': 0, 'source_limit': source_limit(codec, captured['witness_slots.py'])}
    for name, runtime in runtimes.items():
        require(type(runtime) is dict and set(runtime) == {'path', 'sha256', 'bytes'}, 'invalid_runtime_record')
        result.update({name + '_' + key: value for key, value in runtime.items()})
        result[name + '_version'] = runtime_inventory[name + '_version']
    # Only the decimal lengths of these two charged counters depend on the
    # canonical manifest length. Their small fixed point does not hash itself.
    for _ in range(8):
        encoded = canonical(result)
        bundle_bytes = result['payload_bytes'] + len(encoded)
        source_bytes = bundle_bytes + result['unit_bytes']
        if (result['bundle_bytes'], result['source_bytes']) == (bundle_bytes, source_bytes):
            root = parent / sha(encoded)
            validate_parser(codec, captured, result)
            codec['validate_material'](captured, encoded, root)
            return result, encoded, root
        result['bundle_bytes'], result['source_bytes'] = bundle_bytes, source_bytes
    raise ValueError('manifest_size_did_not_converge')


def publish(codec, parent, root, captured, manifest_raw):
    """No replacement/retry: partial output is retained for explicit inspection."""
    codec['trusted_directory'](parent)
    os.mkdir(root, 0o700)
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for name, raw in {**captured, 'bundle.json': manifest_raw}.items():
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o400, dir_fd=directory)
            try:
                offset = 0
                while offset < len(raw):
                    count = os.write(fd, raw[offset:offset + 65_536])
                    codec['require'](count > 0, 'bundle_write_failed')
                    offset += count
                os.fchmod(fd, 0o444)
                os.fsync(fd)
            finally:
                os.close(fd)
        os.fsync(directory)
        os.fchmod(directory, 0o555)
        os.fsync(directory)
    finally:
        os.close(directory)
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def build(output_parent, parser_directory, runtime_inventory_path, *, python_path, deno_path, psql_path):
    source = Path(__file__).resolve().parent
    recipe = globals().get('_CAPTURED_RECIPE')
    if type(recipe) is not bytes or sys.platform != 'linux' or os.getuid() != 0:
        raise ValueError('captured_linux_root_builder_required')
    # The helper code itself is captured before import, and the exact same bytes
    # become bootstrap.py. No application member is executed during packaging.
    bootstrap = read_recipe(source / 'metadata_bootstrap.py')
    codec = {'__name__': 'captured_metadata_bundle_codec', '__file__': str(source / 'metadata_bootstrap.py')}
    exec(compile(bootstrap, codec['__file__'], 'exec'), codec)
    captured = {name: codec['read_regular'](source.parent / name, codec['MAX_MEMBER']) for name in GATEWAY_FILES}
    captured.update({target: codec['read_regular'](source / name, codec['MAX_MEMBER'])
                     for name, target in LOCAL_FILES.items() if target != 'bootstrap.py'})
    captured['bootstrap.py'] = bootstrap
    parser = Path(parser_directory)
    captured['parser.mjs'] = codec['read_regular'](parser / 'parser.mjs', codec['MAX_MEMBER'])
    captured['parser-manifest.json'] = codec['read_regular'](parser / 'manifest.json', codec['MAX_MANIFEST'])
    observed = codec['inventory'](codec['decode'](codec['read_regular'](
        Path(runtime_inventory_path), codec['MAX_INVENTORY']), codec['MAX_INVENTORY']))
    codec['require'](platform.machine() == observed['architecture'] and platform.release() == observed['kernel_release']
                     and sys.version == observed['python_version'] and ssl.OPENSSL_VERSION == observed['tls_version'],
                     'runtime_inventory_not_current')
    paths = {'python': Path(python_path), 'deno': Path(deno_path), 'psql': Path(psql_path)}
    codec['require'](str(Path(sys.executable).resolve(strict=True)) == str(paths['python']), 'python_path_changed')
    runtimes = {name: codec['executable'](path, observed['architecture']) for name, path in paths.items()}
    parent = codec['trusted_directory'](output_parent)
    manifest, encoded, root = assemble(codec, captured, observed, runtimes, parent, recipe)
    codec['check_runtime'](manifest)
    publish(codec, parent, root, captured, encoded)
    # Validate persisted bytes and exact runtime bindings before returning an
    # identity. A failed/partial destination is never removed or overwritten.
    saved, _ = codec['load_bundle'](root)
    codec['require'](saved == manifest, 'published_bundle_changed')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output_parent', type=Path)
    parser.add_argument('parser_directory', type=Path)
    parser.add_argument('runtime_inventory', type=Path)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--deno', required=True, type=Path)
    parser.add_argument('--psql', required=True, type=Path)
    args = parser.parse_args()
    result = build(args.output_parent, args.parser_directory, args.runtime_inventory,
                   python_path=args.python, deno_path=args.deno, psql_path=args.psql)
    import hashlib
    import json
    raw = json.dumps(result, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()
    print(json.dumps({'bundle_sha256': hashlib.sha256(raw).hexdigest(), 'source_bytes': result['source_bytes'],
                      'hosted_admitted': False, 'source_network_enabled': False}, sort_keys=True))


if __name__ == '__main__':
    try:
        recipe = read_recipe(Path(__file__))
        scope = {'__name__': 'captured_metadata_bundle_builder', '__file__': __file__, '_CAPTURED_RECIPE': recipe}
        exec(compile(recipe, __file__, 'exec'), scope)
        scope['main']()
    except Exception:
        raise SystemExit('metadata_builder_refused')
