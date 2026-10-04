#!/usr/bin/env python3
"""Offline bundle/run retention schedules. All fixtures stay in corpus artifacts."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
import corpus_store as store


class CorpusStoreContracts(unittest.TestCase):
    def setUp(self):
        store.OUT.mkdir(parents=True,exist_ok=True)
        self.directory=Path(tempfile.mkdtemp(prefix='store-test-',dir=store.OUT))
        self.addCleanup(self.cleanup)
        self.base=self.directory/'base';self.base.mkdir()
        original={'wrapper_sha256':'a'*64,'profile_sha256':'b'*64,'qpdf_library_sha256':'c'*64}
        (self.base/'identity.json').write_bytes(store.canonical(original))
        self.patch=patch.object(store.build_store,'open_bundle',return_value=self.base)
        self.patch.start();self.addCleanup(self.patch.stop)
        self.source=self.directory/'source';self.source.mkdir()
        identity={'research_only':True,'limits_changed':False,'hosted_admitted':False,
            'original_build_identity_sha256':'d'*64,'original_wrapper_sha256':'a'*64,
            'profile_sha256':'b'*64,'qpdf_library_sha256':'c'*64}
        for name,key in store.RESEARCH_FILES.items():
            raw=('captured '+name).encode();(self.source/name).write_bytes(raw);identity[key]=store.digest(raw)
        raw=store.canonical(identity);self.identity=store.digest(raw)
        (self.source/'identity.json').write_bytes(raw)
        (self.source/'provenance.json').write_bytes(store.canonical({'identity':identity,'link':['informational-only']}))
        self.archive=self.directory/'research-builds'
    def cleanup(self):
        for parent,dirs,files in os.walk(self.directory):
            Path(parent).chmod(0o755)
            for name in files:
                path=Path(parent)/name
                if not path.is_symlink():path.chmod(0o644)
        shutil.rmtree(self.directory)
    def freeze(self):
        return store.freeze_research(self.source,self.source/'research_build.py',self.identity,self.archive)
    def test_archive_replay_uses_captured_recipe_after_source_changes(self):
        archived=self.freeze()
        (self.source/'research_build.py').write_bytes(b'new edited live recipe')
        self.assertEqual(store.open_research(self.identity,self.archive),archived)
        self.assertEqual(store.read(archived/'research_build.py'),b'captured research_build.py')
    def test_archive_cannot_bind_changed_recipe_to_old_identity(self):
        (self.source/'research_build.py').write_bytes(b'changed recipe')
        with self.assertRaisesRegex(ValueError,'research_source_mismatch'): self.freeze()
        self.assertFalse((self.archive/self.identity).exists())
    def test_exact_refreeze_preserves_first_bundle(self):
        first=self.freeze();before={p.name:p.read_bytes() for p in first.iterdir()}
        self.assertEqual(self.freeze(),first)
        self.assertEqual({p.name:p.read_bytes() for p in first.iterdir()},before)
    def test_tampered_archive_refused(self):
        archived=self.freeze();path=archived/'verifier-research.wasm';path.chmod(0o644);path.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'research_bundle_file_mismatch'):
            store.open_research(self.identity,self.archive)
    def test_source_symlink_refused(self):
        path=self.source/'verifier-research.wasm';path.unlink();path.symlink_to(self.source/'verifier-research.cpp')
        with self.assertRaisesRegex(ValueError,'bundle_symlink_refused'): self.freeze()
    def test_repeat_run_key_does_not_touch_existing_evidence(self):
        run=store.claim_run('benchmark',self.identity,'same-key',self.directory/'runs')
        store.finalize(run,{'outcome':'preserved'})
        before=(run/'report.json').read_bytes()
        with self.assertRaisesRegex(ValueError,'run_already_exists'):
            store.claim_run('benchmark',self.identity,'same-key',self.directory/'runs')
        self.assertEqual((run/'report.json').read_bytes(),before)
    def test_final_report_cannot_be_overwritten_even_with_same_content(self):
        run=store.claim_run('research',self.identity,'final',self.directory/'runs')
        store.write_progress(run,{'phase':'running'})
        store.finalize(run,{'phase':'complete'})
        before=(run/'report.json').read_bytes()
        with self.assertRaises(FileExistsError):store.finalize(run,{'phase':'altered'})
        with self.assertRaisesRegex(ValueError,'run_already_finalized'):store.write_progress(run,{})
        self.assertEqual((run/'report.json').read_bytes(),before)
    def test_racing_run_claim_has_one_owner(self):
        barrier=threading.Barrier(2)
        def claim(_):
            barrier.wait()
            try:return store.claim_run('benchmark',self.identity,'race',self.directory/'runs').name
            except ValueError as error:return str(error)
        with ThreadPoolExecutor(max_workers=2) as executor:outcomes=list(executor.map(claim,range(2)))
        self.assertCountEqual(outcomes,['race','run_already_exists'])
    def test_path_traversal_and_short_identity_refused(self):
        for run_id in ('../other','/outside','with.dot','A'*81):
            with self.subTest(run_id=run_id):
                with self.assertRaisesRegex(ValueError,'invalid_run_id'):
                    store.claim_run('benchmark',self.identity,run_id,self.directory/'runs')
        with self.assertRaisesRegex(ValueError,'invalid_build_identity'):
            store.claim_run('benchmark',self.identity[:8],'valid',self.directory/'runs')


if __name__=='__main__':unittest.main()
