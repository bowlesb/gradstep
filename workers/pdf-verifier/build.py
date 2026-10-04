#!/usr/bin/env python3
"""Project-local reproducible macOS arm64 prototype build. No global installs.

All downloads, caches, generated source and binaries stay under .artifacts.
The SDK port recipes themselves verify the pinned zlib/libjpeg SHA-512s.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import uuid
import build_store

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parent.parent
OUT = REPO / '.artifacts/pdf-verifier'
LOCK = json.loads((SOURCE / 'dependencies.lock.json').read_text())


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1048576), b''):
            value.update(part)
    return value.hexdigest()


def dependency(item):
    download = OUT / 'downloads' / item['url'].rsplit('/', 1)[-1]
    download.parent.mkdir(parents=True, exist_ok=True)
    # The SDK's platform-specific name is recorded separately from the URL name.
    if item['version'] == '6.0.11':
        existing = download.parent / 'emscripten-6.0.11-macos-arm64.tar.xz'
        if existing.exists() and not download.exists():
            existing.rename(download)
    if not download.exists():
        temporary = download.with_suffix(download.suffix + '.partial')
        size = 0
        with urllib.request.urlopen(item['url'], timeout=30) as response, temporary.open('wb') as target:
            for part in iter(lambda: response.read(1048576), b''):
                size += len(part)
                if size > item['maximum_bytes']:
                    raise RuntimeError('dependency download exceeds pinned bound')
                target.write(part)
        if digest(temporary) != item['sha256']:
            raise RuntimeError('dependency SHA256 mismatch')
        temporary.rename(download)
    if download.stat().st_size > item['maximum_bytes'] or digest(download) != item['sha256']:
        raise RuntimeError('cached dependency SHA256 mismatch')
    destination = OUT / item['directory']
    root = destination / item['root']
    marker = root / '.pdf-verifier-source-sha256'
    if marker.exists() and marker.read_text() == item['sha256']:
        return root
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(download) as archive:
        # Works with the system Python3.9 used only for bootstrap. Refuse paths,
        # devices and links outside this dedicated extraction directory.
        prefix = str(destination.resolve()) + os.sep
        for member in archive.getmembers():
            target = destination / member.name
            if not str(target.resolve()).startswith(prefix) or member.isdev():
                raise RuntimeError('unsafe dependency archive entry')
            if member.issym() and not str((target.parent / member.linkname).resolve()).startswith(prefix):
                raise RuntimeError('unsafe dependency symlink')
            if member.islnk() and not str((destination / member.linkname).resolve()).startswith(prefix):
                raise RuntimeError('unsafe dependency hardlink')
        if root.exists():
            # A previous manual/interrupted bootstrap may already have unpacked
            # the signed CMake app. Verify its archive-owned files rather than
            # overwriting a macOS signed bundle in place.
            for member in archive.getmembers():
                target = destination / member.name
                if member.isdir():
                    if not target.is_dir():
                        raise RuntimeError('incomplete dependency directory: ' + str(target))
                elif member.issym():
                    if not target.is_symlink() or os.readlink(target) != member.linkname:
                        raise RuntimeError('dependency symlink differs: ' + str(target))
                elif member.isfile() or member.islnk():
                    stream = archive.extractfile(member)
                    expected = hashlib.sha256()
                    for part in iter(lambda: stream.read(1048576), b''):
                        expected.update(part)
                    if not target.is_file() or digest(target) != expected.hexdigest():
                        raise RuntimeError('dependency file differs: ' + str(target))
                else:
                    raise RuntimeError('unsupported dependency archive entry')
        else:
            archive.extractall(destination)
    marker.write_text(item['sha256'])
    return root


def main():
    arguments = argparse.ArgumentParser()
    arguments.add_argument('--link-only', action='store_true', help='Reuse this profile’s already-built static library')
    arguments.add_argument('--clean-library', action='store_true', help='Recompile the static library to check reproducibility')
    args = arguments.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This pinned prototype bootstrap supports macOS arm64 only; no silent toolchain substitution.')
    if not shutil.which('node'):
        raise SystemExit('An existing Node executable is required for the compiler; no global installation is performed.')
    node_version = subprocess.check_output([shutil.which('node'), '--version'], text=True).strip()
    if node_version != 'v24.18.0':
        raise SystemExit('This reproducibility profile requires the existing Node v24.18.0; no global install is performed.')
    OUT.mkdir(parents=True, exist_ok=True)
    build_lock = (OUT / '.build.lock').open('a')
    fcntl.flock(build_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    distribution = OUT / 'working-builds' / str(uuid.uuid4())
    captured = distribution / 'source'
    captured.mkdir(parents=True)
    source_inputs = {name: build_store.read(SOURCE / name) for name in
                     [*build_store.SOURCES, 'profile.json', 'build_store.py']}
    if json.loads(source_inputs['dependencies.lock.json']) != LOCK:
        raise SystemExit('Dependency inputs changed before capture; restart the build.')
    for name, raw in source_inputs.items():
        (captured / name).write_bytes(raw)
        (captured / name).chmod(0o444)
    # Do not reuse the mutable legacy dist directory. An older measured build
    # must already have a checked source/executable snapshot before replacing
    # any dependency cache or selecting a newer build for local tests.
    legacy = OUT / 'dist/identity.json'
    if legacy.exists():
        build_store.open_bundle(build_store.digest(build_store.read(legacy)))
    sdk = dependency(LOCK['emscripten_macos_arm64'])
    cmake = dependency(LOCK['cmake_macos']) / 'CMake.app/Contents/bin'
    python = dependency(LOCK['python_macos_arm64'])
    qpdf = dependency(LOCK['qpdf'])
    em = sdk / 'emscripten'
    config = OUT / 'emscripten.config.py'
    config.write_text('LLVM_ROOT = ' + repr(str(sdk / 'bin')) + '\nBINARYEN_ROOT = ' + repr(str(sdk)) + '\nNODE_JS = ' + repr(shutil.which('node')) + '\n')
    environment = os.environ.copy()
    (OUT / 'tmp').mkdir(exist_ok=True)
    environment.update(EM_CONFIG=str(config), EM_CACHE=str(OUT / 'cache'), EMCC_CORES='4',
                       TMPDIR=str(OUT / 'tmp'),
                       EMSDK_PYTHON=str(python / 'bin/python3'),
                       SSL_CERT_FILE=str(python / 'lib/python3.13/site-packages/certifi/cacert.pem'),
                       PATH=str(cmake) + os.pathsep + str(em) + os.pathsep + environment['PATH'])
    # No inherited compiler flags may silently change the pinned verifier.
    for key in ('CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'EMCC_CFLAGS', 'EMCC_FORCE_STDLIBS'):
        environment.pop(key, None)
    build = OUT / 'qpdf-build'
    # embuilder's fresh-cache port setup expects this directory to exist.
    (OUT / 'cache/sysroot/lib/pkgconfig').mkdir(parents=True, exist_ok=True)
    flags = '-fwasm-exceptions -O3'
    commands = []
    if not args.link_only:
        commands += [[str(em / 'embuilder'), 'build', 'zlib', 'libjpeg'],
                     [str(em / 'emcmake'), 'cmake', '-S', str(qpdf), '-B', str(build),
                      '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_STATIC_LIBS=ON',
                      '-DBUILD_DOC=OFF', '-DINSTALL_EXAMPLES=OFF', '-DUSE_IMPLICIT_CRYPTO=OFF',
                      '-DREQUIRE_CRYPTO_NATIVE=ON', '-DPKG_CONFIG_EXECUTABLE=/usr/bin/false',
                      '-DCMAKE_C_FLAGS=' + flags, '-DCMAKE_CXX_FLAGS=' + flags,
                      '-DZLIB_H_PATH=' + str(OUT / 'cache/sysroot/include'),
                      '-DZLIB_LIB_PATH=' + str(OUT / 'cache/sysroot/lib/wasm32-emscripten/libz.a'),
                      '-DLIBJPEG_H_PATH=' + str(OUT / 'cache/sysroot/include'),
                      '-DLIBJPEG_LIB_PATH=' + str(OUT / 'cache/sysroot/lib/wasm32-emscripten/libjpeg.a')],
                     ['cmake', '--build', str(build), '--target', 'libqpdf', '-j', '4'] +
                     (['--clean-first'] if args.clean_library else [])]
    linked_library = distribution / 'libqpdf.a'
    link = [str(em / 'em++'), str(captured / 'verifier.cpp'), '-I' + str(qpdf / 'include'),
            '-I' + str(build / 'include'), str(linked_library), '-std=c++20',
            '-O3', '-fwasm-exceptions', '--use-port=zlib', '--use-port=libjpeg',
            '-sALLOW_MEMORY_GROWTH=0', '-sINITIAL_MEMORY=67108864', '-sSTACK_SIZE=2097152',
            '-sSTACK_OVERFLOW_CHECK=2', '-sABORTING_MALLOC=1', '-sALLOW_TABLE_GROWTH=0',
            '-sDYNAMIC_EXECUTION=0', '-sMODULARIZE=1', '-sEXPORT_ES6=1', '-sENVIRONMENT=web',
            '-sFILESYSTEM=0',
            '-sINCOMING_MODULE_JS_API=instantiateWasm,print,printErr,onAbort',
            '-sEXPORTED_FUNCTIONS=_pdfv_abi,_pdfv_parser_version,_pdfv_stack_bytes,_pdfv_verify,_malloc,_free',
            '-sEXPORTED_RUNTIME_METHODS=HEAPU8', '-o', str(distribution / 'verifier.mjs')]
    commands.append(link)
    linked_library_sha256 = None
    with (distribution / 'build.log').open('w') as log:
        for command in commands:
            if command is link:
                # Link an owned byte copy even when reusing the library cache.
                library_bytes = build_store.read(build / 'libqpdf/libqpdf.a')
                linked_library_sha256 = build_store.digest(library_bytes)
                linked_library.write_bytes(library_bytes)
                linked_library.chmod(0o444)
            print('Running ' + Path(command[0]).name, flush=True)
            result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
            log.flush()
            if result.returncode:
                raise SystemExit('Build failed; see ' + str(distribution / 'build.log'))
    if any(build_store.read(captured / name) != raw for name, raw in source_inputs.items()) or digest(linked_library) != linked_library_sha256:
        raise SystemExit('Captured build inputs changed during compilation; refusing publication.')
    profile = json.loads(source_inputs['profile.json'])
    canonical_profile = json.dumps(profile, sort_keys=True, separators=(',', ':')).encode()
    manifest = {'profile': profile, 'profile_sha256': hashlib.sha256(canonical_profile).hexdigest(),
                'wasm_sha256': digest(distribution / 'verifier.wasm'),
                'javascript_sha256': digest(distribution / 'verifier.mjs'),
                'wrapper_sha256': digest(captured / 'verifier.cpp'),
                'dependencies_sha256': digest(captured / 'dependencies.lock.json'),
                'runtime_sha256': digest(captured / 'runtime.ts'),
                'memory_inspector_sha256': digest(captured / 'wasm.ts'),
                'build_recipe_sha256': digest(captured / 'build.py'),
                'build_store_sha256': digest(captured / 'build_store.py'),
                'qpdf_library_sha256': digest(linked_library),
                'cmake_cache_sha256': digest(build / 'CMakeCache.txt'),
                'compiler_flags': flags,
                'node_version': node_version,
                'link_settings': link[link.index('-std=c++20'):-2],
                'commands_run': commands,
                'link_arguments': link[1:]}
    # Stable deployment identity contains no local absolute path or invocation
    # history; keep those provenance details beside it for reproducibility.
    identity = {key: value for key, value in manifest.items()
                if key not in ('commands_run', 'link_arguments', 'cmake_cache_sha256')}
    identity_bytes = json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()
    manifest['build_identity_sha256'] = hashlib.sha256(identity_bytes).hexdigest()
    (distribution / 'identity.json').write_bytes(identity_bytes)
    (distribution / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    bundle = build_store.freeze(distribution, source=captured, expected=manifest['build_identity_sha256'], library=linked_library)
    if any(build_store.read(SOURCE / name) != raw for name, raw in source_inputs.items()):
        raise SystemExit('Build preserved, but live source changed during compilation; current build was not selected.')
    # This pointer is only a local test convenience. Hosted packaging must pin
    # an explicitly reviewed digest and may not follow the current pointer.
    with tempfile.NamedTemporaryFile(dir=OUT, prefix='.current-build-', delete=False) as stream:
        pointer = Path(stream.name)
        stream.write(build_store.canonical({'format': 1, 'identity_sha256': manifest['build_identity_sha256']}))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(pointer, OUT / 'current-build.json')
    build_store.fsync_directory(OUT)
    print(json.dumps({**{key: manifest[key] for key in ('profile_sha256', 'wasm_sha256', 'javascript_sha256', 'build_identity_sha256')},
                      'bundle': str(bundle.relative_to(REPO))}))


if __name__ == '__main__':
    main()
