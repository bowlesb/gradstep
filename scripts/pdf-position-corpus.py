#!/usr/bin/env python3
"""Read-only corpus evaluation; extracted text streams to the shipped JS model, never to a service.
Usage: python3 scripts/pdf-position-corpus.py --root /path/to/arxiv --count 512 --split evaluation --output /tmp/report.json
Labels: perturbed known PDF locations + independent unique exact HTML phrase anchors (silver, not human gold).
"""
import argparse, concurrent.futures, hashlib, json, pathlib, re, subprocess, unicodedata
from html.parser import HTMLParser

class Paragraphs(HTMLParser):
    def __init__(self):
        super().__init__(); self.paragraphs=[]; self.current=None; self.skip=0
    def handle_starttag(self, tag, attrs):
        if tag in ('math','script','style','annotation'): self.skip+=1
        if tag=='p': self.current=[]
    def handle_endtag(self, tag):
        if tag in ('math','script','style','annotation'): self.skip=max(0,self.skip-1)
        if tag=='p' and self.current is not None:
            text=' '.join(''.join(self.current).split())
            if len(text)>100: self.paragraphs.append(text)
            self.current=None
    def handle_data(self, text):
        if self.current is not None and not self.skip: self.current.append(text)

def utf16(text): return len(text.encode('utf-16-le'))//2

def normalized(text):
    # Independent character-level oracle; unlike the shipped token-window scorer.
    chars=[]; positions=[]
    for i,c in enumerate(text):
        for v in unicodedata.normalize('NFKD',c).lower():
            if v.isalnum(): chars.append(v); positions.append(i)
    return ''.join(chars),positions

def prepare(path):
    try:
        pdf=path/'arxiv.pdf'
        if pdf.stat().st_size>64*1024*1024: return {'skip':'pdf-size'}
        process=subprocess.run(['pdftotext','-enc','UTF-8',str(pdf),'-'],capture_output=True,timeout=25)
        if process.returncode: return {'skip':'extraction'}
        pages=process.stdout.decode('utf-8').split('\f');
        if pages and not pages[-1].strip(): pages.pop()
        if not pages or len(pages)>512 or sum(map(len,pages))>8000000 or max(map(len,pages))>200000: return {'skip':'text-limit'}
        tests=[]
        # Fixed locations across the whole PDF, not only its abstract/first page.
        for fraction in (.08,.27,.49,.71,.92):
            page=min(len(pages)-1,int(len(pages)*fraction)); text=pages[page]
            words=list(re.finditer(r'\S+',text))
            if len(words)<70: continue
            start=int((len(words)-60)*fraction); selected=words[start:start+50]
            query=' '.join(w.group() for i,w in enumerate(selected) if i%13!=7)
            query=query.replace('ﬁ','fi').replace('ﬀ','ff')
            if len(query)>2400: continue
            tests.append({'kind':'perturbed-pdf','text':query,'page':page,'location':utf16(text[:selected[0].start()]),'end':utf16(text[:selected[-1].end()])})
        html=path/'arxiv.html'; parser=Paragraphs()
        if html.stat().st_size <= 12000000:
            parser.feed(html.read_text(errors='replace'))
            norms=[normalized(p) for p in pages]
            # Find up to five independently unique exact 12-word anchors in HTML paragraphs.
            for paragraph in parser.paragraphs[::max(1,len(parser.paragraphs)//35)]:
                query=' '.join(paragraph.split()[:70])[:2000]
                words=query.split(); anchor=' '.join(words[4:16]); needle=normalized(anchor)[0]
                if len(needle)<50: continue
                hits=[]
                for page,(flat,mapping) in enumerate(norms):
                    pos=flat.find(needle)
                    if pos>=0:
                        if flat.find(needle,pos+1)>=0: hits.append(None)
                        hits.append((page,mapping[pos],mapping[pos+len(needle)-1]+1))
                if len(hits)!=1 or hits[0] is None: continue
                page,start,end=hits[0]
                tests.append({'kind':'html-silver','text':query,'page':page,'location':utf16(pages[page][:start]),'end':utf16(pages[page][:end])})
                if sum(t['kind']=='html-silver' for t in tests)>=5: break
        tests.append({'kind':'negative','text':'The maritime vessel crossed Atlantic waters before docking in northern coastal harbors while sailors repaired its wooden rudder.'})
        return {'paper':path.name,'sha256':hashlib.sha256(pdf.read_bytes()).hexdigest(),'pages':pages,'tests':tests}
    except (OSError,subprocess.TimeoutExpired,ValueError): return {'skip':'read-error'}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--root',type=pathlib.Path,required=True); ap.add_argument('--count',type=int,default=512); ap.add_argument('--split',choices=['development','evaluation'],default='evaluation'); ap.add_argument('--output',required=True); ap.add_argument('--exclude-report',action='append',default=[]); args=ap.parse_args()
    candidates=[p for p in args.root.iterdir() if p.is_dir() and (p/'arxiv.pdf').is_file() and (p/'arxiv.html').is_file()]
    # Split on canonical paper identity, retaining just the latest local revision of each paper.
    base=lambda name: re.sub(r'v[0-9]+$','',name)
    latest={}
    for p in candidates:
        version=int(re.search(r'v([0-9]+)$',p.name)[1]) if re.search(r'v([0-9]+)$',p.name) else 0
        if base(p.name) not in latest or version>latest[base(p.name)][0]: latest[base(p.name)]=(version,p)
    excluded={base(row['id']) for report in args.exclude_report for row in json.loads(pathlib.Path(report).read_text())['corpus']}
    candidates=[p for _,p in latest.values() if base(p.name) not in excluded]
    candidates.sort(key=lambda p:hashlib.sha256(('pdf-peek-v1/'+base(p.name)).encode()).digest())
    chosen=[p for p in candidates if (int(hashlib.sha256(base(p.name).encode()).hexdigest(),16)%5==0)==(args.split=='development')][:args.count]
    process=subprocess.Popen(['node',str(pathlib.Path(__file__).with_name('pdf-position-corpus.mjs')),'--output',args.output,'--split',args.split],stdin=subprocess.PIPE,text=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        for n,record in enumerate(executor.map(prepare,chosen)):
            process.stdin.write(json.dumps(record,ensure_ascii=True)+'\n'); process.stdin.flush()
            if (n+1)%50==0: print(f'Prepared {n+1}/{len(chosen)} papers',flush=True)
    process.stdin.close(); code=process.wait()
    if code: raise SystemExit(code)
if __name__=='__main__': main()
