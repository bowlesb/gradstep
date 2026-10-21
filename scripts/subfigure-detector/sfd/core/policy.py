#!/usr/bin/env python3
"""From raw detector output to the crops the app would show, plus the completeness post-processor.

`final_crops(pred, image, cfg)` applies: score threshold, duplicate/nesting suppression,
single-vs-compound gate, and (optionally) ink completion: every ink component touching a
crop's edge is pulled in, and ink owned by no crop is attached to its nearest crop(s), so the
union of crops covers every ink pixel of the figure. Returns [] for "keep the whole figure".
Pure geometry over the decoded image; no model call.
"""
import math

import numpy as np
from scipy import ndimage


def area(b):
    return max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])


def inter(a, b):
    return [max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])]


def union(a, b):
    return [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]


def iou(a, b):
    i = area(inter(a, b))
    return i / max(1e-9, area(a) + area(b) - i)


def gap(a, b):
    dx = max(0.0, max(a[0], b[0]) - min(a[2], b[2]))
    dy = max(0.0, max(a[1], b[1]) - min(a[3], b[3]))
    return math.hypot(dx, dy)


def ink_mask(img, thresh=235):
    return img.min(axis=2) < thresh


def ink_components(mask, radius_frac=0.003):
    H, W = mask.shape
    r = max(1, int(round(radius_frac * max(W, H))))
    dil = ndimage.binary_dilation(mask, structure=np.ones((2 * r + 1, 2 * r + 1), bool))
    lab, n = ndimage.label(dil)
    comps = []
    for i, sl in enumerate(ndimage.find_objects(lab), 1):
        if sl is None:
            continue
        sub = (lab[sl] == i) & mask[sl]
        if not sub.any():
            continue
        ys, xs = np.nonzero(sub)
        comps.append([float(sl[1].start + xs.min()), float(sl[0].start + ys.min()),
                      float(sl[1].start + xs.max() + 1), float(sl[0].start + ys.max() + 1), int(sub.sum())])
    return comps


def suppress(boxes, iou_thr=0.5, contain_thr=0.85):
    kept = []
    for b in sorted(boxes, key=lambda x: -x['score']):
        bb = b['box']
        ok = True
        for k in kept:
            kb = k['box']
            ov = area(inter(bb, kb))
            if iou(bb, kb) > iou_thr or ov > contain_thr * area(bb) or ov > contain_thr * area(kb):
                ok = False
                break
        if ok:
            kept.append(b)
    return kept


def complete(crops, mask, comps=None, attach_orphans=True, max_iter=4):
    """Grow crops to whole ink components; attach unowned ink so the crops cover all ink."""
    if comps is None:
        comps = ink_components(mask)
    H, W = mask.shape
    boxes = [list(c) for c in crops]
    orig = [list(c) for c in crops]
    owner = []
    for c in comps:
        cb = c[:4]
        a = area(cb)
        best, frac = None, 0.0
        for k, o in enumerate(orig):
            f = area(inter(cb, o)) / max(1e-9, a)
            if f > frac:
                best, frac = k, f
        owner.append((best, frac))
    for _ in range(max_iter):
        changed = False
        for ci, c in enumerate(comps):
            cb = c[:4]
            for k, b in enumerate(boxes):
                ov = area(inter(cb, b))
                if ov <= 0:
                    continue
                # Frames, connectors or backgrounds larger than the crop itself are not panel ink.
                if area(cb) > 1.5 * area(orig[k]):
                    continue
                inside = ov >= area(cb) - 1e-6
                if inside:
                    continue
                o, frac = owner[ci]
                # A component mostly inside another crop's original box belongs to that crop.
                if o is not None and o != k and frac >= 0.5:
                    continue
                # Only labels/letters/ticks (small) or this crop's own clipped body may be pulled in.
                if area(cb) > 0.5 * area(orig[k]) and not (o == k and frac >= 0.6):
                    continue
                nb = union(b, cb)
                # Never grow into another crop's panel.
                if any(j != k and area(inter(nb, orig[j])) - area(inter(b, orig[j])) > 0.08 * area(orig[j]) for j in range(len(orig))):
                    continue
                if nb != b:
                    boxes[k] = nb
                    changed = True
        if not changed:
            break
    if attach_orphans and boxes:
        for ci, c in enumerate(comps):
            cb = c[:4]
            if any(area(inter(cb, b)) >= 0.999 * area(cb) for b in boxes):
                continue
            if any(area(inter(cb, b)) > 0 for b in boxes) and area(cb) > 0.5 * W * H:
                continue  # a figure-wide frame/connector touching crops: not an orphan to attach
            d = sorted((gap(cb, b), k) for k, b in enumerate(boxes))
            near = [d[0][1]]
            # Equidistant (shared) context goes to every crop it is equally close to.
            for dist, k in d[1:]:
                if dist <= d[0][0] * 1.15 + 2:
                    near.append(k)
            for k in near:
                nb = union(boxes[k], cb)
                if any(j != k and area(inter(nb, orig[j])) - area(inter(boxes[k], orig[j])) > 0.08 * area(orig[j]) for j in range(len(orig))):
                    continue  # attaching would swallow another panel: leave it as uncovered shared context
                boxes[k] = nb
    return [[max(0.0, b[0]), max(0.0, b[1]), min(float(W), b[2]), min(float(H), b[3])] for b in boxes]


