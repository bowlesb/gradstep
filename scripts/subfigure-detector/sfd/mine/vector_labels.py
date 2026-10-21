#!/usr/bin/env python3
"""Vector-graphics panel supervision for single-file arXiv figures.

A one-page figure PDF from the author's source (matplotlib, pgfplots, R, ...) is rendered
to pixels exactly as an HTML/PDF figure would be, and its drawing operations give the
geometry: every plotting area is a clip rectangle. Each rendered ink component is then
assigned to its nearest plotting area (tick labels, axis labels, titles, letters, own
legends/colorbars) or marked as shared context (suptitles, legends or labels spanning
several panels). The result is a complete panel box that contains every ink pixel of the
panel, plus explicit shared-context boxes. Ambiguous layouts are rejected, never guessed.

Reads the corpus only; writes PNGs/labels into the output directory.
"""
import argparse, hashlib, io, json, math, multiprocessing as mp, os, sys, traceback
from pathlib import Path

import numpy as np
import pymupdf
from PIL import Image
from scipy import ndimage

LONG_SIDE = 1280
VERSION = 'vector-labels-v3'


def render(page, long_side=LONG_SIDE):
    r = page.rect
    scale = min(4.0, max(0.5, long_side / max(r.width, r.height)))
    pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False, colorspace=pymupdf.csRGB)
    img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)[:, :, :3].copy()
    return img, scale


def ink_mask(img, thresh=235):
    return (img.min(axis=2) < thresh)


def clip_rects(page):
    """Distinct clip rectangles that carry drawn content (plotting areas)."""
    items = page.get_drawings(extended=True)
    stack = []  # (level, rect)
    counts = {}
    for it in items:
        lvl = it.get('level', 0)
        while stack and stack[-1][0] >= lvl:
            stack.pop()
        t = it.get('type')
        if t == 'clip':
            sc = it.get('scissor')
            if sc is not None:
                stack.append((lvl, pymupdf.Rect(sc)))
            continue
        if t == 'group':
            continue
        if stack:
            key = tuple(round(v, 1) for v in stack[-1][1])
            counts[key] = counts.get(key, 0) + 1
    return counts


def to_px(rect, scale, origin):
    return [(rect[0] - origin[0]) * scale, (rect[1] - origin[1]) * scale, (rect[2] - origin[0]) * scale, (rect[3] - origin[1]) * scale]


def area(b):
    return max(0, b[2] - b[0]) * max(0, b[3] - b[1])


def inter(a, b):
    return [max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])]


def union(a, b):
    return [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]


def gap(a, b):
    dx = max(0, max(a[0], b[0]) - min(a[2], b[2]))
    dy = max(0, max(a[1], b[1]) - min(a[3], b[3]))
    return math.hypot(dx, dy)


def seeds_from_clips(counts, page_rect, scale, W, H):
    origin = (page_rect.x0, page_rect.y0)
    seeds = []
    for key, n in counts.items():
        b = to_px(key, scale, origin)
        b = inter(b, [0, 0, W, H])
        if b[2] - b[0] < 0.04 * W or b[3] - b[1] < 0.04 * H:
            continue
        if b[2] - b[0] < 12 or b[3] - b[1] < 12:
            continue
        if (b[2] - b[0]) > 0.97 * W and (b[3] - b[1]) > 0.97 * H:
            continue  # page-level clip
        seeds.append(b)
    # Merge duplicates (twin axes) and nested rects (insets) into the outer rect.
    seeds.sort(key=area, reverse=True)
    kept = []
    for s in seeds:
        nested = False
        for k in kept:
            if area(inter(s, k)) >= 0.85 * area(s):
                nested = True
                break
        if not nested:
            kept.append(s)
    return kept


