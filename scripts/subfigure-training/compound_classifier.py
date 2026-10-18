#!/usr/bin/env python3
"""Can frozen detector features distinguish single/compound figures?

Research diagnostic only: real training labels, validation model selection, no
final-test inference. This is neither an accepted crop policy nor an app export.
"""
import argparse
import json
from pathlib import Path
import random
import time

import numpy as np
from scipy.stats import rankdata
import torch
from torch.utils.data import DataLoader

from train import Figures, build_model, collate, sha, write_json


def classification_metrics(labels, scores, threshold):
    labels=np.asarray(labels);scores=np.asarray(scores)
    if labels.ndim!=1 or scores.shape!=labels.shape or not np.isfinite(scores).all():
        raise ValueError('Scores must match finite one-dimensional labels')
    if not np.isin(labels,[0,1]).all():raise ValueError('Binary labels required')
    positive=labels.astype(bool);chosen=scores>=threshold
    tp=int((positive & chosen).sum());fp=int((~positive & chosen).sum())
    fn=int((positive & ~chosen).sum());tn=int((~positive & ~chosen).sum())
    n1=int(positive.sum());n0=len(positive)-n1;ranks=rankdata(scores,method='average')
    auc=float((ranks[positive].sum()-n1*(n1+1)/2)/(n1*n0)) if n1 and n0 else None
    return {'threshold':threshold,'tp':tp,'fp':fp,'fn':fn,'tn':tn,
            'compound_recall':tp/max(1,tp+fn),'single_specificity':tn/max(1,tn+fp),'auc':auc}


