from sfd.core import evaluate as E
from sfd.evaluation import sweep as SW
from helpers import two_panel


def gt(panels, shared=()):
    return {'id': 'x', 'paper': 'p', 'panels': panels, 'shared': list(shared)}


def test_perfect_split():
    img, panels = two_panel()
    r = E.evaluate_figure(gt(panels), [p[:] for p in panels], img)
    assert r['outcome'] == 'perfect' and r['complete'] == 2


def test_clipped_when_tick_labels_cut():
    img, panels = two_panel()
    crops = [[p[0] + 5, 30, p[2] - 5, 150] for p in panels]   # misses letters/ticks even with 2% margin
    r = E.evaluate_figure(gt(panels), crops, img)
    assert r['outcome'] in ('clipped', 'wrong_boxes', 'missed_panels')
    assert r['complete'] < 2


def test_whole_figure_crop_cannot_match_two_panels():
    img, panels = two_panel()
    r = E.evaluate_figure(gt(panels), [[0, 0, 400, 200], [0, 0, 200, 200]], img)
    assert r['matched'] <= 1


def test_single_figure_false_split_and_whole():
    img, panels = two_panel()
    single = gt([[0, 0, 400, 200]])
    assert E.evaluate_figure(single, [], img)['outcome'] == 'correct_whole'
    assert E.evaluate_figure(single, [p[:] for p in panels], img)['outcome'] == 'false_split'


def test_aggregate_harmful_rate_counts_wrong_crops_not_abstentions():
    rows = [{'compound': True, 'n_gt': 2, 'n_crops': 0, 'outcome': 'not_split', 'paper': 'a'},
            {'compound': True, 'n_gt': 2, 'n_crops': 2, 'outcome': 'clipped', 'matched': 2, 'complete': 1, 'paper': 'b'},
            {'compound': False, 'n_gt': 1, 'n_crops': 0, 'outcome': 'correct_whole', 'paper': 'c'},
            {'compound': False, 'n_gt': 1, 'n_crops': 2, 'outcome': 'false_split', 'paper': 'd'}]
    a = E.aggregate(rows)
    assert a['harmful_rate'] == 0.5 and a['app_success'] == 0.25


def test_two_view_agreement():
    a = [[0, 0, 100, 100], [100, 0, 200, 100]]
    assert SW.agree(a, [[2, 0, 100, 100], [101, 0, 200, 99]])
    assert not SW.agree(a, a[:1])
    assert not SW.agree(a, [[0, 0, 50, 100], [100, 0, 200, 100]])


def test_groupable_when_parts_refine_panels():
    img, panels = two_panel()
    # One annotated panel = the whole figure's left half made of two plots; detector gives each plot.
    gtp = gt([[0, 0, 200, 200], [200, 0, 400, 200]])
    parts = [[20, 10, 100, 168], [100, 10, 180, 168], [220, 10, 380, 168]]
    r = E.evaluate_figure(gtp, parts, img)
    assert r['groupable'] and r['outcome'] != 'perfect'
