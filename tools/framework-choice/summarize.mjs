import {readFile,writeFile,mkdir} from 'node:fs/promises';
const data=JSON.parse(await readFile('results.json','utf8'));
if (!data.finished || data.runs.length !== data.rates.length * data.repeats * 4 * 3
  || data.webkit.length !== 3 || data.webkit.some(run => !run.passed)) {
 throw new Error('Only a completed comparison with all Chromium samples and WebKit checks can be published.');
}
const median=a=>{const s=a.toSorted((x,y)=>x-y);return s.length%2?s[(s.length-1)/2]:(s[s.length/2-1]+s[s.length/2])/2;};
const summary=a=>({median:median(a),min:Math.min(...a),max:Math.max(...a)});
const groups=[];
for(const rate of data.rates)for(const count of [1000,4000,50000])for(const virtual of [false,true])for(const variant of ['react','react-compiler','svelte']){
 const runs=data.runs.filter(r=>r.rate===rate&&r.count===count&&r.virtual===virtual&&r.variant===variant);
 if(!runs.length)continue;
 if(runs.length!==data.repeats)throw new Error('Incomplete comparison group');
 const group={rate,count,virtual,variant,samples:runs.length,heap_mb:summary(runs.map(r=>r.heap_bytes/1048576)),dom_nodes:summary(runs.map(r=>r.dom_nodes)),startup_ms:summary(runs.map(r=>r.startup_ms)),operations:{}};
 for(const operation of Object.keys(runs[0].operations)){
  group.operations[operation]={task_ms:summary(runs.map(r=>r.operations[operation].task_ms)),
    script_ms:summary(runs.map(r=>r.operations[operation].script_ms)),layout_ms:summary(runs.map(r=>r.operations[operation].layout_ms)),
    long_tasks:summary(runs.map(r=>r.operations[operation].long_tasks.length)),max_long_task_ms:Math.max(...runs.flatMap(r=>r.operations[operation].long_tasks),0)};
 }
 group.stream_max_frame_ms=summary(runs.map(r=>r.stream_frames.max));
 groups.push(group);
}
const result={started:data.started,finished:data.finished,host:data.host,browser:data.browser,webkit_version:data.webkit_version,
 versions:data.versions,bundle:data.bundle,total_samples:data.runs.length,repetitions:data.repeats,groups,webkit:data.webkit};
const output='../../docs/research/framework-choice-2026-10-07';
await mkdir(output,{recursive:true});
await writeFile(output+'/summary.json',JSON.stringify(result,null,2)+'\n');
await writeFile(output+'/measurements.json',JSON.stringify(data,null,2)+'\n');
console.log(JSON.stringify({samples:result.total_samples,complete:!!result.finished,output},null,2));
