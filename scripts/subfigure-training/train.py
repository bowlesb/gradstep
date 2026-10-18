#!/usr/bin/env python3
"""Bounded, resumable, offline RT-DETRv2 research training with honest crop metrics.

Use the official Apache-2.0 model/criterion; never execute downloaded model code.
All inputs are pinned local artifacts. Final-test evaluation is explicitly separate
from validation-based model/threshold selection. No model qualifies for release here.
"""
import argparse
import collections
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageEnhance
from scipy.optimize import linear_sum_assignment
import torch
from torch.utils.data import Dataset, DataLoader, WeightedRandomSampler

REPO_REVISION = 'df2a96c8c3a098567a1149bf0248da6efe6d495d'
COCO_SHA = '2ace52184b620204004509b72752ac7bfe64aadaf7fc1d076b18df8ab5a5c77e'
CLASSES = ['shared_legend', 'shared_title', 'shared_x_axis', 'shared_y_axis', 'panel']


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    tmp = path.with_suffix('.tmp'); tmp.write_text(json.dumps(value, indent=2)+'\n'); tmp.replace(path)


def prediction_records(rows,predictions):
    return [{'id':r['id'],'image_sha256':r['sha256'],'width':r['width'],'height':r['height'],
             'predictions':ps} for r,ps in zip(rows,predictions)]


def letterbox(image, size=640,zoom=1.,position=(.5,.5)):
    w, h = image.size
    if not 0<zoom<=1 or any(not 0<=x<=1 for x in position):raise ValueError('Invalid content-preserving placement')
    scale = min(size/w, size/h)*zoom
    rw, rh = round(w*scale), round(h*scale)
    left, top = int((size-rw)*position[0]), int((size-rh)*position[1])
    out = Image.new('RGB', (size, size), 'white')
    out.paste(image.resize((rw, rh), Image.Resampling.BILINEAR), (left, top))
    # Rounded dimensions yield slightly different x/y scales. Track both exactly.
    return out, (rw/w, rh/h, left, top)


class Figures(Dataset):
    def __init__(self, root, manifest, split, augment=False, limit=None,size=640,spatial_jitter=False):
        self.root, self.augment, self.size = root.resolve(), augment, size
        self.spatial_jitter=spatial_jitter
        self.rows = [json.loads(x) for x in (manifest/f'{split}.jsonl').read_text().splitlines()]
        if limit: self.rows = self.rows[:limit]
        for row in self.rows:
            path = (root/row['image']).resolve()
            if not path.is_relative_to(self.root): raise ValueError('Image outside training workspace')
            if sha(path) != row['sha256']: raise ValueError(f"Image hash mismatch: {row['id']}")

    def __len__(self): return len(self.rows)

    def __getitem__(self, i):
        row = self.rows[i]
        image = Image.open(self.root/row['image']).convert('RGB')
        if image.size != (row['width'], row['height']): raise ValueError('Dimension mismatch')
        # Never flip, mirror, or crop scientific text. Small photometric/scan variations only.
        if self.augment:
            if random.random() < .25: image = ImageEnhance.Contrast(image).enhance(random.uniform(.75, 1.15))
            if random.random() < .15: image = image.convert('L').convert('RGB')
        placement={}
        if self.augment and self.spatial_jitter and random.random()<.6:
            placement={'zoom':random.uniform(.72,1.),'position':(random.random(),random.random())}
        image, transform = letterbox(image,self.size,**placement)
        sx, sy, left, top = transform
        boxes = []
        for b in row['boxes']:
            x1, y1, x2, y2 = b['box']
            boxes.append([((x1+x2)/2*sx+left)/self.size, ((y1+y2)/2*sy+top)/self.size,
                          (x2-x1)*sx/self.size, (y2-y1)*sy/self.size])
        target = {'boxes': torch.tensor(boxes, dtype=torch.float32).reshape(-1,4),
                  'labels': torch.tensor([b['class'] for b in row['boxes']], dtype=torch.int64)}
        data = torch.from_numpy(np.asarray(image, dtype=np.float32).transpose(2,0,1).copy()/255.)
        return data, target, i, transform


