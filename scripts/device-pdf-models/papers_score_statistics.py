"""Fixed positive-span recall and fully labelled prose controls; never infer unlabeled maths is wrong."""
import argparse,hashlib,json,math
from collections import defaultdict
from pathlib import Path

def score(rows,outputs,threshold):
    limit=math.log(threshold/(1-threshold));by_paper=defaultdict(lambda:{'gold':0,'complete':0})
    controls=0;false_controls=0;details=[]
    for row in rows:
        logits=[None]*len(row['glyphs'])
        for w in row['windows']:
            values=outputs[w['index']]
            assert len(values)>=w['own'][1]
            logits[w['from']:w['to']]=values[w['own'][0]:w['own'][1]]
        assert all(v is not None and math.isfinite(v) for v in logits)
        pred=[v>limit for v in logits];found=[];start=None
        for i,on in enumerate(pred+[False]):
            if on and start is None:start=i
            if not on and start is not None:found.append((start,i));start=None
        if not row['gold_spans']:
            assert row['label_status']=='text_reviewed_prose_control'
            controls+=1;false_controls+=any(pred)
            if any(pred):details.append({'id':row['id'],'error':'false-positive-prose','text':row['text'],'predicted_spans':found})
        else:
            for gold in row['gold_spans']:
                a,b=gold['from'],gold['to'];complete=False
                for pa,pb in found:
                    if pa<=a and pb>=b:
                        # A span cannot earn completeness by swallowing a labelled prose word.
                        spill=sum(row['mask'][i]==0 for i in range(pa,pb))
                        if spill==0:complete=True
                by_paper[row['paper']]['gold']+=1;by_paper[row['paper']]['complete']+=complete
                if not complete:details.append({'id':row['id'],'error':'incomplete-statistic','gold':gold,'predicted_spans':found})
    gold=sum(x['gold'] for x in by_paper.values());complete=sum(x['complete'] for x in by_paper.values())
    return {'threshold':threshold,'gold_statistics':gold,'complete_statistics':complete,'complete_recall':complete/gold if gold else 0,
            'paper_macro_recall':sum(x['complete']/x['gold'] for x in by_paper.values())/len(by_paper) if by_paper else 0,
            'prose_controls':controls,'false_positive_prose_lines':false_controls,'false_positive_prose_line_rate':false_controls/controls if controls else None,
            'by_paper':dict(by_paper),'errors':details}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('gold',type=Path);p.add_argument('predictions',type=Path);p.add_argument('out',type=Path)
    p.add_argument('--inputs',type=Path,help='Verify the prediction input digest and every exact sequence length.')
    p.add_argument('--thresholds',default='0.7');a=p.parse_args()
    rows=list(map(json.loads,a.gold.read_text().splitlines()));pred=json.loads(a.predictions.read_text())
    if a.inputs:
        assert pred['inputs_sha256']==hashlib.sha256(a.inputs.read_bytes()).hexdigest(), 'input digest mismatch'
        inputs=json.loads(a.inputs.read_text())
        assert len(inputs)==len(pred['logits'])
        assert all(len(i['font'])==len(o) for i,o in zip(inputs,pred['logits']))
    result={'gold_sha256':hashlib.sha256(a.gold.read_bytes()).hexdigest(),'checkpoint_sha256':pred['checkpoint_sha256'],
            'inputs_sha256':pred.get('inputs_sha256'),'scores':[score(rows,pred['logits'],float(t)) for t in a.thresholds.split(',')]}
    a.out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps([{k:v for k,v in row.items() if k not in ['by_paper','errors']} for row in result['scores']]))