def attach_colorbars(seeds):
    """Thin seeds (colorbars) adjacent to one plotting area join it; if they span several, they are shared."""
    main, thin = [], []
    for s in seeds:
        w, h = s[2] - s[0], s[3] - s[1]
        (thin if max(w / h, h / w) >= 6 else main).append(s)
    if not main:
        return seeds, [], []
    groups = [[m] for m in main]
    shared = []
    for t in thin:
        vertical = (t[3] - t[1]) > (t[2] - t[0])
        if vertical:
            overl = [i for i, m in enumerate(main) if min(t[3], m[3]) - max(t[1], m[1]) > 0.3 * (m[3] - m[1])]
        else:
            overl = [i for i, m in enumerate(main) if min(t[2], m[2]) - max(t[0], m[0]) > 0.3 * (m[2] - m[0])]
        if not overl:
            groups.append([t])  # isolated thin plot: treat as its own seed
            continue
        near = sorted(overl, key=lambda i: gap(t, main[i]))
        # A colorbar spanning several plotting areas in its direction is shared context.
        if len(overl) >= 2 and (t[3] - t[1] if vertical else t[2] - t[0]) > 1.3 * max(
                (main[i][3] - main[i][1]) if vertical else (main[i][2] - main[i][0]) for i in overl):
            shared.append(t)
        else:
            groups[near[0]].append(t)
    return [g[0] for g in groups], groups, shared


LETTER = __import__('re').compile(r'^\(?([a-zA-Z]|[ivx]{1,4})\)?[.:]?$')


def text_lines(page, scale, origin, W, H):
    """Text segments: PDF lines split wherever consecutive glyphs leave a gap wider than the font
    size (one PDF 'line' can join tick labels of neighbouring panels on the same baseline)."""
    lines = []
    d = page.get_text('rawdict', flags=0)
    for block in d.get('blocks', []):
        for line in block.get('lines', []):
            dx, dy = line.get('dir', (1, 0))
            rotated = abs(dy) > 0.5
            chars = []
            size = 0
            for sp in line.get('spans', []):
                size = max(size, sp.get('size', 0))
                for ch in sp.get('chars', []):
                    if ch.get('c', ' ').strip():
                        chars.append((ch['bbox'], ch['c']))
            if not chars:
                continue
            key = (lambda c: c[0][1] + c[0][3]) if rotated else (lambda c: c[0][0] + c[0][2])
            chars.sort(key=key)
            if rotated and dy < 0:
                chars.reverse()
            segs, cur = [], [chars[0]]
            lim = max(1.0, 0.9 * size)
            for prev, c in zip(chars, chars[1:]):
                if rotated:
                    g = max(c[0][1] - prev[0][3], prev[0][1] - c[0][3])
                else:
                    g = c[0][0] - prev[0][2]
                if g > lim:
                    segs.append(cur); cur = [c]
                else:
                    cur.append(c)
            segs.append(cur)
            for seg in segs:
                x0 = min(c[0][0] for c in seg); y0 = min(c[0][1] for c in seg)
                x1 = max(c[0][2] for c in seg); y1 = max(c[0][3] for c in seg)
                bb = inter(to_px((x0, y0, x1, y1), scale, origin), [0, 0, W, H])
                if bb[2] - bb[0] < 1 or bb[3] - bb[1] < 1:
                    continue
                lines.append({'box': bb, 'text': ''.join(c[1] for c in seg)[:80], 'rotated': rotated, 'kind': 'text'})
    return lines


def components(mask, W, H, exclude=()):
    m = mask.copy()
    for b in exclude:
        x0, y0, x1, y1 = int(max(0, b[0] - 1)), int(max(0, b[1] - 1)), int(min(W, b[2] + 2)), int(min(H, b[3] + 2))
        m[y0:y1, x0:x1] = False
    r = max(1, int(round(0.004 * max(W, H))))
    dil = ndimage.binary_dilation(m, structure=np.ones((2 * r + 1, 2 * r + 1), bool))
    lab, n = ndimage.label(dil)
    objs = ndimage.find_objects(lab)
    comps = []
    for i, sl in enumerate(objs, 1):
        if sl is None:
            continue
        sub = (lab[sl] == i) & m[sl]
        if not sub.any():
            continue
        ys, xs = np.nonzero(sub)
        y0, x0 = sl[0].start, sl[1].start
        comps.append({'box': [float(x0 + xs.min()), float(y0 + ys.min()), float(x0 + xs.max() + 1), float(y0 + ys.max() + 1)],
                      'pixels': int(sub.sum()), 'xs': xs + x0, 'ys': ys + y0, 'kind': 'ink'})
    return comps


