#!/usr/bin/env python3
"""Read-only index of figure environments in the owner's arXiv corpus.

Reads `<corpus>/<paper>/build/src` (already extracted by the owner's service) and
`abstract.html`; never writes under the corpus. One JSONL row per figure environment:
caption, panel markers in the caption, includes with resolved files, sub-figure macros.
Also writes per-paper author identities for family-disjoint splitting.
"""
import argparse, hashlib, html, json, multiprocessing as mp, os, re, sys
from pathlib import Path

EXTS = ['', '.pdf', '.png', '.jpg', '.jpeg', '.eps', '.PDF', '.PNG', '.JPG']
FIG_ENV = re.compile(r'\\begin\{(figure\*?|wrapfigure|SCfigure\*?|figure\*)\}(.*?)\\end\{\1\}', re.S)
SUB_MACROS = re.compile(r'\\(begin\{subfigure\}|subfloat|subfigure|subcaptionbox|sidesubfloat|begin\{subfloat\})')
INCLUDE = re.compile(r'\\includegraphics\s*(\[[^\]]*\])?\s*\{([^}]*)\}')
INPUT = re.compile(r'\\(?:input|include|subfile)\s*\{([^}]*)\}')
GPATH = re.compile(r'\\graphicspath\s*\{((?:\{[^}]*\}\s*)+)\}')
MARKER = re.compile(r'(?:\(|\b)([a-hA-H])\)|\(([a-hA-H])\)|\\textbf\{\(?([a-hA-H])\)?\}|\b([a-hA-H])\.\s')


def strip_comments(text):
    return re.sub(r'(?<!\\)%.*', '', text)


def balanced(text, start):
    """Return the content of the {...} group whose '{' is at text[start]."""
    depth = 0
    for i in range(start, min(len(text), start + 20000)):
        c = text[i]
        if c == '\\':
            continue
        if c == '{' and (i == 0 or text[i - 1] != '\\'):
            depth += 1
        elif c == '}' and text[i - 1] != '\\':
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return None


def caption_of(body):
    m = re.search(r'\\caption(?:of\{[^}]*\})?\s*(\[[^\]]*\])?\s*\{', body)
    if not m:
        return ''
    # Use the LAST \caption (subcaptions come first in subfigure layouts).
    last = None
    for m in re.finditer(r'\\caption\s*(\[[^\]]*\])?\s*\{', body):
        last = m
    got = balanced(body, last.end() - 1) if last else None
    return got or ''


def panel_letters(caption):
    letters = set()
    for m in re.finditer(r'\(([a-hA-H])\)', caption):
        letters.add(m.group(1).lower())
    for m in re.finditer(r'(?<![\w\\])([a-h])\)\s', caption):
        letters.add(m.group(1))
    for m in re.finditer(r'\\textbf\{\s*\(?([a-hA-H])\)?\s*[\.:]?\s*\}', caption):
        letters.add(m.group(1).lower())
    return sorted(letters)


def spatial_words(caption):
    return sorted(set(w.lower() for w in re.findall(
        r'\b(left|right|top|bottom|middle|upper|lower|row|column|panel|inset|first|second|third)\b', caption, re.I)))


def read_tex(root, name, seen, depth=0):
    if depth > 6:
        return ''
    cands = [name, name + '.tex'] if not name.endswith('.tex') else [name]
    for c in cands:
        p = (root / c)
        try:
            p = p.resolve()
        except OSError:
            continue
        if p in seen or not p.is_file() or not str(p).startswith(str(root.resolve())):
            continue
        seen.add(p)
        try:
            text = strip_comments(p.read_text(errors='replace'))
        except OSError:
            return ''
        return INPUT.sub(lambda m: read_tex(root, m.group(1).strip(), seen, depth + 1), text)
    return ''


def resolve(root, gpaths, name):
    name = name.strip().strip('"')
    for base in [''] + gpaths:
        for ext in EXTS:
            p = root / base / (name + ext)
            try:
                if p.is_file() and str(p.resolve()).startswith(str(root.resolve())):
                    return str(p.relative_to(root))
            except OSError:
                pass
    return None


def authors(abstract):
    try:
        text = abstract.read_text(errors='replace')
    except OSError:
        return []
    return [html.unescape(a).strip() for a in re.findall(r'<meta name="citation_author" content="([^"]*)"', text)]


def index_paper(paper_dir):
    paper_dir = Path(paper_dir)
    paper = paper_dir.name
    out = {'paper': paper, 'figures': [], 'authors': authors(paper_dir / 'abstract.html')}
    src = paper_dir / 'build' / 'src'
    meta = paper_dir / 'build' / 'source.json'
    if not src.is_dir():
        out['error'] = 'no_src'
        return out
    main = 'main.tex'
    try:
        main = json.loads(meta.read_text()).get('main_tex') or main
    except (OSError, ValueError):
        pass
    text = read_tex(src, main, set())
    if not text:
        out['error'] = 'no_tex'
        return out
    gpaths = []
    for m in GPATH.finditer(text):
        gpaths += re.findall(r'\{([^}]*)\}', m.group(1))
    for k, m in enumerate(FIG_ENV.finditer(text)):
        body = m.group(2)
        cap = caption_of(body)
        includes = []
        for im in INCLUDE.finditer(body):
            f = resolve(src, gpaths, im.group(2))
            includes.append({'name': im.group(2).strip(), 'file': f, 'options': (im.group(1) or '')[:120]})
        label = re.search(r'\\label\{([^}]*)\}', body)
        out['figures'].append({
            'paper': paper, 'index': k, 'env': m.group(1), 'label': label.group(1) if label else None,
            'caption': re.sub(r'\s+', ' ', cap)[:2000], 'caption_letters': panel_letters(cap),
            'caption_spatial': spatial_words(cap), 'includes': includes, 'n_includes': len(includes),
            'sub_macros': len(SUB_MACROS.findall(body)), 'tikz': '\\begin{tikzpicture}' in body,
            'minipage': '\\begin{minipage}' in body, 'tabular': '\\begin{tabular' in body,
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=24)
    args = ap.parse_args()
    dirs = sorted(str(p) for p in args.corpus.iterdir() if p.is_dir() and re.match(r'^\d{4}\.\d{4,5}v\d+$', p.name))
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    with mp.Pool(args.workers) as pool, (args.out / 'figures.jsonl').open('w') as ff, (args.out / 'papers.jsonl').open('w') as pf:
        for rec in pool.imap_unordered(index_paper, dirs, chunksize=16):
            for f in rec['figures']:
                ff.write(json.dumps(f) + '\n')
            pf.write(json.dumps({'paper': rec['paper'], 'authors': rec['authors'], 'figures': len(rec['figures']),
                                 'error': rec.get('error')}) + '\n')
            n += 1
            if n % 2000 == 0:
                print(n, flush=True)
    print('papers', n)


if __name__ == '__main__':
    main()
