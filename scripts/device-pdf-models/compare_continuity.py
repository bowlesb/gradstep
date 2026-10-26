"""Compare recorded reader runs by source places, independent of changing block IDs/alignment scores.

Freezes the baseline boundaries: a split is fixed only when BOTH original source fragments are in
one candidate paragraph. Newly joined unrelated text cannot make the denominator disappear.
Every changed paragraph is emitted for adjudication. Other content, formula readings and all source
places must be conserved. Replays must separately have zero missing tagger/crop answers.
Usage: python3 compare_continuity.py BEFORE AFTER OUTPUT.json [FROZEN_CORPUS.json or BASELINE_QUALITY.json]
"""
import collections
import json
import re
import sys
import unicodedata
from pathlib import Path


def load(path):
    index = json.loads((path / 'reader.json').read_text())
    places = collections.defaultdict(list)
    for block, *place in json.loads((path / 'provenance.json').read_text())['blocks']:
        places[block].append(tuple(place))
    return index, places


def letters(text):
    # Only whitespace and a line-end hyphen may change at a join. A retained compound hyphen is fine too.
    return ' '.join(unicodedata.normalize('NFC', text).split())


def compare(before, after, baseline_quality=None):
    frozen = baseline_quality if isinstance(baseline_quality, dict) else None
    if frozen and frozen.get('format') != 'device-pdf-continuity-corpus-v1':
        raise ValueError('unsupported frozen corpus format')
    quality = {p['paper']: p for p in baseline_quality or []} if not frozen else {}
    pinned = {p['key']: p for p in frozen['papers']} if frozen else {}
    result = []
    for paper in pinned:
        if not (before / paper / 'reader.json').exists():
            result.append({'paper': paper, 'changes': [], 'new_joins': 0, 'errors': [{'kind': 'missing_baseline'}], 'baseline_boundaries': []})
    for path in sorted(before.iterdir()):
        if not (path / 'reader.json').exists():
            continue
        if not (after / path.name / 'reader.json').exists():
            result.append({'paper': path.name, 'changes': [], 'new_joins': 0, 'errors': [{'kind': 'missing_candidate'}], 'baseline_boundaries': []})
            continue
        old, old_places = load(path)
        new, new_places = load(after / path.name)
        changed, errors, old_to_new = [], [], collections.defaultdict(set)
        # Several emitted reference entries can share one layout region. Match unchanged paragraphs
        # by text AND places first, rather than interpreting every shared rectangle as a merge.
        exact = collections.defaultdict(list)
        for block in old['blocks']:
            if block['kind'] == 'paragraph':
                exact[(block['text'], tuple(old_places[block['id']]))].append(block['id'])
        unchanged = set()
        for block in new['blocks']:
            if block['kind'] != 'paragraph':
                continue
            matches = exact[(block['text'], tuple(new_places[block['id']]))]
            if matches:
                old_to_new[matches.pop(0)].add(block['id'])
                unchanged.add(block['id'])
        source = collections.defaultdict(set)
        for block in old['blocks']:
            if block['kind'] == 'paragraph' and not old_to_new[block['id']]:
                for place in old_places[block['id']]:
                    source[place].add(block['id'])
        for block in new['blocks']:
            if block['kind'] != 'paragraph' or block['id'] in unchanged:
                continue
            ids = set().union(*(source[p] for p in new_places[block['id']]))
            for i in ids:
                old_to_new[i].add(block['id'])
            fragments = [b for b in old['blocks'] if b['id'] in ids]
            if not fragments:
                # Unplaced synthetic paragraphs were matched exactly above, including multiplicity.
                # Any remaining paragraph is new content, even if it duplicates an existing one.
                errors.append({'kind': 'unmatched_paragraph', 'id': block['id']})
                continue
            expected = ' '.join(b['text'] for b in fragments)
            if letters(expected) != letters(block['text']):
                # Allow only removing a hyphen at a newly joined boundary, not arbitrary lost characters.
                candidates = {fragments[0]['text']}
                for b in fragments[1:]:
                    more = {t + ' ' + b['text'] for t in candidates}
                    more.update(t[:-1] + b['text'] for t in candidates if t.endswith('-') and b['text'][:1].islower())
                    more.update(t + b['text'] for t in candidates if t.endswith('-') and b['text'][:1].islower())
                    candidates = more
                if letters(block['text']) not in {letters(t) for t in candidates}:
                    errors.append({'kind': 'text_changed', 'id': block['id'], 'sources': [b['id'] for b in fragments]})
            if collections.Counter(new_places[block['id']]) != collections.Counter(p for b in fragments for p in old_places[b['id']]):
                errors.append({'kind': 'places_changed', 'id': block['id']})
            if len(fragments) > 1:
                changed.append({'id': block['id'], 'fragments': [{'id': b['id'], 'text': b['text'], 'places': old_places[b['id']]} for b in fragments],
                                'text': block['text']})
        for block in old['blocks']:
            if block['kind'] == 'paragraph' and len(old_to_new[block['id']]) != 1:
                errors.append({'kind': 'lost_or_split_paragraph', 'id': block['id']})
        for field in ['blocks', 'equations', 'figures']:
            def canonical(index):
                rows = [{k: v for k, v in row.items() if k not in ['id', 'block_id', 'asset_paths']}
                        for row in index[field] if field != 'blocks' or row['kind'] != 'paragraph']
                # Inline formulas can move within this list when their open paragraph is committed.
                # Their content and multiplicity must stay, as must the order of all nonparagraph blocks.
                return sorted(json.dumps(row, sort_keys=True) for row in rows) if field == 'equations' else rows
            if canonical(old) != canonical(new):
                errors.append({'kind': 'nonparagraph_content_changed', 'field': field})
        # All source places, including headings, figures, tables and formulas, remain (IDs may change).
        if collections.Counter(p for ps in old_places.values() for p in ps) != collections.Counter(p for ps in new_places.values() for p in ps):
            errors.append({'kind': 'document_places_changed'})
        old_prov = json.loads((path / 'provenance.json').read_text())
        new_prov = json.loads((after / path.name / 'provenance.json').read_text())
        for field in ['equations', 'figures']:
            if collections.Counter(tuple(row[1:]) for row in old_prov[field]) != collections.Counter(tuple(row[1:]) for row in new_prov[field]):
                errors.append({'kind': 'source_regions_or_gates_changed', 'field': field})
        boundaries = []
        if path.name in pinned:
            digest = pinned[path.name]['paper.pdf_sha256']
            if old_prov['source']['pdf_sha256'] != digest or new_prov['source']['pdf_sha256'] != digest:
                errors.append({'kind': 'frozen_pdf_mismatch'})
            for label in frozen['boundaries']:
                if label['paper'] != path.name:
                    continue
                left, right = label['left_block'], label['right_block']
                if old_places[left] != [tuple(p) for p in label['left_places']] or old_places[right] != [tuple(p) for p in label['right_places']]:
                    errors.append({'kind': 'frozen_boundary_mismatch', 'left': left, 'right': right})
                boundaries.append({'left': left, 'right': right, 'reference': label['jats_paragraph'], 'mid_sentence': True,
                                   'fixed': bool(old_to_new[left] & old_to_new[right])})
        for split in quality.get(path.name, {}).get('cross_page_splits', []):
            mid_sentence = split['reference_word_gap'] <= 3 and not re.search(r'[.!?][”’\x22\x27)\]]*$', split['left']['text'].rstrip())
            fixed = bool(old_to_new[split['left']['id']] & old_to_new[split['right']['id']])
            boundaries.append({'left': split['left']['id'], 'right': split['right']['id'], 'reference': split['reference'],
                               'mid_sentence': mid_sentence, 'fixed': fixed})
        result.append({'paper': path.name, 'changes': changed, 'new_joins': sum(len(c['fragments']) - 1 for c in changed),
                       'errors': errors, 'baseline_boundaries': boundaries})
    return result


if __name__ == '__main__':
    q = json.loads(Path(sys.argv[4]).read_text()) if len(sys.argv) > 4 else None
    result = compare(Path(sys.argv[1]), Path(sys.argv[2]), q)
    Path(sys.argv[3]).write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n')
    for p in result:
        mid = [b for b in p['baseline_boundaries'] if b['mid_sentence']]
        print(p['paper'], 'joins', p['new_joins'], 'errors', len(p['errors']), 'mid-sentence fixed', sum(b['fixed'] for b in mid), '/', len(mid))
    if any(p['errors'] for p in result):
        sys.exit(1)