def label_figure(pdf_path, long_side=LONG_SIDE):
    doc = pymupdf.open(pdf_path)
    if len(doc) != 1:
        return None, {'reject': 'pages', 'pages': len(doc)}
    page = doc[0]
    if page.rotation:
        return None, {'reject': 'rotated'}
    pr = page.rect
    if pr.width < 20 or pr.height < 20 or max(pr.width / pr.height, pr.height / pr.width) > 8:
        return None, {'reject': 'shape'}
    img, scale = render(page, long_side)
    H, W = img.shape[:2]
    mask = ink_mask(img)
    ink_total = int(mask.sum())
    if ink_total < 200:
        return None, {'reject': 'blank'}
    counts = clip_rects(page)
    raw = seeds_from_clips(counts, pr, scale, W, H)
    info = {'producer': (doc.metadata.get('producer') or '')[:60], 'creator': (doc.metadata.get('creator') or '')[:60],
            'raw_seeds': len(raw), 'W': W, 'H': H, 'scale': scale}
    if not raw:
        return img, {**info, 'reject': 'no_axes'}
    if len(raw) > 16:
        return img, {**info, 'reject': 'too_many_axes'}
    seeds, groups, shared_cb = attach_colorbars(raw)
    if len(groups) > 12:
        return img, {**info, 'reject': 'too_many_panels'}
    origin = (pr.x0, pr.y0)
    lines = text_lines(page, scale, origin, W, H)
    # Text lines count only where they actually render ink (hidden text layers exist).
    lines = [l for l in lines if mask[int(l['box'][1]):int(math.ceil(l['box'][3])), int(l['box'][0]):int(math.ceil(l['box'][2]))].any()]
    comps = components(mask, W, H, [l['box'] for l in lines])
    elements = lines + comps
    cores = []
    for g in groups:
        b = g[0]
        for t in g[1:]:
            b = union(b, t)
        cores.append(b)
    n = len(cores)
    panel_boxes = [list(c) for c in cores]
    shared = [list(s) for s in shared_cb]
    letters = []
    bridges = split_bridges = 0
    for e in elements:
        b = e['box']
        hits = [i for i in range(n) if area(inter(b, cores[i])) > 0]
        i = None
        if len(hits) == 1:
            i = hits[0]
        elif len(hits) > 1:
            big = [j for j in hits if area(inter(b, cores[j])) > 0.02 * area(cores[j])]
            if len(big) <= 1:
                i = max(hits, key=lambda j: area(inter(b, cores[j])))
            elif e['kind'] == 'ink':
                # Touching plotting areas (shared spines/grids): split pixels by nearest core, but only
                # when the connecting ink lies mostly inside the cores (not a diagram connector).
                xs, ys = e['xs'], e['ys']
                inside = np.zeros(len(xs), bool)
                for j in big:
                    c = cores[j]
                    inside |= (xs >= c[0]) & (xs < c[2]) & (ys >= c[1]) & (ys < c[3])
                if inside.mean() >= 0.8:
                    dist = np.stack([np.hypot(np.maximum(0, np.maximum(cores[j][0] - xs, xs - cores[j][2])),
                                              np.maximum(0, np.maximum(cores[j][1] - ys, ys - cores[j][3]))) for j in big])
                    owner = np.array(big)[dist.argmin(0)]
                    for j in big:
                        sel = owner == j
                        if sel.any():
                            panel_boxes[j] = union(panel_boxes[j], [float(xs[sel].min()), float(ys[sel].min()),
                                                                     float(xs[sel].max() + 1), float(ys[sel].max() + 1)])
                    split_bridges += 1
                    continue
                bridges += 1
                continue
            else:
                bridges += 1
                continue
        else:
            d = sorted((gap(b, cores[j]), j) for j in range(n))
            i = d[0][1]
            if n > 1:
                d0, d1 = d[0][0], d[1][0]
                xs_ = [j for j in range(n) if min(b[2], cores[j][2]) - max(b[0], cores[j][0]) > 0.5 * (cores[j][2] - cores[j][0])]
                ys_ = [j for j in range(n) if min(b[3], cores[j][3]) - max(b[1], cores[j][1]) > 0.5 * (cores[j][3] - cores[j][1])]
                spans_cols = len(xs_) >= 2
                spans_rows = len(ys_) >= 2 and (b[3] - b[1]) > 1.2 * max(cores[j][3] - cores[j][1] for j in ys_)
                if e.get('rotated'):
                    # A rotated label between two plotting areas labels the one on its right (y-axis label).
                    right = [j for j in range(n) if cores[j][0] >= b[2] - 1 and min(b[3], cores[j][3]) - max(b[1], cores[j][1]) > 0]
                    if right and not spans_rows:
                        i = min(right, key=lambda j: cores[j][0] - b[2])
                        d0, d1 = 0, 1e9
                if spans_cols or spans_rows:
                    shared.append(list(b))
                    i = None
                elif d1 - d0 < 0.15 * max(1.0, d1) and d0 > 0.02 * max(W, H):
                    shared.append(list(b))
                    i = None
        if e['kind'] == 'text' and LETTER.match(e['text']):
            letters.append({'text': e['text'], 'box': [round(v, 1) for v in b], 'panel': i})
        if i is not None:
            panel_boxes[i] = union(panel_boxes[i], b)
    overlaps = 0
    for a in range(n):
        for c in range(a + 1, n):
            ov = area(inter(panel_boxes[a], panel_boxes[c]))
            if ov > 0.03 * min(area(panel_boxes[a]), area(panel_boxes[c])):
                overlaps += 1
    shared_px = 0
    for s in shared:
        s2 = [int(s[0]), int(s[1]), int(math.ceil(s[2])), int(math.ceil(s[3]))]
        shared_px += int(mask[s2[1]:s2[3], s2[0]:s2[2]].sum())
    info.update({'panels': n, 'bridges': bridges, 'split_bridges': split_bridges, 'overlaps': overlaps, 'shared': len(shared),
                 'shared_ink_fraction': shared_px / ink_total, 'ink': ink_total, 'text_lines': len(lines),
                 'letters': letters, 'min_panel_area_fraction': min(area(b) for b in panel_boxes) / (W * H)})
    if bridges:
        info['reject'] = 'bridge'
    elif overlaps:
        info['reject'] = 'overlap'
    elif info['shared_ink_fraction'] > 0.25:
        info['reject'] = 'shared_heavy'
    info['panel_boxes'] = [[round(v, 1) for v in b] for b in panel_boxes]
    info['cores'] = [[round(v, 1) for v in b] for b in cores]
    info['shared_boxes'] = [[round(v, 1) for v in b] for b in shared]
    return img, info