def collate(batch):
    images, targets, ids, transforms = zip(*batch)
    return torch.stack(images), list(targets), ids, transforms


def seed_worker(worker):
    seed = torch.initial_seed() % 2**32
    random.seed(seed); np.random.seed(seed)


def ious(a, b):
    a, b = np.asarray(a, dtype=float).reshape(-1,4), np.asarray(b, dtype=float).reshape(-1,4)
    lo = np.maximum(a[:,None,:2], b[None,:,:2]); hi = np.minimum(a[:,None,2:], b[None,:,2:])
    intersection = np.maximum(0, hi-lo).prod(-1)
    aa = np.maximum(0,a[:,2:]-a[:,:2]).prod(-1); bb = np.maximum(0,b[:,2:]-b[:,:2]).prod(-1)
    return intersection / np.maximum(aa[:,None]+bb[None,:]-intersection, 1e-12)


def retained(truth, crop):
    a,b = np.asarray(truth),np.asarray(crop)
    return float(np.maximum(0,np.minimum(a[2:],b[2:])-np.maximum(a[:2],b[:2])).prod() /
                 max(1e-12,np.maximum(0,a[2:]-a[:2]).prod()))


def expanded(box, width, height, margin=.02):
    # Matches an outward-rounded crop with two percent original-image margin.
    x1,y1,x2,y2=box
    return [max(0,math.floor(x1-width*margin)),max(0,math.floor(y1-height*margin)),
            min(width,math.ceil(x2+width*margin)),min(height,math.ceil(y2+height*margin))]


def metrics(rows, predictions, threshold=.35, overlap=.75, class_id=4, compounds_only=False):
    tp=fp=fn=complete=images=0; retention=[]; groups=collections.defaultdict(lambda:[0,0,0])
    failures=[]
    for row, predictions_for_image in zip(rows,predictions):
        gt=[b['box'] for b in row['boxes'] if b['class']==class_id]
        if compounds_only and sum(b['class']==4 for b in row['boxes'])<2:continue
        pr=[b for b in predictions_for_image if b['class']==class_id and b['score']>=threshold]
        matrix=ious(gt,[b['box'] for b in pr])
        matches=[]
        if len(gt) and len(pr):
            # Maximize count of qualifying matches first, IoU second.
            a,b=linear_sum_assignment(-((matrix>=overlap).astype(float)*10+matrix))
            matches=[(i,j) for i,j in zip(a,b) if matrix[i,j]>=overlap]
        n=len(matches); tp+=n; fp+=len(pr)-n; fn+=len(gt)-n; images+=1
        complete+=int(n==len(gt) and n==len(pr))
        g=groups[row['group']];g[0]+=n;g[1]+=len(pr)-n;g[2]+=len(gt)-n
        for i,j in matches:retention.append(retained(gt[i],expanded(pr[j]['box'],row['width'],row['height'])))
        if n!=len(gt) or n!=len(pr):failures.append({'id':row['id'],'truth':len(gt),'predicted':len(pr),'matched':n})
    precision=tp/max(1,tp+fp);recall=tp/max(1,tp+fn)
    return {'threshold':threshold,'iou':overlap,'class':CLASSES[class_id],'images':images,
            'tp':tp,'fp':fp,'fn':fn,'precision':precision,'recall':recall,'false_crop_fraction':fp/max(1,tp+fp),
            'f1':2*precision*recall/max(1e-12,precision+recall),'all_correct_images':complete,
            'annotated_box_retention_mean':float(np.mean(retention)) if retention else None,
            'matched_boxes_at_least_99pct_retained':sum(x>=.99 for x in retention),
            'retention_denominator':len(retention),'paper_group_counts':dict(groups),'failures':failures}


