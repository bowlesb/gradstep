#!/usr/bin/env python3
"""One-connection, bounded publisher corpus capture/replay; never an app importer.

--capture creates the initial reviewed manifest exactly once. Later runs only
restore missing artifacts against pinned hashes; they never update the manifest.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'workers/pdf-verifier/corpus'
OUT = ROOT / '.artifacts/pdf-verifier/corpus'
MIB = 1024 * 1024
MAX_FILE, MAX_TOTAL, MAX_HTML = 32*MIB, 160*MIB, MIB
SPACING, DEADLINE = 1.0, 30.0
POLICIES = [
 ('publication-agreement', 'https://proceedings.mlr.press/pmlr-license-agreement.html'),
 ('publisher-faq', 'https://proceedings.mlr.press/faq.html'),
 ('cc-by-4.0-legalcode', 'https://creativecommons.org/licenses/by/4.0/legalcode.en'),
]


def sha(data): return hashlib.sha256(data).hexdigest()

def json_write(path, value):
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')
    temporary.replace(path)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args): raise RuntimeError('redirect_refused')
    def http_error_308(self,*args): raise RuntimeError('redirect_refused')


class Metadata(HTMLParser):
    def __init__(self): super().__init__(); self.fields={}
    def handle_starttag(self, tag, attributes):
        values=dict(attributes)
        if tag=='meta' and values.get('name','').startswith('citation_'):
            self.fields.setdefault(values['name'],[]).append(values.get('content',''))
    def one(self, name):
        values=self.fields.get('citation_'+name,[])
        if len(values)!=1 or not values[0].strip(): raise RuntimeError('missing_or_duplicate_metadata_'+name)
        return values[0]


class Downloader:
    def __init__(self):
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
        self.last_closed=0.0
        self.receipts_path=OUT/'download-receipts.json'
        self.receipts=json.loads(self.receipts_path.read_text()) if self.receipts_path.exists() else {'received_bytes':0,'files':{}}
        if self.receipts['received_bytes']>MAX_TOTAL: raise RuntimeError('aggregate_transfer_limit')
    def get(self,url,relative,cap,expected=None):
        parsed=urllib.parse.urlsplit(url)
        if parsed.scheme!='https' or parsed.netloc not in ('proceedings.mlr.press','creativecommons.org') or parsed.query or parsed.fragment:
            raise RuntimeError('unapproved_source_url')
        if parsed.netloc=='creativecommons.org' and url!=POLICIES[2][1]: raise RuntimeError('unapproved_license_url')
        path=OUT/relative
        if path.is_symlink() or OUT.resolve() not in path.resolve().parents: raise RuntimeError('unsafe_artifact_path')
        prior=self.receipts['files'].get(relative)
        if path.exists():
            if not prior or prior['url']!=url or path.stat().st_size>cap: raise RuntimeError('unbound_existing_artifact')
            data=path.read_bytes()
            if sha(data)!=prior['sha256'] or (expected and sha(data)!=expected): raise RuntimeError('artifact_hash_mismatch')
            return data,prior
        if self.receipts['received_bytes']>=MAX_TOTAL: raise RuntimeError('aggregate_transfer_limit')
        time.sleep(max(0,self.last_closed+SPACING-time.monotonic()))
        path.parent.mkdir(parents=True,exist_ok=True)
        partial=path.with_suffix(path.suffix+'.part')
        if partial.exists() or partial.is_symlink(): raise RuntimeError('unreconciled_partial_download')
        count=0; started=time.monotonic(); content_type=None
        try:
            request=urllib.request.Request(url,headers={'User-Agent':'ScienceReaderVerifierCorpus/1.0 (local offline benchmark)',
                'Connection':'close','Accept-Encoding':'identity'})
            with self.opener.open(request,timeout=10) as response, partial.open('xb') as output:
                if response.status!=200 or response.url!=url: raise RuntimeError('unexpected_response')
                if response.headers.get('Content-Encoding','identity').lower()!='identity': raise RuntimeError('encoded_response_refused')
                content_type=response.headers.get_content_type()
                length=response.headers.get('Content-Length')
                if length is not None and (not length.isdigit() or int(length)>cap or self.receipts['received_bytes']+int(length)>MAX_TOTAL):
                    raise RuntimeError('declared_transfer_limit')
                while True:
                    if time.monotonic()-started>DEADLINE: raise RuntimeError('download_deadline')
                    remaining=min(cap-count,MAX_TOTAL-self.receipts['received_bytes'])
                    # Fail closed at the exact cap without reading an extra
                    # detection byte. An unknown-length exact-cap file may be
                    # refused; the tool never exceeds the transfer envelope.
                    if remaining<=0: raise RuntimeError('stream_transfer_limit')
                    chunk=response.read(min(65536,remaining))
                    if not chunk: break
                    count+=len(chunk); self.receipts['received_bytes']+=len(chunk)
                    if count>cap or self.receipts['received_bytes']>MAX_TOTAL: raise RuntimeError('stream_transfer_limit')
                    output.write(chunk)
                if length is not None and count!=int(length): raise RuntimeError('truncated_download')
            data=partial.read_bytes(); digest=sha(data)
            if expected and digest!=expected: raise RuntimeError('publisher_bytes_changed')
            if relative.endswith('.pdf') and (content_type!='application/pdf' or not data.startswith(b'%PDF-')):
                raise RuntimeError('not_a_pdf_response')
            if relative.endswith('.html') and content_type not in ('text/html','application/xhtml+xml'): raise RuntimeError('not_an_html_response')
            receipt={'url':url,'sha256':digest,'bytes':count,'content_type':content_type,
                     'retrieved_at':datetime.now(timezone.utc).isoformat(),'redirected':False}
            partial.replace(path); self.receipts['files'][relative]=receipt
            return data,receipt
        finally:
            self.last_closed=time.monotonic()
            if partial.exists(): partial.unlink()
            json_write(self.receipts_path,self.receipts)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--capture',action='store_true');args=parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    with (OUT/'.download.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest_path=SOURCE/'manifest.json'
        if args.capture and manifest_path.exists(): raise RuntimeError('manifest_already_pinned')
        if not args.capture and not manifest_path.exists(): raise RuntimeError('capture_required')
        downloader=Downloader()
        if not args.capture:
            manifest=json.loads(manifest_path.read_text())
            for evidence in manifest['license_evidence']:
                downloader.get(evidence['url'],evidence['file'],MAX_HTML,evidence['sha256'])
            for paper in manifest['papers']:
                downloader.get(paper['source_url'],paper['source_file'],MAX_HTML,paper['source_sha256'])
                downloader.get(paper['pdf_url'],paper['file'],MAX_FILE,paper['sha256'])
                print('VERIFIED',paper['id'],paper['bytes'],flush=True)
            return
        evidence=[]; texts={}
        for key,url in POLICIES:
            relative='evidence/'+key+'.html';data,receipt=downloader.get(url,relative,MAX_HTML)
            evidence.append(dict(receipt,id=key,file=relative));texts[key]=' '.join(data.decode('utf-8').split())
        if 'Creative Commons Attribution 4.0 International License' not in texts['publication-agreement'] or 'permission to publish' not in texts['publisher-faq'].lower():
            raise RuntimeError('publisher_policy_changed_review_required')
        papers=[]; selection=json.loads((SOURCE/'selection.json').read_text())['papers']
        if not 20<=len(selection)<=25: raise RuntimeError('invalid_corpus_size')
        for selected in selection:
            ref=selected['ref']
            if not re.fullmatch(r'v[0-9]+/[a-z]+[0-9]+[a-z]',ref): raise RuntimeError('invalid_source_reference')
            identifier=ref.replace('/','-');source_url='https://proceedings.mlr.press/'+ref+'.html';source_file='evidence/'+identifier+'.html'
            page,source_receipt=downloader.get(source_url,source_file,MAX_HTML)
            metadata=Metadata();metadata.feed(page.decode('utf-8'))
            title=metadata.one('title')
            if selected['title_contains'].casefold() not in title.casefold() or metadata.one('publisher')!='PMLR' or metadata.one('abstract_html_url')!=source_url:
                raise RuntimeError('unexpected_paper_metadata_'+identifier)
            authors=metadata.fields.get('citation_author',[])
            if not authors or len(authors)>100 or any(not a.strip() for a in authors): raise RuntimeError('invalid_authors')
            original_url=metadata.one('pdf_url');parts=urllib.parse.urlsplit(original_url)
            expected_path='/'+ref+'/'+ref.split('/')[1]+'.pdf'
            if parts.scheme not in ('http','https') or parts.netloc!='proceedings.mlr.press' or parts.path!=expected_path or parts.query or parts.fragment:
                raise RuntimeError('unexpected_pdf_link')
            pdf_url=urllib.parse.urlunsplit(('https',parts.netloc,parts.path,'',''));relative='pdf/'+identifier+'.pdf'
            lowered=page.decode('utf-8').lower()
            if any(term in lowered for term in ('creativecommons.org/licenses/by-nc','creativecommons.org/licenses/by-nd','all rights reserved')):
                raise RuntimeError('conflicting_page_license_review_required')
            data,pdf_receipt=downloader.get(pdf_url,relative,MAX_FILE)
            record={'id':identifier,'title':title,'authors':authors,'publisher':'PMLR','publication_date':metadata.one('publication_date'),
                    'proceedings':metadata.one('conference_title'),'volume':ref.split('/')[0][1:],
                    'first_page':metadata.one('firstpage'),'last_page':metadata.one('lastpage'),
                    'source_url':source_url,'source_file':source_file,'source_sha256':source_receipt['sha256'],
                    'publisher_pdf_link':original_url,'pdf_url':pdf_url,'file':relative,'sha256':pdf_receipt['sha256'],'bytes':len(data),
                    'retrieved_at':pdf_receipt['retrieved_at'],'selection_topics':selected['topics'],
                    'license':'CC-BY-4.0','license_url':'https://creativecommons.org/licenses/by/4.0/',
                    'license_basis':'publisher-policy inference; individual signed forms not inspected',
                    'license_evidence_ids':[e['id'] for e in evidence],'modified':False,'production_eligible':False}
            papers.append(record);print('CAPTURED',identifier,len(data),flush=True)
        manifest={'version':1,'purpose':'local offline PDF verifier benchmark only; no upload/application redistribution',
                  'limits':{'file_bytes':MAX_FILE,'aggregate_received_bytes':MAX_TOTAL,'one_connection':True,'spacing_after_close_seconds':SPACING,'redirects':False},
                  'license_evidence':evidence,'papers':papers,'pdf_bytes':sum(p['bytes'] for p in papers),
                  'received_bytes':downloader.receipts['received_bytes']}
        json_write(manifest_path,manifest)
        print('PINNED',len(papers),'papers',manifest['pdf_bytes'],'PDF bytes',flush=True)


if __name__=='__main__': main()
