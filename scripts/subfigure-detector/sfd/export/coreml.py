#!/usr/bin/env python3
"""Core ML (FP32) and ONNX export of a two-class panel detector checkpoint, with parity replay.

Runs on the Mac (coremltools) with networking not required. Inputs: the pinned official RT-DETR
checkout, the checkpoint, and a directory of validation images (never final-test images). For every
image the Torch and Core ML raw outputs are compared (permutation-aware), and the complete app policy
(threshold, suppression, completion) is replayed on both so that the delivered crops can be compared
exactly. ONNX is exported from the same traced graph and replayed with onnxruntime when available.
"""
import argparse, hashlib, json, pathlib, platform, subprocess, sys, time

REPOSITORY_REVISION = 'df2a96c8c3a098567a1149bf0248da6efe6d495d'
CONFIGS = {'r18': 'rtdetrv2_r18vd_120e_coco.yml', 'r34': 'rtdetrv2_r34vd_120e_coco.yml', 'r50m': 'rtdetrv2_r50vd_m_7x_coco.yml'}


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''):
            h.update(c)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--checkpoint', required=True)
    ap.add_argument('--arch', default='r18')
    ap.add_argument('--images', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--threshold', type=float, default=.5)
    ap.add_argument('--onnx', action='store_true')
    ap.add_argument('--precision', choices=['fp32', 'fp16'], default='fp32')
    ap.add_argument('--use-package', help='replay an existing (e.g. weight-compressed) package instead of converting')
    ap.add_argument('--compute-units', choices=['ALL', 'CPU_ONLY', 'CPU_AND_GPU', 'CPU_AND_NE'], default='ALL')
    args = ap.parse_args()
    repo, out = pathlib.Path(args.repo), pathlib.Path(args.out)
    rev = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no'], text=True)
    if rev != REPOSITORY_REVISION or dirty:
        raise ValueError('Expected the unmodified pinned official repository')
    out.mkdir(parents=True, exist_ok=True)
    import numpy as np, torch, coremltools as ct
    from PIL import Image
    from scipy.optimize import linear_sum_assignment
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
    from sfd.core import policy as P
    torch.set_num_threads(4)
    sys.path.insert(0, str(repo.resolve() / 'rtdetrv2_pytorch'))
    from src.core import YAMLConfig
    cfg = YAMLConfig(str(repo / 'rtdetrv2_pytorch/configs/rtdetrv2' / CONFIGS[args.arch]))
    cfg.yaml_cfg['PResNet']['pretrained'] = False
    cfg.yaml_cfg.update(num_classes=2, remap_mscoco_category=False, eval_spatial_size=[640, 640])
    ck = torch.load(args.checkpoint, map_location='cpu', weights_only=False)
    meta = ck.get('meta', {})
    if meta.get('classes') != ['panel', 'shared'] or meta.get('upstream_revision') != REPOSITORY_REVISION:
        raise ValueError('Unexpected checkpoint manifest')
    cfg.model.load_state_dict(ck['model'], strict=True)

    class Raw(torch.nn.Module):
        def __init__(self, m):
            super().__init__(); self.m = m.deploy()

        def forward(self, x):
            o = self.m(x)
            return o['pred_logits'], o['pred_boxes']
    model = Raw(cfg.model).eval()
    paths = sorted(p for p in pathlib.Path(args.images).iterdir() if p.suffix.lower() in ('.png', '.jpg', '.jpeg'))
    if not paths:
        raise ValueError('No images')

    def prep(p):
        im = Image.open(p).convert('RGB')
        s = min(640 / im.width, 640 / im.height)
        rw, rh = max(1, round(im.width * s)), max(1, round(im.height * s))
        left, top = int((640 - rw) * .5), int((640 - rh) * .5)
        canvas = Image.new('RGB', (640, 640), 'white')
        canvas.paste(im.resize((rw, rh), Image.Resampling.BILINEAR), (left, top))
        return np.asarray(im), np.asarray(canvas, dtype=np.float32).transpose(2, 0, 1)[None] / 255., (rw / im.width, rh / im.height, left, top)

    def decode(logits, boxes, tr, W, H):
        prob = 1 / (1 + np.exp(-np.clip(logits[0], -80, 80)))
        sc, lab = prob.max(1), prob.argmax(1)
        sx, sy, left, top = tr
        recs = []
        for s, l, b in zip(sc, lab, boxes[0]):
            if s < .03:
                continue
            cx, cy, bw, bh = b * 640
            bb = [max(0., (cx - bw / 2 - left) / sx), max(0., (cy - bh / 2 - top) / sy), min(float(W), (cx + bw / 2 - left) / sx), min(float(H), (cy + bh / 2 - top) / sy)]
            if bb[2] > bb[0] and bb[3] > bb[1]:
                recs.append({'class': int(l), 'score': float(s), 'box': bb})
        return recs
    report = {'purpose': 'Numerical export parity and delivered-crop parity; not a quality claim',
              'checkpoint_sha256': digest(args.checkpoint), 'checkpoint_meta': {k: meta.get(k) for k in ('script_sha256', 'sources_sha256', 'weights_sha256', 'classes', 'upstream_revision')},
              'arch': args.arch, 'revision': rev, 'python': platform.python_version(), 'torch': torch.__version__, 'coremltools': ct.__version__,
              'preprocessing': 'RGB; bilinear aspect-fit 640 square, centred; white padding; NCHW float32 /255',
              'policy': {'threshold': args.threshold, 'panel_class': 0, 'complete': True}, 'images': []}
    first = prep(paths[0])[1]
    t0 = time.perf_counter()
    with torch.inference_mode():
        traced = torch.jit.trace(model, torch.from_numpy(first), strict=True)
    report['trace_seconds'] = time.perf_counter() - t0
    if args.use_package:
        ml = ct.models.MLModel(args.use_package, compute_units=getattr(ct.ComputeUnit, args.compute_units))
        pkg = pathlib.Path(args.use_package)
        report['conversion_seconds'] = None
        report['package_bytes'] = sum(p.stat().st_size for p in pkg.rglob('*') if p.is_file())
        report['precision'] = 'from-package:' + pkg.name; report['compute_units'] = args.compute_units
    else:
        t0 = time.perf_counter()
        ml = ct.convert(traced, source='pytorch', convert_to='mlprogram',
                        inputs=[ct.TensorType(name='images', shape=(1, 3, 640, 640), dtype=np.float32)],
                        outputs=[ct.TensorType(name='logits'), ct.TensorType(name='boxes')],
                        minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT32 if args.precision == 'fp32' else ct.precision.FLOAT16,
                        compute_units=getattr(ct.ComputeUnit, args.compute_units))
        report['conversion_seconds'] = time.perf_counter() - t0
        pkg = out / f'panel-detector-{args.arch}-{args.precision}.mlpackage'
        ml.save(str(pkg))
        report['package_bytes'] = sum(p.stat().st_size for p in pkg.rglob('*') if p.is_file())
        report['precision'] = args.precision; report['compute_units'] = args.compute_units
    sess = None
    if args.onnx:
        onnx_path = out / f'panel-detector-{args.arch}.onnx'
        torch.onnx.export(model, torch.from_numpy(first), str(onnx_path), input_names=['images'], output_names=['logits', 'boxes'], opset_version=17, dynamo=False)
        report['onnx_bytes'] = onnx_path.stat().st_size
        report['onnx_sha256'] = digest(onnx_path)
        try:
            import onnxruntime as ort
            sess = ort.InferenceSession(str(onnx_path), providers=['CPUExecutionProvider'])
        except Exception as e:
            report['onnx_runtime'] = f'unavailable: {e!r}'[:200]
    ml_times = []
    for k, p in enumerate(paths):
        img, x, tr = prep(p)
        H, W = img.shape[:2]
        with torch.inference_mode():
            tl, tb = [t.numpy() for t in model(torch.from_numpy(x))]
        t0 = time.perf_counter(); r = ml.predict({'images': x}); dt = (time.perf_counter() - t0) * 1000
        ml_times.append(dt)
        cl, cb = r['logits'], r['boxes']
        tp, cp = 1 / (1 + np.exp(-tl[0])), 1 / (1 + np.exp(-cl[0]))
        cost = np.abs(tb[0][:, None] - cb[0][None]).sum(2) + np.abs(tp[:, None] - cp[None]).max(2)
        rr, cc = linear_sum_assignment(cost)
        cfgp = {'threshold': args.threshold, 'panel_class': 0, 'complete': True}
        crops_t = P.final_crops(decode(tl, tb, tr, W, H), img, dict(cfgp))
        crops_c = P.final_crops(decode(cl, cb, tr, W, H), img, dict(cfgp))
        row = {'image': p.name, 'image_sha256': digest(p), 'size': [W, H], 'coreml_ms': dt,
               'matched_max_box_error': float(np.abs(tb[0][rr] - cb[0][cc]).max()),
               'matched_max_probability_error': float(np.abs(tp[rr] - cp[cc]).max()),
               'crops_torch': [[round(v, 1) for v in c] for c in crops_t], 'crops_coreml': [[round(v, 1) for v in c] for c in crops_c],
               'same_crop_count': len(crops_t) == len(crops_c),
               'max_crop_edge_px': max([max(abs(a - b) for a, b in zip(u, v)) for u, v in zip(sorted(crops_t), sorted(crops_c))], default=0.0)}
        if sess is not None:
            ol, ob = sess.run(None, {'images': x.astype(np.float32)})
            op = 1 / (1 + np.exp(-ol[0]))
            cost2 = np.abs(tb[0][:, None] - ob[0][None]).sum(2) + np.abs(tp[:, None] - op[None]).max(2)
            r2, c2 = linear_sum_assignment(cost2)
            row['onnx_matched_max_box_error'] = float(np.abs(tb[0][r2] - ob[0][c2]).max())
            row['onnx_matched_max_probability_error'] = float(np.abs(tp[r2] - op[c2]).max())
        report['images'].append(row)
        print(json.dumps({k2: row[k2] for k2 in ('image', 'coreml_ms', 'matched_max_box_error', 'matched_max_probability_error', 'same_crop_count', 'max_crop_edge_px')}), flush=True)
    report['coreml_first_ms'] = ml_times[0]
    report['coreml_warm_median_ms'] = float(np.median(ml_times[1:])) if len(ml_times) > 1 else None
    report['summary'] = {'images': len(paths),
                         'max_box_error': max(r['matched_max_box_error'] for r in report['images']),
                         'max_probability_error': max(r['matched_max_probability_error'] for r in report['images']),
                         'identical_crop_counts': sum(r['same_crop_count'] for r in report['images']),
                         'max_crop_edge_px': max(r['max_crop_edge_px'] for r in report['images'])}
    if sess is not None:
        report['summary']['onnx_max_box_error'] = max(r['onnx_matched_max_box_error'] for r in report['images'])
        report['summary']['onnx_max_probability_error'] = max(r['onnx_matched_max_probability_error'] for r in report['images'])
    (out / 'parity.json').write_text(json.dumps(report, indent=1))
    print(json.dumps(report['summary']))


if __name__ == '__main__':
    main()
