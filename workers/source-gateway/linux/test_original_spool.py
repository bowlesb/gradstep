"""Portable file-mechanics tests. Injected gates are NOT retirement evidence."""
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from common import canonical, decode
import original_spool as spool


def allow(*values):
    pass


def reject(*values):
    raise ValueError('unresolved_ownership')


class OriginalSpoolTests(unittest.TestCase):
    def setUp(self):
        # /tmp has untrusted writable ancestors and must fail the production
        # namespace check. Use an owned, temporary directory under this home.
        self.temp = tempfile.TemporaryDirectory(prefix='.timestep-spool-test-', dir=Path.home())
        self.base = Path(self.temp.name).resolve() / 'spools'
        self.base.mkdir(mode=0o700)
        self.identity = {'reservation_id': 'bbbbbbbb-0000-4000-8000-000000000001',
                         'claim_id': 'bbbbbbbb-0000-4000-8000-000000000002', 'purpose': 'source_download'}
        self.binding = dict(self.identity, attempt_id='bbbbbbbb-0000-4000-8000-000000000003',
                            request_sha256='1' * 64, binding_sha256='2' * 64, capture_sha256='3' * 64)
        self.body = b'%PDF-1.7\n' + b'bounded synthetic bytes\n' * 4000
        self.reservation = self.base / self.identity['reservation_id'].replace('-', '')
        self.leaf = self.reservation / ('source_download-' + self.identity['claim_id'].replace('-', ''))

    def tearDown(self):
        self.temp.cleanup()

    def open(self, identity=None):
        return spool.OriginalSpool(self.base, identity or self.identity,
                                   guardian_uid=os.getuid(), guardian_gid=os.getgid(),
                                   producer_uid=os.getuid(), producer_gid=os.getgid())

    def facts(self, body=None):
        body = self.body if body is None else body
        return {'status': 200, 'framing': 'content-length', 'framing_complete': True,
                'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}

    def produce(self, action, body=None, hook=None):
        body = self.body if body is None else body
        directory = action.prepare(allow)
        try:
            with spool.Producer(directory, self.binding) as producer:
                for offset in range(0, len(body), spool.CHUNK):
                    producer.append(body[offset:offset + spool.CHUNK])
                return producer.finish(self.facts(body), hook=hook)
        finally:
            os.close(directory)

    def sealed(self, action):
        witness = self.produce(action)
        return witness, action.seal(self.binding, witness, allow)

    def clear(self):
        # Test-owned files only, allowing each subtest a fresh reservation.
        import shutil
        if self.reservation.exists():
            shutil.rmtree(self.reservation)

    def test_maximum_pdf_complete_handoff_and_read_only_descriptor(self):
        body = b'p' * spool.MAX_PAYLOAD
        with self.open() as action:
            witness = self.produce(action, body)
            raw = action.seal(self.binding, witness, allow)
            value = spool.descriptor(raw)
            self.assertEqual(value['bytes'], spool.MAX_PAYLOAD)
            self.assertEqual(value['sha256'], hashlib.sha256(body).hexdigest())
            self.assertNotEqual(value['producer'], value['guardian'])
            self.assertLessEqual(len(raw), spool.MAX_RECORD)
            for role in ('producer', 'guardian'):
                os.link(self.leaf / role / 'payload', self.leaf / role / 'payload.pending')
            os.link(self.leaf / 'guardian' / 'descriptor.json', self.leaf / 'guardian' / 'descriptor.pending')
            _, inventory = action.inventory()
            self.assertEqual(inventory, {'names': 7, 'bytes': 2 * len(body) + len(raw), 'payload_inodes': 2})
            self.assertLessEqual(inventory['bytes'], spool.MAX_RETAINED)
            with action.open_sealed(raw, allow) as fd:
                self.assertEqual(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDONLY)
                self.assertEqual(spool._hash(fd, spool.MAX_PAYLOAD)['sha256'], value['sha256'])
                with self.assertRaises(OSError):
                    os.write(fd, b'changed')
                with self.assertRaisesRegex(ValueError, 'spool_reader_open'):
                    action.capture_cleanup(self.binding, allow)
                with self.assertRaises(BlockingIOError):
                    with self.open():
                        self.fail('second guardian acquired reservation lock')

    def test_limit_plus_one_is_rejected_before_write_and_poisons_writer(self):
        with self.open() as action:
            directory = action.prepare(allow)
            try:
                with spool.Producer(directory, self.binding) as producer:
                    for _ in range(spool.MAX_PAYLOAD // spool.CHUNK):
                        producer.append(b'x' * spool.CHUNK)
                    with self.assertRaisesRegex(ValueError, 'spool_body_limit'):
                        producer.append(b'y')
                    self.assertEqual(os.fstat(producer.fd).st_size, spool.MAX_PAYLOAD)
                    with self.assertRaisesRegex(ValueError, 'spool_producer_closed'):
                        producer.finish(self.facts(b'x' * spool.MAX_PAYLOAD))
                with self.assertRaisesRegex(ValueError, 'spool_producer_started'):
                    spool.Producer(directory, self.binding)
            finally:
                os.close(directory)
            self.assertFalse((self.leaf / 'producer' / 'payload').exists())

    def test_short_writes_preserve_exact_hash_and_disk_full_retains_partial(self):
        real_write = os.write
        with self.open() as action:
            directory = action.prepare(allow)
            try:
                with spool.Producer(directory, self.binding) as producer:
                    with patch.object(spool.os, 'write', side_effect=lambda fd, raw: real_write(fd, raw[:73])):
                        producer.append(self.body[:4096])
                    self.assertEqual(producer.count, 4096)
                    calls = []
                    def disk_full(fd, raw):
                        calls.append(1)
                        if len(calls) == 1:
                            return real_write(fd, raw[:7])
                        raise OSError(errno.ENOSPC, 'fixture full')
                    with patch.object(spool.os, 'write', side_effect=disk_full), self.assertRaises(OSError):
                        producer.append(b'additional input')
                    self.assertEqual(os.fstat(producer.fd).st_size, 4103)
                    with self.assertRaisesRegex(ValueError, 'spool_producer_closed'):
                        producer.append(b'x')
            finally:
                os.close(directory)
            self.assertFalse((self.leaf / 'producer' / 'payload').exists())

    def test_empty_oversized_chunks_and_mutable_inputs_refuse(self):
        for raw in (b'', b'x' * (spool.CHUNK + 1), bytearray(b'x')):
            with self.subTest(kind=type(raw), size=len(raw)), self.open() as action:
                directory = action.prepare(allow)
                try:
                    with spool.Producer(directory, self.binding) as producer:
                        with self.assertRaises(ValueError):
                            producer.append(raw)
                        self.assertEqual(os.fstat(producer.fd).st_size, 0)
                finally:
                    os.close(directory)
            self.clear()

    def test_incomplete_or_inconsistent_http_facts_never_finish(self):
        changes = ({'status': 206}, {'status': True}, {'framing_complete': False}, {'bytes': True},
                   {'bytes': 0}, {'bytes': 12}, {'sha256': 'a' * 64}, {'framing': 'redirect'},
                   {'framing': []}, {'extra': 'field'})
        for change in changes:
            with self.subTest(change=change), self.open() as action:
                directory = action.prepare(allow)
                try:
                    with spool.Producer(directory, self.binding) as producer:
                        producer.append(self.body[:1024])
                        facts = dict(self.facts(self.body[:1024]), **change)
                        with self.assertRaises(ValueError):
                            producer.finish(facts)
                        self.assertFalse((self.leaf / 'producer' / 'payload').exists())
                finally:
                    os.close(directory)
            self.clear()

    def test_producer_owns_binding_and_facts_before_publication_hooks(self):
        with self.open() as action:
            directory = action.prepare(allow)
            original = dict(self.binding)
            facts = self.facts(b'pdf')
            try:
                with spool.Producer(directory, original) as producer:
                    original['request_sha256'] = 'a' * 64
                    producer.append(b'pdf')
                    raw = producer.finish(facts, hook=lambda _: facts.update(framing='changed'))
            finally:
                os.close(directory)
            value = spool._completion(raw)
            self.assertEqual(value['request_sha256'], self.binding['request_sha256'])
            self.assertEqual(value['framing'], 'content-length')

    def test_unresolved_producer_or_missing_mismatched_witness_refuses(self):
        with self.open() as action:
            witness = self.produce(action)
            for proof in (None, True, lambda *values: True, reject):
                with self.subTest(proof=proof), self.assertRaises(ValueError):
                    action.seal(self.binding, witness, proof)
            with self.assertRaises(ValueError):
                action.seal(self.binding, b'{}\n', allow)
            wrong = dict(self.binding, capture_sha256='4' * 64)
            with self.assertRaisesRegex(ValueError, 'spool_binding_mismatch'):
                action.seal(wrong, witness, allow)
            self.assertEqual(list((self.leaf / 'guardian').iterdir()), [])

    def test_full_body_without_finished_producer_cannot_be_promoted(self):
        with self.open() as action:
            directory = action.prepare(allow)
            try:
                with spool.Producer(directory, self.binding) as producer:
                    producer.append(b'pdf')
                    guessed = spool._encoded(dict(self.binding, format='original-transfer-complete-v1',
                               bytes=3, sha256=hashlib.sha256(b'pdf').hexdigest(),
                               producer=spool._id(os.fstat(producer.fd)), framing='content-length'))
                with self.assertRaisesRegex(ValueError, 'spool_incomplete_producer'):
                    action.seal(self.binding, guessed, allow)
            finally:
                os.close(directory)

    def test_each_seal_interruption_reuses_same_guardian_inode(self):
        events = ('copy_chunk', 'guardian_fsynced', 'payload_linked', 'payload_directory_fsynced',
                  'descriptor_chunk', 'descriptor_fsynced', 'descriptor.json_linked', 'descriptor.json_directory_fsynced')
        for event in events:
            with self.subTest(event=event):
                samples = []
                with self.open() as action:
                    witness = self.produce(action)
                    def stop(step):
                        samples.append(action.inventory()[1])
                        if step == event:
                            raise OSError('fixture interruption')
                    with self.assertRaises(OSError):
                        action.seal(self.binding, witness, allow, hook=stop)
                candidate = self.leaf / 'guardian' / 'payload'
                if not candidate.exists():
                    candidate = candidate.with_name('payload.pending')
                inode = candidate.stat().st_ino
                with self.open() as action:
                    raw = action.seal(self.binding, witness, allow)
                    self.assertEqual((self.leaf / 'guardian' / 'payload').stat().st_ino, inode)
                    before = action.inventory()[1]
                    self.assertEqual(action.seal(self.binding, witness, allow), raw)
                    self.assertEqual(action.inventory()[1], before)
                self.assertLessEqual(max(v['payload_inodes'] for v in samples), 2)
                self.assertLessEqual(max(v['bytes'] for v in samples), spool.MAX_RETAINED)
                self.clear()

    def test_partial_descriptor_is_quarantined_without_new_payload(self):
        real_write = os.write
        with self.open() as action:
            witness = self.produce(action)
            def stop(event):
                if event == 'descriptor_chunk':
                    raise OSError('partial descriptor')
            def short_descriptor(fd, raw):
                return real_write(fd, raw[:11] if raw.startswith(b'{') else raw)
            with patch.object(spool.os, 'write', side_effect=short_descriptor), self.assertRaises(OSError):
                action.seal(self.binding, witness, allow, hook=stop)
            before = {p.name: (p.stat().st_ino, p.read_bytes()) for p in (self.leaf / 'guardian').iterdir()}
            with self.assertRaises(ValueError):
                action.seal(self.binding, witness, allow)
            after = {p.name: (p.stat().st_ino, p.read_bytes()) for p in (self.leaf / 'guardian').iterdir()}
            self.assertEqual(before, after)

    def test_restart_rehashes_and_refuses_substitution_or_truncation(self):
        for change in ('same_size', 'truncate', 'replace'):
            with self.subTest(change=change):
                with self.open() as action:
                    witness, raw = self.sealed(action)
                payload = self.leaf / 'guardian' / 'payload'
                if change == 'replace':
                    temporary = payload.with_name('replacement')
                    temporary.write_bytes(self.body)
                    temporary.chmod(0o600)
                    os.replace(temporary, payload)
                else:
                    payload.write_bytes(b'x' * len(self.body) if change == 'same_size' else b'short')
                before = payload.read_bytes()
                with self.open() as action:
                    with self.assertRaisesRegex(ValueError, 'spool_payload_mismatch'):
                        with action.open_sealed(raw, allow):
                            self.fail('accepted substituted bytes')
                    with self.assertRaisesRegex(ValueError, 'spool_payload_mismatch'):
                        action.seal(self.binding, witness, allow)
                self.assertEqual(payload.read_bytes(), before)
                self.clear()

    def test_reopen_requires_durable_barrier_and_reader_gate_after_restart(self):
        with self.open() as action:
            _, raw = self.sealed(action)
        with self.open() as action:
            with self.assertRaisesRegex(ValueError, 'unresolved_ownership'):
                with action.open_sealed(raw, reject):
                    self.fail('lost reader intent was ignored')
            with patch.object(spool.os, 'fsync', side_effect=OSError('fixture durability failure')):
                with self.assertRaises(OSError):
                    with action.open_sealed(raw, allow):
                        self.fail('no durability barrier')

    def test_published_descriptor_survives_durable_producer_unlink(self):
        with self.open() as action:
            witness, raw = self.sealed(action)
            os.unlink('payload', dir_fd=action.dirs['producer'])
            os.fsync(action.dirs['producer'])
        with self.open() as action:
            self.assertEqual(action.seal(self.binding, witness, allow), raw)
            with action.open_sealed(raw, allow) as fd:
                self.assertEqual(os.read(fd, 9), self.body[:9])
            self.assertEqual(action.inventory()[1]['payload_inodes'], 1)

    def test_changed_producer_cannot_replace_accepted_guardian_payload(self):
        with self.open() as action:
            witness, raw = self.sealed(action)
            guardian = self.leaf / 'guardian' / 'payload'
            before = guardian.stat().st_ino, guardian.read_bytes()
            (self.leaf / 'producer' / 'payload').write_bytes(b'x' * len(self.body))
            with self.assertRaisesRegex(ValueError, 'spool_payload_mismatch'):
                action.seal(self.binding, witness, allow)
            self.assertEqual((guardian.stat().st_ino, guardian.read_bytes()), before)
            self.assertEqual((self.leaf / 'guardian' / 'descriptor.json').read_bytes(), raw)

    def test_close_errors_detach_and_attempt_every_owned_descriptor(self):
        actual_close = os.close
        closed = []
        def failing_close(fd):
            actual_close(fd)
            closed.append(fd)
            if len(closed) == 1:
                raise OSError('fixture close consumed fd but failed')
        action = self.open()
        action.__enter__()
        directory = action.prepare(allow)
        producer = spool.Producer(directory, self.binding)
        os.close(directory)
        expected = [producer.fd, producer.directory]
        with patch.object(spool.os, 'close', side_effect=failing_close), self.assertRaises(OSError):
            producer.close()
        self.assertEqual(closed, expected)
        self.assertIsNone(producer.fd)
        self.assertIsNone(producer.directory)
        reused = os.open('/dev/null', os.O_RDONLY)
        try:
            producer.close()
            os.fstat(reused)
        finally:
            os.close(reused)
        closed.clear()
        expected = list(action.dirs.values()) + [action.lock, action.reservation, action.base]
        with patch.object(spool.os, 'close', side_effect=failing_close), self.assertRaises(OSError):
            action.__exit__(None, None, None)
        self.assertEqual(closed, expected)
        self.assertEqual(action.dirs, {})
        self.assertIsNone(action.lock)
        self.assertIsNone(action.reservation)
        self.assertIsNone(action.base)
        reused = os.open('/dev/null', os.O_RDONLY)
        try:
            action.__exit__(None, None, None)
            os.fstat(reused)
        finally:
            os.close(reused)

    def test_symlinked_root_or_conflicting_payload_pair_never_allocates(self):
        alias = self.base.with_name('base-alias')
        alias.symlink_to(self.base, target_is_directory=True)
        original = self.base
        self.base = alias
        try:
            with self.assertRaises(OSError):
                with self.open():
                    self.fail('symlinked base')
        finally:
            self.base = original
        with self.open() as action:
            witness = self.produce(action)
            pending = self.leaf / 'guardian' / 'payload.pending'
            final = self.leaf / 'guardian' / 'payload'
            for file in (pending, final):
                file.write_bytes(self.body)
                file.chmod(0o600)
            before = pending.stat().st_ino, final.stat().st_ino
            with self.assertRaises(ValueError):
                action.seal(self.binding, witness, allow)
            self.assertEqual((pending.stat().st_ino, final.stat().st_ino), before)
            self.assertEqual(len(list(final.parent.iterdir())), 2)

    def test_descriptor_canonical_closed_schema_and_integer_validation(self):
        with self.open() as action:
            _, raw = self.sealed(action)
            original = decode(raw)
            mutations = ({'extra': 'field'}, {'bytes': True}, {'bytes': 0}, {'bytes': spool.MAX_PAYLOAD + 1},
                         {'claim_id': original['claim_id'].upper()}, {'sha256': 'A' * 64},
                         {'producer': {'device': '00', 'inode': '1'}},
                         {'guardian': {'device': '1', 'inode': '0'}},
                         {'guardian': {'device': str(2**64), 'inode': '1'}},
                         {'guardian': original['producer']})
            for mutation in mutations:
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    spool.descriptor(spool._encoded(dict(original, **mutation)))
            for malformed in (raw[:-1], b' ' + raw, raw.replace(b'{', b'{"bytes":12,', 1), b'{}\n',
                              b'x' * (spool.MAX_RECORD + 1)):
                with self.assertRaises(ValueError):
                    spool.descriptor(malformed)

    def test_single_active_leaf_blocks_other_attempt_and_readback_allocation(self):
        with self.open() as action:
            self.produce(action)
        for identity in (dict(self.identity, purpose='stored_readback'),
                         dict(self.identity, claim_id='bbbbbbbb-0000-4000-8000-000000000009')):
            with self.assertRaisesRegex(ValueError, 'spool_reservation_occupied'):
                with self.open(identity):
                    self.fail('allocated a second active leaf')
        self.assertEqual(len(list(self.reservation.iterdir())), 2)

    def test_wrong_file_names_links_types_modes_and_leaf_mutation_refuse(self):
        mutations = ('unknown', 'symlink', 'fifo', 'alias', 'mode', 'oversize', 'leaf_child', 'leaf_mode')
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.open() as action:
                witness = self.produce(action)
                file = self.leaf / 'producer' / 'payload'
                if mutation == 'unknown':
                    (file.parent / 'other').write_bytes(b'')
                elif mutation == 'symlink':
                    file.unlink()
                    file.symlink_to(self.base / 'absent')
                elif mutation == 'fifo':
                    file.unlink()
                    os.mkfifo(file, 0o600)
                elif mutation == 'alias':
                    os.link(file, Path(self.temp.name) / 'alias')
                elif mutation == 'mode':
                    file.chmod(0o644)
                elif mutation == 'oversize':
                    with file.open('ab') as stream:
                        stream.truncate(spool.MAX_PAYLOAD + 1)
                elif mutation == 'leaf_child':
                    (self.leaf / 'other').mkdir()
                else:
                    self.leaf.chmod(0o755)
                with self.assertRaises(ValueError):
                    action.seal(self.binding, witness, allow)
            self.clear()
            alias = Path(self.temp.name) / 'alias'
            if alias.exists():
                alias.unlink()

    def test_namespace_ancestor_base_and_lock_changes_refuse(self):
        parent = Path(self.temp.name)
        parent.chmod(0o777)
        try:
            with self.assertRaisesRegex(ValueError, 'spool_untrusted_ancestor'):
                with self.open():
                    self.fail('writable ancestry')
        finally:
            parent.chmod(0o700)
        with self.open() as action:
            self.produce(action)
            (self.reservation / spool.LOCK).write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'spool_lock_identity'):
                action.inventory()
            (self.reservation / spool.LOCK).write_bytes(b'')
            renamed = self.base.with_name('detached')
            self.base.rename(renamed)
            self.base.mkdir(mode=0o700)
            with self.assertRaisesRegex(ValueError, 'spool_root_changed'):
                action.inventory()

    def test_cleanup_requires_settlement_and_replays_every_unlink_boundary(self):
        for event in ('cleanup_unlinked', 'producer_removed', 'guardian_removed', 'leaf_removed', 'cleanup_fsynced'):
            with self.subTest(event=event):
                with self.open() as action:
                    self.sealed(action)
                    captured = action.capture_cleanup(self.binding, allow)
                    with self.assertRaisesRegex(ValueError, 'unresolved_ownership'):
                        action.retire_slots(captured, reject)
                    def stop(step):
                        if step == event:
                            raise OSError('cleanup interrupted')
                    with self.assertRaises(OSError):
                        action.retire_slots(captured, allow, hook=stop)
                with self.open() as action:
                    receipt = action.retire_slots(captured, allow)
                    self.assertEqual(action.retire_slots(captured, allow), receipt)
                    self.assertEqual(decode(receipt)['cleanup_sha256'], hashlib.sha256(captured).hexdigest())
                self.assertEqual({p.name for p in self.reservation.iterdir()}, {spool.LOCK})
                with self.open(dict(self.identity, purpose='stored_readback')) as action:
                    directory = action.prepare(allow)
                    os.close(directory)
                self.clear()

    def test_cleanup_partial_payload_and_descriptor_does_not_claim_candidate(self):
        with self.open() as action:
            directory = action.prepare(allow)
            try:
                with spool.Producer(directory, self.binding) as producer:
                    producer.append(b'partial PDF')
            finally:
                os.close(directory)
            partial = self.leaf / 'guardian' / 'descriptor.pending'
            partial.write_bytes(b'{"partial')
            partial.chmod(0o600)
            captured = action.capture_cleanup(self.binding, allow)
            self.assertNotIn('sha256', decode(captured))
            action.retire_slots(captured, allow)
            self.assertFalse(self.leaf.exists())

    def test_cleanup_replays_after_one_hardlink_alias_is_removed(self):
        with self.open() as action:
            self.sealed(action)
            for role in ('producer', 'guardian'):
                os.link(self.leaf / role / 'payload', self.leaf / role / 'payload.pending')
            os.link(self.leaf / 'guardian' / 'descriptor.json', self.leaf / 'guardian' / 'descriptor.pending')
            self.assertEqual(action.inventory()[1]['names'], 7)
            captured = action.capture_cleanup(self.binding, allow)
            def stop(event):
                if event == 'cleanup_unlinked':
                    raise OSError('first alias removed')
            with self.assertRaises(OSError):
                action.retire_slots(captured, allow, hook=stop)
        self.assertFalse((self.leaf / 'producer' / 'payload').exists())
        self.assertEqual((self.leaf / 'producer' / 'payload.pending').stat().st_nlink, 1)
        with self.open() as action:
            action.retire_slots(captured, allow)
        self.assertFalse(self.leaf.exists())

    def test_cleanup_barrier_failure_returns_no_receipt_until_replayed(self):
        real_fsync = os.fsync
        with self.open() as action:
            self.sealed(action)
            captured = action.capture_cleanup(self.binding, allow)
            def fail_parent(fd):
                if fd == action.reservation:
                    raise OSError('parent durability unavailable')
                return real_fsync(fd)
            with patch.object(spool.os, 'fsync', side_effect=fail_parent), self.assertRaises(OSError):
                action.retire_slots(captured, allow)
            self.assertFalse(self.leaf.exists())
            receipt = action.retire_slots(captured, allow)
            self.assertEqual(decode(receipt)['cleanup_sha256'], hashlib.sha256(captured).hexdigest())

    def test_changed_cleanup_inventory_refuses_before_any_deletion(self):
        with self.open() as action:
            self.sealed(action)
            captured = action.capture_cleanup(self.binding, allow)
            payload = self.leaf / 'guardian' / 'payload'
            payload.write_bytes(b'x' * len(self.body))
            with self.assertRaisesRegex(ValueError, 'spool_cleanup_conflict'):
                action.retire_slots(captured, allow)
            self.assertTrue((self.leaf / 'producer' / 'payload').exists())
            self.assertTrue((self.leaf / 'guardian' / 'descriptor.json').exists())

    def test_actual_process_exit_releases_lock_but_recovery_needs_saved_proof(self):
        with self.open() as action:
            witness = self.produce(action)
        # Process output contains only synthetic local records. No networking or
        # SQL occurs; os._exit tests kernel FD/lock release without finally.
        script = '''import os,sys
sys.path.insert(0,sys.argv[1]);import original_spool as s
from common import decode
identity,binding,witness=decode(sys.stdin.buffer.readline()),decode(sys.stdin.buffer.readline()),sys.stdin.buffer.readline()
def allow(*x):pass
def stop(event):
 if event==sys.argv[3]:os._exit(71)
with s.OriginalSpool(sys.argv[2],identity,guardian_uid=os.getuid(),guardian_gid=os.getgid(),producer_uid=os.getuid(),producer_gid=os.getgid()) as action:
 raw=action.seal(binding,witness,allow,hook=stop)
 print(s._digest(raw))
'''
        command = [sys.executable, '-I', '-S', '-B', '-c', script, str(Path(spool.__file__).parent),
                   str(self.base), 'copy_chunk']
        data = canonical(self.identity) + b'\n' + canonical(self.binding) + b'\n' + witness
        result = subprocess.run(command, input=data, capture_output=True, timeout=10, env={'LC_ALL': 'C'})
        self.assertEqual(result.returncode, 71, result.stderr)
        inode = (self.leaf / 'guardian' / 'payload.pending').stat().st_ino
        with self.open() as action:
            with self.assertRaisesRegex(ValueError, 'unresolved_ownership'):
                action.seal(self.binding, witness, reject)
        command[-1] = 'no interruption'
        result = subprocess.run(command, input=data, capture_output=True, timeout=10, env={'LC_ALL': 'C'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.leaf / 'guardian' / 'payload').stat().st_ino, inode)
        self.assertRegex(result.stdout.strip().decode(), '^[0-9a-f]{64}$')


if __name__ == '__main__':
    unittest.main()
