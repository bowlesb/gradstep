"""Export pinned tagger weights for the independent on-device CPU reference.

This reads a trusted local PyTorch checkpoint only after verifying its expected
SHA256. No weights, threshold or vocabulary are trained or changed. The binary
contains little-endian float32 tensors in C order; manifest offsets count floats,
not bytes. Actual Swift/PyTorch parity is a separate acceptance gate.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def expected_shapes(n_features, hidden):
    if n_features not in (10, 12) or not 1 <= hidden <= 256:
        raise ValueError('unsupported tagger dimensions')
    shapes = {'font.weight': [256, 24], 'cls.weight': [10, 8], 'ch.weight': [512, 16],
              'inp.weight': [hidden, n_features + 48], 'inp.bias': [hidden],
              'out.weight': [1, 2 * hidden], 'out.bias': [1]}
    for layer in range(2):
        for suffix in ('', '_reverse'):
            key = f'l{layer}{suffix}'
            shapes[f'gru.weight_ih_{key}'] = [3 * hidden, hidden if layer == 0 else 2 * hidden]
            shapes[f'gru.weight_hh_{key}'] = [3 * hidden, hidden]
            shapes[f'gru.bias_ih_{key}'] = [3 * hidden]
            shapes[f'gru.bias_hh_{key}'] = [3 * hidden]
    return shapes


def encode_weights(state, n_features, hidden):
    """Reject changed architectures, extra tensors, non-float32 or nonfinite weights."""
    shapes = expected_shapes(n_features, hidden)
    if set(state) != set(shapes):
        raise ValueError('checkpoint tensor names do not match the reference architecture')
    chunks, tensors, offset = [], {}, 0
    for name in sorted(shapes):
        tensor = state[name]
        if not isinstance(tensor, torch.Tensor) or tensor.dtype != torch.float32 or tensor.layout != torch.strided:
            raise ValueError(f'{name}: expected dense float32 tensor')
        if list(tensor.shape) != shapes[name] or not torch.isfinite(tensor).all().item():
            raise ValueError(f'{name}: invalid shape or nonfinite weight')
        array = tensor.detach().cpu().contiguous().numpy().astype('<f4', copy=False)
        chunk = array.tobytes(order='C')
        count = int(array.size)
        if len(chunk) != count * 4:
            raise ValueError('float32 serialization size mismatch')
        tensors[name] = {'shape': shapes[name], 'offset': offset, 'count': count}
        chunks.append(chunk)
        offset += count
    return b''.join(chunks), tensors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--checkpoint-sha256', required=True, help='Expected hash of this trusted checkpoint; checked before deserialization')
    parser.add_argument('--vocab', type=Path, required=True, help='Exact bytes used by the app, not a differently formatted equivalent')
    parser.add_argument('--vocabulary-sha256', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    for path, expected in [(args.checkpoint, args.checkpoint_sha256), (args.vocab, args.vocabulary_sha256)]:
        if len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected) or sha256(path) != expected:
            raise ValueError(f'pinned input hash mismatch: {path}')
    if args.out.exists():
        raise FileExistsError(args.out)
    # Only owner-pinned, trusted training checkpoints are accepted by this workflow.
    checkpoint = torch.load(args.checkpoint, map_location='cpu', weights_only=False)
    vocab = json.loads(args.vocab.read_text())
    n_features, hidden = checkpoint['n_feats'], checkpoint['hidden']
    if (vocab['font_vocab'] != checkpoint['vocab'] or
        vocab['char_vocab'] != {str(k): v for k, v in checkpoint['cvocab'].items()} or
        vocab['font_prior'] != checkpoint['prior'] or vocab['context'] != checkpoint['context'] or
        len(vocab['features']) != n_features or vocab['max_len'] != 400):
        raise ValueError('vocabulary does not match the frozen checkpoint')
    binary, tensors = encode_weights(checkpoint['model'], n_features, hidden)
    manifest = {'format': 'device-pdf-tagger-reference-v1', 'n_features': n_features, 'hidden': hidden,
                'max_len': vocab['max_len'], 'context': checkpoint['context'],
                'checkpoint_sha256': args.checkpoint_sha256, 'vocabulary_sha256': args.vocabulary_sha256,
                'binary_sha256': hashlib.sha256(binary).hexdigest(), 'binary_file': 'tagger-reference.bin',
                'byte_order': 'little', 'scalar_type': 'float32', 'offset_unit': 'float32_elements',
                'gru_gate_order': ['reset', 'update', 'new'], 'tensors': tensors,
                'exporter_sha256': sha256(__file__), 'torch_version': torch.__version__,
                'numpy_version': np.__version__,
                'validation': 'Weights exported unchanged; requires independent native parity before use.'}
    args.out.mkdir(parents=True)
    (args.out / 'tagger-reference.bin').write_bytes(binary)
    (args.out / 'tagger-reference.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'manifest_sha256': sha256(args.out / 'tagger-reference.json'),
                      'binary_sha256': manifest['binary_sha256'], 'binary_bytes': len(binary),
                      'tensors': len(tensors), 'checkpoint_sha256': args.checkpoint_sha256,
                      'vocabulary_sha256': args.vocabulary_sha256}))


if __name__ == '__main__':
    main()
