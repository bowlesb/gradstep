"""Bottom-up ink grouping: components and pairwise features (pure numpy/scipy; portable to Swift/TS).

A figure is decomposed into ink components (8-bit RGB, ink = min(R,G,B) < 235; components of the ink mask
after a square dilation of radius r = max(1, round(0.003 * max(W, H))), so glyphs merge into words and tick
marks stay with their axis). Panels are then unions of components; every ink pixel belongs to exactly one
component, so a crop built from whole components cannot clip ink.
"""
import math

import numpy as np
from scipy import ndimage

INK = 235
N_COMP_MAX = 400


def ink_mask(img):
    return img.min(axis=2) < INK


def _comp(lab, sl, i, img, sat, x_off=0, y_off=0, sub=None):
    if sub is None:
        sub = lab[sl] == i
    cnt = int(sub.sum())
    if cnt == 0:
        return None
    ys, xs = np.nonzero(sub)
    y0, x0 = sl[0].start, sl[1].start
    box = [float(x0 + xs.min()), float(y0 + ys.min()), float(x0 + xs.max() + 1), float(y0 + ys.max() + 1)]
    bw, bh = box[2] - box[0], box[3] - box[1]
    return {'label': i, 'box': box, 'ink': cnt, 'fill': cnt / max(1.0, bw * bh),
            'sat': float(sat[sl][sub].mean()) / 255.0, 'dark': float(img[sl][sub].mean()) / 255.0}


def components(img, mask=None, max_components=N_COMP_MAX, radius_frac=0.003, split_boxes=None):
    """Returns (comps, labels). comps: dicts with box [x0,y0,x1,y1], ink, fill, sat, dark.
    split_boxes (optional detector panel boxes): a component holding >= 10% of its ink in each of two or more
    boxes (touching panels, shared spines) is cut, each pixel going to the box that contains it (or the nearest)."""
    if mask is None:
        mask = ink_mask(img)
    H, W = mask.shape
    r = max(1, int(round(radius_frac * max(W, H))))
    dil = ndimage.binary_dilation(mask, structure=np.ones((2 * r + 1, 2 * r + 1), bool))
    lab, n = ndimage.label(dil)
    lab = np.where(mask, lab, 0)
    objs = ndimage.find_objects(lab)
    sat = (img.max(axis=2).astype(np.int16) - img.min(axis=2).astype(np.int16))
    comps = []
    next_label = n + 1
    for i, sl in enumerate(objs, 1):
        if sl is None:
            continue
        sub = lab[sl] == i
        if split_boxes and sub.sum() > 50:
            ys, xs = np.nonzero(sub)
            ys = ys + sl[0].start; xs = xs + sl[1].start
            inside = np.stack([(xs >= b[0]) & (xs < b[2]) & (ys >= b[1]) & (ys < b[3]) for b in split_boxes])
            share = inside.mean(axis=1)
            hit = [k for k in range(len(split_boxes)) if share[k] >= 0.10]
            if len(hit) >= 2:
                hb = [split_boxes[k] for k in hit]
                d = np.stack([np.hypot(np.maximum(0, np.maximum(b[0] - xs, xs - b[2])), np.maximum(0, np.maximum(b[1] - ys, ys - b[3]))) for b in hb])
                own = d.argmin(0)
                for k in range(len(hb)):
                    selm = own == k
                    if not selm.any():
                        continue
                    lab[ys[selm], xs[selm]] = next_label
                    y0, y1, x0, x1 = ys[selm].min(), ys[selm].max() + 1, xs[selm].min(), xs[selm].max() + 1
                    c = _comp(lab, (slice(y0, y1), slice(x0, x1)), next_label, img, sat)
                    if c:
                        comps.append(c)
                    next_label += 1
                continue
        c = _comp(lab, sl, i, img, sat, sub=sub)
        if c:
            comps.append(c)
    return comps, lab


def gap(a, b):
    dx = max(0.0, max(a[0], b[0]) - min(a[2], b[2]))
    dy = max(0.0, max(a[1], b[1]) - min(a[3], b[3]))
    return dx, dy


def integral(mask):
    return np.pad(mask.astype(np.int64).cumsum(0).cumsum(1), ((1, 0), (1, 0)))


def box_sum(ii, x0, y0, x1, y1):
    H, W = ii.shape[0] - 1, ii.shape[1] - 1
    x0, x1 = int(max(0, min(W, math.floor(x0)))), int(max(0, min(W, math.ceil(x1))))
    y0, y1 = int(max(0, min(H, math.floor(y0)))), int(max(0, min(H, math.ceil(y1))))
    if x1 <= x0 or y1 <= y0:
        return 0
    return int(ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0])


