"""Portable protocol/ownership tests; no privilege changes, Deno or services.

Mock wait/status records here exercise rejection and orchestration only. They
are not Linux runtime evidence, resource measurements or authority receipts.
The parent runs these tests; the marked Linux fixture supplies real evidence.
"""
import copy
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

import verifier_probe_runtime as probe
from common import canonical
from protocol import digest

CLAIM = 'f1000000-0000-4000-8000-000000000001'
PREDECESSOR = 'f1000000-0000-4000-8000-000000000002'
EXECUTION = 'f1000000-0000-4000-8000-000000000003'
RESERVATION = 'f1000000-0000-4000-8000-000000000004'
NOW = 1_000_000_000
PATH = '/var/lib/timestep-verifier-probe/fixture/control/config.json'


class Bundle:
    root = Path('/opt/timestep-verifier-lab/fixture/bundle')
    sha256 = 'b' * 64
    build_identity_sha256 = '39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610'
    profile_sha256 = 'c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962'
    profile_id = 'qpdf-wasm-pilot-v1'
    manifest = {'files': {'verifier.wasm': {'sha256': 'c' * 64}}}


def config_value(*, fd=None):
    guardian = {'device': '2', 'inode': '4'} if fd is None else {
        'device': str(os.fstat(fd).st_dev), 'inode': str(os.fstat(fd).st_ino)}
    sealed = {'format': 'original-spool-v1', 'reservation_id': RESERVATION, 'claim_id': PREDECESSOR,
              'attempt_id': 'f1000000-0000-4000-8000-000000000005', 'purpose': 'stored_readback',
              'request_sha256': '1' * 64, 'binding_sha256': '2' * 64, 'capture_sha256': '3' * 64,
              'sha256': '4' * 64, 'bytes': 8, 'producer': {'device': '2', 'inode': '3'}, 'guardian': guardian}
    raw = canonical(sealed) + b'\n'
    request = {'version': 1, 'kind': 'original_verify', 'job_id': 'f1000000-0000-4000-8000-000000000006',
               'reservation_id': RESERVATION, 'source_id': '1706.03762', 'source_revision': 1,
               'bucket': 'paper-assets', 'path': 'originals/' + RESERVATION + '/original.pdf',
               'predecessor_operation_id': PREDECESSOR, 'predecessor_result_sha256': '5' * 64,
               'candidate_sha256': sealed['sha256'], 'candidate_bytes': 8, 'input_spool_sha256': digest(raw),
               'byte_ceiling': 8, 'verification_profile_id': 'f1000000-0000-4000-8000-000000000007',
               'stage_recipe_sha256': '6' * 64, 'build_sha256': Bundle.build_identity_sha256,
               'parser_profile_sha256': Bundle.profile_sha256, 'verifier_host_policy_sha256': '7' * 64,
               'storage_policy_sha256': '8' * 64, 'spool_policy_sha256': '9' * 64}
    value = {'format': 'original-verifier-input-v1', 'local_fixture_only': True, 'claim_id': CLAIM,
             'request': request, 'request_sha256': 'a' * 64, 'spool_descriptor': raw.decode()}
    return {'format': 'linux-verifier-probe-config-v1', 'local_fixture_only': True,
            'bundle_path': str(Bundle.root), 'bundle_sha256': Bundle.sha256, 'input': value,
            'execution_id': EXECUTION, 'binding_sha256': 'd' * 64,
            'startup_deadline_ns': str(NOW + 5_000_000_000),
            'go_deadline_ns': str(NOW + 10_000_000_000),
            'collection_deadline_ns': str(NOW + 19_000_000_000)}


def go_value(config):
    return dict(probe._identity_fields(config), format='linux-verifier-probe-go-v1',
                local_fixture_only=True, binding_sha256=config['binding_sha256'],
                deadline_ns=str(NOW + 4_000_000_000))