def average_precision(rows,predictions,class_id,overlap=.5):
    truths=[[b['box'] for b in r['boxes'] if b['class']==class_id] for r in rows]
    total=sum(map(len,truths))
    if not total:return None
    used=[set() for _ in rows];tp=[];fp=[]
    all_pred=sorted([(p['score'],i,p['box']) for i,ps in enumerate(predictions) for p in ps if p['class']==class_id],reverse=True)
    for _,i,box in all_pred:
        m=ious([box],truths[i])[0]
        available=[j for j in range(len(m)) if j not in used[i]]
        j=max(available,key=lambda x:m[x]) if available else -1
        hit=j>=0 and m[j]>=overlap
        if hit:used[i].add(j)
        tp.append(int(hit));fp.append(int(not hit))
    t=np.cumsum(tp);f=np.cumsum(fp);rec=t/total;prec=t/np.maximum(1,t+f)
    return float(np.mean([np.max(prec[rec>=r]) if np.any(rec>=r) else 0 for r in np.linspace(0,1,101)]))


def summarize(rows,predictions,threshold,select_threshold=True):
    result={'panel':metrics(rows,predictions,threshold),'compound_panel':metrics(rows,predictions,threshold,compounds_only=True),
            'panel_iou50':metrics(rows,predictions,threshold,overlap=.5),
            'classes':{},'images':len(rows)}
    if select_threshold:
        sweep=[]
        for t in (.1,.15,.2,.25,.3,.35,.4,.45,.5,.6,.7,.8):
            compound=metrics(rows,predictions,t,compounds_only=True)
            all_panels=metrics(rows,predictions,t)
            sweep.append({**compound,'all_figures':{k:all_panels[k] for k in
                ('tp','fp','fn','precision','recall','false_crop_fraction','f1')}})
        # This branch is never run on the final test, even incidentally.
        acceptable=[m for m in sweep if m['false_crop_fraction']<.02 and
                    m['all_figures']['false_crop_fraction']<.02 and m['tp']>0]
        selected=max(acceptable,key=lambda m:min(m['recall'],m['all_figures']['recall'])) if acceptable else max(
            sweep,key=lambda m:min(m['f1'],m['all_figures']['f1']))
        result.update(selected_validation_threshold=selected['threshold'],
            threshold_sweep=[{k:v for k,v in m.items() if k not in ('failures','paper_group_counts')} for m in sweep])
    for c in range(5):
        result['classes'][CLASSES[c]]={'ap50':average_precision(rows,predictions,c),
            'ap75':average_precision(rows,predictions,c,.75),
            'at_threshold':metrics(rows,predictions,threshold,class_id=c)}
    return result


def containment_loss(predicted,truth):
    """Penalize inward edges relative to each matched target's own size.

    Inputs are normalized cx/cy/w/h boxes. The ordinary L1 and GIoU losses remain
    active to discourage oversized rectangles. This additional term addresses
    the observed loss of small white label margins; it is not a containment proof.
    """
    if not len(predicted):return predicted.sum()*0
    p0=predicted[:,:2]-predicted[:,2:]/2;p1=predicted[:,:2]+predicted[:,2:]/2
    g0=truth[:,:2]-truth[:,2:]/2;g1=truth[:,:2]+truth[:,2:]/2
    return ((torch.relu(p0-g0)+torch.relu(g1-p1))/truth[:,2:].clamp_min(1e-6)).sum(-1).mean()


def matched_containment_loss(output,targets,matcher):
    final={k:output[k] for k in ('pred_boxes','pred_logits')}
    indices=matcher(final,targets)['indices']
    predicted=torch.cat([output['pred_boxes'][i,a] for i,(a,_) in enumerate(indices)])
    truth=torch.cat([t['boxes'][b] for t,(_,b) in zip(targets,indices)])
    return containment_loss(predicted,truth)


