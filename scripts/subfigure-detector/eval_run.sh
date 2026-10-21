#!/usr/bin/env bash
# Usage: eval_run.sh <run-dir> <epoch-tags...>   (validation sets only; final test is never read here)
# For each checkpoint: predictions on the frozen and the new arXiv validation sets at two placements
# (zoom 1.0 and 0.75), then policy sweeps: plain, view-agreement, caption-count, caption-count+agreement.
set -euo pipefail
cd /home/ben/science-reader-subfigures/d21
run=$1; shift
arch=$(python3 -c "import json;print(json.load(open('$run/provenance.json'))['args']['arch'])")
base=$(python3 -c "import json;print(json.load(open('$run/provenance.json'))['args']['weights'])")
for tag in "$@"; do
  ck=$run/ema-$tag.pth; [ "$tag" = best ] && ck=$run/best.pth
  for v in frozen:data/train-v1/frozen-validation-gt.jsonl arxiv:data/eval-validation/gt.jsonl; do
    n=${v%%:*}; g=${v#*:}
    [ -f $run/val-$n-$tag.json ] || env/bin/python src/predict.py --repo ../source/RT-DETR --checkpoint $ck --base $base --arch $arch --gt $g --out $run/val-$n-$tag.json > /dev/null
    [ -f $run/val-$n-$tag-z75.json ] || env/bin/python src/predict.py --repo ../source/RT-DETR --checkpoint $ck --base $base --arch $arch --gt $g --zoom .75 --out $run/val-$n-$tag-z75.json > /dev/null
  done
  F=data/train-v1/frozen-validation-gt.jsonl; A=data/eval-validation/gt.jsonl
  env/bin/python src/sweep.py --thresholds .4,.5,.6 --complete 1 \
    --set frozen-$tag $F $run/val-frozen-$tag.json --set frozen-$tag-agree $F $run/val-frozen-$tag.json,$run/val-frozen-$tag-z75.json \
    --set arxiv-$tag $A $run/val-arxiv-$tag.json --set arxiv-$tag-agree $A $run/val-arxiv-$tag.json,$run/val-arxiv-$tag-z75.json \
    --out $run/sweep-$tag.json
  env/bin/python src/sweep.py --thresholds .5 --complete 1 --caption-count \
    --set arxiv-$tag-caption $A $run/val-arxiv-$tag.json --set arxiv-$tag-caption-agree $A $run/val-arxiv-$tag.json,$run/val-arxiv-$tag-z75.json \
    --out $run/sweep-$tag-caption.json
  env/bin/python src/sweep.py --thresholds .5,.6 --complete 1 --caption-count --caption-fallback plain \
    --set arxiv-$tag-hybrid $A $run/val-arxiv-$tag.json --set arxiv-$tag-hybrid-agree $A $run/val-arxiv-$tag.json,$run/val-arxiv-$tag-z75.json \
    --out $run/sweep-$tag-hybrid.json
done