def process_value(pid, uid, parent, threads=1):
    return {'process_id': pid, 'process_start_id': str(pid * 10),
            'boot_id': 'f1000000-0000-4000-8000-000000000008',
            'cgroup': '0::/tsverifierfixture.slice/tsverifierfixture.service\n',
            'status': {'pid': pid, 'parent_pid': parent, 'uids': [uid] * 4, 'gids': [uid] * 4,
                       'groups': [], 'caps': {k: 0 for k in probe.uid_policy.CAP_FIELDS},
                       'no_new_privs': 1, 'threads': threads, 'seccomp': 2}}


def ready_value(config):
    return dict(probe._identity_fields(config), format='linux-verifier-probe-supervisor-ready-v1',
                local_fixture_only=True, supervisor=process_value(300, 62401, 200),
                deno=process_value(400, 62402, 300, 8),
                control={'child_fd': 9, 'device': '2', 'inode': '5', 'uid': 0, 'gid': 62402, 'mode': 0o440},
                input={'device': '2', 'inode': '4', 'bytes': 8, 'offset': 0, 'access_mode': 'read-only'})


def wait_value(pid, *, code=0, missing_metrics=False):
    usage = {k: 0 for k in probe.USAGE_COUNTERS}
    usage.update(ru_utime=0.02, ru_stime=0.003, ru_maxrss=1024)
    return {'format': 'wait4-child-retirement-v1', 'pid': pid, 'wait_status': code * 256 if code >= 0 else -code,
            'returncode': code, 'platform': 'linux', 'maxrss_unit': 'KiB',
            'rusage': None if missing_metrics else usage,
            'metrics': None if missing_metrics else {'cpu_ms': 23, 'peak_process_bytes': 1048576},
            'metrics_error': 'invalid_rusage' if missing_metrics else None}


def session_value(config, *, code=0, missing_wait=False):
    complete = code == 0 and not missing_wait
    result = dict(probe._identity_fields(config), format='original-verifier-result-v1', local_fixture_only=True,
                  request_sha256=config['input']['request_sha256'], go_sha256='e' * 64, kind='parsed', reason=None,
                  parser_result={'outcome': 'verified', 'sha256': config['input']['request']['candidate_sha256'],
                                 'bytes': 8, 'profileID': Bundle.profile_id, 'profileSHA256': Bundle.profile_sha256,
                                 'wasmSHA256': 'c' * 64, 'elapsedMS': 1.25, 'pages': 1})
    return {'format': 'original-verifier-session-v1', 'local_fixture_only': True, 'hosted_admitted': False,
            'complete': complete, 'verified': complete, 'result': result if complete else None,
            'reason': None if complete else 'child_exit', 'child_retired': not missing_wait,
            'ipc_cleanup_complete': not missing_wait, 'retirement': None if missing_wait else wait_value(400, code=code),
            'lost_wait_authority': False, 'spawn_to_wait_wall_ms': None if missing_wait else 25.5}


def supervisor_value(config, *, code=0, missing_wait=False):
    session = session_value(config, code=code, missing_wait=missing_wait)
    return dict(probe._identity_fields(config), format='linux-verifier-probe-supervisor-result-v1',
                local_fixture_only=True, ready=True, go_received=True,
                reason=None if session['complete'] else 'receiver_failed', session=session, ipc_cleanup_complete=True)


def line(value):
    return canonical(value) + b'\n'