@torch.inference_mode()
def predict(model,loader,device):
    model.eval();results=[None]*len(loader.dataset);elapsed=[]
    for images,_,ids,transforms in loader:
        start=time.perf_counter();out=model(images.to(device,non_blocking=True))
        scores,labels=out['pred_logits'].sigmoid().max(-1)
        boxes=out['pred_boxes'].cpu().float().numpy();scores=scores.cpu().float().numpy();labels=labels.cpu().numpy()
        elapsed.append((time.perf_counter()-start)/len(ids))
        for batch_i,(i,tr) in enumerate(zip(ids,transforms)):
            sx,sy,left,top=tr;row=loader.dataset.rows[i];records=[]
            for score,label,box in zip(scores[batch_i],labels[batch_i],boxes[batch_i]):
                if score<.03:continue
                cx,cy,bw,bh=box*loader.dataset.size
                raw=[(cx-bw/2-left)/sx,(cy-bh/2-top)/sy,(cx+bw/2-left)/sx,(cy+bh/2-top)/sy]
                b=[max(0.,float(raw[0])),max(0.,float(raw[1])),min(float(row['width']),float(raw[2])),min(float(row['height']),float(raw[3]))]
                if not np.isfinite(b).all() or b[2]<=b[0] or b[3]<=b[1]:continue
                records.append({'class':int(label),'score':float(score),'box':b})
            results[i]=records
    return results,float(np.median(elapsed))*1000


