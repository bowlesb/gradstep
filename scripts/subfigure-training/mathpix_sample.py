#!/usr/bin/env python3
"""Read-only sampling of the owner's existing Mathpix-replacement research corpus.

Never imports/runs that project's code, changes its service, or writes beneath its
root. Outputs a JSON copy manifest to stdout. PDF parsing/extraction happens on Mac.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while chunk:=f.read(1024*1024):h.update(chunk)
    return h.hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    p.add_argument('--per-category',type=int,default=3);p.add_argument('--max-mib',type=int,default=200)
    args=p.parse_args();root=args.root.resolve();catalog=root/'data/arxiv/papers.jsonl'
    raw=catalog.read_bytes();rows=[json.loads(s) for s in raw.splitlines()]
    allowed={'http://creativecommons.org/licenses/by/4.0/','http://creativecommons.org/publicdomain/zero/1.0/'}
    categories=('Machine Learning','Computer Vision and Pattern Recognition','Artificial Intelligence','Computation and Language')
    known_development={'2610.22350','2610.14704','2610.15542','2610.19844'}
    split_seed='gradstep-subfigure-mathpix-v1:'
    selected=[];total=0;skipped=collections.Counter();used=set()
    files=('arxiv.pdf','arxiv.html','abstract.html','build/plain.pdf','build/labels.json',
           'build/layout-check.json','build/arxiv-compare.json')
    for category in categories:
        ordered=sorted([r for r in rows if r['category']==category],
                       key=lambda r:hashlib.sha256((split_seed+r['family']).encode()).hexdigest())
        for wanted_split,n in (('train',args.per_category-1),('validation',1)):
            found=0
            for r in ordered:
                if found>=n:break
                if r['family'] in used or r['family'] in known_development:continue
                if not re.fullmatch(r'\d{4}\.\d{4,5}v\d+',r['id']):continue
                if r['id'][:4]<'2501' or r['license'] not in allowed or not r['trainable']:continue
                bucket=int(hashlib.sha256((split_seed+r['family']).encode()).hexdigest()[:8],16)%100
                split='train' if bucket<75 else 'validation' if bucket<90 else 'reserved_test'
                if split!=wanted_split:continue
                directory=root/'data/arxiv'/r['id'];paths=[directory/f for f in files]
                if any(not f.is_file() or f.is_symlink() or not f.resolve().is_relative_to(root) for f in paths):
                    skipped['incomplete_or_external']+=1;continue
                sizes=[f.stat().st_size for f in paths]
                if any(f.suffix=='.pdf' and size>12*1024**2 for f,size in zip(paths,sizes)):
                    skipped['pdf_over_12_mib']+=1;continue
                if total+sum(sizes)>args.max_mib*1024**2:
                    skipped['sample_byte_budget']+=1;continue
                records=[];changed=False
                for f,size in zip(paths,sizes):
                    before=f.stat();digest=sha(f);after=f.stat()
                    if (before.st_size,before.st_mtime_ns)!=(after.st_size,after.st_mtime_ns):changed=True;break
                    records.append({'path':str(f.relative_to(root)),'bytes':size,'sha256':digest,'mtime_ns':after.st_mtime_ns})
                if changed:skipped['changed_while_reading']+=1;continue
                if records[0]['sha256']!=r['pdf_sha256'] or records[1]['sha256']!=r['html_sha256']:
                    skipped['catalog_hash_mismatch']+=1;continue
                selected.append({**r,'split':split,'files':records});used.add(r['family']);total+=sum(sizes);found+=1
    print(json.dumps({'source_root':str(root),'catalog_sha256':hashlib.sha256(raw).hexdigest(),
        'catalog_records':len(rows),'source_read_only':True,'pdf_processing':'Mac only, after copy',
        'split_seed':split_seed,'split_rule':'family SHA bucket: train <75, validation <90, reserved_test otherwise',
        'split_limit':'Provisional paper-family split; cross-paper image duplicates must be checked before admission.',
        'selection_limit':'2025+; four primary categories; complete paired builds; PDFs <=12 MiB; source labels are silver',
        'papers':selected,'bytes':total,'skipped':dict(skipped),'script_sha256':sha(Path(__file__))},indent=2))


if __name__=='__main__':main()
