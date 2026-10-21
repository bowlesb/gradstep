#!/usr/bin/env python3
"""Structure-first census: how often does the arXiv HTML already split a figure into parts?

For every `<figure class="ltx_figure">` (top level, tables excluded) in each paper's official arxiv.html:
images (`<img>` or SVG `<object>` with class ltx_graphics), LaTeXML panels (`ltx_figure_panel`), nested sub-figures
(`<figure class="ltx_figure ltx_figure_panel">` with their own `<figcaption>`), and the caption's panel letters.
A figure whose HTML has >= 2 images is already split into exact parts (the app stacks them); a single-image
figure whose caption names >= 2 letters is the case that needs a model. Reads the corpus only.
"""
import argparse, collections, json, multiprocessing as mp, re
from html.parser import HTMLParser
from pathlib import Path

from sfd.core.policy import caption_letters


class FigParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.figs = [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get('class') or ''
        if tag == 'figure':
            top = 'ltx_figure' in cls.split() and not any(f['kind'] == 'figure' for f in self.stack)
            f = {'kind': 'figure' if top else 'nested', 'imgs': 0, 'panels': 0, 'subfigs': 0, 'caption': '', 'in_cap': 0,
                 'table': 'ltx_table' in cls}
            if not top and self.stack:
                self.stack[-1]['subfigs'] += 1 if 'ltx_figure' in cls else 0
            self.stack.append(f)
        elif self.stack:
            top = next((f for f in self.stack if f['kind'] == 'figure'), None)
            if top is None:
                return
            if tag in ('img', 'object') and 'ltx_graphics' in cls:
                top['imgs'] += 1
            if 'ltx_figure_panel' in cls.split():
                top['panels'] += 1
            if tag == 'figcaption' and self.stack[-1] is top:
                top['in_cap'] += 1
        if self.stack and tag != 'figure' and self.stack[-1].get('in_cap'):
            self.stack[-1]['in_cap'] += 0

    def handle_endtag(self, tag):
        if tag == 'figure' and self.stack:
            f = self.stack.pop()
            if f['kind'] == 'figure' and not f['table']:
                self.figs.append(f)
        elif tag == 'figcaption' and self.stack and self.stack[-1].get('in_cap'):
            self.stack[-1]['in_cap'] = 0

    def handle_data(self, data):
        if self.stack and self.stack[-1].get('in_cap'):
            self.stack[-1]['caption'] += data


def census(path):
    try:
        p = FigParser(); p.feed(Path(path).read_text(errors='replace'))
    except Exception:
        return None
    out = []
    for f in p.figs:
        L = len(caption_letters(f['caption']))
        out.append({'imgs': f['imgs'], 'panels': f['panels'], 'subfigs': f['subfigs'], 'letters': L})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=16)
    args = ap.parse_args()
    files = sorted(str(p / 'arxiv.html') for p in args.corpus.iterdir() if (p / 'arxiv.html').exists())
    c = collections.Counter(); papers = 0
    with mp.Pool(args.workers) as pool:
        for figs in pool.imap_unordered(census, files, chunksize=32):
            if figs is None:
                c['parse_error'] += 1; continue
            papers += 1
            for f in figs:
                c['figures'] += 1
                if f['imgs'] == 0:
                    c['no_image (tikz/svg/text)'] += 1
                elif f['imgs'] >= 2:
                    c['multi_image'] += 1
                    c['multi_image_with_subcaptions' if f['subfigs'] >= 2 else 'multi_image_no_subcaptions'] += 1
                else:
                    c['single_image'] += 1
                    c['single_image_caption_letters>=2' if f['letters'] >= 2 else 'single_image_no_letters'] += 1
    res = {'papers': papers, **c}
    res['share_multi_image'] = c['multi_image'] / max(1, c['figures'])
    res['share_single_image_lettered'] = c['single_image_caption_letters>=2'] / max(1, c['figures'])
    args.out.write_text(json.dumps(res, indent=1))
    print(json.dumps(res, indent=1))


if __name__ == '__main__':
    main()