class ProtocolTests(unittest.TestCase):
    def test_config_owned_closed_binding_and_finite_deadlines(self):
        config = config_value()
        checked = probe.checked_config(line(config), Bundle(), now=NOW)
        config['input']['request']['candidate_bytes'] = 50
        self.assertEqual(checked['input']['request']['candidate_bytes'], 8)
        for update in ({'unknown': 1}, {'local_fixture_only': False},
                       {'bundle_sha256': 'f' * 64}, {'startup_deadline_ns': str(NOW)},
                       {'collection_deadline_ns': str(NOW + probe.MAX_NS + 1)},
                       {'go_deadline_ns': str(NOW + 19_000_000_000)},
                       {'bundle_path': '/opt/../bad'}):
            value = config_value()
            value.update(update)
            with self.subTest(update=update), self.assertRaises(Exception):
                probe.checked_config(line(value), Bundle(), now=NOW)

    def test_duplicate_bom_noncanonical_and_oversized_lines_rejected(self):
        raw = line(config_value())
        for altered in (b'\xef\xbb\xbf' + raw, raw[:-1], raw + b'\n', b' ' + raw,
                        b'{"x":1,"x":2}\n', b'[' * 2000 + b'\n', b'x' * (probe.MAX_CONFIG + 1)):
            with self.subTest(size=len(altered)), self.assertRaises(Exception):
                probe.checked_config(altered, Bundle(), now=NOW)

    def test_go_binds_every_identity_and_original_deadlines(self):
        config = config_value()
        go = go_value(config)
        self.assertEqual(probe.checked_go(line(go), config, now=NOW), go)
        for field in ('claim_id', 'execution_id', 'binding_sha256', 'input_sha256', 'bundle_sha256'):
            value = dict(go, **{field: '0' * 64})
            with self.subTest(field=field), self.assertRaises(Exception):
                probe.checked_go(line(value), config, now=NOW)
        for deadline in ('01', str(NOW), str(NOW + probe.USEFUL_NS + 1), '9' * 21):
            with self.subTest(deadline=deadline), self.assertRaises(Exception):
                probe.checked_go(line(dict(go, deadline_ns=deadline)), config, now=NOW)
        with self.assertRaises(Exception):
            probe.checked_go(line(go), config, now=int(config['go_deadline_ns']))

    def test_pdf_observation_reads_no_payload_and_rejects_offset_or_write_fd(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'payload'
            path.write_bytes(b'%PDFtest')
            fd = os.open(path, os.O_RDONLY)
            try:
                config = config_value(fd=fd)
                with patch.object(probe.os, 'read', side_effect=AssertionError('no payload reads')):
                    checked = probe.checked_pdf(fd, config['input'])
                self.assertEqual(checked['offset'], 0)
                os.lseek(fd, 1, os.SEEK_SET)
                with self.assertRaises(Exception):
                    probe.checked_pdf(fd, config['input'])
            finally:
                os.close(fd)
            fd = os.open(path, os.O_RDWR)
            try:
                with self.assertRaises(Exception):
                    probe.checked_pdf(fd, config_value(fd=fd)['input'])
            finally:
                os.close(fd)

    def test_ready_checks_uid_tree_pipe_and_no_pre_go_input_consumption(self):
        config, ready = config_value(), ready_value(config_value())
        self.assertEqual(probe.checked_ready(line(ready), config, 300, 200), ready)
        for change in ('parent', 'thread_limit', 'capability', 'pipe_mode', 'pipe_uid', 'pdf_offset'):
            changed = copy.deepcopy(ready)
            if change == 'parent':
                changed['deno']['status']['parent_pid'] = 200
            elif change == 'thread_limit':
                changed['deno']['status']['threads'] = 65
            elif change == 'capability':
                changed['deno']['status']['caps']['CapEff'] = 1
            elif change == 'pipe_mode':
                changed['control']['mode'] = 0o640
            elif change == 'pipe_uid':
                changed['control']['uid'] = 62401
            else:
                changed['input']['offset'] = 1
            with self.subTest(change=change), self.assertRaises(Exception):
                probe.checked_ready(line(changed), config, 300, 200)

    def test_result_missing_either_wait_cannot_be_positive_and_raw_failure_survives(self):
        config, ready = config_value(), ready_value(config_value())
        result = supervisor_value(config)
        self.assertTrue(probe.checked_supervisor_result(line(result), config, ready, Bundle())['session']['verified'])
        for changed in (supervisor_value(config, missing_wait=True), supervisor_value(config, code=-9)):
            checked = probe.checked_supervisor_result(line(changed), config, ready, Bundle())
            self.assertFalse(checked['session']['complete'])
            self.assertEqual(checked['session']['retirement'], changed['session']['retirement'])
        for field in ('retirement', 'result'):
            changed = copy.deepcopy(result)
            changed['session'][field] = None
            with self.subTest(field=field), self.assertRaises(Exception):
                probe.checked_supervisor_result(line(changed), config, ready, Bundle())

    def test_result_rejects_arbitrary_content_mismatched_rusage_and_boolean_metrics(self):
        config, ready = config_value(), ready_value(config_value())
        for change in ('extra_result', 'reason', 'sha', 'wait_pid', 'wait_metric', 'wait_unit', 'pages'):
            result = supervisor_value(config)
            if change == 'extra_result':
                result['session']['result']['raw_error'] = 'secret'
            elif change == 'reason':
                result['reason'] = 'arbitrary text'
            elif change == 'sha':
                result['session']['result']['parser_result']['wasmSHA256'] = '0' * 64
            elif change == 'wait_pid':
                result['session']['retirement']['pid'] = 401
            elif change == 'wait_metric':
                result['session']['retirement']['metrics']['cpu_ms'] = 1
            elif change == 'wait_unit':
                result['session']['retirement']['maxrss_unit'] = 'bytes'
            else:
                result['session']['result']['parser_result']['pages'] = True
            with self.subTest(change=change), self.assertRaises(Exception):
                probe.checked_supervisor_result(line(result), config, ready, Bundle())

    def test_pre_ready_wait_is_retained_as_negative_only_with_a_finite_pid(self):
        config = config_value()
        result = supervisor_value(config, code=2)
        result.update(ready=False, go_received=False, reason='startup_failed')
        result['session']['reason'] = 'handshake_failed'
        checked = probe.checked_supervisor_result(line(result), config, None, Bundle())
        self.assertEqual(checked['session']['retirement']['pid'], 400)
        self.assertFalse(checked['session']['complete'])
        for pid in (True, 0, 1, 1 << 31, '400'):
            altered = copy.deepcopy(result)
            altered['session']['retirement']['pid'] = pid
            with self.subTest(pid=pid), self.assertRaises(Exception):
                probe.checked_supervisor_result(line(altered), config, None, Bundle())
        with self.assertRaises(Exception):
            probe.checked_supervisor_result(line(supervisor_value(config)), config, None, Bundle())
        for field in ('ready', 'go_received'):
            altered = copy.deepcopy(result)
            altered[field] = True
            with self.subTest(field=field), self.assertRaises(Exception):
                probe.checked_supervisor_result(line(altered), config, None, Bundle())

    def test_go_pipe_requires_eof_and_refuses_second_frame(self):
        config = config_value()
        for raw, okay in ((line(go_value(config)), True), (line(go_value(config)) + b'{}\n', False)):
            reader, writer = os.pipe()
            try:
                os.write(writer, raw)
                os.close(writer)
                writer = None
                with patch.object(probe, 'clock_ns', return_value=NOW):
                    if okay:
                        self.assertEqual(probe._read_go_pipe(reader, config), go_value(config))
                    else:
                        with self.assertRaises(Exception):
                            probe._read_go_pipe(reader, config)
            finally:
                os.close(reader)
                if writer is not None:
                    os.close(writer)
        reader, writer = os.pipe()
        try:
            os.write(writer, line(go_value(config)))
            # A complete line without EOF does not authorize GO.
            with patch.object(probe, 'clock_ns', side_effect=[NOW, int(config['go_deadline_ns'])]):
                with self.assertRaisesRegex(ValueError, 'go_deadline'):
                    probe._read_go_pipe(reader, config)
        finally:
            os.close(reader)
            os.close(writer)

    def test_raw_close_is_detached_even_if_number_is_reused_before_error(self):
        fd = os.open(os.devnull, os.O_RDONLY)
        original_close, reused = os.close, []
        owner = probe.DescriptorOwner(fd)

        def uncertain(number):
            original_close(number)
            replacement = os.open(os.devnull, os.O_RDONLY)
            if replacement != number:
                os.dup2(replacement, number)
                original_close(replacement)
            reused.append(number)
            raise OSError('after close')

        try:
            with patch.object(probe.os, 'close', side_effect=uncertain):
                self.assertFalse(owner.close())
                self.assertFalse(owner.close())
            self.assertIsNone(owner.fd)
            self.assertEqual(reused, [fd])
            os.fstat(fd)
        finally:
            original_close(fd)

    def test_bootstrap_reexecution_is_same_captured_graph(self):
        context = types.SimpleNamespace(module_root=Path('/owned/modules'), manifest_sha256='a' * 64,
                                        manifest={'files': {name: 'b' * 64 for name in probe.MODULES}})
        argv = ['/owned/modules/verifier_probe_bootstrap.py', '/owned/modules', 'a' * 64, 'reaper', PATH]
        with patch.dict('sys.modules', verifier_probe_context=context), patch.object(probe.sys, 'argv', argv):
            actual = probe._supervisor_argv(PATH, 7)
            self.assertEqual(actual[1:], ['-I', '-S', '-B', *argv[:3], 'supervisor', PATH, '7'])
            context.manifest['files']['extra.py'] = 'c' * 64
            with self.assertRaises(Exception):
                probe._supervisor_argv(PATH, 7)

    def test_preopened_publication_is_bounded_single_use_and_launch_marker_is_exclusive(self):
        # Inject root ownership metadata only; exercise actual openat, inode
        # identity, O_EXCL, file writes, fsync and one-use publication locally.
        actual_fstat, actual_stat = os.fstat, os.stat

        def root_info(info):
            names = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink',
                     'st_size', 'st_mtime_ns', 'st_ctime_ns')
            value = types.SimpleNamespace(**{key: getattr(info, key) for key in names})
            value.st_uid, value.st_gid = 0, probe.REAPER_UID
            return value

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'control'
            directory.mkdir()
            for name in ('ready.json', 'report.json'):
                (directory / name).touch(mode=0o640)
                (directory / name).chmod(0o640)
            with patch.object(probe, '_trusted_directory'), \
                    patch.object(probe.os, 'fstat', side_effect=lambda fd: root_info(actual_fstat(fd))), \
                    patch.object(probe.os, 'stat', side_effect=lambda *a, **kw: root_info(actual_stat(*a, **kw))):
                files = probe.ControlFiles(str(directory / 'config.json'))
                try:
                    files.launch_spent(config_value())
                    with self.assertRaises(FileExistsError):
                        files.launch_spent(config_value())
                    files.publish('ready.json', {'format': 'test-only'})
                    with self.assertRaises(Exception):
                        files.publish('ready.json', {'replacement': True})
                    with self.assertRaises(Exception):
                        files.publish('report.json', {'padding': 'x' * probe.MAX_OUTPUT})
                    # Failed size admission has not consumed/written the slot.
                    self.assertNotIn('report.json', files.published)
                    files.publish('report.json', {'complete': False})
                finally:
                    self.assertTrue(files.close())
            self.assertEqual((directory / 'ready.json').read_bytes(), b'{"format":"test-only"}\n')
            self.assertEqual((directory / 'report.json').read_bytes(), b'{"complete":false}\n')
            self.assertEqual((directory / 'launch-spent.json').stat().st_mode & 0o777, 0o600)

    def test_preopened_output_refuses_replaced_inode_and_attempts_all_closes(self):
        actual_fstat, actual_stat = os.fstat, os.stat

        def root_info(info):
            names = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink',
                     'st_size', 'st_mtime_ns', 'st_ctime_ns')
            value = types.SimpleNamespace(**{key: getattr(info, key) for key in names})
            value.st_uid, value.st_gid = 0, probe.REAPER_UID
            return value

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'control'
            directory.mkdir()
            for name in ('ready.json', 'report.json'):
                (directory / name).touch(mode=0o640)
                (directory / name).chmod(0o640)
            with patch.object(probe, '_trusted_directory'), \
                    patch.object(probe.os, 'fstat', side_effect=lambda fd: root_info(actual_fstat(fd))), \
                    patch.object(probe.os, 'stat', side_effect=lambda *a, **kw: root_info(actual_stat(*a, **kw))):
                files = probe.ControlFiles(str(directory / 'config.json'))
                (directory / 'ready.json').unlink()
                (directory / 'ready.json').touch(mode=0o640)
                try:
                    with self.assertRaises(Exception):
                        files.publish('ready.json', {'complete': True})
                finally:
                    files.close()
            self.assertEqual((directory / 'ready.json').read_bytes(), b'')
        calls = []

        class Owned:
            def __init__(self, name, clean):
                self.name, self.clean = name, clean

            def close(self):
                calls.append(self.name)
                return self.clean

        files = probe.ControlFiles.__new__(probe.ControlFiles)
        files.outputs = {'ready.json': Owned('ready', False), 'report.json': Owned('report', True)}
        files.directory = Owned('directory', True)
        self.assertFalse(files.close())
        self.assertEqual(calls, ['ready', 'report', 'directory'])

    def test_read_at_refuses_symlink_without_following(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'target').write_bytes(b'{}\n')
            (directory / 'go.json').symlink_to(directory / 'target')
            fd = os.open(directory, os.O_RDONLY)
            try:
                with self.assertRaises(OSError):
                    probe._read_file_at(fd, 'go.json', probe.MAX_GO, 0o440, probe.REAPER_UID)
            finally:
                os.close(fd)


