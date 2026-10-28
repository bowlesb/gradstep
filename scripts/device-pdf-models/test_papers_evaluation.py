"""Small acceptance-metric and leakage guards; no private PDFs or models required."""
import argparse, json, tempfile, unittest
from pathlib import Path
from papers_corpus import split
from papers_score_statistics import score,paired_paper_bootstrap


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

    def test_decoded_spans_are_explicit_and_cannot_hide_invalid_logits_or_swallow_prose(self):
        row=self.row();outputs=[[-50]*5,[-50]*5]
        self.assertEqual(score([row],outputs,.7,{row['id']:[[1,5]]})['complete_statistics'],1)
        self.assertEqual(score([row],outputs,.7,{row['id']:[[0,5]]})['complete_statistics'],0)
        self.assertEqual(outputs,[[-50]*5,[-50]*5])
        with self.assertRaises(AssertionError):score([row],outputs,.7,{row['id']:[[1,7]]})
        with self.assertRaises(AssertionError):score([row],[[float('nan')]*5,[-50]*5],.7,{row['id']:[[1,5]]})

    def test_paired_bootstrap_uses_whole_papers_and_reports_zero_error_draws(self):
        a={'by_paper':{'a':{'gold':10,'complete':5},'b':{'gold':1,'complete':1}},
           'gold_statistics':11,'complete_statistics':6,'complete_recall':6/11,'paper_macro_recall':.75}
        b={'by_paper':{'a':{'gold':10,'complete':10},'b':{'gold':1,'complete':1}},
           'gold_statistics':11,'complete_statistics':11,'complete_recall':1,'paper_macro_recall':1}
        result=paired_paper_bootstrap(a,b,1000,2711)
        self.assertEqual(result,paired_paper_bootstrap(a,b,1000,2711))
        self.assertEqual(result['papers_with_positive_gold'],2)
        self.assertEqual(result['relative_incomplete_reduction_interval'],[1,1])
        self.assertEqual(result['complete_recall_delta_interval'],[0,.5])
        self.assertGreater(result['draws_without_baseline_errors'],0)

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
