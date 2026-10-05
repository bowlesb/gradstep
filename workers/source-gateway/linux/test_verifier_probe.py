"""Guardian acceptance regressions; authored records are never host evidence."""
import copy
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import verifier_probe as guardian
from test_verifier_probe_runtime import Bundle, config_value, ready_value, supervisor_value, wait_value
from protocol import canonical, digest


def evidence_value(config):
    identity = {'device': '29', 'inode': '31'}
    ready = ready_value(config)
    report = {'format': 'linux-verifier-probe-report-v1', 'local_fixture_only': True, 'hosted_admitted': False,
              'claim_id': config['input']['claim_id'], 'execution_id': config['execution_id'],
              'bundle_sha256': config['bundle_sha256'], 'input_sha256': digest(canonical(config['input'])),
              'ready_published': True, 'go_forwarded': True, 'complete': True, 'verified': True,
              'reason': None, 'supervisor_result': supervisor_value(config), 'supervisor_wait': wait_value(300),
              'supervisor_wait_authority_lost': False, 'ipc_cleanup_complete': True}
    return {'restart_denied': True, 'initial': {'identity': identity},
            'final': {'identity': dict(identity), 'cgroup.events': {'populated': 0},
                      'cpu.stat': {'usage_usec': 40000}, 'memory.peak': 4000000},
            'ready': {'supervisor_ready': ready}, 'runtime_report': report, 'guardian_stop': None,
            'service_exit': {'ExecMainCode': '1', 'ExecMainStatus': '0', 'Result': 'success'}}


class GuardianContractTests(unittest.TestCase):
    def test_final_cpu_is_checked_even_when_polling_missed_the_overrun(self):
        config = config_value()
        data = evidence_value(config)
        guardian.validate_case(data, 'valid', config, Bundle())
        self.assertEqual(data['measurements']['scope_cpu_usec'], 40000)
        self.assertFalse(data['measurements']['cpu_records_summed'])
        data['final']['cpu.stat']['usage_usec'] = 2000001
        with self.assertRaisesRegex(ValueError, 'measured_completion_missing'):
            guardian.validate_case(data, 'valid', config, Bundle())

    def test_rss_formula_is_explicitly_overlapping_and_keeps_reaper_separate(self):
        config = config_value()
        data = evidence_value(config)
        guardian.validate_case(data, 'valid', config, Bundle())
        self.assertEqual(data['measurements']['conservative_overlapping_rss_bytes'], 2 * 1024 * 1024)
        self.assertFalse(data['measurements']['reaper_rss_in_envelope'])
        self.assertIsNone(data['measurements']['lifetime_task_peak'])

    def test_report_publication_without_successful_reaper_exit_is_not_completion(self):
        config = config_value()
        for change in ({'ExecMainCode': '2'}, {'ExecMainStatus': '2'}, {'Result': 'exit-code'}):
            with self.subTest(change=change):
                data = evidence_value(config)
                data['service_exit'].update(change)
                with self.assertRaisesRegex(ValueError, 'measured_completion_missing'):
                    guardian.validate_case(data, 'valid', config, Bundle())

    def test_missing_either_wait_or_wrong_scope_cannot_complete(self):
        config = config_value()
        for which in ('supervisor', 'deno', 'scope'):
            with self.subTest(which=which):
                data = evidence_value(config)
                if which == 'supervisor':
                    data['runtime_report']['supervisor_wait'] = None
                elif which == 'deno':
                    data['runtime_report']['supervisor_result']['session']['retirement'] = None
                else:
                    data['final']['identity']['inode'] = '99'
                with self.assertRaises(ValueError):
                    guardian.validate_case(data, 'valid', config, Bundle())

    def test_reaper_death_can_only_be_an_unmeasured_negative(self):
        config = config_value()
        data = evidence_value(config)
        data['runtime_report'] = None
        data['service_exit'].update(Result='signal', ExecMainCode='2', ExecMainStatus='9')
        guardian.validate_case(data, 'reaper_death', config, Bundle())
        self.assertNotIn('measurements', data)
        data['runtime_report'] = evidence_value(config)['runtime_report']
        with self.assertRaisesRegex(ValueError, 'reaper_death_not_observed'):
            guardian.validate_case(data, 'reaper_death', config, Bundle())

    def test_kill_uses_only_held_handles_and_does_not_reopen_paths(self):
        with tempfile.TemporaryDirectory() as root:
            scope = os.open(root, os.O_RDONLY)
            write_fd = os.open(Path(root) / 'kill', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                info = os.fstat(scope)
                identity = {'device': str(info.st_dev), 'inode': str(info.st_ino)}
                with patch.object(guardian.os, 'open', side_effect=AssertionError('path reacquisition')):
                    guardian.kill_scope(scope, write_fd, identity)
                    with self.assertRaisesRegex(ValueError, 'scope_changed'):
                        guardian.kill_scope(scope, write_fd, dict(identity, inode='0'))
                self.assertEqual((Path(root) / 'kill').read_bytes(), b'1')
            finally:
                os.close(write_fd)
                os.close(scope)

    def test_join_waits_for_owned_thread_before_returning_to_cleanup(self):
        release, done, exited = threading.Event(), threading.Event(), threading.Event()
        thread = threading.Thread(target=lambda: (release.wait(1), exited.set()))
        thread.start()
        release.set()
        guardian.join_guardian(thread, done)
        self.assertTrue(done.is_set())
        self.assertTrue(exited.is_set())
        self.assertFalse(thread.is_alive())
        class StillRunning:
            ident = 42
            def join(self, seconds):
                self.waited = seconds
            def is_alive(self):
                return True
        with self.assertRaisesRegex(ValueError, 'guardian_join_failed'):
            guardian.join_guardian(StillRunning(), done)

    def test_render_never_allows_shell_or_systemd_path_expansion(self):
        attempt = 'ab000000-0000-4000-8000-000000000001'
        valid = ('/var/lib/timestep-verifier-probe/a', '/var/lib/timestep-verifier-probe/a/spools/payload',
                 '/opt/timestep-verifier-lab/a/modules', 'a' * 64, '/var/lib/timestep-verifier-probe/a/spools')
        result = guardian.render(attempt, *valid)
        self.assertEqual(len(result), 3)
        service = result['tsverifier' + attempt.replace('-', '') + '.service']
        self.assertIn(b'RemainAfterExit=no', service)
        self.assertIn(b'MemorySwapMax=0', service)
        for bad in ('/tmp/with space', '/tmp/%n', '/tmp/a\nExecStart=/bad'):
            with self.subTest(path=bad), self.assertRaises(ValueError):
                guardian.render(attempt, bad, *valid[1:])


if __name__ == '__main__':
    unittest.main()
