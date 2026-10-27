"""Pack masked native training windows; preserve paper and line provenance."""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('inputs',type=Path);p.add_argument('labels',type=Path);p.add_argument('out',type=Path);a=p.parse_args()
inputs=json.loads(a.inputs.read_text());rows=list(map(json.loads,a.labels.read_text().splitlines()))
xs=[];fs=[];cs=[];chs=[];ys=[];starts=[0];ids=[];papers=[];positives=[]
for r in rows:
 for w in r['windows']:
  entry=inputs[w['index']];length=len(entry['font']);mask=np.full(length,-1,dtype=np.int8)
  mask[w['own'][0]:w['own'][1]]=r['mask'][w['from']:w['to']]
  if not np.any(mask>=0):continue
  xs.append(np.asarray(entry['x'],dtype=np.float32).reshape(length,12));fs.append(np.asarray(entry['font'],dtype=np.int16))
  cs.append(np.asarray(entry['cls'],dtype=np.int8));chs.append(np.asarray(entry['char'],dtype=np.int16));ys.append(mask)
  starts.append(starts[-1]+length);ids.append(r['id']);papers.append(r['paper']);positives.append(bool(np.any(mask==1)))
np.savez_compressed(a.out,x=np.concatenate(xs),font=np.concatenate(fs),cls=np.concatenate(cs),char=np.concatenate(chs),
                    y=np.concatenate(ys),start=np.asarray(starts,dtype=np.int64),positive=np.asarray(positives),ids=np.asarray(ids),papers=np.asarray(papers))
summary={'windows':len(ids),'papers':len(set(papers)),'glyphs_including_context':starts[-1],
 'positive_windows':sum(positives),'positive_glyphs':sum(int((y==1).sum()) for y in ys),'negative_glyphs':sum(int((y==0).sum()) for y in ys),
 'inputs_sha256':hashlib.sha256(a.inputs.read_bytes()).hexdigest(),'labels_sha256':hashlib.sha256(a.labels.read_bytes()).hexdigest(),
 'packed_sha256':hashlib.sha256(a.out.read_bytes()).hexdigest(),'label_status':'weak, partial, source-text-derived; not evaluation gold'}
a.out.with_suffix('.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
