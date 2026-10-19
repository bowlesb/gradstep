#!/usr/bin/env python3
"""Mac-only recovery of review candidates from HTML/source/PDF identity.

Archives are read as data, never extracted or executed. Every image must match
the full decoded RGB SHA-256 of an embedded PDF image. Explicit HTML groups do
not prove semantic panels: all output stays a review queue until annotated.
"""
import argparse
import collections
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import platform
import re
import tarfile

from PIL import Image, ImageDraw, ImageFont
from source_html import Figures

Image.MAX_IMAGE_PIXELS = 32_000_000


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def union(boxes):
    return [min(b[0] for b in boxes), min(b[1] for b in boxes),
            max(b[2] for b in boxes), max(b[3] for b in boxes)]


def pad(box, amount):
    return [box[0]-amount, box[1]-amount, box[2]+amount, box[3]+amount]


def archive_assets(path, wanted):
    """Bound decompression, reject links/unsafe paths; unique suffix identity only."""
    found = collections.defaultdict(list)
    total = 0
    with tarfile.open(path, mode='r|*') as archive:
        for i, entry in enumerate(archive):
            total += entry.size
            if i >= 5000 or total > 256*1024**2 or entry.size > 64*1024**2:
                raise ValueError('Archive resource bound')
            parts = PurePosixPath(entry.name).parts
            if not entry.isfile() or not parts or '..' in parts or entry.name.startswith('/') or '\\' in entry.name:
                continue
            normalized = str(PurePosixPath(*parts))
            targets = [w for w in wanted if normalized == w or normalized.endswith('/'+w)]
            if not targets:
                continue
            raw = archive.extractfile(entry).read(16*1024**2+1)
            if len(raw) > 16*1024**2:
                raise ValueError('Image byte bound')
            try:
                im = Image.open(io.BytesIO(raw))
                if im.width*im.height > Image.MAX_IMAGE_PIXELS:
                    raise ValueError('Image pixel bound')
                if 'A' in im.getbands() or 'transparency' in im.info:
                    if im.convert('RGBA').getchannel('A').getextrema() != (255, 255):
                        continue  # PDF mask/compositing needs separate verification.
                im = im.convert('RGB')
                record = {'member': entry.name, 'bytes': len(raw),
                          'sha256': hashlib.sha256(raw).hexdigest(),
                          'rgb_sha256': hashlib.sha256(im.tobytes()).hexdigest(),
                          'width': im.width, 'height': im.height}
                for target in targets:
                    found[target].append(record)
            except (OSError, Image.DecompressionBombError):
                continue
    return {name: values[0] for name, values in found.items() if len(values) == 1}


def occurrences(document, assets):
    dimensions = {(a['width'], a['height']) for a in assets.values()}
    by_rgb = collections.defaultdict(list)
    decoded, visited = {}, 0
    for page_number, page in enumerate(document):
        if page.rotation or page.rect.x0 or page.rect.y0:
            continue
        for item in page.get_image_info(xrefs=True):
            visited += 1
            if visited > 2000:
                raise ValueError('PDF image occurrence bound')
            if (item['width'], item['height']) not in dimensions or not item['xref']:
                continue
            xref = item['xref']
            if xref not in decoded:
                raw = document.extract_image(xref)['image']
                im = Image.open(io.BytesIO(raw)).convert('RGB')
                decoded[xref] = hashlib.sha256(im.tobytes()).hexdigest()
            matrix = item['transform']
            # Mirrored/rotated images require their own reviewed transform.
            if abs(matrix[1]) > .01 or abs(matrix[2]) > .01 or matrix[0] <= 0 or matrix[3] <= 0:
                continue
            by_rgb[decoded[xref]].append({'page_zero_based': page_number, 'xref': xref,
                                          'box_points': list(item['bbox']),
                                          'transform': list(matrix)})
    return by_rgb


