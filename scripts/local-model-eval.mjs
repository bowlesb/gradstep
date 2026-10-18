#!/usr/bin/env node
// Opt-in native Mac scientific evaluation: no model service, credentials, paid judge or network during inference.
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs';
import {execFileSync,spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {buildPaperContext} from '../apps/web/src/lib/paper-context.ts';
const variant=process.argv.find(x=>x.startsWith('--variant='))?.slice(10)??'baseline';
if(!/^[a-z0-9-]+$/.test(variant))throw Error('Invalid evaluation variant');
const out=variant==='baseline'?'.artifacts/local-ai/mac-eval-20261018':`.artifacts/local-ai/mac-eval-${variant}-20261018`;
mkdirSync(`${out}/cases`,{recursive:true});
const papers={dpo:'.artifacts/bundles/ecbc0a04588f',mamba:'.artifacts/bundles/1c734458ee39',muon:'.artifacts/bakeoff/bundles/2610.19844v1',prism:'.artifacts/bakeoff/bundles/2610.14704v1',apertus:'.artifacts/bakeoff/bundles/2610.15542v1'};
const pins=JSON.parse(readFileSync('tests/model-bakeoff/_sources.json'));
const sha=x=>createHash('sha256').update(x).digest('hex');
const cases=[];
for(const [paper,dir] of Object.entries(papers)){
 const reader=readFileSync(`${dir}/reader.json`),manifest=readFileSync(`${dir}/manifest.json`),index=JSON.parse(reader),text=buildPaperContext(index);
 if(sha(reader)!==pins[paper].reader_sha256||sha(manifest)!==pins[paper].manifest_sha256||sha(text)!==pins[paper].context_sha256)throw Error(`Source changed: ${paper}`);
 for(const q of JSON.parse(readFileSync(`tests/model-bakeoff/${paper}.json`))){
  if(q.id==='dpo-visual')continue; // Tool-generated diagrams are not a local-model capability.
  const input={question:q.question,paper:text};let image;
  if(q.figure){
   const prepared=JSON.parse(execFileSync(process.execPath,['scripts/model-bakeoff-figure.mjs',dir,String(q.figure)],{maxBuffer:8*1024*1024}));
   input.selection=prepared.caption;input.focus=prepared.paragraph;
   image=`${out}/cases/${q.id}.jpg`;writeFileSync(image,Buffer.from(prepared.data,'base64'));
  }
  if(q.id==='mamba-equation'){
   const old=JSON.parse(readFileSync('.artifacts/local-ai/cases/mamba-equation-selected.json'));
   input.selection=old.selection;input.focus=old.focus;input.action='equation';
  }
  const file=`${out}/cases/${q.id}.json`;writeFileSync(file,JSON.stringify(input));
  cases.push({...q,input:file,image,input_sha256:sha(JSON.stringify(input)),image_sha256:image?sha(readFileSync(image)):null});
 }
}
// Retain the previous cropped panel control to separate image-resolution failure from scientific reasoning.
const panel=JSON.parse(readFileSync('.artifacts/local-ai/cases/mamba-panel.json'));
writeFileSync(`${out}/cases/mamba-panel-control.json`,JSON.stringify(panel));
cases.push({id:'mamba-panel-control',input:`${out}/cases/mamba-panel-control.json`,image:'.artifacts/local-ai/cases/mamba-panel.png',input_sha256:sha(JSON.stringify(panel)),image_sha256:sha(readFileSync('.artifacts/local-ai/cases/mamba-panel.png')),reference:'Mamba 1.4B reaches 1814 tokens/s at batch128. Transformer 1.3B peaks at364 at batch32 and OOM64/128. Best-throughput ratio1814/364=4.98, not equal-batch speedup.'});
writeFileSync(`${out}/cases.json`,JSON.stringify(cases,null,2));
if(process.argv[2]==='prepare'){console.log(`Prepared ${cases.length} grounded cases`);process.exit(0);}
const model=process.argv[2];if(!/^[a-z0-9-]+$/.test(model??''))throw Error('Use prepare or MODEL');
const selected=process.argv.find(x=>x.startsWith('--cases='))?.slice(8).split(',');
mkdirSync(`${out}/${model}`,{recursive:true});
const provenance={probe_sha256:sha(readFileSync('.artifacts/local-ai/probe-build/Build/Products/Release/LocalAIProbe')),
  catalog:JSON.parse(readFileSync('tests/local-ai/candidates.json')).find(m=>m.id===model),variant,
  machine:execFileSync('/usr/sbin/sysctl',['-n','machdep.cpu.brand_string'],{encoding:'utf8'}).trim(),
  memory_bytes:Number(execFileSync('/usr/sbin/sysctl',['-n','hw.memsize'],{encoding:'utf8'}).trim()),network:'denied by sandbox'};
const provenanceFile=`${out}/${model}/provenance.json`;
if(existsSync(provenanceFile)&&JSON.stringify(JSON.parse(readFileSync(provenanceFile)))!==JSON.stringify(provenance))throw Error('Probe configuration changed; choose a new --variant');
writeFileSync(provenanceFile,JSON.stringify(provenance,null,2));
const timeout=Number(process.argv.find(x=>x.startsWith('--timeout='))?.slice(10)??180);
if(!Number.isSafeInteger(timeout)||timeout<30||timeout>600)throw Error('Timeout must be 30–600 seconds');
for(const c of cases.filter(c=>!selected||selected.includes(c.id))){
 const file=`${out}/${model}/${c.id}.json`;if(existsSync(file))continue;
 const began=new Date(),args=['-l','/usr/bin/sandbox-exec','-p','(version 1) (allow default) (deny network*)','.artifacts/local-ai/probe-build/Build/Products/Release/LocalAIProbe',model,'.artifacts/local-ai/models',c.input,...(c.image?[c.image]:[]),'--catalog','tests/local-ai/candidates.json'];
 const r=spawnSync('/usr/bin/time',args,{encoding:'utf8',timeout:timeout*1000,maxBuffer:2*1024*1024});
 const ended=new Date();let answer=null;try{answer=JSON.parse(r.stdout)}catch{}
 const peak=Number(/(\d+)\s+peak memory footprint/.exec(r.stderr??'')?.[1]??0);
 const result={model,case:c.id,began:began.toISOString(),finished:ended.toISOString(),wall_seconds:(ended-began)/1000,exit:r.status,signal:r.signal,error:r.error?.code??null,process_peak_bytes:peak,answer};
 writeFileSync(file,JSON.stringify(result,null,2));writeFileSync(file.replace('.json','.log'),r.stderr??'');
 console.log(`${model} ${c.id}: ${answer?'answered':'FAILED'} ${(ended-began)/1000}s peak=${peak}`);
}
