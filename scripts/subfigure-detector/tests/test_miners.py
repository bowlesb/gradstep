import json

import numpy as np
import pytest

from sfd.mine import letter_groups as LG
from sfd.mine import vector_labels as V
from sfd.mine import xycut_labels as X
from sfd.annotate import candidates as C
from helpers import two_panel


def test_letter_groups_top_layout():
    # Two rows of three plots; letters (a) above row 1 and (b) above row 2.
    cores = [[c * 110 + 10, r * 120 + 30, c * 110 + 100, r * 120 + 110] for r in range(2) for c in range(3)]
    letters = [('a', [5, 5, 20, 20]), ('b', [5, 125, 20, 140])]
    (groups, mode), why = LG.group_by_letters(cores, cores, letters)
    assert why == 'ok' and mode == 'top' and len(groups) == 2
    assert groups[0][3] < groups[1][1]


def test_letter_groups_rejects_letter_without_area():
    cores = [[10, 30, 100, 110], [120, 30, 210, 110]]
    letters = [('a', [5, 5, 20, 20]), ('b', [500, 500, 510, 510]), ('c', [120, 5, 130, 20])]
    res, why = LG.group_by_letters(cores, cores, letters)
    assert res is None


def test_xycut_finds_two_bodies_and_letters_join_them():
    img, panels = two_panel()
    mask = V.ink_mask(img)
    blocks = C.xycut(mask, 0, 0, min_frac=0.02)
    bodies, groups, shared = X.group(blocks, img.shape[1], img.shape[0])
    assert len(bodies) == 2
    for g, p in zip(sorted(groups), sorted(panels)):
        assert g[1] <= p[1] + 1 and g[3] >= p[3] - 1


def test_vector_labels_on_matplotlib_pdf(tmp_path):
    plt = pytest.importorskip('matplotlib.pyplot')
    import matplotlib
    matplotlib.use('Agg')
    fig, axes = plt.subplots(1, 3, figsize=(9, 3))
    for k, ax in enumerate(axes):
        ax.plot(np.arange(10), np.arange(10) ** (k + 1))
        ax.set_title(f'({chr(97 + k)}) panel'); ax.set_xlabel('x'); ax.set_ylabel('y')
    fig.tight_layout()
    pdf = tmp_path / 'fig.pdf'
    fig.savefig(pdf); plt.close(fig)
    img, info = V.label_figure(str(pdf))
    assert 'reject' not in info, info.get('reject')
    assert info['panels'] == 3
    boxes = sorted(info['panel_boxes'])
    for a, b in zip(boxes, boxes[1:]):
        assert a[2] <= b[0] + 1            # panels do not overlap
    mask = V.ink_mask(img)
    covered = np.zeros_like(mask)
    for x0, y0, x1, y1 in info['panel_boxes'] + info['shared_boxes']:
        covered[int(y0):int(np.ceil(y1)), int(x0):int(np.ceil(x1))] = True
    assert (mask & ~covered).sum() < 0.002 * mask.sum()   # every ink pixel is labelled


def test_vector_labels_single_axes_is_one_panel(tmp_path):
    plt = pytest.importorskip('matplotlib.pyplot')
    fig, ax = plt.subplots(figsize=(4, 3))
    ax.plot([0, 1], [0, 1]); ax.set_xlabel('x'); ax.legend(['line'])
    pdf = tmp_path / 'one.pdf'
    fig.savefig(pdf); plt.close(fig)
    _, info = V.label_figure(str(pdf))
    assert info['panels'] == 1 and 'reject' not in info
