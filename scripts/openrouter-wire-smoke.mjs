#!/usr/bin/env node
// Explicit paid transport contract check. Synthetic text only, max $0.50 spent + unresolved holds.
// Same production adapters; durable service-actor/operation/attempt attribution, no unrecorded sends or retries.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { SpendLedger } from './model-bakeoff-support.mjs';
import { openRouterScriptProvider } from '../supabase/functions/_shared/openrouter-script.ts';
import { openRouterSpeechProvider } from '../supabase/functions/_shared/openrouter-speech.ts';
import { speechRequest } from '../supabase/functions/_shared/podcast-speech.ts';
import { draftRequest } from '../supabase/functions/_shared/podcast-script.ts';
const dir='.artifacts/openrouter-unification-20261018/wire';mkdirSync(dir,{recursive:true});
const ledger=new SpendLedger(`${dir}/spend.json`,0.50), accountID='bace0ff0-0000-4000-8000-000000000001';
const operationID=randomUUID();
const env=Object.fromEntries(readFileSync('.env.providers','utf8').split('\n').filter(l=>l.includes('=')&&!l.startsWith('#')).map(l=>{
  const i=l.indexOf('=');return[l.slice(0,i).trim(),l.slice(i+1).trim().replace(/^(['"])(.*)\1$/,'$2')];}));
const apiKey=env.OPENROUTER_CHAT_API_KEY;if(!apiKey)throw Error('Dedicated OpenRouter key missing');
const speechCheck=process.argv.find(a=>a.startsWith('--speech-check='))?.slice(15)??'speech';
if(!/^speech(?:-[a-z0-9]+)?$/.test(speechCheck))throw Error('Invalid check identity');
const diagnosticFetch=async(url,init)=>{const response=await fetch(url,init);
  if(!response.ok){const raw=(await response.clone().text()).slice(0,4000).split(apiKey).join('[redacted]');
    writeFileSync(`${dir}/${speechCheck}-error.json`,JSON.stringify({status:response.status,body:raw},null,2));}
  return response;};
function attribution(name,hold){
  const attemptID=randomUUID();let dispatched=false;
  return {accountID,operationID,attemptID,feature:'wire_smoke',caller:'model_evaluation',
    dispatch:async metadata=>{if(dispatched||ledger.rows.some(r=>r.check===name))return false;
      ledger.reserve(hold,{id:attemptID,actor_uuid:accountID,operation_uuid:operationID,check:name,...metadata});dispatched=true;return true;},
    receipt:async metadata=>{const row=ledger.rows.find(r=>r.id===attemptID);if(!row)return false;
      row.receipt=metadata;ledger.identify(attemptID,metadata.generation_id);return true;}};
}
async function record(name,result,a){
  const row=ledger.rows.find(r=>r.id===a.attemptID);
  if(row){if(result.requestID)ledger.identify(a.attemptID,result.requestID);
    ledger.settle(a.attemptID,result.state==='rejected'?0:result.billedMicrousd==null?null:result.billedMicrousd/1e6);}
  const summary={check:name,state:result.state,failure:result.failure,model:result.model,generation:result.requestID,
    cost_usd:result.billedMicrousd==null?null:result.billedMicrousd/1e6,usage:result.usage,
    stop:result.stopReason??result.finishReason,has_output:!!(result.text||result.audio),at:new Date().toISOString()};
  writeFileSync(`${dir}/${name}.json`,JSON.stringify(summary,null,2));console.log(summary);
}
for(const [name,model] of [['haiku','claude-haiku-5-5'],['deepseek-pro','deepseek-v4-pro'],['deepseek-flash','deepseek-flash']]){
  if(ledger.rows.some(r=>r.check===name))continue;
  const a=attribution(name,0.04),result=await openRouterScriptProvider({apiKey}).generate({model,max_tokens:128,thinking:{type:'disabled'},
    system:'Return a JSON object with ok set to true.',messages:[{role:'user',content:'Confirm the integration test.'}],
    output_config:{format:{type:'json_schema',schema:{type:'object',properties:{ok:{type:'boolean'}},required:['ok'],additionalProperties:false}}}},AbortSignal.timeout(90000),a);
  await record(name,result,a);
  if(result.state!=='succeeded'||JSON.parse(result.text??'{}').ok!==true)throw Error(`Wire check failed: ${name}`);
}
if(process.argv.includes('--claude-draft')&&!ledger.rows.some(r=>r.check==='claude-draft-low')){
  const a=attribution('claude-draft-low',0.15),request=draftRequest('A synthetic test paper states that a model was compared with a baseline. No numeric results are available.', 'Synthetic integration check',128);
  const result=await openRouterScriptProvider({apiKey,fetch:diagnosticFetch}).generate(request,AbortSignal.timeout(90000),a);
  await record('claude-draft-low',result,a);
  if(result.state!=='succeeded')throw Error('Claude draft schema rejected');
}
if(!ledger.rows.some(r=>r.check===speechCheck)){
  const a=attribution(speechCheck,0.303104),request=speechRequest({segments:[
    {text:'Welcome to Gradstep.',speaker:'explainer',style:'calm'},
    {text:'Let us read the evidence.',speaker:'skeptic',style:'curious'}]}, {explainer:'Sadaltager',skeptic:'Erinome'},16384);
  const result=await openRouterSpeechProvider({apiKey,fetch:diagnosticFetch}).generate(request,AbortSignal.timeout(90000),a);
  await record(speechCheck,result,a);if(result.state!=='succeeded'||!result.audio)throw Error('Speech wire check failed');
  writeFileSync(`${dir}/speech.wav`,result.audio);
}
console.log({actual_usd:ledger.actual,outstanding_usd:ledger.outstanding,cap_usd:ledger.cap,actor_uuid:accountID});
