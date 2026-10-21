"""Bottom-up grouping of ink components into panels (inference).

Pairwise affinities from the trained model -> average-linkage agglomeration over candidate edges (merge while
the mean affinity >= `thr`). Clusters holding >= `panel_ink` of the figure's ink are panels; smaller clusters
(letters, legends, stray labels) are attached to the panel they are most affine to (nearest if no edge), so
every ink pixel ends in some crop. When the caption names L >= 2 parts, the merge history is replayed to the
stage with exactly L panels if one exists with mean affinity >= `floor`. Crops are bounding boxes of the
assigned components: they cannot clip a component.
"""
import heapq

import numpy as np

from sfd.group import features as F


def _bbox(comps, members):
    b = [min(comps[m]['box'][0] for m in members), min(comps[m]['box'][1] for m in members),
         max(comps[m]['box'][2] for m in members), max(comps[m]['box'][3] for m in members)]
    return b


def agglomerate(n, pairs, probs, floor):
    """Average-linkage merges in order of mean affinity, continuing down to `floor`. Returns merge list
    [(score, a, b)] where a, b are cluster ids (cluster id = smallest member id at merge time)."""
    parent = list(range(n))
    members = {i: [i] for i in range(n)}
    edge = {}
    for (i, j), p in zip(pairs, probs):
        edge.setdefault(i, {})[j] = [p, 1]; edge.setdefault(j, {})[i] = [p, 1]
    heap = [(-p, i, j) for (i, j), p in zip(pairs, probs)]
    heapq.heapify(heap)
    merges = []
    alive = set(range(n))
    while heap:
        negp, a, b = heapq.heappop(heap)
        if a not in alive or b not in alive or b not in edge.get(a, {}):
            continue
        s, c = edge[a][b]
        if abs(s / c + negp) > 1e-9:  # stale entry
            continue
        score = s / c
        if score < floor:
            break
        # merge b into a
        merges.append((score, a, b))
        members[a] += members.pop(b)
        alive.discard(b)
        for k, (sk, ck) in edge.pop(b, {}).items():
            edge[k].pop(b, None)
            if k == a:
                continue
            if k in edge[a]:
                edge[a][k][0] += sk; edge[a][k][1] += ck
            else:
                edge[a][k] = [sk, ck]
            edge[k][a] = edge[a][k]
            heapq.heappush(heap, (-(edge[a][k][0] / edge[a][k][1]), min(a, k) if False else a, k))
    return merges


def clusters_at(n, merges, upto):
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    for score, a, b in merges[:upto]:
        parent[find(b)] = find(a)
    out = {}
    for i in range(n):
        out.setdefault(find(i), []).append(i)
    return list(out.values())


def finalize(comps, groups, pairs, probs, panel_ink):
    tot = float(sum(c['ink'] for c in comps)) or 1.0
    ink = [sum(comps[m]['ink'] for m in g) for g in groups]
    panels = [k for k, v in enumerate(ink) if v >= panel_ink * tot]
    if len(panels) < 2:
        return None
    gid = {}
    for k, g in enumerate(groups):
        for m in g:
            gid[m] = k
    aff = {}
    for (i, j), p in zip(pairs, probs):
        a, b = gid[i], gid[j]
        if a != b:
            aff.setdefault(a, {}).setdefault(b, []).append(p); aff.setdefault(b, {}).setdefault(a, []).append(p)
    assign = {k: k for k in panels}
    boxes = {k: _bbox(comps, groups[k]) for k in range(len(groups))}
    for k in range(len(groups)):
        if k in assign:
            continue
        cand = {t: np.mean(v) for t, v in aff.get(k, {}).items() if t in panels}
        if cand:
            assign[k] = max(cand, key=cand.get)
        else:
            assign[k] = min(panels, key=lambda t: sum(F.gap(boxes[k], boxes[t])))
    out = {k: list(groups[k]) for k in panels}
    for k, t in assign.items():
        if k != t:
            out[t] += groups[k]
    return [_bbox(comps, v) for v in out.values()]


def group_figure(img, model, det=None, caption_letters=(), thr=.5, floor=.15, panel_ink=.04, mask=None, split=False,
                 radius_frac=0.003, det_split_score=.5):
    """Returns crops (list of [x0,y0,x1,y1]); [] means keep the whole figure."""
    mask = F.ink_mask(img) if mask is None else mask
    sb = None
    if split and det:
        from sfd.core import policy as Pc
        sb = [b['box'] for b in Pc.suppress([p for p in det if p['class'] == 0 and p['score'] >= det_split_score])]
        H, W = mask.shape
        sb = [b for b in sb if (b[2] - b[0]) * (b[3] - b[1]) < .85 * W * H] or None
    comps, lab = F.components(img, mask, radius_frac=radius_frac, split_boxes=sb)
    if len(comps) < 2:
        return []
    extra = []
    if len(comps) > F.N_COMP_MAX:
        comps.sort(key=lambda c: -c['ink'])
        comps, extra = comps[:F.N_COMP_MAX], comps[F.N_COMP_MAX:]
    pairs = F.candidate_pairs(comps)
    dboxes = [p['box'] for p in (det or []) if p['class'] == 0 and p['score'] >= .3]
    da = F.det_assign(comps, dboxes) if det is not None else None
    X = F.pair_features(comps, pairs, mask, det=da, n_det=len(dboxes))
    probs = model.predict_proba(X)[:, 1]
    merges = agglomerate(len(comps), pairs, probs, floor)
    n_thr = sum(1 for s, _, _ in merges if s >= thr)
    stage = n_thr
    L = len(caption_letters or [])
    if L >= 2:
        tot = float(sum(c['ink'] for c in comps)) or 1.0
        def npanels(k):
            g = clusters_at(len(comps), merges, k)
            return sum(1 for x in g if sum(comps[m]['ink'] for m in x) >= panel_ink * tot)
        if npanels(n_thr) != L:
            best = None
            for k in range(len(merges) + 1):
                if npanels(k) == L and (best is None or abs(k - n_thr) < abs(best - n_thr)):
                    best = k
            if best is not None:
                stage = best
    groups = clusters_at(len(comps), merges, stage)
    crops = finalize(comps, groups, pairs, probs, panel_ink)
    if not crops:
        return []
    for c in extra:  # tiny components beyond the cap join the nearest crop
        k = min(range(len(crops)), key=lambda t: sum(F.gap(c['box'], crops[t])))
        b = crops[k]
        crops[k] = [min(b[0], c['box'][0]), min(b[1], c['box'][1]), max(b[2], c['box'][2]), max(b[3], c['box'][3])]
    H, W = mask.shape
    if any((b[2] - b[0]) * (b[3] - b[1]) >= .92 * W * H for b in crops):
        return []
    return crops
