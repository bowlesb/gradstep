#!/usr/bin/env python3
"""Materialize visually reviewed public figure crops; preserve the original test.

Reads only local PDF-derived images/metadata. The output contains no PDFs and can
be transferred to the isolated training workspace. Codex annotations remain
development labels, not independent human-reviewed ground truth.
"""
import argparse
import collections
import hashlib
from html.parser import HTMLParser
import json
import math
from pathlib import Path
import re

from PIL import Image, ImageDraw, ImageFont
from prepare import CLASSES, phash, sha


class Metadata(HTMLParser):
    def __init__(self):
        super().__init__()
        self.authors, self.licenses = [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'meta' and a.get('name') == 'citation_author':
            self.authors.append(a['content'])
        if tag == 'a' and 'has_license' in a.get('class', '').split():
            self.licenses.append(a.get('href'))


def author_key(name):
    # Comma order differs between the two public metadata sources.
    words = re.findall(r'[^\W\d_]+', name.lower(), flags=re.UNICODE)
    return ' '.join(sorted(words)) if len(''.join(words)) >= 7 else None


def box_inside(box, bounds):
    return (len(box) == 4 and all(isinstance(x, (float, int)) and math.isfinite(x) for x in box)
            and bounds[0] <= box[0] < box[2] <= bounds[2]
            and bounds[1] <= box[1] < box[3] <= bounds[3])


def annotation_boxes(spec, width, height):
    crop = spec['crop']
    if not box_inside(crop, [0, 0, width, height]) or any(x != int(x) for x in crop):
        raise ValueError('Invalid integer review crop')
    if not spec['panels']:
        raise ValueError('Missing panel annotation')
    contexts = {c['id']: c for c in spec['contexts']}
    panel_ids = {f'p{i:02}' for i in range(len(spec['panels']))}
    if len(contexts) != len(spec['contexts']) or panel_ids & contexts.keys():
        raise ValueError('Duplicate annotation identity')
    boxes = []
    for c in spec['contexts']:
        if c['class'] not in range(4) or not box_inside(c['box'], crop):
            raise ValueError('Invalid shared context')
        boxes.append({'id': c['id'], 'class': c['class'], 'box': c['box']})
    for i, panel in enumerate(spec['panels']):
        if not box_inside(panel['box'], crop) or any(c not in contexts for c in panel['required']):
            raise ValueError('Invalid panel or missing required context')
        boxes.append({'id': f'p{i:02}', 'class': 4, 'box': panel['box'],
                      'required_context_ids': sorted(set(panel['required']))})
    for b in boxes:
        b['box'] = [v - crop[i % 2] for i, v in enumerate(b['box'])]
        b['origin'] = 'Codex visual annotation; not independently human reviewed'
    return boxes


def near(a, b):
    return (a['sha256'] == b['sha256'] or
            abs((a['width']/a['height'])/(b['width']/b['height'])-1) <= .08
            and bin(int(a['phash'], 16) ^ int(b['phash'], 16)).count('1') <= 4)


def counts(rows):
    return {'images': len(rows), 'papers': len({r['paper'] for r in rows}),
            'compound_images': sum(sum(b['class'] == 4 for b in r['boxes']) > 1 for r in rows),
            'boxes': dict(collections.Counter(CLASSES[b['class']] for r in rows for b in r['boxes'])),
            'explicit_panel_context_links': sum(len(b.get('required_context_ids', [])) for r in rows for b in r['boxes'])}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidates', type=Path, required=True)
    p.add_argument('--annotations', type=Path, required=True)
    p.add_argument('--sample', type=Path, required=True)
    p.add_argument('--copy', type=Path, required=True)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--base-attribution', type=Path, required=True)
    p.add_argument('--base-fingerprints', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--image-prefix', default='data/reviewed/mathpix-v1/images')
    p.add_argument('--sampling-weight', type=float, default=8.)
    args = p.parse_args()
    if args.out.exists():
        raise ValueError('Immutable revision already exists')
    if not math.isfinite(args.sampling_weight) or not 1 <= args.sampling_weight <= 16:
        raise ValueError('Bounded training sampling weight required')
    if Path(args.image_prefix).is_absolute() or '..' in Path(args.image_prefix).parts:
        raise ValueError('Relative training image prefix required')
    annotation = json.loads(args.annotations.read_text())
    if annotation['candidate_manifest_sha256'] != sha(args.candidates):
        raise ValueError('Changed candidate manifest')
    candidate_manifest = json.loads(args.candidates.read_text())
    if candidate_manifest['sample_sha256'] != sha(args.sample):
        raise ValueError('Changed source-copy manifest')
    sample = json.loads(args.sample.read_text())
    expected = {f['path']: f['sha256'] for paper in sample['papers'] for f in paper['files']}
    candidates = {r['id']: r for r in candidate_manifest['records']}
    base_manifest = json.loads((args.base/'manifest.json').read_text())
    for filename, digest in base_manifest['files'].items():
        if sha(args.base/filename) != digest:
            raise ValueError('Changed base dataset')
    base = {s: [json.loads(line) for line in (args.base/f'{s}.jsonl').read_text().splitlines()]
            for s in ('train', 'validation', 'test')}
    fingerprints = json.loads(args.base_fingerprints.read_text())
    comparison_rows = {}
    for split, rows in base.items():
        comparison_rows[split] = []
        for row in rows:
            if 'phash' in row:
                comparison_rows[split].append(row)
            else:
                entry = fingerprints[row['id']]
                if entry['sha256'] != row['sha256']:
                    raise ValueError('Fingerprint source mismatch')
                comparison_rows[split].append({**row, 'phash': entry['phash']})
    attribution = json.loads(args.base_attribution.read_text())
    base_authors = collections.defaultdict(set)
    for split, rows in base.items():
        for r in rows:
            people = attribution.get(r['paper'], {}).get('author') or []
            for person in people[:1]+people[-1:]:
                key = author_key(person['name'])
                if key:
                    base_authors[key].add(split)
    metadata, authors, exclusions, quarantine = {}, {}, [], set()
    planned, images = [], {}
    for spec in annotation['records']:
        c = candidates[spec['id']]
        if c['split'] not in ('train', 'validation'):
            raise ValueError('Reserved test is not available for development')
        source = (args.candidates.parent/c['image']).resolve()
        if not source.is_relative_to(args.candidates.parent.resolve()) or sha(source) != spec['candidate_sha256'] or sha(source) != c['sha256']:
            raise ValueError('Changed/external candidate image')
        image = Image.open(source).convert('RGB')
        if image.size != (c['width'], c['height']):
            raise ValueError('Candidate dimensions mismatch')
        boxes = annotation_boxes(spec, *image.size)
        image = image.crop(spec['crop'])
        if c['paper'] not in metadata:
            path = args.copy/'data/arxiv'/c['revision']/'abstract.html'
            if sha(path) != expected[str(path.relative_to(args.copy))]:
                raise ValueError('Changed copied source metadata')
            parser = Metadata()
            parser.feed(path.read_text())
            if c['license'] not in parser.licenses or c['license'] not in (
                    'http://creativecommons.org/licenses/by/4.0/', 'http://creativecommons.org/publicdomain/zero/1.0/'):
                raise ValueError('Source abstract does not confirm the catalog license')
            if not parser.authors:
                raise ValueError('Missing paper author metadata')
            metadata[c['paper']] = {'title': c['title'], 'authors': parser.authors, 'source_url': c['source_url'],
                                    'license': c['license'], 'abstract_sha256': sha(path)}
            authors[c['paper']] = {author_key(n) for n in parser.authors[:1]+parser.authors[-1:]}-{None}
        for key in authors[c['paper']]:
            other = base_authors[key]-{c['split']}
            if other:
                quarantine.add(c['paper'])
                exclusions.append({'paper': c['paper'], 'reason': 'first_or_last_author_overlaps_other_existing_split', 'splits': sorted(other)})
        row = {'id': 'arxiv-'+c['id'], 'paper': 'arxiv:'+c['paper'], 'group': 'arxiv:'+c['paper'],
               'split': c['split'], 'image': args.image_prefix+'/'+c['id']+'.png',
               'width': image.width, 'height': image.height, 'phash': f'{phash(image):016x}',
               'domain': c['domain'], 'boxes': boxes, 'review': annotation['annotator'],
               'independent_human_review': False, 'review_note': spec['review_note'],
               'source': 'owner Mathpix-replacement research corpus; public arXiv figure',
               'source_url': c['source_url'], 'license': c['license'], 'source_pdf_sha256': c['source_pdf_sha256'],
               'source_labels_sha256': c['source_labels_sha256'], 'source_candidate_sha256': c['sha256'],
               'source_page_zero_based': c['page_zero_based'], 'source_page_pixel_crop': c['page_pixel_crop'],
               'candidate_pixel_crop': spec['crop'], 'source_dpi': c['dpi'],
               'annotation_sha256': hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest(),
               'caption': c['caption'], 'sampling_weight': args.sampling_weight}
        # Byte hash below must match the exact encoded file later transferred.
        import io
        encoded = io.BytesIO()
        image.save(encoded, format='PNG')
        data = encoded.getvalue()
        row['sha256'] = hashlib.sha256(data).hexdigest()
        images[row['id']] = data
        planned.append(row)
    for i, row in enumerate(planned):
        for split, old in comparison_rows.items():
            if split == row['split']:
                continue
            for other in old:
                if near(row, other):
                    quarantine.add(row['paper'].removeprefix('arxiv:'))
                    exclusions.append({'id': row['id'], 'reason': 'image_overlap_other_existing_split', 'other_id': other['id'], 'other_split': split})
        for other in planned[:i]:
            if row['split'] == other['split']:
                continue
            shared_author = authors[row['paper'].removeprefix('arxiv:')] & authors[other['paper'].removeprefix('arxiv:')]
            if near(row, other) or shared_author:
                quarantine.update((row['paper'].removeprefix('arxiv:'), other['paper'].removeprefix('arxiv:')))
                exclusions.append({'id': row['id'], 'reason': 'new_split_author_or_image_overlap', 'other_id': other['id']})
    admitted, seen = [], set()
    for row in planned:
        if row['paper'].removeprefix('arxiv:') in quarantine:
            continue
        if row['sha256'] in seen:
            exclusions.append({'id': row['id'], 'reason': 'same_split_exact_duplicate'})
            continue
        seen.add(row['sha256'])
        admitted.append(row)
    args.out.mkdir(parents=True)
    (args.out/'images').mkdir()
    for row in admitted:
        (args.out/'images'/Path(row['image']).name).write_bytes(images[row['id']])
    manifest = {'version': 11, 'classes': CLASSES, 'distribution_allowed': False,
                'source': 'base plots-v7 plus visually annotated public arXiv development figures',
                'base_manifest_sha256': sha(args.base/'manifest.json'),
                'base_fingerprints_sha256': sha(args.base_fingerprints),
                'annotations_sha256': sha(args.annotations), 'candidates_sha256': sha(args.candidates),
                'source_copy_manifest_sha256': sha(args.sample),
                'script_sha256': sha(__file__), 'sampling_weight_for_new_training_examples': args.sampling_weight,
                'split_method': 'preassigned paper hash; quarantine first/last-author and exact/pHash cross-split conflicts',
                'review_limit': 'Codex visual review only; no independent human annotation or final-test qualification',
                'pdf_boundary': 'Only local Mac processing; only extracted images/annotations transferred for training',
                'files': {}, 'counts': {}, 'added_counts': {}}
    for split in base:
        added = [r for r in admitted if r['split'] == split]
        path = args.out/f'{split}.jsonl'
        if split == 'test':
            path.write_bytes((args.base/'test.jsonl').read_bytes())
        else:
            path.write_text(''.join(json.dumps(r, sort_keys=True)+'\n' for r in base[split]+added))
        manifest['files'][path.name] = sha(path)
        manifest['counts'][split] = counts(base[split]+added)
        manifest['added_counts'][split] = counts(added)
        extra = args.out/f'mathpix-{split}.jsonl'
        extra.write_text(''.join(json.dumps(r, sort_keys=True)+'\n' for r in added))
        manifest['files'][extra.name] = sha(extra)
    (args.out/'attribution.json').write_text(json.dumps(metadata, indent=2)+'\n')
    (args.out/'exclusions.json').write_text(json.dumps(exclusions, indent=2)+'\n')
    (args.out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    # Visible verification of interpreted panel/context geometry.
    font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 13)
    for offset in range(0, len(admitted), 6):
        batch = admitted[offset:offset+6]
        sheet = Image.new('RGB', (1200, math.ceil(len(batch)/2)*370), 'white')
        draw = ImageDraw.Draw(sheet)
        for i, row in enumerate(batch):
            im = Image.open(args.out/'images'/Path(row['image']).name).convert('RGB')
            d = ImageDraw.Draw(im)
            for b in sorted(row['boxes'], key=lambda b: b['class']):
                color = '#0050d0' if b['class'] == 4 else '#e15b00'
                d.rectangle(b['box'], outline=color, width=2)
                d.text((b['box'][0]+2, b['box'][1]+2), b['id'], fill=color)
            im.thumbnail((580, 320))
            x, y = (i % 2)*600, (i // 2)*370
            draw.text((x+8, y+4), row['id']+' '+row['split'], fill='black', font=font)
            sheet.paste(im, (x+8, y+32))
        sheet.save(args.out/f'review-{offset//6:02}.jpg', quality=94)
    print(json.dumps({'added_counts': manifest['added_counts'], 'quarantined_papers': sorted(quarantine),
                      'exclusions': len(exclusions), 'test_bytes_unchanged': sha(args.out/'test.jsonl') == sha(args.base/'test.jsonl')}, indent=2))


if __name__ == '__main__':
    main()
