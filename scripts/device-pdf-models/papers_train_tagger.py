"""Adapt v5a on partial journal labels with replay of original, disjoint training papers.

Exact-length batches preserve the model's bidirectional input contract. Journal labels
never train on unknown glyphs or neighbouring context. No evaluation family is loaded.
"""
import argparse,copy,hashlib,json,random,time
from collections import defaultdict
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F


from training_core import tagger as T, source_identity
import evaluate_tagger_coverage as E


def complete_expression_loss(prediction, target):
    """Mean worst-positive loss per contiguous labeled expression; unknown/context glyphs never enter it.

    BCE can look excellent while one operator or final digit is missing. This objective preserves the same
    architecture and emphasizes that weakest glyph. It does not infer any extra labels or change inference.
    """
    positive=target==1
    begins=positive & torch.cat([torch.ones_like(positive[:,:1]),~positive[:,:-1]],dim=1)
    groups=begins.reshape(-1).long().cumsum(0).sub(1).clamp_min(0)
    losses=F.softplus(-prediction).where(positive,0).reshape(-1)
    worst=torch.zeros_like(losses).scatter_reduce(0,groups,losses,reduce='amax',include_self=True)
    return worst.sum()/begins.sum().clamp_min(1)


def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--training-root',type=Path,required=True)
    p.add_argument('--checkpoint',type=Path,required=True);p.add_argument('--run',type=Path,required=True)
    p.add_argument('--steps',type=int,default=3000);p.add_argument('--lr',type=float,default=0.0001)
    p.add_argument('--replay',type=float,default=0.6);p.add_argument('--font-dropout',type=float,default=0.15)
    p.add_argument('--distill',type=float,default=0.0)
    p.add_argument('--native-distill',type=float,default=0.0,help='Preserve teacher outputs on unlabeled own glyphs, without treating them as negatives.')
    p.add_argument('--complete-span-weight',type=float,default=0.0)
    p.add_argument('--threshold',type=float,default=0.7,help='Recorded inference threshold; never tuned by this training command.')
    p.add_argument('--replay-papers',type=int,default=180);p.add_argument('--replay-items',type=int,default=45000)
    p.add_argument('--save-steps',default='500,1500')
    p.add_argument('--seed',type=int,default=727);a=p.parse_args();a.run.mkdir(parents=True,exist_ok=False)
    torch.set_num_threads(4);torch.manual_seed(a.seed);random.seed(a.seed);rng=np.random.default_rng(a.seed)
    ck=torch.load(a.checkpoint,map_location='cpu',weights_only=False)
    model=T.Tagger(12,ck.get('hidden',96));model.load_state_dict(ck['model']);model.cuda().train()
    assert a.distill>=0 and a.native_distill>=0 and a.complete_span_weight>=0 and 0<a.threshold<1
    teacher=copy.deepcopy(model).eval().requires_grad_(False) if a.distill or a.native_distill else None
    source=np.load(a.root/'train.npz',allow_pickle=False)
    native={k:source[k] for k in ['x','font','cls','char','y','start','positive']}
    split_rows=json.loads((a.root/'splits.json').read_text());splits={r['sha256']:r['split'] for r in split_rows}
    assert all(splits[paper]=='train' for paper in source['papers'].tolist())
    ids,_dev,_test=T.load_lists(root=a.training_root)
    ids=sorted(ids,key=lambda x:hashlib.sha256(('journal-replay:'+x).encode()).hexdigest())[:a.replay_papers]
    assert set(ids).isdisjoint(_dev) and set(ids).isdisjoint(_test)
    c=T.Corpus(ids,data_dir=a.training_root/'data');c.encode(ck['vocab'],ck['prior'],ck['cvocab'])
    order=rng.permutation(len(c.items))[:a.replay_items]
    examples=[]
    for item in order:
        for idx,flags,_a,_b in E.windows(c,int(item),int(ck['context']),True):
            if len(idx)<2:continue
            x,f,cl,ch=T.tensors(c,idx,flags,int(ck['context']))
            y=np.where(flags==0,c.y[idx],-1).astype(np.int8)
            examples.append((x,f,cl,ch,y))
    # Buckets contain whole sequences of exactly one length, never padded glyphs.
    buckets={'base':defaultdict(list),'positive':defaultdict(list),'negative':defaultdict(list)}
    pools={'base':[],'positive':[],'negative':[]}
    for i,e in enumerate(examples):
        buckets['base'][len(e[0])].append(i);pools['base'].append((len(e[0]),i))
    for i in range(len(native['start'])-1):
        length=int(native['start'][i+1]-native['start'][i]);kind='positive' if native['positive'][i] else 'negative'
        buckets[kind][length].append(i);pools[kind].append((length,i))
    def batch(kind):
        length,_=pools[kind][int(rng.integers(len(pools[kind])))];indices=buckets[kind][length]
        chosen=rng.choice(indices,size=min(64,len(indices),max(1,12000//length)),replace=False)
        seqs=[]
        for i in chosen:
            if kind=='base':seqs.append(examples[i])
            else:
                s,e=native['start'][i:i+2]
                seqs.append(tuple(native[key][s:e] for key in ['x','font','cls','char','y']))
        x=np.stack([v[0] for v in seqs]).copy();f=np.stack([v[1] for v in seqs]).copy()
        if kind=='base' and rng.random()<a.font_dropout:
            f[:]=0;x[:,:,6:9]=0.04
        values=[x,f,*[np.stack([v[j] for v in seqs]) for j in [2,3,4]]]
        return [torch.tensor(v,device='cuda',dtype=torch.float32 if j in [0,4] else torch.int64) for j,v in enumerate(values)]
    run_info={'source_files_sha256':source_identity(),'base_checkpoint_sha256':hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),
              'native_data_sha256':hashlib.sha256((a.root/'train.npz').read_bytes()).hexdigest(),
              'training_source_sha256':hashlib.sha256(Path(T.__file__).read_bytes()).hexdigest(),
              'native_families':len(set(source['papers'].tolist())),'base_replay_papers':ids,
              'base_replay_sequences':len(examples),'pools':{k:len(v) for k,v in pools.items()},
              'steps':a.steps,'lr':a.lr,'replay_probability':a.replay,'font_dropout':a.font_dropout,'seed':a.seed,
              'distillation_weight':a.distill,'native_unknown_distillation_weight':a.native_distill,
              'complete_span_weight':a.complete_span_weight,'complete_span_objective':'mean maximum softplus(-logit) per contiguous known-positive run',
              'threshold':a.threshold,'save_steps':a.save_steps,
              'selection':'development only; inference threshold fixed by the run contract'}
    (a.run/'train-run.json').write_text(json.dumps(run_info,indent=2)+'\n')
    log=(a.run/'train.log.jsonl').open('w');started=time.monotonic();opt=torch.optim.AdamW(model.parameters(),lr=a.lr,weight_decay=0.01)
    totals=defaultdict(list)
    for step in range(1,a.steps+1):
        sample=rng.random();kind='base' if sample<a.replay else ('positive' if rng.random()<0.7 else 'negative')
        x,f,cl,ch,y=batch(kind);prediction=model(x,f,cl,ch);known=y>=0
        loss=F.binary_cross_entropy_with_logits(prediction,y.clamp(min=0),reduction='none',pos_weight=torch.tensor(2.0,device='cuda'))
        loss=loss[known].mean()
        if kind!='base' and a.complete_span_weight:
            loss=loss+a.complete_span_weight*complete_expression_loss(prediction,y)
        if teacher is not None and kind=='base':
            with torch.no_grad():target=torch.sigmoid(teacher(x,f,cl,ch))
            preservation=F.binary_cross_entropy_with_logits(prediction,target,reduction='none')
            loss=loss+a.distill*preservation[known].mean()
        if teacher is not None and kind!='base' and a.native_distill:
            with torch.no_grad():target=torch.sigmoid(teacher(x,f,cl,ch))
            unknown=(y<0)&(x[:,:,10]==0)&(x[:,:,11]==0)
            preservation=F.binary_cross_entropy_with_logits(prediction,target,reduction='none')
            loss=loss+a.native_distill*(preservation*unknown).sum()/unknown.sum().clamp_min(1)
        opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),1.0);opt.step()
        totals[kind].append(float(loss.detach()))
        if step%100==0:
            row={'step':step,'seconds':round(time.monotonic()-started,1),'loss':{k:round(sum(v)/len(v),5) for k,v in totals.items()}}
            print(json.dumps(row),flush=True);log.write(json.dumps(row)+'\n');log.flush();totals.clear()
        if step in {*(int(s) for s in a.save_steps.split(',')),a.steps}:
            saved={**ck,'model':{k:v.detach().cpu() for k,v in model.state_dict().items()},'threshold':a.threshold,
                   'n_feats':12,'adaptation':{**run_info,'step':step}}
            torch.save(saved,a.run/f'step-{step:05}.pt')
    log.close()
if __name__=='__main__':main()