def final_crops(pred, img, cfg):
    """pred: list of {'class','score','box'}; cfg keys: threshold, panel_class, gate (prob or None),
    gate_threshold, complete (bool), merge_iou."""
    H, W = img.shape[:2]
    cls = cfg.get('panel_class', 0)
    boxes = [p for p in pred if p['class'] == cls and p['score'] >= cfg.get('threshold', 0.5)]
    boxes = suppress(boxes, cfg.get('nms_iou', 0.5), cfg.get('contain', 0.85))
    if cfg.get('gate') is not None and cfg['gate'] < cfg.get('gate_threshold', 0.5):
        return []
    # A dominant near-whole-image box means the detector reads the figure as one panel.
    if any(area(b['box']) >= cfg.get('whole_area', 0.85) * W * H for b in boxes):
        return []
    if len(boxes) <= 1:
        return []
    crops = [b['box'] for b in boxes]
    if cfg.get('complete', False):
        mask = cfg['_mask'] if cfg.get('_mask') is not None else ink_mask(img)
        comps = cfg.get('_comps')
        crops = complete(crops, mask, comps, attach_orphans=cfg.get('attach_orphans', True))
        # Completion can make crops coincide (one panel predicted twice); merge those.
        merged = True
        while merged and len(crops) > 1:
            merged = False
            for a in range(len(crops)):
                for b in range(a + 1, len(crops)):
                    if iou(crops[a], crops[b]) > cfg.get('merge_iou', 0.6):
                        crops[a] = union(crops[a], crops[b]); crops.pop(b); merged = True
                        break
                if merged:
                    break
        if len(crops) <= 1 or any(area(c) >= 0.92 * W * H for c in crops):
            return []
    return crops


def display_box(b, W, H, margin=0.02):
    """The app's displayed crop: 2% of the image on each side, outward pixel rounding (figure-view.ts)."""
    x0 = max(0, math.floor(b[0] - margin * W)); y0 = max(0, math.floor(b[1] - margin * H))
    x1 = min(W, math.ceil(b[2] + margin * W)); y1 = min(H, math.ceil(b[3] + margin * H))
    return [x0, y0, x1, y1]


def _bands(crops, axis):
    """Cluster crops into bands along one axis (rows: axis=1, columns: axis=0) by extent overlap."""
    lo, hi = (1, 3) if axis == 1 else (0, 2)
    order = sorted(range(len(crops)), key=lambda k: (crops[k][lo] + crops[k][hi]) / 2)
    bands = []
    for k in order:
        c = crops[k]
        placed = False
        for b in bands:
            ext = [min(crops[j][lo] for j in b), max(crops[j][hi] for j in b)]
            ov = min(ext[1], c[hi]) - max(ext[0], c[lo])
            if ov > 0.5 * min(c[hi] - c[lo], ext[1] - ext[0]):
                b.append(k); placed = True
                break
        if not placed:
            bands.append([k])
    return bands


