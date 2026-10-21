#!/usr/bin/env python3
"""ONNX export (opset 17) of a two-class panel detector for a browser runtime, with onnxruntime parity
against the PyTorch source on validation images (never final-test images). Raw outputs only: logits
[1,300,2] and normalized cx,cy,w,h boxes [1,300,4] in the 640 letterbox; decoding/policy stay in app code."""
import argparse, hashlib, json, pathlib, sys, time

import numpy as np
import torch
from PIL import Image
from scipy.optimize import linear_sum_assignment

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sfd.train import train as T


def digest(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', type=pathlib.Path, required=True)
    ap.add_argument('--checkpoint', type=pathlib.Path, required=True)
    ap.add_argument('--base', type=pathlib.Path, required=True)
    ap.add_argument('--arch', default='r18')
    ap.add_argument('--gt', type=pathlib.Path, required=True)
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--out', type=pathlib.Path, required=True)
    args = ap.parse_args()
    import onnxruntime as ort
    model, _, _ = T.build_model(args.repo, args.base, args.arch, 2, 640)
    st = torch.load(args.checkpoint, map_location='cpu', weights_only=False)
    model.load_state_dict({k: v for k, v in st['model'].items()}, strict=False)

    class Raw(torch.nn.Module):
        def __init__(self, m):
            super().__init__(); self.m = m.deploy()

        def forward(self, x):
            o = self.m(x)
            return o['pred_logits'], o['pred_boxes']
    raw = Raw(model).eval()
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()][:args.n]
    args.out.mkdir(parents=True, exist_ok=True)
    onnx_path = args.out / f'panel-detector-{args.arch}.onnx'
    x0 = torch.zeros(1, 3, 640, 640)
    torch.onnx.export(raw, x0, str(onnx_path), input_names=['images'], output_names=['logits', 'boxes'], opset_version=17, dynamo=False)
    sess = ort.InferenceSession(str(onnx_path), providers=['CPUExecutionProvider'])
    rows, times = [], []
    for g in gts:
        im = T.load_rgb(g['image'])
        canvas, _ = T.letterbox(im, 640)
        x = (np.asarray(canvas, dtype=np.float32).transpose(2, 0, 1)[None] / 255.).astype(np.float32)
        with torch.inference_mode():
            tl, tb = [t.numpy() for t in raw(torch.from_numpy(x))]
        t0 = time.perf_counter(); ol, ob = sess.run(None, {'images': x}); times.append((time.perf_counter() - t0) * 1000)
        tp, op = 1 / (1 + np.exp(-tl[0])), 1 / (1 + np.exp(-ol[0]))
        cost = np.abs(tb[0][:, None] - ob[0][None]).sum(2) + np.abs(tp[:, None] - op[None]).max(2)
        r, c = linear_sum_assignment(cost)
        rows.append({'id': g['id'], 'box_error': float(np.abs(tb[0][r] - ob[0][c]).max()), 'prob_error': float(np.abs(tp[r] - op[c]).max())})
    rep = {'onnx_sha256': digest(onnx_path), 'onnx_bytes': onnx_path.stat().st_size, 'checkpoint_sha256': digest(args.checkpoint),
           'opset': 17, 'onnxruntime': ort.__version__, 'images': len(rows), 'max_box_error': max(r['box_error'] for r in rows),
           'max_prob_error': max(r['prob_error'] for r in rows), 'cpu_ms_median': float(np.median(times[1:])), 'rows': rows}
    (args.out / 'onnx-parity.json').write_text(json.dumps(rep, indent=1))
    print(json.dumps({k: v for k, v in rep.items() if k != 'rows'}))


if __name__ == '__main__':
    main()