@torch.inference_mode()
def extract(model, dataset, views, batch, workers):
    loader=DataLoader(dataset,batch_size=batch,collate_fn=collate,num_workers=workers,shuffle=False)
    features=[];labels=[];identities=[]
    for view in range(views):
        for images,_,ids,_ in loader:
            encoded=model.encoder(model.backbone(images.cuda()))
            pooled=torch.cat([v for x in encoded for v in (x.mean((2,3)),x.amax((2,3)))],dim=1)
            features.append(pooled.cpu())
            labels.extend(float(sum(b['class']==4 for b in dataset.rows[i]['boxes'])>1) for i in ids)
            identities.extend(dataset.rows[i]['id'] for i in ids)
        print(json.dumps({'feature_view':view+1,'images':len(dataset)}),flush=True)
    return torch.cat(features),torch.tensor(labels),identities


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for field in ('root','repo','data','weights','out'):p.add_argument('--'+field,type=Path,required=True)
    p.add_argument('--seed',type=int,default=20261018);p.add_argument('--views',type=int,default=3)
    p.add_argument('--epochs',type=int,default=200);p.add_argument('--patience',type=int,default=25)
    p.add_argument('--hidden',type=int,default=128);p.add_argument('--workers',type=int,default=4)
    p.add_argument('--batch',type=int,default=8);p.add_argument('--max-hours',type=float,default=.25)
    args=p.parse_args()
    if args.out.exists():raise ValueError('Choose a new immutable run directory')
    if min(args.views,args.epochs,args.patience,args.batch)<=0:raise ValueError('Positive run limits required')
    if not torch.cuda.is_available():raise RuntimeError('Explicit GPU experiment; no silent CPU fallback')
    random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed);torch.set_num_threads(4)
    args.out.mkdir(parents=True);start=time.monotonic()
    manifest=json.loads((args.data/'manifest.json').read_text())
    for file,digest in manifest['files'].items():
        if sha(args.data/file)!=digest:raise ValueError('Changed source manifest')
    datasets={s:Figures(args.root,args.data,s,augment=s=='train',spatial_jitter=s=='train')
              for s in ('train','validation')}
    if any(r['domain'].startswith('Generated') for d in datasets.values() for r in d.rows):
        raise ValueError('This ablation uses only real figures')
    for key in ('paper','group','sha256'):
        if {r[key] for r in datasets['train'].rows} & {r[key] for r in datasets['validation'].rows}:
            raise ValueError('Training/validation identity leakage')
    model,_,_,_=build_model(args.repo,args.weights);model.cuda().eval()
    features={s:extract(model,d,args.views if s=='train' else 1,args.batch,args.workers)
              for s,d in datasets.items()}
    del model;torch.cuda.empty_cache();torch.save(features,args.out/'frozen-features.pt')
    train_x,train_y,_=features['train'];val_x,val_y,_=features['validation']
    mean=train_x.mean(0);scale=train_x.std(0).clamp_min(1e-4)
    train_x=((train_x-mean)/scale).cuda();train_y=train_y.cuda();val_x=((val_x-mean)/scale).cuda()
    head=torch.nn.Sequential(torch.nn.Linear(train_x.shape[1],args.hidden),torch.nn.ReLU(),
                             torch.nn.Dropout(.2),torch.nn.Linear(args.hidden,1)).cuda()
    optimizer=torch.optim.AdamW(head.parameters(),lr=.001,weight_decay=.01)
    criterion=torch.nn.BCEWithLogitsLoss(pos_weight=(len(train_y)-train_y.sum())/train_y.sum().clamp_min(1))
    best=-1.;stale=0;best_epoch=-1
    for epoch in range(args.epochs):
        if time.monotonic()-start>args.max_hours*3600:break
        head.train();order=torch.randperm(len(train_x),device='cuda');losses=[]
        for i in range(0,len(order),128):
            ix=order[i:i+128];optimizer.zero_grad(set_to_none=True)
            loss=criterion(head(train_x[ix]).flatten(),train_y[ix])
            if not torch.isfinite(loss):raise FloatingPointError('Non-finite classification loss')
            loss.backward();torch.nn.utils.clip_grad_norm_(head.parameters(),1.,error_if_nonfinite=True)
            optimizer.step();losses.append(float(loss.detach()))
        head.eval()
        with torch.no_grad():scores=head(val_x).flatten().sigmoid().cpu().numpy()
        metrics=classification_metrics(val_y.numpy(),scores,.5)
        if metrics['auc']>best:
            best=metrics['auc'];best_epoch=epoch;stale=0
            state={k:v.detach().cpu().clone() for k,v in head.state_dict().items()}
            torch.save({'head':state,'feature_mean':mean,'feature_scale':scale,'hidden':args.hidden,
                        'epoch':epoch,'detector_sha256':sha(args.weights)},args.out/'best.pth')
            write_json(args.out/'probabilities.json',[{'id':r['id'],'image_sha256':r['sha256'],
                'width':r['width'],'height':r['height'],'compound_probability':float(score)}
                for r,score in zip(datasets['validation'].rows,scores)])
            write_json(args.out/'best-metrics.json',{'epoch':epoch,'auc':best,'threshold_sweep':[
                classification_metrics(val_y.numpy(),scores,t) for t in (.01,.02,.05,.1,.15,.2,.3,.4,.5,.6,.7,.8,.9)]})
        else:stale+=1
        report={'epoch':epoch,'loss':float(np.mean(losses)),**metrics,'best_auc':best}
        with (args.out/'epochs.jsonl').open('a') as f:f.write(json.dumps(report)+'\n')
        if epoch%10==0:print(json.dumps(report),flush=True)
        if stale>=args.patience:break
    write_json(args.out/'provenance.json',{'script_sha256':sha(__file__),'detector_sha256':sha(args.weights),
        'feature_preprocessing_source_sha256':sha(Path(__file__).with_name('train.py')),
        'data_manifest_sha256':sha(args.data/'manifest.json'),'args':{k:str(v) if isinstance(v,Path) else v
            for k,v in vars(args).items()},'feature_order':'encoder pyramid order; per level mean then max',
        'split':'validation','deployment_qualified':False,'distribution_allowed':False})
    (args.out/'source.py').write_bytes(Path(__file__).read_bytes())
    write_json(args.out/'completion.json',{'best_epoch':best_epoch,'best_auc':best,
        'elapsed_seconds':time.monotonic()-start,'note':'Classification only, not panel localization or crop qualification.'})


if __name__=='__main__':main()