def group_to_count(crops, L):
    """When the caption names L parts but the detector found more plotting areas, merge them by rows or
    by columns if that yields exactly L groups (lettered rows/columns of plots); otherwise None."""
    if L < 2 or len(crops) <= L:
        return None
    fits = [axis for axis in (1, 0) if len(_bands(crops, axis)) == L]
    if len(fits) != 1:
        return None  # neither, or both rows and columns give L groups: ambiguous, do not guess
    for axis in fits:
        bands = _bands(crops, axis)
        if len(bands) == L:
            out = []
            for b in bands:
                u = list(crops[b[0]])
                for j in b[1:]:
                    u = union(u, crops[j])
                out.append(u)
            # Merged groups must not overlap each other materially.
            if all(area(inter(out[a], out[b])) <= 0.05 * min(area(out[a]), area(out[b])) for a in range(L) for b in range(a + 1, L)):
                return out
    return None


def caption_decode(pred, L, img, cfg, min_score=0.15):
    """Caption-constrained decoding: choose exactly L mutually non-overlapping panel boxes, greedily by
    score from all candidates above `min_score`, then complete them. None if L boxes cannot be found or the
    chosen boxes leave most of the figure's ink uncovered (the caption's parts are not where the boxes are)."""
    H, W = img.shape[:2]
    cls = cfg.get('panel_class', 0)
    cands = sorted([p for p in pred if p['class'] == cls and p['score'] >= min_score], key=lambda p: -p['score'])
    chosen = []
    for p in cands:
        b = p['box']
        if area(b) >= cfg.get('whole_area', 0.85) * W * H:
            continue
        if any(iou(b, c) > 0.15 or area(inter(b, c)) > 0.3 * min(area(b), area(c)) for c in chosen):
            continue
        chosen.append(b)
        if len(chosen) == L:
            break
    if len(chosen) != L:
        return None
    mask = cfg['_mask'] if cfg.get('_mask') is not None else ink_mask(img)
    ys, xs = np.nonzero(mask)
    total = max(1, len(xs))
    covered = np.zeros(len(xs), bool)
    for b in chosen:
        covered |= (xs >= b[0]) & (xs < b[2]) & (ys >= b[1]) & (ys < b[3])
    if covered.mean() < cfg.get('decode_min_cover', 0.7):
        return None
    crops = complete(chosen, mask, cfg.get('_comps'))
    if any(area(c) >= 0.92 * W * H for c in crops):
        return None
    return crops


POLICY_REVISION = 'sfd-policy-2026-10-22'

LETTER_LINE = __import__('re').compile(r'^\(?([a-lA-L])\)(?:\s|$)|^\(?([a-lA-L])\)?[.:]?$')


def letters_from_text(lines, wanted):
    """Panel letters from OCR/PDF text lines [{'text', 'box'}]: '(a)', '(a) Title', 'a)', 'a'. Returns
    [(char, box)] only when every wanted letter occurs exactly once; the letter's box is the line's first
    characters. None otherwise (the caller then ignores letters)."""
    found = {}
    for ln in lines:
        t = ln['text'].strip()
        m = LETTER_LINE.match(t)
        if not m:
            continue
        ch = (m.group(1) or m.group(2)).lower()
        if ch not in wanted:
            continue
        x0, y0, x1, y1 = ln['box']
        w = (x1 - x0) * min(1.0, 3.0 / max(1, len(t)))
        found.setdefault(ch, []).append([x0, y0, x0 + w, y1])
    if sorted(found) != sorted(wanted) or any(len(v) != 1 for v in found.values()):
        return None
    return [(c, found[c][0]) for c in sorted(found)]


def cx(b):
    return (b[0] + b[2]) / 2


def cy(b):
    return (b[1] + b[3]) / 2


