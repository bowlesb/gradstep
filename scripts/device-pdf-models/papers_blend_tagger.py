"""Conservatively interpolate a fine-tuned tagger with its frozen parent; select on development only."""
import argparse, hashlib
from pathlib import Path
import torch

p = argparse.ArgumentParser()
p.add_argument('base', type=Path)
p.add_argument('adapted', type=Path)
p.add_argument('out', type=Path)
p.add_argument('--weight', type=float, required=True)
a = p.parse_args()
assert 0 < a.weight < 1
base = torch.load(a.base, map_location='cpu', weights_only=False)
adapted = torch.load(a.adapted, map_location='cpu', weights_only=False)
for key in ['vocab', 'cvocab', 'prior', 'hidden', 'context', 'n_feats']:
    assert base[key] == adapted[key], key
assert base['model'].keys() == adapted['model'].keys()
model = {k: torch.lerp(base['model'][k], adapted['model'][k], a.weight) for k in base['model']}
torch.save({**adapted, 'model': model, 'interpolation': {
    'base_sha256': hashlib.sha256(a.base.read_bytes()).hexdigest(),
    'adapted_sha256': hashlib.sha256(a.adapted.read_bytes()).hexdigest(),
    'adapted_weight': a.weight,
}}, a.out)
