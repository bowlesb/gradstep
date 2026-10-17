#!/usr/bin/env node
// Fetch once on the developer's own device. Test/release runs replay these bytes without network access.
import {readFileSync,writeFileSync,existsSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
if(process.platform!=='darwin'||process.argv[2]!=='--on-this-device')throw Error('Run locally with --on-this-device; never on a server.');
const lock=JSON.parse(readFileSync(new URL('../tests/corpus/import-regressions.json',import.meta.url)));
const cache=new URL('../.artifacts/import-corpus/',import.meta.url);mkdirSync(cache,{recursive:true});
const digest=b=>createHash('sha256').update(b).digest('hex');
let fetched=0;
for(const paper of lock.cases)for(const input of paper.responses){
 const target=new URL(input.sha256,cache);
 if(existsSync(target)&&digest(readFileSync(target))===input.sha256)continue;
 const url=new URL(input.url),base=`/html/${paper.source_id}v${paper.revision}`;
 if(url.origin!=='https://arxiv.org'||!(url.pathname===base||url.pathname.startsWith(base+'/')||url.pathname===`/pdf/${paper.source_id}v${paper.revision}`))throw Error('Unapproved corpus URL');
 const r=await fetch(url,{redirect:'error',headers:{'user-agent':'Gradstep/0.1 device import acceptance (+https://gradstep.ai; mailto:hello@gradstep.ai)'},signal:AbortSignal.timeout(60000)});
 const body=Buffer.from(await r.arrayBuffer());
 if(r.status!==input.status||body.length!==input.bytes||digest(body)!==input.sha256)throw Error(`Pinned source changed: ${input.url}. Review the change; do not silently update the lock.`);
 writeFileSync(target,body);fetched++;
 await new Promise(resolve=>setTimeout(resolve,500));
}
console.log(`Import regression corpus verified; ${fetched} responses fetched on this device.`);
