#!/usr/bin/env python3
"""Offline numerical rejection diagnosis; never a new verifier admission."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT/'.artifacts/pdf-verifier/corpus'
SOURCE = ROOT/'workers/pdf-verifier/corpus'
DENO = ROOT/'node_modules/@deno/darwin-arm64/deno'
FROZEN_IDENTITY = '2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_baseline(manifest, manifest_sha256, baseline):
    if baseline['manifest_sha256'] != manifest_sha256 or baseline['build_identity_sha256'] != FROZEN_IDENTITY:
        raise RuntimeError('stale_baseline_identity')
    papers = {paper['id']:paper for paper in manifest['papers']}
    records = {case['id']:case for case in baseline['results']}
    if len(papers) != len(manifest['papers']) or len(records) != len(baseline['results']) or set(papers) != set(records):
        raise RuntimeError('baseline_corpus_mismatch')
    expected = {}
    for identifier, paper in papers.items():
        record = records[identifier]
        if record['bytes'] != paper['bytes'] or not record['runs']:
            raise RuntimeError('baseline_artifact_mismatch')
        for run in record['runs']:
            if run.get('artifactSHA256') != paper['sha256'] or run.get('buildIdentitySHA256') != FROZEN_IDENTITY or run.get('id') != identifier:
                raise RuntimeError('baseline_artifact_mismatch')
        outcomes = {run['outcome'] for run in record['runs']}
        if len(outcomes) != 1: raise RuntimeError('baseline_outcomes_inconsistent')
        expected[identifier] = outcomes.pop()
    return expected


def main():
    baseline = json.loads((OUT/'benchmark.json').read_text())
    manifest = json.loads((SOURCE/'manifest.json').read_text())
    expected = validate_baseline(manifest, sha(SOURCE/'manifest.json'), baseline)
    environment = dict(os.environ,DENO_DIR=str(OUT/'deno-cache'))
    report = {'research_only':True,'hosted_admitted':False,'limits_changed':False,
        'scope':'numeric wrapper probes with same static qpdf library; original admission remains authoritative',
        'research_identity_sha256':sha(OUT/'research/identity.json'),
        'baseline_sha256':sha(OUT/'benchmark.json'),'process_timeout_seconds':5,
        'runner_sha256':sha(Path(__file__)), 'case_sha256':sha(SOURCE/'research_case.ts'),
        'stages':{1:'input guards',2:'processMemoryFile',3:'getAllPages',4:'checkLinearization',
            5:'getAllObjects',6:'all indirect stream decoding',7:'page content parsing'},
        'limit_kinds':{0:'none',1:'checked stream bytes',2:'checked page content bytes',3:'content object count',
            4:'indirect/highest object bound',5:'qpdf global limit',6:'bad_alloc'},
        'filter_bits':{0:'FlateDecode',1:'DCTDecode',2:'JPXDecode',3:'JBIG2Decode',4:'LZWDecode',
            5:'ASCII85Decode',6:'ASCIIHexDecode',7:'RunLengthDecode',8:'Crypt',30:'over eight filters',31:'unknown filter'},
        'results':[]}
    for paper in manifest['papers']:
        command=[str(DENO),'run','--no-config','--no-prompt','--no-remote',
            '--allow-read=workers/pdf-verifier,.artifacts/pdf-verifier/dist,.artifacts/pdf-verifier/corpus',
            'workers/pdf-verifier/corpus/research_case.ts',paper['id']]
        result=subprocess.run(command,cwd=ROOT,env=environment,capture_output=True,text=True,timeout=5,check=True)
        if len(result.stdout)>65536: raise RuntimeError('diagnostic_output_limit')
        record=json.loads(result.stdout)
        if record['id']!=paper['id'] or record['artifactSHA256']!=paper['sha256'] or record['researchIdentitySHA256']!=report['research_identity_sha256']:
            raise RuntimeError('diagnostic_binding_mismatch')
        record['baseline_outcome']=expected[paper['id']]
        record['matches_frozen_outcome']=record['outcome']==record['baseline_outcome']
        report['results'].append(record)
        (OUT/'research/report.json').write_text(json.dumps(report,indent=2)+'\n')
        print(paper['id'],record['outcome'],json.dumps(record['metrics'],sort_keys=True),flush=True)
    report['all_outcomes_match_frozen']=all(r['matches_frozen_outcome'] for r in report['results'])
    (OUT/'research/report.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['all_outcomes_match_frozen']: raise RuntimeError('research_changed_terminal_outcome')
    print('ALL 24 RESEARCH OUTCOMES MATCH FROZEN BUILD',flush=True)


if __name__ == '__main__': main()
