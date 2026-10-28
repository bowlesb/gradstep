import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {createInterface} from 'node:readline';
import {performance} from 'node:perf_hooks';
const source=readFileSync(new URL('../apps/apple/ScienceReader/Resources/pdf-position-matcher.js',import.meta.url),'utf8');
const model=new Function(source+';return PDFPositionMatcher;')();
const report={model:model.version,modelSHA256:createHash('sha256').update(source).digest('hex'),split:process.argv[process.argv.indexOf('--split')+1],environment:`${process.platform}/${process.arch} Node ${process.version}; Poppler text (not PDFKit/device latency)`,papers:0,pages:0,skipped:{},results:{},corpus:[],failures:[]};
const indexTimes=[],queryTimes=[]; let previousQuery=null;
for await(const line of createInterface({input:process.stdin,crlfDelay:Infinity})) {
 const record=JSON.parse(line);
 if(record.skip){report.skipped[record.skip]=(report.skipped[record.skip]||0)+1;continue;}
 let index;const begin=performance.now();
 try{index=model.create(record.pages);}catch{report.skipped['model-limit']=(report.skipped['model-limit']||0)+1;continue;}
 indexTimes.push(performance.now()-begin);report.papers++;report.pages+=record.pages.length;report.corpus.push({id:record.paper,sha256:record.sha256});
 if(previousQuery) {
  // A different paper's academic prose is harder than the fixed unrelated negative. Require its distinctive
  // opening to be absent by an independent exact-character oracle before treating it as a negative.
  const flat=s=>s.normalize('NFKD').toLowerCase().replace(/[^\p{L}\p{N}]/gu,'');
  const opening=flat(previousQuery.split(/\s+/).slice(0,16).join(' '));
  if(opening.length>60 && !record.pages.some(p=>flat(p).includes(opening))) record.tests.push({kind:'cross-paper-negative',text:previousQuery});
 }
 previousQuery=record.tests.find(q=>q.kind==='html-silver')?.text??null;
 for(const [number,q] of record.tests.entries()){
  const t=performance.now(),result=index.match(q.text);queryTimes.push(performance.now()-t);
  const row=report.results[q.kind]??={total:0,correct:0,wrong:0,abstained:0};row.total++;
  if(q.kind.endsWith('negative')){if(result.status==='unmatched')row.correct++;else row.wrong++;continue;}
  if(result.status!=='matched'){row.abstained++;continue;}
  // Page + overlapping original character range, not just document/page retrieval.
  const match=result.ranges.find(r=>r.page===q.page && r.location<q.end && r.location+r.length>q.location);
  if(match)row.correct++;else {row.wrong++;if(report.failures.length<30)report.failures.push({paper:record.paper,kind:q.kind,number,expectedPage:q.page,actualPages:result.ranges.map(r=>r.page),score:result.score});}
 }
}
const stats=a=>{a.sort((x,y)=>x-y);return {p50:a[Math.floor(a.length*.5)]??null,p95:a[Math.floor(a.length*.95)]??null,max:a.at(-1)??null};};
report.milliseconds={index:stats(indexTimes),query:stats(queryTimes)};
writeFileSync(process.argv[process.argv.indexOf('--output')+1],JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({...report,corpus:undefined,failures:report.failures.length},null,2));