def candidate_pairs(comps, k=8, big_frac=0.02):
    """k nearest neighbours by box gap, plus all pairs among big components (>= big_frac of ink)."""
    n = len(comps)
    if n < 2:
        return []
    B = np.array([c['box'] for c in comps])
    dx = np.maximum(0, np.maximum(B[:, None, 0], B[None, :, 0]) - np.minimum(B[:, None, 2], B[None, :, 2]))
    dy = np.maximum(0, np.maximum(B[:, None, 1], B[None, :, 1]) - np.minimum(B[:, None, 3], B[None, :, 3]))
    d = np.hypot(dx, dy)
    np.fill_diagonal(d, np.inf)
    pairs = set()
    kk = min(k, n - 1)
    nn = np.argpartition(d, kk - 1, axis=1)[:, :kk]
    for i in range(n):
        for j in nn[i]:
            pairs.add((min(i, int(j)), max(i, int(j))))
    tot = sum(c['ink'] for c in comps)
    big = [i for i, c in enumerate(comps) if c['ink'] >= big_frac * tot]
    for a in range(len(big)):
        for b in range(a + 1, len(big)):
            pairs.add((big[a], big[b]))
    return sorted(pairs)


def det_assign(comps, det_boxes):
    """Index of the detector box holding most of each component's box area (-1 if none >= 50%), and that fraction."""
    out = []
    for c in comps:
        b = c['box']; a = max(1.0, (b[2] - b[0]) * (b[3] - b[1]))
        best, bf = -1, 0.0
        for k, d in enumerate(det_boxes):
            w = min(b[2], d[2]) - max(b[0], d[0]); h = min(b[3], d[3]) - max(b[1], d[1])
            f = max(0.0, w) * max(0.0, h) / a
            if f > bf:
                best, bf = k, f
        out.append((best if bf >= 0.5 else -1, bf))
    return out


FEATURES = ['gx', 'gy', 'g', 'gx_rel', 'gy_rel', 'ox', 'oy', 'cdx', 'cdy', 'a_i', 'a_j', 'a_ratio', 'ink_i', 'ink_j',
            'w_i', 'h_i', 'w_j', 'h_j', 'fill_i', 'fill_j', 'sat_i', 'sat_j', 'text_i', 'text_j', 'bridge_ink',
            'clean_vgutter', 'clean_hgutter', 'n_comp', 'aspect_img',
            'det_same', 'det_both', 'det_either', 'det_frac_i', 'det_frac_j', 'det_n']


def pair_features(comps, pairs, mask, ii=None, det=None, n_det=0):
    H, W = mask.shape
    S = float(max(W, H))
    if ii is None:
        ii = integral(mask)
    tot = float(sum(c['ink'] for c in comps)) or 1.0
    X = np.zeros((len(pairs), len(FEATURES)), np.float32)
    for r, (i, j) in enumerate(pairs):
        a, b = comps[i]['box'], comps[j]['box']
        gx, gy = gap(a, b)
        wi, hi, wj, hj = a[2] - a[0], a[3] - a[1], b[2] - b[0], b[3] - b[1]
        ox = max(0.0, min(a[2], b[2]) - max(a[0], b[0])) / max(1.0, min(wi, wj))
        oy = max(0.0, min(a[3], b[3]) - max(a[1], b[1])) / max(1.0, min(hi, hj))
        # Ink in the region between the two boxes (bridge), and clean whitespace gutters separating them.
        ux0, uy0, ux1, uy1 = min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])
        bridge = 0.0
        cv = ch = 0.0
        if gx > 0:
            lx, rx = (a[2], b[0]) if a[2] <= b[0] else (b[2], a[0])
            col = box_sum(ii, lx, uy0, rx, uy1)
            cv = 1.0 if col == 0 else 0.0
            bridge = col / max(1.0, (rx - lx) * (uy1 - uy0))
        if gy > 0:
            ty, by = (a[3], b[1]) if a[3] <= b[1] else (b[3], a[1])
            row = box_sum(ii, ux0, ty, ux1, by)
            ch = 1.0 if row == 0 else 0.0
            bridge = max(bridge, row / max(1.0, (by - ty) * (ux1 - ux0)))
        ai, aj = wi * hi / (W * H), wj * hj / (W * H)
        text_i = 1.0 if hi < 0.045 * H and wi > 0.8 * hi else 0.0
        text_j = 1.0 if hj < 0.045 * H and wj > 0.8 * hj else 0.0
        if det is not None:
            di, dj = det[i], det[j]
            ds = 1.0 if di[0] >= 0 and di[0] == dj[0] else 0.0
            both = 1.0 if di[0] >= 0 and dj[0] >= 0 else 0.0
            either = 1.0 if (di[0] >= 0) != (dj[0] >= 0) else 0.0
            dfi, dfj = di[1], dj[1]
        else:
            ds = both = either = dfi = dfj = -1.0
        X[r] = [gx / S, gy / S, math.hypot(gx, gy) / S, gx / max(1.0, min(wi, wj)), gy / max(1.0, min(hi, hj)), ox, oy,
                ((a[0] + a[2]) - (b[0] + b[2])) / (2 * S), ((a[1] + a[3]) - (b[1] + b[3])) / (2 * S),
                ai, aj, min(ai, aj) / max(1e-9, max(ai, aj)), comps[i]['ink'] / tot, comps[j]['ink'] / tot,
                wi / W, hi / H, wj / W, hj / H, comps[i]['fill'], comps[j]['fill'], comps[i]['sat'], comps[j]['sat'],
                text_i, text_j, bridge, cv, ch, min(len(comps), 400) / 400.0, W / max(1.0, H),
                ds, both, either, dfi, dfj, float(n_det)]
    return X
