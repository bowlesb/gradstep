#!/usr/bin/env python3
"""Bounded offline benchmark of the immutable verifier, not hosted admission.

Every run gets a fresh Deno process, no network permissions, and a five-second
parent-enforced wall timeout. CPU is whole-child startup/load/read/parse CPU;
Deno memory is only a post-run RSS/heap/external snapshot, never measured peak.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import statistics
import subprocess
import time
import sys
sys.dont_write_bytecode = True
import corpus_store as store

ROOT=Path(__file__).resolve().parents[3]
SOURCE=ROOT/'workers/pdf-verifier/corpus'
OUT=ROOT/'.artifacts/pdf-verifier/corpus'
DENO=ROOT/'node_modules/@deno/darwin-arm64/deno'
TIMEOUT=5.0


def sha(data): return hashlib.sha256(data).hexdigest()


def descriptive_inspection(path):
    """Auxiliary Poppler facts/license-text flagging; never verifier authority."""
    result={'structural_authority':False,'license_review_scope':'all extracted PDF text; not individual signed forms',
            'conflicting_license_markers':[]}
    tool=shutil.which('pdfinfo')
    if tool:
        try:
            proc=subprocess.run([tool,str(path)],capture_output=True,timeout=TIMEOUT)
            if len(proc.stdout)>65536: raise ValueError('inspection_output_limit')
            values={}
            for line in proc.stdout.decode('utf-8','replace').splitlines():
                if ':' in line:
                    key,value=line.split(':',1)
                    if key in ('Pages','Encrypted','Optimized','PDF version','Tagged','Form','JavaScript'): values[key]=value.strip()
            result['pdfinfo']=values;result['pdfinfo_exit_code']=proc.returncode
        except (subprocess.TimeoutExpired,ValueError): result['pdfinfo_status']='bounded_inspection_failed'
    else: result['pdfinfo_status']='tool_unavailable'
    tool=shutil.which('pdftotext')
    if tool:
        try:
            proc=subprocess.run([tool,'-enc','UTF-8',str(path),'-'],capture_output=True,timeout=TIMEOUT)
            if len(proc.stdout)>4*1024*1024: raise ValueError('inspection_output_limit')
            text=proc.stdout.decode('utf-8','replace');normalized=' '.join(text.casefold().split())
            terms=('all rights reserved','creativecommons.org/licenses/by-nc','creativecommons.org/licenses/by-nd',
                   'cc by-nc','cc-by-nc','cc by-nd','cc-by-nd','non-commercial use only','academic use only')
            result['conflicting_license_markers']=[term for term in terms if term in normalized]
            result['pdftotext_exit_code']=proc.returncode
            result['extracted_text_characters']=len(text)
            result['has_extractable_text']=len(text.strip())>1000
            result['contains_equation_reference']=bool(re.search(r'\b(equation|eq\.)',normalized))
            result['contains_figure_reference']=bool(re.search(r'\b(figure|fig\.)',normalized))
            result['contains_table_reference']='table ' in normalized
            # Small raw lexical features are coverage hints, not parsed counts.
        except (subprocess.TimeoutExpired,ValueError): result['pdftotext_status']='bounded_inspection_failed'
    else: result['pdftotext_status']='tool_unavailable'
    raw=path.read_bytes()
    result['raw_marker_hints']={key:bool(re.search(pattern,raw)) for key,pattern in
      [('linearized',rb'/Linearized\b'),('object_stream',rb'/ObjStm\b'),('xref_stream',rb'/Type\s*/XRef\b'),('image',rb'/Subtype\s*/Image\b'),('font',rb'/Type\s*/Font\b')]}
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-identity',required=True)
    parser.add_argument('--run-id')
    parser.add_argument('--repeats',type=int,choices=[1,3],default=3)
    args=parser.parse_args()
    identity=store.identifier(args.build_identity)
    bundle=store.build_store.open_bundle(identity)
    manifest_bytes=(SOURCE/'manifest.json').read_bytes();manifest=json.loads(manifest_bytes)
    if not 20<=len(manifest['papers'])<=25 or sum(p['bytes'] for p in manifest['papers'])>160*1024*1024: raise RuntimeError('invalid_corpus_bound')
    run_directory=store.claim_run('benchmark',identity,args.run_id)
    with (run_directory/'manifest.json').open('xb') as stream: stream.write(manifest_bytes)
    runner_files=['benchmark.py','case.ts','bundle.ts','corpus_store.py']
    runner_hashes={name:sha((SOURCE/name).read_bytes()) for name in runner_files}
    environment=dict(os.environ,DENO_DIR=str(OUT/'deno-cache'))
    deno_version=subprocess.run([str(DENO),'--version'],capture_output=True,text=True,check=True).stdout.splitlines()[0]
    report={'created_at':datetime.now(timezone.utc).isoformat(),'scope':'local offline corpus only; hosted_admitted remains false',
            'build_identity_sha256':identity,'manifest_sha256':sha(manifest_bytes),'platform':platform.platform(),
            'build_bundle':str(bundle.relative_to(ROOT)),
            'bundle_manifest_sha256':sha(store.read(bundle/'bundle.json')),
            'run_directory':str(run_directory.relative_to(ROOT)),'runner_sha256':runner_hashes,
            'deno':deno_version,'repeats':args.repeats,'process_wall_timeout_seconds':TIMEOUT,
            'cpu_scope':'whole isolated child: startup, build checks, compile, input read/hash and parse',
            'memory_scope':'Deno post-run RSS/heap/external snapshot, not measured peak; peak_host_bytes not available',
            'permission_scope':'Deno read-only corpus and immutable build store; no live verifier source/dist, net, env, run or write permissions',
            'results':[]}
    for entry in manifest['papers']:
        identifier=entry['id'];path=OUT/entry['file']
        if entry['file']!=f'pdf/{identifier}.pdf' or path.is_symlink() or path.stat().st_size!=entry['bytes'] or sha(path.read_bytes())!=entry['sha256']:
            raise RuntimeError('corpus_binding_mismatch')
        case={'id':identifier,'bytes':entry['bytes'],'runs':[]}
        for run in range(args.repeats):
            command=[str(DENO),'run','--no-config','--no-prompt','--no-remote',
                     '--allow-read=workers/pdf-verifier/corpus,.artifacts/pdf-verifier/builds,.artifacts/pdf-verifier/corpus',
                     'workers/pdf-verifier/corpus/case.ts',identity,identifier,sha(manifest_bytes)]
            before=resource.getrusage(resource.RUSAGE_CHILDREN);started=time.monotonic()
            try:
                completed=subprocess.run(command,cwd=ROOT,env=environment,capture_output=True,text=True,timeout=TIMEOUT)
                after=resource.getrusage(resource.RUSAGE_CHILDREN)
                measurement={'run':run+1,'exit_code':completed.returncode,'process_wall_ms':(time.monotonic()-started)*1000,
                 'whole_child_cpu_ms':((after.ru_utime+after.ru_stime)-(before.ru_utime+before.ru_stime))*1000}
                if completed.returncode==0 and len(completed.stdout)<=65536:
                    observed=json.loads(completed.stdout)
                    if observed['id']!=identifier or observed['buildIdentitySHA256']!=identity or observed['manifestSHA256']!=sha(manifest_bytes) or observed['artifactSHA256']!=entry['sha256']:
                        raise RuntimeError('benchmark_output_binding_mismatch')
                    measurement.update(observed);measurement['outcome']=observed['measurement']['outcome']
                else:
                    measurement.update(outcome='execution_failure',diagnostic=completed.stderr[:2000])
            except subprocess.TimeoutExpired:
                after=resource.getrusage(resource.RUSAGE_CHILDREN)
                measurement={'run':run+1,'exit_code':-1,'outcome':'time_limit','process_wall_ms':(time.monotonic()-started)*1000,
                 'whole_child_cpu_ms':((after.ru_utime+after.ru_stime)-(before.ru_utime+before.ru_stime))*1000}
            case['runs'].append(measurement)
        case['descriptive_inspection']=descriptive_inspection(path)
        case['license_review_status']='flagged_exclude_pending_review' if case['descriptive_inspection']['conflicting_license_markers'] else 'no_conflicting_marker_in_extracted_text'
        case['consistent_outcome']=len({r['outcome'] for r in case['runs']})==1
        report['results'].append(case)
        store.write_progress(run_directory,report)
        print(identifier,','.join(sorted({r['outcome'] for r in case['runs']})),
              'max_cpu_ms='+str(round(max(r['whole_child_cpu_ms'] for r in case['runs']),1)),flush=True)
    runs=[r for case in report['results'] for r in case['runs']]
    report['summary']={'paper_count':len(report['results']),'isolated_runs':len(runs),'pdf_bytes':manifest['pdf_bytes'],
                       'paper_outcomes':dict(Counter(case['runs'][0]['outcome'] for case in report['results'])),
                       'run_outcomes':dict(Counter(r['outcome'] for r in runs)),
                       'whole_child_cpu_ms_max':max(r['whole_child_cpu_ms'] for r in runs),
                       'whole_child_cpu_ms_median':statistics.median(r['whole_child_cpu_ms'] for r in runs),
                       'post_run_rss_bytes_max':max((r['memoryPostRunSnapshot']['rss'] for r in runs if 'memoryPostRunSnapshot' in r),default=None),
                       'peak_host_bytes':None,'hosted_admitted':False,
                       'license_flagged_ids':[c['id'] for c in report['results'] if c['license_review_status'].startswith('flagged')],
                       'linearized_pdfinfo_ids':[c['id'] for c in report['results'] if c['descriptive_inspection'].get('pdfinfo',{}).get('Optimized')=='yes']}
    if any(sha((SOURCE/name).read_bytes())!=expected for name,expected in runner_hashes.items()):
        raise RuntimeError('benchmark_runner_changed')
    path=store.finalize(run_directory,report)
    print(json.dumps(report['summary'],sort_keys=True),flush=True)
    print('REPORT',str(path.relative_to(ROOT)),flush=True)


if __name__=='__main__': main()
