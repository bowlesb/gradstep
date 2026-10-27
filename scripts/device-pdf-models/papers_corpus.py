"""Offline profiling and article-family splits for the private Papers corpus.

Does not change the archived corpus or fetch any sources. Model outputs are never used
for grouping or split assignment. Families unite exact text, bibliographic identifiers,
and distinctive normalized titles before assigning a deterministic 80/10/10 split.
"""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import re
import unicodedata


def normalize(text):
    text=unicodedata.normalize('NFKC',text).casefold()
    return ' '.join(re.findall(r'\w+',text))


def profile_one(args):
    import fitz
    fitz.TOOLS.mupdf_display_errors(False)
    fitz.TOOLS.mupdf_display_warnings(False)
    root,row=args
    result={'sha256':row['sha256'],'path':row['path']}
    try:
        with fitz.open(Path(root)/row['path']) as doc:
            result.update(pages=len(doc),encrypted=bool(doc.needs_pass),repaired=bool(doc.is_repaired))
            if doc.needs_pass:
                return result
            page_stats=[]; texts=[]; fonts=Counter()
            for i,page in enumerate(doc):
                text=page.get_text('text')
                texts.append(normalize(text))
                stats={'page':i,'chars':len(text),'replacement_chars':text.count('\ufffd'),
                       'greek_chars':sum('\u0370'<=c<='\u03ff' for c in text),
                       'width':round(page.rect.width,2),'height':round(page.rect.height,2),
                       'caption_starts':len(re.findall(r'(?mi)^\s*(?:fig(?:ure)?\.?|table)\s*\d+',text)),
                       'statistics_candidates':len(re.findall(r'\b[pPtTFrR]\s*[=<>()]|[±≤≥]',text))}
                if i<3 or i==len(doc)//2 or i==len(doc)-1:
                    blocks=page.get_text('dict',flags=fitz.TEXTFLAGS_DICT & ~fitz.TEXT_PRESERVE_IMAGES)['blocks']
                    for block in blocks:
                        for line in block.get('lines',[]):
                            for span in line['spans']: fonts[span['font']]+=len(span['text'])
                    stats['images']=len(page.get_images())
                page_stats.append(stats)
            text=' '.join(texts)
            result.update(text_sha256=hashlib.sha256(text.encode()).hexdigest() if len(text)>500 else None,
                          first_text_sha256=hashlib.sha256(' '.join(texts[:2]).encode()).hexdigest() if sum(map(len,texts[:2]))>500 else None,
                          text_chars=sum(s['chars'] for s in page_stats),
                          low_text_pages=sum(s['chars']<100 for s in page_stats),
                          page_stats=page_stats,fonts=fonts.most_common(25),
                          first_words=text.split()[:350])
    except Exception as exc:
        result['error']=type(exc).__name__+': '+str(exc)[:500]
    return result


def profile(args):
    rows=[json.loads(l) for l in (args.corpus/'candidate-pdfs.jsonl').read_text().splitlines()]
    args.out.mkdir(parents=True,exist_ok=True)
    existing={}
    destination=args.out/'profile.jsonl'
    if destination.exists():
        existing={r['sha256']:r for r in map(json.loads,destination.read_text().splitlines())}
    pending=[r for r in rows if r['sha256'] not in existing]
    with destination.open('a') as output, ProcessPoolExecutor(max_workers=args.workers) as pool:
        jobs={pool.submit(profile_one,(str(args.corpus),row)):row for row in pending}
        for n,future in enumerate(as_completed(jobs),1):
            row=future.result(); output.write(json.dumps(row,ensure_ascii=False)+'\n'); output.flush()
            if n%100==0: print(json.dumps({'profiled':len(existing)+n,'total':len(rows)}),flush=True)
    results=[json.loads(l) for l in destination.read_text().splitlines()]
    summary={'files':len(results),'pages':sum(r.get('pages',0) for r in results),
             'parse_errors':sum('error' in r for r in results),'encrypted':sum(r.get('encrypted',False) for r in results),
             'repaired':sum(r.get('repaired',False) for r in results),
             'low_text_pages':sum(r.get('low_text_pages',0) for r in results)}
    (args.out/'profile-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary),flush=True)


def split(args):
    rows=[json.loads(l) for l in (args.corpus/'candidate-pdfs.jsonl').read_text().splitlines()]
    prof={r['sha256']:r for r in map(json.loads,(args.out/'profile.jsonl').read_text().splitlines())}
    parent={r['sha256']:r['sha256'] for r in rows}
    def find(x):
        while parent[x]!=x:
            parent[x]=parent[parent[x]]; x=parent[x]
        return x
    def union(a,b):
        a,b=find(a),find(b)
        if a!=b: parent[max(a,b)]=min(a,b)
    identifiers=defaultdict(set)
    for row in rows:
        h=row['sha256']
        for b in row['bibliography']:
            doi=(b.get('doi') or '').strip().casefold()
            doi=re.sub(r'^https?://(?:dx\.)?doi\.org/|^doi:\s*','',doi).rstrip(' .')
            if re.match(r'^10\.\d{4,9}/\S+$',doi): identifiers['doi:'+doi].add(h)
            title=normalize(b.get('title') or '')
            if len(title)>35 and len(title.split())>=6 and title not in {'for peer review only','untitled'}:
                identifiers['title:'+title].add(h)
        for key in ['text_sha256','first_text_sha256']:
            if prof[h].get(key): identifiers[key+':'+prof[h][key]].add(h)
    for files in identifiers.values():
        files=sorted(files)
        for file in files[1:]: union(files[0],file)
    groups=defaultdict(list)
    for row in rows: groups[find(row['sha256'])].append(row['sha256'])
    output=[]
    for files in sorted(groups.values()):
        files.sort(); family=hashlib.sha256('\n'.join(files).encode()).hexdigest()
        bucket=int(hashlib.sha256(('papers-family-v1:'+family).encode()).hexdigest()[:8],16)%100
        partition='test' if bucket<10 else 'dev' if bucket<20 else 'train'
        for h in files:
            p=prof[h]
            output.append({'sha256':h,'family':family,'split':partition,'pages':p.get('pages',0),
                           'eligible':not p.get('error') and not p.get('encrypted') and p.get('text_chars',0)>500})
    (args.out/'splits.json').write_text(json.dumps(output,indent=2)+'\n')
    counts=Counter(r['split'] for r in output)
    summary={'files':len(rows),'families':len(groups),'split_files':dict(counts),
             'split_families':dict(Counter(next(r['split'] for r in output if r['sha256']==files[0]) for files in groups.values())),
             'multi_file_families':sum(len(v)>1 for v in groups.values()),'largest_family':max(map(len,groups.values())),
             'method':'SHA-256, normalized DOI/title, full normalized text and first-two-page text; connected components before fixed seeded hash split',
             'limitations':'Near-duplicate editions with changed text and missing metadata need additional review; base-model pretraining overlap not yet established.'}
    byh={r['sha256']:r for r in output}
    assert all(len({byh[h]['split'] for h in files})==1 for files in identifiers.values())
    (args.out/'split-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('command',choices=['profile','split'])
    p.add_argument('--corpus',type=Path,required=True); p.add_argument('--out',type=Path,required=True)
    p.add_argument('--workers',type=int,default=6)
    a=p.parse_args(); globals()[a.command](a)
