#!/usr/bin/env python3
"""Family-disjoint paper split for the arXiv corpus.

Papers sharing a first or last author (normalized initial + surname) or an arXiv family are
joined (union-find). Each component goes wholly to train / validation / test by a salted hash.
Components containing papers used earlier (prior training or validation) never enter the new
test; prior-validation components are excluded from new training.
"""
import argparse, collections, hashlib, json, re, unicodedata
from pathlib import Path

SALT = 'subfigure-detector-20261021'


def norm(name):
    name = unicodedata.normalize('NFKD', name).encode('ascii', 'ignore').decode().lower()
    if ',' in name:
        last, first = [x.strip() for x in name.split(',', 1)]
    else:
        parts = name.split()
        if not parts:
            return None
        last, first = parts[-1], ' '.join(parts[:-1])
    last = re.sub(r'[^a-z]', '', last)
    first = first.split()[0] if first.split() else ''
    first = re.sub(r'[^a-z]', '', first)
    return f'{first}.{last}' if last and first else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--papers', type=Path, required=True)
    ap.add_argument('--prior', type=Path, nargs='*', default=[], help='prior manifests (jsonl) of arXiv rows')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--test', type=float, default=0.08)
    ap.add_argument('--val', type=float, default=0.08)
    args = ap.parse_args()
    papers = [json.loads(l) for l in args.papers.read_text().splitlines()]
    parent = {p['paper']: p['paper'] for p in papers}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def join(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    by_key = collections.defaultdict(list)
    for p in papers:
        a = [norm(x) for x in p['authors']]
        a = [x for x in a if x]
        keys = set()
        if a:
            keys.add('first:' + a[0]); keys.add('last:' + a[-1])
            keys.add('any:' + a[0]); keys.add('any:' + a[-1])
        keys.add('family:' + p['paper'].rsplit('v', 1)[0])
        for k in keys:
            by_key[k.replace('first:', 'any:').replace('last:', 'any:')].append(p['paper'])
    ambiguous = 0
    for k, ps in by_key.items():
        if len(ps) > 30 and not k.startswith('family:'):
            ambiguous += 1  # very common full names join unrelated people; do not link on them
            continue
        for q in ps[1:]:
            join(ps[0], q)
    prior_train, prior_val = set(), set()
    for f in args.prior:
        for line in f.read_text().splitlines():
            r = json.loads(line)
            pid = r.get('paper', '').replace('arxiv:', '')
            fam = [p for p in parent if p.rsplit('v', 1)[0] == pid or p == pid]
            for q in fam:
                (prior_val if 'validation' in f.name else prior_train).add(q)
    comps = collections.defaultdict(list)
    for p in parent:
        comps[find(p)].append(p)
    sizes = sorted((len(v) for v in comps.values()), reverse=True)
    split = {}
    for root, members in comps.items():
        ms = set(members)
        h = int(hashlib.sha256((SALT + root).encode()).hexdigest()[:12], 16) / 16 ** 12
        if ms & prior_val:
            s = 'prior_validation'
        elif ms & prior_train:
            s = 'train'
        elif len(members) > 40:
            s = 'train'  # very large author components stay in training
        elif h < args.test:
            s = 'test'
        elif h < args.test + args.val:
            s = 'validation'
        else:
            s = 'train'
        for m in members:
            split[m] = s
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'paper-split.json').write_text(json.dumps({'salt': SALT, 'split': split}, indent=0))
    summary = {'components': len(comps), 'largest_components': sizes[:10],
               'counts': collections.Counter(split.values()), 'prior_train_papers': len(prior_train),
               'prior_validation_papers': len(prior_val), 'ambiguous_name_keys_not_linked': ambiguous}
    (args.out / 'paper-split-summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
