#!/usr/bin/env python3
"""LaTeX sub-figure supervision from the compiled papers (training split only, read-only corpus).

Many arXiv figures are laid out by LaTeX (`subfigure`, `subfloat`, minipages) as several images with
printed subcaptions "(a) ...", "(b) ...". On the original arXiv PDF page these give real compound layouts
(framed diagrams, photo grids, plots) whose panel identity is printed in the text layer. For each page:

1. find each main caption line ("Figure N:" / "Fig. N."); the figure region is the area above it up to the
   last body-text line (wide, long text) or the top margin, restricted to one column when every subcaption
   lies in one column;
2. find subcaption lines inside the region whose text starts with a panel letter, letters consecutive from
   (a); group them into rows by baseline;
3. each subcaption owns a cell: horizontally between the midpoints to its row neighbours, vertically from
   the previous row's subcaptions down to its own baseline. Cell boundaries must cross (almost) no ink, the
   cell must hold a graphic taller than two subcaption lines above the subcaption, and there must be no
   graphic ink between a subcaption and the next row (letters printed above graphics are rejected);
4. the panel box is the ink inside the cell (graphic + its subcaption); ink outside every panel is shared.

The region is rendered at the same scale as the figure files (long side <= 1,280 px). Ambiguity is
rejected. Output rows are in train2.py format.
"""
import argparse, hashlib, json, multiprocessing as mp, re
from pathlib import Path

import numpy as np
import pymupdf
from PIL import Image
from scipy import ndimage

CAPTION = re.compile(r'^\s*(Figure|Fig\.)\s*\d+\s*[:.|]')
SUBCAP = re.compile(r'^\s*\(?([a-l])\)\s*\S?')
VERSION = 'subfig-pages-v2'


def lines_of(page):
    out = []
    for b in page.get_text('dict', flags=0).get('blocks', []):
        for l in b.get('lines', []):
            t = ''.join(s.get('text', '') for s in l.get('spans', [])).strip()
            if t:
                size = max(s.get('size', 0) for s in l['spans'])
                out.append({'text': t, 'bbox': list(l['bbox']), 'size': size, 'dir': l.get('dir', (1, 0))})
    return out