class Clock:
    def __init__(self):
        self.value = NOW

    def __call__(self):
        return self.value


class FakeChild:
    pid = 300
    stdout = stderr = None
    lost_authority = False

    def __init__(self):
        self.retirement = None

    def observe(self):
        return self.retirement


class RoleTests(unittest.TestCase):
    def run_reaper(self, *, supervisor_code=0, missing_wait=False, missing_metrics=False,
                   stderr=False, missing_go=False, extra_line=False, pre_ready=False, spent_failure=False):
        config, clock, events, files, child = config_value(), Clock(), [], {}, FakeChild()
        ready = ready_value(config)
        nested = supervisor_value(config, code=-9 if supervisor_code else 0)
        if pre_ready:
            nested = supervisor_value(config, code=2)
            nested.update(ready=False, go_received=False, reason='startup_failed')
            nested['session']['reason'] = 'handshake_failed'

        class Files:
            def __init__(self, path):
                self.published = set()

            def launch_spent(self, value):
                events.append('launch_spent_fsynced')
                if spent_failure:
                    raise ValueError('injected marker/fsync failure')

            def publish(self, name, value):
                self.published.add(name)
                files[name] = copy.deepcopy(value)

            def go(self):
                if missing_go:
                    raise FileNotFoundError()
                return line(go_value(config))

            def close(self):
                events.append('files_closed')
                return True

        class Output:
            def __init__(self, owner):
                self.output = bytearray()
                self.output_eof = self.stderr_eof = False
                self.reason, self.count = None, 0

            def poll(self, deadline):
                self.count += 1
                clock.value += 100_000_000
                if self.count == 1:
                    self.output.extend(line(nested if pre_ready else ready))
                    if stderr:
                        self.reason = 'supervisor_stderr'
                if self.count >= 3 and not missing_go:
                    if self.count == 3 and not pre_ready:
                        self.output.extend(line(nested))
                        if extra_line:
                            self.output.extend(b'{}\n')
                    self.output_eof = self.stderr_eof = True
                    if not missing_wait:
                        child.retirement = wait_value(300, code=2 if pre_ready else supervisor_code,
                                                      missing_metrics=missing_metrics)
                if missing_go and clock.value >= int(config['go_deadline_ns']) + 600_000_000:
                    self.output_eof = self.stderr_eof = True
                    child.retirement = wait_value(300, code=2)

            def close(self):
                events.append('pipes_closed')
                return True

        def spawn(*args, **kwargs):
            self.assertEqual(events, ['launch_spent_fsynced'])
            self.assertEqual(kwargs['stdin'], 0)
            self.assertEqual(kwargs['env'], {'LC_ALL': 'C'})
            self.assertEqual(len(kwargs['pass_fds']), 1)
            events.append('spawn_S')
            return child

        with patch.object(probe, 'load_config', return_value=(config, Bundle())), \
                patch.object(probe, 'ControlFiles', Files), patch.object(probe, 'SupervisorOutput', Output), \
                patch.object(probe, 'checked_pdf'), patch.object(probe, '_supervisor_argv', return_value=['/owned/python']), \
                patch.object(probe.Wait4Child, 'spawn', side_effect=spawn), \
                patch.object(probe, '_finish_reaper_drop', side_effect=lambda: events.append('drop_R')), \
                patch.object(probe, 'process_record', return_value=process_value(200, 62403, 1)), \
                patch.object(probe.os, 'getpid', return_value=200), \
                patch.object(probe, '_write_pipe', side_effect=lambda *args: events.append('GO')), \
                patch.object(probe, 'clock_ns', side_effect=clock):
            code = probe.reaper_main(PATH)
        return code, files, events, clock.value

    def test_reaper_spends_launch_before_spawn_then_drops_and_preserves_two_waits(self):
        code, files, events, _ = self.run_reaper()
        self.assertEqual(code, 0)
        self.assertEqual(events[:4], ['launch_spent_fsynced', 'spawn_S', 'drop_R', 'GO'])
        final = files['report.json']
        self.assertTrue(final['complete'])
        self.assertTrue(final['verified'])
        self.assertEqual(final['supervisor_wait']['pid'], 300)
        self.assertEqual(final['supervisor_result']['session']['retirement']['pid'], 400)
        self.assertNotIn('cpu_ms', final)  # No double counting/derived admission metric.

    def test_negative_supervisor_exit_preserves_actual_deno_wait(self):
        code, files, _, _ = self.run_reaper(supervisor_code=2)
        self.assertEqual(code, 2)
        final = files['report.json']
        self.assertFalse(final['complete'])
        self.assertEqual(final['reason'], 'supervisor_exit')
        self.assertEqual(final['supervisor_wait']['returncode'], 2)
        self.assertEqual(final['supervisor_result']['session']['retirement']['returncode'], -9)

    def test_pre_ready_failure_preserves_wait_without_publishing_ready_or_go(self):
        code, files, events, _ = self.run_reaper(pre_ready=True)
        self.assertEqual(code, 2)
        final = files['report.json']
        self.assertFalse(final['complete'])
        self.assertFalse(final['ready_published'])
        self.assertFalse(final['go_forwarded'])
        self.assertEqual(final['reason'], 'startup_failed')
        self.assertEqual(final['supervisor_result']['session']['retirement']['returncode'], 2)
        self.assertNotIn('ready.json', files)
        self.assertNotIn('GO', events)

    def test_launch_marker_failure_never_spawns_or_drops(self):
        code, files, events, _ = self.run_reaper(spent_failure=True)
        self.assertEqual(code, 2)
        self.assertNotIn('spawn_S', events)
        self.assertNotIn('drop_R', events)
        self.assertNotIn('GO', events)
        self.assertIsNone(files['report.json']['supervisor_wait'])

    def test_missing_wait_or_metrics_and_extra_stdout_never_complete(self):
        for arguments in ({'missing_wait': True}, {'missing_metrics': True}, {'extra_line': True}, {'stderr': True}):
            with self.subTest(arguments=arguments):
                code, files, events, _ = self.run_reaper(**arguments)
                self.assertEqual(code, 2)
                self.assertFalse(files['report.json']['complete'])
                self.assertFalse(files['report.json']['verified'])
                if arguments.get('stderr'):
                    self.assertNotIn('GO', events)
                if arguments.get('missing_metrics'):
                    self.assertIsNotNone(files['report.json']['supervisor_result']['session']['retirement'])

    def test_missing_go_is_finite_and_does_not_start_receiver(self):
        code, files, events, ended = self.run_reaper(missing_go=True)
        self.assertEqual(code, 2)
        self.assertNotIn('GO', events)
        self.assertFalse(files['report.json']['complete'])
        self.assertFalse(files['report.json']['go_forwarded'])
        self.assertLessEqual(ended, int(config_value()['collection_deadline_ns']))

    def test_supervisor_drop_order_and_control_eof_before_session_go(self):
        config, events, output = config_value(), [], []
        read_fd, write_fd = os.pipe()

        class Session:
            child = types.SimpleNamespace(pid=400)
            control_metadata = ready_value(config)['control']

            def handshake(self):
                self_test.assertEqual(events, ['begin_drop', 'spawn_D', 'finish_drop'])
                events.append('handshake')

            def go(self, execution, binding, deadline):
                with self_test.assertRaises(OSError):
                    os.fstat(read_fd)
                self_test.assertEqual((execution, binding, deadline),
                                     (EXECUTION, config['binding_sha256'], int(go_value(config)['deadline_ns'])))
                events.append('GO')

            def finish(self):
                events.append('wait_D')
                return session_value(config)

            def stop(self):
                raise AssertionError('completed session must not stop/retry')

        self_test = self

        def spawn(*args, **kwargs):
            self.assertEqual(events, ['begin_drop'])
            self.assertEqual((kwargs['child_uid'], kwargs['child_gid']), (62402, 62402))
            self.assertGreater(kwargs['input_fd'], 2)
            events.append('spawn_D')
            return Session()

        try:
            with patch.object(probe, 'load_config', return_value=(config, Bundle())), \
                    patch.object(probe, 'checked_pdf', return_value=ready_value(config)['input']), \
                    patch.object(probe.uid_policy, 'begin_drop', side_effect=lambda: events.append('begin_drop')), \
                    patch.object(probe.uid_policy, 'finish_drop', side_effect=lambda: events.append('finish_drop')), \
                    patch.object(probe.VerifierSession, 'spawn_paused', side_effect=spawn), \
                    patch.object(probe, 'process_record', side_effect=lambda pid: process_value(pid, 62401 if pid == 300 else 62402,
                                                                                             200 if pid == 300 else 300,
                                                                                             1 if pid == 300 else 8)), \
                    patch.object(probe.os, 'getpid', return_value=300), patch.object(probe.os, 'getppid', return_value=200), \
                    patch.object(probe, '_read_go_pipe', return_value=go_value(config)), \
                    patch.object(probe, '_write_pipe', side_effect=lambda fd, raw, deadline: output.append(probe._line(raw, probe.MAX_OUTPUT))), \
                    patch.object(probe, 'clock_ns', return_value=NOW):
                self.assertEqual(probe.supervisor_main(PATH, read_fd), 0)
            read_fd = None
            self.assertEqual(events, ['begin_drop', 'spawn_D', 'finish_drop', 'handshake', 'GO', 'wait_D'])
            self.assertEqual(len(output), 2)
            self.assertTrue(output[1]['session']['child_retired'])
        finally:
            if read_fd is not None:
                try:
                    os.close(read_fd)
                except OSError:
                    pass
            os.close(write_fd)

    def test_reaper_fixed_drop_order(self):
        calls = []
        with patch.object(probe.uid_policy, 'begin_drop', side_effect=lambda: calls.append('begin')), \
                patch.object(probe.os, 'setgroups', create=True, side_effect=lambda value: calls.append(('groups', value))), \
                patch.object(probe.os, 'setresgid', create=True, side_effect=lambda *value: calls.append(('gid', value))), \
                patch.object(probe.os, 'setresuid', create=True, side_effect=lambda *value: calls.append(('uid', value))), \
                patch.object(probe.uid_policy, 'prctl', side_effect=lambda *value: calls.append(('prctl', value))), \
                patch.object(probe.uid_policy, 'self_check', side_effect=lambda value: calls.append(('check', value))):
            probe._finish_reaper_drop()
        self.assertEqual(calls, ['begin', ('groups', []), ('gid', (62403, 62403, 62403)),
                                 ('uid', (62403, 62403, 62403)), ('prctl', (4, 0)), ('check', 62403)])


if __name__ == '__main__':
    unittest.main()
