"""Package exact reference weights in a float32 Core ML constant-output carrier.

This does not train or change the tagger. The source manifest must be pinned by
SHA256, and its tensor layout and weight bytes are checked before conversion.
The resulting MLProgram is an unencrypted build input: encrypt its compiled
output with an Apple team .mlmodelkey before distribution. The app retrieves the
weights once in memory and checks their exact binary SHA256 before CPU recovery.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types
import numpy as np


def digest(data):
    return hashlib.sha256(data).hexdigest()


def package_digest(path):
    """Same source-package identity as scripts/device-models.mjs."""
    files = sorted(p for p in path.rglob('*') if p.is_file())
    return digest('\n'.join('/' + p.relative_to(path).as_posix() + ':' + digest(p.read_bytes())
                            for p in files).encode('utf-8'))


def read_reference(manifest_path, weights_path, expected_manifest_sha256):
    if not re.fullmatch(r'[0-9a-f]{64}', expected_manifest_sha256):
        raise ValueError('expected manifest SHA256 must be lowercase hexadecimal')
    if not 0 < manifest_path.stat().st_size <= 65_536:
        raise ValueError('reference manifest size is invalid')
    manifest_bytes = manifest_path.read_bytes()
    if digest(manifest_bytes) != expected_manifest_sha256:
        raise ValueError('reference manifest differs from its pinned SHA256')
    manifest = json.loads(manifest_bytes)
    contract = {'format': 'device-pdf-tagger-reference-v1', 'max_len': 400, 'byte_order': 'little',
                'scalar_type': 'float32', 'offset_unit': 'float32_elements',
                'gru_gate_order': ['reset', 'update', 'new']}
    if any(manifest.get(k) != value for k, value in contract.items()):
        raise ValueError('unsupported reference format')
    for key in ('checkpoint_sha256', 'vocabulary_sha256', 'binary_sha256'):
        if not isinstance(manifest.get(key), str) or not re.fullmatch(r'[0-9a-f]{64}', manifest[key]):
            raise ValueError('invalid reference identity: ' + key)
    features, hidden = manifest.get('n_features'), manifest.get('hidden')
    if type(features) is not int or features not in (10, 12) or type(hidden) is not int or not 1 <= hidden <= 256:
        raise ValueError('unsupported reference dimensions')
    shapes = {'font.weight': [256, 24], 'cls.weight': [10, 8], 'ch.weight': [512, 16],
              'inp.weight': [hidden, features + 48], 'inp.bias': [hidden],
              'out.weight': [1, 2 * hidden], 'out.bias': [1]}
    for layer in range(2):
        for suffix in ('', '_reverse'):
            key = f'l{layer}{suffix}'
            shapes[f'gru.weight_ih_{key}'] = [3 * hidden, hidden if layer == 0 else 2 * hidden]
            shapes[f'gru.weight_hh_{key}'] = [3 * hidden, hidden]
            shapes[f'gru.bias_ih_{key}'] = [3 * hidden]
            shapes[f'gru.bias_hh_{key}'] = [3 * hidden]
    tensors = manifest.get('tensors')
    if not isinstance(tensors, dict) or set(tensors) != set(shapes):
        raise ValueError('reference tensor names do not match the architecture')
    count = 0
    for name in sorted(shapes):
        tensor, shape = tensors[name], shapes[name]
        size = math.prod(shape)
        if (not isinstance(tensor, dict) or tensor.get('shape') != shape or
                type(tensor.get('offset')) is not int or tensor['offset'] != count or
                type(tensor.get('count')) is not int or tensor['count'] != size):
            raise ValueError('invalid reference tensor layout: ' + name)
        count += size
    if weights_path.stat().st_size != count * 4 or count * 4 > 16 * 1024 * 1024:
        raise ValueError('reference binary size differs from tensor layout')
    binary = weights_path.read_bytes()
    if len(binary) != count * 4 or digest(binary) != manifest['binary_sha256']:
        raise ValueError('reference binary differs from manifest')
    weights = np.frombuffer(binary, dtype='<f4').copy()
    if not np.isfinite(weights).all():
        raise ValueError('nonfinite reference weight')
    return manifest, weights


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--weights', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        raise FileExistsError(args.out)
    manifest, weights = read_reference(args.manifest, args.weights, args.manifest_sha256)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1,), dtype=types.fp32)], opset_version=ct.target.iOS18)
    def carrier(dummy):
        return mb.const(val=weights, name='reference_weights')

    model = ct.convert(carrier, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS18,
                       compute_precision=ct.precision.FLOAT32, skip_model_load=True)
    model.short_description = 'Exact tagger weights for independent CPU recovery; encrypt before distribution.'
    identity = {'source_manifest_sha256': args.manifest_sha256,
                'binary_sha256': manifest['binary_sha256'], 'checkpoint_sha256': manifest['checkpoint_sha256'],
                'vocabulary_sha256': manifest['vocabulary_sha256']}
    model.user_defined_metadata.update(identity)
    args.out.mkdir(parents=True)
    package = args.out / 'tagger-reference-carrier.mlpackage'
    model.save(str(package))
    metadata = {'format': 'device-pdf-tagger-reference-carrier-v1', **identity,
                'package': package.name, 'package_sha256': package_digest(package),
                'n_features': manifest['n_features'], 'hidden': manifest['hidden'],
                'float32_count': int(weights.size), 'byte_count': int(weights.nbytes),
                'input': {'name': 'dummy', 'dtype': 'float32', 'shape': [1]},
                'output': {'name': 'reference_weights', 'dtype': 'float32', 'shape': [int(weights.size)]},
                'compute_precision': 'float32', 'minimum_deployment_target': 'iOS18',
                'encrypted': False, 'distribution': 'Encrypt compiled output with an Apple team key; never ship this source package.',
                'exporter_sha256': digest(Path(__file__).read_bytes()),
                'coremltools_version': ct.__version__, 'numpy_version': np.__version__}
    (args.out / 'export.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
    print(json.dumps(metadata))


if __name__ == '__main__':
    main()
