import numpy as np

from sfd.core import policy as P
from helpers import two_panel, canvas, draw_box


def test_complete_pulls_in_cut_labels_and_letters():
    img, panels = two_panel()
    mask = P.ink_mask(img)
    # Detector boxes clip the letter (above) and the tick labels (below).
    crops = [[18, 28, 182, 152], [218, 28, 382, 152]]
    out = P.complete(crops, mask)
    for o, p in zip(out, panels):
        assert o[0] <= p[0] and o[1] <= p[1] and o[2] >= p[2] and o[3] >= p[3]
    # Completion never swallows the neighbouring panel.
    assert out[0][2] < 220 and out[1][0] > 180


def test_complete_attaches_orphan_legend_to_nearest_crop():
    img, panels = two_panel()
    draw_box(img, (40, 185, 160, 195), fill=True)       # legend under the left panel only
    mask = P.ink_mask(img)
    out = P.complete([p[:] for p in panels], mask)
    assert out[0][3] >= 195 and out[1][3] < 185
    covered = np.zeros_like(mask)
    for x0, y0, x1, y1 in out:
        covered[int(y0):int(np.ceil(y1)), int(x0):int(np.ceil(x1))] = True
    assert (mask & ~covered).sum() == 0                  # every ink pixel is in some crop


def test_complete_never_swallows_a_neighbour_for_a_straddling_legend():
    img, panels = two_panel()
    draw_box(img, (150, 185, 250, 195), fill=True)      # legend straddling both panels
    out = P.complete([p[:] for p in panels], P.ink_mask(img))
    # Growing either crop over it would take > 8% of the other panel: it stays shared (caller decides).
    assert out[0][2] < 220 and out[1][0] > 180


def test_suppress_removes_duplicates_and_nested():
    boxes = [{'box': [0, 0, 100, 100], 'score': .9}, {'box': [2, 2, 98, 98], 'score': .8},
             {'box': [10, 10, 40, 40], 'score': .7}, {'box': [200, 0, 300, 100], 'score': .6}]
    kept = P.suppress(boxes)
    assert [b['score'] for b in kept] == [.9, .6]


def test_final_crops_whole_figure_box_means_single():
    img, _ = two_panel()
    pred = [{'class': 0, 'score': .9, 'box': [0, 0, 400, 200]}, {'class': 0, 'score': .8, 'box': [20, 10, 180, 168]}]
    assert P.final_crops(pred, img, {'threshold': .5}) == []


def test_final_crops_single_box_is_not_a_split():
    img, _ = two_panel()
    pred = [{'class': 0, 'score': .9, 'box': [20, 10, 180, 168]}]
    assert P.final_crops(pred, img, {'threshold': .5}) == []


def test_final_crops_two_panels_complete():
    img, panels = two_panel()
    pred = [{'class': 0, 'score': .9, 'box': [20, 30, 180, 150]}, {'class': 0, 'score': .85, 'box': [220, 30, 380, 150]},
            {'class': 1, 'score': .9, 'box': [0, 0, 10, 10]}]
    crops = P.final_crops(pred, img, {'threshold': .5, 'complete': True})
    assert len(crops) == 2
    assert crops[0][1] <= 10 and crops[0][3] >= 168


def test_caption_decode_picks_exactly_L_non_overlapping_boxes():
    img, panels = two_panel()
    pred = [{'class': 0, 'score': .4, 'box': [20, 30, 180, 150]}, {'class': 0, 'score': .35, 'box': [25, 35, 175, 145]},
            {'class': 0, 'score': .3, 'box': [220, 30, 380, 150]}]
    crops = P.caption_decode(pred, 2, img, {'decode_min_cover': .3})
    assert crops is not None and len(crops) == 2
    assert P.caption_decode(pred, 3, img, {'decode_min_cover': .3}) is None


def test_group_to_count_merges_rows_only_when_unambiguous():
    # 2 rows x 3 columns of plots; caption names 2 parts -> rows.
    crops = [[c * 100, r * 100, c * 100 + 90, r * 100 + 90] for r in range(2) for c in range(3)]
    groups = P.group_to_count(crops, 2)
    assert groups is not None and len(groups) == 2
    assert groups[0][2] - groups[0][0] > 250
    # 2 x 2 grid and 2 parts: rows and columns both fit -> ambiguous, no grouping.
    grid = [[c * 100, r * 100, c * 100 + 90, r * 100 + 90] for r in range(2) for c in range(2)]
    assert P.group_to_count(grid, 2) is None


def test_display_box_matches_app_margin():
    assert P.display_box([100, 50, 200, 150], 1000, 500) == [80, 40, 220, 160]


DECODE = {'threshold': .5, 'panel_class': 0, 'complete': True, 'caption_decode': True, 'caption_fallback': 'plain',
          'decode_agree': True, 'decode_min_score': .15, 'decode_min_cover': .3, 'agree_iou': .7}


def test_reading_order_rows_then_columns():
    crops = [[200, 110, 300, 200], [0, 0, 100, 100], [0, 110, 100, 200], [200, 0, 300, 100]]
    assert P.reading_order(crops) == [[0, 0, 100, 100], [200, 0, 300, 100], [0, 110, 100, 200], [200, 110, 300, 200]]


def test_decide_split_with_named_parts_and_scores():
    img, panels = two_panel()
    pred = [{'class': 0, 'score': .9, 'box': [220, 30, 380, 150]}, {'class': 0, 'score': .8, 'box': [20, 30, 180, 150]}]
    d = P.decide(pred, img, DECODE, pred_b=pred, caption_letters=['a', 'b'])
    assert d['status'] == 'split' and [p['id'] for p in d['parts']] == ['P1', 'P2']
    assert d['parts'][0]['box'][0] < d['parts'][1]['box'][0]          # reading order
    assert d['parts'][0]['score'] == .8


def test_decide_falls_back_to_whole_when_views_disagree():
    img, _ = two_panel()
    a = [{'class': 0, 'score': .9, 'box': [220, 30, 380, 150]}, {'class': 0, 'score': .8, 'box': [20, 30, 180, 150]}]
    b = [{'class': 0, 'score': .9, 'box': [0, 0, 400, 200]}]
    d = P.decide(a, img, DECODE, pred_b=b, caption_letters=[])
    assert d['status'] == 'whole' and d['reason'] == 'views-disagree' and d['parts'] == []


def test_decide_single_figure():
    img, _ = two_panel()
    d = P.decide([{'class': 0, 'score': .9, 'box': [0, 0, 400, 200]}], img, DECODE, pred_b=[], caption_letters=[])
    assert d['status'] == 'whole'
