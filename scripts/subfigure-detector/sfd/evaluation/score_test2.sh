#!/usr/bin/env bash
# Score test 2 ONCE for the declared systems. Refuses to overwrite.
set -euo pipefail
cd /home/ben/science-reader-subfigures/d21
O=eval/final-test2; [ -e $O ] && { echo "test 2 already scored"; exit 1; }; mkdir -p $O
G=data/eval-test2/gt.jsonl
sha256sum -c data/eval-test2/LOCKED.sha256
sha256sum eval/frozen-rc/* pkg/sfd/core/policy.py pkg/sfd/core/evaluate.py eval/d22/test2-ocr.jsonl > $O/inputs.sha256
pred() { PYTHONPATH=pkg env/bin/python -m sfd.train.predict --repo ../source/RT-DETR --checkpoint $1 --base $2 --arch $3 --gt $G --zoom $4 --out $5 > /dev/null; }
R50=data/weights/rtdetrv2_r50vd_m_7x_coco_ema.pth; R18=../data/sources/rtdetrv2-s.pth
pred eval/frozen-rc/panel-detector-rc-r50m-clean-e10.pth $R50 r50m 1.0 $O/pred-rc.json
pred eval/frozen-rc/panel-detector-rc-r50m-clean-e10.pth $R50 r50m .75 $O/pred-rc-z75.json
pred eval/frozen-rc/panel-detector-rc-r18-clean-e13.pth $R18 r18 1.0 $O/pred-r18.json
pred eval/frozen-rc/panel-detector-rc-r18-clean-e13.pth $R18 r18 .75 $O/pred-r18-z75.json
pred eval/frozen/panel-detector-r50m-e04.pth $R50 r50m 1.0 $O/pred-1021.json
pred eval/frozen/panel-detector-r50m-e04.pth $R50 r50m .75 $O/pred-1021-z75.json
PYTHONPATH=pkg env/bin/python -m sfd.train.predict --repo ../source/RT-DETR --checkpoint ../runs/source-v13-gentle/best.pth --base $R18 --classes 5 --gt $G --out $O/pred-v13.json > /dev/null
FE="env PYTHONPATH=pkg env/bin/python -m sfd.evaluation.final_eval --acknowledge-final-test --gt $G --ocr eval/d22/test2-ocr.jsonl --bootstrap 5000"
$FE --system eval/frozen-rc/system-rc.json --pred $O/pred-rc.json --pred-b $O/pred-rc-z75.json --out $O/rc.json
$FE --system eval/frozen-rc/system-r18-t06.json --pred $O/pred-r18.json --pred-b $O/pred-r18-z75.json --out $O/r18.json
$FE --system eval/systems/frozen-decode-agree.json --pred $O/pred-1021.json --pred-b $O/pred-1021-z75.json --out $O/frozen-1021.json
$FE --system eval/systems/v13-raw.json --pred $O/pred-v13.json --out $O/v13-raw.json
$FE --system eval/systems/v13-complete.json --pred $O/pred-v13.json --out $O/v13-complete.json
date -u +%FT%TZ > $O/scored-utc.txt
