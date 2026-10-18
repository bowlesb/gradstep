#!/usr/bin/env python3
"""Fetch only public figure images/annotations from a pinned research archive.

No PDFs, API credentials, reader-library content, or model-provider calls. HTTP
range requests avoid fetching the unrelated multi-gigabyte synthetic corpus.
"""
import argparse
import collections
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.request
import zipfile

REV='6439d75905c5486a17ff9b343239faba5a9c7da2'
URL=f'https://huggingface.co/datasets/TobiPoni/CompoundFigureSeparation/resolve/{REV}/03_intermediate.zip'
SIZE=3444730286


class RemoteZipFile(io.RawIOBase):
    def __init__(self,url,size,block=4*1024*1024):
        self.url,self.size,self.pos,self.block=url,size,0,block
        self.cache=collections.OrderedDict();self.transferred=0
    def seekable(self):return True
    def readable(self):return True
    def tell(self):return self.pos
    def seek(self,p,whence=0):
        self.pos=p if whence==0 else self.pos+p if whence==1 else self.size+p
        if self.pos<0 or self.pos>self.size:raise ValueError('Archive seek outside bounds')
        return self.pos
    def get_block(self,key):
        if key in self.cache:self.cache.move_to_end(key);return self.cache[key]
        start=key*self.block;end=min(self.size,start+self.block)-1
        request=urllib.request.Request(self.url+f'?range={start}-{end}',headers={
            'Range':f'bytes={start}-{end}','Accept-Encoding':'identity','User-Agent':'GradstepFigureResearch/0.1'})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request,timeout=60) as response:
                    if response.status!=206 or response.headers.get('Content-Range')!=f'bytes {start}-{end}/{self.size}':
                        raise ValueError('Archive server did not honor the exact byte range')
                    data=response.read(end-start+2)
                if len(data)!=end-start+1:raise ValueError('Wrong archive response length')
                break
            except (OSError,ValueError):
                if attempt==2:raise
                time.sleep(1+attempt)
        self.transferred+=len(data);self.cache[key]=data
        while len(self.cache)>4:self.cache.popitem(last=False)
        return data
    def read(self,n=-1):
        if n<0:n=self.size-self.pos
        n=min(n,self.size-self.pos)
        if n>32*1024*1024:raise ValueError('Individual archive entry exceeds research read cap')
        parts=[]
        while n>0:
            key,offset=divmod(self.pos,self.block);data=self.get_block(key)
            part=data[offset:offset+n]
            if not part:raise EOFError('Truncated archive')
            parts.append(part);self.pos+=len(part);n-=len(part)
        return b''.join(parts)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    remote=RemoteZipFile(URL,SIZE);records=[]
    with zipfile.ZipFile(remote) as archive:
        selected=[x for x in archive.infolist() if x.filename.startswith('03_intermediate/SCI-3000_real-compound/')
                  and Path(x.filename).suffix.lower() in ('.png','.jpg','.jpeg','.json')]
        selected.sort(key=lambda x:x.header_offset)
        print(json.dumps({'selected_files':len(selected),'uncompressed_bytes':sum(x.file_size for x in selected)}),flush=True)
        for i,entry in enumerate(selected):
            relative=Path(entry.filename).relative_to('03_intermediate/SCI-3000_real-compound')
            target=(args.out/relative).resolve()
            if not target.is_relative_to(args.out.resolve()) or entry.file_size>32*1024*1024:raise ValueError('Unsafe entry')
            target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists():
                data=archive.read(entry) # zipfile checks the entry CRC, including decompression integrity.
                tmp=target.with_suffix(target.suffix+'.part');tmp.write_bytes(data);tmp.replace(target)
            records.append({'file':str(relative),'bytes':target.stat().st_size,
                            'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'zip_crc32':f'{entry.CRC:08x}'})
            if i%50==0:print(json.dumps({'files':i,'network_bytes':remote.transferred}),flush=True)
    manifest={'source':URL,'revision':REV,'archive_bytes':SIZE,'network_bytes':remote.transferred,'files':records,
              'declared_annotation_license':'MIT','image_source':'SCI-3000; article rights verification pending',
              'retrieved_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (args.out/'download-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'complete_files':len(records),'network_bytes':remote.transferred}),flush=True)


if __name__=='__main__':main()
