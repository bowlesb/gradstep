#!/usr/bin/env python3
"""Paper allow-list for a fresh final test (2026-10-22).

Recomputes the author/family components of split.py and keeps test-pool papers whose whole component has
never been used: no paper of the component appears in the 10-21 final test or validation sets (or any training
row). Writes one paper id per line.
"""
import argparse, collections, json
from pathlib import Path

from sfd.mine import split as SP


def components(papers):
    parent = {p['paper']: p['paper'] for p in papers}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    by_key = collections.defaultdict(list)
    for p in papers:
        a = [x for x in (SP.norm(n) for n in p['authors']) if x]
        keys = {'family:' + p['paper'].rsplit('v', 1)[0]}
        if a:
            keys |= {'any:' + a[0], 'any:' + a[-1]}
        for k in keys:
            by_key[k].append(p['paper'])
    for k, ps in by_key.items():
        if len(ps) > 30 and not k.startswith('family:'):
            continue
        for q in ps[1:]:
            ra, rb = find(ps[0]), find(q)
            if ra != rb:
                parent[max(ra, rb)] = min(ra, rb)
    comp = collections.defaultdict(set)
    for p in parent:
        comp[find(p)].add(p)
    return {p: comp[find(p)] for p in parent}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--papers', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--used', type=Path, nargs='+', required=True, help='GT/row JSONL files whose papers are spent')
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    papers = [json.loads(l) for l in args.papers.read_text().splitlines()]
    split = json.loads(args.split.read_text())['split']
    comp = components(papers)
    used = set()
    for f in args.used:
        for l in f.read_text().splitlines():
            if l.strip():
                used.add(json.loads(l)['paper'])
    keep = sorted(p for p in comp if split.get(p) == 'test' and not (comp[p] & used))
    args.out.write_text('\n'.join(keep) + '\n')
    print(json.dumps({'test_pool': sum(1 for p in comp if split.get(p) == 'test'), 'spent_papers': len(used), 'fresh': len(keep)}))


if __name__ == '__main__':
    main()
