#!/usr/bin/env python3
"""Offline RT-DETRv2-S/Core ML feasibility check, not a scientific-panel evaluation.

Use the pinned official Apache-2.0 implementation and COCO checkpoint in a disposable
environment, or an explicitly hashed five-class research checkpoint. No downloads,
training or application changes happen here. Conversion does not qualify crop quality.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
import time

REPOSITORY_REVISION = 'df2a96c8c3a098567a1149bf0248da6efe6d495d'
WEIGHTS_SHA256 = '2ace52184b620204004509b72752ac7bfe64aadaf7fc1d076b18df8ab5a5c77e'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--weights', required=True)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--checkpoint-manifest', help='Explicit hash/class/training provenance for a research fine-tuned checkpoint')
    parser.add_argument('--precision', choices=['fp16', 'fp32', 'mixed'], default='fp32',
                        help='mixed keeps geometry, normalization and nonlinearities in FP32')
    args = parser.parse_args()
    repo, weights, bundle, out = map(pathlib.Path, (args.repo, args.weights, args.bundle, args.out))
    revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no'], text=True)
    if revision != REPOSITORY_REVISION or dirty:
        raise ValueError('Expected the unmodified, pinned official repository')
    fine_tuned=json.loads(pathlib.Path(args.checkpoint_manifest).read_text()) if args.checkpoint_manifest else None
    expected_sha=fine_tuned['weights_sha256'] if fine_tuned else WEIGHTS_SHA256
    if fine_tuned and (fine_tuned['upstream_revision']!=REPOSITORY_REVISION or fine_tuned['classes']!=
                      ['shared_legend','shared_title','shared_x_axis','shared_y_axis','panel']):
        raise ValueError('Unexpected fine-tuned checkpoint architecture/classes')
    if digest(weights) != expected_sha:
        raise ValueError('Unreviewed checkpoint')
    out.mkdir(parents=True, exist_ok=True)

    import coremltools as ct
    import numpy as np
    import torch
    from PIL import Image
    torch.set_num_threads(4)
    torch.manual_seed(0)
    sys.path.insert(0, str(repo.resolve() / 'rtdetrv2_pytorch'))
    from src.core import YAMLConfig
    config = repo / 'rtdetrv2_pytorch/configs/rtdetrv2/rtdetrv2_r18vd_120e_coco.yml'
    cfg = YAMLConfig(str(config))
    # The complete checkpoint supplies the backbone; do not fetch another set of weights.
    cfg.yaml_cfg['PResNet']['pretrained'] = False
    if fine_tuned:cfg.yaml_cfg.update(num_classes=len(fine_tuned['classes']),remap_mscoco_category=False)
    checkpoint = torch.load(weights, map_location='cpu', weights_only=True)
    if fine_tuned and checkpoint.get('meta',{}).get('data_manifest_sha256')!=fine_tuned['data_manifest_sha256']:
        raise ValueError('Fine-tuned checkpoint dataset provenance mismatch')
    state = checkpoint['ema']['module'] if 'ema' in checkpoint else checkpoint['model']
    cfg.model.load_state_dict(state, strict=True)
    del checkpoint, state

    class RawDetector(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model.deploy()

        def forward(self, images):
            output = self.model(images)
            return output['pred_logits'], output['pred_boxes']

    model = RawDetector(cfg.model).eval()
    index = json.loads((bundle / 'reader.json').read_text())
    images = []
    for figure in index['figures']:
        for asset in figure['asset_paths']:
            path = (bundle / asset).resolve()
            if not path.is_relative_to(bundle.resolve()):
                raise ValueError('Image outside the local verified bundle')
            original = Image.open(path).convert('RGB')
            # Fixed 640-square letterbox, identical for Torch and Core ML; preserve aspect ratio.
            scale = min(640 / original.width, 640 / original.height)
            size = (round(original.width * scale), round(original.height * scale))
            left, top = (640 - size[0]) // 2, (640 - size[1]) // 2
            canvas = Image.new('RGB', (640, 640), (255, 255, 255))
            canvas.paste(original.resize(size, Image.Resampling.BILINEAR), (left, top))
            data = np.asarray(canvas, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0
            images.append((figure['id'], path, original.size, (left, top, *size), data))
    if not images:
        raise ValueError('No figure images')
    report = {
        'purpose': 'Conversion and numerical parity only; not quality or distribution qualification',
        'repository': 'https://github.com/lyuwenyu/RT-DETR', 'revision': revision,
        'weights_sha256': expected_sha, 'weights_bytes': weights.stat().st_size,
        'checkpoint_manifest':fine_tuned,'deployment_qualified':False,
        'script_sha256': digest(pathlib.Path(__file__)), 'python': platform.python_version(),
        'torch': torch.__version__, 'coremltools': ct.__version__,
        'preprocessing': 'RGB; bilinear aspect-fit 640 square; white padding; NCHW float32 / 255',
        'outputs': 'Raw logits and normalized cx/cy/w/h in letterboxed coordinates; no NMS',
        'precision': args.precision.upper(), 'compute_units': 'ALL', 'images': [],
    }
    started = time.perf_counter()
    with torch.inference_mode():
        traced = torch.jit.trace(model, torch.from_numpy(images[0][4]), strict=True)
    report['trace_seconds'] = time.perf_counter() - started
    started = time.perf_counter()
    precision = {'fp16': ct.precision.FLOAT16, 'fp32': ct.precision.FLOAT32}.get(args.precision)
    if args.precision == 'mixed':
        precision = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type in ('conv', 'linear', 'matmul'))
        report['fp16_operations'] = ['conv', 'linear', 'matmul']
    converted = ct.convert(traced, source='pytorch', convert_to='mlprogram',
        inputs=[ct.TensorType(name='images', shape=(1, 3, 640, 640), dtype=np.float32)],
        outputs=[ct.TensorType(name='logits'), ct.TensorType(name='boxes')],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=precision,
        compute_units=ct.ComputeUnit.ALL)
    report['conversion_seconds'] = time.perf_counter() - started
    package = out / f'rtdetrv2-s-{args.precision}.mlpackage'
    converted.save(str(package))
    report['package_bytes'] = sum(p.stat().st_size for p in package.rglob('*') if p.is_file())
    report['package_files'] = {str(p.relative_to(package)): digest(p) for p in package.rglob('*') if p.is_file()}
    for identifier, path, size, letterbox, data in images:
        started = time.perf_counter()
        with torch.inference_mode():
            logits, boxes = model(torch.from_numpy(data))
        torch_ms = (time.perf_counter() - started) * 1000
        started = time.perf_counter()
        result = converted.predict({'images': data})
        coreml_ms = (time.perf_counter() - started) * 1000
        row = {'id': identifier, 'image_sha256': digest(path), 'size': size, 'letterbox': letterbox,
               'torch_ms': torch_ms, 'coreml_ms': coreml_ms,
               'logits_shape': list(result['logits'].shape), 'boxes_shape': list(result['boxes'].shape),
               'finite': bool(np.isfinite(result['logits']).all() and np.isfinite(result['boxes']).all()),
               'max_raw_logit_error': float(np.max(np.abs(logits.numpy() - result['logits']))),
               'max_raw_box_error': float(np.max(np.abs(boxes.numpy() - result['boxes'])))}
        report['images'].append(row)
        # Keep complete predictions so later analysis can distinguish query reordering from numeric drift.
        np.savez_compressed(out / f'{identifier}.npz', torch_logits=logits.numpy(), torch_boxes=boxes.numpy(),
                            coreml_logits=result['logits'], coreml_boxes=result['boxes'])
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(row), flush=True)


if __name__ == '__main__':
    main()
