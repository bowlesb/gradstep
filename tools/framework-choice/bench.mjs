import {chromium,webkit} from '@playwright/test';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,extname} from 'node:path';
import {gzipSync} from 'node:zlib';
import os from 'node:os';
import {prepare,papers,filterSort} from './shared.js';
const root=resolve('dist');
const server=createServer(async(req,res)=>{
 try{
  let path=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(path.endsWith('/'))path+='index.html';
  const file=resolve(root,'.'+path);
  if(!file.startsWith(root+'/'))throw new Error('path');
  let body=await readFile(file);
  const type={'.html':'text/html','.js':'text/javascript','.css':'text/css'}[extname(file)]||'application/octet-stream';
  res.setHeader('Content-Type',type);res.setHeader('Cache-Control','no-store');
  if(/gzip/.test(req.headers['accept-encoding']||'')){body=gzipSync(body);res.setHeader('Content-Encoding','gzip');}
  res.end(body);
 }catch{res.writeHead(404);res.end('not found');}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+server.address().port;
const variants=['react','react-compiler','svelte'];
const cases=[{count:1000,virtual:false},{count:4000,virtual:false},{count:4000,virtual:true},{count:50000,virtual:true}];
const repeats=Number(process.env.REPEATS||7),rates=(process.env.RATES||'1,4').split(',').map(Number);
const result={started:new Date().toISOString(),host:{platform:os.platform(),arch:os.arch(),cpu:os.cpus()[0].model,node:process.version},
 versions:JSON.parse(await readFile('package.json','utf8')),bundle:JSON.parse(await readFile('bundle-sizes.json','utf8')),repeats,rates,runs:[],webkit:[]};
const settle=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
const metrics=async c=>Object.fromEntries((await c.send('Performance.getMetrics')).metrics.map(x=>[x.name,x.value]));
async function measure(page,cdp,action){
 await page.evaluate(()=>{window.longTasks=[];});
 const before=await metrics(cdp),start=Date.now();
 await action();
 await page.evaluate(settle);
 const after=await metrics(cdp);
 const task=await page.evaluate(()=>window.longTasks);
 return {task_ms:(after.TaskDuration-before.TaskDuration)*1000,script_ms:(after.ScriptDuration-before.ScriptDuration)*1000,
   layout_ms:(after.LayoutDuration-before.LayoutDuration)*1000,wall_ms:Date.now()-start,long_tasks:task};
}
let browser;
try{
 browser=await chromium.launch();
 result.browser=browser.version();
 for(const rate of rates)for(let repeat=0;repeat<repeats;repeat++)for(const test of cases){
  const order=variants.slice(repeat%3).concat(variants.slice(0,repeat%3));
  for(const variant of order){
   const context=await browser.newContext({viewport:{width:1280,height:860}});
   const page=await context.newPage(),errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   await page.addInitScript(()=>{window.longTasks=[];new PerformanceObserver(list=>{for(const e of list.getEntries())window.longTasks.push(e.duration);}).observe({type:'longtask',buffered:true});});
   const cdp=await context.newCDPSession(page);
   await cdp.send('Performance.enable');
   await cdp.send('Emulation.setCPUThrottlingRate',{rate});
   const boot=Date.now();
   await page.goto(base+'/'+variant+'/',{waitUntil:'load'});
   await page.waitForFunction(()=>window.bench&&window.stream);
   const startup_ms=Date.now()-boot;
   await page.evaluate(count=>window.bench.prepare(count),test.count);
   await page.evaluate(settle);
   const run={variant,rate,repeat,...test,startup_ms,operations:{}};
   run.operations.mount=await measure(page,cdp,()=>page.evaluate(t=>window.bench.load(t.count,t.virtual),test));
   run.dom=await page.evaluate(()=>window.bench.info());
   if(run.dom.count!==test.count||run.dom.dom!==(test.virtual?26:test.count))throw new Error('wrong row count '+JSON.stringify(run.dom));
   await cdp.send('HeapProfiler.collectGarbage');
   const memory=await metrics(cdp);
   run.heap_bytes=memory.JSHeapUsedSize;run.dom_nodes=memory.Nodes;
   run.operations.update=await measure(page,cdp,()=>page.evaluate(()=>{window.bench.update();}));
   if(await page.locator('[data-paper="1"] .progress').textContent()!=='1%')throw new Error('progress update not rendered');
   run.operations.sort=await measure(page,cdp,()=>page.evaluate(()=>{document.querySelector('button').click();}));
   prepare(test.count);
   const sortedID=String(filterSort(papers(test.count),'',true)[0].id);
   if(await page.locator('tr.row').first().getAttribute('data-paper')!==sortedID)throw new Error('sort not applied');
   run.operations.filter=await measure(page,cdp,()=>page.evaluate(()=>{
    const input=document.querySelector('input');
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'diffusion');
    input.dispatchEvent(new Event('input',{bubbles:true}));
   }));
   const filtered=await page.evaluate(()=>window.bench.info());
   if(filtered.count!==Math.ceil(test.count/6))throw new Error('wrong filter count');
   run.operations.clear=await measure(page,cdp,()=>page.evaluate(()=>{
    const input=document.querySelector('input');
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'');
    input.dispatchEvent(new Event('input',{bubbles:true}));
   }));
   if((await page.evaluate(()=>window.bench.info())).count!==test.count)throw new Error('filter clear not applied');
   const scrollSamples=[];
   run.operations.scroll=await measure(page,cdp,async()=>{
    for(const fraction of [.25,.5,.75,1,0]){
     await page.locator('.viewport').evaluate((el,f)=>el.scrollTop=(el.scrollHeight-el.clientHeight)*f,fraction);
     await page.evaluate(settle);
     scrollSamples.push(await page.locator('.viewport').evaluate(el=>{
      const rows=el.querySelectorAll('tr.row');
      return {top:el.scrollTop,first:rows[0]?.dataset.paper,last:rows[rows.length-1]?.dataset.paper};
     }));
    }
   });
   if(!scrollSamples.slice(0,4).every(s=>s.top>0)||scrollSamples[4].top!==0)throw new Error('scroll did not move');
   if(test.virtual&&scrollSamples[3].first===sortedID)throw new Error('virtual rows did not advance');
   if(scrollSamples[3].last!==String(filterSort(papers(test.count),'',true).at(-1).id))throw new Error('last paper not reachable');
   run.operations.stream=await measure(page,cdp,()=>page.evaluate(async()=>{
    window.frameTimes=[];let last=performance.now(),live=true;
    function frame(now){window.frameTimes.push(now-last);last=now;if(live)requestAnimationFrame(frame);}requestAnimationFrame(frame);
    for(let i=0;i<60;i++){window.stream.append('Reasoning '+i+' ');await new Promise(r=>setTimeout(r,16));}
    live=false;
   }));
   run.stream_frames=await page.evaluate(()=>({max:Math.max(...window.frameTimes),over50:window.frameTimes.filter(n=>n>50).length,count:window.frameTimes.length}));
   if(await page.locator('#answer').textContent()!=='Reasoning '+Array.from({length:60},(_,i)=>i+' ').join('Reasoning '))throw new Error('wrong stream text');
   if(errors.length)throw new Error(errors.join(';'));
   result.runs.push(run);
   await context.close();
   console.log(JSON.stringify({variant,rate,repeat,count:test.count,virtual:test.virtual,mount_ms:+run.operations.mount.task_ms.toFixed(1),filter_ms:+run.operations.filter.task_ms.toFixed(1),heap_mb:+(run.heap_bytes/1048576).toFixed(1)}));
   await writeFile('results.json',JSON.stringify(result,null,2)+'\n');
  }
 }
 await browser.close();browser=null;
 const wk=await webkit.launch();browser=wk;
 result.webkit_version=wk.version();
 for(const variant of variants){
  const context=await wk.newContext({viewport:{width:1280,height:860}});
  const page=await context.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.goto(base+'/'+variant+'/');await page.waitForFunction(()=>window.bench&&window.stream);
  await page.evaluate(()=>{window.bench.prepare(50000);window.bench.load(50000,true);});await page.evaluate(settle);
  await page.getByRole('textbox',{name:'Search library'}).fill('diffusion');await page.evaluate(settle);
  if(await page.getByRole('textbox',{name:'Search library'}).inputValue()!=='diffusion')throw new Error('webkit typing');
  if(await page.evaluate(()=>document.activeElement?.getAttribute('aria-label'))!=='Search library')throw new Error('webkit input focus');
  const first=await page.locator('a.title').first().textContent();
  await page.getByRole('button',{name:'Sort title',exact:true}).focus();
  await page.keyboard.press('Enter');await page.evaluate(settle);
  if(await page.locator('a.title').first().textContent()===first)throw new Error('webkit keyboard activation');
  await page.locator('.viewport').evaluate(el=>el.scrollTop=30000);await page.evaluate(settle);
  if(await page.locator('tr.row').count()>26)throw new Error('webkit unbounded DOM');
  await page.evaluate(()=>{const a=document.querySelector('a.title');const range=document.createRange();range.selectNodeContents(a);const s=getSelection();s.removeAllRanges();s.addRange(range);});
  const selected=await page.evaluate(()=>getSelection().toString());
  if(!selected.includes('Diffusion'))throw new Error('webkit selection');
  await page.evaluate(()=>{window.stream.append('Equation context');});await page.evaluate(settle);
  if(await page.evaluate(()=>getSelection().toString())!==selected)throw new Error('webkit selection lost on stream');
  if(errors.length)throw new Error(errors.join(';'));
  await mkdir('screenshots',{recursive:true});await page.screenshot({path:'screenshots/'+variant+'-webkit.png'});
  result.webkit.push({variant,passed:true,checks:['50k windowed','filter','typing focus and Enter activation','scroll','library title selection retained during adjacent plain-text stream']});
  await context.close();
 }
 await wk.close();browser=null;
 result.finished=new Date().toISOString();
 await writeFile('results.json',JSON.stringify(result,null,2)+'\n');
}catch(error){console.error(error);process.exitCode=1;}finally{if(browser)await browser.close();server.close();}
