#!/usr/bin/env python3
"""Failure-class tag per GT figure (for per-class reporting).

Order of precedence: many-panels (>=5) > lettered-plot-groups > framed-diagrams > touching-raster > plot-grid.
Uses the annotator's note (an explicit 'class=<name>' wins) and the label method; singles are 'single'.
"""
import json, re, sys

GROUP = re.compile(r'lettered (rows|columns|groups|group)|\(\w\) (=|covers)|groups of|each two image|two bar charts|grid of small plots|lettered parts|class=lettered', re.I)
FRAMED = re.compile(r'framed|diagram|pipeline|\bstages?\b|\barrows?\b|workflow|schematic|infographic|class=framed', re.I)
TOUCH = re.compile(r'touching|photo|image|render|frames|strip|screenshot|x-ray|heatmaps|class=touching', re.I)


def tag(g):
    n = len(g['panels'])
    note = g.get('note') or ''
    m = re.search(r'class=([a-z\-]+)', note)
    if n < 2:
        return 'single'
    if m:
        c = m.group(1)
        return 'many-panels' if n >= 5 else c
    if n >= 5:
        return 'many-panels'
    if GROUP.search(note) or g.get('label_method') == 'vgroup' and 'lettered' in note:
        return 'lettered-plot-groups'
    if FRAMED.search(note):
        return 'framed-diagrams'
    if TOUCH.search(note) and not (g.get('file') or '').lower().endswith('.pdf') or 'touching' in note:
        return 'touching-raster'
    return 'plot-grid'


if __name__ == '__main__':
    gt, out = sys.argv[1], sys.argv[2]
    tags = {}
    for l in open(gt):
        g = json.loads(l)
        tags[g['id']] = tag(g)
    json.dump(tags, open(out, 'w'), indent=0)
    import collections
    print(collections.Counter(tags.values()))
