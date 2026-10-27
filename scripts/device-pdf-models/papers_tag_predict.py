"""Predict variable-length journal inputs without padding; uses the frozen v5 architecture."""
import argparse,importlib.util,json,hashlib
from collections import defaultdict
from pathlib import Path
import numpy as np
import torch

p=argparse.ArgumentParser();p.add_argument('--inputs',type=Path,required=True);p.add_argument('--checkpoint',type=Path,required=True)
p.add_argument('--training-source',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
spec=importlib.util.spec_from_file_location('training',a.training_source);T=importlib.util.module_from_spec(spec);spec.loader.exec_module(T)
torch.set_num_threads(4)
ck=torch.load(a.checkpoint,map_location='cpu',weights_only=False)
model=T.Tagger(ck.get('n_feats',12),ck.get('hidden',96));model.load_state_dict(ck['model']);model.cuda().eval()
inputs=json.loads(a.inputs.read_text());groups=defaultdict(list);outputs=[None]*len(inputs)
for i,row in enumerate(inputs):groups[len(row['font'])].append(i)
with torch.no_grad():
 for length,indices in sorted(groups.items()):
  for start in range(0,len(indices),min(256,max(1,24000//length))):
   chosen=indices[start:start+min(256,max(1,24000//length))]
   batch=[inputs[i] for i in chosen]
   x=torch.tensor([r['x'] for r in batch],dtype=torch.float32,device='cuda').reshape(len(batch),length,-1)
   ints=[torch.tensor([r[k] for r in batch],dtype=torch.int64,device='cuda') for k in ['font','cls','char']]
   logits=model(x,*ints).cpu().numpy()
   for i,row in zip(chosen,logits):outputs[i]=[float(v) for v in row]
assert all(o is not None and len(o)==len(r['font']) for o,r in zip(outputs,inputs))
a.out.write_text(json.dumps({'checkpoint_sha256':hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),
                            'inputs_sha256':hashlib.sha256(a.inputs.read_bytes()).hexdigest(),'logits':outputs}))
print(json.dumps({'inputs':len(outputs),'glyphs':sum(map(len,outputs))}))
