#!/usr/bin/env python3
"""Mac-only review candidates from native, single-page source figure PDFs.

HTML preview basenames are only a lookup hint. Require one archive PDF, an
includegraphics reference, and a unique matching caption in the compiled paper.
These checks do not prove semantic correspondence: review both renders before
admission. Never execute TeX, extract archives wholesale, or fetch a PDF.
"""
import argparse
import collections
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import platform
import re
import tarfile

from PIL import Image
from source_html import Figures, source_path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def native_assets(path, stems):
    found, references = collections.defaultdict(list), collections.defaultdict(list)
    total = 0
    with tarfile.open(path, 'r|*') as archive:
        for i, entry in enumerate(archive):
            total += entry.size
            if i >= 5000 or total > 256*1024**2 or entry.size > 64*1024**2:
                raise ValueError('Archive resource bound')
            parts = PurePosixPath(entry.name).parts
            if not entry.isfile() or not parts or '..' in parts or entry.name.startswith('/') or '\\' in entry.name:
                continue
            suffix, stem = PurePosixPath(entry.name).suffix.lower(), PurePosixPath(entry.name).stem
            if suffix == '.pdf' and stem in stems and entry.size <= 16*1024**2:
                raw = archive.extractfile(entry).read()
                if raw.startswith(b'%PDF-'):
                    found[stem].append({'member': entry.name, 'bytes': len(raw),
                                       'sha256': hashlib.sha256(raw).hexdigest(), 'raw': raw})
            elif suffix == '.tex' and entry.size <= 4*1024**2:
                raw = archive.extractfile(entry).read()
                text = raw.decode('utf8', 'replace')
                for match in re.finditer(r'\\includegraphics\*?(?:\[[^\]]{0,2048}\])?\s*\{([^{}]{1,1024})\}', text):
                    try:
                        target = source_path(match.group(1).strip(), '')
                    except ValueError:
                        continue
                    stem = PurePosixPath(target).stem
                    if stem in stems and PurePosixPath(target).suffix.lower() in ('', '.pdf'):
                        references[stem].append({'tex_member': entry.name, 'tex_sha256': hashlib.sha256(raw).hexdigest(),
                                                 'line': text.count('\n', 0, match.start())+1, 'target': target})
    return {stem: {**items[0], 'references': references[stem]}
            for stem, items in found.items() if len(items) == 1 and references[stem]}