def label_page(pdf_path, pno, max_side=1280):
    doc = pymupdf.open(pdf_path)
    page = doc[pno]
    W, H = page.rect.width, page.rect.height
    lines = lines_of(page)
    results = []
    caps = [l for l in lines if CAPTION.match(l['text']) and abs(l['dir'][1]) < .5]
    # Body font size: the size carrying most characters on the page.
    sizes = {}
    for l in lines:
        sizes[round(l['size'])] = sizes.get(round(l['size']), 0) + len(l['text'])
    body_size = max(sizes, key=sizes.get) if sizes else 10
    # Running headers/footers: short lines in the top/bottom 7% of the page.
    header_bottom = max([l['bbox'][3] for l in lines if l['bbox'][3] < 0.075 * H and len(l['text']) < 80], default=0.04 * H)
    for cap in caps:
        ctop = cap['bbox'][1]
        above = [l for l in lines if l['bbox'][3] <= ctop + 1 and abs(l['dir'][1]) < .5]
        body = [l for l in above if (l['bbox'][2] - l['bbox'][0]) > 0.4 * W and len(l['text']) >= 50 and not SUBCAP.match(l['text'])]
        # Paragraph tails: body-size lines directly under a wide body line.
        changed = True
        while changed:
            changed = False
            for l in above:
                if l in body or SUBCAP.match(l['text']) or abs(l['size'] - body_size) > 0.6:
                    continue
                if any(0 <= l['bbox'][1] - b['bbox'][3] < 1.2 * l['size'] and abs(l['bbox'][0] - b['bbox'][0]) < 3 for b in body):
                    body.append(l); changed = True
        top = max([l['bbox'][3] for l in body] + [header_bottom])
        subs = [l for l in above if l['bbox'][1] >= top and SUBCAP.match(l['text'])]
        if len(subs) < 2:
            continue
        letters = [SUBCAP.match(l['text']).group(1) for l in subs]
        if sorted(letters) != [chr(97 + k) for k in range(len(letters))]:
            continue
        # Column restriction.
        if all(l['bbox'][2] <= W / 2 + 5 for l in subs):
            x0r, x1r = 0.0, W / 2
        elif all(l['bbox'][0] >= W / 2 - 5 for l in subs):
            x0r, x1r = W / 2, W
        else:
            x0r, x1r = 0.0, W
        # Rows by baseline.
        subs.sort(key=lambda l: (l['bbox'][3], l['bbox'][0]))
        rows = []
        for l in subs:
            if rows and abs(rows[-1][0]['bbox'][3] - l['bbox'][3]) < 0.6 * max(l['size'], 6):
                rows[-1].append(l)
            else:
                rows.append([l])
        # Tables (many body-size text lines between the region top and the subcaptions) are not figures.
        inner = [l for l in above if l['bbox'][1] >= top and not SUBCAP.match(l['text']) and abs(l['size'] - body_size) <= 0.6
                 and x0r <= l['bbox'][0] and l['bbox'][2] <= x1r]
        if len(inner) > 6:
            continue
        region = [x0r, top, x1r, ctop]
        scale = min(4.0, max_side / max(region[2] - region[0], region[3] - region[1]))
        clip = pymupdf.Rect(*region)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), clip=clip, alpha=False, colorspace=pymupdf.csRGB)
        img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)[:, :, :3].copy()
        mask = img.min(axis=2) < 235
        h, w = mask.shape
        # A one-column region whose ink touches the column edge is really a wider figure: reject.
        if (x0r > 0 and mask[:, :3].any(1).mean() > 0.02) or (x1r < W and mask[:, -3:].any(1).mean() > 0.02):
            continue
        to_px = lambda x, y: ((x - region[0]) * scale, (y - region[1]) * scale)
        panels, ok = [], True
        prev_bottom = 0.0
        for row in rows:
            row.sort(key=lambda l: l['bbox'][0])
            centers = [(l['bbox'][0] + l['bbox'][2]) / 2 for l in row]
            bounds = [x0r] + [(centers[k] + centers[k + 1]) / 2 for k in range(len(row) - 1)] + [x1r]
            row_bottom = max(l['bbox'][3] for l in row)
            yb = to_px(0, row_bottom + 1)[1]
            yt = prev_bottom
            line_h = max(l['bbox'][3] - l['bbox'][1] for l in row) * scale
            for k, l in enumerate(row):
                cx0 = to_px(bounds[k], 0)[0]; cx1 = to_px(bounds[k + 1], 0)[0]
                xa, xb, ya, yb_ = int(max(0, cx0)), int(min(w, cx1)), int(max(0, yt)), int(min(h, yb))
                if xb - xa < 10 or yb_ - ya < 10:
                    ok = False; break
                cell = mask[ya:yb_, xa:xb]
                ys, xs = np.nonzero(cell)
                if len(xs) == 0:
                    ok = False; break
                sub_top = to_px(0, l['bbox'][1])[1] - ya
                graphic = cell[:max(0, int(sub_top) - 1)]
                if graphic.sum() == 0 or (np.nonzero(graphic.any(1))[0].ptp() if graphic.any() else 0) < 2 * line_h:
                    ok = False; break
                panels.append([float(xa + xs.min()), float(ya + ys.min()), float(xa + xs.max() + 1), float(ya + ys.max() + 1)])
            if not ok:
                break
            # Boundaries between cells must be (almost) ink-free over the row band.
            for b in bounds[1:-1]:
                bx = int(to_px(b, 0)[0])
                band = mask[int(yt):int(yb), max(0, bx - 1):min(w, bx + 2)]
                if band.size and band.any(1).mean() > 0.03:
                    ok = False; break
            if not ok:
                break
            prev_bottom = yb
        if not ok or len(panels) != len(subs):
            continue
        # Ink below the last row (between subcaptions and the caption) must be negligible.
        tail = mask[int(prev_bottom):, :]
        if tail.size and tail.sum() > 0.01 * mask.sum():
            continue
        for a in range(len(panels)):
            for b in range(a + 1, len(panels)):
                A, B = panels[a], panels[b]
                if max(0, min(A[2], B[2]) - max(A[0], B[0])) * max(0, min(A[3], B[3]) - max(A[1], B[1])) > 0:
                    ok = False
        if not ok:
            continue
        # Shared context: ink components outside every panel.
        lab, n = ndimage.label(ndimage.binary_dilation(mask, iterations=2))
        shared = []
        for i, sl in enumerate(ndimage.find_objects(lab), 1):
            if sl is None:
                continue
            bb = [sl[1].start, sl[0].start, sl[1].stop, sl[0].stop]
            if not any(bb[0] >= p[0] - 3 and bb[1] >= p[1] - 3 and bb[2] <= p[2] + 3 and bb[3] <= p[3] + 3 for p in panels):
                sub = (lab[sl] == i) & mask[sl]
                if sub.sum() > 20:
                    ys, xs = np.nonzero(sub)
                    shared.append([float(sl[1].start + xs.min()), float(sl[0].start + ys.min()), float(sl[1].start + xs.max() + 1), float(sl[0].start + ys.max() + 1)])
        # Crop the image to the union of panels and shared ink.
        allb = panels + shared
        X0 = max(0, int(min(b[0] for b in allb)) - 6); Y0 = max(0, int(min(b[1] for b in allb)) - 6)
        X1 = min(w, int(max(b[2] for b in allb)) + 6); Y1 = min(h, int(max(b[3] for b in allb)) + 6)
        crop = img[Y0:Y1, X0:X1]
        sh = lambda b: [b[0] - X0, b[1] - Y0, b[2] - X0, b[3] - Y0]
        results.append({'image_array': crop, 'panels': [sh(p) for p in panels], 'shared': [sh(s) for s in shared],
                        'caption': cap['text'][:120], 'letters': len(subs), 'rows': len(rows), 'page': pno})
    return results


