"""Small acceptance-metric and leakage guards; no private PDFs or models required."""
import argparse, json, tempfile, unittest
from pathlib import Path
from papers_corpus import split
from papers_score_statistics import score


class EvaluationTests(unittest.TestCase):
    def row(self):
        return {'id': 'paper-p0-line', 'paper': 'paper', 'text': 'word p<.05 word',
                'glyphs': [None]*6, 'mask': [0, 1, 1, 1, 1, 0],
                'gold_spans': [{'from': 1, 'to': 5}], 'label_status': 'source_crop_reviewed_statistics',
                'windows': [{'index': 0, 'from': 0, 'to': 3, 'own': [1, 4]},
                            {'index': 1, 'from': 3, 'to': 6, 'own': [1, 4]}]}

    def test_stitches_formula_across_windows_and_excludes_context(self):
        result = score([self.row()], [[50, -50, 50, 50, 50], [50, 50, 50, -50, 50]], .7)
        self.assertEqual(result['complete_statistics'], 1)

    def test_partial_detection_and_swallowed_prose_do_not_pass(self):
        self.assertEqual(score([self.row()], [[-50]*5, [-50]*5], .7)['complete_statistics'], 0)
        self.assertEqual(score([self.row()], [[50]*5, [50]*5], .7)['complete_statistics'], 0)
        self.assertEqual(score([self.row()], [[50, -50, 50, -50, 50], [50, 50, 50, -50, 50]], .7)['complete_statistics'], 0)

    def test_nonfinite_or_missing_predictions_fail(self):
        with self.assertRaises(AssertionError):
            score([self.row()], [[float('nan')]*5, [50]*5], .7)
        with self.assertRaises(AssertionError):
            score([self.row()], [[0], [0]], .7)

    def test_all_on_model_fails_prose_control(self):
        row = self.row(); row.update(gold_spans=[], mask=[0]*6, label_status='text_reviewed_prose_control')
        self.assertEqual(score([row], [[50]*5, [50]*5], .7)['false_positive_prose_line_rate'], 1)

    def test_connected_duplicates_never_cross_partitions(self):
        title = 'A distinctive scientific title with enough words for matching'
        rows = [
            {'sha256': 'a', 'bibliography': [{'doi': 'https://doi.org/10.1234/TEST'}]},
            {'sha256': 'b', 'bibliography': [{'doi': '10.1234/test', 'title': title}]},
            {'sha256': 'c', 'bibliography': [{'title': title.upper()}]},
            {'sha256': 'd', 'bibliography': []}]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'candidate-pdfs.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
            (root/'profile.jsonl').write_text(''.join(json.dumps({'sha256': r['sha256'], 'pages': 2, 'text_chars': 1000})+'\n' for r in rows))
            args = argparse.Namespace(corpus=root, out=root)
            split(args)
            first = json.loads((root/'splits.json').read_text())
            grouped = [r for r in first if r['sha256'] in {'a', 'b', 'c'}]
            self.assertEqual(len({r['family'] for r in grouped}), 1)
            self.assertEqual(len({r['split'] for r in grouped}), 1)
            (root/'candidate-pdfs.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in reversed(rows)))
            split(args)
            self.assertEqual(json.loads((root/'splits.json').read_text()), first)


if __name__ == '__main__':
    unittest.main()