def group_by_letters(cores, panel_boxes, letters):
    """cores/panel_boxes: per plotting area; letters: list of (char, box). Returns group boxes or (None, why)."""
    L = len(letters)
    votes = 0
    for _, lb in letters:
        j = min(range(len(cores)), key=lambda k: gap(lb, cores[k]))
        votes += 1 if cy(lb) <= cores[j][1] + 0.25 * (cores[j][3] - cores[j][1]) else -1
    mode = 'top' if votes >= 0 else 'bottom'
    assign = []
    for c in cores:
        best, bd = None, 1e18
        for k, (_, lb) in enumerate(letters):
            if mode == 'top':
                ok = cy(lb) <= c[1] + 0.25 * (c[3] - c[1]) and cx(lb) <= c[2]
                d = ((cx(lb) - c[0]) ** 2 + (cy(lb) - c[1]) ** 2) ** .5
            else:
                ok = cy(lb) >= c[3] - 0.25 * (c[3] - c[1]) and min(lb[2], c[2]) - max(lb[0], c[0]) > -0.5 * (c[2] - c[0])
                d = ((cx(lb) - cx(c)) ** 2 + (cy(lb) - c[3]) ** 2) ** .5
            if ok and d < bd:
                best, bd = k, d
        if best is None:
            return None, 'unassigned_area'
        assign.append(best)
    if set(assign) != set(range(L)):
        return None, 'letter_without_area'
    groups = []
    for k in range(L):
        u = list(letters[k][1])
        for j, a in enumerate(assign):
            if a == k:
                u = union(u, panel_boxes[j])
        groups.append(u)
    for a in range(L):
        for b in range(a + 1, L):
            if area(inter(groups[a], groups[b])) > 0.03 * min(area(groups[a]), area(groups[b])):
                return None, 'group_overlap'
    for k in range(L):
        for j, a in enumerate(assign):
            if a != k and area(inter(groups[k], cores[j])) > 0.05 * area(cores[j]):
                return None, 'group_contains_other_area'
    return (groups, mode), 'ok'





def agree(a, b, thr=.7):
    """Two views agree when they give the same number of crops and the crops pair up at IoU >= thr."""
    if len(a) != len(b):
        return False
    if not a:
        return True
    from scipy.optimize import linear_sum_assignment
    M = np.array([[iou(x, y) for y in b] for x in a])
    i, j = linear_sum_assignment(-M)
    return bool((M[i, j] >= thr).all())


def reading_order(crops):
    """Rows top to bottom (crops whose vertical extents overlap by > 50% share a row), left to right."""
    if not crops:
        return []
    bands = _bands(crops, 1)
    bands.sort(key=lambda b: min(crops[k][1] for k in b))
    return [crops[k] for b in bands for k in sorted(b, key=lambda k: crops[k][0])]


def _score_of(crop, pred, cls):
    best = 0.0
    for p in pred:
        if p['class'] == cls and iou(p['box'], crop) >= 0.3:
            best = max(best, p['score'])
    return best


def letter_regroup(pred, img, letters, c):
    """Group detected plotting areas under printed letters (lettered parts made of several plots)."""
    H, W = img.shape[:2]
    raw = [p for p in pred if p['class'] == c.get('panel_class', 0) and p['score'] >= c.get('threshold', .5)]
    raw = [b['box'] for b in suppress(raw, c.get('nms_iou', .5), c.get('contain', .85)) if area(b['box']) < .85 * W * H]
    if len(raw) <= len(letters):
        return None
    res, _ = group_by_letters(raw, raw, letters)
    if res is None:
        return None
    groups, _ = res
    crops = complete(groups, c['_mask'], c.get('_comps'))
    if any(area(x) >= .92 * W * H for x in crops):
        return None
    return crops


