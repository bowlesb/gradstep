#!/usr/bin/env python3
"""Read public DOAJ/Crossref article metadata, retaining per-paper license evidence.

Do not fetch PDFs or use a paid model/API. Dataset-level declarations do not replace
article rights; absent/ambiguous rights remain unresolved rather than presumed open.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request


def read(url):
    request=urllib.request.Request(url,headers={'User-Agent':'GradstepFigureResearch/0.1','Accept':'application/json'})
    with urllib.request.urlopen(request,timeout=25) as response:return json.load(response)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--attribution',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    papers=json.loads(args.attribution.read_text());existing={}
    if args.out.exists():
        for line in args.out.read_text().splitlines():
            row=json.loads(line);existing[row['paper']]=row
    def one(paper):
        row={'paper':paper,'retrieved_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
             'doaj_url':'https://doaj.org/api/articles/'+paper,'rights_status':'unresolved'}
        try:
            article=read(row['doaj_url'])['bibjson'];row['title']=article.get('title')
            doi=next((x['id'] for x in article.get('identifier',[]) if x['type']=='doi'),None);row['doi']=doi
            if doi:
                row['crossref_url']='https://api.crossref.org/works/'+urllib.parse.quote(doi,safe='')
                work=read(row['crossref_url'])['message'];row['crossref_title']=work.get('title');row['licenses']=work.get('license',[])
                allowed=[x for x in row['licenses'] if any(t in x.get('URL','') for t in
                    ('creativecommons.org/licenses/by/','creativecommons.org/licenses/by-sa/','creativecommons.org/publicdomain/zero/'))]
                if allowed:row['rights_status']='permissive_license_reported_by_crossref';row['permissive_licenses']=allowed
        except Exception as exc:row['metadata_error']=type(exc).__name__
        return row
    pending=sorted(set(papers)-set(existing))
    args.out.parent.mkdir(parents=True,exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for i,row in enumerate(pool.map(one,pending)):
            with args.out.open('a') as f:f.write(json.dumps(row,sort_keys=True)+'\n')
            existing[row['paper']]=row
            if i%25==0:print(json.dumps({'done':len(existing),'total':len(papers)}),flush=True)
    print(json.dumps({'papers':len(existing),'permissive':sum(x['rights_status'].startswith('permissive') for x in existing.values()),
                      'unresolved':sum(x['rights_status']=='unresolved' for x in existing.values())}),flush=True)


if __name__=='__main__':main()
