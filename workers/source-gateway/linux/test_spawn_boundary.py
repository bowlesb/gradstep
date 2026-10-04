"""Pure setup/capability failure schedules, with no privileged syscall execution."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import Mock, patch

import uid_policy


class SpawnBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = str(Path(__file__).resolve().parents[1])
        sys.path.append(cls.path)
        cls.prior = sys.modules.get('frozen_context')
        sys.modules['frozen_context'] = types.SimpleNamespace(root=Path('/fixture'), manifest={})
        import paused_child
        cls.module = paused_child

    @classmethod
    def tearDownClass(cls):
        sys.path.remove(cls.path)
        if cls.prior is None: sys.modules.pop('frozen_context', None)
        else: sys.modules['frozen_context'] = cls.prior

    def child(self, *, joins=True):
        child = Mock()
        child.stdin, child.stdout, child.stderr = (Mock() for _ in range(3))
        for number, pipe in enumerate((child.stdin, child.stdout, child.stderr), 20):
            pipe.fileno.return_value = number
            pipe.closed = False
        child.wait.side_effect = None if joins else subprocess.TimeoutExpired('fixture', .5)
        child.wait.return_value = 0
        return child

    def test_spawn_only_does_not_consume_request_or_ready(self):
        module = self.module
        child, retire, identify = self.child(), Mock(), Mock()
        with patch.object(module.subprocess, 'Popen', return_value=child), patch.object(module.os, 'set_blocking'):
            session = module.PausedChild.spawn_only(argv=['/fixture/python', '/fixture/child'],
                       user=62402, group=62402, identity_reader=identify, stop_child=retire)
        self.assertIsNone(session.value)
        child.stdin.write.assert_not_called()
        identify.assert_not_called()
        retire.assert_not_called()

    def test_second_pipe_setup_failure_keeps_exact_handle_and_respects_stop_strategy(self):
        module = self.module
        for joins in (True, False):
            with self.subTest(joins=joins):
                child, retire = self.child(joins=joins), Mock()
                with patch.object(module.subprocess, 'Popen', return_value=child), \
                     patch.object(module.os, 'set_blocking', side_effect=[None, OSError('fixture failure')]):
                    with self.assertRaises(module.ChildSetupError) as raised:
                        module.PausedChild.spawn_only(argv=['/fixture/python'], user=62402, group=62402,
                                                    identity_reader=Mock(), stop_child=retire)
                self.assertIs(raised.exception.session.child, child)
                self.assertEqual(raised.exception.returncode, 0 if joins else None)
                retire.assert_called_once_with(child)
                child.kill.assert_not_called()
                child.wait.assert_called_once_with(timeout=.5)
                self.assertIsNone(raised.exception.session.report)

    def test_drop_syscall_failure_cannot_reach_capset_or_spawning(self):
        current = {'uids': [0] * 4, 'gids': [0] * 4, 'threads': 1, 'no_new_privs': 1, 'seccomp': 2,
                   'caps': {'CapInh': 0, 'CapPrm': uid_policy.INITIAL_CAPS, 'CapEff': uid_policy.INITIAL_CAPS,
                            'CapBnd': uid_policy.INITIAL_CAPS, 'CapAmb': 0}}
        def operation(option, argument=0):
            if option == 27: return 0
            if option == 24: raise OSError('fixture denied bounding drop')
            return 0
        with patch.object(uid_policy, 'status', return_value=current), \
             patch.object(uid_policy, 'prctl', side_effect=operation), \
             patch.object(uid_policy.os, 'setgroups'), patch.object(uid_policy, '_read', return_value='40'), \
             patch.object(uid_policy, '_libc') as library:
            with self.assertRaises(OSError): uid_policy.begin_drop()
            library.assert_not_called()


if __name__ == '__main__':
    unittest.main()
