#!/usr/bin/env python3
"""Weight-only compression of an FP32 Core ML package (activations stay FP32), then the same parity replay.

Modes: int8 linear symmetric per-channel weights, or FP16 weights with FP32 compute is not available in
Core ML, so 'int8' and 'palette6' (6-bit k-means palettization) are tried. Parity is judged on the delivered
crops of the full policy, exactly as for the FP32 export.
"""
import argparse, json, pathlib, sys, time

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--package', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--checkpoint', required=True)
    ap.add_argument('--arch', default='r50m')
    ap.add_argument('--images', required=True)
    ap.add_argument('--mode', choices=['int8', 'palette6', 'palette4'], default='int8')
    ap.add_argument('--out', required=True)
    ap.add_argument('--compute-units', default='CPU_ONLY')
    args = ap.parse_args()
    import coremltools as ct
    import coremltools.optimize.coreml as cto
    m = ct.models.MLModel(args.package)
    if args.mode == 'int8':
        cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode='linear_symmetric', granularity='per_channel'))
        q = cto.linear_quantize_weights(m, cfg)
    else:
        bits = 6 if args.mode == 'palette6' else 4
        cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode='kmeans', nbits=bits))
        q = cto.palettize_weights(m, cfg)
    out = pathlib.Path(args.out); out.mkdir(parents=True, exist_ok=True)
    pkg = out / f'panel-detector-{args.arch}-{args.mode}.mlpackage'
    q.save(str(pkg))
    # Re-use the export script's parity loop by importing it with a pre-built model.
    sys.argv = ['coreml', '--repo', args.repo, '--checkpoint', args.checkpoint, '--arch', args.arch, '--images', args.images,
                '--out', str(out / 'replay'), '--use-package', str(pkg), '--compute-units', args.compute_units]
    from sfd.export import coreml
    coreml.main()


if __name__ == '__main__':
    main()