def build_model(repo,weights,classes=5,size=640):
    rev=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
    dirty=subprocess.check_output(['git','-C',str(repo),'status','--porcelain','--untracked-files=no'],text=True)
    if rev!=REPO_REVISION or dirty:raise ValueError('Expected pinned clean upstream detector')
    sys.path.insert(0,str(repo/'rtdetrv2_pytorch'))
    from src.core import YAMLConfig
    cfg=YAMLConfig(str(repo/'rtdetrv2_pytorch/configs/rtdetrv2/rtdetrv2_r18vd_120e_coco.yml'))
    cfg.yaml_cfg.update(num_classes=classes,remap_mscoco_category=False,eval_spatial_size=[size,size])
    cfg.yaml_cfg['PResNet']['pretrained']=False
    model=cfg.model
    checkpoint=torch.load(weights,map_location='cpu',weights_only=True)
    source=checkpoint['ema']['module'] if 'ema' in checkpoint else checkpoint['model']
    current=model.state_dict();compatible={k:v for k,v in source.items() if k in current and v.shape==current[k].shape}
    missing=[k for k in current if k not in compatible]
    # These buffers are deterministic grids derived from input shape, not learned parameters.
    # Source and target can intentionally use different resolutions in a declared ablation.
    shape_buffers={'decoder.anchors','decoder.valid_mask'}
    learned_missing=[k for k in missing if k not in shape_buffers]
    if sha(weights)==COCO_SHA:
        allowed=('decoder.enc_score_head.','decoder.dec_score_head.','decoder.denoising_class_embed.')
        if any(not k.startswith(allowed) for k in learned_missing):raise ValueError(f'Unexpected missing pretrained parameters: {missing}')
    elif learned_missing:raise ValueError(f'Fine-tuned checkpoint shape mismatch: {missing}')
    model.load_state_dict(compatible,strict=not missing)
    return model,cfg.criterion,checkpoint,missing


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--repo',type=Path,required=True)
    p.add_argument('--data',type=Path,required=True);p.add_argument('--weights',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--epochs',type=int,default=30)
    p.add_argument('--batch',type=int,default=8);p.add_argument('--workers',type=int,default=4)
    p.add_argument('--lr',type=float,default=.0002);p.add_argument('--seed',type=int,default=20261018)
    p.add_argument('--freeze-epochs',type=int,default=3);p.add_argument('--backbone',choices=('frozen','last','all'),default='last')
    p.add_argument('--max-hours',type=float,default=3);p.add_argument('--patience',type=int,default=10)
    p.add_argument('--threshold',type=float,default=.35);p.add_argument('--limit',type=int)
    p.add_argument('--evaluate',choices=('validation','test'));p.add_argument('--acknowledge-final-test',action='store_true')
    p.add_argument('--resume',action='store_true');p.add_argument('--amp',action='store_true')
    p.add_argument('--compound-weight',type=float,default=1.,help='Training sampler weight for multi-panel figures')
    p.add_argument('--containment-weight',type=float,default=0.,help='Additional inward-edge loss; ablate against zero')
    p.add_argument('--selection',choices=('all','compound'),default='all',help='Validation population for checkpoint AP')
    p.add_argument('--size',type=int,default=640,choices=(640,960,1280),help='Declared input-resolution ablation')
    p.add_argument('--spatial-jitter',action='store_true',help='Training-only zoom out/translation; preserve all image pixels')
    args=p.parse_args()
    if args.evaluate=='test' and not args.acknowledge_final_test:raise ValueError('Final test requires explicit acknowledgment')
    if args.out.exists() and not args.resume:raise ValueError('Run directory exists; choose a new run or resume')
    args.out.mkdir(parents=True,exist_ok=args.resume)
    random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed);torch.set_num_threads(4)
    device=torch.device('cuda');torch.backends.cudnn.benchmark=False
    if not torch.cuda.is_available():raise RuntimeError('Explicit GPU job; no silent CPU fallback')
    manifest=json.loads((args.data/'manifest.json').read_text())
    for filename,digest in manifest['files'].items():
        if sha(args.data/filename)!=digest:raise ValueError('Changed immutable split')
    all_splits={s:[json.loads(x) for x in (args.data/f'{s}.jsonl').read_text().splitlines()] for s in ('train','validation','test')}
    for a,b in (('train','validation'),('train','test'),('validation','test')):
        for field in ('group','paper','sha256'):
            if {x[field] for x in all_splits[a]} & {x[field] for x in all_splits[b]}:raise ValueError(f'Split leakage: {field}')
    model,criterion,initial,missing=build_model(args.repo,args.weights,size=args.size)
    model.to(device);criterion.to(device)
    meta={'args':{k:str(v) if isinstance(v,Path) else v for k,v in vars(args).items()},
          'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'script_sha256':sha(__file__),
          'data_manifest_sha256':sha(args.data/'manifest.json'),'initial_weights_sha256':sha(args.weights),
          'upstream_revision':REPO_REVISION,'torch':str(torch.__version__),'gpu':torch.cuda.get_device_name(0),
          'new_parameters':missing,'distribution_allowed':False,'deployment_qualified':False,
          'preprocessing':f'RGB bilinear aspect-fit {args.size} square; white padding; exact rounded x/y scale; NCHW float32 /255',
          'metric_limit':'Annotated box coverage is not independent critical-label/legend completeness review.'}
    write_json(args.out/('resume-provenance-'+str(int(time.time()))+'.json' if args.resume else 'provenance.json'),meta)
    # Keep the actual source beside its evidence even if a later iteration edits the working script.
    (args.out/'training-source.py').write_bytes(Path(__file__).read_bytes())
    val=Figures(args.root,args.data,args.evaluate or 'validation',limit=args.limit,size=args.size)
    val_loader=DataLoader(val,batch_size=args.batch,collate_fn=collate,num_workers=args.workers,pin_memory=True)
    if args.evaluate:
        predictions,ms=predict(model,val_loader,device)
        report=summarize(val.rows,predictions,args.threshold,select_threshold=args.evaluate!='test')
        report.update(inference_ms_per_image=ms,weights_sha256=sha(args.weights),split=args.evaluate)
        write_json(args.out/'metrics.json',report)
        write_json(args.out/'predictions.json',prediction_records(val.rows,predictions))
        print(json.dumps({k:report['compound_panel'][k] for k in ('recall','precision','tp','fp','fn')}),flush=True);return
    train=Figures(args.root,args.data,'train',augment=True,limit=args.limit,size=args.size,spatial_jitter=args.spatial_jitter)
    generator=torch.Generator().manual_seed(args.seed)
    if args.compound_weight<=0:raise ValueError('Sampling weight must be positive')
    weights=[args.compound_weight if sum(b['class']==4 for b in r['boxes'])>1 else 1. for r in train.rows]
    sampler=WeightedRandomSampler(weights,len(train),replacement=True,generator=generator) if args.compound_weight!=1 else None
    loader=DataLoader(train,batch_size=args.batch,shuffle=sampler is None,sampler=sampler,collate_fn=collate,num_workers=args.workers,
                      worker_init_fn=seed_worker,generator=generator,pin_memory=True,drop_last=True)
    backbone=[];other=[]
    for name,parameter in model.named_parameters():(backbone if name.startswith('backbone.') else other).append(parameter)
    optimizer=torch.optim.AdamW([{'params':other,'lr':args.lr,'base_lr':args.lr},
                                {'params':backbone,'lr':args.lr*.1,'base_lr':args.lr*.1}],weight_decay=.0001)
    ema=copy.deepcopy(model).eval()
    for parameter in ema.parameters():parameter.requires_grad_(False)
    best=-1.;start_epoch=0;updates=0;stale=0;clock=time.monotonic()
    if args.resume:
        optimizer.load_state_dict(initial['optimizer']);start_epoch=initial['epoch']+1
        best=initial['best_score'];updates=initial['updates'];stale=initial.get('stale',0)
        model.load_state_dict(initial['model']);ema.load_state_dict(initial['ema']['module'])
        torch.set_rng_state(initial['torch_rng']);torch.cuda.set_rng_state_all(initial['cuda_rng'])
        generator.set_state(initial['loader_rng']);random.setstate(initial['python_rng'])
    del initial
    if args.containment_weight<0:raise ValueError('Containment weight cannot be negative')
    epochs_completed=start_epoch
    for epoch in range(start_epoch,args.epochs):
        if time.monotonic()-clock>args.max_hours*3600:break
        for name,parameter in model.backbone.named_parameters():
            enabled=epoch>=args.freeze_epochs and (args.backbone=='all' or (args.backbone=='last' and name.startswith('res_layers.3.')))
            parameter.requires_grad_(enabled)
        model.train();model.backbone.eval()  # Keep pretrained BN statistics stable on small scientific batches.
        start=time.monotonic();losses=[]
        factor=.1+.9*(1+math.cos(math.pi*epoch/max(1,args.epochs)))/2
        for pg in optimizer.param_groups:pg['lr']=pg['base_lr']*factor
        for step,(images,targets,_,_) in enumerate(loader):
            if time.monotonic()-clock>args.max_hours*3600:break
            images=images.to(device,non_blocking=True)
            targets=[{k:v.to(device,non_blocking=True) for k,v in t.items()} for t in targets]
            optimizer.zero_grad(set_to_none=True)
            with torch.autocast('cuda',dtype=torch.bfloat16,enabled=args.amp):output=model(images,targets)
            def fp32(x):
                if isinstance(x,torch.Tensor) and x.is_floating_point():return x.float()
                if isinstance(x,dict):return {k:fp32(v) for k,v in x.items()}
                if isinstance(x,list):return [fp32(v) for v in x]
                return x
            loss_dict=criterion(fp32(output),targets,epoch=epoch,step=step,global_step=updates)
            if args.containment_weight:
                loss_dict['loss_containment']=args.containment_weight*matched_containment_loss(fp32(output),targets,criterion.matcher)
            loss=sum(loss_dict.values())
            if not torch.isfinite(loss):raise FloatingPointError('Non-finite training loss; stopping')
            loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),.1,error_if_nonfinite=True);optimizer.step()
            updates+=1;decay=.9999*(1-math.exp(-updates/2000))
            with torch.no_grad():
                model_state=model.state_dict()
                for k,value in ema.state_dict().items():
                    source=model_state[k]
                    if value.is_floating_point():value.mul_(decay).add_(source,alpha=1-decay)
                    else:value.copy_(source)
            losses.append(float(loss.detach()))
            if step%50==0:print(json.dumps({'epoch':epoch,'step':step,'steps':len(loader),'loss':losses[-1],
                                           'vram_gb':torch.cuda.max_memory_allocated()/1e9}),flush=True)
        predictions,ms=predict(ema,val_loader,device);report=summarize(val.rows,predictions,args.threshold)
        if not losses:break
        if args.selection=='compound':
            chosen=[(r,ps) for r,ps in zip(val.rows,predictions) if sum(b['class']==4 for b in r['boxes'])>1]
            cr,cp=map(list,zip(*chosen))
            panel={'ap50':average_precision(cr,cp,4),'ap75':average_precision(cr,cp,4,.75)}
            report['compound_panel_ap']=panel
        else:panel=report['classes']['panel']
        score=(panel['ap50']+panel['ap75'])/2
        improved=score>best
        if improved:best=score;stale=0
        else:stale+=1
        report.update(epoch=epoch,score=score,loss_mean=float(np.mean(losses)),epoch_seconds=time.monotonic()-start,
                      elapsed_seconds=time.monotonic()-clock,inference_ms_per_image=ms,peak_vram_bytes=torch.cuda.max_memory_allocated())
        try:
            values=subprocess.check_output(['nvidia-smi','--query-gpu=temperature.gpu,power.draw,memory.used,utilization.gpu',
                '--format=csv,noheader,nounits'],text=True,timeout=5).strip().splitlines()[0].split(',')
            report['gpu_sample']={k:float(v) for k,v in zip(('temperature_c','power_w','used_vram_mib','utilization_pct'),values)}
            with (args.out/'resources.jsonl').open('a') as f:f.write(json.dumps({'epoch':epoch,'utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),**report['gpu_sample']})+'\n')
            if report['gpu_sample']['temperature_c']>=85:raise RuntimeError('GPU reached the bounded research temperature limit')
        except (OSError,subprocess.SubprocessError,ValueError):
            report['gpu_sample']={'unavailable':True}
        write_json(args.out/'latest-metrics.json',report)
        brief={k:report[k] for k in ('epoch','score','loss_mean','epoch_seconds','elapsed_seconds')}
        brief.update({k:report['compound_panel'][k] for k in ('recall','precision','tp','fp','fn')})
        brief['best']=best;brief['selected_threshold']=report['selected_validation_threshold']
        with (args.out/'epochs.jsonl').open('a') as f:f.write(json.dumps(brief)+'\n')
        print(json.dumps(brief),flush=True)
        checkpoint={'model':model.state_dict(),'ema':{'module':ema.state_dict()},'optimizer':optimizer.state_dict(),
                    'epoch':epoch,'best_score':best,'updates':updates,'stale':stale,'meta':meta,
                    'torch_rng':torch.get_rng_state(),'cuda_rng':torch.cuda.get_rng_state_all(),
                    'loader_rng':generator.get_state(),'python_rng':random.getstate()}
        temporary=args.out/'last.tmp';torch.save(checkpoint,temporary);temporary.replace(args.out/'last.pth')
        if improved:
            torch.save({'model':ema.state_dict(),'epoch':epoch,'meta':meta},args.out/'best.pth')
            write_json(args.out/'best-metrics.json',report)
            write_json(args.out/'best-predictions.json',prediction_records(val.rows,predictions))
        epochs_completed=epoch+1
        if stale>=args.patience:break
    write_json(args.out/'completion.json',{'finished_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
        'elapsed_seconds':time.monotonic()-clock,'best_score':best,'epochs_completed':epochs_completed,
        'peak_vram_bytes':torch.cuda.max_memory_allocated(),'strong_performance_qualified':False})


if __name__=='__main__':main()
