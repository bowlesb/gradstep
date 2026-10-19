#!/usr/bin/env python3
"""Render review candidates from a verified LOCAL copy of the research corpus.

Run on the Mac. Never processes PDFs on the training host. Silver layout boxes
refer to build/plain.pdf, not the original arxiv.pdf. Output is a review queue,
not admitted panel ground truth. Does not execute or import the source project.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform

import fitz
from PIL import Image, ImageDraw, ImageFont


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sample', type=Path, required=True)
    p.add_argument('--copy', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--dpi', type=int, default=144)
    args = p.parse_args()
    if platform.system() != 'Darwin':
        raise ValueError('PDF preparation is Mac-only')
    if not 100 <= args.dpi <= 240:
        raise ValueError('Bounded review resolution required')
    source, out = args.copy.resolve(), args.out.resolve()
    if out == source or out.is_relative_to(source) or source.is_relative_to(out):
        raise ValueError('Output must be separate from the read-only source copy')
    if out.exists():
        raise ValueError('Review revision already exists')
    manifest = json.loads(args.sample.read_text())
    for paper in manifest['papers']:
        if paper['split'] not in ('train', 'validation'):
            raise ValueError('Do not inspect reserved test papers')
        for entry in paper['files']:
            path = source / entry['path']
            if path.is_symlink() or not path.resolve().is_relative_to(source):
                raise ValueError('External source path')
            if path.stat().st_size != entry['bytes'] or sha(path) != entry['sha256']:
                raise ValueError(f'Copy verification failed: {entry["path"]}')
    out.mkdir(parents=True)
    records, rejected = [], []
    font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 13)
    for paper in manifest['papers']:
        directory = source / 'data/arxiv' / paper['id']
        labels_path = directory / 'build/labels.json'
        labels = json.loads(labels_path.read_text())
        layout = json.loads((directory / 'build/layout-check.json').read_text())
        if layout.get('identical') is not True:
            raise ValueError('Paired PDF layout not verified')
        document = fitz.open(directory / 'build/plain.pdf')
        if len(document) != len(labels['pages']):
            raise ValueError('Page count mismatch')
        blocks = {b['id']: b for b in labels['blocks']}
        figures = labels['figures']
        paper_records = []
        last_page, rendered = None, None
        for figure in sorted(figures, key=lambda f: (f['boxes'][0]['page'] if f.get('boxes') else -1, f['id'])):
            identifier = paper['id'] + '-' + figure['id']
            boxes = figure.get('boxes', [])
            if not figure.get('matched') or len(boxes) != 1:
                rejected.append({'id': identifier, 'reason': 'unmatched_or_multiple_page_boxes'})
                continue
            box = boxes[0]
            page_number = box['page']
            page = document[page_number]
            spec = labels['pages'][page_number]
            if page.rotation or abs(page.rect.width-spec['width']) > .05 or abs(page.rect.height-spec['height']) > .05:
                raise ValueError('Unsupported page geometry')
            coords = [box['x0'], box['top'], box['x1'], box['bottom']]
            if not all(math.isfinite(c) for c in coords) or not (0 <= coords[0] < coords[2] <= page.rect.width+.01 and 0 <= coords[1] < coords[3] <= page.rect.height+.01):
                rejected.append({'id': identifier, 'reason': 'invalid_candidate_bounds'})
                continue
            if last_page != page_number:
                pix = page.get_pixmap(matrix=fitz.Matrix(args.dpi/72, args.dpi/72), alpha=False, colorspace=fitz.csRGB)
                rendered = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
                last_page = page_number
            scale = args.dpi/72
            # Exact outward rounding on the page raster; retain a 2pt review margin.
            crop = [max(0, math.floor((coords[0]-2)*scale)), max(0, math.floor((coords[1]-2)*scale)),
                    min(rendered.width, math.ceil((coords[2]+2)*scale)), min(rendered.height, math.ceil((coords[3]+2)*scale))]
            image = rendered.crop(crop)
            filename = identifier + '.png'
            image.save(out / filename)
            html_id = figure.get('html_id') or ''
            parents = [f['id'] for f in figures if f.get('html_id') and html_id.startswith(f['html_id']+'.')]
            children = [f['id'] for f in figures if html_id and (f.get('html_id') or '').startswith(html_id+'.')]
            caption = blocks.get(figure.get('caption_block_id'), {})
            record = {
                'id': identifier, 'paper': paper['family'], 'revision': paper['id'], 'split': paper['split'],
                'domain': paper['category'], 'title': paper['title'], 'license': paper['license'],
                'source_url': 'https://arxiv.org/abs/' + paper['id'],
                'source_pdf': 'data/arxiv/' + paper['id'] + '/build/plain.pdf',
                'source_pdf_sha256': next(f['sha256'] for f in paper['files'] if f['path'].endswith('/build/plain.pdf')),
                'source_labels_sha256': sha(labels_path), 'source_figure': figure,
                'page_zero_based': page_number, 'page_points': [page.rect.width, page.rect.height],
                'dpi': args.dpi, 'page_pixel_crop': crop, 'image': filename,
                'width': image.width, 'height': image.height, 'sha256': sha(out / filename),
                'html_id': html_id, 'ancestor_candidates': parents, 'descendant_candidates': children,
                'caption': caption.get('text', ''), 'caption_boxes': caption.get('boxes', []),
                'review': 'unreviewed automatic whole-figure candidate; NOT training truth',
            }
            records.append(record)
            if not parents:
                paper_records.append(record)
        document.close()
        # Root candidates only; nested automatic figures remain in the JSON for review.
        for offset in range(0, len(paper_records), 9):
            batch = paper_records[offset:offset+9]
            sheet = Image.new('RGB', (1200, math.ceil(len(batch)/3)*340), 'white')
            draw = ImageDraw.Draw(sheet)
            for i, row in enumerate(batch):
                x, y = (i % 3)*400, (i // 3)*340
                draw.text((x+8, y+4), row['id'], font=font, fill='black')
                draw.text((x+8, y+21), f"p{row['page_zero_based']+1} {row['split']} {row['width']}x{row['height']}", font=font, fill='black')
                thumb = Image.open(out / row['image']).convert('RGB')
                thumb.thumbnail((384, 285))
                sheet.paste(thumb, (x+8, y+46))
                draw.rectangle((x, y, x+399, y+339), outline='#bbb')
            sheet.save(out / f"sheet-{paper['id']}-{offset//9}.jpg", quality=92)
    result = {'sample_sha256': sha(args.sample), 'script_sha256': sha(__file__), 'pdf_processing': 'local Mac only',
              'renderer': 'PyMuPDF '+fitz.VersionBind, 'dpi': args.dpi,
              'status': 'Review candidates only; no subfigure training labels admitted',
              'records': records, 'rejections': rejected}
    (out / 'candidates.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'candidates': len(records), 'roots': sum(not r['ancestor_candidates'] for r in records),
                      'rejected': len(rejected), 'out': str(out)}))


if __name__ == '__main__':
    main()