def job(task):
    paper, pdf, out_dir = task
    rows, stats = [], {}
    try:
        doc = pymupdf.open(pdf)
        pages = len(doc)
    except Exception:
        return rows, {'pdf_error': 1}
    for pno in range(min(pages, 40)):
        try:
            res = label_page(pdf, pno)
        except Exception:
            stats['page_error'] = stats.get('page_error', 0) + 1
            continue
        for k, r in enumerate(res):
            img = r.pop('image_array')
            if img.shape[0] < 64 or img.shape[1] < 64:
                continue
            fid = f'{paper}-p{pno:02d}-{k}'
            p = Path(out_dir) / 'images' / paper / f'{fid}.png'
            p.parent.mkdir(parents=True, exist_ok=True)
            Image.fromarray(img).save(p, compress_level=3)
            rows.append({'id': fid, 'image': str(p), 'width': int(img.shape[1]), 'height': int(img.shape[0]), 'paper': paper,
                         'source': 'subfig-pages', 'boxes': [{'box': b, 'class': 0} for b in r['panels']] +
                         [{'box': b, 'class': 1} for b in r['shared']], 'caption': r['caption'], 'rows': r['rows']})
    return rows, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--figures', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=24)
    ap.add_argument('--limit', type=int)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    papers = set()
    for l in args.figures.open():
        f = json.loads(l)
        if split.get(f['paper']) == 'train' and f['n_includes'] >= 2 and (f['sub_macros'] or f['minipage']):
            papers.add(f['paper'])
    papers = sorted(papers)[:args.limit] if args.limit else sorted(papers)
    tasks = [(p, str(args.corpus / p / 'arxiv.pdf'), str(args.out)) for p in papers if (args.corpus / p / 'arxiv.pdf').exists()]
    args.out.mkdir(parents=True, exist_ok=True)
    total, agg = 0, {}
    with mp.Pool(args.workers, maxtasksperchild=50) as pool, (args.out / 'rows.jsonl').open('w') as fo:
        for rows, st in pool.imap_unordered(job, tasks, chunksize=2):
            for r in rows:
                fo.write(json.dumps(r) + '\n'); total += 1
            for k, v in st.items():
                agg[k] = agg.get(k, 0) + v
    print(json.dumps({'papers': len(tasks), 'figures': total, **agg}))


if __name__ == '__main__':
    main()
