#!/usr/bin/env python3
"""Letter-grouped vector labels: panels at the granularity of the figure's printed letters.

When a figure PDF has more plotting areas than its caption names parts (e.g. "(a)" labels a row of three
plots), the parts are groups of plotting areas. The PDF text layer gives each printed letter's exact box.
Every plotting area is assigned to one letter:

* *top* layout (letters at the upper-left of their part): the nearest letter that lies above or level with
  the area's top edge and not to its right;
* *bottom* layout (subcaption letters under their part): the nearest letter below the area whose horizontal
  extent overlaps it.

The layout is the majority over letters. A grouping is accepted only if the printed letters are exactly
a, b, c... matching the caption's count, every letter receives at least one area, group boxes do not overlap,
and each group box (with its letter) contains no other group's area. Training split only.
"""
import argparse, json, re
from pathlib import Path

from sfd.core import policy as P

LETTER = re.compile(r'^\(?([a-l])\)?[.:]?$')
WORD = re.compile(r'^\(([a-lA-L])\)|^([a-lA-L])\)$')


def pdf_letters(pdf, W):
    """Printed panel letters from the PDF text layer: '(a)', '(a)Title', 'a)' words; bold single letters."""
    import pymupdf
    doc = pymupdf.open(pdf)
    page = doc[0]
    r = page.rect
    s = W / r.width
    out = []
    for w in page.get_text('words'):
        m = WORD.match(w[4].strip())
        if m:
            c = (m.group(1) or m.group(2)).lower()
            # Box of the letter token itself (approximate: first 3 characters of the word).
            n = max(1, len(w[4]))
            x1 = w[0] + (w[2] - w[0]) * min(1.0, 3.0 / n)
            out.append((c, [(w[0] - r.x0) * s, (w[1] - r.y0) * s, (x1 - r.x0) * s, (w[3] - r.y0) * s]))
    if not out:
        for b in page.get_text('dict').get('blocks', []):
            for l in b.get('lines', []):
                for sp in l.get('spans', []):
                    t = sp.get('text', '').strip()
                    if len(t) == 1 and t.isalpha() and (sp.get('flags', 0) & 16) and t.lower() <= 'l':
                        bb = sp['bbox']
                        out.append((t.lower(), [(bb[0] - r.x0) * s, (bb[1] - r.y0) * s, (bb[2] - r.x0) * s, (bb[3] - r.y0) * s]))
    return out


group_by_letters = P.group_by_letters


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vector', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--corpus', type=Path, default=Path('/home/ben/mathpix/data/arxiv'))
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    stats, rows = {}, []

    def bump(k):
        stats[k] = stats.get(k, 0) + 1
    for line in args.vector.open():
        r = json.loads(line)
        if r.get('reject') or split.get(r['paper']) != 'train':
            continue
        L = len(r.get('caption_letters') or [])
        if L < 2 or r['panels'] <= L:
            continue
        pdf = args.corpus / r['paper'] / 'build' / 'src' / r['file']
        try:
            toks = pdf_letters(str(pdf), r['W'])
        except Exception:
            bump('pdf_error'); continue
        chars = sorted(c for c, _ in toks)
        if chars != [chr(97 + k) for k in range(L)]:
            bump('letters_not_a_to_L'); continue
        toks.sort(key=lambda t: t[0])
        res, why = group_by_letters(r['cores'], r['panel_boxes'], toks)
        bump(why)
        if res is None:
            continue
        groups, mode = res
        shared = [b for b in r['shared_boxes'] if not any(P.area(P.inter(b, g)) > 0.5 * P.area(b) for g in groups)]
        rows.append({'id': r['id'], 'image': r['image'], 'width': r['W'], 'height': r['H'], 'paper': r['paper'],
                     'source': 'vector-letter-groups', 'letter_mode': mode, 'areas': r['panels'],
                     'boxes': [{'box': g, 'class': 0} for g in groups] + [{'box': b, 'class': 1} for b in shared]})
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(''.join(json.dumps(x) + '\n' for x in rows))
    print(json.dumps({**stats, 'rows': len(rows)}))


if __name__ == '__main__':
    main()
