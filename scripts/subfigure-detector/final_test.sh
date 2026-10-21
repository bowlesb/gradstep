#!/usr/bin/env bash
# Score the frozen system ONCE on the final tests (new arXiv test and the old SCI-3000 test), plus the fixed
# previous detector (v13) as a reference. Usage: final_test.sh <checkpoint> <arch> <base-weights> <system.json>
# Writes eval/final/; refuses to overwrite existing results (final_eval.py also refuses).
set -euo pipefail
cd /home/ben/science-reader-subfigures/d21
ck=$1; arch=$2; base=$3; system=$4
out=eval/final
[ -e $out ] && { echo "eval/final exists: the final test is scored once"; exit 1; }
mkdir -p $out
sha256sum $ck $system data/eval-test/gt.jsonl data/old-test/gt.jsonl src/policy.py src/evaluate.py src/sweep.py src/final_eval.py > $out/frozen-inputs.sha256
for t in arxiv:data/eval-test/gt.jsonl old:data/old-test/gt.jsonl; do
  n=${t%%:*}; g=${t#*:}
  env/bin/python src/predict.py --repo ../source/RT-DETR --checkpoint $ck --base $base --arch $arch --gt $g --out $out/pred-$n.json
  env/bin/python src/predict.py --repo ../source/RT-DETR --checkpoint $ck --base $base --arch $arch --gt $g --zoom .75 --out $out/pred-$n-z75.json
  env/bin/python src/predict.py --repo ../source/RT-DETR --checkpoint ../runs/source-v13-gentle/best.pth --base ../data/sources/rtdetrv2-s.pth --classes 5 --gt $g --out $out/pred-$n-v13.json
  env/bin/python src/final_eval.py --acknowledge-final-test --system $system --gt $g --pred $out/pred-$n.json --pred-b $out/pred-$n-z75.json --out $out/$n-frozen-system.json --bootstrap 5000
  env/bin/python src/final_eval.py --acknowledge-final-test --system eval/systems/v13-raw.json --gt $g --pred $out/pred-$n-v13.json --out $out/$n-v13-raw.json --bootstrap 5000
  env/bin/python src/final_eval.py --acknowledge-final-test --system eval/systems/v13-complete.json --gt $g --pred $out/pred-$n-v13.json --out $out/$n-v13-complete.json --bootstrap 5000
done
date -u +%Y-%m-%dT%H:%M:%SZ > $out/scored-utc.txt