def select_group(assets, by_rgb):
    choices = [by_rgb.get(a['rgb_sha256'], []) for a in assets]
    if not all(choices):
        raise ValueError('Source RGB not found in PDF')
    pages = set(c['page_zero_based'] for c in choices[0])
    for group in choices[1:]:
        pages &= {c['page_zero_based'] for c in group}
    valid = []
    for page in sorted(pages):
        on_page = [[c for c in group if c['page_zero_based'] == page] for group in choices]
        if all(len(c) == 1 for c in on_page):
            valid.append([c[0] for c in on_page])
    if len(valid) != 1:
        raise ValueError('Missing or ambiguous common-page image identity')
    selected = valid[0]
    for i, a in enumerate(selected):
        for b in selected[:i]:
            x, y = a['box_points'], b['box_points']
            area = max(0, min(x[2], y[2])-max(x[0], y[0]))*max(0, min(x[3], y[3])-max(x[1], y[1]))
            smaller = min((x[2]-x[0])*(x[3]-x[1]), (y[2]-y[0])*(y[3]-y[1]))
            if area > .02*smaller:
                raise ValueError('Overlapping asset instances')
    return selected


def subcaption_bounds(caption, image_box, all_image_boxes, page, raster, scale):
    """Include complete printed subcaptions, not just the leading panel letter.

    This is still a review candidate. Text identity, column bounds, following image
    and figure-caption fences constrain the search; all recovered lines are saved.
    """
    if not caption.strip():
        return None, 'No HTML subcaption; inspect all external text'
    expected = re.sub(r'[^a-z0-9]', '', caption.lower())
    bottom = image_box[3]
    stop = min(page.rect.height, bottom+105)
    for other in all_image_boxes:
        overlap = min(image_box[2], other[2])-max(image_box[0], other[0])
        if overlap > (image_box[2]-image_box[0])*.5 and other[1] > bottom+1:
            stop = min(stop, other[1]-1)
    all_words = page.get_text('words')
    # Fence using the complete PDF line BEFORE filtering by panel column. A
    # full-width Figure caption starts in the left column; its right half must
    # never be mistaken for continuation of the right panel's subcaption.
    global_lines = collections.defaultdict(list)
    for w in all_words:
        key = tuple(w[5:7]) if len(w) >= 7 else (round(w[1]/2),)
        global_lines[key].append(w)
    for line in global_lines.values():
        line.sort(key=lambda w: w[0])
        if re.match(r'^(Figure|Fig\.|Table)\s', ' '.join(w[4] for w in line)):
            b = union([list(w[:4]) for w in line])
            if b[1] > bottom and min(b[2], image_box[2])-max(b[0], image_box[0]) > .4*(image_box[2]-image_box[0]):
                stop = min(stop, b[1]-1)
    words = [w for w in all_words
             if bottom-1 <= w[1] < stop and image_box[0]-6 <= (w[0]+w[2])/2 <= image_box[2]+6]
    lines = []
    for word in sorted(words, key=lambda w: (round(w[1]/2), w[0])):
        matching = next((line for line in lines if abs(line[0][1]-word[1]) < 3), None)
        if matching is None:
            lines.append([word])
        else:
            matching.append(word)
    lines.sort(key=lambda line: min(w[1] for w in line))
    retained = []
    for line in lines:
        line.sort(key=lambda w: w[0])
        text = ' '.join(w[4] for w in line)
        if re.match(r'^(Figure|Fig\.|Table)\s', text):
            break
        box = union([list(w[:4]) for w in line])
        if not retained:
            tag = re.match(r'^\(([a-z][0-9]?)\)', text)
            if not tag or tag.group(1) not in expected[:35] or box[1]-bottom > 22:
                continue
            # Beyond the tag, require actual source words when there are words.
            tokens = re.findall(r'[a-z]{3,}', text.lower())[0:4]
            if tokens and not any(t in expected for t in tokens):
                continue
        elif box[1]-retained[-1]['box'][3] > 8 or re.match(r'^\([a-z][0-9]?\)', text):
            break
        retained.append({'text': text, 'box': box})
        if len(retained) >= 9:
            break
    if not retained:
        return None, 'Printed subcaption not resolved; manual review required'
    nominal = union([line['box'] for line in retained])
    search = [max(0, math.floor((nominal[0]-2)*scale)), max(0, math.floor((nominal[1]-1)*scale)),
              min(raster.width, math.ceil((nominal[2]+2)*scale)), min(raster.height, math.ceil((nominal[3]+3)*scale))]
    mask = raster.crop(search).convert('L').point(lambda v: 255 if v < 180 else 0)
    ink = mask.getbbox()
    if not ink or ink[0] == 0 or ink[1] == 0 or ink[2] == mask.width or ink[3] == mask.height:
        return {'lines': retained, 'nominal_points': nominal, 'ink_points': pad(nominal, 2)}, 'Text recovered; ink touches search edge, review required'
    return {'lines': retained, 'nominal_points': nominal,
            'ink_points': [(ink[i]+search[i % 2])/scale for i in range(4)]}, 'Printed subcaption recovered; visual review required'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sample', type=Path, required=True)
    p.add_argument('--copy', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--dpi', type=int, default=216)
    args = p.parse_args()
    if platform.system() != 'Darwin' or not 144 <= args.dpi <= 240:
        raise ValueError('Bounded Mac-only PDF preparation')
    import fitz
    source, out = args.copy.resolve(), args.out.resolve()
    if out.exists() or out.is_relative_to(source) or source.is_relative_to(out):
        raise ValueError('New output separate from source required')
    sample = json.loads(args.sample.read_text())
    for paper in sample['papers']:
        if paper['split'] != 'train':
            raise ValueError('This expansion is training-only')
        for entry in paper['files']:
            path = source/entry['path']
            if path.is_symlink() or not path.resolve().is_relative_to(source) or path.stat().st_size != entry['bytes'] or sha(path) != entry['sha256']:
                raise ValueError('Changed or external source copy')
    out.mkdir(parents=True)
    (out/'images').mkdir()
    accepted, deferred = [], []
    scale = args.dpi/72
    for paper in sample['papers']:
        directory = source/'data/arxiv'/paper['id']
        parser = Figures(paper['id'])
        parser.feed((directory/'arxiv.html').read_text())
        groups = [g for g in parser.groups() if g['id'] in paper['candidate_groups']
                  and not any(re.match(r'^(Figure|Fig\.)\s+\d', c['caption'].strip()) for c in g['children'])]
        # Single-asset figures are also only candidates: one asset may contain many plots.
        singles = [g for g in parser.roots if g['id'] and not g['children'] and len(g['images']) == 1 and g['images'][0]['path']]
        singles = ([g for g in singles if g['id'] in paper['candidate_singles']]
                   if 'candidate_singles' in paper else singles[:2])
        wanted = {c['images'][0]['path'] for g in groups for c in g['children']}
        wanted.update(g['images'][0]['path'] for g in singles)
        try:
            assets = archive_assets(directory/'source.archive', wanted)
            document = fitz.open(directory/'build/plain.pdf')
            if len(document) > 120:
                raise ValueError('PDF page bound')
            matches = occurrences(document, assets)
        except (ValueError, tarfile.TarError) as error:
            deferred.append({'paper': paper['id'], 'reason': str(error)})
            continue
        for group in groups+singles:
            identifier = paper['id']+'-'+group['id']
            children = group['children'] or [group]
            paths = [c['images'][0]['path'] for c in children]
            try:
                if len(set(paths)) != len(paths) or any(path not in assets for path in paths):
                    raise ValueError('Missing or nonunique source archive asset')
                source_assets = [assets[path] for path in paths]
                instances = select_group(source_assets, matches)
                page_number = instances[0]['page_zero_based']
                page = document[page_number]
                pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False, colorspace=fitz.csRGB)
                raster = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
                panels = []
                for child, path, asset, instance in zip(children, paths, source_assets, instances):
                    letter, status = subcaption_bounds(child['caption'], instance['box_points'],
                        [i['box_points'] for i in instances], page, raster, scale) if len(children) > 1 else (None, 'Single asset; semantic panels require review')
                    bounds = union([instance['box_points'], letter['ink_points']]) if letter else instance['box_points']
                    panels.append({'html_id': child['id'], 'source_path': path, 'asset': asset,
                                   'instance': instance, 'label': letter, 'review_required': status,
                                   'caption': ' '.join(child['caption'].split()), 'box_points': pad(bounds, 1)})
                # Review margin also exposes shared headings, nearby captions or
                # unwanted page content; the annotation must crop these explicitly.
                bounds = pad(union([p['box_points'] for p in panels]), 12)
                crop = [max(0, math.floor(bounds[0]*scale)), max(0, math.floor(bounds[1]*scale)),
                        min(raster.width, math.ceil(bounds[2]*scale)), min(raster.height, math.ceil(bounds[3]*scale))]
                image = raster.crop(crop)
                if min(image.size) < 80 or image.width*image.height > 8_000_000:
                    raise ValueError('Candidate size bound')
                for panel in panels:
                    b = panel['box_points']
                    panel['box'] = [max(0, math.floor(b[0]*scale)-crop[0]), max(0, math.floor(b[1]*scale)-crop[1]),
                                    min(image.width, math.ceil(b[2]*scale)-crop[0]), min(image.height, math.ceil(b[3]*scale)-crop[1])]
                path = out/'images'/(identifier+'.png')
                image.save(path)
                accepted.append({'id': identifier, 'paper': paper['family'], 'revision': paper['id'],
                                 'split': 'train', 'html_id': group['id'], 'caption': ' '.join(group['caption'].split()),
                                 'image': str(path.relative_to(out)), 'width': image.width, 'height': image.height,
                                 'sha256': sha(path), 'panels': panels, 'page_zero_based': page_number,
                                 'page_pixel_crop': crop, 'dpi': args.dpi, 'domain': paper['category'],
                                 'source_pdf_sha256': sha(directory/'build/plain.pdf'),
                                 'source_archive_sha256': paper['source_sha256'], 'source_html_sha256': paper['html_sha256'],
                                 'title': paper['title'], 'license': paper['license'],
                                 'source_url': 'https://arxiv.org/abs/'+paper['id'],
                                 'status': 'Source-verified geometry candidate; no automatic training admission'})
            except ValueError as error:
                deferred.append({'id': identifier, 'reason': str(error)})
        document.close()
    manifest = {'version': 1, 'script_sha256': sha(__file__),
                'parser_sha256': sha(Path(__file__).with_name('source_html.py')),
                'sample_sha256': sha(args.sample), 'pdf_processing': 'Mac only',
                'status': 'Review queue, not ground truth or model output', 'records': accepted, 'deferred': deferred}
    (out/'candidates.json').write_text(json.dumps(manifest, indent=2)+'\n')
    font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 13)
    for offset in range(0, len(accepted), 6):
        batch = accepted[offset:offset+6]
        sheet = Image.new('RGB', (1500, math.ceil(len(batch)/2)*450), 'white')
        d = ImageDraw.Draw(sheet)
        for i, row in enumerate(batch):
            im = Image.open(out/row['image']).convert('RGB')
            draw = ImageDraw.Draw(im)
            for panel in row['panels']:
                draw.rectangle(panel['box'], outline='#0050d0', width=2)
            im.thumbnail((730, 400))
            x, y = (i % 2)*750, (i//2)*450
            d.text((x+8, y+4), row['id'], fill='black', font=font)
            sheet.paste(im, (x+8, y+32))
        sheet.save(out/f'review-{offset//6:02}.jpg', quality=94)
    print(json.dumps({'candidates': len(accepted), 'papers': len({r['paper'] for r in accepted}),
                      'deferred': dict(collections.Counter(r['reason'] for r in deferred))}, indent=2))


if __name__ == '__main__':
    main()
