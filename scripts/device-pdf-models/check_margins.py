"""Gate margin removal against PDF-reviewed, source-pinned baseline spans.

Only labeled text may disappear. Every other paragraph must survive verbatim or as an ordered
concatenation (with optional line-end dehyphenation); every nonparagraph block stays in order.
This is content conservation, not an automatic judgment that a new paragraph join is correct.
Usage: python3 check_margins.py BEFORE AFTER FIXTURE.json SPLIT OUTPUT.json
"""
import collections
import json
import sys
import unicodedata
from pathlib import Path


def compact(text):
    return ''.join(unicodedata.normalize('NFC', text).split())


def check(before, after, fixture, split):
    assert fixture['format'] == 'device-pdf-margin-corpus-v1'
    cases = {c['paper']: c for c in [fixture, *fixture.get('regression_papers', [])] if c['split'] == split}
    for key in cases:
        assert (before / key / 'reader.json').exists(), f'{key}: missing pinned baseline'
    rows = []
    for path in sorted(before.iterdir()):
        if not (path / 'reader.json').exists():
            continue
        dest = after / path.name
        old = json.loads((path / 'reader.json').read_text())
        new = json.loads((dest / 'reader.json').read_text())  # Missing candidates fail closed.
        op = json.loads((path / 'provenance.json').read_text())
        np = json.loads((dest / 'provenance.json').read_text())
        assert op['source'] == np['source'], f'{path.name}: source changed'
        if path.name not in cases:
            assert old == new and {k: v for k, v in op.items() if k != 'adapter'} == {k: v for k, v in np.items() if k != 'adapter'}, f'{path.name}: unreviewed output change'
            rows.append({'paper': path.name, 'unchanged': True})
            continue
        case = cases[path.name]
        assert op['source']['pdf_sha256'] == case['pdf_sha256'], f'{path.name}: wrong PDF'
        places = collections.defaultdict(list)
        for bid, *place in op['blocks']:
            places[bid].append(place)
        labels = collections.defaultdict(list)
        blocks = {b['id']: b for b in old['blocks']}
        for label in case['labels']:
            b = blocks[label['block']]
            start, end = label['offset']
            assert b['text'][start:end] == label['text'] and b['kind'] == label['kind'], 'stale text label'
            assert places[b['id']] == label['places'], 'stale source label'
            labels[b['id']].append(label)
        expected = []
        for b in old['blocks']:
            text = b['text']
            last = len(text)
            for label in sorted(labels[b['id']], key=lambda l: l['offset'][0], reverse=True):
                start, end = label['offset']
                assert end <= last, 'overlapping removal labels'
                text = text[:start] + text[end:]; last = start
            if not labels[b['id']] or compact(text):
                expected.append({**b, 'text': text})
        # First consume exact paragraphs, including duplicate texts with their multiplicity.
        pending = [b for b in expected if b['kind'] == 'paragraph']
        joined = []
        remaining = []
        sources = {}
        for b in new['blocks']:
            if b['kind'] != 'paragraph':
                continue
            match = next((i for i, old_b in enumerate(pending) if compact(old_b['text']) == compact(b['text'])), None)
            if match is not None:
                sources[b['id']] = [pending[match]['id']]
                pending.pop(match)
            else:
                remaining.append(b)
        for b in remaining:
            target = compact(b['text'])

            def find(offset=0, start=0):
                if offset == len(target):
                    return []
                for i in range(start, len(pending)):
                    text = compact(pending[i]['text'])
                    variants = [text]
                    if text.endswith('-') and pending[i]['text'][-2:-1].isalpha():
                        variants.append(text[:-1])
                    for variant in variants:
                        if variant and target.startswith(variant, offset):
                            rest = find(offset + len(variant), i + 1)
                            if rest is not None:
                                return [i, *rest]
                return None

            matched = find()
            assert matched is not None, f"{path.name}: unmatched paragraph {b['id']}: {b['text'][:100]}"
            sources[b['id']] = [pending[i]['id'] for i in matched]
            joined.append({'new': b['id'], 'old': [pending[i]['id'] for i in matched], 'text': b['text']})
            for i in reversed(matched):
                pending.pop(i)
        assert not pending, f'{path.name}: lost paragraphs {[b["id"] for b in pending]}'

        def nonparagraphs(bs):
            return [{k: compact(v) if k == 'text' else v for k, v in b.items() if k != 'id'} for b in bs if b['kind'] != 'paragraph']

        assert nonparagraphs(expected) == nonparagraphs(new['blocks']), f'{path.name}: nonparagraph content/order changed'
        for old_b, new_b in zip([b for b in expected if b['kind'] != 'paragraph'], [b for b in new['blocks'] if b['kind'] != 'paragraph']):
            sources[new_b['id']] = [old_b['id']]
        for field in ['equations', 'figures']:
            def content(r):
                return sorted(json.dumps({k: v for k, v in b.items() if k not in ['block_id', 'asset_paths'] and (field != 'figures' or k != 'id')}, sort_keys=True) for b in r[field])
            assert content(old) == content(new), f'{path.name}: changed {field}'
            assert collections.Counter(tuple(r[1:]) for r in op[field]) == collections.Counter(tuple(r[1:]) for r in np[field]), f'{path.name}: changed {field} regions/gates'
        # Removing a header from a shared box can shrink the body box, never move it to another page.
        def contains(a, b):
            return a[0] == b[0] and a[1] - .11 <= b[1] and a[2] - .11 <= b[2] and a[3] + .11 >= b[3] and a[4] + .11 >= b[4]
        assert all(any(contains(a, r[1:]) for bid in sources.get(r[0], []) for a in places[bid]) for r in np['blocks']), f'{path.name}: source region no longer belongs to its text'
        removed_headings = sum(l['kind'] == 'heading' for l in case['labels'])
        assert sum(b['kind'] == 'heading' for b in old['blocks']) - sum(b['kind'] == 'heading' for b in new['blocks']) == removed_headings
        rows.append({'paper': path.name, 'unchanged': False, 'removed_spans': len(case['labels']), 'removed_false_headings': removed_headings,
                     'joined_paragraphs': joined, 'new_joins': sum(len(j['old']) - 1 for j in joined)})
    return rows


if __name__ == '__main__':
    rows = check(Path(sys.argv[1]), Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text()), sys.argv[4])
    Path(sys.argv[5]).write_text(json.dumps(rows, ensure_ascii=False, indent=1) + '\n')
    print(json.dumps({'papers': len(rows), 'unchanged': sum(r['unchanged'] for r in rows),
                      'removed_spans': sum(r.get('removed_spans', 0) for r in rows), 'new_joins': sum(r.get('new_joins', 0) for r in rows)}))
