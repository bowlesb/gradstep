#!/usr/bin/env python3
"""Offline stale-baseline schedules; no compiler, parser, network or file writes."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('corpus_research', Path(__file__).with_name('research.py'))
research = importlib.util.module_from_spec(spec)
spec.loader.exec_module(research)


class BaselineBindings(unittest.TestCase):
    def setUp(self):
        self.manifest = {'papers':[{'id':'v139-tan21a','bytes':23,'sha256':'a'*64}]}
        self.baseline = {'manifest_sha256':'b'*64,'build_identity_sha256':research.FROZEN_IDENTITY,
            'results':[{'id':'v139-tan21a','bytes':23,'runs':[{'id':'v139-tan21a','artifactSHA256':'a'*64,
                'buildIdentitySHA256':research.FROZEN_IDENTITY,'outcome':'verified'}]}]}
    def validate(self): return research.validate_baseline(self.manifest, 'b'*64, self.baseline)
    def test_exact_bound_baseline_matches(self):
        self.assertEqual(self.validate(), {'v139-tan21a':'verified'})
    def test_stale_manifest_is_not_compared(self):
        self.baseline['manifest_sha256'] = 'c'*64
        with self.assertRaisesRegex(RuntimeError,'stale_baseline_identity'): self.validate()
    def test_different_build_is_not_compared(self):
        self.baseline['build_identity_sha256'] = 'c'*64
        with self.assertRaisesRegex(RuntimeError,'stale_baseline_identity'): self.validate()
    def test_same_id_changed_bytes_are_not_compared(self):
        self.manifest['papers'][0]['sha256'] = 'c'*64
        with self.assertRaisesRegex(RuntimeError,'baseline_artifact_mismatch'): self.validate()
    def test_all_runs_must_bind_to_build(self):
        second = copy.deepcopy(self.baseline['results'][0]['runs'][0])
        second['buildIdentitySHA256'] = 'c'*64
        self.baseline['results'][0]['runs'].append(second)
        with self.assertRaisesRegex(RuntimeError,'baseline_artifact_mismatch'): self.validate()
    def test_missing_paper_is_not_silently_dropped(self):
        self.baseline['results'] = []
        with self.assertRaisesRegex(RuntimeError,'baseline_corpus_mismatch'): self.validate()
    def test_duplicate_record_is_not_overwritten_by_dictionary_join(self):
        self.baseline['results'].append(copy.deepcopy(self.baseline['results'][0]))
        with self.assertRaisesRegex(RuntimeError,'baseline_corpus_mismatch'): self.validate()
    def test_mixed_outcomes_are_not_reduced_to_first_run(self):
        second = copy.deepcopy(self.baseline['results'][0]['runs'][0])
        second['outcome'] = 'malformed'
        self.baseline['results'][0]['runs'].append(second)
        with self.assertRaisesRegex(RuntimeError,'baseline_outcomes_inconsistent'): self.validate()


if __name__ == '__main__': unittest.main()
