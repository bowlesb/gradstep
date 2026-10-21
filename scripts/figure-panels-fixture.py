#!/usr/bin/env python3
"""Builds the app's two-plot figure fixture (`ReaderSamples/arxiv-fixture-panels.json`) from the HTML study fixture
(`ReaderSamples/arxiv-fixture.json`): the same authored paper, with Figure 1 replaced by a real two-plot figure (DPO's
Figure 2, from the bundled Mathpix sample cd902bcd…) so the figure view's crops can be checked and reviewed on a real
multi-panel figure (`--figure-fixture-panels`, FigureViewJourneyTests). Every hash, size and path is recomputed so the
package verifies as any arXiv bundle does.

Usage: python3 scripts/figure-panels-fixture.py
"""
import base64, hashlib, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAMPLES = ROOT / 'apps/apple/ScienceReader/Resources/ReaderSamples'
FIGURE = SAMPLES / 'cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/assets/71e93518051c67deb7400d9a48cc2ee6f96ed251dd2b8f916ab4fca9a702418c.jpg'
WIDTH, HEIGHT = 1360, 501


def sha(data):
    return hashlib.sha256(data).hexdigest()


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def main():
    package = json.loads((SAMPLES / 'arxiv-fixture.json').read_text())
    manifest = json.loads(base64.b64decode(package['manifest']))
    members = {m['path']: base64.b64decode(m['base64']) for m in package['members']}
    old = next(m for m in manifest['members'] if m['role'] == 'image')
    image = FIGURE.read_bytes()
    digest = sha(image)
    path = f'assets/{digest}.jpg'
    html = members['index.html'].decode()
    html = html.replace(old['path'], path).replace(f'height="{old["height"]}"', f'height="{HEIGHT}"').replace(f'width="{old["width"]}"', f'width="{WIDTH}"')
    html = html.replace('Figure 1: A test figure.', 'Figure 1: Two results side by side.')
    index = json.loads(members['reader.json'])
    for figure in index['figures']:
        figure['asset_paths'] = [path if p == old['path'] else p for p in figure['asset_paths']]
        figure['alt'] = figure['caption'] = figure['caption'].replace('A test figure.', 'Two results side by side.')
    for block in index['blocks']:
        block['text'] = block['text'].replace('Figure 1: A test figure.', 'Figure 1: Two results side by side.')
    provenance = json.loads(members['provenance.json'])
    for row in provenance['image_inputs']:
        if row['published_path'] == old['path']:
            row.update(published_path=path, published_sha256=digest, input_sha256=digest, width=WIDTH, height=HEIGHT)
    new = {p: d for p, d in members.items() if p != old['path']}
    new[path] = image
    new['index.html'] = html.encode()
    tail = lambda name: b'\n' if members[name].endswith(b'\n') else b''
    new['reader.json'] = compact(index) + tail('reader.json')
    new['provenance.json'] = compact(provenance) + tail('provenance.json')
    rows = []
    for m in manifest['members']:
        m = dict(m)
        if m['path'] == old['path']:
            m.update(path=path, sha256=digest, bytes=len(image), width=WIDTH, height=HEIGHT)
        else:
            m.update(sha256=sha(new[m['path']]), bytes=len(new[m['path']]))
        rows.append(m)
    manifest['members'] = sorted(rows, key=lambda m: m['path'])
    manifest_bytes = compact(manifest) + (b'\n' if base64.b64decode(package['manifest']).endswith(b'\n') else b'')
    out = {'manifest': base64.b64encode(manifest_bytes).decode(), 'manifestSHA256': sha(manifest_bytes),
           'members': [{'path': m['path'], 'base64': base64.b64encode(new[m['path']]).decode()} for m in manifest['members']]}
    (SAMPLES / 'arxiv-fixture-panels.json').write_text(json.dumps(out, sort_keys=True, separators=(',', ':')))
    print(out['manifestSHA256'], len(manifest['members']))


if __name__ == '__main__':
    main()