def caption_pages(caption, pages):
    normal = lambda text: re.sub(r'[^a-z0-9]', '', text.lower())
    # A short prefix avoids formula macro differences, but still binds to figure
    # number plus actual caption words. Require unique occurrence in this paper.
    prefix = normal(caption)[:48]
    if len(prefix) < 25:
        return []
    return [i for i, text in enumerate(pages) if prefix in normal(text)]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sample', type=Path, required=True)
    p.add_argument('--copy', type=Path, required=True)
    p.add_argument('--raster-candidates', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    if platform.system() != 'Darwin':
        raise ValueError('PDF processing is Mac-only')
    import fitz
    source, out = args.copy.resolve(), args.out.resolve()
    if out.exists() or out.is_relative_to(source) or source.is_relative_to(out):
        raise ValueError('New output separate from source required')
    sample = json.loads(args.sample.read_text())
    raster = json.loads(args.raster_candidates.read_text())
    if raster['sample_sha256'] != sha(args.sample):
        raise ValueError('Raster candidate source mismatch')
    seen = {r['id'] for r in raster['records']}
    out.mkdir(parents=True)
    (out/'images').mkdir()
    (out/'parent-pages').mkdir()
    records, deferred = [], []
    for paper in sample['papers']:
        if paper['split'] != 'train':
            raise ValueError('Training-only expansion')
        directory = source/'data/arxiv'/paper['id']
        for entry in paper['files']:
            path = source/entry['path']
            if path.is_symlink() or not path.resolve().is_relative_to(source) or path.stat().st_size != entry['bytes'] or sha(path) != entry['sha256']:
                raise ValueError('Changed or external source copy')
        parser = Figures(paper['id'])
        parser.feed((directory/'arxiv.html').read_text())
        roots = [g for g in parser.roots if g['id'] in paper.get('candidate_singles', [])
                 and paper['id']+'-'+g['id'] not in seen and not g['children']
                 and len(g['images']) == 1 and g['images'][0]['path']]
        if not roots:
            continue
        assets = native_assets(directory/'source.archive', {Path(g['images'][0]['path']).stem for g in roots})
        parent = fitz.open(directory/'build/plain.pdf')
        if parent.is_encrypted or len(parent) > 120:
            raise ValueError('Parent PDF resource bound')
        pages = [page.get_text() for page in parent]
        for group in roots:
            identifier = paper['id']+'-'+group['id']
            asset = assets.get(Path(group['images'][0]['path']).stem)
            matches = caption_pages(group['caption'], pages)
            if not asset or len(matches) != 1:
                deferred.append({'id': identifier, 'reason': 'No unique referenced native PDF and caption page',
                                 'asset_found': bool(asset), 'caption_pages': matches})
                continue
            document = fitz.open(stream=asset['raw'], filetype='pdf')
            if document.is_encrypted or len(document) != 1:
                deferred.append({'id': identifier, 'reason': 'Native PDF must be one unencrypted page'})
                document.close()
                continue
            page = document[0]
            if min(page.rect.width, page.rect.height) < 30 or max(page.rect.width, page.rect.height) > 4000:
                raise ValueError('Native PDF geometry bound')
            scale = min(3., 2000/max(page.rect.width, page.rect.height))
            pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False, colorspace=fitz.csRGB)
            im = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
            path = out/'images'/(identifier+'.png')
            im.save(path)
            parent_page = parent[matches[0]]
            pp = parent_page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False, colorspace=fitz.csRGB)
            parent_path = out/'parent-pages'/(identifier+'.png')
            Image.frombytes('RGB', (pp.width, pp.height), pp.samples).save(parent_path)
            record = {'id': identifier, 'paper': paper['family'], 'revision': paper['id'], 'split': 'train',
                      'html_id': group['id'], 'caption': ' '.join(group['caption'].split()),
                      'image': str(path.relative_to(out)), 'width': im.width, 'height': im.height, 'sha256': sha(path),
                      'panels': [{'box': [0, 0, im.width, im.height], 'asset': {k: v for k, v in asset.items() if k != 'raw'},
                                  'review_required': 'Review native asset against parent page; annotate semantic panels manually'}],
                      'page_zero_based': 0, 'page_pixel_crop': [0, 0, im.width, im.height], 'dpi': scale*72,
                      'source_pdf_sha256': asset['sha256'], 'source_pdf_kind': 'native_single_figure_asset',
                      'source_archive_sha256': paper['source_sha256'], 'source_html_sha256': paper['html_sha256'],
                      'parent_pdf_sha256': sha(directory/'build/plain.pdf'), 'parent_page_zero_based': matches[0],
                      'parent_page_review_image': str(parent_path.relative_to(out)), 'parent_page_review_sha256': sha(parent_path),
                      'domain': paper['category'], 'title': paper['title'], 'license': paper['license'],
                      'source_url': 'https://arxiv.org/abs/'+paper['id'],
                      'status': 'Native-source review candidate, not pixel-identity verification or ground truth'}
            records.append(record)
            document.close()
        parent.close()
    manifest = {'version': 1, 'script_sha256': sha(__file__),
                'parser_sha256': sha(Path(__file__).with_name('source_html.py')), 'sample_sha256': sha(args.sample),
                'raster_candidates_sha256': sha(args.raster_candidates), 'pdf_processing': 'Mac only',
                'status': 'Review queue requiring manual parent-page correspondence and panel annotation',
                'records': records, 'deferred': deferred}
    (out/'candidates.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps({'candidates': len(records), 'deferred': len(deferred)}))


if __name__ == '__main__':
    main()