def decide(pred_a, img, cfg, pred_b=None, caption_letters=(), mask=None, comps=None, text_lines=None):
    """The complete on-device decision for one figure image (reference implementation for the apps).

    pred_a / pred_b: decoded detections ({'class', 'score', 'box'} in image pixels) for the 1.0 and 0.75
    placements; caption_letters: distinct panel letters named by the caption. Returns
    {'status': 'split'|'whole', 'reason': str, 'parts': [{'id': 'P1', 'box': [x0,y0,x1,y1], 'score': s}]}.
    'whole' means: show and send the whole figure (single figure, or the system is unsure).
    """
    m = mask if mask is not None else ink_mask(img)
    c = dict(cfg, _mask=m, _comps=comps if comps is not None else ink_components(m))
    L = len(caption_letters or [])
    use_b = pred_b is not None and cfg.get('agree_iou')
    thr = cfg.get('agree_iou', .7)
    crops, reason = None, None
    if cfg.get('letter_group') and L >= 2 and text_lines:
        letters = letters_from_text(text_lines, sorted(set(caption_letters)))
        if letters:
            g = letter_regroup(pred_a, img, letters, c)
            if g:
                parts = [{'id': f'P{k + 1}', 'box': [float(v) for v in b], 'score': round(_score_of(b, pred_a, cfg.get('panel_class', 0)), 4)}
                         for k, b in enumerate(reading_order(g))]
                return {'status': 'split', 'reason': 'letter-grouped', 'parts': parts}
    if cfg.get('caption_decode') and L >= 2:
        crops = caption_decode(pred_a, L, img, c, cfg.get('decode_min_score', .15)) or []
        reason = 'caption-decoded'
        if not crops and cfg.get('caption_fallback', 'whole') == 'plain':
            crops, reason = final_crops(pred_a, img, c), 'caption-mismatch-detector-fallback'
        if use_b and crops and cfg.get('decode_agree', True):
            cb = caption_decode(pred_b, L, img, dict(c)) or final_crops(pred_b, img, dict(c))
            if not agree(crops, cb, thr):
                crops, reason = [], 'views-disagree'
    else:
        crops, reason = final_crops(pred_a, img, c), 'detector'
        if use_b:
            if not agree(crops, final_crops(pred_b, img, dict(c)), thr):
                crops, reason = [], 'views-disagree'
    if len(crops) < 2:
        return {'status': 'whole', 'reason': reason if reason == 'views-disagree' else 'single-or-unsure', 'parts': []}
    cls = cfg.get('panel_class', 0)
    parts = [{'id': f'P{k + 1}', 'box': [float(v) for v in b], 'score': round(_score_of(b, pred_a, cls), 4)}
             for k, b in enumerate(reading_order(crops))]
    return {'status': 'split', 'reason': reason, 'parts': parts}


def caption_letters(caption):
    """Distinct panel letters a caption names: '(a)', 'a)' followed by space, '\\textbf{(a)}' (as in corpus_index)."""
    import re
    letters = set()
    for m in re.finditer(r'\(([a-hA-H])\)', caption):
        letters.add(m.group(1).lower())
    for m in re.finditer(r'(?<![\w\\])([a-h])\)\s', caption):
        letters.add(m.group(1))
    for m in re.finditer(r'\\textbf\{\s*\(?([a-hA-H])\)?\s*[\.:]?\s*\}', caption):
        letters.add(m.group(1).lower())
    return sorted(letters)


def letterbox_transform(width, height, size=640, zoom=1.0):
    """The model input placement: aspect fit * zoom, centred, white padding. Returns (sx, sy, left, top, rw, rh)."""
    s = min(size / width, size / height) * zoom
    rw, rh = max(1, round(width * s)), max(1, round(height * s))
    left, top = int((size - rw) * .5), int((size - rh) * .5)
    return rw / width, rh / height, left, top, rw, rh


def decode_outputs(logits, boxes, width, height, size=640, zoom=1.0, min_score=.03):
    """Raw model outputs (logits [Q, C], normalized cx,cy,w,h boxes [Q, 4] in the letterbox) -> detections
    {'class', 'score', 'box': [x0, y0, x1, y1] in original image pixels}."""
    sx, sy, left, top, _, _ = letterbox_transform(width, height, size, zoom)
    prob = 1 / (1 + np.exp(-np.clip(np.asarray(logits, dtype=np.float64), -80, 80)))
    out = []
    for p, b in zip(prob, np.asarray(boxes, dtype=np.float64)):
        k = int(p.argmax()); s = float(p[k])
        if s < min_score:
            continue
        cx, cy, bw, bh = b * size
        bb = [max(0., (cx - bw / 2 - left) / sx), max(0., (cy - bh / 2 - top) / sy),
              min(float(width), (cx + bw / 2 - left) / sx), min(float(height), (cy + bh / 2 - top) / sy)]
        if bb[2] > bb[0] and bb[3] > bb[1]:
            out.append({'class': k, 'score': s, 'box': bb})
    return out
