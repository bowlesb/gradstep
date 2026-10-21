import numpy as np

from sfd.group import features as F
from sfd.group import group as G
from sfd.mine.html_structure import FigParser
from helpers import two_panel


class GeometryModel:
    """Stand-in affinity for the fixture: same panel iff the horizontal centres are close (|cdx| < 0.3)."""
    def predict_proba(self, X):
        k = F.FEATURES.index('cdx')
        p = np.where(np.abs(X[:, k]) < 0.3, .95, .05)
        return np.stack([1 - p, p], 1)


def test_components_cover_every_ink_pixel():
    img, _ = two_panel()
    comps, lab = F.components(img)
    mask = F.ink_mask(img)
    assert (lab[mask] > 0).all() and sum(c['ink'] for c in comps) == mask.sum()


def test_split_boxes_cut_a_component_spanning_two_panels():
    img, panels = two_panel()
    img[90, 180:221] = 0                     # a line bridging the two panels
    comps, _ = F.components(img)
    big = [c for c in comps if c['box'][2] - c['box'][0] > 300]
    assert big                                # bridged into one component
    comps2, _ = F.components(img, split_boxes=[[20, 30, 180, 150], [220, 30, 380, 150]])
    assert not [c for c in comps2 if c['box'][2] - c['box'][0] > 300]


def test_group_figure_two_panels_complete_and_whole_coverage():
    img, panels = two_panel()
    crops = G.group_figure(img, GeometryModel(), panel_ink=.2)
    assert len(crops) == 2
    for c, p in zip(sorted(crops), sorted(panels)):
        assert c[0] <= p[0] and c[1] <= p[1] and c[2] >= p[2] and c[3] >= p[3]


def test_group_figure_caption_replay_can_merge_to_one():
    img, _ = two_panel()
    # With a caption naming 2 parts the split is kept; a model that merges everything keeps the figure whole.
    class Merge:
        def predict_proba(self, X):
            return np.tile([.05, .95], (len(X), 1))
    assert G.group_figure(img, Merge()) == []


def test_html_census_counts_images_and_svg_objects():
    html = ('<figure class="ltx_figure"><img class="ltx_graphics" src="a.png"><object class="ltx_graphics" data="b.svg"></object>'
            '<figcaption>Figure 1: (a) one (b) two</figcaption></figure>'
            '<figure class="ltx_table"><img class="ltx_graphics" src="t.png"></figure>')
    p = FigParser(); p.feed(html)
    assert len(p.figs) == 1 and p.figs[0]['imgs'] == 2 and '(a)' in p.figs[0]['caption']