def job(task):
    pdf, out_png, rec = task
    try:
        img, info = label_figure(pdf)
    except Exception as e:  # malformed author PDFs exist; record and continue
        return {**rec, 'reject': 'error', 'error': repr(e)[:200]}
    if img is None:
        return {**rec, **info}
    if 'reject' not in info and out_png:
        Path(out_png).parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray(img).save(out_png, optimize=False, compress_level=3)
        info['image'] = str(out_png)
        info['sha256'] = hashlib.sha256(Path(out_png).read_bytes()).hexdigest()
    return {**rec, **info}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--figures', type=Path, required=True, help='JSONL rows with paper/includes (corpus_index output)')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--limit', type=int)
    ap.add_argument('--workers', type=int, default=24)
    ap.add_argument('--papers', type=Path, help='Optional allow-list of papers (one per line)')
    args = ap.parse_args()
    allow = set(args.papers.read_text().split()) if args.papers else None
    tasks = []
    for line in args.figures.open():
        f = json.loads(line)
        if allow is not None and f['paper'] not in allow:
            continue
        if f['n_includes'] != 1 or not f['includes'][0]['file'] or not f['includes'][0]['file'].lower().endswith('.pdf'):
            continue
        pdf = args.corpus / f['paper'] / 'build' / 'src' / f['includes'][0]['file']
        fid = f"{f['paper']}-{f['index']:03d}"
        rec = {'id': fid, 'paper': f['paper'], 'figure_index': f['index'], 'file': f['includes'][0]['file'],
               'caption_letters': f['caption_letters'], 'caption_spatial': f['caption_spatial'], 'caption': f['caption'][:600]}
        tasks.append((str(pdf), str(args.out / 'images' / f['paper'] / f'{fid}.png'), rec))
        if args.limit and len(tasks) >= args.limit:
            break
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    with mp.Pool(args.workers, maxtasksperchild=200) as pool, (args.out / 'labels.jsonl').open('w') as fo:
        for r in pool.imap_unordered(job, tasks, chunksize=4):
            r['version'] = VERSION
            fo.write(json.dumps(r) + '\n')
            n += 1
            if n % 2000 == 0:
                print(n, flush=True)
    print('done', n)


if __name__ == '__main__':
    main()
