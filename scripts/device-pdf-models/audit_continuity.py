"""Find changed joins independently supported by an exact local HTML paragraph reference.

Usage: python3 audit_continuity.py DIFF.json REFERENCES.json OUTPUT.json
Matches ten prose words on each side in ONE source paragraph (letters joined so line hyphenation
does not prevent a match). Short, noisy, formula-only or unavailable references remain manual review.
This is deliberately not a score for all text or a substitute for inspecting the unmatched PDF boundaries.
"""
import json
import sys
from pathlib import Path


def audit(changes, references):
    refs = {p['paper']: p for p in references}
    out = []
    for paper in changes:
        r = refs[paper['paper']]
        before = {b['id']: b['words'] for b in r['before']}
        paragraphs = [(b['id'], ''.join(b['words'])) for b in r.get('reference', []) if b['kind'] == 'paragraph']
        for change in paper['changes']:
            for left, right in zip(change['fragments'], change['fragments'][1:]):
                lw, rw = before[left['id']][-10:], before[right['id']][:10]
                needle = ''.join(lw + rw)
                matches = [i for i, text in paragraphs if needle in text] if min(len(lw), len(rw)) >= 3 and min(len(''.join(lw)), len(''.join(rw))) >= 15 else []
                out.append({'paper': paper['paper'], 'left': left['id'], 'right': right['id'],
                            'pages': [left['places'][-1][0] + 1, right['places'][0][0] + 1],
                            'tail': left['text'][-220:], 'head': right['text'][:220], 'reference_matches': matches,
                            'status': 'source-supported' if matches else 'needs-review'})
    return out


if __name__ == '__main__':
    rows = audit(json.loads(Path(sys.argv[1]).read_text()), json.loads(Path(sys.argv[2]).read_text()))
    Path(sys.argv[3]).write_text(json.dumps(rows, ensure_ascii=False, indent=1) + '\n')
    print(len(rows), 'joins;', sum(r['status'] == 'source-supported' for r in rows), 'source-supported;', sum(r['status'] == 'needs-review' for r in rows), 'need PDF review')
