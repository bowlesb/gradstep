"""Diagnose paragraph continuity against version-pinned, local publisher JATS references.

This is an alignment aid, not a claim of reading accuracy. Report candidates for PDF adjudication;
publisher-only supplements, layout differences and noisy PDF text are not automatically reader errors.
Usage: python3 publisher_quality.py CORPUS RUN OUTPUT.json
"""
import collections
import difflib
import json
import re
import sys
import unicodedata
from pathlib import Path


def tokens(text):
    text = unicodedata.normalize('NFKC', text).lower().replace('\u00ad', '')
    return re.findall(r'[^\W_]+', text, re.UNICODE)


def align(block, references):
    words = tokens(block['text'])
    if len(words) < 12:
        return None
    bag = collections.Counter(words)
    candidates = sorted(((sum((bag & collections.Counter(ref)).values()), i) for i, ref in enumerate(references)), reverse=True)[:4]
    best = None
    for overlap, i in candidates:
        if overlap / len(words) < .8:
            continue
        matches = difflib.SequenceMatcher(None, words, references[i], autojunk=False).get_matching_blocks()[:-1]
        coverage = sum(m.size for m in matches) / len(words)
        if coverage >= .9 and (best is None or coverage > best['coverage']):
            best = {'reference': i, 'coverage': coverage, 'start': matches[0].b, 'end': matches[-1].b + matches[-1].size,
                    'matched': sorted({j for m in matches for j in range(m.b, m.b + m.size)}), 'words': len(words)}
    return best


def diagnose(corpus, run):
    result = []
    for path in sorted(corpus.glob('*/reference.json')):
        paper = path.parent.name
        reference = json.loads(path.read_text())
        meta = json.loads((path.parent / 'meta.json').read_text())
        # provenance.json uses emitted reader IDs; index.json is a diagnostic trace with different
        # IDs after expanded reference lists or omitted floats. Never join it to reader provenance.
        index = json.loads((run / paper / 'reader.json').read_text())
        provenance = json.loads((run / paper / 'provenance.json').read_text())
        places = collections.defaultdict(list)
        for row in provenance['blocks']:
            places[row[0]].append(row[1:])
        refs = [tokens(p['text']) for p in reference['paragraphs']]
        matched = []
        for i, block in enumerate(index['blocks']):
            if block['kind'] != 'paragraph':
                continue
            match = align(block, refs)
            if match:
                matched.append({**match, 'block': i, 'id': block['id'], 'places': places[block['id']], 'text': block['text']})
        splits = []
        for left, right in zip(matched, matched[1:]):
            if left['reference'] != right['reference'] or right['start'] < left['end'] - 3:
                continue
            if not left['places'] or not right['places']:
                continue
            gap = min(p[0] for p in right['places']) - max(p[0] for p in left['places'])
            if gap < 1:
                continue
            splits.append({'reference': reference['paragraphs'][left['reference']]['id'], 'page_gap': gap,
                           'reference_word_gap': right['start'] - left['end'],
                           'between': [{'kind': b['kind'], 'text': b['text'][:160]} for b in index['blocks'][left['block'] + 1:right['block']]],
                           'left': {k: v for k, v in left.items() if k != 'matched'},
                           'right': {k: v for k, v in right.items() if k != 'matched'}})
        by_ref = collections.defaultdict(list)
        for m in matched:
            by_ref[m['reference']].append(m)
        coverage = [{'id': reference['paragraphs'][i]['id'], 'words': len(ref), 'matched_blocks': len(by_ref[i]),
                     'word_recall': len({j for m in by_ref[i] for j in m['matched']}) / max(1, len(ref))}
                    for i, ref in enumerate(refs)]
        result.append({'paper': paper, 'split': meta.get('split'), 'paragraphs': len(refs), 'aligned_blocks': len(matched),
                       'cross_page_splits': splits, 'coverage': coverage, 'alignments': matched})
    return result


if __name__ == '__main__':
    result = diagnose(Path(sys.argv[1]), Path(sys.argv[2]))
    Path(sys.argv[3]).write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n')
    for p in result:
        print(p['paper'], p['split'], 'aligned', p['aligned_blocks'], 'cross-page split candidates', len(p['cross_page_splits']))
