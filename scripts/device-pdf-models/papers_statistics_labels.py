"""Propose conservative, partially supervised statistics labels; proposals are not human gold.

A mask of -1 means unknown. Positive proposals target single-line variable/comparison/numeric
expressions; typography can still make a proposal incomplete. Plain prose supplies negatives.
Source crops must be reviewed separately before any proposal is used as evaluation gold.
"""
import argparse
import json
from pathlib import Path
import re
import unicodedata

NUMBER=r'[+−-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+−-]?\d+)?'
STAT=re.compile(r'(?<!\w)(?:[pPtTFFrRnNzZβχ]|χ[²2])\s*(?:\(\s*\d+(?:\s*,\s*\d+)*\s*\))?\s*(?:[=<>≤≥≈]|\(cid:\d+\))\s*'+NUMBER)
SYMBOL=re.compile(r'[=<>≤≥±≈×÷∑∏∫√^_]|\(cid:|[\u0370-\u03ff]')


def aligned(row):
    lookup=[]; flat=[]
    for i,g in enumerate(row['glyphs']):
        for ch in unicodedata.normalize('NFKC',g['text']):
            if not ch.isspace(): flat.append(ch);lookup.append(i)
    text=unicodedata.normalize('NFKC',row['text'])
    if ''.join(flat)!=''.join(text.split()): return None
    mapped=[];j=0
    for ch in text:
        if ch.isspace(): mapped.append(None)
        else: mapped.append(lookup[j]);j+=1
    return text,mapped


def propose(row):
    mapping=aligned(row)
    if not mapping:return None
    text,ids=mapping;spans=[]
    for match in STAT.finditer(text):
        # A coordinate triple is one expression; its last assignment is not an atomic statistic.
        if re.search(r'x\s*,\s*y\s*,\s*$',text[:match.start()]):
            continue
        if match.group().startswith(('z','Z')) and '.' not in match.group():
            continue  # A continued integer coordinate assignment, not a complete z statistic.
        covered=[i for i in ids[match.start():match.end()] if i is not None]
        if not covered:continue
        a,b=min(covered),max(covered)+1
        spans.append({'from':a,'to':b,'text':match.group(),'source':'native-statistics-pattern-v1'})
    mask=[-1]*len(row['glyphs'])
    # Long alphabetic words are prose even in a partly labelled mathematical line.
    for match in re.finditer(r'(?<!\w)[A-Za-z]{4,}(?!\w)',text):
        for i in ids[match.start():match.end()]:
            if i is not None:mask[i]=0
    pure_prose=(not SYMBOL.search(text) and not re.search(r'\d|\b[b-hj-zB-HJ-Z]\b',text)
                and len(re.findall(r'[A-Za-z]{3,}',text))>=5)
    if pure_prose:mask=[0]*len(row['glyphs'])
    for span in spans:
        mask[span['from']:span['to']]=[1]*(span['to']-span['from'])
    if not spans and not pure_prose:return None
    return {**row,'proposed_spans':spans,'mask':mask,'pure_prose':pure_prose,'label_status':'weak_training_proposal'}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('lines',type=Path);p.add_argument('out',type=Path);a=p.parse_args()
    rows=[propose(r) for r in map(json.loads,a.lines.read_text().splitlines())];rows=[r for r in rows if r]
    a.out.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    print(json.dumps({'lines':len(rows),'positive_lines':sum(bool(r['proposed_spans']) for r in rows),
                      'proposed_spans':sum(len(r['proposed_spans']) for r in rows),
                      'prose_lines':sum(r['pure_prose'] for r in rows),'papers':len(set(r['paper'] for r in rows))}))
