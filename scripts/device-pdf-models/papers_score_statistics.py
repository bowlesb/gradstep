"""Fixed positive-span recall and fully labelled prose controls; never infer unlabeled maths is wrong."""
import argparse,hashlib,json,math,random
from collections import defaultdict
from pathlib import Path

def score(rows,outputs,threshold,decoded_spans=None):
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
        if decoded_spans is not None:
            found=decoded_spans[row['id']]
            assert all(0<=a<b<=len(logits) for a,b in found)
            assert all(found[i-1][1]<=found[i][0] for i in range(1,len(found)))
            pred=[any(a<=i<b for a,b in found) for i in range(len(logits))]
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


def paired_paper_bootstrap(baseline,candidate,replicates=10000,seed=2711):
    """Resample papers, not correlated glyphs or expressions; report undefined error-reduction draws."""
    assert replicates>0
    papers=sorted(baseline['by_paper']);assert papers and papers==sorted(candidate['by_paper'])
    groups=[]
    for paper in papers:
        a,b=baseline['by_paper'][paper],candidate['by_paper'][paper]
        assert a['gold']==b['gold'] and a['gold']>0
        groups.append((a['gold'],a['complete'],b['complete']))
    rng=random.Random(seed);deltas=[];reductions=[];macro=[];undefined=0
    for _ in range(replicates):
        sample=rng.choices(groups,k=len(groups));gold=sum(r[0] for r in sample)
        before=sum(r[1] for r in sample);after=sum(r[2] for r in sample)
        deltas.append((after-before)/gold)
        macro.append(sum((c-b)/g for g,b,c in sample)/len(sample))
        if gold>before:reductions.append((after-before)/(gold-before))
        else:undefined+=1
    def interval(values):
        if not values:return None
        values=sorted(values)
        def q(p):
            x=p*(len(values)-1);i=int(x);return values[i]+(values[min(i+1,len(values)-1)]-values[i])*(x-i)
        return [q(.025),q(.975)]
    errors=baseline['gold_statistics']-baseline['complete_statistics']
    return {'unit':'paper','papers_with_positive_gold':len(groups),'expressions':baseline['gold_statistics'],
            'replicates':replicates,'seed':seed,'confidence':0.95,'method':'paired percentile bootstrap',
            'complete_recall_delta':candidate['complete_recall']-baseline['complete_recall'],
            'complete_recall_delta_interval':interval(deltas),
            'paper_macro_recall_delta':candidate['paper_macro_recall']-baseline['paper_macro_recall'],
            'paper_macro_recall_delta_interval':interval(macro),
            'relative_incomplete_reduction':(candidate['complete_statistics']-baseline['complete_statistics'])/errors if errors else None,
            'relative_incomplete_reduction_interval':interval(reductions),'draws_without_baseline_errors':undefined}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('gold',type=Path);p.add_argument('predictions',type=Path);p.add_argument('out',type=Path)
    p.add_argument('--inputs',type=Path,help='Verify the prediction input digest and every exact sequence length.')
    p.add_argument('--decoded-spans',type=Path,help='Explicit decoder audit; preserves the original model logits.')
    p.add_argument('--baseline',type=Path,help='Predictions on the identical inputs for paired paper-bootstrap intervals.')
    p.add_argument('--bootstrap-replicates',type=int,default=10000);p.add_argument('--bootstrap-seed',type=int,default=2711)
    p.add_argument('--thresholds',default='0.7');a=p.parse_args()
    rows=list(map(json.loads,a.gold.read_text().splitlines()));pred=json.loads(a.predictions.read_text())
    decoded=json.loads(a.decoded_spans.read_text()) if a.decoded_spans else None
    if decoded is not None:
        assert decoded['predictions_sha256']==hashlib.sha256(a.predictions.read_bytes()).hexdigest()
        assert [float(t) for t in a.thresholds.split(',')]==[decoded['threshold']]
    if a.inputs:
        assert pred['inputs_sha256']==hashlib.sha256(a.inputs.read_bytes()).hexdigest(), 'input digest mismatch'
        inputs=json.loads(a.inputs.read_text())
        assert len(inputs)==len(pred['logits'])
        assert all(len(i['font'])==len(o) for i,o in zip(inputs,pred['logits']))
    result={'gold_sha256':hashlib.sha256(a.gold.read_bytes()).hexdigest(),'checkpoint_sha256':pred['checkpoint_sha256'],
            'inputs_sha256':pred.get('inputs_sha256'),'decoded_spans_sha256':hashlib.sha256(a.decoded_spans.read_bytes()).hexdigest() if a.decoded_spans else None,
            'scores':[score(rows,pred['logits'],float(t),decoded['decoded_spans'] if decoded else None) for t in a.thresholds.split(',')]}
    if a.baseline:
        base=json.loads(a.baseline.read_text())
        assert base.get('inputs_sha256') and base['inputs_sha256']==pred.get('inputs_sha256')
        assert len(base['logits'])==len(pred['logits']) and all(len(x)==len(y) for x,y in zip(base['logits'],pred['logits']))
        result['baseline_sha256']=hashlib.sha256(a.baseline.read_bytes()).hexdigest()
        result['paired_paper_bootstrap']=[paired_paper_bootstrap(score(rows,base['logits'],s['threshold']),s,a.bootstrap_replicates,a.bootstrap_seed) for s in result['scores']]
    a.out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps([{k:v for k,v in row.items() if k not in ['by_paper','errors']} for row in result['scores']]))
