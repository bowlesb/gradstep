#!/usr/bin/env python3
"""Validation-only two-checkpoint geometry ablation, without model inference.

Compare averaging and union of agreeing boxes. Every match is one-to-one and
same-class; keep the independent detector/crop quality gates. No release claim.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment
from train import ious,metrics,sha
from crop_policy import deduplicate,detection_gate


def combine(aa,bb,mode='mean',minimum_overlap=.5,solo_threshold=.95):
    # Scientific panels only. Context quality must be measured separately.
    aa=[p for p in aa if p['class']==4 and p['score']>=.1]
    bb=[p for p in bb if p['class']==4 and p['score']>=.1]
    matrix=ious([p['box'] for p in aa],[p['box'] for p in bb]);pairs=[]
    if aa and bb:
        ii,jj=linear_sum_assignment(-((matrix>=minimum_overlap)*10+matrix))
        pairs=[(i,j) for i,j in zip(ii,jj) if matrix[i,j]>=minimum_overlap]
    result=[]
    for i,j in pairs:
        a,b=aa[i],bb[j];wa,wb=a['score'],b['score']
        if mode=='mean':box=((np.asarray(a['box'])*wa+np.asarray(b['box'])*wb)/(wa+wb)).tolist()
        elif mode=='union':box=[min(a['box'][0],b['box'][0]),min(a['box'][1],b['box'][1]),
                               max(a['box'][2],b['box'][2]),max(a['box'][3],b['box'][3])]
        else:raise ValueError('Unknown fusion mode')
        result.append({'class':4,'score':(wa+wb)/2,'box':box,'source_scores':[wa,wb]})
    useda={i for i,j in pairs};usedb={j for i,j in pairs}
    result += [copy.deepcopy(p) for i,p in enumerate(aa) if i not in useda and p['score']>=solo_threshold]
    result += [copy.deepcopy(p) for i,p in enumerate(bb) if i not in usedb and p['score']>=solo_threshold]
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data',type=Path,required=True);p.add_argument('--first',type=Path,required=True)
    p.add_argument('--second',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    args=p.parse_args()
    rows=[json.loads(s) for s in (args.data/'validation.jsonl').read_text().splitlines()]
    payloads=[path.read_bytes() for path in (args.first,args.second)]
    decoded=[json.loads(raw) for raw in payloads]
    sources=[{r['id']:r for r in saved} for saved in decoded]
    for path,saved_rows,source in zip((args.first,args.second),decoded,sources):
        if len(saved_rows)!=len(source):raise ValueError('Duplicate prediction identity')
        if set(source)!={r['id'] for r in rows}:raise ValueError('Validation image set mismatch')
        if any('image_sha256' not in saved for saved in saved_rows):
            provenance=json.loads((path.parent/'provenance.json').read_text())
            if provenance['data_manifest_sha256']!=sha(args.data/'manifest.json'):
                raise ValueError('Legacy prediction provenance mismatch')
        for r in rows:
            saved=source[r['id']]
            if 'image_sha256' in saved and (saved['image_sha256']!=r['sha256'] or
                (saved['width'],saved['height'])!=(r['width'],r['height'])):
                raise ValueError('Prediction image identity/geometry mismatch')
    reports=[]
    for mode in ('mean','union'):
        for nms in (.4,.5,.7):
            merged=[combine(sources[0][r['id']]['predictions'],sources[1][r['id']]['predictions'],mode) for r in rows]
            for threshold in (.3,.4,.5,.6,.65,.7,.75,.8):
                selected=[deduplicate([p for p in ps if p['score']>=threshold],nms) for ps in merged]
                m=metrics(rows,selected,threshold,compounds_only=True)
                all_m=metrics(rows,selected,threshold)
                reports.append({'mode':mode,'nms':nms,'threshold':threshold,'panel':m,'all_figures':all_m,
                                'detection_gate':detection_gate(all_m,m)})
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps({'split':'validation','reports':reports,'deployment_qualified':False,
        'source_sha256':[hashlib.sha256(raw).hexdigest() for raw in payloads],
        'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},indent=2)+'\n')
    for mode in ('mean','union'):
        best=max([r for r in reports if r['mode']==mode],key=lambda r:r['panel']['f1'])
        print(json.dumps({'mode':mode,'nms':best['nms'],'threshold':best['threshold'],
                          **{k:best['panel'][k] for k in ('tp','fp','fn','recall','precision')},
                          'detection_gate':best['detection_gate']}))


if __name__=='__main__':main()
