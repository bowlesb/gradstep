"""Export a frozen journal-adapted checkpoint in the existing device tagger interface.

The vocabulary and architecture remain the reference model's. Export validation must
use actual Core ML predictions on the Mac; conversion succeeding alone is insufficient.
"""
import argparse, hashlib, importlib.util, json
from pathlib import Path
import numpy as np
import torch
import coremltools as ct

p = argparse.ArgumentParser()
p.add_argument('--training-source', type=Path, required=True)
p.add_argument('--checkpoint', type=Path, required=True)
p.add_argument('--vocab', type=Path, required=True)
p.add_argument('--threshold', type=float, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
assert 0 < a.threshold < 1
a.out.mkdir(parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location('reference_tagger', a.training_source)
T = importlib.util.module_from_spec(spec)
spec.loader.exec_module(T)
ck = torch.load(a.checkpoint, map_location='cpu', weights_only=False)
model = T.Tagger(ck['n_feats'], ck['hidden'])
model.load_state_dict(ck['model'])
model.eval()
vocab = json.loads(a.vocab.read_text())
assert vocab['font_vocab'] == ck['vocab']
assert vocab['char_vocab'] == {str(k): v for k, v in ck['cvocab'].items()}
assert vocab['font_prior'] == ck['prior']
assert vocab['context'] == ck['context'] and len(vocab['features']) == ck['n_feats']
vocab['threshold'] = a.threshold
dim = ct.RangeDim(lower_bound=2, upper_bound=vocab['max_len'], default=64)
example = (torch.zeros(1, 64, ck['n_feats']), *(torch.zeros(1, 64, dtype=torch.int64) for _ in range(3)))
with torch.no_grad():
    traced = torch.jit.trace(model, example)
ml = ct.convert(traced, inputs=[
    ct.TensorType(name='x', shape=(1, dim, ck['n_feats']), dtype=np.float32),
    *[ct.TensorType(name=name, shape=(1, dim), dtype=np.int32) for name in ['font', 'cls', 'char']]],
    outputs=[ct.TensorType(name='logits')], convert_to='mlprogram',
    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS18)
ml.save(str(a.out/'tagger.mlpackage'))
(a.out/'vocab.json').write_text(json.dumps(vocab, indent=1)+'\n')
metadata = {'kind': 'inline-tagger', 'checkpoint_sha256': hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),
            'training_source_sha256': hashlib.sha256(a.training_source.read_bytes()).hexdigest(),
            'threshold': a.threshold, 'context': ck['context'], 'features': ck['n_feats'], 'hidden': ck['hidden'],
            'torch_version': torch.__version__, 'coremltools_version': ct.__version__,
            'precision': 'float16', 'deployment_target': 'iOS18', 'max_len': vocab['max_len'],
            'validation': 'Not validated by this export; requires actual Core ML parity and native conversion.'}
(a.out/'export.json').write_text(json.dumps(metadata, indent=2)+'\n')
print(json.dumps(metadata))
