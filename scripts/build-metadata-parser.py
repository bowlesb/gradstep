#!/usr/bin/env python3
"""Bundle the metadata parser from captured local sources and installed tools.

The generated JavaScript is a separately identified parser artifact, not a
transport or hosted-runtime admission. Only the selected local TS files and
saxes/xmlchars packages are copied into the temporary build tree.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILES = (
    'workers/source-gateway/parse-metadata.ts',
    'supabase/functions/_shared/arxiv.ts',
    'supabase/functions/_shared/http.ts',
    'supabase/functions/_shared/source-xml.ts',
)
PACKAGES = {'saxes': '6.0.0', 'xmlchars': '2.2.0'}
ESBUILD_VERSION = '0.28.2'
MAX_INPUT_BYTES = 524_288
MAX_OUTPUT_BYTES = 524_288
MAX_TOOL_BYTES = 268_435_456


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def capture_executable(source, target):
    value = hashlib.sha256()
    count = 0
    with source.open('rb') as executable, target.open('xb') as captured:
        for block in iter(lambda: executable.read(1_048_576), b''):
            count += len(block)
            if count > MAX_TOOL_BYTES:
                raise ValueError('parser_tool_capacity')
            value.update(block)
            captured.write(block)
    target.chmod(0o500)
    return value.hexdigest()


def compiler():
    system = {'Darwin': 'darwin', 'Linux': 'linux'}.get(platform.system())
    arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64'}.get(platform.machine())
    if system is None or arch is None:
        raise ValueError('unsupported_local_build_platform')
    package = ROOT / 'node_modules' / '@esbuild' / (system + '-' + arch)
    installed = json.loads((package / 'package.json').read_bytes())
    if installed['version'] != ESBUILD_VERSION:
        raise ValueError('parser_compiler_version')
    return (package / 'bin/esbuild').resolve()


def build(destination):
    destination = Path(destination).resolve()
    if destination.exists():
        raise ValueError('parser_destination_exists')
    captured = {name: (ROOT / name).read_bytes() for name in SOURCE_FILES}
    for name, version in PACKAGES.items():
        package_root = ROOT / 'node_modules' / name
        for source in sorted(package_root.rglob('*')):
            if source.is_file() and source.suffix in ('.js', '.json'):
                captured[source.relative_to(ROOT).as_posix()] = source.read_bytes()
        package = json.loads(captured['node_modules/' + name + '/package.json'])
        if package['name'] != name or package['version'] != version:
            raise ValueError('parser_dependency_version')
    if (len(captured) > 32 or any(not raw or len(raw) > 131_072 for raw in captured.values())
            or sum(map(len, captured.values())) > MAX_INPUT_BYTES):
        raise ValueError('parser_source_capacity')
    # Invoke the explicitly installed native compiler directly. Deno's bundle
    # command can download its internal compiler even with --no-npm/--no-remote;
    # this build does not use that implicit toolchain or package installation.
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
           'DENO_NO_UPDATE_CHECK': '1', 'DENO_NO_PROMPT': '1', 'NO_COLOR': '1'}
    with tempfile.TemporaryDirectory(prefix='science-reader-parser-build-') as temporary:
        root = Path(temporary)
        esbuild, deno = root / 'esbuild', root / 'deno'
        compiler_sha = capture_executable(compiler(), esbuild)
        runtime_sha = capture_executable((ROOT / 'node_modules/.bin/deno').resolve(), deno)
        compiler_version = subprocess.run([str(esbuild), '--version'], check=True, capture_output=True,
                                          text=True, timeout=5, env=env).stdout.strip()
        if compiler_version != ESBUILD_VERSION:
            raise ValueError('parser_compiler_version')
        version = subprocess.run([str(deno), '--version'], check=True, capture_output=True,
                                 text=True, timeout=5, env=env).stdout.strip()
        for name, raw in captured.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            target.chmod(0o400)
        command = [str(esbuild), 'workers/source-gateway/parse-metadata.ts', '--bundle',
                   '--platform=neutral', '--format=esm', '--target=es2022',
                   '--main-fields=main', '--conditions=default', '--charset=utf8',
                   '--legal-comments=inline', '--outfile=parser.mjs', '--metafile=graph.json']
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, timeout=30)
        if result.returncode:
            # Every input is local source; no input payload or credential exists
            # at build time. Keep tool errors bounded and off the artifact.
            raise RuntimeError('parser_bundle_failed: ' + result.stderr[:4096].decode('utf8', 'replace'))
        output = (root / 'parser.mjs').read_bytes()
        if not output or len(output) > MAX_OUTPUT_BYTES:
            raise ValueError('parser_output_capacity')
        graph = json.loads((root / 'graph.json').read_bytes())
        # This checks the static dependency graph. Variable-based imports or
        # loaders require review of the exact output before runtime admission;
        # an empty esbuild imports list is not a general JavaScript sandbox.
        if (not set(graph['inputs']).issubset(captured)
                or set(graph['outputs']) != {'parser.mjs'} or graph['outputs']['parser.mjs']['imports']):
            raise ValueError('parser_static_graph_not_closed')
        manifest = {'schema_version': 1, 'kind': 'local_metadata_parser_bundle',
                    'sources': {name: {'sha256': digest(raw), 'bytes': len(raw)} for name, raw in captured.items()},
                    'build_options': command[1:], 'builder_sha256': digest(_CAPTURED_RECIPE),
                    'compiler_version': ESBUILD_VERSION, 'compiler_sha256': compiler_sha,
                    'runtime_version': version, 'runtime_sha256': runtime_sha,
                    'output': {'file': 'parser.mjs', 'bytes': len(output), 'sha256': digest(output)},
                    'hosted_admitted': False, 'source_network_enabled': False}
        destination.mkdir(mode=0o700, parents=True)
        (destination / 'parser.mjs').write_bytes(output)
        (destination / 'manifest.json').write_bytes(canonical(manifest))
        (destination / 'parser.mjs').chmod(0o400)
        (destination / 'manifest.json').chmod(0o400)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    manifest = build(args.destination)
    print(json.dumps({'output': manifest['output'], 'hosted_admitted': False}, sort_keys=True))


if __name__ == '__main__':
    # Execute the same captured recipe bytes named in the artifact. An edit to
    # this development script during compilation cannot relabel old execution
    # with the new recipe's hash. This small loader grants no runtime admission.
    recipe = Path(__file__).read_bytes()
    if not recipe or len(recipe) > 32_768:
        raise ValueError('parser_recipe_capacity')
    scope = {'__name__': 'captured_metadata_parser_builder', '__file__': __file__,
             '_CAPTURED_RECIPE': recipe}
    exec(compile(recipe, __file__, 'exec'), scope)
    scope['main']()
