#!/usr/bin/env python3
"""Score native crop cleanup against frozen, source-reviewed line bands.

Usage: score_formula_crops.py GOLD_BANDS_JSON CROP_JOBS_JSON OUTDIR
Requires Pillow/numpy. Gold rows identify (paper,id), own_y_pixels in absolute
216 dpi page coordinates and neighbor_line_intrusion. This is a known-case
regression, not recognition accuracy. Review source bands before candidate pixels.
"""
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def rgb(path):
    return np.asarray(Image.open(path).convert('RGB'))


def align(image, rect, raw):
    """Place a trimmed/padded image back on the original request pixel grid."""
    h, w = raw.shape[:2]
    x0, y0, x1, y1 = rect
    assert image.shape[:2] == (y1 - y0, x1 - x0)
    result = np.full_like(raw, 255)
    ax, ay, bx, by = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
    assert bx > ax and by > ay
    result[ay:by, ax:bx] = image[ay-y0:by-y0, ax-x0:bx-x0]
    return result


def main():
    gold_path, jobs_path, out_path = map(Path, sys.argv[1:])
    gold, jobs = json.loads(gold_path.read_text()), json.loads(jobs_path.read_text())
    by_key = {(j['paper'], j['equation']): j for j in jobs}
    assert len(by_key) == len(jobs) == len(gold['rows'])
    out_path.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'scope': gold['scope'], 'gold_sha256': hashlib.sha256(gold_path.read_bytes()).hexdigest(),
              'jobs_sha256': hashlib.sha256(jobs_path.read_bytes()).hexdigest(),
              'metric': 'Other-line dark pixels <100 outside frozen source line; resolved means zero. Additional own-ink loss uses <192 and counts only ink retained by the baseline. Exact RGB changes also reported.',
              'rows': []}
    report_path = out_path / 'score.json'
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    cards = []
    for g in gold['rows']:
        j = by_key[(g['paper'], g['id'])]
        directory = Path(j['out'])
        geometry = json.loads((directory/'geometry.json').read_text())
        assert geometry['id'] == j['id']
        assert geometry['rect'] == j['rect']
        for name, digest in [('asset', 'baseline_asset_sha256'), ('source_image', 'source_image_sha256')]:
            assert hashlib.sha256(Path(g[name]).read_bytes()).hexdigest() == g[digest], f'frozen {name} changed'
        raw, before_png, after_png = [rgb(directory/(name+'.png')) for name in ('raw', 'before', 'after')]
        before, after = align(before_png, geometry['before'], raw), align(after_png, geometry['after'], raw)
        ys = np.arange(raw.shape[0]) + j['rect'][1]
        own = np.broadcast_to(((ys >= g['own_y_pixels'][0]) & (ys < g['own_y_pixels'][1]))[:, None], raw.shape[:2])
        b, a = before.min(axis=2), after.min(axis=2)
        retained = own & (b < 192)
        row = {'index': g['index'], 'paper': g['paper'], 'equation': g['id'], 'hint': 'content' in j,
               'labeled_intrusion': g['neighbor_line_intrusion'],
               'before_foreign_pixels': int(((b < 100) & ~own).sum()),
               'after_foreign_pixels': int(((a < 100) & ~own).sum()),
               'own_pixels_retained_before': int(retained.sum()),
               'additional_own_pixels_lost': int((retained & (a >= 192)).sum()),
               'own_rgb_pixels_changed': int((retained & np.any(before != after, axis=2)).sum()),
               'original_baseline_pixels_equal': bool(np.array_equal(before_png, rgb(g['asset'])))}
        report['rows'].append(row)
        source = Image.open(g['source_image']).convert('RGB')
        card = Image.new('RGB', (1100, max(130, source.height+35, before_png.shape[0]+35, after_png.shape[0]+35)), '#eeeeee')
        d = ImageDraw.Draw(card)
        d.text((5, 3), f"{g['index']:02d} {g['paper']} p{g['page']+1} foreign {row['before_foreign_pixels']}->{row['after_foreign_pixels']}; own loss {row['additional_own_pixels_lost']}", fill='black')
        card.paste(source, (5, 25)); card.paste(Image.fromarray(before_png), (450, 25)); card.paste(Image.fromarray(after_png), (780, 25))
        cards.append(card)
    rows = report['rows']; labeled = [r for r in rows if r['labeled_intrusion']]
    # Keep every frozen label visible, but never count a pixel-clean baseline as a fixed failure.
    # A source/baseline-only recheck can adjudicate this discrepancy; candidate success cannot create its denominator.
    positives = [r for r in labeled if r['before_foreign_pixels'] > 0]
    report['baseline_label_disagreements'] = [r['index'] for r in labeled if not r['before_foreign_pixels']]
    report['totals'] = {'crops': len(rows), 'hints': sum(r['hint'] for r in rows),
        'frozen_intrusion_labels': len(labeled), 'confirmed_intrusions_before': len(positives), 'confirmed_intrusions_remaining': sum(r['after_foreign_pixels'] > 0 for r in positives),
        'foreign_pixels_before': sum(r['before_foreign_pixels'] for r in rows), 'foreign_pixels_after': sum(r['after_foreign_pixels'] for r in rows),
        'additional_own_pixels_lost': sum(r['additional_own_pixels_lost'] for r in rows),
        'own_rgb_pixels_changed': sum(r['own_rgb_pixels_changed'] for r in rows),
        'original_baseline_equal': sum(r['original_baseline_pixels_equal'] for r in rows)}
    t = report['totals']
    report['passed'] = (bool(positives) and t['confirmed_intrusions_remaining'] <= len(positives)/2 and t['additional_own_pixels_lost'] == 0
        and t['own_rgb_pixels_changed'] == 0 and t['original_baseline_equal'] == len(rows)
        and all(r['after_foreign_pixels'] <= r['before_foreign_pixels'] for r in rows))
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    for start in range(0, len(cards), 10):
        group = cards[start:start+10]
        sheet = Image.new('RGB', (1100, sum(c.height for c in group)), '#eeeeee'); y = 0
        for c in group: sheet.paste(c, (0, y)); y += c.height
        sheet.save(out_path/f"comparison-{start//10:02d}.png")
    print(json.dumps({'passed': report['passed'], **t}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
