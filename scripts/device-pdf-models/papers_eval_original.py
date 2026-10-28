"""Compare adapted checkpoints on the same complete original labelled lines, without truncation or padding."""
import argparse,hashlib,json
from pathlib import Path
import torch

from training_core import tagger as T
import evaluate_tagger_coverage as E

p=argparse.ArgumentParser();p.add_argument('--training-root',type=Path,required=True)
p.add_argument('--split',choices=['dev','test'],default='dev');p.add_argument('--limit',type=int,default=0);p.add_argument('--out',type=Path,required=True)
p.add_argument('--thresholds',default='0.7')
p.add_argument('--checkpoint',action='append',required=True);a=p.parse_args();torch.set_num_threads(4)
ids=[p for p in json.loads((a.training_root/'papers.json').read_text())[a.split] if (a.training_root/'data'/f'{p}.npz').is_file()]
ids=sorted(ids,key=lambda s:hashlib.sha256(('journal-regression-v1:'+s).encode()).hexdigest())
if a.limit:ids=ids[:a.limit]
c=T.Corpus(ids,data_dir=a.training_root/'data');report={'split':a.split,'papers':ids,'glyphs':len(c.y),'items':len(c.items),'rows':{}}
for specification in a.checkpoint:
 name,path=specification.split('=',1);path=Path(path);ck=torch.load(path,map_location='cpu',weights_only=False)
 model=T.Tagger(ck.get('n_feats',12),ck.get('hidden',96));model.load_state_dict(ck['model']);model.cuda().eval()
 c.encode(ck['vocab'],ck['prior'],ck['cvocab']);pred,covered=E.predict(T,model,c,int(ck['context']),True,'cuda')
 assert covered==len(c.y)
 row={'checkpoint_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'covered_glyphs':covered,
      'thresholds':{t:{'all':T.score(c,pred,float(t),None),'text':T.score(c,pred,float(t),{0})} for t in a.thresholds.split(',')}}
 report['rows'][name]=row;a.out.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({'name':name,**row}),flush=True)
 del model,pred
