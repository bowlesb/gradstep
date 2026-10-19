"""Known geometry distinguishes detection, clipping, and missed-panel failures."""
import copy
import unittest

from context_report import context_report


def fixture():
    row = {'id': 'figure', 'sha256': 'verified', 'width': 1000, 'height': 1000, 'group': 'paper',
           'boxes': [{'id': 'p1', 'class': 4, 'box': [100, 100, 400, 500], 'required_context_ids': ['legend']},
                     {'id': 'p2', 'class': 4, 'box': [500, 100, 800, 500], 'required_context_ids': ['legend']},
                     {'id': 'legend', 'class': 0, 'box': [200, 700, 700, 900]}]}
    record = {'id': row['id'], 'image_sha256': row['sha256'], 'width': 1000, 'height': 1000,
              'predictions': [{'class': b['class'], 'box': b['box'], 'score': .9} for b in row['boxes']]}
    return row, record


class ContextTests(unittest.TestCase):
    def test_shared_region_is_one_region_but_two_required_links(self):
        row, record = fixture()
        report = context_report([row], [record])
        self.assertEqual(report['counts'], {'retained_separately': 2})
        self.assertEqual(report['required_links'], 2)
        self.assertEqual(report['unique_context_regions'], 1)
        self.assertEqual(report['unique_context_regions_retained_for_every_panel'], 1)

    def test_clipped_box_missing_box_and_missed_panel_have_separate_denominators(self):
        row, original = fixture()
        clipped = copy.deepcopy(original)
        clipped['predictions'][-1]['box'] = [200, 700, 550, 900]  # IoU .7, margin cannot restore right edge.
        self.assertEqual(context_report([row], [clipped])['counts'], {'detected_context_clipped': 2})
        missing = copy.deepcopy(original)
        missing['predictions'] = missing['predictions'][:1]  # One panel and no legend.
        report = context_report([row], [missing])
        self.assertEqual(report['counts'], {'no_usable_context_box': 1, 'panel_missed': 1})
        self.assertEqual(report['required_links'], 2)
        self.assertEqual(report['unique_context_regions_retained_for_every_panel'], 0)
        self.assertEqual(report['figures_with_missing_context'], 1)

    def test_context_inside_panel_does_not_require_separate_detection(self):
        row, record = fixture()
        row['boxes'][-1]['box'] = [200, 200, 300, 300]
        row['boxes'][1]['required_context_ids'] = []
        record['predictions'] = record['predictions'][:2]
        self.assertEqual(context_report([row], [record])['counts'], {'retained_in_panel': 1})

    def test_changed_image_dimensions_or_duplicate_predictions_refuse_comparison(self):
        row, record = fixture()
        for key, value in (('image_sha256', 'changed'), ('width', 999)):
            changed = {**record, key: value}
            with self.assertRaises(ValueError):
                context_report([row], [changed])
        with self.assertRaises(ValueError):
            context_report([row], [record, record])


if __name__ == '__main__':
    unittest.main()
