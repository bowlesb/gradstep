import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fetchArxiv, runMetadataPipeline, type MetadataDeps } from '../../supabase/functions/_shared/metadata-pipeline.ts';

test('new exact-version membership reads Atom and the current official OAI endpoint, then stops at metadata', async () => {
 const calls:string[]=[],urls:string[]=[];
 const deps:MetadataDeps={
  rpc:async<T>(name:string,args:Record<string,unknown>={})=>{calls.push(name);
   if(name==='worker_pipeline_metadata'){assert.equal(args.p_revision,3);assert.equal(args.p_eligible,true);}
   return (name==='worker_pipeline_policy'?{enabled:true}:name==='worker_pipeline_claim'?{id:'paper',stage:'metadata',claim_id:'claim',generation:1,source_id:'2305.18290',requested_revision:3,failures:0}:name==='worker_pipeline_arxiv_slot'?{reserved:true,wait_ms:0,spacing_ms:3000}:null) as T;
  },
  fetch:async input=>{const url=String(input);urls.push(url);return new Response(readFileSync(new URL(`../fixtures/arxiv/2305.18290-${url.includes('/api/query')?'atom':'oai'}.xml`,import.meta.url)));},
  sleep:async()=>{},now:()=>Date.UTC(2026,9,13),uuid:()=> 'claim',log:()=>{},
 };
 await runMetadataPipeline(deps,deps.now()+60000);
 assert.equal(urls.length,2);assert.equal(new URL(urls[1]).origin+new URL(urls[1]).pathname,'https://oaipmh.arxiv.org/oai');
 assert.ok(calls.includes('worker_pipeline_metadata'));assert.ok(calls.includes('worker_pipeline_sync_imports'));
 assert.ok(!calls.includes('worker_pipeline_defer'));assert.ok(calls.every(n=>!/(fund|submit|original|asset)/.test(n)));
});

test('retained PDF and provider stages are never fetched, processed, collected or funded', async () => {
 for (const stage of ['download','private_split','ocr_fund','ocr_submit','ocr_wait','ocr_uncertain','render','source_only','done']) {
  const calls: string[] = [];
  const deps: MetadataDeps = {
   rpc: async <T>(name: string) => { calls.push(name); return (name === 'worker_pipeline_policy' ? { enabled:true } : name === 'worker_pipeline_claim'
    ? {id:'retained-paper',stage,claim_id:'claim',generation:2} : null) as T; },
   fetch: async () => {throw Error('no network allowed');}, sleep: async () => {}, now: () => 0, uuid: () => 'claim', log: () => {},
  };
  assert.deepEqual(await runMetadataPipeline(deps, 60_000), {processed:1});
  assert.deepEqual(calls,['worker_pipeline_policy','worker_expire_stale_chat_operations','worker_pipeline_claim','worker_pipeline_sync_imports','worker_pipeline_release']);
 }
});
test('metadata transport cannot follow an arXiv PDF or HTML redirect', async () => {
 for (const url of ['https://arxiv.org/pdf/2305.18290v3','https://arxiv.org/html/2305.18290v3','https://evil.example/api/query']) {
  let calls = 0;
  await assert.rejects(fetchArxiv(async () => {calls++;return new Response('bad');},url,1000,'application/xml'));
  assert.equal(calls,0);
  await assert.rejects(fetchArxiv(async () => {calls++; return new Response(null,{status:302,headers:{location:url}});},'https://export.arxiv.org/api/query?id_list=2305.18290v3',1000,'application/xml'));
  assert.equal(calls,1);
 }
});
