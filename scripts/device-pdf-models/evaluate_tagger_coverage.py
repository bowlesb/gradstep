"""Offline comparison on identical complete labeled lines, using the existing desktop training corpus.

Run on the owner's GPU desktop. This imports its frozen training reader/architecture; it never trains or fetches.
Batch only equal-length sequences: a bidirectional GRU must not see padding absent from the device's prediction.
"""
import argparse
import hashlib
import importlib.util
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch


def windows(c, item, context, complete):
    start, end, kind, previous, following = map(int, c.items[item])
    own = np.arange(start, end)
    pre = np.arange(0, dtype=np.int64)
    post = np.arange(0, dtype=np.int64)
    if context and kind == 0:
        if previous >= 0:
            a, b = map(int, c.items[previous][:2]); pre = np.arange(max(a, b - context), b)
        if following >= 0:
            a, b = map(int, c.items[following][:2]); post = np.arange(a, min(b, a + context))
    if not complete or len(own) + len(pre) + len(post) <= 400:
        stop = min(len(own), 400 - len(pre) - len(post))
        yield np.concatenate([pre, own[:stop], post]), np.concatenate([np.ones(len(pre)), np.zeros(stop), np.full(len(post), 2)]).astype(np.int64), 0, stop
        return
    capacity = 400 - 2 * context
    for a in range(0, len(own), capacity):
        b = min(len(own), a + capacity)
        before = own[max(0, a - context):a] if a else pre
        after = own[b:b + context] if b < len(own) else post
        if not context and b - a == 1 and a:
            before = own[a - 1:a]
        idx = np.concatenate([before, own[a:b], after])
        flags = np.concatenate([np.ones(len(before)), np.zeros(b - a), np.full(len(after), 2)]).astype(np.int64)
        yield idx, flags, a, b


@torch.no_grad()
def predict(T, model, c, context, complete, device):
    groups = defaultdict(list)
    output = {i: np.zeros(int(row[1] - row[0]), np.float32) for i, row in enumerate(c.items)}
    covered = 0
    for item in range(len(c.items)):
        for idx, flags, a, b in windows(c, item, context, complete):
            if not len(idx):
                continue
            groups[len(idx)].append((item, idx, flags, a, b))
            covered += b - a
    for length, rows in sorted(groups.items()):
        batch = max(1, min(256, 32000 // length))
        for offset in range(0, len(rows), batch):
            chunk = rows[offset:offset + batch]
            features = [T.tensors(c, idx, flags, context) for _, idx, flags, _, _ in chunk]
            tensors = [torch.from_numpy(np.stack([f[k] for f in features])).to(device) for k in range(4)]
            probabilities = torch.sigmoid(model(*tensors)).float().cpu().numpy()
            for row, (item, _, flags, a, b) in enumerate(chunk):
                output[item][a:b] = probabilities[row][flags == 0]
    return output, covered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--training-root', type=Path, required=True)
    parser.add_argument('--v4', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--split', choices=['dev', 'test'], default='test')
    parser.add_argument('--device', default='cuda')
    parser.add_argument('--skip-prototype', action='store_true')
    parser.add_argument('--thresholds', default='')
    parser.add_argument('--candidate-threshold', type=float)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('tagger_training', args.training_root / 'train.py')
    T = importlib.util.module_from_spec(spec); spec.loader.exec_module(T)
    torch.set_num_threads(4)
    torch.manual_seed(0)
    splits = json.loads((args.training_root / 'papers.json').read_text())
    ids = [p for p in splits[args.split] if (T.DATA / f'{p}.npz').is_file()]
    c = T.Corpus(ids)
    result = {'split': args.split, 'papers': ids, 'items': len(c.items), 'glyphs': int(len(c.y)), 'rows': {},
              'training_source_sha256': hashlib.sha256((args.training_root / 'train.py').read_bytes()).hexdigest(),
              'data_sha256': {p: hashlib.sha256((T.DATA / f'{p}.npz').read_bytes()).hexdigest() for p in ids}}
    for name, checkpoint, complete in [('v4_shipped', args.v4, False), ('v5a_prototype', args.candidate, False), ('v5a_complete', args.candidate, True)]:
        if args.skip_prototype and name == 'v5a_prototype':
            continue
        ck = torch.load(checkpoint, map_location='cpu', weights_only=False)
        context = int(ck.get('context', 0))
        model = T.Tagger(12 if context else 10, ck.get('hidden', 96))
        model.load_state_dict(ck['model']); model.eval().to(args.device)
        c.encode(ck['vocab'], ck['prior'], ck['cvocab'])
        predictions, covered = predict(T, model, c, context, complete, args.device)
        threshold = 0.7 if name == 'v4_shipped' else args.candidate_threshold or float(ck['threshold'])
        row = {'threshold': threshold, 'context': context, 'covered_glyphs': covered,
               'dropped_glyphs': int(len(c.y) - covered), 'checkpoint_sha256': hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
               **{kind: T.score(c, predictions, threshold, kinds) for kind, kinds in [('all', None), ('text', {0}), ('rows', {1}), ('cells', {2})]}}
        result['rows'][name] = row
        if name == 'v5a_complete' and args.thresholds:
            result['development_thresholds'] = {value: {kind: T.score(c, predictions, float(value), kinds)
                for kind, kinds in [('all', None), ('text', {0}), ('rows', {1}), ('cells', {2})]} for value in args.thresholds.split(',')}
        print(json.dumps({name: row}), flush=True)
        del model
    baseline = result['rows']['v4_shipped']['all']['errors']
    candidate = result['rows']['v5a_complete']['all']['errors']
    cut = lambda counts: sum(counts.get(k, 0) for k in ['cut', 'cut@edge', 'split'])
    result['cut_split'] = {'before': cut(baseline), 'after': cut(candidate), 'reduction': 1 - cut(candidate) / max(1, cut(baseline))}
    assert len({r['all']['gold'] for r in result['rows'].values()}) == 1, 'Unequal gold denominators'
    assert result['rows']['v5a_complete']['dropped_glyphs'] == 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['cut_split']), flush=True)


if __name__ == '__main__':
    main()
