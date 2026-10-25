# Ruling lines per page (pdfplumber): thin filled rectangles and stroked straight lines, in points from the page's
# top left (the text layer's coordinates). Output: <out>/<key>.json = [[ [x0, top, x1, bottom], ... ] per page].
import json, sys, os
import pdfplumber

corpus, ids, out = sys.argv[1], sys.argv[2].split(','), sys.argv[3]
os.makedirs(out, exist_ok=True)
THIN = 2.0
for key in ids:
    dest = os.path.join(out, key + '.json')
    if os.path.exists(dest):
        continue
    pages = []
    try:
        with pdfplumber.open(os.path.join(corpus, key, 'paper.pdf')) as pdf:
            for page in pdf.pages:
                segs = []
                try:
                    objs = list(page.rects) + list(page.lines)
                except Exception:
                    objs = []
                for o in objs:
                    x0, x1, top, bottom = float(o['x0']), float(o['x1']), float(o['top']), float(o['bottom'])
                    w, h = x1 - x0, bottom - top
                    if o.get('object_type') == 'rect':
                        if not (o.get('fill') or o.get('stroke')):
                            continue
                        if h <= THIN and w >= 5:
                            segs.append([round(x0, 2), round(top, 2), round(x1, 2), round(bottom, 2)])
                        elif w <= THIN and h >= 5:
                            segs.append([round(x0, 2), round(top, 2), round(x1, 2), round(bottom, 2)])
                        elif o.get('stroke') and not o.get('fill') and w >= 5 and h >= 5 and len(segs) < 4000:
                            # a stroked box: its four edges
                            lw = float(o.get('linewidth') or 0.4)
                            segs += [[x0, top, x1, top + lw], [x0, bottom - lw, x1, bottom], [x0, top, x0 + lw, bottom], [x1 - lw, top, x1, bottom]]
                    else:
                        lw = float(o.get('linewidth') or 0.4)
                        if h <= THIN and w >= 5:
                            segs.append([round(x0, 2), round(top - lw / 2, 2), round(x1, 2), round(bottom + lw / 2, 2)])
                        elif w <= THIN and h >= 5:
                            segs.append([round(x0 - lw / 2, 2), round(top, 2), round(x1 + lw / 2, 2), round(bottom, 2)])
                pages.append(segs[:4000])
                page.flush_cache()
    except Exception as e:
        print(key, 'failed', e, file=sys.stderr)
        continue
    with open(dest, 'w') as f:
        json.dump(pages, f)
    print(key, len(pages), sum(len(p) for p in pages), flush=True)
